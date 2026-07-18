# frozen_string_literal: true

module Rubycc
  module Pkgconf
    # Where a `<name>.pc` is looked up when nothing else says otherwise.
    module SearchPath
      # The multiarch directory comes first because that is where this
      # environment's real .pc files actually live
      # (/usr/lib/x86_64-linux-gnu/pkgconfig/{zlib,libffi,openssl,...}.pc —
      # see the Step 59 report); /usr/lib/pkgconfig and /usr/share/pkgconfig
      # are the architecture-independent locations pkg-config falls back to
      # next on a Debian/Ubuntu multiarch system.
      DEFAULT_DIRECTORIES = [
        "/usr/lib/x86_64-linux-gnu/pkgconfig",
        "/usr/lib/pkgconfig",
        "/usr/share/pkgconfig"
      ].freeze

      # PKG_CONFIG_PATH (colon-separated, mirroring PATH) is searched before
      # the defaults — the same precedence mkmf's own pkg_config() relies on
      # when dir_config found a --with-*-dir libdir and set PKG_CONFIG_PATH to
      # that libdir's pkgconfig/ subdirectory before invoking pkg-config.
      def self.directories(env = ENV)
        extra = (env["PKG_CONFIG_PATH"] || "").split(File::PATH_SEPARATOR).reject(&:empty?)
        extra + DEFAULT_DIRECTORIES
      end

      # The first `<name>.pc` found across +directories+, or nil.
      def self.find(name, directories: directories())
        directories.each do |dir|
          path = File.join(dir, "#{name}.pc")
          return path if File.file?(path)
        end
        nil
      end
    end
  end
end
