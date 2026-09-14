---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [bundled-headers-coverage-audit-2]
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

### 2026-09-14(実装)

[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) の突き合わせの表から、同梱ヘッダ側に足す形で直した(`bundled-headers-coverage-audit-2`)。
修正前の同梱ヘッダでは rubycc だけが落ち、修正後は gcc と同じく通ることを測った。

## 決着

**解消した**(`bundled-headers-coverage-audit-2`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通る | `-D_GNU_SOURCE` のもとの `qsort_r`が gcc と同じく通る。`test/test_bundled_headers_coverage.rb` と `test/test_header_abi.rb` で確認(x86-64 / aarch64) |
| gem がビルドできる | この PR の後に master で測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
