---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-3
pr: 150
steps: [unprototyped-function-redeclaration-1]
---

# 旧形式で宣言した名前付き関数を、仮引数付きで再宣言・定義・呼び出しできない

## 課題

**`int f();` のように旧形式(空の `()`)で宣言した名前付き関数を、仮引数付きで再宣言・定義したり、
引数を渡して呼んだりすると、rubycc はエラーにする。** gcc は通す。
2026-09-14 にこのホスト(WSL2 / gcc 13.3、`-std=gnu11`)で測った:

| 入力 | gcc | rubycc(BD の修正の前) | rubycc(BD の修正の後) |
|---|---|---|---|
| `void f();` の後に `void f(int x) { (void)x; }` | ok | **`conflicting types for 'f'`** | 同じ |
| `int g();` の後に `int g(int);` と `int g(int x) { ... }` | ok | **`conflicting types for 'g'`** | 同じ |
| `int h();` と宣言し、`h(3)` と呼んだ後で `int h(int x) { ... }` と定義 | ok | **`too many arguments to function 'h'`** | 同じ |

C11 6.7.6.3p15 では、旧形式の関数型と、既定の実引数拡張で型の変わらない仮引数だけを持つプロトタイプは
互換である(`int` はどれも変わらない)。

**BD の修正([unprototyped-function-pointer-compat](unprototyped-function-pointer-compat.md))の範囲外の、前からある不足である。**
BD は関数ポインタ型(`Type::FunctionType` に `prototyped` を足した)と、それを使う代入・比較・呼び出し・
オブジェクトの再宣言を直した。名前付き関数の宣言は、生成器の別の表(`@signatures`)に仮引数の配列として
記録され、`prototyped` を運ばない。再宣言の照合(`declare_function` の `existing[:param_types] != param_types`)も、
呼び出しの引数の数の検査も、この表の配列を見る。

## 影響

**実在の gem ではまだ見ていない。** 古い C のヘッダは `int f();` 形の宣言を持つことがあり、
後で同じ翻訳単位に定義があると 1 行目で止まる。

## 受け入れ条件

- 上の表の 3 つの形が gcc と同じくコンパイルでき、実行結果が gcc と一致する
- 旧形式でしか宣言されていない関数を呼ぶとき、引数には既定の実引数拡張がかかる
  (BD が関数ポインタ経由の呼び出しに入れた規則と同じ)
- 互換でない組み合わせ(`int f(); int f(char);` のように、仮引数の型が拡張で変わるもの)は
  診断を保つ。gcc の扱いを先に測る
- `rake test` が 0 failures

## 着手前に確かめること

- `@signatures` に `prototyped` を持たせるか、`Type::FunctionType` そのものを持たせるかを決める。
  BD が `Type.function_types_compatible?` / `Type.composite` にまとめた規則を、そのまま使える形にすること

## 作業ログ

### 2026-09-14(起票)

BD の手直しのレビューで、エージェントが範囲外として残した形を測った。BD の修正の前と後で結果が同じなので、
BD の退行ではなく前からある不足と分かった。

### 2026-09-14(実装)

生成器の関数の宣言表(`@signatures`)に `prototyped` の鍵を足した(`Type::FunctionType` に置き換えると表を読む約 10 か所に
変更が広がるため)。再宣言は既存の宣言と新しい宣言を `Type.composite` で合成し、合成できなければ `conflicting types`、
できれば合成した型を表に書き戻す。旧形式の宣言しか見えていない関数の呼び出しは、BD が関数ポインタ経由の呼び出しに入れた
規則と同じく、引数の数を照合せず既定の実引数拡張をかける。issue の 3 形は gcc と同じくビルド・実行でき(統合時に再測定)、
互換でない組み合わせ(`int f(); int f(char);` など)は gcc と同じくエラーのまま。

## 決着

**解消した**(`unprototyped-function-redeclaration-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 3 つの形が gcc と同じくコンパイルでき、実行結果が一致する | `test/test_unprototyped_function_redeclaration.rb` が gcc 差分(ホスト / aarch64 のクロス gcc + qemu)で確認 |
| 旧形式でしか宣言されていない関数の呼び出しに既定の実引数拡張がかかる | 同じテストで確認 |
| 互換でない組み合わせは診断を保つ(gcc を先に測る) | gcc も名前付き関数の再宣言ではエラーにする。rubycc も同じ行でエラー |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
