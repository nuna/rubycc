---
name: inspect-corpus-candidate
description: 固定されたcorpus候補gemを一件ずつローカル検査し、archiveのidentity、静的分類、corpusとの差分、隔離したbuild/load smoke、環境不足を再現可能なreportにまとめる。corpus候補の確認、候補gemのローカル検査、固定versionのbuild/load確認を依頼されたときに使う。正式なcorpus追加やverified gemの記録は行わない。
---

# corpus候補を一件ずつ検査する

候補を正式追加する前に、入力identityを固定し、静的検査と任意コード実行を分離して、比較可能な結論を作る。既存のscannerと検証toolを再利用し、手順の詳細を複製しない。

## 入力契約

次の値を受け取る。

- `name`
- `version`（必須。省略時は実行検査へ進まない）
- `platform`
- 期待するSHA-256（64桁の16進数。必須。省略時は実行検査へ進まない）
- 元artifactのパスと候補recordの識別子

元artifactをsource of truthとして読み、recordのname/version/platform/SHAと依頼された入力を照合する。recordに無い候補、形式不正のSHA、自由入力のURL・commandは受け付けない。identityを固定できない場合は、理由だけをreportして停止する。

## 共通の安全境界

1. 着手前に [`test/corpus/README.md`](../../../test/corpus/README.md)、[`tools/scan_popular_gems.rb`](../../../tools/scan_popular_gems.rb)、[`tools/verify_gem_tests.rb`](../../../tools/verify_gem_tests.rb) の該当箇所を読む。
2. `git status --short`を記録し、tracked fileを上書きしない。archive、raw response、unpack tree、log、reportの作業物は`docs/development/corpus-candidate-evaluation/artifacts/`または`mktemp -d`配下だけに置く。
3. 作業directoryを候補ごとに`mktemp -d`で作り、`HOME`、`GEM_HOME`、`GEM_PATH`をその配下へ向ける。既存のgem cache、repositoryのtracked file、secret、credentialを利用しない。終了時に作業物を削除し、永続化するのはreportの要約だけにする。
4. Ruby下限はrbenvから利用可能な3.3系を列挙して選ぶ。patch versionをskillへhard-codeせず、3.3系が無い場合は明示的に`environment_insufficient`として停止する。暗黙のsystem Rubyへfallbackしない。

   ```sh
   ruby_33="$(rbenv versions --bare | grep -E '^3\.3\.[0-9]+$' | sort -V | tail -n 1)"
   test -n "$ruby_33"
   RBENV_VERSION="$ruby_33" rbenv exec ruby -v
   ```

5. 未知コードを実行する前にsecretとcredentialを環境から除く。build/loadは明示的に依頼された場合だけ行い、可能なら使い捨てcontainer/VMで実行する。静的検査だけの依頼では`extconf.rb`、build、load、gem本体testを実行しない。

## 検査phase

### 1. archiveとidentityを再確認する

- 元artifactの固定version・platform・期待SHAからsource metadataとarchiveを再取得する。
- archiveのSHA-256を確認し、gemspecのname/version/platformを要求identityと照合してからunpack/static inspectionへ進む。
- source gemを選べない、platformが違う、SHAが不一致、archiveが壊れている場合はunknown codeを実行せず、`identity_mismatch`、`checksum_mismatch`、`environment_insufficient`などの理由で停止する。
- 取得方法、URL、API SHA、archive SHA、cache hitをreportへ記録する。固定identityを別versionのcacheで置き換えない。

### 2. 静的分類を行う

既存scannerのartifactまたは同じ固定入力で再生成したartifactを使い、次を記録する。

- gemspecのextensionとR10判定
- native source、未宣言native source、extension rootの妥当性
- C/H file数とbundled、system、gap、ruby/self headerの分類
- `candidate`、`no_ext`、`excluded`、`review`、`error`などのscanner status

`no_ext`、R10除外、未宣言native source、extension root不正、取得エラーは実行phaseへ進む停止条件とする。R10を手作業で再実装しない。静的結果だけで`verified`とは呼ばない。

### 3. 増分価値を人手reviewする

`test/corpus/gems.rb`、既存の候補artifact、popular rank artifactと照合し、既存corpus・既存候補との重複を分ける。新しいsystem header、gap header、extension/build形態の有無と、その根拠となるrecordを記録する。正式追加の価値が不明な場合は`needs_review`として停止し、候補を自動選定・自動issue化しない。

### 4. 明示依頼時だけbuild/load smokeを行う

静的phaseが停止条件なしで完了し、かつユーザーがbuild/loadを明示的に依頼した場合だけ実行する。

- archiveを隔離GEM_HOMEへlocal installし、依存gemを暗黙に取得しない。実行したcommand、Ruby version、GEM_HOME、archive SHAを記録する。
- gemspecが宣言するextensionまたは候補固有のdocumented entry pointをloadする。`require`成功だけで終わらせず、期待する`.so`が隔離directoryから`$LOADED_FEATURES`へ入ったこと、または候補固有のsanity条件を確認する。
- pure-Ruby fallback、別GEM_HOMEのextension、loadされていない`.so`を成功と数えない。結果は`build_load_pass`、`build_failed`、`fallback_or_not_loaded`、`environment_insufficient`のいずれかで記録する。
- build/load成功を`verified`やcorpus追加可と表現しない。upstream testは次phaseのrecipeがある場合だけ扱う。

### 5. recipeがある候補だけupstream testへ進める

候補がrepositoryでreview済みのrecipeを[`tools/verify_gem_tests.rb`](../../../tools/verify_gem_tests.rb)に持つ場合だけ、ユーザーの明示依頼に従ってhost controlとrubyccを別々に実行する。recipeが無い場合、任意URL・任意command・dispatch入力のtest scriptは実行せず、`recipe_missing`として停止する。sanity、failures、errors、timeout、environment不足を別statusにし、`--update`を使わない。`data/verified_gems.json`、`test/corpus/gems.rb`、headerは変更しない。

## report schemaと終了条件

候補ごとに次のJSON相当のreportをignored workへ書く。値を観測できない欄は推測で埋めず、`not_requested`、`not_run`、`environment_insufficient`のいずれかにする。

```json
{
  "schema_version": 1,
  "input": {"name": "...", "version": "...", "platform": "...", "expected_sha256": "...", "source_artifact": "..."},
  "identity": {"archive_sha256": "...", "gemspec": {"name": "...", "version": "...", "platform": "..."}},
  "static": {"status": "...", "r10": "...", "native_sources": [], "extension_root": "...", "headers": {"system": [], "gap": []}},
  "incremental_review": {"in_corpus": false, "in_popular": false, "new_headers": [], "decision": "..."},
  "build_load": {"status": "not_requested", "ruby": "...", "sanity": "not_run"},
  "upstream_tests": {"status": "not_run"},
  "next_action": "..."
}
```

reportの`next_action`には、停止理由、追加で必要な環境、または独立した候補issueへ進める条件を一つだけ書く。候補ごとの結論をissue/STEPSへ要約するときも、`build成功`と`verified`、静的候補と正式追加を混同しない。
