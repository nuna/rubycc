# frozen_string_literal: true

require_relative "test_helper"

class TestType < Minitest::Test
  Type = Rubycc::Type

  def test_int_predicates
    assert_predicate Type::Int, :int?
    refute_predicate Type::Int, :pointer?
  end

  def test_pointer_predicates
    ptr = Type::Pointer.new(Type::Int)
    assert_predicate ptr, :pointer?
    refute_predicate ptr, :int?
  end

  def test_char_predicates
    assert_predicate Type::Char, :char?
    assert_predicate Type::Char, :arithmetic?
    refute_predicate Type::Char, :int?
    refute_predicate Type::Char, :pointer?
    refute_predicate Type::Char, :array?
  end

  def test_int_is_arithmetic_but_not_char
    assert_predicate Type::Int, :arithmetic?
    refute_predicate Type::Int, :char?
  end

  def test_pointer_and_array_are_not_arithmetic
    refute_predicate Type::Pointer.new(Type::Char), :arithmetic?
    refute_predicate Type::Array.new(Type::Char, 3), :arithmetic?
  end

  def test_char_size_and_rendering
    assert_equal 1, Type::Char.size
    assert_equal "char", Type::Char.to_s
    assert_equal "char *", Type::Pointer.new(Type::Char).to_s
  end

  def test_char_and_int_are_not_equal
    refute_equal Type::Char, Type::Int
    refute_equal Type::Pointer.new(Type::Char), Type::Pointer.new(Type::Int)
  end

  def test_char_equals_itself
    assert_equal Type::Char, Type::Char
    assert_equal Type::Pointer.new(Type::Char), Type::Pointer.new(Type::Char)
  end

  def test_int_renders_as_int
    assert_equal "int", Type::Int.to_s
  end

  def test_pointer_to_int_renders_with_single_star
    assert_equal "int *", Type::Pointer.new(Type::Int).to_s
  end

  def test_pointer_to_pointer_renders_with_stacked_stars
    assert_equal "int **", Type::Pointer.new(Type::Pointer.new(Type::Int)).to_s
  end

  def test_int_equals_itself
    assert_equal Type::Int, Type::Int
  end

  def test_pointers_with_same_target_are_equal
    assert_equal Type::Pointer.new(Type::Int), Type::Pointer.new(Type::Int)
  end

  def test_int_and_pointer_are_not_equal
    refute_equal Type::Int, Type::Pointer.new(Type::Int)
    refute_equal Type::Pointer.new(Type::Int), Type::Int
  end

  def test_pointers_with_different_depth_are_not_equal
    single = Type::Pointer.new(Type::Int)
    double = Type::Pointer.new(Type::Pointer.new(Type::Int))
    refute_equal single, double
  end

  def test_type_sizes
    assert_equal 4, Type::Int.size
    assert_equal 8, Type::Pointer.new(Type::Int).size
    assert_equal 8, Type::Pointer.new(Type::Pointer.new(Type::Int)).size
  end

  def test_array_predicates
    arr = Type::Array.new(Type::Int, 10)
    assert_predicate arr, :array?
    refute_predicate arr, :int?
    refute_predicate arr, :pointer?
  end

  def test_int_and_pointer_are_not_arrays
    refute_predicate Type::Int, :array?
    refute_predicate Type::Pointer.new(Type::Int), :array?
  end

  def test_array_size_is_element_size_times_length
    assert_equal 40, Type::Array.new(Type::Int, 10).size
    assert_equal 32, Type::Array.new(Type::Pointer.new(Type::Int), 4).size
  end

  def test_array_renders_with_bracketed_length
    assert_equal "int [10]", Type::Array.new(Type::Int, 10).to_s
    assert_equal "int * [4]", Type::Array.new(Type::Pointer.new(Type::Int), 4).to_s
  end

  def test_arrays_with_same_element_and_length_are_equal
    assert_equal Type::Array.new(Type::Int, 3), Type::Array.new(Type::Int, 3)
  end

  def test_arrays_differing_in_length_are_not_equal
    refute_equal Type::Array.new(Type::Int, 3), Type::Array.new(Type::Int, 4)
  end

  def test_void_predicates
    assert_predicate Type::Void, :void?
    refute_predicate Type::Void, :int?
    refute_predicate Type::Void, :char?
    refute_predicate Type::Void, :pointer?
    refute_predicate Type::Void, :array?
    refute_predicate Type::Void, :arithmetic?
  end

  def test_other_types_are_not_void
    refute_predicate Type::Int, :void?
    refute_predicate Type::Char, :void?
    refute_predicate Type::Pointer.new(Type::Int), :void?
    refute_predicate Type::Array.new(Type::Int, 3), :void?
  end

  def test_void_renders_as_void
    assert_equal "void", Type::Void.to_s
  end

  def test_void_equals_itself
    assert_equal Type::Void, Type::Void
  end

  def test_pointer_to_void_renders_with_single_star
    assert_equal "void *", Type::Pointer.new(Type::Void).to_s
  end

  def test_pointer_to_pointer_to_void_renders_with_stacked_stars
    assert_equal "void **", Type::Pointer.new(Type::Pointer.new(Type::Void)).to_s
  end

  def test_pointer_to_void_size_is_eight
    assert_equal 8, Type::Pointer.new(Type::Void).size
  end

  # --- alignment ----------------------------------------------------------

  def test_scalar_alignments
    assert_equal 4, Type::Int.alignment
    assert_equal 1, Type::Char.alignment
    assert_equal 8, Type::Pointer.new(Type::Int).alignment
    assert_equal 8, Type::Pointer.new(Type::Char).alignment
  end

  def test_array_alignment_is_its_elements
    assert_equal 4, Type::Array.new(Type::Int, 10).alignment
    assert_equal 1, Type::Array.new(Type::Char, 5).alignment
    assert_equal 8, Type::Array.new(Type::Pointer.new(Type::Int), 3).alignment
  end

  # --- structs ------------------------------------------------------------

  # Builds and lays out a struct from [name, type] pairs, defaulting to an
  # anonymous tag since layout does not depend on the tag.
  def struct(members, tag: nil)
    type = Type::StructType.new(tag)
    type.define(members)
    type
  end

  def test_struct_predicates
    type = struct([["x", Type::Int]])
    assert_predicate type, :struct?
    refute_predicate type, :int?
    refute_predicate type, :pointer?
    refute_predicate type, :array?
    refute_predicate type, :arithmetic?
    refute_predicate type, :void?
  end

  def test_other_types_are_not_structs
    refute_predicate Type::Int, :struct?
    refute_predicate Type::Char, :struct?
    refute_predicate Type::Void, :struct?
    refute_predicate Type::Pointer.new(Type::Int), :struct?
    refute_predicate Type::Array.new(Type::Int, 3), :struct?
  end

  def test_struct_is_incomplete_until_defined
    type = Type::StructType.new("point")
    refute_predicate type, :complete?
    assert_raises(RuntimeError) { type.size }
    assert_raises(RuntimeError) { type.alignment }
  end

  def test_struct_becomes_complete_after_define
    type = struct([["x", Type::Int]])
    assert_predicate type, :complete?
  end

  def test_struct_member_lookup
    type = struct([["x", Type::Int], ["y", Type::Char]])
    assert_equal 0, type.member("x").offset
    assert_equal Type::Int, type.member("x").type
    assert_equal Type::Char, type.member("y").type
    assert_nil type.member("z")
  end

  # {int; int;}: two 4-byte ints back to back, size 8, alignment 4.
  def test_layout_two_ints
    type = struct([["x", Type::Int], ["y", Type::Int]])
    assert_equal [0, 4], type.members.map(&:offset)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  # {char; int;}: the int must land on a 4-byte boundary, so 3 bytes of
  # padding follow the char; size 8, alignment 4.
  def test_layout_char_then_int_pads_to_eight
    type = struct([["c", Type::Char], ["i", Type::Int]])
    assert_equal [0, 4], type.members.map(&:offset)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  # {char; char;}: no padding needed; size 2, alignment 1.
  def test_layout_two_chars
    type = struct([["a", Type::Char], ["b", Type::Char]])
    assert_equal [0, 1], type.members.map(&:offset)
    assert_equal 2, type.size
    assert_equal 1, type.alignment
  end

  # {int; char;}: the trailing char sits at offset 4, but the whole struct
  # rounds up to the 4-byte alignment, so size 8 (not 5).
  def test_layout_int_then_char_rounds_up
    type = struct([["i", Type::Int], ["c", Type::Char]])
    assert_equal [0, 4], type.members.map(&:offset)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  # A pointer forces 8-byte alignment: {char; int *;} pads to offset 8 and is
  # 16 bytes, aligned to 8.
  def test_layout_char_then_pointer
    type = struct([["c", Type::Char], ["p", Type::Pointer.new(Type::Int)]])
    assert_equal [0, 8], type.members.map(&:offset)
    assert_equal 16, type.size
    assert_equal 8, type.alignment
  end

  # An array member occupies element-size * length and aligns like its element:
  # {char; int[3]; char;} -> the array at 4 (size 12), the last char at 16, the
  # struct rounded to 20 at alignment 4.
  def test_layout_with_array_member
    type = struct([["c", Type::Char], ["a", Type::Array.new(Type::Int, 3)], ["d", Type::Char]])
    assert_equal [0, 4, 16], type.members.map(&:offset)
    assert_equal 20, type.size
    assert_equal 4, type.alignment
  end

  # A nested struct contributes both its size and its alignment: {char;
  # struct{int;char;}; int;}. The inner struct is 8 bytes aligned to 4, so it
  # lands at 4; the trailing int at 12; total 16.
  def test_layout_with_nested_struct_member
    inner = struct([["v", Type::Int], ["c", Type::Char]])
    type = struct([["b", Type::Char], ["in", inner], ["w", Type::Int]])
    assert_equal [0, 4, 12], type.members.map(&:offset)
    assert_equal 16, type.size
    assert_equal 4, type.alignment
  end

  # An array of a struct keeps each element aligned: {struct{int;char;}[2];
  # char;}. The 8-byte element is aligned to 4, the array is 16 bytes at 0, the
  # trailing char at 16, total 20.
  def test_layout_with_array_of_struct_member
    inner = struct([["v", Type::Int], ["c", Type::Char]])
    type = struct([["arr", Type::Array.new(inner, 2)], ["z", Type::Char]])
    assert_equal [0, 16], type.members.map(&:offset)
    assert_equal 20, type.size
    assert_equal 4, type.alignment
  end

  def test_array_of_struct_size_and_alignment
    inner = struct([["v", Type::Int], ["c", Type::Char]])
    array = Type::Array.new(inner, 3)
    assert_equal 24, array.size
    assert_equal 4, array.alignment
  end

  # Structs compare by identity: the same object is equal to itself but not to
  # a structurally identical, separately built struct.
  def test_struct_equality_is_by_identity
    one = struct([["x", Type::Int]], tag: "point")
    assert_equal one, one
    two = struct([["x", Type::Int]], tag: "point")
    refute_equal one, two
    refute_equal one, Type::Int
  end

  # A self-referential struct renders and compares without recursing on its
  # members (the pointer member points back at the struct itself).
  def test_self_referential_struct_does_not_loop
    node = Type::StructType.new("node")
    node.define([["v", Type::Int], ["next", Type::Pointer.new(node)]])
    assert_equal "struct node", node.to_s
    assert_equal "struct node *", Type::Pointer.new(node).to_s
    assert_equal node, node
    assert_same node, node.member("next").type.target
  end

  def test_tagged_struct_renders_with_tag
    assert_equal "struct point", Type::StructType.new("point").to_s
  end

  def test_anonymous_struct_renders_without_tag
    assert_equal "struct <anonymous>", Type::StructType.new(nil).to_s
  end

  def test_pointer_to_struct_renders_with_star
    assert_equal "struct point *", Type::Pointer.new(Type::StructType.new("point")).to_s
  end
end
