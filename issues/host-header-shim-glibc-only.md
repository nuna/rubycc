---
status: open
kind: gap
opened: 2026-09-01
closed:
branch:
pr:
steps: []
---

# glibc 専用のフィクスチャを musl でも走らせている `TestHostHeaderShim` を、理由付きで skip する

## 課題

**Tier B の `musl` ジョブが `TestHostHeaderShim` の 1 error で赤い。**
2026-09-01 に master (`b0c3a21`) へ `workflow_dispatch` した
run [33523016856](https://github.com/nuna/rubycc/actions/runs/33523016856) の実測:

```
3416 runs, 12568 assertions, 0 failures, 1 errors, 581 skips

 59) Error:
TestHostHeaderShim#test_unbundled_host_header_compiles_and_runs_like_gcc:
Rubycc::CompileError: malloc_h.c:4:36: error: expected ';'
extern void *probe_alloc(size_t n) __attr_dealloc_free;
                                   ^
```

**この error は rubycc の欠陥ではない。** `ruby:4.0-alpine` の中で実測した
(2026-09-01、`ruby arch: x86_64-linux-musl` / `gcc target: x86_64-alpine-linux-musl`):

| 調べたこと | 結果 |
|---|---|
| `/usr/include/malloc.h` | **在る**(362 バイト) — なので `setup` の skip 条件は通ってしまう |
| `/usr/include/sys/cdefs.h` | **無い** |
| `grep -rn "__attr_dealloc_free" /usr/include/` | **0 件** |
| **gcc に同じソースを食わせる** | **同じく失敗** — `error: expected declaration specifiers before '__attr_dealloc_free'` |

`__attr_dealloc_free` を含む 5 つの `__attr_*` は **glibc の `sys/cdefs.h` が出すマクロ**であり、
musl にはそれを出すヘッダが 1 つも無い。つまり `MALLOC_H_SOURCE` は **musl では
そもそも妥当な C ではない**。rubycc が先に落ちるので差分実行まで到達しないだけで、
**対照の gcc も同じ位置で落ちる**。

**入った時期も特定できる。** このテストは `bundled-cdefs-attr-macros`(PR #106、
2026-08-25 マージ、`c633df9`)が glibc ホストで書いたものである。週次の musl は:

| スケジュール実行 | 結果 |
|---|---|
| 2026-08-23 [32658611908](https://github.com/nuna/rubycc/actions/runs/32658611908) | 2 failures / **0 errors** |
| 2026-08-30 [33334787161](https://github.com/nuna/rubycc/actions/runs/33334787161) | 2 failures / **1 error**(この error) |

## 影響

**`musl` ジョブが赤いままなので、[共有オブジェクト系の 2 件](musl-shared-object-regression.md)を
直しても週次は緑にならない。** その issue が問題にしたとおり、赤が定常化すると
新しい赤に気づけなくなる。実際いま失敗は 3 件から 1 件に減ったが、
ジョブ全体の赤しか見ていなければその変化は見えない。

**カバレッジは失われない。** このテストが守っているのは「同梱 `sys/cdefs.h` が
ホストの本物を無効化するので、ホストのヘッダが頼るマクロを同梱側が全部持っていること」
という性質であり、**その危険は本物の `sys/cdefs.h` を持つホストにしか存在しない**。
musl では同梱 cdefs.h が無効化する相手がいない。

## 受け入れ条件

- `TestHostHeaderShim` が musl で **理由付きの skip** になる。理由の文言は
  「ホストの libc に `sys/cdefs.h` が無い(`__attr_*` は glibc のもの)」旨を述べること
- glibc x86-64 では**引き続き実行され、skip されない**(退行させない)。
  `tools/ci_check_skips.rb` の逸脱検出が Tier A で新たな指摘を出さない
- Tier B の `musl` ジョブが **0 failures / 0 errors** で緑になる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-01

[musl の共有オブジェクト issue](musl-shared-object-regression.md)の受け入れ条件
(週次が緑になる)を確認するために `weekly.yml` を dispatch して見つけた。
**共有オブジェクト系 2 件は消えており(2 failures → 0)、残っていたのは別件だった。**

`ruby:4.0-alpine` の中で上の表を実測した。**gcc も同じソースを拒否する**ことが決め手で、
これは環境由来であって rubycc の欠陥ではない。

## 決着

(未着手)
