#!/usr/bin/env ruby
# frozen_string_literal: true

# Audits rubycc's bundled libc headers (include/libc/**) against the glibc
# headers of the same name, for both targets (x86-64 on this host's gcc,
# aarch64 on aarch64-linux-gnu-gcc's cross sysroot).
#
# For each bundled header H and each arch it measures, rather than reads:
#
#   * which names (macros, functions, variables, typedefs, struct/union/enum
#     tags and enumerators) glibc's <H> makes visible under _GNU_SOURCE, split
#     into the ones <H> itself owns and the ones it gets from another public
#     header it pulls in (glibc's <stdlib.h> pulls in <alloca.h> and
#     <sys/types.h>, for example);
#   * which names rubycc's bundled <H> makes visible, preprocessed in the
#     hermetic search order (bundled headers only) so nothing from the host
#     libc leaks in;
#   * the difference in both directions, with each glibc-only name tagged by
#     the lowest feature-test level that exposes it (ISO C, POSIX, X/Open,
#     gcc's default _DEFAULT_SOURCE, or only _GNU_SOURCE);
#   * the glibc-shared type guards (__have_*, __*_defined) glibc's <H> sets,
#     and whether the bundled <H> sets the same guard -- the shape of GAPS AU,
#     where a bundled header defined a type glibc guards and a later glibc
#     header redefined it. An unguarded type is probed for an actual clash by
#     compiling "bundled <H>, then the glibc file that owns the guard" (and the
#     reverse order) with rubycc.
#
# The glibc side is measured with the reference compiler's own preprocessor
# (`gcc -E -dD`): #define lines carry the macros, linemarkers carry which file
# -- and through the include stack, which public header -- each name came from,
# and the declarations are read out of the preprocessed text by a small
# declarator scanner (#declared_names). The bundled side goes through the very
# same scanner, so a mistake in it shows up on both sides alike rather than as
# a phantom difference. No glibc header text is copied anywhere: what this tool
# produces is a list of names and where they are visible (R11,
# docs/reference/HEADER-LICENSING.md section 6).
#
# A bundled header states the glibc names it leaves out on purpose in its top
# comment, as "omitted: NAME NAME ... -- reason" (a NAME may end in `*` to
# cover a family). The report marks every missing name so covered, and lists
# the ones no such line covers as undocumented.
#
# Usage:
#   ruby tools/audit_bundled_headers.rb [--arch x86_64|aarch64]... [--header stdlib.h]...
#                                       [--no-guard-probe] [--output FILE]
# With no --header it audits every bundled libc header; with no --arch, every
# arch whose compiler is installed. The Markdown report goes to stdout or FILE.

require "open3"
require "optparse"
require "set"
require "tmpdir"

module AuditBundledHeaders
  ROOT = File.expand_path("..", __dir__)
  INCLUDE_DIR = File.join(ROOT, "include")
  LIBC_DIR = File.join(INCLUDE_DIR, "libc")

  # The compiler that is the glibc oracle for each arch.
  COMPILERS = { "x86_64" => "gcc", "aarch64" => "aarch64-linux-gnu-gcc" }.freeze

  # Feature-test levels, lowest first. A glibc-only name is reported under the
  # first level whose preprocessed <H> makes it visible. "default" is what a
  # plain gcc invocation gets (gnu17 turns on _DEFAULT_SOURCE, i.e. __USE_MISC);
  # "gnu" is what a Ruby extension always gets (ruby/config.h defines
  # _GNU_SOURCE), and is the level the comparison itself runs at.
  LEVELS = [
    ["iso", %w[-std=c11]],
    ["posix", %w[-std=c11 -D_POSIX_C_SOURCE=200809L]],
    ["xopen", %w[-std=c11 -D_XOPEN_SOURCE=700]],
    ["default", %w[-std=gnu17]],
    ["gnu", %w[-std=gnu17 -D_GNU_SOURCE]]
  ].freeze
  COMPARE_LEVEL = "gnu"

  # Path prefixes (relative to a search directory) of headers that are glibc's
  # or the kernel's internal plumbing rather than something a program includes
  # by name. A name defined in one of these belongs to the nearest public header
  # up the include stack.
  INTERNAL_PREFIXES = %w[bits/ gnu/ asm/ asm-generic/ linux/].freeze

  # Headers whose names are configuration plumbing on both sides (feature-test
  # results, __THROW and friends): not counted for any other header. Each is
  # still audited when it is itself the header under test.
  PLUMBING = %w[features.h features-time64.h stdc-predef.h sys/cdefs.h].freeze

  # The guard spellings glibc shares between its own headers so a type defined
  # in two places is defined once.
  GUARD = /\A(?:__have_\w+|_+\w+_defined)\z/

  C_KEYWORDS = Set.new(%w[
    auto break case char const continue default do double else enum extern float
    for goto if inline int long register restrict return short signed sizeof
    static struct switch typedef union unsigned void volatile while _Alignas
    _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn
    _Static_assert _Thread_local __const __const__ __inline __inline__
    __restrict __restrict__ __signed __signed__ __volatile __volatile__
    __extension__ __builtin_va_list __int128 __thread _Float16 _Float32 _Float64
    _Float128 _Float32x _Float64x _Float128x __float128 __ibm128 __bf16
  ]).freeze

  # Keywords followed by a parenthesized operand that is not a declarator.
  GROUP_KEYWORDS = Set.new(%w[
    __attribute__ __attribute __asm__ __asm asm __declspec __typeof__ __typeof
    typeof _Alignas __alignof__ _Atomic
  ]).freeze

  OPENERS = ["(", "[", "{"].freeze
  CLOSERS = [")", "]", "}"].freeze

  TOKEN = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_]\w*|\d[\w.]*|\.\.\.|->|\S/

  # One name visible in a preprocessed translation unit.
  #   kinds : the Set of kinds it was seen as (:macro, :function, :variable,
  #           :typedef, :tag, :enumerator)
  #   owner : the public header it belongs to (angle-bracket spelling), or
  #           :plumbing / :builtin
  #   file  : the physical file it was defined in
  Entry = Struct.new(:kinds, :owner, :file)

  # What one preprocessed translation unit makes visible.
  #   names  : name => Entry ("struct foo" for tags)
  #   pulled : public headers (angle spelling) other than the one under test
  #            that the unit read
  Scan = Struct.new(:names, :pulled)

  # One header on one arch.
  Result = Struct.new(:header, :arch, :error, :glibc_own, :missing, :undocumented, :extras,
                      :missing_pulls, :reserved_missing, :guards, keyword_init: true)

  # A glibc guard glibc's <H> sets and what the bundled <H> does about it.
  #   status : :honoured (the bundled unit sets the same guard), :absent (the
  #            bundled unit declares none of the guarded names), or :unguarded
  #   probe  : for :unguarded, the result of compiling both include orders
  #            with rubycc ({order => "ok" | first error line}), when run
  Guard = Struct.new(:name, :file, :guarded, :status, :probe, keyword_init: true)

  module_function

  def available_arches
    COMPILERS.select { |_, cc| system("command -v #{cc} >/dev/null 2>&1") }.keys
  end

  # Every bundled libc header visible on `arch`, as angle-bracket spellings
  # mapped to their file (the arch layer shadows the common layer, exactly as
  # rubycc's search order does).
  def bundled_headers(arch)
    map = {}
    Dir.glob(File.join(LIBC_DIR, "**", "*.h")).each do |path|
      rel = path.delete_prefix("#{LIBC_DIR}/")
      next if rel.start_with?("glibc/")

      map[rel] = path
    end
    arch_dir = File.join(LIBC_DIR, "glibc", arch)
    Dir.glob(File.join(arch_dir, "**", "*.h")).each do |path|
      map[path.delete_prefix("#{arch_dir}/")] = path
    end
    map.sort.to_h
  end

  # The compiler's own <...> search directories, longest first so a path is
  # matched against the most specific one.
  def search_dirs(compiler, extra_args = [])
    _, err, = Open3.capture3(compiler, *extra_args, "-E", "-v", "-x", "c", "/dev/null", "-o", "/dev/null")
    lines = err.lines.map(&:strip)
    start = lines.index { |l| l.start_with?("#include <...> search starts here") }
    stop = lines.index("End of search list.")
    return [] unless start && stop

    lines[(start + 1)...stop].map { |d| File.expand_path(d) }.sort_by { |d| -d.length }
  end

  def bundled_search_args(arch)
    [INCLUDE_DIR, File.join(LIBC_DIR, "glibc", arch), LIBC_DIR].flat_map { |d| ["-isystem", d] }
  end

  # Preprocesses `#include <header>` with `compiler` and `args`; returns the
  # text or raises with gcc's diagnostics.
  def preprocess(compiler, header, args)
    Dir.mktmpdir("audit-headers") do |dir|
      probe = File.join(dir, "probe.c")
      File.write(probe, "#include <#{header}>\n")
      out, err, status = Open3.capture3(compiler, "-E", "-dD", *args, probe)
      raise "#{compiler} -E <#{header}> failed: #{err.lines.first(3).join.strip}" unless status.success?

      out
    end
  end

  # Reads a `gcc -E -dD` output into a Scan. `dirs` are the search directories
  # that turn a physical path into an angle-bracket spelling.
  def scan(text, header, dirs)
    names = {}
    pulled = Set.new
    stack = []
    tokens = []
    rel_of = {}
    relative = lambda do |file|
      rel_of[file] ||= begin
        dir = dirs.find { |d| file.start_with?("#{d}/") }
        dir ? file.delete_prefix("#{dir}/") : nil
      end
    end
    owner_of = lambda do
      stack.reverse_each do |file|
        return :builtin if file.start_with?("<") || file.end_with?("probe.c")

        rel = relative.call(file)
        next if rel.nil? || INTERNAL_PREFIXES.any? { |p| rel.start_with?(p) }
        return :plumbing if PLUMBING.include?(rel) && rel != header

        return rel
      end
      :builtin
    end

    text.each_line do |line|
      if (m = line.match(/\A# \d+ "([^"]*)"((?: \d)*)/))
        file = m[1]
        flags = m[2].split.map(&:to_i)
        if flags.include?(1)
          stack.push(file)
        elsif flags.include?(2)
          stack.pop while !stack.empty? && stack.last != file
        elsif stack.empty?
          stack.push(file)
        else
          stack[-1] = file
        end
        owner = owner_of.call
        pulled << owner if owner.is_a?(String) && owner != header
      elsif (m = line.match(/\A#define ([A-Za-z_]\w*)/))
        entry = (names[m[1]] ||= Entry.new(Set.new, owner_of.call, stack.last))
        entry.kinds << :macro
      elsif (m = line.match(/\A#undef ([A-Za-z_]\w*)/))
        entry = names[m[1]]
        if entry
          entry.kinds.delete(:macro)
          names.delete(m[1]) if entry.kinds.empty?
        end
      elsif !line.start_with?("#")
        owner = owner_of.call
        file = stack.last
        line.scan(TOKEN) { |t| tokens << [t, owner, file] }
      end
    end

    declared_names(tokens).each do |(name, kind, owner, file)|
      entry = (names[name] ||= Entry.new(Set.new, owner, file))
      entry.kinds << kind
    end
    names.reject! { |_, e| e.owner == :builtin }
    Scan.new(names, pulled)
  end

  # The file-scope names the preprocessed `tokens` ([text, owner, file]
  # triples) declare, as [name, kind, owner, file] quadruples.
  def declared_names(tokens)
    tokens = strip_groups(tokens)
    found = []
    split_declarations(tokens).each do |decl|
      next if decl.empty?
      next if %w[_Static_assert static_assert].include?(decl.first[0])

      owner = decl.first[1]
      file = decl.first[2]
      collect_tags(decl) { |name, kind| found << [name, kind, owner, file] }
      flat = collapse_braces(decl)
      typedef = flat.any? { |t| t[0] == "typedef" }
      split_top(flat, ",").each do |chunk|
        chunk = chunk.take_while { |t| t[0] != "=" }
        name, function = declarator_name(chunk)
        next if name.nil?

        kind = if typedef then :typedef
               elsif function then :function
               else :variable
               end
        found << [name, kind, owner, file]
      end
    end
    found
  end

  # Drops __attribute__((...)), __asm__(...), __extension__ and kin, which
  # carry no names and would otherwise read as declarators.
  def strip_groups(tokens)
    out = []
    i = 0
    while i < tokens.length
      t = tokens[i][0]
      if %w[__attribute__ __attribute __asm__ __asm asm __declspec].include?(t) && tokens[i + 1]&.first == "("
        i = matching(tokens, i + 1) + 1
      elsif %w[__extension__ __inline __inline__ inline].include?(t)
        i += 1
      else
        out << tokens[i]
        i += 1
      end
    end
    out
  end

  # Index of the token closing the bracket opened at `open`.
  def matching(tokens, open)
    pairs = { "(" => ")", "[" => "]", "{" => "}" }
    opener = tokens[open][0]
    closer = pairs.fetch(opener)
    depth = 0
    (open...tokens.length).each do |i|
      depth += 1 if tokens[i][0] == opener
      depth -= 1 if tokens[i][0] == closer
      return i if depth.zero?
    end
    tokens.length - 1
  end

  # Splits the unit into file-scope declarations: at a `;` outside every
  # bracket, and after the closing brace of a function body (a `{` whose
  # previous token is `)`), whose contents are dropped.
  def split_declarations(tokens)
    decls = []
    current = []
    depth = 0
    i = 0
    while i < tokens.length
      t = tokens[i][0]
      if depth.zero? && t == "{" && current.last&.first == ")"
        i = matching(tokens, i) + 1
        decls << current
        current = []
        next
      end
      depth += 1 if OPENERS.include?(t)
      depth -= 1 if CLOSERS.include?(t)
      if depth.zero? && t == ";"
        decls << current
        current = []
      else
        current << tokens[i]
      end
      i += 1
    end
    decls << current unless current.empty?
    decls
  end

  # Yields every tag a declaration defines (with a body) and every enumerator.
  def collect_tags(decl)
    decl.each_with_index do |(t, _), i|
      next unless %w[struct union enum].include?(t)

      name = decl[i + 1]
      brace = name && name[0] == "{" ? i + 1 : i + 2
      next unless decl[brace] && decl[brace][0] == "{"

      yield "#{t} #{name[0]}", :tag if name[0] != "{"
      next unless t == "enum"

      body = decl[(brace + 1)...matching(decl, brace)]
      split_top(body, ",").each do |item|
        yield item.first[0], :enumerator if item.first && item.first[0].match?(/\A[A-Za-z_]\w*\z/)
      end
    end
  end

  # Replaces every {...} group with a single "{}" token.
  def collapse_braces(decl)
    out = []
    i = 0
    while i < decl.length
      if decl[i][0] == "{"
        out << ["{}", decl[i][1], decl[i][2]]
        i = matching(decl, i) + 1
      else
        out << decl[i]
        i += 1
      end
    end
    out
  end

  # Splits `tokens` at `sep` outside every bracket.
  def split_top(tokens, sep)
    parts = [[]]
    depth = 0
    tokens.each do |tok|
      t = tok[0]
      depth += 1 if OPENERS.include?(t)
      depth -= 1 if CLOSERS.include?(t)
      if depth.zero? && t == sep
        parts << []
      else
        parts.last << tok
      end
    end
    parts.reject(&:empty?)
  end

  # The identifier a declarator declares, and whether it declares a function
  # (the name is followed directly by a parameter list). A parenthesized group
  # that starts with `*` is a nested declarator (a pointer to function); any
  # other group after the name is its parameter list.
  def declarator_name(chunk)
    last = nil
    i = 0
    while i < chunk.length
      t = chunk[i][0]
      if GROUP_KEYWORDS.include?(t) && chunk[i + 1]&.first == "("
        i = matching(chunk, i + 1) + 1
        next
      end
      if %w[struct union enum].include?(t)
        i += 2
        next
      end
      if t == "("
        close = matching(chunk, i)
        inner = chunk[(i + 1)...close]
        return declarator_name(inner) if inner.first && %w[* ^].include?(inner.first[0])
        return [last, true] if last

        i = close + 1
        next
      end
      return [last, false] if t == "[" && last

      last = t if t.match?(/\A[A-Za-z_]\w*\z/) && !C_KEYWORDS.include?(t)
      i += 1
    end
    [last, false]
  end

  # A name in the underscore space the standards reserve to the implementation,
  # but which a *program* is meant to write in its own source, and which
  # therefore belongs in the diff like any other public name. The test applied
  # here is exactly that -- "does a program spell this name?" -- not "who owns
  # the spelling":
  #
  #   * the option and limit constants POSIX and X/Open define for a program to
  #     test with #if or pass along (_POSIX_*, _POSIX2_*, _XOPEN_*, _XBS5_*,
  #     _LFS_*, _LFS64_*); _POSIX_VDISABLE, which ruby-termios 1.1.0 writes, is
  #     one of these;
  #   * the query arguments of sysconf/confstr/pathconf (_SC_*, _CS_*, _PC_*)
  #     and of nl_langinfo (_NL_*, _DATE_FMT);
  #   * the ioctl request constructors <asm-generic/ioctl.h> publishes (_IO,
  #     _IOR, _IOW, _IOWR, their _BAD variants, and the _IOC_* fields they are
  #     assembled from), which a driver-facing extension writes to name a
  #     request the libc headers do not;
  #   * the functions a standard itself spells with a leading underscore
  #     (_Exit; POSIX.1-2024's _Fork).
  #
  # Everything else in the space is the implementation talking to itself and
  # stays out of the diff: every __-prefixed name; include and type guards
  # (_STDLIB_H, _BITS_*, __have_*, _*_defined, rubycc's own _RUBYCC_*); the
  # feature-test macros a program *defines* rather than reads (_POSIX_SOURCE,
  # _POSIX_C_SOURCE, _XOPEN_SOURCE, _XOPEN_SOURCE_EXTENDED and kin, all of
  # which carry _SOURCE as a word); glibc's reports about its own layout
  # (_HAVE_STRUCT_*, _STATBUF_ST_*, _DIRENT_HAVE_*, _UTSNAME_*_LENGTH, and the
  # _IO_* innards of <stdio.h>); and the names a public macro merely expands
  # to (_REG_* behind REG_*, _ElfW behind ElfW). None of those can appear in a
  # gem's source, so a bundled header not having one is not a gap.
  # (audit-reserved-public-macros-1)
  PUBLIC_RESERVED_PREFIXES = %w[_POSIX_ _POSIX2_ _XOPEN_ _XBS5_ _LFS_ _LFS64_
                                _SC_ _CS_ _PC_ _NL_ _IOC_].freeze
  PUBLIC_RESERVED_NAMES = Set.new(%w[_Exit _Fork _DATE_FMT
                                     _IO _IOC _IOR _IOW _IOWR
                                     _IOR_BAD _IOW_BAD _IOWR_BAD]).freeze

  # A feature-test macro (_XOPEN_SOURCE, _POSIX_C_SOURCE, ...) or an include
  # guard (_XOPEN_LIM_H), which share the public families' prefixes but are
  # written by the program's build and by glibc's own files respectively.
  FEATURE_TEST_OR_GUARD = /_SOURCE(?:_|\z)|_H_*\z/

  def public_reserved?(name)
    return false if name.match?(FEATURE_TEST_OR_GUARD)

    PUBLIC_RESERVED_NAMES.include?(name) ||
      PUBLIC_RESERVED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
  end

  # True for a name that is the implementation's alone, and so is not counted
  # as missing when a bundled header lacks it. See #public_reserved? for the
  # line between the two halves of the reserved space.
  def reserved?(name)
    stem = name.sub(/\A(?:struct|union|enum) /, "")
    stem.match?(/\A_[A-Z_]/) && !public_reserved?(stem)
  end

  # The "omitted: NAME ... -- reason" lines of a bundled header's first
  # comment, as an Array of [pattern, reason] pairs.
  def omitted_patterns(path)
    comment = File.read(path)[%r{/\*.*?\*/}m].to_s
    comment.scan(/omitted:\s*(.*?)\s+--\s+(.*?)(?:\.\s|\.?\z|;\s)/m).flat_map do |(names, reason)|
      # Drop a " * " continuation marker at the start of a comment line, but
      # not the `*` a family pattern (CPU_*) ends in.
      words = names.gsub(/^\s*\*(?=\s)/, "").split(/[\s,]+/).reject(&:empty?)
      joined = []
      words.each do |w|
        if %w[struct union enum].include?(joined.last)
          joined[-1] = "#{joined.last} #{w}"
        else
          joined << w
        end
      end
      joined.map { |n| [n, reason.gsub(/\s+/, " ")] }
    end
  end

  def covered?(name, patterns)
    patterns.any? do |(pattern, _)|
      if pattern.include?("*")
        File.fnmatch(pattern, name)
      else
        pattern == name
      end
    end
  end

  # Audits `header` on `arch`. `guard_probe` also compiles the unguarded-type
  # clash probes with rubycc (x86-64 only; see #probe_guard).
  def audit(header, arch, guard_probe: true, bundled_path: nil)
    compiler = COMPILERS.fetch(arch)
    bundled_path ||= bundled_headers(arch).fetch(header)
    glibc_dirs = search_dirs(compiler)
    bundled_dirs = [INCLUDE_DIR, File.join(LIBC_DIR, "glibc", arch), LIBC_DIR].sort_by { |d| -d.length }

    levels = {}
    LEVELS.each do |(level, args)|
      levels[level] = scan(preprocess(compiler, header, args), header, glibc_dirs)
    end
    glibc = levels.fetch(COMPARE_LEVEL)
    bundled = scan(preprocess(compiler, header, [*LEVELS.last[1], "-nostdinc", *bundled_search_args(arch)]),
                   header, bundled_dirs)

    own = glibc.names.select { |_, e| e.owner == header }
    patterns = omitted_patterns(bundled_path)
    missing = {}
    reserved_missing = []
    own.each do |name, entry|
      next if bundled.names.key?(name)

      if reserved?(name)
        reserved_missing << name unless (entry.kinds & Set[:typedef, :tag]).empty?
        next
      end
      level = LEVELS.map(&:first).find { |l| levels[l].names.key?(name) } || COMPARE_LEVEL
      missing[name] = level
    end
    missing_pulls = (glibc.pulled - bundled.pulled - PLUMBING).to_a.sort
    # A pulled-in header is documented as "omitted: <sys/types.h> -- ...".
    undocumented = missing.keys.reject { |n| covered?(n, patterns) } +
                   missing_pulls.map { |p| "<#{p}>" }.reject { |p| covered?(p, patterns) }
    extras = bundled.names.select { |n, e| e.owner == header && !reserved?(n) && !glibc.names.key?(n) }.keys

    Result.new(header: header, arch: arch, glibc_own: own.keys.reject { |n| reserved?(n) }.sort,
               missing: missing.sort.to_h, undocumented: undocumented.sort, extras: extras.sort,
               missing_pulls: missing_pulls,
               reserved_missing: reserved_missing.sort,
               guards: guards(header, arch, glibc, bundled, guard_probe && arch == "x86_64"))
  rescue StandardError => e
    Result.new(header: header, arch: arch, error: e.message.lines.first.to_s.strip)
  end

  def guards(header, arch, glibc, bundled, probe)
    glibc.names.select { |n, e| n.match?(GUARD) && e.owner == header && e.kinds.include?(:macro) }.map do |name, entry|
      stem = name.sub(/\A__have_/, "").sub(/\A_+/, "").sub(/_defined\z/, "")
      candidates = [stem, "__#{stem}", "struct #{stem}", "union #{stem}",
                    "struct #{stem.sub(/\Astruct_/, "")}", stem.sub(/\A__/, "")]
      in_file = glibc.names.select { |n, e| e.file == entry.file && !n.match?(GUARD) && e.kinds != Set[:macro] }.keys
      guarded = in_file & candidates
      guarded = in_file.first(4) if guarded.empty?
      internal = INTERNAL_PREFIXES.any? { |p| entry.file.include?("/#{p}") }
      status = if bundled.names.key?(name) then :honoured
               elsif guarded.none? { |n| bundled.names.key?(n) } then :absent
               elsif !internal then :self
               else :unguarded
               end
      result = Guard.new(name: name, file: entry.file, guarded: guarded, status: status)
      # Only a guard in an internal file (bits/types/time_t.h and kin) can be
      # reached by some *other* glibc header that shares a unit with the
      # bundled <H>; a guard glibc's <H> sets in its own text (status :self)
      # would need glibc's <H> and the bundled <H> in one unit, which the
      # search order never produces. An honoured guard is probed too: setting
      # it makes glibc skip the whole guarded file, including whatever that
      # file would have brought in for the partner header (the bundled
      # <signal.h> honouring glibc's siginfo_t guard left <sys/pidfd.h>
      # without __pid_t until <signal.h> supplied it).
      result.probe = probe_guard(header, entry.file, arch) if probe && internal && %i[unguarded honoured].include?(status)
      result
    end.sort_by(&:name)
  end

  # How many unbundled glibc headers #probe_guard pairs a guard's header with.
  PROBE_REACHERS = 3

  # {unbundled glibc header => Set of the files it reads under _GNU_SOURCE},
  # from `gcc -M` (the reference compiler's own dependency list), computed once
  # per arch.
  def glibc_dependencies(arch)
    @glibc_dependencies ||= {}
    @glibc_dependencies[arch] ||= unbundled_glibc_headers(arch).to_h do |header|
      Dir.mktmpdir("audit-deps") do |dir|
        probe = File.join(dir, "probe.c")
        File.write(probe, "#include <#{header}>\n")
        out, status = Open3.capture2e(COMPILERS.fetch(arch), "-M", "-std=gnu17", "-D_GNU_SOURCE", probe)
        files = status.success? ? out.gsub("\\\n", " ").split.drop(2).map { |f| File.expand_path(f) } : []
        [header, Set.new(files)]
      end
    end
  end

  # Probes an unguarded guard the way a program meets it: the bundled <header>
  # next to a glibc public header rubycc does not bundle that reads the file
  # owning the guard (GAPS BL: <signal.h> next to <netdb.h>, which reaches
  # bits/types/__sigval_t.h under __USE_GNU), in both orders, compiled with
  # rubycc under _GNU_SOURCE. Up to PROBE_REACHERS such headers are tried,
  # shortest names first. When no unbundled glibc header reads the file, the
  # file itself is included instead ("direct"), which shows whether the two
  # definitions agree even though no real header pairs them. x86-64 only:
  # `rubycc -target aarch64` on an x86-64 host cannot read the cross
  # sysroot's own headers (GAPS BI).
  def probe_guard(header, glibc_file, arch)
    require_relative "../lib/rubycc"
    reachers = glibc_dependencies(arch).select { |_, deps| deps.include?(glibc_file) }.keys
                                       .sort_by { |h| [h.length, h] }.first(PROBE_REACHERS)
    partners = reachers.empty? ? { "direct" => "\"#{glibc_file}\"" } : reachers.to_h { |h| ["<#{h}>", "<#{h}>"] }
    body = {}
    partners.each do |label, spelling|
      body["<#{header}>, #{label}"] = "#include <#{header}>\n#include #{spelling}\n"
      body["#{label}, <#{header}>"] = "#include #{spelling}\n#include <#{header}>\n"
    end
    body.transform_values do |includes|
      source = "#define _GNU_SOURCE 1\n#{includes}int audit_probe;\n"
      next "n/a (gcc rejects this unit too)" unless gcc_accepts?(source, arch)

      Rubycc::Compiler.new.compile(source, filename: "probe.c", target: arch, libc: "glibc")
      "ok"
    rescue StandardError => e
      e.message.lines.first.to_s.strip.sub(%r{\A.*/include/}, "")
    end
  end

  # Whether the oracle compiles `source` against glibc's own headers -- a
  # probe that includes a glibc file glibc forbids including directly
  # (bits/socket.h) fails there too and says nothing about rubycc.
  def gcc_accepts?(source, arch)
    Dir.mktmpdir("audit-probe") do |dir|
      probe = File.join(dir, "probe.c")
      File.write(probe, source)
      _, status = Open3.capture2e(COMPILERS.fetch(arch), "-std=gnu17", "-fsyntax-only", probe)
      status.success?
    end
  end

  # ---- mixing survey --------------------------------------------------------

  # glibc's own public headers that rubycc does not bundle, so a compile reads
  # them from the host next to the bundled ones: libc6-dev's file list minus
  # the internal directories and minus every bundled spelling. Empty when the
  # package database is not there to ask.
  def unbundled_glibc_headers(arch)
    out, status = Open3.capture2e("dpkg", "-L", "libc6-dev")
    return [] unless status.success?

    dirs = search_dirs(COMPILERS.fetch(arch))
    bundled = bundled_headers(arch).keys
    out.lines.map(&:strip).grep(%r{\A/usr/include/.*\.h\z}).filter_map do |path|
      dir = dirs.find { |d| path.start_with?("#{d}/") }
      rel = dir && path.delete_prefix("#{dir}/")
      next if rel.nil? || INTERNAL_PREFIXES.any? { |p| rel.start_with?(p) }
      next if bundled.include?(rel) || PLUMBING.include?(rel)

      rel
    end.uniq.sort
  end

  # Compiles "#define _GNU_SOURCE / #include <X>" for each unbundled glibc
  # header X, with gcc and with rubycc (default search order: bundled headers
  # first, host glibc after), and returns {X => first rubycc error} for the
  # ones gcc accepts and rubycc does not. This is where a bundled header's gap
  # shows up as a *glibc* header failing (GAPS AM: <spawn.h> needing
  # struct sched_param; AQ: <net/if.h> needing __caddr_t). x86-64 only, for
  # the reason #probe_guard gives.
  def mixing_survey(arch = "x86_64")
    require_relative "../lib/rubycc"
    headers = unbundled_glibc_headers(arch)
    failures = {}
    headers.each do |header|
      source = "#define _GNU_SOURCE 1\n#include <#{header}>\nint audit_probe;\n"
      Dir.mktmpdir("audit-mixing") do |dir|
        probe = File.join(dir, "probe.c")
        File.write(probe, source)
        _, status = Open3.capture2e(COMPILERS.fetch(arch), "-std=gnu17", "-fsyntax-only", probe)
        next unless status.success?

        begin
          Rubycc::Compiler.new.compile(source, filename: "probe.c", target: arch, libc: "glibc")
        rescue StandardError => e
          failures[header] = e.message.lines.first.to_s.strip.sub(%r{\A/usr/include/(?:x86_64-linux-gnu/)?}, "")
        end
      end
    end
    [headers.size, failures]
  end

  # ---- report -------------------------------------------------------------

  def compiler_version(compiler)
    out, = Open3.capture2e(compiler, "--version")
    out.lines.first.to_s.strip
  end

  def glibc_version(compiler)
    out, = Open3.capture2e(compiler, "-E", "-dM", "-x", "c", "-include", "features.h", "/dev/null")
    major = out[/#define __GLIBC__ (\d+)/, 1]
    minor = out[/#define __GLIBC_MINOR__ (\d+)/, 1]
    major && minor ? "#{major}.#{minor}" : "unknown"
  end

  def code_list(names)
    names.empty? ? "—" : names.map { |n| "`#{n}`" }.join(" ")
  end

  def markdown(results_by_header, arches, date, mixing = nil)
    out = []
    out << "# 同梱 libc ヘッダの網羅度監査(glibc の同名ヘッダとの突き合わせ)"
    out << ""
    out << "> **Generated artifact.** `ruby tools/audit_bundled_headers.rb --output " \
           "docs/development/BUNDLED-HEADERS-COVERAGE.md` で再生成する。手で編集しない。"
    out << ""
    out << "測定日: #{date}。オラクル:"
    arches.each do |arch|
      cc = COMPILERS.fetch(arch)
      out << "- #{arch}: `#{cc}`(#{compiler_version(cc)}、glibc #{glibc_version(cc)})"
    end
    out << ""
    out << "## 読み方"
    out << ""
    out << "- **glibc 側**は `<H>` だけを含む翻訳単位を `gcc -E -dD -std=gnu17 -D_GNU_SOURCE` で前処理し、" \
           "`#define` と宣言から名前を拾う。linemarker の include スタックで、各名前を**最も内側の公開ヘッダ**に帰属させる" \
           "(`bits/`・`gnu/`・`asm/`・`asm-generic/`・`linux/` は内部とみなし、その外側の公開ヘッダに帰属する)。" \
           "`<H>` 自身に帰属する名前が「glibc の `<H>` の名前」である。"
    out << "- **同梱側**は同じコンパイラで `-nostdinc` と rubycc の同梱の探索順(`include/`、" \
           "`include/libc/glibc/<arch>/`、`include/libc/`)で前処理する(hermetic と同じ。ホストのヘッダは混ざらない)。" \
           "同梱の `<H>` から見える名前はすべて数える(同梱の別ヘッダ経由でも見えれば足りている)。"
    out << "- **不足**は glibc の `<H>` の名前のうち、同梱の `<H>` から見えないもの。" \
           "`_` + 大文字 / `__` で始まる**予約名**は、処理系が自分のために使う綴り(インクルードガード・`__have_*` などの型ガード・" \
           "プログラムが**書く**側の feature-test マクロ・glibc が自分のレイアウトを報告するマクロ・公開マクロの展開先)は除き、" \
           "**規格が予約領域の綴りをプログラムに使わせているもの**は数える(`_POSIX_*`・`_POSIX2_*`・`_XOPEN_*`・`_XBS5_*`・`_LFS*`・" \
           "`_SC_*`・`_CS_*`・`_PC_*`・`_NL_*`・ioctl の `_IO*`・`_Exit`/`_Fork`。線引きは `tools/audit_bundled_headers.rb` の " \
           "`#public_reserved?`)。括弧の中は、その名前を最初に見せる feature-test の段階: `iso`(`-std=c11`)・`posix`(`_POSIX_C_SOURCE=200809L`)・" \
           "`xopen`(`_XOPEN_SOURCE=700`)・`default`(gcc の既定 = `_DEFAULT_SOURCE` = `__USE_MISC`)・`gnu`(`_GNU_SOURCE` でだけ)。"
    out << "- **未記載**は、不足のうち同梱ヘッダの冒頭コメントの `omitted: 名前 ... -- 理由` で意図して外したと書かれていないもの。"
    out << "- **取り込み不足**は、glibc の `<H>` が含む公開ヘッダのうち、同梱の `<H>` が含まないもの(その中の名前は上の不足に数えない)。"
    out << "- **予約名の型**は、glibc の `<H>` が定義する予約名の typedef / タグのうち同梱に無いもの(GAPS AQ の `__caddr_t` の形)。"
    out << "- **ガード**は、glibc の `<H>` が立てる共有ガード(`__have_*` / `__*_defined`)。`honoured` = 同梱も同じガードを立てる、" \
           "`absent` = 同梱はガード対象の型を定義しない(glibc 側が定義するので衝突しない)、`unguarded` = 同梱が型を定義するが" \
           "ガードを立てない(GAPS AU の形)。`unguarded` には、同梱の `<H>` とガードを持つ glibc のファイルを両方の順で含めて" \
           "rubycc(x86-64)でコンパイルした結果を添える。`self` = ガードが glibc の `<H>` 自身の本文にある" \
           "(glibc の `<H>` と同梱の `<H>` は同じ翻訳単位に並ばないので衝突しえず、probe しない)。"
    out << "- 段階 `iso` は `-std=c11` でも見える名前(= 条件なし)で、POSIX のヘッダでは「feature-test に関係なく見える」を意味する。"
    out << "- **余剰**は同梱の `<H>` が定義するが、glibc の `<H>` からは `_GNU_SOURCE` でも見えない名前。"
    out << ""
    out << "## 一覧"
    out << ""
    header_row = ["ヘッダ"]
    arches.each { |a| header_row += ["#{a} 不足", "#{a} 未記載"] }
    header_row += ["取り込み不足", "unguarded"]
    out << "| #{header_row.join(" | ")} |"
    out << "|#{header_row.map { "---" }.join("|")}|"
    results_by_header.each do |header, per_arch|
      row = ["[`#{header}`](##{anchor(header)})"]
      arches.each do |arch|
        r = per_arch[arch]
        if r.nil? then row += ["—", "—"]
        elsif r.error then row += ["error", "error"]
        else row += [r.missing.size.to_s, r.undocumented.size.to_s]
        end
      end
      pulls = per_arch.values.compact.reject(&:error).flat_map(&:missing_pulls).uniq
      unguarded = per_arch.values.compact.reject(&:error).flat_map { |r| r.guards.select { |g| g.status == :unguarded }.map(&:name) }.uniq
      row << (pulls.empty? ? "—" : pulls.map { |p| "`#{p}`" }.join(" "))
      row << (unguarded.empty? ? "—" : unguarded.size.to_s)
      out << "| #{row.join(" | ")} |"
    end
    out << ""
    out << "## ヘッダ別"
    results_by_header.each do |header, per_arch|
      out << ""
      out << "### #{header}"
      out << ""
      groups = per_arch.compact.group_by { |_, r| detail_key(r) }
      groups.each_value do |pairs|
        label = pairs.map(&:first).join(" / ")
        r = pairs.first[1]
        if r.error
          out << "- #{label}: **error** — #{r.error}"
          next
        end
        out << "**#{label}** — glibc の `<#{header}>` の公開名 #{r.glibc_own.size}、不足 #{r.missing.size}、未記載 #{r.undocumented.size}"
        out << ""
        by_level = r.missing.group_by { |_, level| level }
        LEVELS.map(&:first).each do |level|
          names = by_level.fetch(level, []).map(&:first)
          next if names.empty?

          marked = names.map { |n| r.undocumented.include?(n) ? "**`#{n}`**" : "`#{n}`" }
          out << "- 不足(#{level}): #{marked.join(" ")}"
        end
        out << "- 取り込み不足: #{code_list(r.missing_pulls)}" unless r.missing_pulls.empty?
        out << "- 予約名の型: #{code_list(r.reserved_missing)}" unless r.reserved_missing.empty?
        r.guards.each do |g|
          probe = g.probe ? "(#{g.probe.map { |k, v| "#{k}: #{v}" }.join("; ")})" : ""
          out << "- ガード `#{g.name}` → #{code_list(g.guarded)}: #{g.status}#{probe}"
        end
        out << "- 余剰: #{code_list(r.extras)}" unless r.extras.empty?
        out << "- 不足なし" if r.missing.empty? && r.missing_pulls.empty? && r.reserved_missing.empty? && r.guards.empty?
        out << ""
      end
      out.pop if out.last == ""
    end
    if mixing
      total, failures = mixing
      out << ""
      out << "## glibc 本体のヘッダとの混在(x86-64)"
      out << ""
      out << "`libc6-dev` の公開ヘッダのうち rubycc が同梱しない #{total} 本を、1 本ずつ `#define _GNU_SOURCE` のもとで含め、" \
             "gcc と rubycc(既定の探索順 = 同梱が先、ホストの glibc が後)でコンパイルした。gcc が通し rubycc が落ちたもの" \
             "#{failures.size} 本と、rubycc の最初のエラー。同梱ヘッダの抜けが **glibc 本体のヘッダの失敗**として現れる所" \
             "(GAPS AM の `<spawn.h>`、AQ の `<net/if.h>`)を拾うための一覧で、原因が同梱ヘッダでないもの(rubycc 本体の未対応)も混ざる。"
      out << ""
      if failures.empty?
        out << "(なし)"
      else
        out << "| ヘッダ | rubycc の最初のエラー |"
        out << "|---|---|"
        failures.sort.each { |h, err| out << "| `#{h}` | #{err.gsub("|", "\\|")} |" }
      end
    end
    out << ""
    out.join("\n")
  end

  # Two arches whose findings coincide are reported once.
  def detail_key(result)
    return [:error, result.error] if result.error

    [result.missing, result.undocumented, result.missing_pulls, result.reserved_missing,
     result.guards.map { |g| [g.name, g.status, g.guarded] }, result.extras]
  end

  def anchor(header)
    header.downcase.gsub(/[^a-z0-9 _-]/, "").tr(" ", "-")
  end

  def run(argv)
    options = { arches: [], headers: [], guard_probe: true, output: nil }
    OptionParser.new do |o|
      o.on("--arch ARCH", COMPILERS.keys) { |a| options[:arches] << a }
      o.on("--header H") { |h| options[:headers] << h }
      o.on("--no-guard-probe") { options[:guard_probe] = false }
      o.on("--output FILE") { |f| options[:output] = f }
      o.on("--no-mixing") { options[:mixing] = false }
    end.parse!(argv)
    arches = options[:arches].empty? ? available_arches : options[:arches]
    all = arches.flat_map { |a| bundled_headers(a).keys }.uniq.sort
    headers = options[:headers].empty? ? all : options[:headers]

    results = headers.to_h do |header|
      [header, arches.to_h { |arch| [arch, bundled_headers(arch).key?(header) ? audit(header, arch, guard_probe: options[:guard_probe]) : nil] }]
    end
    mixing = options[:mixing] != false && options[:headers].empty? && arches.include?("x86_64") ? mixing_survey : nil
    text = markdown(results, arches, Time.now.strftime("%Y-%m-%d"), mixing)
    if options[:output]
      File.write(options[:output], text)
    else
      puts text
    end
  end
end

AuditBundledHeaders.run(ARGV) if $PROGRAM_NAME == __FILE__
