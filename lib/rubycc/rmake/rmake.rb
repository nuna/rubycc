# frozen_string_literal: true

# rmake — the mkmf-Makefile subset (M3 / DESIGN R5). It ships the parser, the
# variable expander, the dependency-graph planner, the shell-less runner and the
# CLI (exe/rmake, B6) that RubyGems drives as `$(MAKE)`. This aggregate require is
# the entry point; it stays self-contained — depending on nothing else in
# lib/rubycc until a tool-substituting run reaches for the Driver — so it can be
# loaded on its own from the tests.
require_relative "errors"
require_relative "model"
require_relative "expander"
require_relative "parser"
require_relative "tool_command"
require_relative "makefile"
require_relative "executor"
require_relative "cli"
