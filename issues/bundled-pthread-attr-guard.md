---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱 `pthread.h` が `pthread_attr_t` を glibc のガード無しで定義し、`<netdb.h>` と衝突する

## 課題

**`_GNU_SOURCE` のもとで `<pthread.h>` の後に `<netdb.h>` を含めると、rubycc だけが型の再定義になる。**
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
#define _GNU_SOURCE 1
#include <pthread.h>
#include <netdb.h>
int v(void) { return 0; }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`/usr/include/x86_64-linux-gnu/bits/types/sigevent_t.h:17:30: error: redefinition of typedef 'pthread_attr_t'`** |

glibc は `pthread_attr_t` を 2 か所で typedef し、**同じガード `__have_pthread_attr_t` で 1 回に絞っている**
(`bits/pthreadtypes.h:61-63` と `bits/types/sigevent_t.h:16-18`)。`netdb.h:35-36` は `__USE_GNU` のときに
`bits/types/sigevent_t.h` を含む。

rubycc の同梱 `include/libc/glibc/x86_64/pthread.h:58` は
`typedef union { char __size[56]; long __align; } pthread_attr_t;` と定義するが、
**`__have_pthread_attr_t` を定義しない**。そのため、後から来た glibc 本体の `sigevent_t.h` が
もう一度 typedef する。C11 は同じ型の typedef の再定義を許す(6.7p3)が、ここでは型が違う
(同梱は無名の union、glibc は `union pthread_attr_t`)ので許されない。

## 影響

**実在の gem が落ちる。** コーパス候補 `trilogy` 2.13.0 は、`ext/trilogy-ruby/trilogy.c` から
`<netdb.h>` に届き(Ruby の `config.h` が `_GNU_SOURCE` を定義する)、上のエラーでビルドできない。
**対照の gcc はビルドに成功する**(2026-09-13 実測。対照が落ちたのはロードの証明の段)。

## 受け入れ条件

- 上の最小再現が通る
- `pthread_attr_t` の大きさと整列が、x86-64 と aarch64 の**両方**でリファレンスコンパイラと一致したまま
  (`test/test_header_abi.rb`)
- **同梱 `pthread.h` が定義する他の型**(`pthread_mutex_t` など)にも、glibc 本体のヘッダと共有する
  ガードが無いものがないかを数え、同じ形で直す
- `trilogy` 2.13.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。`cext.c` の `#include` を順に足しても
再現せず、落ちていたのは `trilogy.c` のほうだった。そこから `<netdb.h>` に辿り着いた。

## 決着

(未着手)
