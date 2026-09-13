---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
