---
status: done
kind: gap
opened: 2026-08-16
closed: 2026-08-16
branch: corpus-candidate-pilot-v2-rbtrace
pr: 77
steps:
  - corpus-candidate-pilot-v2-rbtrace-1
  - corpus-candidate-pilot-v2-rbtrace-2
---

# rbtrace 0.5.5 を再検証し、bundled msgpack build失敗を切り分ける

## 課題

pilot v2で固定priorityの上位候補に選ばれた`rbtrace 0.5.5`は、次の固定identityを持つ。

| 項目 | 値 |
| --- | --- |
| platform | `ruby` |
| SHA-256 | `ed0200ffeac4251f3464412e52f36cd64c473673c2739129e0b48c568672fe68` |
| source artifact | `docs/development/corpus-candidate-evaluation/artifacts/pilot-v2/2026-08-07/classification.json` |
| 既存検査 | identity/static一致、Actions `build_failed` |
| 既存run | [31940359185](https://github.com/nuna/rubycc/actions/runs/31940359185) |

既存runでは`rbtrace.c`、`Rakefile`、`extconf.rb`を含むstatic candidateだったが、extconfがbundled
msgpackのconfigure/make installで停止した。これがrubyccの再現可能なgapなのか、bundled dependencyの
build recipe・runner環境の問題なのかを分けないままcorpusへ追加してはいけない。

## 影響

候補固有のbuild失敗をrubycc gapと誤認すると、corpusへ追加しても再現性のないfixtureになる。逆に
bundled dependencyの失敗だけで候補を捨てると、`sys/un.h`や新規gapの増分を持つ候補を見落とす。

## 受け入れ条件

- 固定archive SHAとgemspecのname/version/platformを、ローカルskillとActionsの両方で再確認する
- 同じarchiveを変更・差し替えせず、`build_load`を再実行して失敗箇所、exit status、Ruby/runner、
  generated Makefileの要点をreportへ残す
- 失敗が次のどれか一つに分類され、根拠のlogがある
  - `rubycc_gap`: rubyccの入力処理・コード生成の再現可能なgap
  - `dependency_or_recipe_failure`: bundled msgpackやrecipeの問題
  - `environment_insufficient`: runner/network/toolchain不足
  - `not_reproducible`: 同一identityで再現しない
- buildが通った場合だけ、archiveに記載されたdocumented load entrypointを固定してload sanityを行う。
  純Ruby fallbackや別GEM_HOMEのextensionを成功扱いしない
- repositoryでreview済みのupstream recipeが存在しない場合、任意test commandを実行せず
  `recipe_missing`として停止する
- `rubycc_gap`またはbuild/load passを得た場合も、このissueの検証完了だけでcorpusを自動更新しない。
  追加する場合は差分、テスト、verified記録を含む独立PRとして人間が承認する
- 不採用の場合は理由と再試行条件を記録し、`test/corpus/gems.rb`、header、compiler、
  `data/verified_gems.json`を変更しない

## 実装計画

1. `corpus-candidate-pilot-v2-rbtrace-1`: 固定identityの静的preflightとActions build/load再検証を行い、
   bundled msgpack失敗を分類する
2. `corpus-candidate-pilot-v2-rbtrace-2`: 必要なら最小fixtureまたはrecipeをreviewし、候補の採用・
   不採用を決定する。rubycc修正が必要なら別のcompiler issueへ分離する

## 人間が行う手順

### 1. 静的preflight

1. 上表のname/version/platform/SHAとsource artifactを照合する。SHAが欠ける、recordと不一致、
   archiveが取得できない場合はbuildへ進まず、`identity_mismatch`または`environment_insufficient`で停止する。
2. `inspect-corpus-candidate` skillを静的phaseだけで実行し、`rbtrace.c`、`Rakefile`、`extconf.rb`、
   `sys/un.h`とgap header、既存corpusとの差分をreportへ保存する。
3. 作業物はignored artifactまたは一時directoryだけに置き、tracked fileとverified databaseに変更が
   無いことを`git status --short`で確認する。

### 2. Actions build/load再検証

1. 検証workflowのあるcommitをcheckoutしたGitHub repositoryで、Actionsの
   `corpus-candidate-validation`を`workflow_dispatch`する。
2. 入力は次のとおり固定する。

   | input | value |
   | --- | --- |
   | name | `rbtrace` |
   | version | `0.5.5` |
   | platform | `ruby` |
   | sha256 | `ed0200ffeac4251f3464412e52f36cd64c473673c2739129e0b48c568672fe68` |
   | mode | `build_load` |

3. preflight artifactで`gate_status=candidate`、gemspec identity一致、static statusを確認してから
   build/load artifactを開く。SHA不一致やpreflight failureなら未知コードの実行結果として扱わない。
4. logでbundled msgpackのconfigure、make、installのどの段階で止まったかを確認する。別のmsgpack版を
   手動でGEM_HOMEへ入れる、gem archiveを編集する、任意のbuild commandを追加する、という回避はしない。
5. Actions run URL、commit、runner image、Ruby version、結果JSON、失敗した最初のcommandとexit statusを
   review logへ転記する。infrastructure failureだけは同じ固定入力で1回再試行し、再試行理由を記録する。

### 3. 結論の分岐

- msgpack configure/installが同じ固定入力で再現し、rubyccへ到達していない場合は
  `dependency_or_recipe_failure`。候補をcorpusへ追加せず、review済みrecipeが作れるかだけを判断する。
- rubyccのpreprocessor/codegen入力まで到達し、同じrubycc固有エラーが再現する場合は、最小C fixtureを
  作り、候補gemのarchiveをfixtureにしない形でcompiler gap issueへ切り出す。
- buildが通った場合はdocumented entrypointを候補archiveのREADME/gemspecから確認し、loadされた`.so`
  の実体と期待するRuby側の初期化を確認する。entrypointを推測して実行しない。
- いずれの分岐でも、候補の正式追加は別PRで人間が差分・回帰テスト・verified記録をレビューしてから行う。

### 4. 正式追加を行う場合

1. `dependency_or_recipe_failure`や環境不足ではなく、固定identityで再現可能なrubycc gapまたはbuild/load
   passだと確認できた後にだけ、候補名を含む専用branchを作る。
2. `test/corpus/gems.rb`、必要なheader/compiler、`data/verified_gems.json`を、検査workflowの結果から
   自動コピーせず人間が順に編集する。追加理由、固定version/SHA、host controlとrubyccの結果をPR本文へ
   記録する。
3. gem本体testを実行できるreview済みrecipeがある場合だけ、host controlとrubyccを別々に実行する。
   recipeが無ければbuild/load結果だけでverifiedとは記録しない。
4. rbenvから利用可能な3.3系Rubyを選び、targeted test、corpus census、full `rake test`を実行する。
   失敗を無視してPRを作らず、未使用artifactとtracked diffを確認する。
5. reviewerはcandidate report、追加header/compilerの根拠、テスト結果、`data/verified_gems.json`の
   変更理由を照合する。承認・merge後にこのissueのstatus、作業ログ、PR/merge情報を更新する。

## 作業ログ

固定archive `rbtrace 0.5.5` (SHA-256
`ed0200ffeac4251f3464412e52f36cd64c473673c2739129e0b48c568672fe68`)を、repo-local
`inspect-corpus-candidate` skillと`verify_corpus_candidate.rb --preflight-only`で再確認した。
local static statusは`candidate`、extension rootは`ext`、native sourceは`ext/rbtrace.c`だった。
既存artifactで確認済みのnew system headerは`sys/un.h`、gap headerは`env.h`、`msgpack.h`、`node.h`、
`st.h`、`sys/ipc.h`、`sys/msg.h`である。

Ruby 3.3.12の隔離GEM_HOMEでhost controlは`build_load_pass`、native extension installは`pass`、
shared object loadは`all_shared_objects_loaded`だった。同じ固定archiveをrubyccで実行すると、
bundled msgpackのconfigureとC compile/linkまでは成功したが、Automake/libtoolの
`install-libLTLIBRARIES` recipeをrmakeが実行できず`build_failed` (exit 1)になった。

GitHub Actions [run 31951987733](https://github.com/nuna/rubycc/actions/runs/31951987733)でも、
preflightはubuntu-24.04/Ruby 4.0.6でidentity一致・`candidate`、build/loadは同じ`make install`
段階で`build_failed` (exit 1)だった。`for`/`if`/`done`/brace groupとshell variableを含むrecipeを
candidate archiveなしの最小`Rubycc::Rmake::Executor`実行でも再現したため、分類は
`rubycc_gap`（rmake build-executor gap）とする。依存、runner環境、非再現性ではない。

review済みupstream recipeは無かったため`recipe_missing`として停止し、任意test commandとdocumented
loadは実行していない。詳細は[`pilot-v2-rbtrace-revalidation.md`](../docs/development/corpus-candidate-evaluation/pilot-v2-rbtrace-revalidation.md)
に記録し、raw JSON/logはignored artifactへ保存した。rmake側の対応は
[`rmake-automake-shell-recipes.md`](rmake-automake-shell-recipes.md)へ分離した。
corpus、header、compiler、`data/verified_gems.json`は変更していない。

## 決着

検証と分類は完了した。rbtraceはこの結果だけではcorpusへ追加せず、rmakeの修正後に固定SHAで再検証
する。rmake修正後も候補追加は独立PRで人間が判断する。
