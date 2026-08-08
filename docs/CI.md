# CI 構成(GitHub Actions)

rubycc の継続的検証は 3 層に分かれている。**push ごとに回るのは Tier A のみ**で、
ネットワークや長時間を要するものは Tier B(週次)、配布物の検証は Tier C(タグ)に
分離してある。ワークフローは `.github/workflows/` 配下、skip ガードは
[`../tools/ci_check_skips.rb`](../tools/ci_check_skips.rb)。

構築は **Step 135**。

## 3 層の構成

| 層 | ファイル | トリガ | 目的 | 所要時間の目安 | 失敗が意味すること |
|---|---|---|---|---|---|
| **A** | `test.yml` | `push`(master)/ PR / 手動 / 他ワークフローからの呼び出し | 全 Minitest スイートを Ruby 3.3 / 4.0(両端)で実行 | 1 バージョンあたり 10〜20 分(2 本並列) | 回帰、またはサポート Ruby のいずれかでの非互換。**マージしてはいけない** |
| **B** | `weekly.yml` | 毎週日曜 18:00 UTC(月曜 03:00 JST)/ 手動 | コーパス census の再生成差分、ネットワーク受け入れ、スループット計測、Ruby 3.4 の全スイート、**手動の native aarch64 全スイート**、**musl での全スイートと gem install** | census 〜20 分 / acceptance 〜60 分 / throughput 〜30 分 / ruby-3-4 〜25 分 / aarch64 〜60 分(2本並列) / musl 〜90 分 / musl-aarch64 〜90 分(6 ジョブ並列。aarch64 は `only` の手動実行) | census: ヘッダ網羅性が変わった(要コミット)。acceptance: 実 gem のビルドが壊れた。throughput: **合否判定なし**(下記)。ruby-3-4: 中間バージョン固有の非互換。aarch64: native ARM Ruby/runner 上の非互換。musl: **glibc/musl 互換の主張の、未検証だった側が壊れた**(下記) |
| **C** | `release.yml` | `v*` タグの push / 手動 | Tier A の再実行 + gem の再現ビルド検証 | 30〜50 分 | タグと `Rubycc::VERSION` の不一致、または gem がバイト再現しない。**リリースを止める** |

Tier C の `test` ジョブは `uses: ./.github/workflows/test.yml` で **Tier A をそのまま
再利用**している(このため `test.yml` に `workflow_call` トリガが必要)。リリースが
通常の push と違う基準で通ってしまうことを避けるための構成。

## native aarch64 の全スイート(`weekly.yml` の `aarch64`)

M4 の最後の環境受入れとして、native aarch64 Ruby 上で Tier A と同じ全スイートを回す。
専用 workflow は作らず、`weekly.yml` の `aarch64` job から `test.yml` を reusable workflow
として呼び出す。これにより Ruby 3.3 / 4.0 の matrix、toolchain の検査、skip ガード、
ログ artifact の形式が通常の Tier A と一つに保たれる。

この job は hosted ARM runner の分数が大きいため、週次 schedule では起動しない。
Actions の手動実行で `only: aarch64` を選んだときだけ走り、`ubuntu-24.04-arm` 上で
`uname -m` が `aarch64` であることと Ruby 自身の target を記録してからテストする。
`only` を指定しない通常の週次実行は、従来の job 群だけを実行する。

## apt で入れるパッケージとその根拠

本スイートは**差分テスト主体**(同じソースを rubycc と参照実装の両方でビルドして
突き合わせる)なので、ツールチェインが入っていない CI ランナーではテストの意味が
無くなる。3 層とも次のセットを入れる。

| パッケージ | 何のために必要か |
|---|---|
| `build-essential` | `gcc`(x86_64 差分テストの参照実装)と `make`。`test/support/execution_helper.rb` は gcc を**無条件に呼ぶ**ので、無いと skip ではなく**失敗**する |
| `binutils` | `readelf` / `ld` / `ar` / `nm`。自作 ELF・アーカイブを外部ツールに読ませる検証で使う |
| `pkg-config` | `rubycc-pkgconf` の差分検証 |
| `gcc-aarch64-linux-gnu` | aarch64 差分テストの参照コンパイラ |
| `binutils-aarch64-linux-gnu` | `aarch64-linux-gnu-objdump`(生成命令語の逆アセンブル検証) |
| `libc6-dev-arm64-cross` | `/usr/aarch64-linux-gnu/lib/ld-linux-aarch64.so.1` と `libc.so.6`。自作リンカが生成した aarch64 実行ファイルを qemu 下で走らせるのに要る |
| `qemu-user` | aarch64 実行オラクル |

### `qemu-user` であって `qemu-user-static` ではない

`test/support/aarch64_execution_helper.rb` が探すコマンド名は
**`qemu-aarch64`**(22 行目、`QEMU = "qemu-aarch64"`)である。
`qemu-user-static` がインストールするのは `qemu-aarch64-static` という別名なので、
static 版だけを入れると `available?` が false になり、**aarch64 実行テストが
まるごと静かに skip される**。緑のまま検証が消えるので、この違いは重要。

## skip の暴走ガード(`CI_MAX_SKIPS` / `CI_MIN_RUNS`)

上記のツールのうち gcc 以外は、**無ければ skip**するように書かれている。開発機では
正しい振る舞いだが、CI では「apt のパッケージが 1 つ落ちる → 数百件が skip に変わる
→ ジョブは緑」という事故になる。skip は失敗と違って静かに通る。

対策は二重。

1. **Tier A の "Verify the toolchain is complete" ステップ**で、各ツールの
   `--version` と sysroot のファイル存在を確認し、1 つでも欠けたら**その場で失敗**
   させる(skip が増えてから気付くのでは遅い)。
2. **`tools/ci_check_skips.rb`** が、テスト実行ログ(`TESTOPTS="--verbose"` で
   取得)から Minitest のサマリ行を読み、次のいずれかで失敗する。

| 条件 | 既定値 | 意味 |
|---|---|---|
| `failures > 0` / `errors > 0` | — | rake の終了コードで既に落ちているはずの二重防御 |
| `skips > CI_MAX_SKIPS` | 55 | 外部ツールが欠けた、または skip 条件が広がった |
| `runs < CI_MIN_RUNS` | 2500 | スイートが途中で切れた / テストファイルがロードされなかった |

同時に **skip 理由ごとのヒストグラム**(件数降順)を出す。理由に含まれる絶対パスは
`<path>`、数字は `<n>` に正規化してから集計するので、一時ディレクトリ名で分類が
無限に増えることはない。数値が動いたときに「どのツールが消えたか」がログの先頭で
分かる。

**運用**: 最初の green run(Step 135)で CI 実測値が出た結果、CI は
**2,547 runs / 52 skips**、ローカルは **2,547 runs / 47 skips** だった。
runs は一致しているのに skips が 5 件ずれているのは、内訳が異なる 2 つの効果が
たまたま相殺しているためで、単一の原因ではない。

- **−1**: CI には本物の `pkg-config` が入っているため、
  `test_matches_real_pkg_config_for_zlib` が skip ではなく実行される
  (ローカルは pkg-config 不在のため常に skip)。
- **+6**: `test_rmake_golden.rb` の `make -n` 突き合わせ 6 件が CI では skip
  される。フィクスチャの Makefile が**開発機の Ruby ヘッダの絶対パス**を
  埋め込んでおり、その絶対パスが CI ランナー上には存在しないため。これは
  CI 側だけでは解消できない構造的な差である。

現在の閾値 55 / 2500 は、この実測値(52 skips / 2,547 runs)に小さな余裕を
足したもの。テストを増やすと runs は増える一方なので、`CI_MIN_RUNS` が
テスト追加だけで誤検知することはない。テストの増減があった場合はこの基準値も
追随して更新すること。

## musl ジョブ(`weekly.yml` の `musl`)

M5 は「glibc/musl 互換ヘッダ」を掲げているが、**その主張を支える計測は全て
glibc 側で取られていた** — ABI ハーネスも、コーパスも、
`data/verified_gems.json` の全 18 エントリもである。このジョブが残りの半分。
構築は **Step 174**。

### `container:` を使わず自分で `docker run` する

GitHub Actions のジョブコンテナには、ランナーが**自前の glibc リンクの node**を
差し込む。Alpine イメージはそれを実行できないので、`container: ruby:4.0-alpine`
にすると `uses:` を使うステップが軒並み動かなくなる。
**チェックアウトはホスト(glibc)側で済ませ、そのディレクトリを bind mount して
`docker run` する**構成にすれば、Actions 側は glibc のまま、
**musl に置かれるのは rubycc だけ**になる。計測したいのはそこだけなので、この形にした。

コンテナ内で走るのは [`../.github/scripts/musl-suite.sh`](../.github/scripts/musl-suite.sh)。
インラインの `run:` に書かないのは、`docker run ... sh -c '...'` の入れ子クォートが
読めなくなることと、ファイルなら CI の外で `sh -n` にかけられるからである。

### apk で入れるパッケージ

| パッケージ | 何のために必要か |
|---|---|
| `build-base` | `gcc` / `make` / `musl-dev`。**Alpine の gcc は musl を吐く**ので、差分テストの参照実装が musl ツールチェインになる。このジョブの主眼そのもの |
| `binutils` | glibc 側と同じ理由(`readelf` / `ld` / `ar` / `nm`) |
| `pkgconf` | `pkg-config` の提供元(Alpine では `pkg-config` はこのパッケージ) |
| `libffi-dev` | `fiddle`(生成した `.so` を dlopen するテストが使う)のビルドに要る |
| `zlib-dev` / `yaml-dev` | zlib・psych の extconf が探すホストライブラリ。**このジョブが検証する 3 gem には含まれないが先に入れておく** — パッケージが無いせいで probe が落ちたものを「musl の差」と読み違えないため |

**aarch64 のクロスツールチェインは Alpine に無い**ので、aarch64 差分テストは
このジョブでは設計上まるごと skip される。`tools/ci_check_skips.rb` を
このジョブで回していないのはそれが理由で、acceptance ジョブの理由(実行形状が変わる)
とは別である。閾値は aarch64 の skip だけで発火してしまい、musl について何も語らない。

### 週次は回帰、手動は記録

`tools/verify_gem_tests.rb` は `--update` に `--step N` を要求する
(番号が evidence 文字列に入る)。週次のスケジュール実行には渡せる番号が無いので、
**`workflow_dispatch` の入力 `verify_step` の有無で 2 つのモードに分けた**。

| 起動 | `verify_step` | phase 2 の挙動 |
|---|---|---|
| 週次スケジュール | 空 | **読み取り専用**。「この 3 gem は musl でまだビルドでき、テストが通るか」という回帰の問い |
| 手動 dispatch | ステップ番号 | `--update` で `data/verified_gems.json` を書き、`weekly-musl` アーティファクトとして上げる。**そのファイルをそのままコミットする**ので、DB を書くのは変わらずツールだけ |

**記録用の dispatch では musl 以外の 4 ジョブが走らない**(各ジョブの
`if: inputs.verify_step == ''`)。記録したいときに他の 4 本を引き連れると
1 回あたり 255 分かかり、**記録そのものより随伴のほうが高くつく**ためである。
`schedule` イベントでは `inputs` が null で、GitHub の式評価では
`null == ''` が真になるので、**週次実行は従来どおり 5 ジョブ全部**が走る。
記録用 dispatch のコストは musl ジョブの約 90 分だけ。

## aarch64 musl の ABI 測定ジョブ(`weekly.yml` の `musl-aarch64`)

Step 193 で musl の ABI を同梱ヘッダに反映したが、**測れたのは x86-64 だけ**だった。
arch 層は「機種で値が動く」ことを前提に存在する層なので、
x86-64 の値を aarch64 に写すのは**測定ではなく仮定**になる。
このジョブがその測定を取る。構築は **Step 197**。

### 全スイートは走らせない

qemu エミュレーション下では遅すぎる(ROADMAP §8 が明記)。
走らせるのは **ABI を測る 2 本だけ** — `test_header_abi.rb` と
`test_freestanding_headers.rb`。`bundler` も使わず `gem install minitest` だけにする
(Gemfile の `fiddle` はソースビルドを要するが、この 2 本は fiddle を使わない)。

### 赤でよいジョブである

**目的は測ることで、緑にすることではない。** 差分がログに残ることが成果なので
`continue-on-error` は付けず、**赤をそのまま出してログを上げる**。
先頭に `uname -m` / `RbConfig` の arch / `gcc -dumpmachine` を記録して、
**本当に aarch64 かつ musl だったこと**を証拠として残す。

### `only` 入力 — 1 ジョブだけ回すため

このジョブを `verify_step` だけで守ると、**起動する手段が「週次まるごと」しか無くなる**。
1 ジョブの答えを得るのに他 5 ジョブ分の分数を払うことになるので、
`workflow_dispatch` に **`only`** 入力を足した。

| 起動 | 走るジョブ |
|---|---|
| 週次スケジュール | **6 つ全部**(`inputs` が null で、GitHub の式評価では `null == ''` が真) |
| `verify_step` 指定 | **`musl` のみ**(記録用) |
| `only: musl-aarch64` | **`musl-aarch64` のみ**(測定用) |
| `only: aarch64` | **`aarch64` のみ**(native Ruby 上の M4 全スイート受入れ) |
| 入力なしの手動 dispatch | 6 つ全部 |

## 週次ベンチが合否判定をしない理由

`throughput` ジョブは `BENCH_RUNS=7 rake bench:throughput` を回して結果を
アーティファクトに残すだけで、**しきい値による合否判定を行わない**。

[`THROUGHPUT.md`](THROUGHPUT.md) に記録したとおり、本ベンチは単発の before/after
比較では判定できない。開発機ですら ±10% のドリフトがあり、実際に Step 110 の改善は
単発比較では「横ばい〜悪化」に見えた。有意差が取れるのは**同一マシン・同一セッションで
HEAD → 変更後を連続実行するペア計測**だけである。共有ホストである GitHub の
ランナーはドリフトがさらに大きく、ここで引いたしきい値は偽陽性か無意味かのどちらかに
なる。

このジョブの目的は、(a) ベンチハーネス自体が壊れていないことの確認と、
(b) 傾向を見るための計測ログの蓄積、の 2 点。結果ファイルは**コミットしない**
(`benchmark/results/` にはペア計測可能な同一マシンの記録だけを残す)。

## census が差分で落ちる設計

`corpus:census` は `test/corpus/gems.rb` に**バージョン固定**で並べた実 gem を取得し、
C 拡張が `#include` するヘッダの網羅状況を `test/corpus/include-census.md` に
書き出す。このファイルはコミット対象である。

gem 側のバージョンが固定されている以上、再生成して差分が出るということは
**rubycc 側のヘッダ網羅性が変わった**ことを意味する。これは記録として残すべき情報
なので、週次ジョブは差分を出力したうえで**失敗**させる。対応は「差分を確認して
再生成したファイルをコミットする」。再生成後のファイルはアーティファクトにも
上げてあるので、ローカルで gem を取り直さずに差し替えられる。

## リリース時の `SOURCE_DATE_EPOCH` 固定

`package` ジョブは `gem build` を**別々の作業ディレクトリで 2 回**行い、`cmp` で
バイト一致を確認する。要件 **N4(決定的ビルド)** の配布物版にあたる
(コンパイラ出力側の N4 は `test/test_deterministic_build.rb` が検証している)。

このとき `SOURCE_DATE_EPOCH` を `git log -1 --pretty=%ct`(コミット時刻)に固定する。
RubyGems は gem 内の各エントリの mtime と build 時刻にこの環境変数を使うため、
**固定しないと同一の入力でも 2 回のビルドがバイト単位で食い違う**。それでは
「時計が進んだこと」を測っているだけで、再現性の検証にならない。
作業ディレクトリを 2 つに分けているのは、ビルドが自身のパスに依存していた場合も
検出するため。

## gem push を自動化していないこと

`release.yml` に **`gem push` は意図的に置いていない**。rubygems.org への公開は
取り消せない操作で、アカウント保有者の判断に属する(`RELEASE-CHECKLIST.md` も
公開は手動と記録している)。**公開は手動**で行う。

自動化する場合の選択肢は 2 つ。

- **trusted publishing**(rubygems.org の OIDC 連携): 長期シークレットを持たずに
  済む。`package` ジョブに `permissions: id-token: write` が必要。
- **`RUBYGEMS_API_KEY` シークレット**を登録し、`gem push` ステップを追加する。

いずれにせよ `if: github.ref_type == 'tag'` で保護すること。`release.yml` の末尾に
同趣旨のコメントを残してある。

## 実行コストと無料枠

このリポジトリは private のままなので、GitHub Free の Actions 無料枠
**2,000 分/月**が上限になる。Linux ランナーは消費倍率 1 倍だが、課金は
**ジョブごとに分単位で切り上げ**られる。ジョブを並列化しても待ち時間が減るだけで、
消費する分数そのものは減らない。

当初案(Ruby 3 バージョンを push ごとに全て回し、夜間に 3 ジョブを追加で回す)は
月 5,000〜7,000 分程度の見積りになり、無料枠の **2.5〜3.5 倍**だった。そのため
次の 3 つの削減策を採った。

1. push のマトリクスを両端(3.3 / 4.0)の 2 本に絞り、中間の 3.4 は週次(`weekly.yml`
   の `ruby-3-4` ジョブ)に回す。
2. Tier B の頻度を夜間から週次に落とす。
3. ドキュメントのみの変更では Tier A を起動しない(`test.yml` の `paths-ignore`)。

削減後の見積りは、Tier A が 1 push あたり約 50 分、weekly が 1 週あたり約 255 分
(census 20 分 + acceptance 90 分 + throughput 30 分 + ruby-3-4 25 分 +
musl 90 分)。コードの
push が月 20 回程度と仮定すると、概算で**月 1,700 分程度**となり無料枠に収まる。
**これはあくまで見積りであり、実測値が出た段階でこの節を更新すること。**

トレードオフも明記しておく。中間バージョン(3.4)固有の非互換は、週次実行のため
**検出が最大 1 週間遅れる**可能性がある。ただし両端(下限の 3.3 と最新の 4.0)は
push のたびに検証しているので、3.4 だけで壊れる範囲は限定的という判断で許容した。

将来もし無料枠が苦しくなった場合の選択肢としては、リポジトリを public にする
(標準ランナーは public リポジトリでは無料枠を消費しない)ことと、セルフホスト
ランナーを用意することがある。

## Ruby 4.0 と bundled gems

Ruby 4.0.0 で `fiddle` が default gem から bundled gem に変わったため、Bundler
配下では Gemfile への宣言なしに `require "fiddle"` すると `LoadError` になる。
CI の初回実行(Step 135)がこれを実際に検出し、`Gemfile` の development グループに
`gem "fiddle"` を追加して解決した。開発機の Ruby だけで回していては
気付けない類の非互換であり、マトリクスを回す価値を裏付ける実例である
(Step 133 の `String#to_f` の一件と同種)。

## CI が検出した 2 件目の実バグ: pkg-config のシステムパスフィルタ

`test_matches_real_pkg_config_for_zlib`(`test/test_pkgconf.rb`)は本物の
`pkg-config` と rubycc の出力を突き合わせる比較テストとして Step 59 から
存在していたが、**この開発機には pkg-config が入っておらず、常に skip
されていた**。つまり比較テスト自体は存在していたのに、一度も実際に
比較が走ったことがなかった。

CI(pkg-config あり)で初めてこのテストが実行され、`--libs zlib` の
multiarch libdir(`-L/usr/lib/x86_64-linux-gnu`)が本物の pkg-config の
出力には現れないことが分かった。Debian/Ubuntu の pkg-config は multiarch
の libdir もシステムライブラリパスとして扱い、`-L` を出力から落とすためで、
Step 136 で入れた `SystemPathFilter` の既定値(`/usr/lib`, `/usr/lib64` の
み)がこれを含んでいなかった。

この不一致は推測では直さず、CI の実測データが出るまで待ってから
`SystemPathFilter::DEFAULT_LIBRARY_DIRECTORIES` に multiarch のディレクトリを
追加する形で修正した(`/usr/local/lib` は本物の pkg-config がシステム
ディレクトリとして扱わないため、意図的に含めていない)。

## ローカルでの再現

```sh
# Tier A 相当
mkdir -p tmp/ci
bundle exec rake test TESTOPTS="--verbose" 2>&1 | tee tmp/ci/test.log
ruby tools/ci_check_skips.rb tmp/ci/test.log

# 閾値を変えて試す(手元ではツールの有無で skip 数が変わる)
CI_MAX_SKIPS=100 CI_MIN_RUNS=2000 ruby tools/ci_check_skips.rb tmp/ci/test.log
```

`tmp/` は `.gitignore` 済みなので、CI ログの置き場所も `tmp/ci/` に統一している。
