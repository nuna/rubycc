---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 互換でない関数ポインタを実引数に渡すと、gcc 13 は警告・rubycc はエラー

## 課題

**型の合わない関数ポインタを実引数に渡すと、rubycc はエラーにする。** gcc 13 は警告だけで通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
typedef unsigned long V;
V call(V (*a)(V), V d1, V (*b)(V, V), V d2);
static V one(V s) { return s; }
V g(V s) { return call(one, s, one, s); }
```

| | 結果 |
|---|---|
| gcc 13.3 | 警告 `passing argument 3 of 'call' from incompatible pointer type [-Wincompatible-pointer-types]` |
| rubycc | **`error: incompatible type for argument 3 of 'call'`** |

rubycc のエラーは `lib/rubycc/ir/generator.rb:4227` の `compatible_assignment?` から出る。
規格上は制約違反(6.5.2.2p2 → 6.5.16.1)であり、**規格が求めるのは診断であって、拒否ではない**。

**gcc 14 は同じ入力をエラーにする。** STEPS.md の `qemu` まわりの記録(Debian trixie の gcc 14.2 で
測ったもの)が、gcc 14 は `-Wincompatible-pointer-types` を既定でエラーに格上げしたと記録している。
**つまり rubycc の挙動は gcc 14 と揃い、gcc 13 とは揃わない。** このホストに gcc 14 は無く、
下の gem を gcc 14 で直接は測っていない。

## 影響

**実在の gem が落ちる。** コーパス候補 `hpricot` 0.8.6 は `ext/fast_xs/fast_xs.c:165` で

```c
array = rb_rescue(unpack_utf8, self, unpack_uchar, self);
```

と書いている。`unpack_uchar` は `VALUE (VALUE)` だが、`rb_rescue` の第 3 引数は
`VALUE (*)(VALUE, VALUE)` である(`ruby/internal/iterator.h:364`)。
**対照の gcc 13 はビルドとロードに成功する**(2026-09-13 実測)。

## 受け入れ条件

**先に方針を決め、STEPS.md に記録する**(gcc 13 に揃えて警告に下げるか、gcc 14 に揃えてエラーを保つか)。

- (警告に下げる場合)上の最小再現が警告付きでコンパイルでき、`hpricot` 0.8.6 が rubycc でビルドできる。
  **関数ポインタ以外の互換でないポインタ**の扱いも同じ判断に含めること
- (エラーを保つ場合)gcc 14 の環境で `hpricot` 0.8.6 を測り、対照も落ちることを確かめてから
  `docs/reference/OUT-OF-SCOPE-GEMS.md` に記録する
- どちらの場合も `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件のうち、rubycc だけが落ちて対照(gcc 13)は通った 1 件。
**対照の版で結論が変わる**ので、欠陥とも対象外とも決めずに起票した。

## 決着

(未着手)
