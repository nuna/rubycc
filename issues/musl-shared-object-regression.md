---
status: done
kind: gap
opened: 2026-08-27
closed: 2026-09-01
branch: musl-shared-object-regression
pr: 117
steps: [musl-shared-object-regression-1]
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

**同日中に手元で再現し、原因を特定して直した。**

再現は 2 ファイル(`test_pic.rb` / `test_shared_object.rb`)だけで足りた
(`ruby arch: x86_64-linux-musl` / `gcc target: x86_64-alpine-linux-musl`)。
切り分けの順は次のとおりで、**最初の 2 つの仮説は外れた**:

| 実験 | 結果 |
|---|---|
| 比較テスト単独 | 0 failures — **単独では再現しない** |
| 先行 dlopen テスト + 比較テストの 2 件 | 0 failures — **1 回の残留では足りない** |
| gcc の `.so` の `DT_SONAME` | **無し** — soname による重複排除説は消えた |
| seed 1〜12 で全件 | **全 seed で 1〜2 failures**。seed 依存 |

seed=1 の失敗内容が答えだった:

```
test_links_gcc_constructors_and_matches_gcc_ordering   -"CBA123L"      +"123L"
test_compiled_constructor_order_matches_gcc            -"CBA123L123L"  +"123L"
```

`"CBA"` は**別のフィクスチャ**(`MARKERS` の `mark_a` / `mark_b` / `mark_c`)が書いた文字である。
このファイルの 3 つのフィクスチャは、どれも同じ綴りの `char trace[16]; int marked;` を
**エクスポート**していた。musl の `dlclose` は実質 no-op なので、`lib.close` しても
先に読み込んだ `.so` が常駐し続ける。そこへ次の `.so` が載ると、**gcc ビルドの側は
ELF の既定どおり最初に読み込まれたライブラリの `trace` に書く**。

**rubycc の値 `"123L"` の方が正しい。** 同じファイルの
`test_dlopen_runs_compiled_constructors_in_priority_order` が、優先度
101 → 200 → 500 → 無指定の順として `"123L"` を独立に固定している。
壊れていたのは対照側の期待値の作られ方である。

glibc で露見しなかったのは `dlclose` が本当にアンロードするからで、
**seed 依存だったのは、どのテストが先に常駐するかが実行順で変わるため**である。

直したのはフィクスチャで、**コンパイラ側は無変更**。`trace` / `marked` を内部リンケージに
すると各ライブラリが自分の複製を持つので、テストが測りたいもの(コンストラクタの実行順)
だけが残る。`trace_of` / `marked_count` / `mark_a`〜`mark_c` はエクスポートのまま
(ハンドメイドの `.init_array` が外部シンボルとして参照するため)。

**`GAPS.md` §4 の再検討条件は発火しない。** 条件は「実在の gem で実害が出たとき」であり、
自分のテストのフィクスチャが同じ綴りを共有していたことはそれに当たらない。

## 決着

PR #117 でマージ。**直したのはテストのフィクスチャで、コンパイラは無変更**である。
3 つのフィクスチャが同じ綴りでエクスポートしていた `trace` / `marked` を内部リンケージにした。
設計記録は [STEPS.md の `musl-shared-object-regression-1`](../docs/development/STEPS.md)。

**受け入れ条件のうち、2 件の失敗については CI で確認した。** マージ後の master (`b0c3a21`) に
`weekly.yml` を dispatch した run
[33523016856](https://github.com/nuna/rubycc/actions/runs/33523016856) の musl:

| 実行 | 結果 |
|---|---|
| 2026-08-30 [33334787161](https://github.com/nuna/rubycc/actions/runs/33334787161)(マージ前) | **2 failures** / 1 error |
| 2026-09-01 [33523016856](https://github.com/nuna/rubycc/actions/runs/33523016856)(マージ後) | **0 failures** / 1 error |

`TestSharedObject` の 2 件は消えた。**skip では通していない**(skips は 581 で
マージ前の 581 から動いていない)。

**ただし `musl` ジョブはまだ緑ではない。** 残っている 1 error は
`TestHostHeaderShim#test_unbundled_host_header_compiles_and_runs_like_gcc` で、
これは**この issue が扱った問題ではない**。PR #106(2026-08-25)が glibc ホストで
書いたフィクスチャが musl では妥当な C ではない、という別件であり、
[別の issue](host-header-shim-glibc-only.md) に分離した。2026-08-23 の週次が
0 errors で、2026-08-30 が 1 error であることから、混入時期も切り分けられている。

**「失敗の集合が 2026-08-09 と 2026-08-23 で違う理由」も答えが出た。** 実行順
(minitest の seed)でどの `.so` が先に常駐するかが変わるため、同じ 1 つの原因から
出る失敗の組み合わせが週ごとに入れ替わっていた。
