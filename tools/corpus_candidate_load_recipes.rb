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
