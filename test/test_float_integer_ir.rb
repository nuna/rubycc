# frozen_string_literal: true

require_relative "test_helper"

# Verifies the target-independent IR contract at the generator boundary. The
# backends are responsible for an ISA-specific instruction width; the generator
# must retain the C type's width and signedness in :itof/:ftoi descriptors.
class TestFloatIntegerIR < Minitest::Test
  def test_unsigned_int_descriptor_keeps_width_four_for_both_targets
    %w[x86_64 aarch64].each do |target|
      instructions = generate_ir("int f(double d) { return (unsigned int)d; }", target: target).functions
        .flat_map(&:insts)
        .select { |instruction| instruction.op == :ftoi }

      assert_equal [[4, false]], instructions.map(&:b), target
    end
  end

  def test_unsigned_long_float_to_integer_uses_signed_synthesis_primitives
    instructions = generate_ir("unsigned long f(double d) { return (unsigned long)d; }", target: "x86_64").functions
      .flat_map(&:insts)
      .select { |instruction| instruction.op == :ftoi }

    assert_operator instructions.count { |instruction| instruction.b == [8, true] }, :>=, 2
    refute_includes instructions.map(&:b), [8, false]
  end

  private

  def generate_ir(source, target:)
    # The source contains no includes, so the target's bundled preprocessor
    # configuration is enough to exercise the same parser/generator path the
    # compiler uses without depending on a host header directory.
    entry = Rubycc::Compiler::TARGETS.fetch(target)
    plain_char = Rubycc::Type.plain_char(entry[:char_signed])
    tokens = Rubycc::Preprocess::Preprocessor.new(
      char_unsigned: plain_char.unsigned?,
      arch_macros: entry[:arch_macros],
      libc_arch: entry[:libc_arch],
      libc: Rubycc::Preprocess::Preprocessor.host_libc
    ).run(source, filename: "float-integer.c")
    ast = Rubycc::Front::Parser.new(
      tokens,
      plain_char: plain_char,
      unnamed_bitfields_align: entry[:unnamed_bitfields_align],
      builtin_va_list: entry[:convention].va_list_type
    ).parse
    Rubycc::IR::Generator.new(
      plain_char: plain_char,
      convention: entry[:convention]
    ).generate(ast)
  end
end
