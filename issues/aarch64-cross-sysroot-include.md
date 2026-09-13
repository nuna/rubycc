---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# `-target aarch64` で、同梱していないシステムヘッダをクロス sysroot から探さない

## 課題

**x86-64 のホストで `-target aarch64` を付けると、rubycc が同梱していないシステムヘッダ(`<netdb.h>` など)を
ホスト自身の x86-64 版から読み、その先で落ちる。** 対照の `aarch64-linux-gnu-gcc` は通る。
2026-09-14 にこのホスト(WSL2 / x86-64、`libc6-dev-arm64-cross` 導入済み)で測った:

```c
#include <netdb.h>
int main(void) { return 0; }
```

| | 結果 |
|---|---|
| `aarch64-linux-gnu-gcc -c` | ok |
| `rubycc -target aarch64 -c` | **`/usr/include/netdb.h:28:1: error: bits/stdint-uintn.h: No such file or directory`** |

`Preprocessor::LIBC_MULTIARCH_INCLUDE_DIRS` は aarch64 のシステム探索パスを `/usr/include/aarch64-linux-gnu` +
`/usr/include` としている。このホストには `/usr/include/aarch64-linux-gnu` が無く、Debian のクロス
パッケージは独立した sysroot `/usr/aarch64-linux-gnu/include` にヘッダを置く。そのため `/usr/include/netdb.h`
(x86-64 のホスト版)が見つかり、それが引く `bits/stdint-uintn.h` は x86-64 の multiarch ディレクトリにしか
無いので見つからない。

## 影響

- ネイティブの aarch64 ホスト(`/usr/include/aarch64-linux-gnu` が実在する)では起きないはず。未測定
- **x86-64 ホストでのクロステスト**が、同梱していないヘッダを含むコードを aarch64 で検証できない。
  `bundled-pthread-attr-guard-1` の aarch64 テストは、実物の `<netdb.h>` の代わりに手書きの代替を使った
- 探索結果が見つからないだけでなく、**別アーキテクチャのヘッダを黙って読む**点が危うい。今回は途中で
  落ちたが、通ってしまえば x86-64 の型の配置で aarch64 のコードを作ることになる

## 受け入れ条件

- 上の最小再現が、このホストで `rubycc -target aarch64 -c` でコンパイルでき、`aarch64-linux-gnu-gcc` と同じく通る
- ネイティブの aarch64 ホスト(`/usr/include/aarch64-linux-gnu` が実在する構成)の探索順が変わらない
- x86-64 で `-target aarch64` のとき、x86-64 のホスト版のヘッダを読まない(読むなら理由を STEPS に書く)
- `bundled-pthread-attr-guard-1` の aarch64 テストを実物の `<netdb.h>` に置き換えて通る
- `rake test` が 0 failures

## 着手前に確かめること

- クロス sysroot の場所を決め打ちにするか、`aarch64-linux-gnu-gcc -print-sysroot` などで問い合わせるか
- ギャップ V(aarch64 ホストで multiarch ディレクトリを探さなかった件)の STEPS の判断と矛盾しないこと

## 作業ログ

### 2026-09-14(起票)

`bundled-pthread-attr-guard-1` の aarch64 テストを書いたエージェントが対象外として報告した形を、最小再現で確かめて起票した。

## 決着

(未着手)
