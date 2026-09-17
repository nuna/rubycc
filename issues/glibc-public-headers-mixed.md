---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-18
branch: gap-fixes-wave-8
pr: 158
steps: [glibc-public-headers-mixed-1]
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

### 2026-09-18(実装)

調査をやり直し、23 本の原因を 5 つに分けた。最大のものは「同梱ヘッダが `<features.h>` に届いていない」で、同梱ヘッダ 71 本のうち
`<features.h>` を含んでいたのは 5 本だけだった(`__BEGIN_DECLS` が型指定子の位置に残る)。ほかに `<sys/types.h>` と `<sys/time.h>` の取り込み不足、
同梱 `<sys/cdefs.h>` の名前の不足、そして gcc の**型名マクロ**(`__SIZE_TYPE__` 系 35 個)が丸ごと無かったこと。`__va_arg_pack` は逆に、
無い機能を広告していたので外した(glibc の `<error.h>` がそれを見て組み込み版を選んでいた)。残る 5 本は BY(`_Complex`)・BZ(`_Generic`)・
CA(オペランド付きインラインアセンブリ)に分けて起票した。

## 決着

**解消した**(`glibc-public-headers-mixed-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 23 本の原因を最小再現で確かめ、同梱ヘッダ側と rubycc 本体側に分ける | 18 本が同梱ヘッダ・前処理器の側で、直した。残り 5 本は本体の機能で、3 件の issue に分けた |
| 同梱ヘッダ側のものは直す | 上記。新たに落ちるようになったヘッダは無い |
| 表を作り直し、rubycc だけが落ちる本数を記録する | `BUNDLED-HEADERS-COVERAGE.md` を再生成(混在の表は 23 行 → 5 行) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
