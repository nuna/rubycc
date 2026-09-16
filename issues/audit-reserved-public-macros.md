---
status: done
kind: gap
opened: 2026-09-16
closed: 2026-09-17
branch: gap-fixes-wave-7
pr: 156
steps: [audit-reserved-public-macros-1]
---

# 洗い出しの道具が、`_POSIX_*` など利用者向けの予約名を差分から外す

## 課題

**`tools/audit_bundled_headers.rb` は、名前が `_` + 大文字で始まると「処理系の予約名」として差分から外す**
(`reserved?`。typedef とタグだけは別枠で数える)。そのため、glibc が**利用者向けに公開している**マクロが
表に出ず、`BUNDLED-HEADERS-COVERAGE.md` の「未記載 0 件」はその分だけ弱い主張になっている。

2026-09-16 にこのホスト(WSL2 / gcc 13.3)で測った例:

```c
#include <unistd.h>
int main(void) { return _POSIX_VDISABLE; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok(glibc は `bits/posix_opt.h` で `'\0'` と定義する) |
| rubycc | **`error: undeclared variable '_POSIX_VDISABLE'`** |

`unistd.h` は `bundled-unistd-process-group-1` で分類したばかりで、表では「不足 60 件・未記載 0 件」だが、
`_POSIX_VDISABLE` はどちらにも数えられていない。

## 影響

**実在の gem が落ちる。** `ruby-termios` 1.1.0 は BU(`tcgetpgrp`)を越えた先の `termios.c:759` で
`_POSIX_VDISABLE` を使い、そこで止まる(2026-09-16 実測、master 5f13e54)。

同じ形で抜けうる名前は、`unistd.h` の `_POSIX_*` / `_SC_*` / `_CS_*` / `_PC_*`、`limits.h` の `_POSIX_*_MAX` など、
**規格が利用者に使わせるために予約領域の綴りを与えているもの**である。分類済みの 6 本
(`stdlib.h`・`sched.h`・`termios.h`・`sys/ioctl.h`・`sys/types.h`・`unistd.h`)も、この分だけ数え直しが要る。

## 受け入れ条件

- 上の再現が通り、`_POSIX_VDISABLE` の値が gcc と一致する(x86-64 と aarch64)
- `reserved?` の扱いを見直し、**利用者向けの綴り**(少なくとも `_POSIX_`・`_SC_`・`_CS_`・`_PC_`・`_XOPEN_` で始まるもの)を
  差分に出す。表を作り直し、分類済みの 6 本について「足す / 意図して外す」を数え直す
- `ruby-termios` 1.1.0 がこの段を越える
- `rake test` が 0 failures

## 着手前に確かめること

- 予約名のうち、**内部実装のためのもの**(`__have_*`・`__USE_*`・`_RUBYCC_*` など)は今までどおり外したままにする。
  線引きの根拠を STEPS に書く
- `docs/development/BUNDLED-HEADERS-COVERAGE.md` は生成物なので、道具を直してから作り直す

## 作業ログ

### 2026-09-16(起票)

6 回目の修正の後に ruby-termios を測り直して見つけた(BU の段は越えた)。道具の `reserved?` を読んで原因を確かめた。

### 2026-09-17(実装)

予約領域を用途で二分した。`_POSIX_*` / `_SC_*` / `_CS_*` / `_PC_*` / `_NL_*` / ioctl の `_IO*` / `_Exit` / `_Fork` のように**規格がプログラムに書かせる**綴りは差分に入れ、
インクルードガード・`__` 名・プログラムが定義する側の feature-test マクロ・glibc が自分のレイアウトを報告するマクロは従来どおり外す。表を作り直すと、
`unistd.h` の不足は 60 件から 432 件(aarch64 は 438 件)に増えた。足したのは `_POSIX_VDISABLE` だけで、残りは 4 本の `omitted:` 行にまとめた
(ホストの libc が答える番号・値なので、消費者が出るたびに 1 件ずつ足す)。

## 決着

**解消した**(`audit-reserved-public-macros-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現が通り、`_POSIX_VDISABLE` の値が gcc と一致する(両 arch) | `test/test_bundled_headers_coverage.rb` の再現と `test/test_header_abi.rb` の UNISTD に追加 |
| 利用者向けの綴りを差分に出し、表を作り直して分類済み 6 本を数え直す | 6 本とも未記載 0 件のまま。線引きは `tools/audit_bundled_headers.rb` の `public_reserved?` とテストで固定 |
| `ruby-termios` 1.1.0 がこの段を越える | `RUBYCC=1 gem install` が完走し、`require "termios"` と `Termios::POSIX_VDISABLE == 0` まで確認(2026-09-17)。台帳への記録はこの PR の後 |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
