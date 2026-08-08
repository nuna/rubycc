# CI 構成(GitHub Actions)

rubycc の継続的検証は、通常の回帰、週次の追加検証、リリース配布物の検証に分かれる。
ワークフローは `.github/workflows/`、skip ガードは
[`../tools/ci_check_skips.rb`](../tools/ci_check_skips.rb) に定義する。

## 実行層

| 層 | ワークフロー | トリガ | 対象 | 設定上限 |
|---|---|---|---|---|
| Tier A | `test.yml` | master への push、pull request、手動、reusable workflow 呼び出し | Ruby 3.3 / 4.0 の全 Minitest スイート | 60 分 / Ruby 1 本 |
| Tier B | `weekly.yml` | 毎週日曜 18:00 UTC(月曜 03:00 JST)、手動 | census、受入れ、スループット、Ruby 3.4、native aarch64、native aarch64 glibc、musl、musl/aarch64 | 45〜180 分 / ジョブ |
| Tier C | `release.yml` | `v*` タグの push、手動 | Tier A の再実行と gem の再現ビルド | test 60 分 + package 30 分 |

Tier A の push 実行は、テスト結果に影響しない文書・参照資料・ライセンス・既存ベンチ
結果の変更を `paths-ignore` で除外する。pull request は常に Tier A を実行する。
Tier C の test ジョブは `test.yml` をそのまま再利用する。

## Tier A

各 Ruby バージョンを並列に実行し、次の処理を行う。

1. Ubuntu 24.04 に参照用ツールチェーンを導入する。
2. gcc、aarch64 cross gcc/binutils、qemu、pkg-config、sysroot の存在を確認する。
3. Ruby をセットアップして依存 gem をインストールする。
4. `bundle exec rake test TESTOPTS="--verbose"` を実行する。
5. `tools/ci_check_skips.rb` で実行件数と skip 数を確認し、ログを artifact に保存する。

native aarch64 は `weekly.yml` の `aarch64` ジョブから
`test.yml` を再利用する。手動実行で `only: aarch64` を選んだ場合だけ、
`ubuntu-24.04-arm` 上で Ruby 3.3 / 4.0 の全スイートを実行する。

## 参照用ツールチェーン

差分テストと生成物検査に使用する apt パッケージは次のとおり。

| パッケージ | 用途 |
|---|---|
| `build-essential` | x86-64 の gcc、make |
| `binutils` | readelf、ld、ar、nm |
| `pkg-config` | pkg-config 出力の比較 |
| `gcc-aarch64-linux-gnu` | aarch64 の参照コンパイラ |
| `binutils-aarch64-linux-gnu` | aarch64 生成物の逆アセンブル |
| `libc6-dev-arm64-cross` | aarch64 sysroot の dynamic loader と libc |
| `qemu-user` | aarch64 実行テスト |

実行ヘルパーが探す名前は `qemu-aarch64` なので、`qemu-user-static` だけではなく
`qemu-user` を使用する。

## skip ガード

Tier A、Ruby 3.4、native AArch64 glibc のジョブは、ツールチェーンの存在を先に確認したうえで
`tools/ci_check_skips.rb` を実行する。スクリプトは Minitest のサマリを読み取り、
次の条件でジョブを失敗させる。

| 条件 | 既定値 | 意味 |
|---|---:|---|
| failures または errors がある | — | テスト失敗 |
| skips が `CI_MAX_SKIPS` を超える | 55 (通常) / 130 (native AArch64) | 外部ツール欠落または skip 条件の拡大 |
| runs が `CI_MIN_RUNS` 未満 | 2500 | スイートの途中終了またはロード漏れ |

skip 理由は絶対パスと数値を正規化したヒストグラムとして出力する。
`CI_MAX_SKIPS` と `CI_MIN_RUNS` は環境変数で上書きできる。

## Tier B のジョブ

### census

`test/corpus/gems.rb` の固定バージョンの gem を対象に
`bundle exec rake corpus:census` を実行し、
`test/corpus/include-census.md` と生成ログを artifact に保存する。
コミット済み census と差分がある場合はジョブを失敗させる。

通常プロファイルの閾値 55 / 2500 は、実測値に小さな余裕を足したもの。native AArch64
プロファイルは、x86-64 専用の実行可能ファイル/PIC/linker テストと既知の未対応 corpus を
意図的に skip するため、実測 128 skips に対してスクリプトだけ `CI_MAX_SKIPS=130` を指定する。
ツールチェインの存在確認と skip 理由 histogram は共通であり、依存パッケージ欠落を許容する
閾値ではない。

### aarch64 glibc(`weekly.yml` の `aarch64-glibc`)

M4 のクロス検証だけでは、x86-64 Ruby から aarch64 の生成物を実行していることしか
確認できない。`aarch64-glibc` ジョブは `docker/setup-qemu-action` で arm64 の
`ruby:4.0` イメージを起動し、**Ruby 自身を aarch64 glibc 上で実行**する。
チェックアウトと Actions のステップはホスト側で行い、リポジトリをコンテナへ bind mount
する構成は musl ジョブと同じである。

コンテナ内の `.github/scripts/aarch64-glibc-acceptance.sh` は次の順で実行する。

1. native build 用の `build-essential` と `libffi-dev` を導入する。既存の差分テストが
   cross toolchain の名前で参照する gcc / objdump / runner は、native arm64 の
   `gcc` / `objdump` / `/usr/bin/env` へ環境変数で切り替える。arm64 コンテナ内へ
   amd64 用の cross toolchain を持ち込まない。
2. aarch64 Ruby 上で `bundle exec rake test` を実行し、`ci_check_skips.rb` で
   ツール欠落による静かな skip を拒否する。
3. `RMAKE_ACCEPTANCE=1 ruby tools/m2_acceptance.rb` で json / msgpack のビルドと
   gem 本体テストを実行する。

Step 120 のDoS耐性テストにある計算量の壁時計閾値は、通常環境では従来どおり
係数1で検証する。native AArch64 ジョブだけは QEMU の実測オーバーヘッドを考慮して
`RUBYCC_DOS_PERFORMANCE_FACTOR=4` を設定するが、閾値は有限のままであり、計算量の
上限そのものを無効化しない。

suite と gem acceptance は片方が失敗しても両方のログを残し、最後にまとめてジョブを
失敗させる。`workflow_dispatch` の `only: aarch64-glibc` を指定すれば、このジョブだけを
手動で実行できる。試行錯誤中は `test_scope: smoke` を指定すると、バックエンド・実行・
bit-scan、ABI profile、native c-suite、exampleを含む代表12テストだけを
実行し、M2 は保留する。最終確認だけ
`test_scope: full`(既定値)で全スイートと json/msgpack の M2 受入れを実行する。実行結果は
`weekly-aarch64-glibc` アーティファクトに保存する。

#### M4 native AArch64 glibc 受入れ記録(2026-08-08)

初回のnativeフル実行([run 31192043425](https://github.com/nuna/rubycc/actions/runs/31192043425))は
`2848 runs / 6753 assertions / 71 failures / 536 errors / 338 skips` で失敗した。
原因を分けて修正し、smoke([run 31235353834](https://github.com/nuna/rubycc/actions/runs/31235353834)、
`12 / 36 / 0 / 0 / 0`)を通した後、最終フル実行([run 31235668846](https://github.com/nuna/rubycc/actions/runs/31235668846)、
native job 1時間10分28秒)を実施した。

| 確認 | 最終結果 |
|---|---|
| aarch64 Ruby 上の全スイート | `2848 runs / 8437 assertions / 0 failures / 0 errors / 128 skips` |
| skip ガード | `ci_check_skips: OK (skips <= 130, runs >= 2500)` |
| M2 json 2.21.1 | `607 tests / 3435 assertions / 0 failures / 0 errors / 100% passed` |
| M2 msgpack 1.8.3 | `455 examples / 0 failures / 1 pending` |

初回失敗から切り分けた主な原因と修正は次の通り。

- AArch64 backend が `alloca` と bit-scan を未実装で、後者はmsgpack、前者はjson parserのビルドを止めていた。動的スタックフレーム、AArch64命令、符号なしint→float変換を実装した。
- native arm64 GCC の既定PIEと、x86-64用のオブジェクト・リンカテストを一般実行ハーネスが前提としていた。ターゲットに応じたコンパイラ/リンクフラグへ統一し、x86-64専用の実行・PIC・SharedLinker検査を明示的にskipした。
- ABI検査にglibcのリリース番号、`pthread_kill` の宣言位置、AArch64の`math.h`定数というターゲット/環境依存値が混在していた。ヘッダとABI期待値をターゲット依存に修正した。
- QEMU上のDoS壁時計閾値が狭く、nativeジョブのskip上限も通常の55件のままだった。性能係数4とnative専用上限130件を設定した。
- 最後に、alloca実装後も失敗を期待していた古いdriverテストと、AArch64で実行してはいけないx86-64専用SharedLinkerテストを修正した。

初回修正後の中間実行([run 31232423276](https://github.com/nuna/rubycc/actions/runs/31232423276))では
suiteが `1 failure / 1 error` まで減り、M2は両gemとも通過した。残った2件は上記の古いテスト期待値とターゲット条件の問題であり、最終runで解消した。

### acceptance

`RMAKE_ACCEPTANCE=1 bundle exec rake test TESTOPTS="--verbose"` でネットワークを
必要とする受入れテストを実行し、続けて
`ruby tools/m2_acceptance.rb` で M2 の受入れを実行する。
通常の Tier A と実行件数が異なるため、Tier A の skip 閾値は適用しない。

### throughput

`BENCH_RUNS=7 bundle exec rake bench:throughput` を実行し、結果を artifact に保存する。
GitHub-hosted runner の性能変動を考慮し、数値による合否判定は行わない。

### Ruby 3.4

Ruby 3.4 で Tier A と同じ全スイート、ツールチェーン確認、skip ガードを実行する。

### musl

Ubuntu runner 上で checkout 済みのリポジトリを `ruby:4.0-alpine` に bind mount し、
`docker run` で次を実行する。

- Alpine の musl gcc を参照実装として全スイートを実行する。
- `io-wait`、`stringio`、`json` を `RUBYCC=1 gem install` し、各 gem のテストを実行する。
- 実行結果、拡張ビルド診断、検証データを artifact に保存する。

Alpine のジョブでは aarch64 musl cross toolchain を使用しないため、aarch64 差分テストの
skip は想定される。Tier A の skip ガードはこのジョブには適用しない。

`workflow_dispatch` の `verify_step` 入力が空の場合は回帰実行として
`data/verified_gems.json` を変更せず、入力が指定された場合は
`tools/verify_gem_tests.rb` の更新モードで検証データを生成する。
更新モードでは musl ジョブだけを実行する。

### musl/aarch64

`docker run --platform linux/arm64 ruby:4.0-alpine` で
`test_header_abi.rb` と `test_freestanding_headers.rb` だけを実行し、
結果ログを常に artifact に保存する。qemu 下で全スイートは実行しない。

このジョブは ABI の現状を記録するため、テストが失敗しても
`continue-on-error` で隠さない。現在の既知の制限は aarch64 の `alloca` と
stdio のリンクに関する Gap P である。

## 手動実行の選択

| 入力 | 実行対象 |
|---|---|
| スケジュール | census、acceptance、aarch64-glibc、throughput、musl、musl/aarch64、Ruby 3.4 |
| 入力なしの手動実行 | 上記 7 ジョブ |
| `verify_step` 指定 | musl の更新モード |
| `only: musl-aarch64` | musl/aarch64 のみ |
| `only: aarch64` | native aarch64 の Tier A 全スイート |
| `only: aarch64-glibc` | native aarch64 glibc の全スイートと M2 受入れ |

## リリース配布物

タグ push または手動実行で Tier A を再実行する。タグ push ではタグ名から `v` を除いた
値と `Rubycc::VERSION` を比較する。

`package` ジョブは Ruby 3.3 で `gem build rubycc.gemspec` を別々の作業ディレクトリで
2 回実行し、`cmp` で gem がバイト単位で一致することを確認する。
`SOURCE_DATE_EPOCH` は git の最新コミット時刻に固定する。生成した gem は artifact
として保存し、rubygems.org への push は自動化しない。

## 実行コスト

private repository の GitHub Free Actions 枠は 2,000 分/月である。設定上限の合計は、
Tier A が push 1 回につき 120 分、週次スケジュールが 615 分、
native aarch64 の手動実行が 120 分である。これは `timeout-minutes` の合計であり、
実際の消費量はジョブの実行時間と課金単位に依存する。

## ローカルでの実行

```sh
# Tier A 相当
bundle exec rake test TESTOPTS="--verbose"
ruby tools/ci_check_skips.rb path/to/test.log

# 週次相当
bundle exec rake corpus:census
RMAKE_ACCEPTANCE=1 bundle exec rake test TESTOPTS="--verbose"
BENCH_RUNS=7 bundle exec rake bench:throughput
```
