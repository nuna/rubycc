---
status: open
kind: gap
opened: 2026-08-27
closed:
branch:
pr:
steps: []
---

# 宣言の解決中に型が引けるようにして、struct を返す式を初期化子の要素として読む(GAPS T)

## 課題

struct を返す関数呼び出しを、struct 配列の初期化子の**要素**として書くと rubycc が拒否する。
gcc はブロックスコープで通す(2026-08-08 実測、`gaps-s-t-u-2` で再測定):

```c
typedef struct { int x, y; } pt;
pt fp(void);

void f(void) {
  pt b[] = { {1,2}, fp(), {5,6} };   /* gcc: 3 要素。rubycc: エラー */
}
```

現在の診断(`gaps-s-t-u-2` で文言だけ正した。**限界そのものは残っている**):

```
error: unsupported initializer: rubycc cannot tell whether this expression initializes
       a whole struct element, because its type is not known while the declaration is parsed
  pt b[] = { {1,2}, fp(), {5,6} };
                      ^
```

原因は、パーサが宣言の型を完成させる場面に**型を引く手段が無い**ことである。
struct の部分オブジェクトに立っている式が「その struct 全体を初期化する単一式」なのか
「波括弧を省略した並びの先頭」なのかを区別できず、resolver は後者と仮定してメンバへ降り、
続く項目を吸い込み、リストの末尾で溢れる。

**GAPS T の当初の記述は外れていた**(`gaps-s-t-u-2` で実測して訂正済み)。
「配列の要素数をパーサが数える文脈で」と書いていたが、**明示長 `pt b[3] = { ... }` でも同じく落ちる** —
パーサは長さ推論のためだけでなく、形の検査のためにも型無しで解決するからである。

**ファイルスコープでは gcc も拒否する**(`initializer element is not constant`)ので、
差が出るのはブロックスコープに限る。

## 影響

struct を直接初期化する形(`{1,2}`)は通るので、実害の範囲は
「**関数呼び出しの戻り値を混ぜた初期化子**」に限られる。コーパスでこの形が原因で
落ちた gem の記録は今のところ無い。

放置した場合、この形を使う gem が現れた時点でビルドが止まる。診断は
`gaps-s-t-u-2` 以降、原因の位置(型を決められなかった式)を正しく指すので、
そのときの切り分けは速い。

## 受け入れ条件

- 上の最小再現がブロックスコープで gcc と同じ 3 要素に解決し、実行結果が gcc 対照と一致する
- 明示長(`pt b[3] = { ... }`)でも同じく通る
- ファイルスコープでは引き続き診断する(gcc も拒否するため)
- `excess elements in initializer` / `excess elements in scalar initializer` が
  **本当に要素が余っているとき**(`int a[2] = {1,2,3}` / `int x = {1,2}`)には
  従来どおり出ることを固定したテストが 0 failures のまま
- `test/test_c_suite.rb` の合格数が下がらない

## 作業ログ

### 2026-08-27

ROADMAP / GAPS の散文にだけ載っていた課題を起票した。実測と診断の改善は
`gaps-s-t-u-2` で済んでおり、**残っているのは解消そのもの**である。

解消にはパーサ側に型を引く手段が要る(型表を宣言解決の途中で参照できるようにするか、
初期化子の解決を型が確定した後段へ遅らせるか)。どちらを採るかは未決。

## 決着

(未着手)
