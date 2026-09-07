---
status: done
kind: debt
opened: 2026-08-27
closed: 2026-09-07
branch: macro-hide-set-intersection
pr: 121
steps: [macro-hide-set-intersection-1]
---

# マクロ再展開の hide-set を Prosser の交差則で計算する(c-testsuite 00201)

## 課題

関数形式マクロの引数が別の関数形式マクロを経由して再展開されるとき、rubycc の
hide-set(再帰抑止の印)が gcc と食い違う。実世界の再現は c-testsuite 00201 で、
Step 27(M1)の時点で既知の逸脱として記録され、**現在も
`test/test_c_suite.rb` の `SKIP` に残っている**唯一の hide-set 由来のケースである:

```
"00201" => "macro re-expansion needs Prosser hide-set intersection (documented Step 27 deviation)"
```

最小再現(`test/external/c-testsuite/single-exec/00201.c`、期待出力は `42`):

```c
#include <stdio.h>

#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#define AB(x) CAT(x,y)

int main(void)
{
  int xy = 42;
  printf("%d\n", CAT(A,B)(x));
  return 0;
}
```

`CAT(A,B)` は `AB` に貼り合わさり、その `AB` が続く `(x)` を引数に取って
`CAT(x,y)` → `xy` まで再展開されるべきところで、rubycc は再展開を止める。
**2026-08-27 にこのホスト(WSL2 / gcc 14.2)で再測定した** — `-E` の出力が食い違う:

| | `printf` の行 |
|---|---|
| gcc `-E` | `printf("%d\n", xy);` |
| rubycc `-E` | `printf("%d\n", CAT(x,y));` |

rubycc は `CAT(x,y)` という**中間状態のまま**止まる。コンパイルするとこうなる:

```
00201.c:10:18: error: implicit declaration of function 'CAT'
  printf("%d\n", CAT(A,B)(x));
                 ^
```

**報告される場所も名前も、原因のマクロではない。** 展開が止まった残骸が
関数呼び出しに見えるため、`CAT` が未宣言関数として報告される。

**修正方針は Step 27 の時点で記録済み**であり、この課題は方針の探索ではなく実装である:
置換の paint を「**呼び出し名の suppress ∩ 閉じ括弧の suppress + 自名**」にする
(Prosser のアルゴリズムが定める hide-set の交差則)。

## 影響

**受け皿のマイルストーンが消えている。** ROADMAP §3 の負債表はこの行の解消予定を
「M2」と書いたままだが、M2 は Step 54 で完了している。どのマイルストーンにも
紐付かないまま残っている負債であり、起票の動機はここにある。

実害の記録はコーパスには無い。トークン貼り合わせを 2 段重ねるマクロは、
ヘッダの構成マクロ(`CAT` / `CONCAT` / `GLUE` の類)で使われる形である。
**現れたときの落ち方が分かりにくい**ことは上の実測で確かめた — 報告されるのは
`implicit declaration of function 'CAT'` であって、hide-set の話は一言も出てこない。

## 受け入れ条件

- `test/test_c_suite.rb` の `SKIP` から `"00201"` を消しても
  `rake test` が 0 failures(合格数が 201 → 202 に増える)
- 上記の最小再現が `stdout` バイト一致で `42` を出す(c-testsuite ランナーの判定と同じ)
- 既存の再帰抑止が壊れていないこと — **自己再帰マクロと相互再帰マクロが
  引き続き無限展開しない**ことを固定したテストが 0 failures
- `test/test_preprocessor.rb` の既存テストが 0 failures

## 作業ログ

### 2026-08-27

ROADMAP §3 の散文にだけ載っていた負債を起票した。再現・原因・修正方針は Step 27 で
揃っているので、**残っているのは実装である**。

起票にあたって現在のホスト(WSL2 / gcc 14.2)で再測定し、`-E` 出力の食い違いと
コンパイル時のエラー文言を上に記録した。**Step 27 の記述は今も正しい**。

着手時の注意: hide-set は「引数の展開」と「置換後の再スキャン」で別々に効くので、
**どちらの段で交差を取るか**を実装前に決めること。Step 27 の記録は置換 paint 側を指している。

## 決着

**解消した**(`macro-hide-set-intersection-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

関数形式マクロの置換 paint を「呼び出し名の suppress ∩ 閉じ括弧の suppress + 自名」に
変えた。**着手時の注意に挙げた「どちらの段で交差を取るか」は置換 paint 側で、
引数の展開段は触っていない。**

受け入れ条件の照合:

| 条件 | 結果 |
|---|---|
| `SKIP` から `"00201"` を消して `rake test` が 0 failures | **3417 runs / 14048 assertions / 0 failures / 0 errors / 39 skips** |
| 最小再現が `42` を出す | `-E` が gcc と同じトークン列(`printf("%d\n",xy);`。空白の入れ方だけ違う)。c-testsuite ランナーは実行結果のバイト一致で判定し、合格した |
| 自己再帰・相互再帰が引き続き止まる | 既存 4 テスト + 追加したユニットテストが 0 failures |
| `test/test_preprocessor.rb` が 0 failures | **226 runs / 0 failures / 0 skips** |

issue が書いた「合格数 201 → 202」という数値には**一致しない**。起票(2026-08-27)以降に
別の SKIP が増減しているためで、実測は `TestCSuite` の skip が 14 → 13 である。
`rake test` 全体の skip は 41 → 39 で、**2 件減るのが正しい** —
c-testsuite は `TestCSuite` と `TestCSuiteAArch64` の 2 本走るので 00201 は 2 件 skip していた。

**副産物**: 受け入れ条件の「既存の 4 挙動が壊れていないこと」を gcc と突き合わせて
確かめたところ、そのうち `f(f)(1)` は**もともと gcc と一致していなかった**
(gcc `f(1)` / rubycc `1`。`master` でも同じ)。Step 27 の記録が「一致させた」と
書いていた分を訂正し、[`macro-argument-hide-set`](macro-argument-hide-set.md)(GAPS §1 の **AC**)
として起票した。
