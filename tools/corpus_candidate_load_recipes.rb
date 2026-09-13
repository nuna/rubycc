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
    },
    {
      "name" => "gvltools",
      "version" => "0.5.0",
      "platform" => "ruby",
      "sha256" => "a15e480b3860e7e9661e5e53aff9b1802fe9018fa42a5e845adc2a19a7bcc65d",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["gvltools"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "levenshtein",
      "version" => "0.2.2",
      "platform" => "ruby",
      "sha256" => "e2088ce4eaf4460e48c1812f43f5d89c50835830e74adcb4317cc477d4f1bf98",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["levenshtein"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "sequel_pg",
      "version" => "1.20.0",
      "platform" => "ruby",
      "sha256" => "230a8094cf4cb07754a928fa3a3fe1c34794a81001c978c6c51d5bd5acbd33a2",
      "dependencies" => [
        {"name" => "pg", "version" => "1.6.3"},
        {"name" => "sequel", "version" => "5.108.0"}
      ],
      "entrypoint" => {
        "requires" => ["sequel", "sequel/adapters/postgres"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "panko_serializer",
      "version" => "0.8.5",
      "platform" => "ruby",
      "sha256" => "ba95efee24a3b3abe4e025b4b9f1c39944b321a53f2a4cd6c5a9d5bd6540c929",
      "dependencies" => [
        {"name" => "oj", "version" => "3.17.6"},
        {"name" => "activesupport", "version" => "8.1.3.1"}
      ],
      "entrypoint" => {
        "requires" => ["panko_serializer"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "digest-murmurhash",
      "version" => "1.1.1",
      "platform" => "ruby",
      "sha256" => "4011022fb64e5c8dc78d74f199c713e5c3f1969cc2678a48d985b45704625d51",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["digest/murmurhash"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "splitclient-rb",
      "version" => "8.11.3",
      "platform" => "ruby",
      "sha256" => "9a2483a68d7939df96f9633d31de499617e0bb34c55a1217df334df5bea64547",
      "dependencies" => [
        {"name" => "bitarray", "version" => "1.3.2"},
        {"name" => "concurrent-ruby", "version" => "1.3.8"},
        {"name" => "json", "version" => "2.21.2"},
        {"name" => "jwt", "version" => "3.3.0"},
        {"name" => "lru_redux", "version" => "1.1.0"},
        {"name" => "net-http-persistent", "version" => "4.0.8"},
        {"name" => "redis", "version" => "5.4.1"},
        {"name" => "faraday", "version" => "2.14.3"},
        {"name" => "faraday-net_http_persistent", "version" => "2.3.1"}
      ],
      "entrypoint" => {
        "requires" => ["splitclient-rb"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "llhttp",
      "version" => "0.6.2",
      "platform" => "ruby",
      "sha256" => "3c3c59aafb1e1594ab2f45293478f697458f5a91eb0f0db4b27f61a064024982",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["llhttp"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "tomlib",
      "version" => "0.7.3",
      "platform" => "ruby",
      "sha256" => "85e562eeaa40b2aca552a13515f41fc6ae9dc522154bc1089c8d3ef94dcebd9b",
      "dependencies" => [
        {"name" => "bigdecimal", "version" => "4.1.2"}
      ],
      "entrypoint" => {
        "requires" => ["tomlib"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "quirc",
      "version" => "0.2.0",
      "platform" => "ruby",
      "sha256" => "b235ffda5fdddef6d1374a8a1a36fa64f98994e31e5f6ec76b10d89d9ee643c1",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["quirc"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "looksee",
      "version" => "5.1.0",
      "platform" => "ruby",
      "sha256" => "9498fd11ffc959d7780ee8928ccd6a9c2b7451593c480e4e0dc12b41c140b7b6",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["looksee"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "dedup",
      "version" => "0.1.4",
      "platform" => "ruby",
      "sha256" => "947d7ab050b9a7160417c1a149ed1085731cfb95b7d98934f3ee2fb22c561e63",
      "dependencies" => [],
      "entrypoint" => {
        "requires" => ["dedup"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "aead",
      "version" => "1.8.1",
      "platform" => "ruby",
      "sha256" => "17d7f20cda415b9f0d511d35ab234b01553940b88176ac90219110e7afa1d56f",
      "dependencies" => [
        {"name" => "systemu", "version" => "2.6.5"},
        {"name" => "macaddr", "version" => "1.7.2"}
      ],
      "entrypoint" => {
        "requires" => ["aead", "aead/cipher"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "liquid-c",
      "version" => "4.2.0",
      "platform" => "ruby",
      "sha256" => "1741ecef2948deafd79361ad443b98eb799605e02039fe072df5821ee8d51810",
      "dependencies" => [
        {"name" => "base64", "version" => "0.3.0"},
        {"name" => "bigdecimal", "version" => "4.1.3"},
        {"name" => "strscan", "version" => "3.1.8"},
        {"name" => "liquid", "version" => "5.13.0"}
      ],
      "entrypoint" => {
        "requires" => ["liquid", "liquid/c"],
        "sanity_kind" => "entrypoint_loaded"
      }
    },
    {
      "name" => "do_sqlite3",
      "version" => "0.10.17",
      "platform" => "ruby",
      "sha256" => "8ebdac3d05c2711b7a8215937cbb5f5c97082a12515d3cab50e6f1273129bf3f",
      "dependencies" => [
        {"name" => "bigdecimal", "version" => "4.1.3"},
        {"name" => "data_objects", "version" => "0.10.17"}
      ],
      "entrypoint" => {
        "requires" => ["bigdecimal", "do_sqlite3"],
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
