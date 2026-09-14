---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [bundled-headers-coverage-audit-2]
---

# 同梱 `stdlib.h` が `alloca` を宣言しない(glibc は `__USE_MISC` で `<alloca.h>` を含む)

## 課題

**`#include <stdlib.h>` だけで `alloca` を呼ぶと、rubycc は宣言の無い関数としてエラーにする。** gcc は通す。
2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

| 入力 | gcc | rubycc |
|---|---|---|
| `#include <stdlib.h>` の後で `char *p = alloca(n);` | ok | **`error: implicit declaration of function 'alloca'`** |
| `#include <alloca.h>` の後で同じ | ok | ok |

glibc の `stdlib.h` は `__USE_MISC`(= `_DEFAULT_SOURCE`)のもとで `<alloca.h>` を含む。
rubycc の同梱 `include/libc/stdlib.h` にはその枝が無い。Ruby の拡張は `_GNU_SOURCE` のもとで
コンパイルされる(Ruby の `config.h:17`)ので、この枝は拡張からは常に見えるはずのものである。

## 影響

**実在の gem が落ちる。** コーパス候補 `amalgalite` 2.0.0 は、同梱の SQLite の amalgamation
(`ext/amalgalite/c/sqlite3.c`)が `sqlite3StackAllocRaw` を通じて `alloca` を使い、55,748 行目で上のエラーになる。
この gem はもともと展開予算(GAPS AL)で止まっており、`expansion-budget-source-tokens-1` で予算を越えた後に
この 2 つ目の不足が見えた(2026-09-14 実測、ledger-after-wave-1-2)。**対照の gcc はビルドとロードに成功する**
(buildable-gems-batch-4 の実測)。

同梱ヘッダの抜けとしては 7 件目で、[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) が
まとめて洗い出す対象に入る。[`bundled-stdlib-getloadavg`](bundled-stdlib-getloadavg.md)(AF、同じ `__USE_MISC` の枝)と
[`bundled-stdlib-qsort-r`](bundled-stdlib-qsort-r.md)(AR)と同じ `<stdlib.h>` の話である。

## 受け入れ条件

- 上の 1 行目が gcc と同じく通り、`alloca` で確保した領域に書いて読める(gcc 差分の実行)
- **AF・AR と一緒に** `<stdlib.h>` の `__USE_MISC` / `__USE_GNU` の枝をまとめて見て、足す範囲を決める
- ヘッダを写経しない(`docs/reference/HEADER-LICENSING.md` §6)。由来台帳を更新する
- `amalgalite` 2.0.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

2 回目の修正(#148)の後に、止まっていた gem を測り直して見つけた。

### 2026-09-14(実装)

[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) の突き合わせの表から、同梱ヘッダ側に足す形で直した(`bundled-headers-coverage-audit-2`)。
修正前の同梱ヘッダでは rubycc だけが落ち、修正後は gcc と同じく通ることを測った。

## 決着

**解消した**(`bundled-headers-coverage-audit-2`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通る | `<stdlib.h>` だけで呼ぶ `alloca`が gcc と同じく通る。`test/test_bundled_headers_coverage.rb` と `test/test_header_abi.rb` で確認(x86-64 / aarch64) |
| gem がビルドできる | この PR の後に master で測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
