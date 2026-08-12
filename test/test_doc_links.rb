# frozen_string_literal: true

require_relative "test_helper"

# Guards the documentation split (docs/README.md): docs/reference/ answers "what
# can it do now" for the people who build with rubycc, docs/development/ answers
# "how did it get here" for the people who build rubycc.
#
# The reason this test exists rather than a convention alone: the split moved 19
# files and rewrote 52 referring files in one step, and a broken relative link
# is invisible until somebody follows it. A link that resolves is checkable by a
# machine, so it should be.
class TestDocLinks < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOCS = File.join(ROOT, "docs")

  # A markdown inline link's target, minus anchors and URLs. Only local paths are
  # checked; an external URL is not this test's business (it would need network
  # and would fail for reasons unrelated to this repository).
  LINK = /\[[^\]]*\]\(([^)\s]+)\)/

  def markdown_files
    Dir.glob(File.join(ROOT, "{docs,test,benchmark,examples,.claude}/**/*.md")) +
      Dir.glob(File.join(ROOT, "*.md"))
  end

  # Prose in these documents contains bracket-then-paren shapes that are not
  # links: an IR operand written "[fixed, ret](§4)", a call written "(*fp)(x)".
  # A target that names a file has a directory separator or a file extension, so
  # that is what this checks; anything else is text that merely looks like a link.
  def path_like?(target)
    target.match?(%r{\A[\w./~#-]+\z}) && (target.include?("/") || target.match?(/\.\w+\z/))
  end

  def test_every_local_markdown_link_resolves
    broken = []

    markdown_files.each do |path|
      text = File.read(path)
      text.scan(LINK).each do |(target)|
        next if target.start_with?("http://", "https://", "#", "mailto:")
        next unless path_like?(target)

        # A link may carry an anchor; the file is what matters here.
        file = target.split("#", 2).first
        next if file.nil? || file.empty?

        resolved = File.expand_path(file, File.dirname(path))
        next if File.exist?(resolved)

        broken << "#{path.delete_prefix("#{ROOT}/")} -> #{target}"
      end
    end

    assert_empty broken, "these markdown links do not resolve:\n  #{broken.join("\n  ")}"
  end

  # The three directories are the whole point of the split, so a new document
  # landing directly in docs/ (where it belongs to none of them) is caught here
  # rather than by a reader wondering which kind of file it is. The split is by
  # two axes -- reader and kind -- because one axis alone leaves the
  # developer-facing *specifications* (IR.md, CI.md) with nowhere to go.
  def test_docs_root_holds_only_the_index
    entries = Dir.children(DOCS).sort
    assert_equal %w[README.md development internals reference], entries,
                 "docs/ holds the index and the three directories; " \
                 "a new document belongs in one of them (see docs/README.md)"
  end

  # docs/README.md is the index a reader starts from, so every document has to
  # appear in it. A file nobody links to is a file nobody finds.
  def test_the_index_lists_every_document
    listed = File.read(File.join(DOCS, "README.md")).scan(LINK).flatten
    listed = listed.map { |t| t.split("#", 2).first }.compact

    %w[reference internals development].each do |dir|
      Dir.children(File.join(DOCS, dir)).sort.each do |name|
        assert_includes listed, "#{dir}/#{name}",
                        "docs/README.md should list docs/#{dir}/#{name}"
      end
    end
  end
end
