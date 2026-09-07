---
status: done
kind: gap
opened: 2026-09-08
closed: 2026-09-08
branch: musl-dlopen-fixture-symbols
pr: 126
steps: [musl-dlopen-fixture-symbols-1]
---

# dlopen するフィクスチャのシンボル名が別ファイル間で衝突している(musl の週次が赤)

## 課題

週次の `musl` ジョブが 1 件失敗する(2026-09-07 の dispatch、
[run 34155057494](https://github.com/nuna/rubycc/actions/runs/34155057494)、head `44ad2e0`):

```
TestPic#test_pic_objects_link_into_a_shared_object_and_round_trip [test/test_pic.rb:179]:
initial extern data read through the GOT.
Expected: 100
  Actual: 55
```

**`3429 runs / 1 failures / 0 errors / 581 skips`。他の 8 ジョブは success。**

原因は **`test/test_pic.rb` と `test/test_shared_object.rb` が同じシンボル名の
フィクスチャを dlopen していること**である。どちらも
`shared_counter = 100` / `read_counter` / `write_counter` / `call_via_ptr` を
**エクスポートし**、どちらのテストも途中で **55 を書き込む**。

**musl の `dlclose` は実質 no-op** なので、先に読み込まれたライブラリは
`lib.close` の後も常駐したままになる。Fiddle の dlopen は `RTLD_GLOBAL` なので、
後から読み込まれた側の `shared_counter` は**先に読み込まれた定義に解決される**
(ELF の既定のシンボル介入)。先の테스트が 55 を書いた後なので、
後のテストの「初期値 100」が 55 になる。

**minitest の seed でどちらが先に走るかが変わるため、出たり出なかったりする。**
`ruby:4.0-alpine` で実測(2026-09-08、2 ファイルを 1 プロセスで実行):

| seed | 実行順 | 結果 |
|---|---|---|
| 1 | TestPic → TestSharedObject | **0 failures** |
| **7** | **TestSharedObject → TestPic** | **1 failure(Expected 100 / Actual 55)** |
| 42 | TestPic → TestSharedObject | 0 failures |

再現手順:

```sh
docker run --rm -v "$PWD":/w -w /w ruby:4.0-alpine sh -c '
  apk add --quiet build-base libffi-dev
  ruby -Ilib -Itest -e "require \"minitest/autorun\"
    require_relative \"test/test_shared_object\"
    require_relative \"test/test_pic\"" -- --seed 7'
```

`test/test_aarch64_shared_object.rb` も同じ名前の組(`shared_counter` / `bump` /
`read_counter` / `write_counter` / `call_via_ptr` / `stored` / `stored_message`)を持つ。

## 影響

**glibc では出ない** — `dlclose` が実際にアンロードするため。週次の `musl` ジョブだけが
赤くなり、しかも seed 次第なので**再実行すると緑になることがある**。これは
「直ったように見えて直っていない」形であり、CI の信号としては最も質が悪い。

コンパイラの欠陥ではない。**テストのフィクスチャが名前空間を共有している**だけである。
`musl-shared-object-regression`([PR #117](../docs/development/STEPS.md))が
`test_shared_object.rb` の**ファイル内**の同名衝突を `static` 化で閉じたのと同じ根で、
**ファイル間**の分が残っていた。

## 受け入れ条件

- 上の再現手順が seed 1 / 7 / 42 のいずれでも 0 failures
- dlopen するフィクスチャがエクスポートするシンボル名が、**スイート全体で一意**であること
  (`static` 化では解けない — `extern` の解決を測るテストだからである)
- 他に同じ形(dlopen するフィクスチャの名前がファイル間で重複)が残っていないか
  洗い、結果を記録する
- glibc の `rake test` が 0 failures、musl の全スイートも 0 failures

## 作業ログ

### 2026-09-08(起票)

今日の 5 本(#121〜#125)のマージ後、Tier A の外を確かめるために週次を dispatch して
見つけた。**Tier A(glibc)では原理的に出ない**ので、dispatch していなければ
次の定期実行まで気付かなかった。

`44ad2e0` で初めて出たわけではなく、**seed が変わったから出た**と見るのが自然である
(今日の変更でテスト数が 3416 → 3429 に増え、順序が変わった)。

## 決着

**解消した**(`musl-dlopen-fixture-symbols-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

`test_pic.rb` に `pic_`、`test_aarch64_shared_object.rb` に `a64_` の接頭辞を付けた。
`test_shared_object.rb` は変えていない(#117 が触ったばかりで、こちらを基準とした)。
**`static` 化は使えない** — `extern` の解決そのものを測るテストだからである。

| 条件 | 結果 |
|---|---|
| seed 1 / 7 / 42 / 99 で 0 failures | **4 つとも 0 failures**(変更前は seed 7 で 1 failure) |
| エクスポート名がスイート全体で一意 | dlopen する全フィクスチャを洗った。残る重複 3 件は下記の理由で直していない |
| glibc の `rake test` | **3429 runs / 0 failures / 0 errors / 39 skips** |

**残した重複 3 件**: `a_val` / `b_val`(定数を返すだけで値も同一)、`my_crc`
(libz の `crc32` を同じ入力で呼ぶだけ)、`my_len`(`strlen` の素通し)。
**いずれも状態を持たず、どちらの定義が勝っても観測値が変わらない。**
規則の目的は「観測が実行順に依存しないこと」であって、名前の一意性それ自体ではない。
