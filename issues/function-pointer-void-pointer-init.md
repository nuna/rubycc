---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# 関数を `void *` に暗黙に変換する初期化を拒否する(gcc は既定で警告もしない)

## 課題

**関数(関数ポインタ)で `void *` のメンバを初期化すると、rubycc は `incompatible types in initialization` で拒否する。
gcc は既定では警告もせずに通し、`-pedantic` のときだけ警告する。** 2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <math.h>
struct d { int n; void *p; };
static struct d t[] = { { 1, ceil }, { 2, floor } };
int main(void) { return t[0].n - 1; }
```

| | 結果 |
|---|---|
| gcc 13.3(既定) | ok(警告なし) |
| gcc 13.3 `-pedantic` | `warning: ISO C forbids initialization between function pointer and 'void *' [-Wpedantic]` |
| rubycc | **`error: incompatible types in initialization`** |

ISO C は関数ポインタとオブジェクトポインタ(`void *` を含む)の暗黙の変換を定めていない(C11 6.3.2.3、6.5.16.1)。
gcc は拡張として受け付ける。POSIX の `dlsym` も、この変換が働くことを前提にしている。

[`incompatible-function-pointer-argument`](incompatible-function-pointer-argument.md)(AN)は「gcc 13 が警告にとどめる診断」を扱う。
この形は gcc が既定では警告も出さない点で、AN より gcc との差が大きい。

## 影響

**実在の gem が落ちる。** `amalgalite` 2.0.0 の同梱 SQLite(`sqlite3.c:135127`)が、`MFUNCTION(ceil, 1, xCeil, ceilingFunc)` で
`static double xCeil(double)` を `FuncDef` の `void *pUserData` に入れる(2026-09-14 実測、`bundled-headers-coverage-audit-2` の後)。
SQLite の amalgamation を同梱する gem はほかにもあり、同じ所で落ちる見込み。

## 受け入れ条件

**先に方針を決める**(gcc と同じく受け付けるか、拒否を保つか)。

- (受け付ける場合)上の再現と、代入・引数渡し・戻り値の同じ形が gcc と同じ値になる。逆向き(`void *` → 関数ポインタ)の扱いも
  gcc で測って決める。`amalgalite` 2.0.0 がこの段を越える
- (拒否を保つ場合)診断を「関数ポインタと `void *` の暗黙の変換は受け付けない」と分かる文言にし、`amalgalite` を対象外の gem の文書に載せる
- どちらの場合も `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

ギャップ修正の 4 回目の後に amalgalite を測り直して見つけた(BG を越えた先)。

## 決着

(未着手)
