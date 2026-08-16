---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-daily-workflow
pr:
steps:
  - corpus-candidate-daily-workflow-1
  - corpus-candidate-daily-workflow-2
  - corpus-candidate-daily-workflow-3
---

# 完了済みUTC日を静的scanする日次GitHub Actionsを追加する

## 課題

期間sourceは手動実行しかなく、実行者の端末状態と実行頻度に依存している。1日分フルscanは
約23分で、通常PR CIの約4分より長く、RubyGems.orgという外部サービスにも依存する。
PRのrequired checkへ入れると、コード変更と無関係な通信失敗で開発を止める。

一方、日次の収集をローカルだけにすると欠測に気づきにくく、14〜28日評価の入力を同じscanner
revisionと環境で揃えにくい。このissueは
[corpus-candidate-scan-runtime](corpus-candidate-scan-runtime.md)完了後の静的な定期収集だけを
扱う。gemの `extconf.rb`、build、upstream testは実行しない。

## 影響

閉じたUTC日を独立単位で収集すれば、scheduleが遅延・欠落しても対象期間を指定して再実行できる。
また、通常CIと分離することで外部障害を製品回帰と誤認せずに済む。archiveやraw responseを
長期artifact化すると保存量が約50 MB/日以上になるため、機械比較に必要な小さいJSONだけを
保存する境界も必要である。

## 受け入れ条件

- 独立workflowを追加し、`pull_request`や通常`push`では起動しない
- scheduleは毎時0分を避け、既定で前日に完了したUTC半開区間1日をscanする
- `workflow_dispatch`でexact `from` / `to`を指定して、欠測日を同じ手順で再実行できる
- `ubuntu-24.04`、Ruby 4.0、単一x64 jobとし、Ruby/architecture matrixを作らない
- 当初のjob timeoutは35分とする。通常の`test.yml`やweekly jobの成否へ連結しない
- `permissions: contents: read`、checkoutは`persist-credentials: false`とし、repository secretを
  渡さない
- 実行対象はmetadata取得、archive取得、unpack、静的分類、corpusとの差分集計までとする。
  `gem install`、`extconf.rb`、`make`、gem本体testを実行しないことをworkflow testで検査する
- artifact名にUTC intervalとscanner commitを含め、分類JSON、run summary、短いlogだけを
  35日保持する。`.gem`、unpack tree、raw response cacheはuploadしない
- `docs/development/corpus-candidate-evaluation/artifacts/`は作業用出力としてgitignoreされ、
  `git check-ignore`で同directory配下の任意ファイルが対象になる
- 同じintervalの再実行は同じnormalized inputを持ち、SHA・分類差があればreport上で判別できる
- concurrencyで日次scanの重複実行を防ぐ。ただし進行中runを新しいscheduleが破棄しない
- scheduleの成功、意図した失敗、manual replayを各1回確認し、run URLと所要時間を作業ログへ残す
- workflow構文とscannerのhermetic testを通常の`rake test`で検証する

このPRでは、過去14〜28日の評価、候補のbuild/test、artifactからの自動issue作成、
`test/corpus/gems.rb`の変更を行わない。

## 実装計画

3タスク、各タスクを1コミットの目安とする。

1. `corpus-candidate-daily-workflow-1`: exact UTC intervalとmanual replayを受け取る独立workflowを
   作り、静的scanだけを実行する
2. `corpus-candidate-daily-workflow-2`: 最小権限、timeout、concurrency、compact artifact upload、
   retentionを設定する
3. `corpus-candidate-daily-workflow-3`: YAML/hermetic testとschedule・failure・replayの実測を
   行い、運用手順を更新する

## 作業ログ

### 2026-08-16

日次scanは公開repositoryの標準runnerで実行可能だが、ネットワーク依存なのでPR gateから分離する
方針とした。scheduleの時刻ではなくexact UTC intervalをcheckpointにし、compact JSONだけを
保存する。raw archiveはSHA付きURLから再取得できるため、Actions artifactへ保存しない。

日次workflowの実装を `corpus-candidate-daily-workflow` branchで開始した。タスク1でschedule / manual
dispatchとexact UTC 1日区間、タスク2で最小権限・35分timeout・非キャンセルconcurrency・compact
artifactを追加した。タスク3ではworkflow契約テストとmanual replay手順を追加した。

Ruby 3.3.12で `rake test` は 3256 runs / 11554 assertions / 0 failures / 0 errors / 41 skips、
workflow契約テストは 6 runs / 64 assertions、scanner targeted testは 25 runs / 128 assertions
だった。schedule success、意図したfailure、manual replayのrun URLと所要時間は、workflowをremoteへ
pushして実行可能にした後で追記する。

## 決着

(完了時に記入。結果と`docs/development/STEPS.md`の該当エントリへのリンクを残す。)
