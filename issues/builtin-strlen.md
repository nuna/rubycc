---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-13
branch: gap-fixes-wave-2
pr: 148
steps: [builtin-strlen-1, builtin-strlen-2]
---

# `__builtin_strlen` が無い

## 課題

**`__builtin_strlen` を、rubycc は未宣言の関数として報告する。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
unsigned long f(void) { return __builtin_strlen("abc"); }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: implicit declaration of function '__builtin_strlen'`** |

DESIGN R7 は「`__builtin_expect`, `__builtin_alloca`, `__builtin_va_*`, 主要な `__builtin_*`」を
必須の拡張に挙げている。`__builtin_strlen` はこの一覧に名前が無く、実装も無い。

gcc は文字列リテラルに対する `__builtin_strlen` を**定数に畳む**。上の `f` は `3` を返す。

## 影響

**実在の gem が落ちる。** コーパス候補 `herb` 0.10.4 は、`src/include/lib/hb_string.h:27` のマクロの中で
`(uint32_t) __builtin_strlen(string)` と書き、多くのソースがこのマクロを使う。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-4)。

## 受け入れ条件

- 上の最小再現が通り、gcc と同じ値を返す。文字列リテラル以外の引数(`char *` 変数)でも通る
- **文字列リテラルの場合に定数式として使えるか**を gcc と比べて決める(静的初期化子や配列の大きさの位置)
- 同じ系統の `__builtin_mem*` / `__builtin_str*` のうち、rubycc に無いものを数え、足す範囲を STEPS に書く
- `herb` 0.10.4 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。

### 2026-09-13(実装)

文字列リテラルの引数は構文段階で `unsigned long` の定数に畳み、それ以外は `strlen` の呼び出しに書き換えた
(`__builtin_memcpy` と同じ形)。gcc で測ると、畳んだ値は配列の大きさ・静的初期化子・`_Static_assert`・
`case` ラベルのどれでも使えたので、rubycc も同じ位置で使える。同族の `__builtin_mem*` / `__builtin_str*` の
うち rubycc に無いのは 11 綴りで、需要が出るまで足さない(STEPS)。

### 2026-09-14(退行の修正)

`builtin-strlen-1` の後にブランチ全体で `rake test` を走らせると、**18 件が `conflicting types for 'strlen'` で落ちた**。
最初から登録した `strlen` のプロトタイプが、プログラム自身の宣言(c-testsuite 00025 の `int strlen(char *);`、
aarch64 の glibc の `size_t strlen(const char *)` — aarch64 では素の `char` が符号無し)と衝突していた。
`builtin-strlen-1` を実装したときは x86 の対象テストしか走らせておらず、aarch64 と c-testsuite を見ていなかった。
`builtin-strlen-2` で、最初から登録するプロトタイプに印を付け、プログラムの最初の宣言に黙って譲るようにした
(`memcpy` も同じ扱い)。`__builtin_strlen` の型は、gcc と同じく組み込みのまま保つ。

## 決着

**解消した**(`builtin-strlen-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通り gcc と同じ値を返す。`char *` 変数の引数でも通る | `test/test_builtin_strlen.rb` が gcc 差分の実行で確認 |
| 文字列リテラルの場合に定数式として使えるかを gcc と比べて決める | gcc は 4 つの位置すべてで通す。rubycc も同じく通る |
| 同族のビルトインのうち無いものを数え、足す範囲を STEPS に書く | 11 綴り。需要が出るまで足さない |
| `herb` 0.10.4 が rubycc でビルドできる | **マージ後に台帳の手順で測る** |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
