---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
