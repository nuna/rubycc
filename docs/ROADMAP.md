# rubycc 実行計画(ロードマップ)

このドキュメントは、**担当者(人間・AI モデルを問わず)が入れ替わっても開発を継続できる**
ことを目的に、開発ワークフロー・実装規約・既知の負債・今後の全ステップの設計方針と
トレードオフを記録する。要件とアーキテクチャの根拠は [DESIGN.md](DESIGN.md)、
完了済みステップの設計記録は [STEPS.md](STEPS.md) を参照。

マイルストーン定義(DESIGN.md 8 章の再掲):
- **M1**: プリプロセッサ + C11 サブセットコンパイラ + x86_64 ELF .o 出力。自己テスト合格。
- **M2**: リンカ(.so / 実行ファイル)+ ar。json / msgpack 級の gem を手動ビルドしテスト合格。
- **M3**: rmake + rubygems_plugin + pkg-config シム + conftest 完全対応。
- **M4**: aarch64 バックエンド。
- **M5**: glibc/musl 互換ヘッダ拡充、コーパス 90% 達成、v1.0 リリース。
- **M6 以降**: macOS、基本最適化、行番号デバッグ情報、GCC 擬態モード。

現在地: **M2 完了判定を達成(Step 54、glibc 環境)**: json 2.21.1 = rubycc ビルドの C 拡張で **606 tests / 100% passed**、msgpack 1.8.3 = **455 examples / 0 failures**(手順は tools/m2_acceptance.rb で再現可能)。残項目: musl コンテナでの確認(M3 のコンテナマトリクス整備時)、L5 第三段(.gnu.hash・RELRO、適合性磨き込み)。**M3 進行中**: コーパス化 = Step 55、B1(rmake コア)= Step 56、B2(シェルレス実行器)= Step 57、B3(in-process ツール置換 + -j 並列)= Step 58 完了。**実物 mkmf Makefile → rmake → rubycc 製 .so の柱が通った**(json parser.so dlopen 確認、msgpack フル 12 TU を jobs:4 で約 30 秒完走)。B4 = Step 59、B5(conftest 完全対応)= Step 60 完了(RbConfig 4 キー差し替えの mkmf_shim。実測で have_func 偽陽性(実行ファイルリンカの未解決検査)と check_sizeof(sizeof 式のリゾルバ注入畳み込み)を修正。msgpack extconf の probe が gcc fixture と一致、json の SIMD probe は自然に偽化して JSON_DISABLE_SIMD 不要に)。**M3 完了(Step 64)**: distroless 姿勢(libc 開発ヘッダ不使用 = RUBYCC_HERMETIC_HEADERS・cc/make/sh 不使用)での `gem install json / msgpack` が成功・動作。同梱 libc ヘッダは 22 本で足りた(不足は arpa/inet 1 本のみ、実測駆動)。残項目: 真の distroless / musl コンテナ検証(環境なし、CI 整備時)・sqlite3/pg(dev ライブラリ導入後)。**M3 完了後のユーザ指示成果物 4 件も完了**(Step 65 = C11-COVERAGE.md + GCC-EXTENSIONS.md、Step 66 = ベンチマーク(benchmark/ + docs/BENCHMARKS.md、劣位ケース実測込み)、Step 67 = rubycc-doctor + data/verified_gems.json)。**M4 進行中**: A1(バックエンド抽象化リファクタ)= Step 68 完了(機種非依存リロケーション語彙 6 種・MachineDescription 注入・`Compiler::TARGETS`・`-target`。リファクタ前後で .o バイト一致 3/3 = 挙動変更ゼロを実証)。A2(aarch64 コーデジェン・コア)= Step 70 完了(sp 正オフセットのフレーム・MOVZ/MOVK・CSET・B/CBZ バックパッチ・AAPCS64 x0-x7。副産物として x86_64 の暗黙仮定 2 件 = 関数間パディングの NOP と ELF リーダのアーキ固定を是正)。Step 71 で **qemu-user + クロス gcc を導入し、aarch64 の実行オラクル検証を達成**(差分実行テスト 34 件、実バグ検出なし)。A3(メモリアクセスとリロケーション)= Step 72 完了(ADRP+ADD / ADRP+LDR のペア・リロケーション。x86_64 は 68 サンプルでバイト一致)。素の char の符号性のターゲット化 = Step 73 完了(文字型を 4 実体に分離。x86_64 は 12 サンプルでバイト一致)。**A3 完了(Step 72 + 73 + 74)**: c-testsuite 220 中 191 件・examples 36 中 26 本が aarch64 で通過し、残りはすべて A4 の未対応機能に由来。この過程で x86_64 の暗黙仮定に由来する実バグ 2 件(名前なしビットフィールドの整列規則、CPU 識別マクロ)を検出・修正した。**A4 進行中**: 浮動小数・間接呼び出し = Step 75、スカラ引数分類の per-target 化 = Step 76 完了(**c-testsuite の aarch64 保留が空に。220 件中 203 件通過**、examples は 36 中 28 本)。集約分類のターゲット化 = Step 77、可変長関数の定義 = Step 78 完了で **A4(ABI 完全化)が完了**(c-testsuite 220 中 203 件・examples 36 中 33 件が aarch64 で通過。残りはすべて aarch64 固有ではない既存の未実装機能)。**A5 進行中**: 実行ファイルリンカ + crt = Step 79、共有ライブラリリンカ = Step 80 完了(**自作リンカだけで aarch64 の実行ファイルと .so を生成し qemu 実行・dlopen**。クロス gcc 不要。x86_64 は実行ファイル・.so ともバイト一致)。**M4 のコード生成・ABI・自作リンクは揃った**。**残る M4 受け入れ: aarch64 で全スイート + gem install の実走**(qemu 上で動く aarch64 版 Ruby が必要で、コンテナ/CI マトリクス整備時に対応)。並行して float binary32 丸めバグを解消(Step 69、§3 の債務消し込み)。残項目(随時): ABI ファジングハーネスの機種化・musl/distroless コンテナ検証・sqlite3/pg コーパス。

---

## 1. 開発ワークフロー(1 ステップのサイクル)

1. **計画**(メインセッション): ROADMAP から次ステップを選び、スコープ(対応する機能・
   明示的に先送りしてエラーにする機能)を確定する。着手前に STEPS.md の関連ステップと
   対象ファイルを読む。
2. **移譲**: 複数ファイルにまたがる実装は heavy-implementer、仕様が確定した機械的実装は
   implementer に移譲(references/role-based-model-selection.md)。移譲プロンプトには必ず
   以下を含める:
   - 対象ファイル一覧と現状アーキテクチャの要約(エージェントは会話履歴を持たない)
   - スコープ(対応する機能/診断エラーにする機能)とテスト要件
   - **R11(既存 OSS 類似実装の禁止)の全文**(DESIGN.md 2 章)
   - コーディング規約(下記 2 章)への言及と「コミットはしない」指示
3. **レビュー**(メインセッション): diff 全体を確認。観点: R11、値表現規約との整合、
   診断の網羅、gen_*/static_type 両経路の同期、コメント密度、既存テストの非破壊。
4. **テスト確認**: test-runner に `rake test` を移譲し全件 green を確認。
5. **コミット**: ステップごとに 1 コミット。メッセージは
   `<英語サマリ> (Step N)` + 日本語の箇条書き本文(既存コミットの体裁に従う)。
6. **記録**: STEPS.md に設計判断・トレードオフを追記し、ROADMAP の該当ステップを消し込む
   (計画から変わった点があれば ROADMAP 側も直す)。冒頭の「現在地」も更新する。
7. **サンプル**: そのステップの代表機能を使う C サンプルを
   `examples/m1/step<NN>_<名前>.c` に 1 本追加する(そのステップ時点で
   ビルドできる機能だけを使い、追加後は変更しない)。全サンプルは
   `test/test_examples.rb` が gcc 差分で常時検証する。運用の詳細は
   `examples/README.md`。

## 2. 実装規約と不変条件

コードを書く前に必ず把握すること。違反はレビューで差し戻す。

- **値表現規約**(backend/x86_64.rb 冒頭に原文): 仮想レジスタのスロットは 8 バイト固定で
  64bit 単位に読み書きする。スカラ値はスロット内で常に 32bit 以上へ符号拡張済み。
  幅の変換(切り捨て・拡張)は**メモリ境界(:load/:store の size)と明示的変換命令
  (:sext8 等)だけ**で起きる。新しい幅・符号を追加するときはこの規約を拡張し、
  **ポインタ経由の書き込みとのエイリアシング整合**(STEPS.md Step 11 の罠)をテストする。
- **集約オブジェクトの値=そのアドレス**: 配列・struct は stack_objects / グローバルシンボル
  に置き、式の中では「アドレスを持つ vreg + その型」で流通する。
- **IR 命令は最後の手段**: まず既存命令への脱糖を検討する(!、&&、ループ、複合代入、
  メンバアクセスはすべて脱糖で実現済み)。追加する場合は ir.rb のコメント一覧と
  [IR.md](IR.md)(IR 仕様書)を必ず両方更新。
- **複合代入・++/-- 系はアドレス一度きり評価**のヘルパ経由で実装する(二重評価バグ防止)。
- **型の構築はパーサ、意味検査はジェネレータ**。タグ・(将来の)typedef 名前空間はパーサが
  スコープ管理し、ジェネレータは完成した Type だけを消費する。
- **二重の型推論経路**: 式の型を変えるときは gen_*(コード生成つき)と static_type 系
  (sizeof 用・副作用なし)の両方を同期させる。
- **未対応機能は黙って壊さない**: 明確な文言の CompileError(ファイル名・行・桁・抜粋つき)
  で拒否する。エラーメッセージの文言は gcc に寄せる。
- **決定的出力**(N4): タイムスタンプ・乱数・Ruby オブジェクト ID をバイナリに埋めない。
- **テスト**: 各段のユニットテスト + 実行テスト(ExecutionHelper)。実行テストは
  **gcc で同じソースをビルドした結果との差分比較**を原則毎ケース付ける。stdout 検証可。
- **コメント**: 「なぜそうなっているか」を説明する英語の説明的コメントを既存と同じ密度で
  書く(type.rb / backend/x86_64.rb が基準)。
- **R11**: chibicc/tcc/8cc/lacc・教材(compilerbook 等)に類似したファイル構成・
  インターフェイス・関数内ロジック・命名を禁止。非終端記号は ISO C の文法用語で命名。

## 3. 既知の逸脱・技術的負債

| 項目 | 内容 | 解消予定 |
|---|---|---|
| 不完全型 struct の param/return | 未呼び出しプロトタイプでも宣言時に診断エラー(分類にレイアウトが要るための簡略化) | 実害が出た時点 |
| 可変長部への struct 渡し・va_arg(struct) | 診断エラーにして先送り | 実害が出た時点 |
| 内側スコープの `struct S;` 再宣言 | C 6.7.2.3p7 に従わず外側タグを参照 | 実害が出た時点 |
| ブロックスコープの関数宣言 | 外部リンケージ未モデルで診断エラー | 実害が出た時点 |
| ~~`&arr[i]` 等の計算アドレス定数~~ | **解消(Step 45、b4be1fe)**: 初期化子を「基点シンボル/文字列 + 定数変位 + pointee」へ畳む walker を追加し、キャスト・`&arr[i]`・`arr ± n`・`&rec.member` を R_X86_64_64 の addend に乗せる。json jeaiii-ltoa の「文字列リテラルを struct ポインタにキャストした桁テーブル」が通る | ~~実害が出た時点~~ **完了** |
| 指し先 const の書き込み検出 | `const int *p` の `*p = x` を診断しない(型に修飾を載せない簡略化) | 実害が出た時点 |
| ~~unsigned long ⇔ float/double 変換~~ | **解消(Step 51 定数側 1c65c47 + Step 52 実行時側 45b6606)**: 定数キャストは 6.3.1.4p1 で畳み込み、実行時は分岐 + 符号付き cvt + 補正(sticky ビット/2^63 しきい値)の IR 合成で lowering。float → unsigned int の既存オーバーフローも修正 | ~~実害が出た時点~~ **完了** |
| ~~文式 `({ … })`~~ | **解消(Step 40、4466e68)**: 一次式で `(` の直後が `{` のとき複合文をパースし最後の式文の値・型を採る文式を実装。`?:` の片側 void アーム(GCC 拡張)対応込み。c-testsuite 00213/00214 合格。Data_Make_Struct / TypedData_Make_Struct / rb_intern() の展開先が通る | ~~早期 M2(最優先負債)~~ **完了** |
| ~~`__builtin_offsetof` / 定数文脈 offsetof~~ | **解消(Step 42)**: `__builtin_offsetof(type-name, member-designator)` を実装(ネスト `.name`・添字 `[expr]`・匿名メンバ対応、ビットフィールドは診断)。ConstantEvaluator が畳むため static 初期化子・配列サイズ・case ラベルの定数文脈で使え、同梱 stddef.h の offsetof も __builtin_offsetof 展開に変更 | ~~早期(Step 42 予定)~~ **完了** |
| ~~ビットフィールドのアクセス~~ | **解消(Step 48、d1da0bf)**: 読み・書き・複合代入・++/-- を格納単位の load → shift/mask → read-modify-write store で実装(符号付きは符号拡張、代入式の値は切り詰め後の読み直し)。& は 6.5.3.2p1 の診断。00218 は enum 符号性(00170 と同根)で残置 | ~~M2~~ **完了** |
| マクロ再展開の hide-set 交差 | `CAT(A,B)(x)` の CAT2 経由再展開が gcc と相違(c-testsuite 00201 で実証)。修正方針記録済み: 置換 paint を「呼び出し名の suppress ∩ 閉じ括弧の suppress + 自名」へ | M2 |
| 128 ビット整数の演算残り | 乗算・加減算・比較・変換に加え、**値渡し/返しを Step 94**(16 バイト 2-INTEGER 集約として既存の構造体 ABI 経路)、**シフト `<<`/`>>` を Step 95**(二重ワードシフト合成)で実装。いずれも両ターゲットの gcc 差分実行オラクルで検証。残りは除算・剰余・ビット演算(`& | ^`)・可変長渡しが診断エラー。**corpus 実害**: bigdecimal が `bits.h` で値渡し(Step 93 検出)と `x >> 64`(Step 94 後に検出)を使い落ちていた → Step 94/95 で解消 | **値渡し/返し(Step 94)・シフト(Step 95)解消。残りの演算は H4** |
| enum の unsigned 底型 | 全 enum を int へ写像(gcc は全非負 enum を unsigned int に)。c-testsuite 00170 のポインタ符号不一致で顕在 | 実害が出た時点 |
| compound literal / VLA / _Generic / ワイド文字列 / #pragma push_macro / K&R `int ()` 型 | 各々診断エラー(c-testsuite スキップ表に理由記録) | 実害が出た時点 |
| ~~素の `char` の符号性がターゲット依存~~ | **解消(Step 73)**: 文字型を 4 実体に分離し(素の char の符号あり/なし + ターゲット非依存の signed/unsigned char)、`Compiler::TARGETS` の `char_signed` からプリプロセッサ・パーサ・IR ジェネレータの 3 段へ配る。同梱 limits.h も `__CHAR_UNSIGNED__` で分岐 | ~~A3~~ **完了** |
| ~~`char *` と `signed char *` の非互換化(受理範囲の縮小)~~ | **解消(Step 98)**: redcarpet の html_smartypants.c が `uint8_t*` を `strncmp(const char*)` に渡して落ちたのを機に、`compatible_types?` の `pointer_sign_compatible?` で同サイズ・逆符号の整数指し先(gcc の -Wpointer-sign 相当)と 1 バイト文字型3種の相互ポインタ互換を受理。異サイズ・文字族以外の別型は硬いエラーを維持 | ~~M5 コーパスで実害が出た時点~~ **完了(Step 98)** |
| ~~aarch64 ターゲットでも `__x86_64__`/`__amd64__` を定義~~ | **解消(Step 74)**: CPU 識別マクロを共通部(`PREDEFINED_PLATFORM_MACROS`)と per-target(`X86_64_ARCH_MACROS`/`AARCH64_ARCH_MACROS`)に分割し `TARGETS` から供給。target を無視していた `-E` 経路も是正 | ~~A4/A5~~ **完了** |
| ~~`struct { float a, b; }` の値渡しが aarch64 で silent miscompile~~ | **解消(Step 77)**: 集約分類を `IR::CallConvention` の 2 実装に分け、`AbiPiece` にオフセットと幅を持たせて HFA を s0/s1 に配置。IR レベルの分岐と実行結果の両方で確認 | ~~A4~~ **完了** |
| ~~スタック引数の 16 バイト整列が未対応~~ | **解消(Step 94)**: 16 バイト整列の集約(`__int128` 等)がスタックに溢れる場合、両規約とも NSAA を奇数境界で 1 eightbyte パディングして 16 バイト境界に載せる `:pad_stack` スロット機構を実装。AAPCS64 のレジスタ偶数ペア規則(`:pad`)も同時にバックエンドへ配線。x86_64・aarch64 双方のクロス TU 実行オラクルで確認 | ~~実害が出た時点~~ **完了(Step 94)** |
| 同梱 `stddef.h`/`stdint.h` の `wchar_t` typedef が `int` 固定 | aarch64 gcc の `wchar_t` は `unsigned int`(`__WCHAR_MAX__` = `0xffffffffU`)。Step 82 で aarch64 の `stdint.h` は `WCHAR_MIN`/`WCHAR_MAX` マクロだけ unsigned に合わせたが、`wchar_t` typedef 自体は freestanding `stddef.h` と共有ガード `_RUBYCC_WCHAR_T` を使うため `int` のまま(符号を変えると include 順で不整合)。ワイド文字リテラルは意図的な診断で拒否しており、ABI ハーネスも符号性は検査しないため観測可能な誤りには至っていない。予定: H4(ワイド文字を扱う gem がコーパスで顕在化した時点)。stddef.h を per-target 化するか、freestanding 層に符号を持ち込む設計判断を伴う | ワイド文字を扱う時点(H4 / A4 以降) |
| ~~float リテラルの binary32 丸め~~ | **解消(Step 69)**: `pack("e")` が FLT_MAX 超を +inf へ飽和させていた。double のビット界から 23 ビットへ最近接・偶数丸めで縮約する変換に置き換え、ABI ハーネスの FLT_MAX 検査を通常の assert へ復帰 | ~~早期~~ **完了** |
| long double = double 扱いによる max_align_t 相違 | rubycc は long double を 8 バイト double として扱う(DESIGN 3.3 の既知制限)ため max_align_t が 16/8(glibc は 32/16)。x87 80bit 対応まで ABI ハーネスの該当検査は非 assert | x87 80bit 対応時(将来) |
| DoS フェイルセーフの上限値 | パーサ再帰深さ 500・#if 式 500・マクロ展開 100 万トークン等(Step 32)は実行環境のスタックサイズ(本環境 ~330 括弧段)前提。極端に浅いスタックの環境では再評価が必要。詳細は docs/security-dos-review.md | コーパス(R10)実測で再調整 |
| -fPIC で定義済みエクスポートグローバルを PC32 参照 | Step 33 は TU 内定義グローバルを PC32(interpose 非対応の -Bsymbolic 相当)。rubycc の SharedLinker は S+A−P で正しく解決するが、GNU ld は preemptible シンボルへの PC32 を共有オブジェクト規則違反として拒否(gcc -shared 相互リンク不可)。実行は正しい | 真の interpose 対応(エクスポート定義グローバルも GOT 経由)を M2 終盤か PIC 改善で。実 gem がグローバル変数をエクスポートするか R10 コーパスで判定 |

### 3.1 開いた負債の後続 STEP への割り当て(明示スケジュール)

上表の「実害が出た時点 / コーパスで判定」系の負債は、いずれも M5 のコーパス相(H3/H4)を
受け皿とする。放置(どのマイルストーンにも紐付かない)を防ぐため、開いた各負債の解消予定を
以下に明示する。原則は R11/DESIGN 4.2 の「先回り実装しない — 実 gem で実害が出た項目を優先」。

| 負債 | 解消予定 | 根拠 |
|---|---|---|
| 不完全型 struct の param/return、内側スコープ `struct S;` 再宣言、ブロックスコープ関数宣言、指し先 const 書き込み検出、compound literal / VLA / _Generic / ワイド文字列 / #pragma push_macro / K&R `int ()`、enum unsigned 底型 | **H4**(言語機能不足 → M1 流儀の追補ステップ) | H3 の #include/ビルド集計と gem テストで顕在化した順に H4 で追補。コーパスに現れないものは v1.0 の「既知の制限」として README 記載(H6) |
| 128 ビット整数の演算残り(除算・剰余・ビット演算) | **H4**(値渡し/返しは Step 94、シフトは Step 95 で解消済み)。残りの演算は必要になった時点 | 実 gem が `__int128` を使う頻度は低い。bigdecimal で実害が出た値渡し(Step 94)とシフト(Step 95)は解消。残りは使う gem がコーパスに現れれば H4 で実装 |
| ~~`char *` と `signed char *` の非互換化~~ | **解消(Step 98)**: `pointer_sign_compatible?` で同サイズ逆符号 + 文字型3種の相互互換を受理。redcarpet の `uint8_t*` → `strncmp` で実害が出て緩和 | ~~Step 73 の副作用~~ **完了(Step 98)** |
| ~~スタック引数の 16 バイト整列(x86_64/aarch64 共通)~~ **解消(Step 94)**、-fPIC の PC32 参照 | 16 バイト整列は Step 94 で解消(`:pad_stack` 機構 + クロス TU 実行オラクル)。-fPIC PC32 は **H4**(ABI バグ → 最優先修正 + ABI ファジングに再発防止ケース追加) | ABI 不一致は SEGV 直結の最重要リスク(DESIGN 7 章)。ファジング(下記)で網羅的に炙り出す |
| `wchar_t` typedef 符号性、long double = double による max_align_t 相違 | **feature-gated**(ワイド文字対応時 / x87 80bit 対応時) | いずれも該当機能を意図的に未対応(診断で拒否 / DESIGN 3.3 既知制限)としているため、当該機能に着手するまで観測不能。H4 でワイド文字/long double を使う gem が有意に落ちるなら前倒しを判断 |
| DoS フェイルセーフ上限値の再調整 | **H4**(コーパス R10 実測で再調整) | docs/security-dos-review.md 記載。極浅スタック環境の実測が入手できた時点 |
| ABI ファジングハーネス(Step 25/62)の機種パラメタ化、aarch64 全スイート + gem install 実走、musl/distroless コンテナ検証、sqlite3/pg コーパス | **H3**(QEMU の Docker マトリクス整備と併せて) | §8 M4 受け入れ・H3 参照。現環境に Docker/aarch64 Ruby が無いため、CI マトリクス整備が前提。ネットワーク/コンテナ依存はこの相に閉じる |

## 4. M1 実行計画 — **完了**

Step 28 で M1 の完了判定を満たした(c-testsuite 201/220 合格・失敗ゼロ、
`#include <ruby.h>` + rb_define_module / LONG2NUM を使う拡張ソースが ELF64 .o まで
コンパイル可能。test/test_ruby_smoke.rb が常時検証)。スモークテストは実システムの
glibc 開発ヘッダに対して行う(同梱ヘッダは B7/M5 スコープ)。棚卸しした不足は
§3 の負債表に記録済みで、筆頭(文式)は Step 40 で解消済み。

## 5. M2 — リンカと ar(json/msgpack を手動ビルド)

コンパイラと独立したコンポーネント群。M1 終盤(Step 26 のプリプロセッサ以降)と並行着手可。
以下の L1〜L8 は計画上のラベルで、**コミットの "(Step N)" は M1 と通しで完了順に採番する**
(並行開発で計画順と完了順がずれても混乱しないように)。

順序の方針: (1) 読み取り(ELF リーダ・ar)を先に作り、以降の全ステップのテストを
「自分で書いたものを自分で読み戻す + 実物(gcc/binutils の出力・システムの .so)を読む」
の両輪にする、(2) 静的リンクコアを `ld -r` 相当の再配置可能出力として先に単体検証し、
動的リンク(.so)の複雑さと分離する、(3) コンパイラ側の PIC 対応(L4)を .so ライタ(L5)の
前提として明示する。受け入れ基準は共通で「ユニットテスト + 実物との相互運用テスト +
既存テスト全 green」。

### ~~L1 — ELF リーダ~~ **完了(Step 29、96aefa6)**
計画どおり実装(ラウンドトリップ golden・gcc .o・readelf 突き合わせ・実物
libc.so.6)。PT_DYNAMIC フォールバックは計画どおり未実装(YAGNI)。
設計記録は STEPS.md の Step 29。

### ~~L2 — ar アーカイバ(rubycc-ar)~~ **完了(Step 30、1314bae)**
計画どおり実装(GNU 形式・`//` 長名・`/` インデックス常時生成・rcs/t/x CLI・
system ar と双方向相互運用・決定的出力)。設計記録は STEPS.md の Step 30。

### L3 — 静的リンクコア(セクション統合・シンボル解決・再配置適用)
- ~~前半(ld -r 併合)~~ **完了(Step 31、f4417c3)**: PartialLinker +
  汎用 RelocatableWriter。セクション結合・シンボル解決(strong/weak・
  multiple definition 診断・UND 残存許容)・再配置付け替え(セクションシンボル
  addend 補正)・アーカイブ遅延取り込み。設計記録は STEPS.md の Step 31。
- **後半(残り)**: 再配置の適用エンジン(R_X86_64_PC32 / PLT32 / 64 / 32 / 32S の
  バイトパッチ)。L5(.so ライタ)/L7(実行ファイル)が仮想アドレス配置とともに
  使うため、そちらのステップで実装する。

### ~~L4 — PIC データアクセス(コンパイラ側の前提対応)~~ **完了(Step 33、84be163)**
計画どおり実装(-fPIC で外部グローバル/関数のアドレス取得を GOT 経由
= R_X86_64_REX_GOTPCRELX に、TU 内定義・static・文字列は PC32 lea のまま、
呼び出しは PLT32 のまま)。新 IR op `:got_addr` を追加。gcc -fPIC の再配置種別
一致・非 PIC バイト不変・.so 化で TEXTREL なし + Fiddle 実地呼び出しを検証済み。
設計記録は STEPS.md の Step 33。

### L5 — 共有ライブラリライタ(.so)
- **第一段(自己完結 .so)= 完了(Step 34、77209d8)**: SharedLinker。3 PT_LOAD +
  PT_DYNAMIC + PT_GNU_STACK、静的再配置の適用エンジン(PC32/PLT32/32/32S、
  GOTPCREL 系はスロット生成、.data 絶対アドレスは RELATIVE)、.dynsym/.dynstr/
  SysV .hash/.dynamic、エクスポート、決定的出力。**Fiddle で dlopen して
  エクスポート関数を実呼び出し**するところまで検証済み。設計記録は STEPS.md の
  Step 34。
- **第二段(外部シンボル解決)= 完了(Step 35、6736c6c)**: 外部関数を
  PLT/GOT.plt/JUMP_SLOT、外部データを GLOB_DAT で import、DT_NEEDED
  (--as-needed 相当)・DT_SONAME、未解決 UND は残す。遅延バインドの複雑さを
  避け BIND_NOW を既定。**Fiddle dlopen で外部 libc 関数(strlen/puts/environ)を
  実呼び出し**まで検証済み。設計記録は STEPS.md の Step 35。
- **第三段(残り)**: **.gnu.hash**(ブルームフィルタ・バケット。公式仕様が薄いので
  binutils の出力を readelf で観察して外形を合わせる。実装コードは見ない: R11)。
  glibc は gnu.hash 優先・musl 対応も含め .hash と両方持つ安全側(DESIGN 5.3)。
  .hash のみでも dlopen は動く(Step 34/35 で実証済み)ので、これは適合性・
  性能の仕上げ。RELRO(.got.plt の読み取り専用化)もここで検討。
- 検証: readelf / eu-elflint 構造検査 + Fiddle dlopen 実呼び出しを glibc・musl
  両コンテナで CI 化(動的リンクの libc 差リスク: DESIGN 7 章の関所)。シンボル
  バージョン(GLIBC_2.x)は参照側で無版本解決される想定だが実物 libc.so で確認。

### ~~L6 — ライブラリ解決(-l / -L / DT_NEEDED)~~ **完了(Step 36、9bd39df)**
計画どおり実装(LibraryResolver: -L 探索順・.so 優先/.a フォールバック・
リンカスクリプト GROUP/INPUT/AS_NEEDED/OUTPUT_FORMAT 最小パーサ・.so/.a 振り分け・
推移閉包を辿らない)。-lz で実物 zlib を Fiddle 実行(crc32 既知値)・-lc の
libc.so スクリプト解決・gcc -shared -lz 一致を検証済み。設計記録は STEPS.md の
Step 36。

### ~~L7 — 実行ファイルと crt(conftest 用)~~ **完了(Step 37、f9ba9dc)**
計画どおり実装(ExecutableLinker: 非 PIE ET_EXEC + PT_INTERP、__libc_start_main
呼び出し方式の合成 crt _start、libc 既定 needed)。非 PIE で内部絶対再配置を
直接解決し RELATIVE 不要に。**__libc_start_main の無版本参照が実機 glibc 2.34+ の
デフォルト版に束縛され動作する(verneed 不要)ことを実証**、return 42→exit 42・
puts/printf・conftest try_run 風を実走で検証、gcc -no-pie と一致。設計記録は
STEPS.md の Step 37。musl での検証は L8 の M2 受け入れ(両コンテナ)で行う。

### L8 — ドライバ統合と M2 受け入れ
- ~~exe/rubycc を gcc 互換ドライバに拡張(R6)~~ **完了(Step 38、e9b48a7)**:
  複数入力・一気通貫・-shared・-c・-o・-l/-L・-Wl,・-fPIC・-D/-U・-E・
  -O 等の受理・未知フラグ警告のみ。lib/rubycc/driver.rb にクラス化、exe は薄い
  起動役。中間 .o をメモリ経由で作らない。実物 -lz 一気通貫・複数 TU 実行ファイルが
  gcc 一致。設計記録は STEPS.md の Step 38。
- ~~最小 C 拡張の require 実行受け入れ~~ **完了(Step 39、8e5f8f1)**: rubycc
  ドライバ単体で -shared -fPIC ビルドした C 拡張を Ruby から require して実際に
  呼べることを常設テスト化(単一 TU・gcc 一致・複数 TU)。M2 受け入れの土台。
- ~~文式 `({ … })` サポート(M1 追補・最優先負債)~~ **完了(Step 40、4466e68)**:
  一次式で `(` の直後が `{` のとき複合文をパースし最後の式文の値・型を採る文式を
  実装(`?:` の片側 void アーム対応込み)。ruby.h の TypedData_Make_Struct /
  Data_Make_Struct / rb_intern の展開先が通る。c-testsuite 00213/00214 合格。
  設計記録は STEPS.md の Step 40。
- ~~同梱 freestanding ヘッダと既定インクルードパス(M2 追補・gcc 依存の排除)~~
  **完了(Step 41、6ac0586)**: gem ルート直下 include/ に stdarg/stddef/stdbool/
  stdalign/iso646/stdnoreturn/float を同梱し、既定インクルードパス(同梱 → libc)に
  自動注入。gcc の内部 include ディレクトリへの依存を完全排除。`__need_*` 部分
  インクルード規約対応。`-nostdinc` 新設。Box(TypedData)拡張が CRuby ヘッダのみで
  .so 化 → require → `[1,2,3]` を常設化。設計記録は STEPS.md の Step 41。
- ~~`__builtin_offsetof` / 定数文脈 offsetof(M2 追補)~~ **完了(Step 42)**:
  `__builtin_offsetof(type-name, member-designator)` を lexer → AST → parser →
  ConstantEvaluator(定数文脈)→ generator(実行時)の全層で実装。ネスト
  `.name`・添字 `[expr]`・匿名メンバ対応、ビットフィールドは診断。同梱 stddef.h の
  offsetof を __builtin_offsetof 展開へ変更し、static 初期化子・配列サイズ・
  case ラベルで使えるようにした。設計記録は STEPS.md の Step 42。
- **M2 受け入れの最終形(残り、次ステップ)**: json と msgpack を「extconf.rb が
  生成した Makefile のコマンドを
  手動で rubycc に置き換えて」ビルドし、**gem 自身のテストスイートに合格**。
  glibc / musl 両コンテナで確認。
- 検証環境の前提: この時点では同梱 libc ヘッダ(R8)が無いので、
  「Ruby ヘッダ + libc 開発ヘッダが存在する通常のビルドコンテナ」で検証してよい
  (プリプロセッサの既定インクルードパスに /usr/include を許す)。ヘッダレス環境
  (distroless)対応は M5 の同梱ヘッダで達成する。
- ここで初めて ruby.h の全機能(varargs・関数ポインタ・GNU 拡張・ビットフィールド)が
  実物で検証される。露見した M1 の残穴は棚卸しして「M1 追補ステップ」として
  通し番号で処理する。

## 6. M3 — ビルド統合(rmake / rubygems_plugin / pkg-config / conftest)

M2 完了(手動ビルドが通る状態)が前提。ラベル B1〜B7 は計画上の識別子で、
コミットの "(Step N)" は完了順の通し採番(M2 と同じ規則)。

順序の方針: (1) 一次資料は「実物の mkmf が生成した Makefile と conftest」。着手前に
代表 gem(json / msgpack / sqlite3 / pg / racc / redcarpet)の extconf.rb を実行して
生成物(Makefile・mkmf.log・conftest ソース)を採取し、**test/fixtures にコーパス化**
してから逆算で機能セットを決める。仕様書(POSIX make)から演繹しない — mkmf が
生成しないものは作らない。(2) rmake 単体 → 実行器 → in-process 統合 → mkmf 対話、
の順に外側から内側へ進める。

### B1 — rmake コア(Makefile パーサと依存グラフ実行)
- mkmf 生成 Makefile のサブセット: 変数代入(= := ?= +=)、変数展開(`$(VAR)`/`${VAR}`、
  ネスト、mkmf が実際に使う関数のみ)、明示ルール、**旧式サフィックスルール
  (`.c.o:` 形式。mkmf は `.c.$(OBJEXT)` を生成する)**、.PHONY、VPATH
  (mkmf は `VPATH = $(srcdir)...` を出すので必要)、行継続、コメント。
  条件分岐(ifeq 等)は mkmf が出さない限り実装しない。
- タイムスタンプ比較による再ビルド判定と依存グラフのトポロジカル実行。
- **検証**: 採取した実物 Makefile 群を「パース → 実行計画(どのコマンドをどの順で
  走らせるか)のダンプ」にして golden テスト化。GNU make の -n 出力との突き合わせ。

### B2 — 内蔵コマンド実行器(シェルレス)
- ミニマム環境に /bin/sh が無い前提(R5)で、レシピを自前解釈する:
  単純コマンド、`&&`、`;`、リダイレクト(> 2> >>)、`cd`、`VAR=x cmd` 前置、`@`(非表示)、
  `-`(エラー無視)。パイプ・サブシェル・ワイルドカード展開は mkmf レシピに出ない限り
  非対応(出たらここに追記して拡張)。
- 頻出ユーティリティの内蔵実装(FileUtils ベース): rm -f / mkdir -p / cp / install /
  echo / true(`$(NULLCMD)`)。PATH に実物があればそれを使う選択肢もあるが、
  **無い前提の内蔵実装を正**とし、外部コマンドは最後の手段にする。
- **リスク**(DESIGN 7 章): extconf.rb が xsystem で任意の sh 構文を使う gem は
  カバーしきれない。実行器が解釈できない構文は「gem 名 + レシピ」を記録して明確に
  失敗させ、README のスコープ外リストへ反映する運用にする。
- **検証**: 採取レシピの再生テスト(ファイルシステム効果の突き合わせ)。

### B3 — in-process ツール呼び出しと並列ビルド
- レシピ中の `$(CC)` / `$(LD)` / `$(AR)` を認識して rubycc / rubycc-ar の**内部 API 呼び出し**
  に置換(プロセス起動レス: DESIGN 5.4)。コンパイラ側に「argv を受けて例外で失敗を返す」
  再入可能なエントリポイントを整備する(グローバル状態を持たないこと — fork 並列と
  in-process 実行の両立条件)。
- -j 並列: 依存グラフの独立ノードを Process.fork で並列コンパイル(Linux 前提: DESIGN 6 章)。
  ジョブサーバは実装しない(単一 Makefile 内の並列で十分)。
- **トレードオフ**: in-process 化はコンパイラのバグが rmake ごと落とすリスクと引き換え。
  fork 子プロセス内で実行すれば隔離と並列を同時に満たせるので、既定は
  「fork + in-process」のハイブリッドとする。
- **検証**: json 実物の Makefile を rmake で -j 込み実行し、gcc + make の成果物と
  同等の .so ができること。

### B4 — pkg-config シム(rubycc-pkgconf)
- 純 Ruby の .pc パーサ: 変数定義と展開、Name/Version/Cflags/Libs/Requires(.private)、
  Requires の再帰解決。CLI は mkmf の pkg_config() が呼ぶ形
  (--exists / --modversion / --cflags / --libs、複数モジュール)を一次資料にする。
- 検索パス: PKG_CONFIG_PATH → libdir 既定(/usr/lib/pkgconfig, /usr/lib/x86_64-linux-gnu/pkgconfig,
  /usr/share/pkgconfig 等をターゲット別に)。
- **検証**: システム実物の .pc(zlib, libffi 等)で pkg-config 本家と出力一致テスト。

### B5 — conftest 完全対応
- mkmf の have_header / have_func / have_library / have_macro / try_compile / try_link /
  try_run / check_sizeof / convertible_int が全部通ること。try_run は M2 L7 の
  実行ファイルが前提。
- mkmf は結果を conftest の**終了コードと mkmf.log** で判断する。ログに書かれる
  コマンド行の体裁も実物に寄せ、失敗時に人間が mkmf.log から原因を追える状態を守る(N3)。
- have_func のリンク検査は「未解決シンボルが残ると実行ファイルリンクが失敗する」性質に
  依存するため、L7 リンカの未解決検査の厳密さがここで効く(緩すぎると誤検出で
  機能が「ある」ことになり、gem が壊れる)。
- **検証**: 代表 gem の extconf.rb を RUBYCC 経由で走らせ、生成される Makefile /
  extconf.h が gcc 環境と同内容になること。

### B6 — rubygems_plugin 統合(ヘッダあり環境での gem install)
- rubygems_plugin.rb: `RUBYCC=1` 強制有効 / `RUBYCC=0` 無効 / 既定は「cc と make が
  PATH に無ければ自動有効」。有効時に ENV["MAKE"]=rmake、ENV["PKG_CONFIG"]=シムを注入
  (DESIGN 5.4)。プラグインは gem インストール時に必ず読まれるので、
  **無効時のオーバーヘッドと副作用をゼロに保つ**(判定だけして何もしない)。
- **受け入れ(第一段)**: libc 開発ヘッダのある通常コンテナ(ruby:slim + libc6-dev 相当)で
  `gem install json msgpack sqlite3 pg`(sqlite3/pg はシステムライブラリ利用構成)が
  素の `gem install` コマンドだけで成功し、各 gem の要求どおり動くこと。

### B7 — 同梱ヘッダ先行版と distroless 受け入れ
- **DESIGN の M3 受け入れ(distroless 相当で成功)には libc ヘッダが必要だが、
  R8 の同梱ヘッダ網羅は M5 スコープ**という計画上のギャップをここで埋める:
  M3 では「上記 4 gem(と ruby.h)が #include する範囲だけ」の同梱ヘッダ先行版を作る。
  ヘッダ設計方針(musl 派生かクリーンルームか、ディレクトリ構成、型幅の切替機構)は
  **M5 H1 の設計をこの時点で確定させて従う**(先行版が使い捨てにならないように)。
- **受け入れ(最終)**: cc / make / sh / libc ヘッダの無い distroless 相当イメージ +
  システム .so(libz, libsqlite3, libpq)ありの構成で `gem install json msgpack sqlite3 pg`
  が成功 = **M3 完了**。glibc / musl 両方。
- **M3 完了時の成果物(ユーザ指示、2026-07-17)**: 実装済み C 言語仕様の網羅
  ドキュメントを 2 部作成する。
  1. **C11 カバレッジ**: **N1570(ISO/IEC 9899:201x Committee Draft、DESIGN §9.1 に
     原典 URL 記載)の章番号・見出しをベース**に、各条項の「実装済み / 部分実装
     (制限内容)/ 非対応(診断)/ スコープ外」を一覧化。配置先は
     docs/C11-COVERAGE.md(新規)を想定。
  2. **gcc 拡張カバレッジ**: 実装した gcc 拡張(文式・名前付き可変長マクロ・
     カンマ削除・`__builtin_*` 群・`__has_*`・`__attribute__`・別名キーワード・
     2進リテラル・`__asm__` バリア・`case` 範囲等)を、**実装の仕方を含めて**
     一覧化する — 「意味論まで正確に対応」(例: 文式・ビットスキャン)/
     「受理するが実体は何もしない」(例: `__builtin_unreachable` の無コード、
     x86intrin.h 空スタブ、多くの `__attribute__`)/「正直に非対応と答えて
     フォールバックへ誘導」(例: `__has_builtin` の 0)の別を明記。配置先は
     docs/GCC-EXTENSIONS.md(新規)を想定。
  §3 の負債表・test_c_suite.rb のスキップ表・STEPS.md の設計記録が原資料。
- **M3 完了後のツール(ユーザ指示、2026-07-17)**: Ruby アプリケーション開発者が
  **rubycc を採用できるかを確認できるコマンド**(仮称 `rubycc doctor`)を作る。
  1. **入力**: Gemfile(/ Gemfile.lock)。使用 gem のうち C 拡張を持つものを抽出。
  2. **一次判定**: rubycc リポジトリ附属の「**ビルド確認済み gem データ(JSON)**」
     (gem 名・バージョン範囲・確認日・確認環境・既知の注意点を持つ。**このデータも
     別途作成する** — コーパス CI の結果から生成する運用を想定)をまず参照する。
  3. **二次判定**: 確認済みデータに無い gem は、**依存関係を含めてその場で
     rubycc ビルドを試行**し、成否・失敗箇所(コンパイル/リンク/require のどこで
     何が出たか)をコマンド実行者にレポーティングする。
  4. 出力: gem ごとの 判定(確認済み / その場ビルド成功 / 失敗(理由))の一覧と、
     アプリ全体としての採用可否サマリ。
- **M3 完了後のベンチマーク(ユーザ指示、2026-07-18)**: rubycc がビルドした
  バイナリと gcc ビルドの**実行速度比較**を実施し、**ベンチマークのコードと
  結果ドキュメントの両方をリポジトリにコミット**する。
  1. **対象**: (a) C 言語だけのプログラム(計算カーネル等の代表数種)、
     (b) json / msgpack の C 拡張を使う Ruby プログラム(parse/generate・
     pack/unpack の実ワークロード)。
  2. **rubycc が劣位になるケースを必ず含める**(rubycc は -O0 相当・最適化なし。
     DESIGN N2 は gcc -O2 比 2〜5 倍遅を許容と規定 — その実測確認でもある)。
     tight loop の計算カーネル等、最適化の効く形が劣位の代表になる想定。
  3. 出力: ベンチコード(tools/ or benchmark/ 配下)+ 結果ドキュメント
     (実行環境・コンパイルフラグ・各ケースの実測値と倍率・考察を含む)。

## 7. M4 — aarch64 バックエンド

ラベル A1〜A5 は計画上の識別子(コミット採番規則は M2 と同じ)。M1〜M3 の x86_64 実装が
安定していることが前提で、**「x86_64 で規約化したもの(値表現・IR・テスト)を第二の
バックエンドが検証する」**マイルストーンでもある — IR やテストハーネスに x86_64 の
暗黙の仮定が漏れていればここで露見する。

### A1 — バックエンド抽象化リファクタ(x86_64 のみで完結)【済: Step 68】
- Backend の契約「IR::Function → Result(bytes / symbols / relocations)」を明文化し、
  リロケーション kind(:call / :string / :global / :got)を**機種非依存の語彙**として
  固定する。ELF ライタは kind → 機種別リロケーション型(R_X86_64_* / R_AARCH64_*)の
  マッピングテーブルを持ち、e_machine をパラメタ化。
- ドライバにターゲット選択を追加(既定はホスト検出: RbConfig::CONFIG["host_cpu"])。
- **このステップは挙動変更ゼロ**: x86_64 の全テストが green のまま、という受け入れ基準が
  リファクタの正しさの定義。aarch64 のコードは一行も書かない。

### A2 — aarch64 コーデジェン・コア【済: Step 70】
- 固定長 32bit 命令のエンコーダ(即値の合成は MOVZ/MOVK、比較結果は CSET)。
- spill-everything の移植。**フレームレイアウトは x86_64 と違い「sp からの正オフセット」で
  スロットを参照する**設計にする: AArch64 の ldr/str 即値は「スケール済み非負 12bit」が
  基本で、fp(x29)からの負オフセット参照は 9bit 非スケール(-256〜255)しか使えず
  すぐ溢れるため。溢れる大フレームは加算でアドレスを合成する経路を最初から用意する。
- 32bit 演算は w レジスタで行い C int のラップアラウンドを再現(x86 の eax と同じ理屈)。
  値表現規約(スロット 8 バイト・拡張済み)はそのまま適用。
- AAPCS64 の整数引数 x0-x7(SysV の 6 個より多い)、戻り値 x0、スタック 16 バイト整列。
- 分岐: B(±128MB)/ B.cond(±1MB)。関数内ジャンプは rel 幅が十分なので
  x86 と同じバックパッチ方式でよい。
- **受け入れ**: 制御フロー・算術・関数呼び出しまでの既存実行テストのサブセットが
  aarch64 で green(グローバル・文字列は A3 まで除外)。
- **受け入れの実績(Step 70 + Step 71)**: Step 70 時点では開発ホストに実行環境が無く、
  命令エンコーディングの机上比較(ARM DDI 0487 のビットフィールド定義から組み立てた
  期待値)・関数構造・自作 ELF リーダによる統合確認の 3 層(テスト 42 件)に留まっていた。
  **Step 71 で qemu-user + クロス gcc を導入し、実行オラクルによる受け入れを達成**
  (差分実行テスト 34 件。バックエンドの実バグは検出されず、机上検証の妥当性が裏付けられた)。
  リンクとリファレンス実装にはクロス gcc を使う(自作リンカの aarch64 対応は A5)。
- **A2 で判明した持ち越し**: IR ジェネレータが引数を System V AMD64 の規則で分類して
  backend に渡すため、AAPCS64 の x0-x7(8 本)を活かせず実効 6 引数が上限。
  `:mem` はスカラ第 7 引数か MEMORY 構造体の eightbyte か区別できないため現状は拒否。
  **引数分類の per-target 化は A4 で行う**。

### A3 — メモリアクセスとリロケーション【済: Step 72 + 73 + 74】
- 幅つき load/store(ldrsb / ldrh / ldrsw / str の各幅。符号拡張ロードの規約は
  値表現規約と対応させる)。**A2 で実装・実行検証済み**(Step 70/71)。
- **素の `char` の符号性のターゲット化(§3 の債務)**: aarch64 Linux psABI では素の
  `char` は符号なし。現状は全ターゲット符号あり固定なので、型のターゲット記述に
  「素の char の符号性」を持たせて切り替える。x86_64 の挙動は変えないこと。
- グローバル・文字列参照: ADRP + ADD(R_AARCH64_ADR_PREL_PG_HI21 +
  R_AARCH64_ADD_ABS_LO12_NC のペア)。GOT 経由(L4 相当): ADRP + LDR
  (R_AARCH64_ADR_GOT_PAGE + R_AARCH64_LD64_GOT_LO12_NC)。
  呼び出し: BL + R_AARCH64_CALL26。**1 参照が 2 命令 2 リロケーションになる**点が
  x86(1 命令 1 リロケーション)と違うので、backend の relocation 記録と ELF ライタの
  対応付けをペア前提に拡張する。
- **受け入れ**: 既存実行テスト全件(gcc 差分込み)が aarch64 で green。
  .o を aarch64 の gcc/ld にリンクさせる相互運用も確認。
- **実績(Step 72)**: ペア・リロケーションの表現(kind → RelocDesc 配列 + offset_delta)、
  ADRP+ADD / ADRP+LDR、ELF リーダの型登録、差分実行テスト 23 件まで完了。
  クロス gcc/ld へのリンクと `readelf -r` での読み出しも確認済み。
  x86_64 は 68 サンプルでバイト一致(挙動変更ゼロ)。
  素の char の符号性のターゲット化は **Step 73 で完了**。
  既存実行スイートの aarch64 展開は **Step 74 で完了**: **c-testsuite 220 中 191 件通過**、
  examples 36 本中 26 本一致。残りはすべて A4 の未対応機能に由来する
  (間接呼び出し・浮動小数・struct コピー・alloca・bit-scan・varargs 定義)。
  この過程で x86_64 の暗黙の仮定に由来する実バグを 2 件検出・修正した
  (名前なしビットフィールドの整列規則、CPU 識別マクロのターゲット追従)。

### A4 — ABI 完全化(struct 値渡し・varargs・浮動小数)【済: Step 75〜78】
- 浮動小数と間接呼び出し = **Step 75 完了**(v0-v7、fadd/fcmp/scvtf 等、blr。
  c-testsuite の A4 保留 12 件中 11 件が通過)。
- スカラ引数分類の per-target 化 = **Step 76 完了**(`IR::CallConvention`。整数レジスタ
  6 対 8 の差を吸収し、aarch64 のスタック引数も実装。**c-testsuite の aarch64 保留が空に**、
  220 件中 203 件通過)。
- 集約分類のターゲット化 = **Step 77 完了**(`IR::CallConvention` の 2 実装、`AbiPiece` に
  オフセットと幅、HFA 判定、x8 間接返し、参照渡し、`:memcpy`。**silent miscompile を解消**。
  x86_64 は 254 ファイルでバイト一致)。
- 可変長関数の定義 = **Step 78 完了**(AAPCS64 の 5 フィールド va_list を
  `IR::CallConvention` でターゲット化。va_arg を別 lowering に、va_copy を新規実装。
  呼び出し側は Step 75/76 で対応済みだった)。
- **A4 の受け入れ達成**: c-testsuite 220 中 203 件通過(残り 17 件はターゲット非依存の
  既知債務)、examples 36 中 33 件一致(残り 3 件 = alloca・128 ビット乗算・bit-scan は
  aarch64 固有ではない既存の未実装機能)。x86_64 は各ステップで 254 ファイル規模の
  バイト一致を維持。**未達**: Step 25 の ABI ファジングハーネスの機種パラメタ化は
  未実施(現状は c-testsuite + examples + 専用差分テストで代替。ハーネスは
  ホスト gcc 前提でクロス経路を持たないため。A5 で QEMU マトリクス整備時に検討)。
- 残る既知の穴(§3): 可変長への struct 渡し(両ターゲットで診断)、スタック引数の
  16 バイト整列(x86_64 にも元からある)、`struct{float,float}` 以外の HFA は解消済み。

### A5 — リンカ対応と M4 受け入れ
- **実行ファイルリンカ + crt = Step 79 完了**: 自作リンカ・自作 crt(_start)で
  aarch64 実行ファイルを生成し qemu で実行(クロス gcc 不要)。crt の
  __libc_start_main 規約・PLT スタブ・動的再配置型を実物で裏取り。x86_64 は
  実行ファイル・.so ともバイト一致。共有ライブラリリンクは明示拒否で次段へ。
- **共有ライブラリリンカ = Step 80 完了**: 自作リンカで aarch64 .so を生成し
  qemu 上で dlopen・関数呼び出し(C 拡張そのものの形)。SharedLinker は前段で既に
  機種化されており、実変更は supported_machines の拡大が核心。PLT は BIND_NOW で
  PLT0 不要。CompatRuntime の機種不整合も解消。x86_64 は .so バイト一致。
- **その後 M4 受け入れ**: aarch64 で全スイート + json/msgpack の gem install。
  gem install の完走には **qemu 上で動く aarch64 版 Ruby(mkmf/rake が動く環境)が必要**で、
  現環境には無いため未検証。**コンテナ/CI マトリクス整備時に対応**(musl 検証と同じ枠)。
  リンカ・コンパイラ側の成果物は aarch64 .so を正しく生成できる段階に到達済み。
- A4 から持ち越し: **ABI ファジングハーネス(Step 25/62)の機種パラメタ化**。現状は
  ホスト gcc 前提でクロス経路を持たないため、QEMU マトリクス整備と併せて対応する。
- **CI 環境のトレードオフ**(再掲): QEMU はどこでも動くが遅く、まれに実機と挙動が違う。
  既定は QEMU の Docker マトリクス、リリース前検証だけ実機。
- **CI 環境のトレードオフ**: QEMU(binfmt_misc)はどこでも動くが遅く、まれに実機と
  挙動が違う。既定は QEMU の Docker マトリクスとし、リリース前検証だけ実機
  (Apple Silicon 上の Linux か ARM ランナー)で流す二段構えにする。
- **受け入れ = M4 完了**: 全テストスイート + ABI ファジング + json/msgpack の
  gem install が aarch64(glibc/musl)で成功。

## 8. M5 — 互換ヘッダ・コーパス 90%・v1.0

ラベル H1〜H6 は計画上の識別子(コミット採番規則は M2 と同じ)。M5 は前半(H1〜H3)が
通常のステップ、後半(H4)が**コーパス駆動の反復フェーズ**(1 コミット 1 ステップの
リズムではなく、失敗 gem を潰す小さなコミットの束)になる点が他のマイルストーンと違う。

### H0 — musl 派生ヘッダのライセンス課題の整理(**M5 着手前の必須ゲート。ユーザ指示、2026-07-19**)【済: Step 81】
- **完了(Step 81)**: 成果物 docs/HEADER-LICENSING.md を作成。musl COPYRIGHT を原典確認し、
  下記論点 1 の前提(「著作権性が薄い」)は現行版で削除済みと判明 → 公開ヘッダの
  **omit 許可**(表示義務の免除)というより確実な根拠に依拠。30 ヘッダの由来台帳
  (freestanding 8・musl-derived 15・clean-room 7)、glibc/UAPI の ABI 事実が
  非著作権であることの整理、今後のワークフローを文書化。是正 3 点(gemspec に NOTICE 追加=
  gem build で同梱を実地確認、errno.h/sys/stat.h の由来明記、NOTICE 本文の更新)も実施。
  以下の当初論点はすべて docs/HEADER-LICENSING.md で解決済み。
- M4 完了後・M5(ヘッダ大量拡充)着手前に、**H1 の「musl からの派生」のライセンス上の
  課題をクリアにする**。Step 63/64 で既に少数の musl 派生ヘッダを NOTICE 付きで同梱して
  いるが、M5 で対象が大きく広がる前に体制を確定させる。
- 整理すべき論点(成果物: docs/HEADER-LICENSING.md + 必要なら NOTICE/LICENSE/gemspec の是正):
  1. musl の MIT ライセンス条文の義務(著作権表示とライセンス文の保持)を、gem 配布物
     (gem パッケージ・リポジトリ)の中でどう満たすか — NOTICE 方式で足りるか、
     LICENSE ファイルへの併記や各ヘッダ冒頭表記の要否。musl の COPYRIGHT ファイルが
     「ヘッダ群の大部分は著作権性が薄い(fall outside the copyright)」と述べている範囲と、
     著作権性が認められうる範囲の区別。
  2. 「派生」の程度の記録: どのファイルが musl 由来でどれがクリーンルームかの
     ファイル単位の台帳(現状は各ヘッダ冒頭コメント。台帳化して監査可能に)。
  3. glibc ABI への改変が「glibc からの派生」を構成しないことの確認と明文化
     (実測値・ABI 仕様(psABI)由来の数値は著作物のコピーではない、という整理。
     glibc ヘッダ実物のコピー禁止の運用ルールを再確認)。
  4. rubycc 自身のライセンス(gemspec の license 表記)と同梱物の整合、
     受領者に伝わる形(gem パッケージに NOTICE が含まれるか)の検証。
- 疑義が残る項目は「クリーンルームで書き直す」判断を含めて解消し、H2 以降の
  ヘッダ追加手順(由来の記録・NOTICE 更新)をワークフロー化する。

### H1 — 互換ヘッダ基盤(設計確定。M3 B7 の前に確定させる)【基盤確定: x86-64 側 Step 62-64、aarch64 側 Step 82】
- **aarch64 ABI 層(Step 82)**: `include/libc/glibc/aarch64/` 全 11 本を追加。8 本は
  x86-64 版と宣言・値がバイト一致(`cmp` 確認済み)、実 ABI 差分を持つのは 3 本のみ —
  `sys/types.h`(nlink_t/blksize_t=32bit)・`sys/stat.h`(struct stat 実測 128 バイト・
  並び替え)・`stdint.h`(WCHAR_MIN/MAX が unsigned)。差分はクロス gcc で実測。探索パスは
  `Preprocessor#initialize(libc_arch:)` で切替(既定 x86-64 は従来とバイト同一、
  TARGETS の `libc_arch` から供給)。**ABI ハーネスを machine-parameterize**:
  `run_abi_case_aarch64`(rubycc -target aarch64 → クロス gcc -static → qemu、オラクルは
  クロス gcc)+ `TestHeaderAbiAarch64`(12 ケース green)。これで H2 受け入れの
  「glibc × 2 arch」軸のうち **glibc×{x86-64,aarch64}** が実証済み。残: musl 層は H2 以降。
- **由来の方針決定**(DESIGN R8): 第一候補は musl(MIT)からの派生 + NOTICE への
  ライセンス表記。派生の定義を決めておく — 宣言・型定義・マクロ値は musl を出発点に、
  glibc ターゲットでは**型幅・構造体レイアウト・マクロ値を glibc ABI に一致させる改変**を
  加える(glibc ヘッダ実物は LGPL かつ複雑で同梱できない)。判断に迷う箇所は
  クリーンルームで書き直す方が安全、という優先順位も明記。
- ディレクトリ構成: `headers/freestanding/`(stddef/stdarg/stdbool/stdint/limits 等。
  コンパイラと密結合な va_list・size_t はここ)+ `headers/libc/`(共通宣言)+
  `headers/libc/{glibc,musl}/{x86_64,aarch64}/`(型幅・レイアウトの切替層)。
  freestanding 層は libc に依存しないので**必ず自前で書く**(musl 由来にしない)。
- コンパイラの既定インクルードパス組み込み(-nostdinc / -I の優先順位、
  `#include_next` の実装 — 実ヘッダ併用逃げ道: DESIGN 7 章)。
- **ABI 一致の検証機構をヘッダより先に作る**: 同じ検査ソース(sizeof / offsetof /
  _Alignof / マクロ値を印字)を「gcc + 実ヘッダ」と「rubycc + 同梱ヘッダ」で
  コンパイル・実行して突き合わせる自動ハーネス。以降のヘッダ追加はすべて
  このハーネスのケース追加とセットで行う(ヘッダの正しさを目視に頼らない)。

### H2 — libc ヘッダ第一陣【進行中: Step 83〜】
- **範囲の実測(Step 83)**: ホスト ruby.h(rbenv 3.4.5)を hermetic `-E` した結果、
  **ruby.h の Linux/glibc #include 閉包は既存の同梱セットだけで完全解決**していた
  (未同梱ヘッダを含めば「No such file」で落ちる negative control 済み)。よって H2 の
  不足は ruby.h 側でなく **gem 拡張の .c / mkmf conftest が直接 include するヘッダ**にある。
  実測で未同梱だったのは `signal.h` `fcntl.h` `poll.h` `pthread.h` `sys/socket.h`
  `sys/mman.h` `dlfcn.h`(以降のステップはこの実測リストと、H3 のコーパス集計で駆動する)。
- **追加済み**: `fcntl.h`(Step 83、arch 層。O_DIRECT/DIRECTORY/NOFOLLOW が arch 差)、
  `poll.h`(Step 84、共通層)、`dlfcn.h`(Step 85、共通層。glibc 動的リンク ABI)、
  `sys/mman.h`(Step 86、共通層。PROT_/MAP_/MS_/MADV_)、`signal.h`(Step 87、共通層。
  siginfo_t/struct sigaction の union を実測 offsetof で再現)、`sys/socket.h`(Step 88、共通層。
  sockaddr/msghdr 等を実測 offsetof で再現)、`netinet/in.h`(Step 89、共通層。sockaddr_in/in6・
  IPPROTO_/INADDR_。arpa/inet.h と共有ガードで共存)、`netinet/tcp.h` + `sys/un.h`(Step 90、共通層。
  TCP_ オプション名 / sockaddr_un)。ABI ハーネスに `defines:`(_GNU_SOURCE 等をヘッダ include 前に
  注入。glibc の `__USE_XOPEN`/`__USE_MISC`/`__USE_GNU` ゲート面を rubycc のフラット面と
  apples-to-apples 比較するため)を追加 — 以降の GNU 拡張ヘッダで再利用。
  **ソケットヘッダ群(sys/socket・netinet/in・netinet/tcp・sys/un・arpa/inet)は一通り完成**。
  `pthread.h`(Step 91、arch 層。opaque 型を実測サイズの不透明 blob で再現。mutex_t 40/48 等が arch 差)も追加。
  **これで hermetic census で判明した未同梱ヘッダ(signal/fcntl/poll/pthread/sys-socket/sys-mman/dlfcn)は
  すべて充足**。以降のヘッダ追加は H3 のコーパス集計でデータ駆動に切り替える(推測での追加を止める)。
- 対象範囲: ruby.h 一式と主要 gem(json / msgpack / bigdecimal / date / racc /
  redcarpet / puma)が #include する範囲(stdio / stdlib / string / errno / ctype /
  math / time / signal / sys/types / sys/stat / fcntl / unistd あたりが実測での中心)。
  範囲は推測でなく、**コーパスの #include を集計して決める**。
- off_t / time_t 等の型幅、errno の実体(glibc: __errno_location、musl: 同名関数)、
  FILE の不透明扱い(構造体の中身は見せない — レイアウト互換の負担を避ける)など、
  **「ABI に効く最小限だけ正確に、それ以外は不透明に」**を設計原則にする。
- **受け入れ**: H1 の ABI 一致ハーネスが対象ヘッダ全域で green(glibc/musl × 2 arch)。
  B7 の先行版ヘッダをこの体系に統合し、M3 の受け入れが維持されること。

### H3 — コーパス CI 基盤【進行中: Step 92〜】
- **#include 集計ツール(Step 92)完了**: `test/corpus/`(gems.rb 選定リスト・census.rb・
  `rake corpus:census`・スナップショット include-census.md・hermetic テスト)。実 gem の C 拡張
  #include を集計し同梱ヘッダとの差分をデータ駆動で可視化。オンデマンド dev タスクで `rake test` は
  ネット不要のまま。初回ベースライン(json/msgpack/bigdecimal/date/racc/redcarpet)では機械的に
  追加必須なヘッダは無し(ギャップ候補 7 本は全て SIMD/Windows/C++/have_header ゲート下)。
  **残(この環境では不可)**: Docker マトリクスでの gem install/テスト実走(下記)。ネットワーク gem
  (puma/pg 等)や sqlite3/pg をコーパスに追加する際は census を再実行してスナップショットを更新する。
- 対象 gem の選定を自動化: rubygems.org ダウンロード上位から R10 基準
  (C++ 不使用・実体 asm 不使用・configure 非依存)を機械判定(拡張子・extconf.rb の
  mini_portile / configure 呼び出し検出)でフィルタし、**選定リスト自体をリポジトリに
  コミット**する(再現性のため。手動除外には理由を併記)。census.rb が C++/configure 検出を実装済み。
- マトリクス実行: glibc/musl × x86_64/aarch64 の Docker で各 gem を
  `gem install` → gem 自身のテストスイート実行。結果を機械可読(JSON)で集計し、
  **失敗を 4 分類**(ヘッダ不足 / 言語機能不足 / ABI バグ / rmake・conftest 非互換)する
  レポートを出す — H4 の反復はこの分類が駆動する。
- **受け入れ**: コーパス全 gem の初回実測レポートが出ること(この時点の合格率は
  問わない。ベースラインの確定が目的)。

### H4 — コーパス駆動の穴埋め反復(合格率 90% まで)【進行中: Step 93〜】
- **進行中(Step 93〜)**: この環境では Docker マトリクスは無いが、ホスト(glibc x86_64)で
  `RUBYCC=1 gem install <corpus gem>`(既存の mkmf_shim 機構)を直接回すことで H4 の反復は実行可能。
  bigdecimal のビルドを回し、(1)`extern T name[];` の拒否バグを Step 93 で修正 → 突破、
  (2)次に `__int128` の値渡し未対応(§3 の 128 ビット負債)に到達 → **Step 94 で解消**
  (16 バイト集約 ABI 経路 + 16 バイト整列 pad 機構。ついでにスタック 16 バイト整列負債と
  AAPCS64 偶数レジスタペアのバックエンド未配線も同時に解消)、(3)次に `bits.h` の
  `x >> 64`(128 ビットシフト)に到達 → **Step 95 で解消**。これで `bigdecimal.c` は
  コンパイル通過、(4)`missing/dtoa.c:656` の `hi0bits(register ULong x)` —
  パラメータの `register`(C11 6.7.6.3 ではパラメータに限り合法)→ **Step 96 で解消**、
  (5)同 `dtoa.c:1373` の静的初期化子 `9007199254740992.*9007199254740992.e-256`
  (`tinytens[]` 表)— 浮動小数点の定数式が静的初期化子で畳み込まれない
  → **Step 97 で解消**。**これで bigdecimal はフルビルド達成**。
  以降、コーパス各 gem のビルドを回して落ちた箇所を順に H4 で潰す。
- **bigdecimal の受け入れ完了(Step 97 時点)**: `RUBYCC=1 gem install bigdecimal` が成功し
  `lib/bigdecimal.so` を生成(rmake/rubycc 経由を gem_make.out と mkmf.log で確認)。
  上流ソースのテストスイートを rubycc ビルドの `.so` に対して実走し
  **265 tests / 8,267 assertions / 0 failures / 0 errors**(11 件は
  `BIGDECIMAL_USE_VP_TEST_METHODS` 未設定による正常な omission)。
  コーパス gem のテスト全合格は json に続き 2 例目。
- **redcarpet 3.6.1 の受け入れ完了(Step 98)**: `RUBYCC=1 gem install redcarpet` を回し、
  順に現れた4ブロッカーを **Step 98** で解消 —(a)`<string.h>` が `<strings.h>` を
  引き込む(`strncasecmp`)、(b)`<ctype.h>` の `isascii`/`toascii`、(c)括弧付き宣言子内側の
  推論サイズ `[]`(`int (*fp[])(int) = {...}`)、(d)指し先の符号性差ポインタの受理
  (`uint8_t*` → `strncmp`。§3 の char*/signed char* 負債も同時解消)。上流 v3.6.1 の
  test/unit スイートを rubycc ビルドの `.so` に対して実走 → **136 tests / 206 assertions /
  0 failures / 0 errors / 0 skips**。テスト全合格 3 例目。
- **msgpack 1.8.3 はコンパイラ無改修で通過(Step 98 時点で確認)**: `RUBYCC=1 gem install msgpack`
  がそのままフルビルド、上流 v1.8.3 の MRI spec(Rakefile の `spec/{,cruby/}*_spec.rb`)を実走 →
  **468 examples 中、失敗は JRuby 専用 `spec/jruby/` の 13 件のみ = MRI 対象は全パス、pending 1**。
  テスト全合格 4 例目(既存機能のみで到達)。
- **racc 1.8.1 はコンパイラ無改修で通過(Step 99 時点で確認)**: `RUBYCC=1 gem install racc` で
  cparse.so を rubycc がビルド(`Racc_Runtime_Type = c` で C ランタイム稼働を確認)、上流 v1.8.1 の
  test/unit スイートを実走 → **71 tests / 319 assertions / 0 failures / 0 errors**(生成物
  `lib/racc/parser-text.rb` は rmake ビルド生成物から補完)。テスト全合格 5 例目。
- **date 3.5.1 のビルドを継続中**(ブロッカーを順に解消):Step 99 で多次元配列
  (`monthtab[2][13]`)、Step 100 で配列境界の `sizeof(式)`(`char fmt[sizeof(timefmt)+...]`、
  パーサの通常名スコープに変数型を持たせて構文解析時に畳む)、Step 101 で静的初期化子の
  関数ポインタキャスト `(VALUE (*)(void *))m_real_year`(date_core.c:7159)を解消。
  **これで `date_core.c` はフルコンパイル達成**。次は Step 102 予定 = `date_parse.c` の
  `zonetab.h:32` の `#line` プリプロセッサ指令(6.10.4)。
- **受け入れ基準はビルド成功では不十分**: 「ビルドが通る」ことと「正しく動く」ことは別。
  gem がフルビルドに達したら **gem 本体のテストスイートを実走**して合否を取る
  (これが H4 の「合格率」の実体)。現時点でテスト全合格は json / bigdecimal / redcarpet /
  msgpack / racc の **5 例**(コーパス 6 gem 中 5)。残るコーパス gem: date(ビルド継続中)。
- **実測した運用上の制約**: コーパス 6 gem(json/msgpack/bigdecimal/date/racc/redcarpet)は
  **いずれも `.gem` パッケージにテストを同梱していない**(`gem spec files` で test/ spec/ が 0 件)。
  したがって「gem のテストスイートを走らせる」には `gem install` では不十分で、
  **各 gem のソースリポジトリ(GitHub の該当タグ)を別途取得**し、そこへ rubycc がビルドした
  `.so` を差し込んで実行する必要がある。コーパス CI を組む際はこの取得経路を前提にすること。
- **最初の実測結果(json 2.21.1)**: `RUBYCC=1 gem install json` で parser.so / generator.so を
  rubycc がビルド(rmake が MAKE、mkmf.log の CC が rubycc であることを確認)、その `.so` を
  上流ソースツリーへ差し込んで **json 本体のテストスイートを実走 → 606 tests / 3,433 assertions /
  0 failures / 0 errors / 0 skips で全合格**。rubycc 生成の C 拡張が実際に動作することを
  ビルド成功より一段強い水準で確認できた最初の事例。
- **§3.1 の「開いた負債の後続 STEP 割り当て」で H4 に割り当てた項目は、ここで解消する**
  (言語機能不足・128 ビット整数の演算残り・-fPIC PC32・DoS 上限再調整。
  ~~スタック 16 バイト整列・128 ビット値渡し~~ は Step 94、~~char*/signed char*~~ は Step 98 で
  解消済み)。コーパスに現れないものは v1.0 の「既知の制限」として H6 で README 記載。
- H3 の分類レポートに従って修正を反復する運用フェーズ:
  - ヘッダ不足 → H2 の体系に追加(ABI ハーネスのケースとセット)
  - 言語機能不足 → M1 と同じ流儀の追補ステップ(通し番号でコミット)
  - ABI バグ → 最優先で修正し、ABI ファジングに再発防止ケースを追加(DESIGN 7 章:
    ABI 不一致は SEGV に直結する最重要リスク)
  - rmake / conftest 非互換 → B1〜B5 の該当箇所に追記して拡張
- **`__GNUC__` 非定義方針(R7)の影響をここで実測**する: fallback パスが無くて落ちる
  gem が合格率を有意に下げるなら、「GCC 擬態モード」(M6 予定)の前倒しを判断する。
  判断材料(落ちた gem と原因マクロ)をレポートに残すこと。
- **受け入れ**: コーパス 90% が「install 成功 + gem テスト合格」(R10)。

### H5 — 性能(N1: 20,000 行/秒)
- まず**測定を整備**: 実 gem ソース(前処理後行数ベース)のベンチを rake タスク化し、
  YJIT 有無・主要 gem 別の数値を継続記録する。sqlite3 amalgamation(25 万行)は
  参考値として実測を記録(「動くが遅い」を許容: N1)。
- 定石の最適化を計測駆動で適用: 字句解析の strscan 化、プリプロセッサのトークン列
  キャッシュ(同一ヘッダの再 #include)、文字列連結・中間配列の削減、rmake -j の既定化。
  **推測で最適化しない — プロファイル(stackprof 等は開発時依存として可)が先**。
- **受け入れ**: YJIT 有効で 20,000 行/秒以上(代表 gem の中央値)。未達なら
  ボトルネックの分析と「v1.0 で許容するか」の判断を文書化。

### H6 — v1.0 リリース準備
- N1〜N7 の非機能要件をチェックリスト化して全項目確認(N4 決定的ビルドは
  「同一入力 2 回ビルドのバイナリ一致」を CI 化)。
- ドキュメント: README(対応範囲、既知の制限、R4 の「修正とみなすもの/みなさないもの」、
  distro Ruby での dev パッケージ要件: DESIGN 4.2)、LICENSE / NOTICE
  (musl 派生ヘッダの表記: R8)。
- rubygems.org へ公開、以降のバージョニング方針(セマンティックバージョニング、
  コーパス合格率の回帰を破壊的変更として扱う)を決めて記録。
- **受け入れ = v1.0 リリース = M5 完了**。

## 9. マイルストーン横断のリスク(DESIGN 7 章の運用)

- **ABI 不一致 = 最優先リスク**: Step 25 で導入する ABI ファジングハーネスを、以降の
  全バックエンド変更の回帰テストとして常時 CI で回す。
- **gcc 差分テストの限界**: gcc は開発 CI のみの依存(R2)。差分テストが使えない環境の
  ために、期待値を焼き込んだ golden テストも必ず併設する(現状の実行テストは両対応済み)。
- **`__GNUC__` 非定義の方針**(R7)は M5 のコーパスで初めて本当の影響が測れる。
  ビルド失敗の主因になるようなら「GCC 擬態モード」(M6)の前倒しを検討する。
