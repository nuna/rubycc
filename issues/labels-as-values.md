---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# ラベルのアドレス(`&&label` / `goto *p`、GNU 拡張)を受け付けない

## 課題

**GNU 拡張の「値としてのラベル」を、rubycc は構文エラーにする。** gcc(`-std=gnu11`)は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
int f(int i) {
  static void *t[] = { &&a, &&b };
  goto *t[i];
a: return 1;
b: return 2;
}
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`error: expected expression`**(`&&a` の位置) |

**この拡張についての判断は、どこにも記録されていない。** DESIGN R7 の「それでも必要な最小限の拡張」
にも、ROADMAP §3 の「診断エラーにすると決めたもの」にも無く、`docs/` と `lib/` を
`computed goto` / `labels as values` / `&&label` で検索しても 0 件である(2026-09-13)。

**診断が原因を伝えていない。** `expected expression` からは、GNU 拡張を使っていることが分からない。

## 影響

**実在の gem が落ちる。** コーパス候補 `strptime` 0.2.5 は、`ext/strptime/strftime.c:28` で
`#define LABEL_PTR(x) &&LABEL(x)` と定義し、`strftime.c:60` と `strptime.c:103` の
ディスパッチ表で**条件なしに**使っている(`__GNUC__` の分岐も無い)。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測)。

## 受け入れ条件

**先に方針を決める**(実装するか、対象外にするか)。どちらでも、診断は直す。

- (実装する場合)上の最小再現が x86-64 と AArch64 の**両方**で gcc と同じ結果を返し、
  `strptime` 0.2.5 が rubycc でビルドできる
- (対象外にする場合)ROADMAP §3 に行を足し、診断を「GNU 拡張のラベルのアドレスは非対応」と
  分かる文言にし、`docs/reference/OUT-OF-SCOPE-GEMS.md` に `strptime` を基準 H で載せる
- どちらの場合も `rake test` が 0 failures

## 着手前に確かめること

- 実装の規模を見積もること。**関数内のラベルの番地を定数として静的初期化子に置く**必要があり
  (関数内への再配置)、`goto *expr` は間接分岐として IR に足すことになる
- 同じ理由で落ちる gem がコーパス候補に何件あるかを数えてから、規模に見合うかを判断する
  (いま分かっているのは `strptime` の 1 件だけ)

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件のうち、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
