# セキュリティレビュー — DoS 耐性(サプライチェーン攻撃対策)

このドキュメントは、rubycc に**悪意ある入力を食わせて計算資源(CPU・メモリ・
スタック)を枯渇させる DoS** を成立させられないかを点検し、フェイルセーフを
入れた記録である。rubycc は gem のビルド時に、攻撃者が細工しうる入力
(C ソース・ヘッダ・ELF/ar・ライブラリ)を処理するため、サプライチェーン
攻撃の一部として DoS を誘発される懸念がある。

- レビュー実施: 2026-07-14
- 対策実装: **Step 32**(コミット 059d59d "Add DoS fail-safes against runaway
  parsing and macro expansion (Step 32)")
- 関連: 設計判断の要約は docs/STEPS.md の Step 32、負債表は docs/ROADMAP.md §3

## 1. 脅威モデル

rubycc が処理する入力のうち、**攻撃者が内容を制御しうる**もの:

| 入力 | 処理経路 | 攻撃者の制御 |
|---|---|---|
| C ソース / ヘッダ | プリプロセッサ → 字句 → 構文 → IR → コード生成 | gem に同梱される `.c` / `.h`、依存ヘッダ |
| ELF オブジェクト(.o) | `ObjFile::ELFReader`、`Link::PartialLinker` | vendored `.o`、他ツール産の `.o` |
| ar アーカイブ(.a) | `ObjFile::ArReader`、リンカの遅延取り込み | vendored 静的ライブラリ |
| 共有ライブラリ(.so) | `ObjFile::ELFReader`(動的シンボル) | リンク対象の `.so` |

想定する被害は**可用性の破壊**(ビルドがハング、あるいは OOM/スタック枯渇で
異常終了)。任意コード実行やメモリ破壊は Pure Ruby 実装の性質上の対象外だが、
生の `SystemStackError` がプロセス外に漏れて異常終了する事象は「明確なエラーで
拒否する」(N3: 未対応は黙って壊さない)方針に反するため、可用性の問題として
扱う。

## 2. 実証した脆弱性(対策前)

メインセッションで PoC 入力を作成し、対策前の HEAD(42abd08)で実際に再現した。

### 2.1 本体パーサの再帰下降 → `SystemStackError`(生の Ruby 例外)

`lib/rubycc/front/parser.rb` の再帰下降は深さ無制限。深くネストした入力で
Ruby のコールスタックを溢れさせ、**`CompileError` ではなく生の
`SystemStackError`** を送出する。組み込み利用(将来の rmake / rubygems_plugin)で
捕捉されなければプロセスが異常終了する。再現した経路:

| PoC 入力(縮約) | 例外発生箇所 |
|---|---|
| `int x = ((((…((1))…));`(括弧式 6 万段) | `parse_cast_expression` |
| `int x = {{{…}}};`(初期化子 4 万段) | `parse_initializer_list` |
| `int x = !!!…1;`(単項連鎖 8 万段) | 深い単項再帰 |
| `int f(){{{…}}return 0;}`(複合文 6 万段) | `parse_compound_statement` |
| `M((((…))))`(マクロ引数の括弧 7 万段) | `parse_cast_expression` |
| `1?1?…:1:1`(三項 4 万段) | 条件式の再帰 |

### 2.2 `#if` 定数式パーサの再帰下降 → `SystemStackError`

`lib/rubycc/preprocess/constant_expression.rb` の `ConstantExpressionParser` も
同じく深さ無制限。`#if ((((…))))` を数万段で `SystemStackError`。

### 2.3 マクロ展開の指数膨張 → CPU/メモリ枯渇

`lib/rubycc/preprocess/preprocessor.rb#expand_tokens`(作業キュー方式)は
処理量に上限が無い。青染め(per-token `suppress` 配列)は自己参照・相互再帰は
止めるが、**正当な指数増殖**を止められない。PoC:

```c
#define B0 1
#define B1 B0 B0
#define B2 B1 B1
/* … */
#define B40 B39 B39
int x = B40;          /* 2^40 = 約 1 兆トークンへ展開 */
```

`B40` の 1 行で 20 秒経過してもコンパイルが終わらずタイムアウト(CPU・メモリ
とも枯渇へ向かう)。これは gcc でも同様に破綻するが、サプライチェーン防御
としては明示的な上限で早期に打ち切るべきと判断した。

### 2.4 正常系(対策後も無傷であるべき挙動)

以下は対策前から正しく**停止**しており、対策で壊してはならない:

- 相互再帰マクロ `#define A B` / `#define B A` → 青染めで停止(正常)
- `#if 1` … `#endif` の 5 万段ネスト、`int ****…p;`(ポインタ宣言子 10 万段)
  → いずれもループ処理でスタックを消費せず正常終了

## 3. 分析 — 線形有界で「無限/指数ではない」箇所

以下は攻撃者制御下でも**入力サイズに対して線形**で、指数爆発も無限ループも
起こさないことを確認した。ただし巨大 `count` による大配列確保などを未然に
防ぐため、防御的な健全性チェックは入れる(§4-D)。

- **`ObjFile::ELFReader`** の各テーブル走査(セクション数・シンボル数・
  再配置数・動的エントリ数): `count` はセクションの `sh_size` から導かれ、
  各エントリ読み取り時の境界検査(`require_range`)がファイルサイズで頭打ちに
  する。`e_shnum == 0` 時に第 0 セクションの 64bit `sh_size` を数に使う経路も、
  範囲外読み取りで早期 `raise`。
- **`ObjFile::ArReader`**: メンバ走査 `pos = parse_member(pos) while …` は
  `size >= 0` により毎回 60 バイト以上前進するので無限ループにならない。
  シンボルインデックスの `count` も `offsets_end > bytesize` 検査で有界。
- **`Link::PartialLinker`** のアーカイブ遅延取り込みの不動点反復: 取り込み済み
  メンバ集合が単調増加なので必ず停止する。

## 4. 対策(フェイルセーフ)

いずれも「一定回数/深さ/総量で打ち切り、明確なエラーで拒否する」方針。
パーサ・プリプロセッサは既存の `CompileError`(file:line:col + caret 付き)、
リーダは `ELFFormatError` / `ArFormatError` を送出する。

### A. パーサの再帰深さガード(`front/parser.rb`)
共有カウンタ 1 本 + `ensure` 減算の `with_nesting_guard` ヘルパを、ネストが
深くなる各経路に配置: 式の右再帰段(cast / unary / conditional / assignment)、
複合文 `parse_compound_statement`、初期化子リスト `parse_initializer_list`、
宣言子 `parse_declarator_builder`、struct/union 本体。カウンタは全経路共有
(式の中に文、文の中に式が混ざるため深さは合算が正しい)。上限超過で
`SystemStackError` の代わりに located `CompileError`(`... nested too deeply`)。

**上限確定値 `MAX_NESTING_DEPTH = 500`**。当初案 2000 は本環境の実測で無効と判明:
- 実測で**フルパイプライン(パーサ + IR 生成 + コード生成が同一 AST を深く再帰)
  は約 330 段の括弧でスタックが溢れ、300 段は通る**。括弧経路は 1 段あたり
  約 40 Ruby フレームを消費し、単純再帰の限界は約 13,000 フレーム。よってパーサ
  単体で測った 2000 は「ガード発火前に SystemStackError」となり無効だった。
- 経路別の深さ乗数(実測): 括弧 = 4.1x/段(最悪)、単項 = 2.1x、三項/代入/
  複合文/sizeof ≈ 1.1x。
- 実コードの最大ネスト深さ(全ガード有効で実測): c-testsuite 41 / ruby.h
  スモーク 32 / examples 22。
- 500 は括弧を約 122 段まで許容 = C11 §5.2.4.1 の実装下限 63 の約 1.9 倍、
  実コード最大 41 の 12 倍。発火時のフレームは約 4,900(オーバーフロー
  約 13,000 の 38%)で、より深いスタックから呼ばれる環境(CI・埋め込みホスト)
  にも余裕。**パーサ単体でなくフルコンパイル(`Compiler#compile`)で発火前後を
  検証**(63・100 段は完走、40,000 段の全攻撃経路は located CompileError で拒否)。

### B. `#if` 式パーサの再帰深さガード(`preprocess/constant_expression.rb`)
`ConstantExpressionParser` の `parse_conditional`(括弧/三項)・`parse_unary`
(`!!!` / `---` 連鎖)に深さガード。**上限 `MAX_NESTING_DEPTH = 500`**。この軽量
文法(単一の優先順位クライミング)は約 2,500 段で溢れるため、500 は約 250 段で
拒否 = 約 10 倍のスタック余裕。実 `#if`(通常 10 段未満)を大きく上回る。

### C. マクロ展開の総量上限(`preprocess/preprocessor.rb`)
`expand_tokens` の作業キュー処理に、run 全体で消費する累積トークン予算を設け、
超過で `CompileError`(暴走マクロ・指数膨張マクロを早期打ち切り)。併せて
`#if` 条件スタック深さ、マクロ引数のネスト括弧深さにも上限。
- マクロ展開予算 **`EXPANSION_TOKEN_LIMIT = 1_000_000`**(queue.shift ごとに 1
  消費)。実測: `#include <ruby.h>` の前処理は **136,916 トークン**消費 =
  約 7.3 倍の余裕。指数膨張マクロは予算到達までフル処理してから拒否するため
  所要時間 ≈ 予算に比例(実測 500k→1.65s / 1M→3.2s / 2M→6.9s / 8M→27s)。
  7 倍の安全余裕を保ちつつ約 3.2s で打ち切る 1M を採用(当初案 8M は 27s と
  遅すぎるため不採用)。
- `#if` ネスト深さ **`CONDITIONAL_NESTING_LIMIT = 256`**(ヒープ配列でスタック
  非依存だが敵対的入力を上限化)。
- マクロ引数ネスト **`MACRO_ARGUMENT_NESTING_LIMIT = 2000`**(整数カウンタで
  再帰でないためスタック非依存の防御的上限)。

### D. リーダの `count` 健全性チェック(`objfile/elf_reader.rb`, `ar_archive.rb`)
巨大 `count` で大配列を確保・長時間ループする前に、`count` がそのテーブルの
ファイル内バイト範囲 / 最小エントリサイズから導ける最大数を超えていれば即
`ELFFormatError`。リンカの不動点反復の停止性も明示的に確認。

### E. 回帰テスト(`test/test_dos_resilience.rb`)
§2 の PoC を縮約した入力が、**`SystemStackError` やタイムアウトではなく明確な
`CompileError` / `ELFFormatError` で拒否される**こと、および「上限内の
そこそこ深い正当な入力」が従来どおりコンパイルできること(誤検知しないこと)を
検証する。

## 5. 実装状況 — 完了(Step 32、コミット 059d59d)

- **調査・実証**: 完了(§2、§3)。
- **対策実装**: 完了。上限は全て実測に基づき確定(§4-A〜C)。
  - 変更ファイル: `lib/rubycc/front/parser.rb`(A)、
    `lib/rubycc/preprocess/constant_expression.rb`(B)、
    `lib/rubycc/preprocess/preprocessor.rb`(C)、
    `lib/rubycc/objfile/elf_reader.rb`・`lib/rubycc/objfile/ar_archive.rb`(D)、
    `test/test_dos_resilience.rb`(E、新規)。
  - `rake test`: **1,395 runs / 4,011 assertions / 0 failures / 0 errors /
    19 skips**(baseline 1,374/3,948 から runs +21・assertions +63)。
    ruby.h スモーク・c-testsuite を含め全 green、`ruby -w` 無警告。
  - 誤検知調整の経緯: 当初上限 2000 は本環境のスタック実測(フルパイプラインで
    約 330 段)で無効と判明し、フルコンパイル検証のうえ 500 に確定(§4-A)。
    マクロ予算は 8M が実行時間 27s と遅すぎたため、7 倍の安全余裕を保ちつつ
    約 3.2s で打ち切る 1M に確定(§4-C)。
  - メインセッションでの対策後実証(コミット後): §2 の旧 PoC(括弧/初期化子/
    単項/三項の深いネスト、指数膨張マクロ、深い `#if` 括弧)がすべて
    `SystemStackError`/タイムアウトではなく file:line:col 付きの located
    CompileError で拒否され、ネスト 100 段の正当入力は誤検知なくコンパイル
    できることを確認済み。
- **設計上のポイント**: 脅威の性質に応じてガードを使い分けた — スタック再帰は
  深さカウンタ(A・B)、指数膨張は run 全体の累積トークン予算(C)、非再帰の
  ネスト(`#if` スタック・マクロ引数括弧)は整数上限(C)、リーダの巨大 count は
  テーブルのファイル内サイズ整合検査(D)。
- **今後の課題**:
  - 上限値は gem コーパス(R10)での実測に応じて再調整しうる。特にパーサの 500 は
    「スタック限界(~330 括弧段)の下・実コード最大 41 の上」を両立する値で、
    実行環境のスタックサイズが本環境と大きく異なる場合は再評価が必要。
  - マクロ展開のより厳密な hide-set 交差(Step 27 の既知逸脱、ROADMAP §3)は
    正しさの問題であり本 DoS 対策とは別軸。指数膨張の打ち切りは交差の有無に
    関係なく必要。
