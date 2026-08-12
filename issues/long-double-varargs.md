---
status: open
kind: gap
opened: 2026-08-12
closed:
branch:
pr:
steps: []
---

# 可変長引数に渡した `long double` を libc が読める形で積む

## 課題

rubycc は `long double` を 8 バイトの `double` として扱う(DESIGN §3.3 の既知の制限)。
x86-64 psABI は 80 ビット x87 を 16 バイトで、AArch64 は IEEE binary128 を渡す。

可変長引数に渡すと**呼ばれた側が読む幅と積んだ幅が食い違う**。最小再現
(2026-08-08、glibc x86-64 / gcc 13):

```c
printf("[%Lg]\n", (long double)1.234567);
```

| | 出力 |
|---|---|
| gcc | `[1.23457]` |
| rubycc | `[7.46537e-4948]` |

実 gem での実害も測れている: `oj` の `usual.c:470` が
`sprintf(buf, "%Lg", p->num.dub)` を使い、`UsualTest#test_decimal` が
`ArgumentError: invalid value for BigDecimal(): "-nan"` で落ちる。
**gcc 対照と食い違う唯一のテスト**である(`atomic-type-12` で失敗テスト名の集合を突き合わせ、
gcc 75 件・rubycc 76 件、差分はこの 1 件だけと確認)。

## 影響

`long double` を計算に使うだけなら double の範囲と精度で動くが、**libc の境界を越えると
値が壊れる**。壊れ方が「エラー」ではなく「もっともらしい別の数値」なので、
利用者が気づきにくい。

R10 では `oj` が唯一の未通過要因として残っている(コーパス合格率は 31/34 = 91.2% で
達成済みなので、合格率のためではなく正しさのために直す)。

## 受け入れ条件

- `printf("%Lg", (long double)x)` の出力が gcc と一致する(x86-64・AArch64 の両方)
- `oj` の上流スイートで `UsualTest#test_decimal` が通り、失敗テスト名の集合が gcc 対照と一致する
- 既存の ABI ハーネスと全スイートに回帰がない

## 作業ログ

### 2026-08-12

着手前の設計方針を 2 段階で決めた(`docs/development/ROADMAP.md` §3 の負債表に記録済み)。

- **第 1 段**: 可変長引数に渡すときだけ、double を 80 ビット拡張形式(AArch64 は
  binary128)に変換して積む。**double は両形式の部分集合なので変換は無損失**で、
  観測されている実害はこれで閉じる。`sizeof(long double)` が 8 のままである食い違いは残る
- **第 2 段**: x87 / binary128 の演算そのもの。パーサ・定数畳み込み・ABI 分類・`va_arg` に及ぶ

v1.0 では挙動を変えず、README と CHANGELOG の既知の制限に明記する判断を取った
(`gaps-s-t-u-3`)。理由: 実害が測定済みで oj の 1 テストに限定される一方、
可変長引数の `long double` を診断エラーにすると**今ビルドできている gem が
ビルドできなくなる**副作用の方が広い。

## 決着

(未着手)
