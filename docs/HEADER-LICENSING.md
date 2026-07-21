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

1. **rubycc 全体は MIT**(`LICENSE.txt`、Copyright (c) 2026 itacchi)。同梱する libc 互換
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

## 3. 同梱ヘッダの由来台帳(53 本)

各ヘッダ冒頭の provenance コメントを棚卸しした結果。分類は次の 4 種:

- **freestanding** — ISO C §7 が規定する自立ヘッダ。コンパイラが提供すべきもので、
  libc(musl/glibc)由来ではない。
- **musl-derived** — musl の宣言セット/形状を出発点にし、glibc の対象 arch(x86-64 / aarch64)ABI に合わせて改変。
- **clean-room** — 公開 ABI / ISO C 標準 / カーネル UAPI に対してゼロから記述。musl 由来ではない
  (一部は musl を「形状の参照」にしたが、テキストの派生はしていない)。

### 3.1 freestanding(8 本、`include/*.h`)

libc 由来ではない。musl・glibc いずれの派生でもない。

| ファイル | 根拠 |
|---|---|
| `include/float.h` | ISO C 7.7(x86-64 の IEEE754/x87 一般値) |
| `include/iso646.h` | ISO C 7.9 |
| `include/stdalign.h` | ISO C 7.15(`_Alignof` へのマッピング) |
| `include/stdarg.h` | ISO C 7.16(`__builtin_va_*` へのマッピング) |
| `include/stdbool.h` | ISO C 7.18 |
| `include/stddef.h` | ISO C 7.19(型は x86-64 SysV LP64 に固定) |
| `include/stdnoreturn.h` | ISO C 7.23 |
| `include/x86intrin.h` | 意図的な空スタブ(CRuby の config.h 対策) |

### 3.2 musl-derived(15 本)

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

### 3.3 clean-room(23 本)

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

> `assert.h` と `features.h` は自己申告で clean-room だが、冒頭コメントに
> 「musl's <…> was the shape reference」とある。**形状(どの宣言を並べるか)の参照**で
> あって、musl のテキストを写したものではない。仮に musl 由来と厳格に見なしても、
> §2 (b) の omit 許可により表示義務は生じないため、いずれの解釈でも配布上の追加義務はない。

### 3.4 集計

| 分類 | 本数 |
|---|---|
| freestanding | 8 |
| musl-derived | 22 |
| clean-room | 23 |
| **合計** | **53** |

> Step 82(M5 H1)で `include/libc/glibc/aarch64/` 層 11 本を追加(30→41)。うち 8 本は
> x86-64 版と宣言・値がバイト一致(`cmp` 確認済み)で、由来分類も x86-64 版を継承する。
> 実 ABI 差分を持つのは 3 本のみ: `sys/types.h`(nlink_t/blksize_t が 32bit)・
> `sys/stat.h`(struct stat が実測 128 バイトの aarch64 レイアウト)・`stdint.h`
> (WCHAR_MIN/MAX が unsigned)。いずれも glibc/UAPI ソースのコピーではなく、クロス gcc
> で実測した ABI 事実(§4)の再現。

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
