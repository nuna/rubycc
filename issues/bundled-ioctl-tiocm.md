---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱 `sys/ioctl.h` にモデム制御線の要求番号(`TIOCMGET` / `TIOCM_*`)が無い

## 課題

**`#include <sys/ioctl.h>` しても `TIOCMGET` や `TIOCM_DTR` が定義されない。** gcc(glibc)は定義する。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
#include <sys/ioctl.h>
int f(int fd) { int s = 0; return ioctl(fd, TIOCMGET, &s) + (s & TIOCM_DTR); }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`error: undeclared variable 'TIOCMGET'`** |

rubycc は `<sys/ioctl.h>` を同梱の `include/libc/sys/ioctl.h`(36 行)に解決する。定義しているのは
`TIOCGWINSZ` / `TIOCSWINSZ` と `struct winsize` などで、冒頭のコメントがコーパスの必要に合わせて絞ったと
述べている。glibc は `TIOCMGET` を `asm-generic/ioctls.h:40`(`0x5415`)で、`TIOCM_DTR` を
`bits/ioctl-types.h:48`(`0x002`)で定義し、どちらも `<sys/ioctl.h>` から届く。

## 影響

**実在の gem が落ちる。** コーパス候補 `serialport` 1.4.0 は `posix_serialport_impl.c:637` で `TIOCMGET` を使う。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-4)。

同梱ヘッダの抜けとしては 6 件目で、[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) が
まとめて洗い出す対象に入る。

## 受け入れ条件

- 上の最小再現が gcc と同じく通る
- `TIOCMGET` / `TIOCMSET` / `TIOCMBIS` / `TIOCMBIC` と `TIOCM_*` の値を、x86-64 と aarch64 の**両方**で
  リファレンスコンパイラと突き合わせる(`test/test_header_abi.rb`。**aarch64 の要求番号は x86-64 と違いうる**ので
  共通層に置く前に測る)。ヘッダを写経しない(`docs/reference/HEADER-LICENSING.md` §6)。由来台帳を更新する
- `serialport` 1.4.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
