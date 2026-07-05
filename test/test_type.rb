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
end
