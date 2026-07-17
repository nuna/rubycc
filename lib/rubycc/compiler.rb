# frozen_string_literal: true

require_relative "compile_error"
require_relative "preprocess/preprocessor"
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
    def compile(source, filename:, include_paths: [], pic: false, defines: [], system_includes: true)
      tokens = Preprocess::Preprocessor.new.run(source, filename: filename,
                                                include_paths: include_paths, defines: defines,
                                                system_includes: system_includes)
      program = Front::Parser.new(tokens).parse
      ir_program = IR::Generator.new.generate(program, pic: pic)

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

      # Lay out the file-scope variables: initialized ones into .data (their
      # values packed little-endian at the declared width) and zero-initialized
      # ones into .bss (space reserved only). Each is placed at its type's
      # alignment and registered as a global STT_OBJECT symbol; the section
      # alignment is the widest member's.
      data = +"".b
      data_align = 1
      bss_size = 0
      bss_align = 1
      # Symbols a .data pointer slot resolves against (a "&global", a decayed
      # global array, or a function address in a function-pointer global). A
      # reference to a function defined elsewhere must be registered as an
      # undefined symbol, but only once the set of locally defined functions is
      # known (after the text is compiled), so the names are collected here.
      data_symbol_refs = []
      ir_program.globals.each do |global|
        # A `static` global gets an internal-linkage (STB_LOCAL) object symbol,
        # an ordinary one a global (STB_GLOBAL) symbol; both are laid out into
        # .data/.bss identically.
        internal = global.linkage == :internal
        if global.init.nil?
          bss_align = [bss_align, global.align].max
          bss_size = align_up(bss_size, global.align)
          add_object_symbol(writer, internal, global.name, :bss, bss_size, global.size)
          bss_size += global.size
        else
          data_align = [data_align, global.align].max
          offset = align_up(data.bytesize, global.align)
          data << ("\0".b * (offset - data.bytesize))
          add_object_symbol(writer, internal, global.name, :data, offset, global.size)
          data << global.init.bytes
          # Each pointer slot in the image is patched by a .data relocation,
          # its .text-relative offset (within the global) biased by where the
          # global itself landed in .data.
          global.init.relocations.each do |reloc|
            register_data_relocation(writer, reloc, offset, string_offsets)
            data_symbol_refs << reloc.symbol if reloc.kind == :symbol
          end
        end
      end
      writer.set_data(data, align: data_align) unless data.empty?
      writer.set_bss(bss_size, align: bss_align) if bss_size.positive?

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
          # A `static` function is a file-local (STB_LOCAL) symbol; an ordinary
          # one is global. Either way it is a defined name a same-object
          # reference resolves against, never an undefined external.
          if ir_func.linkage == :internal
            writer.add_local_func(sym[:name], base + sym[:offset], sym[:size])
          else
            writer.add_global_func(sym[:name], base + sym[:offset], sym[:size])
          end
          defined_names << sym[:name]
        end
        result.relocations.each do |reloc|
          relocations << reloc.merge(offset: base + reloc[:offset])
        end
      end

      # A function-pointer global that names a function defined elsewhere leaves
      # an undefined symbol for the linker; one that names a local function or
      # another global is already in the symbol table.
      known_names = defined_names + ir_program.globals.map(&:name)
      data_symbol_refs.each do |symbol|
        writer.add_undefined_symbol(symbol) unless known_names.include?(symbol)
      end

      relocations.each do |reloc|
        case reloc[:kind]
        when :call, :func
          # A call, or a taken function address, whose target is not defined in
          # this translation unit becomes an undefined symbol for the linker to
          # resolve (e.g. libc's abs). Both are PC-relative and share the same
          # PLT32 text relocation.
          writer.add_undefined_symbol(reloc[:symbol]) unless defined_names.include?(reloc[:symbol])
          writer.add_text_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
        when :string
          # A "lea rip" displacement into .rodata: a PC-relative reference to
          # the .rodata section symbol biased by the string's offset. The -4
          # accounts for the rel32 field sitting 4 bytes before its own end.
          addend = string_offsets[reloc[:string_id]] - 4
          writer.add_rodata_relocation(offset: reloc[:offset], addend: addend)
        when :global
          # A "lea rip" displacement addressing a file-scope variable: a
          # PC-relative reference to that variable's own object symbol. A
          # variable only declared `extern` in this unit (referenced but never
          # defined here) has no local object symbol, so it becomes an undefined
          # symbol for the linker, just like an undefined call target.
          writer.add_undefined_symbol(reloc[:symbol]) unless known_names.include?(reloc[:symbol])
          writer.add_global_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
        when :got
          # A PIC access (-fPIC) through the Global Offset Table: a "mov rax,
          # sym@GOTPCREL(rip)" loading the address of a symbol this unit does not
          # define — an extern file-scope object, or an external function whose
          # address is taken. The symbol becomes an undefined symbol for the
          # linker to bind (unless another part of this unit defines it), and the
          # GOT slot is addressed by an R_X86_64_REX_GOTPCRELX relocation.
          writer.add_undefined_symbol(reloc[:symbol]) unless known_names.include?(reloc[:symbol])
          writer.add_got_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
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

    # Rounds `value` up to the next multiple of `alignment`.
    def align_up(value, alignment)
      (value + alignment - 1) / alignment * alignment
    end

    # Registers a file-scope object's symbol, choosing the internal-linkage
    # (STB_LOCAL) writer entry for a `static` object and the global one
    # otherwise.
    def add_object_symbol(writer, internal, name, section, offset, size)
      if internal
        writer.add_local_object(name, section, offset, size)
      else
        writer.add_global_object(name, section, offset, size)
      end
    end

    # Registers one global-image relocation with the ELF writer, translating a
    # within-global slot offset into a .data-section offset. A :symbol reloc
    # points at another object's symbol (an absolute 64-bit address, plus the
    # relocation's own byte displacement for a computed "&arr[i]"); a :string
    # reloc points into .rodata, its addend the interned string's byte offset
    # plus that same displacement.
    def register_data_relocation(writer, reloc, global_offset, string_offsets)
      case reloc.kind
      when :symbol
        writer.add_data_relocation(offset: global_offset + reloc.offset,
                                   symbol: reloc.symbol, addend: reloc.addend)
      when :string
        writer.add_data_rodata_relocation(offset: global_offset + reloc.offset,
                                          addend: string_offsets[reloc.string_id] + reloc.addend)
      end
    end

    public

    # Convenience: read `input_path`, compile it and write the object to
    # `output_path`.
    def self.compile_file(input_path, output_path, include_paths: [], pic: false, defines: [],
                          system_includes: true)
      source = File.read(input_path)
      binary = new.compile(source, filename: input_path, include_paths: include_paths,
                                   pic: pic, defines: defines, system_includes: system_includes)
      File.binwrite(output_path, binary)
      output_path
    end
  end
end
