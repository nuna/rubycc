# frozen_string_literal: true

module Rubycc
  module Pkgconf
    # Drops the `-I<dir>`/`-L<dir>` tokens whose directory the toolchain
    # already searches on its own. pkg-config suppresses those in its
    # --cflags/--libs output (emitting them would let a package silently
    # reorder the compiler's or linker's default search order), so a shim that
    # kept them would disagree with the real tool on the most common packages
    # of all: this environment's zlib.pc alone carries `-I/usr/include` and
    # `-L${libdir}`.
    #
    # The two escape hatches are the ones the environment exposes:
    # PKG_CONFIG_ALLOW_SYSTEM_CFLAGS / PKG_CONFIG_ALLOW_SYSTEM_LIBS turn the
    # respective filter off, and PKG_CONFIG_SYSTEM_INCLUDE_PATH /
    # PKG_CONFIG_SYSTEM_LIBRARY_PATH (colon-separated, mirroring PATH) replace
    # the directory lists below.
    class SystemPathFilter
      # What counts as a system directory when nothing overrides it.
      DEFAULT_INCLUDE_DIRECTORIES = ["/usr/include"].freeze

      # What counts as a system library directory, in two groups.
      #
      # The multiarch pair is here because CI measured the real pkg-config
      # against a Debian zlib.pc (libdir=${prefix}/lib/x86_64-linux-gnu) and
      # found it drops the `-L` for that directory too, not just plain /usr/lib:
      # on Debian/Ubuntu the multiarch libdir *is* a system libdir as far as
      # pkg-config is concerned. It is applied only when the directory exists,
      # because a multiarch libdir is a Debian/Ubuntu layout: on a host without
      # one (Alpine, measured in CI) the real pkg-config keeps a `-L` naming it,
      # since there it is an ordinary directory rather than one the linker
      # already searches. Dropping it there made this shim emit `-lz` where the
      # real tool emitted `-L/usr/lib/x86_64-linux-gnu -lz` (docs/STEPS.md Step
      # 196).
      #
      # /usr/lib, /lib and /usr/lib64 are unconditional: they are system libdirs
      # wherever they exist, and gating them on existence would change what this
      # shim emits on the hosts the other measurements were taken on.
      #
      # The lists are deliberately kept in step with the other hardcoded
      # "default search directory" lists in this codebase --
      # Link::LibraryResolver::DEFAULT_SYSTEM_DIRS and
      # SearchPath::DEFAULT_DIRECTORIES both already special-case the same
      # multiarch path -- on the theory that a directory this shim's own linker
      # searches by default is never worth emitting a `-L` for; that is the
      # whole point of this filter.
      #
      # /usr/local/lib is deliberately *not* included even though
      # LibraryResolver::DEFAULT_SYSTEM_DIRS lists it: the real pkg-config does
      # not treat it as a system directory, and adding it would make this shim
      # diverge from the measured behaviour instead of matching it.
      MULTIARCH_LIBRARY_DIRECTORIES = [
        "/usr/lib/x86_64-linux-gnu",
        "/lib/x86_64-linux-gnu"
      ].freeze

      UNIVERSAL_LIBRARY_DIRECTORIES = [
        "/usr/lib",
        "/lib",
        "/usr/lib64"
      ].freeze

      # The system libdirs on *this* host, in the order above.
      def self.default_library_directories
        MULTIARCH_LIBRARY_DIRECTORIES.select { |d| File.directory?(d) } + UNIVERSAL_LIBRARY_DIRECTORIES
      end

      # +env+ is an argument (defaulting to the process environment) for the
      # same reason SearchPath.directories takes one: it keeps the lookup
      # injectable from a test without mutating the global ENV.
      def initialize(env = ENV)
        @include_directories = directory_list(env["PKG_CONFIG_SYSTEM_INCLUDE_PATH"], DEFAULT_INCLUDE_DIRECTORIES)
        @library_directories = directory_list(env["PKG_CONFIG_SYSTEM_LIBRARY_PATH"],
                                             self.class.default_library_directories)
        @keep_system_includes = set?(env["PKG_CONFIG_ALLOW_SYSTEM_CFLAGS"])
        @keep_system_libraries = set?(env["PKG_CONFIG_ALLOW_SYSTEM_LIBS"])
      end

      # +tokens+ with the system `-I<dir>` entries removed. Every other token
      # (`-D...`, a bare `-I`, `-l...`, ...) is passed through untouched.
      def cflags(tokens)
        return tokens if @keep_system_includes

        reject_system(tokens, "-I", @include_directories)
      end

      # +tokens+ with the system `-L<dir>` entries removed; `-l` and the rest
      # are passed through untouched.
      def libs(tokens)
        return tokens if @keep_system_libraries

        reject_system(tokens, "-L", @library_directories)
      end

      private

      # Only the one-token `-I/usr/include` spelling is recognized. A `.pc`
      # that writes the directory as a separate token (`-I /usr/include`)
      # already defeats this shim's --cflags-only-I/--cflags-only-other split,
      # which classifies per token, so nothing here tries to pair the two up.
      def reject_system(tokens, flag, system_directories)
        tokens.reject do |token|
          token.start_with?(flag) && token.length > flag.length &&
            system_directories.include?(normalize(token[flag.length..]))
        end
      end

      # An explicit value replaces the default outright, even when it is empty
      # (`PKG_CONFIG_SYSTEM_INCLUDE_PATH=` then means "no directory is a
      # system directory"); only an unset variable falls back to +defaults+.
      def directory_list(value, defaults)
        list = value.nil? ? defaults : value.split(File::PATH_SEPARATOR).reject(&:empty?)
        list.map { |dir| normalize(dir) }
      end

      def set?(value)
        !value.nil? && !value.empty?
      end

      # Compare directories as text, not as filesystem objects: repeated and
      # trailing separators are folded away so `-I/usr/include/` matches
      # `/usr/include`, while symlinks are deliberately left unresolved (a
      # .pc's prefix is frequently a symlink, and resolving it would make the
      # output depend on the state of the filesystem).
      def normalize(dir)
        folded = dir.gsub(%r{/{2,}}, "/")
        folded.length > 1 ? folded.sub(%r{/\z}, "") : folded
      end
    end
  end
end
