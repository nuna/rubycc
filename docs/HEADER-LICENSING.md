# 同梱ヘッダのライセンス整理(H0)

**位置づけ**: M4 完了後・M5(互換ヘッダの大量拡充)着手前の必須ゲート(ユーザ指示、
2026-07-19)。M5 で `include/libc/` 配下のヘッダが大きく広がる前に、musl からの派生・
glibc ABI への追従・カーネル UAPI の扱いについてライセンス上の体制を確定させ、以後の
ヘッダ追加をワークフロー化する。

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
5. **是正した点(このゲートで実施)**: (a) `rubycc.gemspec` の `spec.files` に `NOTICE` が
   含まれておらず、gem パッケージ受領者に musl の謝辞が届かなかった → 追加した。
   (b) 由来分類が冒頭コメントに欠けていた 2 本(`errno.h`・`sys/stat.h`)に UAPI 由来である
   旨を明記した。(c) `NOTICE` 本文を、削除済みの musl「triviality」主張ではなく現行の
   omit 許可に依拠する記述へ更新した。

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
- **(c) により、「ヘッダは著作権性が薄いから自由に使える」という論法には依拠しない**
  (ROADMAP H0 論点 1 が前提にしていた musl の旧文言は現在削除済み)。依拠は
  あくまで (b) の明示許可であり、これは triviality 主張より確実である。
- rubycc は omit 許可があってもなお `NOTICE` に musl の著作権表示と MIT 全文を保持する。
  これは義務の履行ではなく、由来を受領者に伝える方針(下流の再配布者が判断を
  行いやすくするため)。

---

## 3. 同梱ヘッダの由来台帳(77 本)

各ヘッダ冒頭の provenance コメントを棚卸しした結果。分類は次の 4 種:

- **freestanding** — ISO C §7 が規定する自立ヘッダ。コンパイラが提供すべきもので、
  libc(musl/glibc)由来ではない。
- **musl-derived** — musl の宣言セット/形状を出発点にし、glibc の対象 arch(x86-64 / aarch64)ABI に合わせて改変。
- **clean-room** — 公開 ABI / ISO C 標準 / カーネル UAPI に対してゼロから記述。musl 由来ではない
  (一部は musl を「形状の参照」にしたが、テキストの派生はしていない)。

### 3.1 freestanding(9 本、`include/*.h`)

libc 由来ではない。musl・glibc いずれの派生でもない。

| ファイル | 根拠 |
|---|---|
| `include/float.h` | ISO C 7.7(x86-64 の IEEE754/x87 一般値) |
| `include/iso646.h` | ISO C 7.9 |
| `include/stdalign.h` | ISO C 7.15(`_Alignof` へのマッピング) |
| `include/stdarg.h` | ISO C 7.16(`__builtin_va_*` へのマッピング) |
| `include/stdbool.h` | ISO C 7.18 |
| `include/stdckdint.h` | ISO C23 7.20(`__builtin_*_overflow` へのマッピング)|
| `include/stddef.h` | ISO C 7.19(型は x86-64 SysV LP64 に固定) |
| `include/stdnoreturn.h` | ISO C 7.23 |
| `include/x86intrin.h` | 意図的な空スタブ(CRuby の config.h 対策) |

### 3.2 musl-derived(22 本)

musl の宣言セット/形状を出発点にし、glibc の対象 arch(x86-64 / aarch64)ABI に追従。
冒頭コメントに「Derived from musl's <…>」と明記。

| ファイル | glibc ABI 追従の内容 |
|---|---|
| `include/libc/alloca.h` | builtin マッピングのみ(arch 非依存) |
| `include/libc/arpa/inet.h` | 宣言セット(Step 64 の実測駆動で UAPI 連鎖を省略) |
| `include/libc/math.h` | `FP_*` / `math_errhandling` を glibc 実測値に |
| `include/libc/stdio.h` | FILE 不透明型、`BUFSIZ`/`TMP_MAX` 等を glibc 実測値に |
| `include/libc/stdlib.h` | `div_t`/`ldiv_t`/`lldiv_t` の LP64 レイアウト、`RAND_MAX`/`EXIT_*` |
| `include/libc/string.h` | 純粋プロトタイプ(arch 非依存) |
| `include/libc/strings.h` | 純粋プロトタイプ(arch 非依存) |
| `include/libc/unistd.h` | ABI 型付き名の LP64 幅 |
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

### 3.3 clean-room(47 本)

musl のテキスト派生ではない。公開 ABI / ISO C / カーネル UAPI に対してゼロから記述。

| ファイル | 記述対象 | musl 参照 |
|---|---|---|
| `include/libc/assert.h` | 標準の assert イディオム。`__assert_fail` プロトタイプは glibc に一致(ホスト libc とリンクするため) | 形状のみ参照(テキスト派生なし) |
| `include/libc/features.h` | POSIX/glibc の feature-test プロトコル。`__USE_*` 集合と glibc バージョンマクロは実測 ABI | 形状のみ参照(テキスト派生なし) |
| `include/libc/sys/cdefs.h` | glibc の公開マクロ契約(挙動)。musl に対応物なし・glibc からのコピーもなし | なし |
| `include/libc/glibc/x86_64/ctype.h` | 公開 `_ISbit` 式とアクセサ signature から機構を再現(glibc からコピーせず、musl の 0/1 返しとも異なる) | なし |
| `include/libc/glibc/x86_64/limits.h` | ISO 規定値 + long/char 幅を glibc x86-64 LP64 に固定。char 符号性は `__CHAR_UNSIGNED__` で分岐(Step 73) | なし(musl 非参照) |
| `include/libc/glibc/x86_64/errno.h` | **Linux/asm-generic UAPI の errno 値**を実測整数定数として再現(§4) | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/sys/stat.h` | **Linux x86-64 kernel ABI の struct stat レイアウト**(実測 144 バイト)と S_IF* 値(§4) | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/ctype.h` | x86-64 版と同一機構(バイト一致) | なし |
| `include/libc/locale.h` | ISO C11 7.11 の公開インタフェース(struct lconv のメンバ名・型・順序は7.11.1.1 が規定)。`LC_*` 値と struct lconv のサイズ/全オフセットは**実測**(両アーキ一致)。setlocale/localeconv は POSIX/ISO C 宣言(Step 122) | なし |
| `include/libc/glibc/x86_64/setjmp.h` | **jmp_buf/sigjmp_buf のサイズ/アライメント**(glibc ABI・実測 200/8。内部フィールドは不再現の不透明 blob・§4)。`sigsetjmp` は glibc に実シンボルが無く `__sigsetjmp` へのマクロという相互運用上の事実を実測(`nm -D`)して再現(Step 122) | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/setjmp.h` | 同上。jmp_buf/sigjmp_buf は実測 312/8(クロス gcc + qemu で計測。arch 依存ゆえ 2 本)(Step 122) | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/limits.h` | ISO 値 + glibc aarch64 LP64 幅。char 符号性は `__CHAR_UNSIGNED__` で分岐(x86-64 版とバイト一致) | なし(musl 非参照) |
| `include/libc/glibc/aarch64/errno.h` | Linux/asm-generic UAPI の errno 値(aarch64 も x86-64 と同一値・§4) | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/sys/stat.h` | **Linux aarch64 kernel ABI の struct stat レイアウト**(実測 128 バイト・並び替え・nlink_t/blksize_t=32bit)と S_IF* 値(§4) | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/fcntl.h` | **Linux UAPI の O_*/F_*/AT_* 値と struct flock レイアウト**(実測・§4)。open/creat/fcntl は POSIX 宣言 | なし(UAPI 由来) |
| `include/libc/glibc/aarch64/fcntl.h` | 同上。O_DIRECT/O_DIRECTORY/O_NOFOLLOW が x86-64 と入れ替わる(arch 別 uapi/asm/fcntl.h・実測) | なし(UAPI 由来) |
| `include/libc/poll.h` | **Linux UAPI の POLL* 値**(asm-generic/poll.h・実測・§4)。struct pollfd は POSIX 宣言。両 arch 同一値のため共通層 | なし(UAPI 由来) |
| `include/libc/dlfcn.h` | **glibc の動的リンク ABI(bits/dlfcn.h)の RTLD_* 値**を実測再現。dlopen/dlsym 等は POSIX 宣言でホスト libc から解決(kernel UAPI ではない)。両 arch 同一のため共通層 | なし(glibc ABI 実測) |
| `include/libc/sys/mman.h` | **Linux UAPI の PROT_/MAP_/MS_/MADV_ 値と MAP_FAILED**(asm-generic/mman・実測・§4)。mmap/munmap 等は POSIX 宣言。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/signal.h` | **シグナル番号・SA_ フラグと sigset_t/siginfo_t/struct sigaction のレイアウト**(kernel UAPI + glibc ABI・実測 offsetof・§4)。signal/kill/sigaction 等は POSIX 宣言。両 arch 同一のため共通層 | なし(UAPI+glibc ABI 実測) |
| `include/libc/sys/socket.h` | **AF_/SOCK_/SO_/MSG_ 値と sockaddr/sockaddr_storage/msghdr/iovec 等のレイアウト**(kernel UAPI + glibc ABI・実測 offsetof・§4)。socket/bind/connect 等は POSIX 宣言。両 arch 同一のため共通層 | なし(UAPI+glibc ABI 実測) |
| `include/libc/netinet/in.h` | **IPPROTO_/INADDR_ 値と sockaddr_in/in6・in6_addr のレイアウト**(kernel UAPI linux/in.h+in6.h・実測 offsetof・§4)。arpa/inet.h/sys/socket.h と共有ガードで共存。両 arch 同一のため共通層 | なし(UAPI+glibc ABI 実測) |
| `include/libc/netinet/tcp.h` | **TCP_ ソケットオプション名**(kernel UAPI linux/tcp.h・実測・§4)。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/sys/un.h` | **struct sockaddr_un の 110 バイトレイアウト**(kernel UAPI linux/un.h・実測 offsetof・§4)。両 arch 同一のため共通層 | なし(UAPI 由来) |
| `include/libc/glibc/x86_64/pthread.h` | **pthreads opaque 型のサイズ/アライメント**(glibc ABI・実測。内部フィールドは不再現の不透明 blob・§4)。pthread_* は POSIX 宣言 | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/pthread.h` | 同上。mutex_t/attr_t/mutexattr_t/condattr_t が x86-64 より広い(実測。arch 依存ゆえ 2 本) | なし(glibc ABI 実測) |
| `include/libc/pwd.h` | **POSIX の struct passwd**(メンバ名・型・順序は公開契約)。サイズ/全オフセットを実測し両アーキ一致(uid_t/gid_t は LP64 で幅差なし)のため共通層。getpwnam/getpwuid/getpwent/setpwent/endpwent/getpwnam_r/getpwuid_r は POSIX 宣言(Step 123) | なし |
| `include/libc/grp.h` | **POSIX の struct group**。サイズ/全オフセットを実測し両アーキ一致のため共通層。getgrnam/getgrgid/getgrent/setgrent/endgrent/getgrnam_r/getgrgid_r は POSIX 宣言(Step 123) | なし |
| `include/libc/sys/utsname.h` | **Linux kernel ABI の struct utsname**(uname(2) が返す 6 個の 65 バイト char 配列。6 個目の domainname は kernel が追加した NIS ドメイン名で、glibc は `__USE_GNU` の有無でこの名前を出し分けるだけの同一フィールド)。実測 390 バイト・全オフセット一致(両アーキ)のため共通層。uname は POSIX 宣言(Step 123) | なし(kernel ABI 実測) |
| `include/libc/sys/uio.h` | **POSIX/kernel UAPI の struct iovec**。sys/socket.h と同じ `_RUBYCC_STRUCT_IOVEC` ガードを共有。実測 16 バイトで両アーキ一致のため共通層。readv/writev は POSIX 宣言(Step 123) | なし(UAPI 由来) |
| `include/libc/sys/resource.h` | **POSIX/kernel UAPI の struct rlimit・struct rusage と RLIMIT_*/RUSAGE_* 値**。struct timeval は sys/time.h と同じ `__timeval_defined` ガードを共有。全メンバのサイズ・オフセットを実測し両アーキ一致(rlim_t/struct timeval のメンバは LP64 で幅差なし)のため共通層。getrlimit/setrlimit/getrusage は POSIX 宣言(Step 123) | なし(UAPI 由来) |
| `include/libc/dirent.h` | **glibc/Linux ABI の struct dirent**(d_reclen/d_type が d_name の前に来る並びは glibc/Linux 固有で POSIX 非規定・実測が唯一の根拠)。DIR は glibc 自身も公開ヘッダで定義を与えない不完全型 `struct __dirstream` のまま(値そのものを持たず常にポインタ経由のため実体不要)。struct dirent は実測 280 バイトで両アーキ一致のため共通層。opendir/readdir/closedir/rewinddir/readdir_r/fdopendir/dirfd は POSIX 宣言(Step 123) | なし(glibc/UAPI 実測) |
| `include/libc/sched.h` | **glibc の cpu_set_t の実測サイズ/アライメント**(128/8。内部の `__bits` 配列は不再現の不透明 blob・§4、setjmp.h/pthread.h と同じ扱い)と CPU_SETSIZE。両アーキ一致のため共通層。センサスが挙げた etc/google-protobuf の実使用範囲(sched_yield/sched_getcpu)にスコープを絞り、CPU_SET 等のアフィニティ操作マクロ群は対象外(Step 123) | なし(glibc ABI 実測) |
| `include/libc/termios.h` | **glibc/Linux ABI の struct termios**(NCCS=32 の `c_cc` 配列を含め実測 60 バイト、全メンバのオフセット・両アーキ一致のため共通層)と主要フラグ定数・V* 添字・B* ボーレート値(実測)。io-console の corpus サンプルが実際に到達する HAVE_TERMIOS_H 経路にスコープを絞り、tcgetattr/tcsetattr/tcflush/tcdrain/tcsendbreak/cfgetispeed/cfsetispeed/cfgetospeed/cfsetospeed は POSIX 宣言(Step 124)。cfmakeraw(BSD/GNU 拡張、数値サーフェスなし)は io-console の実ビルドで露出したギャップとして Step 167 で追加 | なし(glibc/UAPI 実測) |
| `include/libc/sys/ioctl.h` | **struct winsize のレイアウト**(実測 8 バイト・全オフセット両アーキ一致)と TIOCGWINSZ/TIOCSWINSZ の値(kernel UAPI・実測)。io-console の corpus サンプルが実際に発行する ioctl リクエストにスコープを絞り、ioctl は POSIX 非規定の glibc/Linux 宣言(Step 124) | なし(glibc/UAPI 実測) |
| `include/libc/sys/param.h` | **glibc の互換シムとしての実体を実測で確認**した上で、MIN/MAX/howmany/roundup の 4 マクロのみを rubycc 自身の式で再現(値は同一だが glibc のテキストは写経せず)。digest の corpus サンプルはこのヘッダに実際には到達しない(`#include <sys/param.h>` が `_KERNEL`/`_STANDALONE` ゲート内で常に unreachable)ことも実測で確認(Step 124) | なし(glibc ABI 実測) |
| `include/libc/glibc/x86_64/fcntl.h` の隣に置く `sys/fcntl.h`(x86-64) | **glibc の `sys/fcntl.h` が `#include <fcntl.h>` のみの 1 行シム**であることをホストヘッダで実測確認し、同じ 1 行を再現。fcntl.h 自身と同じ理由(O_DIRECT 系のアーキ差)で fcntl.h の隣に配置(Step 124) | なし(glibc ABI 実測) |
| `include/libc/glibc/aarch64/fcntl.h` の隣に置く `sys/fcntl.h`(aarch64) | 同上。x86-64 版とバイト一致(Step 124) | なし(glibc ABI 実測) |
| `include/libc/sys/wait.h` | **waitpid/waitid のオプション定数・`idtype_t` の列挙値・SIGCHLD の `CLD_*` si_code**(実測、両アーキ一致)と、**wait ステータスの符号化**。`WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/`WTERMSIG`/`WIFSTOPPED`/`WSTOPSIG`/`WIFCONTINUED`/`WCOREDUMP` は glibc のマクロ本体を写経せず、観測した符号化(下位 7 bit=終了シグナル、bit 7=コアダンプ、bit 8〜15=終了コード、0xffff=continued)から rubycc 自身の式として書き直し、**全 2^32 個の int ステータス値**について glibc オラクルの戻り値と厳密一致(非ブールの `WCOREDUMP` が返す 0x80 も含む)することを x86-64・aarch64 の両方で実測確認した。`siginfo_t` は `waitid` の第 3 引数のため `#include <signal.h>` で得る(glibc が同じ位置で bits/types/siginfo_t.h を読むのに対応)。両アーキ一致のため共通層。wait/waitpid/waitid は POSIX 宣言(Step 135) | なし(kernel ABI 実測) |
| `include/libc/glibc/x86_64/sys/epoll.h` | **Linux UAPI(linux/eventpoll.h)の `EPOLL_CTL_*`/イベントビット/`EPOLL_CLOEXEC` 値と `struct epoll_event` のレイアウト**(実測)。x86-64 では 32bit プロセスと配列ストライドを揃えるため構造体が **packed**(実測 12 バイト・_Alignof 1・data はオフセット 4)で、aarch64 の自然レイアウト(16/8/8)と食い違うため **arch 層に 2 本**置く(fcntl.h/pthread.h/setjmp.h/sys/stat.h と同じ扱い)。マクロ値はすべて両アーキ一致。epoll_create/epoll_create1/epoll_ctl/epoll_wait は Linux/glibc 宣言(Step 135) | なし(UAPI 実測) |
| `include/libc/glibc/aarch64/sys/epoll.h` | 同上。`struct epoll_event` は packed ではなく実測 16 バイト・_Alignof 8・data はオフセット 8。マクロ値は x86-64 版と一致(Step 135) | なし(UAPI 実測) |
| `include/libc/langinfo.h` | **glibc の `nl_item` 番号**(実測)。番号は平坦な連番ではなく `(カテゴリ << 16)` と インデックスのビット合成で、その合成規則自体も `_NL_ITEM`/`_NL_ITEM_CATEGORY`/`_NL_ITEM_INDEX` を rubycc 自身の式で書き直したうえで全 (カテゴリ, インデックス) 組についてオラクルと一致することを実測確認した。`nl_langinfo` はホスト libc が答えるため番号はホストの列挙と一致する必要がある(locale.h の `LC_*`・unistd.h の `_SC_*` と同じ論法)。全値が両アーキ一致のため共通層。`nl_langinfo` は POSIX 宣言(Step 135) | なし(glibc ABI 実測) |
| `include/libc/sys/timerfd.h` | **Linux UAPI(linux/timerfd.h)の `TFD_*` 値**(実測)。`TFD_CLOEXEC`(0x80000)/`TFD_NONBLOCK`(0x800)は open(2) フラグとビットを共有するため、fcntl.h がアーキ層に分かれている前例に照らして両アーキで実測したが一致。`struct itimerspec` は複製せず `#include <time.h>` で得る(bundled time.h が struct timespec の隣で既に定義しており、複製はドリフト源になる。`sys/wait.h` → `signal.h` と同じ判断)。実測 32 バイト・it_interval@0・it_value@16 も両アーキ一致のため共通層。timerfd_create/settime/gettime は Linux/glibc 宣言(Step 141) | なし(UAPI 実測) |
| `include/libc/sys/inotify.h` | **Linux UAPI(linux/inotify.h)の `IN_*` イベントビットと `struct inotify_event` のレイアウト**(実測)。可変長メンバ `name[]` を持つ型なので、サイズ・全オフセット・各メンバの幅と符号を両アーキで実測(16/4、wd@0 は符号付き int、mask/cookie/len@4/8/12 は符号なし 4 バイト、name@16)。sizeof が「ヘッダ部だけの 16 バイト」であることが `ofs += sizeof(struct inotify_event) + ev->len` というバッファ走査の正しさを支える。全値が両アーキ一致のため共通層。inotify_init/init1/add_watch/rm_watch は Linux/glibc 宣言(Step 141) | なし(UAPI 実測) |
| `include/libc/sys/statfs.h` | **Linux statfs(2) の `struct statfs` レイアウト**(実測 120 バイト・_Alignof 8・全メンバ 8 バイト・パディングなし)。カーネルには 32bit カウンタ版と 64bit 版の 2 系統があり glibc はワード幅 typedef で書いているため sys/stat.h のようなアーキ差を予想したが、**実測では両 LP64 ターゲットとも同一**だったため共通層。符号は一様ではなく f_type/f_bsize/f_namelen/f_frsize/f_flags/f_spare が符号付き、f_blocks/f_bfree/f_bavail/f_files/f_ffree が符号なし(実測)。`__fsid_t` は実測 8 バイト・align 4(= int 2 本、8 バイト語ではない)。`fsid_t` は glibc では sys/types.h 側の別名だが rubycc には型分割層がないため同じガード内に置く。statfs/fstatfs は Linux/glibc 宣言(Step 141) | なし(UAPI/glibc ABI 実測) |
| `include/libc/glibc/x86_64/sys/syscall.h` | **Linux x86-64 システムコール番号**(実測)。glibc の `sys/syscall.h` が `<asm/unistd.h>` を取り込んで `SYS_*` を `__NR_*` の別名として定義する 2 段構成であることも実測で確認し、その関係ごと再現。番号はアーキ別体系で、実測すると `SYS_read` 0 対 63・`SYS_openat` 257 対 56 のようにほぼ全項目が食い違うため **arch 層に 2 本**(io_uring の 3 本 425/426/427 だけが共通)。全数網羅ではなく、nio4r/libev が生 syscall で発行するもの(clock_gettime・eventfd2/signalfd4/inotify_init1/epoll_create1・linux-aio と io_uring)と代表的な中核呼び出しに限定し、**両アーキに存在する名前のみ**を対象とした(x86-64 専用の旧エントリ open/poll/select/pipe/dup2 等は asm-generic 表に存在しないため両側で対象外)。glibc 同様 `syscall()` の宣言は持たない(unistd.h の担当)(Step 141) | なし(kernel ABI 実測) |
| `include/libc/glibc/aarch64/sys/syscall.h` | 同上。aarch64(asm-generic)の番号体系。x86-64 版と名前集合は完全に同じで、番号のみが異なる(クロス gcc + qemu で実測)(Step 141) | なし(kernel ABI 実測) |

> `assert.h` と `features.h` は自己申告で clean-room だが、冒頭コメントに
> 「musl's <…> was the shape reference」とある。**形状(どの宣言を並べるか)の参照**で
> あって、musl のテキストを写したものではない。仮に musl 由来と厳格に見なしても、
> §2 (b) の omit 許可により表示義務は生じないため、いずれの解釈でも配布上の追加義務はない。

### 3.4 集計

| 分類 | 本数 |
|---|---|
| freestanding | 9 |
| musl-derived | 22 |
| clean-room | 47 |
| **合計** | **78** |

> Step 82(M5 H1)で `include/libc/glibc/aarch64/` 層 11 本を追加(30→41)。うち 8 本は
> x86-64 版と宣言・値がバイト一致(`cmp` 確認済み)で、由来分類も x86-64 版を継承する。
> 実 ABI 差分を持つのは 3 本のみ: `sys/types.h`(nlink_t/blksize_t が 32bit)・
> `sys/stat.h`(struct stat が実測 128 バイトの aarch64 レイアウト)・`stdint.h`
> (WCHAR_MIN/MAX が unsigned)。いずれも glibc/UAPI ソースのコピーではなく、クロス gcc
> で実測した ABI 事実(§4)の再現。

> Step 123(M5 H2)でコーパスセンサスの gap 一覧から `pwd.h`・`grp.h`・
> `sys/utsname.h`・`sys/uio.h`・`sys/resource.h`・`dirent.h`・`sched.h` の 7 本を追加
> (56→63、clean-room 26→33)。7 本すべて、呼び出し側がメンバへ直接触れる構造体
> (struct passwd/group/utsname/iovec/rlimit/rusage/dirent)はサイズ・全メンバの
> オフセットを x86-64・クロス gcc(aarch64)の両方で実測し、byte で一致したため
> 共通層(`include/libc/`)に配置した。DIR と cpu_set_t は内部状態を触らせない型
> なので、setjmp.h/pthread.h と同じ方針(実測サイズ/アラインの不透明ブロブ、または
> glibc 自身も定義を与えない不完全型のまま)にした。

> Step 124(M5 H2)でコーパスセンサスの残り gap から `termios.h`・`sys/ioctl.h`・
> `sys/param.h`・`sys/fcntl.h`(x86-64・aarch64 の 2 本)の計 5 本を追加
> (63→68、clean-room 33→38)。struct termios(NCCS を含む)と struct winsize は
> 呼び出し側がメンバへ直接触れる構造体なので、サイズ・全メンバのオフセットを
> x86-64・クロス gcc(aarch64)の両方で実測し、byte で一致したため共通層に配置した
> (TIOCGWINSZ/TIOCSWINSZ の値も同様に両アーキ一致を実測)。sys/param.h は
> 実測の結果、glibc 自身が「古い Unix パラメータの互換ヘッダ」と自称する薄いシムで
> あることを確認し、MIN/MAX/howmany/roundup の 4 マクロのみを rubycc 自身の式
> (値は同一・テキストは非コピー)で再現、BSD 名エイリアスやビットマップ操作マクロ
> 群は対象外とした。sys/fcntl.h は `#include <fcntl.h>` のみの 1 行シムであることを
> 実測確認し、fcntl.h 自身が O_DIRECT 系のアーキ差ゆえに glibc/x86_64・glibc/aarch64
> の 2 層に分かれている構成に合わせて同じ 2 か所に置いた(内容はバイト一致)。
> `sys/endian.h` はセンサスの gap 候補だが、ホスト glibc(x86-64・aarch64 いずれの
> `libc6-dev` パッケージにも)に実在しないことを `dpkg -L` で確認したため追加していない
> (digest の rmd160.c 内の `#include <sys/endian.h>` も `HAVE_SYS_ENDIAN_H_` という、
> どの extconf.rb からも定義されないマクロの下にあり、実行時に到達しない点も実測で
> 確認した)。`regex.h`(oj、`regex_t` を値で埋め込むため実測 64 バイトの内部構造の
> 再現コストが見合わない)・`stdatomic.h`・`stdckdint.h`(いずれも rubycc が
> `_Atomic` 型指定子・`__builtin_add_overflow` を実装しておらず、実測で
> コンパイルエラーになることを確認した)の 3 本は今回のスコープ外(未着手)。

> **`stdckdint.h` はその後 Step 179 で追加した**(上の見送り理由 = `__builtin_add_overflow`
> 不在は Step 177 で解消)。freestanding 側に置いたのは、C23 の `ckd_*` が全整数型に対して
> 型ジェネリックであり、コンパイラにしか表現できないからである。
> 動機は musl の初回実行(Step 175)で、**ホストの ruby の `config.h` が
> `HAVE_STDCKDINT_H` を焼き込んでいると rubycc では `ruby.h` が前処理すら通らない**
> ことが分かったため。`stdatomic.h` は依然として未着手(`_Atomic` が無いまま)。

> Step 135(M5 H2)で、コーパスセンサス(36 gem、Step 139)が挙げた実需ギャップから
> `sys/wait.h`(nio4r)・`sys/epoll.h`(nio4r・unicorn)・`langinfo.h`(nkf)の 3 スペリング
> = ファイル 4 本を追加(68→72、clean-room 38→42)。census が集計する
> 「Bundled header set」は 53→56 スペリング(`sys/epoll.h` は arch 層の 2 本が 1 スペリングへ
> 正規化される)。`sys/wait.h` と `langinfo.h` は全値・全マクロ結果が x86-64・
> クロス gcc(aarch64)の両方で一致したため共通層に置いた。`sys/epoll.h` だけは
> `struct epoll_event` が x86-64 で **packed**(実測 12/1、data オフセット 4。32bit プロセスと
> 配列ストライドを揃えるためのカーネル側の意図的な指定)、aarch64 で自然レイアウト
> (実測 16/8、data オフセット 8)と食い違うため、fcntl.h/pthread.h/setjmp.h/sys/stat.h と
> 同じく arch 層に 2 本置いた。wait ステータスのマクロ群は glibc のマクロ本体を写経せず、
> 観測した符号化から rubycc 自身の式へ書き直したうえで、**全 2^32 個の int ステータス値**に
> ついて 8 マクロすべての戻り値が glibc オラクルと厳密一致することを両アーキで実測確認して
> いる(§4.2 の「マクロが展開する数値」を、単一の値ではなく写像として実測した形)。同様に
> `langinfo.h` の `nl_item` 合成規則も、全 (カテゴリ, インデックス) 組でオラクルと一致することを
> 実測確認した。スコープ外としたもの: wait3/wait4(`struct rusage *` を取るため
> sys/resource.h との共有ガードか相互 include が要るが、センサスのどの hit も使わない)・
> 廃れた `union wait` 系・epoll_pwait/epoll_pwait2(`sigset_t`/`struct timespec` が要る)・
> `nl_langinfo_l`(`locale_t` は bundled locale.h が意図的に持たない拡張)。

> Step 141(M5 H6)で、同じセンサスが挙げた残りの Linux 系ギャップから
> `sys/timerfd.h`・`sys/inotify.h`・`sys/statfs.h`・`sys/syscall.h` の 4 スペリング
> = ファイル 5 本を追加(72→77、clean-room 42→47)。census が集計する
> 「Bundled header set」は 56→60 スペリング(`sys/syscall.h` は arch 層の 2 本が
> 1 スペリングへ正規化される)。4 本とも nio4r(6.7 億 DL)が同梱する libev の
> Linux バックエンドが参照する。**アーキ差の有無は 4 本すべて実測で判定した**:
> `sys/timerfd.h`・`sys/inotify.h`・`sys/statfs.h` は sizeof/_Alignof/全オフセット/
> 全マクロ値が x86-64 とクロス gcc(aarch64)で完全一致したため共通層、
> `sys/syscall.h` は番号がほぼ全項目で食い違うため arch 層 2 本。
>
> - `sys/statfs.h` は**予想が外れた例**。カーネルに 32bit カウンタ版と 64bit 版の
>   2 系統がありメンバ型がワード幅 typedef で書かれているため sys/stat.h と同様の
>   アーキ差を予想したが、実測では両 LP64 ターゲットとも 120 バイト・全メンバ 8 バイト・
>   パディングなしで一致した。一方**符号は一様ではなく**、f_type/f_bsize/f_namelen/
>   f_frsize/f_flags/f_spare が符号付き、5 つのカウンタが符号なしだった(libev が
>   f_type を 0x9123683e のような大きな magic と比較できるのは、この欄が符号付き
>   64bit 語だからで、32bit なら成立しない)。
> - `sys/inotify.h` の `struct inotify_event` は可変長メンバ `name[]` を持つため、
>   サイズ(16、ヘッダ部のみ)・全オフセット・各メンバの幅と符号を両アーキで実測した。
>   なお C は可変長メンバを持つ構造体の配列を禁じており(6.7.2.1)、gcc は拡張として
>   許すが rubycc は拒否する(rubycc 側が規格に忠実)。したがって ABI ハーネスでは
>   `sys/epoll.h` のような `sizeof(struct X[n])` ストライド検証は行わず、実際に意味の
>   ある実行時ストライド `sizeof(struct inotify_event) + ev->len` を probe で走らせている。
> - `sys/timerfd.h` の `struct itimerspec` は複製せず `#include <time.h>` で解決した
>   (`sys/wait.h` → `signal.h` の `siginfo_t`、`string.h` → `strings.h` と同じ前例)。
> - `sys/syscall.h` は**全数網羅していない**。glibc 版はカーネルヘッダから生成された
>   数百項目だが、rubycc 版は (a) nio4r/libev が生 syscall で発行するもの
>   (clock_gettime、eventfd2/signalfd4/inotify_init1/epoll_create1、linux-aio 5 本、
>   io_uring 3 本)と (b) 表の広い範囲を検証できる代表的な中核呼び出しに限定した
>   56 項目で、`sched.h` が CPU_SET 群を対象外にしたのと同じスコープ判断。
>   さらに**両アーキに存在する名前のみ**を採用しており、x86-64 専用の旧エントリ
>   (open/poll/select/pipe/dup2 等。asm-generic 表に対応項目がない)は両側で対象外。
>   これにより 2 本の arch 層ファイルは「番号だけが違い名前集合は同一」になり、
>   ABI ハーネスの Spec を 1 つで両アーキに使える。glibc 同様 `syscall()` の宣言は
>   持たない(unistd.h の担当)ことも実測で確認した。スコープ外としたもの:
>   timerfd_settime64/gettime64・struct statfs64/statfs64/fstatfs64(実測で両 LP64
>   ターゲットとも平の名前と同一レイアウトのため不要)・`ST_*`(実測で
>   `<sys/statfs.h>` は定義せず、`<sys/statvfs.h>` の担当)。

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

### 5.1 gemspec への NOTICE 同梱(是正済み)

`rubycc.gemspec` の `spec.files` は当初 `["LICENSE.txt", "README.md"]` のみを含み、
**`NOTICE` が gem パッケージに入っていなかった**。musl の omit 許可により NOTICE 同梱は
厳密な義務ではないが、由来を受領者へ伝える方針(§2 解釈)に反するため、`spec.files` に
`NOTICE` を追加した。これで `gem install rubycc` の受領者にも musl の謝辞・MIT 全文と
本ドキュメントが指し示す由来体制が届く。

### 5.2 ライセンス表記の整合

- `spec.license = "MIT"` は rubycc 全体の MIT と一致。musl 由来部分も MIT なので矛盾しない。
- `LICENSE.txt` は rubycc 自身の MIT。musl の著作権表示と MIT 全文は `NOTICE` にある。
  両者の分担(自作 = LICENSE.txt、同梱物の由来 = NOTICE)は明確。

---

## 6. 今後のヘッダ追加ワークフロー(H2 以降)

M5 で libc 互換ヘッダを拡充する際、由来の記録と NOTICE の整合を保つため、
新規ヘッダ追加時に次を必須手順とする:

1. **冒頭 provenance コメントを必ず書く**。§3 の 4 分類のどれかを明示する:
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
- 実測 ABI の方針・同梱ヘッダの設計判断: `docs/STEPS.md`(Step 63/64)、`docs/DESIGN.md`
- 派生禁止ルール(R11): `CLAUDE.md`
- gem 配布物の謝辞: リポジトリルート `NOTICE`
