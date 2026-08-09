# frozen_string_literal: true

require_relative "test_helper"
require "rubycc/rmake/rmake"
require "open3"
require "tmpdir"
require "fileutils"
require "set"

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
# Skip guards: developer runs skip when `make` is absent. Ruby's installation
# paths are overridden with logical, scratch-local paths for both make and
# rmake, so a collecting machine's absolute header paths are never a skip
# reason. A single fixture may still skip when `make -n` fails for an unrelated
# reason outside the scratch directory; CI turns that unexpected failure into a
# test failure.
class TestRmakeGolden < Minitest::Test
  Makefile = Rubycc::Rmake::Makefile
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)

  # The fixtures are intentionally kept as the Makefiles emitted by mkmf. Their
  # Ruby installation paths vary by collecting machine, so the comparison uses
  # the same explicit, relative values for GNU make and rmake. Keeping these
  # paths relative also lets the prerequisite stubs live entirely in +dir+.
  LOGICAL_RUBY_HEADER_ROOT = ".rubycc/ruby-headers"
  LOGICAL_RUBY_INSTALL_ROOT = ".rubycc/ruby-install"

  MAKE_AVAILABLE = system("make", "--version", out: File::NULL, err: File::NULL)

  # Cap the stub loop so a persistently-failing make can never spin forever.
  MAX_STUB_ROUNDS = 64

  Dir.glob(File.join(FIXTURES_ROOT, "*-*/*/Makefile")).sort.each do |makefile_path|
    ext = File.basename(File.dirname(makefile_path))
    gem_dir = File.basename(File.dirname(File.dirname(makefile_path)))
    name = "#{gem_dir}_#{ext}".gsub(/[^a-z0-9]+/i, "_")

    define_method(:"test_plan_matches_make_n_#{name}") do
      skip_unless_make

      compare_against_make(makefile_path)
    end
  end

  def test_ruby_header_paths_do_not_require_collecting_machine
    skip_unless_make

    fixture_paths.each do |path|
      Dir.mktmpdir do |dir|
        # Make the fixture's original paths certainly unavailable. The test is
        # deliberately independent of whether this host happens to have the
        # collector's Ruby installation.
        missing_root = File.join(dir, "missing-ruby-install")
        text = File.read(path)
        header_dir = text[/^topdir = \S+\/([^\/\s]+)$/, 1]
        arch = text[/^arch_hdrdir = \S+\/([^\/\s]+)$/, 1]
        refute_nil header_dir, "fixture has no Ruby header directory in #{path}"
        refute_nil arch, "fixture has no Ruby architecture header directory in #{path}"
        text = text.sub(/^topdir = \S+$/, "topdir = #{missing_root}/include/#{header_dir}")
                     .sub(/^arch_hdrdir = \S+$/, "arch_hdrdir = #{missing_root}/include/#{header_dir}/#{arch}")

        File.write(File.join(dir, "Makefile"), text)
        overrides = ruby_path_overrides(text)
        mk = Makefile.parse(text, dir: dir, overrides: overrides)
        allowed_missing = stub_prerequisites(mk, dir)

        refute_nil run_make_n(dir, overrides, allowed_missing: allowed_missing),
                   "make -n must not depend on the fixture collector's Ruby header path: #{path}"
      end
    end
  end

  private

  def compare_against_make(makefile_path)
    Dir.mktmpdir do |dir|
      text = File.read(makefile_path)
      File.write(File.join(dir, "Makefile"), text)
      overrides = ruby_path_overrides(text)
      mk = Makefile.parse(text, dir: dir, overrides: overrides)
      allowed_missing = stub_prerequisites(mk, dir)

      make_lines = run_make_n(dir, overrides, allowed_missing: allowed_missing)
      if make_lines.nil?
        message = "make -n could not run for #{File.basename(File.dirname(makefile_path))}"
        strict_ci? ? flunk(message) : skip(message)
      end

      plan_lines = normalize(mk.plan.command_lines)

      assert_equal make_lines, plan_lines,
                   "rmake plan diverged from `make -n` for #{makefile_path}"
    end
  end

  # Create the source and header prerequisites so a full build is planned. The
  # Ruby header variables have logical relative values from +ruby_path_overrides+
  # and are therefore stubbed inside the scratch directory too.
  def stub_prerequisites(mk, dir)
    sources = mk.variable_value("SRCS").split
    objects = mk.variable_value("OBJS").split.map { |o| o.sub(/\.o\z/, ".c") }
    headers = mk.variable_value("HDRS").split + mk.variable_value("ruby_headers").split

    allowed = Set.new
    (sources + objects + headers).each do |rel|
      next if rel.start_with?("/")

      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
      allowed << File.expand_path(path)
    end
    allowed
  end

  # Run `make -n all`, retrying while it only fails for a missing prerequisite we
  # can legitimately create inside the scratch directory. Returns the normalized
  # command lines, or nil when make cannot be made to succeed here.
  def run_make_n(dir, overrides, allowed_missing: Set.new)
    override_args = overrides.map { |name, value| "#{name}=#{value}" }

    MAX_STUB_ROUNDS.times do
      out, err, status = Open3.capture3("make", "-n", "-f", "Makefile", "all", *override_args, chdir: dir)
      return normalize(out.lines) if status.success?

      missing = err[/No rule to make target ['`]([^'`]+)'/, 1]
      return nil if missing.nil?

      full = File.expand_path(missing, dir)
      # Only materialize a prerequisite that the fixture declared and that was
      # already identified by stub_prerequisites. Unknown missing targets are
      # fixture errors, not a reason to synthesize more files.
      return nil unless allowed_missing.include?(full)

      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.touch(full)
    end
    nil
  end

  def ruby_path_overrides(text)
    arch = text[/^arch_hdrdir = \S+\/([^\/\s]+)$/, 1]
    raise "fixture has no Ruby architecture header path" if arch.nil?

    {
      "topdir" => LOGICAL_RUBY_HEADER_ROOT,
      "arch_hdrdir" => File.join(LOGICAL_RUBY_HEADER_ROOT, arch),
      "prefix" => LOGICAL_RUBY_INSTALL_ROOT
    }.freeze
  end

  def fixture_path
    fixture_paths.first
  end

  def fixture_paths
    Dir.glob(File.join(FIXTURES_ROOT, "*-*/*/Makefile")).sort
  end

  def skip_unless_make
    return if MAKE_AVAILABLE

    message = "make is not available"
    if strict_ci?
      raise Minitest::Assertion, message
    else
      skip message
    end
  end

  def strict_ci?
    ENV["CI"] == "true" || %w[1 true yes].include?(ENV.fetch("RMAKE_ACCEPTANCE_STRICT", "").downcase)
  end

  def normalize(lines)
    lines.map(&:rstrip).reject(&:empty?)
  end
end
