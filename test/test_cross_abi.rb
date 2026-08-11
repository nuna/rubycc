# frozen_string_literal: true

require_relative "test_helper"

# Step 25 Phase C: every previous struct-ABI test builds both sides of a call
# with the same compiler, so a self-consistent but gcc-incompatible layout
# would still pass. Linking a gcc-built translation unit against a
# rubycc-built one into a single executable forces both sides to agree on the
# target psABI, not merely on each other. The same generated layouts run on
# x86_64 and aarch64; the latter uses the cross gcc and qemu path so this test
# does not require an aarch64 Ruby runtime.
class TestCrossAbi < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  SEED = 0x5225C
  LAYOUT_COUNT = 40
  # Eight leading integer parameters reach the last AAPCS64 integer register;
  # the same cases also cross System V AMD64's six-register boundary.
  MAX_LEADING_INT_COUNT = 8
  MEMBER_KINDS = %i[char short int long float double array nested].freeze

  def test_gcc_caller_with_rubycc_callee_matches_gcc_oracle
    assert_callee_compatibility(:x86_64)
  end

  def test_gcc_caller_with_rubycc_callee_matches_gcc_oracle_aarch64
    assert_callee_compatibility(:aarch64)
  end

  def test_rubycc_caller_with_gcc_callee_matches_gcc_oracle
    assert_caller_compatibility(:x86_64)
  end

  def test_rubycc_caller_with_gcc_callee_matches_gcc_oracle_aarch64
    assert_caller_compatibility(:aarch64)
  end

  private

  # gcc building both sides is the oracle; swapping one side for rubycc's
  # object must not change a single printed member. The target is an explicit
  # parameter rather than a second copy of this test, so adding another
  # machine keeps the generated ABI cases shared across all backends.
  def assert_callee_compatibility(target)
    skip_unless_x86_64_host if target == :x86_64
    skip_unless_aarch64_toolchain if target == :aarch64

    oracle = link_units_and_run_for(target, [[callee_source, :gcc], [caller_source, :gcc]])
    cross = link_units_and_run_for(target, [[callee_source, :rubycc], [caller_source, :gcc]])
    assert_equal oracle, cross, "#{target}: gcc caller/rubycc callee output mismatch"
  end

  def assert_caller_compatibility(target)
    skip_unless_x86_64_host if target == :x86_64
    skip_unless_aarch64_toolchain if target == :aarch64

    oracle = link_units_and_run_for(target, [[callee_source, :gcc], [caller_source, :gcc]])
    cross = link_units_and_run_for(target, [[callee_source, :gcc], [caller_source, :rubycc]])
    assert_equal oracle, cross, "#{target}: rubycc caller/gcc callee output mismatch"
  end

  def link_units_and_run_for(target, units)
    case target
    when :x86_64 then link_units_and_run(units)
    when :aarch64 then link_units_and_run_aarch64(units)
    else raise ArgumentError, "unknown ABI target: #{target.inspect}"
    end
  end

  # --- source assembly ------------------------------------------------------

  def callee_source
    @callee_source ||= begin
      bodies = layouts.map { |layout| mangle_definition(layout) }
      "#{common_prefix}\n\n#{bodies.join("\n\n")}\n"
    end
  end

  def caller_source
    @caller_source ||= begin
      lines = ["int printf(const char *, ...);", "", "int main(void) {"]
      lines.concat(layouts.map { |layout| layout_block(layout) })
      lines << "  return 0;"
      lines << "}"
      "#{common_prefix}\n\n#{lines.join("\n")}\n"
    end
  end

  # The struct definitions and mangle() prototypes are byte-identical text in
  # both translation units, exactly as two independently compiled .c files
  # sharing a header would be.
  def common_prefix
    @common_prefix ||= begin
      parts = ["struct Pair { int a; float b; };"]
      parts.concat(layouts.map { |layout| struct_definition(layout) })
      parts.concat(layouts.map { |layout| mangle_prototype(layout) })
      parts.join("\n\n")
    end
  end

  # --- deterministic layout generation ---------------------------------------

  # A single Random instance, seeded once, drives every structural and value
  # choice below in a fixed order, so re-running this test (or this process)
  # always regenerates byte-identical C sources.
  def layouts
    @layouts ||= begin
      rng = Random.new(SEED)
      Array.new(LAYOUT_COUNT) { |index| generate_layout(rng, index) }
    end
  end

  def generate_layout(rng, index)
    member_count = 1 + rng.rand(4)
    members = Array.new(member_count) { MEMBER_KINDS[rng.rand(MEMBER_KINDS.size)] }
    leading_int_count = rng.rand(0..MAX_LEADING_INT_COUNT)
    call_args = Array.new(leading_int_count) { rng.rand(-9..9) }
    initial_values = members.map { |kind| random_initial_value(rng, kind) }

    {
      index: index,
      members: members,
      leading_int_count: leading_int_count,
      call_args: call_args,
      initial_values: initial_values
    }
  end

  def random_initial_value(rng, kind)
    case kind
    when :char
      # Keep well clear of the signed-char wraparound boundary once the
      # mangle body's leading-parameter sum and offset (up to ~68) are added.
      rng.rand(-30..30)
    when :short, :int, :long
      rng.rand(-50..50)
    when :float, :double
      random_quarter(rng, -20.0, 20.0)
    when :array
      Array.new(2) { rng.rand(-50..50) }
    when :nested
      [rng.rand(-50..50), random_quarter(rng, -20.0, 20.0)]
    end
  end

  # A quarter-step value in [min, max] is exactly representable in binary
  # floating point, so %.2f round-trips it without rounding noise.
  def random_quarter(rng, min, max)
    steps = ((max - min) / 0.25).round
    min + (rng.rand(0..steps) * 0.25)
  end

  # --- naming -----------------------------------------------------------------

  def struct_name(layout)
    "S#{layout[:index]}"
  end

  def mangle_name(layout)
    "mangle#{layout[:index]}"
  end

  def member_name(member_index)
    "m#{member_index}"
  end

  # --- struct + prototype text -------------------------------------------------

  def member_declaration(kind, name)
    case kind
    when :char then "char #{name};"
    when :short then "short #{name};"
    when :int then "int #{name};"
    when :long then "long #{name};"
    when :float then "float #{name};"
    when :double then "double #{name};"
    when :array then "int #{name}[2];"
    when :nested then "struct Pair #{name};"
    end
  end

  def struct_definition(layout)
    lines = layout[:members].each_with_index.map do |kind, member_index|
      "  #{member_declaration(kind, member_name(member_index))}"
    end
    "struct #{struct_name(layout)} {\n#{lines.join("\n")}\n};"
  end

  def leading_params(layout)
    Array.new(layout[:leading_int_count]) { |k| "int p#{k}" }
  end

  def mangle_signature(layout)
    params = leading_params(layout) + ["struct #{struct_name(layout)} s"]
    "struct #{struct_name(layout)} #{mangle_name(layout)}(#{params.join(", ")})"
  end

  def mangle_prototype(layout)
    "#{mangle_signature(layout)};"
  end

  # --- mangle() body ------------------------------------------------------------

  def quarter_literal(value, suffix)
    "#{format("%.2f", value)}#{suffix}"
  end

  def leading_param_sum(layout)
    Array.new(layout[:leading_int_count]) { |k| "p#{k}" }.join(" + ")
  end

  # Reading every leading int parameter here is what catches a caller/callee
  # mismatch in register vs. stack argument placement.
  def integer_update_statement(layout, member_index, name)
    offset = layout[:index] + member_index + 1
    sum = leading_param_sum(layout)
    rhs = sum.empty? ? "s.#{name} + #{offset}" : "s.#{name} + #{sum} + #{offset}"
    "  s.#{name} = #{rhs};"
  end

  def float_update_statement(layout, member_index, name, kind)
    offset = layout[:index] + member_index + 1 + 0.25
    suffix = kind == :float ? "f" : ""
    "  s.#{name} = s.#{name} + #{quarter_literal(offset, suffix)};"
  end

  def array_update_statements(layout, member_index, name)
    base = (layout[:index] + member_index + 1) * 10
    Array.new(2) { |k| "  s.#{name}[#{k}] = s.#{name}[#{k}] + #{base + k + 1};" }
  end

  def nested_update_statements(layout, member_index, name)
    base = layout[:index] + member_index + 1
    [
      "  s.#{name}.a = s.#{name}.a + #{base * 10 + 1};",
      "  s.#{name}.b = s.#{name}.b + #{quarter_literal(base + 0.25, "f")};"
    ]
  end

  def mangle_definition(layout)
    statements = []
    layout[:members].each_with_index do |kind, member_index|
      name = member_name(member_index)
      case kind
      when :char, :short, :int, :long
        statements << integer_update_statement(layout, member_index, name)
      when :float, :double
        statements << float_update_statement(layout, member_index, name, kind)
      when :array
        statements.concat(array_update_statements(layout, member_index, name))
      when :nested
        statements.concat(nested_update_statements(layout, member_index, name))
      end
    end
    statements << "  return s;"
    "#{mangle_signature(layout)} {\n#{statements.join("\n")}\n}"
  end

  # --- caller() body --------------------------------------------------------

  def local_init_statements(layout)
    statements = []
    layout[:members].each_with_index do |kind, member_index|
      name = member_name(member_index)
      value = layout[:initial_values][member_index]
      case kind
      when :char, :short, :int, :long
        statements << "  s.#{name} = #{value};"
      when :float
        statements << "  s.#{name} = #{quarter_literal(value, "f")};"
      when :double
        statements << "  s.#{name} = #{quarter_literal(value, "")};"
      when :array
        value.each_with_index { |element, k| statements << "  s.#{name}[#{k}] = #{element};" }
      when :nested
        a, b = value
        statements << "  s.#{name}.a = #{a};"
        statements << "  s.#{name}.b = #{quarter_literal(b, "f")};"
      end
    end
    statements
  end

  def call_statement(layout)
    args = layout[:call_args].map(&:to_s) + ["s"]
    "  struct #{struct_name(layout)} r = #{mangle_name(layout)}(#{args.join(", ")});"
  end

  def print_statements(layout)
    statements = []
    layout[:members].each_with_index do |kind, member_index|
      name = member_name(member_index)
      label = "L#{layout[:index]}.m#{member_index}"
      case kind
      when :char, :short, :int
        statements << "  printf(\"#{label}=%d\\n\", r.#{name});"
      when :long
        statements << "  printf(\"#{label}=%ld\\n\", r.#{name});"
      when :float, :double
        statements << "  printf(\"#{label}=%g\\n\", r.#{name});"
      when :array
        [0, 1].each { |k| statements << "  printf(\"#{label}_#{k}=%d\\n\", r.#{name}[#{k}]);" }
      when :nested
        statements << "  printf(\"#{label}_a=%d\\n\", r.#{name}.a);"
        statements << "  printf(\"#{label}_b=%g\\n\", r.#{name}.b);"
      end
    end
    statements
  end

  def layout_block(layout)
    lines = ["  {", "  struct #{struct_name(layout)} s;"]
    lines.concat(local_init_statements(layout))
    lines << call_statement(layout)
    lines.concat(print_statements(layout))
    lines << "  }"
    lines.join("\n")
  end
end
