# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "rubygems/package"

module Rubycc
  module Doctor
    # Downloads a gem's package from rubygems.org and reads its real
    # specification. This is the authoritative source of a gem's `extensions`
    # list: neither the versions API nor the "quick" (light) gemspec carries the
    # extensions field, so the only reliable way to know whether a gem has a C
    # extension is to read the full .gem's embedded gemspec. That full package is
    # also exactly what an on-the-fly build needs, so probe and build share it.
    #
    # Everything here touches the network; callers treat any failure (offline,
    # 404, timeout) as "unknown" and degrade gracefully.
    class Fetcher
      HOST = "https://rubygems.org"
      # A .gem is a few hundred KB at most for the extension gems we target; this
      # only guards against a hung connection.
      OPEN_TIMEOUT = 15
      READ_TIMEOUT = 60

      class FetchError < StandardError; end

      def initialize(cache_dir)
        @cache_dir = cache_dir
      end

      # Resolve the latest released (non-prerelease) version of +name+ via the v1
      # API. Returns a version string, or nil when the lookup fails.
      def latest_version(name)
        body = get("#{HOST}/api/v1/gems/#{name}.json")
        JSON.parse(body)["version"]
      rescue StandardError
        nil
      end

      # Download NAME-VERSION.gem into the cache and return its local path. Raises
      # FetchError on any network failure so the caller can report "unknown".
      def download(name, version)
        dest = File.join(@cache_dir, "#{name}-#{version}.gem")
        return dest if File.file?(dest) && File.size(dest).positive?

        body = get("#{HOST}/gems/#{name}-#{version}.gem")
        File.binwrite(dest, body)
        dest
      rescue StandardError => e
        raise FetchError, e.message
      end

      # The Gem::Specification embedded in a downloaded .gem.
      def spec(gem_path)
        Gem::Package.new(gem_path).spec
      end

      private

      # A GET that follows rubygems.org's CDN redirects and returns the body,
      # raising on any non-success status.
      def get(url, limit = 5)
        raise FetchError, "too many redirects" if limit.zero?

        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        res = http.get(uri.request_uri)
        case res
        when Net::HTTPSuccess
          res.body
        when Net::HTTPRedirection
          get(URI.join(url, res["location"]).to_s, limit - 1)
        else
          raise FetchError, "#{url} -> HTTP #{res.code}"
        end
      end
    end
  end
end
