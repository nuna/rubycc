# frozen_string_literal: true

# Pkgconf — the pkg-config shim (M3 / DESIGN R5, ROADMAP §6 B4): a pure-Ruby
# .pc parser plus the narrow CLI mkmf's mkmf.rb#pkg_config actually invokes
# ($PKGCONFIG with --exists / --modversion / --cflags[-only-*] /
# --libs[-only-l]). It stays self-contained — depending on nothing else in
# lib/rubycc, like rmake (M3 B1) — so exe/rubycc-pkgconf and the tests can
# load it on its own.
require_relative "errors"
require_relative "model"
require_relative "parser"
require_relative "search_path"
require_relative "resolver"
require_relative "cli"
