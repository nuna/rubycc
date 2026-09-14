---
status: open
kind: gap
opened: 2026-09-14
closed:
branch:
pr:
steps: []
---

# 同梱しない glibc の公開ヘッダのうち、rubycc だけが落ちるものが 23 本ある

## 課題

**`tools/audit_bundled_headers.rb` の混在の調査で、同梱していない glibc の公開ヘッダ 186 本を 1 本ずつ含めると、gcc は通り
rubycc だけが落ちるものが 23 本ある**(2026-09-14、x86-64、`bundled-headers-coverage-audit-2` の後。修正前は 37 本)。
一覧は [`BUNDLED-HEADERS-COVERAGE.md`](../docs/development/BUNDLED-HEADERS-COVERAGE.md) の混在の節にある。

実装したエージェントの分類(原因は確かめていない):

- 多くは `__BEGIN_DECLS` が無いように見える形で落ちる(`glob.h:27`・`net/ethernet.h:29`・`stdio_ext.h:42`・`sys/eventfd.h` など)。
  同梱の `features.h` は `sys/cdefs.h` を含んでいるので、原因は分かっていない
- `error.h` — `__builtin_va_arg_pack`
- `asm/swab.h` を経由するもの — 空でないインラインアセンブリ
- `tgmath.h` — コンパイラの判定
- `netinet/ip.h` — ビットフィールドのメンバの重複

## 影響

これらのヘッダを含む gem は、rubycc でビルドできない。どの gem が該当するかは数えていない。

## 受け入れ条件

- 23 本それぞれの原因を最小再現で確かめ、同梱ヘッダの側の原因と rubycc 本体の側の原因に分ける
- 同梱ヘッダの側のものは直す。rubycc 本体の側のものは、1 件ずつ issue にするか、対象外にするかを決める
- `BUNDLED-HEADERS-COVERAGE.md` を作り直し、rubycc だけが落ちる本数を記録する
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

`bundled-headers-coverage-audit-2` の混在の調査の結果から起票した。

## 決着

(未着手)
