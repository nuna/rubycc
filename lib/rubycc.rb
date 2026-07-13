# frozen_string_literal: true

require_relative "rubycc/version"

module Rubycc
  class Error < StandardError; end
end

require_relative "rubycc/compile_error"
require_relative "rubycc/type"
require_relative "rubycc/front/token"
require_relative "rubycc/front/lexeme_reader"
require_relative "rubycc/front/lexer"
require_relative "rubycc/preprocess/pp_token"
require_relative "rubycc/preprocess/scanner"
require_relative "rubycc/preprocess/token_converter"
require_relative "rubycc/front/ast"
require_relative "rubycc/front/constant_evaluator"
require_relative "rubycc/preprocess/constant_expression"
require_relative "rubycc/preprocess/preprocessor"
require_relative "rubycc/front/parser"
require_relative "rubycc/ir/ir"
require_relative "rubycc/ir/generator"
require_relative "rubycc/backend/x86_64"
require_relative "rubycc/objfile/elf_writer"
require_relative "rubycc/objfile/elf_reader"
require_relative "rubycc/compiler"
