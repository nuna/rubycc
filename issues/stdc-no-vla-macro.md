---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 可変長配列に対応しないのに `__STDC_NO_VLA__` を定義していない

## 課題

**rubycc は可変長配列(VLA)を受け付けないが、`__STDC_NO_VLA__` を定義していない。**
C11 6.10.8.3 は、VLA に対応しない処理系がこのマクロを `1` と定義することを定めている。
DESIGN R7 は VLA を「オプション扱い」とし、ROADMAP §3 は診断エラーにすると決めている。

2026-09-13 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#ifdef __STDC_NO_VLA__
int no_vla = 1;
#else
int no_vla = 0;
#endif
```

| | 前処理の結果 | VLA |
|---|---|---|
| gcc | `int no_vla = 0;` | 対応している |
| rubycc | `int no_vla = 0;` | **対応していない**(`array size must be an integer constant`) |

**移植性のあるコードは、このマクロを見て VLA を避ける。** 定義が無いと、rubycc は「VLA に対応している」と
名乗ったうえで、VLA の経路でエラーになる。

## 影響

**実在の gem が落ちる。** コーパス候補 `brotli` 0.8.0 の同梱 `vendor/brotli/c/include/brotli/port.h:257-263` は

```c
#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 199901L) &&   \
    !defined(__STDC_NO_VLA__) && !defined(__cplusplus) && ...
#define BROTLI_ARRAY_PARAM(name) (name)
#else
#define BROTLI_ARRAY_PARAM(name)
#endif
```

と書き、`shared_dictionary.h:94` の仮引数 `const uint8_t data[BROTLI_ARRAY_PARAM(data_size)]` を
VLA にするか空の `[]` にするかを選んでいる。rubycc ではここが
`array size must be an integer constant` になる。**対照の gcc はビルドとロードに成功する**
(2026-09-13 実測、buildable-gems-batch-3)。**マクロを定義すれば、brotli は VLA を使わない枝を選ぶ。**

## 受け入れ条件

- rubycc が `__STDC_NO_VLA__` を `1` と定義する
- 他の条件付き機能のマクロ(`__STDC_NO_ATOMICS__` / `__STDC_NO_COMPLEX__` / `__STDC_NO_THREADS__`)も
  **同時に測り**、rubycc の対応状況と一致させる(一致しないものは理由を STEPS に書く)
- 定義を足したことで**コーパスの gem が別の枝を選ぶようになった場合**、その gem のビルドが壊れていないことを
  `rake corpus:census` で確かめる
- `brotli` 0.8.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。最初は「仮引数の VLA
(6.7.6.3p7 でポインタに読み替わるので、本物の VLA より狭い)」を別の欠陥として立てるつもりだったが、
brotli の分岐条件を読んで、マクロ 1 つで足りると分かった。

## 決着

(未着手)
