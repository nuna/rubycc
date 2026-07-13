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

  def test_int128_predicates_and_signedness
    assert_predicate Type::Int128, :integer?
    assert_predicate Type::Int128, :arithmetic?
    assert_predicate Type::Int128, :signed?
    refute_predicate Type::Int128, :unsigned?
    refute_predicate Type::Int128, :int?
    refute_predicate Type::Int128, :pointer?
    assert_predicate Type::UInt128, :integer?
    assert_predicate Type::UInt128, :unsigned?
    refute_predicate Type::UInt128, :signed?
  end

  def test_int128_size_and_alignment
    assert_equal 16, Type::Int128.size
    assert_equal 16, Type::Int128.alignment
    assert_equal 16, Type::UInt128.size
    assert_equal 16, Type::UInt128.alignment
  end

  def test_int128_rendering
    assert_equal "__int128", Type::Int128.to_s
    assert_equal "unsigned __int128", Type::UInt128.to_s
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

  # {char; __int128;}: the 16-byte-aligned __int128 lands at offset 16, so 15
  # bytes of padding follow the char; size 32, alignment 16.
  def test_layout_char_then_int128
    type = struct([["c", Type::Char], ["x", Type::Int128]])
    assert_equal [0, 16], type.members.map(&:offset)
    assert_equal 32, type.size
    assert_equal 16, type.alignment
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

  # --- bit-field layout (Step 28 Phase C2) --------------------------------
  # Every size/alignment below was checked against gcc (sizeof/_Alignof).

  # {int a:3; int b:5;}: both fit in one 4-byte int unit; size 4, alignment 4.
  def test_bitfield_two_share_one_unit
    type = struct([["a", Type::Int, 3], ["b", Type::Int, 5]])
    assert_equal [0, 3], type.members.map(&:bit_offset)
    assert_equal [3, 5], type.members.map(&:bit_width)
    assert_equal 4, type.size
    assert_equal 4, type.alignment
  end

  # {int a:30; int b:5;}: b would straddle the 32-bit unit boundary, so it moves
  # to the next int unit; size 8, alignment 4.
  def test_bitfield_straddle_advances_to_next_unit
    type = struct([["a", Type::Int, 30], ["b", Type::Int, 5]])
    assert_equal [0, 32], type.members.map(&:bit_offset)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  # {char a:3; char b:6;}: b straddles the byte, so it moves to the next byte;
  # size 2, alignment 1 (char bit-fields do not widen alignment past char).
  def test_bitfield_char_straddles_byte
    type = struct([["a", Type::Char, 3], ["b", Type::Char, 6]])
    assert_equal [0, 8], type.members.map(&:bit_offset)
    assert_equal 2, type.size
    assert_equal 1, type.alignment
  end

  # {int a:5; int :0; int b:3;}: the unnamed :0 forces the cursor to the next
  # int unit, so b starts at bit 32; size 8, alignment 4.
  def test_bitfield_zero_width_forces_next_unit
    type = struct([["a", Type::Int, 5], [nil, Type::Int, 0], ["b", Type::Int, 3]])
    # The :0 declares no member, so only a and b are recorded.
    assert_equal %w[a b], type.members.map(&:name)
    assert_equal [0, 32], type.members.map(&:bit_offset)
    assert_equal 8, type.size
    assert_equal 4, type.alignment
  end

  # {int :32; int :32;}: two unnamed bit-fields fill 8 bytes but, being unnamed,
  # contribute no alignment, so the struct is 8 bytes at alignment 1 (the
  # struct-timex padding pattern).
  def test_bitfield_unnamed_fill_without_alignment
    type = struct([[nil, Type::Int, 32], [nil, Type::Int, 32]])
    assert_empty type.members
    assert_equal 8, type.size
    assert_equal 1, type.alignment
  end

  # {short a:9; char b;}: a occupies a 2-byte short unit, the plain char b lands
  # at the next byte (offset 2); size 4, alignment 2.
  def test_bitfield_then_plain_member
    type = struct([["a", Type::Short, 9], ["b", Type::Char]])
    assert_equal [0, 2], type.members.map(&:offset)
    assert_equal 9, type.member("a").bit_width
    assert_nil type.member("b").bit_width
    assert_equal 4, type.size
    assert_equal 2, type.alignment
  end

  # {char c; int a:1;}: c at byte 0; the int bit-field fits in the first 32-bit
  # unit at bit 8 without straddling; a named int field raises alignment to 4.
  def test_plain_member_then_bitfield
    type = struct([["c", Type::Char], ["a", Type::Int, 1]])
    assert_equal 8, type.member("a").bit_offset
    assert_equal 4, type.size
    assert_equal 4, type.alignment
  end

  # {long a:40; long b:40;}: b straddles the 64-bit unit, so it starts at bit 64;
  # size 16, alignment 8.
  def test_bitfield_long_based
    type = struct([["a", Type::Long, 40], ["b", Type::Long, 40]])
    assert_equal [0, 64], type.members.map(&:bit_offset)
    assert_equal 16, type.size
    assert_equal 8, type.alignment
  end

  # A named char bit-field alone is a 1-byte struct at alignment 1.
  def test_bitfield_single_char_named
    type = struct([["a", Type::Char, 3]])
    assert_equal 1, type.size
    assert_equal 1, type.alignment
  end

  # A union of bit-fields overlays each at bit 0; its size is the widest member's
  # byte span and its alignment the widest named field's type alignment.
  def test_union_bitfields
    type = Type::StructType.new(nil, kind: :union)
    type.define([["a", Type::Char, 3], ["b", Type::Int, 20]])
    assert_equal [0, 0], type.members.map(&:bit_offset)
    assert_equal 4, type.size
    assert_equal 4, type.alignment
  end

  # --- packed / aligned layout attributes (Step 28 Phase A) ----------------

  # Builds and lays out a struct with the GNU __attribute__ layout overrides.
  def struct_with(members, packed: false, aligned: nil)
    type = Type::StructType.new(nil)
    type.define(members, packed: packed, aligned: aligned)
    type
  end

  # __attribute__((packed)) {char; int;}: the int lands right after the char at
  # offset 1 (no padding), the struct is 5 bytes with alignment 1 (no tail pad).
  def test_packed_layout_removes_all_padding
    type = struct_with([["c", Type::Char], ["i", Type::Int]], packed: true)
    assert_equal [0, 1], type.members.map(&:offset)
    assert_equal 5, type.size
    assert_equal 1, type.alignment
  end

  # __attribute__((aligned(16))) {char;}: the natural size/alignment (1) is
  # raised to 16, and the size rounds up to that final alignment.
  def test_aligned_layout_raises_alignment_and_rounds_size
    type = struct_with([["c", Type::Char]], aligned: 16)
    assert_equal 16, type.alignment
    assert_equal 16, type.size
  end

  # aligned never lowers a struct's natural alignment: aligned(2) on a struct
  # whose int member already forces alignment 4 keeps 4.
  def test_aligned_below_natural_alignment_has_no_effect
    type = struct_with([["i", Type::Int]], aligned: 2)
    assert_equal 4, type.alignment
    assert_equal 4, type.size
  end

  # packed + aligned(4) {char; char; char;}: members stay packed (offsets 0,1,2)
  # while the struct takes alignment 4 and rounds its size up to 4.
  def test_packed_and_aligned_combine
    type = struct_with([["a", Type::Char], ["b", Type::Char], ["c", Type::Char]], packed: true, aligned: 4)
    assert_equal [0, 1, 2], type.members.map(&:offset)
    assert_equal 4, type.size
    assert_equal 4, type.alignment
  end

  # A packed union keeps every member at offset 0 but drops the aggregate to a
  # 1-byte boundary: {int | char} packed is 4 bytes (the widest member) at
  # alignment 1.
  def test_packed_union_alignment_is_one
    type = Type::StructType.new(nil, kind: :union)
    type.define([["i", Type::Int], ["c", Type::Char]], packed: true)
    assert_equal [0, 0], type.members.map(&:offset)
    assert_equal 4, type.size
    assert_equal 1, type.alignment
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

  def test_function_type_predicate
    func = Type::FunctionType.new(Type::Int, [Type::Int], false)
    assert_predicate func, :function?
    refute_predicate func, :pointer?
    refute_predicate func, :integer?
    refute_predicate func, :array?
    refute_predicate func, :struct?
  end

  def test_only_function_type_is_function
    refute_predicate Type::Int, :function?
    refute_predicate Type::Void, :function?
    refute_predicate Type::Pointer.new(Type::Int), :function?
    refute_predicate Type::Array.new(Type::Int, 3), :function?
    refute_predicate Type::StructType.new("s"), :function?
  end

  def test_function_type_has_no_size_or_alignment
    func = Type::FunctionType.new(Type::Int, [Type::Int], false)
    assert_raises(RuntimeError) { func.size }
    assert_raises(RuntimeError) { func.alignment }
  end

  def test_function_type_equality_is_by_value
    a = Type::FunctionType.new(Type::Int, [Type::Int, Type::Pointer.new(Type::Char)], false)
    b = Type::FunctionType.new(Type::Int, [Type::Int, Type::Pointer.new(Type::Char)], false)
    c = Type::FunctionType.new(Type::Int, [Type::Int], false)
    assert_equal a, b
    refute_equal a, c
  end

  def test_function_type_renders_like_a_c_declarator
    assert_equal "int (int, char *)",
                 Type::FunctionType.new(Type::Int, [Type::Int, Type::Pointer.new(Type::Char)], false).to_s
    # An empty parameter list renders "void".
    assert_equal "void (void)", Type::FunctionType.new(Type::Void, [], false).to_s
  end

  def test_function_pointer_renders_with_parenthesized_star
    func = Type::FunctionType.new(Type::Int, [Type::Int], false)
    assert_equal "int (*)(int)", Type::Pointer.new(func).to_s
  end

  def test_variadic_function_type_renders_with_ellipsis
    func = Type::FunctionType.new(Type::Int, [Type::Pointer.new(Type::Char)], true)
    assert_equal "int (char *, ...)", func.to_s
  end

  def test_variadic_flag_participates_in_equality
    fixed = Type::FunctionType.new(Type::Int, [Type::Pointer.new(Type::Char)], false)
    variadic = Type::FunctionType.new(Type::Int, [Type::Pointer.new(Type::Char)], true)
    same_variadic = Type::FunctionType.new(Type::Int, [Type::Pointer.new(Type::Char)], true)
    refute_equal fixed, variadic
    assert_equal variadic, same_variadic
  end

  def test_array_pointer_renders_with_parenthesized_star
    assert_equal "int (*)[3]", Type::Pointer.new(Type::Array.new(Type::Int, 3)).to_s
  end

  # Step 23 Phase B: the System V __va_list_tag has the ABI-fixed layout the C
  # library agrees on — a 32-bit gp_offset/fp_offset then two 8-byte pointers,
  # 24 bytes total, 8-byte aligned.
  def test_va_list_tag_has_the_sysv_layout
    tag = Type::VaListTag
    assert_predicate tag, :struct?
    assert_equal 24, tag.size
    assert_equal 8, tag.alignment
    assert_equal 0, tag.member("gp_offset").offset
    assert_equal Type::UInt, tag.member("gp_offset").type
    assert_equal 4, tag.member("fp_offset").offset
    assert_equal 8, tag.member("overflow_arg_area").offset
    assert_equal Type::Pointer.new(Type::Void), tag.member("overflow_arg_area").type
    assert_equal 16, tag.member("reg_save_area").offset
  end

  # __builtin_va_list is a one-element array of that tag, so it reserves 24
  # bytes but decays to a __va_list_tag * wherever an array does.
  def test_builtin_va_list_is_a_one_element_tag_array
    assert_equal Type::Array.new(Type::VaListTag, 1), Type::BuiltinVaList
    assert_equal 24, Type::BuiltinVaList.size
    assert_equal Type::VaListTag, Type::BuiltinVaList.element
  end

  # Step 24 Phase A: the floating types.
  def test_float_predicates_and_size
    assert_predicate Type::Float, :float?
    assert_predicate Type::Float, :arithmetic?
    refute_predicate Type::Float, :integer?
    refute_predicate Type::Float, :pointer?
    assert_equal 4, Type::Float.size
    assert_equal 4, Type::Float.alignment
    assert_equal "float", Type::Float.to_s
  end

  def test_double_predicates_and_size
    assert_predicate Type::Double, :float?
    assert_predicate Type::Double, :arithmetic?
    refute_predicate Type::Double, :integer?
    assert_equal 8, Type::Double.size
    assert_equal 8, Type::Double.alignment
    assert_equal "double", Type::Double.to_s
  end

  def test_float_and_double_are_distinct_types
    refute_equal Type::Float, Type::Double
    assert_equal Type::Float, Type::Float
  end

  def test_integer_and_pointer_types_are_not_float
    refute_predicate Type::Int, :float?
    refute_predicate Type::Long, :float?
    refute_predicate Type::Pointer.new(Type::Double), :float?
    refute_predicate Type::VaListTag, :float?
  end

  # An incomplete enum (a forward-referenced tag before its "{...}") answers
  # every category predicate false and raises for any measurement, exactly like
  # an incomplete struct.
  def test_incomplete_enum_predicates
    type = Type::EnumType.new("efoo")
    refute_predicate type, :complete?
    refute_predicate type, :integer?
    refute_predicate type, :arithmetic?
    assert_raises(RuntimeError) { type.size }
    assert_raises(RuntimeError) { type.alignment }
    assert_raises(RuntimeError) { type.signed? }
  end

  # Two references to the same still-undefined tag share a type; a completed one
  # is not equal to an incomplete one of the same tag.
  def test_incomplete_enums_with_same_tag_are_equal
    assert_equal Type::EnumType.new("efoo"), Type::EnumType.new("efoo")
    refute_equal Type::EnumType.new("efoo"), Type::EnumType.new("ebar")
  end

  # Completing an enum in place makes it answer as the `int` an enum object is:
  # measurable, integer, signed, and equal to Type::Int in both directions (the
  # identity a function-type compatibility check needs).
  def test_completed_enum_behaves_as_int
    type = Type::EnumType.new("efoo")
    assert_same type, type.complete!
    assert_predicate type, :complete?
    assert_predicate type, :integer?
    assert_predicate type, :arithmetic?
    assert_predicate type, :signed?
    refute_predicate type, :unsigned?
    assert_equal 4, type.size
    assert_equal 4, type.alignment
    assert_equal Type::Int, type
    assert_equal type, Type::Int
  end

  # A completed enum is not equal to a still-incomplete one, nor to a
  # non-`int` integer type (an enum's underlying type here is `int`, not long).
  def test_completed_enum_equality_is_narrow
    complete = Type::EnumType.new("efoo").complete!
    refute_equal complete, Type::EnumType.new("efoo")
    refute_equal Type::Long, complete
    refute_equal Type::UInt, complete
  end
end
