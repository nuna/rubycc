---
status: done
kind: gap
opened: 2026-09-07
closed: 2026-09-08
branch: macro-argument-hide-set
pr: 122
steps: [macro-argument-hide-set-1]
---

# 引数から届いたマクロ名にも hide-set を足す(`f(f)(1)` が gcc と食い違う)

## 課題

関数形式マクロの**引数として渡されたマクロ名**が、置換後の再走査で新しい呼び出しを
作れてしまう。gcc は作らせない。**2026-09-07 にこのホスト(WSL2 / gcc 14.2)で
`-E` を実測した**:

```c
#define f(x) x
f(f)(1)
```

| | 出力 |
|---|---|
| gcc | `f(1)` |
| rubycc | `1` |

`master`(`26db8da`)でも同じ出力で、`macro-hide-set-intersection-1` の
交差則導入で生じたものではない(同ステップ中に両方を実測して確認した)。

原因は置換トークンの塗り方にある。`lib/rubycc/preprocess/preprocessor.rb` の
`substitute` は、**引数由来のトークンには自分の paint を保たせ、マクロ名を足さない**
(Step 27 の設計判断)。そのため引数から来た `f` は無印のままソースの `(1)` に届く。

Prosser のアルゴリズムは `subst` の最後に `hsadd(HS, OS)` を置き、**引数由来を含む
出力トークン全部**に hide-set を足す。規格 6.10.3.4p2 の「置換リストの走査中に
置換中のマクロ名が現れたら置換しない」も同じ側を指す。**gcc・Prosser・規格の 3 つが
揃って `f(1)` 側で、rubycc だけが `1` を出す。**

同じ 5 つの形を並べて測ると、食い違うのはこの 1 件だけである(2026-09-07 実測):

| 形 | gcc | rubycc |
|---|---|---|
| `#define f(x) f(x)` / `f(1)` | `f(1)` | `f(1)` |
| `#define g f` `#define f(x) x` / `g(3)` | `3` | `3` |
| **`#define f(x) x` / `f(f)(1)`** | **`f(1)`** | **`1`** |
| `#define a b(a)` `#define b(x) x` / `a` | `a` | `a` |
| c-testsuite 00201 | `xy` | `xy` |

周辺も測ったところ、**`#define g(x) x` / `#define h g` に `h(g)(2)`** も同じ規則で
食い違っていた(gcc `g(2)` / 変更前 `2`)。本ステップで一緒に一致した。

## 影響

**Step 27 の記録がこの 1 件を「gcc と一致させた」と書いており、事実と違う。**
記録側の訂正は `macro-hide-set-intersection-1` で入れた(STEPS.md の該当節)。

実害の記録はコーパスには無い。**現れるのは「マクロ名そのものを引数に渡し、その直後に
括弧が続く」形**に限られ、普通のヘッダには出にくい。rubycc の方が余計に展開するので、
落ち方は「展開しすぎた結果、未定義の識別子や引数の数の不一致」として現れる。

`test/test_preprocessor.rb` の `test_macro_name_from_an_argument_still_expands` は
**現在の(食い違う側の)挙動を固定している**。直すときはこのテストの期待値ごと変える。

## 受け入れ条件

- 上の 5 つの形すべてで `-E` の出力が gcc と一致する(`f(f)(1)` → `f(1)`)
- c-testsuite 00201 が引き続き合格する(交差則と両立すること)
- `test/test_preprocessor.rb` / `test/test_c_suite.rb` が 0 failures。
  **自己再帰・相互再帰が引き続き無限展開しない**
- 引数を一度だけ展開してメモ化する `Invocation#expanded` の性質が壊れていないこと
  (同じ引数を複数回使うマクロで展開回数が増えない)

## 作業ログ

### 2026-09-07

`macro-hide-set-intersection-1`(閉じ括弧との hide-set 交差)の検証中に、
Step 27 が「gcc と一致」と記録している 4 挙動を**実際に gcc と突き合わせて**発見した。
記録を信じずに測ったことが発見の経路である。

その場では直さず起票した。交差則の変更と混ぜると、00201 が通った理由と
`f(f)(1)` が変わった理由が 1 つの差分に同居して切り分けられなくなるため。

## 作業ログ

### 2026-09-08

実装した(`macro-argument-hide-set-1`)。`substitute` の出口で、返すトークン列**全部**に
その呼び出しの paint を足す(Prosser の `subst` 末尾の `hsadd`)。引数の展開そのもの
(`expand_argument`)は 6.10.3.1 どおり触っていない。

**非識別子も塗る必要がある。** 直前のステップ(`macro-hide-set-intersection-1`)で
閉じ括弧の suppress が交差計算の入力になったので、置換が産んだ `)` が paint を失うと
`#define f(x) g(x)` / `#define g(x) f(x)` の相互再帰が止まらなくなる。
「suppress を見るのは識別子だけ」という最適化は、前ステップによって罠に変わっていた。
止まることは実測で確認した(gcc・rubycc とも `f(1)`)。

## 決着

**解消した**(`macro-argument-hide-set-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

受け入れ条件の照合(2026-09-08、WSL2 / gcc 14.2):

| 条件 | 結果 |
|---|---|
| 5 つの形すべてで `-E` が gcc と一致(`f(f)(1)` → `f(1)`) | **一致**(下表) |
| c-testsuite 00201 が引き続き合格 | 合格(`xy`)。`test_c_suite.rb` の skip も 13 件のまま |
| 自己再帰・相互再帰が止まる | `#define f(x) g(x)` / `#define g(x) f(x)` が gcc と同じく `f(1)` で停止 |
| `Invocation#expanded` のメモ化が壊れていない | 塗り直しは**コピーを作る**ので、同じ引数を複数回使っても展開は 1 回のまま |

| 形 | gcc | rubycc |
|---|---|---|
| `#define f(x) f(x)` / `f(1)` | `f(1)` | `f(1)` |
| `#define g f` `#define f(x) x` / `g(3)` | `3` | `3` |
| **`#define f(x) x` / `f(f)(1)`** | **`f(1)`** | **`f(1)`** |
| `#define a b(a)` `#define b(x) x` / `a` | `a` | `a` |
| c-testsuite 00201 | `xy` | `xy` |
