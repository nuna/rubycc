---
status: in-progress
kind: gap
opened: 2026-08-25
closed:
branch: byte-order-predefined-macros
pr:
steps: []
---

# gcc が予約している byte order の定義済みマクロ 5 件を揃える

## 課題

gcc は次の 5 つを定義済みマクロとして持つが、**rubycc はどれも持たない**。
実測(2026-08-25、ホスト gcc 13.3.0 と `aarch64-linux-gnu-gcc`、`-dM -E </dev/null`)。
**x86-64 と aarch64 で値は同一**である:

```
#define __ORDER_LITTLE_ENDIAN__ 1234
#define __ORDER_BIG_ENDIAN__ 4321
#define __ORDER_PDP_ENDIAN__ 3412
#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__
#define __FLOAT_WORD_ORDER__ __ORDER_LITTLE_ENDIAN__
```

最小再現(`endian_probe.c`):

```c
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__)
  printf("gcc-style endian macros: present, big=%d\n", __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__);
#else
  printf("gcc-style endian macros: ABSENT\n");
#endif
```

| | 出力 |
|---|---|
| gcc | `gcc-style endian macros: present, big=0` |
| rubycc | `gcc-style endian macros: ABSENT` |

同梱ヘッダが持つのは **glibc の綴り**(`include/libc/glibc/x86_64/endian.h` の
`__BYTE_ORDER` / `__LITTLE_ENDIAN`)だけで、**gcc がコンパイラ側で定義する
`__..__` の綴りとは別物**である。`__GNUC__` を定義しない方針
(`test_gnuc_is_not_predefined`)とも別で、この 5 件は clang も同じ値で定義する。

## 影響

**移植性のあるコードは、この 5 件で分岐を選ぶ。**選べないと、gcc なら通らない側の枝へ落ちる。

実測(2026-08-25、[run 32849373119](https://github.com/nuna/rubycc/actions/runs/32849373119)、
`corpus-candidate-validation` の `build_load`、Ruby 4.0.6):
コーパス候補 `roaring 0.4.1`(CRoaring amalgamation)の `roaring.h:464` が

```c
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__)
```

で分岐し、gcc は真の側を取る。rubycc は**偽の側**へ入り、その枝にある
**上流の壊れた行**に当たってビルドが止まる:

```
./roaring.h:486:9: error: macro names must be identifiers
#ifndef !defined(__BYTE_ORDER__) || !defined(__ORDER_LITTLE_ENDIAN__)
```

`#ifndef` に識別子以外を書いたこの行は上流 CRoaring の誤りだが、**gcc は
その枝を読まないので一度も診断しない**。rubycc の診断自体は正しく、gcc と同じ文言である。
つまりこれは診断の問題ではなく、**分岐の選択が gcc と違う**という問題である。

## 受け入れ条件

- 5 件が `gcc -dM -E </dev/null` と**同じ綴り・同じ値**で定義済みになる
  (`__BYTE_ORDER__` と `__FLOAT_WORD_ORDER__` は数値ではなく
  `__ORDER_LITTLE_ENDIAN__` という**マクロ参照**に展開され、`#if` の中で再展開される)
- x86-64 と aarch64 の**両方**で同じ値になる(上表のとおり両者同一)
- `#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__)` が gcc と同じ枝を選ぶ
  差分テストが `test/test_preprocessor.rb` にある
- 既存方針を壊さない — `__GNUC__` は**引き続き未定義**であること
  (`test_gnuc_is_not_predefined` が通り続ける)
- 5 件が `#undef` できること(他の定義済みマクロと同じ扱い)
- `bundle exec rake test` が 0 failures

## 作業ログ

### 2026-08-25(起票)

[corpus-candidate-pilot-v2-roaring](corpus-candidate-pilot-v2-roaring.md) の再走で見つけた。
`#warning`([warning-directive](warning-directive.md)、PR #84)を直した結果、roaring の
ビルドは `#warning` を警告として通過するようになり、**次の停止点としてこれが出た**。

### 2026-08-25(実装)

5 件を `PREDEFINED_NUMERIC_MACROS` に追加した。`__BYTE_ORDER__` と `__FLOAT_WORD_ORDER__` は
数値ではなく `__ORDER_LITTLE_ENDIAN__` への参照として持つ(`__WCHAR_MIN__` と同じ規約)。

**テストは 2 度書いた。** 最初の 4 件のうち 2 件が、無改変ツリーでも通ってしまっていた —
`#if` の中で未定義の識別子が 0 に畳まれるので、`__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__` は
修正前も `0 == 0` で真になる。差別できる 6 件に書き直し、**無改変ツリーで 6 件すべてが
落ちる**ことを master の worktree で実測した。

## 決着

設計記録は `docs/development/STEPS.md` の `byte-order-predefined-macros-1`。
