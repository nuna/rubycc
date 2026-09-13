---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱 `termios.h` に `tcflow` と `TCOON` などが無い(POSIX の関数)

## 課題

**`#include <termios.h>` しても `tcflow` が宣言されない。** gcc(glibc)は宣言する。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
#include <termios.h>
int f(int fd) { return tcflow(fd, TCOON); }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`error: implicit declaration of function 'tcflow'`** |

rubycc は `<termios.h>` を同梱の `include/libc/termios.h`(179 行)に解決する。その冒頭のコメント
(20〜37 行)は、コーパスの必要に合わせて範囲を絞ったと述べ、**`tcflow` / `tcgetsid` / `cfsetspeed` を
意図して外している**。`tcflow` の動作を選ぶ定数(`TCOOFF` / `TCOON` / `TCIOFF` / `TCION`)も無い。

glibc は `tcflow` を `/usr/include/termios.h:94` で**条件なしに**宣言する。`tcflow` は POSIX の関数であり、
GNU や BSD の拡張ではない。

## 影響

**実在の gem が落ちる。** コーパス候補 `ruby-termios` 1.1.0 は `termios.c:532` で `tcflow` を呼ぶ。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-4)。

## 受け入れ条件

- 上の最小再現が gcc と同じく通る
- `TCOOFF` / `TCOON` / `TCIOFF` / `TCION` の値を、x86-64 と aarch64 の**両方**でリファレンスコンパイラと突き合わせる
  (`test/test_header_abi.rb`)。ヘッダを写経せず、測ってから書く(`docs/reference/HEADER-LICENSING.md` §6)。
  由来台帳を更新する
- **同じコメントが外した残り**(`tcgetsid` / `cfsetspeed`)も同時に扱うかを決め、STEPS に書く
- `ruby-termios` 1.1.0 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。
同梱ヘッダの宣言漏れとしては [`bundled-stdlib-getloadavg`](bundled-stdlib-getloadavg.md)(AF)・
[`bundled-sched-param`](bundled-sched-param.md)(AM)・[`bundled-sys-types-caddr`](bundled-sys-types-caddr.md)(AQ)・
[`bundled-stdlib-qsort-r`](bundled-stdlib-qsort-r.md)(AR)に続く 5 件目で、
**同梱ヘッダの範囲を「コーパスが使った分だけ」に絞った判断が、コーパスの外で当たり続けている**。

## 決着

(未着手)
