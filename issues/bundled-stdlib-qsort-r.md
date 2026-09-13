---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱 `stdlib.h` に `qsort_r` の宣言が無い(`_GNU_SOURCE` のもとでも)

## 課題

**`_GNU_SOURCE` を定義して `<stdlib.h>` を含めても、rubycc では `qsort_r` が宣言されない。**
gcc(glibc)は宣言する。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <stdlib.h>
static int cmp(const void *a, const void *b, void *c) { (void)c; return *(const int *)a - *(const int *)b; }
int f(int *v, size_t n) { qsort_r(v, n, sizeof *v, cmp, 0); return v[0]; }
```

| | `-D_GNU_SOURCE` なし | `-D_GNU_SOURCE` あり |
|---|---|---|
| gcc | 警告(暗黙の宣言) | **ok** |
| rubycc | エラー(暗黙の宣言) | **`error: implicit declaration of function 'qsort_r'`** |

glibc は `stdlib.h:973` で `qsort_r` を宣言する。同梱の `include/libc/stdlib.h` は `qsort`(76 行)だけを持つ。

**Ruby の拡張は例外なく `_GNU_SOURCE` のもとでコンパイルされる。** Ruby の
`include/ruby-3.4.0/x86_64-linux/ruby/config.h:17` が `#define _GNU_SOURCE 1` と定義しているためである。
つまり、GNU の枝の宣言が同梱ヘッダに無いと、拡張からは「glibc にはあるのに見えない」ことになる。

## 影響

**実在の gem が落ちる。** コーパス候補 `enumerable-statistics` 2.0.9 は
`ext/enumerable/statistics/extension/statistics.c:1647` で `qsort_r` を呼ぶ。
**対照の gcc はビルドに成功する**(2026-09-13 実測、buildable-gems-batch-3)。

[`bundled-stdlib-getloadavg`](bundled-stdlib-getloadavg.md)(GAPS AF)と同じ系統の穴である。
あちらは `__USE_MISC` の枝、こちらは `__USE_GNU` の枝。

## 受け入れ条件

- 上の最小再現が `-D_GNU_SOURCE` のもとで gcc と同じく通る
- 宣言の形が glibc と一致していることを実測で確かめる(ヘッダを写経しない。
  `docs/reference/HEADER-LICENSING.md` §6)。由来台帳を更新する
- **AF と一緒に、`<stdlib.h>` の `__USE_MISC` / `__USE_GNU` の枝をまとめて見て**、足す範囲を決める
- `enumerable-statistics` 2.0.9 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。最初の再現は `_GNU_SOURCE` を
付けずに測ってしまい、gcc も警告を出していた。付けて測り直して差を確かめた。

## 決着

(未着手)
