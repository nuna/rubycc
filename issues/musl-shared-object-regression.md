---
status: open
kind: gap
opened: 2026-08-27
closed:
branch:
pr:
steps: []
---

# musl 週次ジョブの共有オブジェクト系 2 件の失敗を潰して、Tier B の musl を緑に戻す

## 課題

**Tier B(`weekly.yml`)の `musl` ジョブは 2026-08-09 以降、スケジュール実行 3 回すべてで赤い。**
2026-08-27 に `gh run` で確認した実測:

| スケジュール実行 | run | 結果 |
|---|---|---|
| 2026-08-09 | [31330038506](https://github.com/nuna/rubycc/actions/runs/31330038506) | 2957 runs / **2 failures / 6 errors** / 560 skips |
| 2026-08-16 | [31965072086](https://github.com/nuna/rubycc/actions/runs/31965072086) | failure |
| 2026-08-23 | [32658611908](https://github.com/nuna/rubycc/actions/runs/32658611908) | 3346 runs / **2 failures** / 0 errors / 579 skips |

最新(2026-08-23)の 2 件はどちらも共有オブジェクト系である:

```
TestSharedObject#test_compiled_constructor_order_matches_gcc [test/test_shared_object.rb:1236]:
rubycc's own compile-and-link must match gcc's for the same source.
--- expected
+++ actual
-"123L123L123L"
+"123L"
```

```
TestPic#test_pic_objects_link_into_a_shared_object_and_round_trip [test/test_pic.rb:179]:
initial extern data read through the GOT.
Expected: 100
  Actual: 55
```

**2026-08-09 の 2 件は別の組み合わせ**で、どちらもコンストラクタ順だった
(`test_compiled_constructor_order_matches_gcc` と
`test_links_gcc_constructors_and_matches_gcc_ordering`)。失敗の集合が動いている。

`TestPic` の 55 は、**同じテストが後半で `write_counter.call(55)` に使う値**である
(`test/test_pic.rb:179` の直後)。最初の読み出しで 100 ではなく 55 が返るということは、
その `.so` の状態が前の実行から持ち越されているように見える。**未検証の見立てであり、
これを前提に直しにいかないこと。**

**この赤は Step 205 より後に入った。** GAPS.md §5 のギャップ G の行は
「**両機種とも本物の musl gcc と突き合わせて 0 failures を確認した**(Step 205)」と
記録している。

## 影響

**M5 が掲げる「glibc / musl 互換ヘッダ」の主張の半分が、CI で赤いまま週次で流れている。**

赤が定常化すると、**新しい赤に気づけなくなる**。実際この 3 週間で失敗の集合は入れ替わって
おり(コンストラクタ順 2 件 → コンストラクタ順 + PIC ラウンドトリップ)、
ジョブ全体の赤しか見ていなければその入れ替わりは見えない。

`data/verified_gems.json` の musl 記録 3 件(`json` / `stringio` / `io-wait`)は
このジョブとは別に PASS しており、そこは影響を受けていない。

## 受け入れ条件

- Tier B の `musl` ジョブが 0 failures / 0 errors で緑になる
- 上記 2 件が musl 上で gcc 対照と一致する。**skip で通さない**
  (skip は静かに緑になるので、`tools/ci_check_skips.rb` の逸脱検出も併せて確認する)
- 同じ 2 件が glibc x86-64 でも引き続き通る(退行させない)
- 原因が rubycc の欠陥だった場合は最小再現を `docs/development/GAPS.md` へ 1 行足す。
  環境由来だった場合はテスト側で環境を判定し、**理由付きの skip** にする
- 失敗の集合が 2026-08-09 と 2026-08-23 で違う理由を説明できる(片方が直ると
  もう片方が出る、といった関係かどうか)

## 作業ログ

### 2026-08-27

**GAPS.md の棚卸し中に見つけた。** GAPS §3 は musl を「測定済み」と書き、§5 は
そこから出たギャップ G・H・I をすべて閉じたと書いているので、**文書だけを読むと
musl は片付いたように見える**。実際には週次が 3 回連続で赤い。

起票にあたって `gh run view` で 3 回分のジョブ結果と、直近 2 回の失敗内容を取得した
(上の表と抜粋)。**まだ何も直していない。**

着手時の注意: `musl` ジョブは `docker run ruby:4.0-alpine` でホスト上のチェックアウトを
マウントして走る(ジョブコンテナが使えない理由は `weekly.yml` のコメントにある)ので、
**手元で同じ形を再現できる**。CI の週次を待つ必要は無い。

## 決着

(未着手)
