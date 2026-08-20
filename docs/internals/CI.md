# CI 構成(GitHub Actions)

rubycc の継続的検証は、通常の回帰、週次の追加検証、リリース配布物の検証に分かれる。
ワークフローは `.github/workflows/`、skip ガードは
[`../tools/ci_check_skips.rb`](../../tools/ci_check_skips.rb) に定義する。

## 実行層

| 層 | ワークフロー | トリガ | 対象 | 設定上限 |
|---|---|---|---|---|
| Tier A | `test.yml` | master への push、pull request、手動、reusable workflow 呼び出し | Ruby 3.3 / 4.0 の全 Minitest スイート | 60 分 / Ruby 1 本 |
| Tier B | `weekly.yml` | 毎週日曜 18:00 UTC(月曜 03:00 JST)、手動 | census、決定的 fixture、受入れ、スループット、native aarch64 smoke、Ruby 3.4、musl、musl/aarch64 | 20〜90 分 / ジョブ |
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
   profile は x86_64 が `native-x86`、native AArch64 が `native-aarch64`。

全スイートの前に、runner が本当にそのアーキテクチャかを `uname -m`、Ruby の
`RbConfig` の `host_cpu` / `arch`、`gcc -dumpmachine`、`readelf -h $(command -v ruby)`
の 4 点で検証する。1 つでも外れたら失敗させる — 誤った Ruby で全体が skip に化けて
green になるのを防ぐため。

native aarch64 は `weekly.yml` の `aarch64` ジョブから
`test.yml` を再利用する。手動実行で `only: aarch64` を選んだ場合だけ、
`ubuntu-24.04-arm` 上で Ruby 3.3 / 4.0 の全スイートを実行する。
より軽い `native-aarch64-smoke` は**週次スケジュールでも実行する**。native の機構は
どれも AArch64 runner 上でしか何も報告しないので、全部を手動 dispatch の後ろに置くと
保証の鮮度が「最後に誰かが dispatch した時点」で止まる。job 冒頭の
`tools/native_aarch64_preflight.rb` が Ruby・`gcc -dumpmachine`・Fiddle・Ruby headers・
loader・libc を実測し、必須 ID として結果 JSON へ記録する。x86_64 上の QEMU 実行を
native integration の代用にはしない。

### dispatch する前に、変更が触るテストだけ QEMU で通す

native の全スイートは手動 dispatch なので、**x86-64 でしか動かしていない変更を投げると
往復が発生する**。実例: `gaps-s-t-u-1` は x86-64 で緑だったが、native では
skip ガードが落ちた(テストがホストではなくコンパイラ既定の x86-64 で libc を測っていた。
スイート自体は 3,109 runs / 0 failures だった)。この往復は手元で潰せる:

```sh
rake test:qemu_aarch64 FILES="test/test_preprocessor.rb test/test_elf_reader.rb"
```

arm64 コンテナ(`ruby:4.0`)で、**AArch64 の Ruby と AArch64 の gcc** を使って指定
ファイルだけを走らせる。Docker が x86-64 の場合は、タスクが最初に同じ基底イメージの
`/bin/true` を `--platform linux/arm64` で実行して、Docker デーモン自身が arm64 を
起動できることを確認する。native AArch64 の Docker デーモンでは binfmt は要らない。
この probe は Docker Desktop やリモートデーモンでもクライアント側の `/proc` と混同せず、
失敗時はイメージ構築前に復旧手順を表示して終了する。

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

ホストの qemu-user の登録(Debian は `PO`)だけでは足りない — interpreter のパスが
コンテナのマウント名前空間に無いためである。既存の binfmt エントリがある環境では
`tonistiigi/binfmt --install arm64` が no-op になることもあるので、F フラグ付きで既存
エントリを再登録してからタスクを再実行する。ホスト設定の変更はこのリポジトリから
自動では行わない。下記の bind-mount 例は、Rake タスクに自動適用するものではなく、
同じ起動経路を手動で確認するためのものである。

このホストで実証した bind-mount の最小例(ホスト側に全パスが存在する場合)は次のとおり。
これは同じ arm64 起動経路を手動で確認するための例であり、ホストの qemu やライブラリを
コンテナへ書き込まず read-only で渡す。ディストリビューションによってパスが異なるため、
存在を確認してから使う:

```sh
docker run --rm --platform linux/arm64 \
  -v /usr/libexec/qemu-binfmt:/usr/libexec/qemu-binfmt:ro \
  -v /usr/bin/qemu-aarch64:/usr/bin/qemu-aarch64:ro \
  -v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro \
  -v /lib64:/lib64:ro \
  --entrypoint /bin/true ruby:4.0
```

**全スイートをここで回さない。** native ARM ランナー比で **約 23 倍**遅い
(weekly run 31500900897 と同一テスト名で突き合わせた中央値 22.8x。2 分半 → 1 時間)。
**これはゲートではなく往復の削減であり、native の代用でもない** — 上の方針は変わらない。

タスクは基底イメージに **Tier A と同じ参照ツールチェーン**(`gcc-aarch64-linux-gnu` /
`binutils-aarch64-linux-gnu` / `libc6-dev-arm64-cross` / `qemu-user` ほか)を入れた
イメージを 1 度だけ構築して使い回す。**素のイメージで回してはいけない** — 差分テストは
ツールが無いと失敗ではなく **skip** するので、何も検査していない緑になる
(実測: 素の `ruby:4.0` で 742 skips、うち 467 件が
「aarch64 execution toolchain is not installed」。native ランナーは 241 skips)。

**このイメージの gcc は CI より新しい**(Debian trixie の 14.2 対 Ubuntu 24.04 の 13)。
gcc 14 は従来の警告のいくつかを既定でエラーにするので、**対照側が落ちる**差分テストが
3 件ある(`docs/development/GAPS.md` ギャップ W)。ここでの失敗は、まずその 3 件かどうかを見てから
AArch64 の欠陥として扱うこと。

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
| skips が `CI_MAX_SKIPS` を超える | 55(profile 指定時はその値) | 外部ツール欠落または skip 条件の拡大 |
| runs が `CI_MIN_RUNS` 未満 | 2500(同上) | スイートの途中終了またはロード漏れ |
| 承認外の skip がある | — | profile の許可リストに一致しない skip |
| 許可リストの 1 ルールが `max_count` / `min_count` を外れる | — | 既知原因の skip 件数の増減 |

skip 理由は絶対パスと数値を正規化したヒストグラムとして出力する。
`CI_MAX_SKIPS` と `CI_MIN_RUNS` は環境変数で上書きできるが、名前付き profile の
上限・下限は緩められない。

検査は 2 層である([`../config/ci/skip-baseline.json`](../../config/ci/skip-baseline.json))。

1. **総量**(`max_skips` / `min_runs`)。ツールチェーンが消えて大量に skip したのに
   緑になる、という本来の失敗モードを捕まえるのはこの層である。
2. **許可リスト**(`allowed_skips`)。各 skip は「テスト名パターン + 正規化済み理由」の
   ルールにちょうど 1 つだけ一致する必要があり、ルールごとに `min_count` / `max_count` を持つ。
   総量の余裕に隠れてしまう「新しい原因の skip」を捕まえるのはこの層である。
   既知の skip が別原因の skip に**置き換わった**場合(総数は変わらない)もここで落ちる。

`CI_ENFORCE_SKIP_BASELINE=1`(Tier A と weekly の Ruby 3.4)が追加で要求するのは
**出所のメタデータ**だけである — `provisional` が立っていないこと、
`source_log` / `measured_at` / `owner` があること。

**検査しなくなったもの**: 以前は skip 総数の完全一致(`expected_skips`)と、
テスト名 + 理由の集合全体の SHA-256(`skip_fingerprint`)も固定していた。総数は集合に
含まれるので冗長で、集合の完全一致が上の 2 層を超えて捕まえるのは「承認済みの理由のまま
テスト名が新規追加・改名され、かつ `max_count` を超えない」という狭い場合だけだった。
一方で代償は構造的で、fingerprint はローカルと CI で skip 集合が違う(41 対 40)ため
**CI ログからしか再生成できず**、test/ の skip 行に触れるコミット(直近 120 件を
ざっと数えて 2 割前後)がそのたびに
「push → 落ちる → artifact を取得 → 再計算 → push」の往復を強いられていた。
同じ理由で `expires` も廃止した — 再測定が高コストな値に期限を付けても、
内容と無関係な定期故障を生むだけである。「信用するな」の表明は `provisional` が担う。

## Tier B のジョブ

### census

`test/corpus/gems.rb` の固定バージョンの gem を対象に
`bundle exec rake corpus:census` を実行し、
`test/corpus/include-census.md` と生成ログを artifact に保存する。
コミット済み census と差分がある場合はジョブを失敗させる。
R10 の machine gate は `pg-native-source` と `sqlite3-system-libraries` の明示的な
profile を含む。profile は census に記録されるが、`data/verified_gems.json` の
install・extension load・upstream suite の証拠を代用しない。

### acceptance-fixture

manifestに固定した json 2.21.1 / msgpack 1.8.3 のURL・SHA-256を使い、
`tools/ci_prepare_acceptance_fixtures.rb` がActions cacheへ取得・検証したCI-local archiveと、
`test/fixtures/acceptance/` の期待する round-trip 結果を使って、`acceptance-fixture` profileで
fetch・unpack・extconf・build・gem installを実行する **ネットワークフリーのテストjob** である。
`CI_NETWORK=fixture` のとき fetch helper は明示されたローカル archive だけを atomic copy
し、fixture がなければネットワークへフォールバックせず typed failure にする。

cache準備後のjobは `unshare --user --map-root-user --net` の network namespace 内で、
`mkmf-fixture-probes`、`mkmf-msgpack-extconf`、`mkmf-json-extconf`、
`rmake-fixture-build`、`rmake-json-parser`、`gem-install-json`、
`gem-install-msgpack` を実行し、結果と取得 archive の digest を構造化 artifact へ記録する。

**PR の必須判定ではない。** 実行しているテスト本体は Tier A の `rake test` に
含まれるので、PR ごとの回帰検出は Tier A が担う。この job が足しているのは、
専用 profile でのネットワーク遮断実行と、必須 ID が本当に実行されたことを
`ci_check_acceptance.rb` が検証する点である。

**live acceptance の代替にはならない。** gem の取得・unpack・extconf・ビルドという、
実際の外部 gem サービスへの接続と manifest URL の健全性は live job が検証する。
この job が green でも live 経路が未実行なら、外部サービス込みの受入れは成立していない。

### acceptance

`RMAKE_ACCEPTANCE=1 bundle exec rake test TESTOPTS="--verbose"` でネットワークを
必要とする受入れテストを実行し、続けて
`ruby tools/m2_acceptance.rb` で M2 の受入れを実行する。
通常の Tier A と実行件数が異なるため、Tier A の skip 閾値は適用しない。
代わりに strict acceptance(`RMAKE_ACCEPTANCE_STRICT=1`、`CI_PROFILE=acceptance-live`)
で安定 ID ごとの構造化結果を出力し、`tools/ci_check_acceptance.rb` が
[`../config/ci/acceptance_manifest.json`](../../config/ci/acceptance_manifest.json)の
必須 ID・未実行・skip・`inconclusive` を検査する。fetch/unpack 失敗を skip に
変換しない。取得対象は manifest に固定した HTTPS URL と SHA-256 を使い、digest 確認後に
atomic rename する。`--allow-inconclusive` は非 strict の診断用で、strict では
指定しても失敗する。

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
| スケジュール | census、acceptance-fixture、acceptance、throughput、native-aarch64-smoke、musl、musl/aarch64、Ruby 3.4 |
| 入力なしの手動実行 | 上記 8 ジョブ |
| `verify_step` 指定 | musl の更新モード |
| `only: musl-aarch64` | musl/aarch64 のみ |
| `only: acceptance` | 決定的 fixture と live acceptance のみ |
| `only: aarch64` | native aarch64 の Tier A 全スイートと native-aarch64-smoke |

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
