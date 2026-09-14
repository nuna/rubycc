# 同梱 libc ヘッダの網羅度監査(glibc の同名ヘッダとの突き合わせ)

> **Generated artifact.** `ruby tools/audit_bundled_headers.rb --output docs/development/BUNDLED-HEADERS-COVERAGE.md` で再生成する。手で編集しない。

測定日: 2026-09-14。オラクル:
- x86_64: `gcc`(gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0、glibc 2.39)
- aarch64: `aarch64-linux-gnu-gcc`(aarch64-linux-gnu-gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0、glibc 2.39)

## 読み方

- **glibc 側**は `<H>` だけを含む翻訳単位を `gcc -E -dD -std=gnu17 -D_GNU_SOURCE` で前処理し、`#define` と宣言から名前を拾う。linemarker の include スタックで、各名前を**最も内側の公開ヘッダ**に帰属させる(`bits/`・`gnu/`・`asm/`・`asm-generic/`・`linux/` は内部とみなし、その外側の公開ヘッダに帰属する)。`<H>` 自身に帰属する名前が「glibc の `<H>` の名前」である。
- **同梱側**は同じコンパイラで `-nostdinc` と rubycc の同梱の探索順(`include/`、`include/libc/glibc/<arch>/`、`include/libc/`)で前処理する(hermetic と同じ。ホストのヘッダは混ざらない)。同梱の `<H>` から見える名前はすべて数える(同梱の別ヘッダ経由でも見えれば足りている)。
- **不足**は glibc の `<H>` の名前のうち、同梱の `<H>` から見えないもの(`_` + 大文字 / `__` で始まる予約名は除く)。括弧の中は、その名前を最初に見せる feature-test の段階: `iso`(`-std=c11`)・`posix`(`_POSIX_C_SOURCE=200809L`)・`xopen`(`_XOPEN_SOURCE=700`)・`default`(gcc の既定 = `_DEFAULT_SOURCE` = `__USE_MISC`)・`gnu`(`_GNU_SOURCE` でだけ)。
- **未記載**は、不足のうち同梱ヘッダの冒頭コメントの `omitted: 名前 ... -- 理由` で意図して外したと書かれていないもの。
- **取り込み不足**は、glibc の `<H>` が含む公開ヘッダのうち、同梱の `<H>` が含まないもの(その中の名前は上の不足に数えない)。
- **予約名の型**は、glibc の `<H>` が定義する予約名の typedef / タグのうち同梱に無いもの(GAPS AQ の `__caddr_t` の形)。
- **ガード**は、glibc の `<H>` が立てる共有ガード(`__have_*` / `__*_defined`)。`honoured` = 同梱も同じガードを立てる、`absent` = 同梱はガード対象の型を定義しない(glibc 側が定義するので衝突しない)、`unguarded` = 同梱が型を定義するがガードを立てない(GAPS AU の形)。`unguarded` には、同梱の `<H>` とガードを持つ glibc のファイルを両方の順で含めてrubycc(x86-64)でコンパイルした結果を添える。`self` = ガードが glibc の `<H>` 自身の本文にある(glibc の `<H>` と同梱の `<H>` は同じ翻訳単位に並ばないので衝突しえず、probe しない)。
- 段階 `iso` は `-std=c11` でも見える名前(= 条件なし)で、POSIX のヘッダでは「feature-test に関係なく見える」を意味する。
- **余剰**は同梱の `<H>` が定義するが、glibc の `<H>` からは `_GNU_SOURCE` でも見えない名前。

## 一覧

| ヘッダ | x86_64 不足 | x86_64 未記載 | aarch64 不足 | aarch64 未記載 | 取り込み不足 | unguarded |
|---|---|---|---|---|---|---|
| [`alloca.h`](#allocah) | 0 | 1 | 0 | 1 | `stddef.h` | — |
| [`arpa/inet.h`](#arpaineth) | 5 | 10 | 5 | 10 | `netinet/in.h` `stddef.h` `sys/select.h` `sys/socket.h` `sys/types.h` | — |
| [`assert.h`](#asserth) | 1 | 1 | 1 | 1 | — | — |
| [`ctype.h`](#ctypeh) | 20 | 20 | 20 | 20 | — | — |
| [`dirent.h`](#direnth) | 42 | 43 | 42 | 43 | `stddef.h` | — |
| [`dlfcn.h`](#dlfcnh) | 20 | 21 | 20 | 21 | `stddef.h` | — |
| [`endian.h`](#endianh) | 0 | 0 | 0 | 0 | — | — |
| [`errno.h`](#errnoh) | 2 | 2 | 2 | 2 | — | — |
| [`fcntl.h`](#fcntlh) | 154 | 155 | 153 | 154 | `stddef.h` | — |
| [`features.h`](#featuresh) | 0 | 0 | 0 | 0 | — | — |
| [`grp.h`](#grph) | 9 | 10 | 9 | 10 | `stddef.h` | — |
| [`inttypes.h`](#inttypesh) | 42 | 42 | 42 | 42 | — | — |
| [`langinfo.h`](#langinfoh) | 38 | 39 | 38 | 39 | `nl_types.h` | — |
| [`limits.h`](#limitsh) | 53 | 54 | 53 | 54 | `syslimits.h` | — |
| [`link.h`](#linkh) | 49 | 56 | 42 | 49 | `dlfcn.h` `elf.h` `endian.h` `stddef.h` `stdint.h` `sys/select.h` `sys/types.h` | — |
| [`locale.h`](#localeh) | 19 | 20 | 19 | 20 | `stddef.h` | — |
| [`math.h`](#mathh) | 777 | 777 | 779 | 779 | — | — |
| [`netinet/in.h`](#netinetinh) | 267 | 272 | 267 | 272 | `endian.h` `stddef.h` `sys/select.h` `sys/socket.h` `sys/types.h` | — |
| [`netinet/tcp.h`](#netinettcph) | 90 | 96 | 90 | 96 | `endian.h` `stddef.h` `stdint.h` `sys/select.h` `sys/socket.h` `sys/types.h` | — |
| [`poll.h`](#pollh) | 0 | 1 | 0 | 1 | `sys/poll.h` | — |
| [`pthread.h`](#pthreadh) | 136 | 139 | 136 | 139 | `sched.h` `stddef.h` `time.h` | — |
| [`pwd.h`](#pwdh) | 7 | 8 | 7 | 8 | `stddef.h` | — |
| [`regex.h`](#regexh) | 76 | 79 | 76 | 79 | `endian.h` `sys/select.h` `sys/types.h` | — |
| [`sched.h`](#schedh) | 52 | 0 | 52 | 0 | `stddef.h` | 1 |
| [`setjmp.h`](#setjmph) | 0 | 0 | 0 | 0 | — | — |
| [`signal.h`](#signalh) | 152 | 155 | 177 | 186 | `stddef.h` `sys/ucontext.h` `unistd.h` `endian.h` `sys/procfs.h` `sys/select.h` `sys/time.h` `sys/types.h` `sys/user.h` | 2 |
| [`stdint.h`](#stdinth) | 33 | 33 | 33 | 33 | — | — |
| [`stdio.h`](#stdioh) | 56 | 58 | 56 | 58 | `stdarg.h` `stddef.h` | — |
| [`stdlib.h`](#stdlibh) | 83 | 0 | 83 | 0 | `endian.h` `stddef.h` `sys/select.h` `sys/types.h` | — |
| [`string.h`](#stringh) | 16 | 17 | 16 | 17 | `stddef.h` | — |
| [`strings.h`](#stringsh) | 3 | 4 | 3 | 4 | `stddef.h` | — |
| [`sys/cdefs.h`](#syscdefsh) | 0 | 0 | 0 | 0 | — | — |
| [`sys/epoll.h`](#sysepollh) | 3 | 7 | 3 | 7 | `endian.h` `stddef.h` `sys/select.h` `sys/types.h` | — |
| [`sys/fcntl.h`](#sysfcntlh) | 0 | 1 | 0 | 1 | `stddef.h` | — |
| [`sys/inotify.h`](#sysinotifyh) | 0 | 0 | 0 | 0 | — | — |
| [`sys/ioctl.h`](#sysioctlh) | 13 | 0 | 13 | 0 | `sys/ttydefaults.h` | — |
| [`sys/mman.h`](#sysmmanh) | 72 | 73 | 71 | 72 | `stddef.h` | — |
| [`sys/param.h`](#sysparamh) | 18 | 27 | 18 | 30 | `endian.h` `limits.h` `signal.h` `stddef.h` `sys/select.h` `sys/types.h` `sys/ucontext.h` `syslimits.h` `unistd.h` `sys/procfs.h` `sys/time.h` `sys/user.h` | — |
| [`sys/resource.h`](#sysresourceh) | 20 | 20 | 20 | 20 | — | 1 |
| [`sys/select.h`](#sysselecth) | 1 | 1 | 1 | 1 | — | 2 |
| [`sys/socket.h`](#syssocketh) | 239 | 243 | 239 | 243 | `endian.h` `stddef.h` `sys/select.h` `sys/types.h` | 2 |
| [`sys/stat.h`](#sysstath) | 56 | 56 | 56 | 56 | — | 1 |
| [`sys/statfs.h`](#sysstatfsh) | 3 | 3 | 3 | 3 | — | — |
| [`sys/syscall.h`](#syssyscallh) | 312 | 312 | 256 | 256 | — | — |
| [`sys/time.h`](#systimeh) | 6 | 7 | 6 | 7 | `sys/select.h` | 1 |
| [`sys/timerfd.h`](#systimerfdh) | 0 | 1 | 0 | 1 | `stddef.h` | — |
| [`sys/types.h`](#systypesh) | 15 | 0 | 15 | 0 | `endian.h` `stddef.h` `sys/select.h` | 4 |
| [`sys/uio.h`](#sysuioh) | 16 | 20 | 16 | 20 | `endian.h` `stddef.h` `sys/select.h` `sys/types.h` | 1 |
| [`sys/un.h`](#sysunh) | 1 | 4 | 1 | 4 | `stddef.h` `string.h` `strings.h` | — |
| [`sys/utsname.h`](#sysutsnameh) | 1 | 1 | 1 | 1 | — | — |
| [`sys/wait.h`](#syswaith) | 7 | 10 | 7 | 16 | `stddef.h` `sys/ucontext.h` `unistd.h` `endian.h` `sys/procfs.h` `sys/select.h` `sys/time.h` `sys/types.h` `sys/user.h` | 1 |
| [`termios.h`](#termiosh) | 2 | 0 | 2 | 0 | `sys/ttydefaults.h` | — |
| [`time.h`](#timeh) | 63 | 64 | 63 | 64 | `stddef.h` | 5 |
| [`unistd.h`](#unistdh) | 90 | 91 | 90 | 91 | `stddef.h` | — |

## ヘッダ別

### alloca.h

**x86_64 / aarch64** — glibc の `<alloca.h>` の公開名 1、不足 0、未記載 1

- 取り込み不足: `stddef.h`

### arpa/inet.h

**x86_64 / aarch64** — glibc の `<arpa/inet.h>` の公開名 14、不足 5、未記載 10

- 不足(default): **`inet_net_ntop`** **`inet_net_pton`** **`inet_neta`** **`inet_nsap_addr`** **`inet_nsap_ntoa`**
- 取り込み不足: `netinet/in.h` `stddef.h` `sys/select.h` `sys/socket.h` `sys/types.h`

### assert.h

**x86_64 / aarch64** — glibc の `<assert.h>` の公開名 3、不足 1、未記載 1

- 不足(gnu): **`assert_perror`**

### ctype.h

**x86_64 / aarch64** — glibc の `<ctype.h>` の公開名 36、不足 20、未記載 20

- 不足(posix): **`isalnum_l`** **`isalpha_l`** **`isblank_l`** **`iscntrl_l`** **`isdigit_l`** **`isgraph_l`** **`islower_l`** **`isprint_l`** **`ispunct_l`** **`isspace_l`** **`isupper_l`** **`isxdigit_l`** **`locale_t`** **`tolower_l`** **`toupper_l`**
- 不足(xopen): **`_tolower`** **`_toupper`**
- 不足(default): **`isascii_l`** **`toascii_l`**
- 不足(gnu): **`isctype`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__locale_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `struct __locale_struct`

### dirent.h

**x86_64 / aarch64** — glibc の `<dirent.h>` の公開名 61、不足 42、未記載 43

- 不足(iso): **`d_fileno`**
- 不足(posix): **`alphasort`** **`scandir`**
- 不足(xopen): **`seekdir`** **`telldir`**
- 不足(default): **`AIO_PRIO_DELTA_MAX`** **`DELAYTIMER_MAX`** **`DTTOIF`** **`HOST_NAME_MAX`** **`IFTODT`** **`LOGIN_NAME_MAX`** **`MAXNAMLEN`** **`MAX_CANON`** **`MAX_INPUT`** **`MQ_PRIO_MAX`** **`NAME_MAX`** **`NGROUPS_MAX`** **`PATH_MAX`** **`PIPE_BUF`** **`PTHREAD_DESTRUCTOR_ITERATIONS`** **`PTHREAD_KEYS_MAX`** **`PTHREAD_STACK_MIN`** **`RTSIG_MAX`** **`SEM_VALUE_MAX`** **`SSIZE_MAX`** **`TTY_NAME_MAX`** **`XATTR_LIST_MAX`** **`XATTR_NAME_MAX`** **`XATTR_SIZE_MAX`** **`getdirentries`**
- 不足(gnu): **`alphasort64`** **`getdents64`** **`getdirentries64`** **`ino64_t`** **`readdir64`** **`readdir64_r`** **`scandir64`** **`scandirat`** **`scandirat64`** **`struct dirent64`** **`versionsort`** **`versionsort64`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__ino64_t_defined` → `ino64_t`: absent
- ガード `__ino_t_defined` → `ino_t`: self
- 余剰: `off_t`

### dlfcn.h

**x86_64 / aarch64** — glibc の `<dlfcn.h>` の公開名 46、不足 20、未記載 21

- 不足(iso): **`RTLD_BINDING_MASK`**
- 不足(gnu): **`DLFO_EH_SEGMENT_TYPE`** **`DLFO_STRUCT_HAS_EH_COUNT`** **`DLFO_STRUCT_HAS_EH_DBASE`** **`DL_CALL_FCT`** **`Dl_info`** **`Dl_serinfo`** **`Dl_serpath`** **`LM_ID_BASE`** **`LM_ID_NEWLM`** **`Lmid_t`** **`RTLD_DL_LINKMAP`** **`RTLD_DL_SYMENT`** **`_dl_find_object`** **`_dl_mcount_wrapper_check`** **`dladdr`** **`dladdr1`** **`dlmopen`** **`dlvsym`** **`struct dl_find_object`**
- 取り込み不足: `stddef.h`

### endian.h

**x86_64 / aarch64** — glibc の `<endian.h>` の公開名 16、不足 0、未記載 0

- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`

### errno.h

**x86_64 / aarch64** — glibc の `<errno.h>` の公開名 138、不足 2、未記載 2

- 不足(iso): **`ENOTSUP`**
- 不足(gnu): **`error_t`**
- ガード `__error_t_defined` → `error_t`: absent

### fcntl.h

**x86_64** — glibc の `<fcntl.h>` の公開名 210、不足 154、未記載 155

- 不足(iso): **`F_EXLCK`** **`F_GETLK64`** **`F_SETLK64`** **`F_SETLKW64`** **`F_SHLCK`** **`O_FSYNC`**
- 不足(posix): **`POSIX_FADV_DONTNEED`** **`POSIX_FADV_NOREUSE`** **`POSIX_FADV_NORMAL`** **`POSIX_FADV_RANDOM`** **`POSIX_FADV_SEQUENTIAL`** **`POSIX_FADV_WILLNEED`** **`S_IFBLK`** **`S_IFCHR`** **`S_IFDIR`** **`S_IFIFO`** **`S_IFLNK`** **`S_IFMT`** **`S_IFREG`** **`S_IFSOCK`** **`S_IRGRP`** **`S_IROTH`** **`S_IRUSR`** **`S_IRWXG`** **`S_IRWXO`** **`S_IRWXU`** **`S_ISGID`** **`S_ISUID`** **`S_IWGRP`** **`S_IWOTH`** **`S_IWUSR`** **`S_IXGRP`** **`S_IXOTH`** **`S_IXUSR`** **`UTIME_NOW`** **`UTIME_OMIT`** **`posix_fadvise`** **`posix_fallocate`** **`st_atime`** **`st_ctime`** **`st_mtime`** **`struct stat`** **`struct timespec`** **`time_t`**
- 不足(xopen): **`S_ISVTX`**
- 不足(default): **`FAPPEND`** **`FASYNC`** **`FFSYNC`** **`FNDELAY`** **`FNONBLOCK`** **`F_LOCK`** **`F_OK`** **`F_TEST`** **`F_TLOCK`** **`F_ULOCK`** **`LOCK_EX`** **`LOCK_NB`** **`LOCK_SH`** **`LOCK_UN`** **`R_OK`** **`W_OK`** **`X_OK`** **`lockf`**
- 不足(gnu): **`AT_EMPTY_PATH`** **`AT_HANDLE_FID`** **`AT_NO_AUTOMOUNT`** **`AT_RECURSIVE`** **`AT_STATX_DONT_SYNC`** **`AT_STATX_FORCE_SYNC`** **`AT_STATX_SYNC_AS_STAT`** **`AT_STATX_SYNC_TYPE`** **`DN_ACCESS`** **`DN_ATTRIB`** **`DN_CREATE`** **`DN_DELETE`** **`DN_MODIFY`** **`DN_MULTISHOT`** **`DN_RENAME`** **`FALLOC_FL_ALLOCATE_RANGE`** **`FALLOC_FL_COLLAPSE_RANGE`** **`FALLOC_FL_INSERT_RANGE`** **`FALLOC_FL_KEEP_SIZE`** **`FALLOC_FL_NO_HIDE_STALE`** **`FALLOC_FL_PUNCH_HOLE`** **`FALLOC_FL_UNSHARE_RANGE`** **`FALLOC_FL_ZERO_RANGE`** **`F_ADD_SEALS`** **`F_GETLEASE`** **`F_GETOWN_EX`** **`F_GETSIG`** **`F_GET_FILE_RW_HINT`** **`F_GET_RW_HINT`** **`F_GET_SEALS`** **`F_NOTIFY`** **`F_OFD_GETLK`** **`F_OFD_SETLK`** **`F_OFD_SETLKW`** **`F_OWNER_GID`** **`F_OWNER_PGRP`** **`F_OWNER_PID`** **`F_OWNER_TID`** **`F_SEAL_EXEC`** **`F_SEAL_FUTURE_WRITE`** **`F_SEAL_GROW`** **`F_SEAL_SEAL`** **`F_SEAL_SHRINK`** **`F_SEAL_WRITE`** **`F_SETLEASE`** **`F_SETOWN_EX`** **`F_SETSIG`** **`F_SET_FILE_RW_HINT`** **`F_SET_RW_HINT`** **`LOCK_MAND`** **`LOCK_READ`** **`LOCK_RW`** **`LOCK_WRITE`** **`MAX_HANDLE_SZ`** **`RWF_WRITE_LIFE_NOT_SET`** **`RWH_WRITE_LIFE_EXTREME`** **`RWH_WRITE_LIFE_LONG`** **`RWH_WRITE_LIFE_MEDIUM`** **`RWH_WRITE_LIFE_NONE`** **`RWH_WRITE_LIFE_NOT_SET`** **`RWH_WRITE_LIFE_SHORT`** **`SPLICE_F_GIFT`** **`SPLICE_F_MORE`** **`SPLICE_F_MOVE`** **`SPLICE_F_NONBLOCK`** **`SYNC_FILE_RANGE_WAIT_AFTER`** **`SYNC_FILE_RANGE_WAIT_BEFORE`** **`SYNC_FILE_RANGE_WRITE`** **`SYNC_FILE_RANGE_WRITE_AND_WAIT`** **`creat64`** **`fallocate`** **`fallocate64`** **`fcntl64`** **`lockf64`** **`name_to_handle_at`** **`off64_t`** **`open64`** **`open_by_handle_at`** **`openat64`** **`posix_fadvise64`** **`posix_fallocate64`** **`readahead`** **`splice`** **`struct f_owner_ex`** **`struct file_handle`** **`struct flock64`** **`struct iovec`** **`struct stat64`** **`sync_file_range`** **`tee`** **`vmsplice`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `enum __pid_type`
- ガード `__iovec_defined` → `struct iovec`: absent
- ガード `__mode_t_defined` → `mode_t`: self
- ガード `__off64_t_defined` → `off64_t`: absent
- ガード `__off_t_defined` → `off_t`: self
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__time_t_defined` → `time_t`: absent

**aarch64** — glibc の `<fcntl.h>` の公開名 209、不足 153、未記載 154

- 不足(iso): **`F_EXLCK`** **`F_GETLK64`** **`F_SETLK64`** **`F_SETLKW64`** **`F_SHLCK`** **`O_FSYNC`**
- 不足(posix): **`POSIX_FADV_DONTNEED`** **`POSIX_FADV_NOREUSE`** **`POSIX_FADV_NORMAL`** **`POSIX_FADV_RANDOM`** **`POSIX_FADV_SEQUENTIAL`** **`POSIX_FADV_WILLNEED`** **`S_IFBLK`** **`S_IFCHR`** **`S_IFDIR`** **`S_IFIFO`** **`S_IFLNK`** **`S_IFMT`** **`S_IFREG`** **`S_IFSOCK`** **`S_IRGRP`** **`S_IROTH`** **`S_IRUSR`** **`S_IRWXG`** **`S_IRWXO`** **`S_IRWXU`** **`S_ISGID`** **`S_ISUID`** **`S_IWGRP`** **`S_IWOTH`** **`S_IWUSR`** **`S_IXGRP`** **`S_IXOTH`** **`S_IXUSR`** **`UTIME_NOW`** **`UTIME_OMIT`** **`posix_fadvise`** **`posix_fallocate`** **`st_atime`** **`st_ctime`** **`st_mtime`** **`struct stat`** **`struct timespec`** **`time_t`**
- 不足(xopen): **`S_ISVTX`**
- 不足(default): **`FAPPEND`** **`FASYNC`** **`FFSYNC`** **`FNDELAY`** **`FNONBLOCK`** **`F_LOCK`** **`F_OK`** **`F_TEST`** **`F_TLOCK`** **`F_ULOCK`** **`LOCK_EX`** **`LOCK_NB`** **`LOCK_SH`** **`LOCK_UN`** **`R_OK`** **`W_OK`** **`X_OK`** **`lockf`**
- 不足(gnu): **`AT_EMPTY_PATH`** **`AT_HANDLE_FID`** **`AT_NO_AUTOMOUNT`** **`AT_RECURSIVE`** **`AT_STATX_DONT_SYNC`** **`AT_STATX_FORCE_SYNC`** **`AT_STATX_SYNC_AS_STAT`** **`AT_STATX_SYNC_TYPE`** **`DN_ACCESS`** **`DN_ATTRIB`** **`DN_CREATE`** **`DN_DELETE`** **`DN_MODIFY`** **`DN_MULTISHOT`** **`DN_RENAME`** **`FALLOC_FL_COLLAPSE_RANGE`** **`FALLOC_FL_INSERT_RANGE`** **`FALLOC_FL_KEEP_SIZE`** **`FALLOC_FL_NO_HIDE_STALE`** **`FALLOC_FL_PUNCH_HOLE`** **`FALLOC_FL_UNSHARE_RANGE`** **`FALLOC_FL_ZERO_RANGE`** **`F_ADD_SEALS`** **`F_GETLEASE`** **`F_GETOWN_EX`** **`F_GETSIG`** **`F_GET_FILE_RW_HINT`** **`F_GET_RW_HINT`** **`F_GET_SEALS`** **`F_NOTIFY`** **`F_OFD_GETLK`** **`F_OFD_SETLK`** **`F_OFD_SETLKW`** **`F_OWNER_GID`** **`F_OWNER_PGRP`** **`F_OWNER_PID`** **`F_OWNER_TID`** **`F_SEAL_EXEC`** **`F_SEAL_FUTURE_WRITE`** **`F_SEAL_GROW`** **`F_SEAL_SEAL`** **`F_SEAL_SHRINK`** **`F_SEAL_WRITE`** **`F_SETLEASE`** **`F_SETOWN_EX`** **`F_SETSIG`** **`F_SET_FILE_RW_HINT`** **`F_SET_RW_HINT`** **`LOCK_MAND`** **`LOCK_READ`** **`LOCK_RW`** **`LOCK_WRITE`** **`MAX_HANDLE_SZ`** **`RWF_WRITE_LIFE_NOT_SET`** **`RWH_WRITE_LIFE_EXTREME`** **`RWH_WRITE_LIFE_LONG`** **`RWH_WRITE_LIFE_MEDIUM`** **`RWH_WRITE_LIFE_NONE`** **`RWH_WRITE_LIFE_NOT_SET`** **`RWH_WRITE_LIFE_SHORT`** **`SPLICE_F_GIFT`** **`SPLICE_F_MORE`** **`SPLICE_F_MOVE`** **`SPLICE_F_NONBLOCK`** **`SYNC_FILE_RANGE_WAIT_AFTER`** **`SYNC_FILE_RANGE_WAIT_BEFORE`** **`SYNC_FILE_RANGE_WRITE`** **`SYNC_FILE_RANGE_WRITE_AND_WAIT`** **`creat64`** **`fallocate`** **`fallocate64`** **`fcntl64`** **`lockf64`** **`name_to_handle_at`** **`off64_t`** **`open64`** **`open_by_handle_at`** **`openat64`** **`posix_fadvise64`** **`posix_fallocate64`** **`readahead`** **`splice`** **`struct f_owner_ex`** **`struct file_handle`** **`struct flock64`** **`struct iovec`** **`struct stat64`** **`sync_file_range`** **`tee`** **`vmsplice`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `enum __pid_type`
- ガード `__iovec_defined` → `struct iovec`: absent
- ガード `__mode_t_defined` → `mode_t`: self
- ガード `__off64_t_defined` → `off64_t`: absent
- ガード `__off_t_defined` → `off_t`: self
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__time_t_defined` → `time_t`: absent

### features.h

**x86_64 / aarch64** — glibc の `<features.h>` の公開名 0、不足 0、未記載 0

- 不足なし

### grp.h

**x86_64 / aarch64** — glibc の `<grp.h>` の公開名 18、不足 9、未記載 10

- 不足(default): **`FILE`** **`NSS_BUFLEN_GROUP`** **`fgetgrent`** **`fgetgrent_r`** **`getgrouplist`** **`initgroups`** **`setgroups`**
- 不足(gnu): **`getgrent_r`** **`putgrent`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__FILE_defined` → `FILE`: absent
- ガード `__gid_t_defined` → `gid_t`: self

### inttypes.h

**x86_64 / aarch64** — glibc の `<inttypes.h>` の公開名 203、不足 42、未記載 42

- 不足(gnu): **`PRIB16`** **`PRIB32`** **`PRIB64`** **`PRIB8`** **`PRIBFAST16`** **`PRIBFAST32`** **`PRIBFAST64`** **`PRIBFAST8`** **`PRIBLEAST16`** **`PRIBLEAST32`** **`PRIBLEAST64`** **`PRIBLEAST8`** **`PRIBMAX`** **`PRIBPTR`** **`PRIb16`** **`PRIb32`** **`PRIb64`** **`PRIb8`** **`PRIbFAST16`** **`PRIbFAST32`** **`PRIbFAST64`** **`PRIbFAST8`** **`PRIbLEAST16`** **`PRIbLEAST32`** **`PRIbLEAST64`** **`PRIbLEAST8`** **`PRIbMAX`** **`PRIbPTR`** **`SCNb16`** **`SCNb32`** **`SCNb64`** **`SCNb8`** **`SCNbFAST16`** **`SCNbFAST32`** **`SCNbFAST64`** **`SCNbFAST8`** **`SCNbLEAST16`** **`SCNbLEAST32`** **`SCNbLEAST64`** **`SCNbLEAST8`** **`SCNbMAX`** **`SCNbPTR`**
- 予約名の型: `__gwchar_t`
- ガード `____gwchar_t_defined` → `__gwchar_t`: absent

### langinfo.h

**x86_64 / aarch64** — glibc の `<langinfo.h>` の公開名 98、不足 38、未記載 39

- 不足(posix): **`locale_t`** **`nl_langinfo_l`**
- 不足(gnu): **`ALTMON_1`** **`ALTMON_10`** **`ALTMON_11`** **`ALTMON_12`** **`ALTMON_2`** **`ALTMON_3`** **`ALTMON_4`** **`ALTMON_5`** **`ALTMON_6`** **`ALTMON_7`** **`ALTMON_8`** **`ALTMON_9`** **`CURRENCY_SYMBOL`** **`ERA_YEAR`** **`FRAC_DIGITS`** **`GROUPING`** **`INT_CURR_SYMBOL`** **`INT_FRAC_DIGITS`** **`INT_N_CS_PRECEDES`** **`INT_N_SEP_BY_SPACE`** **`INT_N_SIGN_POSN`** **`INT_P_CS_PRECEDES`** **`INT_P_SEP_BY_SPACE`** **`INT_P_SIGN_POSN`** **`MON_DECIMAL_POINT`** **`MON_GROUPING`** **`MON_THOUSANDS_SEP`** **`NEGATIVE_SIGN`** **`NL_LOCALE_NAME`** **`N_CS_PRECEDES`** **`N_SEP_BY_SPACE`** **`N_SIGN_POSN`** **`POSITIVE_SIGN`** **`P_CS_PRECEDES`** **`P_SEP_BY_SPACE`** **`P_SIGN_POSN`**
- 取り込み不足: `nl_types.h`
- 予約名の型: `__locale_t` `struct __locale_struct`

### limits.h

**x86_64 / aarch64** — glibc の `<limits.h>` の公開名 75、不足 53、未記載 54

- 不足(posix): **`AIO_PRIO_DELTA_MAX`** **`BC_BASE_MAX`** **`BC_DIM_MAX`** **`BC_SCALE_MAX`** **`BC_STRING_MAX`** **`CHARCLASS_NAME_MAX`** **`COLL_WEIGHTS_MAX`** **`DELAYTIMER_MAX`** **`EXPR_NEST_MAX`** **`HOST_NAME_MAX`** **`LINE_MAX`** **`LOGIN_NAME_MAX`** **`MAX_CANON`** **`MAX_INPUT`** **`MQ_PRIO_MAX`** **`NAME_MAX`** **`NGROUPS_MAX`** **`PATH_MAX`** **`PIPE_BUF`** **`PTHREAD_DESTRUCTOR_ITERATIONS`** **`PTHREAD_KEYS_MAX`** **`PTHREAD_STACK_MIN`** **`RE_DUP_MAX`** **`RTSIG_MAX`** **`SEM_VALUE_MAX`** **`SSIZE_MAX`** **`TTY_NAME_MAX`** **`XATTR_LIST_MAX`** **`XATTR_NAME_MAX`** **`XATTR_SIZE_MAX`**
- 不足(xopen): **`IOV_MAX`** **`LONG_BIT`** **`NL_ARGMAX`** **`NL_LANGMAX`** **`NL_MSGMAX`** **`NL_SETMAX`** **`NL_TEXTMAX`** **`NZERO`** **`WORD_BIT`**
- 不足(gnu): **`BOOL_MAX`** **`BOOL_WIDTH`** **`CHAR_WIDTH`** **`INT_WIDTH`** **`LLONG_WIDTH`** **`LONG_WIDTH`** **`NL_NMAX`** **`SCHAR_WIDTH`** **`SHRT_WIDTH`** **`UCHAR_WIDTH`** **`UINT_WIDTH`** **`ULLONG_WIDTH`** **`ULONG_WIDTH`** **`USHRT_WIDTH`**
- 取り込み不足: `syslimits.h`

### link.h

**x86_64** — glibc の `<link.h>` の公開名 50、不足 49、未記載 56

- 不足(iso): **`ElfW`** **`Elf_Symndx`** **`La_x32_regs`** **`La_x32_retval`** **`La_x86_64_regs`** **`La_x86_64_retval`** **`La_x86_64_vector`** **`La_x86_64_xmm`** **`La_x86_64_ymm`** **`La_x86_64_zmm`** **`RT_ADD`** **`RT_CONSISTENT`** **`RT_DELETE`** **`_r_debug`** **`la_x32_gnu_pltenter`** **`la_x32_gnu_pltexit`** **`la_x86_64_gnu_pltenter`** **`la_x86_64_gnu_pltexit`** **`struct La_x86_64_regs`** **`struct La_x86_64_retval`** **`struct r_debug`** **`struct r_debug_extended`**
- 不足(gnu): **`LAV_CURRENT`** **`LA_ACT_ADD`** **`LA_ACT_CONSISTENT`** **`LA_ACT_DELETE`** **`LA_FLG_BINDFROM`** **`LA_FLG_BINDTO`** **`LA_SER_CONFIG`** **`LA_SER_DEFAULT`** **`LA_SER_LIBPATH`** **`LA_SER_ORIG`** **`LA_SER_RUNPATH`** **`LA_SER_SECURE`** **`LA_SYMB_ALTVALUE`** **`LA_SYMB_DLSYM`** **`LA_SYMB_NOPLTENTER`** **`LA_SYMB_NOPLTEXIT`** **`LA_SYMB_STRUCTCALL`** **`dl_iterate_phdr`** **`la_activity`** **`la_objclose`** **`la_objopen`** **`la_objsearch`** **`la_preinit`** **`la_symbind32`** **`la_symbind64`** **`la_version`** **`struct dl_phdr_info`**
- 取り込み不足: `dlfcn.h` `elf.h` `endian.h` `stddef.h` `stdint.h` `sys/select.h` `sys/types.h`

**aarch64** — glibc の `<link.h>` の公開名 43、不足 42、未記載 49

- 不足(iso): **`ElfW`** **`Elf_Symndx`** **`La_aarch64_regs`** **`La_aarch64_retval`** **`La_aarch64_vector`** **`RT_ADD`** **`RT_CONSISTENT`** **`RT_DELETE`** **`_r_debug`** **`la_aarch64_gnu_pltenter`** **`la_aarch64_gnu_pltexit`** **`struct La_aarch64_regs`** **`struct La_aarch64_retval`** **`struct r_debug`** **`struct r_debug_extended`**
- 不足(gnu): **`LAV_CURRENT`** **`LA_ACT_ADD`** **`LA_ACT_CONSISTENT`** **`LA_ACT_DELETE`** **`LA_FLG_BINDFROM`** **`LA_FLG_BINDTO`** **`LA_SER_CONFIG`** **`LA_SER_DEFAULT`** **`LA_SER_LIBPATH`** **`LA_SER_ORIG`** **`LA_SER_RUNPATH`** **`LA_SER_SECURE`** **`LA_SYMB_ALTVALUE`** **`LA_SYMB_DLSYM`** **`LA_SYMB_NOPLTENTER`** **`LA_SYMB_NOPLTEXIT`** **`LA_SYMB_STRUCTCALL`** **`dl_iterate_phdr`** **`la_activity`** **`la_objclose`** **`la_objopen`** **`la_objsearch`** **`la_preinit`** **`la_symbind32`** **`la_symbind64`** **`la_version`** **`struct dl_phdr_info`**
- 取り込み不足: `dlfcn.h` `elf.h` `endian.h` `stddef.h` `stdint.h` `sys/select.h` `sys/types.h`

### locale.h

**x86_64 / aarch64** — glibc の `<locale.h>` の公開名 35、不足 19、未記載 20

- 不足(posix): **`LC_ADDRESS_MASK`** **`LC_ALL_MASK`** **`LC_COLLATE_MASK`** **`LC_CTYPE_MASK`** **`LC_GLOBAL_LOCALE`** **`LC_IDENTIFICATION_MASK`** **`LC_MEASUREMENT_MASK`** **`LC_MESSAGES_MASK`** **`LC_MONETARY_MASK`** **`LC_NAME_MASK`** **`LC_NUMERIC_MASK`** **`LC_PAPER_MASK`** **`LC_TELEPHONE_MASK`** **`LC_TIME_MASK`** **`duplocale`** **`freelocale`** **`locale_t`** **`newlocale`** **`uselocale`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__locale_t` `struct __locale_struct`

### math.h

**x86_64** — glibc の `<math.h>` の公開名 972、不足 777、未記載 777

- 不足(iso): **`ilogbf`** **`ilogbl`** **`llrintf`** **`llrintl`** **`llroundf`** **`llroundl`** **`lrintf`** **`lrintl`** **`lroundf`** **`lroundl`** **`nexttoward`** **`nexttowardf`** **`nexttowardl`** **`remquo`** **`remquof`** **`remquol`** **`scalblnf`** **`scalblnl`**
- 不足(xopen): **`MAXFLOAT`** **`j0`** **`j1`** **`jn`** **`signgam`** **`y0`** **`y1`** **`yn`**
- 不足(default): **`drem`** **`dremf`** **`dreml`** **`finite`** **`finitef`** **`finitel`** **`gamma`** **`gammaf`** **`gammal`** **`isinff`** **`isinfl`** **`isnanf`** **`isnanl`** **`j0f`** **`j0l`** **`j1f`** **`j1l`** **`jnf`** **`jnl`** **`lgamma_r`** **`lgammaf_r`** **`lgammal_r`** **`scalb`** **`scalbf`** **`scalbl`** **`significand`** **`significandf`** **`significandl`** **`y0f`** **`y0l`** **`y1f`** **`y1l`** **`ynf`** **`ynl`**
- 不足(gnu): **`FP_INT_DOWNWARD`** **`FP_INT_TONEAREST`** **`FP_INT_TONEARESTFROMZERO`** **`FP_INT_TOWARDZERO`** **`FP_INT_UPWARD`** **`FP_LLOGB0`** **`FP_LLOGBNAN`** **`HUGE_VAL_F128`** **`HUGE_VAL_F32`** **`HUGE_VAL_F32X`** **`HUGE_VAL_F64`** **`HUGE_VAL_F64X`** **`M_1_PIf`** **`M_1_PIf128`** **`M_1_PIf32`** **`M_1_PIf32x`** **`M_1_PIf64`** **`M_1_PIf64x`** **`M_1_PIl`** **`M_2_PIf`** **`M_2_PIf128`** **`M_2_PIf32`** **`M_2_PIf32x`** **`M_2_PIf64`** **`M_2_PIf64x`** **`M_2_PIl`** **`M_2_SQRTPIf`** **`M_2_SQRTPIf128`** **`M_2_SQRTPIf32`** **`M_2_SQRTPIf32x`** **`M_2_SQRTPIf64`** **`M_2_SQRTPIf64x`** **`M_2_SQRTPIl`** **`M_Ef`** **`M_Ef128`** **`M_Ef32`** **`M_Ef32x`** **`M_Ef64`** **`M_Ef64x`** **`M_El`** **`M_LN10f`** **`M_LN10f128`** **`M_LN10f32`** **`M_LN10f32x`** **`M_LN10f64`** **`M_LN10f64x`** **`M_LN10l`** **`M_LN2f`** **`M_LN2f128`** **`M_LN2f32`** **`M_LN2f32x`** **`M_LN2f64`** **`M_LN2f64x`** **`M_LN2l`** **`M_LOG10Ef`** **`M_LOG10Ef128`** **`M_LOG10Ef32`** **`M_LOG10Ef32x`** **`M_LOG10Ef64`** **`M_LOG10Ef64x`** **`M_LOG10El`** **`M_LOG2Ef`** **`M_LOG2Ef128`** **`M_LOG2Ef32`** **`M_LOG2Ef32x`** **`M_LOG2Ef64`** **`M_LOG2Ef64x`** **`M_LOG2El`** **`M_PI_2f`** **`M_PI_2f128`** **`M_PI_2f32`** **`M_PI_2f32x`** **`M_PI_2f64`** **`M_PI_2f64x`** **`M_PI_2l`** **`M_PI_4f`** **`M_PI_4f128`** **`M_PI_4f32`** **`M_PI_4f32x`** **`M_PI_4f64`** **`M_PI_4f64x`** **`M_PI_4l`** **`M_PIf`** **`M_PIf128`** **`M_PIf32`** **`M_PIf32x`** **`M_PIf64`** **`M_PIf64x`** **`M_PIl`** **`M_SQRT1_2f`** **`M_SQRT1_2f128`** **`M_SQRT1_2f32`** **`M_SQRT1_2f32x`** **`M_SQRT1_2f64`** **`M_SQRT1_2f64x`** **`M_SQRT1_2l`** **`M_SQRT2f`** **`M_SQRT2f128`** **`M_SQRT2f32`** **`M_SQRT2f32x`** **`M_SQRT2f64`** **`M_SQRT2f64x`** **`M_SQRT2l`** **`SNAN`** **`SNANF`** **`SNANF128`** **`SNANF32`** **`SNANF32X`** **`SNANF64`** **`SNANF64X`** **`SNANL`** **`acosf128`** **`acosf32`** **`acosf32x`** **`acosf64`** **`acosf64x`** **`acoshf128`** **`acoshf32`** **`acoshf32x`** **`acoshf64`** **`acoshf64x`** **`asinf128`** **`asinf32`** **`asinf32x`** **`asinf64`** **`asinf64x`** **`asinhf128`** **`asinhf32`** **`asinhf32x`** **`asinhf64`** **`asinhf64x`** **`atan2f128`** **`atan2f32`** **`atan2f32x`** **`atan2f64`** **`atan2f64x`** **`atanf128`** **`atanf32`** **`atanf32x`** **`atanf64`** **`atanf64x`** **`atanhf128`** **`atanhf32`** **`atanhf32x`** **`atanhf64`** **`atanhf64x`** **`canonicalize`** **`canonicalizef`** **`canonicalizef128`** **`canonicalizef32`** **`canonicalizef32x`** **`canonicalizef64`** **`canonicalizef64x`** **`canonicalizel`** **`cbrtf128`** **`cbrtf32`** **`cbrtf32x`** **`cbrtf64`** **`cbrtf64x`** **`ceilf128`** **`ceilf32`** **`ceilf32x`** **`ceilf64`** **`ceilf64x`** **`copysignf128`** **`copysignf32`** **`copysignf32x`** **`copysignf64`** **`copysignf64x`** **`cosf128`** **`cosf32`** **`cosf32x`** **`cosf64`** **`cosf64x`** **`coshf128`** **`coshf32`** **`coshf32x`** **`coshf64`** **`coshf64x`** **`daddl`** **`ddivl`** **`dfmal`** **`dmull`** **`dsqrtl`** **`dsubl`** **`erfcf128`** **`erfcf32`** **`erfcf32x`** **`erfcf64`** **`erfcf64x`** **`erff128`** **`erff32`** **`erff32x`** **`erff64`** **`erff64x`** **`exp10`** **`exp10f`** **`exp10f128`** **`exp10f32`** **`exp10f32x`** **`exp10f64`** **`exp10f64x`** **`exp10l`** **`exp2f128`** **`exp2f32`** **`exp2f32x`** **`exp2f64`** **`exp2f64x`** **`expf128`** **`expf32`** **`expf32x`** **`expf64`** **`expf64x`** **`expm1f128`** **`expm1f32`** **`expm1f32x`** **`expm1f64`** **`expm1f64x`** **`f32addf128`** **`f32addf32x`** **`f32addf64`** **`f32addf64x`** **`f32divf128`** **`f32divf32x`** **`f32divf64`** **`f32divf64x`** **`f32fmaf128`** **`f32fmaf32x`** **`f32fmaf64`** **`f32fmaf64x`** **`f32mulf128`** **`f32mulf32x`** **`f32mulf64`** **`f32mulf64x`** **`f32sqrtf128`** **`f32sqrtf32x`** **`f32sqrtf64`** **`f32sqrtf64x`** **`f32subf128`** **`f32subf32x`** **`f32subf64`** **`f32subf64x`** **`f32xaddf128`** **`f32xaddf64`** **`f32xaddf64x`** **`f32xdivf128`** **`f32xdivf64`** **`f32xdivf64x`** **`f32xfmaf128`** **`f32xfmaf64`** **`f32xfmaf64x`** **`f32xmulf128`** **`f32xmulf64`** **`f32xmulf64x`** **`f32xsqrtf128`** **`f32xsqrtf64`** **`f32xsqrtf64x`** **`f32xsubf128`** **`f32xsubf64`** **`f32xsubf64x`** **`f64addf128`** **`f64addf64x`** **`f64divf128`** **`f64divf64x`** **`f64fmaf128`** **`f64fmaf64x`** **`f64mulf128`** **`f64mulf64x`** **`f64sqrtf128`** **`f64sqrtf64x`** **`f64subf128`** **`f64subf64x`** **`f64xaddf128`** **`f64xdivf128`** **`f64xfmaf128`** **`f64xmulf128`** **`f64xsqrtf128`** **`f64xsubf128`** **`fabsf128`** **`fabsf32`** **`fabsf32x`** **`fabsf64`** **`fabsf64x`** **`fadd`** **`faddl`** **`fdimf128`** **`fdimf32`** **`fdimf32x`** **`fdimf64`** **`fdimf64x`** **`fdiv`** **`fdivl`** **`ffma`** **`ffmal`** **`floorf128`** **`floorf32`** **`floorf32x`** **`floorf64`** **`floorf64x`** **`fmaf128`** **`fmaf32`** **`fmaf32x`** **`fmaf64`** **`fmaf64x`** **`fmaxf128`** **`fmaxf32`** **`fmaxf32x`** **`fmaxf64`** **`fmaxf64x`** **`fmaximum`** **`fmaximum_mag`** **`fmaximum_mag_num`** **`fmaximum_mag_numf`** **`fmaximum_mag_numf128`** **`fmaximum_mag_numf32`** **`fmaximum_mag_numf32x`** **`fmaximum_mag_numf64`** **`fmaximum_mag_numf64x`** **`fmaximum_mag_numl`** **`fmaximum_magf`** **`fmaximum_magf128`** **`fmaximum_magf32`** **`fmaximum_magf32x`** **`fmaximum_magf64`** **`fmaximum_magf64x`** **`fmaximum_magl`** **`fmaximum_num`** **`fmaximum_numf`** **`fmaximum_numf128`** **`fmaximum_numf32`** **`fmaximum_numf32x`** **`fmaximum_numf64`** **`fmaximum_numf64x`** **`fmaximum_numl`** **`fmaximumf`** **`fmaximumf128`** **`fmaximumf32`** **`fmaximumf32x`** **`fmaximumf64`** **`fmaximumf64x`** **`fmaximuml`** **`fmaxmag`** **`fmaxmagf`** **`fmaxmagf128`** **`fmaxmagf32`** **`fmaxmagf32x`** **`fmaxmagf64`** **`fmaxmagf64x`** **`fmaxmagl`** **`fminf128`** **`fminf32`** **`fminf32x`** **`fminf64`** **`fminf64x`** **`fminimum`** **`fminimum_mag`** **`fminimum_mag_num`** **`fminimum_mag_numf`** **`fminimum_mag_numf128`** **`fminimum_mag_numf32`** **`fminimum_mag_numf32x`** **`fminimum_mag_numf64`** **`fminimum_mag_numf64x`** **`fminimum_mag_numl`** **`fminimum_magf`** **`fminimum_magf128`** **`fminimum_magf32`** **`fminimum_magf32x`** **`fminimum_magf64`** **`fminimum_magf64x`** **`fminimum_magl`** **`fminimum_num`** **`fminimum_numf`** **`fminimum_numf128`** **`fminimum_numf32`** **`fminimum_numf32x`** **`fminimum_numf64`** **`fminimum_numf64x`** **`fminimum_numl`** **`fminimumf`** **`fminimumf128`** **`fminimumf32`** **`fminimumf32x`** **`fminimumf64`** **`fminimumf64x`** **`fminimuml`** **`fminmag`** **`fminmagf`** **`fminmagf128`** **`fminmagf32`** **`fminmagf32x`** **`fminmagf64`** **`fminmagf64x`** **`fminmagl`** **`fmodf128`** **`fmodf32`** **`fmodf32x`** **`fmodf64`** **`fmodf64x`** **`fmul`** **`fmull`** **`frexpf128`** **`frexpf32`** **`frexpf32x`** **`frexpf64`** **`frexpf64x`** **`fromfp`** **`fromfpf`** **`fromfpf128`** **`fromfpf32`** **`fromfpf32x`** **`fromfpf64`** **`fromfpf64x`** **`fromfpl`** **`fromfpx`** **`fromfpxf`** **`fromfpxf128`** **`fromfpxf32`** **`fromfpxf32x`** **`fromfpxf64`** **`fromfpxf64x`** **`fromfpxl`** **`fsqrt`** **`fsqrtl`** **`fsub`** **`fsubl`** **`getpayload`** **`getpayloadf`** **`getpayloadf128`** **`getpayloadf32`** **`getpayloadf32x`** **`getpayloadf64`** **`getpayloadf64x`** **`getpayloadl`** **`hypotf128`** **`hypotf32`** **`hypotf32x`** **`hypotf64`** **`hypotf64x`** **`ilogbf128`** **`ilogbf32`** **`ilogbf32x`** **`ilogbf64`** **`ilogbf64x`** **`iscanonical`** **`iseqsig`** **`issignaling`** **`issubnormal`** **`iszero`** **`j0f128`** **`j0f32`** **`j0f32x`** **`j0f64`** **`j0f64x`** **`j1f128`** **`j1f32`** **`j1f32x`** **`j1f64`** **`j1f64x`** **`jnf128`** **`jnf32`** **`jnf32x`** **`jnf64`** **`jnf64x`** **`ldexpf128`** **`ldexpf32`** **`ldexpf32x`** **`ldexpf64`** **`ldexpf64x`** **`lgammaf128`** **`lgammaf128_r`** **`lgammaf32`** **`lgammaf32_r`** **`lgammaf32x`** **`lgammaf32x_r`** **`lgammaf64`** **`lgammaf64_r`** **`lgammaf64x`** **`lgammaf64x_r`** **`llogb`** **`llogbf`** **`llogbf128`** **`llogbf32`** **`llogbf32x`** **`llogbf64`** **`llogbf64x`** **`llogbl`** **`llrintf128`** **`llrintf32`** **`llrintf32x`** **`llrintf64`** **`llrintf64x`** **`llroundf128`** **`llroundf32`** **`llroundf32x`** **`llroundf64`** **`llroundf64x`** **`log10f128`** **`log10f32`** **`log10f32x`** **`log10f64`** **`log10f64x`** **`log1pf128`** **`log1pf32`** **`log1pf32x`** **`log1pf64`** **`log1pf64x`** **`log2f128`** **`log2f32`** **`log2f32x`** **`log2f64`** **`log2f64x`** **`logbf128`** **`logbf32`** **`logbf32x`** **`logbf64`** **`logbf64x`** **`logf128`** **`logf32`** **`logf32x`** **`logf64`** **`logf64x`** **`lrintf128`** **`lrintf32`** **`lrintf32x`** **`lrintf64`** **`lrintf64x`** **`lroundf128`** **`lroundf32`** **`lroundf32x`** **`lroundf64`** **`lroundf64x`** **`modff128`** **`modff32`** **`modff32x`** **`modff64`** **`modff64x`** **`nanf128`** **`nanf32`** **`nanf32x`** **`nanf64`** **`nanf64x`** **`nearbyintf128`** **`nearbyintf32`** **`nearbyintf32x`** **`nearbyintf64`** **`nearbyintf64x`** **`nextafterf128`** **`nextafterf32`** **`nextafterf32x`** **`nextafterf64`** **`nextafterf64x`** **`nextdown`** **`nextdownf`** **`nextdownf128`** **`nextdownf32`** **`nextdownf32x`** **`nextdownf64`** **`nextdownf64x`** **`nextdownl`** **`nextup`** **`nextupf`** **`nextupf128`** **`nextupf32`** **`nextupf32x`** **`nextupf64`** **`nextupf64x`** **`nextupl`** **`powf128`** **`powf32`** **`powf32x`** **`powf64`** **`powf64x`** **`remainderf128`** **`remainderf32`** **`remainderf32x`** **`remainderf64`** **`remainderf64x`** **`remquof128`** **`remquof32`** **`remquof32x`** **`remquof64`** **`remquof64x`** **`rintf128`** **`rintf32`** **`rintf32x`** **`rintf64`** **`rintf64x`** **`roundeven`** **`roundevenf`** **`roundevenf128`** **`roundevenf32`** **`roundevenf32x`** **`roundevenf64`** **`roundevenf64x`** **`roundevenl`** **`roundf128`** **`roundf32`** **`roundf32x`** **`roundf64`** **`roundf64x`** **`scalblnf128`** **`scalblnf32`** **`scalblnf32x`** **`scalblnf64`** **`scalblnf64x`** **`scalbnf128`** **`scalbnf32`** **`scalbnf32x`** **`scalbnf64`** **`scalbnf64x`** **`setpayload`** **`setpayloadf`** **`setpayloadf128`** **`setpayloadf32`** **`setpayloadf32x`** **`setpayloadf64`** **`setpayloadf64x`** **`setpayloadl`** **`setpayloadsig`** **`setpayloadsigf`** **`setpayloadsigf128`** **`setpayloadsigf32`** **`setpayloadsigf32x`** **`setpayloadsigf64`** **`setpayloadsigf64x`** **`setpayloadsigl`** **`sincos`** **`sincosf`** **`sincosf128`** **`sincosf32`** **`sincosf32x`** **`sincosf64`** **`sincosf64x`** **`sincosl`** **`sinf128`** **`sinf32`** **`sinf32x`** **`sinf64`** **`sinf64x`** **`sinhf128`** **`sinhf32`** **`sinhf32x`** **`sinhf64`** **`sinhf64x`** **`sqrtf128`** **`sqrtf32`** **`sqrtf32x`** **`sqrtf64`** **`sqrtf64x`** **`tanf128`** **`tanf32`** **`tanf32x`** **`tanf64`** **`tanf64x`** **`tanhf128`** **`tanhf32`** **`tanhf32x`** **`tanhf64`** **`tanhf64x`** **`tgammaf128`** **`tgammaf32`** **`tgammaf32x`** **`tgammaf64`** **`tgammaf64x`** **`totalorder`** **`totalorderf`** **`totalorderf128`** **`totalorderf32`** **`totalorderf32x`** **`totalorderf64`** **`totalorderf64x`** **`totalorderl`** **`totalordermag`** **`totalordermagf`** **`totalordermagf128`** **`totalordermagf32`** **`totalordermagf32x`** **`totalordermagf64`** **`totalordermagf64x`** **`totalordermagl`** **`truncf128`** **`truncf32`** **`truncf32x`** **`truncf64`** **`truncf64x`** **`ufromfp`** **`ufromfpf`** **`ufromfpf128`** **`ufromfpf32`** **`ufromfpf32x`** **`ufromfpf64`** **`ufromfpf64x`** **`ufromfpl`** **`ufromfpx`** **`ufromfpxf`** **`ufromfpxf128`** **`ufromfpxf32`** **`ufromfpxf32x`** **`ufromfpxf64`** **`ufromfpxf64x`** **`ufromfpxl`** **`y0f128`** **`y0f32`** **`y0f32x`** **`y0f64`** **`y0f64x`** **`y1f128`** **`y1f32`** **`y1f32x`** **`y1f64`** **`y1f64x`** **`ynf128`** **`ynf32`** **`ynf32x`** **`ynf64`** **`ynf64x`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`

**aarch64** — glibc の `<math.h>` の公開名 974、不足 779、未記載 779

- 不足(iso): **`FP_FAST_FMA`** **`FP_FAST_FMAF`** **`ilogbf`** **`ilogbl`** **`llrintf`** **`llrintl`** **`llroundf`** **`llroundl`** **`lrintf`** **`lrintl`** **`lroundf`** **`lroundl`** **`nexttoward`** **`nexttowardf`** **`nexttowardl`** **`remquo`** **`remquof`** **`remquol`** **`scalblnf`** **`scalblnl`**
- 不足(xopen): **`MAXFLOAT`** **`j0`** **`j1`** **`jn`** **`signgam`** **`y0`** **`y1`** **`yn`**
- 不足(default): **`drem`** **`dremf`** **`dreml`** **`finite`** **`finitef`** **`finitel`** **`gamma`** **`gammaf`** **`gammal`** **`isinff`** **`isinfl`** **`isnanf`** **`isnanl`** **`j0f`** **`j0l`** **`j1f`** **`j1l`** **`jnf`** **`jnl`** **`lgamma_r`** **`lgammaf_r`** **`lgammal_r`** **`scalb`** **`scalbf`** **`scalbl`** **`significand`** **`significandf`** **`significandl`** **`y0f`** **`y0l`** **`y1f`** **`y1l`** **`ynf`** **`ynl`**
- 不足(gnu): **`FP_INT_DOWNWARD`** **`FP_INT_TONEAREST`** **`FP_INT_TONEARESTFROMZERO`** **`FP_INT_TOWARDZERO`** **`FP_INT_UPWARD`** **`FP_LLOGB0`** **`FP_LLOGBNAN`** **`HUGE_VAL_F128`** **`HUGE_VAL_F32`** **`HUGE_VAL_F32X`** **`HUGE_VAL_F64`** **`HUGE_VAL_F64X`** **`M_1_PIf`** **`M_1_PIf128`** **`M_1_PIf32`** **`M_1_PIf32x`** **`M_1_PIf64`** **`M_1_PIf64x`** **`M_1_PIl`** **`M_2_PIf`** **`M_2_PIf128`** **`M_2_PIf32`** **`M_2_PIf32x`** **`M_2_PIf64`** **`M_2_PIf64x`** **`M_2_PIl`** **`M_2_SQRTPIf`** **`M_2_SQRTPIf128`** **`M_2_SQRTPIf32`** **`M_2_SQRTPIf32x`** **`M_2_SQRTPIf64`** **`M_2_SQRTPIf64x`** **`M_2_SQRTPIl`** **`M_Ef`** **`M_Ef128`** **`M_Ef32`** **`M_Ef32x`** **`M_Ef64`** **`M_Ef64x`** **`M_El`** **`M_LN10f`** **`M_LN10f128`** **`M_LN10f32`** **`M_LN10f32x`** **`M_LN10f64`** **`M_LN10f64x`** **`M_LN10l`** **`M_LN2f`** **`M_LN2f128`** **`M_LN2f32`** **`M_LN2f32x`** **`M_LN2f64`** **`M_LN2f64x`** **`M_LN2l`** **`M_LOG10Ef`** **`M_LOG10Ef128`** **`M_LOG10Ef32`** **`M_LOG10Ef32x`** **`M_LOG10Ef64`** **`M_LOG10Ef64x`** **`M_LOG10El`** **`M_LOG2Ef`** **`M_LOG2Ef128`** **`M_LOG2Ef32`** **`M_LOG2Ef32x`** **`M_LOG2Ef64`** **`M_LOG2Ef64x`** **`M_LOG2El`** **`M_PI_2f`** **`M_PI_2f128`** **`M_PI_2f32`** **`M_PI_2f32x`** **`M_PI_2f64`** **`M_PI_2f64x`** **`M_PI_2l`** **`M_PI_4f`** **`M_PI_4f128`** **`M_PI_4f32`** **`M_PI_4f32x`** **`M_PI_4f64`** **`M_PI_4f64x`** **`M_PI_4l`** **`M_PIf`** **`M_PIf128`** **`M_PIf32`** **`M_PIf32x`** **`M_PIf64`** **`M_PIf64x`** **`M_PIl`** **`M_SQRT1_2f`** **`M_SQRT1_2f128`** **`M_SQRT1_2f32`** **`M_SQRT1_2f32x`** **`M_SQRT1_2f64`** **`M_SQRT1_2f64x`** **`M_SQRT1_2l`** **`M_SQRT2f`** **`M_SQRT2f128`** **`M_SQRT2f32`** **`M_SQRT2f32x`** **`M_SQRT2f64`** **`M_SQRT2f64x`** **`M_SQRT2l`** **`SNAN`** **`SNANF`** **`SNANF128`** **`SNANF32`** **`SNANF32X`** **`SNANF64`** **`SNANF64X`** **`SNANL`** **`acosf128`** **`acosf32`** **`acosf32x`** **`acosf64`** **`acosf64x`** **`acoshf128`** **`acoshf32`** **`acoshf32x`** **`acoshf64`** **`acoshf64x`** **`asinf128`** **`asinf32`** **`asinf32x`** **`asinf64`** **`asinf64x`** **`asinhf128`** **`asinhf32`** **`asinhf32x`** **`asinhf64`** **`asinhf64x`** **`atan2f128`** **`atan2f32`** **`atan2f32x`** **`atan2f64`** **`atan2f64x`** **`atanf128`** **`atanf32`** **`atanf32x`** **`atanf64`** **`atanf64x`** **`atanhf128`** **`atanhf32`** **`atanhf32x`** **`atanhf64`** **`atanhf64x`** **`canonicalize`** **`canonicalizef`** **`canonicalizef128`** **`canonicalizef32`** **`canonicalizef32x`** **`canonicalizef64`** **`canonicalizef64x`** **`canonicalizel`** **`cbrtf128`** **`cbrtf32`** **`cbrtf32x`** **`cbrtf64`** **`cbrtf64x`** **`ceilf128`** **`ceilf32`** **`ceilf32x`** **`ceilf64`** **`ceilf64x`** **`copysignf128`** **`copysignf32`** **`copysignf32x`** **`copysignf64`** **`copysignf64x`** **`cosf128`** **`cosf32`** **`cosf32x`** **`cosf64`** **`cosf64x`** **`coshf128`** **`coshf32`** **`coshf32x`** **`coshf64`** **`coshf64x`** **`daddl`** **`ddivl`** **`dfmal`** **`dmull`** **`dsqrtl`** **`dsubl`** **`erfcf128`** **`erfcf32`** **`erfcf32x`** **`erfcf64`** **`erfcf64x`** **`erff128`** **`erff32`** **`erff32x`** **`erff64`** **`erff64x`** **`exp10`** **`exp10f`** **`exp10f128`** **`exp10f32`** **`exp10f32x`** **`exp10f64`** **`exp10f64x`** **`exp10l`** **`exp2f128`** **`exp2f32`** **`exp2f32x`** **`exp2f64`** **`exp2f64x`** **`expf128`** **`expf32`** **`expf32x`** **`expf64`** **`expf64x`** **`expm1f128`** **`expm1f32`** **`expm1f32x`** **`expm1f64`** **`expm1f64x`** **`f32addf128`** **`f32addf32x`** **`f32addf64`** **`f32addf64x`** **`f32divf128`** **`f32divf32x`** **`f32divf64`** **`f32divf64x`** **`f32fmaf128`** **`f32fmaf32x`** **`f32fmaf64`** **`f32fmaf64x`** **`f32mulf128`** **`f32mulf32x`** **`f32mulf64`** **`f32mulf64x`** **`f32sqrtf128`** **`f32sqrtf32x`** **`f32sqrtf64`** **`f32sqrtf64x`** **`f32subf128`** **`f32subf32x`** **`f32subf64`** **`f32subf64x`** **`f32xaddf128`** **`f32xaddf64`** **`f32xaddf64x`** **`f32xdivf128`** **`f32xdivf64`** **`f32xdivf64x`** **`f32xfmaf128`** **`f32xfmaf64`** **`f32xfmaf64x`** **`f32xmulf128`** **`f32xmulf64`** **`f32xmulf64x`** **`f32xsqrtf128`** **`f32xsqrtf64`** **`f32xsqrtf64x`** **`f32xsubf128`** **`f32xsubf64`** **`f32xsubf64x`** **`f64addf128`** **`f64addf64x`** **`f64divf128`** **`f64divf64x`** **`f64fmaf128`** **`f64fmaf64x`** **`f64mulf128`** **`f64mulf64x`** **`f64sqrtf128`** **`f64sqrtf64x`** **`f64subf128`** **`f64subf64x`** **`f64xaddf128`** **`f64xdivf128`** **`f64xfmaf128`** **`f64xmulf128`** **`f64xsqrtf128`** **`f64xsubf128`** **`fabsf128`** **`fabsf32`** **`fabsf32x`** **`fabsf64`** **`fabsf64x`** **`fadd`** **`faddl`** **`fdimf128`** **`fdimf32`** **`fdimf32x`** **`fdimf64`** **`fdimf64x`** **`fdiv`** **`fdivl`** **`ffma`** **`ffmal`** **`floorf128`** **`floorf32`** **`floorf32x`** **`floorf64`** **`floorf64x`** **`fmaf128`** **`fmaf32`** **`fmaf32x`** **`fmaf64`** **`fmaf64x`** **`fmaxf128`** **`fmaxf32`** **`fmaxf32x`** **`fmaxf64`** **`fmaxf64x`** **`fmaximum`** **`fmaximum_mag`** **`fmaximum_mag_num`** **`fmaximum_mag_numf`** **`fmaximum_mag_numf128`** **`fmaximum_mag_numf32`** **`fmaximum_mag_numf32x`** **`fmaximum_mag_numf64`** **`fmaximum_mag_numf64x`** **`fmaximum_mag_numl`** **`fmaximum_magf`** **`fmaximum_magf128`** **`fmaximum_magf32`** **`fmaximum_magf32x`** **`fmaximum_magf64`** **`fmaximum_magf64x`** **`fmaximum_magl`** **`fmaximum_num`** **`fmaximum_numf`** **`fmaximum_numf128`** **`fmaximum_numf32`** **`fmaximum_numf32x`** **`fmaximum_numf64`** **`fmaximum_numf64x`** **`fmaximum_numl`** **`fmaximumf`** **`fmaximumf128`** **`fmaximumf32`** **`fmaximumf32x`** **`fmaximumf64`** **`fmaximumf64x`** **`fmaximuml`** **`fmaxmag`** **`fmaxmagf`** **`fmaxmagf128`** **`fmaxmagf32`** **`fmaxmagf32x`** **`fmaxmagf64`** **`fmaxmagf64x`** **`fmaxmagl`** **`fminf128`** **`fminf32`** **`fminf32x`** **`fminf64`** **`fminf64x`** **`fminimum`** **`fminimum_mag`** **`fminimum_mag_num`** **`fminimum_mag_numf`** **`fminimum_mag_numf128`** **`fminimum_mag_numf32`** **`fminimum_mag_numf32x`** **`fminimum_mag_numf64`** **`fminimum_mag_numf64x`** **`fminimum_mag_numl`** **`fminimum_magf`** **`fminimum_magf128`** **`fminimum_magf32`** **`fminimum_magf32x`** **`fminimum_magf64`** **`fminimum_magf64x`** **`fminimum_magl`** **`fminimum_num`** **`fminimum_numf`** **`fminimum_numf128`** **`fminimum_numf32`** **`fminimum_numf32x`** **`fminimum_numf64`** **`fminimum_numf64x`** **`fminimum_numl`** **`fminimumf`** **`fminimumf128`** **`fminimumf32`** **`fminimumf32x`** **`fminimumf64`** **`fminimumf64x`** **`fminimuml`** **`fminmag`** **`fminmagf`** **`fminmagf128`** **`fminmagf32`** **`fminmagf32x`** **`fminmagf64`** **`fminmagf64x`** **`fminmagl`** **`fmodf128`** **`fmodf32`** **`fmodf32x`** **`fmodf64`** **`fmodf64x`** **`fmul`** **`fmull`** **`frexpf128`** **`frexpf32`** **`frexpf32x`** **`frexpf64`** **`frexpf64x`** **`fromfp`** **`fromfpf`** **`fromfpf128`** **`fromfpf32`** **`fromfpf32x`** **`fromfpf64`** **`fromfpf64x`** **`fromfpl`** **`fromfpx`** **`fromfpxf`** **`fromfpxf128`** **`fromfpxf32`** **`fromfpxf32x`** **`fromfpxf64`** **`fromfpxf64x`** **`fromfpxl`** **`fsqrt`** **`fsqrtl`** **`fsub`** **`fsubl`** **`getpayload`** **`getpayloadf`** **`getpayloadf128`** **`getpayloadf32`** **`getpayloadf32x`** **`getpayloadf64`** **`getpayloadf64x`** **`getpayloadl`** **`hypotf128`** **`hypotf32`** **`hypotf32x`** **`hypotf64`** **`hypotf64x`** **`ilogbf128`** **`ilogbf32`** **`ilogbf32x`** **`ilogbf64`** **`ilogbf64x`** **`iscanonical`** **`iseqsig`** **`issignaling`** **`issubnormal`** **`iszero`** **`j0f128`** **`j0f32`** **`j0f32x`** **`j0f64`** **`j0f64x`** **`j1f128`** **`j1f32`** **`j1f32x`** **`j1f64`** **`j1f64x`** **`jnf128`** **`jnf32`** **`jnf32x`** **`jnf64`** **`jnf64x`** **`ldexpf128`** **`ldexpf32`** **`ldexpf32x`** **`ldexpf64`** **`ldexpf64x`** **`lgammaf128`** **`lgammaf128_r`** **`lgammaf32`** **`lgammaf32_r`** **`lgammaf32x`** **`lgammaf32x_r`** **`lgammaf64`** **`lgammaf64_r`** **`lgammaf64x`** **`lgammaf64x_r`** **`llogb`** **`llogbf`** **`llogbf128`** **`llogbf32`** **`llogbf32x`** **`llogbf64`** **`llogbf64x`** **`llogbl`** **`llrintf128`** **`llrintf32`** **`llrintf32x`** **`llrintf64`** **`llrintf64x`** **`llroundf128`** **`llroundf32`** **`llroundf32x`** **`llroundf64`** **`llroundf64x`** **`log10f128`** **`log10f32`** **`log10f32x`** **`log10f64`** **`log10f64x`** **`log1pf128`** **`log1pf32`** **`log1pf32x`** **`log1pf64`** **`log1pf64x`** **`log2f128`** **`log2f32`** **`log2f32x`** **`log2f64`** **`log2f64x`** **`logbf128`** **`logbf32`** **`logbf32x`** **`logbf64`** **`logbf64x`** **`logf128`** **`logf32`** **`logf32x`** **`logf64`** **`logf64x`** **`lrintf128`** **`lrintf32`** **`lrintf32x`** **`lrintf64`** **`lrintf64x`** **`lroundf128`** **`lroundf32`** **`lroundf32x`** **`lroundf64`** **`lroundf64x`** **`modff128`** **`modff32`** **`modff32x`** **`modff64`** **`modff64x`** **`nanf128`** **`nanf32`** **`nanf32x`** **`nanf64`** **`nanf64x`** **`nearbyintf128`** **`nearbyintf32`** **`nearbyintf32x`** **`nearbyintf64`** **`nearbyintf64x`** **`nextafterf128`** **`nextafterf32`** **`nextafterf32x`** **`nextafterf64`** **`nextafterf64x`** **`nextdown`** **`nextdownf`** **`nextdownf128`** **`nextdownf32`** **`nextdownf32x`** **`nextdownf64`** **`nextdownf64x`** **`nextdownl`** **`nextup`** **`nextupf`** **`nextupf128`** **`nextupf32`** **`nextupf32x`** **`nextupf64`** **`nextupf64x`** **`nextupl`** **`powf128`** **`powf32`** **`powf32x`** **`powf64`** **`powf64x`** **`remainderf128`** **`remainderf32`** **`remainderf32x`** **`remainderf64`** **`remainderf64x`** **`remquof128`** **`remquof32`** **`remquof32x`** **`remquof64`** **`remquof64x`** **`rintf128`** **`rintf32`** **`rintf32x`** **`rintf64`** **`rintf64x`** **`roundeven`** **`roundevenf`** **`roundevenf128`** **`roundevenf32`** **`roundevenf32x`** **`roundevenf64`** **`roundevenf64x`** **`roundevenl`** **`roundf128`** **`roundf32`** **`roundf32x`** **`roundf64`** **`roundf64x`** **`scalblnf128`** **`scalblnf32`** **`scalblnf32x`** **`scalblnf64`** **`scalblnf64x`** **`scalbnf128`** **`scalbnf32`** **`scalbnf32x`** **`scalbnf64`** **`scalbnf64x`** **`setpayload`** **`setpayloadf`** **`setpayloadf128`** **`setpayloadf32`** **`setpayloadf32x`** **`setpayloadf64`** **`setpayloadf64x`** **`setpayloadl`** **`setpayloadsig`** **`setpayloadsigf`** **`setpayloadsigf128`** **`setpayloadsigf32`** **`setpayloadsigf32x`** **`setpayloadsigf64`** **`setpayloadsigf64x`** **`setpayloadsigl`** **`sincos`** **`sincosf`** **`sincosf128`** **`sincosf32`** **`sincosf32x`** **`sincosf64`** **`sincosf64x`** **`sincosl`** **`sinf128`** **`sinf32`** **`sinf32x`** **`sinf64`** **`sinf64x`** **`sinhf128`** **`sinhf32`** **`sinhf32x`** **`sinhf64`** **`sinhf64x`** **`sqrtf128`** **`sqrtf32`** **`sqrtf32x`** **`sqrtf64`** **`sqrtf64x`** **`tanf128`** **`tanf32`** **`tanf32x`** **`tanf64`** **`tanf64x`** **`tanhf128`** **`tanhf32`** **`tanhf32x`** **`tanhf64`** **`tanhf64x`** **`tgammaf128`** **`tgammaf32`** **`tgammaf32x`** **`tgammaf64`** **`tgammaf64x`** **`totalorder`** **`totalorderf`** **`totalorderf128`** **`totalorderf32`** **`totalorderf32x`** **`totalorderf64`** **`totalorderf64x`** **`totalorderl`** **`totalordermag`** **`totalordermagf`** **`totalordermagf128`** **`totalordermagf32`** **`totalordermagf32x`** **`totalordermagf64`** **`totalordermagf64x`** **`totalordermagl`** **`truncf128`** **`truncf32`** **`truncf32x`** **`truncf64`** **`truncf64x`** **`ufromfp`** **`ufromfpf`** **`ufromfpf128`** **`ufromfpf32`** **`ufromfpf32x`** **`ufromfpf64`** **`ufromfpf64x`** **`ufromfpl`** **`ufromfpx`** **`ufromfpxf`** **`ufromfpxf128`** **`ufromfpxf32`** **`ufromfpxf32x`** **`ufromfpxf64`** **`ufromfpxf64x`** **`ufromfpxl`** **`y0f128`** **`y0f32`** **`y0f32x`** **`y0f64`** **`y0f64x`** **`y1f128`** **`y1f32`** **`y1f32x`** **`y1f64`** **`y1f64x`** **`ynf128`** **`ynf32`** **`ynf32x`** **`ynf64`** **`ynf64x`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__f32x4_t` `__f64x2_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__sv_bool_t` `__sv_f32_t` `__sv_f64_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`

### netinet/in.h

**x86_64 / aarch64** — glibc の `<netinet/in.h>` の公開名 298、不足 267、未記載 272

- 不足(iso): **`IN6_ARE_ADDR_EQUAL`** **`IN6_IS_ADDR_LINKLOCAL`** **`IN6_IS_ADDR_LOOPBACK`** **`IN6_IS_ADDR_MC_GLOBAL`** **`IN6_IS_ADDR_MC_LINKLOCAL`** **`IN6_IS_ADDR_MC_NODELOCAL`** **`IN6_IS_ADDR_MC_ORGLOCAL`** **`IN6_IS_ADDR_MC_SITELOCAL`** **`IN6_IS_ADDR_MULTICAST`** **`IN6_IS_ADDR_SITELOCAL`** **`IN6_IS_ADDR_UNSPECIFIED`** **`IN6_IS_ADDR_V4COMPAT`** **`IN6_IS_ADDR_V4MAPPED`** **`INADDR_ALLHOSTS_GROUP`** **`INADDR_ALLRTRS_GROUP`** **`INADDR_ALLSNOOPERS_GROUP`** **`INADDR_DUMMY`** **`INADDR_MAX_LOCAL_GROUP`** **`INADDR_UNSPEC_GROUP`** **`IN_BADCLASS`** **`IN_CLASSA`** **`IN_CLASSA_HOST`** **`IN_CLASSA_MAX`** **`IN_CLASSA_NET`** **`IN_CLASSA_NSHIFT`** **`IN_CLASSB`** **`IN_CLASSB_HOST`** **`IN_CLASSB_MAX`** **`IN_CLASSB_NET`** **`IN_CLASSB_NSHIFT`** **`IN_CLASSC`** **`IN_CLASSC_HOST`** **`IN_CLASSC_NET`** **`IN_CLASSC_NSHIFT`** **`IN_CLASSD`** **`IN_EXPERIMENTAL`** **`IN_LOOPBACKNET`** **`IN_MULTICAST`** **`IPPORT_BIFFUDP`** **`IPPORT_CMDSERVER`** **`IPPORT_DAYTIME`** **`IPPORT_DISCARD`** **`IPPORT_ECHO`** **`IPPORT_EFSSERVER`** **`IPPORT_EXECSERVER`** **`IPPORT_FINGER`** **`IPPORT_FTP`** **`IPPORT_LOGINSERVER`** **`IPPORT_MTP`** **`IPPORT_NAMESERVER`** **`IPPORT_NETSTAT`** **`IPPORT_RESERVED`** **`IPPORT_RJE`** **`IPPORT_ROUTESERVER`** **`IPPORT_SMTP`** **`IPPORT_SUPDUP`** **`IPPORT_SYSTAT`** **`IPPORT_TELNET`** **`IPPORT_TFTP`** **`IPPORT_TIMESERVER`** **`IPPORT_TTYLINK`** **`IPPORT_USERRESERVED`** **`IPPORT_WHOIS`** **`IPPORT_WHOSERVER`** **`IPPROTO_AH`** **`IPPROTO_BEETPH`** **`IPPROTO_COMP`** **`IPPROTO_DCCP`** **`IPPROTO_DSTOPTS`** **`IPPROTO_EGP`** **`IPPROTO_ENCAP`** **`IPPROTO_ESP`** **`IPPROTO_ETHERNET`** **`IPPROTO_FRAGMENT`** **`IPPROTO_GRE`** **`IPPROTO_HOPOPTS`** **`IPPROTO_ICMPV6`** **`IPPROTO_IDP`** **`IPPROTO_IGMP`** **`IPPROTO_IPIP`** **`IPPROTO_L2TP`** **`IPPROTO_MAX`** **`IPPROTO_MH`** **`IPPROTO_MPLS`** **`IPPROTO_MPTCP`** **`IPPROTO_MTP`** **`IPPROTO_NONE`** **`IPPROTO_PIM`** **`IPPROTO_PUP`** **`IPPROTO_ROUTING`** **`IPPROTO_RSVP`** **`IPPROTO_SCTP`** **`IPPROTO_TP`** **`IPPROTO_UDPLITE`** **`IPV6_2292DSTOPTS`** **`IPV6_2292HOPLIMIT`** **`IPV6_2292HOPOPTS`** **`IPV6_2292PKTINFO`** **`IPV6_2292PKTOPTIONS`** **`IPV6_2292RTHDR`** **`IPV6_ADDRFORM`** **`IPV6_ADDR_PREFERENCES`** **`IPV6_ADD_MEMBERSHIP`** **`IPV6_AUTHHDR`** **`IPV6_AUTOFLOWLABEL`** **`IPV6_CHECKSUM`** **`IPV6_DONTFRAG`** **`IPV6_DROP_MEMBERSHIP`** **`IPV6_DSTOPTS`** **`IPV6_FREEBIND`** **`IPV6_HDRINCL`** **`IPV6_HOPLIMIT`** **`IPV6_HOPOPTS`** **`IPV6_IPSEC_POLICY`** **`IPV6_JOIN_ANYCAST`** **`IPV6_JOIN_GROUP`** **`IPV6_LEAVE_ANYCAST`** **`IPV6_LEAVE_GROUP`** **`IPV6_MINHOPCOUNT`** **`IPV6_MTU`** **`IPV6_MTU_DISCOVER`** **`IPV6_MULTICAST_ALL`** **`IPV6_MULTICAST_HOPS`** **`IPV6_MULTICAST_IF`** **`IPV6_MULTICAST_LOOP`** **`IPV6_NEXTHOP`** **`IPV6_ORIGDSTADDR`** **`IPV6_PATHMTU`** **`IPV6_PKTINFO`** **`IPV6_PMTUDISC_DO`** **`IPV6_PMTUDISC_DONT`** **`IPV6_PMTUDISC_INTERFACE`** **`IPV6_PMTUDISC_OMIT`** **`IPV6_PMTUDISC_PROBE`** **`IPV6_PMTUDISC_WANT`** **`IPV6_RECVDSTOPTS`** **`IPV6_RECVERR`** **`IPV6_RECVERR_RFC4884`** **`IPV6_RECVFRAGSIZE`** **`IPV6_RECVHOPLIMIT`** **`IPV6_RECVHOPOPTS`** **`IPV6_RECVORIGDSTADDR`** **`IPV6_RECVPATHMTU`** **`IPV6_RECVPKTINFO`** **`IPV6_RECVRTHDR`** **`IPV6_RECVTCLASS`** **`IPV6_ROUTER_ALERT`** **`IPV6_ROUTER_ALERT_ISOLATE`** **`IPV6_RTHDR`** **`IPV6_RTHDRDSTOPTS`** **`IPV6_RTHDR_LOOSE`** **`IPV6_RTHDR_STRICT`** **`IPV6_RTHDR_TYPE_0`** **`IPV6_RXDSTOPTS`** **`IPV6_RXHOPOPTS`** **`IPV6_TCLASS`** **`IPV6_TRANSPARENT`** **`IPV6_UNICAST_HOPS`** **`IPV6_UNICAST_IF`** **`IPV6_V6ONLY`** **`IPV6_XFRM_POLICY`** **`IP_ADD_MEMBERSHIP`** **`IP_ADD_SOURCE_MEMBERSHIP`** **`IP_BIND_ADDRESS_NO_PORT`** **`IP_BLOCK_SOURCE`** **`IP_CHECKSUM`** **`IP_DEFAULT_MULTICAST_LOOP`** **`IP_DEFAULT_MULTICAST_TTL`** **`IP_DROP_MEMBERSHIP`** **`IP_DROP_SOURCE_MEMBERSHIP`** **`IP_FREEBIND`** **`IP_HDRINCL`** **`IP_IPSEC_POLICY`** **`IP_LOCAL_PORT_RANGE`** **`IP_MAX_MEMBERSHIPS`** **`IP_MINTTL`** **`IP_MSFILTER`** **`IP_MTU`** **`IP_MTU_DISCOVER`** **`IP_MULTICAST_ALL`** **`IP_MULTICAST_IF`** **`IP_MULTICAST_LOOP`** **`IP_MULTICAST_TTL`** **`IP_NODEFRAG`** **`IP_OPTIONS`** **`IP_ORIGDSTADDR`** **`IP_PASSSEC`** **`IP_PKTINFO`** **`IP_PKTOPTIONS`** **`IP_PMTUDISC`** **`IP_PMTUDISC_DO`** **`IP_PMTUDISC_DONT`** **`IP_PMTUDISC_INTERFACE`** **`IP_PMTUDISC_OMIT`** **`IP_PMTUDISC_PROBE`** **`IP_PMTUDISC_WANT`** **`IP_PROTOCOL`** **`IP_RECVERR`** **`IP_RECVERR_RFC4884`** **`IP_RECVFRAGSIZE`** **`IP_RECVOPTS`** **`IP_RECVORIGDSTADDR`** **`IP_RECVRETOPTS`** **`IP_RECVTOS`** **`IP_RECVTTL`** **`IP_RETOPTS`** **`IP_ROUTER_ALERT`** **`IP_TOS`** **`IP_TRANSPARENT`** **`IP_TTL`** **`IP_UNBLOCK_SOURCE`** **`IP_UNICAST_IF`** **`IP_XFRM_POLICY`** **`SCM_SRCRT`** **`SOL_ICMPV6`** **`SOL_IP`** **`SOL_IPV6`** **`struct ipv6_mreq`**
- 不足(default): **`GROUP_FILTER_SIZE`** **`IP_MSFILTER_SIZE`** **`MCAST_BLOCK_SOURCE`** **`MCAST_EXCLUDE`** **`MCAST_INCLUDE`** **`MCAST_JOIN_GROUP`** **`MCAST_JOIN_SOURCE_GROUP`** **`MCAST_LEAVE_GROUP`** **`MCAST_LEAVE_SOURCE_GROUP`** **`MCAST_MSFILTER`** **`MCAST_UNBLOCK_SOURCE`** **`bindresvport`** **`bindresvport6`** **`s6_addr16`** **`s6_addr32`** **`struct group_filter`** **`struct group_req`** **`struct group_source_req`** **`struct in_pktinfo`** **`struct ip_mreq`** **`struct ip_mreq_source`** **`struct ip_mreqn`** **`struct ip_msfilter`** **`struct ip_opts`**
- 不足(gnu): **`getipv4sourcefilter`** **`getsourcefilter`** **`inet6_opt_append`** **`inet6_opt_find`** **`inet6_opt_finish`** **`inet6_opt_get_val`** **`inet6_opt_init`** **`inet6_opt_next`** **`inet6_opt_set_val`** **`inet6_option_alloc`** **`inet6_option_append`** **`inet6_option_find`** **`inet6_option_init`** **`inet6_option_next`** **`inet6_option_space`** **`inet6_rth_add`** **`inet6_rth_getaddr`** **`inet6_rth_init`** **`inet6_rth_reverse`** **`inet6_rth_segments`** **`inet6_rth_space`** **`setipv4sourcefilter`** **`setsourcefilter`** **`struct in6_pktinfo`** **`struct ip6_mtuinfo`**
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h` `sys/socket.h` `sys/types.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`

### netinet/tcp.h

**x86_64 / aarch64** — glibc の `<netinet/tcp.h>` の公開名 111、不足 90、未記載 96

- 不足(iso): **`TCP_CC_INFO`** **`TCP_CM_INQ`** **`TCP_CONGESTION`** **`TCP_COOKIE_TRANSACTIONS`** **`TCP_DEFER_ACCEPT`** **`TCP_FASTOPEN_CONNECT`** **`TCP_FASTOPEN_KEY`** **`TCP_FASTOPEN_NO_COOKIE`** **`TCP_INQ`** **`TCP_LINGER2`** **`TCP_MD5SIG`** **`TCP_MD5SIG_EXT`** **`TCP_NOTSENT_LOWAT`** **`TCP_QUEUE_SEQ`** **`TCP_REPAIR`** **`TCP_REPAIR_OFF`** **`TCP_REPAIR_OFF_NO_WP`** **`TCP_REPAIR_ON`** **`TCP_REPAIR_OPTIONS`** **`TCP_REPAIR_QUEUE`** **`TCP_REPAIR_WINDOW`** **`TCP_SAVED_SYN`** **`TCP_SAVE_SYN`** **`TCP_SYNCNT`** **`TCP_THIN_DUPACK`** **`TCP_THIN_LINEAR_TIMEOUTS`** **`TCP_TIMESTAMP`** **`TCP_TX_DELAY`** **`TCP_ULP`** **`TCP_WINDOW_CLAMP`** **`TCP_ZEROCOPY_RECEIVE`**
- 不足(default): **`SOL_TCP`** **`TCPI_OPT_ECN`** **`TCPI_OPT_ECN_SEEN`** **`TCPI_OPT_SACK`** **`TCPI_OPT_SYN_DATA`** **`TCPI_OPT_TIMESTAMPS`** **`TCPI_OPT_WSCALE`** **`TCPOLEN_MAXSEG`** **`TCPOLEN_SACK_PERMITTED`** **`TCPOLEN_TIMESTAMP`** **`TCPOLEN_TSTAMP_APPA`** **`TCPOLEN_WINDOW`** **`TCPOPT_EOL`** **`TCPOPT_MAXSEG`** **`TCPOPT_NOP`** **`TCPOPT_SACK`** **`TCPOPT_SACK_PERMITTED`** **`TCPOPT_TIMESTAMP`** **`TCPOPT_TSTAMP_HDR`** **`TCPOPT_WINDOW`** **`TCP_CA_CWR`** **`TCP_CA_Disorder`** **`TCP_CA_Loss`** **`TCP_CA_Open`** **`TCP_CA_Recovery`** **`TCP_COOKIE_IN_ALWAYS`** **`TCP_COOKIE_MAX`** **`TCP_COOKIE_MIN`** **`TCP_COOKIE_OUT_NEVER`** **`TCP_COOKIE_PAIR_SIZE`** **`TCP_MAXWIN`** **`TCP_MAX_WINSHIFT`** **`TCP_MD5SIG_FLAG_IFINDEX`** **`TCP_MD5SIG_FLAG_PREFIX`** **`TCP_MD5SIG_MAXKEYLEN`** **`TCP_MSS`** **`TCP_MSS_DEFAULT`** **`TCP_MSS_DESIRED`** **`TCP_NO_QUEUE`** **`TCP_QUEUES_NR`** **`TCP_RECV_QUEUE`** **`TCP_SEND_QUEUE`** **`TCP_S_DATA_IN`** **`TCP_S_DATA_OUT`** **`TH_ACK`** **`TH_FIN`** **`TH_PUSH`** **`TH_RST`** **`TH_SYN`** **`TH_URG`** **`enum tcp_ca_state`** **`struct tcp_cookie_transactions`** **`struct tcp_info`** **`struct tcp_md5sig`** **`struct tcp_repair_opt`** **`struct tcp_repair_window`** **`struct tcp_zerocopy_receive`** **`struct tcphdr`** **`tcp_seq`**
- 取り込み不足: `endian.h` `stddef.h` `stdint.h` `sys/select.h` `sys/socket.h` `sys/types.h`

### poll.h

**x86_64 / aarch64** — glibc の `<poll.h>` の公開名 0、不足 0、未記載 1

- 取り込み不足: `sys/poll.h`

### pthread.h

**x86_64 / aarch64** — glibc の `<pthread.h>` の公開名 187、不足 136、未記載 139

- 不足(iso): **`PTHREAD_CANCELED`** **`PTHREAD_CANCEL_ASYNCHRONOUS`** **`PTHREAD_CANCEL_DEFERRED`** **`PTHREAD_CANCEL_DISABLE`** **`PTHREAD_CANCEL_ENABLE`** **`PTHREAD_EXPLICIT_SCHED`** **`PTHREAD_INHERIT_SCHED`** **`PTHREAD_MUTEX_ADAPTIVE_NP`** **`PTHREAD_MUTEX_ERRORCHECK_NP`** **`PTHREAD_MUTEX_RECURSIVE_NP`** **`PTHREAD_MUTEX_TIMED_NP`** **`PTHREAD_SCOPE_PROCESS`** **`PTHREAD_SCOPE_SYSTEM`** **`pthread_attr_getdetachstate`** **`pthread_attr_getguardsize`** **`pthread_attr_getinheritsched`** **`pthread_attr_getschedparam`** **`pthread_attr_getschedpolicy`** **`pthread_attr_getscope`** **`pthread_attr_getstackaddr`** **`pthread_attr_getstacksize`** **`pthread_attr_setdetachstate`** **`pthread_attr_setguardsize`** **`pthread_attr_setinheritsched`** **`pthread_attr_setschedparam`** **`pthread_attr_setschedpolicy`** **`pthread_attr_setscope`** **`pthread_attr_setstackaddr`** **`pthread_attr_setstacksize`** **`pthread_cancel`** **`pthread_cleanup_pop`** **`pthread_cleanup_push`** **`pthread_cond_timedwait`** **`pthread_condattr_destroy`** **`pthread_condattr_getpshared`** **`pthread_condattr_init`** **`pthread_condattr_setpshared`** **`pthread_getschedparam`** **`pthread_mutex_getprioceiling`** **`pthread_mutex_setprioceiling`** **`pthread_mutexattr_getprioceiling`** **`pthread_mutexattr_getprotocol`** **`pthread_mutexattr_getpshared`** **`pthread_mutexattr_setprioceiling`** **`pthread_mutexattr_setprotocol`** **`pthread_mutexattr_setpshared`** **`pthread_setcancelstate`** **`pthread_setcanceltype`** **`pthread_setschedparam`** **`pthread_setschedprio`** **`pthread_testcancel`** **`struct _pthread_cleanup_buffer`**
- 不足(posix): **`PTHREAD_BARRIER_SERIAL_THREAD`** **`PTHREAD_MUTEX_ROBUST`** **`PTHREAD_MUTEX_ROBUST_NP`** **`PTHREAD_MUTEX_STALLED`** **`PTHREAD_MUTEX_STALLED_NP`** **`PTHREAD_PRIO_INHERIT`** **`PTHREAD_PRIO_NONE`** **`PTHREAD_PRIO_PROTECT`** **`PTHREAD_RWLOCK_DEFAULT_NP`** **`PTHREAD_RWLOCK_PREFER_READER_NP`** **`PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`** **`PTHREAD_RWLOCK_PREFER_WRITER_NP`** **`pthread_attr_getstack`** **`pthread_attr_setstack`** **`pthread_barrier_destroy`** **`pthread_barrier_init`** **`pthread_barrier_t`** **`pthread_barrier_wait`** **`pthread_barrierattr_destroy`** **`pthread_barrierattr_getpshared`** **`pthread_barrierattr_init`** **`pthread_barrierattr_setpshared`** **`pthread_barrierattr_t`** **`pthread_condattr_getclock`** **`pthread_condattr_setclock`** **`pthread_getcpuclockid`** **`pthread_mutex_consistent`** **`pthread_mutex_timedlock`** **`pthread_mutexattr_getrobust`** **`pthread_mutexattr_gettype`** **`pthread_mutexattr_setrobust`** **`pthread_rwlock_destroy`** **`pthread_rwlock_init`** **`pthread_rwlock_rdlock`** **`pthread_rwlock_timedrdlock`** **`pthread_rwlock_timedwrlock`** **`pthread_rwlock_tryrdlock`** **`pthread_rwlock_trywrlock`** **`pthread_rwlock_unlock`** **`pthread_rwlock_wrlock`** **`pthread_rwlockattr_destroy`** **`pthread_rwlockattr_getkind_np`** **`pthread_rwlockattr_getpshared`** **`pthread_rwlockattr_init`** **`pthread_rwlockattr_setkind_np`** **`pthread_rwlockattr_setpshared`** **`pthread_spin_destroy`** **`pthread_spin_init`** **`pthread_spin_lock`** **`pthread_spin_trylock`** **`pthread_spin_unlock`**
- 不足(xopen): **`pthread_getconcurrency`** **`pthread_setconcurrency`**
- 不足(default): **`PTHREAD_STACK_MIN`**
- 不足(gnu): **`PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP`** **`PTHREAD_ATTR_NO_SIGMASK_NP`** **`PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP`** **`PTHREAD_MUTEX_FAST_NP`** **`PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP`** **`PTHREAD_RWLOCK_WRITER_NONRECURSIVE_INITIALIZER_NP`** **`pthread_attr_getaffinity_np`** **`pthread_attr_getsigmask_np`** **`pthread_attr_setaffinity_np`** **`pthread_attr_setsigmask_np`** **`pthread_cleanup_pop_restore_np`** **`pthread_cleanup_push_defer_np`** **`pthread_clockjoin_np`** **`pthread_cond_clockwait`** **`pthread_getaffinity_np`** **`pthread_getattr_default_np`** **`pthread_getattr_np`** **`pthread_getname_np`** **`pthread_mutex_clocklock`** **`pthread_mutex_consistent_np`** **`pthread_mutexattr_getrobust_np`** **`pthread_mutexattr_setrobust_np`** **`pthread_rwlock_clockrdlock`** **`pthread_rwlock_clockwrlock`** **`pthread_setaffinity_np`** **`pthread_setattr_default_np`** **`pthread_setname_np`** **`pthread_timedjoin_np`** **`pthread_tryjoin_np`** **`pthread_yield`**
- 取り込み不足: `sched.h` `stddef.h` `time.h`
- 予約名の型: `__atomic_wide_counter` `__jmp_buf` `__once_flag` `__pthread_list_t` `__pthread_slist_t` `__pthread_unwind_buf_t` `__sigset_t` `__thrd_t` `__tss_t` `struct __cancel_jmp_buf_tag` `struct __jmp_buf_tag` `struct __pthread_cleanup_frame` `struct __pthread_cond_s` `struct __pthread_internal_list` `struct __pthread_internal_slist` `struct __pthread_mutex_s` `struct __pthread_rwlock_arch_t`
- ガード `____sigset_t_defined` → `__sigset_t`: absent
- ガード `__have_pthread_attr_t` → `union pthread_attr_t` `pthread_attr_t`: honoured(<pthread.h>, <aio.h>: ok; <aio.h>, <pthread.h>: ok; <pthread.h>, <fts.h>: ok; <fts.h>, <pthread.h>: ok; <pthread.h>, <ftw.h>: ok; <ftw.h>, <pthread.h>: ok)
- ガード `__jmp_buf_tag_defined` → `struct __jmp_buf_tag`: absent
- 余剰: `pthread_kill`

### pwd.h

**x86_64 / aarch64** — glibc の `<pwd.h>` の公開名 17、不足 7、未記載 8

- 不足(default): **`FILE`** **`NSS_BUFLEN_PASSWD`** **`fgetpwent`** **`fgetpwent_r`** **`getpwent_r`** **`putpwent`**
- 不足(gnu): **`getpw`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__FILE_defined` → `FILE`: absent
- ガード `__gid_t_defined` → `gid_t`: self
- ガード `__uid_t_defined` → `uid_t`: self

### regex.h

**x86_64 / aarch64** — glibc の `<regex.h>` の公開名 92、不足 76、未記載 79

- 不足(iso): **`REG_BADBR`** **`REG_BADPAT`** **`REG_BADRPT`** **`REG_EBRACE`** **`REG_EBRACK`** **`REG_ECOLLATE`** **`REG_ECTYPE`** **`REG_EEND`** **`REG_EESCAPE`** **`REG_EPAREN`** **`REG_ERANGE`** **`REG_ERPAREN`** **`REG_ESIZE`** **`REG_ESPACE`** **`REG_ESUBREG`** **`REG_NOERROR`** **`REG_NOMATCH`** **`active_reg_t`** **`re_syntax_options`** **`reg_errcode_t`** **`s_reg_t`**
- 不足(posix): **`REG_ENOSYS`**
- 不足(gnu): **`REGS_FIXED`** **`REGS_REALLOCATE`** **`REGS_UNALLOCATED`** **`RE_BACKSLASH_ESCAPE_IN_LISTS`** **`RE_BK_PLUS_QM`** **`RE_CARET_ANCHORS_HERE`** **`RE_CHAR_CLASSES`** **`RE_CONTEXT_INDEP_ANCHORS`** **`RE_CONTEXT_INDEP_OPS`** **`RE_CONTEXT_INVALID_DUP`** **`RE_CONTEXT_INVALID_OPS`** **`RE_DEBUG`** **`RE_DOT_NEWLINE`** **`RE_DOT_NOT_NULL`** **`RE_DUP_MAX`** **`RE_HAT_LISTS_NOT_NEWLINE`** **`RE_ICASE`** **`RE_INTERVALS`** **`RE_INVALID_INTERVAL_ORD`** **`RE_LIMITED_OPS`** **`RE_NEWLINE_ALT`** **`RE_NO_BK_BRACES`** **`RE_NO_BK_PARENS`** **`RE_NO_BK_REFS`** **`RE_NO_BK_VBAR`** **`RE_NO_EMPTY_RANGES`** **`RE_NO_GNU_OPS`** **`RE_NO_POSIX_BACKTRACKING`** **`RE_NO_SUB`** **`RE_NREGS`** **`RE_SYNTAX_AWK`** **`RE_SYNTAX_ED`** **`RE_SYNTAX_EGREP`** **`RE_SYNTAX_EMACS`** **`RE_SYNTAX_GNU_AWK`** **`RE_SYNTAX_GREP`** **`RE_SYNTAX_POSIX_AWK`** **`RE_SYNTAX_POSIX_BASIC`** **`RE_SYNTAX_POSIX_EGREP`** **`RE_SYNTAX_POSIX_EXTENDED`** **`RE_SYNTAX_POSIX_MINIMAL_BASIC`** **`RE_SYNTAX_POSIX_MINIMAL_EXTENDED`** **`RE_SYNTAX_SED`** **`RE_TRANSLATE_TYPE`** **`RE_UNMATCHED_RIGHT_PAREN_ORD`** **`re_compile_fastmap`** **`re_compile_pattern`** **`re_match`** **`re_match_2`** **`re_search`** **`re_search_2`** **`re_set_registers`** **`re_set_syntax`** **`struct re_registers`**
- 取り込み不足: `endian.h` `sys/select.h` `sys/types.h`
- 予約名の型: `__re_long_size_t` `__re_size_t`

### sched.h

**x86_64 / aarch64** — glibc の `<sched.h>` の公開名 77、不足 52、未記載 0

- 不足(iso): `sched_priority`
- 不足(gnu): `CLONE_CHILD_CLEARTID` `CLONE_CHILD_SETTID` `CLONE_DETACHED` `CLONE_FILES` `CLONE_FS` `CLONE_IO` `CLONE_NEWCGROUP` `CLONE_NEWIPC` `CLONE_NEWNET` `CLONE_NEWNS` `CLONE_NEWPID` `CLONE_NEWTIME` `CLONE_NEWUSER` `CLONE_NEWUTS` `CLONE_PARENT` `CLONE_PARENT_SETTID` `CLONE_PIDFD` `CLONE_PTRACE` `CLONE_SETTLS` `CLONE_SIGHAND` `CLONE_SYSVSEM` `CLONE_THREAD` `CLONE_UNTRACED` `CLONE_VFORK` `CLONE_VM` `CPU_ALLOC` `CPU_ALLOC_SIZE` `CPU_AND` `CPU_AND_S` `CPU_CLR` `CPU_CLR_S` `CPU_COUNT` `CPU_COUNT_S` `CPU_EQUAL` `CPU_EQUAL_S` `CPU_FREE` `CPU_ISSET` `CPU_ISSET_S` `CPU_OR` `CPU_OR_S` `CPU_SET` `CPU_SET_S` `CPU_XOR` `CPU_XOR_S` `CPU_ZERO` `CPU_ZERO_S` `CSIGNAL` `clone` `getcpu` `setns` `unshare`
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__cpu_mask` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__time_t_defined` → `time_t`: unguarded(<sched.h>, <aio.h>: ok; <aio.h>, <sched.h>: ok; <sched.h>, <fts.h>: ok; <fts.h>, <sched.h>: ok; <sched.h>, <ftw.h>: ok; <ftw.h>, <sched.h>: ok)

### setjmp.h

**x86_64 / aarch64** — glibc の `<setjmp.h>` の公開名 8、不足 0、未記載 0

- 予約名の型: `__jmp_buf` `__sigset_t` `struct __jmp_buf_tag`
- ガード `____sigset_t_defined` → `__sigset_t`: absent
- ガード `__jmp_buf_tag_defined` → `struct __jmp_buf_tag`: absent

### signal.h

**x86_64** — glibc の `<signal.h>` の公開名 232、不足 152、未記載 155

- 不足(posix): **`BUS_ADRALN`** **`BUS_ADRERR`** **`BUS_MCEERR_AO`** **`BUS_MCEERR_AR`** **`BUS_OBJERR`** **`CLD_CONTINUED`** **`CLD_DUMPED`** **`CLD_EXITED`** **`CLD_KILLED`** **`CLD_STOPPED`** **`CLD_TRAPPED`** **`FPE_CONDTRAP`** **`FPE_FLTDIV`** **`FPE_FLTINV`** **`FPE_FLTOVF`** **`FPE_FLTRES`** **`FPE_FLTSUB`** **`FPE_FLTUND`** **`FPE_FLTUNK`** **`FPE_INTDIV`** **`FPE_INTOVF`** **`ILL_BADIADDR`** **`ILL_BADSTK`** **`ILL_COPROC`** **`ILL_ILLADR`** **`ILL_ILLOPC`** **`ILL_ILLOPN`** **`ILL_ILLTRP`** **`ILL_PRVOPC`** **`ILL_PRVREG`** **`POLL_ERR`** **`POLL_HUP`** **`POLL_IN`** **`POLL_MSG`** **`POLL_OUT`** **`POLL_PRI`** **`SEGV_ACCADI`** **`SEGV_ACCERR`** **`SEGV_ADIDERR`** **`SEGV_ADIPERR`** **`SEGV_BNDERR`** **`SEGV_CPERR`** **`SEGV_MAPERR`** **`SEGV_MTEAERR`** **`SEGV_MTESERR`** **`SEGV_PKUERR`** **`SIGEV_NONE`** **`SIGEV_SIGNAL`** **`SIGEV_THREAD`** **`SIGEV_THREAD_ID`** **`SI_ASYNCIO`** **`SI_ASYNCNL`** **`SI_DETHREAD`** **`SI_KERNEL`** **`SI_MESGQ`** **`SI_QUEUE`** **`SI_SIGIO`** **`SI_TIMER`** **`SI_TKILL`** **`SI_USER`** **`psiginfo`** **`psignal`** **`pthread_attr_t`** **`pthread_barrier_t`** **`pthread_barrierattr_t`** **`pthread_cond_t`** **`pthread_condattr_t`** **`pthread_key_t`** **`pthread_kill`** **`pthread_mutex_t`** **`pthread_mutexattr_t`** **`pthread_once_t`** **`pthread_rwlock_t`** **`pthread_rwlockattr_t`** **`pthread_sigmask`** **`pthread_spinlock_t`** **`pthread_t`** **`si_addr_lsb`** **`si_arch`** **`si_call_addr`** **`si_int`** **`si_lower`** **`si_overrun`** **`si_pkey`** **`si_ptr`** **`si_stime`** **`si_syscall`** **`si_timerid`** **`si_upper`** **`si_utime`** **`sigev_notify_attributes`** **`sigev_notify_function`** **`sigevent_t`** **`sigqueue`** **`sigtimedwait`** **`sigwait`** **`sigwaitinfo`** **`stack_t`** **`struct sigevent`** **`struct timespec`** **`time_t`** **`union pthread_attr_t`**
- 不足(xopen): **`MINSIGSTKSZ`** **`SIGSTKSZ`** **`SIG_HOLD`** **`SS_DISABLE`** **`SS_ONSTACK`** **`TRAP_BRANCH`** **`TRAP_BRKPT`** **`TRAP_HWBKPT`** **`TRAP_TRACE`** **`TRAP_UNK`** **`killpg`** **`sigaltstack`** **`sighold`** **`sigignore`** **`siginterrupt`** **`sigpause`** **`sigrelse`** **`sigset`**
- 不足(default): **`FP_XSTATE_MAGIC1`** **`FP_XSTATE_MAGIC2`** **`FP_XSTATE_MAGIC2_SIZE`** **`SA_INTERRUPT`** **`SA_STACK`** **`gsignal`** **`sig_t`** **`sigblock`** **`siggetmask`** **`sigmask`** **`sigreturn`** **`sigsetmask`** **`sigstack`** **`sigval_t`** **`ssignal`** **`struct _fpreg`** **`struct _fpstate`** **`struct _fpx_sw_bytes`** **`struct _fpxreg`** **`struct _xmmreg`** **`struct _xsave_hdr`** **`struct _xstate`** **`struct _ymmh_state`** **`struct sigcontext`** **`struct sigstack`**
- 不足(gnu): **`pthread_sigqueue`** **`sigandset`** **`sighandler_t`** **`sigisemptyset`** **`sigorset`** **`sysv_signal`** **`tgkill`**
- 取り込み不足: `stddef.h` `sys/ucontext.h` `unistd.h`
- 予約名の型: `__atomic_wide_counter` `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__once_flag` `__pthread_list_t` `__pthread_slist_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__thrd_t` `__time_t` `__timer_t` `__tss_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `struct __pthread_cond_s` `struct __pthread_internal_list` `struct __pthread_internal_slist` `struct __pthread_mutex_s` `struct __pthread_rwlock_arch_t`
- ガード `____sigset_t_defined` → `__sigset_t`: unguarded(<signal.h>, <aio.h>: ok; <aio.h>, <signal.h>: ok; <signal.h>, <fts.h>: ok; <fts.h>, <signal.h>: ok; <signal.h>, <ftw.h>: ok; <ftw.h>, <signal.h>: ok)
- ガード `____sigval_t_defined` → `__sigval_t`: honoured(<signal.h>, <aio.h>: ok; <aio.h>, <signal.h>: ok; <signal.h>, <wait.h>: ok; <wait.h>, <signal.h>: ok; <signal.h>, <netdb.h>: ok; <netdb.h>, <signal.h>: ok)
- ガード `__have_pthread_attr_t` → `pthread_attr_t`: absent
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__sig_atomic_t_defined` → `sig_atomic_t`: unguarded(<signal.h>, <wait.h>: ok; <wait.h>, <signal.h>: ok; <signal.h>, <resolv.h>: ok; <resolv.h>, <signal.h>: ok; <signal.h>, <sys/signal.h>: ok; <sys/signal.h>, <signal.h>: ok)
- ガード `__sigevent_t_defined` → `sigevent_t`: absent
- ガード `__siginfo_t_defined` → `siginfo_t`: honoured(<signal.h>, <wait.h>: ok; <wait.h>, <signal.h>: ok; <signal.h>, <resolv.h>: ok; <resolv.h>, <signal.h>: ok; <signal.h>, <sys/pidfd.h>: ok; <sys/pidfd.h>, <signal.h>: ok)
- ガード `__sigset_t_defined` → `sigset_t`: honoured(<signal.h>, <aio.h>: ok; <aio.h>, <signal.h>: ok; <signal.h>, <fts.h>: ok; <fts.h>, <signal.h>: ok; <signal.h>, <ftw.h>: ok; <ftw.h>, <signal.h>: ok)
- ガード `__sigstack_defined` → `struct sigstack`: absent
- ガード `__sigval_t_defined` → `sigval_t`: absent
- ガード `__stack_t_defined` → `stack_t`: absent
- ガード `__time_t_defined` → `time_t`: absent
- ガード `__uid_t_defined` → `uid_t`: self

**aarch64** — glibc の `<signal.h>` の公開名 257、不足 177、未記載 186

- 不足(posix): **`BUS_ADRALN`** **`BUS_ADRERR`** **`BUS_MCEERR_AO`** **`BUS_MCEERR_AR`** **`BUS_OBJERR`** **`CLD_CONTINUED`** **`CLD_DUMPED`** **`CLD_EXITED`** **`CLD_KILLED`** **`CLD_STOPPED`** **`CLD_TRAPPED`** **`FPE_CONDTRAP`** **`FPE_FLTDIV`** **`FPE_FLTINV`** **`FPE_FLTOVF`** **`FPE_FLTRES`** **`FPE_FLTSUB`** **`FPE_FLTUND`** **`FPE_FLTUNK`** **`FPE_INTDIV`** **`FPE_INTOVF`** **`ILL_BADIADDR`** **`ILL_BADSTK`** **`ILL_COPROC`** **`ILL_ILLADR`** **`ILL_ILLOPC`** **`ILL_ILLOPN`** **`ILL_ILLTRP`** **`ILL_PRVOPC`** **`ILL_PRVREG`** **`POLL_ERR`** **`POLL_HUP`** **`POLL_IN`** **`POLL_MSG`** **`POLL_OUT`** **`POLL_PRI`** **`SEGV_ACCADI`** **`SEGV_ACCERR`** **`SEGV_ADIDERR`** **`SEGV_ADIPERR`** **`SEGV_BNDERR`** **`SEGV_CPERR`** **`SEGV_MAPERR`** **`SEGV_MTEAERR`** **`SEGV_MTESERR`** **`SEGV_PKUERR`** **`SIGEV_NONE`** **`SIGEV_SIGNAL`** **`SIGEV_THREAD`** **`SIGEV_THREAD_ID`** **`SI_ASYNCIO`** **`SI_ASYNCNL`** **`SI_DETHREAD`** **`SI_KERNEL`** **`SI_MESGQ`** **`SI_QUEUE`** **`SI_SIGIO`** **`SI_TIMER`** **`SI_TKILL`** **`SI_USER`** **`psiginfo`** **`psignal`** **`pthread_attr_t`** **`pthread_kill`** **`pthread_sigmask`** **`si_addr_lsb`** **`si_arch`** **`si_call_addr`** **`si_int`** **`si_lower`** **`si_overrun`** **`si_pkey`** **`si_ptr`** **`si_stime`** **`si_syscall`** **`si_timerid`** **`si_upper`** **`si_utime`** **`sigev_notify_attributes`** **`sigev_notify_function`** **`sigevent_t`** **`sigqueue`** **`sigtimedwait`** **`sigwait`** **`sigwaitinfo`** **`stack_t`** **`struct sigevent`** **`struct timespec`** **`time_t`**
- 不足(xopen): **`MINSIGSTKSZ`** **`SIGSTKSZ`** **`SIG_HOLD`** **`SS_DISABLE`** **`SS_ONSTACK`** **`TRAP_BRANCH`** **`TRAP_BRKPT`** **`TRAP_HWBKPT`** **`TRAP_TRACE`** **`TRAP_UNK`** **`killpg`** **`sigaltstack`** **`sighold`** **`sigignore`** **`siginterrupt`** **`sigpause`** **`sigrelse`** **`sigset`**
- 不足(default): **`ESR_MAGIC`** **`EXTRA_MAGIC`** **`FPSIMD_MAGIC`** **`SA_INTERRUPT`** **`SA_STACK`** **`SVE_MAGIC`** **`SVE_NUM_PREGS`** **`SVE_NUM_ZREGS`** **`SVE_SIG_CONTEXT_SIZE`** **`SVE_SIG_FFR_OFFSET`** **`SVE_SIG_FFR_SIZE`** **`SVE_SIG_FLAG_SM`** **`SVE_SIG_PREGS_OFFSET`** **`SVE_SIG_PREGS_SIZE`** **`SVE_SIG_PREG_OFFSET`** **`SVE_SIG_PREG_SIZE`** **`SVE_SIG_REGS_OFFSET`** **`SVE_SIG_REGS_SIZE`** **`SVE_SIG_ZREGS_OFFSET`** **`SVE_SIG_ZREGS_SIZE`** **`SVE_SIG_ZREG_OFFSET`** **`SVE_SIG_ZREG_SIZE`** **`SVE_VL_MAX`** **`SVE_VL_MIN`** **`SVE_VQ_BYTES`** **`SVE_VQ_MAX`** **`SVE_VQ_MIN`** **`TPIDR2_MAGIC`** **`ZA_MAGIC`** **`ZA_SIG_CONTEXT_SIZE`** **`ZA_SIG_REGS_OFFSET`** **`ZA_SIG_REGS_SIZE`** **`ZA_SIG_ZAV_OFFSET`** **`ZT_MAGIC`** **`ZT_SIG_CONTEXT_SIZE`** **`ZT_SIG_REGS_OFFSET`** **`ZT_SIG_REGS_SIZE`** **`ZT_SIG_REG_BYTES`** **`ZT_SIG_REG_SIZE`** **`gsignal`** **`sig_t`** **`sigblock`** **`sigcontext_struct`** **`siggetmask`** **`sigmask`** **`sigreturn`** **`sigsetmask`** **`sigstack`** **`sigval_t`** **`ssignal`** **`struct _aarch64_ctx`** **`struct esr_context`** **`struct extra_context`** **`struct fpsimd_context`** **`struct sigcontext`** **`struct sigstack`** **`struct sve_context`** **`struct tpidr2_context`** **`struct za_context`** **`struct zt_context`** **`sve_vl_from_vq`** **`sve_vl_valid`** **`sve_vq_from_vl`**
- 不足(gnu): **`pthread_sigqueue`** **`sigandset`** **`sighandler_t`** **`sigisemptyset`** **`sigorset`** **`sysv_signal`** **`tgkill`**
- 取り込み不足: `endian.h` `stddef.h` `sys/procfs.h` `sys/select.h` `sys/time.h` `sys/types.h` `sys/ucontext.h` `sys/user.h` `unistd.h`
- 予約名の型: `__be16` `__be32` `__be64` `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__kernel_caddr_t` `__kernel_clock_t` `__kernel_clockid_t` `__kernel_daddr_t` `__kernel_fd_set` `__kernel_fsid_t` `__kernel_gid16_t` `__kernel_gid32_t` `__kernel_gid_t` `__kernel_ino_t` `__kernel_ipc_pid_t` `__kernel_key_t` `__kernel_loff_t` `__kernel_long_t` `__kernel_mode_t` `__kernel_mqd_t` `__kernel_off_t` `__kernel_old_dev_t` `__kernel_old_gid_t` `__kernel_old_time_t` `__kernel_old_uid_t` `__kernel_pid_t` `__kernel_ptrdiff_t` `__kernel_sighandler_t` `__kernel_size_t` `__kernel_ssize_t` `__kernel_suseconds_t` `__kernel_time64_t` `__kernel_time_t` `__kernel_timer_t` `__kernel_uid16_t` `__kernel_uid32_t` `__kernel_uid_t` `__kernel_ulong_t` `__key_t` `__le16` `__le32` `__le64` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__poll_t` `__quad_t` `__rlim64_t` `__rlim_t` `__s128` `__s16` `__s32` `__s64` `__s8` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__sum16` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u128` `__u16` `__u32` `__u64` `__u8` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `__wsum`
- ガード `____sigset_t_defined` → `__sigset_t`: unguarded
- ガード `____sigval_t_defined` → `__sigval_t`: honoured
- ガード `__have_pthread_attr_t` → `pthread_attr_t`: absent
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__sig_atomic_t_defined` → `sig_atomic_t`: unguarded
- ガード `__sigevent_t_defined` → `sigevent_t`: absent
- ガード `__siginfo_t_defined` → `siginfo_t`: honoured
- ガード `__sigset_t_defined` → `sigset_t`: honoured
- ガード `__sigstack_defined` → `struct sigstack`: absent
- ガード `__sigval_t_defined` → `sigval_t`: absent
- ガード `__stack_t_defined` → `stack_t`: absent
- ガード `__time_t_defined` → `time_t`: absent
- ガード `__uid_t_defined` → `uid_t`: self

### stdint.h

**x86_64 / aarch64** — glibc の `<stdint.h>` の公開名 122、不足 33、未記載 33

- 不足(gnu): **`INT16_WIDTH`** **`INT32_WIDTH`** **`INT64_WIDTH`** **`INT8_WIDTH`** **`INTMAX_WIDTH`** **`INTPTR_WIDTH`** **`INT_FAST16_WIDTH`** **`INT_FAST32_WIDTH`** **`INT_FAST64_WIDTH`** **`INT_FAST8_WIDTH`** **`INT_LEAST16_WIDTH`** **`INT_LEAST32_WIDTH`** **`INT_LEAST64_WIDTH`** **`INT_LEAST8_WIDTH`** **`PTRDIFF_WIDTH`** **`SIG_ATOMIC_WIDTH`** **`SIZE_WIDTH`** **`UINT16_WIDTH`** **`UINT32_WIDTH`** **`UINT64_WIDTH`** **`UINT8_WIDTH`** **`UINTMAX_WIDTH`** **`UINTPTR_WIDTH`** **`UINT_FAST16_WIDTH`** **`UINT_FAST32_WIDTH`** **`UINT_FAST64_WIDTH`** **`UINT_FAST8_WIDTH`** **`UINT_LEAST16_WIDTH`** **`UINT_LEAST32_WIDTH`** **`UINT_LEAST64_WIDTH`** **`UINT_LEAST8_WIDTH`** **`WCHAR_WIDTH`** **`WINT_WIDTH`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__intptr_t_defined` → `intptr_t`: self
- 余剰: `wchar_t`

### stdio.h

**x86_64 / aarch64** — glibc の `<stdio.h>` の公開名 130、不足 56、未記載 58

- 不足(posix): **`ctermid`** **`flockfile`** **`fmemopen`** **`ftrylockfile`** **`funlockfile`** **`getc_unlocked`** **`getchar_unlocked`** **`open_memstream`** **`putc_unlocked`** **`putchar_unlocked`** **`renameat`** **`va_list`** **`vdprintf`**
- 不足(xopen): **`tempnam`**
- 不足(default): **`clearerr_unlocked`** **`cookie_close_function_t`** **`cookie_io_functions_t`** **`cookie_read_function_t`** **`cookie_seek_function_t`** **`cookie_write_function_t`** **`feof_unlocked`** **`ferror_unlocked`** **`fflush_unlocked`** **`fgetc_unlocked`** **`fileno_unlocked`** **`fopencookie`** **`fputc_unlocked`** **`fread_unlocked`** **`fwrite_unlocked`** **`getw`** **`putw`** **`setbuffer`** **`setlinebuf`** **`tmpnam_r`**
- 不足(gnu): **`L_cuserid`** **`RENAME_EXCHANGE`** **`RENAME_NOREPLACE`** **`RENAME_WHITEOUT`** **`SEEK_DATA`** **`SEEK_HOLE`** **`cuserid`** **`fcloseall`** **`fgetpos64`** **`fgets_unlocked`** **`fopen64`** **`fpos64_t`** **`fputs_unlocked`** **`freopen64`** **`fseeko64`** **`fsetpos64`** **`ftello64`** **`obstack_printf`** **`obstack_vprintf`** **`off64_t`** **`renameat2`** **`tmpfile64`**
- 取り込み不足: `stdarg.h` `stddef.h`
- 予約名の型: `_IO_lock_t` `__FILE` `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fpos64_t` `__fpos_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mbstate_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `struct _G_fpos64_t` `struct _G_fpos_t` `struct _IO_FILE` `struct _IO_cookie_io_functions_t`
- ガード `__FILE_defined` → `FILE`: honoured(<stdio.h>, <argp.h>: ok; <argp.h>, <stdio.h>: ok; <stdio.h>, <wchar.h>: ok; <wchar.h>, <stdio.h>: ok; <stdio.h>, <malloc.h>: ok; <malloc.h>, <stdio.h>: ok)
- ガード `____FILE_defined` → `__FILE`: absent
- ガード `_____fpos64_t_defined` → `__fpos64_t`: absent
- ガード `_____fpos_t_defined` → `__fpos_t`: absent
- ガード `____mbstate_t_defined` → `__mbstate_t`: absent
- ガード `__cookie_io_functions_t_defined` → `cookie_io_functions_t`: absent
- ガード `__off64_t_defined` → `off64_t`: absent
- ガード `__off_t_defined` → `off_t`: self
- ガード `__ssize_t_defined` → `ssize_t`: self
- ガード `__struct_FILE_defined` → `_IO_lock_t` `struct _IO_FILE`: absent

### stdlib.h

**x86_64 / aarch64** — glibc の `<stdlib.h>` の公開名 162、不足 83、未記載 0

- 不足(posix): `WCONTINUED` `WEXITED` `WEXITSTATUS` `WIFCONTINUED` `WIFEXITED` `WIFSIGNALED` `WIFSTOPPED` `WNOHANG` `WNOWAIT` `WSTOPPED` `WSTOPSIG` `WTERMSIG` `WUNTRACED` `getsubopt`
- 不足(xopen): `a64l` `l64a`
- 不足(default): `arc4random` `arc4random_buf` `arc4random_uniform` `clearenv` `drand48_r` `ecvt` `ecvt_r` `erand48_r` `fcvt` `fcvt_r` `gcvt` `initstate_r` `jrand48_r` `lcong48_r` `lrand48_r` `mktemp` `mrand48_r` `nrand48_r` `on_exit` `qecvt` `qecvt_r` `qfcvt` `qfcvt_r` `qgcvt` `random_r` `rpmatch` `seed48_r` `setstate_r` `srand48_r` `srandom_r` `strtoq` `strtouq` `struct drand48_data` `struct random_data` `valloc`
- 不足(gnu): `comparison_fn_t` `getpt` `locale_t` `mkostemp64` `mkostemps64` `mkstemp64` `mkstemps64` `strfromd` `strfromf` `strfromf128` `strfromf32` `strfromf32x` `strfromf64` `strfromf64x` `strfroml` `strtod_l` `strtof128` `strtof128_l` `strtof32` `strtof32_l` `strtof32x` `strtof32x_l` `strtof64` `strtof64_l` `strtof64x` `strtof64x_l` `strtof_l` `strtol_l` `strtold_l` `strtoll_l` `strtoul_l` `strtoull_l`
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h` `sys/types.h`
- 予約名の型: `__compar_d_fn_t` `__compar_fn_t` `__locale_t` `struct __locale_struct`
- ガード `__ldiv_t_defined` → `ldiv_t`: self
- ガード `__lldiv_t_defined` → `lldiv_t`: self

### string.h

**x86_64 / aarch64** — glibc の `<string.h>` の公開名 55、不足 16、未記載 17

- 不足(posix): **`locale_t`** **`strcoll_l`** **`strerror_l`** **`strxfrm_l`**
- 不足(default): **`explicit_bzero`**
- 不足(gnu): **`basename`** **`memfrob`** **`rawmemchr`** **`sigabbrev_np`** **`sigdescr_np`** **`strdupa`** **`strerrordesc_np`** **`strerrorname_np`** **`strfry`** **`strndupa`** **`strverscmp`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__locale_t` `struct __locale_struct`

### strings.h

**x86_64 / aarch64** — glibc の `<strings.h>` の公開名 13、不足 3、未記載 4

- 不足(posix): **`locale_t`** **`strcasecmp_l`** **`strncasecmp_l`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__locale_t` `struct __locale_struct`
- 余剰: `memchr`

### sys/cdefs.h

**x86_64 / aarch64** — glibc の `<sys/cdefs.h>` の公開名 0、不足 0、未記載 0

- 不足なし

### sys/epoll.h

**x86_64 / aarch64** — glibc の `<sys/epoll.h>` の公開名 29、不足 3、未記載 7

- 不足(iso): **`enum EPOLL_EVENTS`** **`epoll_pwait`** **`epoll_pwait2`**
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h` `sys/types.h`

### sys/fcntl.h

**x86_64 / aarch64** — glibc の `<sys/fcntl.h>` の公開名 0、不足 0、未記載 1

- 取り込み不足: `stddef.h`

### sys/inotify.h

**x86_64 / aarch64** — glibc の `<sys/inotify.h>` の公開名 32、不足 0、未記載 0

- 不足なし

### sys/ioctl.h

**x86_64 / aarch64** — glibc の `<sys/ioctl.h>` の公開名 176、不足 13、未記載 0

- 不足(iso): `IOCSIZE_MASK` `IOCSIZE_SHIFT` `IOC_IN` `IOC_INOUT` `IOC_OUT` `NCC` `TCGETS2` `TCSETS2` `TCSETSF2` `TCSETSW2` `TIOCGISO7816` `TIOCSISO7816` `struct termio`
- 取り込み不足: `sys/ttydefaults.h`

### sys/mman.h

**x86_64** — glibc の `<sys/mman.h>` の公開名 104、不足 72、未記載 73

- 不足(iso): **`MAP_32BIT`** **`MAP_ABOVE4G`** **`MAP_DENYWRITE`** **`MAP_EXECUTABLE`** **`MAP_FILE`** **`MAP_FIXED_NOREPLACE`** **`MAP_HUGETLB`** **`MAP_HUGE_MASK`** **`MAP_HUGE_SHIFT`** **`MAP_NONBLOCK`** **`MAP_SHARED_VALIDATE`** **`MAP_SYNC`** **`MAP_TYPE`** **`MCL_CURRENT`** **`MCL_FUTURE`** **`MCL_ONFAULT`** **`PROT_GROWSDOWN`** **`PROT_GROWSUP`** **`mlockall`** **`mode_t`** **`munlockall`** **`shm_open`** **`shm_unlink`**
- 不足(posix): **`POSIX_MADV_DONTNEED`** **`POSIX_MADV_NORMAL`** **`POSIX_MADV_RANDOM`** **`POSIX_MADV_SEQUENTIAL`** **`POSIX_MADV_WILLNEED`** **`posix_madvise`**
- 不足(default): **`MADV_COLD`** **`MADV_COLLAPSE`** **`MADV_DODUMP`** **`MADV_DOFORK`** **`MADV_DONTDUMP`** **`MADV_DONTFORK`** **`MADV_DONTNEED_LOCKED`** **`MADV_HUGEPAGE`** **`MADV_HWPOISON`** **`MADV_KEEPONFORK`** **`MADV_MERGEABLE`** **`MADV_NOHUGEPAGE`** **`MADV_PAGEOUT`** **`MADV_POPULATE_READ`** **`MADV_POPULATE_WRITE`** **`MADV_REMOVE`** **`MADV_UNMERGEABLE`** **`MADV_WIPEONFORK`** **`SHADOW_STACK_SET_TOKEN`** **`mincore`**
- 不足(gnu): **`MFD_ALLOW_SEALING`** **`MFD_CLOEXEC`** **`MFD_EXEC`** **`MFD_HUGETLB`** **`MFD_NOEXEC_SEAL`** **`MLOCK_ONFAULT`** **`MREMAP_DONTUNMAP`** **`MREMAP_FIXED`** **`MREMAP_MAYMOVE`** **`PKEY_DISABLE_ACCESS`** **`PKEY_DISABLE_WRITE`** **`memfd_create`** **`mlock2`** **`mmap64`** **`mremap`** **`pkey_alloc`** **`pkey_free`** **`pkey_get`** **`pkey_mprotect`** **`pkey_set`** **`process_madvise`** **`process_mrelease`** **`remap_file_pages`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__mode_t_defined` → `mode_t`: absent
- ガード `__off_t_defined` → `off_t`: self

**aarch64** — glibc の `<sys/mman.h>` の公開名 103、不足 71、未記載 72

- 不足(iso): **`MAP_DENYWRITE`** **`MAP_EXECUTABLE`** **`MAP_FILE`** **`MAP_FIXED_NOREPLACE`** **`MAP_HUGETLB`** **`MAP_HUGE_MASK`** **`MAP_HUGE_SHIFT`** **`MAP_NONBLOCK`** **`MAP_SHARED_VALIDATE`** **`MAP_SYNC`** **`MAP_TYPE`** **`MCL_CURRENT`** **`MCL_FUTURE`** **`MCL_ONFAULT`** **`PROT_BTI`** **`PROT_GROWSDOWN`** **`PROT_GROWSUP`** **`PROT_MTE`** **`mlockall`** **`mode_t`** **`munlockall`** **`shm_open`** **`shm_unlink`**
- 不足(posix): **`POSIX_MADV_DONTNEED`** **`POSIX_MADV_NORMAL`** **`POSIX_MADV_RANDOM`** **`POSIX_MADV_SEQUENTIAL`** **`POSIX_MADV_WILLNEED`** **`posix_madvise`**
- 不足(default): **`MADV_COLD`** **`MADV_COLLAPSE`** **`MADV_DODUMP`** **`MADV_DOFORK`** **`MADV_DONTDUMP`** **`MADV_DONTFORK`** **`MADV_DONTNEED_LOCKED`** **`MADV_HUGEPAGE`** **`MADV_HWPOISON`** **`MADV_KEEPONFORK`** **`MADV_MERGEABLE`** **`MADV_NOHUGEPAGE`** **`MADV_PAGEOUT`** **`MADV_POPULATE_READ`** **`MADV_POPULATE_WRITE`** **`MADV_REMOVE`** **`MADV_UNMERGEABLE`** **`MADV_WIPEONFORK`** **`mincore`**
- 不足(gnu): **`MFD_ALLOW_SEALING`** **`MFD_CLOEXEC`** **`MFD_EXEC`** **`MFD_HUGETLB`** **`MFD_NOEXEC_SEAL`** **`MLOCK_ONFAULT`** **`MREMAP_DONTUNMAP`** **`MREMAP_FIXED`** **`MREMAP_MAYMOVE`** **`PKEY_DISABLE_ACCESS`** **`PKEY_DISABLE_WRITE`** **`memfd_create`** **`mlock2`** **`mmap64`** **`mremap`** **`pkey_alloc`** **`pkey_free`** **`pkey_get`** **`pkey_mprotect`** **`pkey_set`** **`process_madvise`** **`process_mrelease`** **`remap_file_pages`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__mode_t_defined` → `mode_t`: absent
- ガード `__off_t_defined` → `off_t`: self

### sys/param.h

**x86_64** — glibc の `<sys/param.h>` の公開名 22、不足 18、未記載 27

- 不足(iso): **`CANBSIZ`** **`DEV_BSIZE`** **`EXEC_PAGESIZE`** **`HZ`** **`MAXHOSTNAMELEN`** **`MAXPATHLEN`** **`MAXSYMLINKS`** **`NBBY`** **`NCARGS`** **`NGROUPS`** **`NODEV`** **`NOFILE`** **`NOGROUP`** **`clrbit`** **`isclr`** **`isset`** **`powerof2`** **`setbit`**
- 取り込み不足: `endian.h` `limits.h` `signal.h` `stddef.h` `sys/select.h` `sys/types.h` `sys/ucontext.h` `syslimits.h` `unistd.h`

**aarch64** — glibc の `<sys/param.h>` の公開名 22、不足 18、未記載 30

- 不足(iso): **`CANBSIZ`** **`DEV_BSIZE`** **`EXEC_PAGESIZE`** **`HZ`** **`MAXHOSTNAMELEN`** **`MAXPATHLEN`** **`MAXSYMLINKS`** **`NBBY`** **`NCARGS`** **`NGROUPS`** **`NODEV`** **`NOFILE`** **`NOGROUP`** **`clrbit`** **`isclr`** **`isset`** **`powerof2`** **`setbit`**
- 取り込み不足: `endian.h` `limits.h` `signal.h` `stddef.h` `sys/procfs.h` `sys/select.h` `sys/time.h` `sys/types.h` `sys/ucontext.h` `sys/user.h` `syslimits.h` `unistd.h`

### sys/resource.h

**x86_64 / aarch64** — glibc の `<sys/resource.h>` の公開名 48、不足 20、未記載 20

- 不足(iso): **`PRIO_MAX`** **`PRIO_MIN`** **`PRIO_PGRP`** **`PRIO_PROCESS`** **`PRIO_USER`** **`RLIMIT_OFILE`** **`RLIM_NLIMITS`** **`RLIM_SAVED_CUR`** **`RLIM_SAVED_MAX`** **`getpriority`** **`id_t`** **`setpriority`**
- 不足(gnu): **`RLIM64_INFINITY`** **`RUSAGE_LWP`** **`getrlimit64`** **`prlimit`** **`prlimit64`** **`rlim64_t`** **`setrlimit64`** **`struct rlimit64`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__priority_which_t` `__quad_t` `__rlim64_t` `__rlim_t` `__rlimit_resource_t` `__rusage_who_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `enum __priority_which` `enum __rlimit_resource` `enum __rusage_who`
- ガード `__id_t_defined` → `id_t`: absent
- ガード `__rusage_defined` → `struct rusage`: unguarded(<sys/resource.h>, direct: x86_64-linux-gnu/bits/types/struct_rusage.h:33:1: error: redefinition of 'struct rusage'; direct, <sys/resource.h>: libc/sys/resource.h:59:1: error: redefinition of 'struct rusage')
- ガード `__timeval_defined` → `struct timeval`: honoured(<sys/resource.h>, <aio.h>: ok; <aio.h>, <sys/resource.h>: ok; <sys/resource.h>, <fts.h>: ok; <fts.h>, <sys/resource.h>: ok; <sys/resource.h>, <ftw.h>: ok; <ftw.h>, <sys/resource.h>: ok)
- 余剰: `suseconds_t` `time_t`

### sys/select.h

**x86_64 / aarch64** — glibc の `<sys/select.h>` の公開名 15、不足 1、未記載 1

- 不足(default): **`NFDBITS`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `____sigset_t_defined` → `__sigset_t`: unguarded(<sys/select.h>, <aio.h>: ok; <aio.h>, <sys/select.h>: ok; <sys/select.h>, <fts.h>: ok; <fts.h>, <sys/select.h>: ok; <sys/select.h>, <ftw.h>: ok; <ftw.h>, <sys/select.h>: ok)
- ガード `__sigset_t_defined` → `sigset_t`: honoured(<sys/select.h>, <aio.h>: ok; <aio.h>, <sys/select.h>: ok; <sys/select.h>, <fts.h>: ok; <fts.h>, <sys/select.h>: ok; <sys/select.h>, <ftw.h>: ok; <ftw.h>, <sys/select.h>: ok)
- ガード `__suseconds_t_defined` → `suseconds_t`: self
- ガード `__time_t_defined` → `time_t`: unguarded(<sys/select.h>, <aio.h>: ok; <aio.h>, <sys/select.h>: ok; <sys/select.h>, <fts.h>: ok; <fts.h>, <sys/select.h>: ok; <sys/select.h>, <ftw.h>: ok; <ftw.h>, <sys/select.h>: ok)
- ガード `__timeval_defined` → `struct timeval`: honoured(<sys/select.h>, <aio.h>: ok; <aio.h>, <sys/select.h>: ok; <sys/select.h>, <fts.h>: ok; <fts.h>, <sys/select.h>: ok; <sys/select.h>, <ftw.h>: ok; <ftw.h>, <sys/select.h>: ok)

### sys/socket.h

**x86_64 / aarch64** — glibc の `<sys/socket.h>` の公開名 302、不足 239、未記載 243

- 不足(iso): **`AF_ALG`** **`AF_APPLETALK`** **`AF_ASH`** **`AF_ATMPVC`** **`AF_ATMSVC`** **`AF_AX25`** **`AF_BLUETOOTH`** **`AF_BRIDGE`** **`AF_CAIF`** **`AF_CAN`** **`AF_DECnet`** **`AF_ECONET`** **`AF_FILE`** **`AF_IB`** **`AF_IEEE802154`** **`AF_IPX`** **`AF_IRDA`** **`AF_ISDN`** **`AF_IUCV`** **`AF_KCM`** **`AF_KEY`** **`AF_LLC`** **`AF_MAX`** **`AF_MCTP`** **`AF_MPLS`** **`AF_NETBEUI`** **`AF_NETROM`** **`AF_NFC`** **`AF_PACKET`** **`AF_PHONET`** **`AF_PPPOX`** **`AF_QIPCRTR`** **`AF_RDS`** **`AF_ROSE`** **`AF_ROUTE`** **`AF_RXRPC`** **`AF_SECURITY`** **`AF_SMC`** **`AF_SNA`** **`AF_TIPC`** **`AF_VSOCK`** **`AF_WANPIPE`** **`AF_X25`** **`AF_XDP`** **`CMSG_ALIGN`** **`CMSG_DATA`** **`CMSG_FIRSTHDR`** **`CMSG_LEN`** **`CMSG_NXTHDR`** **`CMSG_SPACE`** **`MSG_BATCH`** **`MSG_CMSG_CLOEXEC`** **`MSG_CONFIRM`** **`MSG_CTRUNC`** **`MSG_DONTROUTE`** **`MSG_EOR`** **`MSG_ERRQUEUE`** **`MSG_FASTOPEN`** **`MSG_FIN`** **`MSG_MORE`** **`MSG_PROXY`** **`MSG_RST`** **`MSG_SYN`** **`MSG_WAITFORONE`** **`MSG_ZEROCOPY`** **`PF_ALG`** **`PF_APPLETALK`** **`PF_ASH`** **`PF_ATMPVC`** **`PF_ATMSVC`** **`PF_AX25`** **`PF_BLUETOOTH`** **`PF_BRIDGE`** **`PF_CAIF`** **`PF_CAN`** **`PF_DECnet`** **`PF_ECONET`** **`PF_FILE`** **`PF_IB`** **`PF_IEEE802154`** **`PF_IPX`** **`PF_IRDA`** **`PF_ISDN`** **`PF_IUCV`** **`PF_KCM`** **`PF_KEY`** **`PF_LLC`** **`PF_MAX`** **`PF_MCTP`** **`PF_MPLS`** **`PF_NETBEUI`** **`PF_NETROM`** **`PF_NFC`** **`PF_PACKET`** **`PF_PHONET`** **`PF_PPPOX`** **`PF_QIPCRTR`** **`PF_RDS`** **`PF_ROSE`** **`PF_ROUTE`** **`PF_RXRPC`** **`PF_SECURITY`** **`PF_SMC`** **`PF_SNA`** **`PF_TIPC`** **`PF_VSOCK`** **`PF_WANPIPE`** **`PF_X25`** **`PF_XDP`** **`SCM_RIGHTS`** **`SOCK_DCCP`** **`SOCK_PACKET`** **`SOCK_RDM`** **`SOL_AAL`** **`SOL_ALG`** **`SOL_ATM`** **`SOL_BLUETOOTH`** **`SOL_CAIF`** **`SOL_DCCP`** **`SOL_DECNET`** **`SOL_IRDA`** **`SOL_IUCV`** **`SOL_KCM`** **`SOL_LLC`** **`SOL_MCTP`** **`SOL_MPTCP`** **`SOL_NETBEUI`** **`SOL_NETLINK`** **`SOL_NFC`** **`SOL_PACKET`** **`SOL_PNPIPE`** **`SOL_PPPOL2TP`** **`SOL_RAW`** **`SOL_RDS`** **`SOL_RXRPC`** **`SOL_SMC`** **`SOL_TIPC`** **`SOL_TLS`** **`SOL_X25`** **`SOL_XDP`** **`SOMAXCONN`** **`SO_ACCEPTCONN`** **`SO_DEBUG`** **`SO_DONTROUTE`** **`SO_OOBINLINE`** **`SO_RCVLOWAT`** **`SO_RCVTIMEO`** **`SO_SNDLOWAT`** **`SO_SNDTIMEO`** **`SO_TIMESTAMP`** **`SO_TIMESTAMPING`** **`SO_TIMESTAMPNS`**
- 不足(posix): **`sockatmark`**
- 不足(default): **`FIOGETOWN`** **`FIOSETOWN`** **`SCM_TIMESTAMP`** **`SCM_TIMESTAMPING`** **`SCM_TIMESTAMPING_OPT_STATS`** **`SCM_TIMESTAMPING_PKTINFO`** **`SCM_TIMESTAMPNS`** **`SCM_TXTIME`** **`SCM_WIFI_STATUS`** **`SIOCATMARK`** **`SIOCGPGRP`** **`SIOCGSTAMPNS_OLD`** **`SIOCGSTAMP_OLD`** **`SIOCSPGRP`** **`SO_ATTACH_BPF`** **`SO_ATTACH_FILTER`** **`SO_ATTACH_REUSEPORT_CBPF`** **`SO_ATTACH_REUSEPORT_EBPF`** **`SO_BINDTODEVICE`** **`SO_BINDTOIFINDEX`** **`SO_BPF_EXTENSIONS`** **`SO_BSDCOMPAT`** **`SO_BUF_LOCK`** **`SO_BUSY_POLL`** **`SO_BUSY_POLL_BUDGET`** **`SO_CNX_ADVICE`** **`SO_COOKIE`** **`SO_DETACH_BPF`** **`SO_DETACH_FILTER`** **`SO_DETACH_REUSEPORT_BPF`** **`SO_DOMAIN`** **`SO_GET_FILTER`** **`SO_INCOMING_CPU`** **`SO_INCOMING_NAPI_ID`** **`SO_LOCK_FILTER`** **`SO_MARK`** **`SO_MAX_PACING_RATE`** **`SO_MEMINFO`** **`SO_NETNS_COOKIE`** **`SO_NOFCS`** **`SO_NO_CHECK`** **`SO_PASSCRED`** **`SO_PASSPIDFD`** **`SO_PASSSEC`** **`SO_PEEK_OFF`** **`SO_PEERCRED`** **`SO_PEERGROUPS`** **`SO_PEERNAME`** **`SO_PEERPIDFD`** **`SO_PEERSEC`** **`SO_PREFER_BUSY_POLL`** **`SO_PRIORITY`** **`SO_PROTOCOL`** **`SO_RCVBUFFORCE`** **`SO_RCVMARK`** **`SO_RCVTIMEO_NEW`** **`SO_RCVTIMEO_OLD`** **`SO_RESERVE_MEM`** **`SO_RXQ_OVFL`** **`SO_SECURITY_AUTHENTICATION`** **`SO_SECURITY_ENCRYPTION_NETWORK`** **`SO_SECURITY_ENCRYPTION_TRANSPORT`** **`SO_SELECT_ERR_QUEUE`** **`SO_SNDBUFFORCE`** **`SO_SNDTIMEO_NEW`** **`SO_SNDTIMEO_OLD`** **`SO_TIMESTAMPING_NEW`** **`SO_TIMESTAMPING_OLD`** **`SO_TIMESTAMPNS_NEW`** **`SO_TIMESTAMPNS_OLD`** **`SO_TIMESTAMP_NEW`** **`SO_TIMESTAMP_OLD`** **`SO_TXREHASH`** **`SO_TXTIME`** **`SO_WIFI_STATUS`** **`SO_ZEROCOPY`** **`isfdtype`** **`struct osockaddr`**
- 不足(gnu): **`MSG_TRYHARD`** **`SCM_CREDENTIALS`** **`SCM_PIDFD`** **`SCM_SECURITY`** **`recvmmsg`** **`sendmmsg`** **`struct mmsghdr`** **`struct ucred`**
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h` `sys/types.h`
- 予約名の型: `__CONST_SOCKADDR_ARG` `__SOCKADDR_ARG` `__kernel_caddr_t` `__kernel_clock_t` `__kernel_clockid_t` `__kernel_daddr_t` `__kernel_fd_set` `__kernel_fsid_t` `__kernel_gid16_t` `__kernel_gid32_t` `__kernel_gid_t` `__kernel_ino_t` `__kernel_ipc_pid_t` `__kernel_key_t` `__kernel_loff_t` `__kernel_long_t` `__kernel_mode_t` `__kernel_mqd_t` `__kernel_off_t` `__kernel_old_dev_t` `__kernel_old_gid_t` `__kernel_old_time_t` `__kernel_old_uid_t` `__kernel_pid_t` `__kernel_ptrdiff_t` `__kernel_sighandler_t` `__kernel_size_t` `__kernel_ssize_t` `__kernel_suseconds_t` `__kernel_time64_t` `__kernel_time_t` `__kernel_timer_t` `__kernel_uid16_t` `__kernel_uid32_t` `__kernel_uid_t` `__kernel_ulong_t` `enum __socket_type`
- ガード `__iovec_defined` → `struct iovec`: unguarded(<sys/socket.h>, <netdb.h>: ok; <netdb.h>, <sys/socket.h>: ok; <sys/socket.h>, <mqueue.h>: ok; <mqueue.h>, <sys/socket.h>: ok; <sys/socket.h>, <net/if.h>: ok; <net/if.h>, <sys/socket.h>: ok)
- ガード `__osockaddr_defined` → `struct osockaddr`: absent
- ガード `__socklen_t_defined` → `socklen_t`: unguarded(<sys/socket.h>, <netdb.h>: ok; <netdb.h>, <sys/socket.h>: ok; <sys/socket.h>, <net/if.h>: ok; <net/if.h>, <sys/socket.h>: ok; <sys/socket.h>, <resolv.h>: ok; <resolv.h>, <sys/socket.h>: ok)

### sys/stat.h

**x86_64 / aarch64** — glibc の `<sys/stat.h>` の公開名 110、不足 56、未記載 56

- 不足(posix): **`S_TYPEISMQ`** **`S_TYPEISSEM`** **`S_TYPEISSHM`** **`UTIME_NOW`** **`UTIME_OMIT`** **`fchmodat`** **`futimens`** **`mkdirat`** **`mkfifoat`** **`utimensat`**
- 不足(xopen): **`mknod`** **`mknodat`**
- 不足(default): **`ACCESSPERMS`** **`ALLPERMS`** **`DEFFILEMODE`** **`S_BLKSIZE`** **`S_IEXEC`** **`S_IREAD`** **`S_IWRITE`** **`lchmod`**
- 不足(gnu): **`STATX_ALL`** **`STATX_ATIME`** **`STATX_ATTR_APPEND`** **`STATX_ATTR_AUTOMOUNT`** **`STATX_ATTR_COMPRESSED`** **`STATX_ATTR_DAX`** **`STATX_ATTR_ENCRYPTED`** **`STATX_ATTR_IMMUTABLE`** **`STATX_ATTR_MOUNT_ROOT`** **`STATX_ATTR_NODUMP`** **`STATX_ATTR_VERITY`** **`STATX_BASIC_STATS`** **`STATX_BLOCKS`** **`STATX_BTIME`** **`STATX_CTIME`** **`STATX_DIOALIGN`** **`STATX_GID`** **`STATX_INO`** **`STATX_MNT_ID`** **`STATX_MNT_ID_UNIQUE`** **`STATX_MODE`** **`STATX_MTIME`** **`STATX_NLINK`** **`STATX_SIZE`** **`STATX_TYPE`** **`STATX_UID`** **`STATX__RESERVED`** **`fstat64`** **`fstatat64`** **`getumask`** **`lstat64`** **`stat64`** **`statx`** **`struct stat64`** **`struct statx`** **`struct statx_timestamp`**
- 予約名の型: `__be16` `__be32` `__be64` `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__kernel_caddr_t` `__kernel_clock_t` `__kernel_clockid_t` `__kernel_daddr_t` `__kernel_fd_set` `__kernel_fsid_t` `__kernel_gid16_t` `__kernel_gid32_t` `__kernel_gid_t` `__kernel_ino_t` `__kernel_ipc_pid_t` `__kernel_key_t` `__kernel_loff_t` `__kernel_long_t` `__kernel_mode_t` `__kernel_mqd_t` `__kernel_off_t` `__kernel_old_dev_t` `__kernel_old_gid_t` `__kernel_old_time_t` `__kernel_old_uid_t` `__kernel_pid_t` `__kernel_ptrdiff_t` `__kernel_sighandler_t` `__kernel_size_t` `__kernel_ssize_t` `__kernel_suseconds_t` `__kernel_time64_t` `__kernel_time_t` `__kernel_timer_t` `__kernel_uid16_t` `__kernel_uid32_t` `__kernel_uid_t` `__kernel_ulong_t` `__key_t` `__le16` `__le32` `__le64` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__poll_t` `__quad_t` `__rlim64_t` `__rlim_t` `__s128` `__s16` `__s32` `__s64` `__s8` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__sum16` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u128` `__u16` `__u32` `__u64` `__u8` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `__wsum`
- ガード `__blkcnt_t_defined` → `blkcnt_t`: self
- ガード `__blksize_t_defined` → `blksize_t`: self
- ガード `__dev_t_defined` → `dev_t`: self
- ガード `__gid_t_defined` → `gid_t`: self
- ガード `__ino_t_defined` → `ino_t`: self
- ガード `__mode_t_defined` → `mode_t`: self
- ガード `__nlink_t_defined` → `nlink_t`: self
- ガード `__off_t_defined` → `off_t`: self
- ガード `__statx_defined` → —: absent
- ガード `__statx_timestamp_defined` → —: absent
- ガード `__time_t_defined` → `time_t`: unguarded(<sys/stat.h>, <aio.h>: ok; <aio.h>, <sys/stat.h>: ok; <sys/stat.h>, <fts.h>: ok; <fts.h>, <sys/stat.h>: ok; <sys/stat.h>, <ftw.h>: ok; <ftw.h>, <sys/stat.h>: ok)
- ガード `__uid_t_defined` → `uid_t`: self
- 余剰: `S_ISTYPE`

### sys/statfs.h

**x86_64 / aarch64** — glibc の `<sys/statfs.h>` の公開名 6、不足 3、未記載 3

- 不足(gnu): **`fstatfs64`** **`statfs64`** **`struct statfs64`**
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- 余剰: `fsid_t`

### sys/syscall.h

**x86_64** — glibc の `<sys/syscall.h>` の公開名 368、不足 312、未記載 312

- 不足(iso): **`SYS__sysctl`** **`SYS_accept`** **`SYS_accept4`** **`SYS_access`** **`SYS_acct`** **`SYS_add_key`** **`SYS_adjtimex`** **`SYS_afs_syscall`** **`SYS_alarm`** **`SYS_arch_prctl`** **`SYS_bind`** **`SYS_bpf`** **`SYS_brk`** **`SYS_cachestat`** **`SYS_capget`** **`SYS_capset`** **`SYS_chdir`** **`SYS_chmod`** **`SYS_chown`** **`SYS_chroot`** **`SYS_clock_adjtime`** **`SYS_clock_getres`** **`SYS_clock_settime`** **`SYS_clone3`** **`SYS_close_range`** **`SYS_connect`** **`SYS_copy_file_range`** **`SYS_creat`** **`SYS_create_module`** **`SYS_delete_module`** **`SYS_dup`** **`SYS_dup2`** **`SYS_epoll_create`** **`SYS_epoll_ctl_old`** **`SYS_epoll_pwait2`** **`SYS_epoll_wait`** **`SYS_epoll_wait_old`** **`SYS_eventfd`** **`SYS_execve`** **`SYS_execveat`** **`SYS_faccessat2`** **`SYS_fadvise64`** **`SYS_fallocate`** **`SYS_fanotify_init`** **`SYS_fanotify_mark`** **`SYS_fchdir`** **`SYS_fchmod`** **`SYS_fchmodat`** **`SYS_fchmodat2`** **`SYS_fchown`** **`SYS_fchownat`** **`SYS_fdatasync`** **`SYS_fgetxattr`** **`SYS_finit_module`** **`SYS_flistxattr`** **`SYS_flock`** **`SYS_fork`** **`SYS_fremovexattr`** **`SYS_fsconfig`** **`SYS_fsetxattr`** **`SYS_fsmount`** **`SYS_fsopen`** **`SYS_fspick`** **`SYS_fstat`** **`SYS_fsync`** **`SYS_ftruncate`** **`SYS_futex_requeue`** **`SYS_futex_wait`** **`SYS_futex_waitv`** **`SYS_futex_wake`** **`SYS_futimesat`** **`SYS_get_kernel_syms`** **`SYS_get_mempolicy`** **`SYS_get_robust_list`** **`SYS_get_thread_area`** **`SYS_getcwd`** **`SYS_getdents`** **`SYS_getdents64`** **`SYS_getegid`** **`SYS_geteuid`** **`SYS_getgid`** **`SYS_getgroups`** **`SYS_getitimer`** **`SYS_getpeername`** **`SYS_getpgid`** **`SYS_getpgrp`** **`SYS_getpmsg`** **`SYS_getppid`** **`SYS_getpriority`** **`SYS_getresgid`** **`SYS_getresuid`** **`SYS_getrlimit`** **`SYS_getrusage`** **`SYS_getsid`** **`SYS_getsockname`** **`SYS_getsockopt`** **`SYS_gettimeofday`** **`SYS_getuid`** **`SYS_getxattr`** **`SYS_init_module`** **`SYS_inotify_init`** **`SYS_io_pgetevents`** **`SYS_ioperm`** **`SYS_iopl`** **`SYS_ioprio_get`** **`SYS_ioprio_set`** **`SYS_kcmp`** **`SYS_kexec_file_load`** **`SYS_kexec_load`** **`SYS_keyctl`** **`SYS_landlock_add_rule`** **`SYS_landlock_create_ruleset`** **`SYS_landlock_restrict_self`** **`SYS_lchown`** **`SYS_lgetxattr`** **`SYS_link`** **`SYS_linkat`** **`SYS_listen`** **`SYS_listxattr`** **`SYS_llistxattr`** **`SYS_lookup_dcookie`** **`SYS_lremovexattr`** **`SYS_lsetxattr`** **`SYS_lstat`** **`SYS_madvise`** **`SYS_map_shadow_stack`** **`SYS_mbind`** **`SYS_memfd_create`** **`SYS_memfd_secret`** **`SYS_migrate_pages`** **`SYS_mincore`** **`SYS_mkdir`** **`SYS_mkdirat`** **`SYS_mknod`** **`SYS_mknodat`** **`SYS_mlock`** **`SYS_mlock2`** **`SYS_mlockall`** **`SYS_modify_ldt`** **`SYS_mount`** **`SYS_mount_setattr`** **`SYS_move_mount`** **`SYS_move_pages`** **`SYS_mq_getsetattr`** **`SYS_mq_notify`** **`SYS_mq_open`** **`SYS_mq_timedreceive`** **`SYS_mq_timedsend`** **`SYS_mq_unlink`** **`SYS_mremap`** **`SYS_msgctl`** **`SYS_msgget`** **`SYS_msgrcv`** **`SYS_msgsnd`** **`SYS_msync`** **`SYS_munlock`** **`SYS_munlockall`** **`SYS_name_to_handle_at`** **`SYS_newfstatat`** **`SYS_nfsservctl`** **`SYS_open`** **`SYS_open_by_handle_at`** **`SYS_open_tree`** **`SYS_openat2`** **`SYS_pause`** **`SYS_perf_event_open`** **`SYS_personality`** **`SYS_pidfd_getfd`** **`SYS_pidfd_open`** **`SYS_pidfd_send_signal`** **`SYS_pipe`** **`SYS_pivot_root`** **`SYS_pkey_alloc`** **`SYS_pkey_free`** **`SYS_pkey_mprotect`** **`SYS_poll`** **`SYS_prctl`** **`SYS_pread64`** **`SYS_preadv`** **`SYS_preadv2`** **`SYS_prlimit64`** **`SYS_process_madvise`** **`SYS_process_mrelease`** **`SYS_process_vm_readv`** **`SYS_process_vm_writev`** **`SYS_ptrace`** **`SYS_putpmsg`** **`SYS_pwrite64`** **`SYS_pwritev`** **`SYS_pwritev2`** **`SYS_query_module`** **`SYS_quotactl`** **`SYS_quotactl_fd`** **`SYS_readahead`** **`SYS_readlink`** **`SYS_readv`** **`SYS_reboot`** **`SYS_recvfrom`** **`SYS_recvmmsg`** **`SYS_recvmsg`** **`SYS_remap_file_pages`** **`SYS_removexattr`** **`SYS_rename`** **`SYS_renameat`** **`SYS_renameat2`** **`SYS_request_key`** **`SYS_restart_syscall`** **`SYS_rmdir`** **`SYS_rseq`** **`SYS_rt_sigpending`** **`SYS_rt_sigqueueinfo`** **`SYS_rt_sigreturn`** **`SYS_rt_sigsuspend`** **`SYS_rt_sigtimedwait`** **`SYS_rt_tgsigqueueinfo`** **`SYS_sched_get_priority_max`** **`SYS_sched_get_priority_min`** **`SYS_sched_getaffinity`** **`SYS_sched_getattr`** **`SYS_sched_getparam`** **`SYS_sched_getscheduler`** **`SYS_sched_rr_get_interval`** **`SYS_sched_setaffinity`** **`SYS_sched_setattr`** **`SYS_sched_setparam`** **`SYS_sched_setscheduler`** **`SYS_seccomp`** **`SYS_security`** **`SYS_select`** **`SYS_semctl`** **`SYS_semget`** **`SYS_semop`** **`SYS_semtimedop`** **`SYS_sendfile`** **`SYS_sendmmsg`** **`SYS_sendmsg`** **`SYS_sendto`** **`SYS_set_mempolicy`** **`SYS_set_mempolicy_home_node`** **`SYS_set_robust_list`** **`SYS_set_thread_area`** **`SYS_set_tid_address`** **`SYS_setdomainname`** **`SYS_setfsgid`** **`SYS_setfsuid`** **`SYS_setgid`** **`SYS_setgroups`** **`SYS_sethostname`** **`SYS_setitimer`** **`SYS_setns`** **`SYS_setpgid`** **`SYS_setpriority`** **`SYS_setregid`** **`SYS_setresgid`** **`SYS_setresuid`** **`SYS_setreuid`** **`SYS_setrlimit`** **`SYS_setsid`** **`SYS_settimeofday`** **`SYS_setuid`** **`SYS_setxattr`** **`SYS_shmat`** **`SYS_shmctl`** **`SYS_shmdt`** **`SYS_shmget`** **`SYS_shutdown`** **`SYS_sigaltstack`** **`SYS_signalfd`** **`SYS_socketpair`** **`SYS_splice`** **`SYS_stat`** **`SYS_statx`** **`SYS_swapoff`** **`SYS_swapon`** **`SYS_symlink`** **`SYS_symlinkat`** **`SYS_sync`** **`SYS_sync_file_range`** **`SYS_syncfs`** **`SYS_sysfs`** **`SYS_sysinfo`** **`SYS_syslog`** **`SYS_tee`** **`SYS_time`** **`SYS_timer_create`** **`SYS_timer_delete`** **`SYS_timer_getoverrun`** **`SYS_timer_gettime`** **`SYS_timer_settime`** **`SYS_times`** **`SYS_tkill`** **`SYS_truncate`** **`SYS_tuxcall`** **`SYS_umask`** **`SYS_umount2`** **`SYS_uname`** **`SYS_unlink`** **`SYS_unlinkat`** **`SYS_unshare`** **`SYS_uselib`** **`SYS_userfaultfd`** **`SYS_ustat`** **`SYS_utime`** **`SYS_utimensat`** **`SYS_utimes`** **`SYS_vfork`** **`SYS_vhangup`** **`SYS_vmsplice`** **`SYS_vserver`** **`SYS_wait4`** **`SYS_waitid`** **`SYS_writev`**

**aarch64** — glibc の `<sys/syscall.h>` の公開名 312、不足 256、未記載 256

- 不足(iso): **`SYS_accept`** **`SYS_accept4`** **`SYS_acct`** **`SYS_add_key`** **`SYS_adjtimex`** **`SYS_bind`** **`SYS_bpf`** **`SYS_brk`** **`SYS_cachestat`** **`SYS_capget`** **`SYS_capset`** **`SYS_chdir`** **`SYS_chroot`** **`SYS_clock_adjtime`** **`SYS_clock_getres`** **`SYS_clock_settime`** **`SYS_clone3`** **`SYS_close_range`** **`SYS_connect`** **`SYS_copy_file_range`** **`SYS_delete_module`** **`SYS_dup`** **`SYS_epoll_pwait2`** **`SYS_execve`** **`SYS_execveat`** **`SYS_faccessat2`** **`SYS_fadvise64`** **`SYS_fallocate`** **`SYS_fanotify_init`** **`SYS_fanotify_mark`** **`SYS_fchdir`** **`SYS_fchmod`** **`SYS_fchmodat`** **`SYS_fchmodat2`** **`SYS_fchown`** **`SYS_fchownat`** **`SYS_fdatasync`** **`SYS_fgetxattr`** **`SYS_finit_module`** **`SYS_flistxattr`** **`SYS_flock`** **`SYS_fremovexattr`** **`SYS_fsconfig`** **`SYS_fsetxattr`** **`SYS_fsmount`** **`SYS_fsopen`** **`SYS_fspick`** **`SYS_fstat`** **`SYS_fsync`** **`SYS_ftruncate`** **`SYS_futex_requeue`** **`SYS_futex_wait`** **`SYS_futex_waitv`** **`SYS_futex_wake`** **`SYS_get_mempolicy`** **`SYS_get_robust_list`** **`SYS_getcwd`** **`SYS_getdents64`** **`SYS_getegid`** **`SYS_geteuid`** **`SYS_getgid`** **`SYS_getgroups`** **`SYS_getitimer`** **`SYS_getpeername`** **`SYS_getpgid`** **`SYS_getppid`** **`SYS_getpriority`** **`SYS_getresgid`** **`SYS_getresuid`** **`SYS_getrlimit`** **`SYS_getrusage`** **`SYS_getsid`** **`SYS_getsockname`** **`SYS_getsockopt`** **`SYS_gettimeofday`** **`SYS_getuid`** **`SYS_getxattr`** **`SYS_init_module`** **`SYS_io_pgetevents`** **`SYS_ioprio_get`** **`SYS_ioprio_set`** **`SYS_kcmp`** **`SYS_kexec_file_load`** **`SYS_kexec_load`** **`SYS_keyctl`** **`SYS_landlock_add_rule`** **`SYS_landlock_create_ruleset`** **`SYS_landlock_restrict_self`** **`SYS_lgetxattr`** **`SYS_linkat`** **`SYS_listen`** **`SYS_listxattr`** **`SYS_llistxattr`** **`SYS_lookup_dcookie`** **`SYS_lremovexattr`** **`SYS_lsetxattr`** **`SYS_madvise`** **`SYS_map_shadow_stack`** **`SYS_mbind`** **`SYS_memfd_create`** **`SYS_memfd_secret`** **`SYS_migrate_pages`** **`SYS_mincore`** **`SYS_mkdirat`** **`SYS_mknodat`** **`SYS_mlock`** **`SYS_mlock2`** **`SYS_mlockall`** **`SYS_mount`** **`SYS_mount_setattr`** **`SYS_move_mount`** **`SYS_move_pages`** **`SYS_mq_getsetattr`** **`SYS_mq_notify`** **`SYS_mq_open`** **`SYS_mq_timedreceive`** **`SYS_mq_timedsend`** **`SYS_mq_unlink`** **`SYS_mremap`** **`SYS_msgctl`** **`SYS_msgget`** **`SYS_msgrcv`** **`SYS_msgsnd`** **`SYS_msync`** **`SYS_munlock`** **`SYS_munlockall`** **`SYS_name_to_handle_at`** **`SYS_newfstatat`** **`SYS_nfsservctl`** **`SYS_open_by_handle_at`** **`SYS_open_tree`** **`SYS_openat2`** **`SYS_perf_event_open`** **`SYS_personality`** **`SYS_pidfd_getfd`** **`SYS_pidfd_open`** **`SYS_pidfd_send_signal`** **`SYS_pivot_root`** **`SYS_pkey_alloc`** **`SYS_pkey_free`** **`SYS_pkey_mprotect`** **`SYS_prctl`** **`SYS_pread64`** **`SYS_preadv`** **`SYS_preadv2`** **`SYS_prlimit64`** **`SYS_process_madvise`** **`SYS_process_mrelease`** **`SYS_process_vm_readv`** **`SYS_process_vm_writev`** **`SYS_ptrace`** **`SYS_pwrite64`** **`SYS_pwritev`** **`SYS_pwritev2`** **`SYS_quotactl`** **`SYS_quotactl_fd`** **`SYS_readahead`** **`SYS_readv`** **`SYS_reboot`** **`SYS_recvfrom`** **`SYS_recvmmsg`** **`SYS_recvmsg`** **`SYS_remap_file_pages`** **`SYS_removexattr`** **`SYS_renameat`** **`SYS_renameat2`** **`SYS_request_key`** **`SYS_restart_syscall`** **`SYS_rseq`** **`SYS_rt_sigpending`** **`SYS_rt_sigqueueinfo`** **`SYS_rt_sigreturn`** **`SYS_rt_sigsuspend`** **`SYS_rt_sigtimedwait`** **`SYS_rt_tgsigqueueinfo`** **`SYS_sched_get_priority_max`** **`SYS_sched_get_priority_min`** **`SYS_sched_getaffinity`** **`SYS_sched_getattr`** **`SYS_sched_getparam`** **`SYS_sched_getscheduler`** **`SYS_sched_rr_get_interval`** **`SYS_sched_setaffinity`** **`SYS_sched_setattr`** **`SYS_sched_setparam`** **`SYS_sched_setscheduler`** **`SYS_seccomp`** **`SYS_semctl`** **`SYS_semget`** **`SYS_semop`** **`SYS_semtimedop`** **`SYS_sendfile`** **`SYS_sendmmsg`** **`SYS_sendmsg`** **`SYS_sendto`** **`SYS_set_mempolicy`** **`SYS_set_mempolicy_home_node`** **`SYS_set_robust_list`** **`SYS_set_tid_address`** **`SYS_setdomainname`** **`SYS_setfsgid`** **`SYS_setfsuid`** **`SYS_setgid`** **`SYS_setgroups`** **`SYS_sethostname`** **`SYS_setitimer`** **`SYS_setns`** **`SYS_setpgid`** **`SYS_setpriority`** **`SYS_setregid`** **`SYS_setresgid`** **`SYS_setresuid`** **`SYS_setreuid`** **`SYS_setrlimit`** **`SYS_setsid`** **`SYS_settimeofday`** **`SYS_setuid`** **`SYS_setxattr`** **`SYS_shmat`** **`SYS_shmctl`** **`SYS_shmdt`** **`SYS_shmget`** **`SYS_shutdown`** **`SYS_sigaltstack`** **`SYS_socketpair`** **`SYS_splice`** **`SYS_statx`** **`SYS_swapoff`** **`SYS_swapon`** **`SYS_symlinkat`** **`SYS_sync`** **`SYS_sync_file_range`** **`SYS_syncfs`** **`SYS_sysinfo`** **`SYS_syslog`** **`SYS_tee`** **`SYS_timer_create`** **`SYS_timer_delete`** **`SYS_timer_getoverrun`** **`SYS_timer_gettime`** **`SYS_timer_settime`** **`SYS_times`** **`SYS_tkill`** **`SYS_truncate`** **`SYS_umask`** **`SYS_umount2`** **`SYS_uname`** **`SYS_unlinkat`** **`SYS_unshare`** **`SYS_userfaultfd`** **`SYS_utimensat`** **`SYS_vhangup`** **`SYS_vmsplice`** **`SYS_wait4`** **`SYS_waitid`** **`SYS_writev`**

### sys/time.h

**x86_64 / aarch64** — glibc の `<sys/time.h>` の公開名 24、不足 6、未記載 7

- 不足(default): **`adjtime`** **`futimes`** **`lutimes`**
- 不足(gnu): **`TIMESPEC_TO_TIMEVAL`** **`TIMEVAL_TO_TIMESPEC`** **`futimesat`**
- 取り込み不足: `sys/select.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__itimer_which_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `enum __itimer_which`
- ガード `__suseconds_t_defined` → `suseconds_t`: self
- ガード `__time_t_defined` → `time_t`: unguarded(<sys/time.h>, <aio.h>: ok; <aio.h>, <sys/time.h>: ok; <sys/time.h>, <fts.h>: ok; <fts.h>, <sys/time.h>: ok; <sys/time.h>, <ftw.h>: ok; <ftw.h>, <sys/time.h>: ok)
- ガード `__timeval_defined` → `struct timeval`: honoured(<sys/time.h>, <aio.h>: ok; <aio.h>, <sys/time.h>: ok; <sys/time.h>, <fts.h>: ok; <fts.h>, <sys/time.h>: ok; <sys/time.h>, <ftw.h>: ok; <ftw.h>, <sys/time.h>: ok)

### sys/timerfd.h

**x86_64 / aarch64** — glibc の `<sys/timerfd.h>` の公開名 7、不足 0、未記載 1

- 取り込み不足: `stddef.h`

### sys/types.h

**x86_64 / aarch64** — glibc の `<sys/types.h>` の公開名 62、不足 15、未記載 0

- 不足(posix): `pthread_attr_t` `pthread_barrier_t` `pthread_barrierattr_t` `pthread_cond_t` `pthread_condattr_t` `pthread_key_t` `pthread_mutex_t` `pthread_mutexattr_t` `pthread_once_t` `pthread_rwlock_t` `pthread_rwlockattr_t` `pthread_spinlock_t` `pthread_t` `union pthread_attr_t`
- 不足(default): `fsid_t`
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h`
- 予約名の型: `__atomic_wide_counter` `__fsid_t` `__once_flag` `__pthread_list_t` `__pthread_slist_t` `__sig_atomic_t` `__thrd_t` `__tss_t` `struct __pthread_cond_s` `struct __pthread_internal_list` `struct __pthread_internal_slist` `struct __pthread_mutex_s` `struct __pthread_rwlock_arch_t`
- ガード `__blkcnt_t_defined` → `blkcnt_t`: self
- ガード `__blksize_t_defined` → `blksize_t`: self
- ガード `__clock_t_defined` → `clock_t`: unguarded(<sys/types.h>, <aio.h>: ok; <aio.h>, <sys/types.h>: ok; <sys/types.h>, <fts.h>: ok; <fts.h>, <sys/types.h>: ok; <sys/types.h>, <ftw.h>: ok; <ftw.h>, <sys/types.h>: ok)
- ガード `__clockid_t_defined` → `clockid_t`: unguarded(<sys/types.h>, <aio.h>: ok; <aio.h>, <sys/types.h>: ok; <sys/types.h>, <fts.h>: ok; <fts.h>, <sys/types.h>: ok; <sys/types.h>, <ftw.h>: ok; <ftw.h>, <sys/types.h>: ok)
- ガード `__daddr_t_defined` → `daddr_t`: self
- ガード `__dev_t_defined` → `dev_t`: self
- ガード `__fsblkcnt_t_defined` → `fsblkcnt_t`: self
- ガード `__fsfilcnt_t_defined` → `fsfilcnt_t`: self
- ガード `__gid_t_defined` → `gid_t`: self
- ガード `__have_pthread_attr_t` → `union pthread_attr_t` `pthread_attr_t`: absent
- ガード `__id_t_defined` → `id_t`: self
- ガード `__ino64_t_defined` → `ino64_t`: self
- ガード `__ino_t_defined` → `ino_t`: self
- ガード `__key_t_defined` → `key_t`: self
- ガード `__mode_t_defined` → `mode_t`: self
- ガード `__nlink_t_defined` → `nlink_t`: self
- ガード `__off64_t_defined` → `off64_t`: self
- ガード `__off_t_defined` → `off_t`: self
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__ssize_t_defined` → `ssize_t`: self
- ガード `__suseconds_t_defined` → `suseconds_t`: self
- ガード `__time_t_defined` → `time_t`: unguarded(<sys/types.h>, <aio.h>: ok; <aio.h>, <sys/types.h>: ok; <sys/types.h>, <fts.h>: ok; <fts.h>, <sys/types.h>: ok; <sys/types.h>, <ftw.h>: ok; <ftw.h>, <sys/types.h>: ok)
- ガード `__timer_t_defined` → `timer_t`: unguarded(<sys/types.h>, <aio.h>: ok; <aio.h>, <sys/types.h>: ok; <sys/types.h>, <fts.h>: ok; <fts.h>, <sys/types.h>: ok; <sys/types.h>, <ftw.h>: ok; <ftw.h>, <sys/types.h>: ok)
- ガード `__u_char_defined` → `u_char`: self
- ガード `__uid_t_defined` → `uid_t`: self
- ガード `__useconds_t_defined` → `useconds_t`: self

### sys/uio.h

**x86_64 / aarch64** — glibc の `<sys/uio.h>` の公開名 19、不足 16、未記載 20

- 不足(iso): **`UIO_MAXIOV`**
- 不足(default): **`preadv`** **`pwritev`**
- 不足(gnu): **`RWF_APPEND`** **`RWF_DSYNC`** **`RWF_HIPRI`** **`RWF_NOWAIT`** **`RWF_SYNC`** **`preadv2`** **`preadv64`** **`preadv64v2`** **`process_vm_readv`** **`process_vm_writev`** **`pwritev2`** **`pwritev64`** **`pwritev64v2`**
- 取り込み不足: `endian.h` `stddef.h` `sys/select.h` `sys/types.h`
- ガード `__iovec_defined` → `struct iovec`: unguarded(<sys/uio.h>, <netdb.h>: ok; <netdb.h>, <sys/uio.h>: ok; <sys/uio.h>, <mqueue.h>: ok; <mqueue.h>, <sys/uio.h>: ok; <sys/uio.h>, <net/if.h>: ok; <net/if.h>, <sys/uio.h>: ok)

### sys/un.h

**x86_64 / aarch64** — glibc の `<sys/un.h>` の公開名 3、不足 1、未記載 4

- 不足(default): **`SUN_LEN`**
- 取り込み不足: `stddef.h` `string.h` `strings.h`

### sys/utsname.h

**x86_64 / aarch64** — glibc の `<sys/utsname.h>` の公開名 3、不足 1、未記載 1

- 不足(default): **`SYS_NMLN`**

### sys/wait.h

**x86_64** — glibc の `<sys/wait.h>` の公開名 31、不足 7、未記載 10

- 不足(default): **`WAIT_ANY`** **`WAIT_MYPGRP`** **`WCOREFLAG`** **`W_EXITCODE`** **`W_STOPCODE`** **`wait3`** **`wait4`**
- 取り込み不足: `stddef.h` `sys/ucontext.h` `unistd.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__id_t_defined` → `id_t`: self
- ガード `__idtype_t_defined` → `idtype_t`: unguarded(<sys/wait.h>, <wait.h>: ok; <wait.h>, <sys/wait.h>: ok)
- ガード `__pid_t_defined` → `pid_t`: self

**aarch64** — glibc の `<sys/wait.h>` の公開名 30、不足 7、未記載 16

- 不足(default): **`WAIT_ANY`** **`WAIT_MYPGRP`** **`WCOREFLAG`** **`W_EXITCODE`** **`W_STOPCODE`** **`wait3`** **`wait4`**
- 取り込み不足: `endian.h` `stddef.h` `sys/procfs.h` `sys/select.h` `sys/time.h` `sys/types.h` `sys/ucontext.h` `sys/user.h` `unistd.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__idtype_t_defined` → `idtype_t`: unguarded
- ガード `__pid_t_defined` → `pid_t`: self

### termios.h

**x86_64 / aarch64** — glibc の `<termios.h>` の公開名 160、不足 2、未記載 0

- 不足(default): `CCEQ` `TIOCSER_TEMT`
- 取り込み不足: `sys/ttydefaults.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__pid_t_defined` → `pid_t`: self

### time.h

**x86_64 / aarch64** — glibc の `<time.h>` の公開名 106、不足 63、未記載 64

- 不足(iso): **`timespec_get`**
- 不足(posix): **`CLOCK_BOOTTIME_ALARM`** **`CLOCK_REALTIME_ALARM`** **`CLOCK_TAI`** **`clock_getcpuclockid`** **`clock_nanosleep`** **`locale_t`** **`strftime_l`** **`timer_create`** **`timer_delete`** **`timer_getoverrun`** **`timer_gettime`** **`timer_settime`**
- 不足(xopen): **`getdate`** **`getdate_err`**
- 不足(default): **`dysize`**
- 不足(gnu): **`ADJ_ESTERROR`** **`ADJ_FREQUENCY`** **`ADJ_MAXERROR`** **`ADJ_MICRO`** **`ADJ_NANO`** **`ADJ_OFFSET`** **`ADJ_OFFSET_SINGLESHOT`** **`ADJ_OFFSET_SS_READ`** **`ADJ_SETOFFSET`** **`ADJ_STATUS`** **`ADJ_TAI`** **`ADJ_TICK`** **`ADJ_TIMECONST`** **`MOD_CLKA`** **`MOD_CLKB`** **`MOD_ESTERROR`** **`MOD_FREQUENCY`** **`MOD_MAXERROR`** **`MOD_MICRO`** **`MOD_NANO`** **`MOD_OFFSET`** **`MOD_STATUS`** **`MOD_TAI`** **`MOD_TIMECONST`** **`STA_CLK`** **`STA_CLOCKERR`** **`STA_DEL`** **`STA_FLL`** **`STA_FREQHOLD`** **`STA_INS`** **`STA_MODE`** **`STA_NANO`** **`STA_PLL`** **`STA_PPSERROR`** **`STA_PPSFREQ`** **`STA_PPSJITTER`** **`STA_PPSSIGNAL`** **`STA_PPSTIME`** **`STA_PPSWANDER`** **`STA_RONLY`** **`STA_UNSYNC`** **`clock_adjtime`** **`getdate_r`** **`strptime_l`** **`struct timeval`** **`struct timex`** **`timespec_getres`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__locale_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t` `struct __locale_struct`
- ガード `__clock_t_defined` → `clock_t`: unguarded(<time.h>, <aio.h>: ok; <aio.h>, <time.h>: ok; <time.h>, <fts.h>: ok; <fts.h>, <time.h>: ok; <time.h>, <ftw.h>: ok; <ftw.h>, <time.h>: ok)
- ガード `__clockid_t_defined` → `clockid_t`: unguarded(<time.h>, <aio.h>: ok; <aio.h>, <time.h>: ok; <time.h>, <fts.h>: ok; <fts.h>, <time.h>: ok; <time.h>, <ftw.h>: ok; <ftw.h>, <time.h>: ok)
- ガード `__itimerspec_defined` → `struct itimerspec`: unguarded(<time.h>, <threads.h>: ok; <threads.h>, <time.h>: ok; <time.h>, <thread_db.h>: thread_db.h:281:3: error: expected type specifier; <thread_db.h>, <time.h>: thread_db.h:281:3: error: expected type specifier)
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__struct_tm_defined` → `struct tm`: honoured(<time.h>, <threads.h>: ok; <threads.h>, <time.h>: ok; <time.h>, <thread_db.h>: thread_db.h:281:3: error: expected type specifier; <thread_db.h>, <time.h>: thread_db.h:281:3: error: expected type specifier)
- ガード `__time_t_defined` → `time_t`: unguarded(<time.h>, <aio.h>: ok; <aio.h>, <time.h>: ok; <time.h>, <fts.h>: ok; <fts.h>, <time.h>: ok; <time.h>, <ftw.h>: ok; <ftw.h>, <time.h>: ok)
- ガード `__timer_t_defined` → `timer_t`: unguarded(<time.h>, <aio.h>: ok; <aio.h>, <time.h>: ok; <time.h>, <fts.h>: ok; <fts.h>, <time.h>: ok; <time.h>, <ftw.h>: ok; <ftw.h>, <time.h>: ok)
- ガード `__timeval_defined` → `struct timeval`: absent

### unistd.h

**x86_64 / aarch64** — glibc の `<unistd.h>` の公開名 166、不足 90、未記載 91

- 不足(iso): **`execle`** **`getgroups`** **`getlogin`** **`getpgrp`** **`setpgid`** **`setsid`** **`tcgetpgrp`** **`tcsetpgrp`**
- 不足(posix): **`faccessat`** **`fchdir`** **`fchownat`** **`fexecve`** **`getlogin_r`** **`getpgid`** **`getsid`** **`lchown`** **`linkat`** **`readlinkat`** **`setegid`** **`seteuid`** **`symlinkat`** **`unlinkat`**
- 不足(xopen): **`F_LOCK`** **`F_TEST`** **`F_TLOCK`** **`F_ULOCK`** **`gethostid`** **`lockf`** **`nice`** **`setpgrp`** **`setregid`** **`setreuid`** **`socklen_t`** **`swab`** **`sync`**
- 不足(default): **`L_INCR`** **`L_SET`** **`L_XTND`** **`acct`** **`chroot`** **`closefrom`** **`crypt`** **`daemon`** **`endusershell`** **`getdomainname`** **`getdtablesize`** **`getentropy`** **`getpass`** **`getusershell`** **`getwd`** **`profil`** **`revoke`** **`setdomainname`** **`sethostid`** **`sethostname`** **`setlogin`** **`setusershell`** **`ttyslot`** **`ualarm`** **`vfork`** **`vhangup`**
- 不足(gnu): **`CLOSE_RANGE_CLOEXEC`** **`CLOSE_RANGE_UNSHARE`** **`SEEK_DATA`** **`SEEK_HOLE`** **`TEMP_FAILURE_RETRY`** **`close_range`** **`copy_file_range`** **`dup3`** **`eaccess`** **`environ`** **`euidaccess`** **`execveat`** **`execvpe`** **`ftruncate64`** **`get_current_dir_name`** **`getresgid`** **`getresuid`** **`gettid`** **`group_member`** **`lockf64`** **`lseek64`** **`off64_t`** **`pipe2`** **`pread64`** **`pwrite64`** **`setresgid`** **`setresuid`** **`syncfs`** **`truncate64`**
- 取り込み不足: `stddef.h`
- 予約名の型: `__blkcnt64_t` `__blkcnt_t` `__blksize_t` `__caddr_t` `__clock_t` `__clockid_t` `__daddr_t` `__dev_t` `__fsblkcnt64_t` `__fsblkcnt_t` `__fsfilcnt64_t` `__fsfilcnt_t` `__fsid_t` `__fsword_t` `__gid_t` `__id_t` `__ino64_t` `__ino_t` `__int16_t` `__int32_t` `__int64_t` `__int8_t` `__int_least16_t` `__int_least32_t` `__int_least64_t` `__int_least8_t` `__intmax_t` `__intptr_t` `__key_t` `__loff_t` `__mode_t` `__nlink_t` `__off64_t` `__off_t` `__pid_t` `__quad_t` `__rlim64_t` `__rlim_t` `__sig_atomic_t` `__socklen_t` `__ssize_t` `__suseconds64_t` `__suseconds_t` `__syscall_slong_t` `__syscall_ulong_t` `__time_t` `__timer_t` `__u_char` `__u_int` `__u_long` `__u_quad_t` `__u_short` `__uid_t` `__uint16_t` `__uint32_t` `__uint64_t` `__uint8_t` `__uint_least16_t` `__uint_least32_t` `__uint_least64_t` `__uint_least8_t` `__uintmax_t` `__useconds_t`
- ガード `__gid_t_defined` → `gid_t`: self
- ガード `__intptr_t_defined` → `intptr_t`: self
- ガード `__off64_t_defined` → `off64_t`: absent
- ガード `__off_t_defined` → `off_t`: self
- ガード `__pid_t_defined` → `pid_t`: self
- ガード `__socklen_t_defined` → `socklen_t`: absent
- ガード `__ssize_t_defined` → `ssize_t`: self
- ガード `__uid_t_defined` → `uid_t`: self
- ガード `__useconds_t_defined` → `useconds_t`: self

## glibc 本体のヘッダとの混在(x86-64)

`libc6-dev` の公開ヘッダのうち rubycc が同梱しない 186 本を、1 本ずつ `#define _GNU_SOURCE` のもとで含め、gcc と rubycc(既定の探索順 = 同梱が先、ホストの glibc が後)でコンパイルした。gcc が通し rubycc が落ちたもの23 本と、rubycc の最初のエラー。同梱ヘッダの抜けが **glibc 本体のヘッダの失敗**として現れる所(GAPS AM の `<spawn.h>`、AQ の `<net/if.h>`)を拾うための一覧で、原因が同梱ヘッダでないもの(rubycc 本体の未対応)も混ざる。

| ヘッダ | rubycc の最初のエラー |
|---|---|
| `arpa/nameser.h` | arpa/nameser.h:398:1: error: expected type specifier |
| `complex.h` | bits/cmathcalls.h:55:13: error: expected ';' |
| `error.h` | bits/error.h:40:53: error: implicit declaration of function '__builtin_va_arg_pack' |
| `glob.h` | glob.h:27:1: error: expected type specifier |
| `net/ethernet.h` | net/ethernet.h:29:1: error: expected type specifier |
| `net/if_arp.h` | net/if_arp.h:28:1: error: expected type specifier |
| `netatalk/at.h` | asm/swab.h:10:2: error: non-empty inline assembly is not supported |
| `netinet/in_systm.h` | netinet/in_systm.h:25:1: error: expected type specifier |
| `netinet/ip.h` | netinet/ip.h:114:18: error: duplicate member 'ip_v' |
| `netinet/ip_icmp.h` | netinet/ip_icmp.h:24:1: error: expected type specifier |
| `netipx/ipx.h` | netipx/ipx.h:25:1: error: expected type specifier |
| `obstack.h` | obstack.h:190:52: error: expected ';' |
| `stdbit.h` | stdbit.h:67:25: error: extra tokens at end of #if expression |
| `stdio_ext.h` | stdio_ext.h:42:1: error: expected type specifier |
| `sys/eventfd.h` | sys/eventfd.h:30:1: error: expected type specifier |
| `sys/fanotify.h` | sys/fanotify.h:25:1: error: expected type specifier |
| `sys/platform/x86.h` | bits/platform/features.h:37:3: error: non-empty inline assembly is not supported |
| `sys/poll.h` | sys/poll.h:55:5: error: expected ';' |
| `sys/rseq.h` | asm/swab.h:10:2: error: non-empty inline assembly is not supported |
| `sys/signalfd.h` | sys/signalfd.h:53:1: error: expected type specifier |
| `tgmath.h` | tgmath.h:795:1: error: "Unsupported compiler; you cannot use <tgmath.h>" |
| `thread_db.h` | thread_db.h:281:3: error: expected type specifier |
| `utmpx.h` | utmpx.h:26:1: error: expected type specifier |
