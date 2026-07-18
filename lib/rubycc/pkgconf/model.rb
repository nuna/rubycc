# frozen_string_literal: true

module Rubycc
  module Pkgconf
    # One parsed .pc file: the handful of fields mkmf's pkg_config() and its
    # own Requires chain ever touch. `cflags`/`libs`/`libs_private` are the
    # field text after `${var}` expansion, still a raw (unsplit) string —
    # Resolver is the one that shellsplits it into tokens, since only Resolver
    # knows whether a field is being consumed for --cflags or --libs.
    class Package
      attr_reader :name, :description, :version, :requires, :requires_private,
                  :cflags, :libs, :libs_private, :path

      def initialize(name:, description:, version:, requires:, requires_private:,
                     cflags:, libs:, libs_private:, path:)
        @name = name
        @description = description
        @version = version
        @requires = requires
        @requires_private = requires_private
        @cflags = cflags
        @libs = libs
        @libs_private = libs_private
        @path = path
      end
    end
  end
end
