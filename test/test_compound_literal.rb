# frozen_string_literal: true

require_relative "test_helper"

# Step 53: compound literals "( type-name ) { initializer-list }" (ISO C
# 6.5.2.5) in block scope. The literal denotes an unnamed object with the
# enclosing block's automatic storage, so it is an lvalue: a struct yields its
# address (a by-value argument, an assignment, a member access all follow the
# ordinary struct-value convention), an array decays to a pointer to its first
# element, and a scalar loads its value; "&(T){...}" takes the object's address.
# These are execution tests checked against the system gcc (exit status and, for
# the printing cases, stdout), plus the file-scope diagnostic.
class TestCompoundLiteral < Minitest::Test
  include ExecutionHelper

  # The json parser.c form that motivated the step: a struct compound literal
  # with designated initializers, passed to a function by value.
  def test_struct_designated_passed_by_value
    src = <<~C
      typedef struct { int type; int phase; int head; } frame;
      int sum(frame f) { return f.type * 100 + f.phase * 10 + f.head; }
      int main(void) {
        return sum((frame){ .type = 1, .phase = 2, .head = 3, });
      }
    C
    assert_c_exit_status(123, src)
  end

  def test_scalar_compound_literal
    assert_c_exit_status(42, "int main(void) { return (int){42}; }")
  end

  # An array compound literal decays to a pointer; subscripting reads elements.
  def test_array_compound_literal_decays_and_subscripts
    src = <<~C
      int main(void) {
        int *a = (int[]){10, 20, 30};
        return a[0] + a[1] + a[2];
      }
    C
    assert_c_exit_status(60, src)
  end

  # The "[]" bound is inferred from the element count.
  def test_array_bound_inferred_from_elements
    src = "int main(void) { return sizeof((int[]){1,2,3,4,5}) / sizeof(int); }"
    assert_c_exit_status(5, src)
  end

  # An array literal decays right at a call argument, and is subscripted inline.
  def test_array_literal_argument_and_inline_subscript
    src = <<~C
      int at(int *p, int i) { return p[i]; }
      int main(void) {
        return at((int[]){4, 5, 6}, 2) + (int[]){7, 8, 9}[1];
      }
    C
    assert_c_exit_status(14, src)
  end

  # "&(T){...}" is a pointer to the unnamed object, usable as a pointer argument.
  def test_address_of_compound_literal_as_pointer_argument
    src = <<~C
      typedef struct { int a; int b; } pair;
      int viaptr(pair *p) { return p->a * 10 + p->b; }
      int main(void) { return viaptr(&(pair){ .a = 4, .b = 2 }); }
    C
    assert_c_exit_status(42, src)
  end

  # Member access binds directly to the literal ("(T){...}.member").
  def test_member_access_on_compound_literal
    src = <<~C
      typedef struct { int x; int y; } point;
      int main(void) { return (point){ .x = 30, .y = 12 }.x + (point){ .x = 30, .y = 12 }.y; }
    C
    assert_c_exit_status(42, src)
  end

  # Nested struct-in-struct via a nested brace list, both designated and by
  # position (brace elision).
  def test_nested_struct_literal
    src = <<~C
      typedef struct { int x; int y; } point;
      typedef struct { point origin; int tag; } shape;
      int main(void) {
        shape a = (shape){ .origin = {3, 4}, .tag = 9 };
        shape b = (shape){ {1, 2}, 5 };
        return a.origin.x + a.origin.y + a.tag + b.origin.x + b.origin.y + b.tag;
      }
    C
    assert_c_exit_status(24, src)
  end

  # A compound literal used as an initializer-list expression for a nested
  # aggregate is a whole-object copy, not brace elision of the outer list.
  def test_nested_compound_literal_initializer_expression
    src = <<~C
      typedef struct { int x; int y; } point;
      typedef struct { point origin; int tag; } shape;
      int main(void) {
        shape value = { .origin = (point){ .x = 8, .y = 5 }, .tag = 1 };
        return value.origin.x * 10 + value.origin.y + value.tag;
      }
    C
    assert_c_exit_status(86, src)
  end

  # A partially designated literal zero-fills its unspecified members.
  def test_unspecified_members_are_zero_filled
    src = <<~C
      typedef struct { int a; int b; int c; } triple;
      int main(void) {
        triple t = (triple){ .b = 7 };
        return t.a * 100 + t.b * 10 + t.c;  /* a and c are zero */
      }
    C
    assert_c_exit_status(70, src)
  end

  # Each evaluation of a compound literal reinitializes the object; the loop
  # sums a value that depends only on the current iteration.
  def test_loop_reinitializes_each_iteration
    src = <<~C
      typedef struct { int keep; int seed; } cell;
      int main(void) {
        int acc = 0;
        for (int i = 0; i < 4; i++) {
          cell c = (cell){ .seed = i };  /* keep is re-zeroed every pass */
          c.keep += 10;                  /* proves keep starts at 0 each time */
          acc += c.keep + c.seed;
        }
        return acc;  /* 4*10 + (0+1+2+3) */
      }
    C
    assert_c_exit_status(46, src)
  end

  # A struct compound literal on the right of an assignment.
  def test_compound_literal_as_assignment_rhs
    src = <<~C
      typedef struct { int a; int b; } pair;
      int main(void) {
        pair p = (pair){ .a = 1, .b = 2 };
        p = (pair){ .a = 40, .b = 2 };
        return p.a + p.b;
      }
    C
    assert_c_exit_status(42, src)
  end

  # The address of a nested member of a compound literal.
  def test_address_of_nested_member
    src = <<~C
      typedef struct { int x; int y; } point;
      typedef struct { point origin; int tag; } shape;
      int main(void) {
        point *p = &(shape){ .origin = {7, 8}, .tag = 1 }.origin;
        return p->x * 10 + p->y;
      }
    C
    assert_c_exit_status(78, src)
  end

  def test_stdout_from_struct_literal_argument
    src = <<~C
      int printf(const char *, ...);
      typedef struct { int a; int b; } pair;
      int show(pair p) { return printf("%d,%d\\n", p.a, p.b); }
      int main(void) { show((pair){ .a = 6, .b = 7 }); return 0; }
    C
    assert_c_program(src, exit_status: 0, stdout: "6,7\n")
  end

  # A compound literal is not distinguished from a cast until the "{" is seen:
  # "(int)x" must still parse as an ordinary cast.
  def test_ordinary_cast_still_parses
    assert_c_exit_status(3, "int main(void) { double d = 3.9; return (int)d; }")
  end

  # A compound literal at file scope has static storage duration, which this
  # subset does not lay out yet; it is a clear diagnostic, not a silent miscompile.
  def test_file_scope_compound_literal_is_diagnosed
    src = "int *p = (int[]){1, 2, 3};\nint main(void) { return p[0]; }"
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(src, filename: "fs.c")
    end
    assert_match(/compound literal at file scope is not supported yet/, error.description)
  end

  def test_file_scope_addressed_compound_literal_is_diagnosed
    src = "typedef struct { int a; } S;\nS *g = &(S){ .a = 1 };\nint main(void) { return g->a; }"
    error = assert_raises(Rubycc::CompileError) do
      Rubycc::Compiler.new.compile(src, filename: "fs.c")
    end
    assert_match(/compound literal at file scope is not supported yet/, error.description)
  end
end
