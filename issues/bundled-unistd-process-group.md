---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-16
branch: gap-fixes-wave-6
pr: 154
steps: [bundled-unistd-process-group-1]
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

### 2026-09-16(実装)

`tools/audit_bundled_headers.rb` の表で `unistd.h` の不足を数え、90 件(両 arch で同じ)を「足す 30 件 / 意図して外す 60 件」に分類した。
足したのは、プロセスグループとセッション(`tcgetpgrp`・`tcsetpgrp`・`getpgrp`・`setpgid`・`getpgid`・`setsid`・`getsid`・`setpgrp`)と、
拡張から直に呼びそうな POSIX / GNU の宣言(`getgroups`・`getlogin`・`fchdir`・`chroot`・`daemon`・`nice`・`sync`・`syncfs`・`lockf` と `F_*`・
`getentropy`・`dup3`・`pipe2`・`environ`・`gettid`・`SEEK_DATA` / `SEEK_HOLE`・`TEMP_FAILURE_RETRY`)。外した 60 件は理由をヘッダ冒頭に書いた。

## 決着

**解消した**(`bundled-unistd-process-group-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 最小再現が通る | `test/test_bundled_headers_coverage.rb` に issue の再現を入れて確認 |
| `unistd.h` の差分を足す / 意図して外すに分類する | 90 件を分類し、未記載は 0 件(両 arch)。表を作り直した |
| 足した宣言が gcc の宣言と衝突しない | glibc 本体の `<unistd.h>` の直前で再宣言して x86-64 / aarch64 の両方で確認。`F_*` と `SEEK_DATA` / `SEEK_HOLE` の値は `gcc -E -dM` で両 arch 一致 |
| `ruby-termios` 1.1.0 がこの段を越える | この PR の後に台帳の測り直しで確かめる |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
