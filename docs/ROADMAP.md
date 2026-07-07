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
| ポインタ⇔整数キャスト | 0 以外は "cast between pointer and integer is not supported yet"。ポインタ幅の整数型が無いため | Step 17(long 導入時) |
| `&配列` 未対応 | "address of array is not supported yet" | Step 21(関数ポインタと同時期に配列ポインタ型ごと) |
| 引数 7 個以上 | スタック渡し未実装で診断エラー | Step 21 |
| struct 値渡し・値返し | 診断エラーにして先送り | Step 25 |
| 内側スコープの `struct S;` 再宣言 | C 6.7.2.3p7 に従わず外側タグを参照 | 実害が出た時点 |
| 初期化子の制限 | 配列・struct の初期化子リスト未対応。グローバルは整数定数のみ | Step 20 |

## 4. M1 残りの実行計画(Step 15〜)

順序の方針: (1) C 適合性の逸脱を早く解消する、(2) 型システムの土台(整数型)を
struct 系の応用(union/enum/typedef)より先に固める、(3) ruby.h が要求する機能
(関数ポインタ・varargs・プリプロセッサ・GNU 拡張最小セット)を M1 後半に集める。
各ステップの受け入れ基準は共通で「新機能の実行テスト(gcc 差分込み)+ 診断テスト +
既存テスト全 green」。

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

コンパイラと独立したコンポーネント群。M1 終盤(Step 26 のプリプロセッサ以降)と並行着手可。
以下の L1〜L8 は計画上のラベルで、**コミットの "(Step N)" は M1 と通しで完了順に採番する**
(並行開発で計画順と完了順がずれても混乱しないように)。

順序の方針: (1) 読み取り(ELF リーダ・ar)を先に作り、以降の全ステップのテストを
「自分で書いたものを自分で読み戻す + 実物(gcc/binutils の出力・システムの .so)を読む」
の両輪にする、(2) 静的リンクコアを `ld -r` 相当の再配置可能出力として先に単体検証し、
動的リンク(.so)の複雑さと分離する、(3) コンパイラ側の PIC 対応(L4)を .so ライタ(L5)の
前提として明示する。受け入れ基準は共通で「ユニットテスト + 実物との相互運用テスト +
既存テスト全 green」。

### L1 — ELF リーダ(.o の読み戻しと .so の動的シンボル読み取り)
- 自前 .o のフルパース(セクション・シンボルテーブル・RELA)。elf_writer との
  **ラウンドトリップ golden テスト**(書いたものを読んで同じ構造に戻ること)で
  ライタ・リーダ双方を相互検証する(N7)。gcc が出した .o も読めること。
- 外部 .so の読み取り: ELF ヘッダ、.dynsym / .dynstr、DT_SONAME。列挙は
  **セクションヘッダ経由(sh_size / sh_entsize)を第一経路**とする。alloc セクション
  (.dynsym 等)は strip では消えないため実運用で欠けることはほぼ無い。セクションヘッダの
  無い .so に当たったら PT_DYNAMIC(DT_SYMTAB + DT_HASH/DT_GNU_HASH からの個数導出)へ
  フォールバックを追加する(最初からは作らない: YAGNI)。
- 検証: readelf の出力(-s / -d)と突き合わせるテスト。システムの libc.so.6 実物を
  読んで printf 等のエクスポートが見えること。

### L2 — ar アーカイバ(rubycc-ar)
- GNU ar 形式: `!<arch>\n` マジック、60 バイトヘッダ、偶数境界パディング、
  長いファイル名の `//` 拡張名テーブル、シンボルインデックス `/`(ranlib 相当を
  書き込み時に常時生成)。BSD 形式は対象外。
- exe/rubycc-ar CLI は mkmf が叩く `$(AR) rcs` を最優先で(r/c/s/t/x を実装)。
- 用途は vendored ライブラリの静的リンク(R5)。リンカ(L3)からはライブラリとして
  読み、**未解決シンボル駆動の遅延取り込み**(ELF リンカの伝統的セマンティクス:
  コマンドライン順、必要になったメンバだけ引き込む)で使う。
- 検証: system ar との相互運用(rubycc-ar が作ったものを ar t/x で読める、逆も)。

### L3 — 静的リンクコア(セクション統合・シンボル解決・再配置適用)
- 入力: 複数 .o + アーカイブ。同名セクションの結合(アラインメント維持・オフセット
  再計算)、シンボル解決(重複定義はエラー。weak は当面「定義が無ければ 0 でなく
  エラー、strong と衝突したら strong 勝ち」の最小実装とし、コーパスで必要になったら
  拡充)、再配置適用(R_X86_64_PC32 / PLT32 / 64 / 32 / 32S)。
- **中間マイルストーンとして `ld -r` 相当(複数 ET_REL → 単一 ET_REL)を実装する**。
  これにより動的リンクを作る前に「rubycc がマージした .o を gcc でリンクして実行テスト全件
  green」という強い検証ができる。
- 設計方針: リンカ独自の中間表現は最初は作らず、リーダが返す ELF 構造の上で直接
  統合する。入力が増えて破綻したら IR 導入を検討(R11 上も、binutils/lld/mold の
  内部構成を参照しない。仕様(ELF gABI・psABI)だけを一次資料にする)。
- 検証: 既存の実行テスト群を「rubycc .o を rubycc で ld -r 併合 → gcc でリンク」経路でも
  全件実行。

### L4 — PIC データアクセス(コンパイラ側の前提対応)
- 現状の :global_addr は PC32 直参照で、**同一 DSO 内で解決されるシンボルにしか安全でない**。
  .so が外部データシンボル(libruby の rb_eArgError 等の VALUE 変数)を参照するには
  GOT 経由が必須(コピー再配置は実行ファイル専用。テキスト再配置(DT_TEXTREL)は禁止)。
- 設計: -fPIC 時(mkmf は常に付ける)、**その TU に定義が無いグローバルのアドレス取得を
  `mov rax, [rip+disp]` + R_X86_64_REX_GOTPCRELX に変える**。TU 内で定義された
  グローバル・static・文字列リテラルは既存の PC32 lea のまま(同一 DSO 内で必ず解決される。
  「他 DSO からの interpose」は C 拡張の実態では起きないので、既定で -Bsymbolic 相当と
  割り切ることを明文化)。関数呼び出しは既存の PLT32 のままでよい(PLT 生成はリンカの仕事)。
- **トレードオフ**: 「外部かどうか」を TU 内の定義有無で決めるため、同一 .so 内の別 TU の
  グローバルも GOT 経由になり 1 命令分遅い。正しさ優先で許容(N2)。リンカ側で
  GOTPCRELX → lea への緩和(relaxation)は M6 以降の最適化。
- 検証: gcc -fPIC の再配置種別と突き合わせ。**rubycc の .o を gcc/ld で .so にリンクして
  TEXTREL が出ない**こと(readelf -d で確認)を CI に追加。

### L5 — 共有ライブラリライタ(.so)
- レイアウト: ELF ヘッダ / プログラムヘッダ(PT_LOAD(r-x / r-- / rw-)、PT_DYNAMIC、
  PT_GNU_STACK)/ .dynsym .dynstr **.gnu.hash と .hash の両方**(glibc は gnu.hash 優先、
  musl 対応も含め安全側: DESIGN 5.3)/ .rela.dyn(GLOB_DAT / RELATIVE / 64)/
  .rela.plt(JUMP_SLOT)/ .plt / .got / .got.plt / .text .rodata .data .bss / .dynamic。
- エクスポート方針: 定義済みグローバルを全て動的シンボルに出す(gcc 既定と同じ。
  mkmf は Init_xxx が見えることを要求する)。未解決の rb_* は UND のまま残す
  (共有ライブラリでは合法。dlopen 時に解決: DESIGN 4.2)。
- .gnu.hash(ブルームフィルタ・バケット)は公式仕様が薄いので、binutils の出力を
  readelf で**観察して外形を合わせる**(実装コードは見ない: R11)。
- 決定的出力(N4): ハッシュのバケット数等もサイズから決定的に導出する。
- 検証: readelf / eu-elflint での構造検査に加え、**Ruby の Fiddle で dlopen して
  エクスポート関数を実際に呼ぶ**実地テストを glibc・musl 両コンテナで CI 化。
  ここが「動的リンクの細部は libc 差が出やすい」リスク(DESIGN 7 章)の関所。
  シンボルバージョン(GLIBC_2.x)は参照側としては無版本参照で解決される想定だが、
  実物の libc.so で必ず確認する。

### L6 — ライブラリ解決(-l / -L / DT_NEEDED)
- -L 探索順 → `libfoo.so` 優先・`libfoo.a` フォールバック。静的ライブラリは L2/L3 の
  遅延取り込みで、共有ライブラリは「.dynsym を読んで解決記録 + DT_NEEDED」で扱う
  (.so の中身はリンクしない)。
- **glibc の `libc.so` はテキストのリンカスクリプト**(`GROUP ( libc.so.6 ... )`)である
  現実に対応する: GROUP / INPUT / OUTPUT_FORMAT / AS_NEEDED だけ認識する最小パーサを
  用意する(本物のリンカスクリプト言語は実装しない)。
- DT_NEEDED は「実際にシンボルを解決した .so」だけに張る(--as-needed 相当を既定)。
  soname は DT_SONAME、無ければ指定ファイル名。依存の推移閉包(.so が必要とする .so)は
  辿らない — それは実行時の動的リンカの仕事で、リンク時の未解決検査は .so では行わない。
- 検証: システム実物の libz 等に対して -lz でリンクし、Fiddle 実行まで通すテスト。

### L7 — 実行ファイルと crt(conftest 用)
- 目的は mkmf の conftest(try_link / try_run)のみ。一般の実行ファイル生成品質は狙わない。
- 形式: **非 PIE の ET_EXEC + PT_INTERP** を選ぶ(PIE より再配置が単純。ASLR 適合性は
  conftest には不要)。インタプリタパスは実在確認で選択
  (glibc: /lib64/ld-linux-x86-64.so.2、musl: /lib/ld-musl-x86_64.so.1)。
- crt: _start は **__libc_start_main 呼び出し方式**(glibc / musl 両方が提供し、libc 初期化・
  atexit・環境変数を正しく通す)。「main 直呼び + exit syscall」の自前方式は printf 等の
  libc 初期化前提が崩れるので採らない。glibc 2.34+ で __libc_start_main がバージョン付き
  シンボルになっている点は、無版本参照での解決可否を実物で確認してから確定する。
  機械語は Ruby 内で合成(DESIGN 5.3 crt/)。
- 検証: mkmf が生成する典型 conftest ソース(have_func / have_header / try_run の実物)を
  ビルド・実行して終了コードを確認。glibc / musl 両方。

### L8 — ドライバ統合と M2 受け入れ
- exe/rubycc を gcc 互換ドライバに拡張(R6): 複数入力(.c / .o 混在)、-c 無しの
  コンパイル+リンク一気通貫、-shared、-l / -L / -Wl,、-fPIC、-O(受理して無視)、
  未知の GCC 固有フラグは警告のみで無視。
- **M2 受け入れ**: json と msgpack を「extconf.rb が生成した Makefile のコマンドを
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

## 7. M4 — aarch64 バックエンド

ラベル A1〜A5 は計画上の識別子(コミット採番規則は M2 と同じ)。M1〜M3 の x86_64 実装が
安定していることが前提で、**「x86_64 で規約化したもの(値表現・IR・テスト)を第二の
バックエンドが検証する」**マイルストーンでもある — IR やテストハーネスに x86_64 の
暗黙の仮定が漏れていればここで露見する。

### A1 — バックエンド抽象化リファクタ(x86_64 のみで完結)
- Backend の契約「IR::Function → Result(bytes / symbols / relocations)」を明文化し、
  リロケーション kind(:call / :string / :global / :got)を**機種非依存の語彙**として
  固定する。ELF ライタは kind → 機種別リロケーション型(R_X86_64_* / R_AARCH64_*)の
  マッピングテーブルを持ち、e_machine をパラメタ化。
- ドライバにターゲット選択を追加(既定はホスト検出: RbConfig::CONFIG["host_cpu"])。
- **このステップは挙動変更ゼロ**: x86_64 の全テストが green のまま、という受け入れ基準が
  リファクタの正しさの定義。aarch64 のコードは一行も書かない。

### A2 — aarch64 コーデジェン・コア
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

### A3 — メモリアクセスとリロケーション
- 幅つき load/store(ldrsb / ldrh / ldrsw / str の各幅。符号拡張ロードの規約は
  値表現規約と対応させる)。
- グローバル・文字列参照: ADRP + ADD(R_AARCH64_ADR_PREL_PG_HI21 +
  R_AARCH64_ADD_ABS_LO12_NC のペア)。GOT 経由(L4 相当): ADRP + LDR
  (R_AARCH64_ADR_GOT_PAGE + R_AARCH64_LD64_GOT_LO12_NC)。
  呼び出し: BL + R_AARCH64_CALL26。**1 参照が 2 命令 2 リロケーションになる**点が
  x86(1 命令 1 リロケーション)と違うので、backend の relocation 記録と ELF ライタの
  対応付けをペア前提に拡張する。
- **受け入れ**: 既存実行テスト全件(gcc 差分込み)が aarch64 で green。
  .o を aarch64 の gcc/ld にリンクさせる相互運用も確認。

### A4 — ABI 完全化(struct 値渡し・varargs・浮動小数)
- 浮動小数: 引数/戻り値 v0-v7、SSE と対になる FP 命令(fadd/fcmp/scvtf 等)。
- struct 値渡し・値返し: AAPCS64 の分類(2 レジスタまでの合成、HFA(同一浮動小数型
  4 個まで)は vレジスタ、超過はメモリ / x8 間接返し)。**SysV と規則が全く違う**ので、
  Step 25 で作った ABI ファジングハーネスを機種パラメタ化して回すことが受け入れ条件。
- varargs: AAPCS64 の va_list は 5 フィールドの構造体(__stack / __gr_top / __vr_top /
  __gr_offs / __vr_offs)で SysV と別物。__builtin_va_* の実装を backend 別に分ける
  (同梱ヘッダの va_list 定義もターゲットで切替)。
- **受け入れ**: ABI ファジング(構造体レイアウト・varargs 網羅)が aarch64 で green。

### A5 — リンカ対応と M4 受け入れ
- リンカの再配置適用・PLT/GOT 生成を aarch64 に対応(PLT エントリの命令列、
  ページ境界計算)。crt(_start)の aarch64 版。
- **CI 環境のトレードオフ**: QEMU(binfmt_misc)はどこでも動くが遅く、まれに実機と
  挙動が違う。既定は QEMU の Docker マトリクスとし、リリース前検証だけ実機
  (Apple Silicon 上の Linux か ARM ランナー)で流す二段構えにする。
- **受け入れ = M4 完了**: 全テストスイート + ABI ファジング + json/msgpack の
  gem install が aarch64(glibc/musl)で成功。

## 8. M5 — 互換ヘッダ・コーパス 90%・v1.0

ラベル H1〜H6 は計画上の識別子(コミット採番規則は M2 と同じ)。M5 は前半(H1〜H3)が
通常のステップ、後半(H4)が**コーパス駆動の反復フェーズ**(1 コミット 1 ステップの
リズムではなく、失敗 gem を潰す小さなコミットの束)になる点が他のマイルストーンと違う。

### H1 — 互換ヘッダ基盤(設計確定。M3 B7 の前に確定させる)
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

### H2 — libc ヘッダ第一陣
- 対象範囲: ruby.h 一式と主要 gem(json / msgpack / bigdecimal / date / racc /
  redcarpet / puma)が #include する範囲(stdio / stdlib / string / errno / ctype /
  math / time / signal / sys/types / sys/stat / fcntl / unistd あたりが実測での中心)。
  範囲は推測でなく、**コーパスの #include を集計して決める**。
- off_t / time_t 等の型幅、errno の実体(glibc: __errno_location、musl: 同名関数)、
  FILE の不透明扱い(構造体の中身は見せない — レイアウト互換の負担を避ける)など、
  **「ABI に効く最小限だけ正確に、それ以外は不透明に」**を設計原則にする。
- **受け入れ**: H1 の ABI 一致ハーネスが対象ヘッダ全域で green(glibc/musl × 2 arch)。
  B7 の先行版ヘッダをこの体系に統合し、M3 の受け入れが維持されること。

### H3 — コーパス CI 基盤
- 対象 gem の選定を自動化: rubygems.org ダウンロード上位から R10 基準
  (C++ 不使用・実体 asm 不使用・configure 非依存)を機械判定(拡張子・extconf.rb の
  mini_portile / configure 呼び出し検出)でフィルタし、**選定リスト自体をリポジトリに
  コミット**する(再現性のため。手動除外には理由を併記)。
- マトリクス実行: glibc/musl × x86_64/aarch64 の Docker で各 gem を
  `gem install` → gem 自身のテストスイート実行。結果を機械可読(JSON)で集計し、
  **失敗を 4 分類**(ヘッダ不足 / 言語機能不足 / ABI バグ / rmake・conftest 非互換)する
  レポートを出す — H4 の反復はこの分類が駆動する。
- **受け入れ**: コーパス全 gem の初回実測レポートが出ること(この時点の合格率は
  問わない。ベースラインの確定が目的)。

### H4 — コーパス駆動の穴埋め反復(合格率 90% まで)
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
