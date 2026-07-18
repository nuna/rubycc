# frozen_string_literal: true

# rmake — the mkmf-Makefile subset (M3 / DESIGN R5). B1 ships the parser, the
# variable expander and the dependency-graph planner; there is no CLI yet
# (exe/rmake arrives with the runner in B2/B3), so this aggregate require is the
# only entry point. It stays self-contained — depending on nothing else in
# lib/rubycc — so it can be loaded on its own from the tests.
require_relative "errors"
require_relative "model"
require_relative "expander"
require_relative "parser"
require_relative "makefile"
require_relative "executor"
