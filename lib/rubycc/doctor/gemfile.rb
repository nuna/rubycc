# frozen_string_literal: true

module Rubycc
  module Doctor
    # Extracts the gems an application uses from its Gemfile.lock (preferred, for
    # exact resolved versions) or, failing that, a bare Gemfile.
    #
    # Bundler's Gemfile is a Ruby DSL; evaluating it safely means sandboxing
    # arbitrary code, which is heavy and a security hazard. The lock file, by
    # contrast, is a fixed indented text format with no code in it, so parsing it
    # is both safe and gives the *resolved* versions and the full transitive
    # dependency closure (its `specs:` section is exactly that closure). rubycc
    # doctor therefore prefers the lock and treats it as authoritative.
    #
    # When only a Gemfile is present it is parsed naively — `gem "name"` lines are
    # read with a regexp, never `eval`'d. That yields direct dependencies only
    # (no closure) and often no version; callers surface that as a limitation.
    module Gemfile
      # One resolved gem: its name, version (nil when unknown), the names of its
      # direct runtime dependencies (from the lock; empty otherwise) and the
      # source section it came from (:gem for rubygems.org, :path/:git for local
      # or VCS gems that cannot be fetched from rubygems.org).
      Entry = Struct.new(:name, :version, :dependencies, :source, keyword_init: true)

      # The parsed picture the CLI drives off: the list of gem entries, the names
      # of the directly-declared dependencies, and where the data came from
      # (:lock exact versions, or :gemfile direct-only best effort).
      Result = Struct.new(:entries, :direct, :origin, :path, keyword_init: true)

      module_function

      # Load gem information from +dir+ (or an explicit --gemfile path). A
      # Gemfile.lock next to the Gemfile is preferred; otherwise the Gemfile
      # itself is parsed. Returns a Result, or nil when neither file exists.
      def load(gemfile_path)
        lock = "#{gemfile_path}.lock"
        if File.file?(lock)
          parse_lock(File.read(lock), path: lock)
        elsif File.file?(gemfile_path)
          parse_gemfile(File.read(gemfile_path), path: gemfile_path)
        end
      end

      # Parse the text of a Gemfile.lock. The format is a sequence of sections
      # introduced by an unindented header (GEM, PATH, GIT, DEPENDENCIES, ...).
      # Inside GEM/PATH/GIT a `specs:` line is followed by the resolved gems at
      # 4-space indent (`name (version)`), each optionally trailed by its own
      # dependencies at 6-space indent (`dep (constraint)`). DEPENDENCIES lists
      # the directly-declared gems at 2-space indent.
      def parse_lock(text, path: nil)
        entries = []
        direct = []
        section = nil       # current top-level section header
        source = nil        # :gem / :path / :git for the current specs block
        in_specs = false
        current = nil       # the Entry whose dependency lines we are reading

        text.each_line do |raw|
          line = raw.chomp
          next if line.strip.empty?

          if line == line.lstrip # unindented -> a section header
            section = line
            source = { "GEM" => :gem, "PATH" => :path, "GIT" => :git }[section]
            in_specs = false
            current = nil
            next
          end

          if section == "DEPENDENCIES"
            direct << line.strip.sub(/[!<>=~ ].*\z/, "").strip
            next
          end

          if source
            if line.strip == "specs:"
              in_specs = true
              next
            end
            next unless in_specs

            indent = line[/\A */].length
            if indent == 4 && (m = line.strip.match(/\A(\S+) \(([^)]+)\)\z/))
              current = Entry.new(name: m[1], version: m[2].split.first, dependencies: [], source: source)
              entries << current
            elsif indent >= 6 && current && (m = line.strip.match(/\A(\S+)/))
              current.dependencies << m[1]
            end
          end
        end

        Result.new(entries: entries, direct: direct.uniq, origin: :lock, path: path)
      end

      # Parse a bare Gemfile naively: pick up every `gem "name"` (or 'name')
      # declaration and an optional literal version argument. This never evaluates
      # the file, so conditionals, variables and computed names are invisible —
      # the caller reports the reduced fidelity. Group/platform blocks are not
      # tracked; every declared gem is returned.
      def parse_gemfile(text, path: nil)
        entries = []
        text.each_line do |raw|
          line = raw.sub(/#.*/, "")
          m = line.match(/\bgem\s*\(?\s*["']([^"']+)["']\s*(?:,\s*["']([^"']+)["'])?/)
          next unless m

          version = m[2]&.sub(/\A[~><=!\s]+/, "")&.strip
          version = nil if version && version.empty?
          entries << Entry.new(name: m[1], version: version, dependencies: [], source: :gem)
        end
        Result.new(entries: entries.uniq(&:name), direct: entries.map(&:name).uniq, origin: :gemfile, path: path)
      end
    end
  end
end
