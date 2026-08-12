# 同梱ヘッダのライセンス整理

現在の `include/` は物理ファイル 81 本で、分類・配布物・由来をこの文書、ルート `NOTICE`、
`rubycc.gemspec` の三者で確認できる。

このドキュメントは監査可能な一次記録であり、各ヘッダ冒頭の provenance コメント・
ルート `NOTICE`・`rubycc.gemspec`・運用ルール(`CLAUDE.md` R11 派生の
「glibc 実物コピー禁止」)と整合する。

---

## 1. 結論(要約)

1. **rubycc 全体は MIT**(`LICENSE.txt`、Copyright (c) 2026 DATE Ken)。同梱する libc 互換
   ヘッダの一部は musl libc(MIT)を出発点にした派生を含むが、**musl と rubycc は
   どちらも MIT なのでライセンスの衝突はない**。
2. musl は公開ヘッダ(`include/*`・`arch/*/bits/*`)について、MIT が本来要求する
   **著作権表示・許諾表示の保持義務を明示的に免除**している(後述の omit 許可)。
   したがって rubycc が musl 由来ヘッダを同梱するにあたり、musl の表示を保持する
   **法的義務はない**。それでも rubycc は透明性と謝辞のため `NOTICE` に musl の
   著作権表示と MIT 全文を保持する(義務ではなく方針)。
3. glibc ABI への追従(型幅・構造体レイアウト・マクロ値を glibc x86-64 に合わせる改変)は
   **「glibc からの派生」を構成しない**。同梱ヘッダに glibc(LGPL)のソースは一切
   コピーしておらず、再現しているのは相互運用に必要な **ABI 事実(実測値)**のみで、
   事実は著作権の対象外だからである(§4)。
4. カーネル UAPI 由来のヘッダ(`errno.h`・`sys/stat.h`)も同じ論理で、Linux UAPI(GPL)の
   ソースコピーではなく、syscall ABI の数値・レイアウトを実測して再現したものである(§4)。
5. `NOTICE` を gem に同梱し、musl の著作権表示と MIT 全文を配布物に含める。ヘッダの
   provenance コメント、`NOTICE`、`rubycc.gemspec` は同じ由来方針に従う。

---

## 2. musl のライセンスと公開ヘッダの扱い

musl の `COPYRIGHT`(https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT)より、原文を引用する。

**(a) 全体のライセンス**:

> musl as a whole is licensed under the following standard MIT license

**(b) 公開ヘッダ・crt の表示義務の免除(omit 許可)**:

> permission is hereby granted for all public header files (include/* and
> arch/*/bits/*) and crt files intended to be linked into applications
> (crt/*, ldso/dlstart.c, and arch/*/crt_arch.h) to omit the copyright notice
> and permission notice otherwise required by the license

**(c) 「著作権性が薄い」主張の削除**:

現行の `COPYRIGHT` には、かつて存在した「対象ファイルの大部分は自明で著作権の
対象にならない(sufficiently trivial not to be subject to copyright)」という趣旨の文が
**削除された**旨が記されている:

> This file previously contained text expressing a belief that most of the files
> covered by the above exception were sufficiently trivial not to be subject to
> copyright \[…\] this text has been removed.

### 解釈

- rubycc が依拠するのは **(b) の omit 許可**である。musl 自身が公開ヘッダについて
  「著作権表示・許諾表示を省略してよい」と明示的に許可しているため、musl 由来ヘッダを
  出発点にした rubycc の同梱ヘッダは、musl の表示を保持しなくても MIT 条項に違反しない。
- **(c) により、「ヘッダは著作権性が薄いから自由に使える」という論法には依拠しない**。
  依拠は
  あくまで (b) の明示許可であり、これは triviality 主張より確実である。
- rubycc は omit 許可があってもなお `NOTICE` に musl の著作権表示と MIT 全文を保持する。
  これは義務の履行ではなく、由来を受領者に伝える方針(下流の再配布者が判断を
  行いやすくするため)。

---

## 3. 同梱ヘッダの由来台帳(81 本)

各ヘッダ冒頭の provenance コメントを棚卸しした結果。分類は次の 3 種:

- **freestanding** — ISO C §7 の自立ヘッダと、コンパイラが提供する互換スタブ。libc
  (musl/glibc)由来ではない。
- **musl-derived** — musl の宣言セット/形状を出発点にし、glibc の対象 arch(x86-64 / aarch64)ABI に合わせて改変。
- **clean-room** — 公開 ABI / ISO C 標準 / カーネル UAPI に対してゼロから記述。musl 由来ではない
  (一部は musl を「形状の参照」にしたが、テキストの派生はしていない)。

### 3.1 freestanding(10 本、`include/*.h`)

libc 由来ではない。musl・glibc いずれの派生でもない。

| ファイル | 根拠 |
|---|---|
| `include/float.h` | ISO C 7.7。float/double は IEEE754 で全機種共通、**`long double` は機種で分岐**(x86-64 = x87 80 ビット、aarch64 = IEEE binary128) |
| `include/iso646.h` | ISO C 7.9 |
| `include/stdalign.h` | ISO C 7.15(`_Alignof` へのマッピング) |
| `include/stdarg.h` | ISO C 7.16(`__builtin_va_*` へのマッピング) |
| `include/stdbool.h` | ISO C 7.18 |
| `include/stdckdint.h` | ISO C23 7.20(`__builtin_*_overflow` へのマッピング)|
| `include/stdatomic.h` | ISO C 7.17 の部分実装。`_Atomic` 型指定子と typedef、`atomic_init`/`ATOMIC_VAR_INIT`/`kill_dependency`、総称マクロ(load/store/exchange/compare_exchange/fetch_add/sub)を既存の `__atomic_*` 組み込みへマッピングする。**`fetch_or`/`_and`/`_xor`・`atomic_flag`・`atomic_is_lock_free` は提供しない**。`ATOMIC_*_LOCK_FREE` は、rubycc が操作を拒否する幅を 0 と答える安全側の値を使用する |
| `include/stddef.h` | ISO C 7.19(型は x86-64 SysV LP64 に固定) |
| `include/stdnoreturn.h` | ISO C 7.23 |
| `include/x86intrin.h` | 意図的な空スタブ(CRuby の config.h 対策) |

### 3.2 musl-derived(22 本)

musl の宣言セット/形状を出発点にし、glibc の対象 arch(x86-64 / aarch64)ABI に追従。
冒頭コメントに「Derived from musl's <…>」と明記。

| ファイル | glibc ABI 追従の内容 |
|---|---|
| `include/libc/alloca.h` | builtin マッピングのみ(arch 非依存) |
| `include/libc/arpa/inet.h` | 宣言セット。UAPI の不要な連鎖は省略 |
| `include/libc/math.h` | `FP_*` / `math_errhandling` を glibc 実測値に |
| `include/libc/stdio.h` | FILE 不透明型、`BUFSIZ`/`TMP_MAX` 等を glibc 実測値に |
| `include/libc/stdlib.h` | `div_t`/`ldiv_t`/`lldiv_t` の LP64 レイアウト、`RAND_MAX`/`EXIT_*` |
| `include/libc/string.h` | 純粋プロトタイプ(arch 非依存) |
| `include/libc/strings.h` | 純粋プロトタイプ(arch 非依存) |
| `include/libc/unistd.h` | ABI 型付き名の LP64 幅。`_SC_IOV_MAX` は 60 |
| `include/libc/glibc/x86_64/endian.h` | little-endian x86-64 に固定 |
| `include/libc/glibc/x86_64/inttypes.h` | 64bit/MAX/PTR/fast16+ の "l" 形(実測) |
| `include/libc/glibc/x86_64/stdint.h` | 幅を glibc x86-64 LP64 に固定(実測) |
| `include/libc/glibc/x86_64/sys/select.h` | `fd_set` を glibc x86-64 に固定 |
| `include/libc/glibc/x86_64/sys/time.h` | `struct timeval` メンバを glibc x86-64 に固定(実測) |
| `include/libc/glibc/x86_64/sys/types.h` | 全幅・符号を glibc x86-64 LP64 に固定(実測) |
| `include/libc/glibc/x86_64/time.h` | `time_t`=long、`struct tm` の tm_gmtoff/tm_zone 拡張(実測) |
| `include/libc/glibc/aarch64/endian.h` | little-endian aarch64 に固定(x86-64 版とバイト一致) |
| `include/libc/glibc/aarch64/inttypes.h` | LP64 の "l" 形(x86-64 版とバイト一致) |
| `include/libc/glibc/aarch64/stdint.h` | 幅を glibc aarch64 LP64 に固定。WCHAR_MIN/MAX は unsigned(0/UINT32_MAX)で x86-64 と相違(実測) |
| `include/libc/glibc/aarch64/sys/select.h` | `fd_set` を glibc aarch64 に固定(x86-64 版とバイト一致) |
| `include/libc/glibc/aarch64/sys/time.h` | `struct timeval` を glibc aarch64 に固定(x86-64 版とバイト一致) |
| `include/libc/glibc/aarch64/sys/types.h` | 全幅・符号を glibc aarch64 LP64 に固定。nlink_t/blksize_t=32bit で x86-64 と相違(実測) |
| `include/libc/glibc/aarch64/time.h` | `time_t`=long、`struct tm` 拡張(x86-64 版とバイト一致) |

### 3.3 clean-room(49 本)

musl のテキスト派生ではない。公開 ABI / ISO C / カーネル UAPI に対してゼロから記述。

| ファイル | 記述対象 | musl 参照 |
|---|---|---|
| `include/libc/assert.h` | 標準の assert イディオム。`__assert_fail` プロトタイプは glibc に一致(ホスト libc とリンクするため) | 形状のみ参照(テキスト派生なし) |
| `include/libc/features.h` | POSIX/glibc の feature-test プロトコル。`__USE_*` 集合と glibc バージョンマクロは実測 ABI | 形状のみ参照(テキスト派生なし) |
| `include/libc/sys/cdefs.h` | glibc の公開マクロ契約(挙動)。musl に対応物なし・glibc からのコピーもなし | なし |
| `include/libc/glibc/x86_64/ctype.h` | 公開 `_ISbit` 式とアクセサ signature から機構を再現(glibc からコピーせず、musl の 0/1 返しとも異なる) | なし |
| `include/libc/glibc/x86_64/limits.h` | ISO 規定値 + long/char 幅を glibc x86-64 LP64 に固定。char 符号性は `__CHAR_UNSIGNED__` で分岐 | なし(musl 非参照) |
| `include/libc/glibc/x86_64/errno.h` | **Linux/asm-generic UAPI の errno 値**を実測整数定数として再現(§4) | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/sys/stat.h` | **Linux x86-64 kernel ABI の struct stat レイアウト**(実測 144 バイト)と S_IF* 値(§4) | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/ctype.h` | x86-64 版と同一機構(バイト一致) | なし |
| `include/libc/locale.h` | ISO C11 7.11 の公開インタフェース(struct lconv のメンバ名・型・順序は7.11.1.1 が規定)。`LC_*` 値と struct lconv の対象 ABI レイアウトに対応する。setlocale/localeconv は POSIX/ISO C 宣言 | なし |
| `include/libc/glibc/x86_64/setjmp.h` | **jmp_buf/sigjmp_buf のサイズ/アライメント**(glibc ABI・200/8)。内部フィールドは不透明 blob とする。`sigsetjmp` は `__sigsetjmp` へのマクロとして扱う | なし(glibc ABI) |
| `include/libc/glibc/aarch64/setjmp.h` | 同上。jmp_buf/sigjmp_buf は 312/8 とする | なし(glibc ABI) |
| `include/libc/glibc/aarch64/limits.h` | ISO 値 + glibc aarch64 LP64 幅。char 符号性は `__CHAR_UNSIGNED__` で分岐(x86-64 版とバイト一致) | なし(musl 非参照) |
| `include/libc/glibc/aarch64/errno.h` | Linux/asm-generic UAPI の errno 値(aarch64 も x86-64 と同一値・§4) | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/sys/stat.h` | **Linux aarch64 kernel ABI の struct stat レイアウト**(実測 128 バイト・並び替え・nlink_t/blksize_t=32bit)と S_IF* 値(§4) | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/fcntl.h` | **Linux UAPI の O_*/F_*/AT_* 値と struct flock レイアウト**(実測・§4)。open/creat/fcntl は POSIX 宣言 | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/fcntl.h` | 同上。O_DIRECT/O_DIRECTORY/O_NOFOLLOW が x86-64 と入れ替わる(arch 別 uapi/asm/fcntl.h・実測) | なし(UAPI 由来) |
| `include/libc/poll.h` | **Linux UAPI の POLL* 値**(asm-generic/poll.h・実測・§4)。struct pollfd は POSIX 宣言。両 arch 同一値のため共通層 | なし(UAPI 由来) |
| `include/libc/dlfcn.h` | **glibc の動的リンク ABI(bits/dlfcn.h)の RTLD_* 値**を実測再現。dlopen/dlsym 等は POSIX 宣言でホスト libc から解決(kernel UAPI ではない)。両 arch 同一のため共通層 | なし(glibc ABI 実測) |
| `include/libc/sys/mman.h` | **Linux UAPI の PROT_/MAP_/MS_/MADV_ 値と MAP_FAILED**(asm-generic/mman・実測・§4)。mmap/munmap 等は POSIX 宣言。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/signal.h` | **シグナル番号・SA_ フラグと sigset_t/siginfo_t/struct sigaction のレイアウト**(kernel UAPI + glibc ABI・実測 offsetof・§4)。signal/kill/sigaction 等は POSIX 宣言。両 arch 同一のため共通層 | なし(UAPI+glibc ABI 実測) |
| `include/libc/sys/socket.h` | **AF_/SOCK_/SO_/MSG_ 値と sockaddr/sockaddr_storage/msghdr/iovec 等のレイアウト**(kernel UAPI + glibc ABI・§4)。socket/bind/connect 等は POSIX 宣言。`AF_NETLINK`/`PF_NETLINK`(値 16)と Linux 拡張 `accept4` の宣言を含む。両 arch 同一のため共通層 | なし(UAPI+glibc ABI) |
| `include/libc/netinet/in.h` | **IPPROTO_/INADDR_ 値と sockaddr_in/in6・in6_addr のレイアウト**(kernel UAPI linux/in.h+in6.h・§4)。arpa/inet.h/sys/socket.h と共有ガードで共存する。`INET_ADDRSTRLEN`/`INET6_ADDRSTRLEN`(16/46)と、libc の実オブジェクトである `in6addr_any`/`in6addr_loopback` の extern 宣言を含む。両 arch 同一のため共通層 | なし(UAPI+glibc ABI) |
| `include/libc/netinet/tcp.h` | **TCP_ ソケットオプション名**(kernel UAPI linux/tcp.h)。TCP 状態機械の 11 状態(`TCP_ESTABLISHED` 1 〜 `TCP_CLOSING` 11)を含む。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/sys/un.h` | **struct sockaddr_un の 110 バイトレイアウト**(kernel UAPI linux/un.h・実測 offsetof・§4)。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/pthread.h` | **pthreads opaque 型のサイズ/アライメント**(glibc ABI・実測。内部フィールドは不再現の不透明 blob・§4)。pthread_* は POSIX 宣言 | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/pthread.h` | 同上。mutex_t/attr_t/mutexattr_t/condattr_t が x86-64 より広い(実測。arch 依存ゆえ 2 本) | なし(glibc ABI 実測) |
| `include/libc/pwd.h` | **POSIX の struct passwd**(メンバ名・型・順序は公開契約)。LP64 の対象 ABI レイアウトに対応する。getpwnam/getpwuid/getpwent/setpwent/endpwent/getpwnam_r/getpwuid_r は POSIX 宣言 | なし |
| `include/libc/grp.h` | **POSIX の struct group**。対象 ABI レイアウトに対応する。getgrnam/getgrgid/getgrent/setgrent/endgrent/getgrnam_r/getgrgid_r は POSIX 宣言 | なし |
| `include/libc/sys/utsname.h` | **Linux kernel ABI の struct utsname**。6 個の 65 バイト char 配列を含む 390 バイトのレイアウトに対応する。uname は POSIX 宣言 | なし(kernel ABI) |
| `include/libc/sys/uio.h` | **POSIX/kernel UAPI の struct iovec**。`_RUBYCC_STRUCT_IOVEC` ガードを共有し、readv/writev を宣言する | なし(UAPI 由来) |
| `include/libc/sys/resource.h` | **POSIX/kernel UAPI の struct rlimit・struct rusage と RLIMIT_*/RUSAGE_* 値**。struct timeval は sys/time.h と共通のガードを使用する。getrlimit/setrlimit/getrusage は POSIX 宣言 | なし(UAPI 由来) |
| `include/libc/dirent.h` | **glibc/Linux ABI の struct dirent**。DIR は不完全型 `struct __dirstream` とし、struct dirent の対象 ABI レイアウトに対応する。opendir/readdir/closedir/rewinddir/readdir_r/fdopendir/dirfd は POSIX 宣言 | なし(glibc/UAPI) |
| `include/libc/sched.h` | **glibc の cpu_set_t**。128/8 の不透明 blob と CPU_SETSIZE を提供する。sched_yield/sched_getcpu の宣言に対応し、CPU_SET 等のアフィニティ操作マクロ群は対象外 | なし(glibc ABI) |
| `include/libc/termios.h` | **glibc/Linux ABI の struct termios**。NCCS=32 の `c_cc` 配列を含む 60 バイトのレイアウト、主要フラグ定数・V* 添字・B* ボーレート値を提供する。tcgetattr/tcsetattr/tcflush/tcdrain/tcsendbreak/cfgetispeed/cfsetispeed/cfgetospeed/cfsetospeed を宣言する。cfmakeraw は対象外 | なし(glibc/UAPI 実測) |
| `include/libc/sys/ioctl.h` | **struct winsize の 8 バイトレイアウト**と TIOCGWINSZ/TIOCSWINSZ の値を提供する。ioctl は Linux/glibc 宣言。 | なし(glibc/UAPI 実測) |
| `include/libc/sys/param.h` | glibc 互換シムとして MIN/MAX/howmany/roundup の 4 マクロを提供する。BSD 名エイリアス、ビットマップ操作マクロは対象外 | なし(glibc ABI 実測) |
| `include/libc/glibc/x86_64/fcntl.h` の隣に置く `sys/fcntl.h`(x86-64) | `#include <fcntl.h>` のみの 1 行シム。fcntl.h と同じ arch 層に置く | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/fcntl.h` の隣に置く `sys/fcntl.h`(aarch64) | x86-64 版と同じ 1 行シム | なし(glibc ABI 実測) |
| `include/libc/sys/wait.h` | waitpid/waitid のオプション定数・`idtype_t`・`CLD_*`、wait ステータスの符号化と WIF*/WEXITSTATUS/WTERMSIG/WSTOPSIG/WCOREDUMP 等のマクロを提供する。`siginfo_t` は `<signal.h>` から得る。wait/waitpid/waitid を宣言する | なし(kernel ABI 実測) |
| `include/libc/glibc/x86_64/sys/epoll.h` | Linux UAPI の epoll 定数と `struct epoll_event` を提供する。x86-64 は packed の 12 バイト・align 1・data@4 | なし(UAPI 実測) |
| `include/libc/glibc/aarch64/sys/epoll.h` | Linux UAPI の epoll 定数と `struct epoll_event` を提供する。aarch64 は自然レイアウトの 16 バイト・align 8・data@8 | なし(UAPI 実測) |
| `include/libc/langinfo.h` | glibc の `nl_item` 番号とカテゴリ・インデックスの合成規則、`nl_langinfo` の宣言を提供する | なし(glibc ABI 実測) |
| `include/libc/sys/timerfd.h` | Linux UAPI の TFD_* 値と timerfd_create/settime/gettime の宣言を提供する。`struct itimerspec` は `<time.h>` の定義を使用する | なし(UAPI 実測) |
| `include/libc/sys/inotify.h` | Linux UAPI の IN_* 値と、16 バイトのヘッダ部を持つ `struct inotify_event`、inotify_init/init1/add_watch/rm_watch の宣言を提供する | なし(UAPI 実測) |
| `include/libc/sys/statfs.h` | Linux statfs(2) の 120 バイト・align 8 の `struct statfs` と statfs/fstatfs の宣言を提供する。対象 LP64 arch で同じレイアウトを使用する | なし(UAPI/glibc ABI 実測) |
| `include/libc/glibc/x86_64/sys/syscall.h` | Linux x86-64 の対象システムコール番号を `SYS_*`/`__NR_*` として提供する。nio4r/libev の使用範囲と代表的な中核呼び出しに限定し、`syscall()` は宣言しない | なし(kernel ABI 実測) |
| `include/libc/glibc/aarch64/sys/syscall.h` | Linux aarch64 の対象システムコール番号を提供する。x86-64 版と名前集合は同じで番号が異なる。`syscall()` は宣言しない | なし(kernel ABI 実測) |

| `include/libc/link.h` | `struct link_map` の先頭フィールドを glibc の動的リンク ABI の実測値で再現。`dlinfo(RTLD_DI_LINKMAP)` の linker-map 取得に必要な範囲に限定 | なし(glibc ABI 実測) |
| `include/libc/regex.h` | `regex_t`/`regmatch_t` の glibc-compatible なサイズ・アライメント・メンバ配置を実測して再現。C 拡張の値埋め込みに必要な ABI のみで、POSIX regex の実装は含めない | なし(glibc ABI 実測) |

> `assert.h` と `features.h` は自己申告で clean-room だが、冒頭コメントに
> 「musl's <…> was the shape reference」とある。**形状(どの宣言を並べるか)の参照**で
> あって、musl のテキストを写したものではない。仮に musl 由来と厳格に見なしても、
> §2 (b) の omit 許可により表示義務は生じないため、いずれの解釈でも配布上の追加義務はない。

### 3.4 集計
| 分類 | 本数 |
|---|---|
| freestanding | 10 |
| musl-derived | 22 |
| clean-room | 49 |
| **合計** | **81** |
この分類は現在の `include/` の物理ファイルと各ヘッダ冒頭の provenance コメントに
対応する。arch 層のファイルは物理ファイルとして数え、census で同一の
angle-bracket spelling に正規化されるものも個別に管理する。

---

## 4. glibc ABI 追従・UAPI 参照が「派生」を構成しないことの整理

### 4.1 何をコピーしていないか

- 同梱ヘッダに **glibc のソース(LGPL)は一切コピーしていない**。マクロ本体・inline 関数・
  内部識別子・コメントなど、glibc のヘッダに固有の**表現**は再現していない。
- 同様に、**Linux カーネル UAPI ヘッダ(GPL)のソースもコピーしていない**。

### 4.2 何を再現しているか

再現しているのは、相互運用に必要な **ABI 事実**のみ:

- 型の幅と符号(`sizeof` / signedness)
- 構造体・共用体のメンバ順序とオフセット(`offsetof`)、整列(`_Alignof`)、総サイズ
- マクロが展開する数値(`BUFSIZ`、`RAND_MAX`、errno 値、`S_IF*` 等)

これらは**リファレンスプラットフォーム(glibc x86-64)でリファレンスコンパイラに印字させて
実測した数値**であり、rubycc が生成するコードがホスト libc / カーネルと正しく相互運用する
ために**一意に決まる**値である(別の値を選ぶ自由はない)。

### 4.3 なぜ著作物のコピーにならないか

- ABI 事実は、著作権が保護しない **アイデア・手続き・方法・事実**の側にある
  (米国 17 U.S.C. §102(b);事実性・相互運用性の観点)。ある型が 8 バイトであること、
  `struct stat` が 144 バイトであることは、著作者の創作的表現ではなく、
  プラットフォームが定めた**事実**である。
- したがって、この事実に合わせるための改変は「glibc からの派生」でも
  「カーネル UAPI からの派生」でもない。再現の**手段**(どの宣言をどう書くか)は
  §3 の分類(musl 由来 or clean-room)に従い、そちらのライセンス整理でカバーされる。

### 4.4 運用ルール(再確認)

- `CLAUDE.md` R11 の派生ルール「**glibc 実物のコピー禁止**」は維持する。ABI 値は
  リファレンス環境からの**実測**でのみ取得し、glibc ヘッダのテキストを写経しない。
- カーネル UAPI についても同様に、値・レイアウトの**実測**のみで、`uapi/*` ヘッダの
  テキストを写経しない。

---

## 5. gem 配布物での履行

### 5.1 gemspec への NOTICE 同梱

`rubycc.gemspec` の `spec.files` は `lib/**/*.rb`・`include/**/*.h`・`exe/*`・
`data/*` と `LICENSE.txt`・`NOTICE`・`README.md`・`CHANGELOG.md` を同梱する。
`NOTICE` には musl の謝辞・MIT 全文が含まれる。`HEADER-LICENSING.md` 自体は監査用の
リポジトリ文書で、gem には含めず、`README.md` と `NOTICE` から参照する。

### 5.2 ライセンス表記の整合

- `spec.license = "MIT"` は rubycc 全体の MIT と一致。musl 由来部分も MIT なので矛盾しない。
- `LICENSE.txt` は rubycc 自身の MIT。musl の著作権表示と MIT 全文は `NOTICE` にある。
  両者の分担(自作 = LICENSE.txt、同梱物の由来 = NOTICE)は明確。

---

## 6. ヘッダ追加ワークフロー

libc 互換ヘッダを追加・変更するときは、由来の記録と NOTICE の整合を保つため、
次を必須手順とする:

1. **冒頭 provenance コメントを必ず書く**。§3 の 3 分類のどれかを明示する:
   - freestanding / musl-derived / clean-room のいずれか。
   - musl-derived の場合は「Derived from musl's <…>」、glibc ABI 追従があればその内容。
   - clean-room の場合は記述対象(ISO C / 公開 ABI / カーネル UAPI)と、musl を形状参照した
     なら「musl's <…> was the shape reference(テキスト派生なし)」と明記。
2. **ABI 値は実測でのみ取得**。glibc / カーネル UAPI のヘッダテキストを写経しない
   (§4.4、R11)。実測手順(sizeof/_Alignof/offsetof・マクロ値をリファレンスコンパイラで印字)を
   踏む。
3. **この台帳(§3)を更新**する。新規ヘッダを該当分類の表に 1 行追加し、§3.4 の集計を更新。
4. **NOTICE の見直し**。musl 以外の新しい由来(将来、別の MIT/BSD ライブラリを形状参照
   する等)が入る場合は、その謝辞を `NOTICE` に追記する。musl の omit 許可は musl 固有で
   あり、他ライブラリには及ばない点に注意。
5. **疑義があればクリーンルームで書き直す**。由来が曖昧・混在するヘッダは、公開 ABI /
   標準に対してゼロから書き直して clean-room に寄せる(§3.3 の `sys/cdefs.h` が先例)。

---

## 参考

- musl `COPYRIGHT`: https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT
- 同梱ヘッダの設計方針: `docs/development/DESIGN.md`
- 派生禁止ルール(R11): `CLAUDE.md`
- gem 配布物の謝辞: リポジトリルート `NOTICE`
