# test/fixtures/mkmf — mkmf 生成物コーパス

M3(rmake / rubygems_plugin / pkg-config / conftest、docs/development/ROADMAP.md §6)の一次資料。
「実物の mkmf が生成した Makefile と conftest」を先に採取し、そこから逆算で
B1(rmake の Makefile サブセット)・B5(conftest 対応)の機能セットを決める。
仕様書(POSIX make)からの演繹はしない — mkmf が生成しないものは作らない、という方針。

## 何が入っているか

代表 gem の `extconf.rb` を実際に実行して得られた、各 ext ディレクトリの

- `Makefile`
- `mkmf.log`(生成された場合のみ)
- `extconf.h`(生成された場合のみ。今回採取した gem では未生成)
- `provenance.txt`(採取日時・ruby バージョン・`RbConfig::CONFIG["CC"]`・
  gem バージョン・各 ext の採取結果サマリ)

を、`test/fixtures/mkmf/<gem>-<version>/<ext名>/` に配置したもの。Makefileは原則
実物だが、json parserだけは受入れテストで使うため後述の論理パス正規化を行う。

採取対象(2026-07-18 時点):

| gem | バージョン | ext | 備考 |
|---|---|---|---|
| json | 2.21.1 | parser, generator | `JSON_DISABLE_SIMD=1`(tools/m2_acceptance.rb と同じ理由。rubycc に SIMD 組み込み関数対応が無いため） |
| msgpack | 1.8.3 | msgpack | |
| racc | 1.8.1(latest) | cparse | extconf.rb が `have_*` 系を呼ばないため mkmf.log は生成されない |
| redcarpet | 3.6.1(latest) | redcarpet | racc と同様、mkmf.log は生成されない |
| bigdecimal | 4.1.2(latest) | bigdecimal | |

## conftest ソースについて

mkmf は `have_header` / `have_func` などの probe に使った conftest ソース
(`conftest.c` 等)を判定後に削除するため、ここにファイルとして残っていない。
ただし **`mkmf.log` に `checked program was:` として probe に使ったソース全文が
そのまま記録される**ため、`mkmf.log` があれば conftest の内容も実質的に採取できて
いる。上表のとおり racc / redcarpet は probe 自体を行わない extconf.rb のため
`mkmf.log` が存在しない(mkmf の実際の挙動どおりで、採取漏れではない)。

## 未収載の gem

sqlite3 / pg は、この環境にシステム開発ヘッダ(`sqlite3.h` / `libpq-fe.h`)が
無く `extconf.rb` がヘッダ欠如で失敗するため、今回は対象外。dev ライブラリ
(`libsqlite3-dev` / `libpq-dev` 等)を導入できる環境で
`tools/collect_mkmf_corpus.rb` を再実行すれば追加できる
(`GEMS` 定数に `sqlite3`/`pg` のエントリを足す)。

## 採取内容の正規化について

`mkmf.log` はprobeの一次資料として採取時の絶対パスを含むため、そのまま保持する。
一方、json 2.21.1 parserのMakefileは `topdir`、`arch_hdrdir`、`prefix`、`arch`、
`ruby_version` の5 assignmentだけを固定した論理fixtureへ正規化する。
`test/test_rmake_tools.rb` はこれらを実行時の `RbConfig` へ注入するため、採取したPCの
Ruby prefixに依存しない。このfixtureはjsonのx86_64用probe結果
(`HAVE_X86INTRIN_H`)を含むため、AArch64の実ビルド証拠としては使わない。
collector(`tools/collect_mkmf_corpus.rb`)も同じ正規化を適用するので、再生成で戻らない。

## 再生成方法

```sh
ruby tools/collect_mkmf_corpus.rb [work_dir]
# 既定の作業ディレクトリ: /tmp/rubycc_corpus (CORPUS_WORK 環境変数で変更可)
```

ネットワーク(rubygems.org)とシステムの `ruby` / `gcc` / mkmf が必要
(probe 自体は環境の gcc で行う — tools/m2_acceptance.rb と同じ前提)。
`gem fetch` / `gem unpack` は冪等(作業ディレクトリに既に取得済みなら再取得しない)。
fixtures は毎回上書きされる(ただしjson parser Makefileは上記の正規化を再適用する)。取得・展開に失敗した gem はスキップして
標準エラーに理由を出し、1 つでも採取に成功していれば終了コード 0 を返す。

## 対応する軽量テスト

`test/test_mkmf_corpus.rb` が、各 fixture の Makefile がサフィックスルールと
`CC =` 変数代入を含むこと、mkmf.log がある fixture では conftest 全文
(`checked program was:`)が記録されていることを検証する。
