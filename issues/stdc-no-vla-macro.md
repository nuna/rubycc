---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-13
branch: stdc-no-vla-macro
pr: 144
steps: [stdc-no-vla-macro-1]
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

### 2026-09-13(実装)

`__STDC_NO_VLA__` を定義した。同時に他の条件付き機能マクロ 3 つも実測し、
`__STDC_NO_COMPLEX__`/`__STDC_NO_THREADS__` は rubycc が未対応なので同じく定義したが、
`__STDC_NO_ATOMICS__` は `_Atomic`/`<stdatomic.h>` が実際に動くため定義しなかった
(根拠は STEPS の該当エントリ)。

レビューで `__STDC_NO_THREADS__` の根拠を直した。最初は `_Thread_local` が無いことを挙げていたが、
6.10.8.3 がこのマクロで示すのは `<threads.h>` の有無だけである。glibc の `<threads.h>` を
rubycc でコンパイルして確かめ、構造体メンバの頭の `__extension__` で止まることを見つけた
([extension-struct-member](extension-struct-member.md) に起票)。定義する結論は変わらない。

## 決着

**解消した**(`stdc-no-vla-macro-1`。設計判断・実装・実測値の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

受け入れ条件との対応:

| 受け入れ条件 | 状態 |
|---|---|
| rubycc が `__STDC_NO_VLA__` を `1` と定義する | **満たした**。`test/test_preprocessor.rb`・`test/test_stdc_no_vla_macro.rb` で検証(STEPS 参照) |
| 他の条件付き機能のマクロも同時に測り、対応状況と一致させる | **満たした**。`__STDC_NO_COMPLEX__`/`__STDC_NO_THREADS__` を追加定義、`__STDC_NO_ATOMICS__` は対応済みのため定義しなかった(根拠は STEPS) |
| 定義を足したことでコーパスの gem が別の枝を選ぶようになった場合、`rake corpus:census` で壊れていないことを確かめる | **満たした**。`rake corpus:census` を走らせ(2026-09-13)、43 gem を処理して終了コード 0。**生成される `test/corpus/include-census.md` は 1 バイトも変わらなかった** — 3 つのマクロで分岐が変わったコーパスの gem は無い |
| `brotli` 0.8.0 が rubycc でビルドできる | **未実施**。このセッションでは隔離ビルドを走らせていない。**マージ後にメインセッションが確認する** |
| `rake test` が 0 failures | **満たした**。**3,542 runs / 16,647 assertions / 0 failures / 0 errors / 39 skips** |
