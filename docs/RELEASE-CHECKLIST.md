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
| **N1** コンパイル速度 | YJIT 有効時 20,000 行/秒目安 | **未達だが v1.0 で許容**(13,854 行/秒 = 69.3%) |
| **N2** 生成コード品質 | gcc -O2 比 2〜5 倍遅を許容 | **条件付き達成**(tight loop 系で最大 7.65x 超過) |
| **N3** 診断品質 | ファイル名・行・桁・ソース抜粋 | **達成** |
| **N4** 決定的ビルド | 同一入力→同一バイナリ | **達成**(Step 126 で CI 化) |
| **N5** サポート Ruby | Ruby 3.2 以上 | **静的確認のみ・実機未検証** |
| **N6** メモリ | 1 TU あたり 1GB 以内 | **達成**(最大 467MB) |
| **N7** テスト容易性 | 各コンポーネントを独立にテスト可能 | **達成** |

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

### N5. サポート Ruby — 静的確認のみ・実機未検証

- **gemspec**: `rubycc.gemspec:17` に `spec.required_ruby_version = ">= 3.2"`(適正)。
- **静的スキャン**(`lib/`・`exe/` 全 56 ファイル):
  - `Data.define`(3.2+)を多用。3.2 で動く機能なので問題なし。
  - `it` 暗黙ブロック引数(3.4+)・`Module#set_temporary_name`(3.4+)・
    `Range#overlap?`(3.3+)・パターンマッチ・rightward assignment は**使用なし**。
  - `Set` を使う 4 ファイルはすべて `require "set"` を持つ(Step 118/120 の対応)。
  - 全ファイルに `frozen_string_literal: true`。`RUBY_VERSION` による分岐は皆無。
- **環境**: rbenv には `3.4.5` と `4.0.6` のみで **3.2 系は未インストール**。
- **CI**: `.github/` 等のワークフローは**存在しない**。複数バージョンを自動検証する
  仕組みが未整備。
- **判定**: 静的に矛盾は見つからないが **Ruby 3.2 での実機実行実績はない**。
  v1.0 では「3.2 以上を宣言、CI での常時検証は未整備」と正直に記載する。

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
3. **`_Atomic`(C11)未対応**: `stdatomic.h` を同梱しない。`_Atomic int x = 0;` は
   `error: expected ';'` になることを実測確認(Step 124)。
4. **`ckd_*`(C23)未対応**: `__builtin_add_overflow` 相当が無く `stdckdint.h` を
   同梱できない(Step 124)。
5. **`regex.h` 非同梱**: oj が `regex_t` を値で埋め込むため不透明型で済まず、
   全メンバの再現がコストに見合わない(Step 124)。
6. **`__GNUC__` を定義しない(R7)**: `#ifdef __GNUC__` の非 GNUC 側に常に展開される。
   GNU 拡張前提の最適化パスには乗れない。
7. **128 ビット整数の除算・剰余・ビット演算(`& | ^`)・可変長引数渡しが未実装**
   (`ROADMAP.md` §3)。値渡し・値返し(Step 94)とシフト(Step 95)は解消済み。
8. **C++ / configure / mini_portile 依存の gem は対象外(R10)**: grpc(C++)、
   nokogiri の vendored ビルド、ffi。nokogiri は `--use-system-libraries` なら対象内。
9. **Ruby 3.2 での実機検証は未実施**(N5 参照)。

より広範な言語機能の欠落一覧は `C11-COVERAGE.md` と `ROADMAP.md` §3 に整理済みなので、
README では要約に留めそちらへリンクする。

## 4. 参照

- `DESIGN.md` §3.2(N1〜N7 原文)・§3.3(スコープ外)
- `THROUGHPUT.md`(N1)・`BENCHMARKS.md`(N2)
- `STEPS.md` Step 115(N3)・116(N6)・124(未対応機能の実測)・126(N4)
- `ROADMAP.md` §3(既知の負債)・`C11-COVERAGE.md`(条項別の適合状況)
- `rubycc.gemspec`(N5 の宣言)
