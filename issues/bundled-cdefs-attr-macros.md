---
status: open
kind: gap
opened: 2026-08-25
closed:
branch:
pr:
steps: []
---

# 同梱 `sys/cdefs.h` に無い `__attr_*` のせいで、ホストの glibc ヘッダが構文エラーになる

## 課題

同梱していないヘッダは**ホストの `/usr/include` から読まれる**。そのホストのヘッダが
glibc の `sys/cdefs.h` のマクロを使うと、**同梱の `sys/cdefs.h`(`include/libc/sys/cdefs.h`)が
先に `_SYS_CDEFS_H` を立てて本物を無効化する**ため、同梱側に無いマクロは未定義のまま残り、
識別子として構文エラーになる。

最小再現(2026-08-25、ホスト、glibc 2.39、`/usr/include/malloc.h`):

```c
#include <malloc.h>
int main(void){ void *p = malloc(1); free(p); return 0; }
```

| | 結果 |
|---|---|
| gcc 13.3.0 | 成功 |
| rubycc | `/usr/include/malloc.h:61:3: error: expected ';'` — `  __attr_dealloc_free;` |

同梱の `sys/cdefs.h` は同じ宣言に並ぶ `__attribute_malloc__`(55 行)・
`__attribute_warn_unused_result__`(63 行)・`__attribute_alloc_size__`(64 行)は持つ。
**`__attr_dealloc` 系だけが抜けている。**

ホストのトップレベルヘッダが使っていて同梱側に無いものを機械的に突き合わせると、
抜けているのは次の 5 つである(2026-08-25 実測):

| マクロ | ホスト側の使用者 |
|---|---|
| `__attr_access` | `pwd.h` `grp.h` `gshadow.h` `pthread.h` `monetary.h` `stdlib.h` `regex.h` `stdio.h` `unistd.h` `string.h` `wchar.h` `shadow.h` |
| `__attr_access_none` | `pthread.h` |
| `__attr_dealloc` | `dirent.h` `malloc.h` `stdlib.h` `wchar.h` `iconv.h` `stdio.h` |
| `__attr_dealloc_fclose` | `stdio.h` `wchar.h` |
| `__attr_dealloc_free` | `malloc.h` `stdio.h` `stdlib.h` `wchar.h` |

**実際に踏むのは、rubycc が同梱していないヘッダだけ**である。`stdio.h` / `stdlib.h` /
`string.h` / `unistd.h` などは同梱があるのでホスト側へ行かない。`malloc.h` は同梱が無く、
だから最初に出たのがこれである。

## 影響

`#include <malloc.h>` を書いた拡張は、**gcc なら通るのにビルドできない**。
`malloc_usable_size` や `mallopt` を使うコードは珍しくない。

実測(2026-08-25、[run 32855252546](https://github.com/nuna/rubycc/actions/runs/32855252546)、
`corpus-candidate-validation` の `build_load`):コーパス候補 `roaring 0.4.1` が
`__BYTE_ORDER__` の解消([byte-order-predefined-macros](byte-order-predefined-macros.md))の
**次の停止点**としてこれに当たった。`roaring.c` / `bitmap64.c` / `cext.c` の 3 TU すべてで同じ。

同じ形は `malloc.h` に限らない。**同梱に無い glibc ヘッダを踏むたびに再発する**。

## 受け入れ条件

- 上表の 5 つが同梱 `sys/cdefs.h` に入り、`#include <malloc.h>` の最小再現が
  **gcc と同じく成功する**こと
- 展開先は既存の `__attribute_*` と同じ方針にすること — rubycc が実装しない属性は
  **空に展開**する(glibc が `__GNUC_PREREQ` の偽側で取る形と同じ)。
  **なぜその展開先なのかをヘッダのコメントに書く**
- clean room の方針を守ること(冒頭コメントのとおり、glibc からの複製ではなく
  公開されたマクロ契約に対して書く)
- ホストのヘッダを踏む経路の回帰テストがあること
  (`test/test_header_abi.rb` か mkmf/conftest 側のどちらが妥当かは着手時に判断する)
- `bundle exec rake test` が 0 failures

## 作業ログ

### 2026-08-25(起票)

[corpus-candidate-pilot-v2-roaring](corpus-candidate-pilot-v2-roaring.md) の再走で見つけた。
`malloc.h` を同梱する案もあるが、**それでは同じ形が次のヘッダで再発する**。
同梱 `sys/cdefs.h` が本物を無効化している以上、埋めるべきはそちらだと見ている
(着手時に確定させること)。

## 決着

(未着手)
