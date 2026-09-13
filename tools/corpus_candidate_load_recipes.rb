#!/usr/bin/env ruby
# frozen_string_literal: true

# Fixed, reviewed load recipes for candidates whose documented Ruby entrypoint
# is more meaningful than requiring every installed .so directly.  This file is
# deliberately data-only: dispatch inputs can select a recipe by exact
# name/version/platform/SHA, but cannot supply a require path, command, or Ruby
# expression.

module CorpusCandidateLoadRecipes
  SCHEMA_VERSION = 1

  RECIPES = [
    {
      "name" => "graphql-c_parser",
      "version" => "1.1.4",
      "platform" => "ruby",
      "sha256" => "8d3bf769ae935373ada877fe003036892b45be98c2fbcc6731dd82af2c3e0656",
      "dependencies" => [
        {"name" => "graphql", "version" => "2.6.8"}
      ],
      "entrypoint" => {
        "requires" => ["graphql/c_parser"],
        "sanity_kind" => "graphql_c_parser"
      }
    },
    {
      "name" => "ox",
      "version" => "2.14.29",
      "platform" => "ruby",
      "sha256" => "206736d5a8dade9dca10cf72022bc157ad6ca3eecaba3853918426ed88e12dc2",
      "dependencies" => [
        {"name" => "bigdecimal", "version" => "4.1.2"}
      ],
      "entrypoint" => {
        "requires" => ["ox"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "kgio",
      "version" => "2.11.4",
      "platform" => "ruby",
      "sha256" => "bda7a2146115998a5b07154e708e0ac02c38dcee7e793c33e2e14f600fdfffc6",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["kgio"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "raindrops",
      "version" => "0.20.1",
      "platform" => "ruby",
      "sha256" => "aa0eb9ff6834f2d9e232ba688bd49cb30be893bc5a3452e74722c94c1fab4730",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["raindrops"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "ruby-ll",
      "version" => "2.2.0",
      "platform" => "ruby",
      "sha256" => "f8811ae1dfc77d6d95033a615aacb6ab8e93fb9f421fefe75107b077dc9ab588",
      "dependencies" => [
        {"name" => "ast", "version" => "2.4.3"},
        {"name" => "ansi", "version" => "1.6.0"}
      ],
      "entrypoint" => {
        "requires" => ["ll"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "oga",
      "version" => "3.5",
      "platform" => "ruby",
      "sha256" => "2b65fe1dd192c01079f93748a04a7a8011369e4c99ea1c7e73f4a037e3229353",
      "dependencies" => [
        {"name" => "ast", "version" => "2.4.3"},
        {"name" => "ansi", "version" => "1.6.0"},
        {"name" => "ruby-ll", "version" => "2.2.0"}
      ],
      "entrypoint" => {
        "requires" => ["oga"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "smarter_csv",
      "version" => "1.19.0",
      "platform" => "ruby",
      "sha256" => "fec551faa10a7b24f62e10a2bcba0e5116f5f86ced8c6a52b41ba7b33d03697b",
      "dependencies" => [
        {"name" => "bigdecimal", "version" => "4.1.2"}
      ],
      "entrypoint" => {
        "requires" => ["smarter_csv"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "bson_ext",
      "version" => "1.12.5",
      "platform" => "ruby",
      "sha256" => "e7badf502fc2728c6e0e942e71db5497ff0de7eb30653935cb7877a312e6b209",
      "dependencies" => [
        {"name" => "base64", "version" => "0.3.0"},
        {"name" => "bson", "version" => "1.12.5"}
      ],
      "entrypoint" => {
        "requires" => ["bson"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "oj-introspect",
      "version" => "0.9.0",
      "platform" => "ruby",
      "sha256" => "b7af4974654e8733902bb7707ec96155c1c577d0ba2564eb1d72cd091546834f",
      "dependencies" => [
        {"name" => "bigdecimal", "version" => "4.1.2"},
        {"name" => "ostruct", "version" => "0.6.3"},
        {"name" => "oj", "version" => "3.17.6"}
      ],
      "entrypoint" => {
        "requires" => ["oj/introspect"],
        "sanity_kind" => "entrypoint_loaded"
      }
    }
  ].map(&:freeze).freeze

  module_function

  def find(name:, version:, platform:, sha256:)
    RECIPES.find do |recipe|
      recipe.fetch("name") == name &&
        recipe.fetch("version") == version &&
        recipe.fetch("platform") == platform &&
        recipe.fetch("sha256") == sha256.to_s.downcase
    end
  end

  def public_recipe(recipe)
    return nil unless recipe

    {
      "schema_version" => SCHEMA_VERSION,
      "status" => "ready",
      "name" => recipe.fetch("name"),
      "version" => recipe.fetch("version"),
      "platform" => recipe.fetch("platform"),
      "sha256" => recipe.fetch("sha256"),
      "dependencies" => recipe.fetch("dependencies"),
      "entrypoint" => recipe.fetch("entrypoint")
    }
  end
end
