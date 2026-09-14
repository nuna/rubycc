---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [function-definition-parenthesized-name-1, function-definition-parenthesized-name-2]
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

### 2026-09-14(実装)

原因は宣言子の解析にあった。括弧の中が識別子だけで接尾辞を持たないとき、「この段に接尾辞なし」を表す番兵 `:none` を返さず、
`nil` に落としていた。外側の段はこれを「中の名前がもう関数の接尾辞を持っている」と読み、自分の仮引数並びを捨てていた。
`nil` は「typedef 経由の関数型」を表す既存の番兵でもあるので、typedef 経由の定義と取り違えた。

### 2026-09-14(回帰の修正)

-1 を入れた後の全体テストで、`test_knr_function_definitions.rb` の `int (*g)(a, b);` の診断が「仮引数名だけの並びは関数定義でしか使えない」から
「関数宣言子が要る」に変わった。括弧の中に `*` があるときも「接尾辞なし」の番兵が外へ伝わり、外側の `(a, b)` を定義の仮引数並びとして
採っていた。括弧の中の宣言子がポインタの前置を持つときは、以前どおり `nil` に畳むようにした(`function-definition-parenthesized-name-2`)。

## 決着

**解消した**(`function-definition-parenthesized-name-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現が通り、gcc と同じ値を返す。`static`・ポインタを返す形・旧形式の仮引数並びでも通る | `test/test_function_definition_parenthesized_name.rb`(二重の括弧、同名マクロを避ける形も) |
| typedef で関数型を継ぐ定義は拒否したまま | 同じテストで確認(gcc も拒否する) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
