---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 文として書いた `__attribute__ ((fallthrough));` を受け付けない

## 課題

**`switch` の中で `__attribute__ ((fallthrough));` を文として書くと、rubycc は構文エラーにする。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
int f(int x) {
  switch (x) {
  case 1:
    x += 1;
    __attribute__ ((fallthrough));
  case 2:
    return x;
  }
  return 0;
}
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`fallthrough.c:5:5: error: expected type specifier`** |

GNU の文属性(空文に付ける `__attribute__`)で、C23 の `[[fallthrough]];` と同じ意味を持つ。
DESIGN R7 は `__attribute__((...))` の**構文受理**を必須の拡張に挙げているが、rubycc は宣言の中の属性しか
読まず、**文の頭の属性**は宣言の始まりとして読んで型指定子を探し、そこで止まる。

## 影響

**実在の gem が落ちる。** コーパス候補 `liquid-c` 4.2.0 は `ext/liquid_c/parser.c:242` で
`__attribute__ ((fallthrough));` と書いている。**対照の gcc はビルドに成功する**(2026-09-13 実測、
buildable-gems-batch-4)。`-Wimplicit-fallthrough` を黙らせるための書き方なので、他の gem にもあると見込む。

## 受け入れ条件

- 上の最小再現が通り、`f(1)` と `f(2)` が gcc と同じ値を返す
- `__attribute__((fallthrough))` 以外の文属性も**構文として受理して無視する**か、未知の属性として診断するかを決め、
  STEPS に書く(R7 の「aligned / packed 以外は無視」との整合)
- 宣言の頭の `__attribute__`(`__attribute__((unused)) int x;` など)の扱いは変えない
- `liquid-c` 4.2.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
