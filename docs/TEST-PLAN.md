# テスト・CI改善計画

策定日: 2026-08-09

## 位置づけ

この計画は、[`TEST-REVIEW.md`](TEST-REVIEW.md)で採用した5方針を、tools・テスト・CI・仕様文書へ段階的に反映するための実装計画である。

細部の共通化を先行せず、まず「未実行なのにgreenになる」状態を減らし、実測で必要性が確認された部分だけを抽象化する。

## 対象と非対象

対象:

1. AArch64のQEMU target executionとnative integrationの分離
2. x86_64専用テストを維持しつつ、共通ハーネスとホスト依存部分を整理
3. c-testsuite `00130`・`00151`のオラクル強化とケース単位のskip解除
4. struct `va_arg`の暫定仕様、R10コーパス調査、段階実装判断
5. strict acceptance、決定的fixture、外部障害の分類

非対象:

- 全テストを全CPU・全libc・全実行方式の組み合わせで実行すること
- x86_64固有のELF・relocationテストを無理にAArch64と共通化すること
- struct `va_arg`の実装を利用実態の調査前に開始すること
- 通常の`rake test`へネットワーク依存を持ち込むこと

## 設計原則

### 同じファイルではなく、同じ保証範囲を確認する

テストを次の5分類で扱う。

| 分類 | 実行方針 |
|---|---|
| 共通意味論 | parser、IR、診断、決定性などを全環境で実行 |
| ターゲット構造 | ELF machine、relocation、命令語を対象targetを明示して実行 |
| QEMU target execution | x86_64 hostからAArch64コードをQEMUで実行するPR用cross検証 |
| native integration | Ruby、Fiddle、loader、host libcを対応native runnerで実行 |
| 外部依存acceptance | network、gem、上流ソースの状態を明示的に分類 |

テストファイル数やrun数を無理に一致させず、各targetで論理的な保証範囲が満たされているかを判定する。

### `pass`・`fail`・`skipped`・`inconclusive`を分ける

- `pass`: 必須テストが実行され、期待結果を満たした
- `fail`: 製品またはテスト自体の失敗
- `skipped`: 開発者向けの非対象・任意テスト
- `inconclusive`: 外部サービス・CI基盤などにより受入れ判定不能

`inconclusive`を製品のgreenとして扱わない。GitHub Actions上でのrequired/non-required jobの扱いは、製品テストと外部依存テストを混同しない形で設定する。

## 実施フェーズ

### タスク分解のルール

各タスクは、目的・成果物・完了条件が一つに対応する意味単位とする。実装だけでなく、観測結果の記録、テスト、CI設定、仕様文書の更新までを同じタスクの完了条件に含める。`0A-1`や`2B-3`のようなIDはタスクIDであり、コミットやPRの分割単位の候補でもある。

依存関係は次の通りである。

```text
0A ─┬─> 0B ─> 2B ─> 2C
    ├─> 1
    ├─> 3
    └─> 4A/4B ─> 4C（需要がある場合）
1・2・3・4 ─> 5 ─> 最終文書整合
```

### Phase 0A: 契約と現状測定

新しいRake taskや大規模なprofile機構を作る前に、各CI経路の保証範囲を固定する。

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **0A-1 実行コンテキスト定義** | `host`、`target`、`runner`、`libc`、`network`の意味を固定する | x86_64 / AArch64、native / QEMU、glibc / musl、network-free / live / fixtureの分類表を作る | すべての対象CI経路が分類表のいずれかに一意に分類される |
| **0A-2 現行経路の棚卸し** | 現在何が実行・skipされているかを測定する | Tier A、AArch64 cross、native AArch64、acceptanceのrun/skip、必要ツール、失敗条件を記録する | 各経路についてrun数・skip数・skip理由・不足ツールが再現可能な形で残る |
| **0A-3 安定IDとmanifest設計** | ログやMinitest名に依存しない判定単位を決める | `c-suite-00130`、`mkmf-msgpack-extconf`、`rmake-json-parser`のようなIDと、必須条件・所有者・期限の形式を定義する | 必須acceptance候補に重複しない安定IDが付いている |
| **0A-4 受入れ契約のレビュー** | `pass` / `fail` / `skipped` / `inconclusive`の扱いを決める | required/non-required job、許可skip、未実行、外部障害の判定規則を文書化する | 後続checkerの入力と終了コードを実装前にレビューできる |

この段階で作る成果物は、現状一覧、安定ID一覧、profileごとの必要ツール・必須条件、受入れ契約である。テストIDはMinitestのメソッド名に依存させない。

### Phase 0B: 最小の判定基盤

目的は、受入れテストの未実行を検出することに限定する。Rake全体のprofile taskや複雑なskip allowlistはこの段階では追加しない。

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **0B-1 結果スキーマ実装** | テスト結果を機械判定できる形式にする | 新規 `tools/ci_result.rb`にID、状態、理由、profile、実行時刻などの共通形式を定義する | `pass` / `fail` / `skipped` / `inconclusive`を構造化して表現できる |
| **0B-2 結果出力の接続** | acceptance側が構造化結果を出せるようにする | 受入れテストから結果を出力し、ログ解析を補助用途に限定する | 必須IDごとに「実行されたか」と結果が保存される |
| **0B-3 acceptance checker実装** | 必須IDとstrict policyを判定する | `tools/ci_check_acceptance.rb`と`config/ci/acceptance_manifest.json`を追加する | 必須IDの未実行、strict時のskip、`inconclusive`を期待通りに終了コードへ反映できる |
| **0B-4 既存checker互換性確認** | 既存Tier Aの監視を壊さない | `tools/ci_check_skips.rb`のCLIと総run/skip判定を維持し、共通形式を再利用する | 既存CIの判定結果が変わらず、checker間でログ解析・policy実装が重複しない |

### Phase 1: 低コストで再現性の高い問題を解消する

#### 1-A. `00130`・`00151`のオラクル強化

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **1A-1 回帰fixture設計** | 何を観測すれば配列意味論を保証できるか決める | project-owned fixture、stdout形式、期待値、mutation対象を定義する | `00130`と`00151`それぞれに具体的な観測値と失敗条件がある |
| **1A-2 `00130`の強化** | 多次元配列の実体を検証する | 配列要素、行ポインタ、要素ポインタの具体値をstdoutで検証する | initializerやpointer計算を壊した実装が終了コードだけで通らない |
| **1A-3 `00151`の強化** | designated initializerを検証する | 各値、別要素、配列サイズを出力し、initializerを無視してゼロにする変異を追加する | 変異が確実に失敗し、期待値が値の一致として確認できる |
| **1A-4 GCCとの比較** | oracleの妥当性を確認する | x86_64とAArch64/QEMUでGCC版・Rubycc版のstdoutと終了コードを比較する | 両targetで結果が一致し、native AArch64を意味論テストの必須条件にしない理由が記録される |
| **1A-5 skipのケース単位解除** | 検証できたケースだけを実行対象へ戻す | `TestCSuite::SKIP`の共有理由を分解し、対象ケースのskipを削除する | 強化されたoracleと元のc-testsuiteケースの保証範囲が対応し、fixtureだけpassして元ケースがskipのままにならない |

upstreamのc-testsuiteファイルは根拠なく変更しない。元ケースのoracleがなお弱い場合は、skip解除を保留して理由をケース単位で残す。

#### 1-B. rmake goldenの絶対path依存解消

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **1B-1 差分原因の分離** | 絶対pathがgolden差分のどこに現れるか特定する | 収集元PCとCIのgoldenを比較し、環境値と意味ある出力を分離する | path以外の差分がないこと、または別問題であることが確認できる |
| **1B-2 正規化方式の実装** | PC固有値を比較可能な表現へ変換する | 論理パスへの正規化、またはfixture内での明示的な環境値置換を実装する | 実行時に無条件再生成せず、同じ入力から同じ比較結果になる |
| **1B-3 CI再現性確認** | ローカルとCIの比較条件を揃える | golden更新手順と検証ジョブを整備する | PC固有path不足によるskipがなく、ローカルとCIで同じ判定になる |

### Phase 2: strict acceptanceと決定的fixture

#### 2-A. fetch/unpackの失敗分類を共通化

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **2A-1 失敗分類契約** | retry対象と製品失敗を分ける | timeout・429・5xx、404・version消失、checksum不一致、unpack・ディスク・RubyGems、compile/link/gem testの分類表を作る | 各失敗が一つの状態と終了方針に対応する |
| **2A-2 fetch helper実装** | retry・checksum・unpack結果を統一する | `test/support/acceptance_fetch_helper.rb`を追加し、限定回数の指数バックオフと失敗分類を実装する | 同じ入力・失敗条件でmkmfとrmakeが同じ状態を返す |
| **2A-3 利用箇所への接続** | 個別テストのskip変換をなくす | `test_mkmf_conftest.rb`、`test_rmake_tools.rb`などのfetch処理をhelperへ移す | strict時にfetch/unpack失敗がskipへ変換されない |
| **2A-4 分類単体テスト** | ネットワーク状態を再現可能にする | timeout、429、404、checksum不一致、破損archive、compile失敗のfixtureを用意する | 外部ネットワークなしで分類と終了状態を検証できる |

通常の`rake test`はnetwork-freeのままskipを許可する。ただしstrict CIでは受入れ不能をskipに変換しない。

#### 2-B. 必須fixture job

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **2B-1 fixtureの作成** | 外部ネットワークなしの受入れ対象を固定する | mkmf/rmakeの入力、archive、checksum、期待結果をfixture化する | fixture jobがネットワークなしで実行できる |
| **2B-2 manifestと結果の接続** | 必須対象を宣言し、実行を確認する | manifestに必須IDを登録し、構造化結果を`ci_check_acceptance.rb`へ渡す | 必須IDの未実行を検出できる |
| **2B-3 required job化** | fixture受入れをPRの必須判定にする | GitHub Actionsにnetwork-free required jobを追加する | 必須IDが全件実行され、結果がartifactまたはログから追跡できる |
| **2B-4 no-network検証** | PCや外部サービスに依存しないことを確認する | ネットワークを遮断した環境でjobを実行する | ネットワークなしで安定してpassし、外部障害を`pass`と誤認しない |

#### 2-C. live acceptanceと外部障害の可視化

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **2C-1 strict live job** | 実際のgem取得をfixtureと分離する | `RMAKE_ACCEPTANCE=1`とstrictフラグをworkflowで明示し、`tools/m2_acceptance.rb`のfail-fast方針を維持する | live経路でfetch/unpack skipが発生しない |
| **2C-2 受入れartifact** | 失敗を後から再判定可能にする | URL、version、checksum、cache hit/miss、失敗分類、構造化結果を保存する | 製品失敗と外部障害をartifactから区別できる |
| **2C-3 inconclusive policy** | 外部障害を製品greenに混ぜない | 外部障害を`inconclusive`としてrequired判定から分離し、通知ルールを設定する | 外部障害で製品の成功が偽装されず、jobの状態と通知の意味が一致する |
| **2C-4 観測とcache判断** | cache導入の必要性を測定する | まずfixture、次に観測・checksum付きartifactを導入し、外部障害率とcache hit/missを測定する | 測定結果に基づきcacheを導入・見送りできる。fixtureとcacheを同時導入しない |

### Phase 3: native AArch64の限定的な統合確認

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **3-1 native前提条件の確認** | native runnerで何が保証されるか確認する | AArch64 Ruby、loader、libc、Fiddle、Ruby header、必要ツールのpreflightを定義する | 必須profileで不足ツールがskipではなくfailになり、任意の開発経路では従来のskip方針を維持できる |
| **3-2 native smoke選定** | QEMUでは代替できないテストを選ぶ | AArch64版Ruby上のRubycc、native loader/libc、Fiddle shared object、代表的ABI・aggregate・variadic、Ruby header/libc統合を登録する | 各テストがnative固有の保証と一対一に対応する |
| **3-3 workflow job実装** | native smokeを実際のAArch64 runnerで実行する | 既存native AArch64 workflowへ限定profileを追加する | native runner上で対象テストがskipされず、結果が識別可能な形で保存される |
| **3-4 QEMU/native表示分離** | target code実行とhost integrationを混同しない | `aarch64_execution_helper.rb`とworkflowの表示・結果にrunner種別を出す | QEMU target executionとnative integrationがジョブ・ログ上で区別される |
| **3-5 効果とコストの検証** | 重複実行の費用対効果を確認する | native smokeで検出した問題、実行時間、runner費用を測定する | 全suite重複による時間増加を避け、定めた上限内でnative固有の問題を検出できる |

QEMU用の共通コンパイル・比較処理は維持し、native実行条件だけをrunner strategyとして差し替える。native AArch64で言語意味論テスト全体を再実行することは、このPhaseの対象外である。

### Phase 4: struct `va_arg`の仕様決定と利用調査

現状はstruct variadicを診断拒否し、[`DESIGN.md`](DESIGN.md#L80)はABI完全互換と記載している。この矛盾を解消してから、利用実態に応じて実装の要否を判断する。

#### 4-A. 暫定仕様と既存動作の固定

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **4A-1 仕様差分の明文化** | R9、R10、診断実装の差分を列挙する | structを`...`へ渡す場合、`va_arg(ap, struct T)`、固定引数struct ABIを別々に整理する | どの構文が対応・非対応かが文書とテストで一致する |
| **4A-2 暫定診断テスト** | 非対応をsilent mismatchにしない | struct callerとstruct `va_arg`を診断拒否し、スカラー・ポインタ・doubleのvariadicは現行対応を維持する | 非対応入力がskipや誤実行ではなく、安定した診断になる |
| **4A-3 文書の暫定整合** | 誤った完全対応宣言を残さない | 必要に応じてDESIGN、README、ROADMAP、C11カバレッジの暫定表現を更新する | 実装済み範囲と仕様表現の矛盾がない |

#### 4-B. R10コーパスの利用実態調査

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **4B-1 scanner実装** | 候補箇所を機械的に集める | `tools/scan_corpus_variadics.rb`で`va_arg`、`va_copy`、struct caller、wrapper、関数ポインタ経由の候補を収集する | ファイル・行・検出種別を再現可能な形式で出力できる |
| **4B-2 R10 corpus走査** | 対象範囲で候補を漏れなく列挙する | R10対象gem、macro、生成コードを走査する | scan結果がartifactまたは調査記録として残る |
| **4B-3 手動分類** | ヒューリスティック結果を実際の利用と区別する | マクロ展開・生成コードを確認し、候補を「実使用」「誤検出」「要追加確認」に分類する | scannerを不在証明や合格判定に使わず、判断可能な候補表ができる |
| **4B-4 実装判断記録** | 需要の有無を決める | 影響gem、API形態、target/ABI、回避策、優先度を記録する | 実装する、暫定非対応を維持する、仕様を限定する、のいずれかを根拠付きで決められる |

#### 4-C. 需要がある場合の段階実装

4-Bで実需要が確認された場合だけ実施する。需要がない場合は、4-Aの暫定仕様を正式な非対応範囲として整合させ、4-Cは実施しない。

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **4C-1 ABI実装範囲の設計** | 一度に全ABIを実装しない | 小さいINTEGER struct、レジスタ枯渇、stack boundary、AAPCS64 HFA、SysV INTEGER/SSE混在、大きいstruct・alignment、`va_copy`の順序を定義する | 各段階の入力、oracle、未対応境界が明記される |
| **4C-2 最小ケース実装** | 最小のstruct `va_arg`から対応する | 小さいINTEGER structを実装し、境界条件を追加する | GCCとRubyccの期待値が一致し、未対応ケースを誤って受理しない |
| **4C-3 ABI境界の拡張** | targetごとの引数分類を検証する | HFA、混在分類、stack/alignment、連続取得を段階的に追加する | 各段階で単独の回帰テストがあり、前段の結果を壊さない |
| **4C-4 双方向・失敗安全性確認** | 呼出し側だけの偶然の一致を排除する | GCC caller/Rubycc callee、Rubycc caller/GCC calleeの両方向を確認する | silent mismatch、クラッシュ、未定義メモリ読み取りがなく、問題時は診断拒否へ戻せる |
| **4C-5 仕様・対象範囲の更新** | 実装と宣言を一致させる | R9、R10対象範囲、README、ROADMAP、C11カバレッジを同時更新する | 実装済みABI範囲と仕様文書が一致する |

### Phase 5: 必要最小限のhost/target整理

Phase 1〜4で実際の重複・失敗原因が確認できた箇所だけを抽出する。host、target、libc、runnerを一つの巨大なprofileへ統合しない。

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **5-1 依存要因の観測** | 抽象化する根拠を集める | host CPU、target ABI、ELF machine、relocation、Ruby header、loader、Fiddle、libc SONAME/path、runnerの差分を記録する | 各差分が実際の失敗・重複・skipのどれに関係するか説明できる |
| **5-2 実行コンテキスト境界の設計** | host/target/libc/runnerを分離する | 小さなprofileまたはhelperの責務と入力を定義する | 一つのprofileが複数の異なる保証を隠さない |
| **5-3 libc解決の整理** | PC固有のSONAME/path依存を解消する | [`test/support/libc_helper.rb`](../test/support/libc_helper.rb)をAArch64を含む解決方式へ整理する | glibc/muslとtargetのpathがrunner環境に応じて解決される |
| **5-4 実行形式テストの整理** | x86_64固有oracleとnative統合を分離する | [`test/support/execution_helper.rb`](../test/support/execution_helper.rb)、[`test/support/aarch64_execution_helper.rb`](../test/support/aarch64_execution_helper.rb)、`test_shared_object.rb`、`test_executable.rb`を整理する | ELF・relocation固有期待値はtarget別に残り、native loader/Fiddle確認はnative profileで実行される |
| **5-5 Ruby header/includeの整理** | host Rubyとtarget C環境を混同しない | `test_ruby_smoke.rb`、`test_extension_build.rb`等のinclude path取得を整理する | Ruby headerとlibc headerの出所がCIでも明示され、PC絶対pathに依存しない |
| **5-6 profile taskの再評価** | 抽象化の保守費用を判断する | 実行対象、時間、成功指標が安定した後にRake profile taskの必要性を再評価する | task追加が有効な場合だけ導入し、テスト選択の複雑化が効果を上回る場合は導入しない |

x86_64とAArch64のELF・ABI固有期待値は共通化せず、GCC・ELF仕様など独立したoracleを残す。

## フェーズ横断の仕上げタスク

各Phaseの成果を統合する作業も、単一の「後処理」にせず、次の意味単位に分ける。

| タスク | 意味単位 | 主な作業・成果物 | 完了条件 |
|---|---|---|---|
| **F-1 CI結果とartifactの確認** | 結果を追跡可能にする | profile、stable ID、状態、runner、target、libc、network条件をartifactへ残す | 失敗したタスクをジョブログだけでなくIDから追跡できる |
| **F-2 ドキュメント整合** | 実装と説明を一致させる | `docs/CI.md`、`DESIGN.md`、`README.md`、`ROADMAP.md`、`STEPS.md`、本計画を更新する | skip、required、native/QEMU、struct `va_arg`の説明が実装と一致する |
| **F-3 代表経路の最終検証** | 計画全体の受入れを行う | Tier A、AArch64/QEMU、native AArch64 smoke、fixture acceptance、live acceptanceを実行する | 各経路のpass/fail/skipped/inconclusiveが契約通りで、許可されない未実行がない |
| **F-4 運用判断** | 維持可能性を確認する | 実行時間、費用、外部障害率、skip数、保守負担をレビューする | 継続、縮小、撤回、次期実装の判断と根拠が記録される |

## CI・tools変更一覧

| 目的 | 変更対象 | 方針 |
|---|---|---|
| Tier Aの既存skip監視 | `tools/ci_check_skips.rb` | 既存CLI互換。総run/skip判定は補助判定として維持 |
| 結果形式の共有 | 新規 `tools/ci_result.rb` | checker間で状態分類と構造化結果を共有 |
| acceptance判定 | 新規 `tools/ci_check_acceptance.rb` | 必須ID、strict skip、`inconclusive`を判定。ログ解析を重複実装しない |
| acceptance取得 | 新規 `test/support/acceptance_fetch_helper.rb` | retry・checksum・失敗分類を共通化 |
| struct利用調査 | 新規 `tools/scan_corpus_variadics.rb` | 候補収集のみ。合格判定や不在証明には使わない |
| native/cross CI | `.github/workflows/test.yml`、`weekly.yml` | QEMU PR検証を維持し、native smokeを別profileで追加 |
| 必須fixture | `config/ci/acceptance_manifest.json`、CI workflow | network-freeの必須IDと結果を固定 |

`ci_check_skips.rb`と`ci_check_acceptance.rb`に独立したログ解析・policy実装を持たせない。既存Tier Aの互換性を守りつつ、acceptanceは構造化結果を主入力にする。

## タスク単位と順序

各タスクを独立PRまたは独立コミットの候補とし、前提となる契約・観測結果がない状態で後続の抽象化やskip解除を進めない。同じPhase内で並列化できるものは、成果物の境界を崩さない範囲で並列に進める。

1. `0A-1` → `0A-2` → `0A-3` → `0A-4`で、実行コンテキスト、現状値、stable ID、判定契約を確定する。
2. `0B-1` → `0B-2` → `0B-3` → `0B-4`で、結果スキーマとacceptance checkerを導入し、既存Tier Aとの互換性を確認する。
3. `1A-1`の後、`1A-2`と`1A-3`を並列に進め、`1A-4`で比較検証してから`1A-5`でskipを解除する。`1B-1` → `1B-2` → `1B-3`は1-Aと並列に進められる。
4. `2A-1` → `2A-2` → `2A-3` → `2A-4`でfetch/unpackの分類を固める。`2B-1` → `2B-2` → `2B-3` → `2B-4`は、`0B`と`2A`の成果を前提に進める。
5. `2C-1` → `2C-2` → `2C-3`でlive acceptanceを分離し、`2C-4`でcache導入の要否を判断する。cacheを導入する場合も、観測結果の確認後に別タスクとして扱う。
6. `3-1` → `3-2` → `3-3` → `3-4` → `3-5`でnative AArch64 smokeを追加する。これは`0A`完了後であれば、Phase 1・Phase 2の一部と並列に進められる。
7. `4A-1` → `4A-2` → `4A-3`で暫定仕様を固定し、`4B-1` → `4B-2` → `4B-3` → `4B-4`で利用実態を調査する。`4C-1`以降は`4B-4`で実装需要が確認された場合だけ開始する。
8. Phase 1〜4で得た証拠を使い、`5-1` → `5-2` → `5-3`〜`5-5` → `5-6`の順に、必要なhost/target整理だけを実施する。
9. `F-1` → `F-2` → `F-3` → `F-4`でartifact、仕様文書、代表経路、運用コストを最終確認する。

`0A`完了後に並列化できる範囲は広いが、`00130`・`00151`のskip解除、strict acceptanceのrequired化、struct `va_arg`の実装開始、Phase 5の大規模共通化は、それぞれの前段タスクの完了条件を満たすまで行わない。

## 成功指標と撤回条件

| 対象 | 成功指標 | 撤回条件 |
|---|---|---|
| 判定基盤 | 必須IDが全件実行され、strict acceptanceの未実行skipが0 | ID管理がログ形式に過度依存する場合 |
| AArch64 | QEMU/nativeの誤認がなく、native固有smokeが実行される | 重複だけ増え、native固有問題を検出できない場合 |
| `00130`・`00151` | 具体値とmutationを検出し、根拠ごとにskip解除 | fixtureだけpassし、元ケースが未検証のままの場合 |
| struct `va_arg` | R9/R10への影響と利用実態が記録され、仕様文書が一致 | GCCとのsilent mismatch、クラッシュ、R10低下 |
| acceptance | fixtureが常時決定的にpassし、live失敗が分類される | 外部障害redが継続し通知価値を失う場合 |
| CI matrix | 代表経路で目的を満たし、時間・費用が上限内 | profile追加のたびに保守量・実行時間が増える場合 |

## 批判レビューでの主な修正点

初版計画から次を変更した。

- profile taskとpolicyを最初から全面導入せず、結果契約と必須ID判定に縮小した
- `ci_check_skips.rb`とacceptance checkerのログ解析重複を避ける構成にした
- `00130`・`00151`とrmake goldenを、費用対効果の高い早期作業へ移した
- native AArch64は全suiteではなく、native固有の統合スモークに限定した
- struct `va_arg`のscanを実装判断の前提にし、不在証明や合格判定には使わないと明記した
- cacheとartifactを同時導入せず、fixture、観測、artifact、cacheの順にした
- 全ターゲット・全libc・全runnerの組み合わせを作らず、代表経路に限定した

## 実装進捗（2026-08-09）

このworktreeで実装した範囲と、実装後の批判レビューによる修正を次のように記録する。

| タスク | 状態 | 実装・検証 |
|---|---|---|
| 0B 構造化結果・checker・reporter | 完了 | profile/network context、期限、未実行・skip・strict `inconclusive` 判定、空の既存結果ファイルを含むreporter統合テストを追加 |
| 1A `00130`・`00151` | 完了 | stdout/GCC oracle、`00151` mutation、skip再導入検出。host suiteは実CPU targetを選択 |
| 1B rmake golden | 完了 | logical path、全fixtureのheader独立性、未知missing targetの合成禁止、CI strict失敗 |
| 2A fetch helper | 完了 | retry分類、実子プロセスtimeout、manifest URL直取得、atomic download、SHA-256検証、checksum/unpack分類、strict typed failure |
| 2B fixture job | 完了 | mkmf/rmakeのnetwork-free required profileとmanifestをworkflowへ接続 |
| 2C live/M2 | 実装・ローカル実測完了 | live stable ID、M2結果ID、`inconclusive` policy、manifest artifact report、pinned URL/digest、variadic scan artifactを接続。x86_64ローカルでlive対象30 runs / 2598 assertionsとM2 json 603 tests / msgpack 455 examplesを実測pass |
| 3 native AArch64 smoke | 実装完了・実runner未実測 | native RubyのCPU/arch、gcc machine、Fiddle、Ruby headers、loader/libc preflight、skip防止、ABI/Fiddle/cross-compiler smokeを接続。現在のx86_64環境ではnative AArch64実測は未実行 |
| 4A struct `va_arg` | 完了 | DESIGNの対応範囲を修正し、struct caller・直接/typedef `va_arg`の診断を固定 |
| 4B scanner | 部分完了 | lexical scanner、typedef検出、c-testsuite実測記録、M2 json/msgpack artifact接続。R10全gemの手動分類は未完了 |

レビューで追加した代表的な再検証結果は、CI checker 14 runs / 58 assertions、
fetch helper 9 / 33、scanner 8 / 44、rmake golden 7 / 24、c-suite対象4 / 23で、
いずれもfailure/error/skipは0である。実装後の全体回帰は
`2996 runs / 9660 assertions / 0 failures / 0 errors / 42 skips` だった。

## 残課題（2026-08-10）

実装済みのCI経路と、まだ実環境で確認していない範囲を混同しないため、次を残課題として管理する。

| 残課題 | 現状 | 次の確認・完了条件 |
|---|---|---|
| live network acceptanceの実環境実行 | workflow、stable ID、strict checker、M2結果記録は実装済み。外部ネットワークを使うjob自体はこの環境では未実行 | GitHub Actions上でlive jobを実行し、fetch/unpack、gem install、M2の全必須IDとartifactを確認する |
| native AArch64の実測 | `uname`だけでなくRubyの`RbConfig`を検証するnative smoke workflowを追加済み。現在のx86_64環境ではnative AArch64は未実行 | AArch64 runner上で対象smokeがskipされずpassし、ログにnative contextが残ることを確認する |
| R10全対象gemの手動分類 | scannerのc-testsuite実測と、M2で取得できたjson/msgpackのartifact走査まで。macro展開・生成コードを含む全gemの手動分類は未完了 | R10対象gemごとに「実使用・誤検出・要追加確認」を分類し、struct `va_arg`の実装要否を決定する |

これらは未実施をgreenとして扱わない。fixture acceptanceはnetwork-freeの必須経路として独立しており、live/native/R10の未確認範囲は上表の状態のまま受入れ判定から区別する。

## 次段階の実装計画（R10手動分類を除く、2026-08-10）

この段階では、R10全対象gemの手動分類（上表の3行目）を実施しない。残る課題を、成果物と完了条件が一つに対応するタスクへ分解する。

### 6A 実checksum値をmanifestへ接続する

| タスク | 作業 | 完了条件 | 依存 |
|---|---|---|---|
| 6A-1 manifest契約 | gem/archiveごとのURL、version、SHA-256、更新期限、対象profileを定義する | 欠落・形式不正・期限切れをテストで検出できる | なし |
| 6A-2 fetch検証 | helperが取得後にSHA-256を計算し、期待値なし・不一致・一致を別状態で記録する | 不一致をunpackやpassへ進めず、typed failureとして返す | 6A-1 |
| 6A-3 呼び出し側接続 | M2とlive acceptanceが同じmanifestから期待値を読み、結果artifactにdigestを残す | 全live取得対象が検証対象として記録される | 6A-2 |
| 6A-4 批判レビュー・修正 | manifestの更新運用、cacheとの相互作用、秘密情報混入を確認する | レビュー指摘を修正し、helper・M2・checkerの契約が一致する | 6A-1〜3 |

### 6B live acceptanceを実環境で確定する

| タスク | 作業 | 完了条件 | 依存 |
|---|---|---|---|
| 6B-1 実行前preflight | RubyGems、curl、Ruby、rmake、結果パス、network/profileを確認する | 必須ツール不足をskipで隠さず、実行条件をartifactへ残す | なし |
| 6B-2 live実行 | stable ID単位でmkmf/rmake/gem installを実行する | manifestのlive IDが全件一度だけ記録される | 6A-3、6B-1 |
| 6B-3 M2実行 | json/msgpackの取得、拡張ビルド、gem test、variadic reportを同一jobで実行する | M2 4経路と2 suiteの状態・digest・reportが保存される | 6A-3、6B-1 |
| 6B-4 artifact判定 | checker、結果JSON、fetchログ、M2 reportを照合する | 外部障害をproduct passと誤認せず、未実行IDがない | 6B-2、6B-3 |
| 6B-5 批判レビュー・修正 | liveの再実行性、失敗分類、長時間実行、外部障害時の判定を確認する | レビュー指摘を修正し、再実行手順を文書化する | 6B-4 |

### 6C native AArch64 smokeをrunnerで確定する

| タスク | 作業 | 完了条件 | 依存 |
|---|---|---|---|
| 6C-1 native結果契約 | native runner、host CPU、Ruby `RbConfig`、loader/libcを構造化結果へ記録する | QEMU結果とnative結果をIDだけで区別できる | なし |
| 6C-2 preflight強化 | `uname`、Ruby host_cpu/arch、gcc、Fiddle、Ruby headersを確認する | AArch64以外では実施せず、AArch64必須profileの不足はfailになる | 6C-1 |
| 6C-3 native job接続 | smokeとchecker/artifact uploadをworkflowへ接続する | native runnerでskip 0、対象IDがpass、context logが保存される | 6C-2 |
| 6C-4 実runner検証 | GitHub Actions AArch64 runnerで実行する | 実測結果に基づき、未実行を完了扱いしない | 6C-3 |
| 6C-5 批判レビュー・修正 | runner種別、CPU判定、skip防止、実行時間を確認する | レビュー指摘を修正し、QEMU/nativeの保証範囲を文書化する | 6C-4 |

### 並列化とレビュー順序

6Aと6Cは書き込み範囲を分離して並列に実装できる。6Bは6A-3のmanifest接続に依存するため、6A完了後に実施する。各実装タスクの完了直後に、次の観点で批判レビューを行う。

- 目的に対して観測が十分か。未実行・誤ったprofile・外部障害をpassへ変換していないか。
- PC固有のパス、CPU、RubyGems cache、時刻、ネットワークへ暗黙に依存していないか。
- manifest、helper、reporter、checker、workflowの状態・ID・contextが一致しているか。
- 失敗時の再現方法とartifactがあり、skipが単なるgreen化に使われていないか。

レビューで指摘が出た場合は、指摘を記録してから実装を修正し、対象タスクの完了条件を再実行する。最後に6A〜6Cの成果を統合し、R10手動分類は未完了のまま明示する。

### 次段階タスクの実装進捗とレビュー結果（2026-08-10）

| タスク | 状態 | 実装・批判レビュー後の確認 |
|---|---|---|
| 6A manifest/checksum接続 | 完了 | manifest URL・実SHA-256・期限・gem/source metadata、HTTPS直取得、atomic download、cache検証、artifact report、checker照合を接続。レビューで見つかったURL未使用、未知profileの空判定、非atomic cache、M2依存の未固定を修正した |
| 6B-1 live preflight | 完了 | `tools/live_acceptance_preflight.rb`でRuby/RubyGems/curl/rmake/rubycc、strict/profile/network、CPU、結果・artifact pathを実測してfail/passを記録。外部ツールを隠した異常系でexit 1とfail artifactを確認した |
| 6B-2〜4 live/M2/artifact判定 | ローカル実測完了・GitHub Actions未実測 | x86_64でpreflightを含むlive必須ID 10件、30 runs / 2598 assertions、M2 json 603 tests / msgpack 455 examplesを実測し、SHA-256付きartifactとstrict checkerがpass。レビューでBundler環境漏れと専用GEM_HOMEのRSpec bin参照を修正した |
| 6B-5 live批判レビュー | 完了 | 外部障害を`inconclusive`へ分離し、strictでは失敗、fetch checksum不一致・compile/link・gem test失敗はpass/skipに変換しないことを確認した |
| 6C-1〜3,5 native契約・preflight・workflow・レビュー | 実装完了・実runner未実測 | native contextを`uname`だけでなくRuby/gcc/Fiddle/headers/loader/libcから構成し、preflight fail、required ID、context JSONを含むartifact upload、cross-compiler ABI smokeを接続。レビューでpreflightの非構造化失敗と同一compilerだけのABI確認を修正した |
| 6C-4 GitHub Actions AArch64実測 | 未実施 | `ubuntu-24.04-arm`でpreflightを含む全native IDがpass、skip 0、contextがAArch64であることを確認する |

R10全対象gemの手動分類は、この段階の対象外であり未完了のまま残す。GitHub Actionsのlive/native実runner実測も、push・dispatchを伴う外部操作をこの作業では行っていないため、実装完了とは別に未実施として管理する。

## 残課題の実施計画とタスク分解（2026-08-10）

上記の残課題を、ローカルで完了できる準備作業と、GitHub Actionsまたは外部gem
ソースを必要とする実測作業に分ける。実測していないものをgreenや「検証済み」とは
扱わない。各タスクは、実装・測定の直後に批判的レビューを行い、指摘があれば
修正後に完了条件を再実行する。

### 1. live acceptanceのGitHub Actions実runner実測

目的は、ローカルの成功ではなく、GitHub-hosted Ubuntu runner上でmanifest固定の取得、
gem install、M2のgem自身のテスト、およびstrict checkerが一つのCI経路で成立することを
確認することである。

| ID | タスク | 成果物・完了条件 | 依存 |
|---|---|---|---|
| LIVE-0 | 対象refと実行契約を固定 | branchのcommit SHA、workflow変更、manifest SHA-256、実行予定の`acceptance-only`入力を記録する。未commit差分を実測証拠にしない | なし |
| LIVE-1 | acceptance-only入口を用意 | `workflow_dispatch.only=acceptance`で決定的fixtureとlive acceptanceだけが起動し、census・throughput・musl・native・Ruby 3.4が起動しない。入力値ごとの期待job集合を表にして、workflow YAMLのparseと条件の静的確認を通す | LIVE-0 |
| LIVE-2 | ローカル事前検証 | checker、manifest、preflight、fixtureの対象テストを実行し、`git diff --check`を通す。live preflightは`bundle install`より前に実行し、依存導入失敗時にも実行環境artifactを残す。ここでのpassはGitHub実測の代用にしない | LIVE-1 |
| LIVE-3 | 外部実行 | 対象refをGitHubへpushし、`only=acceptance`をdispatchする。fixture jobとlive jobの両方を実行する | LIVE-2、外部操作の承認 |
| LIVE-4 | 結果・artifact照合 | fixtureの必須IDがpass、liveのpreflight・8個のstable acceptance ID・2個のM2 suite IDが各一件、未実行/skip/inconclusiveがなく、manifest URL・expected/actual digest・bytes・reportが一致する。workflowの`head_sha`がLIVE-0のSHAと一致する | LIVE-3 |
| LIVE-5 | 批判レビューと再実測 | ネットワーク障害、429/5xx retry、checksum不一致、compile/link失敗、gem test失敗を区別する。外部障害はstrict checkerをfailにし、未実行M2をpassへ変換しない。artifactに失敗分類が残ること、runner上の実job集合がLIVE-1の期待集合と一致することを確認し、問題があればworkflow/toolsを修正してLIVE-2〜4を再実行する | LIVE-4 |
| LIVE-6 | 記録と有効期限 | run URL/ID、commit SHA、runner、Ruby、結果要約、artifact名、失敗分類、再実行の有無、次回再検証期限を`TEST-PLAN.md`と`TEST-REVIEW.md`へ記録する。一回の成功を継続保証とは扱わない | LIVE-5 |

`acceptance-only`を追加する利点は、live実測を週次全体の費用・失敗と分離しながら
fixtureを同時に必須化できることである。欠点はworkflowの条件分岐が増え、条件の回帰を
テストする必要があること、GitHub runner・RubyGems・DNSに依存することである。全週次を
実行する方法なら入口変更は不要だが、費用が大きく、どのjobの失敗かを切り分けにくい。
manifestの固定SHA-256とstrict判定は、前者の外部依存をなくすものではなく、取得物の
同一性と失敗の意味を固定するための対策である。

LIVE-1の期待job集合は、manual inputの組み合わせも含めて次のように固定する。

| `verify_step` | `only` | 起動を期待するjob |
|---|---|---|
| 空 | 空 | `dispatch-contract`、census、acceptance-fixture、acceptance、throughput、musl、musl-aarch64、Ruby 3.4 |
| 空 | `acceptance` | `dispatch-contract`、acceptance-fixture、acceptance |
| 空 | `aarch64` | `dispatch-contract`、aarch64、native-aarch64-smoke |
| 空 | `musl-aarch64` | `dispatch-contract`、musl-aarch64 |
| 非空 | 空 | `dispatch-contract`、muslの更新モード |
| 非空 | 非空 | `dispatch-contract`だけが起動し、validationでfail |

`dispatch-contract`は、全jobがskipになる不正なmanual inputを成功扱いしないための
guardである。LIVE-3/ARM-2では、表示されたjob集合とこの表を照合する。

### 2. native AArch64実runner実測

目的は、QEMUによるtarget実行をnative実行の証拠に置き換えず、`ubuntu-24.04-arm`上の
Ruby、loader/libc、Fiddle、ヘッダー、ABI smoke、およびTier A全suiteの実測を残すことである。

| ID | タスク | 成果物・完了条件 | 依存 |
|---|---|---|---|
| ARM-0 | native契約を凍結 | `only=aarch64`、`ubuntu-24.04-arm`、Ruby 3.3/4.0のTier A reusable job、native smoke、required ID、skip許容範囲を記録する | なし |
| ARM-1 | ローカル静的検証 | workflow YAML、native preflight、manifest/checker、native helperテストを実行する。x86_64でnative必須profileを実行した場合はskipではなくfailになることを確認する | ARM-0 |
| ARM-2 | 外部実行 | 対象refをGitHubへpushし、`only=aarch64`をdispatchする。native full suiteとnative smokeを実行する | ARM-1、外部操作の承認 |
| ARM-3 | 実CPU証拠の確認 | `uname -m`、Ruby `RbConfig`のhost_cpu/archとELF machine、gcc machine、Fiddleのloader probe、Ruby headerのcompile probe、Rubyのdynamic dependency、loader/libcがAArch64で一致し、QEMU経由の代替でないことをcontext artifactから確認する | ARM-2 |
| ARM-4 | 結果・skip照合 | native smokeのrequired IDが全件pass、CPU依存テストが対象CPU上で実行され、無条件skip・不足ツール隠蔽・full suite途中終了がない。full suiteは承認済みskip理由/件数のbaselineと比較し、baseline未確定ならsmoke passだけでnative全suiteの完了を主張しない | ARM-2、ARM-3 |
| ARM-5 | 批判レビューと再実測 | runnerラベルだけを信頼していないか、full suiteとsmokeの保証範囲が重複/欠落していないか、skip allowlistが新しい欠落を隠していないか、120分の費用に対して情報量が妥当かを確認する。指摘があればworkflow/helper/checkerを修正しARM-1〜4を再実行する | ARM-4 |
| ARM-6 | 記録と有効期限 | run URL/ID、commit SHA、native context、full suiteとsmokeのrun/skip/failure、skip baseline、artifact名、次回再検証期限を文書化する。一回のmanual dispatch成功を継続保証とは扱わない | ARM-5 |

full suiteを含める利点は、native Ruby上で既存のhost依存テストが意図せずskipや別
architectureの生成物へ流れないことも確認できる点である。欠点は実行時間とrunner費用が
大きいことである。smokeだけなら安価だが、Tier A全体のnative互換性は主張できない。
したがって最初の受入れは`only=aarch64`でfull suiteとsmokeを同時に実行し、以後の定期
監視をsmoke中心にするかは実測後のレビューで決める。

### 3. R10対象gemの手動分類

この作業は、scannerの件数をR10合否やstruct `va_arg`対応の証拠にしないための調査である。
まず現在のmachine gateで`status: ok`の32件を初期母集団とする。ただし、`DESIGN.md`が
in-scopeとする`pg`をcensusがmini_portile文字列だけでexcludedにしている点、
`sqlite3`のsystem-library profileを別経路とする点は、分類開始前にスコープ境界を確定する。
この境界が未決のままでは「全対象」の件数を固定しない。

初期母集団（census `status: ok`）は次の32件である。

`json`, `msgpack`, `bigdecimal`, `date`, `racc`, `redcarpet`, `digest`, `erb`,
`etc`, `io-console`, `io-nonblock`, `io-wait`, `openssl`, `prism`, `psych`,
`stringio`, `strscan`, `zlib`, `fiddle`, `rbs`, `syslog`, `websocket-driver`, `puma`,
`google-protobuf`, `bootsnap`, `oj`, `nio4r`, `mysql2`, `http_parser.rb`, `stackprof`,
`yajl-ruby`, `nkf`。

| ID | タスク | 成果物・完了条件 | 依存 |
|---|---|---|---|
| R10-0 | 母集団・境界を確定 | DESIGN、`gems.rb`、censusの差分を確認し、pg、sqlite3 system-library、除外7件の扱いを明記する。対象名・versionが一意で、件数と理由が一致する | なし |
| R10-1 | source provenanceと記録形式を固定 | 各gemのversion、取得URL、SHA-256、取得日時、解凍元、生成ファイルの入手経路を記録する。作業用scratch GEM_HOME/ディレクトリを使用し、ローカルBundlerや既存gemを混ぜない。記録は後述の必須フィールドを持つ | R10-0 |
| R10-2 | 機械的候補抽出 | C source、header、extconf、macro、生成前後のsourceを、実際のextconf/Rakeで選ばれたフラグとpreprocessor条件に沿って走査し、`va_list`/`va_arg`/struct型/可変呼出し候補と位置をartifact化する。scanner結果は候補一覧に限定し、不在証明に使わない | R10-1 |
| R10-3 | gemごとの手動分類 | 各候補を、(a)実使用、(b)誤検出、(c)要追加確認に分類する。コメント・dead code・未選択platform、macro展開後、Rake/extconf生成後の実コンパイル経路を根拠付きで記録する。(c)は未解決理由・次の確認・担当・期限を必須にし、pass扱いしない | R10-2 |
| R10-4 | recipeとcontrol/rubyccの対象経路確認 | 全対象について検証recipeまたは同等の再現手順を用意する。(a)および判断に影響する(c)は、同一source・同一testでGCC controlとrubyccを分離実行する。extensionが実際にloadされたこと、suiteがfallbackを使っていないことを確認する。AArch64条件を含む場合はAArch64 runner上だけで実行する | R10-3 |
| R10-5 | 仕様判断 | 実使用の型、SysV AMD64/AAPCS64、レジスタ枯渇、HFA、生成コードの有無を整理し、structを`...`へ渡す場合とstruct `va_arg`を独立判定する。必要な場合だけ段階実装の対象を決める。x86_64の結果をAArch64の証拠にしない | R10-4 |
| R10-6 | 完了性レビュー | 対象全件に分類・根拠・source SHA・実行profile・未確定理由があり、「未調査」を空欄やpassにしていないことを第三者が確認する。全32件に最終分類があり、cの件数と未解決理由を集計する | R10-5 |
| R10-7 | 修正・再実測・記録 | レビュー指摘で分類、scanner、verify tool、仕様文書に修正を入れ、該当gemの確認を再実行する。`data/verified_gems.json`は(d)水準のinstall+upstream suite証拠が揃ったgemだけ更新し、手動分類結果とは混同しない | R10-6 |

R10分類記録の各gem行には、少なくとも `name`、`version`、source/gem SHA-256、ext root、
generated sourceの有無と生成コマンド、候補のfile:line・候補種別、preprocessor/build
profile、分類、control/rubycc結果、extension loadの証拠、upstream suite結果、レビュー者・
日時、(c)の場合の未解決理由・次アクション・期限を持たせる。(a)は実際に選択された
translation unitまたは実行経路まで示し、(b)はなぜ未選択かを示す。これらがない行は
分類済みとは数えない。

手動分類の利点は、macro・生成コード・platform gateを実際のビルド経路に沿って判断
できる点である。欠点は32件分のsource取得・依存導入・control/rubycc実行に時間がかかり、
system libraryやarchitecture差で再現条件が増える点である。scannerだけなら安価だが偽陽性・
見逃しを除去できず、suite passだけなら実使用していない経路を証明できない。したがって
候補抽出、手動根拠、control/rubycc実測を別証拠として保存する。

### 共通のレビューゲートと順序

LIVE-0〜2とARM-0〜1はローカルで並列に進められる。外部runner実測は同じcommit SHAを
使うため、LIVE-3とARM-2はref固定後に実行する。R10-0〜3はCI実測とは独立だが、
R10-0の境界確定前に32件の分類を開始しない。

各レビューでは少なくとも次を問う。

1. 実際に保証したい目的を観測しているか。runner label、scanner件数、suite終了コードだけを証拠にしていないか。
2. PC固有のCPU、path、cache、Ruby/Bundler環境、時刻、networkに暗黙依存していないか。
3. 失敗・未実行・inconclusive・skipが、意図せずpassへ変換されていないか。
4. source、結果JSON、context、artifact、commit SHAが相互に追跡可能か。
5. 指摘を修正した後、同じ完了条件を再実行しているか。

この計画自体のレビュー完了後も、push/dispatchが必要なLIVE-3/ARM-2と、手動分類を
実施していないR10は未完了として残す。ローカルのfixture/live相当、x86_64上のforced
native failure、既存scanner結果を、これらの実測の代用にはしない。

### 残課題計画のローカル実装・批判レビュー後の進捗（2026-08-10）

| タスク | 状態 | 確認内容 |
|---|---|---|
| LIVE-1 acceptance-only入口 | ローカル完了 | `workflow_dispatch.only=acceptance`、fixture/liveの条件、入力組み合わせ検証、workflow静的テストを追加。`test/test_weekly_workflow.rb` 3 runs / 21 assertionsで確認 |
| LIVE-2 preflight順序 | ローカル完了 | live preflightを`bundle install`前へ移動し、依存導入失敗時にも結果JSONを残す契約へ修正。YAML、manifest、checker、preflightを再確認 |
| ARM-1/ARM-3 native preflight | ローカル完了・実runner未実測 | Ruby ELF/dynamic dependency、Fiddle loader、Ruby header compileを実測するcontext/resultへ強化。`test/test_native_aarch64_preflight.rb` 1 run / 8 assertions、x86_64ではstructured failを確認 |
| R10-0〜R10-6 計画 | 批判レビュー・改善完了、実分類未着手 | 32件暫定母集団、pg/sqlite3境界、証拠フィールド、macro/生成コード、control/rubycc、architecture profile、`要追加確認`の期限、全件レビュー条件を文書化 |
| LIVE-3/ARM-2 外部実測 | 未実施 | commit SHAを固定してpush/dispatchする外部操作が必要。未実施をpassへ扱わない |
| R10-7 手動分類実測 | 未実施 | ユーザー指定のR10全対象gem手動分類は、境界確定後に別工程として実施する |

この計画レビュー後の全体回帰は `3000 runs / 9689 assertions / 0 failures /
0 errors / 42 skips` で、`tools/ci_check_skips.rb`も `skips <= 55`、`runs >= 2500`
を満たした。skip 42件は従来の許可された理由であり、native smoke 2件はx86_64上で
意図どおりskipされている。これはnative実runner実測の代用ではない。
