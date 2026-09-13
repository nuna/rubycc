---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# rmake が GNU make の条件文(`ifeq` など)を読めない

## 課題

**rmake は Makefile の条件文を 1 つも受け付けない。** `lib/rubycc/rmake/parser.rb` の
`handle_normal`(121〜133 行)は、行を「代入」か「`:` を含むルール」のどちらかとして読み、
**それ以外はすべて `cannot parse line` の `ParseError`** にする。`ifeq` / `ifneq` / `ifdef` / `ifndef` /
`else` / `endif` はどれもこの経路に落ちる(2026-09-13、コードで確認)。

実例のエラー(2026-09-13 実測):

```
rmake: Makefile:9: cannot parse line: "ifeq ($(USE_SSL),1)"
```

## 影響

**実在の gem が落ちる。** コーパス候補 `hiredis-client` 0.30.1 は、`extconf.rb` の中で同梱の hiredis を
make でビルドする。RubyGems プラグインが差し込む `MAKE`(= rmake)がその
`ext/redis_client/hiredis/vendor/Makefile` を読み、9 行目の `ifeq ($(USE_SSL),1)` で止まる。
このファイルには条件文の行が 28 行ある。**対照(GNU make)はビルドに成功する**
(2026-09-13 実測、buildable-gems-batch-3)。

mkmf が生成する Makefile は条件文を使わないので、**extconf.rb だけでビルドする gem には影響しない**。
影響するのは、同梱ライブラリの手書き Makefile を make に渡す gem である。

## 受け入れ条件

**先に方針を決め、STEPS.md に記録する**(条件文の部分集合に対応するか、対象外にするか)。

- (対応する場合)`ifeq` / `ifneq` / `ifdef` / `ifndef` / `else` / `endif` の入れ子を含むテストが、
  GNU make と同じ変数値・同じレシピを選ぶ。`hiredis-client` 0.30.1 が rubycc でビルドできる
- (対象外にする場合)`docs/reference/OUT-OF-SCOPE-GEMS.md` に基準と `hiredis-client` を載せ、
  rmake の診断が「GNU make の条件文は非対応」と分かる文言になる
- どちらの場合も `rake test` が 0 failures

## 着手前に確かめること

- [`rmake-automake-shell-recipes`](rmake-automake-shell-recipes.md)(done)が決めた rmake の範囲を読み、
  **その判断と矛盾しない**方針にすること
- 同じ理由で落ちる gem がコーパス候補に何件あるかを数えてから、規模に見合うかを判断する

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc 側(rmake)だけが落ちて対照は通った 1 件。

## 決着

(未着手)
