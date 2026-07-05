# frozen_string_literal: true

require_relative "compile_error"
require_relative "front/lexer"
require_relative "front/parser"
require_relative "ir/generator"
require_relative "backend/x86_64"
require_relative "objfile/elf_writer"

module Rubycc
  # Orchestrates every compilation stage: source -> tokens -> AST -> IR ->
  # machine code -> ELF relocatable object.
  class Compiler
    # Compiles C source into an ELF64 relocatable object, returned as an
    # ASCII-8BIT String. Raises Rubycc::CompileError on user errors.
    def compile(source, filename:)
      tokens = Front::Lexer.new(source, filename: filename).tokenize
      program = Front::Parser.new(tokens).parse
      ir_functions = IR::Generator.new.generate(program)

      backend = Backend::X86_64.new
      writer = ObjFile::ELFWriter.new
      writer.add_file_symbol(File.basename(filename))

      text = +"".b
      ir_functions.each do |ir_func|
        result = backend.compile(ir_func)
        base = text.bytesize
        text << result.bytes
        result.symbols.each do |sym|
          writer.add_global_func(sym[:name], base + sym[:offset], sym[:size])
        end
      end
      writer.add_text_section(text)
      writer.to_binary
    end

    # Convenience: read `input_path`, compile it and write the object to
    # `output_path`.
    def self.compile_file(input_path, output_path)
      source = File.read(input_path)
      binary = new.compile(source, filename: input_path)
      File.binwrite(output_path, binary)
      output_path
    end
  end
end
