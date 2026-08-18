---
status: done
kind: gap
opened: 2026-08-16
closed: 2026-08-16
branch: corpus-candidate-pilot-v2-graphql-c-parser
pr: 75, 76
steps:
  - corpus-candidate-pilot-v2-graphql-c-parser-1
  - corpus-candidate-pilot-v2-graphql-c-parser-2
---

# graphql-c_parser 1.1.4 を documented entrypointで再検証する

## 課題

pilot v2で固定priorityの上位候補に選ばれた`graphql-c_parser 1.1.4`は、次の固定identityを持つ。

| 項目 | 値 |
| --- | --- |
| platform | `ruby` |
| SHA-256 | `8d3bf769ae935373ada877fe003036892b45be98c2fbcc6731dd82af2c3e0656` |
| source artifact | `docs/development/corpus-candidate-evaluation/artifacts/pilot-v2/2026-08-03/classification.json` |
| 既存検査 | identity/static一致、build evidence/install pass、generic load sanity失敗 |
| 既存run | [31940399889](https://github.com/nuna/rubycc/actions/runs/31940399889) |

native extensionのbuild evidenceとinstallは成功した一方、汎用load sanityは`GraphQL::Language`
未定義で`fallback_or_not_loaded`になった。extensionの直接requireだけではRuby側のdocumented
entrypointと初期化を再現できない可能性があるため、toolの誤判定とgemのload不具合を分離する。

## 影響

generic `.so` requireだけで候補を落とすと、実際には使えるgemを見落とす。反対に任意のrequireや
test commandを許すと、安全境界と再現性を失う。load entrypointが固定できない候補は成功扱いにしない。

## 受け入れ条件

- 固定archive SHAとgemspecのname/version/platformをローカルskillとActionsで再確認する
- archiveのREADME、gemspec、同梱Rubyコードからdocumented load entrypointと期待する公開定数・APIを
  人間が確認し、recipeとして固定する。推測したrequireやdispatch入力のcommandは採用しない
- host controlとrubyccのGEM_HOMEを分離し、同じ固定entrypointで次を別statusに記録する
  - native extension install
  - rubycc build evidence
  - documented load sanity
  - pure-Ruby fallbackまたはextension未load
- `$LOADED_FEATURES`または候補固有のsanity条件で、隔離GEM_HOMEのextensionが実際にloadされたことを
  確認する。Ruby側の初期化だけが失敗した場合は、build失敗と混同しない
- recipeが安全にreviewできない、またはdocumented entrypointが見つからない場合は
  `recipe_missing`として停止する。任意test commandへfallbackしない
- host/rubyccの比較結果と、上流recipeがある場合のtest結果をreportへ残す。`--update`、
  `data/verified_gems.json`更新、corpus変更は自動で行わない
- 成功または再現可能なrubycc gapと判定した場合も、正式追加は人間が独立PRで行う。不採用の場合は
  generic sanityの誤判定か候補固有のload問題かを明記する

## 実装計画

1. `corpus-candidate-pilot-v2-graphql-c-parser-1`: fixed archiveからdocumented entrypointを調査し、
   安全なrecipe schemaへ登録する
2. `corpus-candidate-pilot-v2-graphql-c-parser-2`: host control/rubyccのbuild-loadと、必要ならreview済み
   upstream recipeを実行し、正式追加・保留・不採用を決定する

## 人間が行う手順

### 1. entrypointの調査

1. 上表の固定identityとsource artifactを照合する。identity不一致、SHA不一致、archive破損、
   Ruby 3.3系やActions runner不足の場合は実行せず停止する。
2. 固定archiveを隔離directoryへ展開し、README、gemspec、`lib/`、extensionのRuby wrapperだけを読む。
   READMEに記載されたrequire例、gemspecのrequire_paths、Ruby wrapperがrequireするextensionを候補として
   列挙する。
3. entrypointはname/version/SHAに紐付けた固定recipeとしてレビューする。Ruby codeの一行をその場で
   書き換えたり、失敗した定数を満たすためだけの任意requireを追加したりしない。
4. entrypointが見つからない場合は`recipe_missing`を記録して終了する。この場合、既存のgeneric load
   failureをgemの品質判定へ直接変換しない。

### 2. local staticとActions preflight

1. `inspect-corpus-candidate` skillを静的phaseで実行し、`alloca.h`、`libintl.h`、`malloc.h`、
   extension root、native source、既存corpus差分を記録する。
2. `corpus-candidate-validation`を`workflow_dispatch`し、入力を次の値に固定する。

   | input | value |
   | --- | --- |
   | name | `graphql-c_parser` |
   | version | `1.1.4` |
   | platform | `ruby` |
   | sha256 | `8d3bf769ae935373ada877fe003036892b45be98c2fbcc6731dd82af2c3e0656` |
   | mode | `build_load` |

3. preflightのidentity/static statusを確認し、candidate gateを通過した場合だけbuild/load artifactを
   取得する。artifactはrepositoryへ戻さずignored workへ保存する。

### 3. load結果の比較

1. まずhost control相当の隔離環境で、固定recipeのentrypointを実行する。依存gemの暗黙取得や既存
   GEM_HOMEへのfallbackを許さない。
2. 同じarchive、同じRuby、同じentrypointをrubycc側で実行し、build evidence、install先、
   `$LOADED_FEATURES`に入った`.so`の絶対path、公開APIのsanity結果を記録する。
3. `GraphQL::Language`が未定義でも、recipeが実際に公開するAPIと一致するなら、旧generic sanityの
   failureとは別に`documented_load_pass`または`documented_load_failed`で記録する。期待APIが定義されない
   場合はrubyccのbuild failureではなく、Ruby wrapper/entrypointの問題として切り分ける。
4. repositoryでreview済みのupstream recipeがある場合だけ、Actionsの`upstream` modeを使う。recipeが
   無い場合は`recipe_missing`で止め、任意のRSpec/Rake commandを直接実行しない。

### 4. 正式追加の判断

- host/rubyccとも固定entrypointでpassし、新規header/gap/build形態の増分根拠がある場合は、候補issueの
  差分案を人間がreviewし、必要なcorpus/header/compiler/verified変更を独立PRで行う。
- rubyccだけが失敗し、最小fixtureで再現できる場合はcompiler gapとして記録し、gem追加とcompiler修正を
  同じ変更へ混ぜない。
- entrypointが無い、controlも失敗、または純Ruby fallbackしか確認できない場合は正式追加せず、
  reportとissueへ理由を記録する。

### 5. 正式追加を行う場合

1. documented entrypointでhost/rubycc双方の結果を確認し、generic sanityの失敗を解消または正しく
   分類できた後にだけ、候補名を含む専用branchを作る。
2. `test/corpus/gems.rb`、必要なheader/compiler、`data/verified_gems.json`を検査workflowから自動更新
   せず、人間が差分根拠を確認しながら編集する。固定version/SHA、load entrypoint、期待API、control/
   rubycc結果をPR本文へ記録する。
3. review済みrecipeがある場合だけgem本体testをhost controlとrubyccで別々に実行し、recipeが無い場合は
   build/load結果をverifiedと扱わない。
4. rbenvの3.3系Rubyでtargeted test、corpus census、full `rake test`を実行し、tracked fileへ混入した
   archiveやraw logが無いことを確認する。
5. reviewerは、`.so`が隔離GEM_HOMEから実際にloadされた証拠、公開APIのsanity、header/compiler差分、
   verified記録を照合する。承認・merge後にこのissueのstatus、作業ログ、PR/merge情報を更新する。

## 作業ログ

既存のlocal skill artifactで固定archiveのSHAとgemspec identityを再確認した。static statusは
`candidate`、extension rootは`ext/graphql_c_parser_ext`、new system headerは`alloca.h`、new gap
headerは`libintl.h`と`malloc.h`だった。

PR #75でname/version/platform/SHAに固定したdata-only recipeを追加し、documented entrypoint
`graphql/c_parser`、依存`graphql 2.6.8`、`GraphQL::CParser.parse`のsanityを実装した。host/rubyccを
別GEM_HOMEで実行し、Ruby 3.3.12のローカル検証とActions run 31950250084 (Ruby 4.0.6)の双方で
native extension install、rubycc build evidence (rubycc側)、documented loadをpassと確認した。
旧generic `.so` loadの`GraphQL::Language` NameErrorは候補のbuild failureではなく、documented
entrypointを使わない検査器の誤判定と切り分けた。

`tools/verify_gem_tests.rb --list`にreview済みupstream recipeは無かったため、任意test commandへ
fallbackせずupstream testは未実行とした。corpus、header、compiler、`data/verified_gems.json`は
変更していない。

## 決着

固定entrypointによる再検証は完了し、結果をPR #75へ反映した。候補の正式corpus追加はこの検証の
成功だけでは行わず、別の人間レビューPRで判断する。
