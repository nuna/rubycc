# frozen_string_literal: true

require_relative "../objfile/elf_reader"
require_relative "../link/errors"
require_relative "../link/library_resolver"

module Rubycc
  module Preprocess
    # Measures the glibc minor version of the C library a compile will link
    # against, so <features.h>'s __GLIBC__/__GLIBC_MINOR__ can describe *this*
    # host instead of the machine the bundled headers were written on.
    #
    # rubycc ships one copy of the libc headers for every host (R8), so the
    # version those headers report used to be a constant: 39, the reference
    # platform's. On any other host that constant made version-gated header code
    # ("#if __GLIBC_PREREQ (2, 38)") select a different branch than the host's
    # own gcc does, and in the over-reporting direction — claiming 2.39 on a
    # 2.34 host — the selected branch can reach for a symbol that libc does not
    # have, which surfaces as an undefined symbol at link or dlopen time
    # (docs/development/GAPS.md gap U). The value therefore has to be measured, and the only
    # honest place to measure it is the C library itself: not the host's
    # /usr/include (a distroless target has none, which is the whole reason the
    # bundled headers exist) and not the host's gcc (rubycc must work without
    # one).
    #
    # What a glibc image states about itself is the set of symbol versions it
    # defines — GLIBC_2.2.5, GLIBC_2.3, ... GLIBC_2.39 — recorded in its
    # .gnu.version_d table, which ELFReader reads. The highest GLIBC_2.<n> it
    # defines is the newest interface it can satisfy, so <n> is what
    # __GLIBC_MINOR__ has to say for a version gate to pick a branch this libc
    # can actually back.
    #
    # That measure has one known way of coming out low: a glibc release that
    # added no new symbol to libc.so.6 gets no version node of its own (2.19,
    # 2.20, 2.21 and 2.37 are the releases where this happened), so on such a
    # host the highest node names the previous release. The result is then
    # conservative rather than wrong in the dangerous direction — a gate may
    # take an older branch, never one whose symbols are missing — but it does
    # differ from what the host's own headers say. Reading the version out of
    # glibc's banner string instead would be exact; it is not done here because
    # that means pattern-matching English prose in .rodata, whereas the version
    # table is a structure the ABI defines.
    #
    # Which file is "the C library" is a question about the *target*, never
    # about this host's own paths: the search runs through LibraryResolver with
    # the target's own system directories, exactly as the `-lc` of a real link
    # would, so a cross compile measures the cross libc and a host with no libc
    # at all measures nothing and falls back (see .minor_for).
    module GlibcVersion
      # The library request that finds the C library. Deliberately the same
      # spelling a link uses, so this reads whatever `-lc` would reach —
      # including through the GNU-ld script glibc installs as libc.so.
      LIBC_LIBRARY = "c"

      # A version node naming a whole glibc release: "GLIBC_2.39" and kin. The
      # three-component names ("GLIBC_2.2.5") and the non-release ones
      # ("GLIBC_PRIVATE", "GLIBC_ABI_DT_RELR") are not releases whose minor
      # number __GLIBC_MINOR__ could carry, so only this shape counts. The major
      # number is pinned at 2 for the same reason __GLIBC__ is: glibc has
      # carried it since 1997, and a 3.x would be a different ABI whose minor
      # number this measurement should not be feeding to a 2.x header anyway.
      # Naming glibc's own spelling here is not the hard-coded host identity
      # test/test_platform_literals.rb guards against: this module measures
      # glibc specifically, and a libc that spells its versions otherwise is
      # precisely the "not measurable" case (see .minor_in).
      RELEASE_VERSION = /\AGLIBC_2\.(\d+)\z/

      class << self
        # The measured glibc minor version for `target` (an architecture name or
        # triple, as LibraryResolver takes), or nil when this host has no glibc
        # to measure — no C library on the target's search path, a libc that is
        # not glibc (musl defines no version nodes), or one this reader cannot
        # parse. The caller decides what an unmeasurable host means; the
        # preprocessor falls back to the value the bundled <features.h> carries.
        #
        # Memoized per target for the life of the process: a translation unit
        # must not pay a 2 MB read of libc for a value that cannot change while
        # the compiler runs (N1). nil is memoized too, so a host without a libc
        # searches once rather than once per unit.
        def minor_for(target)
          cache = (@minor_for ||= {})
          return cache[target] if cache.key?(target)

          cache[target] = measure(target)
        end

        # The uncached measurement, kept separate so a caller (and the tests)
        # can ask for a fresh reading. The first library that states a version
        # settles it: the `-lc` resolution yields libc itself ahead of the
        # loader it names, and a glibc loader repeats libc's versions rather
        # than adding to them.
        def measure(target)
          libc_images(target).each do |path|
            minor = minor_in(path)
            return minor if minor
          end
          nil
        end

        # The highest glibc release version the shared object at `path` defines,
        # or nil when it defines none — which is the answer for a musl libc, for
        # a relocatable object, and for anything that is not an ELF file this
        # reader accepts. An unreadable file is likewise "cannot measure", not
        # an error: this runs on the way to a compile that must still happen.
        def minor_in(path)
          reader = ObjFile::ELFReader.read_file(path)
          reader.version_definitions.filter_map { |v| v.name[RELEASE_VERSION, 1]&.to_i }.max
        rescue ObjFile::ELFFormatError, SystemCallError, IOError
          nil
        end

        # The shared objects a `-lc` link for `target` would bind against, in
        # the order the linker sees them. A target with no C library on its
        # search path is not an error here (a cross target whose sysroot is not
        # installed, a musl image with no glibc): it simply cannot be measured.
        def libc_images(target)
          Link::LibraryResolver.resolve([LIBC_LIBRARY], target: target).needed
        rescue Link::LinkError, SystemCallError
          []
        end
      end
    end
  end
end
