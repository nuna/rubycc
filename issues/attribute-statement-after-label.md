---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-3
pr: 150
steps: [attribute-statement-after-label-1]
---

# ラベルの直後に単独で置いた属性の文を受け付けない

## 課題

**`case` ラベルの直後に `__attribute__ ((fallthrough));` を単独で置くと、rubycc は構文エラーにする。**
gcc は通す。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で、`attribute-statement-1` を入れた rubycc で測った:

```c
int f(int x) {
  switch (x) {
  case 1:
    __attribute__ ((fallthrough));
  case 2:
    return x + 10;
  }
  return 0;
}
int main(void) { return f(1); }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`attr_after_label.c:4:5: error: expected expression`** |

`attribute-statement-1` はブロックの要素(`parse_block_item`)として現れる属性の文を直した。
ラベルの直後の 1 文は `parse_nested_statement` から `parse_statement` を直接呼ぶ経路で読まれ、
`parse_block_item` を通らないので、この修正が届かない(実装したエージェントの報告と、上の実測で確認)。

## 影響

空の case から次の case へ落とすとき(`case 1:` の本体が無い形)に `-Wimplicit-fallthrough` を黙らせる書き方である。
**実在の gem ではまだ見ていない**(liquid-c 4.2.0 は実文の後に置く形で、`attribute-statement-1` で直った側)。

## 受け入れ条件

- 上の最小再現がコンパイルでき、`f(1)` が gcc と同じ値を返す
- `default:` や通常のラベル(`L:`)の直後でも同じく通る
- 属性の後が `;` 以外(別の文)ならエラーのまま(gcc と同じ)
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

`attribute-statement-1` の統合時に、実装したエージェントが対象外として報告した形を最小再現で確かめて起票した。

### 2026-09-14(実装)

`#parse_block_item` の属性の空文の処理を `#parse_attribute_only_statement` に切り出し、ラベルの後の 1 文を読む
`#parse_statement` でも同じ判定で呼ぶようにした(コードの重複なし)。gcc を測ると、`case 1:` / `default:` / 通常のラベルの
直後の属性の空文はどれも通り、属性の後が `;` 以外ならエラー。通常のラベルの後の「属性 + 宣言」は gcc のラベル属性の拡張で
通るが、本件の範囲外とした(STEPS)。

## 決着

**解消した**(`attribute-statement-after-label-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現がコンパイルでき、`f(1)` が gcc と同じ値を返す | `test/test_attribute_statement_after_label.rb` が gcc 差分で確認(`f(1)` = 11) |
| `default:` や通常のラベルの直後でも通る | 同じテストで確認 |
| 属性の後が `;` 以外ならエラーのまま | 同じテストで確認 |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
