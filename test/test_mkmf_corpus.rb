# frozen_string_literal: true

require_relative "test_helper"

# Step 55 (M3 着手前作業、docs/development/ROADMAP.md §6 冒頭): test/fixtures/mkmf/ に
# 採取した実物 mkmf 生成物(Makefile / mkmf.log)の基本形を検証する軽量テスト。
# コーパスそのものの再生成は tools/collect_mkmf_corpus.rb が行う
# (test/fixtures/mkmf/README.md 参照)。このテストは fixtures の欠落・破損の
# 早期検知が目的で、mkmf の probe を再実行したりはしない。
class TestMkmfCorpus < Minitest::Test
  FIXTURES_ROOT = File.expand_path("fixtures/mkmf", __dir__)

  # <gem-version>/<ext名> ディレクトリを列挙する。
  def ext_fixture_dirs
    Dir.glob(File.join(FIXTURES_ROOT, "*-*/*")).select { |d| File.directory?(d) }.sort
  end

  def test_corpus_is_present
    assert Dir.exist?(FIXTURES_ROOT), "test/fixtures/mkmf is missing"
    assert_operator ext_fixture_dirs.size, :>=, 1, "no <gem>/<ext> fixture directories found under #{FIXTURES_ROOT}"
  end

  def test_each_fixture_makefile_has_suffix_rule_and_cc_assignment
    dirs = ext_fixture_dirs
    refute_empty dirs, "no fixture directories to check"

    dirs.each do |dir|
      makefile_path = File.join(dir, "Makefile")
      assert File.exist?(makefile_path), "#{dir} has no Makefile"

      lines = File.readlines(makefile_path)

      suffix_rule = lines.any? { |l| l.start_with?(".c.o:") || l.start_with?(".c.$(OBJEXT):") }
      assert suffix_rule, "#{makefile_path} has no .c.o: / .c.$(OBJEXT): suffix rule"

      cc_assignment = lines.any? { |l| l =~ /^CC\s*=/ }
      assert cc_assignment, "#{makefile_path} has no CC = variable assignment"
    end
  end

  def test_mkmf_log_when_present_records_conftest_program
    dirs = ext_fixture_dirs
    refute_empty dirs, "no fixture directories to check"

    checked_something = false
    dirs.each do |dir|
      mkmf_log_path = File.join(dir, "mkmf.log")
      next unless File.exist?(mkmf_log_path)

      count = File.read(mkmf_log_path).scan("checked program was:").size
      assert_operator count, :>=, 1, "#{mkmf_log_path} has no 'checked program was:' entry"
      checked_something = true
    end

    assert checked_something, "no fixture's mkmf.log recorded any conftest program " \
                               "(corpus should include at least one gem whose extconf.rb probes)"
  end
end
