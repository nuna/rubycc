# rubycc v1.0 リリースチェックリスト — 非機能要件 N1〜N7(M5 H6)

DESIGN 要件 **N1〜N7**(`DESIGN.md` §3.2)の充足状況を v1.0 リリース前に一覧で確認する。
ROADMAP H6(「N1〜N7 の非機能要件をチェックリスト化して全項目確認」)に対応する記録。

既存の実測ドキュメント(THROUGHPUT.md / BENCHMARKS.md / STEPS.md)から根拠を引用し、
**推測での「OK」判定は行わない**。本チェックリスト作成にあたって新たに実測したのは
N5(gemspec 宣言の確認・静的スキャン・rbenv の状況)と N7(代表テストの単体実行)で、
他は既存記録の再確認である。

## 1. 要約表

| 要件 | 概要 | 判定 |
|---|---|---|
| **N1** コンパイル速度 | 典型的な gem を数十秒以内 | **達成**(msgpack 11 TU が 2.46 秒)。行/秒は 2026-08-27 にゲートから外し、回帰検知の計測値にした([THROUGHPUT.md](THROUGHPUT.md)) |
| **N2** 生成コード品質 | gcc -O2 比 2〜5 倍遅を許容 | **条件付き達成**(tight loop 系で最大 7.65x 超過) |
| **N3** 診断品質 | ファイル名・行・桁・ソース抜粋 | **達成** |
| **N4** 決定的ビルド | 同一入力→同一バイナリ | **達成**(Step 126 で CI 化) |
| **N5** サポート Ruby | Ruby 3.3 以上 | **達成**(3.3.12 で実機検証、Step 133 でバグ 1 件を発見・修正) |
| **N6** メモリ | 1 TU あたり 1GB 以内 | **達成**(最大 467MB) |
| **N7** テスト容易性 | 各コンポーネントを独立にテスト可能 | **達成** |

機能要件のうち v1.0 の関門になっていた 2 つも、2026-08-12 時点で満たしている
(いずれも本チェックリストの範囲外だが、リリース判断には必要なので併記する)。

| 要件 | 判定 | 根拠 |
|---|---|---|
| **R10** コーパスの 90% が gem 自身のテストに合格 | **達成** — 31/34 = **91.2%** | `test/corpus/include-census.md` の「R10 pass rate」節が `data/verified_gems.json` から生成する |
| **M4** aarch64 バックエンドの受け入れ | **達成** — 4 項目すべて完了 | `ROADMAP.md` §7 の M4 受け入れ表 |

## 2. 各要件の詳細

### N1. コンパイル速度 — 未達だが許容

- **検証**: `benchmark/throughput.rb`(`rake bench:throughput`)。実 gem 16 ファイルの
  ファイル別「行/秒」中央値。
- **実測**(`THROUGHPUT.md`): 代表値 **13,854 行/秒 = 目標の 69.3%**(Ruby 4.0.6+YJIT)。
  外部基準の gcc -O0 は同一分母で 34,874 行/秒(rubycc はその 0.39 倍)。
  sqlite3 amalgamation(25 万行)は **16,001 行/秒 = 目標の 80.0%** で完走。
  実インストール体感は msgpack(11 TU)フルビルドが **2.46 秒**。
- **判定と根拠**: 未達。THROUGHPUT.md の v1.0 判断(許容)を踏襲する。N1 本来の目的
  「典型的な gem を数十秒以内」は満たしており、最悪ケースも完走し、残ボトルネックは
  ユニークヘッダの初回字句解析に収斂した構造的なもの。回帰は
  `rake bench:throughput` で検出できる。

### N2. 生成コード品質 — 条件付き達成

- **検証**: `benchmark/run.rb`。C カーネル 5 種 + json/msgpack を gcc -O2 / gcc -O0 /
  rubycc でビルドし実行時間比較(`BENCHMARKS.md`)。
- **実測**(gcc -O2 比): treesum 1.22x / msgpack 2.60x / mandelbrot 5.02x /
  strproc 4.84x / sieve 6.52x / arrayscan 7.41x / **json 7.65x(最大)**。
- **判定と根拠**: tight loop 系・計算律速で目標(2〜5 倍)を**超過**。制御フロー律速・
  VM 律速は範囲内。許容する理由:
  1. **gcc -O0(同じ「最適化なし」同士の等価比較)では全ケース 1.1〜2.9x** に収まる。
  2. 超過分はすべて**レジスタ割付が無いことの構造的帰結**(全中間値をスタックに
     materialize)であり、原因を特定・定量化済み。
  3. 解消は **M6(基本最適化・レジスタ割付)** に計画済み。
  4. json は両ビルドとも SIMD を無効化して差分をコード生成に限定しており、表の値は
     保守側(実運用の SIMD 有効時は gcc 側がさらに有利)。

### N3. 診断品質 — 達成

- **検証**: `test/test_diagnostics.rb`(単体実行で 224 runs / 710 assertions / 0 failures)。
  ファイル名・行・桁・ソース抜粋を個別に検証するケースを持つ。
- **改善実績**(Step 115): 未宣言識別子が**静的初期化子の中**にあると原因不明の
  「unsupported initializer for global variable」になっていた誤誘導を修正。
  この改善は、sqlite3 のデバッグ中に「ヘッダ不足」を「IR のギャップ」と誤読しかけた
  実体験から生まれたもので、N3 の実効性を裏付ける事例でもある。

### N4. 決定的ビルド — 達成

- **検証**: `test/test_deterministic_build.rb`(Step 126 で新設、10 ケース)。
  同一プロセス内(両アーキ)・**別プロセス 2 回**・異なる cwd と絶対パス・
  `TZ`/`LANG`/`LC_ALL` 変更・`.so` と実行ファイルのリンク・アーカイブ・
  **メンバ mtime を未来に変えてからの再構築**・rmake の clean を挟んだフルビルド。
- **調査結論**: 修正不要。ar ヘッダは Step 30 時点で既に mtime/uid/gid = "0"、
  `Time.now` は rmake のステイル判定のみ、`rand`/`SecureRandom` 不使用、
  `__DATE__`/`__TIME__`/`__COUNTER__` は未実装、`STT_FILE` は `File.basename` で cwd 非依存。

### N5. サポート Ruby — 達成(実機検証済み)

- **変更(Step 131)**: N5 の下限を 3.2 から 3.3 に引き上げた。3.2 は EOL 済み
  (2022-12 リリース、通常のメンテナンス期限 2026-03 を経過)であり、N5 の根拠
  「YJIT 安定版」は 3.3 以降の方がよりよく満たす(`DESIGN.md` N5 参照)。
- **gemspec**: `rubycc.gemspec:17` に `spec.required_ruby_version = ">= 3.3"`(適正)。
- **静的スキャン**(`lib/`・`exe/` 全 56 ファイル):
  - `Data.define`(3.2+)を多用。3.3 で動く機能なので問題なし。
  - `it` 暗黙ブロック引数(3.4+)・`Module#set_temporary_name`(3.4+)・
    `Range#overlap?`(3.3+)・パターンマッチ・rightward assignment は**使用なし**。
  - `Set` を使う 4 ファイルはすべて `require "set"` を持つ(Step 118/120 の対応)。
  - 全ファイルに `frozen_string_literal: true`。`RUBY_VERSION` による分岐は皆無。
- **環境**: Ruby 3.3 系での実機検証は**完了**(下記「実機検証(Step 133)」)。
- **CI(Step 135 で構築)**: GitHub Actions で、push / PR ごとに **Ruby 3.3 / 4.0 の
  両端**のマトリクスで全スイートを実行し(`.github/workflows/test.yml`)、中間の
  **3.4 は週次**(`.github/workflows/weekly.yml` の `ruby-3-4` ジョブ)で全スイートを
  実行する。差分テストの相手となるツールチェイン(gcc・binutils・aarch64 クロス・
  qemu-user)を apt で導入し、欠けていたらその場で失敗させたうえで、
  `tools/ci_check_skips.rb` が skip 数・runs 数の逸脱も検出する(skip は静かに
  緑になるため)。構成の詳細は [`CI.md`](../internals/CI.md)。
- **実機検証(Step 133)**: Ruby 3.3.12 を導入して全スイートを実行したところ、
  **1 件失敗した** — `String#to_f` が「`.` の直後に小数部の数字が無く指数が続く」形
  (`1.e5`)で指数を落とす 3.3 のバグにより、浮動小数点定数がサイレントに誤変換されていた。
  正規化を入れて修正し(Step 133)、**3.3.12 と 3.4.5 の両方で 2,531 runs / 0 failures**
  を確認した。
- **判定**: **達成**。継続検証も Step 135 の CI(push ごとに 3.3 / 4.0 の両端、
  3.4 は週次)で自動化された。実際にその CI の初回実行が、Ruby 4.0 で `fiddle` が
  default gem から外れたことによる非互換(`Gemfile` への宣言漏れ)を検出しており、
  マトリクスを回す価値を裏付ける実例が早速もう 1 件増えた。この 1 件(`String#to_f`)は
  「静的スキャンで非互換が見つからない」ことが「動く」ことを意味しないという
  実例であり、下限バージョンを実際に回す価値を裏付けている。

### N6. メモリ — 達成

- **検証**: sqlite3 amalgamation(261,463 行、想定最大級の単一 TU)のフルコンパイルでの
  最大 RSS(Step 116)。
- **実測**: **467 MB**(gcc -O0 は 277 MB)。1GB の目安に対し十分な余裕。

### N7. テスト容易性 — 達成

- **コンポーネント別テスト**: CPP(`test_preprocessor.rb`/`test_scanner.rb`)、
  フロントエンド(`test_lexer.rb`/`test_parser.rb`/`test_type.rb`/`test_diagnostics.rb`/
  `test_c_suite.rb`)、コード生成(`test_execution_harness.rb`/`test_bitfield.rb`/
  `test_int128_abi.rb`/`test_aarch64_*_execution.rb` 8 本/`test_pic.rb` 等)、
  リンカ・objfile(`test_elf_reader.rb`/`test_elf_writer.rb`/`test_ar_archive.rb`/
  `test_link.rb`/`test_shared_object.rb`/`test_executable.rb`/`test_cross_abi.rb` 等)、
  ビルド統合(`test_rmake*.rb` 6 本/`test_mkmf_conftest.rb`/`test_pkgconf.rb` 等)、
  決定性・DoS 耐性(`test_deterministic_build.rb`/`test_dos_resilience.rb`)。
- **単体実行で独立に green** であることを確認: preprocessor 189 / parser 298 /
  diagnostics 224 / c_suite 221 / shared_object 25 / deterministic_build 10 runs、
  いずれも 0 failures。
- **全体規模**: 2,523 runs / 6,866 assertions / 0 failures / 47 skips(`rake test`)。

## 3. README に「既知の制限」として記載すべき項目

1. **N1 未達**: 13,854 行/秒 = 目標の 69.3%。ただし典型的な gem のフルビルドは数秒で、
   sqlite3 amalgamation も 16,001 行/秒・467MB で完走(`THROUGHPUT.md`)。
2. **N2 の超過**: gcc -O2 比で最大 7.65x(json)。レジスタ割付が無いことの構造的帰結で、
   gcc -O0 比では 1.1〜2.9x。M6 で改善予定(`BENCHMARKS.md`)。
3. **`_Atomic`(C11)未対応**: `_Atomic int x = 0;` は `error: expected ';'` になる。
   `<stdatomic.h>` は部分実装で、`memory_order_*` と `atomic_thread_fence` のみを提供する。
4. **C23 checked arithmetic は部分対応**: 同梱の `stdckdint.h` は `ckd_add`/
   `ckd_sub`/`ckd_mul` を overflow builtin にマッピングする。その他の C23 は未対応。
5. **`regex.h` は最小 ABI のみ**: `regex_t` を値で埋め込む拡張向けに
   glibc-compatible なレイアウトは同梱するが、完全な POSIX regex 実装は提供しない。
6. **`__GNUC__` を定義しない(R7)**: `#ifdef __GNUC__` の非 GNUC 側に常に展開される。
   GNU 拡張前提の最適化パスには乗れない。
7. **128 ビット整数の除算・剰余・ビット演算(`& | ^`)・可変長引数渡しが未実装**
   (`ROADMAP.md` §3)。値渡し・値返し(Step 94)とシフト(Step 95)は解消済み。
8. **C++ / configure / mini_portile 依存の gem は対象外(R10)**: grpc(C++)、
   nokogiri の vendored ビルド、ffi。nokogiri は `--use-system-libraries` なら対象内。
9. **`long double` は 8 バイト**(`double` として扱う)。`printf("%Lg", x)` に渡すと
   libc は 16 バイトを読むので値が壊れる(GAPS S)。v1.0 では文書化に留め、
   解消は直後に着手する(`ROADMAP.md` §3)。

より広範な言語機能の欠落一覧は `C11-COVERAGE.md` と `ROADMAP.md` §3 に整理済みなので、
README では要約に留めそちらへリンクする。

## 4. 参照

- `DESIGN.md` §3.2(N1〜N7 原文)・§3.3(スコープ外)
- `THROUGHPUT.md`(N1)・`BENCHMARKS.md`(N2)
- `STEPS.md` Step 115(N3)・116(N6)・124(未対応機能の実測)・126(N4)
- `ROADMAP.md` §3(既知の負債)・`C11-COVERAGE.md`(条項別の適合状況)
- `rubycc.gemspec`(N5 の宣言)

## 5. リリース手順(v1.0.0)

**v1.0.0 は 2026-08-13 に公開した。** 以下は全行が済である(タグ push と `gem push` は
**意図的に自動化しない** — アカウント保有者の操作である)。

この表を「済」で埋めても**配るものが正しいとは限らなかった**。実際にタグを打つ前に
`gem build` と `examples/distroless/Dockerfile` を走らせたところ 3 件の不具合が出ている
(経緯は `STEPS.md` の `release-tag-record-1`)。**次のリリースでも、配るものを作って
動かすまでは「済」を信じない。**

| | 状態 |
|---|---|
| `lib/rubycc/version.rb` を `1.0.0` に | **済** |
| `CHANGELOG.md` の 1.0.0 エントリ | **済**(gemspec の `files` にも追加済み) |
| README の実績を実測値に更新 | **済**(2026-08-12 時点: 検証済み gem は glibc x86-64 31 / musl x86-64 3 / glibc aarch64 6。R10 通過率 31/34 = 91.2%) |
| `bundle exec rake test` | **済** — 3,109 runs / 10,848 assertions / 0 failures / 0 errors / 41 skips(2026-08-12、`m4-aarch64-acceptance` 時点) |
| gem の再現ビルド | **済** — `SOURCE_DATE_EPOCH` 固定で 2 回ビルドし**バイト一致**(474,112 bytes) |
| 同梱物の確認 | **済** — `LICENSE.txt` / `NOTICE` / `README.md` / `CHANGELOG.md` / `data/verified_gems.json` / ヘッダ 78 本 |
| **タグ `v1.0.0` を打つ** | **済**(2026-08-12、`dca836f`。[issue](../../issues/release-v1-0-0.md))。Tier C は全ジョブ success([run 31610051259](https://github.com/nuna/rubycc/actions/runs/31610051259))で、タグと `Rubycc::VERSION` の一致・`SOURCE_DATE_EPOCH` 固定の再現ビルドを検証した |
| **`gem push`** | **済**(2026-08-13、リポジトリ所有者が実施。同 issue)。rubygems.org で `rubycc 1.0.0` の公開を確認済み。自動化しない方針は変わらない(docs/internals/CI.md) |

### 準備中に見つけて直したもの

- **`rubycc-doctor --version` が「version unknown」を返していた。** OptionParser が
  `--version` を自前で処理するが、バージョンを渡していなかったための既定メッセージ。
  **バージョンを知っている コマンドの答えとして不適切**なので直した。
  他の 4 コマンドのうち `rubycc` / `rubycc-ar` は元から正しい。
- **`CHANGELOG.md` が gem に入らなかった。** 追加したファイルを `gemspec` の
  `files` に足し忘れていた。**同梱物は毎回ビルドして確かめること**。

### 測って「直さない」と判断したもの

- **`rmake --version` と `rubycc-pkgconf --version` は未対応のまま。**
  mkmf の `pkg_config` が実際に渡すのは `--exists` / `--modversion` /
  `--cflags*` / `--libs*` **だけ**で、`--version` は呼ばない(実測)。
  **pkg-config の `--version` は本物なら pkg-config 自身のバージョンを返すもの**で、
  スクリプトがその形式を解釈しうるため、**似て非なる値を返す方が危険**である。
  必要になるまで足さない。

## 6. リリース手順(v1.1.0)

**v1.1.0 は 2026-09-12 の作業。** タグ push と `gem push` は v1.0.0 と同じく
**意図的に自動化しない**(アカウント保有者の操作)。

§5 の警告どおり、**配るものを実際に作って動かしてから**表を埋めた。

| | 状態 |
|---|---|
| `lib/rubycc/version.rb` を `1.1.0` に | **済** |
| `CHANGELOG.md` の 1.1.0 エントリ | **済**。**英語で書く**(この文書は gem に同梱されて配られる。最初 日本語で書いて直した) |
| README の実績を実測値に更新 | **済**(`corpus-debug-inspector-rbs-1` で更新済み: 41 候補 / R10 分母 35 / 検証済み 33 = **94.3%**) |
| `bundle exec rake test` | **済** — 3,498 runs / 14,489 assertions / 0 failures / 0 errors / 39 skips。`tools/ci_check_skips.rb` も OK |
| gem の再現ビルド | **済** — `SOURCE_DATE_EPOCH=1789176602` を固定して別ディレクトリで 2 回ビルドし、`cmp` で**バイト一致**(637,440 bytes、SHA-256 `42a84e1a335c4bb65de737082855da5af213bd74c48a62058cd4a75946f97d18`) |
| 同梱物の確認 | **済** — 165 ファイル。`LICENSE.txt` / `NOTICE` / `README.md` / `CHANGELOG.md` / `data/verified_gems.json` すべて在り、ヘッダ 81 本、lib 66 本、exe 5 本 |
| **配るものを動かす** | **済** — 隔離した `GEM_HOME` に `gem install` し、`rubycc` / `rubycc-ar` / `rubycc-doctor` が `1.1.0` を答えることと、`hello.c` を**コンパイルして実行できる**ことを確認 |
| **タグ `v1.1.0` を打つ** | **済**(2026-09-12、`6c9ded2`)。Tier C は全ジョブ success([run 34672677229](https://github.com/nuna/rubycc/actions/runs/34672677229))で、`Rubycc::VERSION=1.1.0 / tag=v1.1.0` の一致と `SOURCE_DATE_EPOCH=1789177496` 固定の再現ビルドを検証した |
| **`gem push`** | **済**(2026-09-12 04:30 UTC、リポジトリ所有者が実施)。rubygems.org で `rubycc 1.1.0` の公開を確認(SHA-256 `ea2adb59…`)。自動化しない方針は変わらない |

### 配った gem は、手元で検証した gem とバイトが違う

**齟齬ではない。** `SOURCE_DATE_EPOCH` は**コミット時刻に固定される**ので、
準備中の検証(マージ前のコミット、`1789176602`、637,440 bytes)と
Tier C のビルド(マージコミット、`1789177496`)では入力が違う。
再現性の主張は「**同じツリーを同じ epoch で 2 回ビルドすると一致する**」であって、
両者はそれぞれ独立にそれを満たしている。

**配るのは Tier C の artifact(`rubycc-gem`)である。** 手元で作り直すと、
コミットが同じでも**ビルド環境の差が入りうる**。CI が「2 回ビルドしてバイト一致」を
確認した現物をそのまま push するのが、検証と配布物を一致させる唯一の形である。

### 動かして確かめたこと

`--version` を 5 つのコマンドすべてに投げた。**`rmake` と `rubycc-pkgconf` は
未対応のままで、これは §5 の「測って『直さない』と判断したもの」どおり**である
(mkmf は `--version` を呼ばない。pkg-config の `--version` は本物ならツール自身の
バージョンを返すもので、似て非なる値の方が危険)。**前回 v1.0.0 で見つかった
`rubycc-doctor` の "version unknown" は再発していない。**

| コマンド | 出力 |
|---|---|
| `rubycc` / `rubycc-ar` / `rubycc-doctor` | `<名前> 1.1.0` |
| `rmake` | `rmake: Makefile: No such file`(`--version` を引数として解釈しない) |
| `rubycc-pkgconf` | `rubycc-pkgconf: unknown option '--version'` |
