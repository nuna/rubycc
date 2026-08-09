# CI 構成(GitHub Actions)

rubycc の継続的検証は、通常の回帰、週次の追加検証、リリース配布物の検証に分かれる。
ワークフローは `.github/workflows/`、skip ガードは
[`../tools/ci_check_skips.rb`](../tools/ci_check_skips.rb) に定義する。

## 実行層

| 層 | ワークフロー | トリガ | 対象 | 設定上限 |
|---|---|---|---|---|
| Tier A | `test.yml` | master への push、pull request、手動、reusable workflow 呼び出し | Ruby 3.3 / 4.0 の全 Minitest スイート | 60 分 / Ruby 1 本 |
| Tier B | `weekly.yml` | 毎週日曜 18:00 UTC(月曜 03:00 JST)、手動 | census、決定的fixture、受入れ、スループット、Ruby 3.4、musl、musl/aarch64 | 25〜90 分 / ジョブ |
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
同じ手動実行では `native-aarch64-smoke` も実行し、AArch64 Ruby上の
native loader/libc、Fiddleによるshared object、aggregate・variadic ABIを
小さな専用テストで確認する。x86_64上のQEMU実行結果をnative integrationの
代用にはしない。native smoke jobは `uname` だけでなく、Rubyの
`RbConfig::CONFIG["host_cpu"]` と `arch` も検証し、誤ったRubyが2件のskipだけで
greenになることを防ぐ。job冒頭の `tools/native_aarch64_preflight.rb` は
`uname`、Ruby、`gcc -dumpmachine`、Fiddle、Ruby headers、dynamic loader、libcを
実測し、`native-aarch64-preflight` として結果JSON・context artifactへ記録する。
preflightを含むrequired IDがすべて `pass` で、native contextの実測値がAArch64に
一致しない限りjobはgreenにならない。

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

Tier A と Ruby 3.4 のジョブは、ツールチェーンの存在を先に確認したうえで
`tools/ci_check_skips.rb` を実行する。スクリプトは Minitest のサマリを読み取り、
次の条件でジョブを失敗させる。

| 条件 | 既定値 | 意味 |
|---|---:|---|
| failures または errors がある | — | テスト失敗 |
| skips が `CI_MAX_SKIPS` を超える | 55 | 外部ツール欠落または skip 条件の拡大 |
| runs が `CI_MIN_RUNS` 未満 | 2500 | スイートの途中終了またはロード漏れ |

skip 理由は絶対パスと数値を正規化したヒストグラムとして出力する。
`CI_MAX_SKIPS` と `CI_MIN_RUNS` は環境変数で上書きできる。

## Tier B のジョブ

### census

`test/corpus/gems.rb` の固定バージョンの gem を対象に
`bundle exec rake corpus:census` を実行し、
`test/corpus/include-census.md` と生成ログを artifact に保存する。
コミット済み census と差分がある場合はジョブを失敗させる。

### acceptance-fixture

`acceptance-fixture` はネットワークを使わない必須の製品シグナルである。
コミット済みのmkmf/rmake fixtureを専用profileで実行し、
`mkmf-fixture-probes` と `rmake-fixture-build` の両方を構造化結果に記録する。
このjobが通らない場合、live networkの結果が成功しても製品の受入れ成功とは扱わない。

### acceptance

`RMAKE_ACCEPTANCE=1 bundle exec rake test TESTOPTS="--verbose"` でネットワークを
必要とする受入れテストを実行し、続けて
`ruby tools/m2_acceptance.rb` で M2 の受入れを実行する。
通常の Tier A と実行件数が異なるため、Tier A の skip 閾値は適用しない。

strict acceptanceでは `RMAKE_ACCEPTANCE_STRICT=1`、`CI_PROFILE=acceptance-live`、
`CI_RESULT_PATH=tmp/ci/acceptance-results.json` を設定する。受入れテストは
stable IDごとの構造化結果を出力し、`tools/ci_check_acceptance.rb` が
[`config/ci/acceptance_manifest.json`](../config/ci/acceptance_manifest.json)の必須ID、
未実行、skip、`inconclusive`を確認する。fetch/unpack失敗はstrict経路でskipに変換しない。
テスト開始前に `tools/live_acceptance_preflight.rb` が Ruby、RubyGems、curl、rmake、rubycc、
strict/profile/network設定、実行CPU、結果・artifactパスを確認し、
`acceptance-live-preflight`として構造化結果へ記録する。preflight失敗は必須IDのfailとなり、
suiteの未実行をpassへ変換しない。
ネットワークやRubyGemsなど外部要因による判定不能は製品のpassにはせず、live受入れ運用で
`inconclusive`として分類する。`--allow-inconclusive` は非strictの診断レポートに
限られ、strict required jobでは指定しても失敗する。M2のjson/msgpack自身の
テスト結果もstable IDとして同じファイルに追加する。

live対象のgemとsource tarballはmanifestに固定したHTTPS URLとSHA-256を使う。
`test/support/acceptance_fetch_helper.rb` は取得を一時ファイルへ行い、digest確認後に
atomic renameする。取得結果にはexpected/actual digest、bytes、cache hit/missを
`acceptance-artifacts.json`へ記録し、checkerもlive required IDごとにartifactの存在、
URL一致、digest一致を検証する。キャッシュのchecksum不一致は自動でpassへ変換せず、
upstream変更またはmanifest更新が必要な明示的失敗とする。M2のtest-unit、
test-unit-ruby-core、rspecもバージョンを固定し、CIでは専用GEM_HOME/GEM_PATHを使う。

M2の実行後には、取得したjson/msgpackのextツリーを
`tools/scan_corpus_variadics.rb`で走査し、候補抽出結果をartifactに保存する。
scannerは候補調査用であり、struct利用の不在証明や合否判定には使わない。

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

手動実行では最初に`dispatch-contract`が入力の組み合わせを検証する。
`verify_step`と`only`を同時に指定した場合は全jobをskipせず、このvalidation jobがfailする。

| 入力 | 実行対象 |
|---|---|
| スケジュール | census、acceptance、throughput、musl、musl/aarch64、Ruby 3.4 |
| 入力なしの手動実行 | 上記 6 ジョブ |
| `verify_step` 指定 | musl の更新モード |
| `only: musl-aarch64` | musl/aarch64 のみ |
| `only: acceptance` | 決定的 fixture と live acceptance のみ |
| `only: aarch64` | native aarch64 の Tier A 全スイート |

## リリース配布物

タグ push または手動実行で Tier A を再実行する。タグ push ではタグ名から `v` を除いた
値と `Rubycc::VERSION` を比較する。

`package` ジョブは Ruby 3.3 で `gem build rubycc.gemspec` を別々の作業ディレクトリで
2 回実行し、`cmp` で gem がバイト単位で一致することを確認する。
`SOURCE_DATE_EPOCH` は git の最新コミット時刻に固定する。生成した gem は artifact
として保存し、rubygems.org への push は自動化しない。

## 実行コスト

private repository の GitHub Free Actions 枠は 2,000 分/月である。設定上限の合計は、
Tier A が push 1 回につき 120 分、週次スケジュールが 435 分、
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
