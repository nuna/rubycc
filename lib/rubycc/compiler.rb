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
      defined_names = []
      relocations = []
      ir_functions.each do |ir_func|
        result = backend.compile(ir_func)
        # Align each function to 16 bytes with NOP (0x90) padding, keeping the
        # output deterministic and every entry point aligned.
        pad_to_alignment(text, 16)
        base = text.bytesize
        text << result.bytes
        result.symbols.each do |sym|
          writer.add_global_func(sym[:name], base + sym[:offset], sym[:size])
          defined_names << sym[:name]
        end
        result.relocations.each do |reloc|
          relocations << { offset: base + reloc[:offset], symbol: reloc[:symbol] }
        end
      end

      # A call whose target is not defined in this translation unit becomes an
      # undefined symbol for the linker to resolve (e.g. libc's abs).
      relocations.each do |reloc|
        writer.add_undefined_symbol(reloc[:symbol]) unless defined_names.include?(reloc[:symbol])
        writer.add_text_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
      end

      writer.add_text_section(text)
      writer.to_binary
    end

    private

    # Pads `buffer` with NOP (0x90) bytes until its length is a multiple of
    # `alignment`.
    def pad_to_alignment(buffer, alignment)
      remainder = buffer.bytesize % alignment
      buffer << ("\x90".b * (alignment - remainder)) if remainder.positive?
    end

    public

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
