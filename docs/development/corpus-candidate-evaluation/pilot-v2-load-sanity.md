# pilot v2 load sanity: `graphql-c_parser 1.1.4`

## 目的

pilot v2で、rubycc build evidenceと汎用shared-object load sanityの結果が分かれた
`graphql-c_parser 1.1.4`を、review済みの固定entrypointで再検査した。候補を正式corpusへ
追加する検査ではなく、load recipeの安全境界とhost/rubycc比較の再現性を確認する検査である。

## 固定入力

| 項目 | 値 |
| --- | --- |
| gem | `graphql-c_parser` |
| version | `1.1.4` |
| platform | `ruby` |
| archive SHA-256 | `8d3bf769ae935373ada877fe003036892b45be98c2fbcc6731dd82af2c3e0656` |
| archive size | 40,960 bytes |
| load dependency | `graphql` `2.6.8` |
| documented require | `graphql/c_parser` |
| sanity | `GraphQL::CParser.parse("{ __typename }")` と default parser の一致 |

recipeはname/version/platform/SHAの完全一致でのみ選択されるデータ定義であり、dispatch input
からrequire path、command、Ruby expressionを受け取らない。一致するrecipeがない場合は
`recipe_missing`で停止し、任意のload commandへfallbackしない。

## 実測結果

### ローカル Ruby 3.3.12

host control、rubyccとも次の結果になった。

| compiler | native extension install | rubycc build evidence | documented load | status |
| --- | --- | --- | --- | --- |
| host | `pass` | `not_applicable` | `pass` | `documented_load_pass` |
| rubycc | `pass` | `pass` | `pass` | `documented_load_pass` |

### GitHub Actions Ruby 4.0.6

[load sanity workflow run 31950250084](https://github.com/nuna/rubycc/actions/runs/31950250084)で、
host/rubyccそれぞれに別の作業ディレクトリとGEM_HOMEを割り当てて実行した。

| compiler | native extension install | rubycc build evidence | documented load | status |
| --- | --- | --- | --- | --- |
| host | `pass` | `not_applicable` | `pass` | `documented_load_pass` |
| rubycc | `pass` | `pass` | `pass` | `documented_load_pass` |

比較ジョブの結果は `pass` で、preflightのstatic statusも `candidate` だった。raw logとJSONは
`docs/development/corpus-candidate-evaluation/artifacts/`以下へ取得したが、同ディレクトリは
`.gitignore`対象であり、commitには含めていない。

## 判定

以前のgeneric `.so` requireで観測した`GraphQL::Language`未定義は、candidateのbuild失敗ではなく、
Ruby側のdocumented requireと初期化を省略した検査器の誤判定だった。固定recipeではhost controlと
rubyccが同じAPI sanityを通過し、native extension install・rubycc build evidence・documented
loadを別statusで確認できた。

このissueでは、再現結果を検査器とworkflowへ反映しただけで、`test/corpus/gems.rb`、headers、
compiler、`data/verified_gems.json`、正式corpusは変更していない。
