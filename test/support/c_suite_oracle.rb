# frozen_string_literal: true

# Project-owned probes for c-testsuite cases whose upstream programs only
# communicate their result through main's low exit-status byte. The upstream
# sources remain the subject under test; these probes only add observability in
# memory and are never written back to test/external/c-testsuite.
module CTestSuiteOracle
  EXPECTED_OUTPUT = {
    # arr[1][3], p[1][3], *q and *v must all observe the same stored value.
    "00130" => "2 2 2 2\n",
    # The first four values cover ordinary and designated initializers; the
    # final three values prove that the inferred and explicit dimensions are
    # still 2 x 3 x 5.
    "00151" => "1 6 7 7 2 3 5\n"
  }.freeze

  # This is the output of the source-level mutant used by the regression test:
  # the array keeps its shape, but all designated initializer values are
  # discarded. A zero-only output must not satisfy the real oracle.
  MUTATION_OUTPUT = {
    "00151" => "0 0 0 0 2 3 5\n"
  }.freeze

  class << self
    def supported_case?(basename)
      EXPECTED_OUTPUT.key?(basename)
    end

    def expected_output(basename)
      EXPECTED_OUTPUT.fetch(basename)
    end

    def mutation_output(basename)
      MUTATION_OUTPUT.fetch(basename)
    end

    # Add a stdout oracle around one of the upstream sources. `mutation:` is
    # intentionally narrow: it exists only to prove that 00151's oracle would
    # reject an implementation that silently drops its initializer values.
    def source(c_path, basename, mutation: nil)
      source = File.read(c_path)

      case basename
      when "00130"
        raise ArgumentError, "00130 has no supported mutation" unless mutation.nil?

        instrument_00130(source)
      when "00151"
        if mutation == :ignore_initializer
          source = ignore_00151_initializer(source)
        elsif !mutation.nil?
          raise ArgumentError, "unknown 00151 mutation: #{mutation.inspect}"
        end

        instrument_00151(source)
      else
        raise ArgumentError, "no c-testsuite oracle for #{basename.inspect}"
      end
    end

    private

    def instrument_00130(source)
      marker = "\treturn 0;"
      unless source.scan(marker).length == 1
        raise "00130 oracle anchor changed: expected one final return"
      end

      replacement = <<~C
        \tprintf("%d %d %d %d\\n", arr[1][3], p[1][3], *q, *v);
        \treturn 0;
      C
      source = source.sub(marker, replacement.chomp)
      "#include <stdio.h>\n#{source}"
    end

    def instrument_00151(source)
      <<~C
        #define main c_testsuite_main
        #{source}
        #undef main
        #include <stdio.h>

        int main(void)
        {
          int status = c_testsuite_main();
          printf("%d %d %d %d %d %d %d\\n",
                 arr[0][1][0], arr[0][1][3], arr[0][1][4], arr[1][1][4],
                 (int)(sizeof arr / sizeof arr[0]),
                 (int)(sizeof arr[0] / sizeof arr[0][0]),
                 (int)(sizeof arr[0][0] / sizeof arr[0][0][0]));
          return status;
        }
      C
    end

    def ignore_00151_initializer(source)
      initializer = /\Aint arr\[\]\[3\]\[5\] = \{.*?\n\};\n/m
      mutated = source.sub(initializer, "int arr[2][3][5] = { 0 };\n")
      raise "00151 initializer mutation anchor changed" if mutated == source

      mutated
    end
  end
end
