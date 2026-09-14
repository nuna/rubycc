---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# glibc 本体の `<alloca.h>` を読むと、`alloca` がリンク時に未定義参照になる

## 課題

**rubycc が glibc 本体の `<alloca.h>` を読む経路では、`alloca` の呼び出しがリンク時に `undefined reference to 'alloca'` になる。**
2026-09-14 にこのホストで、`bundled-headers-coverage-audit-2` を実装したエージェントが測った。例のプログラムに `alloca` を入れ、
`test/test_examples_aarch64.rb`(aarch64 はクロス sysroot の glibc 本体のヘッダでコンパイルする)で走らせたときに起きた。

glibc の `<alloca.h>` は、`alloca` を組み込み関数に写すマクロを `__GNUC__` のときだけ定義する。rubycc は `__GNUC__` を定義しない
(DESIGN R7)ので、`alloca` は外部関数の呼び出しとして残る。glibc の共有ライブラリに `alloca` という関数は無い。

同梱ヘッダの経路(既定の探索順で同梱の `<alloca.h>` / `<stdlib.h>` を読む)では、x86-64 と aarch64 の両方で通る。

## 影響

同梱ヘッダより先に glibc 本体の `<alloca.h>` を読む構成(aarch64 のクロス sysroot を使う例題テストなど)で、`alloca` を使うコードが
リンクできない。**実在の gem ではまだ見ていない。**

## 受け入れ条件

- どの経路で glibc 本体の `<alloca.h>` を読むのかを測って書く(x86-64 と aarch64、同梱ヘッダの探索順との関係)
- その経路でも `alloca` を呼ぶプログラムが gcc と同じく動く。直し方(組み込みとして認識する名前に `alloca` を入れる、など)は
  gcc の振る舞いを測ってから決める
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`bundled-headers-coverage-audit-2` の例を aarch64 で走らせて見つかった。例からは `alloca` を外し、同梱ヘッダの経路は
`test/test_header_abi.rb` の `STDLIB_GNU` で確かめている。

## 決着

(未着手)
