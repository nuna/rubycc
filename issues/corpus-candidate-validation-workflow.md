---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-validation-workflow
pr: 71
steps:
  - corpus-candidate-validation-workflow-1
  - corpus-candidate-validation-workflow-2
  - corpus-candidate-validation-workflow-3
---

# 選択済みcorpus候補を隔離して検証する手動GitHub Actionsを追加する

## 課題

日次scanはarchiveの静的検査までに限定すべきだが、corpusへ進めるにはrubycc build、load smoke、
可能ならgem自身のtestとhost cc対照が必要である。これらは `extconf.rb`、Makefile、上流testという
任意コードを実行するため、scheduleで全候補へ自動実行したり、開発者の通常環境で直接実行したり
するべきではない。

既存 `tools/verify_gem_tests.rb` はrecipeのあるgemを検証できるが、候補検査専用の最小権限な
手動workflowと、静的artifactから実行検査へ進む入力契約がない。このissueは
[corpus-candidate-local-inspection-skill](corpus-candidate-local-inspection-skill.md)でローカルに
recipeと停止条件を確認した候補の再現検証だけを扱う。

## 影響

任意コード実行を静的日次jobから分離すると、候補数が増えてもsecretやcacheを一括して危険へ
さらさずに済む。また、一時的な開発者環境の成功ではなく、破棄されるrunner上のlogとJSONを
review evidenceとして残せる。

## 受け入れ条件

- `workflow_dispatch`専用の候補検証workflowを追加し、schedule、push、pull requestでは起動しない
- 入力はgem名、version、platform、期待SHA-256、検証modeとする。shellへ文字列連結せず、
  name/version/platformの形式とSHA長を検証してから配列引数または環境変数でtoolへ渡す
- `permissions: contents: read`、checkout `persist-credentials: false`、repository/environment
  secretsなし、cacheのrestore/saveなしとする
- 日次scanのartifactを信頼して実行せず、archiveを再取得してSHA/name/version/platformを
  再照合する。不一致なら未知コードを実行する前に失敗する
- build/load smokeとupstream testを別stepまたは別jobにし、前者の成功をverified gemと扱わない
- upstream modeはrepositoryでreview済みの `tools/verify_gem_tests.rb` recipeがあるgemだけ許可し、
  任意URL、任意command、dispatch入力中のtest scriptを実行しない
- rubyccとhost cc controlの結果を区別し、sanity checkで注入した`.so`が実際にloadされたことを
  証明する。`--update`は使わず、`data/verified_gems.json`を変更しない
- 1候補1jobを基本とし、build/loadは30分、upstream検証を含むjobは90分以内でtimeoutする。
  大量候補matrixやRuby/architecture全組合せを作らない
- 実行後にcacheを保存しない。upload対象はwrapperが生成したstructured resultと必要最小限のlog
  だけとし、`.gem`、source tree、GEM_HOMEをartifact化しない。retentionは14日とする
- 成功、既知制限、新規再現gap、環境不足、timeout、infrastructure failureを別statusで出力する
- input拒否、SHA不一致、build失敗、sanity失敗、recipeなし、成功をfixtureまたは安全な既知gemで
  検証し、run URLと所要時間を作業ログへ残す
- workflowの結果からcorpusを自動変更せず、正式追加は候補ごとの独立issue/PRで行う

このPRでは日次収集、候補選定、header修正、corpus正式追加を行わない。

## 実装計画

3タスク、各タスクを1コミットの目安とする。

1. `corpus-candidate-validation-workflow-1`: workflow_dispatch入力の検証と、archiveの再取得・
   SHA/name/version/platform照合を実装する
2. `corpus-candidate-validation-workflow-2`: build/loadとrecipe限定のupstream testを分離し、
   最小権限、timeout、cache禁止、structured resultを設定する
3. `corpus-candidate-validation-workflow-3`: input拒否、SHA不一致、sanity失敗、成功、環境不足を
   fixtureまたは安全な既知gemで検証し、運用手順を更新する

## 作業ログ

### 2026-08-16

静的scanと任意コード実行では必要な権限・保存物・失敗時の意味が異なるため、日次workflowから
分離した。ローカルskillでrecipeを整えた候補だけを手動再現し、実行後のcacheを次runへ渡さない
構成を成功条件にした。

`corpus-candidate-validation-workflow` branchで実装を開始した。workflow_dispatchのname/version/
platform/SHA/mode入力を環境変数で受け、固定URLのarchiveを再取得してSHA/name/version/platformを
再照合する`tools/verify_corpus_candidate.rb`を追加した。gemspecとarchive内容を静的に棚卸しし、
`no_ext`、未宣言native source、Go/Rust等の追加native source、未知のbuild manifestはbuild/load前に
停止する。作業領域はrunner tempの隔離GEM_HOMEに固定し、通常のHOME、repository、cacheを使わない。

build/load jobは30分、upstream jobは90分で分離し、upstreamは`tools/verify_gem_tests.rb`のrecipeを
`--control`とrubyccで別々に実行する。`--update`、任意command、repository secret、Actions cacheは
workflowから排除し、structured resultと短いlogだけを14日保存する。workflow契約テストとtoolの入力
検証テストを追加した。

ローカルではRuby 3.3.12で`actionagent 1.2.1`を`no_ext`、`funnel_http 0.5.12`をGo/cgoの
`review_required`として停止し、意図的なSHA不一致を`checksum_mismatch`、shell metacharacterを
`input_rejected`としてbuild前に拒否した。安全な既知gemを使うremote workflowの成功、失敗、recipe
なし、環境不足の実測とrun URLはpush後に追記する。

安全な既知gemのbuild/load smokeとして`json 2.21.1`（固定SHA
`13a43df75d95641443f5702dff350f237164a9d811ff0f2c2800d4d980220583`）をRuby 3.3.12で実行した。
archive/name/version/platformの照合、rubycc build evidence、2つのshared objectのload sanityが
すべて成功し、結果は`build_load_pass`になった。これはworkflowの経路確認用であり、upstream testの
合格や`verified_gems`/corpusへの追加を意味しない。

## 決着

(完了時に記入。結果と`docs/development/STEPS.md`の該当エントリへのリンクを残す。)
