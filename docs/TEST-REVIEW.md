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

残る外部確認は、GitHub Actions live jobと`ubuntu-24.04-arm` native jobの実runner実測だけである。これらはこの作業でpush/dispatchしていないため、ローカル実測を代用して完了とは扱わない。R10全対象gemのmacro展開・生成コードを含む手動分類も、ユーザー指定どおり未着手である。

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
修正した。残る外部確認は、同じcommitを使ったGitHub Actionsのacceptance実測とnative
AArch64 full suiteであり、実測前にprofileの件数を確定扱いしない。R10 34対象gemの
手動分類も未完了のままである。

## 実runner最終結果に対する批判的レビュー（2026-08-10）

### 実測結果

commit `7d903c47334844b3a5bc51b5290cef3e669fdef8` について、次のrunを取得し、CI上の
checkerだけでなくartifactのログをローカルでもstrict modeで再検査した。

| profile / run | 結果 |
|---|---|
| [native AArch64 weekly 31345396123](https://github.com/nuna/rubycc/actions/runs/31345396123) | Ruby 3.3/4.0とも `3059 / 9011 / 0 / 0 / 245`。native smoke、preflight、full suite、strict baselineが全件pass |
| [native x86_64 Tier A 31345396034](https://github.com/nuna/rubycc/actions/runs/31345396034) | Ruby 3.3/4.0とも `3059 / 10079 / 0 / 0 / 42`。strict baselineが全件pass |

AArch64のcontext artifactでは、`uname_machine=aarch64`、Ruby `host_cpu=aarch64`、
`ruby_arch=aarch64-linux`、Ruby ELF Machine=AArch64、`gcc_machine=aarch64-linux-gnu`、
AArch64 loader/libc、Fiddle probe、Ruby header probeを確認した。従って、今回のnative
結果をx86_64上のQEMU実行で代用していない。x86_64側ではAArch64専用テストが理由付きで
skipされ、AArch64 runner側ではそれらが実行されることもログで確認した。

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
