# frozen_string_literal: true

# Shared, deliberately small result format for CI checks.
#
# The test suite has several execution contexts (native, QEMU, fixture and
# live-network). A Minitest summary alone cannot tell the CI policy whether a
# required acceptance was actually attempted. This module keeps that policy's
# input structured without coupling the tests to a particular log format.

require "json"

module Rubycc
  module CIResult
    VERSION = 1
    STATES = %w[pass fail skipped inconclusive].freeze
    REQUIRED_FIELDS = %w[id state].freeze

    class Error < StandardError; end

    module_function

    def result(id:, state:, reason: nil, **metadata)
      id = normalize_id(id)
      state = normalize_state(state)

      value = { "id" => id, "state" => state }
      value["reason"] = String(reason) unless reason.nil?
      metadata.each do |key, entry|
        key = String(key)
        raise Error, "result metadata key cannot be #{key.inspect}" if REQUIRED_FIELDS.include?(key)

        value[key] = entry
      end
      value
    end

    def document(results:, metadata: {})
      unless results.respond_to?(:map)
        raise Error, "results must be an array"
      end

      normalized = results.map do |entry|
        unless entry.respond_to?(:to_hash)
          raise Error, "each result must be a hash"
        end

        hash = entry.to_hash
        result(id: hash.fetch("id", hash[:id]),
               state: hash.fetch("state", hash[:state]),
               reason: hash.key?("reason") ? hash["reason"] : hash[:reason],
               **hash.reject { |key, _| %w[id state reason].include?(key.to_s) })
      rescue KeyError => e
        raise Error, "result is missing #{e.key.inspect}", cause: e
      end

      {
        "version" => VERSION,
        "results" => normalized,
        "metadata" => metadata.to_h.transform_keys(&:to_s)
      }
    end

    def write(path, results:, metadata: {})
      payload = JSON.pretty_generate(document(results: results, metadata: metadata))
      File.open(path, "w", 0o644) do |file|
        file.write(payload)
        file.write("\n")
      end
      path
    end

    def read(path)
      raw = JSON.parse(File.read(path))
      validate_document(raw)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot read result file #{path}: #{e.message}", cause: e
    rescue JSON::ParserError => e
      raise Error, "invalid JSON in result file #{path}: #{e.message}", cause: e
    end

    def validate_document(value)
      unless value.is_a?(Hash)
        raise Error, "result document must be an object"
      end
      unless value["version"] == VERSION
        raise Error, "unsupported result document version #{value["version"].inspect}"
      end
      unless value["results"].is_a?(Array)
        raise Error, "result document results must be an array"
      end

      metadata = value.fetch("metadata", {})
      raise Error, "result document metadata must be an object" unless metadata.is_a?(Hash)

      document(results: value["results"], metadata: metadata)
    rescue KeyError => e
      raise Error, "result document is missing #{e.key.inspect}", cause: e
    end

    def normalize_id(id)
      value = String(id)
      raise Error, "result id must not be empty" if value.empty?
      raise Error, "result id must not contain whitespace: #{value.inspect}" if value.match?(/\s/)

      value
    rescue TypeError
      raise Error, "result id must be a string"
    end

    def normalize_state(state)
      value = String(state)
      return value if STATES.include?(value)

      raise Error, "unsupported result state #{value.inspect}; expected #{STATES.join(", ")}"
    rescue TypeError
      raise Error, "result state must be a string"
    end
  end
end
