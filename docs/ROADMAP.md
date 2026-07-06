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

現在地: **M1 の途中、Step 13(struct)まで完了**。

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
   (計画から変わった点があれば ROADMAP 側も直す)。

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
  メンバアクセスはすべて脱糖で実現済み)。追加する場合は ir.rb のコメント一覧を必ず更新。
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
| ポインタ条件の拒否 | `if (p)` を診断エラーにしている(C では合法)。Step 9 の意図的逸脱 | Step 14 |
| ヌルポインタ定数 | `p = 0` / `p != 0` が型不一致エラーになる | Step 14 |
| `&配列` 未対応 | "address of array is not supported yet" | Step 21(関数ポインタと同時期に配列ポインタ型ごと) |
| 引数 7 個以上 | スタック渡し未実装で診断エラー | Step 21 |
| struct 値渡し・値返し | 診断エラーにして先送り | Step 25 |
| 内側スコープの `struct S;` 再宣言 | C 6.7.2.3p7 に従わず外側タグを参照 | 実害が出た時点 |
| 初期化子の制限 | 配列・struct の初期化子リスト未対応。グローバルは整数定数のみ | Step 20 |

## 4. M1 残りの実行計画(Step 14〜)

順序の方針: (1) C 適合性の逸脱を早く解消する、(2) 型システムの土台(整数型)を
struct 系の応用(union/enum/typedef)より先に固める、(3) ruby.h が要求する機能
(関数ポインタ・varargs・プリプロセッサ・GNU 拡張最小セット)を M1 後半に集める。
各ステップの受け入れ基準は共通で「新機能の実行テスト(gcc 差分込み)+ 診断テスト +
既存テスト全 green」。

### Step 14 — キャスト式・ヌルポインタ定数・スカラ条件
- cast-expression(`(型名)式`)。型名パースは sizeof(型名) の既存実装を一般化。
- 整数定数 0 → 任意ポインタ型の暗黙変換(ヌルポインタ定数)。比較(`p == 0`)・代入・
  引数・戻り値で許可。
- 条件位置のスカラ一般化: ポインタ条件を「0 との !=」に脱糖し、Step 9 の意図的逸脱を解消。
  ポインタは 64bit で test すること(32bit 切り捨てが元々の懸念)。
- **トレードオフ**: ポインタ⇔整数のキャストは intptr_t 級の整数型がまだ無いので、
  「同サイズになる将来ステップまで診断エラー」とするのが安全。
- 判断メモ: `(void)式`(値を捨てるキャスト)もここで対応(mkmf の conftest 頻出)。

### Step 15 — ビット演算子・シフト・カンマ演算子
- `& | ^ ~ << >>` と複合代入 `&= |= ^= <<= >>=`、カンマ演算子。
- ISO C の優先順位(inclusive-OR > exclusive-OR > AND > equality、shift は additive の上)
  にチェーンを挿入。`&`(単項)と `&`(二項)の既存パーサ分岐に注意。
- IR に :and :or :xor :shl :sar を追加(シフト量は cl レジスタ)。符号付き int なので
  右シフトは算術(sar)。unsigned 導入(Step 17)時に :shr を追加する前提で設計。

### Step 16 — switch・goto・ラベル文
- switch / case / default(6.8.4.2)、goto / ラベル(6.8.6.1, 6.8.1)。
- switch は「case 定数との比較チェーン + ジャンプ」への脱糖で十分(ジャンプテーブルは
  最適化であり M6 以降)。break はループと共通のコンテキストスタックに乗せる。
- goto はジェネレータに関数単位のラベル表(前方参照はバックパッチ)。
- ruby.h 由来のコードや gem(ragel/racc 生成コード)で switch/goto は頻出のため M1 必須。

### Step 17 — 整数型の拡張(long / short / unsigned / _Bool)
**M1 で最も影響範囲が広いステップ。単独で着手し、他と混ぜない。**
- 型: signed/unsigned × char/short/int/long(long long は LP64 では long と同幅なので
  エイリアスで受理)、_Bool。宣言指定子の組み合わせ(`unsigned long`、`long int` 等)を
  正規化するロジックをパーサに追加。
- 整数リテラル接尾辞(U/L/UL)と、値がはみ出す場合の型繰り上げ(6.4.4.1 の表)。
- 整数昇格・通常算術変換(6.3.1.8)をジェネレータの二項演算に実装。
- 値表現規約の拡張: スロット内は「64bit へ拡張済み(符号付きは符号拡張、無符号はゼロ拡張)」
  へ規約を持ち上げるのが一貫性が高い。32bit 演算の上位ゼロ化との整合を再点検すること。
- backend: 2 バイトの load/store(movsx/movzx word)、8 バイト演算の一般化(size=8 は既存)、
  無符号の div/mod(div)・右シフト(shr)・比較(setb/setbe/seta/setae)。
- **トレードオフ**: VALUE(unsigned long)を扱うために unsigned long は必須。_Bool は
  ruby.h の stdbool 利用に備えて小さく入れる(比較結果 0/1 の既存表現で足りる)。

### Step 18 — enum・typedef
- enum(定数はスコープ内の int 定数として登録、型は int 扱いで十分)。
- typedef: パーサのスコープに typedef 名前空間を追加。**識別子が型名かどうかで構文が変わる**
  (C の有名な曖昧性)ため、宣言の先頭判定 `type_specifier?` を「typedef 名の照会」込みに
  拡張する。字句解析器は変更しない(パーサ側で解決する方が既存分業と整合)。
- ruby.h は `typedef unsigned long VALUE;` を筆頭に typedef だらけなので Step 17 の直後に置く。

### Step 19 — union・無名 struct/union メンバ
- union: StructType の設計(恒等比較・可変・タグスコープ)をそのまま流用し、
  レイアウトだけ「全メンバ offset 0、サイズ=最大メンバ、アラインメント=最大」に変える。
- 無名 struct/union メンバ(C11 6.7.2.1p13): ruby.h の RBasic 系で使われるため M1 必須。
  メンバ解決を「無名メンバの中を透過的に探索」に拡張。

### Step 20 — 初期化子
- ローカル/グローバルの brace 初期化子リスト(配列・struct・ネスト)、
  `char s[] = "..."`、要素数省略(`int a[] = {...}`)、余った要素のゼロ埋め。
- グローバル側は「定数式 + アドレス定数(`&g`、文字列リテラル、関数名)」まで対応し、
  .data にリロケーション付き初期値を書けるよう ELF ライタを拡張(R_X86_64_64)。
- 指示付き初期化子(designated initializer、C99)は gem コードで頻出のためここに含める。
- **トレードオフ**: 静的初期化の定数畳み込みが要るため、パーサの定数評価器を
  ジェネレータ側の本格的な定数式評価(6.6)に置き換える。プリプロセッサの #if 評価
  (Step 26)でも同じ評価器を使う前提で設計すること。

### Step 21 — 関数ポインタ・間接呼び出し・スタック渡し引数
- 関数型と関数ポインタ宣言子(`int (*f)(int)`)、関数指示子の退化、`(*f)(x)` と `f(x)` の
  両呼び出し、関数ポインタの代入・引数渡し・struct メンバ格納。
- **rb_define_method 等の登録 API が全部関数ポインタを取るため ruby.h 対応の必須要件。**
- 宣言子パーサを ISO C の direct-declarator 再帰(括弧つき宣言子)に一般化する。
  ここで `&配列`(配列ポインタ型 `int (*)[N]`)も一緒に解消する。
- 引数 7 個以上のスタック渡し(呼び出し側 push、被呼び出し側は rbp+16 以降から読む)。

### Step 22 — 記憶クラス・型修飾子・その他宣言まわり
- static(ファイルスコープ: 内部リンケージ = ELF ローカルシンボル/関数スコープ:
  .data/.bss に一意シンボルで配置)、extern(宣言のみ)、const/volatile(受理して
  const の代入違反だけ診断、volatile は意味なしで受理)、inline(受理して無視)。
- _Static_assert、_Alignof。register/auto は受理して無視。
- mkmf の conftest と実際の gem コードで static/const は必須。

### Step 23 — 可変長引数(整数のみ)
- 呼び出し側: プロトタイプの `...`、可変部の引数のデフォルト実引数昇格、
  **al レジスタに使用 xmm 数(この段階では常に 0)をセット**して call。
- 定義側: va_list(SysV の reg_save_area 方式。struct 定義は同梱ヘッダで提供)、
  va_start / va_arg / va_end を __builtin_va_* として実装。
- rb_funcall / rb_raise(いずれも variadic)のために M1 必須。浮動小数の varargs は
  Step 24 で完成させる二段構え。

### Step 24 — float / double(SSE)
- 型・リテラル・変換(整数⇔浮動小数、float⇔double)、算術・比較。
- ABI: 引数 xmm0-7、戻り値 xmm0、varargs の al レジスタと reg_save_area の xmm 保存を完成。
- backend: SSE2 命令(movss/movsd/addsd/ucomisd/cvtsi2sd 等)のエンコード。
  スロット表現は「xmm から 8 バイトで store」に統一すれば既存フレームのまま。
- float の丸め再現は Ruby 側の定数畳み込みでのみ必要(`[x].pack('f').unpack1('f')`、
  DESIGN 6 章)。
- **トレードオフ**: bigdecimal / json 等は double を使うので M1 に含めるが、
  x87 80bit(long double)は double 扱いで確定(DESIGN 3.3)。

### Step 25 — struct の値渡し・値返し(R9 の中核)
- System V AMD64 の分類アルゴリズム(MEMORY / INTEGER / SSE、8 バイト単位の分類、
  16 バイト超は MEMORY、戻り値 MEMORY は隠れポインタ rdi + rax 返し)。
- **R9 が「最重要要件」と定めた領域**。gcc でビルドした呼び出し側と rubycc でビルドした
  被呼び出し側を相互リンクする ABI テスト(DESIGN 6 章テスト 3 の先行版)をこのステップで
  導入する。ランダムな struct レイアウトを生成して両方向で値を突き合わせるハーネスを作る。
- ここまでで「コンパイラ本体」の C11 サブセットはほぼ完成。

### Step 26〜27 — プリプロセッサ(2 ステップに分割)
**M1 の最後の大物。コンパイラ本体と独立に開発できるので、Step 25 までと並行着手も可。**
- **Step 26(コア)**: 翻訳フェーズ 1〜4 の再構成。プリプロセッサトークン化(既存 Lexer と
  別物として設計し、最後に既存トークンへ変換する)、#include(-I 探索、`"` と `<>`)、
  #define(オブジェクトマクロ)/#undef、#if/#ifdef/#ifndef/#elif/#else/#endif
  (定数式評価は Step 20 の評価器を流用)、#error、行番号の維持(診断の N3 を壊さない)。
- **Step 27(完成)**: 関数マクロ(引数展開・再スキャン・自己参照の青染め)、# と ##、
  可変引数マクロ(__VA_ARGS__)、定義済みマクロ(__FILE__ __LINE__ __STDC__ __RUBYCC__、
  **__GNUC__ は定義しない**: DESIGN R7)、__has_include / __has_attribute / __has_builtin、
  #pragma once。
- **設計方針**: マクロ展開のアルゴリズムは仕様(6.10.3)に忠実に、ただし実装の構成は
  独自に(R11)。展開の正しさは gcc -E との差分テストで検証する(トークン列比較)。
- **トレードオフ**: #line、_Pragma は使用頻度が低いので受理のみ・順次対応。

### Step 28 — GNU 拡張の最小セットと ruby.h スモークテスト
- __attribute__((...)) の構文受理(aligned/packed のみ意味を実装、他は無視)、
  __builtin_expect(素通し)、__builtin_alloca、__extension__、
  空テンプレートのインラインasm(`__asm__ volatile("" ::: "memory")`)の受理(DESIGN R7)。
- ビットフィールド: ruby.h と主要 gem での使用状況を調査し、必要なら実装、
  不要なら診断エラーのまま M2 へ進む(コーパスで再判定)。
- **M1 の完了判定**: (1) c-testsuite 等の外部テストスイートから本サブセット範囲の
  ケースを流用して合格、(2) ruby.h を #include した最小の拡張ソースが .o まで
  コンパイルできる(リンクは M2)。ここで見つかった不足(未実装の GNU 拡張・ヘッダ)を
  棚卸しして M2 と並行で潰す。

## 5. M2 — リンカと ar(json/msgpack を手動ビルド)

コンパイラと独立したコンポーネント。M1 終盤(Step 26 以降)と並行着手可。

- **L1: ELF リーダと ar**: 自前 .o の読み戻し(ラウンドトリップテスト)、外部 .so の
  ELF ヘッダ/.dynsym/DT_SONAME 読み取り、ar アーカイブ(`!<arch>`)の読み書き。
- **L2: 静的リンクコア**: 複数 .o のセクション統合・シンボル解決(強弱・COMDAT は当面
  非対応)・再配置適用(PC32/PLT32/64/32S)。
- **L3: 共有ライブラリ出力(.so)**: PT_DYNAMIC、.dynsym/.dynstr、**.gnu.hash と .hash の
  両方**(glibc/musl 両対応。DESIGN 5.3)、RELA(GLOB_DAT/JUMP_SLOT/RELATIVE)、PLT/GOT、
  DT_NEEDED(-l は対象 .so の .dynsym を読んで解決。開発ヘッダ不要: DESIGN 4.2)。
  - **PIC の設計判断**: Ruby 拡張は「Init_xxx をエクスポートし rb_* を未解決で残す」形なので、
    自 DSO 内のデータ参照は既存の PC32 直参照のままでよいか、GOT 経由が要るかを
    ここで確定する(コピー再配置は実行ファイルを作らない限り発生しない。
    テキスト再配置(DT_TEXTREL)だけは絶対に避けること)。外部シンボル参照は PLT/GOT 必須。
- **L4: 実行ファイルと crt**: conftest 用。PT_INTERP + 動的リンク実行ファイル、
  最小 _start(argc/argv → main → exit。Ruby 内で機械語合成: DESIGN 5.3 crt/)。
- **L5: 受け入れ**: json と msgpack を「extconf.rb が生成した Makefile のコマンドを
  手動で rubycc に置き換えて」ビルドし、gem のテストスイートに合格。
  ここで初めて ruby.h の全機能(varargs・関数ポインタ・GNU 拡張)が実戦検証される。
- **リスク**: 動的リンクの细部(ハッシュテーブル・シンボルバージョニングの受け側)は
  glibc/musl の挙動差が出やすい。両 libc の Docker イメージで dlopen できることを
  CI 化してから先に進む。シンボルバージョン(GLIBC_2.x)は「参照側としては無視できる」
  はずだが、L3 の設計時に必ず実物の libc.so で確認する。

## 6. M3 — ビルド統合(rmake / rubygems_plugin / pkg-config / conftest)

- **rmake**: mkmf が生成する Makefile のサブセット(変数展開・代入 4 種・ルール・
  自動変数 $@ $< $^・VPATH は不要)。レシピは /bin/sh を使わず内蔵実行器で
  「単純コマンド・&&・; ・リダイレクト・cd」を解釈(DESIGN R5)。$(CC) 等は
  in-process で rubycc 呼び出しに置換(プロセス起動レス: DESIGN 5.4)。-j は Process.fork。
- **rubygems_plugin**: `RUBYCC=1` 強制 / cc・make 不在時の自動有効化 / `RUBYCC=0` 無効化。
  ENV["MAKE"] / ENV["PKG_CONFIG"] の注入(DESIGN 5.4)。
- **pkg-config シム**: 純 Ruby .pc パーサ(Requires 再帰、--cflags/--libs/--exists)。
- **conftest 対応**: mkmf の have_header/have_func/try_link/try_run が全部通ること。
  try_run は L4 の実行ファイルが動くことが前提。
- **受け入れ**: distroless 相当のイメージ(cc/make/sh なし)で
  `gem install json msgpack sqlite3 pg`(sqlite3/pg はシステムライブラリあり構成)が成功。
- **リスク**: extconf.rb が xsystem で任意の sh 構文を使うケース(DESIGN 7 章)。
  内蔵実行器でカバーできない gem はスコープ外として README に列挙する。

## 7. M4 — aarch64 バックエンド

- 前提リファクタ: Backend を「IR → Result(bytes/symbols/relocations)」のインターフェイスで
  抽象化(現状ほぼ成立している)。ELF ライタの機種依存(e_machine・リロケーション型)を
  パラメタ化。
- AAPCS64: 引数 x0-x7 / v0-v7、戻り値 x0/v0、スタック 16 バイト整列、可変長引数は
  SysV と別方式(スタック上の名前なし領域)なので va_* を backend 別に実装。
- リロケーション: CALL26、ADRP + ADD_ABS_LO12_NC(グローバル・文字列参照)、
  リンカ側の対応も同時に。
- spill-everything の構造はそのまま移植できる(AArch64 は ldr/str のオフセット制約にだけ注意)。
- 受け入れ: 既存の実行テスト全件を aarch64(Docker/QEMU)で green に。ABI ファジングも両対応。

## 8. M5 — 互換ヘッダ・コーパス 90%・v1.0

- **互換ヘッダ**(DESIGN R8): musl(MIT)から派生させる案を第一候補とし、ライセンス表記を
  NOTICE に明記。glibc ターゲットでは「型幅・構造体レイアウトを glibc ABI に一致させた
  自前ヘッダ」を書く(glibc ヘッダ実物は同梱できない)。off_t/time_t 等の型幅は
  ターゲット別に切り替え。`#include_next` で実ヘッダ併用も可能にする(DESIGN 7 章)。
- **コーパス CI**: rubygems.org 上位の対象 gem(DESIGN R10 の選定基準)を実際に
  `gem install` → gem 自身のテストスイート実行、の Docker マトリクス
  (glibc/musl × x86_64/aarch64)。不足ヘッダ・未実装拡張はここで検出して漸進対応。
- **性能**(N1): YJIT 前提で 20,000 行/秒。プロファイルして字句解析の strscan 化、
  文字列連結の削減、TU 単位 fork 並列(rmake -j)を適用。
  sqlite3 amalgamation(25 万行)は「動くが遅い」を許容。
- **受け入れ = v1.0**: コーパス 90% 合格(R10)、N1〜N7 の非機能要件をチェックリスト化して
  全項目確認。

## 9. マイルストーン横断のリスク(DESIGN 7 章の運用)

- **ABI 不一致 = 最優先リスク**: Step 25 で導入する ABI ファジングハーネスを、以降の
  全バックエンド変更の回帰テストとして常時 CI で回す。
- **gcc 差分テストの限界**: gcc は開発 CI のみの依存(R2)。差分テストが使えない環境の
  ために、期待値を焼き込んだ golden テストも必ず併設する(現状の実行テストは両対応済み)。
- **`__GNUC__` 非定義の方針**(R7)は M5 のコーパスで初めて本当の影響が測れる。
  ビルド失敗の主因になるようなら「GCC 擬態モード」(M6)の前倒しを検討する。
