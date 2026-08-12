# frozen_string_literal: true

require_relative "test_helper"
require_relative "abi_harness/harness"

# Step 62 (M5 H1): the ABI-verification harness, exercised first on the headers
# rubycc already ships -- the freestanding layer under include/ (stddef, stdarg,
# stdbool, stdalign, float). Each case compiles one probe program twice, against
# the real headers with gcc and against the bundled headers with rubycc, and
# asserts byte-identical output. This both proves those bundled headers are ABI
# compatible and gives the harness a green baseline before the bundled libc
# headers (the next step) start adding cases of their own.
#
# One freestanding discrepancy is deliberately *not* asserted here, because it
# is an open rubycc gap rather than a harness or header defect (see
# test/abi_harness/README.md): sizeof/_Alignof of max_align_t (rubycc models long
# double as 8-byte double, so the type is 16/8 where glibc's is 32/16). Every
# other freestanding check, including FLT_MAX, matches to the byte.
class TestHeaderAbi < Minitest::Test
  include ExecutionHelper
  include HeaderAbiHarness

  def setup
    skip "gcc unavailable (needed as the ABI oracle)" unless tool?("gcc")
    skip "system libc headers not found (/usr/include/stdio.h missing)" unless File.exist?("/usr/include/stdio.h")
    # Both sides of this differential are built for, and run on, this host's own
    # CPU (see HeaderAbiHarness#host_target), so a machine rubycc has no backend
    # for has nothing to compare here.
    skip_unless_host_target_supported
  end

  # <stddef.h>: the fundamental typedefs' widths and alignments, plus offsetof
  # against a probe struct (which exercises the harness's offset path and, since
  # both compilers lay the struct out per the psABI, must agree).
  STDDEF = HeaderAbiHarness::Spec.new(
    header: "stddef.h",
    sizes: %w[size_t ptrdiff_t wchar_t],
    snippets: ["struct abi_probe { char c; int i; double d; short s; };"],
    offsets: [["struct abi_probe", "c"], ["struct abi_probe", "i"],
              ["struct abi_probe", "d"], ["struct abi_probe", "s"]]
  )

  # <stdarg.h>: va_list's own width/alignment, and a variadic function that
  # actually uses the va_* macros as the compile-only "the macros are usable"
  # check. Running it also confirms the argument walk agrees with gcc's.
  STDARG = HeaderAbiHarness::Spec.new(
    header: "stdarg.h",
    sizes: %w[va_list],
    ints: ["abi_sum(4, 5, 15, 25, 55)"],
    snippets: [<<~C.chomp]
      static long abi_sum(int n, ...) {
        va_list ap; va_start(ap, n);
        long total = 0;
        for (int i = 0; i < n; i++) total += va_arg(ap, int);
        va_end(ap);
        return total;
      }
    C
  )

  # <stdbool.h>: _Bool's width, and the macro values the header defines.
  STDBOOL = HeaderAbiHarness::Spec.new(
    header: "stdbool.h",
    sizes: %w[bool],
    ints: %w[true false __bool_true_false_are_defined]
  )

  # <stdalign.h>: the feature macros, and that alignof maps onto _Alignof (so
  # alignof(T) yields the same alignment gcc's does for representative types).
  STDALIGN = HeaderAbiHarness::Spec.new(
    header: "stdalign.h",
    ints: ["__alignof_is_defined", "__alignas_is_defined",
           "alignof(double)", "alignof(long long)", "alignof(int)"]
  )

  # <float.h>: the integer characteristics of every floating type, and the
  # float/double magnitude macros compared as exact hex floats; every macro
  # listed here matches gcc exactly.
  FLOAT = HeaderAbiHarness::Spec.new(
    header: "float.h",
    ints: %w[FLT_RADIX FLT_EVAL_METHOD DECIMAL_DIG
             FLT_MANT_DIG FLT_DIG FLT_MIN_EXP FLT_MAX_EXP
             DBL_MANT_DIG DBL_DIG DBL_MIN_EXP DBL_MAX_EXP
             LDBL_MANT_DIG LDBL_DIG LDBL_MIN_EXP LDBL_MAX_EXP],
    floats: %w[FLT_MIN FLT_MAX FLT_EPSILON FLT_TRUE_MIN DBL_MAX DBL_MIN DBL_EPSILON DBL_TRUE_MIN]
  )

  # <iso646.h>: a header with no printable ABI surface at all; its correctness is
  # that the operator-spelling macros expand to usable operators, proven by the
  # snippet compiling under both toolchains (the pure declaration-existence case).
  ISO646 = HeaderAbiHarness::Spec.new(
    header: "iso646.h",
    snippets: ["static int abi_iso646(int a, int b) { return (a and b) or (a bitor b); }"]
  )

  # The scalar types rubycc admits under _Atomic, each probed twice -- bare and
  # under the parenthesized atomic-type-specifier -- so the claim the whole
  # implementation rests on ("_Atomic T has T's layout") is measured against gcc
  # type by type rather than assumed. `long double` is deliberately absent: it
  # is the one freestanding type rubycc already models differently (8-byte
  # double against x87's 16), so a row for it would report that known gap here
  # (see this file's header comment for the same exclusion around max_align_t).
  ATOMIC_SCALARS = %w[_Bool char signed\ char unsigned\ char
                      short unsigned\ short int unsigned\ int
                      long unsigned\ long long\ long unsigned\ long\ long
                      float double void\ * int\ * size_t ptrdiff_t].freeze

  # <stdatomic.h>: the layout claim above, the C11 typedefs, memory_order's
  # width and the memory-order constants' values, plus a snippet exercising
  # every generic macro the bundled header provides so a missing or unusable
  # one fails to compile on rubycc's side.
  #
  # The ATOMIC_*_LOCK_FREE macros are deliberately *not* probed: gcc answers 2
  # for all ten because it falls back to libatomic for the widths its ISA
  # cannot do inline, while rubycc refuses those operations outright and so
  # answers 0 for them (measured; see include/stdatomic.h). That is an intended
  # divergence, and the values are pinned in test_atomic_type.rb instead, where
  # they can be stated as rubycc's own answer rather than compared to gcc's.
  STDATOMIC = HeaderAbiHarness::Spec.new(
    header: "stdatomic.h",
    sizes: ATOMIC_SCALARS.flat_map { |type| [type, "_Atomic(#{type})"] } +
           %w[atomic_bool atomic_char atomic_schar atomic_uchar
              atomic_short atomic_ushort atomic_int atomic_uint
              atomic_long atomic_ulong atomic_llong atomic_ullong
              atomic_size_t atomic_ptrdiff_t memory_order],
    ints: %w[memory_order_relaxed memory_order_consume memory_order_acquire
             memory_order_release memory_order_acq_rel memory_order_seq_cst] +
          ["ATOMIC_VAR_INIT(7)", "kill_dependency(9)", "abi_stdatomic()"],
    snippets: [<<~C.chomp]
      static int abi_stdatomic(void) {
        atomic_int object;
        int expected;
        int total = 0;
        atomic_init(&object, 1);
        total += atomic_load(&object);
        total += atomic_load_explicit(&object, memory_order_acquire);
        atomic_store(&object, 2);
        atomic_store_explicit(&object, 3, memory_order_release);
        total += atomic_exchange(&object, 4);
        total += atomic_exchange_explicit(&object, 5, memory_order_acq_rel);
        total += atomic_fetch_add(&object, 6);
        total += atomic_fetch_add_explicit(&object, 7, memory_order_relaxed);
        total += atomic_fetch_sub(&object, 8);
        total += atomic_fetch_sub_explicit(&object, 9, memory_order_relaxed);
        expected = atomic_load(&object);
        total += atomic_compare_exchange_strong(&object, &expected, 10);
        total += atomic_compare_exchange_weak(&object, &expected, 11);
        total += atomic_compare_exchange_strong_explicit(&object, &expected, 12,
                                                         memory_order_acq_rel,
                                                         memory_order_relaxed);
        total += atomic_compare_exchange_weak_explicit(&object, &expected, 13,
                                                       memory_order_acq_rel,
                                                       memory_order_relaxed);
        atomic_thread_fence(memory_order_seq_cst);
        atomic_signal_fence(memory_order_seq_cst);
        return total + atomic_load(&object);
      }
    C
  )

  # ---------------------------------------------------------------------------
  # Step 63 (M3 B7): the bundled libc first batch. Each Spec probes the ABI
  # surface the bundled header commits to -- macro values, type widths, struct
  # layouts and the presence of the core declarations -- so it is machine-checked
  # against the host glibc rather than eyeballed. Snippets that merely need a
  # declaration to exist reference the symbol without calling it (or wrap it in
  # sizeof), so the probe links with plain gcc (no -lm) as the harness expects.
  # ---------------------------------------------------------------------------

  # <stdio.h>: the glibc macro values and that FILE* and the core stream calls
  # are usable. FILE itself is opaque, so it is probed only through a pointer.
  STDIO = HeaderAbiHarness::Spec.new(
    header: "stdio.h",
    sizes: %w[fpos_t],
    ints: %w[EOF SEEK_SET SEEK_CUR SEEK_END _IOFBF _IOLBF _IONBF
             BUFSIZ FOPEN_MAX FILENAME_MAX L_tmpnam TMP_MAX],
    snippets: [<<~C.chomp]
      static int abi_stdio(FILE *f, const char *s) {
        return fputc('x', f) + fputs(s, f) + (stdin != stdout);
      }
    C
  )

  # <stdlib.h>: the div_t family's LP64 layout, the exit/rand macros, and the
  # allocation/conversion declarations.
  STDLIB = HeaderAbiHarness::Spec.new(
    header: "stdlib.h",
    sizes: ["div_t", "ldiv_t", "lldiv_t", "size_t"],
    ints: %w[EXIT_SUCCESS EXIT_FAILURE RAND_MAX],
    offsets: [["div_t", "quot"], ["div_t", "rem"],
              ["ldiv_t", "quot"], ["ldiv_t", "rem"]],
    snippets: [<<~C.chomp]
      static long abi_stdlib(const char *s) {
        void *p = malloc(8); free(p);
        return strtol(s, (char **)0, 10) + atoi(s);
      }
    C
  )

  # <string.h>: the mem*/str* prototypes are present and usable. The
  # strcasecmp/strncasecmp calls are the regression guard for <string.h>
  # pulling in <strings.h> the way glibc does under __USE_MISC: with only
  # <string.h> included they must still resolve (Step 98, driven by redcarpet's
  # autolink.c), so this snippet failing to compile under rubycc would flag the
  # pull-in being dropped. strlcpy/strlcat guard their prototypes (Step 104,
  # driven by date's strftime).
  STRING = HeaderAbiHarness::Spec.new(
    header: "string.h",
    sizes: %w[size_t],
    snippets: [<<~C.chomp]
      static int abi_string(char *d, const char *s) {
        memcpy(d, s, strlen(s) + 1);
        return strcmp(d, s) + (memchr(s, 'a', 4) != (void *)0)
             + strcasecmp(d, s) + strncasecmp(d, s, 3)
             + (int)strlcpy(d, s, 8) + (int)strlcat(d, s, 16);
      }
    C
  )

  # <strings.h>: the BSD byte-string prototypes.
  STRINGS = HeaderAbiHarness::Spec.new(
    header: "strings.h",
    snippets: [<<~C.chomp]
      static int abi_strings(const char *a, const char *b) {
        return strcasecmp(a, b) + strncasecmp(a, b, 3) + ffs(0x10);
      }
    C
  )

  # <ctype.h>: glibc does not return a bare 0/1 -- the classifiers yield the
  # masked table bits, so the exact return values (and the _IS* masks) are part
  # of the ABI and are asserted here. The __ctype_*_loc accessors resolve from
  # the host libc at link time.
  CTYPE = HeaderAbiHarness::Spec.new(
    header: "ctype.h",
    ints: ["isalpha('a')", "isdigit('5')", "isspace(' ')", "isupper('A')",
           "islower('a')", "isxdigit('f')", "isalnum('z')", "ispunct('!')",
           "toupper('a')", "tolower('A')",
           # isascii/toascii (Step 98, driven by redcarpet's html.c): pure bit
           # tests with no locale table, so the value must match glibc exactly.
           "isascii('a')", "isascii(200)", "isascii(0)", "isascii(127)",
           "toascii(0x1FF)", "toascii('A')",
           HeaderAbiHarness::GLIBC_ONLY],
    # The whole _IS* set is glibc's own spelling of the classification table's
    # bits; musl has no equivalent names at all. Two musl runs measured four of
    # them failing on the oracle and none passing (_ISupper/_ISlower in Step
    # 175, _ISalpha/_ISdigit in Step 181, gcc truncating its report each time),
    # and they are one enum in glibc. The remaining three are moved on that
    # family reading rather than on their own measurement -- an inference, said
    # out loud, in place of two more hour-long CI rounds to name each one.
    glibc: { ints: %w[_ISupper _ISlower _ISalpha _ISdigit _ISspace
                      _ISblank _IScntrl _ISpunct _ISalnum] }
  )

  # <assert.h>: the assert macro expands to usable code (its __assert_fail hook
  # resolves from libc), and static_assert is available.
  ASSERT = HeaderAbiHarness::Spec.new(
    header: "assert.h",
    snippets: [<<~C.chomp]
      static_assert(sizeof(int) == 4, "int is 4 bytes");
      static int abi_assert(int x) { assert(x > 0); return x; }
    C
  )

  # <alloca.h>: alloca maps onto the compiler builtin.
  ALLOCA = HeaderAbiHarness::Spec.new(
    header: "alloca.h",
    snippets: ["static void *abi_alloca(unsigned long n) { return alloca(n); }"]
  )

  # <math.h>: the FP_* classification codes and math_errhandling value, the
  # special magnitudes and constants as exact hex floats, and that the core
  # function declarations exist (probed under sizeof so no libm link is needed).
  MATH = HeaderAbiHarness::Spec.new(
    header: "math.h",
    ints: %w[FP_NAN FP_INFINITE FP_ZERO FP_SUBNORMAL FP_NORMAL
             MATH_ERRNO MATH_ERREXCEPT math_errhandling FP_ILOGB0 FP_ILOGBNAN],
    floats: %w[M_PI M_E M_SQRT2 M_LN2 M_LOG2E HUGE_VAL],
    snippets: [<<~C.chomp]
      static int abi_math(double x) {
        return isnan(x) + isinf(x) + (signbit(x) != 0)
             + (sizeof(sqrt(x)) == 8) + (sizeof(pow(x, x)) == 8)
             + (sizeof(floor(x)) == 8) + (sizeof(ldexp(x, 2)) == 8);
      }
    C
  )

  # <limits.h>: the arithmetic-type ranges. The unsigned maxima print as -1 when
  # cast to (long long), but identically so on both sides, so they still verify.
  LIMITS = HeaderAbiHarness::Spec.new(
    header: "limits.h",
    ints: %w[CHAR_BIT MB_LEN_MAX SCHAR_MIN SCHAR_MAX UCHAR_MAX CHAR_MIN CHAR_MAX
             SHRT_MIN SHRT_MAX USHRT_MAX INT_MIN INT_MAX UINT_MAX
             LONG_MIN LONG_MAX ULONG_MAX LLONG_MIN LLONG_MAX ULLONG_MAX]
  )

  # <endian.h>: the byte-order identity macros and the host<->be/le conversions.
  ENDIAN = HeaderAbiHarness::Spec.new(
    header: "endian.h",
    ints: ["__BYTE_ORDER", "__LITTLE_ENDIAN", "__BIG_ENDIAN",
           "BYTE_ORDER", "LITTLE_ENDIAN", "BIG_ENDIAN",
           "htobe16(0x1234)", "htole16(0x1234)", "be16toh(0x1234)",
           "htobe32(0x12345678)", "be32toh(0x12345678)",
           "htole64(0x1122334455667788UL)", "htobe64(0x1122334455667788UL)"]
  )

  # <stdint.h>: the exact/least/fast widths and their limit and constant macros.
  STDINT = HeaderAbiHarness::Spec.new(
    header: "stdint.h",
    sizes: %w[int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t
              int_least8_t int_least16_t int_least32_t int_least64_t
              int_fast8_t int_fast16_t int_fast32_t int_fast64_t
              uint_fast8_t uint_fast16_t uint_fast32_t uint_fast64_t
              intptr_t uintptr_t intmax_t uintmax_t],
    ints: %w[INT8_MIN INT8_MAX UINT8_MAX INT16_MIN INT16_MAX UINT16_MAX
             INT32_MIN INT32_MAX UINT32_MAX INT64_MIN INT64_MAX UINT64_MAX
             INT_FAST16_MAX INT_FAST32_MAX INT_FAST64_MAX
             INTPTR_MAX UINTPTR_MAX INTMAX_MAX UINTMAX_MAX
             PTRDIFF_MAX SIZE_MAX SIG_ATOMIC_MIN SIG_ATOMIC_MAX
             WCHAR_MIN WCHAR_MAX WINT_MAX] +
          ["INT8_C(3)", "UINT8_C(3)", "INT64_C(3)", "UINT64_C(3)",
           "INTMAX_C(3)", "UINTMAX_C(3)"]
  )

  # <inttypes.h>: the imaxdiv_t layout, plus the PRI/SCN format-specifier macros
  # verified through their length and first character (so a wrong length modifier
  # for this LP64 ABI is caught), and the greatest-width call declarations.
  INTTYPES = HeaderAbiHarness::Spec.new(
    header: "inttypes.h",
    sizes: %w[imaxdiv_t],
    offsets: [["imaxdiv_t", "quot"], ["imaxdiv_t", "rem"]],
    ints: ["sizeof(PRId8)", "PRId8[0]", "sizeof(PRId64)", "PRId64[0]", "PRId64[1]",
           "sizeof(PRIu32)", "PRIu32[0]", "sizeof(PRIx64)", "PRIx64[0]",
           "sizeof(PRIdPTR)", "PRIdPTR[0]", "sizeof(PRIdMAX)", "PRIdMAX[0]",
           "sizeof(SCNd8)", "SCNd8[0]", "SCNd8[1]", "sizeof(SCNu16)", "SCNu16[0]",
           "sizeof(SCNx64)", "SCNx64[0]", "sizeof(SCNd32)", "SCNd32[0]"],
    snippets: [<<~C.chomp]
      static intmax_t abi_inttypes(const char *s) {
        return imaxabs(strtoimax(s, (char **)0, 10));
      }
    C
  )

  # <time.h>: time_t's width, struct tm's 56-byte glibc layout (tm_gmtoff/tm_zone
  # included), struct timespec, the CLOCKS_PER_SEC / clock-id macros, and the
  # calendar-call declarations.
  TIME = HeaderAbiHarness::Spec.new(
    header: "time.h",
    sizes: ["time_t", "clock_t", "struct tm", "struct timespec"],
    ints: %w[CLOCKS_PER_SEC TIME_UTC CLOCK_REALTIME CLOCK_MONOTONIC
             CLOCK_PROCESS_CPUTIME_ID TIMER_ABSTIME],
    offsets: [["struct tm", "tm_sec"], ["struct tm", "tm_min"], ["struct tm", "tm_hour"],
              ["struct tm", "tm_mday"], ["struct tm", "tm_mon"], ["struct tm", "tm_year"],
              ["struct tm", "tm_wday"], ["struct tm", "tm_yday"], ["struct tm", "tm_isdst"],
              ["struct tm", "tm_gmtoff"], ["struct tm", "tm_zone"],
              ["struct timespec", "tv_sec"], ["struct timespec", "tv_nsec"]],
    snippets: [<<~C.chomp]
      static time_t abi_time(struct tm *tp) {
        time_t t = time((time_t *)0);
        return t + mktime(tp) + (long)difftime(t, 0);
      }
    C
  )

  # <sys/types.h>: the width-critical POSIX typedefs.
  SYS_TYPES = HeaderAbiHarness::Spec.new(
    header: "sys/types.h",
    sizes: %w[ssize_t off_t pid_t uid_t gid_t mode_t dev_t ino_t nlink_t
              blksize_t blkcnt_t fsblkcnt_t time_t clock_t suseconds_t
              id_t key_t clockid_t timer_t]
  )

  # <sys/time.h>: struct timeval's 16-byte layout and the BSD time calls.
  SYS_TIME = HeaderAbiHarness::Spec.new(
    header: "sys/time.h",
    sizes: %w[struct\ timeval],
    offsets: [["struct timeval", "tv_sec"], ["struct timeval", "tv_usec"]],
    snippets: [<<~C.chomp]
      static int abi_systime(struct timeval *tv) {
        return gettimeofday(tv, (void *)0);
      }
    C
  )

  # <sys/select.h>: fd_set's 128-byte layout, FD_SETSIZE, and the FD_* macros.
  SYS_SELECT = HeaderAbiHarness::Spec.new(
    header: "sys/select.h",
    sizes: %w[fd_set],
    ints: %w[FD_SETSIZE],
    snippets: [<<~C.chomp]
      static int abi_select(int fd) {
        fd_set s; FD_ZERO(&s); FD_SET(fd, &s);
        return FD_ISSET(fd, &s); FD_CLR(fd, &s);
      }
    C
  )

  # <sys/select.h> then <signal.h>: both headers define sigset_t, each behind
  # its own typedef guard prior to this fix, so whichever header lost the race
  # to define it first would still see the other header's guard as unset and
  # redefine the type -- a conflict a Spec checking only one header at a time
  # could never surface. This pins the sys/select.h-first include order and
  # exercises fd_set and sigset_t together in one function, proving both
  # headers' declarations are live simultaneously.
  SIGSET_SELECT_FIRST = HeaderAbiHarness::Spec.new(
    header: "sys/select.h",
    also: ["signal.h"],
    sizes: %w[sigset_t],
    # __sigset_t is glibc's internal name for the type sigset_t is a typedef
    # of; musl has no such alias (measured on musl, Step 175: gcc fails on it).
    # The public sigset_t above is what the conflict this Spec pins is about,
    # and it is checked on either libc.
    glibc: { sizes: %w[__sigset_t] },
    snippets: [<<~C.chomp]
      static int abi_sigset_select_first(int fd) {
        fd_set f; FD_ZERO(&f); FD_SET(fd, &f);
        sigset_t s; sigemptyset(&s); sigaddset(&s, SIGINT);
        return FD_ISSET(fd, &f) + sigismember(&s, SIGINT);
      }
    C
  )

  # <signal.h> then <sys/select.h>: the same conflict as SIGSET_SELECT_FIRST
  # above but with the include order reversed, so the fix is proven regardless
  # of which header a gem happens to pull in first (ruby.h's defines.h reaches
  # <sys/select.h>; a gem's own source can #include <signal.h> before or after
  # that).
  SIGSET_SIGNAL_FIRST = HeaderAbiHarness::Spec.new(
    header: "signal.h",
    also: ["sys/select.h"],
    sizes: %w[sigset_t],
    # __sigset_t: glibc-only, for the same reason as SIGSET_SELECT_FIRST above.
    glibc: { sizes: %w[__sigset_t] },
    snippets: [<<~C.chomp]
      static int abi_sigset_signal_first(int fd) {
        sigset_t s; sigemptyset(&s); sigaddset(&s, SIGINT);
        fd_set f; FD_ZERO(&f); FD_SET(fd, &f);
        return sigismember(&s, SIGINT) + FD_ISSET(fd, &f);
      }
    C
  )

  # <unistd.h>: the standard file-descriptor and access-mode constants, the few
  # ABI-typed names' widths, and that the core system-call declarations exist.
  # _POSIX_MONOTONIC_CLOCK (Step 146 gap 4) is a measured POSIX option macro,
  # not a declaration, so it only needs the `ints` check below. _CS_PATH and
  # _PC_PIPE_BUF (Step 157 gap D) are the same kind of host-numbered macro as
  # the _SC_* set, and confstr/fpathconf/pathconf (Step 157 gap C) are proven
  # usable the same way sysconf already is, through the snippet call below.
  # ttyname_r (Step 167, M5 H6): io-console's other real-build gap alongside
  # termios.h's cfmakeraw, added as ttyname's POSIX reentrant pair; it carries
  # no numeric surface of its own, so it is likewise just called in the
  # snippet to prove it is usable. fdatasync() is a declaration-only check here:
  # bootsnap calls it, but invoking it in an ABI probe would make the probe
  # mutate a caller-supplied descriptor.
  UNISTD = HeaderAbiHarness::Spec.new(
    header: "unistd.h",
    sizes: %w[ssize_t off_t pid_t uid_t gid_t],
    ints: %w[STDIN_FILENO STDOUT_FILENO STDERR_FILENO F_OK R_OK W_OK X_OK
             SEEK_SET SEEK_CUR SEEK_END
             _SC_ARG_MAX _SC_CHILD_MAX _SC_CLK_TCK _SC_NGROUPS_MAX
             _SC_OPEN_MAX _SC_PAGESIZE _SC_PAGE_SIZE _SC_NPROCESSORS_CONF
             _SC_NPROCESSORS_ONLN _SC_PHYS_PAGES _SC_AVPHYS_PAGES _SC_IOV_MAX
             _POSIX_MONOTONIC_CLOCK _CS_PATH _PC_PIPE_BUF],
    snippets: [<<~C.chomp]
      static long abi_unistd(int fd, const char *path, void *buf, unsigned long n) {
        return read(fd, buf, n) + write(fd, buf, n) + pread(fd, buf, n, 0)
             + pwrite(fd, buf, n, 0) + close(fd) + getpid()
             + sysconf(_SC_PAGESIZE)
             + (long)confstr(_CS_PATH, (char *)buf, n)
             + fpathconf(fd, _PC_PIPE_BUF) + pathconf(path, _PC_PIPE_BUF)
             + ttyname_r(fd, (char *)buf, n) + (fdatasync != 0);
      }
    C
  )

  # <features.h>: the glibc version macros the version-gated header code branches
  # on. The whole header is glibc's own -- musl ships no <features.h> surface of
  # this kind, so its version-gate macros do not exist there (measured on musl,
  # Step 175: gcc fails on all three) -- so `libc:` marks the case as unrunnable
  # anywhere else rather than glibc-only checks being split out of it.
  FEATURES = HeaderAbiHarness::Spec.new(
    header: "features.h",
    libc: :glibc,
    ints: ["__GLIBC__", "__GLIBC_MINOR__", # platform-literal: names glibc's own feature-test macros, gated by `libc: :glibc` above
           # platform-literal: same glibc-only version gate, continued from the line above
           "__GLIBC_PREREQ(2, 17)", "__GLIBC_PREREQ(2, 99)", "__GLIBC_PREREQ(3, 0)"]
  )

  # <sys/cdefs.h>: the compiler-abstraction macros expand to usable code. The
  # __GNUC_PREREQ value is deliberately not asserted: rubycc does not define
  # __GNUC__ (DESIGN R7), so it evaluates to 0 where gcc yields 1 -- a real,
  # intended toolchain difference rather than a header defect. Like
  # <features.h>, the header itself is glibc's: on musl there is no
  # <sys/cdefs.h> to be the oracle at all (measured, Step 175: "fatal error:
  # sys/cdefs.h: No such file or directory"), hence `libc:`.
  SYS_CDEFS = HeaderAbiHarness::Spec.new(
    header: "sys/cdefs.h",
    libc: :glibc,
    snippets: [<<~C.chomp]
      __BEGIN_DECLS
      extern int abi_cdefs(int) __THROW __attribute_pure__;
      __END_DECLS
      static int abi_cdefs_use(int x) { return __glibc_likely(x > 0) ? x : -x; }
    C
  )

  # <errno.h> and <sys/stat.h> are (c)-group headers brought forward as measured
  # stubs so the distroless ruby.h build resolves; they are ABI-checked here too
  # since they ship and shadow the host copies. <errno.h>: the errno numbers and
  # the errno lvalue (its __errno_location hook resolves from libc).
  ERRNO = HeaderAbiHarness::Spec.new(
    header: "errno.h",
    ints: %w[EPERM ENOENT ESRCH EINTR EIO ENXIO E2BIG ENOEXEC EBADF ECHILD
             EAGAIN ENOMEM EACCES EFAULT EBUSY EEXIST ENODEV ENOTDIR EISDIR
             EINVAL EMFILE ENOSPC EPIPE ERANGE ENAMETOOLONG ENOSYS
             EWOULDBLOCK EDEADLK ECONNRESET ETIMEDOUT],
    snippets: ["static int abi_errno(void) { errno = 0; return errno; }"]
  )

  # <sys/stat.h>: struct stat's 144-byte kernel layout and the S_IF* mode bits.
  SYS_STAT = HeaderAbiHarness::Spec.new(
    header: "sys/stat.h",
    sizes: %w[struct\ stat mode_t],
    ints: ["S_IFMT", "S_IFDIR", "S_IFREG", "S_IFLNK", "S_IFCHR", "S_IFBLK",
           "S_IFIFO", "S_IFSOCK", "S_ISUID", "S_ISGID", "S_ISVTX", "S_IRWXU",
           "S_IRWXG", "S_IRWXO", "S_ISDIR(0040000)", "S_ISREG(0100000)"],
    offsets: [["struct stat", "st_dev"], ["struct stat", "st_ino"],
              ["struct stat", "st_nlink"], ["struct stat", "st_mode"],
              ["struct stat", "st_uid"], ["struct stat", "st_gid"],
              ["struct stat", "st_rdev"], ["struct stat", "st_size"],
              ["struct stat", "st_blksize"], ["struct stat", "st_blocks"],
              ["struct stat", "st_atim"], ["struct stat", "st_mtim"],
              ["struct stat", "st_ctim"]],
    snippets: ["static int abi_stat(const char *p, struct stat *b) { return stat(p, b); }"]
  )

  # <fcntl.h> (Step 83, M5 H2): an arch layer header like sys/stat.h -- the
  # O_DIRECT/O_DIRECTORY/O_NOFOLLOW bit assignments swap between x86-64 and
  # aarch64's kernel uapi/asm/fcntl.h, so the three are asserted here even
  # though they read the same value on this (x86-64) host as the arch-neutral
  # flags do; the aarch64 case below is what actually exercises the swap.
  # rubycc's bundled header exposes O_LARGEFILE/O_NOATIME/O_PATH/O_DIRECT/
  # O_TMPFILE unconditionally (no feature-test gating, matching sys/stat.h's
  # unconditional st_atim), but the host glibc gates those same names behind
  # __USE_GNU; `defines: ["_GNU_SOURCE"]` makes the oracle expose its full
  # surface too, so the comparison stays apples-to-apples.
  FCNTL = HeaderAbiHarness::Spec.new(
    header: "fcntl.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ flock off_t mode_t],
    ints: %w[O_RDONLY O_WRONLY O_RDWR O_ACCMODE
             O_CREAT O_EXCL O_NOCTTY O_TRUNC O_APPEND O_NONBLOCK O_NDELAY
             O_DSYNC O_ASYNC O_SYNC O_RSYNC O_CLOEXEC O_LARGEFILE O_NOATIME
             O_PATH O_DIRECT O_DIRECTORY O_NOFOLLOW O_TMPFILE
             F_DUPFD F_GETFD F_SETFD F_GETFL F_SETFL F_GETLK F_SETLK F_SETLKW
             F_SETOWN F_GETOWN F_DUPFD_CLOEXEC F_SETPIPE_SZ F_GETPIPE_SZ FD_CLOEXEC
             F_RDLCK F_WRLCK F_UNLCK
             AT_FDCWD AT_SYMLINK_NOFOLLOW AT_REMOVEDIR AT_SYMLINK_FOLLOW
             SEEK_SET SEEK_CUR SEEK_END],
    offsets: [["struct flock", "l_type"], ["struct flock", "l_whence"],
              ["struct flock", "l_start"], ["struct flock", "l_len"],
              ["struct flock", "l_pid"]],
    snippets: [<<~C.chomp]
      static int abi_fcntl(const char *p, struct flock *lk) {
        int fd = open(p, O_RDONLY | O_CLOEXEC);
        lk->l_type = F_RDLCK;
        return fcntl(fd, F_GETFD) + openat(AT_FDCWD, p, O_RDONLY) + creat(p, 0644);
      }
    C
  )

  # <poll.h> (Step 84, M5 H2): unlike fcntl.h, poll's ABI is arch-neutral --
  # struct pollfd's layout and every POLLIN/POLLOUT/... value are identical on
  # x86-64 and aarch64 -- so the header lives in the common layer and this Spec
  # is re-run byte-for-byte in the aarch64 class's neutral-layer section below.
  # `defines: ["_GNU_SOURCE"]` is needed for the same reason fcntl.h's Spec
  # needs it: rubycc's bundled header exposes the XOPEN (POLLRDNORM family) and
  # GNU (POLLREMOVE, POLLRDHUP) names unconditionally, while the host glibc
  # gates them behind __USE_XOPEN / __USE_GNU.
  POLL = HeaderAbiHarness::Spec.new(
    header: "poll.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ pollfd nfds_t],
    ints: %w[POLLIN POLLPRI POLLOUT POLLERR POLLHUP POLLNVAL
             POLLRDNORM POLLRDBAND POLLWRNORM POLLWRBAND POLLMSG] +
          [HeaderAbiHarness::GLIBC_ONLY] + %w[POLLRDHUP],
    # POLLREMOVE is one of the GNU names above: measured on musl (Step 175),
    # gcc there has no such macro. POLLRDHUP, which the same _GNU_SOURCE gate
    # covers on glibc, is left in the common list -- it is not among what musl's
    # gcc reported, so it stays checked there until a run says otherwise.
    glibc: { ints: %w[POLLREMOVE] },
    offsets: [["struct pollfd", "fd"], ["struct pollfd", "events"],
              ["struct pollfd", "revents"]],
    snippets: [<<~C.chomp]
      static int abi_poll(struct pollfd *fds, nfds_t n) {
        fds[0].events = POLLIN | POLLOUT;
        return poll(fds, n, 100);
      }
    C
  )

  # <dlfcn.h> (Step 85, M5 H2): the dynamic-loading interface. Its ABI is
  # arch-neutral -- every RTLD_* value is identical on x86-64 and aarch64 -- so
  # the header is in the common layer and this Spec is re-run in the aarch64
  # class's neutral-layer section. `defines: ["_GNU_SOURCE"]` is needed because
  # rubycc's bundled header exposes the glibc extensions (RTLD_NOLOAD,
  # RTLD_DEEPBIND, RTLD_NODELETE, RTLD_NEXT, RTLD_DEFAULT) unconditionally, while
  # the host glibc gates them behind __USE_GNU. RTLD_NEXT/RTLD_DEFAULT are
  # pointers, so they are exercised through the snippet rather than the int
  # checks. The dl* calls sit under sizeof (unevaluated, like <math.h>'s), so the
  # probe proves the declarations are usable without emitting a link reference --
  # dlopen in a statically linked aarch64 probe would otherwise pull the loader in.
  DLFCN = HeaderAbiHarness::Spec.new(
    header: "dlfcn.h",
    defines: ["_GNU_SOURCE"],
    ints: %w[RTLD_LAZY RTLD_NOW RTLD_GLOBAL RTLD_LOCAL RTLD_NOLOAD] +
          [HeaderAbiHarness::GLIBC_ONLY] + %w[RTLD_NODELETE],
    # RTLD_DEEPBIND is a glibc extension to dlopen's mode flags; musl has no
    # equivalent (measured, Step 175: gcc there fails on it). Its neighbours
    # RTLD_NOLOAD / RTLD_NODELETE and the RTLD_NEXT / RTLD_DEFAULT handles in
    # the snippet are not among what musl's gcc reported, so they stay in the
    # common list.
    glibc: { ints: %w[RTLD_DEEPBIND] },
    snippets: [<<~C.chomp]
      static unsigned long abi_dlfcn(const char *name, const char *sym) {
        return sizeof(dlopen(name, RTLD_LAZY | RTLD_GLOBAL))
             + sizeof(dlsym((void *)0, sym)) + sizeof(dlclose((void *)0))
             + sizeof(dlerror()) + (RTLD_NEXT != RTLD_DEFAULT);
      }
    C
  )

  # <sys/mman.h> (Step 86, M5 H2): the memory-mapping interface. Its ABI is
  # arch-neutral -- every PROT_/MAP_/MS_/MADV_ value is identical on x86-64 and
  # aarch64 (both use the asm-generic assignments) -- so the header is in the
  # common layer and this Spec is re-run in the aarch64 class's neutral-layer
  # section. `defines: ["_GNU_SOURCE"]` is needed because rubycc's bundled header
  # exposes the Linux MAP_* extensions, MAP_ANON and the MADV_* advice values
  # unconditionally, while the host glibc gates them behind __USE_MISC/__USE_GNU.
  MMAN = HeaderAbiHarness::Spec.new(
    header: "sys/mman.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[size_t off_t],
    ints: %w[PROT_NONE PROT_READ PROT_WRITE PROT_EXEC
             MAP_SHARED MAP_PRIVATE MAP_FIXED MAP_ANONYMOUS MAP_ANON
             MAP_GROWSDOWN MAP_LOCKED MAP_NORESERVE MAP_POPULATE MAP_STACK
             MS_ASYNC MS_INVALIDATE MS_SYNC
             MADV_NORMAL MADV_RANDOM MADV_SEQUENTIAL MADV_WILLNEED MADV_DONTNEED MADV_FREE],
    snippets: [<<~C.chomp]
      static int abi_mman(void *p, size_t n) {
        void *m = mmap(p, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (m == MAP_FAILED) return -1;
        madvise(m, n, MADV_DONTNEED);
        mprotect(m, n, PROT_READ);
        return munmap(m, n);
      }
    C
  )

  # <signal.h> (Step 87, M5 H2): the signalling interface. Its ABI is
  # arch-neutral -- every signal number, SA_ flag value and the sigset_t /
  # siginfo_t / struct sigaction layouts are identical on x86-64 and aarch64
  # (both use glibc's generic sigaction with the trailing sa_restorer and the
  # 128-byte sigset_t / siginfo_t) -- so the header lives in the common layer and
  # this Spec is re-run in the aarch64 class's neutral-layer section below. The
  # struct sigaction and siginfo_t offset checks lean on the header's member
  # macros (sa_handler -> __sigaction_handler.sa_handler, si_pid ->
  # _sifields.__sigchld.si_pid, ...), so a one-byte drift in the union layout is
  # caught against the gcc oracle. `defines: ["_GNU_SOURCE"]` is needed because
  # rubycc's bundled header exposes the SA_ extensions, SIGRTMIN/SIGRTMAX and the
  # full signal-number set unconditionally, while the host glibc gates them
  # behind __USE_XOPEN_EXTENDED / __USE_MISC / __USE_GNU. The sigaction / signal /
  # sigemptyset / sigaddset / kill / raise calls resolve from the static libc and
  # pull in no loader, so the snippet exercises them by real call.
  SIGNAL = HeaderAbiHarness::Spec.new(
    header: "signal.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[sig_atomic_t sigset_t struct\ sigaction siginfo_t],
    ints: %w[SIGHUP SIGINT SIGQUIT SIGILL SIGTRAP SIGABRT SIGBUS SIGFPE SIGKILL
             SIGUSR1 SIGSEGV SIGUSR2 SIGPIPE SIGALRM SIGTERM SIGSTKFLT SIGCHLD
             SIGCONT SIGSTOP SIGTSTP SIGTTIN SIGTTOU SIGURG SIGXCPU SIGXFSZ
             SIGVTALRM SIGPROF SIGWINCH SIGIO SIGPWR SIGSYS
             SIGRTMIN SIGRTMAX NSIG
             SIG_BLOCK SIG_UNBLOCK SIG_SETMASK
             SA_NOCLDSTOP SA_NOCLDWAIT SA_SIGINFO SA_ONSTACK SA_RESTART
             SA_NODEFER SA_RESETHAND],
    offsets: [["struct sigaction", "sa_handler"], ["struct sigaction", "sa_mask"],
              ["struct sigaction", "sa_flags"], ["struct sigaction", "sa_restorer"],
              ["siginfo_t", "si_signo"], ["siginfo_t", "si_errno"],
              ["siginfo_t", "si_code"], ["siginfo_t", "si_pid"],
              ["siginfo_t", "si_uid"], ["siginfo_t", "si_status"],
              ["siginfo_t", "si_addr"], ["siginfo_t", "si_band"],
              ["siginfo_t", "si_fd"]],
    snippets: [<<~C.chomp]
      static void abi_sig_handler(int s) { (void)s; }
      static int abi_signal(void) {
        struct sigaction sa;
        sigemptyset(&sa.sa_mask);
        sa.sa_handler = abi_sig_handler;
        sa.sa_flags = SA_RESTART;
        sigaction(SIGINT, &sa, (struct sigaction *)0);
        signal(SIGTERM, SIG_IGN);
        return kill(0, 0) + raise(0) + sigaddset(&sa.sa_mask, SIGUSR1);
      }
    C
  )

  # <sys/socket.h> (Step 88, M5 H2): the socket address structs and the core
  # socket calls. Its ABI is arch-neutral -- every AF_/PF_/SOCK_/SOL_/SO_/MSG_/
  # SHUT_ value and every struct layout (sockaddr, sockaddr_storage, msghdr,
  # iovec, cmsghdr and linger all included) is identical on x86-64 and aarch64
  # -- so the header lives in the common layer and this Spec is re-run in the
  # aarch64 class's neutral-layer section below. `defines: ["_GNU_SOURCE"]` is
  # needed because rubycc's bundled header exposes SOCK_CLOEXEC/SOCK_NONBLOCK,
  # MSG_NOSIGNAL and SO_REUSEPORT unconditionally, while the host glibc gates
  # them behind __USE_GNU / __USE_MISC. socket/bind/connect/send/recv/
  # setsockopt resolve from the static libc and pull in no loader, so the
  # snippet exercises them by real call against a loopback socket.
  SOCKET = HeaderAbiHarness::Spec.new(
    header: "sys/socket.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[socklen_t sa_family_t struct\ sockaddr struct\ sockaddr_storage
              struct\ msghdr struct\ iovec struct\ linger],
    ints: %w[AF_UNSPEC AF_UNIX AF_INET AF_INET6 AF_NETLINK PF_INET PF_NETLINK
             SOCK_STREAM SOCK_DGRAM SOCK_RAW SOCK_SEQPACKET SOCK_CLOEXEC SOCK_NONBLOCK
             SOL_SOCKET
             SO_REUSEADDR SO_TYPE SO_ERROR SO_BROADCAST SO_SNDBUF SO_RCVBUF
             SO_KEEPALIVE SO_LINGER SO_REUSEPORT
             MSG_OOB MSG_PEEK MSG_TRUNC MSG_DONTWAIT MSG_WAITALL MSG_NOSIGNAL
             SHUT_RD SHUT_WR SHUT_RDWR],
    offsets: [["struct sockaddr", "sa_family"], ["struct sockaddr", "sa_data"],
              ["struct msghdr", "msg_name"], ["struct msghdr", "msg_namelen"],
              ["struct msghdr", "msg_iov"], ["struct msghdr", "msg_iovlen"],
              ["struct msghdr", "msg_control"], ["struct msghdr", "msg_controllen"],
              ["struct msghdr", "msg_flags"],
              ["struct iovec", "iov_base"], ["struct iovec", "iov_len"]],
    snippets: [<<~C.chomp]
      static int abi_socket(const struct sockaddr *sa, socklen_t len) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (connect(fd, sa, len) < 0) return -1;
        char buf[4];
        return (int)recv(fd, buf, sizeof buf, MSG_PEEK) + (int)send(fd, buf, 1, 0);
      }

      /* accept4 on a listening socket that has nothing pending: the call is
         what is under test (the declaration and the libc definition behind it),
         so the interesting answer is the EAGAIN a non-blocking accept gives,
         not a connection. kgio calls it exactly this way. */
      static int abi_accept4(void) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        struct sockaddr_storage ss;
        socklen_t len = sizeof ss;
        if (fd < 0 || listen(fd, 1) < 0) return -1;
        int got = accept4(fd, (struct sockaddr *)&ss, &len, SOCK_NONBLOCK);
        return (got < 0) ? 1 : 0;
      }
    C
  )

  # <arpa/inet.h> (Step 64): brought forward for msgpack, which includes it for
  # the endian macros and the ntoh*/hton* conversions. The bundled header
  # collapses glibc's socket + UAPI fan-out to the flat surface the gem actually
  # uses, so the ABI checked is the byte-order conversions (constant-folded on
  # both sides to the same swapped value), the address types' widths and layout,
  # and that the inet_* / socklen_t declarations exist. The endian macros come in
  # through the same <endian.h> the endian case already asserts.
  ARPA_INET = HeaderAbiHarness::Spec.new(
    header: "arpa/inet.h",
    sizes: ["in_addr_t", "in_port_t", "socklen_t", "struct in_addr"],
    ints: ["ntohs(0x1234)", "ntohl(0x12345678)", "htons(0x1234)", "htonl(0x12345678)",
           "__BYTE_ORDER", "__LITTLE_ENDIAN", "__BIG_ENDIAN"],
    offsets: [["struct in_addr", "s_addr"]],
    snippets: [<<~C.chomp]
      static int abi_arpa_inet(struct in_addr *a, const char *s) {
        char buf[64]; socklen_t n = sizeof(buf);
        return inet_aton(s, a) + (int)inet_addr(s) + (inet_ntoa(*a) != (void *)0)
             + inet_pton(2, s, a) + (inet_ntop(2, a, buf, n) != (void *)0);
      }
    C
  )

  # <netinet/in.h> (Step 89, M5 H2): the IPv4/IPv6 address types, the
  # sockaddr_in / sockaddr_in6 structs and the IPPROTO_/INADDR_ values. Its ABI
  # is arch-neutral -- every struct layout (sockaddr_in, sockaddr_in6, in6_addr
  # all included) and every macro value is identical on x86-64 and aarch64 --
  # so the header lives in the common layer and this Spec is re-run in the
  # aarch64 class's neutral-layer section below. It shares in_addr_t/in_port_t/
  # struct in_addr/socklen_t with <arpa/inet.h> and sa_family_t with
  # <sys/socket.h> through the same guard macros, so `also: ["sys/socket.h"]`
  # pulls in AF_INET for the snippet without redefining anything.
  NETINET_IN = HeaderAbiHarness::Spec.new(
    header: "netinet/in.h",
    also: ["sys/socket.h", "string.h"],
    defines: ["_GNU_SOURCE"],
    sizes: %w[in_addr_t in_port_t sa_family_t struct\ in_addr struct\ in6_addr
              struct\ sockaddr_in struct\ sockaddr_in6],
    ints: %w[IPPROTO_IP IPPROTO_ICMP IPPROTO_TCP IPPROTO_UDP IPPROTO_IPV6 IPPROTO_RAW
             INADDR_ANY INADDR_LOOPBACK INADDR_BROADCAST INADDR_NONE
             INET_ADDRSTRLEN INET6_ADDRSTRLEN
             htons(0x1234) htonl(0x12345678)],
    offsets: [["struct sockaddr_in", "sin_family"], ["struct sockaddr_in", "sin_port"],
              ["struct sockaddr_in", "sin_addr"],
              ["struct sockaddr_in6", "sin6_family"], ["struct sockaddr_in6", "sin6_port"],
              ["struct sockaddr_in6", "sin6_flowinfo"], ["struct sockaddr_in6", "sin6_addr"],
              ["struct sockaddr_in6", "sin6_scope_id"]],
    snippets: [<<~C.chomp]
      static int abi_netinet(struct sockaddr_in *a) {
        struct in6_addr any = IN6ADDR_ANY_INIT;
        a->sin_family = AF_INET; a->sin_port = htons(80); a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        return (int)a->sin_addr.s_addr + any.s6_addr[15] + IPPROTO_TCP;
      }

      /* in6addr_any / in6addr_loopback are libc *objects*, not macros, so this
         case is about the definitions resolving at link time and holding the
         addresses the INIT macros spell. raindrops reaches for the address of
         one, which the initializer macros cannot give it. */
      static int abi_in6addr(void) {
        struct in6_addr any = IN6ADDR_ANY_INIT;
        struct in6_addr lo = IN6ADDR_LOOPBACK_INIT;
        return (memcmp(&in6addr_any, &any, sizeof any) == 0)
             + (memcmp(&in6addr_loopback, &lo, sizeof lo) == 0) * 2
             + in6addr_loopback.s6_addr[15];
      }
    C
  )

  # <netinet/tcp.h> (Step 90, M5 H2): the TCP-level socket-option names, used
  # with setsockopt at level IPPROTO_TCP. Arch-neutral (common layer). Only the
  # option macros are checked -- the header carries no struct rubycc reproduces.
  TCP = HeaderAbiHarness::Spec.new(
    header: "netinet/tcp.h",
    defines: ["_GNU_SOURCE"],
    ints: %w[TCP_NODELAY TCP_MAXSEG TCP_CORK TCP_KEEPIDLE TCP_KEEPINTVL
             TCP_KEEPCNT TCP_INFO TCP_QUICKACK TCP_USER_TIMEOUT TCP_FASTOPEN
             TCP_ESTABLISHED TCP_SYN_SENT TCP_SYN_RECV TCP_FIN_WAIT1 TCP_FIN_WAIT2
             TCP_TIME_WAIT TCP_CLOSE TCP_CLOSE_WAIT TCP_LAST_ACK TCP_LISTEN TCP_CLOSING],
    snippets: [<<~C.chomp]
      static int abi_tcp(void) { return TCP_NODELAY + TCP_KEEPIDLE; }
    C
  )

  # <sys/un.h> (Step 90, M5 H2): struct sockaddr_un, the AF_UNIX address. Its
  # 110-byte layout (a 108-byte sun_path) is arch-neutral (common layer).
  SOCKADDR_UN = HeaderAbiHarness::Spec.new(
    header: "sys/un.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ sockaddr_un],
    offsets: [["struct sockaddr_un", "sun_family"], ["struct sockaddr_un", "sun_path"]],
    snippets: [<<~C.chomp]
      static unsigned long abi_un(void) {
        struct sockaddr_un a; a.sun_family = 1; a.sun_path[0] = '/';
        return sizeof a.sun_path + a.sun_family;
      }
    C
  )

  # <pthread.h> (Step 91, M5 H2): the POSIX threads types and the core pthreads
  # calls. Unlike the socket/signal headers, pthread's ABI is arch dependent --
  # the opaque objects are wider on aarch64 (pthread_mutex_t 40->48,
  # pthread_attr_t 56->64, pthread_mutexattr_t / pthread_condattr_t 4->8) -- so
  # the header lives in the arch layer alongside fcntl.h and sys/stat.h, and the
  # aarch64 case below is in that class's arch-specific section rather than its
  # neutral one. The `sizes` list is the load-bearing check: every opaque type's
  # sizeof and _Alignof must match the (cross-)gcc oracle, which is exactly what
  # proves the measured arch-dependent __size[N] counts are right. `defines:
  # ["_GNU_SOURCE"]` matches the fcntl.h Spec's reason -- rubycc's bundled header
  # exposes its whole surface unconditionally while the host glibc gates parts of
  # pthread.h behind __USE_* feature-test macros. Every pthread_* call sits under
  # sizeof (unevaluated, like <dlfcn.h>'s dl* calls), so the probe proves the
  # declarations are usable without emitting a link reference -- a real pthread
  # reference in the statically linked aarch64 probe would otherwise pull the
  # pthread implementation in. The three PTHREAD_*_INITIALIZER macros and
  # PTHREAD_ONCE_INIT are exercised as file-scope static initializers.
  # pthread_kill and pthread_atfork (Step 146 gap 3) sit under the same
  # sizeof-unevaluated umbrella as every other call above (pthread_kill from
  # the glibc-only snippet, for the reason noted there) -- pthread_atfork
  # in particular must never be linked for real here, since glibc supplies it
  # only from libc_nonshared.a via a member that references __dso_handle
  # (Step 146 gap 6, unresolved).
  PTHREAD = HeaderAbiHarness::Spec.new(
    header: "pthread.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[pthread_t pthread_mutex_t pthread_cond_t pthread_rwlock_t
              pthread_attr_t pthread_mutexattr_t pthread_condattr_t
              pthread_rwlockattr_t pthread_once_t pthread_key_t pthread_spinlock_t],
    ints: %w[PTHREAD_MUTEX_NORMAL PTHREAD_MUTEX_RECURSIVE PTHREAD_MUTEX_ERRORCHECK
             PTHREAD_MUTEX_DEFAULT PTHREAD_CREATE_JOINABLE PTHREAD_CREATE_DETACHED
             PTHREAD_PROCESS_PRIVATE PTHREAD_PROCESS_SHARED PTHREAD_ONCE_INIT],
    # pthread_kill is declared by <pthread.h> on glibc but not on musl
    # (measured, Step 175: gcc there rejects it inside the snippet below, where
    # it used to sit next to pthread_self), so it is probed from a glibc-only
    # snippet of its own. Same sizeof-unevaluated treatment as every other call
    # here, for the same linking reason.
    glibc: { snippets: [<<~PTHREAD_KILL.chomp] },
      static unsigned long abi_pthread_kill(pthread_t t) {
        return sizeof(pthread_kill(t, 0));
      }
    PTHREAD_KILL
    snippets: [<<~C.chomp]
      static pthread_mutex_t  abi_m  = PTHREAD_MUTEX_INITIALIZER;
      static pthread_cond_t   abi_c  = PTHREAD_COND_INITIALIZER;
      static pthread_rwlock_t abi_rw = PTHREAD_RWLOCK_INITIALIZER;
      static pthread_once_t   abi_o  = PTHREAD_ONCE_INIT;
      static void  abi_once_init(void) { }
      static void *abi_thread_start(void *p) { return p; }
      static void  abi_atfork_hook(void) { }
      static unsigned long abi_pthread(pthread_t *t, pthread_attr_t *at,
                                       pthread_mutexattr_t *ma, pthread_key_t *k) {
        return sizeof(pthread_create(t, at, abi_thread_start, (void *)0))
             + sizeof(pthread_join(*t, (void **)0)) + sizeof(pthread_detach(*t))
             + sizeof(pthread_equal(*t, pthread_self())) + sizeof(pthread_self())
             + sizeof(pthread_mutex_init(&abi_m, ma)) + sizeof(pthread_mutex_lock(&abi_m))
             + sizeof(pthread_mutex_trylock(&abi_m)) + sizeof(pthread_mutex_unlock(&abi_m))
             + sizeof(pthread_mutex_destroy(&abi_m))
             + sizeof(pthread_cond_init(&abi_c, (const pthread_condattr_t *)0))
             + sizeof(pthread_cond_wait(&abi_c, &abi_m)) + sizeof(pthread_cond_signal(&abi_c))
             + sizeof(pthread_cond_broadcast(&abi_c)) + sizeof(pthread_cond_destroy(&abi_c))
             + sizeof(pthread_once(&abi_o, abi_once_init)) + sizeof(abi_rw)
             + sizeof(pthread_key_create(k, (void (*)(void *))0)) + sizeof(pthread_key_delete(*k))
             + sizeof(pthread_getspecific(*k)) + sizeof(pthread_setspecific(*k, (void *)0))
             + sizeof(pthread_attr_init(at)) + sizeof(pthread_attr_destroy(at))
             + sizeof(pthread_mutexattr_init(ma)) + sizeof(pthread_mutexattr_destroy(ma))
             + sizeof(pthread_mutexattr_settype(ma, PTHREAD_MUTEX_RECURSIVE))
             + sizeof(pthread_atfork(abi_atfork_hook, abi_atfork_hook, abi_atfork_hook));
      }
    C
  )

  # <setjmp.h> (Step 122, M5 H2): the non-local jump facility. Like pthread.h,
  # jmp_buf/sigjmp_buf are arch dependent -- glibc's saved register set is wider
  # on aarch64 -- so the header lives in the arch layer alongside pthread.h and
  # the aarch64 case below is in that class's arch-specific section. The `sizes`
  # check is load-bearing here too: jmp_buf/sigjmp_buf's sizeof and _Alignof must
  # match the (cross-)gcc oracle, proving the measured __size[N] counts are
  # right. setjmp/longjmp/_setjmp/_longjmp/sigsetjmp/siglongjmp are exercised
  # only inside unused static functions (the "declaration exists / is usable"
  # snippet pattern iso646.h's Spec already uses) rather than actually called
  # from main, since running longjmp would divert control flow away from the
  # probe entirely -- the point here is that the calls type-check against gcc,
  # not that the jump executes.
  SETJMP = HeaderAbiHarness::Spec.new(
    header: "setjmp.h",
    sizes: %w[jmp_buf sigjmp_buf],
    snippets: [<<~C.chomp]
      static int abi_setjmp(jmp_buf env) {
        int r = setjmp(env);
        if (r) longjmp(env, r + 1);
        return r;
      }
      static int abi_sigsetjmp(sigjmp_buf env) {
        int r = sigsetjmp(env, 1);
        if (r) siglongjmp(env, r + 1);
        return r;
      }
      static int abi_bsd_setjmp(jmp_buf env) {
        int r = _setjmp(env);
        if (r) _longjmp(env, r + 1);
        return r;
      }
      /* jmp_buf and sigjmp_buf must be the *same* type, not merely the same
         size: glibc spells both as arrays of one shared tag, so code that
         stores a jmp_buf and hands it to siglongjmp() compiles. Declaring them
         as two anonymous unions gave each its own distinct type and made that
         call a type error here while gcc accepted it (found building
         google-protobuf's ruby-upb.h). Passing each buffer to the other
         family's function is what pins the compatibility; the sizes above only
         pin the widths. */
      static int abi_setjmp_buffers_are_one_type(jmp_buf a, sigjmp_buf b) {
        int r = sigsetjmp(a, 0);
        if (r) siglongjmp(a, r + 1);
        r += setjmp(b);
        if (r) longjmp(b, r + 1);
        return r;
      }
    C
  )

  # <locale.h> (Step 122, M5 H2): struct lconv and the LC_* category numbers.
  # Unlike pthread.h/setjmp.h, struct lconv's layout is arch-neutral -- every
  # member is a pointer or char, and both x86-64 and aarch64 are LP64, so the
  # measured size and every member offset agree exactly across the two arches --
  # so the header lives in the common layer and this Spec is re-run in the
  # aarch64 class's neutral-layer section below. The LC_* values are glibc
  # runtime ABI (setlocale resolves from the host libc, so the numbers must
  # match the host's own enumeration), the same reasoning unistd.h's _SC_*
  # checks rest on.
  LOCALE = HeaderAbiHarness::Spec.new(
    header: "locale.h",
    sizes: %w[struct\ lconv],
    ints: %w[LC_ALL LC_COLLATE LC_CTYPE LC_MONETARY LC_NUMERIC LC_TIME LC_MESSAGES] +
          [HeaderAbiHarness::GLIBC_ONLY],
    # Every category beyond the POSIX six is glibc's own. LC_PAPER/LC_NAME were
    # measured on musl in Step 175 and LC_ADDRESS/LC_TELEPHONE/LC_MEASUREMENT in
    # Step 181; LC_IDENTIFICATION is moved with them on the family reading
    # rather than on its own measurement, since gcc truncated its report again.
    # The six the list keeps are the ones POSIX requires of every libc.
    glibc: { ints: %w[LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE
                      LC_MEASUREMENT LC_IDENTIFICATION] },
    offsets: [["struct lconv", "decimal_point"], ["struct lconv", "thousands_sep"],
              ["struct lconv", "grouping"], ["struct lconv", "int_frac_digits"],
              ["struct lconv", "frac_digits"]],
    snippets: [<<~C.chomp]
      static int abi_locale(void) {
        setlocale(LC_ALL, "C");
        struct lconv *lc = localeconv();
        return lc->frac_digits + lc->int_frac_digits;
      }
    C
  )

  # <pwd.h> (Step 123, M5 H2): the user database interface. struct passwd's
  # layout is arch-neutral -- every member is a pointer or uid_t/gid_t, and
  # both x86-64 and aarch64 are LP64, so the measured size and every member
  # offset agree exactly across the two arches -- so the header lives in the
  # common layer and this Spec is re-run in the aarch64 class's neutral-layer
  # section below. getpwnam/getpwuid/getpwent/setpwent/endpwent/getpwnam_r/
  # getpwuid_r resolve from the static libc at link time (a real call, unlike
  # dlfcn.h/pthread.h's sizeof-wrapped calls, since these are ordinary libc.a
  # symbols with no extra runtime library beyond the NSS modules the linker
  # warns -- harmlessly, since the harness only ever compiles and links these
  # functions but never calls them from main -- about needing at runtime).
  PWD = HeaderAbiHarness::Spec.new(
    header: "pwd.h",
    sizes: %w[struct\ passwd],
    offsets: [["struct passwd", "pw_name"], ["struct passwd", "pw_passwd"],
              ["struct passwd", "pw_uid"], ["struct passwd", "pw_gid"],
              ["struct passwd", "pw_gecos"], ["struct passwd", "pw_dir"],
              ["struct passwd", "pw_shell"]],
    snippets: [<<~C.chomp]
      static int abi_pwd(uid_t uid, const char *name, struct passwd *rb,
                          char *buf, size_t n, struct passwd **res) {
        struct passwd *p = getpwuid(uid);
        struct passwd *q = getpwnam(name);
        setpwent();
        struct passwd *r = getpwent();
        endpwent();
        return (p != (void *)0) + (q != (void *)0) + (r != (void *)0)
             + getpwnam_r(name, rb, buf, n, res) + getpwuid_r(uid, rb, buf, n, res);
      }
    C
  )

  # <grp.h> (Step 123, M5 H2): the group database interface. struct group's
  # layout is arch-neutral -- every member is a pointer or gid_t -- so the
  # header lives in the common layer and this Spec is re-run in the aarch64
  # class's neutral-layer section below. getgrnam/getgrgid/getgrent/setgrent/
  # endgrent/getgrnam_r/getgrgid_r resolve from the static libc the same way
  # pwd.h's do.
  GRP = HeaderAbiHarness::Spec.new(
    header: "grp.h",
    sizes: %w[struct\ group],
    offsets: [["struct group", "gr_name"], ["struct group", "gr_passwd"],
              ["struct group", "gr_gid"], ["struct group", "gr_mem"]],
    snippets: [<<~C.chomp]
      static int abi_grp(gid_t gid, const char *name, struct group *rb,
                          char *buf, size_t n, struct group **res) {
        struct group *p = getgrgid(gid);
        struct group *q = getgrnam(name);
        setgrent();
        struct group *r = getgrent();
        endgrent();
        return (p != (void *)0) + (q != (void *)0) + (r != (void *)0)
             + getgrnam_r(name, rb, buf, n, res) + getgrgid_r(gid, rb, buf, n, res);
      }
    C
  )

  # <sys/utsname.h> (Step 123, M5 H2): system identification. struct utsname's
  # layout (six 65-byte char arrays) is arch-neutral -- a plain char-array
  # struct has no arch-dependent field widths -- so the header lives in the
  # common layer and this Spec is re-run in the aarch64 class's neutral-layer
  # section below. uname resolves from the host libc at link time. `defines:
  # ["_GNU_SOURCE"]` is needed because rubycc's bundled header exposes the
  # sixth field unconditionally as `domainname`, while the host glibc only uses
  # that spelling (rather than `__domainname`) under __USE_GNU.
  UTSNAME = HeaderAbiHarness::Spec.new(
    header: "sys/utsname.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ utsname],
    offsets: [["struct utsname", "sysname"], ["struct utsname", "nodename"],
              ["struct utsname", "release"], ["struct utsname", "version"],
              ["struct utsname", "machine"], ["struct utsname", "domainname"]],
    snippets: [<<~C.chomp]
      static int abi_utsname(struct utsname *u) { return uname(u); }
    C
  )

  # <sys/uio.h> (Step 123, M5 H2): scatter/gather I/O. struct iovec's layout
  # (a pointer and a size_t) is arch-neutral -- so the header lives in the
  # common layer and this Spec is re-run in the aarch64 class's neutral-layer
  # section below. readv/writev resolve from the host libc at link time.
  UIO = HeaderAbiHarness::Spec.new(
    header: "sys/uio.h",
    sizes: %w[struct\ iovec],
    offsets: [["struct iovec", "iov_base"], ["struct iovec", "iov_len"]],
    snippets: [<<~C.chomp]
      static long abi_uio(int fd, const struct iovec *iov, int n) {
        return readv(fd, iov, n) + writev(fd, iov, n);
      }
    C
  )

  # <sys/resource.h> (Step 123, M5 H2): resource limits and usage. struct
  # rlimit (two rlim_t) and struct rusage (two struct timeval plus 14 longs)
  # are both arch-neutral -- rlim_t and struct timeval's members are all
  # 8-byte on either LP64 target -- so the header lives in the common layer
  # and this Spec is re-run in the aarch64 class's neutral-layer section
  # below. getrlimit/setrlimit/getrusage resolve from the host libc at link
  # time. `defines: ["_GNU_SOURCE"]` is needed because rubycc's bundled header
  # exposes RUSAGE_THREAD unconditionally, while the host glibc gates it behind
  # __USE_GNU.
  RESOURCE = HeaderAbiHarness::Spec.new(
    header: "sys/resource.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ rlimit struct\ rusage rlim_t],
    ints: %w[RLIMIT_CPU RLIMIT_FSIZE RLIMIT_DATA RLIMIT_STACK RLIMIT_CORE RLIMIT_RSS
             RLIMIT_NPROC RLIMIT_NOFILE RLIMIT_MEMLOCK RLIMIT_AS RLIMIT_LOCKS
             RLIMIT_SIGPENDING RLIMIT_MSGQUEUE RLIMIT_NICE RLIMIT_RTPRIO RLIMIT_RTTIME
             RLIMIT_NLIMITS RUSAGE_SELF RUSAGE_CHILDREN RUSAGE_THREAD],
    offsets: [["struct rlimit", "rlim_cur"], ["struct rlimit", "rlim_max"],
              ["struct rusage", "ru_utime"], ["struct rusage", "ru_stime"],
              ["struct rusage", "ru_maxrss"], ["struct rusage", "ru_ixrss"],
              ["struct rusage", "ru_idrss"], ["struct rusage", "ru_isrss"],
              ["struct rusage", "ru_minflt"], ["struct rusage", "ru_majflt"],
              ["struct rusage", "ru_nswap"], ["struct rusage", "ru_inblock"],
              ["struct rusage", "ru_oublock"], ["struct rusage", "ru_msgsnd"],
              ["struct rusage", "ru_msgrcv"], ["struct rusage", "ru_nsignals"],
              ["struct rusage", "ru_nvcsw"], ["struct rusage", "ru_nivcsw"]],
    snippets: [<<~C.chomp]
      static int abi_resource(struct rlimit *rl, struct rusage *ru) {
        return getrlimit(RLIMIT_NOFILE, rl) + setrlimit(RLIMIT_NOFILE, rl)
             + getrusage(RUSAGE_SELF, ru);
      }
    C
  )

  # <dirent.h> (Step 123, M5 H2): directory streams. struct dirent's glibc/
  # Linux layout (ino_t, off_t, d_reclen, d_type ahead of d_name) is arch-
  # neutral -- ino_t/off_t are both 8-byte on either LP64 target -- so the
  # header lives in the common layer and this Spec is re-run in the aarch64
  # class's neutral-layer section below. DIR is left an incomplete type (the
  # same public spelling glibc itself uses), so it is only ever probed through
  # a `DIR *`. opendir/readdir/closedir/rewinddir/readdir_r/fdopendir/dirfd
  # resolve from the host libc at link time.
  DIRENT = HeaderAbiHarness::Spec.new(
    header: "dirent.h",
    sizes: %w[struct\ dirent],
    ints: %w[DT_UNKNOWN DT_FIFO DT_CHR DT_DIR DT_BLK DT_REG DT_LNK DT_SOCK DT_WHT],
    offsets: [["struct dirent", "d_ino"], ["struct dirent", "d_off"],
              ["struct dirent", "d_reclen"], ["struct dirent", "d_type"],
              ["struct dirent", "d_name"]],
    snippets: [<<~C.chomp]
      static int abi_dirent(const char *path, int fd, struct dirent *entry,
                             struct dirent **result) {
        DIR *d1 = opendir(path);
        DIR *d2 = fdopendir(fd);
        struct dirent *e = readdir(d1);
        int rc = readdir_r(d1, entry, result);
        rewinddir(d1);
        int fdn = dirfd(d1);
        return (d1 != (void *)0) + (d2 != (void *)0) + (e != (void *)0)
             + rc + fdn + closedir(d1) + closedir(d2);
      }
    C
  )

  # <sched.h> (Step 123, M5 H2): pared to the surface etc/google-protobuf's
  # corpus samples reach (sched_yield, sched_getcpu, cpu_set_t's existence),
  # per the header's own provenance note. cpu_set_t's measured size/alignment
  # (128, 8-byte aligned) is arch-neutral -- so the header lives in the common
  # layer and this Spec is re-run in the aarch64 class's neutral-layer section
  # below. sched_yield/sched_getcpu resolve from the host libc at link time.
  # `defines: ["_GNU_SOURCE"]` is needed because the host glibc gates
  # cpu_set_t/CPU_SETSIZE/sched_getcpu behind __USE_GNU, while rubycc's
  # bundled header exposes them unconditionally.
  SCHED = HeaderAbiHarness::Spec.new(
    header: "sched.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[cpu_set_t],
    ints: %w[CPU_SETSIZE],
    snippets: [<<~C.chomp]
      static int abi_sched(void) { return sched_yield() + sched_getcpu(); }
    C
  )

  # <termios.h> (Step 124, M5 H2): pared to the surface io-console's corpus
  # sample reaches on the HAVE_TERMIOS_H path, per the header's own provenance
  # note. struct termios's layout (60 bytes; tcflag_t/speed_t are `unsigned
  # int`, cc_t is `unsigned char` on either LP64 target) is arch-neutral, so
  # the header lives in the common layer and this Spec is re-run in the
  # aarch64 class's neutral-layer section below. tcgetattr/tcsetattr/
  # tcflush/tcdrain/tcsendbreak/cfgetispeed/cfsetispeed/cfgetospeed/
  # cfsetospeed resolve from the host libc at link time. No `defines` is
  # needed: every name here (including XCASE, a Linux/glibc extension) is
  # already visible under gcc's default mode (implied _DEFAULT_SOURCE), which
  # is what compile_with_gcc uses (no -std flag), so the oracle's surface
  # already matches rubycc's flat one without a feature-test macro. cfmakeraw
  # (Step 167, M5 H6): a BSD/GNU extension with no numeric surface of its own,
  # added to the header when building io-console for real exposed it as a gap
  # the #include-only corpus census could not see; the snippet below calls it
  # to prove the declaration is usable (same treatment as the rest of this
  # Spec's calls).
  TERMIOS = HeaderAbiHarness::Spec.new(
    header: "termios.h",
    sizes: %w[struct\ termios speed_t tcflag_t cc_t],
    ints: %w[NCCS
             VINTR VQUIT VERASE VKILL VEOF VTIME VMIN VSWTC VSTART VSTOP VSUSP
             VEOL VREPRINT VDISCARD VWERASE VLNEXT VEOL2
             IGNBRK BRKINT IGNPAR PARMRK INPCK ISTRIP INLCR IGNCR ICRNL IXON
             IXANY IXOFF IMAXBEL IUTF8
             OPOST ONLCR OCRNL ONOCR ONLRET OFILL OFDEL
             CSIZE CS5 CS6 CS7 CS8 CSTOPB CREAD PARENB PARODD HUPCL CLOCAL
             ISIG ICANON ECHO ECHOE ECHOK ECHONL NOFLSH TOSTOP IEXTEN XCASE
             B0 B50 B75 B110 B134 B150 B200 B300 B600 B1200 B1800 B2400 B4800
             B9600 B19200 B38400
             TCSANOW TCSADRAIN TCSAFLUSH TCIFLUSH TCOFLUSH TCIOFLUSH],
    offsets: [["struct termios", "c_iflag"], ["struct termios", "c_oflag"],
              ["struct termios", "c_cflag"], ["struct termios", "c_lflag"],
              ["struct termios", "c_line"], ["struct termios", "c_cc"]],
    # The speed members are glibc's public spelling: musl keeps them under
    # reserved names (measured, Step 175: gcc there fails on c_ispeed and
    # c_ospeed, reporting __c_ispeed / __c_ospeed as struct termios's members
    # instead), so the two offsets are probed only where the public names are
    # the members. The struct's overall size, which is what a caller allocating
    # one depends on, is still checked on either libc through `sizes`.
    glibc: { offsets: [["struct termios", "c_ispeed"],
                       ["struct termios", "c_ospeed"]] },
    snippets: [<<~C.chomp]
      static int abi_termios(int fd, struct termios *t) {
        int rc = tcgetattr(fd, t);
        t->c_cc[VMIN] = 1;
        t->c_cc[VTIME] = 0;
        t->c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN | XCASE);
        rc += tcsetattr(fd, TCSANOW, t);
        rc += tcflush(fd, TCIFLUSH);
        rc += tcdrain(fd);
        rc += tcsendbreak(fd, 0);
        speed_t is = cfgetispeed(t);
        speed_t os = cfgetospeed(t);
        rc += cfsetispeed(t, is) + cfsetospeed(t, os);
        cfmakeraw(t);
        return rc;
      }
    C
  )

  # <sys/ioctl.h> (Step 124, M5 H2): pared to the surface io-console's corpus
  # sample reaches -- ioctl(2) itself and the TIOCGWINSZ/TIOCSWINSZ terminal
  # window size requests against struct winsize -- per the header's own
  # provenance note. struct winsize's layout (8 bytes, all `unsigned short`
  # members) and both request numbers are arch-neutral, so the header lives
  # in the common layer and this Spec is re-run in the aarch64 class's
  # neutral-layer section below. ioctl resolves from the host libc at link
  # time.
  IOCTL = HeaderAbiHarness::Spec.new(
    header: "sys/ioctl.h",
    sizes: %w[struct\ winsize],
    ints: %w[TIOCGWINSZ TIOCSWINSZ],
    offsets: [["struct winsize", "ws_row"], ["struct winsize", "ws_col"],
              ["struct winsize", "ws_xpixel"], ["struct winsize", "ws_ypixel"]],
    snippets: [<<~C.chomp]
      static int abi_ioctl(int fd, struct winsize *ws) {
        return ioctl(fd, TIOCGWINSZ, ws) + ioctl(fd, TIOCSWINSZ, ws);
      }
    C
  )

  # <sys/param.h> (Step 124, M5 H2): the traditional MIN/MAX/howmany/roundup
  # macros only, per the header's own provenance note (digest's corpus
  # sample never reaches this header at all in a userspace build -- its one
  # `#include <sys/param.h>` is gated behind `defined(_KERNEL) ||
  # defined(_STANDALONE)`). A pure macro-value check: these are rubycc's own
  # formulas re-deriving the same well-known results glibc's shim macros
  # produce, not copied text, so gcc and rubycc must agree on every sample
  # value regardless of which arch runs the check -- arch-neutral, common
  # layer, re-run in the aarch64 class's neutral-layer section below.
  SYS_PARAM = HeaderAbiHarness::Spec.new(
    header: "sys/param.h",
    ints: ["MIN(3, 5)", "MIN(5, 3)", "MAX(3, 5)", "MAX(5, 3)",
           "howmany(10, 3)", "howmany(9, 3)", "roundup(10, 8)", "roundup(16, 8)"]
  )

  # <sys/fcntl.h> (Step 124, M5 H2): the traditional compatibility alias for
  # <fcntl.h>, per the header's own provenance note. Its O_DIRECT/
  # O_DIRECTORY/O_NOFOLLOW values swap between x86-64 and aarch64 (they are
  # <fcntl.h>'s own values, reached through the alias), so this Spec lives
  # in the arch-specific section below (paralleling FCNTL) rather than being
  # re-run byte-for-byte in the neutral-layer section.
  SYS_FCNTL = HeaderAbiHarness::Spec.new(
    header: "sys/fcntl.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[struct\ flock],
    ints: %w[O_RDONLY O_CREAT O_DIRECT O_DIRECTORY O_NOFOLLOW],
    snippets: [<<~C.chomp]
      static int abi_sys_fcntl(const char *p) {
        int fd = open(p, O_RDONLY | O_CREAT, 0644);
        return fcntl(fd, F_GETFD);
      }
    C
  )

  # <sys/wait.h> (Step 135, M5 H2): waiting for process state changes, added
  # from the corpus census gap list (nio4r). Two things are checked here. The
  # option flags, the idtype_t enumerators and the SIGCHLD si_code values are
  # ordinary measured constants. The status-decoding macros are the
  # interesting part: rubycc re-derived the wait-status encoding rather than
  # copying glibc's macro bodies, so the `ints` list below exercises all eight
  # macros over a spread of statuses that hits every branch of that encoding
  # -- normal exit (0x2a00), a plain signal (0x0009), a signal with the core
  # flag (0x0089), the stopped marker (0x137f), continued (0xffff) and the
  # all-zero case -- and compares the exact value, not just truthiness (which
  # is what pins WCOREDUMP to the 0x80 flag bit rather than 1). Everything
  # here measured identical on x86-64 and aarch64, so the header is in the
  # common layer and this Spec is re-run in the aarch64 class's neutral-layer
  # section below. `defines: ["_GNU_SOURCE"]` is needed because rubycc's
  # bundled header exposes WCOREDUMP, the waitid option set and the __WALL
  # family unconditionally while the host glibc gates them behind
  # __USE_MISC / __USE_XOPEN_EXTENDED. wait/waitpid/waitid resolve from the
  # static libc at link time.
  WAIT = HeaderAbiHarness::Spec.new(
    header: "sys/wait.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[idtype_t pid_t id_t],
    ints: %w[WNOHANG WUNTRACED WCONTINUED WEXITED WSTOPPED WNOWAIT
             __WNOTHREAD __WALL __WCLONE
             P_ALL P_PID P_PGID
             CLD_EXITED CLD_KILLED CLD_DUMPED CLD_TRAPPED CLD_STOPPED CLD_CONTINUED] +
          ["WIFEXITED(0x0000)", "WEXITSTATUS(0x0000)", "WIFSIGNALED(0x0000)",
           "WTERMSIG(0x0000)", "WIFSTOPPED(0x0000)", "WIFCONTINUED(0x0000)",
           "WCOREDUMP(0x0000)",
           "WIFEXITED(0x2a00)", "WEXITSTATUS(0x2a00)", "WIFSIGNALED(0x2a00)",
           "WIFEXITED(0x0009)", "WIFSIGNALED(0x0009)", "WTERMSIG(0x0009)",
           "WCOREDUMP(0x0009)",
           "WIFSIGNALED(0x0089)", "WTERMSIG(0x0089)", "WCOREDUMP(0x0089)",
           "WIFEXITED(0x137f)", "WIFSIGNALED(0x137f)", "WIFSTOPPED(0x137f)",
           "WSTOPSIG(0x137f)",
           "WIFSTOPPED(0x007f)", "WSTOPSIG(0x007f)",
           "WIFCONTINUED(0xffff)", "WIFSTOPPED(0xffff)", "WIFSIGNALED(0xffff)",
           "WCOREDUMP(0xffff)", "WEXITSTATUS(0xff00)"],
    snippets: [<<~C.chomp]
      static int abi_wait(pid_t pid, int *st, siginfo_t *info) {
        pid_t a = wait(st);
        pid_t b = waitpid(pid, st, WNOHANG | WUNTRACED | WCONTINUED);
        int c = waitid(P_ALL, 0, info, WEXITED | WSTOPPED | WNOWAIT);
        return (int)a + (int)b + c
             + WIFEXITED(*st) + WEXITSTATUS(*st) + WIFSIGNALED(*st)
             + WTERMSIG(*st) + WIFSTOPPED(*st) + WSTOPSIG(*st)
             + WIFCONTINUED(*st) + WCOREDUMP(*st)
             + (info->si_code == CLD_EXITED);
      }
    C
  )

  # <sys/epoll.h> (Step 135, M5 H2): the Linux epoll(7) interface, added from
  # the corpus census gap list (nio4r, unicorn). Unlike poll.h, this one is an
  # arch-layer header: struct epoll_event is packed to 12 bytes on x86-64 (so
  # 32- and 64-bit processes see the same array stride) but takes its natural
  # 16-byte layout on aarch64, so the aarch64 case below sits in that class's
  # arch-specific section alongside FCNTL/PTHREAD/SETJMP rather than being
  # re-run as a neutral-layer check. The sizeof/_Alignof and the two offsets
  # are the load-bearing checks: they are exactly what proves the packed
  # attribute is present on one target and absent on the other. Every macro
  # value measured identical on both. `defines: ["_GNU_SOURCE"]` is needed
  # because the host glibc gates epoll_create1/EPOLL_CLOEXEC and the
  # EPOLLEXCLUSIVE/EPOLLWAKEUP extensions behind __USE_GNU, while rubycc's
  # bundled header exposes its whole surface unconditionally.
  # epoll_create/epoll_create1/epoll_ctl/epoll_wait resolve from the static
  # libc at link time.
  EPOLL = HeaderAbiHarness::Spec.new(
    header: "sys/epoll.h",
    defines: ["_GNU_SOURCE"],
    sizes: ["struct epoll_event", "union epoll_data", "epoll_data_t"],
    ints: %w[EPOLL_CTL_ADD EPOLL_CTL_DEL EPOLL_CTL_MOD EPOLL_CLOEXEC
             EPOLLIN EPOLLPRI EPOLLOUT EPOLLERR EPOLLHUP
             EPOLLRDNORM EPOLLRDBAND EPOLLWRNORM EPOLLWRBAND EPOLLMSG
             EPOLLRDHUP EPOLLEXCLUSIVE EPOLLWAKEUP EPOLLONESHOT EPOLLET] +
          ["sizeof(struct epoll_event[4])"],
    offsets: [["struct epoll_event", "events"], ["struct epoll_event", "data"],
              ["union epoll_data", "ptr"], ["union epoll_data", "fd"],
              ["union epoll_data", "u32"], ["union epoll_data", "u64"]],
    snippets: [<<~C.chomp]
      static int abi_epoll(int fd, struct epoll_event *out, int n) {
        int ep = epoll_create(1);
        int ep1 = epoll_create1(EPOLL_CLOEXEC);
        struct epoll_event ev;
        ev.events = EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP;
        ev.data.fd = fd;
        epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
        epoll_ctl(ep, EPOLL_CTL_MOD, fd, &ev);
        epoll_ctl(ep, EPOLL_CTL_DEL, fd, (struct epoll_event *)0);
        return ep + ep1 + epoll_wait(ep, out, n, 0) + (int)ev.data.u32;
      }
    C
  )

  # <langinfo.h> (Step 135, M5 H2): locale-dependent string lookup, added from
  # the corpus census gap list (nkf). nl_langinfo is answered by the host
  # libc, so every nl_item number has to match the host's own enumeration --
  # the same reasoning behind locale.h's LC_* and unistd.h's _SC_* checks --
  # and the numbering is a packed (category << 16 | index) composition rather
  # than a flat sequence, so the whole item set is asserted rather than a
  # sample. The three _NL_ITEM helpers are checked through sample expansions
  # so rubycc's own re-derivation of that composition is pinned against the
  # oracle's. Everything measured identical on x86-64 and aarch64, so the
  # header is in the common layer and this Spec is re-run in the aarch64
  # class's neutral-layer section below. `defines: ["_GNU_SOURCE"]` is needed
  # because the host glibc gates DECIMAL_POINT/THOUSANDS_SEP/YESSTR/NOSTR
  # behind __USE_GNU while rubycc's bundled header exposes them
  # unconditionally.
  LANGINFO = HeaderAbiHarness::Spec.new(
    header: "langinfo.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[nl_item],
    ints: %w[CODESET
             RADIXCHAR THOUSEP] +
          [HeaderAbiHarness::GLIBC_ONLY] +
          %w[ABDAY_1 ABDAY_2 ABDAY_3 ABDAY_4 ABDAY_5 ABDAY_6 ABDAY_7
             DAY_1 DAY_2 DAY_3 DAY_4 DAY_5 DAY_6 DAY_7
             ABMON_1 ABMON_2 ABMON_3 ABMON_4 ABMON_5 ABMON_6
             ABMON_7 ABMON_8 ABMON_9 ABMON_10 ABMON_11 ABMON_12
             MON_1 MON_2 MON_3 MON_4 MON_5 MON_6
             MON_7 MON_8 MON_9 MON_10 MON_11 MON_12
             AM_STR PM_STR D_T_FMT D_FMT T_FMT T_FMT_AMPM
             ERA ERA_D_FMT ALT_DIGITS ERA_D_T_FMT ERA_T_FMT
             CRNCYSTR YESEXPR NOEXPR YESSTR NOSTR],
    # Two groups, at two places in the list above, which is why the bundle
    # carries its own GLIBC_ONLY separator (see HeaderAbiHarness#abi_checks):
    # DECIMAL_POINT / THOUSANDS_SEP are glibc's aliases for RADIXCHAR / THOUSEP
    # and sit third (measured on musl, Step 175), while the _NL_ITEM macros are
    # glibc's item-encoding internals and sit last (measured in Step 181 --
    # musl's gcc reports them as implicit function declarations, having no such
    # macros). The items the aliases name are still checked on both libcs.
    # YESSTR / NOSTR stay common: no musl run has reported them.
    glibc: {
      ints: %w[DECIMAL_POINT THOUSANDS_SEP] +
            [HeaderAbiHarness::GLIBC_ONLY] +
            ["_NL_ITEM(2, 40)", "_NL_ITEM(5, 1)", "_NL_ITEM(0, 14)",
             "_NL_ITEM_CATEGORY(D_T_FMT)", "_NL_ITEM_INDEX(D_T_FMT)",
             "_NL_ITEM_CATEGORY(CODESET)", "_NL_ITEM_INDEX(CODESET)",
             "_NL_ITEM_CATEGORY(NOEXPR)", "_NL_ITEM_INDEX(NOEXPR)"]
    },
    snippets: [<<~C.chomp]
      static int abi_langinfo(void) {
        return (nl_langinfo(CODESET) != (char *)0)
             + (nl_langinfo(D_T_FMT) != (char *)0)
             + (nl_langinfo(RADIXCHAR) != (char *)0)
             + (nl_langinfo(YESEXPR) != (char *)0);
      }
    C
  )

  # <sys/timerfd.h> (Step 141, M5 H6): the Linux timerfd(2) family, added from
  # the corpus census gap list (nio4r, through libev's periodic-timer
  # backend). The four TFD_* values are the whole macro surface; two of them
  # share bits with the open(2) flags, which is the reason they are measured
  # rather than assumed (fcntl.h is an arch-layer header precisely because
  # some O_* names do differ between the targets, yet these two do not). The
  # struct itimerspec size and offsets are checked here too, because the
  # bundled header deliberately does not define that struct -- it reaches for
  # <time.h> -- so these lines are also the regression guard for that
  # include being dropped. Everything measured identical on x86-64 and
  # aarch64, so the header is in the common layer and this Spec is re-run in
  # the aarch64 class's neutral-layer section below.
  # timerfd_create/timerfd_settime/timerfd_gettime resolve from the static
  # libc at link time.
  TIMERFD = HeaderAbiHarness::Spec.new(
    header: "sys/timerfd.h",
    sizes: ["struct itimerspec", "struct timespec", "clockid_t"],
    ints: %w[TFD_CLOEXEC TFD_NONBLOCK TFD_TIMER_ABSTIME TFD_TIMER_CANCEL_ON_SET
             CLOCK_REALTIME CLOCK_MONOTONIC],
    offsets: [["struct itimerspec", "it_interval"], ["struct itimerspec", "it_value"]],
    snippets: [<<~C.chomp]
      static int abi_timerfd(void) {
        struct itimerspec its;
        its.it_interval.tv_sec = 0; its.it_interval.tv_nsec = 0;
        its.it_value.tv_sec = 1; its.it_value.tv_nsec = 0;
        int fd = timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC | TFD_NONBLOCK);
        int a = timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET,
                                &its, (struct itimerspec *)0);
        int b = timerfd_gettime(fd, &its);
        return fd + a + b;
      }
    C
  )

  # <sys/inotify.h> (Step 141, M5 H6): the Linux inotify(7) interface, added
  # from the corpus census gap list (nio4r, through libev's ev_stat backend).
  # struct inotify_event ends in a flexible array member, so its sizeof and
  # every offset are the load-bearing checks: a wrong tail assumption would
  # silently shift every event in a read buffer, since callers walk the
  # buffer by `sizeof(struct inotify_event) + ev->len`. That expression is in
  # the snippet for the same reason. The whole IN_ mask set is asserted (not
  # sampled) because these are kernel-defined bits a caller ORs together, and
  # IN_ALL_EVENTS / IN_CLOSE / IN_MOVE additionally pin rubycc's own
  # composition of them. Everything measured identical on x86-64 and aarch64,
  # so the header is in the common layer and this Spec is re-run in the
  # aarch64 class's neutral-layer section below. `defines: ["_GNU_SOURCE"]`
  # is needed because the host glibc gates inotify_init1 / IN_CLOEXEC /
  # IN_NONBLOCK behind __USE_GNU while rubycc's bundled header exposes its
  # whole surface unconditionally.
  #
  # The array-stride check the EPOLL Spec makes with
  # `sizeof(struct epoll_event[4])` has no counterpart here on purpose: C
  # forbids a struct with a flexible array member as an array element
  # (6.7.2.1), gcc allows `struct inotify_event[3]` as an extension, and
  # rubycc rejects it -- a divergence in rubycc's favour, and one the probe
  # must not depend on. The stride that actually matters for this type is the
  # runtime one, `sizeof(struct inotify_event) + ev->len`, which the snippet
  # exercises instead.
  INOTIFY = HeaderAbiHarness::Spec.new(
    header: "sys/inotify.h",
    defines: ["_GNU_SOURCE"],
    sizes: ["struct inotify_event"],
    ints: %w[IN_CLOEXEC IN_NONBLOCK
             IN_ACCESS IN_MODIFY IN_ATTRIB IN_CLOSE_WRITE IN_CLOSE_NOWRITE
             IN_OPEN IN_MOVED_FROM IN_MOVED_TO IN_CREATE IN_DELETE
             IN_DELETE_SELF IN_MOVE_SELF
             IN_CLOSE IN_MOVE IN_ALL_EVENTS
             IN_UNMOUNT IN_Q_OVERFLOW IN_IGNORED
             IN_ONLYDIR IN_DONT_FOLLOW IN_EXCL_UNLINK IN_MASK_CREATE
             IN_MASK_ADD IN_ISDIR IN_ONESHOT],
    offsets: [["struct inotify_event", "wd"], ["struct inotify_event", "mask"],
              ["struct inotify_event", "cookie"], ["struct inotify_event", "len"],
              ["struct inotify_event", "name"]],
    snippets: [<<~C.chomp]
      static int abi_inotify(const char *path, char *buf, int nbytes) {
        int fd = inotify_init();
        int fd1 = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
        int wd = inotify_add_watch(fd1, path,
                                   IN_ATTRIB | IN_MODIFY | IN_CREATE | IN_DELETE
                                   | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF
                                   | IN_MOVE_SELF | IN_DONT_FOLLOW | IN_MASK_ADD);
        int total = 0, ofs = 0;
        while (ofs < nbytes) {
          struct inotify_event *ev = (struct inotify_event *)(buf + ofs);
          total += (int)(ev->mask & (IN_IGNORED | IN_UNMOUNT | IN_ISDIR)) + ev->wd
                 + (int)ev->cookie;
          ofs += (int)(sizeof(struct inotify_event) + ev->len);
        }
        return fd + wd + total + inotify_rm_watch(fd1, wd);
      }
    C
  )

  # <sys/statfs.h> (Step 141, M5 H6): the Linux statfs(2) interface, added
  # from the corpus census gap list (nio4r, through libev's ev_stat backend
  # deciding whether a filesystem is local). Every member's offset AND its
  # size are asserted, because the interesting failure mode here is a member
  # that is the right width on one target and not the other: the kernel has
  # both a 32-bit-counter and a 64-bit-counter statfs layout, and glibc
  # writes the members in terms of word-sized typedefs. Measured, both LP64
  # targets land on the same all-64-bit 120-byte layout, so the header is in
  # the common layer and this Spec is re-run in the aarch64 class's
  # neutral-layer section below. The `sfs.f_type == 0x9123683eL` compare in
  # the snippet is the shape libev uses and only behaves as intended on a
  # signed 64-bit field, so it doubles as the signedness guard.
  STATFS = HeaderAbiHarness::Spec.new(
    header: "sys/statfs.h",
    sizes: ["struct statfs"],
    # __fsid_t is glibc's internal name for the f_fsid member's type; musl has
    # no such alias (measured, Step 175: gcc there fails on it). The member
    # itself is still checked on either libc, through the offset, the sizeof
    # expression and the snippet's f_fsid.__val[0] read.
    glibc: { sizes: ["__fsid_t"] },
    ints: ["sizeof(((struct statfs *)0)->f_type)",
           "sizeof(((struct statfs *)0)->f_bsize)",
           "sizeof(((struct statfs *)0)->f_blocks)",
           "sizeof(((struct statfs *)0)->f_bfree)",
           "sizeof(((struct statfs *)0)->f_bavail)",
           "sizeof(((struct statfs *)0)->f_files)",
           "sizeof(((struct statfs *)0)->f_ffree)",
           "sizeof(((struct statfs *)0)->f_namelen)",
           "sizeof(((struct statfs *)0)->f_frsize)",
           "sizeof(((struct statfs *)0)->f_flags)",
           "sizeof(((struct statfs *)0)->f_spare)",
           "sizeof(((struct statfs *)0)->f_fsid)"],
    offsets: [["struct statfs", "f_type"], ["struct statfs", "f_bsize"],
              ["struct statfs", "f_blocks"], ["struct statfs", "f_bfree"],
              ["struct statfs", "f_bavail"], ["struct statfs", "f_files"],
              ["struct statfs", "f_ffree"], ["struct statfs", "f_fsid"],
              ["struct statfs", "f_namelen"], ["struct statfs", "f_frsize"],
              ["struct statfs", "f_flags"], ["struct statfs", "f_spare"]],
    snippets: [<<~C.chomp]
      static int abi_statfs(const char *path, int fd) {
        struct statfs sfs;
        int a = statfs(path, &sfs);
        int b = fstatfs(fd, &sfs);
        return a + b
             + (sfs.f_type == 0x9123683eL)
             + (int)(sfs.f_bsize + sfs.f_frsize + sfs.f_namelen + sfs.f_flags)
             + (int)(sfs.f_blocks + sfs.f_bfree + sfs.f_bavail
                     + sfs.f_files + sfs.f_ffree)
             + sfs.f_fsid.__val[0];
      }
    C
  )

  # <sys/syscall.h> (Step 141, M5 H6): the SYS_ system-call numbers, added
  # from the corpus census gap list (nio4r; libev issues clock_gettime, the
  # eventfd/signalfd/inotify/epoll creation calls and the linux-aio and
  # io_uring operations by raw number). This is an arch-layer header -- the
  # x86-64 and aarch64 tables disagree on essentially every entry, so the
  # aarch64 case below sits in that class's arch-specific section alongside
  # FCNTL/PTHREAD/SETJMP/EPOLL rather than being re-run as a neutral check --
  # and the numbers ARE the entire ABI surface, so every name the bundled
  # header defines is asserted rather than sampled. Both spellings are
  # checked: the __NR_ names and the SYS_ aliases the header derives from
  # them, since third-party code writes either. `syscall(SYS_getpid)` in the
  # snippet is the end-to-end check that a measured number actually reaches
  # the kernel entry point it names. The prototype is declared locally because
  # <sys/syscall.h> itself does not supply it; glibc keeps it in <unistd.h>,
  # and rubycc exposes it there too for users that include that header.
  SYSCALL_NUMBERS = %w[read write close lseek openat readlinkat faccessat
                       ioctl fcntl pipe2 dup3 statfs fstatfs
                       mmap mprotect munmap
                       clone exit exit_group getpid gettid kill tgkill
                       rt_sigaction rt_sigprocmask futex sched_yield getcpu
                       membarrier getrandom
                       nanosleep clock_gettime clock_nanosleep
                       epoll_create1 epoll_ctl epoll_pwait ppoll pselect6
                       eventfd2 signalfd4
                       inotify_init1 inotify_add_watch inotify_rm_watch
                       timerfd_create timerfd_settime timerfd_gettime
                       io_setup io_destroy io_getevents io_submit io_cancel
                       io_uring_setup io_uring_enter io_uring_register
                       socket setsockopt].freeze

  SYSCALL = HeaderAbiHarness::Spec.new(
    header: "sys/syscall.h",
    defines: ["_GNU_SOURCE"],
    ints: SYSCALL_NUMBERS.map { |name| "SYS_#{name}" } +
          SYSCALL_NUMBERS.map { |name| "__NR_#{name}" },
    snippets: [<<~C.chomp]
      extern long syscall(long __number, ...);
      static long abi_syscall(void) {
        return syscall(SYS_getpid) + syscall(SYS_sched_yield);
      }
    C
  )

  def test_wait_abi_matches_gcc
    assert_abi_matches(WAIT)
  end

  def test_timerfd_abi_matches_gcc
    assert_abi_matches(TIMERFD)
  end

  def test_inotify_abi_matches_gcc
    assert_abi_matches(INOTIFY)
  end

  def test_statfs_abi_matches_gcc
    assert_abi_matches(STATFS)
  end

  def test_syscall_abi_matches_gcc
    assert_abi_matches(SYSCALL)
  end

  def test_epoll_abi_matches_gcc
    assert_abi_matches(EPOLL)
  end

  def test_langinfo_abi_matches_gcc
    assert_abi_matches(LANGINFO)
  end

  def test_pwd_abi_matches_gcc
    assert_abi_matches(PWD)
  end

  def test_grp_abi_matches_gcc
    assert_abi_matches(GRP)
  end

  def test_utsname_abi_matches_gcc
    assert_abi_matches(UTSNAME)
  end

  def test_uio_abi_matches_gcc
    assert_abi_matches(UIO)
  end

  def test_resource_abi_matches_gcc
    assert_abi_matches(RESOURCE)
  end

  def test_dirent_abi_matches_gcc
    assert_abi_matches(DIRENT)
  end

  def test_sched_abi_matches_gcc
    assert_abi_matches(SCHED)
  end

  def test_termios_abi_matches_gcc
    assert_abi_matches(TERMIOS)
  end

  def test_ioctl_abi_matches_gcc
    assert_abi_matches(IOCTL)
  end

  def test_sys_param_abi_matches_gcc
    assert_abi_matches(SYS_PARAM)
  end

  def test_sys_fcntl_abi_matches_gcc
    assert_abi_matches(SYS_FCNTL)
  end

  def test_arpa_inet_abi_matches_gcc
    assert_abi_matches(ARPA_INET)
  end

  def test_netinet_in_abi_matches_gcc
    assert_abi_matches(NETINET_IN)
  end

  def test_tcp_abi_matches_gcc
    assert_abi_matches(TCP)
  end

  def test_un_abi_matches_gcc
    assert_abi_matches(SOCKADDR_UN)
  end

  def test_pthread_abi_matches_gcc
    assert_abi_matches(PTHREAD)
  end

  def test_setjmp_abi_matches_gcc
    assert_abi_matches(SETJMP)
  end

  def test_locale_abi_matches_gcc
    assert_abi_matches(LOCALE)
  end

  def test_errno_abi_matches_gcc
    assert_abi_matches(ERRNO)
  end

  def test_sys_stat_abi_matches_gcc
    assert_abi_matches(SYS_STAT)
  end

  def test_fcntl_abi_matches_gcc
    assert_abi_matches(FCNTL)
  end

  def test_poll_abi_matches_gcc
    assert_abi_matches(POLL)
  end

  def test_dlfcn_abi_matches_gcc
    assert_abi_matches(DLFCN)
  end

  def test_mman_abi_matches_gcc
    assert_abi_matches(MMAN)
  end

  def test_signal_abi_matches_gcc
    assert_abi_matches(SIGNAL)
  end

  def test_socket_abi_matches_gcc
    assert_abi_matches(SOCKET)
  end

  def test_stdio_abi_matches_gcc
    assert_abi_matches(STDIO)
  end

  def test_stdlib_abi_matches_gcc
    assert_abi_matches(STDLIB)
  end

  def test_string_abi_matches_gcc
    assert_abi_matches(STRING)
  end

  def test_strings_abi_matches_gcc
    assert_abi_matches(STRINGS)
  end

  def test_ctype_abi_matches_gcc
    assert_abi_matches(CTYPE)
  end

  def test_assert_abi_matches_gcc
    assert_abi_matches(ASSERT)
  end

  def test_alloca_abi_matches_gcc
    assert_abi_matches(ALLOCA)
  end

  def test_math_abi_matches_gcc
    assert_abi_matches(MATH)
  end

  def test_limits_abi_matches_gcc
    assert_abi_matches(LIMITS)
  end

  def test_endian_abi_matches_gcc
    assert_abi_matches(ENDIAN)
  end

  def test_stdint_abi_matches_gcc
    assert_abi_matches(STDINT)
  end

  def test_inttypes_abi_matches_gcc
    assert_abi_matches(INTTYPES)
  end

  def test_time_abi_matches_gcc
    assert_abi_matches(TIME)
  end

  def test_sys_types_abi_matches_gcc
    assert_abi_matches(SYS_TYPES)
  end

  def test_sys_time_abi_matches_gcc
    assert_abi_matches(SYS_TIME)
  end

  def test_sys_select_abi_matches_gcc
    assert_abi_matches(SYS_SELECT)
  end

  def test_sigset_select_first_abi_matches_gcc
    assert_abi_matches(SIGSET_SELECT_FIRST)
  end

  def test_sigset_signal_first_abi_matches_gcc
    assert_abi_matches(SIGSET_SIGNAL_FIRST)
  end

  def test_unistd_abi_matches_gcc
    assert_abi_matches(UNISTD)
  end

  def test_features_abi_matches_gcc
    assert_abi_matches(FEATURES)
  end

  def test_sys_cdefs_abi_matches_gcc
    assert_abi_matches(SYS_CDEFS)
  end

  def test_stddef_abi_matches_gcc
    assert_abi_matches(STDDEF)
  end

  def test_stdarg_abi_matches_gcc
    assert_abi_matches(STDARG)
  end

  def test_stdbool_abi_matches_gcc
    assert_abi_matches(STDBOOL)
  end

  def test_stdalign_abi_matches_gcc
    assert_abi_matches(STDALIGN)
  end

  def test_float_abi_matches_gcc
    assert_abi_matches(FLOAT)
  end

  def test_iso646_abi_matches_gcc
    assert_abi_matches(ISO646)
  end

  def test_stdatomic_abi_matches_gcc
    assert_abi_matches(STDATOMIC)
  end

  private

  # Runs a Spec both ways and asserts a clean run and byte-identical output. The
  # gcc side is the oracle; rubycc must reproduce it exactly.
  #
  # A Spec whose header belongs to one libc only is skipped rather than run
  # here, and says so: on the other libc the oracle itself does not compile, so
  # the case would report the harness's assumption as a rubycc failure. The skip
  # is deliberately loud about which header and which libc -- a silently passing
  # case is the failure mode docs/internals/CI.md's skip guard exists to catch.
  def assert_abi_matches(spec)
    unless spec_applies_to?(spec)
      skip "<#{spec.header}> exists only on #{spec.libc}; this host's libc is #{host_libc}"
    end

    result = run_abi_case(spec)
    assert_equal 0, result.gcc_status, "gcc-built probe for <#{spec.header}> exited #{result.gcc_status}"
    assert_equal 0, result.rubycc_status, "rubycc-built probe for <#{spec.header}> exited #{result.rubycc_status}"
    assert_equal result.gcc_out, result.rubycc_out,
                 "<#{spec.header}>: rubycc ABI output differs from gcc"
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end

# Step 180 (M5 H6): the harness's libc parameterization itself. These are
# assertions about the probe *text* the harness generates, so they need no
# toolchain at all and run -- never skip -- on either kind of host.
#
# The load-bearing one is that the parameterization is invisible on a glibc
# host: a check moved into a Spec's `glibc:` bundle must come back at exactly
# the position it held before the move, so the long-standing glibc baseline is
# still compiled from byte-identical source and its green means what it did
# before. Each case spells the pre-split Spec out by hand and diffs the
# generated source against the live one, which is what makes this a check on
# the merge rather than a restatement of it.
class TestHeaderAbiLibcParameterization < Minitest::Test
  include HeaderAbiHarness

  # <ctype.h> as it stood before _ISupper / _ISlower moved into its bundle:
  # they sat in the middle of the _IS* group, which is why CTYPE's list carries
  # a GLIBC_ONLY marker instead of letting the bundle land at the tail.
  CTYPE_BEFORE_SPLIT = HeaderAbiHarness::Spec.new(
    header: "ctype.h",
    ints: ["isalpha('a')", "isdigit('5')", "isspace(' ')", "isupper('A')",
           "islower('a')", "isxdigit('f')", "isalnum('z')", "ispunct('!')",
           "toupper('a')", "tolower('A')",
           "isascii('a')", "isascii(200)", "isascii(0)", "isascii(127)",
           "toascii(0x1FF)", "toascii('A')",
           "_ISupper", "_ISlower", "_ISalpha", "_ISdigit", "_ISspace",
           "_ISblank", "_IScntrl", "_ISpunct", "_ISalnum"]
  )

  # <termios.h> as it stood before c_ispeed / c_ospeed moved into its bundle:
  # those were the last two offsets, so no marker is needed -- the bundle is
  # appended at the tail. Only the offsets changed, so only they are restated;
  # every other field is taken from the live Spec.
  TERMIOS_BEFORE_SPLIT = HeaderAbiHarness::Spec.new(
    **TestHeaderAbi::TERMIOS.to_h.merge(
      offsets: [["struct termios", "c_iflag"], ["struct termios", "c_oflag"],
                ["struct termios", "c_cflag"], ["struct termios", "c_lflag"],
                ["struct termios", "c_line"], ["struct termios", "c_cc"],
                ["struct termios", "c_ispeed"], ["struct termios", "c_ospeed"]],
      glibc: nil
    )
  )

  def test_marker_splices_the_bundle_back_where_the_checks_were
    assert_equal abi_probe_source(CTYPE_BEFORE_SPLIT, :glibc),
                 abi_probe_source(TestHeaderAbi::CTYPE, :glibc)
  end

  def test_tail_bundle_is_appended_where_the_checks_were
    assert_equal abi_probe_source(TERMIOS_BEFORE_SPLIT, :glibc),
                 abi_probe_source(TestHeaderAbi::TERMIOS, :glibc)
  end

  # The marker is a harness-internal element, never a C spelling: it must not
  # reach the probe text on either libc.
  def test_marker_never_reaches_the_probe_text
    refute_includes abi_probe_source(TestHeaderAbi::CTYPE, :glibc),
                    HeaderAbiHarness::GLIBC_ONLY.to_s
    refute_includes abi_probe_source(TestHeaderAbi::CTYPE, :musl),
                    HeaderAbiHarness::GLIBC_ONLY.to_s
  end

  # The musl probe is the glibc one minus exactly the glibc-only checks: every
  # other line, and their order, is untouched.
  def test_musl_probe_drops_only_the_glibc_only_checks
    ctype = abi_probe_source(TestHeaderAbi::CTYPE, :glibc).lines
    assert_equal ctype.reject { |line| line.include?("(_IS") },
                 abi_probe_source(TestHeaderAbi::CTYPE, :musl).lines

    termios = abi_probe_source(TestHeaderAbi::TERMIOS, :glibc).lines
    assert_equal termios.reject { |line| line.include?("c_ispeed") || line.include?("c_ospeed") },
                 abi_probe_source(TestHeaderAbi::TERMIOS, :musl).lines
  end

  # langinfo.h needs its glibc-only checks in two places at once -- the
  # DECIMAL_POINT aliases third in the list, the _NL_ITEM internals last -- so
  # its bundle carries its own separator. Both groups must land where they were
  # and nowhere else, or the glibc baseline's probe text moves.
  def test_bundle_with_its_own_separator_lands_in_both_places
    glibc = abi_probe_source(TestHeaderAbi::LANGINFO, :glibc).lines
    musl = abi_probe_source(TestHeaderAbi::LANGINFO, :musl).lines

    decimal_point = glibc.index { |line| line.include?("DECIMAL_POINT") }
    thousep = glibc.index { |line| line.include?("(THOUSEP)") }
    abday = glibc.index { |line| line.include?("ABDAY_1") }
    assert_operator thousep, :<, decimal_point, "the aliases follow the items they alias"
    assert_operator decimal_point, :<, abday, "and precede the day names, as before the split"
    assert_includes glibc.last(12).join, "_NL_ITEM_INDEX(NOEXPR)", "the internals stay last"

    assert_equal glibc.reject { |line| line.include?("DECIMAL_POINT") ||
                                       line.include?("THOUSANDS_SEP") ||
                                       line.include?("_NL_ITEM") },
                 musl
  end

  # A Spec that declares no bundle is libc-independent, which is what keeps the
  # other 40-odd cases' probe text exactly as it was.
  def test_spec_without_a_bundle_is_identical_for_either_libc
    assert_equal abi_probe_source(TestHeaderAbi::STDDEF, :glibc),
                 abi_probe_source(TestHeaderAbi::STDDEF, :musl)
    assert_equal abi_probe_source(TestHeaderAbi::SIGNAL, :glibc),
                 abi_probe_source(TestHeaderAbi::SIGNAL, :musl)
  end

  # A Spec naming a `libc:` applies to that libc only; one that names none
  # applies everywhere.
  def test_libc_only_specs_apply_to_that_libc_only
    assert spec_applies_to?(TestHeaderAbi::FEATURES, :glibc)
    refute spec_applies_to?(TestHeaderAbi::FEATURES, :musl)
    assert spec_applies_to?(TestHeaderAbi::SYS_CDEFS, :glibc)
    refute spec_applies_to?(TestHeaderAbi::SYS_CDEFS, :musl)
    assert spec_applies_to?(TestHeaderAbi::CTYPE, :musl)
  end
end

# Step 193 (M5 H6): the musl branches of the bundled headers.
#
# The harness above is a differential against *this host's* real headers, so it
# can only ever exercise the branch this host's libc selects: on a glibc machine
# the musl arms of the bundled headers are never compiled at all, and the CI
# musl run -- where their values were measured -- cannot be reproduced here.
# What can be reproduced here is the branch selection, which is where a mistake
# would actually live: sizes, alignments and macro values are settled at compile
# time, so compiling the probe with `libc: "musl"` and running it shows exactly
# which arm each #if took, on a host of either libc. The expected text below is
# the measured musl column of Step 193 transcribed once; nothing in it is
# derived from a header.
#
# The glibc case is the other half: it pins the #else arms to the values the
# harness above has been proving against the gcc oracle all along, so a
# mis-nested #if that quietly moved the default would fail here rather than only
# on the next musl run.
#
# One kind of check cannot be made this way: anything whose value comes from the
# libc at *runtime*. The ctype classifiers are the whole of that set -- glibc's
# out-of-line isalpha() returns its own table bits, so a musl-compiled probe
# linked against glibc still prints 1024 where musl would print 1. For those the
# check is structural instead (see #test_ctype_calls_the_classifier_functions_on_musl).
class TestMuslBundledHeaderValues < Minitest::Test
  include ExecutionHelper
  include HeaderAbiHarness

  def setup
    skip "gcc unavailable (needed to link and run the probe)" unless tool?("gcc")
    # The two expected columns below are transcribed x86-64 measurements, and
    # every check in them is one the two C libraries were measured to disagree
    # on *there*. Several are also arch-specific (the fast-type widths, O_*,
    # struct rusage), so on another machine this case would be comparing that
    # machine's values against a different machine's measurement -- a failure
    # that says nothing about either. It is skipped until an aarch64 musl run
    # supplies columns of its own.
    skip "the expected columns are x86-64 measurements; this host is #{host_target}" unless host_target == "x86_64"
  end

  # Every check the two C libraries were measured to disagree on, gathered into
  # one probe. Unlike the Specs above this one is not per-header: it is the
  # divergence list itself, which spans ten headers (stdio.h arrives with the
  # harness's own preamble), and it is never run as a differential -- only
  # compiled both ways and compared against the two measured columns.
  DIVERGENCES = HeaderAbiHarness::Spec.new(
    header: "stdint.h",
    also: %w[limits.h fcntl.h math.h unistd.h pthread.h sys/wait.h sys/resource.h],
    sizes: ["int_fast16_t", "int_fast32_t", "uint_fast16_t", "uint_fast32_t",
            "pthread_rwlockattr_t", "struct rusage"],
    ints: %w[O_ACCMODE O_LARGEFILE
             INT_FAST16_MIN INT_FAST16_MAX INT_FAST32_MIN INT_FAST32_MAX
             UINT_FAST16_MAX UINT_FAST32_MAX
             MB_LEN_MAX BUFSIZ FOPEN_MAX TMP_MAX
             math_errhandling _POSIX_MONOTONIC_CLOCK] +
          ["WIFSTOPPED(0x0000)", "WIFSTOPPED(0x007f)",
           "WIFSTOPPED(0x137f)", "WIFSTOPPED(0xffff)"]
  )

  # The measured musl column (docs/development/STEPS.md Step 193). The four fast-type sizes
  # and the two INT_FAST*_MIN / UINT_FAST*_MAX pairs are what the 32-bit types
  # imply, which is the point: the widths were measured and the limits follow
  # them, rather than each limit being asserted on its own. WIFSTOPPED is
  # printed for all four status words the harness probes, three of which musl
  # and glibc agree on.
  MUSL_EXPECTED = <<~OUT
    sizeof(int_fast16_t) = 4, _Alignof(int_fast16_t) = 4
    sizeof(int_fast32_t) = 4, _Alignof(int_fast32_t) = 4
    sizeof(uint_fast16_t) = 4, _Alignof(uint_fast16_t) = 4
    sizeof(uint_fast32_t) = 4, _Alignof(uint_fast32_t) = 4
    sizeof(pthread_rwlockattr_t) = 8, _Alignof(pthread_rwlockattr_t) = 4
    sizeof(struct rusage) = 272, _Alignof(struct rusage) = 8
    O_ACCMODE = 2097155
    O_LARGEFILE = 32768
    INT_FAST16_MIN = -2147483648
    INT_FAST16_MAX = 2147483647
    INT_FAST32_MIN = -2147483648
    INT_FAST32_MAX = 2147483647
    UINT_FAST16_MAX = 4294967295
    UINT_FAST32_MAX = 4294967295
    MB_LEN_MAX = 4
    BUFSIZ = 1024
    FOPEN_MAX = 1000
    TMP_MAX = 10000
    math_errhandling = 2
    _POSIX_MONOTONIC_CLOCK = 200809
    WIFSTOPPED(0x0000) = 0
    WIFSTOPPED(0x007f) = 0
    WIFSTOPPED(0x137f) = 1
    WIFSTOPPED(0xffff) = 0
  OUT

  # The glibc column: the values the harness above has been proving against the
  # gcc oracle since these headers were written. The two unsigned fast limits
  # print as -1 because the probe widens every integer check to (long long) and
  # glibc's UINT_FAST16_MAX is UINT64_MAX; that is the harness's long-standing
  # format, and the gcc oracle prints it the same way.
  GLIBC_EXPECTED = <<~OUT
    sizeof(int_fast16_t) = 8, _Alignof(int_fast16_t) = 8
    sizeof(int_fast32_t) = 8, _Alignof(int_fast32_t) = 8
    sizeof(uint_fast16_t) = 8, _Alignof(uint_fast16_t) = 8
    sizeof(uint_fast32_t) = 8, _Alignof(uint_fast32_t) = 8
    sizeof(pthread_rwlockattr_t) = 8, _Alignof(pthread_rwlockattr_t) = 8
    sizeof(struct rusage) = 144, _Alignof(struct rusage) = 8
    O_ACCMODE = 3
    O_LARGEFILE = 0
    INT_FAST16_MIN = -9223372036854775808
    INT_FAST16_MAX = 9223372036854775807
    INT_FAST32_MIN = -9223372036854775808
    INT_FAST32_MAX = 9223372036854775807
    UINT_FAST16_MAX = -1
    UINT_FAST32_MAX = -1
    MB_LEN_MAX = 16
    BUFSIZ = 8192
    FOPEN_MAX = 16
    TMP_MAX = 238328
    math_errhandling = 3
    _POSIX_MONOTONIC_CLOCK = 0
    WIFSTOPPED(0x0000) = 0
    WIFSTOPPED(0x007f) = 1
    WIFSTOPPED(0x137f) = 1
    WIFSTOPPED(0xffff) = 0
  OUT

  # A probe that exercises the classification macros. Compiled only; its output
  # is not compared, because on a glibc host the functions it resolves to are
  # glibc's (see the class comment).
  CTYPE_SOURCE = <<~C
    #include <ctype.h>
    int probe(int c) {
      return isalpha(c) + isdigit(c) + isspace(c) + isupper(c) + islower(c)
           + isxdigit(c) + isalnum(c) + ispunct(c) + iscntrl(c) + isgraph(c)
           + isprint(c) + isblank(c) + toupper(c) + tolower(c)
           + isascii(c) + toascii(c);
    }
  C

  def test_musl_branches_yield_the_measured_musl_values
    assert_equal MUSL_EXPECTED, run_divergence_probe("musl")
  end

  def test_glibc_branches_are_untouched_by_the_musl_ones
    assert_equal GLIBC_EXPECTED, run_divergence_probe("glibc")
  end

  # The ctype difference is one of mechanism, not of constants: under musl the
  # bundled header must not define the table-lookup macros, so every classifier
  # is the out-of-line function -- which is also the only way musl's bare 0/1
  # can be produced, since it has no __ctype_b_loc() table to mask. Reading the
  # object's undefined symbols is what tells the two apart on this host: the
  # glibc build reaches for the three table accessors and calls no classifier,
  # the musl build calls the classifiers and reaches for no accessor.
  def test_ctype_calls_the_classifier_functions_on_musl
    assert_equal %w[isalnum isalpha isblank iscntrl isdigit isgraph islower isprint
                    ispunct isspace isupper isxdigit tolower toupper],
                 undefined_symbols(CTYPE_SOURCE, "musl")
    assert_equal %w[__ctype_b_loc __ctype_tolower_loc __ctype_toupper_loc],
                 undefined_symbols(CTYPE_SOURCE, "glibc")
  end

  private

  # Compiles the divergence probe for `libc`, links and runs it, and returns its
  # standard output. The probe text is the harness's own, so each line is
  # labeled exactly as the differential above would label it.
  def run_divergence_probe(libc)
    source = abi_probe_source(DIVERGENCES, libc.to_sym)
    in_tmpdir do |dir|
      object = File.join(dir, "divergences_#{libc}.o")
      File.binwrite(object, Rubycc::Compiler.new.compile(source, filename: "divergences.c",
                                                                 libc: libc, target: host_target))
      status, output = link_and_run(object)
      assert_equal 0, status, "the #{libc} probe exited #{status}"
      output
    end
  end

  # The sorted names of the symbols `source` leaves for the linker when compiled
  # for `libc`, read with the project's own ELF reader.
  def undefined_symbols(source, libc)
    object = Rubycc::Compiler.new.compile(source, filename: "ctype.c", libc: libc,
                                          target: host_target)
    Rubycc::ObjFile::ELFReader.read(object)
                              .symbols.select(&:undefined?).map(&:name).reject(&:empty?).sort
  end

  def tool?(name)
    system(name, "--version", out: File::NULL, err: File::NULL) ? true : false
  end
end

# Step 82 (M5 H1): the aarch64 side of the header ABI harness. Every Spec above
# is declared once and here re-run against the cross ABI -- rubycc compiles the
# probe for the aarch64 target (so its bundled glibc/aarch64 header layer is on
# the search path), the object is linked statically with the cross gcc and run
# under qemu, and the oracle is the cross gcc building the same probe against the
# target's real aarch64 glibc headers. Byte-identical stdout proves the bundled
# aarch64 layer reproduces the target ABI.
#
# The eight arch-specific cases are the ones that would diverge from x86-64 if
# the layer were wrong: struct stat's 128-byte aarch64 layout (SYS_STAT), the
# 32-bit nlink_t/blksize_t (SYS_TYPES, and inside SYS_STAT), the unsigned
# WCHAR_MIN/MAX (STDINT), the unsigned plain-char range (LIMITS, via
# __CHAR_UNSIGNED__), the swapped O_DIRECT/O_DIRECTORY/O_NOFOLLOW bits (FCNTL
# and, reached through its compatibility alias, SYS_FCNTL), the wider pthreads
# opaque types (PTHREAD: pthread_mutex_t 40->48, pthread_attr_t 56->64,
# pthread_mutexattr_t / pthread_condattr_t 4->8), and the
# wider jmp_buf/sigjmp_buf (SETJMP: 200->312, a bigger saved register set). The
# remaining cases exercise the neutral layers (the common libc declarations and
# the arch headers that are byte-identical across the two ABIs), confirming they
# stay in agreement across the target switch. The whole class skips on a host
# without the cross toolchain (aarch64-linux-gnu-gcc + qemu-aarch64).
class TestHeaderAbiAarch64 < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper
  include HeaderAbiHarness

  def setup
    skip_unless_aarch64_toolchain
  end

  # --- arch-specific layer: the ABI that differs from x86-64 -----------------

  def test_sys_stat_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_STAT)
  end

  def test_sys_types_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_TYPES)
  end

  def test_stdint_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::STDINT)
  end

  # <float.h> is a freestanding header -- one file for every machine -- so this
  # class did not cover it, on the assumption that such a header has nothing
  # arch-specific in it. It does: `long double` is x87 80-bit extended on x86-64
  # and IEEE binary128 on aarch64, and this header handed x87's numbers to both
  # until Step 200 measured the difference on real aarch64 hardware-emulation.
  # The case exists so that assumption is checked rather than assumed again.
  def test_float_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::FLOAT)
  end

  def test_limits_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::LIMITS)
  end

  def test_fcntl_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::FCNTL)
  end

  def test_sys_fcntl_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_FCNTL)
  end

  def test_pthread_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::PTHREAD)
  end

  def test_setjmp_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SETJMP)
  end

  # struct epoll_event is packed to 12 bytes (1-byte aligned, data at offset
  # 4) on x86-64 but takes its natural 16-byte layout (8-byte aligned, data at
  # offset 8) here, so this is an arch-specific case, not a neutral re-check.
  def test_epoll_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::EPOLL)
  end

  # The system-call numbers are per-architecture: aarch64 uses the modern
  # asm-generic table while x86-64 keeps its own historical one, and the two
  # disagree on all but three of the names the bundled header defines (only
  # the io_uring trio, allocated from the shared modern range, matches). So
  # this is an arch-specific case, not a neutral re-check.
  def test_syscall_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYSCALL)
  end

  # --- neutral layer: re-checked to confirm byte-identity across the switch --

  def test_time_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::TIME)
  end

  def test_errno_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::ERRNO)
  end

  def test_endian_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::ENDIAN)
  end

  def test_ctype_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::CTYPE)
  end

  def test_inttypes_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::INTTYPES)
  end

  def test_sys_time_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_TIME)
  end

  def test_sys_select_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_SELECT)
  end

  # <unistd.h> had no aarch64 case until Step 160, an oversight rather than a
  # decision: its surface (the _SC_* / _CS_* / _PC_* values and the declarations)
  # is measured as identical on both arches, which is exactly the claim a
  # cross-checked case is supposed to keep honest.
  def test_unistd_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::UNISTD)
  end

  def test_sigset_select_first_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SIGSET_SELECT_FIRST)
  end

  def test_sigset_signal_first_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SIGSET_SIGNAL_FIRST)
  end

  def test_stddef_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::STDDEF)
  end

  # <stdatomic.h> is freestanding, so like <float.h> it is one file for every
  # machine -- and the layout claim it rests on ("_Atomic T has T's layout") is
  # a per-target measurement, not a portable one. The cross run makes the
  # aarch64 ABI say so too.
  def test_stdatomic_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::STDATOMIC)
  end

  def test_poll_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::POLL)
  end

  def test_dlfcn_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::DLFCN)
  end

  def test_mman_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::MMAN)
  end

  def test_signal_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SIGNAL)
  end

  def test_socket_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SOCKET)
  end

  def test_netinet_in_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::NETINET_IN)
  end

  def test_tcp_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::TCP)
  end

  def test_un_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SOCKADDR_UN)
  end

  def test_locale_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::LOCALE)
  end

  def test_pwd_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::PWD)
  end

  def test_grp_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::GRP)
  end

  def test_utsname_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::UTSNAME)
  end

  def test_uio_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::UIO)
  end

  def test_resource_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::RESOURCE)
  end

  def test_dirent_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::DIRENT)
  end

  def test_sched_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SCHED)
  end

  def test_termios_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::TERMIOS)
  end

  def test_ioctl_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::IOCTL)
  end

  def test_sys_param_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::SYS_PARAM)
  end

  def test_wait_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::WAIT)
  end

  def test_langinfo_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::LANGINFO)
  end

  def test_timerfd_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::TIMERFD)
  end

  def test_inotify_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::INOTIFY)
  end

  def test_statfs_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::STATFS)
  end

  private

  # Runs a Spec through the aarch64 harness and asserts a clean run on both
  # toolchains and byte-identical output. The cross gcc is the oracle; rubycc's
  # aarch64 build must reproduce it exactly.
  def assert_abi_matches_aarch64(spec)
    result = run_abi_case_aarch64(spec)
    assert_equal 0, result.gcc_status,
                 "cross-gcc probe for <#{spec.header}> exited #{result.gcc_status}"
    assert_equal 0, result.rubycc_status,
                 "rubycc aarch64 probe for <#{spec.header}> exited #{result.rubycc_status}"
    assert_equal result.gcc_out, result.rubycc_out,
                 "<#{spec.header}>: rubycc aarch64 ABI output differs from cross gcc"
  end
end

# Step 202 (M5 H6): the aarch64 musl branches of the bundled headers, the
# aarch64 counterpart of TestMuslBundledHeaderValues above.
#
# TestHeaderAbiAarch64 above is a differential against the *cross gcc's* real
# headers, which are glibc's -- there is no musl cross gcc to compile an oracle
# with, so the musl arms of the aarch64 layer cannot be checked that way, the
# same limitation TestMuslBundledHeaderValues describes for a glibc host's own
# musl branches. What can still be checked, the same way, is the branch
# selection: sizes, alignments and macro values are settled at compile time, so
# compiling the probe with `target: "aarch64", libc: "musl"` and *running it
# under qemu* (the object needs a real linker and a real machine to execute on,
# not merely to compile -- the cross gcc is that linker here, and the values
# under test all come from the header, not from which libc the link actually
# resolves against) shows exactly which arm each #if took. The expected text
# below is the measured musl column of Step 202 transcribed once; nothing in it
# is derived from a header, and no musl or glibc source was read to produce it
# (R11) -- only the CI aarch64 Alpine run's own numbers.
#
# The glibc case is the other half, the same way: it pins the #else arms to the
# values TestHeaderAbiAarch64 has been proving against the cross-gcc oracle all
# along, so a mis-nested #if that quietly moved the default would fail here too.
class TestAarch64MuslBundledHeaderValues < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper
  include HeaderAbiHarness

  def setup
    skip_unless_aarch64_toolchain
  end

  # Every aarch64 check Step 202 measured the two C libraries to disagree on,
  # gathered into one probe: the four fast-type sizes (stdint.h), MB_LEN_MAX
  # (limits.h), O_ACCMODE/O_LARGEFILE (fcntl.h), and the five pthreads opaque
  # objects (pthread.h). INT_FAST16_MAX/INT_FAST32_MAX are the one macro pair
  # Step 202 measured directly (the table in the task); INT_FAST16_MIN,
  # INT_FAST32_MIN and the two UINT_FAST*_MAX are the values the measured
  # 32-bit width already forces (the same relationship the bundled stdint.h
  # itself encodes: those macros are spelled through the exact-width names
  # rather than asserted on their own), so they are included as the width's
  # necessary consequence, not as separate assumptions.
  DIVERGENCES = HeaderAbiHarness::Spec.new(
    header: "stdint.h",
    also: %w[limits.h fcntl.h pthread.h],
    sizes: ["int_fast16_t", "int_fast32_t", "uint_fast16_t", "uint_fast32_t",
            "pthread_mutex_t", "pthread_attr_t", "pthread_mutexattr_t",
            "pthread_condattr_t", "pthread_rwlockattr_t"],
    ints: %w[MB_LEN_MAX O_ACCMODE O_LARGEFILE
             INT_FAST16_MIN INT_FAST16_MAX INT_FAST32_MIN INT_FAST32_MAX
             UINT_FAST16_MAX UINT_FAST32_MAX]
  )

  # The measured aarch64 musl column (docs/development/STEPS.md Step 202).
  MUSL_EXPECTED = <<~OUT
    sizeof(int_fast16_t) = 4, _Alignof(int_fast16_t) = 4
    sizeof(int_fast32_t) = 4, _Alignof(int_fast32_t) = 4
    sizeof(uint_fast16_t) = 4, _Alignof(uint_fast16_t) = 4
    sizeof(uint_fast32_t) = 4, _Alignof(uint_fast32_t) = 4
    sizeof(pthread_mutex_t) = 40, _Alignof(pthread_mutex_t) = 8
    sizeof(pthread_attr_t) = 56, _Alignof(pthread_attr_t) = 8
    sizeof(pthread_mutexattr_t) = 4, _Alignof(pthread_mutexattr_t) = 4
    sizeof(pthread_condattr_t) = 4, _Alignof(pthread_condattr_t) = 4
    sizeof(pthread_rwlockattr_t) = 8, _Alignof(pthread_rwlockattr_t) = 4
    MB_LEN_MAX = 4
    O_ACCMODE = 2097155
    O_LARGEFILE = 131072
    INT_FAST16_MIN = -2147483648
    INT_FAST16_MAX = 2147483647
    INT_FAST32_MIN = -2147483648
    INT_FAST32_MAX = 2147483647
    UINT_FAST16_MAX = 4294967295
    UINT_FAST32_MAX = 4294967295
  OUT

  # The glibc column: the values TestHeaderAbiAarch64 has been proving against
  # the cross-gcc oracle since these headers were written (STDINT, LIMITS,
  # FCNTL, PTHREAD). The two unsigned fast limits print as -1 for the same
  # reason the x86-64 GLIBC_EXPECTED's do: the probe widens every integer
  # check to (long long), and glibc's UINT_FAST16_MAX/UINT_FAST32_MAX is
  # UINT64_MAX.
  GLIBC_EXPECTED = <<~OUT
    sizeof(int_fast16_t) = 8, _Alignof(int_fast16_t) = 8
    sizeof(int_fast32_t) = 8, _Alignof(int_fast32_t) = 8
    sizeof(uint_fast16_t) = 8, _Alignof(uint_fast16_t) = 8
    sizeof(uint_fast32_t) = 8, _Alignof(uint_fast32_t) = 8
    sizeof(pthread_mutex_t) = 48, _Alignof(pthread_mutex_t) = 8
    sizeof(pthread_attr_t) = 64, _Alignof(pthread_attr_t) = 8
    sizeof(pthread_mutexattr_t) = 8, _Alignof(pthread_mutexattr_t) = 4
    sizeof(pthread_condattr_t) = 8, _Alignof(pthread_condattr_t) = 4
    sizeof(pthread_rwlockattr_t) = 8, _Alignof(pthread_rwlockattr_t) = 8
    MB_LEN_MAX = 16
    O_ACCMODE = 3
    O_LARGEFILE = 0
    INT_FAST16_MIN = -9223372036854775808
    INT_FAST16_MAX = 9223372036854775807
    INT_FAST32_MIN = -9223372036854775808
    INT_FAST32_MAX = 9223372036854775807
    UINT_FAST16_MAX = -1
    UINT_FAST32_MAX = -1
  OUT

  # A probe that exercises the classification macros, the aarch64 counterpart
  # of TestMuslBundledHeaderValues::CTYPE_SOURCE. Compiled only; the values it
  # would print are not the point (see #test_ctype_calls_the_classifier_functions_on_musl).
  CTYPE_SOURCE = <<~C
    #include <ctype.h>
    int probe(int c) {
      return isalpha(c) + isdigit(c) + isspace(c) + isupper(c) + islower(c)
           + isxdigit(c) + isalnum(c) + ispunct(c) + iscntrl(c) + isgraph(c)
           + isprint(c) + isblank(c) + toupper(c) + tolower(c)
           + isascii(c) + toascii(c);
    }
  C

  def test_musl_branches_yield_the_measured_musl_values
    assert_equal MUSL_EXPECTED, run_divergence_probe_aarch64("musl")
  end

  def test_glibc_branches_are_untouched_by_the_musl_ones
    assert_equal GLIBC_EXPECTED, run_divergence_probe_aarch64("glibc")
  end

  # The structural check ctype.h needs (see the class comment on
  # TestMuslBundledHeaderValues): under musl every classifier must resolve to
  # the out-of-line function, and under glibc to the table accessors, which
  # shows up in which symbols the compiled object leaves undefined.
  def test_ctype_calls_the_classifier_functions_on_musl
    assert_equal %w[isalnum isalpha isblank iscntrl isdigit isgraph islower isprint
                    ispunct isspace isupper isxdigit tolower toupper],
                 undefined_symbols_aarch64(CTYPE_SOURCE, "musl")
    assert_equal %w[__ctype_b_loc __ctype_tolower_loc __ctype_toupper_loc],
                 undefined_symbols_aarch64(CTYPE_SOURCE, "glibc")
  end

  private

  # Compiles the divergence probe for `libc` targeting aarch64, links it
  # statically with the cross gcc and runs it under qemu, and returns its
  # standard output.
  def run_divergence_probe_aarch64(libc)
    source = abi_probe_source(DIVERGENCES, libc.to_sym)
    in_tmpdir do |dir|
      object = File.join(dir, "aarch64_divergences_#{libc}.o")
      compile_with_rubycc_aarch64(source, object, libc: libc)
      status, output = link_and_run_aarch64(object)
      assert_equal 0, status, "the aarch64 #{libc} probe exited #{status}"
      output
    end
  end

  # The sorted names of the symbols `source` leaves for the linker when
  # compiled for aarch64 against `libc`, read with the project's own ELF
  # reader.
  def undefined_symbols_aarch64(source, libc)
    object = Rubycc::Compiler.new.compile(source, filename: "ctype.c", target: "aarch64", libc: libc)
    Rubycc::ObjFile::ELFReader.read(object)
                              .symbols.select(&:undefined?).map(&:name).reject(&:empty?).sort
  end
end
