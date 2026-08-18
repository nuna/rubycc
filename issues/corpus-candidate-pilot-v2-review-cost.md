---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps:
  - corpus-candidate-pilot-v2-review-cost-1
  - corpus-candidate-pilot-v2-review-cost-2
---

# corpus候補reviewの人手負荷を計測し、自動拡張の運用条件を決める

## 課題

`corpus-candidate-pilot-v2`では日次scanのwall time、timeout、workflow final failureは計測できたが、
候補を人間が確認する時間は計測していない。候補は200 unique names得られ、`review`/`needs_review`も
79 occurrenceあるため、候補を増やしたときの手動review負荷を推測で運用条件にしてはいけない。

機械実行の時間、Actionsの待ち時間、静的結果を読む時間、候補を正式追加する判断時間を混ぜると、
改善対象と許容すべき待ち時間を区別できない。

## 影響

review負荷が分からないまま候補の自動拡張を有効にすると、日次scan自体は高速でも、候補を処理する
人間の作業が滞留する可能性がある。反対にActionsの待ち時間を人手負荷として数えると、実際には
改善可能な機械処理を過大評価する。

## 目的と範囲

- 候補1件ごとの人間のactive review timeと、機械実行・待ち時間を別々に記録する
- 固定した候補選定規則のままreview件数と時間分布を集計する
- 自動corpus拡張へ昇格できるreview負荷の上限と、上限を超えた場合の停止条件を結果を見る前に決める

このissueでは候補gemのcorpus追加、header/compilerの実装、`data/verified_gems.json`の更新を行わない。

## 受け入れ条件

- 次の項目を持つreview log schemaまたはtracked templateを追加する。実測log、候補archive、Actions
  logは`docs/development/corpus-candidate-evaluation/artifacts/`配下のignored workだけに置く
  - 候補のname/version/platform/SHA、source artifact、scanner revision
  - reviewer識別子(必要なら匿名の作業者ID)、review開始・終了の時刻
  - active review seconds、機械実行seconds、Actions待ちseconds、pause理由
  - static review、build/load、upstream test、最終判断のstatus
  - 次のactionと、判断を止めた理由
- active reviewは「候補identityを確認してから、判断とnext actionを記録するまで」の人間が実際に
  作業した時間と定義する。archive download、build、Actionsの待ち時間はactive timeに含めず、
  それぞれ別の秒数へ記録する
- 最初の計測では固定priorityで選んだ候補を少なくとも3件記録する。5件未満しか得られない場合は
  p95を推定せず`insufficient_samples`と明記する
- review件数、active timeのp50/p95、候補1件あたりの機械時間、停止理由別件数をreportへ記録する
- 許容するreview負荷の目標値と根拠を、実測値を見る前にmanifestまたはissueへ記録する。目標未達を
  候補の自動採用で隠さず、日次scan継続とcorpus自動拡張の可否を別々に判定する
- `rake test`をネットワークアクセスなしで実行し、review logのschema検証を含めて0 failuresとする

## 実装計画

1. `corpus-candidate-pilot-v2-review-cost-1`: review log schema、tracked template、active/machine/wait
   timeの定義、入力値検証を追加する
2. `corpus-candidate-pilot-v2-review-cost-2`: 固定候補を人間が手順どおりにreviewして計測し、p50/p95、
   サンプル不足、運用目標の判定をreportとpilot issueへ反映する

## 人間が行う手順

### 1. 作業前の固定

1. `corpus-candidate-pilot-v2`のreport、`pilot-v2-metrics.json`、`pilot-v2-inspections.json`を読み、
   候補の再ランキングや追加選定をしない。候補の順序はmanifestの固定priorityに従う。
2. cleanな作業directoryで`git status --short`を保存し、作業用archive・unpack tree・log・reportの
   出力先を`docs/development/corpus-candidate-evaluation/artifacts/`または`mktemp -d`に限定する。
3. Rubyを暗黙のsystem Rubyにせず、rbenvで利用可能な3.3系を選ぶ。通常のHOME、既存GEM_HOME、
   repository内のtracked file、secret、credentialを候補検査へ渡さない。
4. review開始前に、候補identityと期待SHA、source artifactの存在を確認する。欠落・不一致なら
   timerを止めて`identity_mismatch`として記録し、候補の内容を推測しない。

### 2. active timeの計測

1. 候補identity確認が終わった直後にactive timerを開始し、`review_started_at`を記録する。
2. `inspect-corpus-candidate` skillの静的phaseで、gemspec、extension root、native source、build
   manifest、system/gap header、既存corpus/popularとの差分を確認する。
3. 判断材料を待つためのarchive取得、scanner実行、Actionsのworkflow実行・queue待ちはactive timerを
   止め、`machine_seconds`または`actions_wait_seconds`へ記録する。logを読んで判断している間はactive
   timerを再開する。
4. build/loadやupstream testは、別の候補issueで明示的に許可された場合だけ行う。任意URL、任意command、
   任意のRuby codeを入力して時間を短縮しない。
5. 最終statusとnext actionをreview logへ記録し、active timerを停止して`review_finished_at`を記録する。
   中断した場合は中断理由と再開時刻を別に記録し、経過時間をactive timeへ足し込まない。

### 3. 集計と判定

1. 候補ごとのlogからreview count、active p50/p95、machine p50/p95、Actions waitの合計、status別・
   停止理由別件数を計算する。
2. サンプル数が5件未満ならp95を`insufficient_samples`とし、補間値や平均値で代用しない。
3. 事前に記録したreview負荷目標と比較する。日次scanのp95・timeout・window failureとは別の判定とし、
   review負荷だけを理由に静的scanの収集結果を破棄しない。
4. 目標達成時も候補を自動追加せず、候補ごとの独立issueでidentity、build/load、必要なupstream test、
   corpus差分をreviewする。

## 作業ログ

未着手。pilot v2では人手review時間を計測していなかったため、候補の自動拡張を昇格させる前の
運用負荷計測として起票した。

## 決着

未着手。
