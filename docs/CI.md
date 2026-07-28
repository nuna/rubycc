# CI 構成(GitHub Actions)

rubycc の継続的検証は 3 層に分かれている。**push ごとに回るのは Tier A のみ**で、
ネットワークや長時間を要するものは Tier B(夜間)、配布物の検証は Tier C(タグ)に
分離してある。ワークフローは `.github/workflows/` 配下、skip ガードは
[`../tools/ci_check_skips.rb`](../tools/ci_check_skips.rb)。

構築は **Step 135**。

## 3 層の構成

| 層 | ファイル | トリガ | 目的 | 所要時間の目安 | 失敗が意味すること |
|---|---|---|---|---|---|
| **A** | `test.yml` | `push`(master)/ PR / 手動 / 他ワークフローからの呼び出し | 全 Minitest スイートを Ruby 3.3 / 3.4 / 4.0 で実行 | 1 バージョンあたり 10〜20 分(3 本並列) | 回帰、またはサポート Ruby のいずれかでの非互換。**マージしてはいけない** |
| **B** | `nightly.yml` | 毎日 18:00 UTC(03:00 JST)/ 手動 | コーパス census の再生成差分、ネットワーク受け入れ、スループット計測 | census 〜20 分 / acceptance 〜60 分 / throughput 〜30 分(3 ジョブ並列) | census: ヘッダ網羅性が変わった(要コミット)。acceptance: 実 gem のビルドが壊れた。throughput: **合否判定なし**(下記) |
| **C** | `release.yml` | `v*` タグの push / 手動 | Tier A の再実行 + gem の再現ビルド検証 | 30〜50 分 | タグと `Rubycc::VERSION` の不一致、または gem がバイト再現しない。**リリースを止める** |

Tier C の `test` ジョブは `uses: ./.github/workflows/test.yml` で **Tier A をそのまま
再利用**している(このため `test.yml` に `workflow_call` トリガが必要)。リリースが
通常の push と違う基準で通ってしまうことを避けるための構成。

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
| `skips > CI_MAX_SKIPS` | 60 | 外部ツールが欠けた、または skip 条件が広がった |
| `runs < CI_MIN_RUNS` | 2400 | スイートが途中で切れた / テストファイルがロードされなかった |

同時に **skip 理由ごとのヒストグラム**(件数降順)を出す。理由に含まれる絶対パスは
`<path>`、数字は `<n>` に正規化してから集計するので、一時ディレクトリ名で分類が
無限に増えることはない。数値が動いたときに「どのツールが消えたか」がログの先頭で
分かる。

**運用**: 既定値の 60 / 2400 はローカル実測(2,531 runs / 47 skips)に対する
緩めの初期値である。**最初の green run で CI 実測値が出たら、その値に合わせて
締めること**(成功時もサマリを出力するのはこのため)。緩いままだと、
「半分が skip になった」程度の劣化を検出できない。

## 夜間ベンチが合否判定をしない理由

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
なので、夜間ジョブは差分を出力したうえで**失敗**させる。対応は「差分を確認して
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
