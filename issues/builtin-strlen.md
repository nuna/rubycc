---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
