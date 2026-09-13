---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-13
branch: gap-fixes-wave-1
pr: 147
steps: [extension-struct-member-1]
---

# 構造体のメンバ宣言の頭の `__extension__` を受け付けない

## 課題

**`__extension__` を構造体のメンバ宣言の頭に付けると、rubycc は構文エラーにする。** gcc は通す。
宣言の頭に付く形は rubycc も通す。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

| 入力 | gcc | rubycc |
|---|---|---|
| `struct s { __extension__ unsigned long long int v; int w; };` | ok | **`error: expected type specifier`** |
| `int g(void) { __extension__ long long a = 3; return (int)a; }` | ok | ok |

パーサは宣言の頭に並ぶ `__extension__` を読み飛ばしている(`lib/rubycc/front/parser.rb:518` と、
`1634` 行からの補助メソッド)が、**構造体のメンバ宣言を読む経路では読み飛ばしていない**。

## 影響

**glibc の `<threads.h>` が rubycc でコンパイルできない。** `<threads.h>` が読み込む
`bits/atomic_wide_counter.h:27` が `__extension__ unsigned long long int __value64;` をメンバに持つためである。
C11 の `thrd_create` / `thrd_join` を使う小さなプログラムは、gcc ではビルドして実行でき(出力 `42`)、
rubycc では上のエラーで止まる(2026-09-13 実測)。

このため `stdc-no-vla-macro-1` は `__STDC_NO_THREADS__` を定義した。**この issue が閉じたら、
その判断は測り直す必要がある**(`lib/rubycc/preprocess/preprocessor.rb` のコメントにも書いた)。

## 受け入れ条件

- 上の表の 1 行目が gcc と同じく通り、構造体の配置(`sizeof` / `offsetof`)が gcc と一致する
- 共用体のメンバ、入れ子の構造体のメンバでも同じく通る
- 上の `<threads.h>` のプログラムが rubycc でビルドでき、gcc と同じ出力になる。
  そのうえで `__STDC_NO_THREADS__` の定義を外すかどうかを測り直し、STEPS に記録する
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

`stdc-no-vla-macro-1` のレビューで、`__STDC_NO_THREADS__` の根拠を確かめるために glibc の
`<threads.h>` を rubycc でコンパイルして見つけた。

### 2026-09-13(実装)

構造体・共用体のメンバ宣言を読むループの先頭で、既存の `__extension__` の読み飛ばしを呼んだ。
その結果、`thrd_create` / `thrd_join` のプログラムが rubycc でビルド・リンク・実行でき、gcc と同じ
`42` を出した。**その先で止まる別のエラーは無かった。** そこで `__STDC_NO_THREADS__` の定義を外した。

## 決着

**解消した**(`extension-struct-member-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通り、配置(`sizeof` / `offsetof`)が gcc と一致する | `test/test_extension_struct_member.rb` で確認 |
| 共用体のメンバ、入れ子の構造体のメンバでも通る | 同じテストで確認 |
| `<threads.h>` のプログラムが rubycc でビルドでき gcc と同じ出力になる。`__STDC_NO_THREADS__` を測り直す | ビルド・実行とも一致(`42`)。**`__STDC_NO_THREADS__` の定義を外した**(C11 6.10.8.3 は `<threads.h>` の有無だけに結びつける) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
