---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# 同梱 `signal.h` が `union sigval` を glibc のガード無しで定義する

## 課題

**`_GNU_SOURCE` のもとで同梱の `<signal.h>` と glibc の `<netdb.h>` を両方含めると、rubycc は `union sigval` の
再定義で落ちる。含める順に関係なく起きる。** gcc は通す。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <signal.h>
#include <netdb.h>
int main(void) { union sigval v; v.sival_int = 1; return v.sival_int - 1; }
```

| 形 | gcc 13.3 | rubycc |
|---|---|---|
| `<signal.h>` → `<netdb.h>`、`-D_GNU_SOURCE` | ok | **`bits/types/__sigval_t.h:24:1: error: redefinition of 'union sigval'`** |
| `<netdb.h>` → `<signal.h>`、`-D_GNU_SOURCE` | ok | **`include/libc/signal.h:57:1: error: redefinition of 'union sigval'`** |
| どちらの順も、`_GNU_SOURCE` 無し | ok | ok |

glibc の `<netdb.h>` は `__USE_GNU` のとき `bits/types/sigevent_t.h` を経て `bits/types/__sigval_t.h` を引く。
同梱の `include/libc/signal.h:57` は、glibc のヘッダ間で共有するガードを見ずに `union sigval` を定義している。
[`bundled-pthread-attr-guard`](bundled-pthread-attr-guard.md)(AU、`pthread_attr_t`)と同じ形である。

Ruby の拡張は Ruby の `config.h` によって常に `_GNU_SOURCE` のもとでコンパイルされる。

## 影響

**実在の gem が落ちる。** `iodine` 0.7.59 の `fio.c`(`<signal.h>` と `<netdb.h>` の両方を含む)が、この再定義で落ちる
(2026-09-14 実測、`atomic-builtin-small-widths-1` の後。`.c` を単独で `-c`)。

AU を直したときの点検は、`pthread.h` の型だけを見ていた。

## 受け入れ条件

- 上の 2 つの順が、どちらも `_GNU_SOURCE` のもとで通る
- `union sigval` の大きさと整列が、x86-64 と aarch64 の両方で gcc と一致したまま(`test/test_header_abi.rb`)
- 同梱ヘッダ全体で、glibc のヘッダ間で共有するガードを持つ型を数え、同じ形の抜けが残っていないことを確かめる
  ([`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) の受け入れ条件の 1 つと同じ)
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`atomic-builtin-small-widths-1` を実装したエージェントが、iodine の残りの原因として報告した形を、最小再現で両方の順について確かめて起票した。

## 決着

(未着手)
