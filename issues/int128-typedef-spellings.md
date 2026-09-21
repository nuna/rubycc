---
status: done
kind: gap
opened: 2026-09-18
closed: 2026-09-22
branch: gap-fixes-wave-9
pr: 159
steps: [int128-typedef-spellings-1]
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

### 2026-09-22(実装)

gcc を測ると、この 2 つは**定義済みの typedef**で、しかも普通の先行宣言としては扱われない: プログラムが file scope で
`typedef int __int128_t;` と書いても黙って通り、2 回目の型の違う再宣言だけが衝突になる。既存の `__builtin_va_list` の予約と同じ形なので、
そこに合流させた(最初の宣言だけは型を問わず置き換え、以後は通常の再宣言の規則に従う)。型は `__int128` / `unsigned __int128` と同じ実体なので、
大きさ・整列・算術・引数渡しは変更なしに揃う。

## 決着

**解消した**(`int128-typedef-spellings-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現が通り、`sizeof` / `_Alignof` と算術が `__int128` 系と同じになる(両 arch) | `test/test_int128_typedef_spellings.rb`(gcc 差分、x86-64 と aarch64) |
| `-target aarch64` で `#include <sys/ucontext.h>` が通る | 同じテストで確認(クロスヘッダがある環境で実行) |
| gcc の typedef の扱い(再定義・隠蔽・タグ名)を測って合わせる | 5 通りを測り、同じテストに入れた |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
