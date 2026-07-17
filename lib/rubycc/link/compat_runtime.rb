# frozen_string_literal: true

require_relative "../compiler"
require_relative "../objfile/ar_archive"

module Rubycc
  module Link
    # rubycc's compiler-support runtime: the small set of symbols a CRuby built
    # by a compiler other than rubycc leaves for the C runtime to supply, and
    # which rubycc must therefore provide itself the way gcc's driver quietly
    # links libgcc. It is delivered as an `ar` archive appended to the tail of
    # every link so the linker's lazy member extraction pulls a definition in
    # *only* when an input actually references it; a link that never mentions one
    # of these symbols gets none of this code, exactly as if the archive were not
    # on the command line.
    #
    # The one member of record is rb_gc_guarded_ptr_val, the target of
    # RB_GC_GUARD's non-`__GNUC__` fallback (ruby/internal/memory.h). Because
    # rubycc deliberately does not define __GNUC__ (DESIGN R7), CRuby's macro
    # expands to a call to this function rather than the GNU inline-asm barrier;
    # yet a gcc-built CRuby, having taken the asm path itself, never exports the
    # function. The whole contract is to hand the pointer back untouched — the
    # call is itself the optimization barrier that keeps the guarded VALUE live,
    # and rubycc performs no optimization that the barrier would need to defeat.
    #
    # The archive is built by compiling the runtime's own C source *with rubycc*
    # (a self-host: rubycc compiles its own support code) into an ET_REL object,
    # then wrapping it in a one-member ranlib-indexed archive. Each entry in the
    # source table is one self-contained function so the set can grow a symbol at
    # a time without any member dragging in an unrelated definition.
    class CompatRuntime
      # The runtime's source fragments, keyed by the member name each is archived
      # under. One function per fragment keeps the lazy pull-in surgical: only the
      # fragment defining a referenced symbol is extracted. Compiled PIC because
      # the definitions land in shared objects.
      #
      # `volatile` is kept on the parameter and return types so the declaration
      # matches CRuby's own prototype spelling; it qualifies the pointee, not the
      # ABI, so it has no effect on the generated code. `val` is unused by design
      # — the argument exists only so the call site materializes the guarded
      # value as a real function argument, which is the entire point of the guard.
      SOURCES = {
        "rb_gc_guarded_ptr_val" => <<~C
          /* rubycc compat runtime: definitions CRuby's non-GNUC fallback paths
             reference. RB_GC_GUARD's fallback calls rb_gc_guarded_ptr_val, which a
             gcc-built CRuby does not export; returning the pointer unchanged is the
             whole contract (the call itself is the optimization barrier, and rubycc
             does not optimize). Pulled in lazily, only when referenced. */
          typedef unsigned long __rubycc_VALUE;
          volatile __rubycc_VALUE *rb_gc_guarded_ptr_val(volatile __rubycc_VALUE *ptr, __rubycc_VALUE val) {
            return ptr;
          }
        C
      }.freeze

      # A stable synthetic filename for each fragment's diagnostics and file
      # symbol, so a compile error (should the source ever regress) points at the
      # runtime rather than at a user file.
      SOURCE_FILENAME = "rubycc_compat_runtime.c"

      class << self
        # The compiler-support runtime as an `ar` archive (an ASCII-8BIT String),
        # ready to append to a link's input list. Memoized: the bytes are
        # deterministic (N4) and their construction — compiling every fragment —
        # is done once per process.
        def archive_bytes
          @archive_bytes ||= build_archive
        end

        private

        # Compiles each source fragment to a PIC ET_REL object and lays them out
        # as archive members in table order, producing a symbol-indexed archive
        # the linker can extract from lazily.
        def build_archive
          writer = ObjFile::ArWriter.new
          SOURCES.each do |name, source|
            object = Compiler.new.compile(source, filename: SOURCE_FILENAME, pic: true)
            writer.add_member("#{name}.o", object)
          end
          writer.to_binary
        end
      end
    end
  end
end
