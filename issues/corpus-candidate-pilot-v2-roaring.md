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

# roaring 0.4.1 の `#warning` preprocessor gapを再現し、対応方針を決める

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

未着手。`#warning`の拒否が再現可能な新規rubycc gapか、gemのcompiler分岐・環境依存かを分離するために
起票した。

## 決着

未着手。
