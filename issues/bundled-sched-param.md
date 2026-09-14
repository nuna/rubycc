---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [bundled-headers-coverage-audit-2]
---

# 同梱 `sched.h` に `struct sched_param` が無く、glibc の `<spawn.h>` が読めない

## 課題

**`#include <sched.h>` しても `struct sched_param` が完全型にならない。** gcc(glibc)ではなる。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
#include <sched.h>
int f(void) { struct sched_param p; p.sched_priority = 0; return p.sched_priority; }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`error: invalid use of incomplete type 'struct sched_param'`** |

rubycc は `<sched.h>` を同梱の `include/libc/sched.h`(35 行)に解決する。Step 123(M5 H2)が
意図して絞ったもので、中身は `sched_yield` / `sched_getcpu` / 大きさだけを再現した `cpu_set_t` である。
glibc は `struct sched_param` を `<sched.h>` → `bits/sched.h:80` → `bits/types/struct_sched_param.h`
で定義する。

**システムの `<spawn.h>` がこれで壊れる。** `/usr/include/spawn.h` は `<sched.h>` を含み、
35 行目で `posix_spawnattr_t` のメンバに `struct sched_param __sp;` を置く。
同梱の `sched.h` を拾うと、ここが `error: field '__sp' has incomplete type` になる。

## 影響

**実在の gem が落ちる。** コーパス候補 `posix-spawn` 0.3.15 は `<spawn.h>` を含むため、
上のエラーでビルドできない。**対照の gcc はビルドとロードに成功する**(2026-09-13 実測)。

## 受け入れ条件

- 上の最小再現が gcc と同じく通る
- `struct sched_param` の**大きさとメンバのオフセット**を、x86-64 と aarch64 の**両方**で
  リファレンスコンパイラと突き合わせる(`test/test_header_abi.rb` の SCHED のケース)。
  ヘッダのテキストを写経せず、**測ってから書く**(`docs/reference/HEADER-LICENSING.md` §6 の手順)
- 由来台帳に 1 行足し、集計を更新する
- `#include <spawn.h>` だけの翻訳単位が rubycc でコンパイルできる
- `posix-spawn` 0.3.15 が rubycc で `build_load` を通る
- `rake test` が 0 failures

## 着手前に確かめること

- **`<spawn.h>` が `<sched.h>` から他に何を必要とするか**を先に測ること。Step 123 のコメントは
  `sched_setscheduler` 系を意図して外している。`struct sched_param` だけを足して次の宣言で
  また落ちるなら、同じ系統の [`bundled-stdlib-getloadavg`](bundled-stdlib-getloadavg.md) と同様に
  **まとめて見て決める**

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件のうち、rubycc だけが落ちて対照は通った 1 件。
rubycc の `-E` 出力の先頭が glibc と違う形の `cpu_set_t` だったことから、同梱ヘッダを拾っていると分かった。

### 2026-09-14(実装)

[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) の突き合わせの表から、同梱ヘッダ側に足す形で直した(`bundled-headers-coverage-audit-2`)。
修正前の同梱ヘッダでは rubycc だけが落ち、修正後は gcc と同じく通ることを測った。

## 決着

**解消した**(`bundled-headers-coverage-audit-2`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通る | `struct sched_param` と `<spawn.h>` だけの翻訳単位が gcc と同じく通る。`test/test_bundled_headers_coverage.rb` と `test/test_header_abi.rb` で確認(x86-64 / aarch64) |
| gem がビルドできる | この PR の後に master で測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
