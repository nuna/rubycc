---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-18
branch: gap-fixes-wave-8
pr: 158
steps: [glibc-alloca-without-gnuc-1]
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

### 2026-09-18(実装)

既定の探索順では同梱の `<alloca.h>` が必ず勝ち、そこではマクロが名前を `__builtin_alloca` に写すので問題は起きない。glibc 本体のヘッダに届くのは
**同梱の libc 層を切ったとき**(`-nostdinc` + `-I` で libc を与える構成)で、aarch64 の例題と c-testsuite のクロス実行系がそれに当たる。
gcc は `-std=gnu17` では `alloca` を**名前のまま組み込みとして**展開する(`-U__GNUC__` でも同じ)。そこで呼び出し位置で名前を見て、
`__builtin_alloca` と同じ `:alloca` に降ろすようにした。組み込みと見なす宣言の形は gcc を 10 通り測って合わせてある。

## 決着

**解消した**(`glibc-alloca-without-gnuc-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| どの経路で glibc 本体の `<alloca.h>` を読むのかを測って書く | 探索順と、そこに入る構成(`-nostdinc` + `-I`、aarch64 のクロス実行系)を STEPS に記録 |
| その経路でも `alloca` を呼ぶプログラムが gcc と同じく動く | `test/test_glibc_alloca_without_gnuc.rb`(修正前は 2 件が未解決シンボルで失敗)と `examples/m6/glibc_alloca_without_gnuc_1_stack_blocks.c`(x86-64 は同梱ヘッダ、aarch64 はクロス sysroot の glibc ヘッダを読む) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
