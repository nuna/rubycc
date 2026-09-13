---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-13
branch: extern-initializer-file-scope
pr: 142
steps: [extern-initializer-file-scope-1]
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

### 2026-09-13(着手)

`lib/rubycc/front/parser.rb` の 2 箇所を実測した:

- `parse_global_declarator`(ファイルスコープ、916 行付近)— `spec_info.storage == :extern` の
  ときの `error_at` を削除。呼び出し元をたどり、ファイルスコープの宣言だけがここを通ることを確認した
- `parse_init_declarator`(2274 行付近、`parse_declaration` からしか呼ばれずブロックスコープ専用)—
  同じ形のエラーが残っており、これがブロックスコープの拒否そのものだった。**変更不要**と確認した

パーサだけでは足りなかった: `lib/rubycc/ir/generator.rb#declare_global` が
`decl.storage == :extern` を無条件に「実体の無い参照」の分岐へ送っていたため、
初期化子付きの `extern` 宣言を通しても `.data` に実体が出ず、リンカ向けの未定義参照のままに
なることを確認した。分岐条件を `decl.storage == :extern && !has_init` に直した。

`test/test_extern_initializer_file_scope.rb` を新設し、スカラーと struct へのポインタ
(cool.io 同梱 libev の `EV_API_DECL struct ev_loop *ev_default_loop_ptr = 0;` の形)の両方で、
定義側と参照側を別翻訳単位にした gcc 差分実行を追加した。ブロックスコープのエラーは
`test/test_diagnostics.rb` の既存テストをブロックスコープ版に差し替えた。
サンプル `examples/m6/extern_initializer_file_scope_1_definition.c` を追加した。

設計判断の詳細は `docs/development/STEPS.md` の `extern-initializer-file-scope-1` を参照。

## 決着

**解消した**(`extern-initializer-file-scope-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

受け入れ条件の照合:

| 条件 | 結果 |
|---|---|
| 最小再現が外部定義になり、別の翻訳単位から読める | `test/test_extern_initializer_file_scope.rb` が gcc 差分で一致(両方 gcc / 両方 rubycc / 定義 gcc・参照 rubycc) |
| ブロックスコープは引き続きエラー | `test/test_diagnostics.rb` と上の新ファイルの両方で固定 |
| `cool.io` 1.9.5 が `build_load` を通る | **この PR では未測定**。マージ後に台帳の手順(`tools/verify_corpus_candidate.rb --update`)で測る |
| `rake test` が 0 failures | **3,534 runs / 15,907 assertions / 0 failures / 0 errors / 39 skips** |
