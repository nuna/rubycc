---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# `-I/usr/include` を渡すと、glibc 本体のヘッダが同梱ヘッダより先に見つかる

## 課題

**`-I/usr/include` を付けると、`#include <stdio.h>` だけの翻訳単位が rubycc では通らなくなる。**
gcc は通す。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で測った:

| | `#include <stdio.h>` |
|---|---|
| gcc `-I/usr/include` | ok(`-v` は `ignoring duplicate directory "/usr/include"` と報告する) |
| rubycc(`-I` なし) | ok |
| rubycc `-I/usr/include` | **`/usr/include/stdio.h:655:12: error: expected ';'`** |

**gcc は、システムのディレクトリと同じ `-I` を無視する**(システムのディレクトリとしての順序を保つ)。
rubycc は `-I` のディレクトリを同梱ヘッダより先に探すので、glibc 本体の `stdio.h` を読み、
その中の `__fortified_attr_access`(同梱の `sys/cdefs.h` が定義しないマクロ)で落ちる。
rubycc の既定の探索パスは、同梱ヘッダの後に `/usr/include/x86_64-linux-gnu` と `/usr/include` を置く
(`lib/rubycc/preprocess/preprocessor.rb:104-112`)。

## 影響

**実在の gem が落ちる。** コーパス候補 `do_sqlite3` 0.10.17 の `extconf.rb:11` は
`dir_config("sqlite3", ["/usr/local", "/opt/local", "/usr"])` と書き、mkmf が `-I/usr/include` を足す。
最初の設定判定(`#include "ruby.h"` だけの試験プログラム)が上のエラーになり、extconf が止まる。
**対照の gcc はビルドに成功する**(2026-09-13 実測)。

`dir_config` に `/usr` を渡すのは古い gem によくある書き方なので、同じ形の gem は他にもあると見込む。

## 受け入れ条件

- rubycc `-I/usr/include` で上の翻訳単位が通る
- **gcc と同じ規則**を実測で決めて実装する(システムのディレクトリと重なる `-I` を無視する。
  `-isystem` と `-idirafter` の扱いも同時に確かめる)
- 重ならない `-I` の順序は変わらない
- `do_sqlite3` 0.10.17 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
