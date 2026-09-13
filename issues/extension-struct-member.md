---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
