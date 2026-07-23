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
  # pull-in being dropped.
  STRING = HeaderAbiHarness::Spec.new(
    header: "string.h",
    sizes: %w[size_t],
    snippets: [<<~C.chomp]
      static int abi_string(char *d, const char *s) {
        memcpy(d, s, strlen(s) + 1);
        return strcmp(d, s) + (memchr(s, 'a', 4) != (void *)0)
             + strcasecmp(d, s) + strncasecmp(d, s, 3);
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
           "_ISupper", "_ISlower", "_ISalpha", "_ISdigit", "_ISspace",
           "_ISblank", "_IScntrl", "_ISpunct", "_ISalnum"]
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

  # <unistd.h>: the standard file-descriptor and access-mode constants, the few
  # ABI-typed names' widths, and that the core system-call declarations exist.
  UNISTD = HeaderAbiHarness::Spec.new(
    header: "unistd.h",
    sizes: %w[ssize_t off_t pid_t uid_t gid_t],
    ints: %w[STDIN_FILENO STDOUT_FILENO STDERR_FILENO F_OK R_OK W_OK X_OK
             SEEK_SET SEEK_CUR SEEK_END],
    snippets: [<<~C.chomp]
      static long abi_unistd(int fd, void *buf, unsigned long n) {
        return read(fd, buf, n) + write(fd, buf, n) + close(fd) + getpid();
      }
    C
  )

  # <features.h>: the glibc version macros the version-gated header code branches
  # on.
  FEATURES = HeaderAbiHarness::Spec.new(
    header: "features.h",
    ints: ["__GLIBC__", "__GLIBC_MINOR__",
           "__GLIBC_PREREQ(2, 17)", "__GLIBC_PREREQ(2, 99)", "__GLIBC_PREREQ(3, 0)"]
  )

  # <sys/cdefs.h>: the compiler-abstraction macros expand to usable code. The
  # __GNUC_PREREQ value is deliberately not asserted: rubycc does not define
  # __GNUC__ (DESIGN R7), so it evaluates to 0 where gcc yields 1 -- a real,
  # intended toolchain difference rather than a header defect.
  SYS_CDEFS = HeaderAbiHarness::Spec.new(
    header: "sys/cdefs.h",
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
             F_SETOWN F_GETOWN F_DUPFD_CLOEXEC FD_CLOEXEC
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
             POLLRDNORM POLLRDBAND POLLWRNORM POLLWRBAND POLLMSG
             POLLREMOVE POLLRDHUP],
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
    ints: %w[RTLD_LAZY RTLD_NOW RTLD_GLOBAL RTLD_LOCAL
             RTLD_NOLOAD RTLD_DEEPBIND RTLD_NODELETE],
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
    ints: %w[AF_UNSPEC AF_UNIX AF_INET AF_INET6 PF_INET
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
    also: ["sys/socket.h"],
    defines: ["_GNU_SOURCE"],
    sizes: %w[in_addr_t in_port_t sa_family_t struct\ in_addr struct\ in6_addr
              struct\ sockaddr_in struct\ sockaddr_in6],
    ints: %w[IPPROTO_IP IPPROTO_ICMP IPPROTO_TCP IPPROTO_UDP IPPROTO_IPV6 IPPROTO_RAW
             INADDR_ANY INADDR_LOOPBACK INADDR_BROADCAST INADDR_NONE
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
    C
  )

  # <netinet/tcp.h> (Step 90, M5 H2): the TCP-level socket-option names, used
  # with setsockopt at level IPPROTO_TCP. Arch-neutral (common layer). Only the
  # option macros are checked -- the header carries no struct rubycc reproduces.
  TCP = HeaderAbiHarness::Spec.new(
    header: "netinet/tcp.h",
    defines: ["_GNU_SOURCE"],
    ints: %w[TCP_NODELAY TCP_MAXSEG TCP_CORK TCP_KEEPIDLE TCP_KEEPINTVL
             TCP_KEEPCNT TCP_INFO TCP_QUICKACK TCP_USER_TIMEOUT TCP_FASTOPEN],
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
  PTHREAD = HeaderAbiHarness::Spec.new(
    header: "pthread.h",
    defines: ["_GNU_SOURCE"],
    sizes: %w[pthread_t pthread_mutex_t pthread_cond_t pthread_rwlock_t
              pthread_attr_t pthread_mutexattr_t pthread_condattr_t
              pthread_rwlockattr_t pthread_once_t pthread_key_t pthread_spinlock_t],
    ints: %w[PTHREAD_MUTEX_NORMAL PTHREAD_MUTEX_RECURSIVE PTHREAD_MUTEX_ERRORCHECK
             PTHREAD_MUTEX_DEFAULT PTHREAD_CREATE_JOINABLE PTHREAD_CREATE_DETACHED
             PTHREAD_PROCESS_PRIVATE PTHREAD_PROCESS_SHARED PTHREAD_ONCE_INIT],
    snippets: [<<~C.chomp]
      static pthread_mutex_t  abi_m  = PTHREAD_MUTEX_INITIALIZER;
      static pthread_cond_t   abi_c  = PTHREAD_COND_INITIALIZER;
      static pthread_rwlock_t abi_rw = PTHREAD_RWLOCK_INITIALIZER;
      static pthread_once_t   abi_o  = PTHREAD_ONCE_INIT;
      static void  abi_once_init(void) { }
      static void *abi_thread_start(void *p) { return p; }
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
             + sizeof(pthread_mutexattr_settype(ma, PTHREAD_MUTEX_RECURSIVE));
      }
    C
  )

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

  private

  # Runs a Spec both ways and asserts a clean run and byte-identical output. The
  # gcc side is the oracle; rubycc must reproduce it exactly.
  def assert_abi_matches(spec)
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

# Step 82 (M5 H1): the aarch64 side of the header ABI harness. Every Spec above
# is declared once and here re-run against the cross ABI -- rubycc compiles the
# probe for the aarch64 target (so its bundled glibc/aarch64 header layer is on
# the search path), the object is linked statically with the cross gcc and run
# under qemu, and the oracle is the cross gcc building the same probe against the
# target's real aarch64 glibc headers. Byte-identical stdout proves the bundled
# aarch64 layer reproduces the target ABI.
#
# The six arch-specific cases are the ones that would diverge from x86-64 if the
# layer were wrong: struct stat's 128-byte aarch64 layout (SYS_STAT), the 32-bit
# nlink_t/blksize_t (SYS_TYPES, and inside SYS_STAT), the unsigned WCHAR_MIN/MAX
# (STDINT), the unsigned plain-char range (LIMITS, via __CHAR_UNSIGNED__), the
# swapped O_DIRECT/O_DIRECTORY/O_NOFOLLOW bits (FCNTL), and the wider pthreads
# opaque types (PTHREAD: pthread_mutex_t 40->48, pthread_attr_t 56->64,
# pthread_mutexattr_t / pthread_condattr_t 4->8). The remaining cases
# exercise the neutral layers (the common libc declarations and
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

  def test_limits_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::LIMITS)
  end

  def test_fcntl_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::FCNTL)
  end

  def test_pthread_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::PTHREAD)
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

  def test_stddef_abi_matches_cross_gcc
    assert_abi_matches_aarch64(TestHeaderAbi::STDDEF)
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
