# frozen_string_literal: true

require_relative "rubycc/version"

# Every file rubycc reads — C source, a .pc file, a Makefile, a Gemfile, a
# linker script — is read as bytes (File.binread), and every path it builds is a
# byte string. The reason is a property of Ruby rather than of any one reader:
# two strings holding the same non-ASCII bytes under different encodings are
# neither == nor eql?, hash differently, and cannot be joined or concatenated at
# all — while File.read tags what it returns with Encoding.default_external,
# which is the locale, which is US-ASCII when there is none. Strings that enter
# from the process instead (ARGV, ENV, Dir.pwd, a directory listing) are
# therefore re-tagged with String#b at the class boundary they cross;
# `text.b unless text.encoding == Encoding::BINARY` is the spelling for that,
# leaving a string that is already bytes alone rather than duplicating it.
module Rubycc
  class Error < StandardError; end
end

require_relative "rubycc/diagnostics"
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
require_relative "rubycc/backend/aarch64"
require_relative "rubycc/objfile/elf_writer"
require_relative "rubycc/objfile/elf_reader"
require_relative "rubycc/objfile/relocatable_writer"
require_relative "rubycc/objfile/ar_archive"
require_relative "rubycc/link/errors"
require_relative "rubycc/link/partial_linker"
require_relative "rubycc/link/shared_linker"
require_relative "rubycc/link/executable_linker"
require_relative "rubycc/link/library_resolver"
require_relative "rubycc/compiler"
require_relative "rubycc/driver"
