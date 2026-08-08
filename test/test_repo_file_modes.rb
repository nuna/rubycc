# frozen_string_literal: true

require_relative "test_helper"

# The executable bit as *git records it*, not as the working tree shows it.
#
# This checkout carries `core.filemode = false` in .git/config, which tells git
# not to look at working-tree modes at all. A `chmod +x` therefore leaves the
# index at 100644 and `git status` stays silent: the script runs here and is
# non-executable everywhere else. That is exactly how Step 174 and Step 198
# both burned a CI run ("permission denied" on a freshly added .sh), and the
# reason this test reads `git ls-files -s` rather than File.executable?.
#
# The policy is directory-based because the repo already splits cleanly that way:
#
#   exe/, .github/scripts/  -- invoked as bare commands (gem bindir, `run:` steps),
#                              so the bit has to be in the index
#   everything else         -- invoked through an interpreter (`ruby tools/x.rb`,
#                              `sh script.sh`), so the bit is noise
#
# tools/ deliberately sits in the second group: `bundle exec tools/x.rb` fails
# with "not executable", so those files document `ruby tools/x.rb` instead
# (see the Usage headers there and docs/STEPS.md atomic-type-3).
class TestRepoFileModes < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE_DIRS = ["exe/", ".github/scripts/"].freeze

  def setup
    @entries = tracked_entries
    skip "not a git checkout" if @entries.nil?
  end

  def test_files_invoked_as_bare_commands_carry_the_bit_in_the_index
    missing = @entries.reject { |mode, _| mode == "100755" }
                      .map { |_, path| path }
                      .select { |path| EXECUTABLE_DIRS.any? { |dir| path.start_with?(dir) } }

    assert_empty missing, <<~MSG.chomp
      tracked as 100644 but invoked as a bare command, so CI will get "permission denied".
      A local `chmod +x` is invisible here (core.filemode=false); record it with:
        git update-index --chmod=+x #{missing.join(" ")}
    MSG
  end

  def test_nothing_else_carries_the_bit
    stray = @entries.select { |mode, _| mode == "100755" }
                    .map { |_, path| path }
                    .reject { |path| EXECUTABLE_DIRS.any? { |dir| path.start_with?(dir) } }

    assert_empty stray, <<~MSG.chomp
      tracked as 100755 outside #{EXECUTABLE_DIRS.join(" / ")}. Either the file belongs in one
      of those directories, or the bit is accidental -- `git update-index --chmod=-x <path>`.
    MSG
  end

  def test_every_executable_file_starts_with_a_shebang
    without = @entries.select { |mode, _| mode == "100755" }
                      .map { |_, path| path }
                      .reject { |path| File.binread(File.join(REPO_ROOT, path), 2) == "#!" }

    assert_empty without, "tracked as 100755 but has no #! line, so exec'ing it is up to the caller's shell"
  end

  private

  # [[mode, path], ...] straight out of the index. Returns nil outside a checkout
  # (the gem package ships these tests but not the .git directory).
  def tracked_entries
    out = IO.popen(["git", "-C", REPO_ROOT, "ls-files", "-s"], err: File::NULL, &:read)
    return nil unless $?&.success? # rubocop:disable Style/SpecialGlobalVars -- no English require in this suite

    out.lines.map do |line|
      mode, rest = line.split(" ", 2)
      [mode, rest.split("\t", 2).last.chomp]
    end
  end
end
