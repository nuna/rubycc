---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
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

## 決着

(未着手)
