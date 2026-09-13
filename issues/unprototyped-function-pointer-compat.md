---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 仮引数付きの関数ポインタを、旧形式の `void (*)()` へ代入できない

## 課題

**`void (*)(int *, long)` の値を、仮引数を書かない旧形式の `void (*)()` に代入すると、rubycc はエラーにする。**
gcc は警告も出さずに通す。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
struct s { void (*f)(); };
static void work(int *p, long n) { p[0] = (int)n; }
void set(struct s *x, void (*lf)(int *, long)) { x->f = lf; }
int run(void) { struct s x; int v = 0; set(&x, work); ((void (*)(int *, long))x.f)(&v, 7); return v; }
```

| | 結果 |
|---|---|
| gcc 13.3(`-std=gnu11`) | ok(警告も出ない) |
| rubycc | **`unproto_fp.c:3:55: error: incompatible types in assignment`** |

**規格上は互換な型である。** C11 6.7.6.3p15 は、一方が仮引数の型並びを持ち、もう一方が関数定義でない
旧形式の宣言子(空の `()`)のとき、仮引数の型並びが省略記号を持たず、各仮引数の型が既定の実引数拡張の
結果と互換であれば、2 つの関数型は互換だと定める。`int *` と `long` はどちらも拡張で変わらない。

[`incompatible-function-pointer-argument`](incompatible-function-pointer-argument.md)(AN)とは別件である。
AN は gcc 13 が警告を出す制約違反の扱いを決める話で、こちらは gcc が警告も出さない**正しいプログラム**を
rubycc が拒否している。

## 影響

**実在の gem が落ちる。** コーパス候補 `numo-narray` 0.9.2.1 は、構造体メンバ `void (*loop_func)();`
(`ext/numo/narray/ndloop.c` の `na_md_loop_t`)へ、`ndloop_alloc` の仮引数
`void (*loop_func)(ndfunc_t*, na_md_loop_t*)` を `ndloop.c:359` で代入している。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-4)。

numo-narray は [`include-absolute-path`](include-absolute-path.md)(AO、PR #145)を直した後にここで止まった。
**2 つ目の欠陥は、1 つ目を直すまで見えなかった。**

## 受け入れ条件

- 上の最小再現がコンパイルでき、`run()` が gcc と同じく `7` を返す
- 逆向き(旧形式から仮引数付きへ)の代入と、実引数として渡す場合も同じ規則で通る
- **互換にならない組み合わせは引き続き診断する** — 仮引数に `char` / `short` / `float` を持つ関数
  (既定の実引数拡張で型が変わる)や、省略記号を持つ関数を旧形式に代入する場合を、gcc と突き合わせて決める
- `numo-narray` 0.9.2.1 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 の後、AO を直した rubycc で numo-narray を測り直して見つけた。最初は代入の相手の行を
読み違え(`lp->vargs = args;` だと思った)、両辺とも `VALUE` なのに拒否されていると誤解しかけた。
エラーの行番号どおり 359 行目を読み直して、関数ポインタの代入だと分かった。

## 決着

(未着手)
