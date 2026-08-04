# frozen_string_literal: true

require_relative "test_helper"

# The _Noreturn function specifier (ISO C11 6.7.4, Step 182). It is only an
# optimization hint (see include/stdnoreturn.h's comment, which this feature
# shares its rationale with), so rubycc accepts and drops it -- dropping it
# changes no observable behavior. This is what let musl's plain "_Noreturn void
# abort(void);" (unlike glibc's __attribute__((__noreturn__)) spelling of the
# same prototype) stop blocking a translation unit from being parsed at all.
#
# TestParser and TestDiagnostics pin the parse-level acceptance/rejection; this
# file cross-checks the whole thing against the system gcc at run time, so a
# _Noreturn-declared function that is actually called behaves identically on
# both compilers.
class TestNoreturn < Minitest::Test
  include ExecutionHelper

  def test_prototype_and_definition_match_gcc
    src = <<~C
      #include <stdlib.h>
      _Noreturn void die(int code);
      int main(void) {
        die(42);
      }
      _Noreturn void die(int code) {
        exit(code);
      }
    C
    assert_matches_gcc(42, src)
  end

  def test_mixes_with_storage_class_in_either_order
    src = <<~C
      #include <stdlib.h>
      static _Noreturn void bail(int code);
      _Noreturn static void abandon(int code);

      static _Noreturn void bail(int code) { exit(code); }
      _Noreturn static void abandon(int code) { exit(code); }

      int main(void) {
        if (0) {
          bail(1);
        }
        abandon(7);
      }
    C
    assert_matches_gcc(7, src)
  end

  def test_repeated_specifier_matches_gcc
    src = <<~C
      #include <stdlib.h>
      _Noreturn _Noreturn void die(void);
      _Noreturn _Noreturn void die(void) {
        exit(9);
      }
      int main(void) {
        die();
      }
    C
    assert_matches_gcc(9, src)
  end

  # The block-scope form musl's headers rely on (Step 168): the function it
  # names is defined further down the same translation unit.
  def test_block_scope_declaration_matches_gcc
    src = <<~C
      #include <stdlib.h>
      int main(void) {
        _Noreturn void die(int code);
        die(5);
      }
      _Noreturn void die(int code) {
        exit(code);
      }
    C
    assert_matches_gcc(5, src)
  end

  private

  # Compiles `src` with both rubycc and gcc, links and runs each, asserting
  # both exit with `expected`.
  def assert_matches_gcc(expected, src)
    assert_c_exit_status(expected, src, compiler: :rubycc)
    assert_c_exit_status(expected, src, compiler: :gcc)
  end
end
