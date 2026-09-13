---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱 `sys/types.h` に `__caddr_t` が無く、glibc の `<net/if.h>` が読めない

## 課題

**`#include <net/if.h>` が rubycc では構文エラーになる。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
#include <net/if.h>
int f(void) { struct ifreq r; return (int)sizeof r; }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`/usr/include/net/if.h:148:2: error: expected type specifier`** |

glibc の `net/if.h:148` は `struct ifreq` のメンバに `__caddr_t ifru_data;` を置く。`__caddr_t` は
glibc の `bits/types.h:204` で `typedef char *__caddr_t;` と定義される。

rubycc は `<sys/types.h>` を同梱の `include/libc/glibc/x86_64/sys/types.h`(123 行)に解決する。
これは公開名の `caddr_t` を 108 行で直接 `char *` と定義しているが、**glibc の内部名 `__caddr_t` は
定義していない**。glibc 本体のヘッダ(`net/if.h`)は内部名のほうを使うので、同梱と本体が混ざる所で落ちる。

## 影響

**実在の gem が落ちる。** コーパス候補 `network_interface` 0.0.4 は
`ext/network_interface_ext/netifaces.c` から `<net/if.h>` を含むため、上のエラーでビルドできない。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-3)。

## 受け入れ条件

- 上の最小再現が gcc と同じく通り、`sizeof(struct ifreq)` が x86-64 と aarch64 の**両方**で
  リファレンスコンパイラと一致する(`test/test_header_abi.rb`)
- **同梱 `sys/types.h` が定義しない glibc の内部名のうち、glibc 本体のヘッダが使うもの**を先に数え、
  足す範囲を決める(1 つずつ塞ぐと回数が増える。[`bundled-stdlib-getloadavg`](bundled-stdlib-getloadavg.md) と同じ方針)
- ヘッダのテキストを写経せず、測ってから書く(`docs/reference/HEADER-LICENSING.md` §6 の手順)。由来台帳を更新する
- `network_interface` 0.0.4 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。aarch64 側の同梱ヘッダはまだ見ていない。

## 決着

(未着手)
