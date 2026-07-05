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
end
