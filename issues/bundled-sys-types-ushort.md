---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-5
pr: 153
steps: [bundled-sys-types-ushort-1]
---

# 同梱 `sys/types.h` の `ushort` が `unsigned char` になっている

## 課題

**同梱の `sys/types.h` は `ushort` を `unsigned char` と定義している。glibc は `unsigned short`。** 2026-09-14 にこのホスト
(WSL2 / gcc 13.3)で測った:

```c
#include <sys/types.h>
int main(void) { return sizeof(ushort); }
```

| | 終了コード(`sizeof(ushort)`) |
|---|---|
| gcc 13.3 | 2 |
| rubycc | **1** |

x86-64 と aarch64 の同梱ヘッダの両方(`include/libc/glibc/{x86_64,aarch64}/sys/types.h` の `typedef unsigned char ushort;`)。
`bundled-headers-coverage-audit-2` を実装したエージェントが気づいた。名前は宣言されているので、名前の突き合わせの表には出ない。

## 影響

`ushort` を構造体のメンバや引数に使うコードは、gcc でコンパイルしたものと ABI が合わない。**実在の gem ではまだ見ていない。**

## 受け入れ条件

- `ushort` の大きさ・整列・符号が、x86-64 と aarch64 の両方で gcc と一致する(`test/test_header_abi.rb`)
- 同じ節の他の省略名(`uint` / `ulong` / `u_char` など)も同じく gcc と突き合わせる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`bundled-headers-coverage-audit-2` の統合時に、報告された形を最小再現で確かめて起票した。

### 2026-09-14(実装)

同じ節の BSD の省略名 11 個(`u_char` 〜 `u_int64_t`)を両 arch で gcc と測った。食い違いは `ushort` だけで、`unsigned short` に直した。

## 決着

**解消した**(`bundled-sys-types-ushort-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| `ushort` の大きさ・整列・符号が両 arch で gcc と一致する | `test/test_header_abi.rb` の `SYS_TYPES` に BSD の省略名を足して確認 |
| 同じ節の他の省略名も gcc と突き合わせる | 11 個すべて測った。他は一致していた |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
