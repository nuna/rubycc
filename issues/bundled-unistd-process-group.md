---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# 同梱 `unistd.h` にプロセスグループと端末の関数(`tcgetpgrp` など)が無い

## 課題

**同梱の `unistd.h` は `tcgetpgrp` を宣言しない。** 同じ系統の `tcsetpgrp`・`getpgrp`・`setpgid` も見当たらない
(2026-09-14、`include/libc/unistd.h` を grep)。gcc は通す。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <unistd.h>
int main(void) { return tcgetpgrp(0) == -2; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: implicit declaration of function 'tcgetpgrp'`** |

`unistd.h` は、[`bundled-headers-coverage-audit`](bundled-headers-coverage-audit.md) で**まだ分類していない** 49 本の 1 つである。

## 影響

**実在の gem が落ちる。** `ruby-termios` 1.1.0 の `termios.c:565` が `tcgetpgrp` を呼ぶ(2026-09-14 実測、BA の `tcflow` を直した後の次の段)。

## 受け入れ条件

- 上の再現が通る
- `tools/audit_bundled_headers.rb` の表を使って `unistd.h` の差分を「足す / 意図して外す(理由を冒頭コメントに)」に分類する
  (`bundled-headers-coverage-audit-2` で 5 本に行ったのと同じやり方)
- 足した関数の宣言が gcc の宣言と衝突しない(再宣言で確かめる。x86-64 と aarch64)
- `ruby-termios` 1.1.0 がこの段を越える
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

ギャップ修正の 4 回目の後に ruby-termios を測り直して見つけた。

## 決着

(未着手)
