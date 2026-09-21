---
status: done
kind: gap
opened: 2026-09-22
closed: 2026-09-22
branch: gap-fixes-wave-9
pr: 159
steps: [bundled-sigstksz-1]
---

# 同梱 `signal.h` に `SIGSTKSZ` / `MINSIGSTKSZ` が無い

## 課題

**`sigaltstack` の典型的な使い方で `SIGSTKSZ` を書くと、rubycc は「宣言されていない変数」にする。** gcc は通す。
2026-09-22 にこのホスト(WSL2 / gcc 13.3 / glibc 2.39)で測った:

```c
#define _GNU_SOURCE
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) { stack_t ss; ss.ss_size = SIGSTKSZ; ss.ss_sp = malloc(ss.ss_size); ss.ss_flags = 0; return sigaltstack(&ss, 0); }
```

| | 結果 |
|---|---|
| gcc 13.3 | 実行して終了コード 0 |
| rubycc | **`error: undeclared variable 'SIGSTKSZ'`** |

glibc 2.34 以降、`SIGSTKSZ` は `sysconf (_SC_SIGSTKSZ)` に、`MINSIGSTKSZ` は `SIGSTKSZ` に展開される
(`gcc -E -dM -D_GNU_SOURCE` で確認)。**定数ではない**ので、`static char s[SIGSTKSZ];` のような形は gcc でも通らない
(`storage size of 's' isn't constant`)。rubycc で足りないのは、実行時の値として使う形である。

`bundled-headers-core-batch-1` は `signal.h` を分類したが、`_SC_SIGSTKSZ` が同梱 `unistd.h` に無いため、
この 2 つは足さずに残した(`PTHREAD_STACK_MIN` も同じ形で `_SC_THREAD_STACK_MIN` を使う)。

## 影響

代替シグナルスタックを張る拡張(スタックオーバーフローの検出や、クラッシュ時の後始末をするもの)。
**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の再現が rubycc でコンパイル・実行でき、gcc と同じ結果になる(x86-64 と aarch64)
- `_SC_SIGSTKSZ` / `_SC_MINSIGSTKSZ` / `_SC_THREAD_STACK_MIN` の値を両 arch で測って同梱 `unistd.h` に足し、
  `SIGSTKSZ` / `MINSIGSTKSZ` / `PTHREAD_STACK_MIN` を glibc と同じ展開の形で足す
- `sysconf` に渡した値がホストの libc で意味のある値を返すことを、実行して確かめる
- `rake test` が 0 failures

## 着手前に確かめること

- 古い glibc(2.33 以前)ではこれらが定数だった。rubycc が対象にする glibc の範囲と、どちらの形に合わせるかを確かめる

## 作業ログ

### 2026-09-22(起票)

`bundled-headers-core-batch-1` の統合時に、報告された形(`static char s[SIGSTKSZ]`)が gcc でも通らないことが分かったため、
実行時の値として使う形で測り直して起票した。

### 2026-09-22(実装)

`_SC_SIGSTKSZ`(250)/ `_SC_MINSIGSTKSZ`(249)/ `_SC_THREAD_STACK_MIN`(75)を両 arch で測って同梱 `unistd.h` に足し、`SIGSTKSZ` と
`MINSIGSTKSZ` を `signal.h` に、`PTHREAD_STACK_MIN` を `pthread.h` に、glibc と同じ展開の形で足した。統合時に、glibc の `<signal.h>` が
`_GNU_SOURCE` のもとで `<unistd.h>` を取り込むことが分かり、同梱側も同じにした(`<signal.h>` だけで `SIGSTKSZ` が使える)。

## 決着

**解消した**(`bundled-sigstksz-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現が rubycc でコンパイル・実行でき、gcc と同じ結果になる(両 arch) | `test/test_bundled_headers_coverage.rb` の再現(`<unistd.h>` を含めない形)。x86-64 は 8192 / 8192 / 16384、aarch64 は 20480 / 20480 / 131072 で gcc と一致 |
| `_SC_*` の値を両 arch で測って足し、3 つのマクロを glibc と同じ展開の形で足す | 上記。`test/test_header_abi.rb` に `_SC_*` の値を追加 |
| `sysconf` がホストの libc で意味のある値を返す | 上の実行結果 |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
