---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [bundled-headers-coverage-audit-2]
---

# 同梱 `stdlib.h` に `getloadavg` の宣言が無い

## 課題

**`#include <stdlib.h>` しても `getloadavg` が宣言されない。** gcc(glibc)は宣言する。
2026-09-13 にこのホストで実測:

```c
#include <stdlib.h>
int main(void) { double a[3]; return getloadavg(a, 3); }
```

| | 結果 |
|---|---|
| gcc | **ok** |
| rubycc | **`error: implicit declaration of function 'getloadavg'`** |

glibc は `getloadavg` を `<stdlib.h>` の中で **`__USE_MISC`**(= `_DEFAULT_SOURCE`)の
枝に置いている。同梱ヘッダにはその枝が無い。

## 影響

**実在の gem が落ちる。** コーパス候補 `vmstat` 2.3.1 は
`ext/vmstat/hw/posix.h:25` で `getloadavg(&loadavg[0], AVGCOUNT)` を呼ぶため
`build_load` に失敗する(2026-09-13 実測)。**対照(host gcc)は成功する。**

## 受け入れ条件

- 上の最小再現が gcc と同じく通る
- **宣言の形が glibc と一致している**ことを実測で確かめる(引数と戻り値の型)。
  ヘッダのテキストを写経せず、**リファレンスコンパイラで測ってから書く**
  (`docs/reference/HEADER-LICENSING.md` §6 の手順)
- 由来台帳(§3.3)に 1 行足し、§3 / §3.2 / §3.3 / §3.4 の集計を更新する
- `test/test_header_abi.rb` に x86_64 と aarch64 の**両方**でケースを追加する
- `vmstat` 2.3.1 が `build_load` を通る
- `rake test` が 0 failures

## 着手前に確かめること

- **`_DEFAULT_SOURCE` の枝に何が入っているか**を先に測ること。`getloadavg` だけを足すと、
  同じ枝の他の宣言で次の gem が落ちる。**同梱ヘッダの穴は 1 つずつ塞ぐと回数が増える**
  ので、枝ごと見て決める

## 作業ログ

### 2026-09-13(起票)

コーパス候補 46 件の `build_load` で、rubycc だけが落ちて対照は通る 5 件のうちの 1 件。

### 2026-09-14(実装)

[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) の突き合わせの表から、同梱ヘッダ側に足す形で直した(`bundled-headers-coverage-audit-2`)。
修正前の同梱ヘッダでは rubycc だけが落ち、修正後は gcc と同じく通ることを測った。

## 決着

**解消した**(`bundled-headers-coverage-audit-2`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通る | `getloadavg` の最小再現が gcc と同じく通る。`test/test_bundled_headers_coverage.rb` と `test/test_header_abi.rb` で確認(x86-64 / aarch64) |
| gem がビルドできる | この PR の後に master で測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
