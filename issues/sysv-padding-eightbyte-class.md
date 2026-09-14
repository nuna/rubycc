---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# x86-64 で、後半が詰め物だけの構造体を可変長引数に渡すと、xmm を 1 つ余分に使う

## 課題

**`struct { float a, b; } __attribute__((aligned(16)))`(16 バイトで、後半の 8 バイトは詰め物だけ)を x86-64 の可変長引数に渡すと、
gcc は後半にレジスタを割り当てない(この構造体を 2 個渡すと `%al = 2`)。rubycc は後半も SSE に分類して xmm を 2 個使うので、
可変長の 2 個目を `va_arg` がずれた場所から読む。** 固定引数では一致する。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で、
`aapcs64-aligned-attribute-aggregate-1` を実装したエージェントが測った。

System V の分類では、メンバの無い eightbyte は NO_CLASS になる(psABI 3.2.3)。rubycc の分類は、詰め物だけの eightbyte にも
クラスを付けているとみられる(未確認)。

## 影響

後半が詰め物だけになる整列の構造体を、可変長引数で gcc の関数とやり取りするコードで値がずれる。**実在の gem ではまだ見ていない。**

## 受け入れ条件

- 上の形を 2 個以上、可変長引数で渡したとき、rubycc → gcc と gcc → rubycc の両方向が gcc 同士と一致し、`%al` も gcc と同じになる
- 固定引数と戻り値でも同じ形が一致したまま
- `test/test_aapcs64_aligned_attribute_aggregate.rb` の x86-64 側から外した `f2_attr` の形を戻す
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`aapcs64-aligned-attribute-aggregate-1` の測定行列で見つかった。テストの x86-64 側からは理由を書いて外した。

## 決着

(未着手)
