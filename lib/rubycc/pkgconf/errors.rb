# frozen_string_literal: true

module Rubycc
  # The base error is normally provided by lib/rubycc.rb. Like rmake (M3 B1),
  # Pkgconf is loadable on its own (its only caller so far is the
  # exe/rubycc-pkgconf CLI, not the Rubycc aggregate), so define a stand-in only
  # when the full library has not been required yet.
  Error = Class.new(StandardError) unless defined?(Error)

  module Pkgconf
    # Base for every error this shim raises: a malformed .pc file, a module
    # that cannot be found on the search path, or a construct outside the
    # subset mkmf's pkg_config() actually calls for (R11/ROADMAP §6 B4).
    class PkgconfError < Rubycc::Error; end

    # The .pc text used a construct the parser does not accept: an
    # unrecognized line, or a `${var}` reference to a variable that was never
    # assigned (in this file, at the point the reference appears — pkg-config
    # itself requires forward-references to be avoided the same way).
    class ParseError < PkgconfError
      def initialize(message, path:, line_number:)
        super("#{path || '<pc>'}:#{line_number}: #{message}")
      end
    end

    # No `<name>.pc` was found on the search path (PKG_CONFIG_PATH, then the
    # default directories) — the same condition mkmf's `pkg-config --exists`
    # probe reports as "not found".
    class NotFoundError < PkgconfError; end

    # A `Requires`/`Requires.private` entry carried a version comparison
    # (`zlib >= 1.2`-style). mkmf's own `pkg_config(pkg, *options)` never
    # passes a version constraint — the `pkg` argument is always a bare module
    # name — so comparing versions is out of scope here (see the Step 59
    # report for the mkmf.rb tally this is based on); a constraint inside a
    # `Requires` field is diagnosed instead of silently ignored or guessed at.
    class UnsupportedError < PkgconfError; end
  end
end
