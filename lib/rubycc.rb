# frozen_string_literal: true

require_relative "rubycc/version"

module Rubycc
  class Error < StandardError; end
end

require_relative "rubycc/compile_error"
require_relative "rubycc/front/token"
require_relative "rubycc/front/lexer"
require_relative "rubycc/front/ast"
require_relative "rubycc/front/parser"
require_relative "rubycc/ir/ir"
require_relative "rubycc/ir/generator"
require_relative "rubycc/backend/x86_64"
require_relative "rubycc/objfile/elf_writer"
require_relative "rubycc/compiler"
