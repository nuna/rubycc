# frozen_string_literal: true

require "shellwords"

module Rubycc
  module Pkgconf
    # Loads .pc files by name from a search path and walks their Requires
    # chain to produce the token lists --cflags/--libs need. A module is
    # loaded at most once per Resolver (a memoizing cache doubling as the
    # cycle guard for a Requires loop); within a single module's own
    # Cflags/Libs value, tokens are kept exactly as written — no de-duplication
    # is attempted (see the Step 59 report: this cannot be measured against
    # the real pkg-config in this environment, so the simplest order-preserving
    # concatenation is used, which is all mkmf's pkg_config() needs).
    class Resolver
      def initialize(directories: SearchPath.directories)
        @directories = directories
        @cache = {}
      end

      # True if +name+ and its whole Requires/Requires.private chain resolve —
      # the same thing `pkg-config --exists` has to check, since it must load
      # every dependency's .pc file to answer the question.
      def exists?(name)
        cflags_tokens(name)
        true
      rescue PkgconfError
        false
      end

      def load(name)
        return @cache[name] if @cache.key?(name)

        path = SearchPath.find(name, directories: @directories)
        raise NotFoundError, "package '#{name}' not found (searched #{@directories.join(File::PATH_SEPARATOR)})" unless path

        @cache[name] = Parser.parse(File.read(path), path: path)
      end

      # Own Cflags, then each public Requires recursively, then each
      # Requires.private recursively — a private dependency's compiler flags
      # are still needed to build against +name+, they are just not exposed to
      # *its* dependents (that asymmetry is Requires.private's whole point).
      def cflags_tokens(name, visited = {})
        return [] if visited[name]

        visited[name] = true
        pkg = load(name)
        tokens = Shellwords.split(pkg.cflags)
        pkg.requires.each { |dep| tokens.concat(cflags_tokens(dep, visited)) }
        pkg.requires_private.each { |dep| tokens.concat(cflags_tokens(dep, visited)) }
        tokens
      end

      # Own Libs, then each public Requires recursively. Requires.private
      # never contributes here — pkg-config only pulls a private dependency's
      # Libs into the static-link case (Libs.private via --static), which
      # mkmf's pkg_config() never requests, so it is out of scope.
      def libs_tokens(name, visited = {})
        return [] if visited[name]

        visited[name] = true
        pkg = load(name)
        tokens = Shellwords.split(pkg.libs)
        pkg.requires.each { |dep| tokens.concat(libs_tokens(dep, visited)) }
        tokens
      end
    end
  end
end
