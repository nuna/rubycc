# frozen_string_literal: true

require_relative "test_helper"

# Guards the work-item format (issues/README.md). The whole point of the status
# field is to stop "finished but still open" -- which is exactly what happened
# while work items lived as prose inside four different documents, where nothing
# could check them. A field a machine reads is a field a machine can check.
class TestIssueDocs < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ISSUES = File.join(ROOT, "issues")

  STATUSES = %w[open in-progress done dropped].freeze
  KINDS = %w[gap debt feature infra docs].freeze
  SECTIONS = ["## 課題", "## 影響", "## 受け入れ条件", "## 作業ログ", "## 決着"].freeze
  DATE = /\A\d{4}-\d{2}-\d{2}\z/

  # Every issue except the template, which is the shape rather than an instance.
  def issue_files
    Dir.glob(File.join(ISSUES, "*.md")).reject do |path|
      %w[README.md TEMPLATE.md].include?(File.basename(path))
    end
  end

  # The leading YAML block. Parsed by hand rather than with a YAML library: the
  # values here are scalars and empty fields are the norm ("closed:" with nothing
  # after it), so a five-line reader is clearer than teaching a parser about them.
  def front_matter(path)
    text = File.read(path)
    match = text.match(/\A---\n(.*?)\n---\n/m)
    return nil unless match

    match[1].lines.to_h do |line|
      key, value = line.split(":", 2)
      [key.to_s.strip, value.to_s.strip]
    end
  end

  def test_every_issue_has_a_front_matter_block
    issue_files.each do |path|
      refute_nil front_matter(path), "#{File.basename(path)}: missing the leading --- front matter block"
    end
  end

  def test_status_and_kind_use_the_declared_vocabulary
    issue_files.each do |path|
      fm = front_matter(path)
      name = File.basename(path)
      assert_includes STATUSES, fm["status"], "#{name}: status"
      assert_includes KINDS, fm["kind"], "#{name}: kind"
      assert_match DATE, fm["opened"].to_s, "#{name}: opened must be YYYY-MM-DD"
    end
  end

  # The fields that only mean something once the work moved: a closed issue that
  # names no PR cannot be traced back to what actually landed.
  def test_state_and_fields_agree
    issue_files.each do |path|
      fm = front_matter(path)
      name = File.basename(path)

      case fm["status"]
      when "in-progress"
        refute_empty fm["branch"].to_s, "#{name}: an in-progress issue names its branch"
      when "done"
        # "none" is the honest answer for work that changes nothing in the
        # repository -- pushing a tag, running `gem push`. Demanding a PR number
        # there would only teach people to invent one.
        refute_empty fm["pr"].to_s, "#{name}: a done issue names its PR, or `none` with the reason in 決着"
        assert_match DATE, fm["closed"].to_s, "#{name}: a done issue carries closed:"
        next if fm["pr"] == "none"

        refute_equal "[]", fm["steps"].to_s,
                     "#{name}: a done issue points at the STEPS entries that carry its design record"
      when "dropped"
        assert_match DATE, fm["closed"].to_s, "#{name}: a dropped issue carries closed:"
      end
    end
  end

  def test_every_issue_carries_the_declared_sections
    issue_files.each do |path|
      text = File.read(path)
      SECTIONS.each do |heading|
        assert_includes text, heading, "#{File.basename(path)}: missing section #{heading}"
      end
    end
  end

  # One issue is one branch is one PR, so the file name is the branch name. A
  # sequence number would collide under parallel work -- this repository already
  # renumbered its step IDs for exactly that reason.
  def test_file_names_are_branch_shaped_slugs
    issue_files.each do |path|
      name = File.basename(path, ".md")
      assert_match(/\A[a-z0-9]+(?:[-\/][a-z0-9]+)*\z/, name,
                   "#{name}: an issue file is named after its branch (lowercase, hyphens)")
    end
  end
end
