---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# 関数名を括弧で囲んだ関数定義 `int (f)(int a) { ... }` を拒否する

## 課題

**関数定義の宣言子で関数名を括弧で囲むと、rubycc は「typedef 経由の関数定義」と誤って診断して拒否する。**
gcc は通す。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
int (add)(int a, int b) { return a + b; }
int main(void) { return add(1, 2) - 3; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: function definition through a typedef is not allowed`** |

`(add)(int a, int b)` は括弧で囲んだ宣言子に仮引数並びが続く関数宣言子(C11 6.7.6p1、6.7.6.3)で、
関数定義の宣言子として正しい(6.9.1p2 が禁じるのは typedef 名で関数型を継ぐ形)。**診断も原因を伝えていない。**

関数名を括弧で囲むのは、同名の関数形式マクロの展開を避ける定番の書き方である。

## 影響

**実在の gem が落ちる。** `iodine` 0.7.59 の `fiobj_mustache.c` / `iodine_mustache.c` が、
`mustache_parser.h:1018` の `MUSTACHE_FUNC int(mustache_build)(mustache_build_args_s args) { ... }` で落ちる
(2026-09-14 実測、`atomic-builtin-small-widths-1` の後。各 `.c` を単独で `-c`)。

## 受け入れ条件

- 上の再現が通り、gcc と同じ値を返す。`static int (f)(void) { ... }`・ポインタを返す `int *(g)(void)`・
  旧形式の仮引数並びでも通る
- typedef 名で関数型を継ぐ定義(`typedef int F(void); F f { ... }`)は、これまでどおり拒否する
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`atomic-builtin-small-widths-1` を実装したエージェントが、iodine の残りの原因として報告した形を最小再現で確かめて起票した。

## 決着

(未着手)
