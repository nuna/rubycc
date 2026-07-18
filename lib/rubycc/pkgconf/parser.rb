# frozen_string_literal: true

module Rubycc
  module Pkgconf
    # Parses one .pc file's text into a Package. The grammar covered is
    # exactly what the real .pc files this environment ships (zlib.pc,
    # libffi.pc, openssl.pc's Requires chain — see test/fixtures/pkgconfig)
    # and mkmf's own pkg_config() call shape actually use: `#`-comments and
    # blank lines, `name=value` variable assignments, `${name}` expansion
    # inside both variable and field values, and the seven fields
    # Name/Description/Version/Requires/Requires.private/Libs/Libs.private/
    # Cflags. Any other field line (URL:, Conflicts:, ...) is accepted and
    # ignored — mkmf's pkg_config() never reads them — rather than rejected,
    # so a real-world .pc with extra fields still parses.
    class Parser
      VARIABLE_LINE = /\A([A-Za-z_][A-Za-z0-9_.]*)=(.*)\z/
      FIELD_LINE = /\A([A-Za-z][A-Za-z0-9.]*)\s*:\s*(.*)\z/
      VARIABLE_REFERENCE = /\$\{([A-Za-z_][A-Za-z0-9_.]*)\}/

      # A single `Requires`/`Requires.private` entry with a version
      # comparison attached, spaced (`zlib >= 1.2`) or not (`zlib>=1.2`).
      REQUIRES_OPERATOR = /\A(<=|>=|==|!=|<|>|=)\z/

      KNOWN_FIELDS = %w[Name Description Version Requires Requires.private Libs Libs.private Cflags].freeze

      def self.parse(text, path: nil)
        new(text, path: path).parse
      end

      def initialize(text, path: nil)
        @text = text
        @path = path
        @variables = {}
        @fields = {}
      end

      def parse
        @text.each_line.with_index(1) do |raw_line, line_number|
          parse_line(raw_line.chomp, line_number)
        end
        build_package
      end

      private

      def parse_line(line, line_number)
        return if line.strip.empty?
        return if line.lstrip.start_with?("#")

        if (m = VARIABLE_LINE.match(line))
          @variables[m[1]] = expand(m[2].strip, line_number)
        elsif (m = FIELD_LINE.match(line))
          @fields[m[1]] = expand(m[2].strip, line_number) if KNOWN_FIELDS.include?(m[1])
        else
          raise ParseError.new("unrecognized line: #{line.inspect}", path: @path, line_number: line_number)
        end
      end

      # Variables are expanded at the point they are assigned, against
      # whatever variables are already known — the same order the real
      # fixtures rely on (prefix, then exec_prefix=${prefix}, then
      # libdir=${exec_prefix}/lib, ...). Fields are expanded the same way,
      # against the full variable table (fields conventionally follow all
      # variable assignments in a .pc file).
      def expand(value, line_number)
        value.gsub(VARIABLE_REFERENCE) do
          name = Regexp.last_match(1)
          @variables.fetch(name) do
            raise ParseError.new("undefined variable '#{name}'", path: @path, line_number: line_number)
          end
        end
      end

      def build_package
        Package.new(
          name: @fields["Name"],
          description: @fields["Description"],
          version: @fields["Version"],
          requires: parse_requires(@fields["Requires"]),
          requires_private: parse_requires(@fields["Requires.private"]),
          cflags: @fields["Cflags"] || "",
          libs: @fields["Libs"] || "",
          libs_private: @fields["Libs.private"] || "",
          path: @path
        )
      end

      # A bare module-name list ("libssl libcrypto" or "libssl, libcrypto").
      # A version comparison attached to an entry is diagnosed rather than
      # evaluated: mkmf's pkg_config(pkg, *options) always passes `pkg` as a
      # bare module name (see the Step 59 report), so this shim only needs to
      # resolve Requires by name.
      def parse_requires(value)
        return [] if value.nil? || value.strip.empty?

        spaced = value.gsub(/(<=|>=|==|!=|<|>|=)/) { " #{Regexp.last_match(1)} " }
        tokens = spaced.split(/[,\s]+/).reject(&:empty?)
        tokens.each do |token|
          next unless REQUIRES_OPERATOR.match?(token)

          raise UnsupportedError,
                "version-constrained Requires (#{value.inspect}) is unsupported: mkmf's pkg_config() " \
                "never passes a version constraint, so only bare module names in Requires are handled"
        end
        tokens
      end
    end
  end
end
