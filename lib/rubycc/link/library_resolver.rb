# frozen_string_literal: true

require "rbconfig"
require "set"

module Rubycc
  module Link
    # Turns the command line's library requests (`-l` names and `-L` search
    # directories) into the two concrete input sets the final link consumes: the
    # shared objects whose exports satisfy imports (SharedLinker's `needed:`) and
    # the relocatable inputs pulled in for their definitions (SharedLinker's
    # `inputs`, where archives are taken lazily). It is the piece that stands
    # between a driver's flags and the linker core: nothing here reads a compiler
    # flag string — the caller has already split `-lz` into the name `"z"` and
    # `-L/opt/lib` into a directory — so this class only does the resolution the
    # ELF/GNU conventions prescribe.
    #
    # Search follows the classic rule: each `-L` directory in command-line order,
    # then the platform's default library directories (only those that exist), and
    # within a single directory an unversioned `lib<name>.so`, a versioned
    # `lib<name>.so.<version>`, and then `lib<name>.a` are preferred in that order.
    # The first directory holding either form settles the request — the `.so`/`.a`
    # preference does not reach across directories, so an earlier directory's `.a`
    # wins over a later directory's `.so`, matching the traditional linker. A
    # `:filename` request (`-l:libfoo.so.1`) looks that exact name up instead of
    # composing `lib…so`/`lib…a`.
    #
    # A resolved file is dispatched by what it actually is, read from its leading
    # bytes: an ELF shared object (ET_DYN) joins `needed`, an ELF relocatable or an
    # `ar` archive joins `inputs`, and anything else is treated as a GNU-ld text
    # linker script (glibc ships `libc.so` as `GROUP ( libc.so.6 … )`) whose
    # GROUP/INPUT file lists are expanded and each named file resolved in turn.
    #
    # The transitive closure of shared dependencies is deliberately *not* followed:
    # a `.so` that itself needs other `.so`s records those as its own DT_NEEDED and
    # the runtime loader pulls them at load time; a static link only needs the
    # directly requested libraries. Deduplication is by real path so the same
    # library requested twice (or reached once directly and once through a script)
    # contributes a single entry, keeping the output deterministic (N4).
    class LibraryResolver
      # ELF and `ar` magics, and the e_type value that marks a shared object; a
      # resolved file matching neither magic is taken to be a text linker script.
      ELFMAG   = "\x7FELF".b
      AR_MAGIC = "!<arch>\n".b
      ET_DYN   = 3

      # The target's default library directories, consulted after every `-L`
      # directory. Debian's multiarch directory is target-specific; using the
      # x86_64 spelling unconditionally made a native aarch64 build unable to
      # resolve even libc's ordinary `-lm`/`-lpthread` dependencies.
      TARGET_SYSTEM_DIRS = {
        "x86_64" => [
          "/usr/lib/x86_64-linux-gnu",
          "/usr/lib",
          "/lib/x86_64-linux-gnu",
          "/lib",
          "/usr/local/lib"
        ].freeze,
        "aarch64" => [
          "/usr/lib/aarch64-linux-gnu",
          "/usr/lib",
          "/lib/aarch64-linux-gnu",
          "/lib",
          "/usr/aarch64-linux-gnu/lib",
          "/usr/local/lib"
        ].freeze
      }.freeze

      # musl folds the libraries that glibc normally exposes as separate DSOs into
      # libc. Runtime images therefore have no libm.so, libpthread.so, or libdl.so
      # (and often no unversioned libc.so either), even though extconf-generated
      # link flags still request them. Only these known libc-provided names are
      # eligible for the fallback; an absent arbitrary `-lfoo` must remain an
      # error rather than silently depending on libc.
      MUSL_LIBC_PROVIDED_LIBRARIES = %w[c m pthread rt dl resolv util crypt nsl].freeze

      # Alpine/musl runtime names. The loader is also the libc implementation, so
      # it is a valid last-resort target when a libc.musl-* compatibility symlink
      # is not present in a stripped runtime.
      MUSL_LIBC_FILE = /\Alibc\.musl(?:-[^.]*)?\.so\.\d[\w.-]*\z/
      MUSL_LOADER_FILE = /\Ald-musl-[^.]+\.so\.\d[\w.-]*\z/
      VERSIONED_SHARED_SUFFIX = /\A\d[\w.-]*\z/

      class << self
        # Return the conventional system library directories for +target+.
        # A target triple is accepted because the driver normalizes one before
        # passing it here. Unknown targets fall back to the host layout so that
        # the resolver remains useful for diagnostics instead of inventing a
        # multiarch path for an unsupported architecture.
        def default_system_dirs(target: nil)
          arch = normalize_target(target || RbConfig::CONFIG["host_cpu"])
          TARGET_SYSTEM_DIRS.fetch(arch) do
            TARGET_SYSTEM_DIRS.fetch(normalize_target(RbConfig::CONFIG["host_cpu"])) do
              TARGET_SYSTEM_DIRS.fetch("x86_64")
            end
          end
        end

        def normalize_target(spec)
          cpu = spec.to_s.split("-", 2).first.to_s
          case cpu
          when "amd64", "x64" then "x86_64"
          when "arm64"        then "aarch64"
          else cpu
          end
        end

        # Resolves `libraries` (an ordered array of `-l` argument strings, each the
        # text after `-l`, e.g. `"z"` or `":libfoo.so.1"`) against `search_dirs`
        # (the `-L` directories, in order) and returns a Resolution.
        def resolve(libraries, search_dirs: [], target: nil)
          new(search_dirs: search_dirs, target: target).resolve(libraries)
        end

        # High-level convenience for a driver: resolves `libraries` and links them
        # together with the object `inputs` into a shared object. The resolved
        # archives follow the objects so the lazy pull-in sees the objects'
        # undefined symbols first; the resolved shared objects become the
        # dependencies imports bind against.
        def link(inputs, libraries: [], search_dirs: [], soname: nil, target: nil)
          r = resolve(libraries, search_dirs: search_dirs, target: target)
          SharedLinker.link(inputs + r.inputs, needed: r.needed, soname: soname)
        end

        # Convenience: link and write the shared object to `path`.
        def link_to(inputs, path, libraries: [], search_dirs: [], soname: nil, target: nil)
          File.binwrite(path, link(inputs, libraries: libraries, search_dirs: search_dirs,
                                   soname: soname, target: target))
        end
      end

      # Kept as a public host-layout constant for callers and tests that need to
      # inspect the default search path without selecting a cross target.
      DEFAULT_SYSTEM_DIRS = default_system_dirs.freeze

      # The outcome of resolving a set of library requests: `needed` are the shared
      # object paths to bind imports against, `inputs` the relocatable inputs
      # (archives and objects) to feed the merge, both in first-seen order.
      Resolution = Struct.new(:needed, :inputs, keyword_init: true)

      def initialize(search_dirs: [], target: nil)
        @dirs = (search_dirs + self.class.default_system_dirs(target: target)).select do |d|
          File.directory?(d)
        end
      end

      # The ordered search path actually consulted (existing `-L` dirs followed by
      # the existing default directories); exposed so a driver can report it.
      attr_reader :dirs

      def resolve(libraries)
        @needed = []
        @inputs = []
        @seen = Set.new
        libraries.each { |spec| resolve_spec(spec) }
        Resolution.new(needed: @needed, inputs: @inputs)
      end

      private

      # Resolves one `-l` request to a file and ingests it. `spec` is the text
      # after `-l`: a leading colon selects an exact filename, otherwise the name
      # is composed into `lib<name>.so` / `lib<name>.a`.
      def resolve_spec(spec)
        ingest(find_library(spec))
      end

      # Locates the file for a `-l` request. For a plain name each directory is
      # tried in order, preferring an unversioned shared object, then a versioned
      # shared object, then an archive within that directory; the first directory
      # carrying any form wins. On musl, the small set of libraries folded into
      # libc falls back to the detected musl libc image after the ordinary search.
      # A `:filename` request looks the given name up verbatim. An unsatisfiable
      # request is a hard error, named the way a driver reports a missing library.
      def find_library(spec)
        if spec.start_with?(":")
          exact = spec[1..]
          dir = @dirs.find { |d| File.file?(File.join(d, exact)) }
          return File.join(dir, exact) if dir
        else
          path = find_plain_library(spec)
          return path if path

          if MUSL_LIBC_PROVIDED_LIBRARIES.include?(spec)
            libc = find_musl_libc
            return libc if libc
          end
        end
        raise LinkError, "cannot find -l#{spec}"
      end

      # Searches the normal shared/archive forms for a plain `-l` request. The
      # versioned form matters in runtime-only images, where package managers keep
      # `libz.so.1` but omit the development symlink `libz.so`.
      def find_plain_library(spec)
        @dirs.each do |d|
          shared = File.join(d, "lib#{spec}.so")
          return shared if File.file?(shared)

          versioned = find_versioned_shared(d, spec)
          return versioned if versioned

          archive = File.join(d, "lib#{spec}.a")
          return archive if File.file?(archive)
        end
        nil
      end

      # Finds a versioned shared object without manufacturing or requiring the
      # unversioned development symlink. Symlinks carrying the ABI/SONAME name
      # are preferred over their fully-versioned targets when both are present;
      # otherwise the highest numeric version is selected deterministically.
      def find_versioned_shared(dir, spec)
        prefix = "lib#{spec}.so."
        candidates = directory_entries(dir).filter_map do |name|
          next unless name.start_with?(prefix)
          suffix = name.delete_prefix(prefix)
          next unless VERSIONED_SHARED_SUFFIX.match?(suffix)

          path = File.join(dir, name)
          path if File.file?(path)
        end
        choose_versioned(candidates)
      end

      # Finds musl's combined libc image. Prefer the libc.musl-* name, which is
      # the stable library spelling in Alpine runtime images, and use the loader
      # name as a fallback because musl implements both entry points in one ELF.
      # Searching the resolver's directories keeps this useful for a mounted
      # runtime/sysroot rather than assuming only the host's /lib.
      def find_musl_libc
        @dirs.each do |dir|
          candidate = choose_versioned(directory_entries(dir).filter_map do |name|
            next unless MUSL_LIBC_FILE.match?(name)

            path = File.join(dir, name)
            path if File.file?(path)
          end)
          return candidate if candidate
        end

        @dirs.each do |dir|
          candidate = choose_versioned(directory_entries(dir).filter_map do |name|
            next unless MUSL_LOADER_FILE.match?(name)

            path = File.join(dir, name)
            path if File.file?(path)
          end)
          return candidate if candidate
        end
        nil
      end

      def choose_versioned(candidates)
        candidates.max_by do |path|
          name = File.basename(path)
          version = name.split(".so.", 2).last.to_s.split(".").map(&:to_i)
          [File.symlink?(path) ? 1 : 0, version, name]
        end
      end

      def directory_entries(dir)
        Dir.children(dir)
      rescue SystemCallError
        []
      end

      # Classifies a resolved file and routes it: a shared object to `needed`, a
      # relocatable object or archive to `inputs`, a linker script to expansion.
      # Files are deduplicated by real path so a library reached more than once
      # (directly and through a script, say) is recorded a single time.
      def ingest(path)
        return unless @seen.add?(dedup_key(path))

        case classify(path)
        when :shared          then @needed << path
        when :object, :archive then @inputs << path
        when :script          then expand_script(path)
        end
      end

      # A stable identity for deduplication: the canonical real path when it can be
      # resolved, else the path as given (a broken symlink still keys on itself).
      def dedup_key(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      # Reads a file's leading bytes and names its kind. The 18 bytes cover the ELF
      # magic and e_type; a shorter file cannot be an ELF object. A file matching
      # neither the ELF nor the `ar` magic is assumed to be a text linker script.
      def classify(path)
        head = File.binread(path, 18).to_s.b
        if head.start_with?(ELFMAG)
          head.byteslice(16, 2).to_s.unpack1("S<") == ET_DYN ? :shared : :object
        elsif head.start_with?(AR_MAGIC)
          :archive
        else
          :script
        end
      end

      # Parses a GNU-ld text linker script for its GROUP/INPUT file lists and
      # resolves each named entry, in order, through the same machinery — so a
      # `-l` token inside the script searches the path recursively and an absolute
      # path is ingested directly.
      def expand_script(path)
        LinkerScript.parse(File.read(path)).each { |token| resolve_token(token) }
      end

      # Resolves one token from a linker script's file list. A `-l` token is a
      # nested library request; any other token is a file path — used verbatim
      # when it exists, otherwise looked up by name across the search directories.
      def resolve_token(token)
        return resolve_spec(token.sub(/\A-l/, "")) if token.start_with?("-l")

        path =
          if File.file?(token)
            token
          else
            dir = @dirs.find { |d| File.file?(File.join(d, token)) }
            dir && File.join(dir, token)
          end
        raise LinkError, "cannot find '#{token}' referenced by a linker script" unless path

        ingest(path)
      end
    end

    # A deliberately small reader for the sliver of GNU-ld linker-script syntax
    # that a library search actually meets: the file-list commands GROUP and INPUT
    # (with AS_NEEDED nested inside), and OUTPUT_FORMAT, which is skipped. glibc's
    # `libc.so` is exactly such a script — `/* GNU ld script */ GROUP ( … )` — and
    # this recovers the real files it points at.
    #
    # It is not a linker-script *language*: SECTIONS, PROVIDE, MEMORY, symbol
    # assignments and the rest are not modelled. Only the recognized commands act;
    # every other token outside a file list is ignored, so an unfamiliar directive
    # passes by without derailing the scan rather than being half-interpreted.
    # AS_NEEDED contents are treated as ordinary inputs here — the "only if used"
    # trimming is the DT_NEEDED as-needed logic SharedLinker already applies.
    class LinkerScript
      # The commands that introduce a parenthesized list of input files. AS_NEEDED
      # appears nested within GROUP/INPUT but is itself just another such list.
      FILE_LIST_COMMANDS = %w[GROUP INPUT AS_NEEDED].freeze

      class << self
        # Parses `text` and returns the ordered file tokens its GROUP/INPUT lists
        # name (absolute paths or `-l` requests), for the caller to resolve.
        def parse(text)
          new(text).parse
        end
      end

      def initialize(text)
        @tokens = tokenize(strip_comments(text))
      end

      def parse
        files = []
        i = 0
        while i < @tokens.length
          token = @tokens[i]
          if FILE_LIST_COMMANDS.include?(token) && @tokens[i + 1] == "("
            i = collect(i + 1, files)
          elsif token == "OUTPUT_FORMAT" && @tokens[i + 1] == "("
            i = skip_parens(i + 1)
          else
            i += 1
          end
        end
        files
      end

      private

      # Collects a parenthesized file list starting at `open` (the index of its
      # `(`), appending each file token to `out` and recursing into nested
      # GROUP/INPUT/AS_NEEDED lists so their files land in the same order. Commas,
      # which GNU-ld allows between file names, are separators and dropped. Returns
      # the index just past the matching `)`.
      def collect(open, out)
        i = open + 1
        loop do
          token = @tokens[i]
          raise LinkError, "unterminated file list in linker script" if token.nil?

          case token
          when ")" then return i + 1
          when "," then i += 1
          when *FILE_LIST_COMMANDS
            raise LinkError, "expected '(' after #{token} in linker script" unless @tokens[i + 1] == "("

            i = collect(i + 1, out)
          when "OUTPUT_FORMAT"
            i = @tokens[i + 1] == "(" ? skip_parens(i + 1) : i + 1
          else
            out << token
            i += 1
          end
        end
      end

      # Skips a balanced parenthesized group starting at `open` (its `(`), used to
      # discard an OUTPUT_FORMAT's contents. Returns the index past the matching
      # `)`.
      def skip_parens(open)
        depth = 0
        i = open
        loop do
          token = @tokens[i]
          raise LinkError, "unterminated group in linker script" if token.nil?

          depth += 1 if token == "("
          depth -= 1 if token == ")"
          return i + 1 if depth.zero?

          i += 1
        end
      end

      # Removes `/* … */` comments (the only comment form the scripts use),
      # replacing each with a space so it cannot glue two tokens together.
      def strip_comments(text)
        text.gsub(%r{/\*.*?\*/}m, " ")
      end

      # Splits the script into words, first padding the structural punctuation
      # (parentheses and commas) with spaces so `GROUP(a,b)` tokenizes the same as
      # `GROUP ( a , b )`.
      def tokenize(text)
        text.gsub(/([(),])/, ' \1 ').split
      end
    end
  end
end
