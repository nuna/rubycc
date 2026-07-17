# frozen_string_literal: true

require_relative "compile_error"
require_relative "compiler"
require_relative "preprocess/preprocessor"
require_relative "link/errors"
require_relative "link/partial_linker"
require_relative "link/shared_linker"
require_relative "link/executable_linker"
require_relative "link/library_resolver"
require_relative "link/compat_runtime"

module Rubycc
  # The gcc-compatible command-line driver: it reads the same option and input
  # vocabulary a compiler driver is invoked with (`rubycc -c -fPIC -Iinc -o x.o
  # x.c`, `rubycc -shared -o x.so a.o b.o -Llib -lz`, `rubycc -o prog main.c
  # util.c`) and drives the existing compiler and linker components to satisfy
  # it. It owns no compilation or linking logic of its own — it classifies the
  # inputs, picks the output mode gcc's flag precedence dictates, and hands the
  # work to Compiler, SharedLinker, ExecutableLinker and LibraryResolver.
  #
  # Three modes are selected exactly as gcc selects them: `-c` compiles each
  # source to an object without linking; `-shared` links every input into a
  # shared object; the absence of a mode flag links into an executable. A
  # one-shot invocation (`-c` absent, a `.c` given) compiles each source in
  # memory and feeds the resulting object bytes straight to the linker, so no
  # intermediate `.o` is ever written to disk. `-E` runs the preprocessor only.
  #
  # Unknown options are handled the tolerant way a build driver must (R6): a
  # documented-but-unmodelled flag family (`-O*`, `-g*`, `-W*`, `-f*`, `-m*`,
  # `-std=…`, and friends) is accepted and ignored silently, and any other
  # `-`-prefixed token draws a warning and is ignored, so an environment-specific
  # flag mkmf passes never derails a build. A genuine mistake with a definite
  # meaning — a missing `-o` operand — is still an error.
  class Driver
    PROG = "rubycc"

    # Options that take a separate operand this driver does not act on. They are
    # recognized only so the operand is not mistaken for an input file; both the
    # option and its argument are skipped. (`-isystem` and friends are handled
    # separately, as header search directories.)
    ARG_CONSUMING_IGNORED = %w[-Xlinker -z -u -T -MF -MT -MQ -include -isysroot
                               -aux-info -Xassembler -Xpreprocessor].freeze

    # Bare flags accepted and ignored: linking/codegen switches whose effect this
    # minimal toolchain does not model but whose presence must not be an error.
    SILENT_IGNORE_EXACT = %w[-pipe -pthread -no-pie -pie -rdynamic -static -s
                             -nostdlib -nostartfiles -shared-libgcc -static-libgcc
                             -symbolic -fsyntax-only].freeze

    # A command-line usage error (a missing operand, an unsupported combination):
    # reported with the driver's "error:" prefix and a non-zero exit.
    class UsageError < StandardError; end

    class << self
      # Runs the driver for `argv` and returns the process exit status (0 on
      # success, 1 on any diagnosed failure). `stdout`/`stderr` are injectable so
      # a test can drive the driver in-process and capture its streams.
      def run(argv, stdout: $stdout, stderr: $stderr)
        new(argv, stdout: stdout, stderr: stderr).run
      end
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv
      @out = stdout
      @err = stderr
      @inputs = []          # [{ path:, kind: }] in command-line order
      @output = nil
      @mode_flag = nil      # :compile / :shared / :preprocess (nil => executable)
      @include_paths = []
      @defines = []         # ordered [:define, "NAME[=VAL]"] / [:undef, "NAME"]
      @libraries = []       # -l request strings, in order
      @lib_dirs = []        # -L directories, in order
      @pic = false
      @soname = nil
      @system_includes = true  # -nostdinc clears this
      @default_libs = true     # -nodefaultlibs clears this
    end

    def run
      return print_version if version_requested?

      parse
      dispatch
      0
    rescue UsageError => e
      @err.puts "#{PROG}: error: #{e.message}"
      1
    rescue CompileError => e
      # A compiler diagnostic already carries its gcc-style file:line:col header
      # and caret, so it is printed verbatim.
      @err.puts e.message
      1
    rescue Link::LinkError => e
      @err.puts "#{PROG}: error: #{e.message}"
      1
    rescue Errno::ENOENT => e
      @err.puts "#{PROG}: error: #{e.message}"
      1
    end

    private

    # --version / -v keep their existing meaning (print the version and exit),
    # taking precedence over any other argument.
    def version_requested?
      @argv.include?("--version") || @argv.include?("-v")
    end

    def print_version
      @out.puts "rubycc #{Rubycc::VERSION}"
      0
    end

    # --- argument parsing --------------------------------------------------

    def parse
      i = 0
      i = handle_arg(@argv[i], i) while i < @argv.length
    end

    # Dispatches one argument and returns the index of the next unconsumed one.
    # The separated ("-I dir") and joined ("-Idir") spellings of the path/macro/
    # library options are both accepted, matching gcc.
    def handle_arg(arg, i)
      case arg
      when "-c"                                  then @mode_flag = :compile; i + 1
      when "-shared"                             then @mode_flag = :shared;  i + 1
      when "-E"                                  then @mode_flag = :preprocess; i + 1
      when "-fPIC", "-fpic", "-fPIE", "-fpie"    then @pic = true; i + 1
      when "-nostdinc"                           then @system_includes = false; i + 1
      when "-nodefaultlibs"                       then @default_libs = false; i + 1
      when "-o"          then @output = value(arg, i); i + 2
      when "-I"          then @include_paths << value(arg, i); i + 2
      when /\A-I(.+)\z/m then @include_paths << Regexp.last_match(1); i + 1
      when "-isystem", "-iquote", "-idirafter"
        @include_paths << value(arg, i); i + 2
      when "-D"          then @defines << [:define, value(arg, i)]; i + 2
      when /\A-D(.+)\z/m then @defines << [:define, Regexp.last_match(1)]; i + 1
      when "-U"          then @defines << [:undef, value(arg, i)]; i + 2
      when /\A-U(.+)\z/m then @defines << [:undef, Regexp.last_match(1)]; i + 1
      when "-l"          then @libraries << value(arg, i); i + 2
      when /\A-l(.+)\z/m then @libraries << Regexp.last_match(1); i + 1
      when "-L"          then @lib_dirs << value(arg, i); i + 2
      when /\A-L(.+)\z/m then @lib_dirs << Regexp.last_match(1); i + 1
      when /\A-Wl,(.+)\z/m then parse_linker_options(Regexp.last_match(1)); i + 1
      when *ARG_CONSUMING_IGNORED
        @argv[i + 1].nil? ? i + 1 : i + 2
      else
        handle_other(arg, i)
      end
    end

    # A token matching none of the explicit options: an input file, a silently
    # accepted codegen/warning flag, or an unknown option (warned and dropped).
    def handle_other(arg, i)
      if !arg.start_with?("-")
        classify_input(arg)
      elsif silently_ignored?(arg)
        # Accepted with no effect (an optimization/debug/warning switch).
      else
        warning("unknown option '#{arg}' ignored")
      end
      i + 1
    end

    # Whether `arg` is a documented gcc flag family this toolchain does not model
    # but accepts without complaint: the optimization (`-O*`), debug (`-g*`),
    # warning (`-W*`) and code-generation (`-f*`) switches, the language-standard
    # selector (`-std=…`), and the fixed bare set above. A machine switch (`-m*`)
    # is deliberately excluded — it names a target capability this toolchain does
    # not honor, so it is warned about like any other unmodelled option.
    def silently_ignored?(arg)
      SILENT_IGNORE_EXACT.include?(arg) ||
        arg.match?(/\A-(?:O|g|W|f)/) || arg.start_with?("-std=")
    end

    # The operand of an option that takes a separate value, erroring with a
    # gcc-style message when it is missing.
    def value(name, i)
      operand = @argv[i + 1]
      raise UsageError, "missing #{value_kind(name)} after '#{name}'" if operand.nil?

      operand
    end

    def value_kind(name)
      case name
      when "-o" then "filename"
      when "-I", "-L", "-isystem", "-iquote", "-idirafter" then "directory"
      else "argument"
      end
    end

    # Interprets the comma-separated linker options in a `-Wl,` passthrough. Only
    # the ones with a driver-level effect are acted on: `-soname NAME` (in the
    # `-soname NAME`, `-soname=NAME` and `-h NAME` spellings) sets the shared
    # object's DT_SONAME. Options that carry a value we ignore (`-rpath` and kin)
    # skip that value so it is not read as a bare option; every other linker
    # option is silently ignored.
    def parse_linker_options(joined)
      tokens = joined.split(",")
      j = 0
      while j < tokens.length
        token = tokens[j]
        case token
        when "-soname", "--soname", "-h" then @soname = tokens[j + 1]; j += 2
        when /\A(?:-soname|--soname|-h)=(.+)\z/ then @soname = Regexp.last_match(1); j += 1
        when "-rpath", "-rpath-link", "--dynamic-linker", "--version-script" then j += 2
        else j += 1
        end
      end
    end

    # Classifies an input by extension into the role it plays: a `.c` source to
    # compile, a `.o`/`.obj` object or `.a` archive to link, a `.so[.N]` shared
    # library to depend on. Anything else is treated as a linker input object, as
    # gcc defaults an unrecognized suffix to.
    def classify_input(path)
      kind =
        case File.extname(path).downcase
        when ".c"          then :source
        when ".o", ".obj"  then :object
        when ".a"          then :archive
        else path.match?(/\.so(?:\.\d+)*\z/) ? :shared : :object
        end
      @inputs << { path: path, kind: kind }
    end

    # --- dispatch ----------------------------------------------------------

    def dispatch
      raise UsageError, "no input file" if @inputs.empty?

      case mode
      when :preprocess           then preprocess_only
      when :compile              then compile_only
      when :shared, :executable  then link
      end
    end

    # The output mode gcc's precedence selects: -E over -c over -shared, and an
    # executable when no mode flag is present.
    def mode
      @mode_flag || :executable
    end

    # --- compile-only (-c) -------------------------------------------------

    # Compiles each source to its own object. gcc rejects `-o` with `-c` when
    # more than one source is compiled (one `-o` cannot name several outputs);
    # with a single source `-o` names its object, otherwise the object is the
    # source's basename with a `.o` suffix, dropped into the current directory.
    def compile_only
      sources = @inputs.select { |input| input[:kind] == :source }
      warn_unused_link_inputs
      if @output && sources.length > 1
        raise UsageError, "cannot specify '-o' with '-c' and multiple compilations"
      end

      sources.each do |input|
        output = @output || default_object_name(input[:path])
        Compiler.compile_file(input[:path], output, include_paths: @include_paths,
                                                     pic: @pic, defines: @defines,
                                                     system_includes: @system_includes)
      end
    end

    # A `.o`/`.a`/`.so` passed alongside `-c` cannot contribute to a
    # compile-only run; gcc keeps it a warning rather than an error.
    def warn_unused_link_inputs
      @inputs.each do |input|
        next if input[:kind] == :source

        warning("#{input[:path]}: linker input file unused because linking not done")
      end
    end

    def default_object_name(path)
      base = File.basename(path)
      ext = File.extname(base)
      "#{ext.empty? ? base : base[0...-ext.length]}.o"
    end

    # --- link (-shared / executable) ---------------------------------------

    # Links every input into the requested output. Sources are compiled to object
    # bytes in memory and passed straight to the linker; objects and archives are
    # passed by path; a `.so` input becomes a dependency. The `-l`/`-L` requests
    # are resolved into further archive inputs (appended after the objects so the
    # lazy archive pull-in sees the objects' undefined symbols first) and the
    # dependency shared objects imports bind against. rubycc's compiler-support
    # runtime is appended last, after the user inputs and the resolved libraries,
    # so its members are pulled in lazily only when something ahead still leaves
    # one of their symbols undefined (the libgcc-style default link). The output
    # is made executable so it can be run in place, as gcc leaves its own output.
    def link
      output = @output || "a.out"
      link_inputs = []
      needed = []
      @inputs.each do |input|
        case input[:kind]
        when :source           then link_inputs << compile_source(input)
        when :object, :archive then link_inputs << input[:path]
        when :shared           then needed << input[:path]
        end
      end

      resolution = Link::LibraryResolver.resolve(@libraries, search_dirs: @lib_dirs)
      link_inputs.concat(resolution.inputs)
      needed.concat(resolution.needed)
      link_inputs << Link::CompatRuntime.archive_bytes if @default_libs

      if mode == :shared
        Link::SharedLinker.link_to(link_inputs, output, needed: needed, soname: @soname)
      else
        Link::ExecutableLinker.link_to(link_inputs, output, needed: needed)
      end
      File.chmod(0o755, output)
    end

    def compile_source(input)
      Compiler.new.compile(File.read(input[:path]), filename: input[:path],
                           include_paths: @include_paths, pic: @pic, defines: @defines,
                           system_includes: @system_includes)
    end

    # --- preprocess-only (-E) ----------------------------------------------

    # Runs the preprocessor over each source and writes the token stream to `-o`
    # (or standard output). The reconstruction is a best-effort re-spelling of the
    # preprocessing tokens — token spellings joined with a space where whitespace
    # separated them and a newline where the line advanced — rather than a
    # byte-faithful copy of gcc's `-E` output; it is enough for a probe that only
    # needs macros expanded and headers included. Non-source inputs are ignored.
    def preprocess_only
      text = +""
      @inputs.each do |input|
        next unless input[:kind] == :source

        tokens = Preprocess::Preprocessor.new.preprocess(
          File.read(input[:path]), filename: input[:path],
          include_paths: @include_paths, defines: @defines,
          system_includes: @system_includes
        )
        text << render_preprocessed(tokens.reject(&:eof?))
      end

      if @output
        File.write(@output, text)
      else
        @out.print(text)
      end
    end

    def render_preprocessed(tokens)
      out = +""
      previous = nil
      tokens.each do |token|
        if previous.nil?
          # first token: no leading separator
        elsif token.filename != previous.filename || token.line != previous.line
          out << "\n"
        elsif token.space_before
          out << " "
        end
        out << token.text
        previous = token
      end
      out << "\n" unless out.empty?
      out
    end

    # --- diagnostics -------------------------------------------------------

    def warning(message)
      @err.puts "#{PROG}: warning: #{message}"
    end
  end
end
