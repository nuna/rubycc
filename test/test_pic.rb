# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"
require "fiddle"

# Exercises the -fPIC data/function access path (Step 33). Under -fPIC a
# reference that takes the address of a file-scope object or function this
# translation unit does not define is lowered through the Global Offset Table
# (a "mov rax, sym@GOTPCREL(rip)" with an R_X86_64_REX_GOTPCRELX relocation)
# instead of a PC-relative "lea rip"; a symbol defined here, a `static` and a
# string literal keep the PC-relative form, and a call stays PLT32. Without the
# flag the output is byte-for-byte the non-PIC one.
class TestPic < Minitest::Test
  include ExecutionHelper

  def setup
    skip_unless_x86_64_host
  end

  Reader = Rubycc::ObjFile::ELFReader

  # 48 8B 05 <disp32>: the "mov rax, [rip + disp32]" the GOT load emits.
  GOT_MOV_PREFIX = [0x48, 0x8B, 0x05].pack("C*")
  # 48 8D 05 <disp32>: the "lea rax, [rip + disp32]" a PC-relative address uses.
  LEA_PREFIX = [0x48, 0x8D, 0x05].pack("C*")

  # .dynamic tags and flag bits that would mark a writable-text (non-PIC) load.
  DT_TEXTREL = 22
  DT_FLAGS = 30
  DF_TEXTREL = 0x4

  # --- relocation discrimination (pic: true) -----------------------------

  # A reference to an object this unit does not define goes through the GOT.
  def test_extern_data_access_uses_got
    kinds = text_relocs("extern int x; int get(void) { return x; }", pic: true)
    assert_equal [[:R_X86_64_REX_GOTPCRELX, "x", -4]], kinds
  end

  # An object defined here (even referenced by "&g") keeps the PC-relative form.
  def test_defined_data_access_stays_pc32
    kinds = text_relocs("int g; int *get(void) { return &g; }", pic: true)
    assert_equal [[:R_X86_64_PC32, "g", -4]], kinds
  end

  # A `static` object is always resolved within this object, so PC-relative.
  def test_static_data_access_stays_pc32
    kinds = text_relocs("static int s; int *get(void) { return &s; }", pic: true)
    assert_equal [[:R_X86_64_PC32, "s", -4]], kinds
  end

  # A string literal addresses .rodata, defined in this object: PC-relative.
  def test_string_literal_stays_pc32_into_rodata
    reloc = text_relocs_raw("char *msg(void) { return \"hi\"; }", pic: true).first
    assert_equal :R_X86_64_PC32, reloc.type_name
    assert_equal :section, reloc.symbol.type
    assert_equal ".rodata", reloc.symbol.section.name
  end

  # Taking the address of an external function goes through the GOT, while a
  # call to it stays a PLT32 near call.
  def test_extern_function_address_uses_got_but_call_stays_plt32
    src = "void ext(void); void (*ptr(void))(void) { ext(); return ext; }"
    kinds = text_relocs(src, pic: true)
    assert_includes kinds, [:R_X86_64_PLT32, "ext", -4]
    assert_includes kinds, [:R_X86_64_REX_GOTPCRELX, "ext", -4]
  end

  # Taking the address of a function defined in this unit keeps the existing
  # PC-relative func-address relocation (PLT32 kind); it is never a GOT load.
  def test_defined_function_address_is_not_got
    src = "void g(void) {} void (*ptr(void))(void) { return g; }"
    kinds = text_relocs(src, pic: true)
    assert_equal [[:R_X86_64_PLT32, "g", -4]], kinds
    refute(kinds.any? { |type, | type == :R_X86_64_REX_GOTPCRELX })
  end

  # --- machine-code encoding ---------------------------------------------

  # The GOT access emits "mov rax, [rip + disp32]" with a zero displacement
  # placeholder the relocation fills; a PC-relative access keeps the lea.
  def test_got_access_emits_mov_and_defined_access_emits_lea
    got = text_bytes("extern int x; int get(void) { return x; }", pic: true)
    assert_includes got, GOT_MOV_PREFIX + [0].pack("l<")
    refute_includes got, LEA_PREFIX + [0].pack("l<")

    lea = text_bytes("int g; int *get(void) { return &g; }", pic: true)
    assert_includes lea, LEA_PREFIX + [0].pack("l<")
    refute_includes lea, GOT_MOV_PREFIX + [0].pack("l<")
  end

  # --- non-PIC byte invariance -------------------------------------------

  # For a source that references an external object, the non-PIC output is
  # byte-for-byte unchanged while the PIC output genuinely differs (the lea
  # becomes a GOT mov). Compiling identical sources twice is deterministic (N4).
  def test_non_pic_output_is_unchanged_and_pic_differs
    src = "extern int x; int get(void) { return x; }"
    non_pic = compile(src, pic: false)
    non_pic_again = compile(src, pic: false)
    pic = compile(src, pic: true)

    assert_equal non_pic, non_pic_again, "non-PIC output must be deterministic"
    refute_equal non_pic, pic, "PIC output must differ from non-PIC for an extern access"
  end

  # A source with no external reference is byte-identical whether or not -fPIC
  # is given: the PIC path only diverges for symbols this unit does not define.
  def test_self_contained_source_is_identical_with_or_without_pic
    src = "static int s = 5; int get(void) { return s; }"
    assert_equal compile(src, pic: false), compile(src, pic: true)
  end

  # --- gcc cross-check ---------------------------------------------------

  # gcc's own -fPIC access to an extern int uses a GOTPCREL(X) relocation
  # against that symbol, exactly the family rubycc selects — pinning the choice
  # to the ecosystem's.
  def test_gcc_uses_gotpcrel_for_extern_data
    skip "gcc not available" unless gcc_available?

    in_tmpdir do |dir|
      src = File.join(dir, "a.c")
      obj = File.join(dir, "a.o")
      File.write(src, "extern int x;\nint get(void) { return x; }\n")
      _out, status = Open3.capture2e("gcc", "-O0", "-fPIC", "-c", "-o", obj, src)
      assert status.success?, "gcc -fPIC failed"

      relocs = Reader.read_file(obj).relocations_for(".text")
      got = relocs.find { |r| r.symbol&.name == "x" }
      refute_nil got, "gcc should relocate the extern access against x"
      assert_includes [:R_X86_64_GOTPCREL, :R_X86_64_GOTPCRELX, :R_X86_64_REX_GOTPCRELX],
                      got.type_name, "gcc should reach x through the GOT under -fPIC"
    end
  end

  # --- acceptance: shared library round-trip (ROADMAP L4) ----------------

  # Two rubycc -fPIC objects — one referencing an extern int and an extern
  # function, the other defining them — link into a shared object with gcc, and
  # the result (a) carries no TEXTREL (every text reference is PC-relative), and
  # (b) round-trips a value through GOT-based extern data reads/writes and an
  # extern function called through a GOT-loaded pointer, dlopened via Fiddle.
  def test_pic_objects_link_into_a_shared_object_and_round_trip
    skip "gcc not available" unless gcc_available?

    access = <<~C
      extern int shared_counter;
      extern int bump(int by);
      typedef int (*fn)(int);
      int read_counter(void) { return shared_counter; }
      void write_counter(int v) { shared_counter = v; }
      int call_via_ptr(int x) { fn f = bump; return f(x); }
    C
    define = <<~C
      int shared_counter = 100;
      int bump(int by) { return by + 1; }
    C

    in_tmpdir do |dir|
      access_o = File.join(dir, "access.o")
      define_o = File.join(dir, "define.o")
      File.binwrite(access_o, compile(access, pic: true, filename: "access.c"))
      File.binwrite(define_o, compile(define, pic: true, filename: "define.c"))

      so = File.join(dir, "libpic.so")
      out, status = Open3.capture2e("gcc", "-shared", "-o", so, access_o, define_o)
      assert status.success?, "gcc -shared failed:\n#{out}"

      assert_no_textrel(so)

      lib = Fiddle.dlopen(so)
      read_counter = fiddle_fn(lib, "read_counter", [], Fiddle::TYPE_INT)
      write_counter = fiddle_fn(lib, "write_counter", [Fiddle::TYPE_INT], Fiddle::TYPE_VOID)
      call_via_ptr = fiddle_fn(lib, "call_via_ptr", [Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      assert_equal 100, read_counter.call, "initial extern data read through the GOT"
      write_counter.call(55)
      assert_equal 55, read_counter.call, "extern data write then read through the GOT"
      assert_equal 43, call_via_ptr.call(42), "extern function called through a GOT pointer"
    ensure
      lib&.close
    end
  end

  private

  def compile(src, pic:, filename: "a.c")
    Rubycc::Compiler.new.compile(src, filename: filename, pic: pic, target: host_target)
  end

  def text_relocs_raw(src, pic:)
    Reader.read(compile(src, pic: pic)).relocations_for(".text")
  end

  def text_relocs(src, pic:)
    text_relocs_raw(src, pic: pic).map { |r| [r.type_name, r.symbol&.name, r.addend] }
  end

  def text_bytes(src, pic:)
    Reader.read(compile(src, pic: pic)).section(".text").data
  end

  # Asserts the shared object has no DT_TEXTREL / DF_TEXTREL flag — i.e. no
  # relocation forces a writable text segment, which is the whole point of PIC.
  def assert_no_textrel(so)
    reader = Reader.read_file(so)
    reader.dynamic_entries.each do |entry|
      refute_equal DT_TEXTREL, entry.tag, "shared object must not carry DT_TEXTREL"
      if entry.tag == DT_FLAGS
        assert_equal 0, entry.value & DF_TEXTREL, "DF_TEXTREL must be clear"
      end
    end
  end

  def fiddle_fn(lib, name, args, ret)
    Fiddle::Function.new(lib[name], args, ret)
  end

  def in_tmpdir
    Dir.mktmpdir("rubycc-pic") { |dir| yield dir }
  end

  def gcc_available?
    @gcc_available ||= system("gcc", "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end
