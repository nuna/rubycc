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
      ir_program = IR::Generator.new.generate(program)

      backend = Backend::X86_64.new
      writer = ObjFile::ELFWriter.new
      writer.add_file_symbol(File.basename(filename))

      # Lay out the translation unit's string pool as .rodata: each interned
      # string in id order, NUL-terminated. `string_offsets[id]` is the byte
      # offset of string `id` within the section.
      rodata = +"".b
      string_offsets = []
      ir_program.strings.each do |bytes|
        string_offsets << rodata.bytesize
        rodata << bytes << "\0".b
      end

      text = +"".b
      defined_names = []
      relocations = []
      ir_program.functions.each do |ir_func|
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
          relocations << reloc.merge(offset: base + reloc[:offset])
        end
      end

      relocations.each do |reloc|
        case reloc[:kind]
        when :call
          # A call whose target is not defined in this translation unit becomes
          # an undefined symbol for the linker to resolve (e.g. libc's abs).
          writer.add_undefined_symbol(reloc[:symbol]) unless defined_names.include?(reloc[:symbol])
          writer.add_text_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
        when :string
          # A "lea rip" displacement into .rodata: a PC-relative reference to
          # the .rodata section symbol biased by the string's offset. The -4
          # accounts for the rel32 field sitting 4 bytes before its own end.
          addend = string_offsets[reloc[:string_id]] - 4
          writer.add_rodata_relocation(offset: reloc[:offset], addend: addend)
        end
      end

      writer.set_rodata(rodata) unless rodata.empty?
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
