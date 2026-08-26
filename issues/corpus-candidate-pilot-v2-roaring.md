---
status: open
kind: gap
opened: 2026-08-16
closed:
branch:
pr:
steps:
  - corpus-candidate-pilot-v2-roaring-1
  - corpus-candidate-pilot-v2-roaring-2
---

# roaring 0.4.1 を正式追加するか決める — 残る障害は x86 SIMD 組み込み関数

**現在地(2026-08-27)**: 起票時の `#warning` は PR #84 で解消済み。以後の再走で
`__BYTE_ORDER__`(PR #105)と同梱 cdefs.h の `__attr_*`(PR #106)も解消し、
**残るのは AVX2 の組み込み関数だけ**である。経緯は作業ログを参照。
以下の「課題」は起票時(2026-08-16)の記述であり、当時の事実として残す。

## 課題

pilot v2で固定priorityの上位候補に選ばれた`roaring 0.4.1`は、次の固定identityを持つ。

| 項目 | 値 |
| --- | --- |
| platform | `ruby` |
| SHA-256 | `caf8802c8de04d8567fb8438d226810179f4cbb5f4f1c87d0e73bfcec54cd9e8` |
| source artifact | `docs/development/corpus-candidate-evaluation/artifacts/pilot-v2/2026-08-04/classification.json` |
| 既存検査 | identity/static一致、Actions `build_failed` |
| 既存run | [31940431681](https://github.com/nuna/rubycc/actions/runs/31940431681) |

既存runでは`ext/roaring`のnative sourceに新規system headerとSIMD/CPU関連gapがあり、
`roaring.h`の`#warning "Warning. Unrecognized compiler."`をrubyccがinvalid preprocessing directive
として拒否した。これは再現可能なrubycc gapの候補だが、標準仕様として`#warning`をどう扱うか、
archiveのCPU/compiler分岐に起因するのかを確認せずにcorpusへ追加してはいけない。

## 影響

この候補を追加できれば実際のpreprocessor/compiler gapをcorpusで固定できる可能性がある。一方、
warningの扱いを誤って修正すると、他のpreprocessorテストや診断出力を壊す。gem固有の回避策と
rubycc本体の仕様変更を分離する必要がある。

## 受け入れ条件

- 固定archive SHAとgemspecのname/version/platformを再確認し、同じarchiveで失敗を再現する
- `#warning`の入力箇所、周辺の条件分岐、rubyccの最初のエラー、host compilerの結果をreportへ記録する
- 次のいずれかを根拠付きで決定する
  - `rubycc_gap`: 標準的な`#warning`入力をrubyccが拒否しており、最小fixtureで再現する
  - `gem_branch_or_environment`: roaringのcompiler/CPU分岐またはrunner環境だけが選択されている
  - `unsupported_candidate`: 現行corpusの対象外となる非標準・再現不能なbuild形態
- `rubycc_gap`の場合、gem archiveを直接fixtureにせず、最小のpreprocessor fixtureと回帰テストを
  別compiler issue/PRとして用意する。warningの仕様と診断出力をレビューしてから修正する
- rubycc修正後に同じ固定SHAでbuild/loadを再実行し、host controlとの差、extension load、必要なupstream
  testを別statusで記録する
- `roaring`を正式corpusへ追加する場合は、既存corpusとの差分、header/compiler変更、verified記録、
  targeted/full testを一つの人間レビュー可能なPRにまとめる。自動workflowからは変更しない

## 実装計画

1. `corpus-candidate-pilot-v2-roaring-1`: 固定identityで再現し、`#warning`とcompiler/CPU分岐を
   host/rubyccで比較する
2. `corpus-candidate-pilot-v2-roaring-2`: 最小fixtureによるrubycc gapの採否を決め、必要ならcompiler
   issueへ分離した後、roaringの正式追加可否を再判定する

## 人間が行う手順

### 1. 固定入力での再現

1. 上表のidentityとsource artifactを照合し、archiveを隔離directoryへ取得する。SHA、gemspec、
   extension rootが一致しない場合は未知コードのbuildへ進まない。
2. `inspect-corpus-candidate` skillの静的phaseで、`ext/roaring`のC/H、`endian.h`、SIMD/CPU関連gap、
   extconf、build manifestを確認する。
3. `corpus-candidate-validation`を`workflow_dispatch`し、入力を次の値に固定する。

   | input | value |
   | --- | --- |
   | name | `roaring` |
   | version | `0.4.1` |
   | platform | `ruby` |
   | sha256 | `caf8802c8de04d8567fb8438d226810179f4cbb5f4f1c87d0e73bfcec54cd9e8` |
   | mode | `build_load` |

4. preflightを通過した場合だけbuild/load logを取得する。`roaring.h`の`#warning`行と最初のrubycc
   エラーを引用し、runner、Ruby、compiler、commit、run URLをreportへ記録する。archiveへのpatch、
   headerの削除、別gem版への差し替えはしない。

### 2. host/rubyccと最小fixtureの比較

1. 固定archiveから該当する`#warning`と、そこへ到達する最小の条件分岐だけを読み取る。CPU検出や
   compiler macroの全体をそのままfixtureへコピーしない。
2. host compilerが同じ入力をwarningとして受理するかを確認し、host側のwarningとrubycc側の拒否を
   別結果として記録する。host commandを新しく作る場合は、repositoryの既存compiler/preprocessor
   fixture・テスト方針に従い、gemの任意build scriptを直接実行しない。
3. `#warning`だけを含む最小fixtureをtestへ追加する案を作り、通常の`#error`、unknown directive、
   warning出力との既存仕様に矛盾しないかを人間がレビューする。fixture追加前に、これはroaringの
   正式追加ではなくrubyccの言語処理回帰テストであることを明記する。
4. `#warning`対応が必要なら、compiler issueへ切り出し、roaringのcorpus変更と同じPRで実装しない。
   対応不要なら、分岐またはrunner依存の理由と再現不能条件を記録して候補を保留する。

### 3. 正式追加の判断

- rubycc gapが最小fixtureで再現し、修正後に固定roaring archiveのbuild/loadが通った場合、既存corpusの
  追加規則に沿ってheader/compiler差分とverified記録を人間がreviewする。
- warningの扱いを修正しない場合でも、候補が再現可能なgap fixtureとして有用か、正式corpusへ入れるかを
  別々に判断する。gapを記録できることだけで`build_load_pass`とは呼ばない。
- gem branch/環境依存またはrecipe不足の場合は正式追加せず、再試行条件と不採用理由をissueへ残す。

### 4. 正式追加を行う場合

1. `#warning`のrubycc gapが最小fixtureで再現され、必要なcompiler修正が別PRでmerge済みであることを
   確認してから、roaring専用branchを作る。gemの条件分岐だけで通した結果は採用根拠にしない。
2. `test/corpus/gems.rb`、必要なheader/compiler、`data/verified_gems.json`を人間が編集し、固定SHA、
   新規header/gap、修正したpreprocessor仕様、host/rubyccのbuild/load結果をPR本文へ記録する。
3. review済みrecipeがある場合だけgem本体testをhost controlとrubyccで別々に実行する。recipeが無い
   場合は、corpusでgapを再現できることとgemがverifiedであることを別statusにする。
4. rbenvの3.3系Rubyでtargeted compiler/preprocessor test、corpus census、full `rake test`を実行し、
   AArch64など既存の対象が不要に変わっていないこととignored artifactの混入がないことを確認する。
5. reviewerは最小fixture、warningの仕様、roaring固定archiveの再検証、header/compiler差分、verified
   記録を照合する。承認・merge後にこのissueのstatus、作業ログ、PR/merge情報を更新する。

## 作業ログ

起票時。`#warning`の拒否が再現可能な新規rubycc gapか、gemのcompiler分岐・環境依存かを分離するために
起票した。

### 2026-08-25(手順 1 を実行)

**identity は一致した。** 隔離directoryへ再取得したarchiveのSHA-256は
`caf8802c8de04d8567fb8438d226810179f4cbb5f4f1c87d0e73bfcec54cd9e8`(期待値と一致、183,808 bytes)、
gemspecは `roaring` / `0.4.1` / `ruby`。extension rootは `ext/roaring`、native sourceは
C 4 本 + H 2 本(`roaring.c` だけで 26,017 行の CRoaring amalgamation)。

**`#warning` は解消していた。** `corpus-candidate-validation` を master(`90ce9ca`)で
`mode: build_load` として dispatch した([run 32849373119](https://github.com/nuna/rubycc/actions/runs/32849373119)、
Ruby 4.0.6)。preflightは `ready`、build_loadは `build_failed`。ログの `roaring.h:313` は
**エラーではなく警告として通過**している:

```
./roaring.h:313:1: warning: "Warning. Unrecognized compiler."
```

つまり [warning-directive](warning-directive.md)(PR #84)の修正が実gemで効くことを確認した。

**次の停止点は別のgapだった。**

```
./roaring.h:486:9: error: macro names must be identifiers
#ifndef !defined(__BYTE_ORDER__) || !defined(__ORDER_LITTLE_ENDIAN__)
```

`roaring.h:464` の `#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__)` で
gccは真の側、rubyccは偽の側を取る。**rubyccがgccの定義済みマクロ 5 件
(`__BYTE_ORDER__` / `__ORDER_LITTLE_ENDIAN__` / `__ORDER_BIG_ENDIAN__` /
`__ORDER_PDP_ENDIAN__` / `__FLOAT_WORD_ORDER__`)を持たない**ためで、
486行の壊れた`#ifndef`はgccが一度も読まない枝にある上流の誤りである。
rubyccの診断自体はgccと同じ文言で正しい。

compiler側のgapとして [byte-order-predefined-macros](byte-order-predefined-macros.md) を
分離して起票した(手順 2-4 の「compiler issueへ切り出す」に相当)。
**この候補の正式追加は、そちらのmerge後に固定SHAで再走してから判断する。**

なお、`#warning` の最小fixtureはPR #84で既にあるので、手順 2 の 3 番(fixture追加案)は
**その分は不要**である。

### 2026-08-25(byte order 解消後の再走)

[byte-order-predefined-macros](byte-order-predefined-macros.md) を入れたブランチで
同じ固定SHAを `build_load` した([run 32855252546](https://github.com/nuna/rubycc/actions/runs/32855252546))。
**`roaring.h:486` のエラーは消えた** — rubyccがgccと同じ枝を取るようになった。
`roaring.h:313` の `#warning` は警告として通過したまま。

次の停止点は**同梱ヘッダとホストヘッダの噛み合わせ**である。`roaring.c` / `bitmap64.c` /
`cext.c` の3 TUすべてで同じ:

```
/usr/include/malloc.h:61:3: error: expected ';'
  __attr_dealloc_free;
```

roaring固有ではなく、`#include <malloc.h>` の2行で再現する。
[bundled-cdefs-attr-macros](bundled-cdefs-attr-macros.md) として分離して起票した。

### 2026-08-26(cdefs 解消後の再走 — 停止点は 2 種類に分かれた)

master(`1c4d019`、[bundled-cdefs-attr-macros](bundled-cdefs-attr-macros.md) 込み)で
3 回目の `build_load`([run 32880666098](https://github.com/nuna/rubycc/actions/runs/32880666098))。
`malloc.h` のエラーは消え、**4 TU すべてがコンパイルまで進んだうえで、2 種類の理由で落ちた**。

| TU | 停止点 |
| --- | --- |
| `cext.c` / `bitmap32.c` / `bitmap64.c` | `roaring.h:365` の `__builtin_popcountll` が未実装 |
| `roaring.c` | `roaring.c:894` の `static inline __m256i popcount256(__m256i v)` — **AVX2 の組み込み関数** |

前者は [popcount-and-long-bit-scan-builtins](popcount-and-long-bit-scan-builtins.md) として
分離した(roaring とは独立に価値がある)。

**後者はこの候補の性格を決める。** `roaring.h:157` の
`#if defined(__x86_64__) || defined(_M_X64)` で `CROARING_IS_X64` が立ち、gcc も同じ枝を取る。
つまり**分岐選択の食い違いではなく**、gcc が `__attribute__((target("avx2")))` と
実行時ディスパッチで本当に AVX2 を積んでいる形である。rubycc は `__m256i` 系の型も
`_mm256_*` の組み込み関数も持たない。

`ROARING_DISABLE_X64` を渡せば x64 経路ごと落ちるが、**archive への patch や build 変数の
差し込みは手順で禁じている**(`extconf.rb` はこれを設定しない)。

**したがって roaring の採否は「rubycc が x86 SIMD 組み込み関数を持つか」という
プロジェクト方針の判断待ちである。** ここで勝手に決めない。選択肢は 3 つ:

1. SIMD 組み込み関数の実装に着手する(M2〜M4 級の規模。要求もコーパスからの圧力も
   これ 1 件では足りない)
2. `docs/reference/OUT-OF-SCOPE-GEMS.md` へ「対応しないと判断済み」として記録し、
   再検討の条件を書く
3. 判断を保留し、`popcount` だけ直して候補は open のまま置く(現状)

## 決着

未着手(手順 1 完了。停止点は 3 つ解消した — `#warning`(PR #84)、
`__BYTE_ORDER__`(PR #105)、同梱 cdefs.h の `__attr_*`(PR #106)。
**残る AVX2 組み込み関数は方針判断が要る**ので、ここで止めて人間の判断を待つ)。
