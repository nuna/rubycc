---
status: open
kind: gap
opened: 2026-09-18
closed:
branch:
pr:
steps: []
---

# `_Complex` 型が無い

## 課題

**`_Complex`(ISO C11 6.2.5p11、型指定子)を rubycc は型として読まない。** gcc は通す。
2026-09-18 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
double _Complex f(double _Complex z);
int main(void) { return 0; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: expected ';'`**(`_Complex` の位置) |

glibc の `<complex.h>` は `bits/cmathcalls.h` の `__MATHCALL` が `double _Complex` に展開されるため、
**この型が無いと `<complex.h>` を含む翻訳単位が 1 つもコンパイルできない**(`glibc-public-headers-mixed-1` の
混在調査で、残る 5 本のうちの 1 本)。

## 影響

`<complex.h>` を含む gem。**実在の gem ではまだ見ていない**(コーパス候補では未確認)。
C11 の必須機能ではない(`__STDC_NO_COMPLEX__` を定義すれば規格準拠のまま外せる)。

## 受け入れ条件

**先に方針を決める**(実装するか、対象外にするか)。

- (対象外にする場合)`__STDC_NO_COMPLEX__` を定義し、`_Complex` を使ったときの診断を
  「複素数型は非対応」と分かる文言にする。`docs/reference/OUT-OF-SCOPE-GEMS.md` の基準 H の説明に加える
- (実装する場合)`float` / `double` / `long double` の複素数型、算術・比較、`creal` / `cimag` などの
  libc 呼び出し、引数渡しと戻り値の ABI(x86-64 と AArch64)を gcc と突き合わせる
- どちらの場合も `rake test` が 0 failures

## 作業ログ

### 2026-09-18(起票)

`glibc-public-headers-mixed-1` の調査で、`<complex.h>` が落ちる原因として見つかった。最小再現で確かめた。

## 決着

(未着手)
