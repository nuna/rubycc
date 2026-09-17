---
status: open
kind: gap
opened: 2026-09-18
closed:
branch:
pr:
steps: []
---

# `_Generic`(型総称選択)が無い

## 課題

**`_Generic`(ISO C11 6.5.1.1)を rubycc は式として読まない。** gcc は通す。
2026-09-18 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
int main(void) { int x = 1; return _Generic(x, int: 1, default: 0) - 1; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok(終了コード 0) |
| rubycc | **`error: expected expression`** |

glibc の `<tgmath.h>` は、コンパイラを識別したうえで `__builtin_tgmath` か `_Generic` を使う。
rubycc は `__GNUC__` を定義しない(DESIGN R7)ので `<tgmath.h>` は `#error` で止まり、
仮に識別を通しても `_Generic` が無い(`glibc-public-headers-mixed-1` の混在調査で、残る 5 本のうちの 1 本)。

## 影響

型総称マクロを書く gem。**実在の gem ではまだ見ていない**。
`_Generic` は C11 の必須機能で、既存のテストにも「対象外」として skip されているものがある
(`test/test_c_suite.rb` の skip 一覧)。

## 受け入れ条件

**先に方針を決める**(実装するか、対象外を明文化するか)。

- (実装する場合)`_Generic(式, 型: 値, ...)` の型選択が gcc と一致する(選ばれない枝は評価しない、
  制御式は左辺値変換した型で照合する、`default` の有無、重複した型はエラー)。c-testsuite の
  該当ケースの skip を外す
- (対象外にする場合)診断を「型総称選択は非対応」と分かる文言にし、ROADMAP §3 と
  `docs/reference/OUT-OF-SCOPE-GEMS.md` の基準 H に載せる。`<tgmath.h>` もそこに含める
- どちらの場合も `rake test` が 0 failures

## 作業ログ

### 2026-09-18(起票)

`glibc-public-headers-mixed-1` の調査で、`<tgmath.h>` が落ちる原因の 2 段目として見つかった。最小再現で確かめた。

## 決着

(未着手)
