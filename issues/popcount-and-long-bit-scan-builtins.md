---
status: open
kind: gap
opened: 2026-08-26
closed:
branch:
pr:
steps: []
---

# `__builtin_popcount*` と、ビット走査の `l` 綴りが無い

## 課題

gcc が持つビット演算の組み込み関数のうち、rubycc に無いものが 2 群ある。
実測(2026-08-26、ホスト gcc 13.3.0):

```c
#include <stdio.h>
int main(void) {
  unsigned long long x = 0xF0F0F0F0F0F0F0F0ULL;
  printf("%d %d %d\n", __builtin_popcount(0xFFu), __builtin_popcountl(0xFFFFul),
         __builtin_popcountll(x));
  return 0;
}
```

| | 結果 |
|---|---|
| gcc | `8 16 32` |
| rubycc | `error: implicit declaration of function '__builtin_popcount'` |

同じ形で `__builtin_clzl` / `__builtin_ctzl`(`long` の綴り)も無い。gcc は通る。

rubycc が既に持つのは `__builtin_ctz` / `__builtin_ctzll` / `__builtin_clz` /
`__builtin_clzll` の 4 つで(`lib/rubycc/front/lexeme_reader.rb:42`)、
**`l` の綴りだけが抜けている**。x86-64 と AArch64 では `long` と `long long` が
どちらも 8 バイトなので、`l` は `ll` と同じ幅で足りる。

## 影響

**ビットセットを扱うコードは popcount を使う。** 圧縮、インデックス、集合演算を
やる拡張は珍しくない。gcc なら通るコードが通らない。

実測(2026-08-26、[run 32880666098](https://github.com/nuna/rubycc/actions/runs/32880666098)):
コーパス候補 `roaring 0.4.1` の 4 TU 中 3 TU がこれで止まっている
(`roaring.h:365` の `__builtin_popcountll`)。
**ただし roaring はこれを直しても通らない** — 残り 1 TU が AVX2 の組み込み関数を要求する
([corpus-candidate-pilot-v2-roaring](corpus-candidate-pilot-v2-roaring.md) 参照)。
つまりこの課題は roaring のためではなく、**それ自体として**価値がある。

## 受け入れ条件

- `__builtin_popcount` / `__builtin_popcountl` / `__builtin_popcountll` が
  gcc と同じ値を返すこと(x86-64 と AArch64 の両方で、差分テストで確認する)
- `__builtin_clzl` / `__builtin_ctzl` が `ll` と同じ結果になること
- 定数畳み込みの経路でも gcc と一致すること
  (`lib/rubycc/front/constant_evaluator.rb` に `bit_scan` の前例がある)
- `bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256)

## 実装の見取り図(着手前に確認すること)

既存の `__builtin_ctz` 系は `BuiltinBitScan` として次を通る。同じ 7 ファイルに
popcount 用の対を足すのが素直に見えるが、**着手時に確かめること**。

`lib/rubycc/front/lexeme_reader.rb`(キーワード)→ `preprocess/preprocessor.rb`(同)→
`front/parser.rb`(`parse_builtin_bit_scan`、3642 行)→ `ir/generator.rb` →
`ir/ir.rb` → `backend/x86_64.rb` と `backend/aarch64.rb` → `ir/simplify.rb` /
`front/constant_evaluator.rb`

**命令の選び方に注意**: x86-64 の `popcnt` は SSE4.2 の命令で、ベースラインの
x86-64 には無い。gcc も `-mpopcnt` 無しでは命令を使わず展開する。
**どの命令列を出すかは着手時の判断**であり、ここでは決めない。

## 作業ログ

### 2026-08-26(起票)

[corpus-candidate-pilot-v2-roaring](corpus-candidate-pilot-v2-roaring.md) の 3 回目の
再走で見つけた。`l` の綴りが無いことは、その場で `__builtin_clzl` を試して確かめた。

## 決着

(未着手)
