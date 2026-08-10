# テスト実装レビュー

調査日: 2026-08-09

## 結論

ローカルのテストスイートは green だが、次の観点をすべて満たすとは判定できない。

- `DESIGN.md` のABI・コーパス・性能要件が、テストで完全には確認されていない。
- AArch64の実行テストが、x86_64ホスト上のQEMUで実施されている。
- ネイティブAArch64ランナーで、x86_64用テストと同じスイートが動くことを確認できない。
- 既に通るケースや受入れ失敗をskipにして、greenになり得る箇所がある。

## 採用した方針

レビュー後、以下の方針を採用する。いずれも一括変更ではなく、検証結果を確認しながら段階的に進める。具体的な実装順序とtools/CI変更は[`TEST-PLAN.md`](TEST-PLAN.md)に定義する。

### 1. AArch64実行テスト：QEMU検証を維持し、native検証を追加する

- QEMUによるAArch64差分テストは、PRのcross検証として維持する。
- ジョブ名・文書上はnative実行と区別し、「AArch64 target execution」と明示する。
- native AArch64 runnerでは、Ruby、loader、libc、Fiddle、代表的なABIのスモークテストを実行する。
- native AArch64の全スイートは、当面は週次・手動実行とする。
- QEMUのツールチェーン不足はskipではなくジョブ失敗として扱う。

### 2. x86_64専用テスト：全面共通化せず、共通ハーネスだけ抽出する

- x86_64固有のELF・relocationテストとAArch64固有テストは維持する。
- ソース生成、ABIケース、GCC比較、結果検証など、意味が共通する部分だけを共通ハーネス化する。
- loader、libc、Rubyヘッダー、Fiddleなどのホスト依存部分はtarget/host profileに集約する。
- 「同じテストファイル・同じrun数」ではなく、「同じ論理的な保証範囲」を両ターゲットで確認する。

### 3. `00130`・`00151`：強化後にケース単位でskipを解除する

- 直ちにskipを一括削除しない。
- `00130`は配列アクセス・ポインタ参照の値を個別に検証する。
- `00151`はdesignatorで初期化された値を個別に検証し、初期化子を無視しても通る誤検出を防ぐ。
- GCC版とRubycc版のstdout・終了コードを比較する。
- 根拠が揃ったケースから個別にskipを解除する。

### 4. struct `va_arg`：暫定的な診断拒否と利用実態調査を先行する

- 当面はstructをvariadicへ渡す処理とstruct `va_arg`の診断拒否を維持する。
- 「structを`...`へ渡す」「structを`va_arg`で取得する」を独立した仕様項目として整理する。
- R10対象gemでの実利用を調査する。
- 利用実態が確認された場合、小さいINTEGER struct、レジスタ枯渇、AAPCS64 HFA、SysV混在分類などの順に段階実装を検討する。
- 暫定仕様を正式採用する場合は、R9の「ABI完全互換」表現、R10対象範囲、READMEを修正する。

### 5. 受入れテスト：strict acceptanceと決定的fixtureを分離する

- 通常の`rake test`はネットワークフリーのまま維持する。
- `RMAKE_ACCEPTANCE=1`を明示したstrict CIでは、fetch/unpack失敗をskipにしない。
- timeout、429、5xxのみ限定的に再試行する。
- compile/link失敗、checksum不一致、gemテスト失敗は即時失敗とする。
- fixtureまたはchecksum付きartifactによる決定的な受入れテストを必須ジョブにする。
- live gem取得テストは外部依存ジョブとして分離し、外部障害は製品greenではなく`inconclusive`として記録する。

## 実行結果

実行環境は `x86_64`、Ruby 3.4.5。次のコマンドを実行した。

```text
bundle exec rake test TESTOPTS="--verbose"
```

結果:

```text
2957 runs, 9456 assertions, 0 failures, 0 errors, 44 skips
```

追加実装後の最終通常回帰は次の結果だった。

```text
2996 runs, 9660 assertions, 0 failures, 0 errors, 42 skips
ci_check_skips: OK (skips <= 55, runs >= 2500)
```

このPCでは `qemu-aarch64`、`aarch64-linux-gnu-gcc`、`aarch64-linux-gnu-objdump` が利用可能だった。したがって、AArch64実行テストはskipされず、QEMU経由で実行された。

`test_aarch64_execution.rb` の `test_signed_arithmetic` も、x86_64ホスト上で1 run / 2 assertions / 0 skipsとなった。

## 実装後の批判レビューと修正

実装後、目的適合性・skipによるgreen化・CI依存・保守コストの観点でタスクごとに
再レビューした。レビューで見つかった問題と対応は次のとおりである。

| タスク | 批判的な指摘 | 反映した修正 |
|---|---|---|
| 0B/2C | `--allow-inconclusive`でrequired jobをgreenにでき、fixture profileも未実装だった。さらに空の結果ファイルをJSONとして読むとreporterが初回記録に失敗した | strictでは常に失敗するcheckerへ変更し、mkmf/rmake fixture jobを追加。network contextと期限、空ファイル初期化も検証 |
| 1A | host c-suiteがnative AArch64でx86 object/headerを使う可能性があった | Rubyのhost CPUからtarget/include pathを選び、system includeを明示。oracle caseのskip再導入検出を追加 |
| 1B | `make -n`の任意失敗と未宣言targetの自動stubがskip/誤成功を生む可能性があった | CIではfail、stub対象を宣言済みprerequisiteに限定し、header独立性を全fixtureで確認 |
| 2A | fetch process timeoutとDNS/TLS等の分類が不足していた | child processを終了させるtimeout、限定retry、失敗種別、strict typed resultを追加 |
| 3 | OSの`uname`だけでは誤ったRubyでnative testがskipできた | `RbConfig::CONFIG["host_cpu"]`/`arch`をworkflowとhelperの両方で検証 |
| 4B | typedef経由のstruct `va_arg`を見逃していた。実コーパス接続もなかった | typedef検出を追加し、c-testsuite実測とM2 json/msgpack artifact走査を記録。scannerは合否判定に使わない |

なお、R10全対象gemのmacro展開・生成コードを含む手動分類は、ネットワーク取得を伴う
ためこの実装の残課題である。未実施をgreenと扱わないよう、M2で取得できた範囲だけを
 artifact化し、全体の不在証明とは主張していない。

## 6A〜6C追加実装の批判的レビュー（2026-08-10）

目的適合性、CIでの再現性、外部障害と製品失敗の分離、skipによるgreen化の観点で追加実装を再レビューした。

| 対象 | レビューで見つかった問題 | 修正・再確認 |
|---|---|---|
| 6A manifest / fetch / checker | manifest URLを定義しても実際のfetchが別経路なら検証契約が空洞化する。artifact reportや未知profileがfail-openになる可能性、cacheのpartial publish、M2依存の浮動も問題になる | live/M2はmanifestのHTTPS URLを直接取得し、SHA-256一致後にatomic renameする。reportのURL/expected/actual/bytes/cacheをcheckerで検証し、未知profile・0件選択・required artifact欠落を失敗にした。M2のtest-unit/test-unit-ruby-core/rspecを固定した |
| 6B live acceptance | ローカルの`bundle exec`環境変数がscratch GEM_HOMEへ漏れると、製品ではなくBundler環境のテストになる。CIツール欠落をsuite開始後まで発見できない。専用GEM_HOMEへinstallしたRSpecをPATH上の別版で実行する余地もあった | `test/test_gem_install.rb`でBUNDLE/RUBYOPT/RUBYLIBを分離し、live preflightを追加した。M2は`Gem.bindir/rspec`を直接実行する。ローカルでpreflightを含む10 required ID、live 30 runs / 2598 assertions、M2 json 603 tests / msgpack 455 examplesをstrict checkerでpass確認した |
| 6C native AArch64 | OSの`uname`だけでは誤ったRubyやQEMUをnativeと誤認できる。preflightが通常ログだけだと、テスト本体未実行時に原因を追跡できない。同一compiler同士の比較だけではABI差を検出できない。さらに依存導入前のpreflightが`bundle exec`に依存すると、環境確認そのものが先に失敗する | native preflightと各smoke resultへRuby `RbConfig`、gcc machine、Fiddle、headers、loader/libcを記録し、checkerが実測AArch64を要求する。preflight失敗も構造化failとartifactにする。preflightは標準ライブラリだけの`ruby`直接実行にし、rubycc caller/GCC callee、GCC caller/rubycc calleeの両方向を追加した。x86_64でrequired指定した場合はskipではなくfailになることを確認した |

この時点で残る外部確認はなく、GitHub Actions live jobと`ubuntu-24.04-arm` native jobの
実runner実測を後続runで完了した。R10全対象gemのmacro展開・生成コードを含む手動分類は、
ユーザー指定どおり未着手である。

なお、不要ファイルの `a.out` は存在しない。実装変更の範囲は上表と
[`TEST-PLAN.md`](TEST-PLAN.md)の進捗表に記録している。

## 指摘事項

### 1. [高] AArch64固有の実行テストがx86_64上で実行される

[`AArch64ExecutionHelper`](../test/support/aarch64_execution_helper.rb#L43) はホストCPUを確認せず、QEMUとcross gccの有無だけでテストを実行する。

通常のGitHub Actionsジョブもx86_64ランナー上でAArch64ツールチェーンをインストールする([`test.yml`](../.github/workflows/test.yml#L81))。テスト本体は生成したAArch64コードをQEMUで実行する([`aarch64_execution_helper.rb`](../test/support/aarch64_execution_helper.rb#L197))ため、物理的な実行環境はAArch64ではない。

提示された「CPUアーキテクチャ特有のテストは、そのアーキテクチャ上で実行したときだけ実施する」という条件には適合しない。

ネイティブAArch64ジョブは存在するが、`weekly.yml`の手動選択時だけである([`weekly.yml`](../.github/workflows/weekly.yml#L334))。

### 2. [高] ネイティブAArch64ランナーでの同一動作が保証されない

共有オブジェクトテストはx86_64用のELF machine・relocation定数を使用し、`Compiler#compile`の既定ターゲットもx86_64である([`test_shared_object.rb`](../test/test_shared_object.rb#L29)、[`test_shared_object.rb`](../test/test_shared_object.rb#L1388)、[`compiler.rb`](../lib/rubycc/compiler.rb#L62))。

その生成物をFiddleでロードするテストにホストアーキテクチャの判定がない。ネイティブAArch64上では、x86_64用 `.so` のロードを試みることになる。

一方、実行ファイルテストはx86_64用dynamic loaderのパスだけを確認する([`test_executable.rb`](../test/test_executable.rb#L685))。AArch64では実行テストがskipされ、greenでも実行範囲が狭くなる可能性がある。

また、rmakeのgolden fixtureは収集元PCの絶対Rubyヘッダーパスに依存し、別環境ではskipする設計になっている([`test_rmake_golden.rb`](../test/test_rmake_golden.rb#L22))。

### 3. [高] `00130` と `00151` のskipは現在の実装と整合しない

[`test_c_suite.rb`](../test/test_c_suite.rb#L36) は、`00130`と`00151`を「multidimensional arrays (known debt)」として無条件にskipする。AArch64側もこのskipリストを共有している([`test_c_suite_aarch64.rb`](../test/test_c_suite_aarch64.rb#L55))。

しかし、テスト本体と同じRubyccコンパイル、gccリンク、実行の経路で個別確認した結果は次のとおりだった。

```text
00130 x86_64:   exit=0, output=""
00151 x86_64:   exit=0, output=""
00130 aarch64:  exit=0, output=""
00151 aarch64:  exit=0, output=""
```

ただし、両ケースの`.expected`は空であり、特に`00151`は初期化子を無視して両方をゼロにしても成功し得る。この結果だけでskipを直ちに削除するのは不十分である。先に具体的な配列値を検証し、GCC版との比較を追加したうえで、根拠が揃ったケースから個別にskipを解除する。

### 4. [高] DESIGN.mdのR9を確認できず、struct `va_arg`を明示的に拒否している

[`DESIGN.md`](DESIGN.md#L80) は、System V AMD64 / AArch64 AAPCS64について、構造体の値渡し・返却と可変長引数を要求している。また、可変長引数の実装方針も「完全実装」としている([`DESIGN.md`](DESIGN.md#L219))。

しかし、次のケースが未確認または拒否になっている。

- `00140`: 構造体をvariadic関数へ渡すケースをskip
- `00204`: struct-by-value、HFA、struct `va_arg`をまとめてskip
- `test_va_arg_of_struct_type_is_rejected`: struct `va_arg`をコンパイルエラーとして検証([`test_diagnostics.rb`](../test/test_diagnostics.rb#L250))

整数・doubleのvariadic引数や固定引数のHFAは別テストで確認されているが、要求されるstruct `va_arg`の成功ケースは確認できない。未対応を仕様とするならDESIGN.mdに制限を追記し、対応予定ならskipではなく失敗するテストとして扱う必要がある。

### 5. [高] 受入れテストのfetch/unpack失敗がskipになり、greenになり得る

weekly acceptance jobは、受入れテストで実行形状が変わることを理由に[`ci_check_skips.rb`](../tools/ci_check_skips.rb)を実行していない([`weekly.yml`](../.github/workflows/weekly.yml#L136))。

さらに、ネットワークやgemのunpack失敗をskipしている([`test_mkmf_conftest.rb`](../test/test_mkmf_conftest.rb#L221)、[`test_rmake_tools.rb`](../test/test_rmake_tools.rb#L315))。

そのため、受入れテストが外部要因で実質未実行でも、ジョブがgreenになる可能性がある。少なくともCIでは、ネットワーク障害とテスト対象の未実行を区別し、期待するskip理由・件数を検証する必要がある。

### 6. [中] R10とN1は通常のテストで合否判定されない

R10は対象コーパスの90%以上について、gem installと各gem自身のテストスイート合格を要求している([`DESIGN.md`](DESIGN.md#L85))。さらに、glibc/musl × x86_64/aarch64のコーパスCIをテスト戦略としている([`DESIGN.md`](DESIGN.md#L224))。

現状のCIでは、musl上で検証するgemは `io-wait`、`stringio`、`json` の3件に限定されている([`CI.md`](CI.md#L90))。通常の `rake test`にもコーパス検証は含まれない。

N1の20,000行/秒も、ベンチマーク結果をartifactに保存するだけで、CIの合否閾値はない([`weekly.yml`](../.github/workflows/weekly.yml#L164))。リリースチェックリストでは実測値13,854行/秒で未達だが許容と記録されているため、厳密な要件充足ではなく、明示的な許容判断として扱う必要がある。

## 確認できた良い点

- [`Rakefile`](../Rakefile#L5) は `test/**/test_*.rb` をまとめて実行する。
- Tier Aではツールチェーンの事前確認とskip数・run数のガードを行っている([`test.yml`](../.github/workflows/test.yml#L99)、[`ci_check_skips.rb`](../tools/ci_check_skips.rb#L175))。
- AArch64テストにはgccとの差分比較、AAPCS64 aggregate、variadic、ヘッダーABIのテストがある。
- AArch64の未対応例は`PENDING`に名前と理由を持たせて管理している([`test_examples_aarch64.rb`](../test/test_examples_aarch64.rb#L27))。

## 今後の検証条件

1. QEMU実行とnative実行が、ジョブ・ログ・文書上で区別されている。
2. native統合テストが対象runner上でskipされずに実行される。
3. `00130`・`00151`が、終了コードだけでなく具体的な値を検証する。
4. struct `va_arg`の暫定仕様とR10コーパスへの影響が記録されている。
5. strict acceptanceで受入れケースの未実行がgreenにならない。
6. R10のコーパス判定とN1の性能判定は、別途CIで確認可能な合否条件または許容条件として明文化する。

## 残課題の計画に対する批判的レビューと修正（2026-08-10）

`docs/TEST-PLAN.md`の残課題計画を、目的適合性、CI再現性、外部障害、skipによるgreen化、
R10分類の証拠強度の観点からレビューした。レビューで見つかった問題と反映した修正は
次のとおりである。

| 対象 | 批判的な指摘 | 反映した修正・残る確認 |
|---|---|---|
| live dispatch | YAMLをparseできても、`only=acceptance`で意図したjob集合だけが起動する保証にはならない。未commit差分や別SHAのrunを証拠にする危険もある。不正な`verify_step`+`only`の組み合わせは全jobskipになり得る | `acceptance`入力と`dispatch-contract`を追加し、fixtureとliveだけを対象にした。LIVE-1に入力別の期待job集合、LIVE-4に実runの`head_sha`・job集合照合を追加した。push/dispatch自体は未実施で、commit SHA固定が残る |
| live preflight | `bundle install`を先に行うと、依存導入の外部障害時にpreflight artifactが残らない | live preflightを`bundle install`より前へ移動し、Ruby/RubyGems/curl/rmake/rubycc、profile/network、結果パスを依存導入前に記録するよう修正した。workflow実runnerでの確認は残る |
| live failure | ネットワーク障害時にM2が未実行でも、suite終了コードだけを見てpassと解釈する余地がある | LIVE-4/5にpreflight、8 stable acceptance ID、2 M2 suite IDの一件ずつの要求を明記し、strict checkerが未実行・skip・inconclusiveを許容しないことを再確認する。外部障害は運用上分類してもproduct passにはしない |
| native context | `uname`、Ruby設定、Fiddleのrequire、loaderファイル存在だけでは、実際のRuby ELF、header compile、loader/libc利用の証拠が弱い | `tools/native_aarch64_preflight.rb`へRuby ELF `readelf`、Ruby dynamic dependency `ldd`、Fiddle loader probe、`ruby.h` compile probeを追加した。x86_64ではrequired profileがskipではなくstructured failになることを再実行した |
| native skip | full suiteの総skip閾値だけでは、既知skipへの置換や新しいCPU依存skipを見逃す可能性がある | ARM-4/5に承認済みskip理由・件数のbaseline比較を追加した。native smokeはrequired ID全件passを別判定する。AArch64実run後にbaselineを固定するまでは、full suiteのnative完全性を確定扱いしない |
| R10母集団 | `status: ok` 32件は機械ゲートの結果に過ぎず、`pg`の偽陽性やsqlite3 system-library profileを無条件に確定すると対象を誤る | R10-0を先に置き、DESIGN、`gems.rb`、census、profileの境界を確定してから件数を固定する。初期母集団32件は暫定値として扱う |
| R10証拠 | scannerだけではmacro、生成C、platform gateを判断できず、control/rubycc差分や未対応recipeも曖昧になる | 各行にsource/gem SHA、候補file:line、生成情報、build profile、分類、control/rubycc、extension load、suite、reviewer、(c)の次アクション/期限を必須化した。recipeがないgemを黙ってskipしない |
| R10未確定 | `要追加確認`が無期限の保留箱やpassへ変わる可能性がある | (c)は未解決理由・担当・期限を持ち、R10完了条件に件数集計を含めた。分類結果だけでは`data/verified_gems.json`を更新しない |
| architecture | x86_64でAArch64条件分岐を実行して、R10やstruct `va_arg`の結論へ流用する危険がある | R10-4/5にprofile分離を追加し、AArch64条件を含む実行はAArch64 runnerだけで行う。x86_64結果はAArch64の証拠にしない |

再確認結果:

```text
weekly.yml YAML parse: OK
weekly dispatch matrix (manual inputs): OK
acceptance manifest: required 15 / artifacts 4
test/test_weekly_workflow.rb: 3 runs, 21 assertions, 0 failures, 0 errors, 0 skips
test/test_ci_result.rb: 14 runs, 58 assertions, 0 failures, 0 errors, 0 skips
test/test_live_acceptance_preflight.rb: 2 runs, 11 assertions, 0 failures, 0 errors, 0 skips
test/test_native_aarch64_preflight.rb: 1 run, 8 assertions, 0 failures, 0 errors, 0 skips
native preflight on x86_64 with native profile: structured fail (not skip)
full regression: 3000 runs, 9689 assertions, 0 failures, 0 errors, 42 skips
ci_check_skips: OK (skips <= 55, runs >= 2500)
```

以上でローカルで完了できる計画・入口・preflight強化のレビューと修正は完了した。
ただし、GitHub Actionsのlive/native実runner実測とR10全対象gemの手動分類は、上記の
完了条件を満たすまで未完了であり、ローカル結果を代用しない。

## 実装継続分の批判的レビューと修正（2026-08-10）

### acceptance-only実runnerの失敗と修正

commit `8a371237d5813d63d2795fe7777f0a666b238031` の
[acceptance-only run 31340014349](https://github.com/nuna/rubycc/actions/runs/31340014349) は、
fixture jobとdispatch契約はpassし、liveのrequired resultも一見passしたが、通常suiteの
`TestRmakeGolden`が次の2件でfail/errorとなった。

```text
fixture has no Ruby header directory in test/fixtures/mkmf/json-2.21.1/parser/Makefile
fixture has no Ruby architecture header path
```

原因は、PC依存pathを除くためにMakefileへplaceholderを入れた一方、golden testが
実在pathのsuffixからRuby header directory/architectureを抽出する契約だったことである。
失敗をskipへ変換せず、fixtureを固定論理path（x86_64のprobe結果を含む）へ正規化し、
`test/test_rmake_tools.rb`で実行時の`RbConfig`を5 assignmentへ注入する修正を入れた。
さらにcollectorへ同じ正規化を移し、再生成でPC依存pathへ戻らないようにした。厳密な
assignment数・placeholder残存・期待値をテストし、golden 7 runs / 24 assertions、
rmake tools 12 runs / 36 assertionsを再実行した。

この修正のtrade-offは、Makefileの一次資料性を一部失う代わりにCI再現性を得る点である。
そのためrawの`mkmf.log`は保持し、fixtureの正規化対象とx86_64限定性を
`test/fixtures/mkmf/README.md`と`provenance.txt`へ明記した。AArch64の実ビルド証拠には
流用しない。GitHub Actions上の再実行は、この修正を含む最終commitで別途確認する。

### R10 profile境界・candidate artifactのレビュー

`pg`と`sqlite3`をrawの文字列判定だけで除外しない案について、次の失敗モードを確認した。

- profile名だけを追加すると未知profileがfail-openになる。
- `r10_extconf_args`を宣言しても、実際のverification recipeが同じ引数を使わなければ、
  censusの対象境界と`data/verified_gems.json`の証拠が分離する。
- scannerの空結果を「struct利用なし」と解釈すると、macro・生成コード・未選択platform
  の見逃しをpassへ変換する。

これを受け、既知profileのallowlist、pg native branchの`pg_config`/system-library marker、
sqlite3の`--enable-system-libraries`を要求し、未知・引数不足・marker不足をfail-closedに
した。`tools/r10_corpus_scan.rb`と`data/r10_corpus_scan.json`では39候補/34対象/5除外、
既存record 29件、scanner候補128件、34件すべてmanual classification pendingを記録する。
control/rubycc、extension load、upstream suiteはこのscanで実行したことにせず、既存recordも
再実行済みとはしない。`docs/R10-CORPUS-SCAN.md`はこの境界を明記する。

prosは対象数と根拠の追跡性が上がること、consはprofileとverification recipeの二重管理が
残り、手動分類・install/suite実測を別途完了する必要があることである。したがって現時点の
R10 pass rateは34分母/29記録/85.3%であり、90%達成とは記載しない。

## 継続実装分の批判的レビューと修正（2026-08-10）

native AArch64実測へ進む前に、ホスト依存のtarget漏れ、変換ABI、skip profileを再レビューした。

| 対象 | 批判的な指摘 | 修正・再確認 |
|---|---|---|
| host target propagation | `Compiler#compile`の既定値がx86_64のため、native AArch64で直接compileするテストがx86_64 objectを生成し得る。各テストが個別にCPU判定すると漏れとpath差が増える | `HostTarget`を追加し、ExecutionHelper、driver/c-suite、ELF/link/executable/PIC/deterministic、ABI harness、header/ruby smokeなどのhost compileとloader/libc判定を集中化した。x86専用ELF実行は明示guard、AArch64専用relocationケースはAArch64上でのみ実行する構造へ修正した |
| ordinary GCC link | DebianのPIE既定値が非PICのrubycc objectとAArch64で衝突し、通常のGCC比較がlink errorになった。全てのlink helperへ無条件にPIE方針を混ぜると、PIE検証を隠す | ordinary execution differentialだけに`-no-pie`を適用し、PIE policy専用テストは既存の明示的な`-pie`経路へ分離した。これはlink modeを確認するテストではなく、hosted codeの意味比較であることをhelperコメントへ記録した |
| float→integer conversion | 32-bit unsigned destinationをIRで8 bytesへ拡張するとAArch64のunsigned W-formを失う。さらに境界値`4294967295u`のfloat round-tripはCの未定義動作になり得る | IRはCの宛先幅 `[width, signed?]`を保持し、x86だけunsigned intでREX.W、AArch64はW/Xを直接選ぶよう修正した。範囲内へ丸められる値へテストを修正し、IR生成、x86 opcode、AArch64 W/X opcode、x86実行差分を個別に再検証した |
| native skip policy | named profileの広い上限や`expected_skips: null`は、既知reasonを別testへ付け替えた欠落を検知できない。AArch64上で必須の`TestElfWriter`ケースをskip許可に残すと目的に反する | AArch64 profileから同ケースを許可リストごと削除し、skipをunapprovedとしてfailさせる。x86 profileでは対象外skipとしてのみ許可する。x86/AArch64ともprofileをworkflowへ接続し、Ruby CPU/arch、Ruby ELF、gcc target、runner CPUをprofileと整合確認する。実AArch64ログ取得後にID単位の厳密baselineへ更新するまではprofileをprovisionalと明記する |
| libc path provenance | AArch64のnative pathとcross sysroot pathが同じ候補群にあると、名前だけでhost libcとみなす危険がある | `host_libc_path`はELF64 little-endianとhost machineを検証してから採用する。platform-literalの根拠注記も追加した。native runnerで実際に選ばれたpath/SONAMEはpreflight artifactで別途確認する |

今回のローカル批判レビューで見つかった問題はskip化せず、テストまたはcheckerの失敗として
修正した。GitHub Actionsのacceptance実測はrun 31345720437、native AArch64 full
suiteはrun 31345396123で完了し、実測前に確定扱いしなかったprofileをartifactに基づき
固定した。R10 34対象gemの手動分類は未完了のままである。

## 実runner最終結果に対する批判的レビュー（2026-08-10）

### 実測結果

commit `7d903c47334844b3a5bc51b5290cef3e669fdef8` について、次のrunを取得し、CI上の
checkerだけでなくartifactのログをローカルでもstrict modeで再検査した。

| profile / run | 結果 |
|---|---|
| [native AArch64 weekly 31345396123](https://github.com/nuna/rubycc/actions/runs/31345396123) | Ruby 3.3/4.0とも `3059 / 9011 / 0 / 0 / 245`。native smoke、preflight、full suite、strict baselineが全件pass |
| [native x86_64 Tier A 31345396034](https://github.com/nuna/rubycc/actions/runs/31345396034) | Ruby 3.3/4.0とも `3059 / 10079 / 0 / 0 / 42`。strict baselineが全件pass |
| [acceptance-only 31345720437](https://github.com/nuna/rubycc/actions/runs/31345720437) | fixture 2 ID、live required ID、M2 json/msgpack、dispatch契約がpass。suiteは `3059 / 12610 / 0 / 0 / 33`。x86_64上のAArch64 native smoke 2 IDは対象CPU外の承認済みskip |

AArch64のcontext artifactでは、`uname_machine=aarch64`、Ruby `host_cpu=aarch64`、
`ruby_arch=aarch64-linux`、Ruby ELF Machine=AArch64、`gcc_machine=aarch64-linux-gnu`、
AArch64 loader/libc、Fiddle probe、Ruby header probeを確認した。従って、今回のnative
結果をx86_64上のQEMU実行で代用していない。x86_64側ではAArch64専用テストが理由付きで
skipされ、AArch64 runner側ではそれらが実行されることもログで確認した。

acceptance artifactでは、json/msgpackのgemとsource tarballの4件について、manifestのURL、
expected/actual SHA-256、bytes、cache状態を確認した。live結果の未実行・inconclusiveはなく、
M2 jsonは596 tests / 3390 assertions、msgpackは455 examples / 0 failures（1 pending）だった。
ネットワーク障害やchecksum不一致をskipへ変換した結果ではないことを、preflight・結果ID・
artifact checkerの三者で確認した。

### 批判的レビューと修正確認

| 観点 | 残り得る弱点 | 判定・対応 |
|---|---|---|
| DESIGN仕様・制限 | skip理由を「実装未完了」とだけ書くと、仕様上の制限と単なる未実装を混同する | `alloca`/bit-scanは`docs/IR.md` §6.5のターゲット別実装範囲へ合わせ、`DESIGN.md` R7から参照する。struct `va_arg`は既存のout-of-scope判断を維持し、今回のnative実測を対応済みとは解釈しない |
| CI再現性 | runner labelやOSだけを信頼すると、誤ったRuby/gccやcross sysrootでgreenになり得る | preflightでCPU、Ruby設定/ELF、gcc target、loader/libc、Fiddle、headersを相互確認し、context artifactを保存した。AArch64実測で全項目passを確認した |
| CPU依存テスト | x86_64上でAArch64 native証拠を作る、またはAArch64上でx86専用検査を無条件実行する危険 | host targetを共通化し、x86専用検査はAArch64でskip、AArch64専用ケースはnative runnerで実行する。AArch64 full suiteでは無条件skipの追加を確認しなかった |
| skipによるgreen化 | 広いallowlistと総数上限だけでは、既知理由を別testへ付け替えた欠落を見逃す | profileを`provisional=false`、実測件数、期限、owner、test+理由のallowlist、SHA-256 fingerprintで固定した。245/42の件数とfingerprintがRuby 3.3/4.0で一致し、strict checkerも再実行passした |
| 実装の副作用 | ordinary GCC linkへ`-no-pie`を一律適用すると、PIE検証を隠す可能性がある | ordinary execution differentialだけに適用し、PIE専用テストは明示`-pie`経路へ分離した。AArch64のdirect compiler/link pathも`-fno-pie`/`-no-pie`を統一した |

このレビューの結論は、実runner上のnative/x86 CI経路とskip監視は完了とするが、
「すべてのAArch64制限が解消した」「R10の90%要件を満たした」とはしないことである。
R10全34対象gemの手動分類、macro/生成コードの実使用確認、control/rubycc、extension load、
upstream suiteはscanner artifactの存在だけでは完了にならず、明示的な残課題として残す。
不要ファイル`a.out`は存在しない。

## R10手動分類の独立批判レビューと修正（2026-08-10）

R10手動分類の初稿について、候補の実態、zero findingの扱い、実ビルド経路の漏れを分けて3視点でレビューした。目的は細かな表記ではなく、DESIGN.mdの制限を確認するための証拠として十分か、未実行をgreenへ変換する経路がないかを確認することである。

### 指摘と反映

| 観点 | 批判的な指摘 | 反映した修正 |
|---|---|---|
| zero finding | 29件を一律`no_candidate`とすると、scanner対象外のroot `src`、generated source、textual include、外部ABIを不在証明に変換する | machine state `no_candidate`とsource/profile補助分類を分離。a0=`scoped_no_candidate` 20件、b0=`non_target_variadic_wrapper` 1件、c=`needs_more_evidence` 8件とし、cにはowner/action/dueを必須化 |
| selected path | ext配下の全Cファイルをcompiler選択単位のように記録していた。`http_parser.rb`のvendor test、`nkf`のincluded Cが実ビルド対象と誤読される | `translation_units`、`non_selected_sources`、`build_entrypoints`、`preprocessor_constraints`を分離。http_parserの生成`ryah_http_parser.c`、nkfの`PERL_XS` inactive block、nio4rのlibev textual includeを明記 |
| generated source | dateの`date_parse.c`を生成Cと誤記し、gperfの`zonetab.h`、puma/http parserの生成物 provenanceが曖昧 | `generated_source`をstatus/files/commandsへ分解。dateはgperf generated header、pumaはchecked-in Ragel output、http_parserはextconf生成未再現、rbs/prismは生成・template未再実行として記録 |
| scanner外の variadic | google-protobuf、json、pg、openssl等にはscanner外またはzero結果でも通常のva_list wrapperがある。これはstruct `va_arg`の実使用とは別だが、zero=コードなしではない | source evidenceへwrapperの存在とstruct操作でない根拠を記録。google-protobuf/oj/date/http_parser/nkfは候補単位で128件を一対一にfalse positive分類 |
| profile/architecture | pgのcross-build、sqlite3 bundled path、system OpenSSL/libffi/libyaml、prism/rbs root sourceをdefault profileの結果へ混ぜる危険。x86の結果をAArch64へ流用できない | profile scopeを台帳へ固定。8件をcとして実ビルド・前処理・外部ABI確認待ちにし、AArch64を含む確認は該当runnerだけで行う計画を残した |

### 採用判断とpros/cons

一律`no_candidate`を維持する案は、台帳が小さくなる利点がある一方、scannerの対象範囲と実際のbuild pathの差を隠し、R10の90%やstruct `va_arg`非対応の根拠を過大評価する。zero findingをすべてcへする案はfalse passには強いが、明確に限定できる20件まで保留になり、調査結果の有用性を下げる。

採用した分離案は、20件を「宣言したprofileのsource snapshotに限ったa0」、1件を「非対象のva_list wrapperを確認したb0」、8件を「追加証拠が必要なc」として扱う。利点は証拠の境界と残課題が定量化されること、欠点は補助状態と実測verificationを二重管理すること、source inventoryと生成規則の保守費用が増えることである。DESIGNの「struct/unionを`...`へ渡すこと、struct/union `va_arg`を診断対象とする」という制限を誤って解除しないことを優先し、このトレードオフを採用した。

### 再確認

```text
ruby -Itest test/test_r10_manual_classification.rb
6 runs, 359 assertions, 0 failures, 0 errors, 0 skips
ruby tools/r10_manual_classification.rb --validate
r10_manual_classification: OK (34 targets)
```

このOKは、34対象、scanner finding 128件、source evidence、zero assessment、provenance、未実行verificationの形式整合性を意味する。control/rubycc、実Makefile/preprocessor、extension load、upstream suite、CPU固有経路はまだ`not_run`であり、`data/verified_gems.json`やR10 90%達成率は更新していない。したがって、手動分類のsource工程は進捗したが、R10全体の受入れ完了とは判定しない。

## R10-M4 実行検証の批判的レビュー（2026-08-10）

### 実測結果

| batch | 結果 | レビュー判定 |
|---|---|---|
| M4A simple/native | 10件中9件はcontrol/rubyccともsuite pass。`nkf`は両方8 tests / 44 assertions / 1 error、sanityは両方pass | build/loadはpass、suiteはcompiler比較inconclusive。skipへ変換しない |
| M4B standard | 11/11がcontrol/rubyccともbuild・sanity・suite pass | `etc` 2 omissions、`io-wait` 1 omissionをartifactへ残した。suiteの実行結果を捏造していない |
| RBS追加recipe | control/rubyccともbuild・sanity load pass。suiteは707 tests / 5,400 assertions / 22 failures / 7 errors / 10 omissionsで一致 | suiteはinconclusive。拡張load成功をsuite passへ昇格しない |
| M4C generated/external ABI | 実測完了（pass/fail/inconclusiveを分離） | prism/fiddle/google-protobuf/yajl-rubyは両経路pass。bootsnapは両経路ともsummary欠落、pumaはcontrol timeout・rubycc summary欠落のためstrict validatorでinconclusiveへ訂正。openssl/nio4r/ojは比較失敗、mysql2はDocker停止でinconclusive。未実行をskipへ変換していない |
| M4D sqlite3/pg profiles | 実測試行、外部依存inconclusive | system-library/native-sourceの両control/rubyccがextconfで停止。sqlite3.h/libsqlite3、pg_config/pkg-config/libpq-fe.h不足を記録し、load/suiteはnot_run。 |

詳細は[`data/r10_verification_m4a.json`](../data/r10_verification_m4a.json)、
[`data/r10_verification_m4b.json`](../data/r10_verification_m4b.json)、
[`data/r10_verification_m4c.json`](../data/r10_verification_m4c.json)、
[`data/r10_verification_rbs.json`](../data/r10_verification_rbs.json)に保存した。
各artifactはx86_64 / Ruby 3.4.5のローカル実測であり、AArch64証拠を含まない。
M4Dのsqlite3/pg外部profile試行は[`data/r10_verification_m4d.json`](../data/r10_verification_m4d.json)
に分離し、extconf停止をsuite skipとして扱っていない。

### 批判レビューと修正

| 観点 | 指摘 | 対応 |
|---|---|---|
| compiler比較 | rubycc側だけを実行すると、Ruby/test dependency、OS、upstream sourceの失敗をrubycc差分と誤認し得る | 同じrecipe・scratch構成でcontrol/rubyccを分離実行し、controlはrubycc痕跡なし、rubyccは`gem_make.out`/Makefile/`mkmf.log`のtraceを要求した |
| extension load | suiteがpure-Ruby fallbackでpassしても、native extension検証にならない | sanityで注入した`.so`が`$LOADED_FEATURES`へ現れることを必須化。RBS/nkfはload passでもsuite inconclusiveを維持した |
| skip/omission | upstreamのomission/pendingを無記録でpassへまとめると、未実行を隠せる | summaryのother countsと理由をartifactへ記録。今回の明示的suite error/failureはfailとして残し、skipへ置換しなかった |
| 外部障害 | 初回M4Bは既存gem cacheのEROFSで停止した | scratch cacheへ切り替えて再実行。初回失敗を成功runへ混ぜず、再実行だけを証拠とした |
| source取得 | yajl-rubyのGitHub 1.4.3 tagが存在せず、誤ったtagへ差し替えるとversion違いを測定する | exact 1.4.3 `.gem`のdata archiveに含まれる14 RSpec filesをsource/test treeとして展開するrecipeを追加し、control/rubycc 416 examples passを確認した |
| 外部suite | mysql2のMariaDB Docker停止、pumaのcontrol timeout、opensslのrubycc summary欠落を環境都合としてskipできる | suite未完了をfail/inconclusiveとして保持し、Docker起動・timeout原因切り分けを残課題化した |
| PC/CI依存 | `/home`や`/tmp`の絶対pathをartifactへ入れると別runnerで追跡不能になる | `--json`出力と保存artifactのwork path/log tailを論理placeholderへ正規化し、portable検査を追加した |
| architecture | x86_64で通った結果をAArch64へ拡張し得る | artifactへ`architecture=x86_64`、`aarch64_evidence=false`を明記。AArch64固有検証はnative runnerで別途行う |

control/rubycc二重実行のprosは環境由来とcompiler由来の失敗を分離できること、consは実行時間・
依存取得・外部サービス条件が倍増することである。今回の目的は「greenにする」ことではなく
DESIGNの制限を実使用経路で確認することなので、コストを受け入れ、同一失敗をinconclusive
として残す判断が妥当である。`data/verified_gems.json`はsuite passが確定した対象だけを
更新する設計のため、今回のM4証跡を自動でverified recordへ昇格させていない。

再確認:

```text
ruby -Itest test/test_verify_gem_tests_cli.rb
3 runs, 30 assertions, 0 failures, 0 errors, 0 skips
ruby -Itest test/test_r10_manual_classification.rb
6 runs, 359 assertions, 0 failures, 0 errors, 0 skips
ruby tools/r10_manual_classification.rb --validate
r10_manual_classification: OK (34 targets)
```

このレビュー時点の残課題は、sqlite3/pg profileの依存を備えた再実測、8件のc分類に対する
前処理・外部ABI証拠、全34件の完了性レビュー、AArch64該当経路である。これらをsource scanや
今回のx86_64 artifactだけで完了扱いしない。

## R10-M4 証跡validatorの独立批判レビューと修正（2026-08-10）

独立レビューでは、回帰テストのgreenとR10受入れ証跡の正しさを分けて確認した。主な指摘は、
M4Cのbootsnap/pumaでsummaryがnullなのに結果がpassとして保存されていたこと、
台帳validatorがartifactのgem/version/mode/resultを再導出していなかったこと、suiteの総数や
failure/error以外の状態を機械的に検査していなかったこと、source/gem SHA・recipe・実行環境が
artifactへ結び付いていなかったことである。

次の修正を反映した。

- tools/verify_gem_tests.rbのJSON証跡へbuild_state、extension_load_state、suite_state、
  source/gem SHA-256、recipe fingerprint、実行環境、test dependency version、Rubycc revision、
  dirty-stateを追加した。
- summaryが存在し、実行テスト数が1以上で、failure/error/other countsを持つ場合だけsuite
  passを出力する。summary欠落・0件はunparsable/inconclusiveであり、skipへ変換しない。
- tools/r10_manual_classification.rb --validateがartifactをrepository-relative pathから読み、
  schema、対象名/version/mode、machine scanのgem SHA、build/load/suite比較、recipe、revision、
  実行環境を突合する。ledgerの状態だけを変更しても検証を通らない。
- M4C artifactを正規化し、bootsnapはinconclusive、pumaもcontrol/rubycc双方のsummary欠落を
  inconclusiveとして記録した。puma/bootsnapをsuite passへ数えない。

厳格化のprosは、summary欠落・artifact差し替え・台帳だけの状態改変による偽のgreenを検出
できること、sourceと実行環境を後から追跡できることである。consは、環境障害や上流suiteの
出力形式差が増分のinconclusiveになり、再実測やparser更新が必要になること、artifact生成時
のdirty worktreeも明示的に記録しなければならないことである。R10受入れの目的を優先し、
曖昧なpassを増やさない方を採用した。

再確認:

    ruby -Itest test/test_verify_gem_tests_cli.rb
    4 runs, 36 assertions, 0 failures, 0 errors, 0 skips
    ruby -Itest test/test_r10_manual_classification.rb
    9 runs, 382 assertions, 0 failures, 0 errors, 0 skips
    ruby tools/r10_manual_classification.rb --validate
    r10_manual_classification: OK (34 targets)

この修正後も、artifactはglibc/x86_64・Ruby 3.4.5の実測であり、AArch64/muslの証拠ではない。
R10の90%達成、8件のc分類、sqlite3/pgの開発依存を備えた再実測は未完了である。

## R10 strict validator再レビューと追加修正（2026-08-10）

修正後の独立再レビューで、初回修正にも残っていたfail-open経路を確認した。測定済み状態なのにartifactが欠落している場合、run_idだけで通過できたこと、artifact内の明示的なbuild_state / suite_stateをsummaryやbuild evidenceより先に信頼していたこと、summary.lineを現在のverify toolで再現していなかったことが重大な問題だった。

以下を追加修正した。

- control、rubycc、extension_load、upstream_suiteの pass / fail / inconclusive は、対応するrepository-relative artifactと対象resultの存在を必須化した。run_idだけでは測定証拠にならない。recorded_not_rerunは測定済み状態として扱わず、artifactを指す場合は拒否する。
- build_state、extension_load_state、suite_stateをresultのsanity、build evidence、status、summaryから再導出し、artifactの明示値と一致することを検証する。欠落evidenceでbuild_state: pass、summaryなしでsuite_state: passという改ざん・記録ミスを通さない。
- validatorがverify_gem_tests.rbを読み込み、recipe fingerprintだけでなく現在のRECIPESからrecipe全体を再生成して突合する。source kind / URL、gem URL / SHA、source SHA形式、execution context、rubycc mode / revision / dirty-stateも検証する。
- summary.lineをverify toolのparse_summaryへ再入力し、tests / assertions / failures / errors / other countsが一致することを必須化した。M4Cの手作業artifactで、592, testsのようにtoolが受理しない表記を正規の592 testsへ改め、omissions / pendingもlineへ戻した。
- 欠落artifact、evidenceなしのpass、toolで再解析できないsummaryを検出する回帰テストを追加した。

厳格化のprosは、台帳だけの書き換え、summary欠落、run_idだけの受入れ、古いrecipeによる結果の流用を機械的に拒否できる点である。consは、validatorがrecipe定義とparserの変更に追随する必要があり、過去に手動整形したartifactが再生成不能ならinconclusiveになる点である。今回の目的はCIで偶然greenになることではなく、DESIGNの制限を検証経路と証跡の両方で確認することなので、保守コストを受け入れてfalse passを優先的に排除する判断とした。

再確認結果:

    ruby -Itest test/test_r10_manual_classification.rb
    12 runs, 386 assertions, 0 failures, 0 errors, 0 skips
    ruby -Itest test/test_verify_gem_tests_cli.rb
    4 runs, 36 assertions, 0 failures, 0 errors, 0 skips
    ruby tools/r10_manual_classification.rb --validate
    r10_manual_classification: OK (34 targets)

この修正後もartifactはglibc/x86_64・Ruby 3.4.5のローカル実測であり、GitHub Actions runnerやAArch64/muslの証拠ではない。R10 90%達成、8件のc分類、sqlite3/pgの開発依存を備えた再実測、全34件の完了性レビューは引き続き残課題である。
