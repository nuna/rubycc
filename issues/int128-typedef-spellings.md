---
status: open
kind: gap
opened: 2026-09-18
closed:
branch:
pr:
steps: []
---

# gcc が定義済み typedef として持つ `__int128_t` / `__uint128_t` の綴りが無い

## 課題

**rubycc は `__int128` と `unsigned __int128` は受け付けるが、gcc が定義済みの typedef として持つ
`__int128_t` / `__uint128_t` の綴りを受け付けない。** 2026-09-18 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
int main(void) { __int128 a = 1; unsigned __int128 b = 2; __int128_t c = 3; return (int)(a + b + c) - 6; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: expected ';'`**(`__int128_t` の位置) |

`__int128` は字句解析器のキーワード一覧にあり(`lib/rubycc/front/lexeme_reader.rb:38`)、
`__int128_t` / `__uint128_t` はどこにも無い。gcc はこの 2 つを**定義済みの typedef**として持つ
(`gcc -dM -E -x c /dev/null` には出ないが、宣言なしで使える)。

## 影響

**glibc のヘッダが落ちる。** `-target aarch64` で `<sys/ucontext.h>` を含むと、クロス sysroot の
`sys/user.h:32` の `__uint128_t vregs[32];` で止まる(2026-09-18 実測、`aarch64-cross-sysroot-include-1` の後。
**対照の `aarch64-linux-gnu-gcc` は通る**)。`<sys/ucontext.h>` はシグナルハンドラでレジスタを読む拡張が含む。
**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の再現が通り、`sizeof` / `_Alignof` と算術が `__int128` / `unsigned __int128` と同じになる(x86-64 と aarch64)
- `-target aarch64` で `#include <sys/ucontext.h>` が通る
- `rake test` が 0 failures

## 着手前に確かめること

- gcc がこの 2 つをどう見せているか(定義済み typedef か、キーワードの別名か)を測る。`typedef` の再定義や
  `struct __int128_t` のようなタグ名との衝突の扱いも合わせて測る

## 作業ログ

### 2026-09-18(起票)

`aarch64-cross-sysroot-include-1` の統合時に、報告された形を最小再現で確かめて起票した。

## 決着

(未着手)
