# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "open3"
require "tmpdir"
require "fileutils"

# Step 56 (M3 / ROADMAP §6 B1): golden tests that hold rmake's execution plan
# to GNU make's own `make -n` transcript for each real mkmf Makefile under
# test/fixtures/mkmf. For a Makefile we copy it to a scratch directory, create
# the source/header prerequisites so a full build is planned (objects and the
# shared object are left absent, so both tools plan the whole compile+link),
# run `make -n all`, and require rmake's planned command list to equal make's.
#
# Normalization (kept deliberately small): each side's lines are right-stripped
# and blank lines dropped. No other rewriting is needed — rmake and make both
# strip the `@`/`-` recipe prefixes for display, and rmake reproduces make's
# whitespace-preserving variable expansion byte for byte, so the command text
# itself is compared verbatim.
#
# Skip guards: the whole suite skips when `make` is absent. A single fixture
# skips when `make -n` fails for a reason outside the scratch directory — the
# fixtures embed the collecting machine's absolute ruby header paths, which need
# not exist elsewhere; in that case make errors and there is nothing to compare.
class TestRmakeGolden < Minitest::Test
  Makefile = Rubycc::Rmake::Makefile
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)

  MAKE_AVAILABLE = system("make", "--version", out: File::NULL, err: File::NULL)

  # Cap the stub loop so a persistently-failing make can never spin forever.
  MAX_STUB_ROUNDS = 64

  Dir.glob(File.join(FIXTURES_ROOT, "*-*/*/Makefile")).sort.each do |makefile_path|
    ext = File.basename(File.dirname(makefile_path))
    gem_dir = File.basename(File.dirname(File.dirname(makefile_path)))
    name = "#{gem_dir}_#{ext}".gsub(/[^a-z0-9]+/i, "_")

    define_method(:"test_plan_matches_make_n_#{name}") do
      skip "make is not available" unless MAKE_AVAILABLE

      compare_against_make(makefile_path)
    end
  end

  private

  def compare_against_make(makefile_path)
    Dir.mktmpdir do |dir|
      FileUtils.cp(makefile_path, File.join(dir, "Makefile"))
      mk = Makefile.parse(File.read(makefile_path), dir: dir)
      stub_prerequisites(mk, dir)

      make_lines = run_make_n(dir)
      skip "make -n could not run in this environment for #{File.basename(File.dirname(makefile_path))}" if make_lines.nil?

      plan_lines = normalize(mk.plan.command_lines)

      assert_equal make_lines, plan_lines,
                   "rmake plan diverged from `make -n` for #{makefile_path}"
    end
  end

  # Create the source and header prerequisites so a full build is planned. Only
  # files inside the scratch directory are created; absolute prerequisites (the
  # ruby headers baked into the fixture) are left to the environment.
  def stub_prerequisites(mk, dir)
    sources = mk.variable_value("SRCS").split
    objects = mk.variable_value("OBJS").split.map { |o| o.sub(/\.o\z/, ".c") }
    headers = mk.variable_value("HDRS").split

    (sources + objects + headers).each do |rel|
      next if rel.start_with?("/")

      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
    end
  end

  # Run `make -n all`, retrying while it only fails for a missing prerequisite we
  # can legitimately create inside the scratch directory. Returns the normalized
  # command lines, or nil when make cannot be made to succeed here.
  def run_make_n(dir)
    MAX_STUB_ROUNDS.times do
      out, err, status = Open3.capture3("make", "-n", "-f", "Makefile", "all", chdir: dir)
      return normalize(out.lines) if status.success?

      missing = err[/No rule to make target ['`]([^'`]+)'/, 1]
      return nil if missing.nil?

      full = File.expand_path(missing, dir)
      # Refuse to touch anything outside the scratch directory.
      return nil unless full.start_with?(dir + File::SEPARATOR)

      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.touch(full)
    end
    nil
  end

  def normalize(lines)
    lines.map(&:rstrip).reject(&:empty?)
  end
end
