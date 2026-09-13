---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# ファイルスコープの `extern` 付き定義(初期化子あり)を拒否する

## 課題

**`extern int x = 1;` をファイルスコープに書くと、rubycc はエラーにする。** gcc は警告だけで通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
extern int x = 1;
int get(void) { return x; }
```

| | 結果 |
|---|---|
| gcc | 警告 `'x' initialized and declared 'extern'`。オブジェクトは生成される |
| rubycc | **`error: 'x' has both 'extern' and initializer`** |

**規格上は正しいプログラムである。** C11 6.9.2p1 の例が `extern int i3 = 3; // definition, external linkage`
を挙げており、ファイルスコープで初期化子を持つ宣言は、`extern` が付いていても外部定義になる。
**制約違反になるのはブロックスコープの場合だけ**である(6.7.9p5)。

rubycc はこのエラーを `lib/rubycc/front/parser.rb` の 2 箇所で出す。ファイルスコープの宣言を読む
`parse_global_declarator`(916 行付近)も、コメントに「`extern` と初期化子は矛盾するので拒否する」
と書いて同じく拒否している。

## 影響

**実在の gem が落ちる。** コーパス候補 `cool.io` 1.9.5 は、同梱 libev の `ext/libev/ev.c:1845` で

```c
EV_API_DECL struct ev_loop *ev_default_loop_ptr = 0; /* needs to be initialised to make it a definition despite extern */
```

と書いており、`EV_API_DECL` は `ext/libev/ev.h:203` で `extern` に展開される。上流のコメントが、
これが定義であることを意図していると明言している。**対照の gcc はビルドとロードに成功する**
(2026-09-13 実測、`tools/verify_corpus_candidate.rb --mode build_load`)。

## 受け入れ条件

- 上の最小再現がコンパイルでき、`x` が**外部定義**になる — 別の翻訳単位の `extern int x;` から
  読んで `1` が返ることを、gcc 差分の実行で確かめる
- ブロックスコープの `void f(void) { extern int y = 1; }` は**引き続きエラー**になる(6.7.9p5)
- `cool.io` 1.9.5 が rubycc で `build_load` を通る
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件のうち、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
