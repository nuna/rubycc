---
status: open
kind: infra
opened: 2026-08-16
closed:
branch:
pr:
steps:
  - corpus-candidate-pilot-v2-1
  - corpus-candidate-pilot-v2-2
  - corpus-candidate-pilot-v2-3
---

# 日次フル静的scanでcorpus候補の収率・増分価値・運用時間を検証する

## 課題

[corpus-candidate-evaluation](corpus-candidate-evaluation.md) は4週分のselection-onlyで3,881件の
新規未検査名を得たが、archive静的検査は最新3件だけで、全件no-extだった。そのため現行bounded
routeを不採用とした。一方、別の完了済みUTC 1日を全件静的scanすると、109 archiveから8件の
`[1]`候補を得た。3件sampleだけでは発見方法の収率を判断できない。

改善後の方法がcorpusを適切に増やすか確認するには、日次の全静的scanを一定期間継続し、
候補件数だけでなく既存corpusに対するheader/gapの増分、検査コスト、build/test可能性を同時に
測る必要がある。このissueは次の完了を前提とする。

- [corpus-candidate-scan-runtime](corpus-candidate-scan-runtime.md)
- [corpus-candidate-daily-workflow](corpus-candidate-daily-workflow.md)
- [corpus-candidate-local-inspection-skill](corpus-candidate-local-inspection-skill.md)
- [corpus-candidate-validation-workflow](corpus-candidate-validation-workflow.md)

## 影響

候補数だけで採用すると、既存gemの更新や同じheader集合を繰り返しreviewする仕組みになりうる。
反対に3件sampleの失敗だけで破棄すると、実測1日で8件あった候補を見落とす。14日分の閉じた
windowを欠測なく検査し、静的増分と上位候補の実行結果を結び付けることで、収集経路の価値と
維持費を分けて判断できる。

## 受け入れ条件

- 結果を見る前に、連続する完了済みUTC 1日windowを14個、scanner revision、ranking規則、
  中止条件とともにmanifestへ固定する
- 各日をselection-onlyではなく全source gemのarchive静的検査まで実行する。欠測日は
  `workflow_dispatch`で同じintervalを再実行し、欠測のまま分母から除外しない
- 日別・合計で次を集計する
  - release entry、unique gem、取得成功、retry、error、byte数
  - `[1]`、`[1b]`、`[2]`、`[3]`、`[R]`、no-ext
  - 既存corpusとpopular上位100にないunique候補、日をまたぐ重複率
  - 新規system header spelling、新規gap spelling、既存corpusと同一header集合の件数
  - フェーズ別elapsed time、日次wall timeのp50/p95、最大作業領域
- raw response、`.gem`、unpack tree、候補別logをcommitしない。
  `docs/development/corpus-candidate-evaluation/artifacts/`のignored workから、manifest、metrics、
  結論だけを同directory外のreview可能なreportへ要約する
- 静的候補は、次の固定順で最大3件を選ぶ
  1. 新規gap header
  2. 新規system header
  3. 既存corpusにないextension/build形態
  4. download数
  5. release日時、gem名
- 上位3件を`inspect-corpus-candidate` skillでローカル検査し、同じ固定identityを手動Actionsで
  再検証する。静的結果、rubycc build/load、host control、上流test、環境不足を混同しない
- 次の運用条件を判定する
  - 日次scanのp95目標15分、timeout率0、最終失敗率5%未満
  - 14日で少なくとも1件、既存corpusにないheader/gapまたはbuild形態を持ち、build/load成功か
    再現可能な新規rubycc gapを示す候補がある
  - 人手review件数と1候補あたりの所要時間を記録し、維持可能か明示する
- 14日で適格候補が0件の場合だけ、事前規則に従って28日まで延長する。結果を見てwindowを
  入れ替えたり、失敗日を除外したりしない
- 結果を採用・条件付き採用・不採用で決着する
  - 採用: 時間・失敗率の運用条件を満たし、増分価値のある候補を1件以上再現できる
  - 条件付き採用: 候補はあるが時間、失敗率、環境不足、人手負荷のいずれかが未達
  - 不採用: 28日まで実施しても増分価値を再現できない、または運用負荷が改善不能
- 正式追加に進む候補は1 gem = 1 issueとして新規作成する。この評価PRでは
  `test/corpus/gems.rb`、header、compiler、`data/verified_gems.json`を変更しない
- report、STEPS、issueへ実測値と決着を記録し、推定値を実測結果として書かない

## 実装計画

3タスク、各タスクを1コミットの目安とする。

1. `corpus-candidate-pilot-v2-1`: 14個のUTC日window、scanner revision、候補選定規則、資源境界を
   manifestへ事前固定する
2. `corpus-candidate-pilot-v2-2`: 日次artifactを収集・集計し、上位3候補をlocal skillと手動Actions
   で検査する
3. `corpus-candidate-pilot-v2-3`: p50/p95、失敗率、増分header/gap、review負荷を判定し、採用・
   条件付き採用・不採用とfollow-up issueを記録する

## 作業ログ

### 2026-08-16

従来評価の3件sampleに対し、1日全件scanでは109 archive中8候補が得られた。改善後の評価は
sample上限を置かず、日次全静的scanを14日継続する。定期実行が速いことだけでなく、既存corpusへ
新しいheader/gapまたはbuild形態を持ち込めることと、候補ごとの実行検査まで成功条件に含めた。

## 決着

(完了時に記入。結果と`docs/development/STEPS.md`の該当エントリへのリンクを残す。)
