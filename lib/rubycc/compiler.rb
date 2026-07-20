# frozen_string_literal: true

require_relative "compile_error"
require_relative "preprocess/preprocessor"
require_relative "front/parser"
require_relative "ir/generator"
require_relative "backend/x86_64"
require_relative "backend/aarch64"
require_relative "objfile/elf_writer"

module Rubycc
  # Orchestrates every compilation stage: source -> tokens -> AST -> IR ->
  # machine code -> ELF relocatable object.
  class Compiler
    # The backend dispatch table: a normalized target name selects the code
    # generator that lowers IR to that machine's instructions, the ELF machine
    # description (e_machine value + relocation-type table) the object writer
    # emits under, and the one ABI trait the machine-independent front end has to
    # know about — whether plain `char` is signed. That last entry is what makes
    # the front end target-aware at all: the signedness of plain `char` is
    # implementation-defined (6.2.5p15) and each ABI pins it, signed under the
    # x86-64 System V psABI and unsigned under AAPCS64, so it has to reach type
    # resolution rather than being decided once for the whole compiler. The
    # `arch_macros` entry is the same idea one stage earlier: the CPU-identifying
    # predefined macros a translation unit (and the libc headers it includes)
    # dispatches on. `unnamed_bitfields_align` is a third: the ABIs disagree on
    # whether an unnamed bit-field's type raises its aggregate's alignment, so
    # sizeof and _Alignof of such a struct are target-dependent (see
    # StructType#define). Apart from those three every entry shares the
    # orchestration logic below unchanged.
    TARGETS = {
      "x86_64" => { backend: Backend::X86_64, machine: ObjFile::ELFWriter::X86_64,
                    char_signed: true,
                    arch_macros: Preprocess::Preprocessor::X86_64_ARCH_MACROS,
                    unnamed_bitfields_align: false },
      "aarch64" => { backend: Backend::AArch64, machine: ObjFile::ELFWriter::AARCH64,
                     char_signed: false,
                     arch_macros: Preprocess::Preprocessor::AARCH64_ARCH_MACROS,
                     unnamed_bitfields_align: true }
    }.freeze

    # Compiles C source into an ELF64 relocatable object, returned as an
    # ASCII-8BIT String. Raises Rubycc::CompileError on user errors. `target`
    # names the machine to generate code for (see TARGETS); it defaults to
    # x86_64 and an unknown value is a caller error.
    def compile(source, filename:, include_paths: [], pic: false, defines: [], system_includes: true,
                target: "x86_64")
      entry = TARGETS.fetch(target) { raise ArgumentError, "unsupported target: #{target.inspect}" }
      # The target's plain-`char` type, threaded through every stage that builds
      # or reasons about one: the preprocessor (which predefines
      # __CHAR_UNSIGNED__ when it is unsigned), the parser (which resolves the
      # `char` type-specifier to it) and the generator (which types a string
      # literal's elements with it).
      plain_char = Type.plain_char(entry[:char_signed])
      tokens = Preprocess::Preprocessor.new(char_unsigned: plain_char.unsigned?,
                                            arch_macros: entry[:arch_macros])
                                       .run(source, filename: filename,
                                            include_paths: include_paths, defines: defines,
                                            system_includes: system_includes)
      program = Front::Parser.new(tokens, plain_char: plain_char,
                                          unnamed_bitfields_align: entry[:unnamed_bitfields_align]).parse
      ir_program = IR::Generator.new(plain_char: plain_char).generate(program, pic: pic)

      backend = entry[:backend].new
      writer = ObjFile::ELFWriter.new(machine: entry[:machine])
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
        # Align each function to 16 bytes with the target's NOP filler, keeping
        # the output deterministic and every entry point aligned.
        pad_to_alignment(text, 16, entry[:machine].text_padding)
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
          # resolve (e.g. libc's abs). The two are recorded as distinct kinds
          # because they only coincide on some targets: x86_64 resolves both with
          # the same PC-relative PLT32, while aarch64 needs a `bl`'s CALL26 for
          # one and an address-forming instruction pair for the other.
          writer.add_undefined_symbol(reloc[:symbol]) unless defined_names.include?(reloc[:symbol])
          if reloc[:kind] == :call
            writer.add_text_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
          else
            writer.add_func_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
          end
        when :string
          # A reference from .text into .rodata, resolved against the .rodata
          # section symbol and displaced by the string's byte offset within the
          # pool. The offset is passed unbiased: whatever a target's own field
          # placement demands on top of it belongs to its machine description,
          # not to this machine-independent layer.
          writer.add_rodata_relocation(offset: reloc[:offset],
                                       addend: string_offsets[reloc[:string_id]])
        when :global
          # A reference from .text addressing a file-scope variable, resolved
          # against that variable's own object symbol. A variable only declared
          # `extern` in this unit (referenced but never defined here) has no
          # local object symbol, so it becomes an undefined symbol for the
          # linker, just like an undefined call target.
          writer.add_undefined_symbol(reloc[:symbol]) unless known_names.include?(reloc[:symbol])
          writer.add_global_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
        when :got
          # A PIC access (-fPIC) through the Global Offset Table: a load of the
          # address of a symbol this unit does not define — an extern file-scope
          # object, or an external function whose address is taken — from that
          # symbol's GOT slot. The symbol becomes an undefined symbol for the
          # linker to bind (unless another part of this unit defines it); which
          # relocation addresses the slot is the machine description's business.
          writer.add_undefined_symbol(reloc[:symbol]) unless known_names.include?(reloc[:symbol])
          writer.add_got_relocation(offset: reloc[:offset], symbol: reloc[:symbol])
        end
      end

      writer.set_rodata(rodata) unless rodata.empty?
      writer.add_text_section(text)
      writer.to_binary
    end

    private

    # Pads `buffer` with repetitions of the target's NOP encoding until its
    # length is a multiple of `alignment`. `filler` may be several bytes wide
    # (aarch64's NOP is a whole 32-bit word), so the gap is filled in whole
    # units; a gap that is not a multiple of the filler width cannot arise
    # because the alignment is a multiple of the instruction size.
    def pad_to_alignment(buffer, alignment, filler)
      remainder = buffer.bytesize % alignment
      return unless remainder.positive?

      buffer << (filler * ((alignment - remainder) / filler.bytesize))
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
                          system_includes: true, target: "x86_64")
      source = File.read(input_path)
      binary = new.compile(source, filename: input_path, include_paths: include_paths,
                                   pic: pic, defines: defines, system_includes: system_includes,
                                   target: target)
      File.binwrite(output_path, binary)
      output_path
    end
  end
end
