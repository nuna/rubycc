---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-3
pr: 150
steps: [bundled-pthread-attr-guard-1]
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

### 2026-09-14(実装)

glibc と同じく、typedef を `__have_pthread_attr_t` で 1 回に絞り、共用体の中身は無条件に定義する形にした
(x86_64 / aarch64 の両方)。**逆順(`<netdb.h>` を先に含める)も同じ理由で壊れていた**ことを修正前のヘッダで確かめ、
両方向をテストにした。glibc のヘッダ間で共有されるガードは、x86-64 と aarch64 の両方で `pthread_attr_t` の 1 件だけだった。

aarch64 のテストは実物の `<netdb.h>` を使えなかった。x86-64 ホストの `-target aarch64` が、同梱していないヘッダを
クロス sysroot から探さないためで、別の課題として [`aarch64-cross-sysroot-include`](aarch64-cross-sysroot-include.md)(BI)に起票した。

## 決着

**解消した**(`bundled-pthread-attr-guard-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| `<pthread.h>` + `<netdb.h>` の最小再現が rubycc で通る | `test/test_bundled_pthread_attr_guard.rb` で両方向を確認。修正前は落ちることも確認 |
| `pthread_attr_t` の大きさと整列が x86-64 と aarch64 の両方で一致したまま | `test/test_header_abi.rb` の forward / reverse の Spec(aarch64 は手書きの代替で) |
| 同梱 `pthread.h` の他の型を数え、同じ形で直す | 数えた結果、glibc と共有するガードは `pthread_attr_t` の 1 件だけ。直すものは無い |
| `trilogy` 2.13.0 | この PR の後に測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
