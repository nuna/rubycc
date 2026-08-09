#!/usr/bin/env ruby
# frozen_string_literal: true

# Heuristically find variadic-related C source patterns in a local corpus.
#
# This tool deliberately does not invoke a preprocessor, a compiler, or the
# network.  Its output is a list of candidates for human follow-up.  It is not
# an absence proof, an R10 conformance check, or a pass/fail gate.

require "json"
require "optparse"

module CorpusVariadicsScanner
  SCHEMA_VERSION = 1
  TOOL_NAME = "scan_corpus_variadics"

  DEFAULT_EXTENSIONS = %w[.c .h .i .inc].freeze
  DEFAULT_EXCLUDED_DIRS = [".git"].freeze
  VA_LIST_TYPE_NAMES = %w[va_list __builtin_va_list __gnuc_va_list __isoc_va_list].freeze

  KEYWORDS = %w[
    _Alignas _Alignof _Atomic _Generic _Static_assert _Thread_local
    asm case const do else enum extern for goto if inline register restrict
    return sizeof static struct switch typedef typeof union unsigned volatile
    while
  ].freeze

  # These declarations are useful when a corpus source calls a libc API but
  # the corresponding system header is outside the scan root.  They are only
  # fallback candidates; a local declaration always takes precedence.
  KNOWN_VARIADIC_APIS = {
    "asprintf" => 2,
    "dprintf" => 2,
    "err" => 2,
    "errx" => 2,
    "execl" => 2,
    "execlp" => 2,
    "execle" => 2,
    "fprintf" => 2,
    "open" => 2,
    "openat" => 3,
    "printf" => 1,
    "snprintf" => 3,
    "sprintf" => 2,
    "syslog" => 2,
    "warn" => 1,
    "warnx" => 1
  }.freeze

  LIMITATIONS = [
    "The scan is lexical and heuristic; it is not a proof of absence or an R10/pass gate.",
    "Comments and string/character literals are ignored, but preprocessor conditions are not evaluated.",
    "Macros are not expanded: macro-generated uses can be missed, while matching tokens in a macro body can be reported.",
    "Includes are not resolved across files; declarations and typedefs are associated with their containing source file.",
    "No C type checking is performed; struct caller findings require manual confirmation and compiler/oracle evidence."
  ].freeze

  Finding = Struct.new(
    :root_index, :path, :line, :column, :kind, :confidence, :evidence, :details,
    keyword_init: true
  )

  ApiDeclaration = Struct.new(
    :root_index, :path, :line, :column, :name, :fixed_parameter_count, :form,
    keyword_init: true
  )

  Source = Struct.new(
    :root_index, :path, :absolute_path, :text, :sanitized, :line_starts,
    :api_declarations, :struct_variables, :struct_aliases, :va_list_aliases,
    keyword_init: true
  )

  # A scanner instance is reusable, but each call to #scan creates a fresh
  # report.  Roots are kept in caller order; files and findings are sorted.
  class Scanner
    IDENT_CALL_RE = /(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*\(/n
    FUNCTION_POINTER_RE = /\(\s*\*\s*([A-Za-z_][A-Za-z0-9_]*)?\s*\)\s*\(/n
    VA_ARG_NAMES = %w[va_arg __builtin_va_arg].freeze
    VA_COPY_NAMES = %w[va_copy __builtin_va_copy __va_copy].freeze

    def initialize(roots: ["."], extensions: DEFAULT_EXTENSIONS,
                   excluded_dirs: DEFAULT_EXCLUDED_DIRS)
      @root_inputs = roots.map(&:to_s)
      @root_inputs = ["."] if @root_inputs.empty?
      @extensions = extensions.map { |ext| normalize_extension(ext) }.uniq.sort.freeze
      @excluded_dirs = excluded_dirs.map(&:to_s).reject(&:empty?).uniq.freeze
      @roots = @root_inputs.each_with_index.map do |input, index|
        absolute = File.expand_path(input)
        raise ArgumentError, "root does not exist: #{input}" unless File.exist?(absolute)

        { index: index, input: input, absolute: absolute }
      end.freeze
      @errors = []
    end

    def scan
      @errors = []
      sources = load_sources
      sources.each do |source|
        source.api_declarations = discover_api_declarations(source)
        source.struct_aliases = discover_struct_aliases(source)
        source.va_list_aliases = discover_va_list_aliases(source)
        source.struct_variables = discover_struct_variables(source)
      end

      api_index = build_api_index(sources)
      findings = sources.flat_map do |source|
        discover_findings(source, api_index)
      end
      findings.sort_by! { |finding| finding_sort_key(finding) }

      report = {
        "schema_version" => SCHEMA_VERSION,
        "tool" => TOOL_NAME,
        "mode" => "heuristic-candidate-scan",
        "not_proof" => true,
        "not_acceptance_gate" => true,
        # Absolute input paths are intentionally omitted.  Findings identify
        # their root by index and use a path relative to that root, so the
        # report remains comparable between a checkout and a CI workspace.
        "roots" => @roots.map { |root| { "index" => root[:index] } },
        "extensions" => @extensions,
        "excluded_directories" => @excluded_dirs.sort,
        "files_scanned" => sources.size,
        "api_declarations" => sources.flat_map { |source| source.api_declarations.map { |api| api_to_h(api) } }
          .sort_by { |api| [api["root_index"], api["path"], api["line"], api["column"], api["name"]] },
        "findings" => findings.map { |finding| finding_to_h(finding) },
        "summary" => summary(findings),
        "errors" => @errors.sort_by { |error| [error["root_index"], error["path"], error["message"]] },
        "limitations" => LIMITATIONS
      }
      report
    end

    private

    def normalize_extension(extension)
      value = extension.to_s
      value = ".#{value}" unless value.start_with?(".")
      value.downcase
    end

    def load_sources
      @roots.flat_map do |root|
        paths = if File.file?(root[:absolute])
                  [root[:absolute]]
                else
                  Dir.glob(File.join(root[:absolute], "**", "*"), File::FNM_DOTMATCH)
                    .select { |path| File.file?(path) }
                end

        paths.filter_map do |path|
          next if File.symlink?(path)
          next if excluded_path?(root, path)
          next unless @extensions.include?(File.extname(path).downcase)

          relative = relative_path(root[:absolute], path)
          begin
            text = File.binread(path)
          rescue SystemCallError => error
            @errors << {
              "root_index" => root[:index],
              "path" => relative,
              "message" => "#{error.class}: #{error.message}"
            }
            next
          end

          sanitized = sanitize(text)
          Source.new(
            root_index: root[:index],
            path: relative,
            absolute_path: path,
            text: text,
            sanitized: sanitized,
            line_starts: line_starts(sanitized),
            api_declarations: [],
            struct_variables: {},
            struct_aliases: [],
            va_list_aliases: []
          )
        end
      end.sort_by { |source| [source.root_index, source.path] }
    end

    def excluded_path?(root, path)
      relative = relative_path(root[:absolute], path)
      relative.split(/[\\\/]/).any? { |component| @excluded_dirs.include?(component) }
    end

    def relative_path(root, path)
      return File.basename(path) if File.file?(root)

      prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      relative = path.start_with?(prefix) ? path.delete_prefix(prefix) : File.basename(path)
      relative.tr(File::SEPARATOR, "/")
    end

    # Replace comments and literals with spaces while preserving byte offsets
    # and newlines.  This makes every finding point into the original file.
    def sanitize(text)
      bytes = text.bytes
      output = bytes.dup
      state = :code
      quote = nil
      index = 0

      while index < bytes.length
        byte = bytes[index]
        next_byte = bytes[index + 1]

        case state
        when :code
          if byte == 47 && next_byte == 47 # //
            output[index] = 32
            output[index + 1] = 32
            index += 2
            state = :line_comment
          elsif byte == 47 && next_byte == 42 # /*
            output[index] = 32
            output[index + 1] = 32
            index += 2
            state = :block_comment
          elsif byte == 34 || byte == 39 # string or character literal
            output[index] = 32
            quote = byte
            index += 1
            state = :quoted
          else
            index += 1
          end
        when :line_comment
          if byte == 10
            state = :code
            index += 1
          else
            output[index] = 32
            index += 1
          end
        when :block_comment
          if byte == 42 && next_byte == 47
            output[index] = 32
            output[index + 1] = 32
            index += 2
            state = :code
          else
            output[index] = 10 if byte == 10
            output[index] = 13 if byte == 13
            output[index] = 32 unless byte == 10 || byte == 13
            index += 1
          end
        when :quoted
          if byte == 92 # escaped character or escaped newline
            output[index] = 32
            if next_byte
              output[index + 1] = 10 if next_byte == 10
              output[index + 1] = 13 if next_byte == 13
              output[index + 1] = 32 unless next_byte == 10 || next_byte == 13
              index += 2
            else
              index += 1
            end
          elsif byte == quote
            output[index] = 32
            index += 1
            state = :code
          else
            output[index] = 10 if byte == 10
            output[index] = 13 if byte == 13
            output[index] = 32 unless byte == 10 || byte == 13
            index += 1
          end
        end
      end

      output.pack("C*")
    end

    def line_starts(text)
      starts = [0]
      text.bytes.each_with_index { |byte, index| starts << index + 1 if byte == 10 }
      starts
    end

    def position(source, offset)
      line_index = source.line_starts.bsearch_index { |start| start > offset }
      line_index = line_index ? line_index - 1 : source.line_starts.length - 1
      [line_index + 1, offset - source.line_starts[line_index] + 1]
    end

    def matching_delimiter(text, open_offset)
      opening = text.getbyte(open_offset)
      closing = { 40 => 41, 91 => 93, 123 => 125 }[opening]
      return nil unless closing

      stack = [closing]
      index = open_offset + 1
      while index < text.bytesize
        byte = text.getbyte(index)
        if [40, 91, 123].include?(byte)
          stack << { 40 => 41, 91 => 93, 123 => 125 }[byte]
        elsif [41, 93, 125].include?(byte)
          return nil unless stack.last == byte

          stack.pop
          return index if stack.empty?
        end
        index += 1
      end
      nil
    end

    # Return top-level comma-separated arguments with their offsets in the
    # source.  Braced compound literals are kept as one argument.
    def split_arguments(text, absolute_offset)
      return [] if text.strip.empty?

      arguments = []
      start = 0
      stack = []
      text.bytes.each_with_index do |byte, index|
        case byte
        when 40 then stack << 41
        when 91 then stack << 93
        when 123 then stack << 125
        when 41, 93, 125 then stack.pop if stack.last == byte
        when 44
          next unless stack.empty?

          arguments << {
            text: text.byteslice(start, index - start),
            offset: absolute_offset + start
          }
          start = index + 1
        end
      end
      arguments << {
        text: text.byteslice(start, text.bytesize - start),
        offset: absolute_offset + start
      }
      arguments
    end

    def function_calls(source)
      calls = []
      source.sanitized.to_enum(:scan, IDENT_CALL_RE).each do
        match = Regexp.last_match
        name = match[1]
        next if KEYWORDS.include?(name)

        open_offset = match.end(0) - 1
        close_offset = matching_delimiter(source.sanitized, open_offset)
        next unless close_offset

        content_offset = open_offset + 1
        content = source.sanitized.byteslice(content_offset, close_offset - content_offset)
        calls << {
          name: name,
          name_offset: match.begin(1),
          open_offset: open_offset,
          close_offset: close_offset,
          arguments: split_arguments(content, content_offset)
        }
      end
      calls
    end

    def function_pointers(source)
      pointers = []
      source.sanitized.to_enum(:scan, FUNCTION_POINTER_RE).each do
        match = Regexp.last_match
        open_offset = match.end(0) - 1
        close_offset = matching_delimiter(source.sanitized, open_offset)
        next unless close_offset

        content_offset = open_offset + 1
        content = source.sanitized.byteslice(content_offset, close_offset - content_offset)
        arguments = split_arguments(content, content_offset)
        ellipsis = arguments.index { |argument| argument[:text].strip == "..." }
        next unless ellipsis

        pointers << {
          name: match[1],
          offset: match.begin(0),
          open_offset: open_offset,
          close_offset: close_offset,
          arguments: arguments,
          fixed_parameter_count: ellipsis
        }
      end
      pointers
    end

    def discover_api_declarations(source)
      declarations = []

      function_calls(source).each do |call|
        next unless top_level_ellipsis?(call[:arguments])
        next unless declaration_context?(source, call[:close_offset])
        next if preprocessor_line?(source, call[:name_offset])

        ellipsis = call[:arguments].index { |argument| argument[:text].strip == "..." }
        declarations << ApiDeclaration.new(
          root_index: source.root_index,
          path: source.path,
          line: position(source, call[:name_offset])[0],
          column: position(source, call[:name_offset])[1],
          name: call[:name],
          fixed_parameter_count: ellipsis,
          form: "function_or_declaration"
        )
      end

      function_pointers(source).each do |pointer|
        next unless pointer[:name]

        declarations << ApiDeclaration.new(
          root_index: source.root_index,
          path: source.path,
          line: position(source, pointer[:offset])[0],
          column: position(source, pointer[:offset])[1],
          name: pointer[:name],
          fixed_parameter_count: pointer[:fixed_parameter_count],
          form: "function_pointer"
        )

        # A typedef such as `typedef void (*callback_t)(const char *, ...);`
        # is commonly followed by `callback_t callback;`.  Treat the object
        # as an API candidate too, so a later `callback(...)` call is visible.
        next unless typedef_prefix?(source, pointer[:offset])

        pattern = /\b#{Regexp.escape(pointer[:name])}\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?=[=,;\)\]])/n
        source.sanitized.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          declarations << ApiDeclaration.new(
            root_index: source.root_index,
            path: source.path,
            line: position(source, match.begin(1))[0],
            column: position(source, match.begin(1))[1],
            name: match[1],
            fixed_parameter_count: pointer[:fixed_parameter_count],
            form: "function_pointer_variable"
          )
        end
      end

      # Keep one declaration per source location.  A pointer declaration is
      # intentionally represented separately from the generic function scan.
      declarations.uniq { |declaration| [declaration.path, declaration.line, declaration.column, declaration.name] }
    end

    def typedef_prefix?(source, offset)
      line_start = offset.zero? ? 0 : source.sanitized.rindex("\n", offset - 1).to_i + 1
      prefix = source.sanitized.byteslice(line_start, offset - line_start).to_s
      prefix.match?(/\btypedef\b/n)
    end

    def top_level_ellipsis?(arguments)
      arguments.any? { |argument| argument[:text].strip == "..." }
    end

    def declaration_context?(source, close_offset)
      index = close_offset + 1
      index += 1 while index < source.sanitized.bytesize && [9, 10, 13, 32].include?(source.sanitized.getbyte(index))
      [59, 123].include?(source.sanitized.getbyte(index)) # ; or {
    end

    def preprocessor_line?(source, offset)
      line_start = offset.zero? ? 0 : source.sanitized.rindex("\n", offset - 1).to_i + 1
      line = source.sanitized.byteslice(line_start, offset - line_start)
      line.lstrip.start_with?("#")
    end

    def discover_struct_aliases(source)
      aliases = []
      source.sanitized.to_enum(:scan, /\btypedef\s+(?:struct|union)\s+[A-Za-z_][A-Za-z0-9_]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/n).each do
        aliases << Regexp.last_match(1)
      end

      # Also cover `typedef struct { ... } name;` without attempting to parse
      # the full declaration body.
      source.sanitized.to_enum(:scan, /\btypedef\s+(?:struct|union)\s*\{/n).each do
        match = Regexp.last_match
        open = source.sanitized.index("{", match.begin(0))
        close = matching_delimiter(source.sanitized, open)
        next unless close

        suffix = source.sanitized.byteslice(close + 1, 160).to_s
        alias_match = /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*;/n.match(suffix)
        aliases << alias_match[1] if alias_match
      end
      aliases.uniq.sort
    end

    def discover_va_list_aliases(source)
      aliases = []
      type_names = VA_LIST_TYPE_NAMES.join("|")
      pattern = /\btypedef\s+(?:(?:const|volatile)\s+)?(?:#{type_names})\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/n
      source.sanitized.to_enum(:scan, pattern).each { aliases << Regexp.last_match(1) }
      aliases.uniq.sort
    end

    def discover_struct_variables(source)
      variables = {}
      pattern = /\b(?:struct|union)\s+[A-Za-z_][A-Za-z0-9_]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?=[=,;\)\]])/n
      source.sanitized.to_enum(:scan, pattern).each { variables[Regexp.last_match(1)] = true }

      # Named declarations above do not cover `struct { ... } value;`.  Walk
      # only the anonymous body and collect the declarators immediately after
      # its closing brace.  A typedef's name is an alias, not an object, so it
      # is deliberately excluded here.
      source.sanitized.to_enum(:scan, /\b(?:struct|union)\s*\{/n).each do
        match = Regexp.last_match
        open = source.sanitized.index("{", match.begin(0))
        close = matching_delimiter(source.sanitized, open)
        next unless close

        prefix = source.sanitized.byteslice(0, match.begin(0)).to_s
        next if prefix.match?(/\btypedef\s*\z/n)

        semicolon = source.sanitized.index(";", close + 1) || source.sanitized.bytesize
        suffix = source.sanitized.byteslice(close + 1, semicolon - close - 1).to_s
        suffix.split(",").each do |declarator|
          name = /\b([A-Za-z_][A-Za-z0-9_]*)\b/n.match(declarator)
          variables[name[1]] = true if name
        end
      end

      source.struct_aliases.each do |type_name|
        pattern = /\b#{Regexp.escape(type_name)}\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?=[=,;\)\]])/n
        source.sanitized.to_enum(:scan, pattern).each { variables[Regexp.last_match(1)] = true }
      end
      variables
    end

    def build_api_index(sources)
      index = Hash.new { |hash, name| hash[name] = [] }
      sources.each do |source|
        source.api_declarations.each { |declaration| index[declaration.name] << declaration }
      end
      index
    end

    def discover_findings(source, api_index)
      findings = []
      calls = function_calls(source)

      calls.each do |call|
        if VA_ARG_NAMES.include?(call[:name])
          arguments = call[:arguments]
          type_argument = arguments[1]
          if type_argument && struct_va_arg_type?(type_argument[:text], source.struct_aliases)
            type_text = normalize(type_argument[:text])
            alias_type = source.struct_aliases.any? do |alias_name|
              type_text.match?(/\A(?:const|volatile)?\s*#{Regexp.escape(alias_name)}\s*\z/n)
            end
            findings << finding(
              source,
              type_argument[:offset],
              "va_arg_struct_or_union",
              "high",
              call_text(source, call),
              "type" => type_text,
              "type_form" => alias_type ? "struct_or_union_typedef" : "struct_or_union_specifier",
              "builtin" => call[:name].start_with?("__builtin_")
            )
          end
        elsif VA_COPY_NAMES.include?(call[:name])
          findings << finding(
            source,
            call[:name_offset],
            "va_copy_candidate",
            "high",
            call_text(source, call),
            "builtin" => call[:name].start_with?("__builtin_") || call[:name] == "__va_copy"
          )
        end

        if call[:arguments].any? { |argument| va_list_argument?(argument[:text], source.va_list_aliases) }
          findings << finding(
            source,
            call[:name_offset],
            "va_list_wrapper",
            "medium",
            call_text(source, call),
            "role" => "function_parameter_or_call"
          )
        end
      end

      va_list_type_names = VA_LIST_TYPE_NAMES.join("|")
      source.va_list_aliases.each do |alias_name|
        pattern = /\btypedef\s+(?:(?:const|volatile)\s+)?(?:#{va_list_type_names})\s+#{Regexp.escape(alias_name)}\b/n
        source.sanitized.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          findings << finding(
            source,
            match.begin(0),
            "va_list_wrapper",
            "high",
            source.sanitized.byteslice(match.begin(0), match[0].bytesize),
            "role" => "typedef_alias",
            "alias" => alias_name
          )
        end
      end

      function_pointers(source).each do |pointer|
        findings << finding(
          source,
          pointer[:offset],
          "function_pointer_variadic_api",
          "high",
          source.sanitized.byteslice(pointer[:offset], pointer[:close_offset] - pointer[:offset] + 1),
          "name" => pointer[:name],
          "fixed_parameter_count" => pointer[:fixed_parameter_count]
        )
      end

      calls.each do |call|
        api = select_api(call[:name], api_index, source)
        next unless api
        next if api_is_declared_at?(source, call, api_index[call[:name]])

        fixed_count = api[:fixed_parameter_count]
        call[:arguments].each_with_index do |argument, index|
          next if index < fixed_count
          shape = struct_argument_shape(argument[:text], source.struct_variables)
          next unless shape

          confidence = api[:local] ? "high" : "medium"
          details = {
            "callee" => call[:name],
            "argument_index" => index,
            "fixed_parameter_count" => fixed_count,
            "argument_shape" => shape,
            "api_source" => api[:local] ? "scanned_declaration" : "known_variadic_api"
          }
          details["declaration"] = api_declaration_hash(api[:local]) if api[:local]
          findings << finding(
            source,
            argument[:offset],
            "struct_argument_to_variadic_candidate",
            confidence,
            call_text(source, call),
            details
          )
        end
      end

      findings
    end

    def select_api(name, api_index, source)
      # A bare C identifier is not a link-time declaration scope.  Two source
      # files can use the same helper name with different signatures, so only
      # a declaration in this source is treated as local evidence.  Header
      # declarations are intentionally not inferred without include analysis;
      # the small known-API table is the explicit fallback for those calls.
      local = api_index[name]
        .select { |api| api.root_index == source.root_index && api.path == source.path }
        .sort_by { |api| [api.line, api.column] }
        .first
      return { fixed_parameter_count: local.fixed_parameter_count, local: local } if local

      fixed_count = KNOWN_VARIADIC_APIS[name]
      return nil unless fixed_count

      { fixed_parameter_count: fixed_count, local: nil }
    end

    def api_is_declared_at?(source, call, declarations)
      declarations.any? do |declaration|
        declaration.root_index == source.root_index &&
          declaration.path == source.path &&
          declaration.line == position(source, call[:name_offset])[0] &&
          declaration.column == position(source, call[:name_offset])[1]
      end
    end

    def va_list_argument?(text, aliases)
      type_names = VA_LIST_TYPE_NAMES.join("|")
      return true if text.match?(/\b(?:#{type_names})\b/n)

      aliases.any? { |alias_name| text.match?(/\b#{Regexp.escape(alias_name)}\b/n) }
    end

    def struct_argument_shape(text, variables)
      normalized = text.strip
      return "explicit_struct_or_union_type" if normalized.match?(/\A\(?\s*(?:struct|union)\b/n)
      return "compound_literal" if normalized.match?(/\b(?:struct|union)\s+[A-Za-z_][A-Za-z0-9_]*\s*\{/n)

      variables.each_key do |variable|
        match = /\b#{Regexp.escape(variable)}\b/n.match(normalized)
        next unless match

        before = normalized.byteslice(0, match.begin(0)).to_s.rstrip
        next if before.end_with?("&", "*")

        return "known_struct_or_union_variable"
      end
      nil
    end

    def struct_va_arg_type?(text, aliases)
      normalized = text.to_s.strip
      return true if normalized.match?(/\A(?:const|volatile)?\s*(?:struct|union)\b/n)

      aliases.any? do |alias_name|
        normalized.match?(/\A(?:const|volatile)?\s*#{Regexp.escape(alias_name)}\s*\z/n)
      end
    end

    def call_text(source, call)
      normalize(source.sanitized.byteslice(call[:name_offset], call[:close_offset] - call[:name_offset] + 1))
    end

    def normalize(text)
      value = text.to_s.dup
      value.force_encoding(Encoding::UTF_8)
      value.scrub.gsub(/\s+/, " ").strip
    end

    def finding(source, offset, kind, confidence, evidence, details = {})
      line, column = position(source, offset)
      Finding.new(
        root_index: source.root_index,
        path: source.path,
        line: line,
        column: column,
        kind: kind,
        confidence: confidence,
        evidence: normalize(evidence),
        details: details
      )
    end

    def finding_sort_key(finding)
      [finding.root_index, finding.path, finding.line, finding.column, finding.kind, finding.evidence]
    end

    def api_declaration_hash(api)
      {
        "root_index" => api.root_index,
        "path" => api.path,
        "line" => api.line,
        "column" => api.column,
        "name" => api.name,
        "fixed_parameter_count" => api.fixed_parameter_count,
        "form" => api.form
      }
    end

    def api_to_h(api)
      api_declaration_hash(api)
    end

    def finding_to_h(finding)
      {
        "root_index" => finding.root_index,
        "path" => finding.path,
        "line" => finding.line,
        "column" => finding.column,
        "kind" => finding.kind,
        "confidence" => finding.confidence,
        "evidence" => finding.evidence,
        "details" => finding.details
      }
    end

    def summary(findings)
      counts = Hash.new(0)
      findings.each { |finding| counts[finding.kind] += 1 }
      {
        "total_findings" => findings.size,
        "by_kind" => counts.keys.sort.each_with_object({}) { |kind, result| result[kind] = counts[kind] }
      }
    end
  end

  module CLI
    module_function

    def option_parser(options)
      OptionParser.new do |parser|
        parser.banner = <<~BANNER
          Usage: ruby tools/scan_corpus_variadics.rb [options] [ROOT ...]

          Heuristically list variadic-related C source candidates without using
          the network.  This scanner is not an absence proof, an R10 conformance
          check, or a pass/fail gate.  It does not expand or evaluate macros.
        BANNER
        parser.on("-r", "--root PATH", "scan PATH (repeatable; default: .)") { |root| options[:roots] << root }
        parser.on("-f", "--format FORMAT", %w[json text], "output format (default: json)") do |format|
          options[:format] = format
        end
        parser.on("-o", "--output PATH", "write output to PATH instead of stdout") { |path| options[:output] = path }
        parser.on("--extension EXT", "include EXT (repeatable; default: .c,.h,.i,.inc)") do |extension|
          options[:extensions] << extension
        end
        parser.on("--exclude-dir NAME", "skip directories named NAME (repeatable; default: .git)") do |name|
          options[:excluded_dirs] << name
        end
        parser.on("-h", "--help", "show this help") do
          puts parser
          puts
          puts "Finding kinds: va_arg_struct_or_union, struct_argument_to_variadic_candidate,"
          puts "              va_list_wrapper, function_pointer_variadic_api, va_copy_candidate"
          puts
          puts "The JSON report is deterministic: no timestamp or host toolchain data is added."
          exit 0
        end
      end
    end

    def run(argv)
      options = {
        roots: [],
        format: "json",
        output: nil,
        extensions: [],
        excluded_dirs: CorpusVariadicsScanner::DEFAULT_EXCLUDED_DIRS.dup
      }
      parser = option_parser(options)
      positional = parser.parse!(argv)
      options[:roots].concat(positional)
      options[:roots] = ["."] if options[:roots].empty?
      options[:extensions] = CorpusVariadicsScanner::DEFAULT_EXTENSIONS if options[:extensions].empty?

      report = CorpusVariadicsScanner::Scanner.new(
        roots: options[:roots],
        extensions: options[:extensions],
        excluded_dirs: options[:excluded_dirs]
      ).scan
      output = options[:format] == "text" ? render_text(report) : JSON.pretty_generate(report) + "\n"
      write_output(options[:output], output)
      report["errors"].empty? ? 0 : 1
    rescue OptionParser::ParseError, ArgumentError => error
      warn "#{TOOL_NAME}: #{error.message}"
      warn parser
      2
    end

    def render_text(report)
      lines = []
      lines << "mode: #{report["mode"]}"
      lines << "warning: candidate scan only; not an absence proof or pass/fail gate"
      report["findings"].each do |finding|
        lines << format(
          "%s:%d:%d: %s [%s] %s",
          finding["path"], finding["line"], finding["column"], finding["kind"],
          finding["confidence"], finding["evidence"]
        )
      end
      lines << "summary: #{JSON.generate(report["summary"])}"
      report["errors"].each { |error| lines << "error: #{error["path"]}: #{error["message"]}" }
      lines.join("\n") + "\n"
    end

    def write_output(path, output)
      if path && path != "-"
        File.write(path, output)
      else
        $stdout.write(output)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit CorpusVariadicsScanner::CLI.run(ARGV)
end
