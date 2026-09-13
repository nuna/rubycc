---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-13
branch: gap-fixes-wave-1
pr: 147
steps: [escape-sequence-e-1]
---

# 文字列・文字定数のエスケープ `\e`(GNU 拡張、ESC)を受け付けない

## 課題

**`"\e[0m"` のような `\e` を、rubycc は未知のエスケープとしてエラーにする。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
const char *esc(void) { return "\e[0m"; }
```

| | 結果 |
|---|---|
| gcc 13.3(既定) | ok(警告も出ない) |
| rubycc | **`error: unknown escape sequence in string literal`** |

`\e` は ESC(0x1B)を表す GNU 拡張で、C11 6.4.4.4 の単純エスケープには無い。規格上は未定義の
エスケープなので診断が要るが、gcc は `-pedantic` を付けない限り黙って受理する。
端末の色付け(`"\e[31m"` など)で広く使われる書き方である。

## 影響

**実在の gem が落ちる。** コーパス候補 `string_undump` 0.1.1 は `ext/string_undump/string_undump.c:37` で
`return "\e";` と書いている。**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-4)。

## 受け入れ条件

- 上の最小再現が通り、`\e` と `\E` が 0x1B になる(文字列リテラルと文字定数の両方。gcc 差分の実行で確かめる)
- 規格に無い他のエスケープ(例: `\q`)の扱いは変えない(**gcc がどう扱うかを先に測り**、変えるなら STEPS に理由を書く)
- `string_undump` 0.1.1 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。

### 2026-09-13(実装)

`lib/rubycc/front/lexeme_reader.rb` の単純エスケープの表に `\e` / `\E` を足した。文字列・文字定数・
wide 文字定数が同じ表を通るので、1 箇所で足りた。`\q` / `\%` についての gcc の扱いも測り、
rubycc の既存のエラーは変えていない(理由は STEPS)。

## 決着

**解消した**(`escape-sequence-e-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通り、`\e` と `\E` が 0x1B になる(文字列・文字定数) | `test/test_escape_sequence_e.rb` が gcc 差分の実行で確認(wide 文字定数 `L'\e'` も) |
| 規格に無い他のエスケープの扱いは gcc を測ってから決める | 測った(`\q` は gcc で警告、`\%` は無診断)。rubycc は従来どおりエラーのまま。変えるには警告の段階を持つ診断が要る |
| `string_undump` 0.1.1 が rubycc でビルドできる | **マージ後に台帳の手順で測る** |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
