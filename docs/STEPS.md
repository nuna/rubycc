# rubycc 開発ステップ記録(ステップ 1〜13)

各ステップで「何を作ったか」に加えて、**なぜそう設計したか・何を捨てたか(トレードオフ)**を
記録する。実装担当(人間・AI を問わず)は、関連する範囲のステップをここで読んでから
コードに入ること。今後の計画・開発規約は [ROADMAP.md](ROADMAP.md)、要件・アーキテクチャは
[DESIGN.md](DESIGN.md) を参照。

各ステップは 1 コミットに対応する(コミットメッセージ末尾の "(Step N)" が対応)。
コミット本文に変更内容の詳細があるので、`git log` と併読すること。

---

## 採番方式(2026-08-06 変更)

**Step 1〜208 は連番、それ以降は `<ブランチ名>-<連番>`**(例 `differential-discipline-1`)。

### なぜ変えたか

連番は **2 回衝突した**。どちらも「並行して進んでいた別の作業が先に master に入り、
同じ番号を取っていた」形である(Step 202、Step 208)。

**形式を変えるだけでは直らない。** 衝突の原因は
**採番が着手時に、共有されていない共通カウンタから行われる**ことなので、
日付にしてもスラッグにしても、並行する 2 本が同じ日・同じ話題なら同じ値を取る。
**構造的に衝突しないのは、採番の元がストリームごとに違うときだけ**である。

ブランチ名は git が一意性を保証するので、`<ブランチ名>-<連番>` は**ぶつかりようがない**。
時系列の順序は、この文書内の**位置**で保たれる(番号で並べ替える運用はしていない)。

### 過去は振り直さない

Step 1〜208 への参照は**コードのコメントと文書に数百箇所**ある。
振り直せばその全部を書き換えることになり、**得るものより壊す危険の方が大きい**。
過去は連番のまま、新しいものだけ新方式にする。

---

## Step 1 — gem スケルトンとテスト基盤(a18e651)

**内容**: gemspec(実行時依存なし)、`exe/rubycc` スタブ、実行テストハーネス
(ExecutionHelper: C ソース → .o → gcc でリンク → 実行 → 終了コード検証)。

**設計判断**:
- コンパイラ本体より先にテストハーネスを作り、**gcc リファレンス経路でハーネス自体を検証**した。
  以降の全ステップは「同じ C ソースを gcc でもビルドして実行結果を突き合わせる」差分テストを
  標準装備できた(N7)。
- gcc は開発時 CI のみの依存であり、gem の実行時依存にはしない(R2 と両立)。

## Step 2 — 最小の垂直スライス(4632f50)

**内容**: `int main(void) { return <整数式>; }` を字句解析 → 再帰下降パーサ → 三番地コード
IR → x86_64 コーデジェン(機械語直接エンコード)→ ELF64 ET_REL .o まで貫通。

**設計判断**:
- **垂直スライス優先**: 言語機能の幅を広げる前に、最もリスクの高い末端
  (ELF 形式・機械語エンコード・gcc とのリンク互換)を最初に貫通させ、以降のステップを
  「動くパイプラインへの追加」に変えた。
- **spill-everything コーデジェン**: 全 vreg を [rbp - 8*(n+1)] のスタックスロットに置き、
  各 IR 命令が eax/ecx にロード → 計算 → ストアする。コード品質を捨てて(N2 で許容済み)
  単純さ・デバッグ容易性・テスト容易性を取った。レジスタ割付は将来の最適化パス(M6)へ。
- **32bit 演算で C int を再現**: x86-64 の 32bit 演算は結果を自動でラップアラウンドさせるので、
  Ruby の多倍長整数のマスク処理をコーデジェン側で意識しなくてよい。
- **診断を最初から整備**(N3): CompileError はファイル名・行・桁・ソース抜粋・キャレットを持つ。
  後付けでは全経路の改修になるため初手で導入した。
- ELF ライタはタイムスタンプ等を埋めず**決定的出力**(N4)。
- R11 対応: パーサの非終端記号は ISO C 標準の文法用語(additive-expression 等)で命名。
  二項式は優先順位テーブル駆動の左結合ループで実装(教材系の「優先順位ごとに関数を並べる」
  構成を避ける意図もある)。

**トレードオフ**: IR は最適化を一切しない(定数畳み込みすら将来)。SSA にはしないが、
仮想レジスタ無制限の三番地コードなので将来 SSA 化できる余地は残る(DESIGN 5.2)。

## Step 3 — ローカル変数・宣言・代入(fc80f0e)

**内容**: 宣言(初期化子・カンマ区切り宣言子)、変数参照、単純代入、式文・空文。

**設計判断**:
- 記号表(変数名 → vreg)は IR Generator に置く。**パーサは構文と型の構築、ジェネレータが
  意味検査**という分業をここで確立(以降のステップも踏襲)。
- 代入は「値を持つ式」として実装(C の意味論どおり)。左辺値の構文判定はパーサ
  (`assignable?`)、型・意味の検査はジェネレータ。

## Step 4 — 比較・論理否定・if/else・ブロックスコープ(2ed4053)

**内容**: `== != < <= > >=`、単項 `!`、if/else、compound-statement、シャドウイング。

**設計判断**:
- 単項 `!` は IR ジェネレータで「0 との eq」に**脱糖**し、IR 命令を増やさなかった。
  「**IR 命令は本当に必要になるまで追加しない。まず既存命令への脱糖を検討する**」という
  方針をここで確立(Step 5・9 はこの方針により IR・backend 無変更で実装できた)。
- ジャンプは rel32 バックパッチ方式(ラベル位置確定後に一括解決)。objdump での目視確認を
  レビュー手順に含めた。
- スコープは記号表のスタック化。C 準拠のシャドウイング。

## Step 5 — 反復文と break/continue(d151722)

**内容**: while / do-while / for(C99 の for スコープ)、break / continue。

**設計判断**:
- ループはすべて既存の :label / :jump / :jump_if_zero への脱糖で実現。**IR・backend 無変更**。
- break/continue の飛び先はジェネレータ内のループコンテキストスタックで管理。
  ループ外での使用は位置情報付き診断。

## Step 6 — 関数定義・プロトタイプ・呼び出し・リロケーション(fbcd0e5)

**内容**: 複数関数、プロトタイプ、SysV AMD64 の整数引数 6 個(edi/esi/edx/ecx/r8d/r9d)、
再帰・相互再帰・外部 libc 関数呼び出し、.rela.text(R_X86_64_PLT32)。

**設計判断**:
- 呼び出し規約: 引数はプロローグで**スロットに退避**してから使う(spill-everything と一貫)。
  引数はすべてスロット経由なので、ロード順でレジスタを壊す心配がない。
- スタック 16 バイト整列は「push rbp + 16 の倍数の sub」で恒常的に成立させ、call ごとの
  調整を不要にした。
- 未定義シンボルは SHN_UNDEF で .o に残し、解決はリンカ(gcc、将来は自前)に委ねる。
- 引数 7 個以上(スタック渡し)は**明示的に診断エラー**にして先送り。
  「未対応機能は黙って壊れるのではなく、明確なエラーメッセージで拒否する」方針を確立。

## Step 7 — 最小の型システムとポインタ(1c40884)

**内容**: Type(Int/Pointer)、`int *p` / `int **pp`、単項 `&` / `*`、型検査。

**設計判断**:
- 型は値等価(`int *` == `int *`)の不変オブジェクト。`#to_s` が C の宣言子風に描画され、
  診断メッセージにそのまま使える。
- **スロットの load/store を REX.W(64bit)化**。スカラは「スロット内では常に 32bit 以上へ
  拡張済み」、ポインタは 64bit のまま、という値表現の統一で、スロット幅を型ごとに変える
  複雑さを回避した(規約の明文化は Step 10)。
- IR の :load/:store は size(バイト幅)を持ち、幅の知識を backend から分離。

## Step 8 — 一次元配列・ポインタ演算・sizeof(a52210e)

**内容**: 配列宣言、添字(`*(base + index)` へ脱糖)、配列→ポインタ退化、
p±n / p−q / ポインタ比較、sizeof(式・型名)。

**設計判断**:
- 配列はスロットに収まらないので **stack_objects(フレーム内の連続領域)** を新設。
  vreg 領域の下に 16 バイト整列で確保し、:object_addr でベースアドレスを取る。
  「集約オブジェクトの値=そのアドレス」という表現をここで導入(Step 13 の struct も踏襲)。
- sizeof は**コード生成を伴わない静的型導出**(static_type 系)で畳み込む。
  gen_* と static_type の**二重の型推論経路を持つ保守コスト**を受け入れて、
  「sizeof のオペランドは評価されない」という C の意味論と IR の単純さを取った。
  ジェネレータに式の型導出を変更するときは**両経路の同期が必要**(レビュー観点)。
- ポインタ演算のスケーリングは size=8 の 64bit 演算 + :sext(添字の符号拡張)で実装。

## Step 9 — 論理演算子・条件演算子・複合代入・インクリメント(43032e2)

**内容**: `&& ||`(短絡)、`?:`、`+= -= *= /= %=`、前置/後置 `++ --`。

**設計判断**:
- すべて既存 IR 命令への脱糖で実現(IR・backend 無変更)。短絡はラベルとジャンプ、
  複合代入は「アドレスを一度だけ評価して load → 演算 → store」。
  `a[i++] += 1` 型の**二重評価バグを構造的に防ぐ**ため、複合代入・++/-- 系は必ず
  「アドレス一度きり評価」のヘルパ経由で実装する(以降の lvalue 種追加時も同じ経路に乗せる。
  Step 13 の MemberAccess はこの規約に従った)。
- 条件位置(if/while/&&/…)の型検査を明示化し、**ポインタ条件を診断エラー**にした。
  これは C 標準からの**意図的な一時逸脱**(32bit test による切り捨ての潜在バグより
  明示エラーが良い)。スカラ条件の一般化は将来ステップで対応(ROADMAP 参照)。

## Step 10 — char・文字/文字列リテラル・.rodata(ef0424e)

**内容**: char 型、文字リテラル(int 型)、文字列リテラル(.rodata、重複排除、NUL 終端)。

**設計判断**:
- **値表現規約の明文化**(backend/x86_64.rb 冒頭コメント): スロット内のスカラは常に
  32bit 以上へ符号拡張済み。8bit への変換は**メモリ境界(load/store)と明示的な
  int→char 変換(:sext8)のみ**で起きる。この規約が以降の全幅追加(将来の short/long/
  unsigned)の基準になる。
- 文字列は TU 単位でプール(同一内容は 1 個)し、:string_addr → lea rip 相対 +
  R_X86_64_PC32(.rodata セクションシンボル + addend)で参照。リロケーション記録を
  kind 付き({kind: :call/:string/...})に一般化し、以降の種類追加を容易にした。
- テストハーネスに stdout 検証を追加(puts の実出力を gcc と突き合わせ)。

## Step 11 — グローバル変数と .data/.bss(7c0f4e5)

**内容**: ファイルスコープ変数。初期化付きは .data、未初期化は .bss(SHT_NOBITS)。

**設計判断**:
- `int g;` は gcc の `-fno-common` と同じ**定義扱い**(モダン gcc/clang のデフォルトに合わせ、
  コモンシンボルの複雑さを回避)。
- 初期化子は整数定数のみ。**定数評価はパーサで実施**(初期化子の一般化は将来ステップ)。
- グローバル参照は :global_addr(lea rip 相対 + シンボル直参照の R_X86_64_PC32)経由の
  アドレス取得に統一し、読み・書き・複合代入・++/-- をローカルと同じ load/store 経路に乗せた。
- **Step 10 の既知バグを修正**: ローカル char スカラの読み出しを :sext8 で下位バイトから
  再拡張するようにし、「ポインタ経由の 1 バイト書き込み」とスロット表現(拡張済み値)の
  エイリアシング不整合を解消。値表現規約の運用で最初に踏んだ罠なので、幅のある型を
  追加するときは**ポインタ経由の書き込みとの整合**を必ずテストすること。

## Step 12 — 戻り値型の一般化と void/void*(f63d5ae)

**内容**: 戻り値型 int/char/任意ポインタ/void、値なし return、void* の暗黙変換、
malloc/free の利用。

**設計判断**:
- ポインタ戻り値は rax、char 戻り値は「拡張済み値」の規約でそのまま成立
  (値表現規約の配当)。
- void* は他ポインタ型と**双方向の暗黙変換**(代入・引数・戻り値・==/!=)。
  void* への演算・参照外しはエラー。C の規則どおり。
- void の不完全型としての扱い(変数不可・sizeof 不可)は Type::VoidType の size が
  raise する設計で「ジェネレータが先に診断で拒否する」不変条件を守る。

## Step 13 — struct(ec3bf2f)

**内容**: struct の定義・前方宣言・自己参照、System V AMD64 レイアウト
(自然アラインメント・パディング)、`.` / `->`、struct 代入(:memcpy → rep movsb)、
struct のローカル/グローバル/配列/ポインタ、タグの名前空間とブロックスコープ。

**設計判断**:
- **StructType は恒等比較・可変**(他の型は値等価・不変)。C のタグ同一性
  (再宣言は同一定義を指す)に一致し、自己参照 struct で ==/to_s が無限再帰しない。
  前方宣言・自己参照ポインタは未完成の同一オブジェクトを参照し、`#define`(レイアウト確定)が
  同じオブジェクトをその場で完成させる。
- **タグスコープはパーサに置く**(@tag_scopes)。「型の構築はパーサ、意味検査はジェネレータ」
  の既存分業を維持するため。ジェネレータは完成した Type オブジェクトだけを消費する。
- レイアウト計算は type.rb(StructType#define)。gcc の sizeof/offsetof と全ケース一致を
  テストで確認。
- IR への追加は **:memcpy 1 命令のみ**(a=宛先アドレス, b=元アドレス, size=バイト数。
  backend は rep movsb)。struct 値は「オブジェクトのアドレスを持つ vreg + struct 型」で
  統一表現(Step 8 の配列と同型の発想)。メンバアクセスは「ベースアドレス + 定数オフセット」
  への脱糖。
- **struct の値渡し・値返しは明示的に診断エラー**(SysV の分類アルゴリズムが必要で
  規模が大きい。ROADMAP の専用ステップで対応)。union・ビットフィールド・初期化子も同様に先送り。

**トレードオフ**: `struct S;` を「外側スコープの S が見えていても内側で新タグを宣言する」
C の細則(6.7.2.3p7)には従っていない(外側を参照する)。実用上の影響が出た時点で対応。

## Step 14 — キャスト式・ヌルポインタ定数・スカラ条件(1416b4a)

**内容**: cast-expression(`(型名)式`)、ヌルポインタ定数(NPC)の暗黙変換、
条件位置でのポインタ許可(Step 9 の意図的逸脱の解消)、`(void)式`。

**設計判断**:
- **cast-expression の挿入位置**は ISO C どおり multiplicative と unary の間。
  `(` の次が型指定子なら型キャスト、さもなくば括弧式(1 トークン先読み)。
  **typedef 導入時(Step 18)はこの判定に typedef 名の名前空間参照が必要**になる旨を
  パーサにコメントで残した。型名パースは parse_type_name として抽出し sizeof(型名) と共有。
- **キャスト生成は目的型で分岐**(type-name 文法は int/char/void/ポインタ/struct しか
  生まないため場合分けが閉じる)。算術↔算術は narrow_to_type 再利用(int→char のみ
  :sext8、拡幅はスロットが拡張済みなのでコード無し)、ポインタ↔ポインタ・NPC→ポインタは
  **リタグのみでコード無し**。`(void)` は gen_expr で評価して値を捨てる(gen_value でなく
  gen_expr なのは void 関数呼び出しを被演算子に許すため)。
- **ポインタ⇔整数(0 以外)のキャストは診断エラー**
  「cast between pointer and integer is not supported yet」。ポインタ幅の整数型
  (long / intptr_t 級)が無い現状では往復できないため(Step 17 で解消見込み)。
- **NPC 判定はノード単位**(`AST.null_pointer_constant?` = IntLit かつ値 0。'\0' は
  字句解析器が整数 0 に落とすので自動的に含まれる)。型(int)だけではリテラル 0 を
  識別できないため、型でなくノードを見る。一般の整数定数式(`1-1` 等)は Step 20 の
  定数式評価導入時に拡張する前提をコメントに明記。
- **NPC の暗黙変換は compatible_assignment?(expected, value_node, actual) に集約**し、
  代入(単純代入・添字・メンバ・参照外し)・初期化・引数・return の全経路に適用。
  複合代入・++/-- は NPC 非該当なので compatible_types? のまま。==/!= は gen_binary で
  NPC×ポインタを検出して **size=8 比較**、?: は conditional_result_type にノードを渡して
  NPC 側の腕にポインタ型を与える。`p < 0` は従来どおり invalid operands。
- **条件の脱糖は gen_condition に集約**: ポインタ条件は「0 との :ne(**size=8**)」に
  脱糖して int 0/1 を返し、既存の :jump_if_zero(32bit テスト)に渡す。Step 9 で
  拒否した理由だった「アドレス上位 32bit の切り捨て」を 64bit 比較で解消。`!p` は
  gen_logical_not 内で :eq size=8。**struct 条件は診断エラーのまま**
  (require_scalar_condition を require_scalar_for_truth に置換し、算術+ポインタを許可)。
- **static_type の同期**: Cast(型名をそのまま返す)と static_binary_type
  (NPC の ==/!= を int にする)を追加。sizeof((char *)0) == 8 を実行テストで確認。
- **グローバル `int *p = 0;`** は既存経路がそのまま通り、init 非 nil の既存規約どおり
  **.data に 8 バイトのゼロ**として配置(null ポインタとして意味的に正しい)。
- **IR 命令の追加なし**(すべて既存 :const/:eq/:ne/:sext8 への脱糖)。

**トレードオフ**: `(x)(y)`(x が非型)はキャストではなく括弧式+呼び出しと解釈されるが、
現状は呼び出し対象が裸の識別子に限られるため「expected ';'」で止まる(関数ポインタの
Step 21 で意味を持つ)。Step 13 で NULL の代わりに自己ループ番兵を使っていた連結リストの
テストは、本ステップで実 NULL 終端の走査テストに置き換えた。

## Step 15 — ビット演算子・シフト・カンマ演算子(a00121e)

**内容**: `&`(二項)`|` `^` `~` `<<` `>>`、複合代入 `&= |= ^= <<= >>=`、カンマ演算子。

**設計判断**:
- **優先順位チェーンの挿入**は ISO C どおり: logical-AND の下に inclusive-OR >
  exclusive-OR > AND > equality、relational と additive の間に shift-expression。
  既存の parse_left_associative + 演算子表(1 段 1 定数)のパターンをそのまま踏襲。
  二項 `&` は AND-expression の位置でのみ認識され、単項 `&`(アドレス取得)とは
  出現位置で衝突しない(`&&`/`&=` は字句解析が先に分離)。
- **字句の最長一致を 3 文字に拡張**(PUNCTUATORS_3 = `<<=` `>>=` のみ)。
  3→2→1 文字の順で照合し、`<<=` > `<<` > `<=` > `<` の順序を保証。
- **`~x` はパーサで `x ^ -1` に脱糖**(-1 は全幅で全ビット 1)。「IR 命令は最後の
  手段」の方針どおり専用 :not を追加せず、:xor の既存経路(型検査含む)に乗せる。
  ポインタ/struct オペランドは `x ^ 1` と同じ invalid operands 診断が自動適用。
- **AST は源言語の :shr を保持し、ジェネレータが :sar に写像**。「int は符号付き
  なので算術シフト」という決定を型を知るジェネレータに置くことで、Step 17 の
  unsigned 導入時は「unsigned オペランドなら :shr(論理シフト)を選ぶ」だけで済む。
  IR の :shr は Step 17 で追加予定(ir.rb にコメント明記)。
- **シフトの下降**: シフト量は b オペランドとして CL レジスタ経由
  (既存 emit_binary が b を ECX にロードする規約の配当で `D3 /4`・`D3 /7` が
  そのまま使える)。x86 が 32bit オペランドのシフト量を 5bit にマスクするのは
  C の UB 領域なのでそのまま許容。シフトは可換でない+下降が特殊なため
  SHIFT_OPS として通常の可換 32bit 演算(:add 系)と分けて処理。
- **ビット演算 :and/:or/:xor は既存 32bit 二項演算と同じ規約**(binary_result_type
  の最終 else に自然に落ち、算術×算術 → int のみ許可)。
- **カンマの文脈分離**: parse_expression(式文法の最上位)だけを
  comma-expression に格上げ。実引数・宣言初期化子は元から
  parse_assignment_expression を直接呼ぶ構造だったため、「区切りのカンマ」は
  無変更で保たれた。括弧式・添字・式文・for の 3 句・条件位置・return・`?:` の
  中間項は parse_expression 経由なので ISO C どおりカンマ可。左は gen_expr で
  評価・破棄(void 関数呼び出しを左に許すため)、右の [値, 型] が結果。
  static_type も右の型を返す(sizeof(a, b) は b の型)。

**トレードオフ**: 16 進リテラル(`0x0F`)は未対応のまま(本ステップのスコープ外。
テストのビットマスクは 10 進で記述)。整数リテラルの基数拡張は必要になった時点で対応。

---

## Step 16 — switch・goto・ラベル文(408be5e)

**内容**: switch / case / default(6.8.4.2, 6.8.1)、goto / ラベル文(6.8.6.1, 6.8.1)。
新規 IR 命令ゼロ。backend・ir.rb 無変更。

**設計判断**:
- **switch は比較チェーンへ脱糖**(ジャンプテーブルは最適化であり M6 以降)。
  制御式を一度だけ評価し、各 case 定数と `:ne` で比較して `:jump_if_zero`
  (= 等しければジャンプ)で該当ラベルへ。jump-if-nonzero 命令を IR に足さず、
  既存 2 命令の組み合わせで表現(「IR 命令は最後の手段」)。全 case 不一致は
  default ラベル(なければ switch 終端)への無条件ジャンプ。
- **case/default の収集は AST の再帰走査**(collect_switch_labels):ブロック・
  if の両腕・ループ本体・ラベル文・case/default 自身の本体を降下し、ネストした
  switch では停止(内側の case は内側の所有)。これにより「ブロック内に埋まった
  case」(Duff's device 型)も正しく外側 switch に帰属する。
- **ノード→ラベル id の対応は `{}.compare_by_identity`**。AST ノードは
  Data.define(値等価)のため、`case 1: ...` が二重に見える同値ノードを
  区別するには恒等キーが必要。dispatch 生成時に採番した id を、本体生成中の
  gen_case/gen_default が @case_label_stack(switch のネストに対応)経由で引く。
- **@loop_stack を @control_stack に一般化**。フレームは
  `{break_label:, continue_label:}` で、ループは両方自前、switch フレームは
  break_label のみ差し替えて continue_label を外側から継承。これで switch 内の
  break は switch を抜け、continue はループまで素通しになる(継承値が nil =
  ループ外 switch 内の continue は診断)。
- **goto は関数スコープの @goto_labels(name → {id:, defined:, token:})で
  バックパッチ不要**。初出時(前方 goto でも定義でも)に id を採番するので、
  goto は即 `:jump` を発行でき、後から来る定義が同じ id に `:label` を置くだけ。
  ROADMAP 当初案の「前方参照はバックパッチ」より単純になった。重複定義は
  定義時に、未定義ラベルへの goto は関数末尾で(保存したトークン位置で)診断。
- **case 定数はパーサで畳み込み**(整数・文字定数 + 単項 `+`/`-` の連なり)。
  グローバル初期化子の既存畳み込みと同じ範囲に揃え、一般の定数式評価
  (`case 1 + 2:`)は Step 20 の定数評価器(6.6)導入時に拡張する。
- **ラベル文の判別は 2 トークン先読み**(識別子 + `:`)。式文との曖昧さは
  この位置でのみ生じ、`x ? a : b;` は 2 個目が `?` なので誤爆しない。

**診断**: 重複 case 値・複数 default・switch 外の case/default・非整数の制御式
(ポインタ/struct)・重複ラベル定義・未定義ラベルへの goto・ループ外 switch 内の
continue(break は合法)。

**トレードオフ**: goto がスコープ途中へ飛ぶと宣言の初期化式はスキップされる
(C 準拠の挙動。vreg スロットはコンパイル時割り付けなので実行は安全)。

---

## Step 17 — 整数型の拡張: long / short / unsigned / _Bool(253b48d)

**内容**: signed/unsigned × char/short/int/long と _Bool(LP64)。16進・8進リテラルと
u/l/ll 接尾辞。整数昇格(6.3.1.1)・通常算術変換(6.3.1.8)。符号別の除算・剰余・
右シフト・関係比較。sizeof → unsigned long。ポインタ⇔整数キャスト解禁。
M1 で最も影響範囲が広いステップとして単独で実施。

**設計判断**:
- **型システムは IntegerType 1 クラスに一般化**(名前・幅・符号・bool フラグ)。
  Scalar/CharType の 2 クラスを置き換え、型ごとに共有インスタンス
  (Type::Int、Type::ULong 等)を定義して恒等比較=値比較を維持。`long long` は
  LP64 で同幅の long に、`signed char` は char に、パース時点で正規化。
- **値表現規約は「≥32bit 拡張済み・上位 32bit は narrow 値では不定」に据え置き**。
  ROADMAP 当初案の「64bit へ拡張済み」への持ち上げは採らなかった: 32bit 演算の
  たびに上位を作り直すコストがかかる一方、上位が要る場面(64bit 演算・アドレス・
  条件判定)は :sext/:zext を境界で挟めば足りる。幅・符号の変換点は
  メモリ境界(load/store)と明示変換(:sext/:zext)の 2 箇所のみという不変条件は維持。
- **宣言指定子は多重集合を収集してから 6.7.2 で正規化**(順不同対応)。
  void/_Bool は単独のみ、signed+unsigned・short+long・重複・3 個以上の long を診断。
- **リテラルの型は 6.4.4.1 の候補列**をトークンの基数・接尾辞から構築して決定
  (10進は無接尾辞で unsigned に落ちない、16進/8進は落ちる)。レクサはトークンに
  基数と正規化済み(小文字)接尾辞を保持し、型決定はパーサが担当。
  IntLit ノードが型を持ち、static_type もそれを返す。
- **新 IR 命令は符号で機械語が分かれるものだけ**: :udiv/:umod、:shr、
  :ult/:ule/:ugt/:uge(setb 系。アドレスは無符号なのでポインタ順序比較にも使用)、
  :uload(movzx ロード)、:zext。加減乗・ビット演算・等値比較はビットパターンが
  符号非依存なので既存命令を共用。:sext は元幅 1/2/4 の引数を取る形に一般化し、
  :sext8 を吸収・廃止。
- **変換は #convert に集約**: 8 バイト先への拡幅は「元の型」の符号で、
  1/2 バイト先への縮小は「先の型」の符号で低位バイトから再導出、4 バイト先と
  同幅の符号変え(int⇔unsigned int)はコード不要。_Bool への変換は「値 != 0」に
  脱糖(専用命令なし)。代入文脈(=・初期化・引数・return・?: の腕)は
  #convert_for_assignment で一元適用。
- **narrow 型ローカルの再読出しガードを一般化**: Step 11 で char に入れた
  「&x 経由のエイリアス書き込み後の上位バイト不整合」対策を、1/2 バイトの
  全整数型に拡張(符号に応じ :sext/:zext で低位から再導出)。
- **通常算術変換は LP64 前提でサイズ比較に単純化**: 昇格後、同符号なら広い方、
  異符号なら「無符号のサイズ ≥ 符号付きのサイズなら無符号、さもなくば符号付き」。
  LP64 では「符号付きが真に広ければ全値を表現できる」が常に成り立つため
  この 2 分岐で 6.3.1.8 と一致する。
- **switch の制御式は整数昇格**し、long なら case 定数との比較を 64bit で実施。

**レビューでの修正**: 実装エージェントの成果に 2 点の欠陥があり主セッションで修正。
(1) `bool?` が IntegerType にしか無く、compatible_types? がポインタ型等で
NoMethodError(71 テスト失敗)→ 全型クラスに `bool?`(false)を追加。
(2) 診断文言が gcc の easter egg("'long long long' is too long for GCC")を
そのまま流用 → 中立な文言に変更。

**トレードオフ**: ポインタ差の結果型は int のまま(ptrdiff_t = long への変更は
実害が出た時点で)。一般の定数式評価(`case 1 + 2:` 等)は Step 20 の定数評価器で。

---

## Step 18 — enum・typedef(0395856)

**内容**: enum-specifier(6.7.2.2)と typedef(6.7.1)。C の「識別子が型名かどうかで
構文が変わる」曖昧性をパーサ側スコープ表で解決。ジェネレータ・IR・backend は無変更。

**設計判断**:
- **通常識別子スコープ(@ordinary_scopes)をパーサに追加**し、既存のタグスコープと
  完全並走で push/pop(関数本体・for 括弧・compound)。エントリは typedef 名
  (→解決済み Type)、enum 定数(→Integer 値)、通常識別子(ペイロードなし)の 3 種。
  通常識別子は「内側スコープの変数宣言が外側の typedef 名/enum 定数をシャドウする」
  ことだけのために記録し、再宣言診断は既存のジェネレータ側に残す(責務の重複を回避)。
- **字句解析器は変更しない**(ROADMAP の確定判断)。typedef 名は識別子のまま
  トークン化され、パーサが type_specifier? の照会で解決する。lexer hack ではなく
  パーサ内スコープ表方式。
- **typedef 名の認識は「最初で唯一の型指定子」の位置のみ**。型キーワードを 1 つでも
  読んだ後の識別子は宣言子(`int T;` は typedef T があっても変数 T の宣言)という
  ISO C の規則どおりで、これがシャドウ宣言を可能にする。`unsigned T x;` は
  T が宣言子になった結果の構文エラー(gcc と同じ挙動)。
- **enum 型は Type::Int をそのまま返す**(専用 EnumType なし — ROADMAP の確定判断)。
  enum 定数は式中でも case ラベルでも enumerator 定数式でもパーサが
  IntLit(Type::Int) に畳み込むため、AST 以降のパイプラインは enumerator を一切
  見ない。ジェネレータ無変更はこの帰結。
- **enum タグは struct タグと同一名前空間**(C 6.2.3)。StructType と区別する
  EnumTag マーカーを @tag_scopes に置き、種別不一致を「defined as wrong kind of
  tag」で診断。enum に不完全形は無いので未定義タグの参照は即エラー
  (struct の前方宣言との対比)。
- **enumerator 値の畳み込みはケース定数と同じ制限**(整数・文字定数 + 単項 +/-)に
  「スコープ内の他 enumerator 参照」を加えた範囲。一般の定数式(`A = 1 + 2`)は
  Step 20 の定数評価器(6.6)導入時に拡張。
- **同一型への再 typedef も一律拒否**(M1 単純化。C11 6.7p3 は同一型なら許容)。
  ruby.h 処理で実害が出た時点で緩和する。

**トレードオフ**: typedef の再定義許容(C11 準拠)と一般定数式の enumerator は先送り。
enum の列挙型としての区別(-Wenum-compare 相当の警告等)は持たない(int と完全同一視)。

---

## Step 19 — union・無名 struct/union メンバ(596bf9e)

**内容**: union(6.7.2.1)と無名 struct/union メンバ(C11 6.7.2.1p13)。
ジェネレータ・IR・backend は無変更。

**設計判断**:
- **StructType に kind(:struct | :union)を追加して流用**(別クラスを作らない —
  ROADMAP の確定判断)。`struct?` は「struct または union の集成体」の意味に広げて
  両方 true を維持。ジェネレータの「集成体かどうか」の全分岐(メンバアドレス・
  :memcpy 丸ごとコピー・値渡し拒否・スカラー要求診断)が読み替えなしで union に
  効くための選択で、意味の変更は struct? のコメントに明記。区別が要るのは
  タグ種別チェックと to_s 表示だけで、そこに `union?` を使う。
- **レイアウトのみ kind 分岐**: layout_struct(既存の逐次配置)/ layout_union
  (全メンバ offset 0、サイズ = 最大メンバサイズを最大アラインメントへ切り上げ)。
  不完全→define で完成という可変性・恒等比較・前方宣言・自己参照ポインタの機構は
  struct と完全共有。
- **無名メンバは member(name) の透過探索で実現**: 名前付きメンバを先に探し、
  なければ name=nil の集成体メンバの中を再帰探索して「無名メンバの offset +
  内側の offset」を畳み込んだ合成 Member を返す。内側の再帰が返す Member には
  既に内側の合成 offset が入っているため、外側は自分の offset を足すだけで
  何段ネストしても 1 回のルックアップで解決する。ジェネレータの . / -> 低下は
  member.offset / member.type しか見ないので、無名メンバの存在を一切知らない
  まま透過アクセスが成立(無変更の根拠)。
- **名前衝突はパーサの define 時に診断**: 無名メンバが透過的に晒す全名前を
  再帰収集して seen 集合に畳み、直接メンバとの衝突を双方向(無名→直接、
  直接→無名)で「duplicate member」として検出。
- **タグ付き無宣言子は一律拒否**(`struct Inner { ... };` / `struct Inner;` が
  struct 本体内に単独で現れる形)。C11 の無名メンバはタグなしに限るため
  「declaration does not declare anything」で診断(gcc は警告どまりだが M1 は
  エラーに単純化)。

**トレードオフ**: struct 本体内の `enum { A };`(メンバなしの enum 定数宣言)も
「declaration does not declare anything」で拒否される(gcc は許容)。実害が出た
時点で緩和。型パンニングの読み出し値はリトルエンディアン前提(x86-64 のみが
ターゲットの M1 では gcc 差分テストと整合)。

---

## Step 20 — 定数式評価器・初期化子(3413652)

**内容**: 定数式評価(6.6)と初期化子(6.7.9)。brace リスト・指示付き初期化子・
brace 省略・`[]` 長さ推論・文字列初期化・グローバルのアドレス定数と
ELF .rela.data(R_X86_64_64)。実装は 2 段階に分割して移譲
(第 1 段: 評価器 = implementer、第 2 段: 初期化子 = heavy-implementer)。

**設計判断**:
- **定数式評価器はパーサ・記号表非依存**(front/constant_evaluator.rb)。enum 定数は
  Step 18 でパーサが IntLit に畳み込み済みなので AST 評価だけで完結する。非定数は
  NotConstant(トークン保持)、到達した 0 除算は DivisionByZero を投げ、呼び出し側が
  文脈別の診断文言に変換。&&/||/?: は短絡し、未評価側の 0 除算はエラーにしない。
  除算・剰余は 0 方向切り捨て(Ruby の床除算と異なる)。M1 簡略化として計算は
  無限精度で行い、ラップは Cast 時のみ(unsigned の厳密なラップ意味論は先送り)。
  Step 26 のプリプロセッサ #if が同じ評価器を再利用する前提の分離。
- **パーサの畳み込み 4 箇所を一元置換**: constant-expression = conditional-expression
  (6.6)として既存の parse_conditional_expression で AST を組み評価器で畳む。
  `case 1 ? 2 : 3:` の `:` の曖昧性は conditional の文法構造で自然に解決される。
- **初期化子リゾルバは front 側の共有コンポーネント**
  (front/initializer_resolver.rb)。型 + InitializerList → フラットな
  ScalarInit(offset, type, value) / StringInit(offset, bytes) 列 + 完成型
  (`[]` の長さ推論込み)。**値の評価と型検査を意図的に外に出し**、グローバル
  (定数畳み込み)とローカル(実行時ストア)の差をリゾルバの外に隔離。構造上の
  診断(excess・未知メンバ・範囲外 index・空 {}・文字列超過)のみ担当。
- **brace 省略は「同一カーソルの再帰」で実現**: 各 brace レベルを前進カーソルで
  走査し、braceなしの集成体サブオブジェクトには同じカーソルを渡して必要なだけ
  消費させる(6.7.9p20)。designator は先頭要素で位置を再設定し、残りの連鎖を
  辿ってから適用、以降は次位置から継続。パーサでもリゾルバを実行して
  VariableDecl/GlobalDecl の型を確定させ(sizeof が効く)、ジェネレータは同じ
  純粋リゾルバを再実行する(冪等)。
- **ローカルのゼロ埋めは「全体ゼロ化 → 明示分上書き」**: 8/4/2/1 バイトの最大幅
  ストアでオブジェクト全体を先にゼロ化。どの範囲が未指定かの簿記が不要になり、
  パディング・配列末尾・文字列 NUL が自動で 0 になる。`char s[] = "hi"` は
  バイト即値ストア(.rodata の文字列プールを汚さない選択)。
- **グローバルは GlobalInit(バイト像 + リロケーション列)に一般化**: 整数スロットは
  評価器で畳んでスロット幅にマスク(無限精度値の pack RangeError をレビューで
  検出し修正)。ポインタスロットのアドレス定数は 0 / &グローバル / グローバル
  配列名の減衰 / 文字列リテラルの 4 形のみ(関数名は Step 21、&arr[i] 等の計算
  アドレスは必要時)。ELF は .rela.data を新設し、シンボル参照は R_X86_64_64
  addend 0、文字列は .rodata セクションシンボル + addend。
- **sizeof(式) は定数文脈では非対応のまま**(型推論がジェネレータ側にあるため)。
  必要になった時点で static_type の共有を検討。

**トレードオフ**: 文字列初期化は NUL 込みで収まる長さを要求(`char s[2] = "ab"` の
NUL 落ちは C では合法だが M1 は診断)。多次元配列は未対応のため brace 省略の主対象は
struct 配列。unsigned 演算の定数畳み込みラップは Cast 時のみ。

---

## Step 21 — 関数ポインタ・間接呼び出し・スタック渡し引数(d211de0)

**内容**: 宣言子パーサの ISO C 6.7.6 direct-declarator 再帰への一般化と
Type::FunctionType、関数指示子の退化(6.3.2.1p4)、間接呼び出し
(`f(x)` / `(*fp)(x)` / `s.fp(x)` / `table[i](x)`)、引数 7 個以上のスタック渡し、
`&配列`(配列ポインタ型)、グローバル初期化子の関数名アドレス定数。
実装は 2 段階に分割して移譲(第 1 段: 宣言子・型 = heavy-implementer、
第 2 段: 意味論・backend = heavy-implementer)。

**設計判断**:
- **宣言子は「構文の読み取り」と「型の構築」を分離**: parse_declarator 系は
  [名前トークン, build ラムダ, 関数接尾辞のパラメータ] を返し、build が基底型を
  内から外へ包む。ポインタ接頭辞は文面上最外だが束縛は接尾辞 `()`/`[]` より弱いので
  先に基底を包み(戻り値・要素型側に入る)、接尾辞は「後のものほど強く束縛」なので
  逆文面順に適用する。接尾辞は [:array, length, tok] / [:function, params, tok] の
  記述子で持ち、apply_declarator_suffix が 6.7.6.3 の制約(関数を返す関数・配列、
  関数の配列)を適用時に診断する。
- **`(` の曖昧性は次トークンで解消**(paren_starts_declarator?): `*`・`[`・`(`・
  typedef 名でない識別子なら括弧つき宣言子、型指定子・typedef 名・`)` なら
  パラメータリスト。`int (*f)(int)` と抽象宣言子 `int (int)` を区別する。
  パラメータは 6.7.6.3 調整(配列→要素ポインタ、関数→関数ポインタ)を
  parse_parameter_declaration で適用。
- **FunctionType は Data で値等価・size/alignment は raise**: 関数型はオブジェクト型
  でないため測れない。到達しうる箇所(sizeof・メンバ・ブロックスコープ変数)は
  すべて事前に診断するので、raise は「ガード漏れ」の検出器。
- **呼び出しは postfix 接尾辞に一般化し、直接/間接の判別はジェネレータ**:
  AST::Call は (callee, args, token)。callee が「変数に隠されていない裸の関数名」なら
  従来どおり :call、それ以外は式を評価して Pointer(FunctionType) を検査し
  :call_indirect(対象を r10 にロードして call r10。r10 は SysV スクラッチかつ
  非引数レジスタ)。引数の個数・型検査・変換は両経路で lower_call_arguments を共有。
- **関数指示子の退化は :func_addr(lea rip 相対)**: reloc は :call と全く同じ経路
  (未定義なら undefined symbol + R_X86_64_PLT32)を再利用。lea の disp32 も
  call rel32 も命令末尾 4 バイトなので addend −4 が一致する。外部関数(libc の
  abs 等)は PLT スタブのアドレスになるが、関数ポインタとして有効(差分テストで
  検証)。`*fp` は「ロードせずポインタ値をそのまま返す」ことで指示子へ戻り再退化し、
  `(*fp)(x)` / `(**fp)(x)` が自然に成立する。
- **スタック渡しは「逆順 push + 奇数個なら 8 バイト先行パッド」**: プロローグが
  rsp を常に 16 整列に保つ前提で、push 本数が奇数のときだけ先に sub rsp, 8 を
  入れて call 時点の整列を維持、復帰後に一括で回収。全引数は rbp 相対スロットに
  あるため rsp の変動が未ロード引数を壊さない。被呼び出し側はプロローグで
  [rbp + 16 + 8*(i−6)] から rax 経由でスロットへ写す。狭い整数パラメータの正規化は
  スロット格納後に効く既存のジェネレータ処理のままで済む。
- **`&配列` は基底アドレスの付け替え**: 配列変数はもともと基底アドレスに評価される
  ので、`&a` は同じ値を Pointer(Array) に retag するだけ。Pointer(Array) の deref は
  配列 lvalue(値文脈で要素ポインタへ再退化、sizeof では配列全体)。ポインタ加減算は
  既存の target.size スケールがそのまま「配列全体サイズ」で効く。
- **グローバルの関数アドレス定数は既存 GlobalReloc(:symbol) に相乗り**: `f` / `&f` を
  関数シンボルへの R_X86_64_64 として発行し、署名はローカル代入と同じ規則で検査。
  .data から外部関数を参照する場合の undefined symbol 登録を compiler.rb に追加
  (定義済み関数・グローバル名の集合と突き合わせ)。

**トレードオフ**: ブロックスコープの関数宣言(`int f(int);` を関数内で)は診断で
拒否(外部リンケージの意味論を持ち込まない)。関数型の struct メンバも診断
(関数ポインタは可)。`&arr[i]` 等の計算アドレス定数は引き続き未対応。多次元配列も
未対応のまま(配列の配列は接尾辞適用時に診断)。

---

## Step 22 — 記憶クラス・型修飾子・_Static_assert・_Alignof(8500270)

**内容**: 宣言指定子の拡張(static/extern/register/auto・const/volatile・inline)、
const 代入違反の診断、_Static_assert(6.7.10)、_Alignof(6.5.3.4)、static の
内部リンケージ(ELF ローカルシンボル)、ブロックスコープ static、extern 宣言。
実装は 2 段階に分割して移譲(第 1 段: 指定子・診断・アサーション、
第 2 段: リンケージ・記憶域。いずれも heavy-implementer)。

**設計判断**:
- **const は型に載せず宣言のフラグで追跡**: 型システムに Qualified ラッパを導入すると
  値等価比較(Pointer/FunctionType の Data 等価、代入互換、関数ポインタ署名)全体に
  修飾除去が波及するため、M1 では「宣言されたオブジェクトのトップレベル修飾」だけを
  VariableDecl/GlobalDecl/Parameter のフラグ → Local の const として伝搬し、
  単純代入・複合代入・++/-- を "assignment of read-only variable" で診断する。
  トップレベル判定: ポインタ派生が無ければ指定子の const、あれば最外ポインタ段の
  修飾(`int * const p` は const、`const int *p` は非 const)。ポインタ段の修飾は
  parse_pointer_qualifiers が「星 1 個につき const フラグ 1 個」のリストで返す。
- **typedef const は typedef エントリに併載**: OrdinaryName(:typedef) の value を
  [型, const] の対にし、使用側の指定子 const と OR。`typedef const int *cp;` は
  指し先修飾なので typedef 自体は非 const(同じトップレベル規則を適用)。
- **register/auto は 6.7.1 の重複検査にだけ参加して不記録**: DeclSpecInfo(storage,
  const, inline_p) に残るのは typedef/static/extern のみ。指定子は型指定子と任意順で
  混在可。allow_storage_class: false の文脈(メンバ・パラメータ・型名)でも
  const/volatile は合法(`int f(const int x)`、`sizeof(const int)`)。
- **_Static_assert は「何も生成しない宣言」**: typedef・タグ宣言と同じく空の宣言列を
  返し、AST に痕跡を残さない。評価は既存の定数式経路。_Alignof は SizeofType に並ぶ
  AlignofType として sizeof と同一の分担(パーサ→ジェネレータ畳み込み・ULong)で実装、
  定数式評価器にも同じ拒否条件(void・関数型・不完全型)で追加し配列境界に書ける。
- **シンボル表は bind 別 2 パスで構築**: ELF の「STB_LOCAL は最初の STB_GLOBAL より
  前」を、シンボル登録時に bind を持たせ build 時に [LOCAL, GLOBAL] の 2 パスで
  並べることで満たす(各パス内は従来の関数→オブジェクト順を保存、sh_info は既存の
  first_global_index がそのまま正しくなる)。API は add_local_func/add_local_object を
  新設(bind: 引数より呼び出し側が読みやすい)。
- **ブロックスコープ static は一意名グローバルへの降ろし**: シンボル名
  `<変数名>.<n>`(TU 全体の単調カウンタ、ソース順で決定的 = N4)。'.' は C 識別子に
  現れないため実シンボルと衝突しない。束縛は Local(global: true) にして既存の
  :global_addr 経路・グローバル初期化経路(定数畳み込み・GlobalInit・.bss)を
  そのまま再利用 — 「1 回だけ初期化」は .data/.bss 配置で構築時に満たされ、
  実行時初期化コードを出さない。
- **extern は「記憶域なしの束縛登録」**: @defined_globals(記憶域を確保した名前)を
  導入し、extern は @global_bindings への ||= 登録のみ。定義は前後どちらでも共存可、
  型不一致は "conflicting types for"、定義 2 個目のみ "redefinition"。定義されない
  参照は :global reloc 解決時に未定義シンボル登録(Step 21 の :call/:func と同じ流儀)。

**トレードオフ**: 指し先 const(`const int *p` の `*p = x`)・const 配列要素・const
struct メンバへの書き込みは検出しない(型レベル追跡を持たない意図的簡略化)。
volatile は完全に無視(最適化を行わない現段階では意味差なし)。ブロックスコープ
extern の束縛はブロックを超えて残る。宣言と定義の static/extern 不一致
(6.2.2p7 の未定義動作)は診断しない。括弧内ポインタの const(`int (* const p)[3]`)は
トップレベル判定に乗らず非 const 扱い(既知のギャップ)。

---

## Step 23 — 可変長引数(整数のみ)(ae4bf95)

**内容**: プロトタイプ・宣言子の `...`、可変部のデフォルト実引数昇格、可変長
呼び出しの al=0、__builtin_va_list / __builtin_va_start / __builtin_va_arg /
__builtin_va_end(SysV reg_save_area 方式、整数・ポインタのみ)。
実装は 2 段階に分割して移譲(第 1 段: 呼び出し側、第 2 段: 定義側。
いずれも heavy-implementer)。

**設計判断**:
- **variadic は FunctionType の値等価に参加**: Data.define(:return_type,
  :param_types, :variadic) にしたことで、関数ポインタ代入・グローバル初期化子の
  署名検査が専用分岐なしで自動的に厳密化される。`...` は宣言子接尾辞タプルの
  末尾に追加し、既存の function_params 抽出(suffix[1])を変更せずに通した。
- **al=0 は :call/:call_indirect の size フィールドで伝達**: call 系で size は
  未使用だったため「非 nil = 可変長 callee(値は固定パラメータ数)」と定義。
  backend は引数配置(間接なら r10 ロードも)後・call 直前に xor eax, eax を発行
  (EAX はスタック引数中継後で死んでいる)。
- **__builtin_va_list はヘッダでなく定義済み typedef**: プリプロセッサが無い
  段階(#include は Step 26)なので、パーサの最外 ordinary スコープに
  `__builtin_va_list` を登録する方式にした(ROADMAP の「同梱ヘッダで提供」からの
  意図的変更。stdarg.h は Step 26 で `typedef __builtin_va_list va_list;` として
  提供予定)。gcc も同名ビルトインを解するため、定義側の差分テストが同一ソースで
  成立する。型は SysV psABI の __va_list_tag struct(gp_offset/fp_offset u32、
  overflow_arg_area/reg_save_area void*、24 バイト)の要素数 1 配列 —
  psABI 由来のレイアウト・タグ名なので R11 に抵触しない。配列にしたことで、
  ローカルは減衰・パラメータは 6.7.6.3 調整でどちらも `__va_list_tag *` になり、
  va_list の関数間転送(vprintf 転送)が単一の型検査(タグ singleton への
  ポインタ、identity 比較)で成立する。
- **レジスタ退避領域はフレーム最下部の 48 バイト**: vreg 領域・stack object の
  下に置く(48 は 16 の倍数なので整列ロジック追加なし)。xmm は退避しない
  (浮動小数型が無い M1 では fp_offset=48 固定で xmm 側を読む経路が生じない。
  Step 24 で完成させる二段構え)。named パラメータの通常 spill はレジスタを
  読むだけなので、6 本全部の退避と順序依存がない。
- **新 backend 命令は :va_start のみ、va_arg は既存 IR に降ろす**: :va_start は
  reg_save_area のフレーム内位置(backend しか知らない)を要するため backend
  命令にし、4 フィールドを rax + r10 で店舗。va_arg は gp_offset の
  :uload → :ult 48 → 分岐 → 両腕が同じ結果スロット vreg に :copy して合流
  (vreg は SSA でないスロットなので合流が自然に書ける)という既存命令だけの
  展開。昇格対象型(char/short/_Bool)の va_arg は診断(C では UB)。
- **overflow_arg_area = rbp + 16 + 8×max(named−6, 0)**: named 7 個以上でも
  可変部の開始が正しくずれる(差分テストで named=1/7/8 を検証)。

**トレードオフ**: 浮動小数の可変長(al>0、xmm 退避、fp_offset)は Step 24。
struct の可変部渡し・va_arg(struct) は診断(Step 25 の SysV 分類と同時期に検討)。
va_copy は未提供(必要時に追加。M1 の rb_funcall/rb_raise 経路では不要)。

---

## Step 24 — float / double と SysV xmm 呼び出し規約 (04452c9)

**内容**: 浮動小数点定数(小数・指数・f/l 接尾辞・先頭/末尾ドット)、float/double
型、四則・全 6 比較・整数⇔浮動小数・float⇔double 変換、単項マイナス、浮動小数点の
条件式。ABI: xmm0-7 引数・xmm0 戻り値・可変長呼び出しの al = 使用 xmm 数・
176 バイトレジスタ退避領域・va_arg(ap, double)・float/double グローバル初期化子。
実装は 2 フェーズに分割して移譲(Phase A: 関数内演算、Phase B: 呼び出し境界。
いずれも heavy-implementer)。

**設計判断**:
- **浮動小数点値もスロット規約に乗せる**: float はスロット下位 4 バイトに IEEE754
  単精度(上位 32 bit は狭い整数と同様に不定)、double は 8 バイト全体。定数は
  :const が整数即値としてビットパターン(`[v].pack("E"/"e").unpack1(...)`)を
  実体化し、浮動小数点命令は xmm0/xmm1 スクラッチで movss/movsd によりスロットを
  直接読み書きする。フレーム構造・:copy・:store は変更ゼロで浮動小数型が入った。
- **単項マイナスは符号ビット :xor へ脱糖**: 専用命令を置かず、float 0x80000000 /
  double 0x8000000000000000 との整数 :xor(size 8)。-0.0 と NaN の符号反転も
  IEEE754 どおりになる。
- **NaN 対応比較は「above 系に寄せる」**: ucomis は NaN で CF=ZF=PF=1 になるため、
  :fgt/:fge は ucomis(a,b)+seta/setae、:flt/:fle はオペランドを反転した
  ucomis(b,a)+seta/setae で、大小 4 種すべてが NaN→0 に揃う。:feq は
  sete AND setnp(NaN で 0)、:fne は setne OR setp(NaN で 1)。
- **:call の b は [vreg, kind] ペア、size は [fixed, ret] ディスクリプタ**:
  引数のレジスタクラス(:gp/:sse4/:sse8)は型を知るジェネレータが分類し、
  backend は左→右ウォークで edi..r9d / xmm0..7 の「次の空き」に割り当てるだけ
  (あふれた引数はクラス問わず 8 バイトスロット内容のまま逆順 push)。
  Step 23 の「size 非 nil = 可変長」を [固定パラメータ数, 戻り値クラス] ペアに
  拡張し、al = 使用 xmm 数(mov al, imm8)と xmm0 戻り値回収を同じフィールドで
  伝達する。
- **Function.param_kinds でプロローグと :va_start を駆動**: パラメータの着信位置
  (GP/xmm/スタック)の導出と、可変長関数の gp_offset(8×min(GP,6))・
  fp_offset(48+16×min(SSE,8))・overflow 開始(スタック渡し named 数)の導出を
  すべて param_kinds から行う。:va_start の b(固定パラメータ数)は残るが未使用。
- **xmm 退避は al ガードなしの常時 8 本**: al で退避を分岐する定石に対し、
  発行コードが実引数個数に依存しない方が決定的(N4)で分岐 1 つ分単純。
  各 16 バイト psABI スロットの下位 8 バイトのみ movsd で保存
  (va_arg(double) が読み戻すのはその 8 バイトだけ)。
- **可変長部の float は :ftof で double へ昇格**(6.5.2.2p6)し :sse8 で渡す。
  va_arg(ap, float) は promotable-type 診断(char/short と同じ扱い)。
  va_arg(double) は fp_offset の :uload → :ult 176 → 分岐(レジスタ側 +=16 /
  あふれ側 +=8)という Step 23 の GP 側と同型の展開。
- **グローバル初期化子は Ruby Float の pack で畳み込み**: FloatLit・単項マイナス・
  整数定数を IEEE754 像へ(double は pack("E")、float は pack("e") が単精度への
  正しい丸めを行う)。浮動定数→整数グローバルは to_i(ゼロ方向切り捨て、6.3.1.4)。
- **チェックポイント運用**: Phase A 完了時に [WIP] コミットを作り、Phase B 完了後に
  `git reset --soft` で 1 コミットへ統合した。移譲エージェントがセッション上限で
  中断される事故(本ステップで実際に発生)から確定済み作業を守るため。
  「1 ステップ 1 コミット」の最終形は維持。

**トレードオフ**: unsigned long ⇔ float/double 変換は未対応(64 bit 符号無しの
往復に追加コードが要るため診断で拒否。既知の負債として ROADMAP に記載)。
long double は double 扱い(DESIGN 3.3)、x87 は一切使わない。float のスタック渡しは
「スロット下位 4 バイトが有効」の規約で 8 バイト push に統一。

---

## Step 25 — struct の値渡し・値返し(SysV eightbyte 分類)(54389f9)

**内容**: struct/union を関数の引数・戻り値として値で渡す。System V AMD64 psABI
3.2.3 の eightbyte 分類(INTEGER/SSE/MEMORY)、引数の all-or-nothing 配置、
16 バイト超の MEMORY 戻り値の隠れ結果ポインタ、レジスタ戻り(rax/rdx・xmm0/xmm1)。
実装は 3 フェーズに分割(Phase A: ジェネレータ側配置決定(:mem kind)への契約移行、
Phase B: struct 本体(heavy-implementer)、Phase C: gcc ↔ rubycc クロスリンク
ABI ハーネス(implementer))。

**設計判断**:
- **バックエンドは struct を知らないまま**: 全機構を eightbyte 粒度の既存命令
  (:memcpy・size 8 の :load/:store・:object_addr)への降ろしで実現。struct 引数は
  スクラッチ stack object へ :memcpy してから 8 バイトずつ :load(stack object は
  16 バイト整列・切り上げ確保なので、サイズが 8 の倍数でない struct でも末尾
  eightbyte の 8 バイト読みが領域内に収まる — 端数サイズ対策を構造的に解決)。
- **配置決定をジェネレータへ移動(:mem kind の導入、Phase A)**: psABI の
  all-or-nothing 規則は「引数全体の eightbyte 列が両クラスのレジスタ残数に収まるか」
  を要し、それを知るのは型を持つジェネレータだけ。place_argument_kinds が呼び出しと
  パラメータの両方で同じ配置シミュレーションを走らせ、バックエンドは指定された
  kind(:gp/:sse4/:sse8/:mem)に従うだけ(超過は契約違反 raise)。
- **分類は psABI 仕様から直接実装**: classify_eightbytes が member offset で再帰
  (ネスト struct/union、配列は要素ごと)し、eightbyte ごとに INTEGER 優先 /
  NO_CLASS→SSE でマージ。SSE eightbyte は常に :sse8(movsd 1 本で packed float
  2 個も運べる)。本サブセットは自然整列のみなのでスカラが eightbyte 境界を
  跨ぐことはない。
- **MEMORY 戻りは「隠れポインタ = 先頭の :gp 引数」**: caller はスクラッチバッファの
  アドレスを [addr, :gp] ペアとして引数列の先頭に挿入(配置シミュレーションが
  rdi を消費)し、callee は psABI どおりそのポインタを rax で返すので、dst の
  回収は通常のスカラ呼び出しと同一 — バックエンド変更ゼロ。callee 側は隠れ
  ポインタを合成第 0 パラメータとして受け、`return expr;` は隠れポインタへの
  :memcpy + そのポインタの size nil :ret。
- **レジスタ戻りは :call の ret = [buffer_vreg, classes] / :ret の size = クラス配列**:
  callee はスクラッチへ :memcpy 後、バックエンドが [rcx+8i] から INTEGER =
  rax→rdx / SSE = xmm0→xmm1 の順に収集して leave/ret。caller 側は call 後に同じ
  ウォークで戻りレジスタをバッファへ散布。バッファアドレスは rcx 経由
  (戻りレジスタと重ならない)。dst = nil で、式の値はバッファアドレス。
- **param_count/param_kinds を「ABI スロット列」に一般化**: スカラ 1 スロット、
  struct は分類された eightbyte 数(MEMORY は ceil(size/8) 個の :mem)、MEMORY 戻り
  関数は隠れポインタが先頭スロット。スロットが vreg 0..param_count-1 を占め、
  struct パラメータの再組み立て(スロット → stack object への :store)は
  ジェネレータがプロローグ IR で行う。:va_start の gp_offset/fp_offset/overflow は
  param_kinds の count(:gp)/count(:sse*)/count(:mem) から導出。
- **クロスリンク差分ハーネス(Phase C、R9 / DESIGN 6 章テスト 3 の先行版)**:
  固定シードの乱数で 40 個の struct レイアウト(メンバ 1〜4、char〜double・
  小配列・ネスト struct、先行 int 0〜5 個)を生成し、caller と callee を
  別コンパイラでビルドして 1 実行ファイルにリンク。gcc×gcc をオラクルに、
  gcc caller × rubycc callee / rubycc caller × gcc callee の stdout(全メンバの
  printf)+ 終了コードを突き合わせる。自己無撞着なだけの ABI 実装
  (caller/callee とも rubycc なら整合して見える)を排除する。
- **ハーネスが既存バグを即座に発見**: アドレス経由の代入 6 経路(添字・メンバ・
  ポインタの単純/複合代入)が convert_for_assignment を通さず store していた
  (int→long の符号拡張欠落、int→float/double の itof 欠落、複合代入の
  double→float 縮小欠落)。変数代入経路と同じ変換を入れて修正し、回帰テスト
  STORE_CONVERSION_DIFFERENTIAL_SOURCES を追加。ランダムレイアウト×クロスリンクの
  網羅性が、手書きテストの「型が揃った代入ばかり書く」バイアスを突破した実例。
- **チェックポイント運用の継続**: Phase A/B をそれぞれ [WIP] コミットにし、
  Phase C 完了後に `git reset --soft` で 1 コミットへ統合(Step 24 で確立した運用。
  本ステップでも移譲エージェントのセッション上限中断が 2 回発生し、有効だった)。

**トレードオフ**: 不完全型 struct の param/return は宣言時点で診断エラー
(C は未呼び出しのプロトタイプなら許すが、分類にレイアウトが要るため簡略化)。
可変長部への struct 渡しと va_arg(struct) は未対応のまま(既知の負債)。
末尾到達 UB の struct 戻りはクラッシュ防止形(MEMORY = 隠れポインタを返す /
レジスタ = rax に 0)で処理。

---

## Step 26 — プリプロセッサ・コア(翻訳フェーズ 1〜4)(3048586)

**内容**: pp トークナイザ(行継続・コメント・newline トークン)、#include(-I、
"" と <>)、#define(オブジェクトマクロ)/#undef、マクロ展開(再走査・自己参照
抑制)、#if/#ifdef/#ifndef/#elif/#else/#endif(defined 演算子・Step 20 の
ConstantEvaluator 流用)、#error、CLI -I、行番号維持(N3)。関数マクロ・#/##・
定義済みマクロは Step 27。実装は 3 フェーズ(A: トークナイザとパイプライン統合、
B: #include とオブジェクトマクロ、C: 条件コンパイルとハーネス。A/B/C とも
heavy-implementer)。

**設計判断**:
- **pp トークナイザは既存 Lexer と別物、最後に Front::Token へ 1:1 変換**:
  ISO C 6.4 の preprocessing-token 分類(identifier / pp-number / string / char /
  punct / other + 明示 newline)。ディレクティブが行指向なので newline を
  トークンとして残し、変換段(フェーズ 4 終端)で落とす。
- **行継続は「カーソル不変条件」で処理**: 事前のソース書き換えは桁情報を壊す
  ため不採用。スキャナのカーソルが「splice(\ + 改行)の上に止まらない」不変条件を
  保ち、advance/peek が透過的に跨ぐ。トークンは物理行の位置を持ち、跨いだ
  トークンは開始位置を採る。// コメント末尾の \ が次行を巻き込む gcc 挙動も
  この機構から自然に出る。
- **数値・エスケープ・キーワード判定を LexemeReader へ抽出**: 位置非依存の
  復号器(LexError はオフセット持ちで、呼び出し側が行/桁へ写像)を既存 Lexer と
  pp 変換段が共有し、両経路のトークンが byte-for-byte 一致することを構造的に
  保証。pp 単体テストが「pp 出力 == Lexer 出力」の同一性を直接検証する。
- **pp-number は 6.4.8 の広い形で走査し、C 定数としての妥当性は変換段で診断**:
  "12abc" や "1.2.3" は pp トークンとしては合法、Front::Token 化で拒否。
- **自己参照抑制は hide set ではなく展開再帰スタックの名前集合**: オブジェクト
  マクロのみの範囲では 6.10.3.4 と等価でより単純(R11 上も既存実装の定石を
  避ける)。展開で生まれたトークンは呼び出し箇所の位置を継承(診断が使用箇所を
  指す)。関数マクロ(Step 27)で必要になれば拡張する。
- **#include のヘッダ名はディレクティブ側で逐語再構成**: Scanner は header-name を
  特別扱いせず、#include 行に限り "file" は :string の内側、<file> は < 〜 > の
  text 連結で復元(6.10.2 の逐語規則。マクロ展開する第 3 形式は未対応)。
  quote は includer のディレクトリ → -I、angle は -I のみ。includee は同一
  マクロ表で再帰処理し、トークンは includee の filename/行を保持(N3)。
  深さ上限 200。
- **space_before フラグ**: `#define F(x)`(関数マクロ形式 — Step 27 まで診断)と
  `#define F (x)`(置換列が ( で始まるオブジェクトマクロ)の判別に、トークンへ
  「直前に空白/コメントがあったか」を 1 bit だけ持たせた。Step 27 の関数マクロ
  判定でも再利用する。
- **#if の定数式は「defined 置換 → マクロ展開 → 残存識別子を 0 → pp 専用
  条件式パーサ → ConstantEvaluator」**(6.10.1): パーサは integer constant
  expression の範囲だけ(キャスト・sizeof・カンマ・代入なし)を受理し、既存の
  Front::AST ノードを構築して Step 20 の評価器を無変更で流用。浮動定数は診断。
  パーサは Front::Parser の階層下降を写さず、優先順位表駆動の precedence
  climbing(二項全体を 1 メソッド)で構成(R11)。キーワード綴り(sizeof 等)は
  pp 段では識別子なので 0 中和により文法から自然に排除される。
- **スキップ中の group は条件ディレクティブのみ解釈**: ネスト追跡と #elif/#else/
  #endif の処理だけ行い、#include/#define/#error・不正ディレクティブ・通常行は
  無視(gcc 同様)。内側 #if の条件式は評価しない。条件スタックは
  process_lines(=ファイル)ごとにローカルで、include を跨ぐ開閉は構造的に
  不可能 — ファイル単位のバランス検査(未クローズは unterminated 診断)。
- **検証は 3 層**: pp 単体(トークン列・位置・診断)、gcc -E -P とのトークン列
  差分(gcc の出力を既存 Lexer で字句解析し type/value 列で比較 — テキスト比較
  より頑健)、実行差分(条件コンパイルで戻り値が変わる C を run_source で比較)。
  test_examples はサンプルを実パスからコンパイルする方式に変更し、quote include が
  examples/m1 基準で解決されるようにした。

**トレードオフ**: #if の算術は評価器の任意精度のまま(6.10.1p4 の intmax_t 幅
ラップは未実装 — 実害の出る境界値が現れた時点で対応)。マクロ再定義の同一性
判定はトークン字面列の一致(空白位置の同一性 6.10.3p2 までは見ない)。#include の
マクロ展開形式(第 3 形式)、#line、_Pragma は未対応(ROADMAP どおり受理のみ
順次)。ヘッダ名内の空白は表現不可(< > の text 連結)。

---

## Step 27 — プリプロセッサ完成(関数マクロ・#/##・定義済みマクロ)(d3cdda5)

**内容**: 関数マクロ(引数展開・再走査・自己参照の青染め)、# 文字列化と ##
連結、可変引数マクロ(__VA_ARGS__)、定義済みマクロ(__FILE__ __LINE__ __STDC__
__STDC_VERSION__ __RUBYCC__ — **__GNUC__ は定義しない**: DESIGN R7)、#if 式の
__has_include / __has_attribute / __has_builtin、#pragma once。実装は 2 フェーズ
(A: 関数マクロと青染め、B: #/## とビルトイン。両方 heavy-implementer)。

**設計判断**:
- **展開は作業キュー + トークン単位の suppress(青染め)配列**: キュー先頭を
  取り出し、置換結果をキュー先頭へ戻して再走査(6.10.3.4)。各トークンが
  「自分を展開してはいけないマクロ名の凍結配列」を持ち、Prosser の hide-set
  交差ではなく次の置換規則で塗る — 引数は先に完全展開して**自身の paint を
  保持**、リテラル置換トークンだけが「呼び出しトークンの paint + マクロ名」を
  受け取る。`#define f(x) f(x)` の f(1)→f(1)、`#define g f` 越しの g(3)→3、
  f(f)(1)→1、相互再帰 a→b(a) の停止、の 4 挙動を gcc と一致させた。病的な
  自己入れ子(Prosser 交差が要る例)は gcc と発散し得ることを既知の逸脱として
  記録し、差分テストの題材からは意図的に外した(R11 上も定石実装を避ける)。
- **引数は raw / expanded の二重表現(Invocation 構造体)**: raw は未展開
  トークン列(# と ## のオペランド)、expanded は遅延メモ化した完全展開形
  (通常のパラメータ参照)。同じパラメータを何度使っても展開は 1 回、# / ##
  専用の引数は一度も展開されない(6.10.3.1p1)。トップレベルのコンマトークン
  自体も保持し、#__VA_ARGS__ が呼び出しの綴りを空白込みで再現する(gcc 実測:
  `S(a ,b)` → `"a ,b"` — コンマ前の空白も残る)。
- **# 文字列化(6.10.3.2)**: 定義時に「関数マクロの # の直後はパラメータか
  __VA_ARGS__」を検査(オブジェクトマクロの # は通常トークンのまま変換段の
  stray '#' 診断に任せる)。綴りは raw 引数を空白 1 個へ正規化し両端は落とす。
  文字列・文字リテラル内の " と \ のみエスケープ。結果はリテラル規則で paint
  した :string pp トークン。
- **## 連結は substitute の 1 パス内で span カーソル方式(6.10.3.3)**: 直前に
  置いた置換要素が何トークン寄与したかを span で追跡し、0 をプレースマーカー
  (空引数)として表現 — 専用のプレースマーカートークンを導入しない。左端の
  最終トークンと右オペランドの先頭トークンの綴りを連結して Scanner で再字句化、
  ちょうど 1 pp トークンでなければ診断。左から右への連鎖は構造上自然に出る。
  貼り付け結果はリテラル paint を受けてキューへ戻り、マクロ名を成せば再展開、
  自分自身の名を成せば paint で止まる。
- **定義済みマクロは置換リストではなく使用地点からの動的展開**: __FILE__ /
  __LINE__ は使用トークンの filename / line から生成(6.10.8.1)、include 先では
  ヘッダの値になる。ビルトインと defined の #define / #undef は診断(6.10.8.4)。
  ビルトインの展開結果は非識別子なので paint も再帰も不要。__STDC_VERSION__ は
  ホスト gcc が C17(201710L)でも **201112L(C11)に固定**(本プロジェクトの
  対象規格。ビルトイン定数は gcc 差分に載らないためユニットテストで検証)。
- **__has_* は #if の defined と同段で畳み込み**: 演算子表(PP_OPERATORS)で
  defined / __has_include / __has_attribute / __has_builtin を 1/0 の pp-number へ
  置換してからマクロ展開へ渡す(6.10.1p1 のオペランド非展開)。__has_include は
  resolve_include と同じ探索(quote は問い合わせ元のディレクトリ → -I、angle は
  -I のみ)を**読まずに** File.file? で判定。__has_attribute は Step 28 で
  aligned/packed に 1 を返すまで常に 0。__has_builtin は varargs 組み込み
  (__builtin_va_start/va_arg/va_end)のみ 1。#if の外では全て通常の識別子。
- **#pragma once は File.expand_path キーの集合**: #include 解決後・読み込み前に
  照合して 2 回目以降を丸ごとスキップ。その他の #pragma は受理して無視
  (gcc 固有 pragma で診断爆死しないため)。_Pragma は未対応(ROADMAP どおり)。

**トレードオフ**: hide-set 交差なしの青染めは病的な自己入れ子で gcc と発散し得る
(上記)。`+ ## +` → `++` のような「有効だが意外な」貼り付けは gcc 同様に許容。
#__VA_ARGS__ の空白再現はコンマトークンの space_before 粒度(コメント由来の
空白も 1 個の空白になる)。

---

## Step 28 — GNU 拡張と ISO 適合の仕上げ、ruby.h スモークテスト(M1 完了)(c2f4f71)

**内容**: __attribute__((...)) 構文受理と aligned/packed の実レイアウト、
__builtin_expect / __builtin_alloca / 空インライン asm、そして「`#include <ruby.h>`
を .o までコンパイルする」M1 完了判定に向けた反復プローブ駆動の適合修正群:
定義済みターゲット/数値リミットマクロ、#include_next、_Pragma、隣接文字列連結、
L'x'、ビットフィールドレイアウト、__int128 最小サブセット、一時定義ほか宣言まわりの
ISO 適合、c-testsuite 220 ケースのベンダリングと常時実行ハーネス。
実装は 8 フェーズ(A/B/C1〜C4/C5b = heavy-implementer(C1 のみ implementer)、
C5a = implementer)。C 系は「実ヘッダを試しにコンパイル → 最初の診断を修正 →
再試行」の反復で範囲を確定した。

**設計判断**:
- **__attribute__ は全宣言位置 + 型名/抽象宣言子で構文受理、意味は struct/union の
  aligned/packed のみ**: Ruby の config.h(実 gcc で生成されたビルド成果物)が
  CONSTFUNC 等を生の __attribute__ で無条件定義するため受理は回避不能。
  struct RBasic の aligned(8) は ABI 実体なので、StructType#define(packed:,
  aligned:) にレイアウト上書きを実装。裸 aligned = 16(BIGGEST_ALIGNMENT)。
- **packed の psABI 帰結**: 非整列フィールドを持つ集合体は MEMORY クラス
  (psABI 3.2.3)。classify_struct に unaligned_field? ガードを追加 —
  同一コンパイラの差分テストでは出ず、クロスコンパイラ検証(rubycc ユニット ↔
  gcc ユニット)で顕在化した実 ABI 差。
- **__builtin_alloca は「rsp を恒久的に動かす」初の op**: :alloca は 16 の倍数へ
  切り上げて sub rsp。正しさは新規の簿記ではなく既存不変条件(全値 rbp 相対、
  push 方式の自己回収する引数積み、leave エピローグ)に依拠。
  __builtin_expect は両オペランドを long へ変換し値は exp(最適化器が無いので
  ヒントは無意味)。インライン asm は空テンプレート+空オペランドのみ受理、
  クロバー文字列は破棄(並べ替えをしない処理系ではメモリバリアは自然に no-op)。
- **プローブ駆動の C フェーズ**: 実ヘッダの最初の診断を直し再試行する反復で、
  当初調査の見落とし 3 点が判明 — (1) _Pragma は config.h が無条件に吐く、
  (2) ビットフィールドは glibc の bits/timex.h(無名 int :32 パディング)経由で
  到達する、(3) gcc の数値リミット定義済みマクロ(__LONG_MAX__ 等)に glibc が
  __GNUC__ 不在時も依存する。「調査 → 一括実装」より「診断 → 修正 → 再試行」の
  ループの方が実ヘッダ相手には正確だった。
- **定義済みマクロは「予約形のみ・#undef 可能な普通のマクロ」**: ターゲット系
  (__x86_64__ __linux__ __LP64__ 等 9 種)と数値系(__LONG_MAX__ 等 27 種、
  gcc -dM の綴りを 16 進・サフィックス込みで一致)。__GNUC__・非予約形
  (linux/unix)は定義しない(R7)。置換列は Scanner で再走査して生成
  (__WCHAR_MIN__ の複数トークン式も特別扱い不要)。
- **#include_next は「-I 起点インデックスの再開」**: 各ファイルの解決元 -I
  ディレクトリを記録し、その次から探索。起点なし(主ファイル・quote 相対)は
  gcc と同じく通常 #include にフォールバック。gcc fixinclude の limits.h 連鎖が
  要求(gcc の内部 include ディレクトリは stdarg.h/stddef.h の唯一の供給元なので
  探索パスから外せない)。
- **__has_* は「defined に応える」「展開後にも畳む」**: gcc 同様
  defined(__has_builtin) は 1(偽だと ruby は config.h の焼き込み
  HAVE_BUILTIN_* へフォールバックし __builtin_unreachable を吐く)。
  RBIMPL_HAS_BUILTIN(x)→__has_builtin(x) のようなマクロ包みは展開後に演算子が
  現れるため、#if 評価で展開後に fold_operators を再実行(fold はオペランドを
  展開しないため 1 パスで停止)。
- **翻訳フェーズ 6(隣接文字列連結)は TokenConverter**: パイプライン上
  フェーズ 5〜7 が住む場所。エスケープはリテラル毎に復号してから連結
  ("\x41" "1" ≠ "\x411"、6.4.5p4)。ストリーミング Lexer(ユニットテスト専用路)は
  意図的に連結しない。
- **_Pragma は再走査中に 4 トークン消費して破棄**: ディレクティブでなく演算子として
  処理するのでマクロ産出形(config.h の RUBY_SYMBOL_EXPORT_BEGIN =
  _Pragma("GCC visibility push(default)"))にも効く。
- **ビットフィールドは「レイアウトは忠実、アクセスは診断」**: ビットカーソルで
  単位跨ぎ禁止・:0 強制整列・無名は整列に不寄与(psABI)を実装し、sizeof/_Alignof
  を gcc と全一致(struct timex 208 バイト実測込み)。読み書き・& は
  「bit-field access is not supported yet」(M2 負債)。ABI 分類はビットが跨る
  eightbyte 全てに INTEGER を寄与、packed の非整列テストからは除外。
  packed + ビットフィールドの組合せは診断。
- **__int128 は「16 バイト struct 的オブジェクト」表現**: 16 バイト vreg を
  導入せず、値=スタックオブジェクトのアドレス(low +0 / high +8)。演算は半語の
  64 ビット op へ展開 — 乗算は新 IR op :mulhi(mul r64 の rdx)+ :mul + :add、
  加減算はキャリー/ボロー手計算、比較は high 優先の分岐無し合成。変換は
  符号/ゼロ充填と low 半語切り捨て。除算・シフト・ビット演算・値渡し/返し・
  可変長渡しは診断(到達コーパスは rb_mul_size_overflow の乗算・比較・変換と
  onigmo.h のメンバレイアウトのみ)。struct メンバは 2 eightbyte とも INTEGER。
- **一時定義(6.9.2)は ObjectRecord マージ表**: 「2 回目の定義は即エラー」から
  「型一致でマージ・初期化子は 1 回だけ・後着初期化子が .bss を .data に昇格」へ。
  static/非 static 混在は双方向診断。
- **enum の不完全型と in-place 完成**: 未定義タグは Type::EnumType として前方宣言
  (不完全 struct の鏡映)。定義到達時に complete! でその場で int として振る舞い
  始め、先行プロトタイプが捕まえた型と後続参照(Int 解決)の同一性が成立する。
- **typedef 経由の関数宣言**: 宣言子自身にパラメータ並びが無い場合、typedef の
  FunctionType から無名パラメータを合成してプロトタイプ化(intern.h の
  rb_gvar_getter_t 群)。typedef 経由の関数「定義」は 6.9.1p2 で診断。
- **c-testsuite は「ベンダリング + 明示スキップ表」**: 220 ケースを
  test/external/ に取り込み(LICENSE・.otags の出自記録込み)、upstream posix
  ランナーと同じ合否(コンパイル・リンク(-lm)・exit 0・stdout+stderr バイト
  一致)。スキップは理由 1 行付きハッシュで、消し込みがそのまま進捗になる。
  201/220 合格・19 スキップ・0 失敗。R11 はテストケースの流用を妨げない
  (ROADMAP が明示計画)。
- **既知の逸脱の実証**: 00201(CAT(A,B)(x) の CAT2 経由再展開)が Step 27 の
  Prosser hide-set 交差逸脱の実世界再現と確定。修正方針(置換 paint を
  「呼び出し名の suppress ∩ 閉じ括弧の suppress + 自名」にする)まで記録し M2 へ。

**M1 完了判定**: (1) c-testsuite 201/220 合格(スキップは全て理由記録済みの
機能不足、失敗ゼロ・誤コンパイルゼロ)。(2) test/test_ruby_smoke.rb —
`#include <ruby.h>` + rb_define_module、および LONG2NUM/NUM2LONG/
rb_define_module_function を使う実質的な拡張ソースが ELF64 .o まで
コンパイルできる(リンクは M2)。glibc 開発ヘッダは実システムのものを使用
(同梱ヘッダは B7/M5)。

**トレードオフ**: メンバ単位 packed/aligned は受理のみ。ビットフィールド
アクセス・128 ビットの除算/シフト等・ワイド文字列・VLA・_Generic・
compound literal・文式 ({…})(Data_Make_Struct が要求、早期 M2)・
#pragma push_macro/pop_macro・K&R の int () 型・enum の unsigned 底型
(00170 の残り)は未対応(スキップ表と ROADMAP に記録)。restrict / [static N]
は受理して破棄。__STDC_VERSION__ は 201112L 固定。

---

## Step 29 — ELF リーダ(M2 L1: .o の読み戻しと .so の動的シンボル)(96aefa6)

**内容**: Rubycc::ObjFile::ELFReader(ELFWriter の対)。ET_REL のフルパース
(セクション・.symtab・SHT_RELA)と、ET_DYN の動的リンクインターフェイス読み取り
(.dynsym / DT_SONAME / DT_NEEDED)。M2 の最初のステップ(計画ラベル L1)。
コンパイラ本体とは独立した新コンポーネント(heavy-implementer 1 フェーズ)。

**設計判断**:
- **load-then-query 型のオブジェクトモデル**: read/read_file が画像全体を先に
  解析し、配列 + 名前引き(section/symbol/dynamic_symbol/relocations_for)を
  提供する。ストリーミング/コールバック型にしなかったのは、L3 リンカが
  セクション・シンボル・再配置へランダムアクセスするため。値オブジェクトは
  Ruby Struct(Section/Symbol/Relocation/RelocationSection/DynamicEntry)で、
  binding/type/visibility は :local/:global/:weak 等のシンボルへ復号
  (未知値は整数のまま通す)。
- **未知の再配置タイプは拒否せず数値で保持**(type_name のみ nil): 見慣れない
  オブジェクトも読める状態を保ち、扱えるかどうかの判断は適用側(L3)に委ねる。
- **RELA は sh_info の対象セクション毎にグループ化**(RelocationSection#target):
  リンカの fixup 適用がセクション単位の走査になる形をそのまま表現。シンボル解決は
  各 RELA セクションの sh_link が指すシンボルテーブル経由(.symtab と .dynsym を
  テーブル毎に保持)。
- **.so はセクションヘッダ経由のみ**(sh_size / sh_entsize 第一経路): alloc
  セクションは strip で消えないため、セクションヘッダ無し .so への PT_DYNAMIC
  フォールバック(DT_HASH/DT_GNU_HASH からの個数導出)は ROADMAP どおり YAGNI と
  して非実装をコメントで明示。verdef/verneed(シンボルバージョニング)も無視。
- **e_shnum==0 / SHN_XINDEX の第 0 セクション経由エスケープ**は、現入力では
  発火しないが実物 .so の頑健性のため最小実装。全構造読み取りは境界検査付きで、
  切り詰め・不整合は ELFFormatError(欠陥を名指しするメッセージ)。
- **検証 3 層(N7 の背骨)**: (1) ELFWriter の全機能マトリクス(text/rodata/
  data+R_X86_64_64/bss/local/global/undefined/PLT32/PC32/FILE シンボル)との
  ラウンドトリップ golden — 書いた構造がそのまま読み戻ることでライタ・リーダ
  双方の契約を固定。(2) rubycc と gcc 両方の実 .o(gcc 版はバージョン差に頑健な
  「存在と関係」のみ検証)。(3) readelf -s / -d / --dyn-syms との行単位
  突き合わせ + 実物 libc.so.6(printf/malloc がエクスポートされ SONAME が
  libc.so.6)。readelf / libc 不在環境は skip ガード。
- **examples のステップサンプルは対象外**: ELF リーダは C 言語機能を追加しない
  (「そのステップで書けるようになった C」が存在しない)ため、examples/ の
  ステップ毎サンプルの慣習は M2 ではコンパイラ機能に触れるステップ(L4 の PIC
  等)にのみ適用する。

**トレードオフ**: ET_EXEC(実行ファイル)は読まない(L7 で必要になれば拡張)。
プログラムヘッダは未解析(ET_REL に不要、.so は SONAME 用途のみ)。シンボル
バージョン付き名(printf@GLIBC_2.2.5 等)は .dynstr の生の名前のまま。

---

## Step 30 — ar アーカイバ(M2 L2: GNU 形式の読み書きと rubycc-ar CLI)(1314bae)

**内容**: Rubycc::ObjFile::ArReader / ArWriter(GNU ar 形式)と exe/rubycc-ar。
mkmf が叩く `$(AR) rcs` の代替、および L3 リンカの静的ライブラリ読み取り経路。
heavy-implementer 1 フェーズ。

**設計判断**:
- **リーダは load-then-query、ライタはビルダ**: ELFReader / ELFWriter と同じ
  流儀で統一。リーダは members(ファイル順)に加え、`/` インデックスを
  symbols(生の順序)と symbol_index(先勝ちハッシュ)の両形で公開し、
  member_defining(name) が「この未解決シンボルを定義するメンバは?」という
  L3 の遅延取り込み照会そのものになる。
- **シンボルインデックスは書き込み時に常時生成**(ranlib 相当): 各メンバの
  バイト列を ELFReader に渡して定義済み global/weak のみ収集(手書きの ELF
  解析はしない — コンポーネント間で解析器を 1 つに保つ)。非 ELF メンバは
  寄与ゼロ。インデックスのサイズはシンボル名と個数のみに依存するため、
  記録するメンバオフセットとの鶏卵問題は生じない。
- **決定的出力(N4)**: mtime/uid/gid = 0、通常メンバ mode = 644、予約メンバ
  (`/`・`//`)は mode 0 — Debian の `ar rcsD`(deterministic モード)と
  同一の値に固定し、同一入力 → バイト同一を検証。
- **60 バイトヘッダのフィールド配置**は name(0,16)/mtime(16,12)/uid(28,6)/
  gid(34,6)/mode(40,8)/size(48,10)/`\x60\n`(58,2)。mode を 42 に置く
  off-by-two をやりがち(実装中に実際に踏んだ)なので記録。データは奇数長の
  ときだけ `\n` 1 個で偶数境界へ(size フィールドは実バイト数のみ)。
- **長名は `//` テーブル**: `name/` が 16 バイトに収まらない名前だけを
  `/\n` 終端で並べ、ヘッダからは `/N`(テーブルへの 10 進バイトオフセット)で
  参照。短名の末尾 `/` は名前の終端マーカー。
- **リーダの許容度**: インデックス無し(`ar qc` 出力)は symbols 空で受理。
  未知オフセットを指すシンボルは致命でなくスキップ。bad magic・ヘッダ切り詰め・
  `\x60\n` 欠落・EOF 越え size は ArFormatError(欠陥名指し)。
- **CLI は 1 語目の結合フラグ**(`rcs` / `-rcs` / `t` / `x`): r=置換または追記
  (既存メンバは順序保存で差し替え)、t=一覧、x=抽出、s 単独=インデックス
  再生成。c/s/u/D 等の修飾子は本実装が常時満たす性質(作成許可・インデックス
  常時生成・決定的出力)なので no-op で受理。
- **相互運用は双方向で検証**: rubycc-ar 出力 → system `ar t`/`ar x`(メンバ
  バイト同一)/`nm -s`(インデックス可視)、system `ar rcsD` 出力(長名込み)→
  本リーダで一覧・抽出・インデックス読み取り。

**トレードオフ**: BSD ar 形式・`ar d/m/p/q` 等の残り操作・thin archive は
対象外(mkmf 経路に不要)。examples のステップサンプルは Step 29 と同じ理由で
対象外(C 言語機能を追加しないステップ)。

---

## Step 31 — 静的リンクコア(M2 L3 前半: ld -r 併合)(f4417c3)

**内容**: Rubycc::Link::PartialLinker — 複数 ET_REL オブジェクト + ar アーカイブを
単一 ET_REL へ併合する `ld -r` 相当。再配置は付け替えのみで適用しない(適用
エンジンは L5/L7 の最終リンク側)。汎用 ET_REL ライタ
Rubycc::ObjFile::RelocatableWriter を併設。heavy-implementer 1 フェーズ。

**設計判断**:
- **L3 を「ld -r(付け替え)」と「最終リンク(適用)」に分割**: ROADMAP の
  中間マイルストーンをそのまま独立ステップにした。ld -r 出力は再配置を保持する
  ものなので、バイトパッチ無しで「併合の正しさ」だけを先に固められる —
  受け入れ検証も「rubycc .o 群を本コアで併合 → 単一 .o を gcc でリンクして
  実行結果一致」という強い形にできる。
- **リンカ IR は作らない**(ROADMAP): ELFReader が返す構造の上で直接、
  選択(左→右、.o 無条件・アーカイブは未解決シンボル駆動で同一アーカイブ内
  不動点まで・通過済み再訪なしの古典的 single-pass)→ 併合(セクション結合・
  シンボル解決・再配置付け替え)の 2 フェーズ。
- **汎用 RelocatableWriter を新設**: コンパイラの ELFWriter は固定セクション
  メニュー + 固定再配置種別で ld -r 出力(任意セクション集合・任意タイプ/addend・
  出力セクションシンボル)を表現できない。流用で歪めず併存させ、コンパイラは
  従来のライタのまま。新ライタは build-then-emit(add_section/add_symbol/
  add_relocation がハンドルを返し identity で参照)で、ELFReader との
  ラウンドトリップで検証。
- **セクションシンボル参照の addend 補正が唯一の微妙な点**: 入力断片が出力
  セクション内の新オフセットへ動くため、セクションシンボル基準の addend には
  断片の配置オフセットを加算して出力セクションシンボルへ付け替える。名前付き
  シンボル参照はシンボル値自体がシフト済みなので addend 不変。ユニットと
  readelf -r の実測(`.rodata + 6` の生存)で検証。
- **シンボル解決規則**: strong+strong は両入力を名指しする multiple definition
  エラー、strong>weak、weak+weak 先勝ち、defined>undefined、全 UND は UND の
  まま(ld -r で合法)、COMMON は非対応診断(rubycc も gcc の -fno-common 既定も
  出さない)。エラーは Link::LinkError(CompileError とは別系統)。
- **開発中に踏んだ罠(記録)**: Ruby の Struct は値ハッシュなので、レイアウト中に
  index を書き換える Section 構造体を Hash キーにすると突然引けなくなる —
  再配置のグループ化が全滅し .rela が丸ごと消えた。identity(equal?)照合へ修正。
  「ミュータブルな Struct を Hash キーにしない」は本リポジトリの一般則にする。
- **検証**: 併合 .o の gcc リンク実行一致(関数呼び出し PLT32・グローバル PC32・
  rodata 文字列のセクションシンボル再配置・.bss 横断)、gcc 産 .o の併合、
  system ld -r との解決結果一致(バイトではなく帰結の比較)、決定的出力
  (同一入力 → バイト同一)。

**トレードオフ**: COMMON シンボル・SHT_GROUP(COMDAT)・REL 形式(RELA のみ)・
アーカイブの複数回走査(--start-group 相当)は対象外。examples サンプルは
Step 29/30 と同じ理由で対象外。

---

## Step 32 — DoS フェイルセーフ(サプライチェーン攻撃対策)(059d59d)

**内容**: 悪意ある入力(仕込まれた C ソース/ヘッダ/ELF/ar)による資源枯渇 DoS を、
生の `SystemStackError`・無限ループ・指数膨張ではなく、明確なエラーで拒否する
横断的フェイルセーフ。攻撃 PoC で脆弱性を実証してから対策(詳細な独立記録は
docs/security-dos-review.md)。heavy-implementer 1 フェーズ。

**設計判断**:
- **脅威の性質に応じてガードを使い分ける**: スタック再帰は深さカウンタ、
  指数膨張は run 全体の累積トークン予算、非再帰のネスト(#if スタック・マクロ
  引数括弧)は整数上限、リーダの巨大 count はテーブルのファイル内サイズ整合
  検査。「一定回数/深さ/総量で打ち切り、file:line:col + caret 付きの
  CompileError / ELFFormatError で拒否する」で統一(N3: 未対応は黙って壊さない)。
- **パーサの深さ上限は「実測で決める」**: 当初想定 2000 は本環境の実測で無効。
  フルパイプライン(パーサ + IR 生成 + コード生成が同一 AST を深く再帰)は
  約 330 段の括弧でスタックが溢れる(括弧 1 段 ≈ 40 Ruby フレーム、限界
  約 13,000 フレーム)。共有カウンタ + ensure 減算の with_nesting_guard を
  式の各右再帰段・複合文・初期化子・宣言子・struct 本体に配置し、上限
  **500** に確定(括弧を約 122 段許容 = C11 実装下限 63 の 1.9 倍・実コード
  最大 41 の 12 倍)。**パーサ単体でなくフルコンパイルで発火前後を検証**した
  のが肝 — パーサだけ通っても後段 IR 生成で溢れては無意味。
- **マクロ展開予算は実行時間で選ぶ**: 累積 100 万トークン(ruby.h 前処理の
  実測 13.7 万に対し 7.3 倍)。指数膨張マクロは予算到達までフル処理してから
  拒否するため所要時間 ≈ 予算比例で、8M(27s)は遅すぎ 1M(約 3.2s)を採用。
- **リーダは既にサイズ線形有界**: ELF/ar の count 駆動ループは境界検査で
  ファイルサイズに頭打ちされ、指数/無限ではない。唯一 e_shnum==0 時に第 0
  セクションの 64bit sh_size を数に使う経路だけ、テーブルがファイルに収まらない
  巨大 count を map 前に弾く検査を追加。他は有界な旨をコメント明記(防御の
  網羅性を文書で担保)。
- **教訓の一般化**: 深さ/総量の上限は「環境のスタック実測 → 実コーパスの最大値
  → 安全係数」で決める。ロジックだけ見て安全マージンを推定すると(2000 のように)
  外す。

**トレードオフ**: 上限値は実行環境のスタックサイズに依存する(パーサ 500 は
本環境の ~330 括弧段限界前提)。極端に浅いスタックの環境では再評価が必要。
gem コーパス(R10)での実測に応じて再調整しうる。

**採番の注記**: 本来 Step 32 として計画していた L4(PIC データアクセス)は、
ユーザー要請で割り込んだ本 DoS 対策を Step 32 に充てたため Step 33 へ繰り下げ。

---

## Step 33 — PIC データアクセス(M2 L4: -fPIC の GOT 経由参照)(84be163)

**内容**: `-fPIC` の下で、この翻訳単位が定義しないファイルスコープの
オブジェクト/関数のアドレス取得を GOT 経由に切り替える。.so が外部データ
シンボル(libruby の VALUE 変数等)を参照する前提。heavy-implementer 1 フェーズ。

**設計判断**:
- **新 IR op `:got_addr` を1つ追加**(フラグ拡張ではなく): `:global_addr`/
  `:func_addr` に got フラグを持たせる案は Instruction の固定フィールド
  (op/dst/a/b/size)にマーカーを押し込み全命令共通のインターフェイスを汚す。
  GOT ロード(リンカ管理スロットからの特殊再配置付きロード)は既存 op の脱糖で
  表現できない独立した機械プリミティブで、「IR 命令は最後の手段」の趣旨
  (脱糖できるものを op 化しない)にも抵触しない。データ・関数を「シンボルの
  アドレス」の一点で共通化でき、1 命令追加でバックエンド 1 メソッド・ELF 1
  再配置種に閉じる。
- **判定はジェネレータで1箇所に集約**: 全 `:global_addr` 発行を emit_global_addr
  へ集約し、pic_extern_object?(データは @object_records の有無)/
  pic_extern_func?(関数は @signatures の defined 有無)で「この TU の定義か」を
  判定。TU 内定義・static・文字列リテラルは PC32 lea のまま、外部参照だけ
  `:got_addr`。関数呼び出しは PLT32 のまま(PLT 生成はリンカの仕事)。
- **非 PIC はバイト不変**(N4): @pic 既定 false のとき出し分けヘルパは常に
  false を返し、既存経路と新再配置を一切通らない。同一ソースの pic 有無
  コンパイルで非 PIC 側が 2 回とも決定的一致、自己完結ソースは pic 有無で
  バイト同一、を検証。
- **GOT mov エンコード**: `48 8B 05 <disp32>` = `mov rax,[rip+disp32]`。disp32 は
  ゼロプレースホルダで `{ kind: :got }` 再配置に記録、ELFWriter が
  R_X86_64_REX_GOTPCRELX(type 42)・addend −4 を発行(PC32 と同じ −4 バイアス)。
  GOT スロットに実アドレスが入るのでロード結果がそのままポインタで以降不変。
- **受容トレードオフ(コメント明記)**: 「定義有無」で外部性を判定するため
  同一 .so 内の別 TU のグローバルも GOT 経由になり 1 命令遅い(正しさ優先 N2)。
  参照より後方で定義されるオブジェクトも(未記録のため)外部扱いになるが、
  GOT スロットがローカル定義に解決されるので正しさは保たれる。interpose は
  既定で許容(-Bsymbolic 相当にはしない)。GOTPCRELX→lea 緩和はリンカ将来最適化。
- **検証**: GOT mov のバイト列・type 42/addend −4 のラウンドトリップ・出し分けの
  網羅(外部データ→GOT / TU 内定義→PC32 / static→PC32 / 文字列→.rodata PC32 /
  外部関数アドレス→GOT・呼び出し→PLT32 / TU 内定義関数→PC32)、gcc -fPIC -c が
  同アクセスに GOTPCREL 系を使うことの相互チェック、受け入れ(rubycc -fPIC の .o を
  gcc -shared で .so 化 → readelf -d に TEXTREL なし → Fiddle で dlopen し
  GOT 経由 extern データ往復)。

**トレードオフ**: 上記の別 TU グローバルの 1 命令コスト。examples の
ステップサンプルは対象外(PIC はコンパイルフラグで、test_examples.rb は -fPIC を
渡さず gcc 差分をとるため GOT 経路を実行検証できない。実行検証は test_pic.rb の
.so + Fiddle 受け入れテストで担保)。

---

## Step 34 — 自己完結 共有ライブラリライタ(M2 L5 第一段: .so と dlopen)(77209d8)

**内容**: Rubycc::Link::SharedLinker — 複数 .o + アーカイブを ET_DYN(.so)へ
最終リンクする。まず外部依存を持たない自己完結 .so を生成し、Ruby の Fiddle で
dlopen してエクスポート関数を実際に呼べる状態を作る。GNU hash・外部シンボル解決
(PLT/GOT/JUMP_SLOT/GLOB_DAT/DT_NEEDED)・SONAME は後続(L5b/L6)。L5 は一体だと
巨大かつ .gnu.hash の実装リスクが高いため段階分割した第一段。heavy-implementer
1 フェーズ(session limit で中断・再開)。

**設計判断**:
- **最終リンクの基盤を PartialLinker の上に載せる**: SharedLinker は入力を
  PartialLinker で単一 ET_REL に併合 → ELFReader で読み戻し → ET_DYN 生成。
  併合(セクション結合・シンボル解決・遅延取り込み)を再利用し、SharedLinker は
  「仮想アドレス配置 + 再配置適用 + 動的セクション生成」に集中。L6(ライブラリ
  解決)は「UND を残す + DT_NEEDED」でこの併合リーダに合流でき、L7(実行ファイル)は
  同じ配置・適用エンジンを ET_EXEC/e_entry 付きで再利用できる分離。
- **配置は p_vaddr = p_offset で自明化**: 役割別 3 PT_LOAD(r-x / r-- / rw-)、
  各セグメント先頭を 0x1000 整列。全配置セクションで p_vaddr = p_offset を採ると
  p_vaddr≡p_offset(mod page)が自明に満たされ、配置ロジックが単純になる
  (ファイルとメモリで同一レイアウト)。ehdr+phdr は先頭 r-x に同梱、.bss は
  NOBITS で memsz のみ拡張、PT_GNU_STACK で非実行スタック。
- **静的再配置の適用エンジン(L3 後半に相当)**: PC32/PLT32 は S+A−P で直接
  (同一 .so 内なので PLT スタブ不要)、32/32S は絶対直書き、GOTPCREL 系は
  シンボルごとに GOT スロットを実際に生成しスロット経由参照、.data の絶対
  アドレス初期化子(R_X86_64_64)はベース相対値を書いて R_X86_64_RELATIVE を
  発行。GOT スロット自体にも RELATIVE。**第一段で出す動的再配置は RELATIVE のみ**
  (位置独立オブジェクトの絶対アドレスはすべてローダの base 加算で解決)。
- **.hash のみ(SysV)**: nchain = dynsym 数、nbucket はエクスポート数から
  サイズ決定的なラダーで導出(平均チェイン長 ~1)。glibc は .gnu.hash 不在時に
  .hash へフォールバックするので dlsym が動く。.gnu.hash は次段。
- **併合が生む 2 つの再配置形を確認**: (1) クロスユニット併合で内部化した
  シンボルへの GOTPCRELX(-fPIC の別 TU 参照)、(2) ファイルスコープポインタが
  生む .data の R_X86_64_64。どちらも Fiddle 実行で往復を確認。
- **検証は「実際に dlopen して呼ぶ」まで**: ラウンドトリップ + readelf -a
  クリーン + eu-elflint(存在時)に加え、Fiddle で dlopen し内部関数・グローバル
  読み書き・文字列・クロスユニット GOT・データポインタが全て期待値を返すことを
  実走で確認(受け入れの肝)。

**トレードオフ / 既知の負債**: (1) rubycc -fPIC は**定義済みでエクスポートされる
グローバル**を PC32 で参照する(Step 33 の -Bsymbolic 相当の割り切り)。
SharedLinker はローダ非依存に S+A−P で解決するので**実行は正しい**が、GNU ld は
これを「preemptible シンボルへの PC32」= 共有オブジェクト規則違反として拒否する。
よって定義済みグローバルを含む入力は `gcc -shared` 相互比較が不可(gcc 互換
テストは関数+文字列入力を使用)。これはコンパイラ側 PIC コード生成の限界で、
真の interpose 対応(エクスポートされる定義済みグローバルも GOT 経由にする)は
将来の PIC 改善課題(ROADMAP §3)。(2) .gnu.hash・外部シンボル・SONAME は L5b/L6。

---

## Step 35 — 外部シンボル解決(M2 L5 第二段: PLT/GOT import と DT_NEEDED)(6736c6c)

**内容**: SharedLinker(Step 34)を拡張し、別の共有ライブラリ(libc.so.6 等)が
提供する外部関数・外部データを import して実際に呼べる .so を生成する。第一段の
「UND 拒否」を外部シンボル解決へ置換。.gnu.hash は第三段(次段)。heavy-implementer
1 フェーズ。

**設計判断**:
- **即時バインド(BIND_NOW)を既定にして遅延リゾルバを不採用**: 遅延バインドは
  .got.plt[1][2] と _dl_runtime_resolve トランポリン(PLT[0])の連携が必要で
  複雑。DF_BIND_NOW / DF_1_NOW でローダが起動時に全 JUMP_SLOT/GLOB_DAT を解決
  するようにすれば、PLT スタブは単純な間接 jmp(FF 25 disp32 + NOP パディング、
  16 バイト)だけで済み、PLT[0] とリゾルバ機構が丸ごと不要になる。conftest/gem の
  用途では起動時解決のコストは問題にならず、実装が大幅に単純化する。
- **GOT を 2 系統に分離**: 内部データ用 `.got`(RELATIVE と外部 GLOB_DAT を同居、
  symbol 名で dedup)と関数用 `.got.plt`(予約 3 スロット [0]=&_DYNAMIC + 各
  外部関数)。.rela.dyn は RELATIVE 先頭固定で DT_RELACOUNT を維持 → GLOB_DAT →
  シンボル付き 64、の順。
- **内部/外部の出し分けを scan で一元判定**(external_import? = UND かつ非
  section): 外部関数 PLT32 → PLT スタブ + JUMP_SLOT、外部データ GOTPCREL →
  GLOB_DAT、内部は Step 34 どおり(PLT32 直接・内部 GOT は RELATIVE)。UND への
  テキスト再配置(PC32/32/32S)は rubycc -fPIC が生成しないため明確にエラー。
- **DT_NEEDED は --as-needed 相当**: 各 UND を依存 .so の dynamic_symbols で
  解決し、実際に 1 つ以上供給した依存だけを DT_NEEDED に記録(名前は依存の
  DT_SONAME)。どの依存にも無い UND はエラーにせず UND のまま残す(共有
  ライブラリでは合法、実行時の別 .so 連鎖で解決されうる: DESIGN 4.2)。
- **第一段のバイト完全互換を維持**: 外部 import が無い入力では .plt/.got.plt/
  .rela.plt と BIND_NOW 系 DT タグを一切生成せず、Step 34 と同一出力(自己完結
  .so テストが継続 green で担保)。
- **.dynsym/.hash の構成**: .dynsym は [null] + exports + imports(UND,
  SHN_UNDEF/value 0)。SysV .hash は nchain=全 dynsym 数だが buckets には
  defined export のみを連鎖(import は lookup 対象外)。
- **検証は「外部 libc 関数を実際に呼ぶ」まで**: Fiddle で dlopen し
  strlen(my_len("hello")=5)・puts・environ(GLOB_DAT 経由データ読み取り)が
  実走。gcc -shared -lc との DT_NEEDED・実行結果一致、readelf -a クリーンも確認。

**トレードオフ / 既知の負債**: RELRO 未実装(.got.plt は書き込み可能なまま。
conftest/gem 用途では実害なし、堅牢化は将来)。UND へのテキスト再配置は非対応。
.gnu.hash・遅延バインド PLT・-l/-L 探索とリンカスクリプト(GROUP)解析・シンボル
バージョニングは第三段/L6。

---

## Step 36 — ライブラリ解決(M2 L6: -l/-L 探索とリンカスクリプト)(9bd39df)

**内容**: Rubycc::Link::LibraryResolver — `-l名`/`-L` から実ライブラリを探索し、
共有(.so)は SharedLinker の needed へ、静的(.a)/オブジェクトは遅延取り込みの
inputs へ振り分ける。glibc の libc.so がテキストのリンカスクリプトである現実にも
対応。heavy-implementer 1 フェーズ。

**設計判断**:
- **探索・振り分けを独立コンポーネント化**: SharedLinker/PartialLinker は
  「解決済みの needed/inputs」を受ける契約のまま、その手前に LibraryResolver を
  置いた。L8 ドライバは探索路の知識を持たず、構造化データ(-l 名の配列 + -L
  配列)を渡すだけで .so を得られる。
- **.so/.a 優先はディレクトリ内に閉じる**: 各 -L(コマンドライン順)→ 実在する
  システム既定パス(/usr/lib/x86_64-linux-gnu → /usr/lib → /lib/x86_64-linux-gnu
  → /lib → /usr/local/lib)を順に見て、ディレクトリ内で lib名.so 優先・lib名.a
  フォールバック、最初に該当したディレクトリで確定。GNU ld と同じく「跨ぎ優先に
  しない」(先行ディレクトリの .a が後続ディレクトリの .so に勝つ)ことで混在
  環境での挙動を伝統的リンカと一致させる。-l:filename 厳密名も受理。
- **glibc の libc.so がテキストスクリプトである現実への対応**: ELF/ar の
  どちらの magic でもないファイルをリンカスクリプトと見なし、GROUP/INPUT/
  AS_NEEDED(ネスト可)/OUTPUT_FORMAT(読み飛ばし)/ /* */ コメントだけの最小
  パーサで実ファイル群へ展開。スクリプト内の絶対パスと -l 名(再帰解決)を
  たどる。本物のスクリプト言語(SECTIONS/PROVIDE/ENTRY 等)は実装せず、未知
  ディレクティブは半解釈を避けて無視(誤展開の防止)。R11 上、参照したのは
  スクリプト構文の観察のみで ld の実装コードは見ない。
- **推移閉包を辿らない / .so に未解決検査を課さない**(ROADMAP): リンク時は
  直接要求されたライブラリのみ扱い、.so の DT_NEEDED 連鎖は実行時ローダに委ねる。
  UND 残存は合法。DT_NEEDED の as-needed トリムは SharedLinker 既存ロジックに委譲。
- **決定性(N4)**: needed/inputs は初出順、realpath デデュープで同一ライブラリの
  重複到達(直接指定とスクリプト経由)を単一化。
- **検証は実物ライブラリまで**: -lz で zlib を解決し Fiddle dlopen で
  crc32(0,"123456789",9)=0xCBF43926 を実行(SONAME libz.so.1 が DT_NEEDED)、
  -lc の libc.so GROUP スクリプトを展開して strlen 実行、ar 静的ライブラリの
  遅延取り込み(使用メンバのみ)、gcc -shared -lz との DT_NEEDED 一致。

**トレードオフ**: --start-group/--end-group(単一パスで足りる範囲)・シンボル
バージョニングは対象外。CLI フラグのパース自体は L8(本ステップは -l/-L を
構造化データとして受ける)。examples サンプルは他のリンカ系ステップと同じく対象外。

---

## Step 37 — 実行ファイルと crt(M2 L7: 非 PIE ET_EXEC と _start 合成)(f9ba9dc)

**内容**: Rubycc::Link::ExecutableLinker(SharedLinker のサブクラス)— mkmf の
conftest(try_link/try_run)を通すための、動的リンクされた非 PIE ET_EXEC 実行
ファイルを生成。Ruby 内で合成した crt(_start)経由で __libc_start_main を呼び
C ランタイムを初期化。heavy-implementer 1 フェーズ。

**設計判断**:
- **SharedLinker をサブクラス化して再利用**(共通基底の抽出はリスクが高いため):
  配置・再配置適用・PLT/GOT・.dynsym/.hash/.dynamic は SharedLinker のものを
  そのまま使い、差分だけを「挙動を一切変えないフック」で表現(link_inputs/
  after_merge/load_base=0/rebase_internal?=true/leading_sections=[]/e_type=ET_DYN/
  e_entry=0)。既定値が .so の従来挙動とバイト完全一致し、既存 .so テストで担保。
  ExecutableLinker は build_phdrs/phnum/plan_dynamic_symbols/section_bytes と
  上記フックのみ override。
- **非 PIE の簡略化が核心**: e_type=ET_EXEC・固定ベース 0x400000 なので絶対
  アドレスが確定し、内部の絶対再配置(64/32/32S)をリンク時に最終値で直接解決
  でき、**RELATIVE 動的再配置が一切不要**(rebase_internal?=false で .rela.dyn の
  RELATIVE を抑止)。内部 GOT スロットも絶対値直書き。外部シンボル(libc)は
  従来どおり PLT/GOT + JUMP_SLOT/GLOB_DAT。PIE より再配置が単純という L7 の
  狙いどおり。
- **crt を「ET_REL 化して入力先頭に prepend」**: psABI のプロセス起動慣例から
  _start を 31 バイト機械語合成(各命令に英語コメント)し、RelocatableWriter で
  1 セクションの ET_REL にして入力の先頭に置く。PartialLinker が併合し、_start の
  2 参照(main=非 PIE の絶対 32bit R_X86_64_32、__libc_start_main=PLT32)を
  既存の再配置パイプラインが処理する。専用の再配置経路を新設しない設計。
- **__libc_start_main の無版本参照で足りることを実証**: glibc 2.34+ は
  __libc_start_main@@GLIBC_2.34 がデフォルト版。rubycc の無版本 UND 参照は
  そのデフォルト版に束縛され、7 引数 ABI(init/fini=NULL)で正しく起動する。
  verneed(GLIBC_2.34)を張る必要はない(実機 glibc 2.39 で return 42→exit 42、
  puts/printf 動作を確認)。
- **実行ファイルリンク時は libc を既定 needed に**: _start の __libc_start_main
  呼び出しが libc を要求するため、gcc が crt1.o 経由で libc を暗黙リンクするのと
  同様に既定で追加(libc: :auto で既定パス群から発見、DT_NEEDED は SONAME 文字列
  "libc.so.6" で決定的)。実行ファイルは何もエクスポートしない(exports 空)。
  ELFReader は ET_EXEC を .so と同じ section header 経由で読み戻せるよう拡張。
- **検証は実際に走らせて終了コードまで**: return 42→exit 42、puts("hi")→stdout
  "hi"+exit 0、printf、argc/argv マーシャリング、conftest try_run 風→exit 0、
  gcc -no-pie との stdout/終了コード一致。examples/m2/ を新設し step37_conftest.c
  (mkmf try_run の形)を追加。

**トレードオフ**: PIE・静的リンク実行ファイル・一般的な実行ファイル品質は対象外
(conftest を通すことに限定)。SharedLinker の r-x セグメント filesz が
offset 0 で `finish - first.offset`(ページ丸めに救われる既存の癖)は .so 側を
壊さないため据え置き、ExecutableLinker 側でのみ正しい filesz を算出。

---

## Step 38 — gcc 互換ドライバ(M2 L8 前半: exe/rubycc の統合)(e9b48a7)

**内容**: exe/rubycc を gcc 互換ドライバに全面拡張。複数入力・コンパイル+リンク
一気通貫・-shared/-c/-o・-l/-L・-fPIC・-D/-U・-Wl,・-E・-O 等の受理を実装し、
既存のコンパイラ・リンカ部品を束ねる。M2 受け入れ(json/msgpack 実ビルド)の下地。
heavy-implementer 1 フェーズ。

**設計判断**:
- **駆動ロジックを lib/rubycc/driver.rb にクラス化、exe は薄い起動役**: Driver.run
  (argv, stdout:, stderr:)はストリーム注入でユニットテスト可能。exe/rubycc は
  `exit Rubycc::Driver.run(ARGV)` の 1 行。コンパイル/リンクのロジックは新規実装
  せず、Compiler / PartialLinker / SharedLinker / ExecutableLinker /
  LibraryResolver を束ねるだけ(R11 上も既存 CLI 実装を写さない独自構成)。
- **一気通貫は中間 .o を作らない**: -c 無しで .c を渡すと Compiler が返す ELF
  バイト列をメモリ上で直接リンカへ渡す(PartialLinker が生バイト列とパスを判別
  する既存仕様を利用)。Tempfile 不要で、tmp 名に依存しない決定性(N4)。
- **モード優先は gcc に合わせる**: -E > -c > -shared > 既定(実行ファイル)。
  入力は拡張子で分類(.c=source / .o=object / .a=archive / .so=needed 依存 /
  他=linker input)。
- **-D/-U はディレクティブ文字列へ変換して既存経路に載せる**: コマンドラインの
  -DNAME[=VAL]/-U を `#define`/`#undef` 相当のディレクティブ列に変換し、既存の
  process_lines へ流す。プリプロセッサの再定義検査・検証をそのまま活用し、
  大きな改造を避けた。順序も gcc 同様に保持(後の -U が先の -D を打ち消す)。
  compiler.rb/preprocessor.rb に defines: を追加、-E 用に PPToken 列を返す
  Preprocessor#preprocess を切り出し。
- **未知フラグは警告のみで無視(R6)**: -O/-g/-W/-f/-std/-pipe/-pthread/-no-pie は
  無警告で受理・無視、-m* や不明な -フラグは `warning: unknown option ... ignored`
  を出してビルド継続(mkmf が環境依存フラグを渡すため)。引数を取るオプション
  (-Xlinker/-z/-MF/-include 等)は operand を消費して入力ファイル誤認を防ぐ。
- **-shared は libc を自動 needed しない**: 未定義 libc シンボルは実行時にローダの
  グローバルスコープで解決(共有ライブラリの通例)。実行ファイルのみ
  ExecutableLinker が libc を既定 needed。生成物は chmod 0755。
- **検証は mkmf 典型コマンド形と gcc 相互運用まで**: 複数 TU 一気通貫が
  gcc -no-pie と stdout/終了コード一致、実物 -lz 一気通貫で crc32=0xCBF43926、
  -DFOO が #if に効く、未知フラグ警告のみでビルド成功、`rubycc -c -fPIC -I -o` と
  `rubycc -shared -o *.o -L -l` の 2 段が通る。examples/m2/step38_driver.c 追加。

**トレードオフ**: -E の出力は PPToken 列からの best-effort 再構成で gcc -E との
バイト一致は保証しない(mkmf のマクロ展開/インクルード確認用途には十分)。
ユーザーが -lc を明示しつつ実行ファイルを作ると resolver の libc と
ExecutableLinker 既定 libc でパスが違えば DT_NEEDED が二重化しうる(稀・無害)。

---

## Step 39 — C 拡張ビルドの受け入れ(M2: require して動く)(8e5f8f1)

**内容**: M2 受け入れの核心「rubycc のドライバ単体で Ruby C 拡張を .so にビルドし、
Ruby から require して実際に呼べる」ことを常設回帰テスト化(test/
test_extension_build.rb)。メインセッションで手動実証(rb_define_module /
rb_define_module_function / INT2NUM / NUM2INT / rb_str_new_cstr を使う最小拡張が
`SmokeExt.add(40,2)=42` を返す)した事実をテストへ落とし込んだ implementer
1 フェーズ。

**設計判断**:
- **受け入れの本質は「.o まで」でなく「require して動く」**: Step 28 の ruby.h
  スモークは .o までだったが、M2 では SharedLinker/ExecutableLinker が揃い、
  rubycc ドライバ単体で .so までリンクできる。rb_* シンボルは .so に UND のまま
  残り、**require 時に Ruby 本体(既にプロセスにある libruby)から解決される** —
  C 拡張の本来の動作機構がそのまま働く。これを実プロセスで検証する。
- **3 ケースで受け入れを固める**: (1) 最小拡張を rubycc で .so 化 → 子プロセスの
  Ruby で require して呼び出し、(2) 同一ソースの gcc -shared 版と挙動一致、
  (3) 複数 TU を 1 回の rubycc -shared コマンドで一気通貫。子プロセスの require
  結果は Marshal 経由で親へ返してアサート、10 秒タイムアウトでハング防止。
- **既存の受け入れ資産を再利用**: インクルードパスは test_ruby_smoke.rb /
  test_c_suite.rb と同一の pin 済み定数、ドライバ起動は test_driver.rb の
  サブプロセス方式。skip ガードも既存と同一。
- **位置づけ**: これで「rubycc の C 拡張ツールチェーンが実際に機能する」ことが
  CI で常時保証される。ROADMAP の M2 受け入れの最終形(json/msgpack の実 gem
  テスト合格)へ向けた土台の確立であり、次は実 gem で ruby.h の全機能を踏んで
  M1 の残穴(文式 ({…}) 等、ROADMAP §3)を棚卸し・追補ステップで潰す段階に入る。

**トレードオフ**: 本ステップの拡張は最小(整数演算・文字列生成)で、実 gem が
要求する文式・複雑な型・大量の rb_* API はまだ踏んでいない。M2 受け入れの完了
判定(json/msgpack が gem テストに合格)は後続ステップで、そこで露見する不足を
追補ステップとして通し番号で処理する。

---

## Step 40 — GNU 文式 `({ 文... 最後の式 })`(M1 追補・最優先負債の解消)

M2 受け入れ(Step 39)で確認した「実 C 拡張を塞ぐ最初の壁」を潰す M1 追補ステップ。
ruby.h の `TypedData_Make_Struct` / `Data_Make_Struct` / `rb_intern` 等が文式に
展開されるため、これが無いと実 gem のコンパイルが即座に止まる(証拠: 上記マクロを
含むソースが `error: expected expression` で失敗)。heavy-implementer へ移譲し、
メインセッションで差分レビュー + gcc 差分実測 + 全スイート再実行して確定。

**設計判断**:
- **一次式での分岐で実装**: `(` の直後が `{` のときだけ複合文をパースして `)` で
  閉じ、`AST::StatementExpr(body, token)` を返す。通常の括弧式 `( expr )` とは
  別経路に分け、既存の `parse_compound_statement` をそのまま呼ぶことで、入れ子
  ガード(MAX_NESTING_DEPTH=500)とブロックの tag/ordinary スコープ push を
  無改造で継承する(DoS フェイルセーフを迂回しない)。
- **値・型の規則は「最後の式文」**: IR 生成で最後の要素以外を文として実行し、
  最後が式文ならその式の値・型を、そうでなければ(空ブロック・宣言・ループ・空文で
  終わる場合)void を構文全体の結果とする。`static_type` にも同じ規則を実装し、
  sizeof(文式) が値生成なしに型だけで評価できる経路を用意(最後の式が参照しうる
  ブロック局所宣言の型をスコープに束縛してから最終式の型を推論)。**新しい IR
  命令は追加せず**、既存の `gen_statement`/`gen_expr` を再利用したため IR.md は不変。
- **`?:` の片側 void アーム(GCC 拡張)を同時対応**: 文式が `goto` 等で終わって
  void 型になると、c-testsuite 00213 の `1 ? printf(...) : ({ ...; goto L; })` が
  現れる。ISO C は両アーム void のみ許容だが GCC は片側 void を許容するため、
  `conditional_result_type` で片側 void を void 合成とし、`gen_conditional` に
  void 経路(各アームを値変換せず副作用のみ)を追加した。この 2 機能が噛み合って
  初めて 00213 が通る。
- **`__extension__ ({ … })`**: 既存の cast 前置での `__extension__` 読み飛ばし
  経由で自動的に受理され、追加変更は不要だった。

**トレードオフ**: `static_statement_expr_type` はブロック直下の `VariableDecl` の
型のみをスコープに束縛する(sizeof(文式) の最終式がブロック局所変数を参照する稀な
場合の型推論用)。多重宣言子や局所 typedef/tag を最終式で踏む極端なケースは未対応
だが、実行経路(`gen_statement_expr`)は通常の宣言処理を通るため影響なし。

**位置づけ**: これで実 C 拡張が要求する ruby.h の割り当てマクロが展開時に通る。
次は json/msgpack の実 gem ビルドで ruby.h の全機能を踏み、露見する M1 の残穴を
追補ステップとして通し番号で潰す段階(M2 受け入れの最終形)に入る。

---

## Step 41 — 同梱 freestanding ヘッダと既定インクルードパス(M2 追補・gcc 依存の排除)

Step 40 で実 C 拡張(TypedData)が .so 化・require できることを確認した際、次の壁が
`#include <stdarg.h>` の未解決だった。stdarg/stddef/stdbool/stdalign 等は **glibc に無く
コンパイラが供給すべき freestanding ヘッダ**で、それまで既存テストは gcc の内部 include
ディレクトリ(`/usr/lib/gcc/.../13/include`)を pin して借りていた。これは「gcc/binutils
なしで C 拡張をビルドする」目標に反する依存。本ステップでこの依存を断つ。メインセッションで
実 ruby.h・実 TypedData 拡張を通して必要なヘッダ内容・解決モデルを実測確定し、
heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **同梱ヘッダは gem ルート直下 `include/`**: stdarg/stddef/stdbool/stdalign/iso646/
  stdnoreturn/float の 7 本を同梱。rubycc のビルトイン(`__builtin_va_*`・`_Alignof`・
  `_Bool`)と predefine 済み数値マクロ(`__SIZEOF_*__` 等)へ写像し、**具体型は x86_64
  SysV LP64 固定**(size_t=unsigned long 等)。ガード名は `_RUBYCC_*`、コメントも独自
  文面で R11 遵守(gcc/glibc のヘッダ構成・文面に似せない)。ISO/ABI 規定値(float.h の
  各定数等)は共通で問題なし。
- **glibc の `__need_*` 部分インクルード規約に対応**: glibc の stdio.h は
  `#define __need___va_list` してから stdarg を、`#define __need_NULL` してから stddef を
  インクルードして `__gnuc_va_list` / `NULL` だけを取り込む。この規約に対応しないと
  stdio.h が壊れる(実測)。stdarg は `__gnuc_va_list` を、stddef は
  `__need_NULL/size_t/wchar_t/ptrdiff_t` を個別に定義する分岐を持つ。
- **既定システムインクルードパス**: [同梱 include/] → [libc: /usr/include/
  x86_64-linux-gnu, /usr/include] の順。同梱を先頭に置き rubycc の stdarg/stddef を
  glibc より優先させる。gcc の内部 include ディレクトリは**含めない**(排除が目的)。
  ユーザ `-I`/`-isystem` の後ろに連結し、angled include が `-I` 無しで解決する。
  `-nostdinc`(driver)/ `system_includes:`(Compiler)で無効化(ハーメティックなテスト用)。
- **注入は Preprocessor に集約**: 既定パス定数を Preprocessor に持たせ、Compiler・Driver
  から `system_includes:` で一貫制御。同梱ディレクトリは lib からの相対(`File.expand_path`)
  で解決し、ソースチェックアウトでもインストール済み gem でも動く。
- **offsetof は従来型**: rubycc は `__builtin_offsetof` を未サポート(パースエラー)の
  ため、stddef.h の offsetof は `((size_t)&(((t*)0)->m))`。**実行時文脈でのみ正しく、
  定数式文脈(static 初期化子・配列サイズ・case ラベル)では未対応**。`__builtin_offsetof`
  サポートと定数文脈 offsetof は Step 42 へ送る(ROADMAP §3)。

**トレードオフ**: libc システムパスは x86_64-linux-gnu トリプレットをハードコード
(rubycc は x86_64 Linux 専用ターゲットなので許容)。同梱 libc ヘッダ(R8、ヘッダレス
distroless 対応)は M5 スコープで、本ステップは freestanding ヘッダのみ供給しコンパイラ
依存を切るに留める。`va_copy`→`__builtin_va_copy`・`alignas`→`_Alignas`・`noreturn`→
`_Noreturn` は rubycc 側が未対応だが、マクロは未展開なら無害(ruby.h・Box・新テストは
踏まない)。

**位置づけ**: これで rubycc は **gcc の内部ヘッダに一切依存せず**実 TypedData 拡張を
ビルドできる(Box 拡張を CRuby ヘッダのみで .so 化 → require → `[1,2,3]` を常設回帰化)。
文式(Step 40)と本ステップで、実 gem が最初に踏む二つの壁(文式・freestanding ヘッダ)を
撤去した。次は json/msgpack の実 gem ビルドで残る不足(定数文脈 offsetof 含む)を追補
ステップで潰す段階に入る。

---

## Step 42 — `__builtin_offsetof`(定数文脈 offsetof、M2 追補)

Step 41 の同梱 stddef.h は offsetof を従来型 `((size_t)&(((t*)0)->m))` で定義したが、
これは rubycc の定数評価器がアドレス演算を畳めないため**定数式文脈(static 初期化子・
配列サイズ・case ラベル)で失敗**する。gcc/clang が `__builtin_offsetof` を提供する
理由がまさにこれで、実 C 拡張は「フィールド名 → バイトオフセットの静的テーブル」の
形で定数文脈 offsetof を踏む。メインセッションで接続先(lexer キーワード表・ビルトイン
解析の流儀・ConstantEvaluator・`StructType#member`・`gen_sizeof` の畳み込みパターン)を
特定して仕様を確定し、heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **6 層の最小接続**: lexer(KEYWORDS に追加)→ AST(`BuiltinOffsetof(type, designator,
  token)` + designator 要素の `OffsetofMember`/`OffsetofIndex`)→ parser(既存ビルトイン
  分岐に追加、member-designator = 先頭識別子 + `.name`/`[定数式]` の連鎖)→
  ConstantEvaluator(オフセット畳み込み)→ generator(`gen_sizeof` を鏡写しに
  `:const` を emit して `[dst, Type::ULong]`)→ 同梱 stddef.h(offsetof を
  `__builtin_offsetof` 展開へ変更)。**新 IR 命令なし**(既存 `:const` を使用)。
- **畳み込みは ConstantEvaluator に一本化**: 定数文脈(case ラベル・配列サイズ・
  グローバル初期化子)は既存の `evaluate_constant_expression` 経由で自動的に効き、
  実行時文脈の `gen_offsetof` も同じ評価器を呼ぶ。オフセット計算は型情報のみ
  (`StructType#member` が匿名 struct/union メンバをオフセット込み合成 Member で
  透過解決するのをそのまま利用)で、メンバステップは `offset += m.offset`、
  添字ステップは `offset += idx * 要素サイズ`。
- **診断は `OffsetofError < NotConstant`**: 非集約/不完全型・メンバ無し・非配列への
  添字・ビットフィールド(バイトオフセットを持たない)を具体的文言で報告。
  NotConstant のサブクラスなので、既存の定数文脈 rescue(汎用文言)でも安全に
  捕捉され、実行時文脈では generator が `detail` を `error_at` で表面化する。

**トレードオフ**: 定数文脈でビットフィールド offsetof を書いた場合の診断は既存の
汎用文言(「not a constant」系)になる(NotConstant 経由で捕捉されるため)。専用文言は
実行時文脈のみ。実害は薄く、診断の文言改善は必要になった時点で。

**位置づけ**: 実 gem が最初に踏む三つの壁(文式 = Step 40・freestanding ヘッダ =
Step 41・定数文脈 offsetof = Step 42)を撤去。次は json/msgpack の実 gem ビルドに
進み、露見する残穴を追補ステップで潰す(M2 受け入れの最終形)。

---

## Step 43 — GNU 可変長マクロ拡張(名前付き引数とカンマ削除、M2 追補)

M2 受け入れの本丸(json/msgpack の実 gem ビルド)に着手し、extconf.rb が生成した
実フラグで全 C ファイルを rubycc コンパイルして壁のインベントリを作成した。最初の壁が
本ステップ: linux/stddef.h の `__struct_group(TAG, NAME, ATTRS, MEMBERS...)`(glibc の
`<sys/types.h>` → linux/posix_types.h 経由で事実上全 TU が踏む)が名前付き可変長引数で、
msgpack 12 ファイル中 10 がマクロ定義の時点で全滅。GNU カンマ削除 `, ## __VA_ARGS__` も
未対応だった(glibc/CRuby ヘッダの printf 転送マクロが多用)。メインセッションで両
ギャップを実測特定し、heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **Macro に va_name を一元化**: 可変長部の名前(ISO 裸 `...` = "__VA_ARGS__"、
  GNU 名前付き形 = その識別子、非可変長 = nil)を Macro 構造体に持たせ、可変長参照の
  判定(`variadic_ref?`)を「トークン名 == va_name」に一本化。実引数束縛・stringize
  (`#args`)・paste・再定義同一性判定(va_name を比較に含め ISO 形と名前付き形を
  別物と扱う)が両形で同じ経路を通る。名前付き形では `__VA_ARGS__` は通常識別子
  (gcc 準拠)。
- **カンマ削除は「貼り付け」ではなく特別指示**: `##` の左が literal カンマ・右が
  可変長引数の並びだけを `gnu_comma_paste?` で検出し、可変長実引数が**省略**された
  ときのみ直前のカンマを削除、存在すれば(空でも)カンマを残して展開済み引数を
  貼り付けなしで差し込む。`Z()`(0 引数扱いで削除)と `F(a,)`(空スロットは残す)の
  gcc の細部を `no_variable_arguments?` で再現し、gcc -E トークン列比較で全組み合わせを
  検証。それ以外の `##`(Step 27)の意味論は不変。
- **DoS フェイルセーフは不変**: EXPANSION_TOKEN_LIMIT 等の予算は迂回しない。

**位置づけ**: msgpack 全 12 ファイルが glibc・CRuby の全ヘッダを通過し本体コードへ
到達。露見した次の壁は (a) 未実装 gcc ビルトイン(__builtin_ctz / choose_expr /
constant_p / unreachable。CRuby config.h が gcc ビルド時の HAVE_BUILTIN_* を焼き込んで
いるため必須)、(b) 2進リテラル 0b0001、(c) 可変長配列メンバ `VALUE arr[];`、
(d) ビットフィールドアクセス(記録済み M2 負債)。json 側は x86intrin.h
(config.h 焼き込みの HAVE_X86INTRIN_H)と __builtin_clzll、グローバル初期化子の
アドレス定数(キャスト付き文字列リテラル)。これらを Step 44 以降の追補で潰す。

---

## Step 44 — gcc ビルトイン群と __has_builtin(M2 追補)

CRuby の config.h(x86_64-linux/ruby/config.h)は CRuby 自身が gcc でビルドされた
時点の probe 結果(`HAVE_BUILTIN___BUILTIN_*`・`HAVE_X86INTRIN_H`)を焼き込んでおり、
CRuby ヘッダと gem のコードはそれを信じて無条件にビルトインを呼ぶ — Step 41 の
HAVE_STMT_AND_DECL_IN_EXPR と同じ「焼き込まれた gcc 能力」問題の第 2 弾。実測の壁:
`__builtin_choose_expr`+`constant_p`(ruby.h の INT2FIX 経路、msgpack 3 ファイル)、
`__builtin_ctz`(msgpack rmem.h、無ガード)、`__builtin_clzll`(json の float パーサ、
焼き込みガード)、`__builtin_unreachable`(CRuby assert.h の UNREACHABLE_RETURN)、
`<x86intrin.h>`(焼き込みガードで include)、2進リテラル 0b0001(msgpack フラグ)。
メインセッションで全サイトを特定し使用形状を精査、heavy-implementer へ移譲・レビュー。

**設計判断**:
- **__has_builtin は正直に答える**: 対応ビルトインの表(KNOWN_BUILTINS)に 1/0 を
  返し、`#ifdef __has_builtin` / `#if defined(__has_builtin)` の両形を真にする。
  ガード付きコード(json の `__has_builtin(__builtin_bswap64)` 等)は正直な 0 で
  フォールバックへ逃げるため、**bswap 等の実装自体が不要になる** — 実装面積を最小に
  保つ要。`#ifdef __has_include` は意図的に据え置き(真にすると kernel UAPI ヘッダの
  `__signed__` 経路を引き込み拡張ビルドが壊れることを実測)。
- **choose_expr はパース時解決**: 第 1 引数を既存の定数評価で畳み、選ばれた側の
  AST ノードをそのまま返す(専用 AST 不要)。選ばれない側は構文チェックのみで評価も
  コード生成もされず、型は選ばれた側 — generator・ConstantEvaluator の変更なしで
  定数文脈(static 初期化子の INT2FIX)にも自動で効く。
- **constant_p は「試し畳み」**: ConstantEvaluator で引数を evaluate してみて成功なら
  1、NotConstant/DivisionByZero なら rescue して 0。非定数がエラーでなく正当な 0 に
  なるのが要点(gcc 準拠)。引数は評価されない。
- **ctz/clz は新 IR :bit_scan 1 命令**(a=対象、b=:forward/:reverse、size=4/8)。
  backend で bsf(0F BC)/ bsr(0F BD)+ `xor eax, 幅-1`(clz = (幅-1) − 最上位
  ビット位置)に降ろす。オペランド 0 は UB(gcc 準拠)でゼロ処理を出さない。
  定数畳み込みも gcc 同値で対応(焼き込みガード下の定数文脈に耐える)。
- **unreachable は無コード**: rubycc は最適化しないので、void 値を返すだけで意味論上
  安全。`return (__builtin_unreachable(), val)` のコンマ式は既存の void 対応で通る。
- **memcpy は書き換え**: パース時に `Call("memcpy", …)` へ書き換え、組み込み
  プロトタイプを seed(未宣言でも可、libc に UND 解決)。
- **x86intrin.h は空スタブ**: 実 intrinsic の使用は全て `__AVX2__`/`__LZCNT__` 等の
  別ガードで守られ、rubycc はそれらを定義しないため空で安全(実測確認)。

**位置づけ**: msgpack 12 ファイル中 7 が .o 到達。残る壁は可変長配列メンバ
(buffer_class.c、Step 46)とビットフィールドアクセス(4 ファイル、Step 47)。
json parser.c は複合リテラル(c-testsuite 00216 と同根)へ前進。

---

## Step 45 — グローバル初期化子のアドレス定数(M2 追補)

json gem の generator.c(vendor/jeaiii-ltoa.h)が「200 文字の文字列リテラルを
`struct digit_pair *` にキャストして桁ルックアップテーブルにする」形で
"unsupported initializer" になっていた。同時に ROADMAP §3 の記録済み負債
「`&arr[i]` 等の計算アドレス定数」も同類として一括解消。heavy-implementer へ
移譲(セッション上限で中断したが実装は完了済みで、検証・確定はメインセッションが
引き継いだ)。

**設計判断**:
- **AddressConstant への畳み込み walker**: 初期化子式を「基点(シンボル or interned
  文字列)+ 定数バイト変位 + 現在の pointee 型」へ再帰的に畳む。pointee を持ち回る
  ことで、後続の添字・`+ n` が「1 要素 = 何バイト」を知り、ポインタキャストは
  **アドレス不変で pointee だけ差し替える**(ビット表現は変わらないという 6.6 の
  実質)。対応形: キャスト(ネスト可)・文字列リテラル・&global/配列 decay・
  `&arr[i]`・`arr ± n`(+ は両オペランド順)・`&rec.member`(StructType#member で
  匿名メンバ透過、ビットフィールドは拒否)・`&*p`。畳めない形(実行時値・非定数
  添字)は NotAddressConstant → 従来の診断。
- **変位は relocation の addend に乗せる**: GlobalReloc に addend(既定 0)を追加し、
  R_X86_64_64 の r_addend として ELF ライタまで配線(:string kind は「rodata 内の
  interned 文字列オフセット + addend」)。ライタ・リンカは Step 31〜37 で addend を
  既にモデル化済みだったため、受け渡しの配線のみで済んだ。実行ファイル/共有
  ライブラリ両リンク経路の実行テストで addend 適用を検証。
- **関数アドレス定数は既存経路を維持**: `f`/`&f` はシグネチャ検査付きの既存判定を
  先に通し、walker はオブジェクト系のみを担当。

**位置づけ**: json generator.c の壁が浮動小数点リテラルの整数キャスト
(`u32(1e2)`、§3 の負債「unsigned long ⇔ float/double 変換」の顕在化)へ前進。
msgpack 側の残り(FAM・ビットフィールド)と合わせ、次の追補ステップで潰す。

---

## Step 46 — 可変長配列メンバ(flexible array member、M2 追補)

msgpack の buffer_class.c(held-buffer: `size_t` ヘッダ + `VALUE mapped_strings[];`)が
「array size must be an integer constant」で失敗していた。ISO C 6.7.2.1p18 の FAM を
実装。heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **不完全配列は length=nil の Type::Array**: 新しい型クラスを作らず既存 Array に
  不完全形を導入。`#size` は guard raise とし、サイズを要求しうる全経路(変数宣言・
  plain sizeof/_Alignof・配列要素・レイアウト)は**先に診断で止まる**ことをスイートで
  保証する設計。lvalue の decay は有界配列と同一経路で、`p->fam[i]` は既存のメンバ
  アクセス lowering がそのまま働く(新 IR 命令なし)。
- **レイアウトは「オフセットに置くがサイズ寄与ゼロ」**: FAM は要素型の境界に整列した
  オフセットを持つがカーソルを進めず、sizeof は FAM が無いかのような値(6.7.2.1p18)。
  要素型のアライメントは集約に参加。gcc と sizeof/_Alignof/offsetof 一致を差分検証。
- **ISO の制約を診断で固める**: 最後以外のメンバ(`int f[], g;` の宣言子リスト内
  兄弟も検出)・union 内・FAM のみの struct・FAM 付き struct の配列要素・FAM への
  初期化子(gcc の static 初期化拡張は採らず、オブジェクト外書き込みの不正コード
  生成を防ぐ)を拒否。

**位置づけ**: msgpack の FAM の壁を突破。同ファイルの次の壁は
`RUBY_TYPED_DEFAULT_FREE`(= `(RUBY_DATA_FUNC)-1`、整数定数の関数ポインタキャスト)を
持つ `static const rb_data_type_t` 初期化子 — Step 45 のアドレス定数 walker に
「絶対値(整数→ポインタキャスト)」基点を足す小拡張で、Step 47 として処理。

---

## Step 47 — グローバル初期化子の整数→ポインタキャスト(M2 追補)

msgpack buffer_class.c の `static const rb_data_type_t` が CRuby の
`RUBY_TYPED_DEFAULT_FREE`(展開 = `(RUBY_DATA_FUNC)-1`、xfree を意味する番兵)を
関数ポインタスロットに置く形で "unsupported initializer" になっていた。Step 45 の
AddressConstant walker への小拡張として implementer(仕様確定済み・単一ファイル)へ
移譲・レビューして確定。

**設計判断**:
- **:absolute 基点の追加**: AddressConstant の base_kind に :absolute(symbol も
  string も無し、offset = 生ビットパターン)を追加。ポインタキャストのオペランドが
  アドレス定数として畳めないときだけ整数定数として畳んでこの基点に落とす
  (`(dfree_t)-1`・`(void *)0x1000`)。既存の offset 機構がそのまま働くため、
  `(char *)16 + 2` のような絶対値算術も追加コードなしで成立。
- **relocation を作らず直書き**: :absolute はリンク時に解決すべきものが無いので、
  スロットへ pack_integer の 8 バイトを直接書く(スカラー整数初期化子と同じ扱い)。

**位置づけ**: msgpack は buffer_class.c が .o 到達し、残る壁はビットフィールド
アクセスの 4 ファイルのみ(Step 48)。

---

## Step 48 — ビットフィールドの読み書き(M2 追補・§3 負債の解消)

msgpack 実ビルドの最後の壁(4 ファイル)。レイアウト・ABI 分類は Step 28 で実装済み
だったが、アクセス(shift/mask の lowering)が診断エラーのままだった(ROADMAP §3 の
記録済み負債)。heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **lvalue を 2 形に分離**: メンバアクセスの解決を resolve_member(基底式を 1 回
  だけ評価して [基底アドレス, Member] を返す)に共通化し、読み・書き・複合代入・
  ++/--・& の全 5 サイトが bitfield? で分岐。基底式の二重評価(副作用重複)を防ぐ。
  ビットフィールドは「アドレス」を持たないので、gen_member_address は & 用途に縮小し
  「cannot take address of bit-field」を診断(6.5.3.2p1)。
- **読みは load→shift→拡張**: 格納単位(宣言型幅、レイアウト保証により単位跨ぎ
  なし)を uload し、論理右シフトでビット 0 へ、符号付きは shl→sar の対で符号拡張・
  unsigned/_Bool はマスク。結果型は 6.3.1.1 の昇格(int / unsigned int(width≥32 の
  unsigned)/ long 系は自型)。
- **書きは read-modify-write**: 単位 load → `& ~(mask<<shift)` → 値の低 width
  ビットを `<<shift` して OR → store。隣接フィールドを壊さない。代入式の値は
  「切り詰め後の読み直し値」(符号付きは符号拡張、gcc 同値)。複合代入・++/-- も
  同じ部品の組み合わせで実装。
- **新 IR 命令なし**: 既存の :uload/:store/:shl/:sar/:shr/:and/:or/:const で完結。
  無名 struct/union 越しは Member#bit_offset が集約絶対ビット位置なので自然に正しい。

**c-testsuite 00218**: ビットフィールドアクセス自体は通るが、enum 基底型ビット
フィールドのゼロ拡張(gcc は全非負 enum を unsigned 扱い)が rubycc の「enum = int」
モデル(00170 と同根の §3 負債)と衝突して不一致。スキップ理由を更新して残置。

**位置づけ**: **msgpack 全 12 ファイルの .o 化を達成**し、rubycc ドライバ一発で
msgpack.so(777KB)のリンクまで成功。require は `rb_gc_guarded_ptr_val` 1 シンボル
のみで停止 — RB_GC_GUARD が `#ifdef __GNUC__` の asm 版でなく非 GNUC フォールバック
(extern 関数版。gcc ビルドの CRuby はエクスポートしない)に落ちるため。あわせて
`defined(__STDC__)`/`#ifdef __FILE__` がビルトインマクロを認識しない予想外の
プリプロセッサ非適合も発見(gcc は 1)。次ステップ群で対処。

---

## Step 49 — defined() のビルトインマクロ認識と gcc 別名キーワード(M2 追補)

msgpack.so の require を塞ぐ RB_GC_GUARD 問題の調査中に、`defined(__STDC__)` /
`#ifdef __FILE__` が偽になるプリプロセッサ非適合(gcc は 1)を発見。ビルトイン
マクロは展開時に特別処理され @macros 表に居ないため、defined 系だけが見落として
いた。implementer へ移譲し、途中で判明した波及(下記)を含めて 1 ステップで確定。

**設計判断**:
- **判定の一元化**: 「defined に見える名前」= @macros のエントリ + ビルトイン
  マクロ + __has_* 問い合わせ演算子、を defined_macro_name? ヘルパに集約し、
  #ifdef/#ifndef(defined_condition)と #if の defined 演算子(fold_defined)の
  両サイトから使う(N1570 6.10.8p1)。
- **適合修正が新しい glibc 経路を開いた**: 正しくなった `defined(__STDC_VERSION__)`
  により glibc sys/cdefs.h が rubycc を「gcc 以外の C99 準拠コンパイラ」と判別する
  経路を初めて選び、その先の kernel UAPI ヘッダ(asm-generic/int-ll64.h の
  `typedef __signed__ char __s8;`)が gcc 別名キーワードを無条件に使うため、
  ruby.h スモーク等 6 テストが赤に。**適合修正と「それによって初めて到達する経路」
  の対応は一体**と判断し、別名キーワード対応を同ステップに含めた。
- **別名は lexer で正規綴りへ正規化**: `__signed(__)` → signed・`__const(__)` →
  const・`__volatile(__)` → volatile・`__inline(__)` → inline を KEYWORD_ALIASES
  として字句解析時に畳む。`tok.keyword?("const")` 等の完全一致判定が多数あるため、
  各判定サイトに別名分岐を足すのではなく入口で 1 回だけ写像する設計
  (RESTRICT_SPELLINGS は restrict がどの綴りでも非キーワードなので従来方式のまま)。
  parse_asm_statement の `__volatile__` 専用分岐は正規化で不要になり削除
  (二重管理の解消)。

**位置づけ**: glibc の「非 gcc C99」経路が常用経路になった(スモーク・拡張ビルド
とも green)。`#ifdef __has_include` も gcc と一致して真になり、旧コメントの
「意図的に晒さない」制約は別名キーワード対応により不要になった。次は
RB_GC_GUARD の非 GNUC フォールバックシンボル(rb_gc_guarded_ptr_val)を
互換ランタイムで供給する Step 50。

---

## Step 50 — 互換ランタイム(lazily linked compat runtime、M2 追補)

msgpack.so(Step 48 で全 12 TU の .o 化・リンクまで到達)の require を止めていた
唯一の未解決シンボル `rb_gc_guarded_ptr_val` への対処。CRuby の RB_GC_GUARD は
`#ifdef __GNUC__` の asm バリア版と、extern 関数を呼ぶ非 GNUC フォールバック版を
持ち、rubycc は `__GNUC__` を定義しない方針(DESIGN R7)なので後者に展開される —
だが gcc でビルドされた CRuby は自分が asm 版を使ったためこの関数をエクスポート
しない。heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **`__GNUC__` 定義は不採用**: 定義すれば asm 版に乗れるが、glibc 全域が gcc 経路
  (`__REDIRECT` の asm リネーム・gcc の limits.h との include_next 連携等)に切り
  替わり爆発半径が大きすぎる。実測でも `-D__GNUC__` は即座に別の壁に当たる。
  R7 の方針(「__GNUC__ 非定義でフォールバック面積を減らす」)を維持し、
  フォールバック側が要求する**実体を rubycc が供給する**方向を採った。
- **libgcc 相当の「コンパイラ支援ランタイム」**: gcc が libgcc を暗黙リンクする
  のと同じ位置づけで、rubycc ドライバがリンク入力の最末尾に互換アーカイブを自動
  追加する。ar のシンボルインデックス + PartialLinker の既存遅延抽出 fixpoint に
  より、**シンボルが参照された時だけ**メンバが実体化し、非参照リンクには 1 バイトも
  入らない。1 メンバ 1 関数の定数テーブル構成で将来のシンボル追加も外科的。
  `-nodefaultlibs` で無効化可(gcc 互換)。
- **セルフホスト**: 互換ソースは rubycc 自身が実行時にコンパイルする(pic)。
  `rb_gc_guarded_ptr_val` はポインタをそのまま返す — 呼び出しの存在自体が最適化
  バリアであり、rubycc は最適化しないため、これで契約が完全に満たされる。

**位置づけ**: **msgpack 全 12 TU → rubycc ドライバ一発 .so 化 → require →
Packer/Unpacker round-trip 完全一致**。実 gem の C 拡張が rubycc 単体ツール
チェーンで動作した初の事例(M2 受け入れの msgpack 側のコンパイル・リンク・実行の
実証。gem 自身のテストスイート合格は extconf/Makefile 置換の手順整備後)。
リンカ/ランタイム機能のため examples は追加しない(Step 29〜36 と同じ扱い)。
残る json 側の壁: 浮動小数点リテラルの整数キャスト(Step 51)→ 複合リテラル
(Step 52)。

---

## Step 51 — 浮動小数点定数の整数キャスト畳み込み(M2 追補)

json generator(vendor/jeaiii-ltoa.h)が 10 進しきい値を `u32(1e2)`〜`u64(1e15)`
(double リテラルの unsigned long キャスト、u32_t/u64_t は LP64 で unsigned long)と
綴り、比較だけでなく除算・剰余のオペランドにも使う。rubycc は §3 負債
「unsigned long ⇔ float/double 変換」の診断で停止していた — その**定数側だけ**を
先に解消する外科的ステップ。implementer へ移譲(仕様確定済み・2 箇所)。

**設計判断**:
- **畳み込みは 2 箇所に同じ規則で**: ConstantEvaluator の evaluate_cast(定数文脈:
  配列サイズ・case・static 初期化子)と generator の gen_cast_to_arithmetic
  (実行時式中の定数キャスト。診断の手前で試み、成功なら :const)。どちらも
  「FloatLit / 単項マイナス付き FloatLit → 6.3.1.4p1 のゼロ方向切り捨て → 幅と
  符号でラップ」。ネストしたキャスト越し(`(long)(double)1e2`)は追わない最小実装。
- **evaluate 本体に Float を流さない**: 浮動値の取り出しは float_constant_value
  ヘルパに閉じ、定数評価器の演算は純整数のまま(既存の全畳み込みの前提を保つ)。
- **実行時変換は据え置き**: 非定数の float ⇔ unsigned long は従来どおり診断。
  負債の本体(実行時変換)は次ステップで cvt 系 + 補正シーケンスとして対処。

**位置づけ**: json generator の壁は実行時式 `u32((10*(1<<24)/1e3+1)*n)` の
double → unsigned long 変換(§3 負債の本体)へ前進。既存 IR は符号付き変換のみ
(:itof/:ftoi)だが、unsigned 64bit 変換は分岐 + 符号付き変換 + 補正の組み合わせで
generator 内に降ろせる見込み(新 IR 不要)= Step 52。

---

## Step 52 — 実行時の unsigned long ⇔ float/double 変換(M2 追補・§3 負債の解消)

Step 51 で定数側を畳んだ §3 負債「unsigned long ⇔ float/double 変換」の本体。
json jeaiii-ltoa の `u32((10*(1<<24)/1e3+1)*n)`(実行時変数を含む double 式の
unsigned long キャスト)が診断で停止していた。heavy-implementer へ移譲・レビュー。

**設計判断**:
- **既存 IR の分岐合成で generator 内に降ろす(新 IR・backend 変更なし)**:
  x86-64 の cvtsi2s*/cvtts*2si は符号付きのみで、64bit 符号無しの最上位ビットを
  符号と誤読する。標準手法(分岐 + 符号付き変換 + 補正)を :shr/:and/:or/:itof/
  :ftoi/:fadd/:fsub/:flt/:jump_if_zero の合成で書き、両アームが result vreg に
  :copy して合流点で読む(va_arg lowering と同じスロット方式)。
- **u64 → 浮動は目的幅で単段合成**: 最上位ビット set 時は `half=(x>>1)|(x&1)`
  (sticky ビット保存)→ 符号付き変換 → 自身加算で 2 倍。double 経由の 2 段丸めを
  避け、丸めビットが効く値(0x8000000000000401 等)も gcc と %a ビット一致。
- **浮動 → u64 は 2^63 しきい値分岐**: 未満は直行、以上は 2^63 を引いて変換後に
  最上位ビットを OR で戻す。float 源は :ftof で double へ広げて(exact)一本化。
  範囲外・NaN は C の UB につき特別処理なし。
- **既存バグの修正が付随**: float → unsigned int(size 4)が (INT_MAX, UINT_MAX]
  で 32bit 符号付き truncate によりオーバーフローしていた(変更前からの欠陥)。
  符号無し 4byte 目的先は 64bit 幅で truncate して下位を採る。
- **診断の削除**: reject_unsupported_float_int_conversion は全ケースを lowering
  したため削除。負債表のこの行は完全解消。

**位置づけ**: json generator.c が .o 完走。json の残る壁は parser.c の複合リテラル
のみ(Step 53)。それが落ちれば json/msgpack 両 gem の全 TU が .o 化でき、M2
完了判定(gem テストスイート合格)の手順整備に入る。

---

## Step 53 — 複合リテラル(ブロックスコープ、M2 追補)

json の最後の壁。parser.c がスタックフレームを `(json_frame){ .type = …, … }`
(ブロックスコープの複合リテラル + 指示付き初期化子、struct 値渡し)で push する。
heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **弁別はキャスト解析点の 1 箇所**: `( type-name )` の直後が `{` なら複合リテラル、
  それ以外は従来キャスト。文式 `({` は type_specifier? が偽になるため衝突しない。
  postfix を parse_postfix_suffixes に分割し、`(T){...}.member` / `[i]` / 呼び出しを
  後置可能にした。`(int[]){...}` は既存の `[]` 長さ推論(parse_init_declarator と
  同じ InitializerResolver 経由)で確定。
- **generator は既存機構の再利用のみ(新 IR なし)**: 無名オブジェクト = 既存の
  ローカル割り付け(new_object)+ 既存の初期化 lowering(zero_fill + placement)。
  未指定メンバのゼロ埋め・ループ毎の再初期化は既存経路の性質がそのまま効く。
  値カテゴリも既存規約に一致(struct=アドレス / 配列=decay / スカラー=ロード、
  `&(T){...}` は lvalue アドレス)。
- **ファイルスコープ形(静的記憶域)は診断で先送り**: json/msgpack は踏まない
  ことを実測確認。c-testsuite 00149/00150/00216 はファイルスコープ形ほか
  (empty struct・`[a ... b]` 範囲指示子・6.7.9p13 の whole-struct メンバ初期化)が
  残るためスキップ理由を更新して残置。
- 付随修正: static_type の BuiltinAlloca(→ void *)欠落を補完(CRuby の
  RB_ALLOCV の ?: alloca アームで露見)。

**位置づけ**: json parser.c が .o 完走し、**json/msgpack 両 gem の全 TU が .o 化
可能**になった。メインセッションで json 両拡張(parser.so / generator.so)を
rubycc ドライバで .so 化 → gem の lib と組み合わせて require したところ、
**JSON.parser == JSON::Ext::Parser(C 拡張が選択され)、JSON.parse / generate /
pretty_generate / round-trip が全て正常動作**。M2 対象の 2 gem が rubycc 単体
ツールチェーンで動作する状態に到達。残る M2 完了判定は「gem 自身のテストスイート
合格」の実施(次ステップ)。GNU ld 相互運用(PC32 拒否)は §3 記録済みの既知制約の
まま(rubycc 自身の SharedLinker では問題なし)。

---

## Step 54 — M2 受け入れの実施と再現ツール(M2 完了判定の達成)

Step 53 までで C 言語側の壁が全て撤去されたため、M2 の完了判定
「extconf.rb が生成した Makefile のコマンドを手動で rubycc に置き換えて json /
msgpack をビルドし、**gem 自身のテストスイートに合格**」を実施した。メイン
セッションで全手順を実測し、implementer が tools/m2_acceptance.rb として永続化。

**結果(実測、2 回再現)**:
- **json 2.21.1**: rubycc ビルドの parser.so + generator.so で
  **606 tests / 3433 assertions / 100% passed**。テスト前に
  `JSON.parser == JSON::Ext::Parser` を検証(pure-Ruby フォールバックでなく
  C 拡張が使われていることの確認)。
- **msgpack 1.8.3**: rubycc ビルドの msgpack.so(12 TU 一発)で
  **455 examples / 0 failures / 1 pending**(pending は msgpack リポジトリ自身が
  期待値として記す既知項目)。

**設計判断**:
- **受け入れは常設スイートでなくツール**: ネットワーク(gem fetch / GitHub
  tarball のテスト取得)と rspec 等の外部依存を持つため、rake test には含めず
  tools/m2_acceptance.rb(冪等・一気通貫・PASS/FAIL 判定で exit code)として残す。
  常設回帰は Step 39/50 の C 拡張スモーク(require 実行込み)が担う。
- **json の SIMD は gem 公式スイッチで無効化**: json の extconf は環境 gcc の
  probe で JSON_ENABLE_SIMD/HAVE_CPUID_H を焼き込み、simd.h が SSE intrinsics と
  <cpuid.h>(gcc 同梱ヘッダ)を要求する。SIMD intrinsics は DESIGN 3.3 の明示
  スコープ外なので、**gem 自身が提供する公式オプション** `JSON_DISABLE_SIMD=1` で
  無効化(R4 の「gem が公式に提供するインストールオプションの選択」= 無修正の
  範囲内)。M3 の mkmf 統合では probe が rubycc に対して自然に失敗するため、
  この env var 自体が不要になる見込み。
- **残項目の明示**: musl コンテナでの確認は未実施(本環境は glibc のみ。M3 の
  コンテナマトリクス整備時に実施)。L5 第三段(.gnu.hash・RELRO)は適合性の
  磨き込みとして後続。GNU ld 相互運用(PC32)は §3 記録済みの既知制約のまま。

**位置づけ**: **M2 のマイルストーン定義(json / msgpack 級の gem を手動ビルドし
テスト合格)を glibc 環境で達成**。Step 29 のELFリーダから 26 ステップ・追補
15 ステップで、リンカ・ar・ドライバ・互換ランタイム・C 言語残穴の全てを埋めた。
次は M3(rmake / rubygems_plugin / pkg-config / conftest = gem install 統合)。

---

## Step 55 — mkmf コーパスの採取(M3 着手前作業)

M3 の順序方針(ROADMAP §6: 一次資料は実物の mkmf 生成物。POSIX make から演繹しない)
に従い、代表 gem の extconf.rb を実行して生成物を test/fixtures/mkmf/ にコーパス化。
implementer へ移譲(機械的採取)。

**採取内容**: json 2.21.1(parser/generator)・msgpack 1.8.3・racc 1.8.1(cparse)・
redcarpet 3.6.1・bigdecimal 4.1.2 の 6 ext。各 Makefile + mkmf.log + extconf.h +
provenance.txt(採取日・ruby/CC バージョン)。mkmf の conftest ソースは probe 後に
削除されるが mkmf.log に "checked program was:" として全文が残るため(合計 54 probe)、
これで conftest も網羅。tools/collect_mkmf_corpus.rb で再生成可能。

**実物からの発見(B1 の仕様に直結)**:
- サフィックスルールは計画の想定(`.c.$(OBJEXT)`)と違い**展開済みの `.c.o:` 形式**。
- racc / redcarpet の extconf は probe を一切呼ばず **mkmf.log 自体が生成されない**
  (mkmf の正常挙動。conftest 対応が不要な gem が実在する)。
- sqlite3 / pg は本環境に dev ヘッダが無く extconf が失敗するため未収載
  (README に導入後の再実行手順を記録)。

**位置づけ**: B1(rmake コア)の golden テストの一次資料が揃った。次は B1 =
「採取 Makefile 群のパース → 実行計画ダンプの golden 化 + GNU make -n との
突き合わせ」から。

---

## Step 56 — rmake コア: Makefile パーサと実行計画(M3 B1)

mkmf 生成 Makefile を /bin/sh も make も無い環境で処理する make 互換サブセットの
第一段。heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **コーパス駆動の機能セット**: Step 55 の実物 6 本(全て同一テンプレートで値のみ
  相違、diff で構造差ゼロ)を棚卸しし、現れる構文だけを実装。結果は想定より狭い —
  変数代入は再帰 `=` **のみ**(:=/?=/+= は出現ゼロ)、関数(wildcard/shell 等)も
  出現ゼロで未実装、置換参照 `$(V:0=@)` と自動変数($@ $< $(@D) 等)が本命。
  「mkmf が生成しないものは作らない」方針が実装面積を大きく削った。
- **make の細部の再現が golden 一致の鍵**: 代入値の**末尾空白保持**(`dldflags =
  ... `)がリンク行の空白数に効く、`$(V:0=)` の語末サフィックス置換、等は GNU make
  の実測で確認して合わせた。
- **計画と実行の分離**: B1 は「パース → 展開 → タイムスタンプ stale 判定
  (後順 DFS + 伝播)→ トポロジカル順の Plan」まで。レシピは展開して @/- 属性を
  保持するだけで実行しない(実行器 = B2)。`Plan#command_lines` が make -n 相当。
- **DoS フェイルセーフ**: 再帰変数の循環(`A=$(B)`/`B=$(A)`)は展開深さ上限
  (MAX_EXPANSION_DEPTH=200)で ExpansionError に。
- **golden 検証**: fixtures 6 本を一時 dir に展開してダミーソースを touch し、
  `make -n` の出力と Plan のコマンド列を逐語比較(正規化は rstrip + 空行除去のみ)。
  **6 本全て一致**。

**位置づけ**: 次は B2(シェルレス内蔵コマンド実行器)→ B3(in-process ツール
呼び出し + fork 並列)で、実物 Makefile を rmake だけで最後まで走らせる。

---

## Step 57 — rmake のシェルレス実行器(M3 B2)

/bin/sh の無い環境で Makefile レシピを自前解釈する実行層。heavy-implementer へ
移譲(セッション上限で一度中断、SendMessage 再開で完遂)・レビューして確定。

**設計判断**:
- **語彙はコーパスの全ターゲットから確定**: fixtures 6 本の all だけでなく
  install/clean/distclean/realclean まで Plan 展開して棚卸し。ROADMAP の想定に
  無かった `||`・glob(clean の rm 引数)・`rmdir --ignore-fail-on-non-empty -p`・
  `exit >`(mkmf の TOUCH の実体!)が出現して実装対象に、逆にパイプ・サブシェル・
  コマンド置換は出現ゼロで UnsupportedRecipeError(ターゲット + レシピ行を明示)の
  明確失敗にした。
- **and-or リストは sh 同等の左→右単一ステータス**: `&&`/`||`/`;` を 1 本の
  成否が流れる連接として評価。`cd` は行内スコープ(次行は基点から)、`VAR=` 前置は
  その 1 プロセスのみ — make が各行を独立シェルで走らせる意味論の再現。
- **内蔵ユーティリティが正**: rm/mkdir/rmdir/cp/install/echo/touch/true/:/exit を
  FileUtils ベースで内蔵し、**basename ディスパッチ**で `/usr/bin/install` も内蔵に
  解決(実物 Makefile は絶対パスで書く)。外部コマンド(gcc 等)は配列 argv の
  spawn 直接実行でシェル文字列を一切組み立てない。
- **再生テストは実物レシピ**: fixtures 6 本の clean をそのまま実行してファイル
  システム効果を assert(外部コマンド不要の実レシピ)。all は疑似 CC で依存順と
  exit 伝播を確認(実 CC の in-process 置換は B3)。

**位置づけ**: rmake は「パース → 計画 → シェルレス実行」まで通った。次は B3 =
$(CC)/$(LDSHARED)/$(AR) の rubycc 内部 API への in-process 置換 + fork 並列で、
実物 Makefile から rubycc 製 .so を作る統合点。

---

## Step 58 — rmake の in-process ツール置換と -j 並列(M3 B3)

「実物 Makefile → rmake → rubycc 製 .so」の統合点。heavy-implementer へ移譲・
レビューして確定。

**設計判断**:
- **置換は「argv[0] ↔ $(CC)/$(LDSHARED) 第 1 語」の具体名一致**: rubycc の
  Driver が gcc 互換 CLI であることが効き、コンパイル行(-c)もリンク行(-shared)も
  同一写像(argv[0] を落として Driver.run へ)で済む。-shared 等の残り語は展開時に
  レシピへ入っているため前置不要。$(AR) は全 fixture でレシピ出現ゼロ = 写像対象外
  (mkmf の static: は STATIC_LIB 空値依存のみ、という実物の発見)。既定 OFF で
  従来経路は不変。
- **fork + in-process ハイブリッド**(ROADMAP B3 の想定どおり): 逐次はツール
  ごとに fork してクラッシュ隔離、並列は step 単位 fork の worker 内で in-process
  (二重 fork なし)。Driver の再入性は無状態経路の確認 + 「2 回の独立ビルドが
  バイト一致」の決定性テストで担保。
- **-j は Step#prereqs の導出から**: planner の build を「stale step は自身を
  露出、非 step は prereq の露出集合を転送」に拡張し、phony(all)越しの実依存辺を
  線形 Plan 上に張る。失敗時は新規 launch 停止 + drain 後に停止(make の -k off
  相当)、出力は worker ごとにバッファして step 完了時に一括 flush(make -O 相当)。
- **受け入れ**: 実物 json parser Makefile(fixtures 非改変、コピー先の srcdir
  のみ書き換え)で parser.so 生成 → Init_parser dlopen。msgpack はフル 12 TU を
  jobs: 4 で約 30 秒完走(手動確認)。並列の重なり・依存順・失敗隔離は疑似 CC の
  常設テストで検証(ネットワーク前提の実物受け入れは RMAKE_ACCEPTANCE=1 の opt-in)。

**位置づけ**: rmake は mkmf Makefile を最後まで自力で走らせられる。次は B4
(pkg-config シム)→ B5(conftest 完全対応 = mkmf を rubycc で動かす)→
B6(rubygems_plugin で gem install 統合)。

---

## Step 59 — pkg-config シム(M3 B4)

mkmf の pkg_config() が呼ぶ $PKGCONFIG を純 Ruby で置き換えるシム。implementer へ
移譲(一次資料 = mkmf ソースと実物 .pc、仕様確定済み)・レビューして確定。

**設計判断**:
- **CLI 表面は mkmf の棚卸しから**: mkmf.rb の pkg_config(1953 行)が起動する形は
  --exists と xpopen の --{option} 群だけで、既定パスでは libs / cflags-only-I /
  cflags-only-other / cflags / libs-only-l を個別に呼ぶ。この 7 オプションのみ実装
  (pkg-config 本家の全表面は作らない — rmake と同じコーパス駆動)。
- **バージョン制約は CLI 非対応で正しい**: mkmf は pkg をモジュール名のみで渡す
  (制約付き文字列を渡す経路が無い)。.pc 内の Requires に制約が現れた場合は評価
  せず診断(UnsupportedError)。
- **重複除去はしない素朴連結**: 本環境に本家が無く実測不可のため保守的に。
  Requires グラフのモジュール単位再訪問だけはガード(循環防止)。本家差分テストは
  skip ガード付きで、pkg-config のある環境で自動的に検証が効く。
- fixture は実物 .pc のバイトコピー(zlib・openssl→libssl→libcrypto の連鎖)。

**位置づけ**: 次は B5(conftest 完全対応 = mkmf を rubycc ツールチェーンで動かし、
have_header/have_func/try_link/try_run と mkmf.log の体裁まで通す)。

---

## Step 60 — conftest 完全対応: mkmf 統合 shim(M3 B5)

mkmf の conftest(have_header/have_func/try_link/try_run/check_sizeof …)を
rubycc ツールチェーンで動かす統合点。メインセッションで mkmf ソースを精査して
設計を確定し、heavy-implementer へ移譲(セッション上限で一度中断、再開で完遂)。

**設計判断**:
- **差し替えは RbConfig の 4 キーだけ**: mkmf は conftest コマンドを
  `RbConfig::expand("$(CC) …")` で組み、単一文字列 system(メタ文字なしなら直接
  exec)で実行する。CC/LDSHARED/CPP/PKG_CONFIG を rubycc 実行ファイルへ向ける
  shim(lib/rubycc/mkmf_shim.rb、プロセス内のみ・冪等)を mkmf より先に require
  するだけで全 probe が rubycc 経由になる。**mkmf を一切パッチしない**ので
  mkmf.log の体裁は本物のまま(N3)。CONFIG と MAKEFILE_CONFIG の両方を書き換え、
  probe と生成 Makefile の CC = が揃う。
- **実測が炙り出した本質的ギャップ 2 件**(shim 自体より価値が大きい):
  (a) **have_func の偽陽性**: ExecutableLinker が未解決の強参照を残したまま
  実行ファイルを出していた。ROADMAP B5 が予告していた「リンカの未解決検査の
  厳密さがここで効く」の実物で、非 weak の未解決 import を undefined reference
  エラーにして解消(共有オブジェクト側は実行時スコープ補完のため据え置き)。
  (b) **check_sizeof の `sizeof <式>` 定数畳み込み**: ConstantEvaluator は型情報を
  持たないため SizeofExpr を非定数として弾いていた。リゾルバ注入(型を知る IR
  generator だけが供給)で解決し、型文脈の無い場面(パーサの配列長)は従来どおり。
- **受け入れの実り**: msgpack extconf の -DHAVE_* 集合が gcc 採取の fixture と
  一致(= probe の真偽が gcc と同じ)。json は SIMD probe が rubycc に対して
  **自然に偽**になり、M2 受け入れで必要だった JSON_DISABLE_SIMD が不要になった
  (probe 駆動の設計が正しく機能した証左)。

**位置づけ**: extconf.rb → mkmf → conftest → Makefile 生成が rubycc だけで通る。
次は B6(rubygems_plugin: ENV["MAKE"]=rmake 注入で素の gem install を通す)。

---

## Step 61 — rubygems_plugin と rmake CLI(M3 B6・第一段受け入れ達成)

「ユーザがフラグを渡さず `gem install` するだけで C 拡張が rubycc ビルドされる」
統合点。heavy-implementer へ移譲・レビューして確定。

**設計判断**:
- **RubyGems の契約は実測で棚卸し**: Gem::Ext::Builder は ENV["MAKE"] を
  shellsplit して argv 起動(シェル非経由)、実測の起動は
  `rmake DESTDIR= sitearchdir=… sitelibdir=… [clean|(all)|install]` の 4 連で
  **-j は渡されない**。sitearchdir 上書きが install-so の出力先を賄うため、
  **コマンドライン変数上書き(Makefile 内定義より優先)**が CLI の肝(rmake
  ライブラリに新規実装)。
- **exe/rmake は tools: :rubycc 常時 ON**: rmake は rubycc のビルド専用 CLI
  なので、生成 Makefile の CC が gcc のままでも rubycc に差し替える。
- **プラグインは「無効時に完全に不活性」**: rubygems_plugin.rb は全 gem コマンドで
  ロードされるため、RUBYCC=0 / 判定オフでは ENV に一切触れない(テストで担保)。
  有効時のみ MAKE / PKG_CONFIG / RUBYLIB / RUBYOPT(-rrubycc/mkmf_shim)を冪等注入。
  判定は RUBYCC=1/0 / 未設定は「PATH に cc/gcc/make が無ければ自動有効」
  (DESIGN 5.4)。
- **受け入れ**: 素の `RUBYCC=1 gem install json / msgpack` が一時 GEM_HOME で
  成功し、require して round-trip 動作。gem_make.out の exe/rmake と mkmf.log の
  exe/rubycc で「本当に rubycc 経由だった」ことを assert。**ROADMAP B6 の第一段
  受け入れ(ヘッダあり環境での素の gem install)をローカルで達成**。

**位置づけ**: M3 の残りは B7(同梱 libc ヘッダ先行版 + distroless 相当受け入れ =
M3 完了判定)。H1(互換ヘッダ基盤の設計)を先に確定させてから着手する。

---

## Step 62 — ヘッダ ABI ハーネスと libc 配線(M3 B7 前段 = H1)

同梱 libc ヘッダ(R8)の前段。ROADMAP H1 の「ABI 一致の検証機構をヘッダより先に
作る」を実施。heavy-implementer へ移譲(上限中断 → 再開で完遂)・レビューして確定。

**設計判断**:
- **ハーネスは宣言的 Spec → 生成ソース → 二重実行**: sizeof/_Alignof・整数マクロ・
  浮動マクロ(%a 厳密)・offsetof・コンパイル可否 snippet を、gcc + 実ヘッダと
  rubycc + 同梱優先の両方で実行して出力一致を取る。以降のヘッダ追加は必ず
  ケース追加とセット(目視に頼らない)。freestanding 6 ケースで green 稼働。
- **検索パスは 4 層**: freestanding → 同梱 libc ABI 切替層(glibc/x86_64)→
  同梱 libc 共通層 → ホスト。同梱が先勝ちし、include_next(既実装と確認)で
  実ヘッダへ委譲する逃げ道を確保。ホスト層は distroless で自然に消える。
- **棚卸しの発見**: gem 自身が直接 include する libc は assert.h/string.h のみで、
  libc 表面はほぼ全て ruby.h 経由。対象はトップレベル 25 本(宣言のみ 13 /
  型レイアウト要 6 / UAPI 連鎖 6。最難は sys/stat の struct stat と
  ネットワーク系連鎖)。bits/ 84 本は同梱側でフラット定義に畳むため移植対象でない。
- **ハーネスの初仕事**: float リテラルの binary32 丸めバグ(FLT_MAX の 10 進綴りが
  +inf)と max_align_t 相違(long double = double の既知制限の帰結)を検出。
  §3 に負債記録し該当検査は解除条件付きの非 assert。

**位置づけ**: 次 = Step 63(libc ヘッダ第一陣: 棚卸しリストの (a)(b) 群を実装し
ハーネスのケースとセットで固める)→ Step 64(distroless 相当受け入れ = M3 完了)。

---

## Step 63 — 同梱 libc ヘッダ第一陣(M3 B7)

R8(libc 互換ヘッダの同梱)の第一陣 21 本。heavy-implementer へ移譲(上限中断 →
メインセッションが検証を引き継いで確定)。

**設計判断**:
- **musl 派生 + glibc 実測 ABI**(H1 方針の実施): 宣言の出発点は musl(MIT、
  NOTICE に表記)、型幅・レイアウト・マクロ値は ABI ハーネスで gcc に印字させた
  glibc x86_64 実測値に合わせる。bits/ 間接は使わずフラット定義。glibc 実物の
  コピーは一切しない(LGPL)。
- **層の割当**: どの libc でも同じ宣言は共通層(stdio の FILE 不透明ポインタ等)、
  型幅・レイアウトが libc/arch 固有のものは ABI 切替層(stdint/limits/time/
  sys/types 等)。(c) UAPI 群から errno と sys/stat を必要最小で先取り
  (ruby.h スモークが要求)。
- **検証はハーネス駆動**: 21 本全てにケースを付け 27 runs / 81 assertions green。
  **distroless 模擬**(-nostdinc + 同梱のみ、ホスト /usr/include 不使用)で
  ruby.h 拡張が .o 到達することを常設テスト化 — B7 の受け入れの核心が
  コンパイル段について達成された。

**位置づけ**: 次 = Step 64(残りの (c) UAPI 群の充実 + distroless 相当での
json/msgpack フルビルド受け入れ = M3 完了判定)。

---

## Step 64 — distroless 姿勢の受け入れ = M3 完了判定(M3 B7 の締め)

heavy-implementer へ移譲・レビューして確定。

**結果(実測)**:
- json / msgpack の全 TU が **-nostdinc + 同梱ヘッダのみ**(ホスト /usr/include
  完全不使用)でコンパイル → .so 化 → require → round-trip まで成功。
- 不足はただ 1 本: msgpack の sysdep_endian.h が要求する arpa/inet.h。ソケットは
  未使用のため UAPI 連鎖(netinet/in・sys/socket)は**作らず**、必要面だけを
  collapse した自己完結ヘッダで対応(実測駆動の最小主義が最後まで機能)。
- **hermetic ヘッダモード**(RUBYCC_HERMETIC_HEADERS)を新設し、
  `RUBYCC=1 RUBYCC_HERMETIC_HEADERS=1 gem install json / msgpack` が成功・動作。
  mkmf.log 等にホスト include が皆無であることを assert(opt-in 常設)。

**判定**: DESIGN M3 の受け入れ「cc / make / sh / libc ヘッダの無い distroless
相当で gem install が成功」のうち、**ローカルで検証可能な全て**(libc 開発ヘッダ
不使用・cc/make/sh 不使用・conftest はホスト libc.so のリンクのみ = DESIGN 4.2 の
前提どおり)を達成。**M3 完了**。残項目: 真の distroless イメージ / musl コンテナ
での検証(コンテナ環境が無いため未実施。CI 整備時に実施)。sqlite3 / pg の
受け入れも dev ライブラリ導入後(コーパス CI)。

---

## Step 65 — C11 / gcc 拡張カバレッジドキュメント(ユーザ指示成果物)

M3 完了後成果物の 2 件(2026-07-17 指示)。implementer へ移譲・レビューして確定。

- docs/C11-COVERAGE.md: N1570 章立てで 4 値判定(133 表行)。条番号は原典 PDF を
  取得して TOC 裏取りし、指示文の例示ミス(freestanding ヘッダの本数・7.17 の
  誤り)も原典側に合わせて訂正された。判定は負債表・スキップ表・STEPS.md・
  lib/ grep の実測のみから起こし推測なし。
- docs/GCC-EXTENSIONS.md: 29 拡張を実装方式 3 分類(正確対応 / 受理して実体なし /
  正直に非対応と答えてフォールバック誘導)で一覧化。

---

## Step 66 — gcc 速度比較ベンチマーク(ユーザ指示成果物)

M3 完了後成果物(2026-07-18 指示)。heavy-implementer へ移譲(上限中断 → 再開で
完遂、ドキュメントはユーザ指示により日本語で作成)・レビューして確定。

- benchmark/ にコード一式(C カーネル 5 本 + json/msgpack 実ワークロード +
  3-way ハーネス)、docs/BENCHMARKS.md に実測・考察。
- **劣位ケースを含む実測**(指示要件): 最大は json の gcc-O2 比 7.65x・
  arrayscan 7.41x(tight loop、レジスタ割付/ベクトル化の不在)。gcc-O0 比では
  全ケース 1.1〜2.9x で、非最適化コード同士では十分競合。分岐・VM 律速では
  差が縮む(treesum 1.22x / msgpack 2.60x)。N2(gcc-O2 比 2〜5x)は tight loop
  系で超過 — 構造的帰結として記録し、M6 レジスタ割付を改善余地と明記。

## Step 67 — rubycc-doctor と確認済み gem データ(ユーザ指示成果物)

M3 完了後成果物(2026-07-17 指示)。heavy-implementer へ移譲(上限中断 → 再開で
完遂)・レビューして確定。

- exe/rubycc-doctor: Gemfile.lock(推移閉包)→ C 拡張判定(.gem 取得 +
  Gem::Package。API は extensions を返さないことを実測確認)→
  data/verified_gems.json 一次参照 → 未確認はその場ビルド(extconf(shim)→
  rmake → require)で失敗段階特定 → 判定表 + 採用可否サマリ。
- 実測: 未収載の racc 1.8.1 がその場ビルド → require OK → ADOPTABLE。
- これで **M3 完了後のユーザ指示成果物 4 件(C11-COVERAGE / GCC-EXTENSIONS /
  ベンチマーク / doctor)が全て完了**。

---

## Step 68 — バックエンド抽象化リファクタ(M4 A1)

M4 の初手。heavy-implementer へ移譲・レビューして確定。**挙動変更ゼロ**が受け入れ基準
(A1 の定義)で、リファクタ前後の .o バイト一致(git stash 旧実装との比較 3/3)で裏取り。

- リロケーション語彙を**機種非依存の 6 種**に固定: .text 側 :call(:func は
  compiler.rb が同経路に集約)/ :string / :global / :got、.data 側 :symbol / :rodata。
  バックエンドは R_X86_64_* を一切知らない。
- `ObjFile::ELFWriter::MachineDescription`(Data)= e_machine 値 + 「kind →
  `RelocDesc(type, addend, symbol)`」表をコンストラクタ注入。addend は固定バイアス
  (x86_64 の PC 相対 −4)か :recorded(reloc 自身の addend)、symbol は :named か
  :rodata_section。build_rela / build_rela_data は共通の append_machine_reloc に
  テーブル駆動で一本化。既定機種 `ELFWriter::X86_64` が psABI の型・addend 規約を固定。
- `Compiler::TARGETS`(ターゲット名 → backend クラス + 機種記述)でディスパッチ。
  ドライバに `-target`/`--target=` を追加(既定はホスト検出 =
  RbConfig::CONFIG["host_cpu"]、amd64/x64 → x86_64・arm64 → aarch64 の正規化と
  triple の先頭要素採用)。aarch64 は「not implemented yet」、未知は
  「unsupported target」の UsageError。
- 契約の明文化は docs/IR.md §6 に追記(バックエンドとの契約の一部のため、IR 例外
  ルールの範囲)。aarch64 のコードは一行も書いていない。

---

## Step 69 — binary64 → binary32 の正しい丸め(§3 債務の消し込み)

ABI ハーネス(Step 62)が検出していた「同梱 float.h の `FLT_MAX` が +inf になる」
バグの解消。原因は Ruby の `Array#pack("e")` が binary32 の表現範囲を超える大きさを
**丸めずに +inf へ飽和**させることで、`3.40282347e+38F` は真値が FLT_MAX から半 ULP
以内にあり最近接丸めなら FLT_MAX になるべきものだった。

- 特別扱いの範囲分岐を積む代わりに、double のビット界(符号・指数・仮数)を辿って
  52 ビット仮数を 23 ビットへ**最近接・偶数丸め**で縮約する 1 本の変換
  (`#double_to_binary32_bits`)に統一。オーバーフロー(→ 無限大)・非正規数への
  段階的縮退・最小正規数への繰り上がりが、いずれも同じ丸め 1 回の結果として出る。
  シフト量は Ruby の多倍長 Integer で扱うので、深い underflow でも正確。
- 定数材料化(`#float_bit_pattern`)とグローバル初期化子のパック(`#pack_float`)の
  両経路が同じ変換を通る。double 側(8 バイト)は従来どおり `pack("E")`。
- 検証は単体 15 件(FLT_MAX の 10 進綴り・厳密な同点が偶数側=無限大へ倒れること・
  同点の直下は FLT_MAX へ・偶数丸めの上下・FLT_TRUE_MIN・その半分の underflow・
  符号付きゼロ・無限大・NaN)+ gcc 差分の実行テスト。ハーネス側は FLT_MAX を
  非 assert から通常の検査へ戻し、README の既知ギャップから当該行を削除した
  (残る非 assert は long double = double 由来の max_align_t のみ)。
- 新機能ではなくバグ修正のため examples の追加はなし(値の一致は gcc 差分テストが
  常時検証する)。

---

## Step 70 — aarch64 コーデジェン・コア(M4 A2)

第二バックエンドの本体。heavy-implementer へ移譲し、エンコーディングをメインセッションで
仕様値と突き合わせてレビュー。**A1 で切ったバックエンド契約(IR::Function → Result)を
一切変えずに** 2 機種目が載ることを実証した。

- **フレームは sp からの正オフセット**(x86_64 の rbp 負オフセットと対照的)。理由は
  A64 の ldr/str は「スケール済み非負 12bit 即値」(64bit アクセスで 0..32760)が基本形で、
  fp 相対の符号付き形は 9bit 非スケール(−256..255)しかなく現実的なフレームで即溢れるため。
  溢れた場合にアドレスを加算で合成する経路(12bit 2 段 → 超巨大は materialize + 拡張レジスタ加算)を
  最初から用意した。保存レコード(x29/x30)はフレーム最下端 [sp+0] に置き、stp/ldp の
  オフセットを常に 0 にしている。
- 32bit 演算は w レジスタで行い C int のラップアラウンドを再現(x86 の eax と同じ理屈)。
  スロットは常に 64bit 単位で読み書きする値表現規約はそのまま適用。
- 比較は `subs`(cmp)+ `cset`。除算に剰余命令が無いため、剰余は `sdiv`/`udiv` の商を
  経由して `msub` で復元する。即値は MOVZ + 非ゼロ 16bit フィールドごとの MOVK で合成。
- 分岐は B(26bit・±128MB)と CBZ(19bit・±1MB)のバックパッチ。範囲外は黙って
  切り捨てず raise する。
- **副産物として x86_64 の暗黙の仮定を 2 つ検出**(M4 の狙いどおり):
  (1) 関数間パディングが全機種で x86 の `0x90` 固定だった → `MachineDescription` に
  `text_padding` を追加し aarch64 は NOP ワード 0xD503201F に。(2) 自作 ELF リーダが
  EM_X86_64 以外を拒否し、リロケーション型名表がアーキ非依存の単一表だった →
  e_machine キーの二段テーブルへ再構成。
- 未対応構文(グローバル・文字列・浮動小数・struct 値渡し・varargs・間接呼び出し)は
  `Backend::UnsupportedError` で明示的に拒否し、ドライバが gcc 風の診断として報告する。
  黙って誤コードを吐かないことをテストで固定した。
- **判明した ABI 上の制約**: IR ジェネレータが引数を **System V AMD64 の規則で分類済み**
  (:gp/:sse4/:sse8/:mem)で backend に渡すため、GP レジスタ 6 本を超える引数は
  `:mem` として届く。AAPCS64 の x0-x7 は 8 本あるので本来レジスタで渡せるが、
  `:mem` はスカラ第 7 引数か MEMORY 構造体の eightbyte か区別できず、推測すると
  誤コードになる。よって当面は拒否とし、**引数分類の per-target 化を A4 の作業として
  ROADMAP に記録**した(実効上限は当面 6 引数)。
- **検証の限界(重要)**: 開発ホストに qemu-user・aarch64 クロス gcc・aarch64 対応
  objdump のいずれも無く、**生成コードの実行・逆アセンブルによる独立検証はできていない**。
  そのため検証は 3 層(命令エンコーディングを ARM DDI 0487 のビットフィールド定義から
  組み立てた期待値と比較 / 関数まるごとの構造・バックパッチ変位・リロケーション記録 /
  自作 ELF リーダによる e_machine・CALL26 の統合確認)に留まる。テストの期待値も
  同じ仕様書読解に依存するため、**読み違いがあれば実装とテストが同方向に誤る**リスクが
  残る。独立オラクル(アセンブラ/エミュレータ)での検証は環境導入後に行う。
- examples の追加なし(サンプルは gcc 差分で**実行**検証する仕組みのため、実行環境の
  無い aarch64 では成立しない)。

---

## Step 71 — aarch64 の実行オラクル検証(Step 70 の残存リスクの解消)

Step 70 で「生成コードを一度も走らせていない」ことを最大の残存リスクとして記録していたが、
開発ホストに **qemu-user(qemu-aarch64)とクロス gcc(aarch64-linux-gnu-gcc 13.3.0)**を
導入できたため、実行による検証に切り替えた。

- ハーネス(`test/support/aarch64_execution_helper.rb`)は
  「rubycc で aarch64 の .o → クロス gcc で `-static` リンク → qemu-aarch64 で実行」。
  中心は**差分アサーション**で、同一ソースをクロス gcc でもビルドして走らせ、
  終了コードと標準出力の一致を見る。期待値を人が計算しないので、
  期待値の誤りが結果の誤りを隠せない。
- ツールの無いホストでは skip(存在確認はプロセス内 1 回でメモ化)。既存の
  `ExecutionHelper` と x86_64 経路は無改変。
- **検証の制約**: A2 には文字列リテラルが無いため `printf` が使えない。標準出力は
  `putchar(int)`(直接呼び出しなので A2 の範囲内)で 1 文字ずつ出す。また終了コードは
  下位 8 ビットしか運べないため、幅の広い結果は自前の 10 進出力ヘルパで stdout に流す。
- テスト 34 件。負数の除算・剰余は被除数 8 種 × 除数 ±3 の総当たり、シフトは量 0..30 と
  62/63 の境界、比較は符号あり 36 組・符号なし 16 組、ほかに goto/switch/相互再帰/
  各幅 load/store/ポインタ演算/大フレーム(スロットオフセットが 4095*8 を超えて
  アドレス合成経路に入ることを実測で確認)/逆アセンブルに不正命令が現れないこと。
- **結果: バックエンドの実バグはゼロ**。条件コードの符号あり/なし、`msub` のオペランド順、
  アドレス合成経路など要注意箇所はいずれも実オラクルを通過し、Step 70 の机上検証が
  妥当だったことが裏付けられた。
- **副産物として ABI 非適合を 1 件検出**: rubycc は素の `char` を全ターゲットで
  **符号あり**として扱うが、**aarch64 Linux psABI では符号なし**(x86_64 は符号あり)。
  バックエンドではなく型システム側のターゲット依存プロパティであり、修正は x86_64 にも
  波及するため A2 のスコープ外と判断し、テスト側で `signed char`/`unsigned char` を
  明示して回避したうえで、**§3 の債務と A3 の作業項目に記録**した。
- 未検証として残るもの: 16MB 超フレームの第 3 経路(qemu の既定スタック上限で
  rubycc/gcc 双方がクラッシュし差分比較が成立しない)、クロス翻訳単位の ABI 適合
  (gcc が吐いた呼び出し元と rubycc の関数を混ぜる検査。x86_64 の `test_cross_abi.rb`
  に相当する aarch64 版は未整備)。

---

## Step 72 — aarch64 のシンボルアドレスとペア・リロケーション(M4 A3)

aarch64 は 64 ビットアドレスを 1 命令で名指せないため、**1 参照が 2 命令 2 リロケーション**
になる(x86_64 は 1 命令 1 リロケーション)。この構造の違いをどこで吸収するかが設計の核。

- **バックエンドは先頭の `adrp` の位置だけを 1 件記録し、ペアへの展開は ELF ライタが行う**。
  「1 参照が何エントリになるか」は機種の性質であって、コード生成側の関心ではないため。
  機種記述を「kind → `RelocDesc` の**配列**」に変え、`RelocDesc` に `offset_delta`
  (先頭命令からの適用位置。aarch64 のペアは 0 と 4、x86_64 は常に 0)を追加した。
- 併せて **A1 の抽象化漏れを是正**。compiler.rb が `:string` の addend を
  `string_offsets[id] - 4` と x86 固有の PC 相対バイアス込みで計算していた。
  `RelocDesc` に `addend_bias` を追加してバイアスを機種記述の責務とし、compiler は
  バイアスを含まない生のオフセットを渡すようにした。
- **`:call` と `:func` を別 kind に分離**。x86_64 では両者とも PLT32 で一致するため
  compiler.rb が同一経路に集約していたが、aarch64 では前者が `bl` の CALL26、後者が
  アドレス生成のペアで別物になる。x86_64 で偶然一致していた 2 つの概念が、
  第二バックエンドで分離を要求した例。
- 非 PIC は ADRP + ADD(`R_AARCH64_ADR_PREL_PG_HI21` + `R_AARCH64_ADD_ABS_LO12_NC`)、
  PIC は ADRP + LDR(`R_AARCH64_ADR_GOT_PAGE` + `R_AARCH64_LD64_GOT_LO12_NC`)。
  前者はリンク時にシンボルを束縛し、後者は GOT スロットを**読む**ことで実行時の
  差し替え可能性を保つ。どちらも宛先スロットには使えるポインタが入るので、
  そこから先の load/store は変わらない。
- リロケーション型番号は**推測せずクロス binutils の実物出力(`readelf -r`)で裏取り**した。
- **x86_64 の出力は 68 サンプルでバイト一致**(挙動変更ゼロ)。
- 検証は差分実行テスト 23 件。文字列リテラルが使えるようになったため、標準出力の検証が
  `putchar` から `printf` に移行できた。libc の extern データシンボル(`stdout`)と
  extern 関数(`printf`)への GOT 経由アクセスも含む。
- 多次元配列はフロントエンド全体の既知の制限(パーサが拒否)で aarch64 固有ではないため
  対象外とした。間接呼び出し・浮動小数・struct 値渡し・varargs は A4 として未対応のまま。

---

## Step 73 — 素の char の符号性のターゲット化

Step 71 の aarch64 実行差分テストが検出した ABI 非適合の解消。素の `char` の符号性は
処理系定義(6.2.5p15)で **ABI ごとに決まる**: x86_64 System V は符号あり、AAPCS64 は
符号なし。rubycc は全ターゲット符号あり固定だった。

- 前提として**文字型の分離**が必要だった。従来 `signed char` は素の `char` に正規化されて
  専用インスタンスが無かったが、`signed char` は標準上つねに符号ありでターゲットに
  依存しないため、素の char と同一にはできない。結果、文字型は 4 実体になった:
  素の char の符号あり/符号なし 2 実体(**どちらも綴りは `"char"`** なので診断メッセージや
  `#char?` はどちらでも同じに読める)+ ターゲット非依存の signed char / unsigned char。
- ターゲット選択は `Compiler::TARGETS` の `char_signed` から `Type.plain_char` で
  1 実体を作り、プリプロセッサ(`__CHAR_UNSIGNED__` の有無)・パーサ(`char` 型指定子の
  解決先)・IR ジェネレータ(**文字列リテラルの要素型はパーサではなくジェネレータが決める**)
  の 3 段へ配る。真偽値ではなく **Type インスタンスを渡す**設計にして、
  「符号性 → 型」の対応を `Type.plain_char` の 1 箇所に閉じ込めた。
- **符号性を消費する側は無変更で済んだ**。整数昇格・定数畳み込み・load/store の符号拡張・
  比較・除算・右シフトはすべて `type.signed?` / `type.size` 経由の型駆動だったため、
  aarch64 バックエンドは IR の指示どおり `ldrb`(ゼロ拡張)を選ぶようになる。
  char 型を**生成する**箇所は 4 箇所しかなかった(パーサの型指定子解決、ジェネレータの
  文字列リテラル 4 箇所、初期化子解決の char 配列判定、型インスタンス定義)。
- 同梱 limits.h は `__CHAR_UNSIGNED__` で `CHAR_MIN`/`CHAR_MAX` を分岐。**arch ディレクトリで
  はなくコンパイラの定義済みマクロから取る**形にした(同梱ヘッダの arch レイヤは
  x86_64 固定のままのため)。実測値はクロス gcc と一致(x86_64 = −128/127、aarch64 = 0/255)。
- **x86_64 の出力は 12 サンプルでバイト一致**(挙動変更ゼロ)。
- **受理範囲が狭まった点(意図的)**: `char *` と `signed char *` が非互換になった。
  従来は `signed char` が `char` に正規化されていたため通っていたが、C 標準上は
  制約違反(gcc も警告する)。`char *` と `unsigned char *` は従来からエラーで、
  `signed char *` だけ通るのは非対称だった。実 C 拡張のビルドテスト(ruby.h +
  TypedData)を含む全テストが green のまま通ったため厳密化を採用。将来コーパスで
  問題が出た場合は `Type.character?` を使って 1 バイト文字型間のポインタ互換を
  緩める逃げ道が 1 箇所で書ける(§3 に記録)。
- 範囲外として残した不整合: **aarch64 ターゲットでも `__x86_64__`/`__amd64__` を
  定義したまま**(改修前からの挙動)。§3 に記録した。

---

## Step 74 — 既存実行スイートの aarch64 展開(M4 A3 の締め)

M4 の狙い「**x86_64 で規約化したものを第二のバックエンドが検証する**」が実際に機能した
ステップ。専用テストではなく**既存の実行テスト資産**を aarch64 で回し、通過率を実測した。

- **c-testsuite 220 ケース中 191 件が aarch64 で通過**。x86_64 で通っているケースのうち
  A4 の未対応機能に当たらないものは**全件が同じ出力**を出した。
- ヘッダの解決が要点だった。ホストの `/usr/include/x86_64-linux-gnu` も同梱の
  `include/libc/glibc/x86_64/` も **x86_64 ABI 固定**なので使えない。`system_includes: false`
  で両方を排除し、クロス環境の `/usr/aarch64-linux-gnu/include`(クロス gcc の `-E -v`
  出力で確認)と、ABI 中立なコンパイラ提供ヘッダ(`include/`)だけを使う。
- **SKIP を 2 系統に分離**した。A4 バックエンド未対応 12 件(間接呼び出し 6・浮動小数 6)は
  個別列挙して**そのまま A4 の作業リスト**とし、ターゲット非依存の既知債務 17 件は
  x86_64 側の SKIP を**コピーせず参照**する — フロントエンド由来で target 次元を持たない
  以上、両者が食い違ってはならず、片方を直せば両方が自動で消えるため。両リストが
  交差しないことを検査するテストも置いた。
- examples 36 本の差分ランナーも追加し **26 本が一致**。残り 10 本から、c-testsuite では
  出てこなかった A4 項目(struct コピー・alloca・bit-scan builtins・varargs 定義)を
  追加で洗い出せた。
- **実バグ 2 件を検出・修正**(どちらも x86_64 の暗黙の仮定):
  1. **名前なしビットフィールドの整列規則**。System V psABI は「名前なしビットフィールドの
     型は構造体の整列に影響しない」、**AAPCS64 は逆**ですべてのビットフィールドの
     コンテナ型が寄与する(`struct { char c; long : 1; }` が x86_64 で 2/1、aarch64 で 8/8)。
     gcc で 10 形状を両ターゲット実測して規則を確定させ、`unnamed_bitfields_align` として
     TARGETS に特性化した。
  2. **`__x86_64__`/`__amd64__` が常に定義され `__aarch64__` が未定義**だった。
     aarch64 向けなのにユニットが `#ifdef __x86_64__` で誤った枝を選び、クロス libc ヘッダを
     誤った CPU 同一性の下で読んでいた。CPU 識別マクロを共通部と per-target に分割し、
     target を完全に無視していた `-E` 経路も併せて是正(§3 の債務を消し込み)。
- **既定で回す判断**: 増分は約 +64 秒(400 → 441 秒、+16%)。ツールが無いホストでは
  丸ごと skip されるため移植性を損なわず、環境変数でゲートすると「誰も回さないので
  気づかない」状態になり、今回 2 件の実バグを掘り当てた検出力がそのまま失われる。
- 残存する x86_64 前提として、同梱 `stddef.h` の `wchar_t` が `int` 固定(aarch64 gcc は
  `unsigned int`)。ワイド文字リテラルは意図的な診断で拒否しており観測可能な誤りに
  至らないため未修正、§3 に記録。

---

## Step 75 — aarch64 の浮動小数と間接呼び出し(M4 A4 第一段)

A4(ABI 完全化)の最初の一段。変更は aarch64 backend に閉じ、x86_64 と IR は無変更。

- **浮動小数値のスロット往復**は値自身の幅で `ldr`/`str` の S/D 形式を使い、汎用レジスタを
  経由しない設計にした。`float` のスロットは意味のある 4 バイトしか持たず上位半分は不定
  なので、D レジスタとして読むと**まったく別の数値を演算に渡してしまう**。整数側の
  「8 バイト未満の値は低位 size バイトだけを保証する」という値表現規約と同じ理屈で、
  x86_64 の movss/movsd の使い分けにも対応する。`fmov` 経由は 1 オペランドあたり
  2 命令増えて得るものがない。
- スクラッチは v16/v17(引数の v0-v7 と callee-saved の v8-v15 を回避)。
- **比較の NaN 規則が x86 と構造的に違う**のが設計上の要点。FCMP は unordered
  (どちらかが NaN)を **N=0 Z=0 C=1 V=1** という ordered では決して出ない組み合わせで
  報告する。そこで MI / LS / GT / GE を選ぶと、NaN 相手に `< <= > >=` の 4 条件すべてが
  false になり C の要求どおりになる。等値は FCMP が unordered で Z を**クリア**するため
  (x86 の ucomis は ZF を**セット**する)、素の EQ/NE だけで NaN 規則が出る —
  x86 側で必要な sete+setnp のような組み合わせが要らない。
- 変換は `scvtf`/`ucvtf`・`fcvtzs`/`fcvtzu` を記述子どおり選ぶ。機械が符号なし版を持つため、
  x86 側で必要だった「unsigned int を 64 ビットへ広げる」細工が不要。
- 間接呼び出しは引数配置の**後**に呼び出し先を x9 へロードして `blr`。x9 は引数レジスタでは
  ないので、配置済みの引数を壊さない。
- **成果: c-testsuite の A4 保留 12 件のうち 11 件が通過**。残る 00174 は浮動小数でも
  間接呼び出しでもなく、**整数 7 引数**(`printf` に値を 6 個並べただけの、ごくありふれた形)
  が原因だった。IR が System V AMD64 で分類するため 7 番目が `:mem` になり、
  AAPCS64 なら x6 に載るものが拒否される。examples の保留も 10 → 9 件に減り、
  停止要因が変わっていた 2 件の理由も実測に合わせて訂正した。
- **判明した優先順位**: 残る最大のボトルネックは struct 値渡しではなく
  **IR の引数分類が System V 固定であること**。整数 7 個以上の呼び出しが全て止まり、
  00174 も step21_dispatch もこれ 1 つが原因。バックエンド側では原理的に解けない。
- 既知の意味論差: `:ftoi` の符号なし変換に `fcvtzu` を使うため、**範囲外入力(C では
  未定義動作)で x86_64 バックエンドと結果が食い違いうる**。範囲内では完全一致し、
  差分テストのオラクルである gcc-aarch64 の下ろし方とも一致するためこちらを採った。

---

## Step 76 — 引数分類のターゲット化(M4 A4)

Step 75 の実測で「残る最大のボトルネックは struct 値渡しではなく引数分類」と判明した
ため、優先度を上げて着手。`printf` に整数を 6 個並べただけの形(可変長を含めて 7 個)が
止まっていた。

- **分類器を `IR::CallConvention` としてターゲット記述化**。保持するのは 4 つだけ:
  整数/ベクタ引数レジスタ数(System V = 6/8、AAPCS64 = 8/8)と、規約固有の 2 機構を
  名指すタグ。`place_argument_kinds` は本数を規約から取るだけで、all-or-nothing 規則を
  含むロジックは不変。**struct の eightbyte 分類は一切触っていない**(次段)。
- **安全性のための 2 タグ導入が設計の要点**。単に GP を 8 本にすると、これまで `:mem` で
  拒否されていた「16 バイト超 struct の値渡し」「大きな struct 返し」が**黙って
  System V の規則で通ってしまい**、AAPCS64(参照渡し・x8 間接返し)と食い違って
  silent miscompile になる。`:indirect`(参照渡しされる集約の eightbyte)と
  `:indirect_result`(専用レジスタで渡す隠れ結果ポインタ)を専用の kind にして、
  未実装のバックエンドが**名指しで拒否**できるようにした。16 バイト以下の struct が
  溢れてスタックに載るケースは AAPCS64 §6.4.2 C.11 と一致するので `:mem` のまま。
- **aarch64 のスタック引数と sp の関係**が最大の設計判断。この backend は全ての値を
  `[sp + off]` で名指すため、**呼び出しごとに sp を動かすと全スロットのオフセットが
  同時に無効化される**(まだ配置していない引数のスロットも含めて)。そこで
  **outgoing argument area をフレーム最下部にプロローグで一度だけ確保**し、関数本体を
  通じて sp を固定した。サイズは IR 命令列を走査して関数内で最も引数の多い呼び出しに
  合わせ 16 に丸める(同時に in-flight な呼び出しは 1 つなので全呼び出しで共有できる)。
  スタック引数を持たない関数のフレームは不変。
- 着信スタック引数は `[sp + frame_size + 8k]`。AArch64 は戻りアドレスを x30 に持ち
  スタックに何も積まないため、呼び出し側の sp がちょうどそこにある。
- 配置は「スタック引数を先に一括 → 次にレジスタ」の 2 パス。スクラッチと引数レジスタの
  干渉順序が引数列の並びから独立する。
- **x86_64 は 254 ファイル(examples 全件 + c-testsuite 本体)でバイト一致**。
- **成果: c-testsuite の aarch64 保留リストが空になった**(220 件中 203 件通過、
  残り 17 件はターゲット非依存の既知債務)。examples の保留も 9 → 8 件。
- IR 契約を変更したため、`ir.rb` のコメントと `docs/IR.md`(§2 param_kinds、§5 :call、
  §8.2 出典表に AAPCS64 §6.4.2)の両方を更新した。x86_64 が観測する kind 集合は不変。
- **判明した既存の silent miscompile**: `struct { float a, b; }` の**値渡し**は本変更
  以前から誤っている。System V は 2 つの float を 1 eightbyte にまとめて d0 へ、
  AAPCS64 は HFA として s0/s1 へ渡すため一致しない。`struct {double,double}` や整数を
  含む struct は偶然一致する。`:memcpy` 未対応のため到達経路は細い(引数として直接
  渡す形のみ)がゼロではなく、**struct 分類のターゲット化で最優先に扱う**(§3 に記録)。

---

## Step 77 — 集約分類のターゲット化(M4 A4 の本体)

Step 76 で記録した **`struct { float a, b; }` の silent miscompile** の解消が最優先目的。
System V は 2 つの float を 1 eightbyte にまとめて d0 へ渡すが、**AAPCS64 は HFA
(Homogeneous Floating-point Aggregate)として s0/s1 の別レジスタへ渡す**。

- `IR::CallConvention` を抽象基底とし `SystemVAMD64Convention` / `AAPCS64Convention` の
  2 実装に分けた。System V の eightbyte 分類ロジックはジェネレータから**そのまま移設**
  (挙動不変)。ターゲット依存なものは 3 つ: レジスタ本数、`aggregate_plan`(集約の
  切り分け)、`placer`(引数リストの走査規則)。
- **`AbiPiece(offset, size, kind)` にオフセットと幅を持たせたのが設計の要点**。
  System V は常に `(8*i, 8)`、AAPCS64 の HFA は `(4*i, 4)`。「同じ struct が x86-64 では
  1 eightbyte、aarch64 では 2 レジスタ」という差がこの 1 箇所に閉じる。
- **配置器を逐次型にしたのは x86_64 のバイト一致のため**。集約は「レジスタに乗るか
  溢れるか」で切り分け方自体が変わる(溢れた HFA は eightbyte 単位で積む)ので配置決定が
  必要だが、配置は左側の引数にしか依存しない。引数生成と同じ順で問い合わせれば
  命令の発行順が一切変わらない。
- **HFA 判定**は要素サイズと個数を再帰的に求め(struct は加算・配列は乗算・**union は最大**・
  スカラは `[size, 1]`、ビットフィールドや整数が 1 つでもあれば失格)、さらに
  **`size == count * element_size` を検証**する。`aligned(16)` を付けた
  `struct {float,float}` はメンバ 2 個でも 16 バイトを占め、gcc は HFA 扱いせず x0/x1 で
  渡す — 個数だけ見ると誤判定する。実物の `gcc -S` 出力と突き合わせて確定させた規則:
  - HFA 判定は **16 バイト制限より先**(double×4 = 32 バイトでも d0..d3)
  - **packed struct は memory 化しない**(System V の unaligned-field 規則に AAPCS64 の
    対応物は無い)
  - HFA が溢れると **NSRN のみ**飽和(後続の int は x0 に届く)、非 HFA 集約が溢れると
    **NGRN のみ**飽和(後続の int はスタック)
  - 16 バイト整列の集約は**偶数番 x レジスタから**
  - 溢れた HFA はメンバごとではなく **eightbyte 単位**で積む
- aarch64 backend に x8 間接結果・参照渡し・HFA の v レジスタ配置・`:memcpy` を実装。
- **IR 契約の変更 2 点**(`ir.rb` と `docs/IR.md` の両方を更新):
  1. **`:indirect` タグを削除**。参照渡しされる集約は、ジェネレータが「呼び出し側コピーへの
     通常の `:gp` ポインタ」に縮約する。backend 側に専用規則が要らなくなり、未使用タグを
     残すより契約が正直になる。`:indirect_result`(x8)は専用レジスタが要るので残す。
  2. **戻り記述子をクラス配列から `AbiPiece` 配列へ**。HFA のメンバ幅・オフセットを
     表現するために必要だった。
- **x86_64 は 254 ファイルでバイト一致**(examples 全件 + c-testsuite 本体。旧実装は
  `git archive HEAD` で作業ツリーに触れず取り出して比較)。メインセッションでも
  20 ファイルで独立に裏取りした。
- 検証: IR レベルで `param_kinds` が `[:sse8]` 対 `[:sse4, :sse4]` に分岐することを確認し、
  実行でも rubycc / gcc(aarch64)/ x86_64 の三者が一致。逆アセンブルでも rubycc が
  gcc と同じく s0/s1 で受け取ることを確認した。
- examples の保留は 8 → 6 件(`step25_records` と `step53_compound_literals` が通過。
  `step28_wideint` は struct copies を抜けたが 128 ビット乗算で止まるため理由を書き換えた)。
- **残る制約**: スタック引数の 16 バイト整列は未対応(IR の `:mem` スロットが 8 バイト単位
  固定のため、`__int128` を含む集約がスタックに溢れる場合)。ただしこれは **x86_64 側にも
  元からある同じ穴**で、今回入ったものではない。レジスタ側の偶数番規則は実装済み。

---

## Step 78 — aarch64 の可変長関数の定義(M4 A4 完了)

A4 の最後の項目。呼び出し側は Step 75/76 で対応済み(AAPCS64 では可変長引数も固定引数と
同じレジスタ規則のため)で、残るは**定義側**だけだった。

- **va_list はターゲットで構造が全く違う**のが本質。System V の 4 フィールド
  (gp_offset/fp_offset/overflow_arg_area/reg_save_area)に対し、AAPCS64 は 5 フィールド
  (`__stack`/`__gr_top`/`__vr_top`/`__gr_offs`/`__vr_offs`)。しかもセマンティクスが逆で、
  System V は「先頭からの正のオフセット」、**AAPCS64 は top からの負のオフセットが 0 に
  向かって増える**(0 に達したらそのファイルは尽きて `__stack` から取る)。
- ターゲット化は `IR::CallConvention` に持たせた(`va_list_tag`/`va_list_type`/
  `va_list_abi`)。va_list は呼び出し規約が引数を並べたレジスタ/スタック配置を
  そのまま歩くものなので、タグの形・型・va_arg 歩行の流儀はすべて同一 ABI の別側面。
- `AArch64VaListTag`(5 フィールド)は**タグ 1 要素配列**にしてポインタ decay を統一した。
  gcc の aarch64 は素の struct だが、配列 decay で得られる「32 バイト tag へのポインタを
  1 整数レジスタに載せる」形は AAPCS64 の参照渡しとバイト等価で、vprintf 転送も同じ
  レジスタに同じポインタが載る。
- **va_arg の lowering を `va_list_abi` で分岐**し、System V パスは**一切変更しない**
  (x86 バイト等価の担保)。AAPCS64 は別 lowering として新設した。2 つの歩行は逆向きの
  オフセットで別構造を読むので、記述子で 1 つにまとめず別実装にするのが素直。
- **va_copy を新規実装**した(既存はキーワード未対応だった)。lexer/preprocessor/parser/
  AST/generator に `__builtin_va_copy` を追加し、タグ全体の `:memcpy` に降ろす
  (IR 命令の追加なし)。
- aarch64 の可変長プロローグはフレーム最上部に VR 退避域(128B)+ GP 退避域(64B)を確保し、
  x0-x7 と d0-d7 を退避。`:va_start` で 5 フィールドを書き込む。
- **実装中に発見した不具合**: `__stack` を caller_sp としていたが、gcc は名前付き引数が
  スタックに溢れた分だけ進める(`__stack = caller_sp + 8*named_stack`)。9 整数引数の
  実行テストで露見し、gcc の asm(frame 240 / `__stack` = 248)と突き合わせて修正した。
- **x86_64 は 254 ファイルでバイト一致**。examples の保留は 6 → **3 件**(variadic 3 件が
  通過。残りは alloca・128 ビット乗算・bit-scan で、いずれも aarch64 固有ではない
  既存の未実装機能)。
- 残る制約: 可変長への struct 渡しは依然未対応(両ターゲットで診断。c-suite 00140 も
  既存 SKIP のまま)。va_arg の許容型は int/long/pointer/double のみ(既存どおり)。

---

## Step 79 — aarch64 実行ファイルの自作リンク(M4 A5 第一段)

A2〜A4 の aarch64 実行検証はすべて**クロス gcc でリンク**していた。A5 でリンクも自前化する。
このステップは実行ファイルリンカと crt に絞り、共有ライブラリ(gem install 用)は次段。

- **成果: rubycc 自身のリンカだけで aarch64 実行ファイルを生成し qemu で実行できる**。
  gcc/binutils 不要という目標に前進。
- 機種依存/非依存の切り分けが設計の中心。ELF ヘッダ・セクション・シンボルテーブル・
  .hash・.dynamic 構築・3 セグメントのページ整列レイアウトは**非依存でそのまま流用**。
  機種依存は 8 点(e_machine・再配置型番号・再配置スキャン分類・再配置適用・PLT スタブ
  命令列・動的再配置型・crt の _start 命令列・セグメント整列)。
- **x86_64 のバイト一致を構造的に保証する方式**: `elf_writer.rb` の MachineDescription
  思想に倣い、機種を e_machine で判定して機種依存メソッドの先頭で aarch64 分岐に振り、
  **x86_64 の本体コードは一字一句そのまま残す**。リンク対象機種は入力 .o の e_machine
  から判定する(ExecutableLinker は crt 生成が merge 前なので入力ヘッダを直読み、
  SharedLinker は merge 後の reader.machine)。
- crt(_start)は `__libc_start_main(main, argc, argv, init, fini, rtld_fini, stack_end)`
  を x0-x6 に積む規約を実物の gcc バイナリの逆アセンブルで裏取りした。
- PLT は per-function スタブ `adrp x16 / ldr x17,[x16,#lo12] / add x16 / br x17` の
  16 バイト、.got.plt 先頭 3 スロット予約。動的再配置型は readelf -r で実測
  (JUMP_SLOT=1026、GLOB_DAT=1025、RELATIVE=1027、ABS64=257)。セグメント整列は
  aarch64 が 64KiB、x86_64 が 4KiB(ADRP のページ計算は常に 4KiB)。
- 内部マージ機構(PartialLinker / RelocatableWriter)に e_machine 伝播を追加した。
- **x86_64 は実行ファイル 3/3・共有オブジェクト 2/2 でバイト一致**(挙動変更ゼロ)。
  メインセッションでも実行ファイル・.so の両方で独立に裏取りした。
- **スコープ外は明示拒否**: aarch64 の共有ライブラリリンクは `LinkError`
  「aarch64 shared objects are not yet implemented」で止める(黙って x86_64 の
  ロジックを走らせない)。
- 検証: 自作リンク経路を `aarch64_execution_helper` に追加(既存クロス gcc 経路は温存)。
  17 ケース(戻り値・putchar/puts/printf・グローバル・argc・複数 TU・float・struct 値渡しの
  実行差分 + ET_EXEC/NEEDED/JUMP_SLOT/PT_INTERP の構造検査 + .so 拒否のガード)。
- **次段(A5 第二段)に残したもの**: 共有ライブラリリンカの aarch64 対応(.so 生成、
  R_AARCH64_RELATIVE による内部再配置、遅延解決 PLT0)。これが **gem install に必要**。
  非 PIC 実行ファイルは GOT 再配置を出さないため、GOT 経路(ADR_GOT_PAGE / GLOB_DAT)は
  実装済みだが実行未到達。CompatRuntime が x86_64 コンパイル固定である潜在的穴も
  次段で解消する。

---

## Step 80 — aarch64 共有ライブラリの自作リンク(M4 A5 第二段)

前段(Step 79)で aarch64 実行ファイルを自前化した。残る .so 生成は **Ruby C 拡張
(gem install の成果物)に必須**。

- **成果: rubycc 自身のリンカで aarch64 の .so を生成し、qemu 上で dlopen・関数呼び出し
  できる**。これは C 拡張そのものの形。
- 調査で判明したのは、**SharedLinker が前段で既にほぼ完全に機種パラメータ化されていた**
  こと。実行ファイルリンカ(SharedLinker のサブクラス)を aarch64 対応させた際に、
  機種依存の判断がすべて `aarch64?` 分岐に整理されていた。ブロックしていたのは
  `supported_machines = [EM_X86_64]` の明示拒否だけで、両機種に広げるのが実変更の核心。
  x86_64 の本体ロジックには一切触れていない。
- 共有ライブラリ固有の要素(内部絶対アドレスの `R_AARCH64_RELATIVE` リベース)は
  `reloc_relative` が aarch64 で RELATIVE を返すため既存経路がそのまま機能する。
- **PLT は既存 x86_64 .so と同じく BIND_NOW + per-function スタブのみ**(PLT0 の遅延解決
  トランポリンは不要)。ローダが load 時に全 JUMP_SLOT を解決するため 4 命令スタブが
  直接 callee へ跳ぶ。遅延バインドを前提とするツールには差異になり得るが、通常の
  dlopen/依存ロードでは影響しない。
- **CompatRuntime の機種不整合を修正**(前段が指摘した潜在穴)。`archive_bytes` を
  target 別メモ化にし、aarch64 リンク時は aarch64 でコンパイルする。msgpack が要求する
  `rb_gc_guarded_ptr_val` を参照する .so で機種一致を確認。既定は x86_64 なので既存は不変。
- 検証はホストに aarch64 Ruby が無いため、構造検証(自作 ELFReader)+ qemu 上での
  実ロード・呼び出し(消費側の実行ファイルをクロス gcc でビルドし rubycc 製 .so を
  dlopen)の二層。自己完結・cross-unit(GOT 経由)・外部インポート(JUMP_SLOT/GLOB_DAT)を
  すべて実行差分で確認した。
- **x86_64 の .so は 3 ケースでバイト一致、CompatRuntime の x86_64 アーカイブも一致**。
  メインセッションでも rubycc 製 .so を qemu 上で dlopen(triple/add が正しく返る)し、
  x86_64 .so のバイト一致も独立に裏取りした。
- **gem install の見込み**: 共有ライブラリ生成の中核(PIC・動的再配置・PLT/GOT・
  動的セクション)は実ロード・実呼び出しまで検証済み。ただし `gem install msgpack` を
  aarch64 で完走させるには **qemu 上で動く aarch64 版 Ruby(mkmf/rake が動く環境)が必要**で、
  当環境には無いため gem install 全体のスモークは未検証(ホスト環境の制約。M4 受け入れの
  コンテナマトリクス整備時に対応)。

---

## Step 81 — musl 派生ヘッダのライセンスゲート(H0、ユーザ指示)

M4 完了後・M5(互換ヘッダの大量拡充)着手前の必須ゲート(ユーザ指示、2026-07-19)。
成果物は docs/HEADER-LICENSING.md。コード生成ではなくライセンス整理のステップ。

- **musl COPYRIGHT を原典で確認したことが最大の収穫**。ROADMAP の H0 論点 1 が前提に
  していた「musl は『ヘッダの大部分は著作権性が薄い』と述べている」という文言は、
  **現行の COPYRIGHT では削除済み**だった(削除された旨が明記されている)。代わりに
  musl は公開ヘッダ(`include/*`・`arch/*/bits/*`)について MIT が要求する著作権表示・
  許諾表示の**保持義務を明示的に免除**している(omit 許可)。この方が triviality 主張より
  確実な根拠なので、文書はこちらに依拠する。古い前提のまま進めていたら誤った論拠に
  なっていた。
- 同梱 30 ヘッダの**由来台帳**を作成: freestanding 8(コンパイラ提供、libc 非由来)・
  musl-derived 15・clean-room 7。監査可能な一次記録として各ヘッダ冒頭コメントと整合。
- glibc(LGPL)・カーネル UAPI(GPL)の ABI 事実(型幅・構造体レイアウト・マクロ値)は
  **実測値であり著作物のコピーではない**(17 U.S.C. §102(b))ことを整理し、glibc/UAPI 派生を
  構成しないことを明文化。R11 の「glibc 実物コピー禁止」を UAPI にも拡張して再確認。
- **是正 3 点**: (1) gemspec の spec.files に NOTICE が欠け gem 受領者に musl の謝辞が
  届いていなかった → 追加(`gem build` で data.tar.gz に NOTICE が入ることを実地確認)。
  (2) 由来分類が冒頭コメントに欠けていた errno.h / sys/stat.h に UAPI 由来(musl 非派生・
  ABI 事実)を明記。(3) NOTICE 本文を omit 許可ベースに更新し、ABI 事実の非著作権性への
  言及と HEADER-LICENSING.md への参照を追加。
- 今後のヘッダ追加ワークフロー(由来コメント必須・ABI は実測のみ・台帳更新・NOTICE 見直し・
  疑義はクリーンルーム化)を文書化。M5 の H1 以降はこの手順に従う。
- ヘッダのコメント変更が同梱ヘッダの ABI テスト(test_header_abi)を壊さないことを確認。

---

## Step 82 — aarch64 ABI 層ヘッダとヘッダ ABI ハーネスの machine 並列化(M5 H1)

M5 の最初の実装ステップ。第二バックエンド(aarch64)を実 gem まで通すには、同梱 libc
ヘッダも aarch64 の ABI を映さねばならない。x86-64 で規約化した「ABI 層ヘッダ + 実測駆動
ABI ハーネス」を aarch64 に拡張し、探索パスを target で切替可能にした。

- **差分は着手前にメインセッションで実測して確定**(過去に調査フェーズで委譲が繰り返し
  中断したため)。ホスト gcc(x86-64)とクロス gcc(aarch64-linux-gnu-gcc -static + qemu)で
  全 arch 層 Spec の型幅・マクロ値・offsetof を突き合わせた結果、**aarch64 が x86-64 と
  異なるのは正確に 4 点のみ**と判明: `nlink_t`(unsigned long→unsigned int)・`blksize_t`
  (long→int)・`WCHAR_MIN/MAX`(符号付き→unsigned)・`struct stat`(144→128 バイト・並び替え)。
  `CHAR_MIN/MAX` は既に `__CHAR_UNSIGNED__` 機構(Step 73)で吸収済み。fast 型・PRI/SCN 書式・
  struct tm/timespec/timeval・fd_set・endian・errno 番号・ctype マスク等はすべて両 arch で
  バイト一致(→ aarch64 層へは検証コピー)。この実測表を委譲プロンプトに埋め込み、
  エージェント側で再調査させずに機械的実装に徹させた。
- **`include/libc/glibc/aarch64/` を新設(全 11 本)**。探索解決のため全ヘッダを配置する
  必要がある(x86-64 層は arch 層専用で共通層に降りていないため)。8 本は x86-64 版と
  宣言・値がバイト一致(errno.h のみ provenance 1 語差)、3 本のみ実 ABI 差分を持つ:
  `sys/types.h`(nlink_t/blksize_t を 32bit)・`sys/stat.h`(aarch64 実測 128B レイアウト。
  st_mode が st_nlink の前・`__pad1`/`__pad2`/`__glibc_reserved[2]` で 128B に整合)・
  `stdint.h`(WCHAR_MIN=0/WCHAR_MAX=UINT32_MAX)。
- **設計判断: フル並列ツリー(全 11 本コピー)を採用**。共通層への引き下げ(DRY)より
  優先したのは x86-64 のバイト同一性不変条件。x86-64 層を 1 バイトも触らないため
  バイト同一性が自明に保たれる。8 本の重複は ABI 凍結ファイルで churn が事実上ゼロであり、
  将来 DRY 化するなら「バイト一致」が保証済みなので容易。
- **探索パスの target 切替**: `Preprocessor#initialize` に `libc_arch:`(既定 "x86_64")を
  追加し `@libc_arch_include_dir` を保持。`default_system_include_paths` を凍結定数返しから
  インスタンス変数からの再構築に変更(arch スロットのみ差し替え)。既定 x86-64 では旧
  `DEFAULT_SYSTEM_INCLUDE_PATHS` と要素完全一致 → 生成物バイト同一。`compiler.rb`/`driver.rb`
  は TARGETS の新 `libc_arch` キーを受け渡すのみ。
- **wchar_t typedef の符号性は既知限定事項として据え置き**(long double 幅と同じ扱い)。
  freestanding `stddef.h` と共有ガード `_RUBYCC_WCHAR_T` を使うため、stdint.h だけ符号を
  変えると include 順で不整合になる。テスト対象でありヘッダ分岐に効く `WCHAR_MIN/MAX`
  マクロ値のみ aarch64 ABI に合わせ、その旨を stdint.h コメントに明記。
- **ABI ハーネスの machine 並列化**: `run_abi_case`(x86-64)は無改変で、`run_abi_case_aarch64`
  を追加(rubycc -target aarch64 で .o 生成 → クロス gcc -static リンク → qemu 実行、オラクルは
  クロス gcc -static + qemu、stdout をバイト比較)。既存 `aarch64_execution_helper.rb` の
  ヘルパを再利用。`TestHeaderAbiAarch64`(12 ケース)は arch 依存 4(SYS_STAT/SYS_TYPES/
  STDINT/LIMITS)+ 中立 8 を回し、クロスツール不在ならクラスごとスキップ。Spec 定数は
  `TestHeaderAbi::` から共有参照(検査内容は arch 非依存・期待値は実行時にオラクルが算出)。
- **バイト同一性の独立検証**: `include/libc/glibc/x86_64/` は無変更(git status は
  `?? aarch64/` のみ)。既定 x86-64 探索パスが旧定数と `==` で一致。examples を既定
  x86-64 でコンパイルした .o の sha256 が実装前後で完全一致。x86-64 側 ABI テスト
  (TestHeaderAbi 28 ケース)は無改変 green。

---

## Step 83 — 同梱 `<fcntl.h>` の追加(M5 H2 の第一陣)

M5 H2(libc ヘッダ第一陣)の最初のヘッダ追加。B7(Step 63-64)の先行バッチ以降で
初めて同梱 libc の面を広げるステップ。

- **範囲は推測でなく実測で確定**(H2 の方針)。ホスト ruby.h(rbenv 3.4.5)を rubycc の
  hermetic モード(`RUBYCC_HERMETIC_HEADERS=1`、ホスト libc パスを外す)で `-E` した結果、
  **ruby.h の Linux/glibc #include 閉包は既存の同梱セットだけで完全解決**していた
  (1,146 行の rb_ API が展開、exit 0。negative control として未同梱の regex.h/wchar.h は
  正しく「No such file」で失敗)。つまり不足は ruby.h 側ではなく **gem 拡張の .c コードや
  mkmf conftest が直接 include するヘッダ**にある: 実測で未同梱だったのは
  signal.h / fcntl.h / poll.h / pthread.h / sys/socket.h / sys/mman.h / dlfcn.h。
  このうち ROADMAP が「実測での中心」に挙げる fcntl.h を本ステップの対象とした。
- **fcntl.h は arch 層ヘッダ**とクロス gcc 実測で判明。x86-64 と aarch64 で
  **O_DIRECT / O_DIRECTORY / O_NOFOLLOW の 3 ビット割当が入れ替わる**(O_TMPFILE は
  O_DIRECTORY 由来で自動追従)。他(O_RDONLY〜O_CLOEXEC・O_LARGEFILE/NOATIME/PATH・
  全 F_* コマンド・FD_CLOEXEC・F_RDLCK/WRLCK/UNLCK・全 AT_*・SEEK_*・struct flock=32B)は
  両 arch で完全一致。よって `include/libc/glibc/{x86_64,aarch64}/fcntl.h` の 2 本を置き、
  差分は当該 3 マクロ + provenance の一文のみ。provenance は errno.h/sys/stat.h と同じ
  clean-room UAPI 由来(asm-generic/fcntl.h + arch 別 uapi/asm/fcntl.h の ABI 事実の実測再現)。
- **ABI ハーネスに `defines:` フィールドを新設**(隠れた前提の露見)。rubycc の同梱ヘッダは
  feature-test マクロで gating せず**フラットな面を無条件露出**する設計(sys/stat.h が
  st_atim を無条件露出しているのと同じ)。一方ホスト glibc は O_DIRECT/O_LARGEFILE/
  O_NOATIME/O_PATH/O_TMPFILE を `__USE_GNU` で隠すため、`_GNU_SOURCE` 未定義のオラクルでは
  これらが undeclared になり比較できなかった。プローブの**全 #include より前**(features.h の
  `__USE_*` 解決前)に `#define` を差し込む `defines:` を Spec に追加し、FCNTL は
  `defines: ["_GNU_SOURCE"]` を指定してオラクル側にもフル surface を露出させ apples-to-apples に。
  未指定 Spec はプローブ文字列がバイト同一(既存 40 ケース無改変)。今後 poll.h/sys/socket.h/
  GNU string 拡張等でも再利用できる汎用機構。
- **実バグを 1 件発見・修正**: ヘッダ冒頭コメント中に `O_*/F_*` と書くと `*/` がコメント
  終端と解釈され gcc・rubycc 双方でコメントが途中終了する。実装者が `gcc -c` で確認し
  `O_*, F_* and AT_*` に修正。ABI ハーネス規律(目視でなく実行で検証)が機能した例。
- **検証**: fcntl の 2 ケース(x86-64 + aarch64)が green で O_DIRECT/DIRECTORY/NOFOLLOW の
  arch 差異をオラクル比較で保証。test_header_abi.rb 全体 42 ケース green(既存 40 無改変)。
  hermetic で fcntl.h が解決(exit 0)。既存 examples に fcntl.h 参照はなく x86-64 挙動不変。

---

## Step 84 — 同梱 `<poll.h>` の追加(M5 H2)

Step 83 の fcntl.h に続く H2 のヘッダ追加。実測で未同梱だった gem 拡張向けヘッダの一つ。

- **poll.h は共通層**とクロス gcc 実測で確定。struct pollfd(8B: int fd@0/short events@4/
  short revents@6)も全 POLL* 値も **x86-64/aarch64 で完全一致**(fcntl.h の O_DIRECT 系のような
  arch 差がない)。よって arch 層ではなく `include/libc/poll.h` の 1 本(stdio.h と同じ共通層)。
- provenance は clean-room UAPI 由来(asm-generic/poll.h の POLL* 値の実測再現、struct pollfd は
  POSIX 宣言)。errno.h/fcntl.h と同じ扱い。
- Step 83 で新設した ABI ハーネスの `defines:` 機構を早速再利用: rubycc は POLLRDNORM 系
  (XOPEN)・POLLREMOVE/POLLRDHUP(GNU)を無条件露出するが glibc は `__USE_XOPEN`/`__USE_GNU` で
  ゲートするため、POLL Spec に `defines: ["_GNU_SOURCE"]` を指定してオラクルにもフル surface を露出。
- 共通層ゆえ `TestHeaderAbiAarch64` では neutral layer 区分に配置(arch 依存ケース件数は不変)。
- 検証: poll の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 44 runs green、
  hermetic で poll.h 解決(exit 0)、既存 examples に poll.h 参照なし。

---

## Step 85 — 同梱 `<dlfcn.h>` の追加(M5 H2)

H2 のヘッダ追加を継続。実測で未同梱だった gem 拡張向けヘッダ(動的ロード)。

- **dlfcn.h は共通層**(RTLD_* 値が両 arch 完全一致)。`include/libc/dlfcn.h` の 1 本。
- provenance は clean-room だが **kernel UAPI ではなく glibc の動的リンク ABI**(bits/dlfcn.h)。
  RTLD_LAZY=0x1/NOW=0x2/GLOBAL=0x100/LOCAL=0/NOLOAD=0x4/DEEPBIND=0x8/NODELETE=0x1000、
  RTLD_NEXT=(void*)-1/RTLD_DEFAULT=(void*)0。dlopen/dlsym/dlclose/dlerror は POSIX 宣言で実体は
  リンク時にホスト libc から解決(dlfcn は syscall インタフェースではない)。
- POLL Spec の `defines: ["_GNU_SOURCE"]` を踏襲(RTLD_NOLOAD/DEEPBIND/NODELETE/NEXT/DEFAULT は
  glibc が `__USE_GNU` でゲート)。RTLD_NEXT/DEFAULT はポインタなので snippet 側で使用検査。
  **snippet は dl* 呼び出しを `sizeof(...)` 下に置く**(未評価=リンク参照を生まない。math.h と
  同流儀)ことで、静的リンクの aarch64 プローブが dlopen でローダを引き込むのを回避。
- サブエージェントがセッション上限に達したため、本ステップはメインセッションで直接実装。
- 検証: dlfcn の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 46 runs green、
  hermetic で dlfcn.h 解決(exit 0)、既存 examples に dlfcn.h 参照なし。

---

## Step 86 — 同梱 `<sys/mman.h>` の追加(M5 H2)

H2 のヘッダ追加を継続。実測で未同梱だった gem 拡張向けヘッダ(メモリマッピング)。

- **sys/mman.h は共通層**(PROT_/MAP_/MS_/MADV_ 値が両 arch 完全一致。x86-64/aarch64 とも
  asm-generic の割当を使う)。`include/libc/sys/mman.h` の 1 本。
- provenance は clean-room UAPI 由来(asm-generic/mman-common.h + mman.h のフラグ値・MAP_FAILED の
  実測再現)。mmap/munmap/mprotect/msync/madvise/mlock/munlock は POSIX 宣言。errno.h/fcntl.h と同扱い。
- size_t/off_t は共有ガード(`_RUBYCC_SIZE_T`/`_RUBYCC_OFF_T`)で定義。プローブが必ず include する
  stddef.h も同じ `_RUBYCC_SIZE_T` を使うため二重定義にならない。
- POLL/DLFCN と同じく `defines: ["_GNU_SOURCE"]`(MAP_* 拡張・MAP_ANON・MADV_* は glibc が
  `__USE_MISC`/`__USE_GNU` でゲート)。mmap 系は静的 libc に常在しローダを引き込まないため
  snippet は実呼び出しで可(dlfcn の sizeof 回避は不要)。
- 検証: mman の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 48 runs green、
  hermetic で sys/mman.h 解決(exit 0)、既存 examples に参照なし。

---

## Step 87 — 同梱 `<signal.h>` の追加(M5 H2)

H2 のヘッダ追加を継続。実測で未同梱だった gem 拡張向けヘッダのうち最もレイアウトが重いもの。

- **signal.h は共通層**(シグナル番号・SA_* フラグ・sigset_t/siginfo_t/struct sigaction の
  レイアウトが両 arch 完全一致)。`include/libc/signal.h` の 1 本。
- **siginfo_t(128B)と struct sigaction(152B)の union レイアウトを実測オフセットで再現**。
  クロス gcc + qemu で全 offsetof を実測し(si_pid@16/si_uid@20/si_status@24・si_addr@16・
  si_value@24・si_band@16/si_fd@24・sa_handler@0/sa_mask@8/sa_flags@136/sa_restorer@144)、
  glibc の `_sifields`/`__sigaction_handler` union をアクセサマクロ(`#define si_pid ...`・
  `#define sa_handler ...`)込みで再現。ハーネスが全 offsetof をクロス gcc と突き合わせて保証。
- SIGRTMIN/SIGRTMAX は glibc では**定数でなく関数呼び出し**(`__libc_current_sigrtmin/max()`。
  ローダが下位 RT シグナルを予約するため実行時決定)なので、extern 宣言 + 呼び出しマクロで実装。
  ハーネスは実行時にホスト/qemu 上で呼んで 34/64 を比較。
- レイアウト依存が重く union の 1 バイトずれが即失敗になるため heavy-implementer(Opus)に委譲。
- POLL/DLFCN/MMAN と同じく `defines: ["_GNU_SOURCE"]`。sigaction/kill 等は静的 libc に常在するため
  snippet は実呼び出しで可。
- 検証: signal の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 50 runs green、
  hermetic で signal.h 解決(exit 0)、既存 examples に参照なし。

---

## Step 88 — 同梱 `<sys/socket.h>` の追加(M5 H2)

H2 のヘッダ追加を継続。ネットワーク系 gem(puma 等)が使うソケット API。

- **sys/socket.h は共通層**(AF_*/SOCK_*/SO_*/MSG_* 値と全 struct レイアウトが両 arch 完全一致)。
  `include/libc/sys/socket.h` の 1 本。
- struct を実測サイズ/オフセットで再現: `struct msghdr`(56B、msg_name@0/namelen@8/iov@16/
  iovlen@24/control@32/controllen@40/flags@48)、`sockaddr`(16B)、`sockaddr_storage`(128B・
  __ss_align で align 8)、`iovec`(16B、_RUBYCC_STRUCT_IOVEC ガード)、`cmsghdr`(16B)、`linger`(8B)。
  ハーネスが全 offsetof/sizeof をクロス gcc と突き合わせて保証。
- provenance は clean-room UAPI/glibc(linux/socket.h・asm-generic/socket.h の実測再現)。
  socket/bind/connect/send/recv 等 17 の POSIX プロトタイプはホスト libc から解決。
- 型ガードは既存共有名に一致(size_t/ssize_t/socklen_t は既存ヘッダと共有、sa_family_t を新設)。
- POLL/DLFCN/MMAN/SIGNAL と同じく `defines: ["_GNU_SOURCE"]`(SOCK_CLOEXEC/NONBLOCK・MSG_NOSIGNAL・
  SO_REUSEPORT は glibc が __USE_GNU/__USE_MISC でゲート)。
- 検証: socket の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 52 runs green、
  hermetic で sys/socket.h 解決(exit 0)、既存 examples に参照なし。
- **フォローアップ**: 実ネットワーク gem はさらに `netinet/in.h`(sockaddr_in/in6・htons 等)・
  `netinet/tcp.h`・`sys/un.h` を必要とする(ソケットヘッダ群として後続で追加)。

---

## Step 89 — 同梱 `<netinet/in.h>` の追加(M5 H2)

Step 88 の sys/socket.h と対になる IPv4/IPv6 アドレス層。ネットワーク gem のソケットヘッダ群の一部。

- **netinet/in.h は共通層**(struct レイアウト・IPPROTO_*/INADDR_* 値が両 arch 完全一致)。
  `include/libc/netinet/in.h`。
- struct を実測オフセットで再現: `sockaddr_in`(16B: sin_family@0/sin_port@2/sin_addr@4/sin_zero@8)、
  `sockaddr_in6`(28B: family@0/port@2/flowinfo@4/addr@8/scope_id@24)、`in6_addr`(16B・union で
  align 4・s6_addr マクロ)。IPPROTO_IP=0/ICMP=1/TCP=6/UDP=17/IPV6=41/RAW=255、INADDR_ANY=0/
  LOOPBACK=0x7f000001/BROADCAST=NONE=0xffffffff、IN6ADDR_ANY/LOOPBACK_INIT。
- **既存 arpa/inet.h(Step 64)と共存**: in_addr_t/in_port_t/struct in_addr/socklen_t を同じ共有ガード
  (`_RUBYCC_IN_ADDR_T` 等)、sa_family_t を sys/socket.h と同じ `_RUBYCC_SA_FAMILY_T` で定義。
  htons/htonl 系は arpa/inet.h と同一シグネチャで再宣言(合法)。両方 include しても二重定義なし
  (hermetic で netinet/in.h + arpa/inet.h + sys/socket.h 併用 exit 0 を確認)。
- provenance は clean-room UAPI/glibc(linux/in.h・linux/in6.h の実測再現)。
- Spec は `also: ["sys/socket.h"]` で AF_INET を取得(既存の `also` フィールドを利用)。
- 検証: netinet の 2 ケース(x86-64 + aarch64)green、test_header_abi.rb 全体 54 runs green
  (arpa/inet.h の既存テストも無傷)、hermetic 解決、既存 examples に参照なし。

---

## Step 90 — 同梱 `<netinet/tcp.h>` + `<sys/un.h>`(M5 H2、ソケットヘッダ群の完成)

sys/socket.h(88)・netinet/in.h(89)に続き、ソケットヘッダ群を完成させる小ヘッダ 2 本。
どちらも極小で密接に関連するため 1 ステップにまとめた(Step 63 のバッチ追加と同じ扱い)。

- **netinet/tcp.h**(共通層): TCP レベルの setsockopt オプション名(TCP_NODELAY=1〜TCP_FASTOPEN=23)。
  両 arch 一致。struct tcp_info は gem が使わないため省略(オプション名のみ)。clean-room UAPI(linux/tcp.h)。
- **sys/un.h**(共通層): AF_UNIX アドレス `struct sockaddr_un`(実測 110B・align 2、
  sun_family@0/sun_path[108]@2)。両 arch 一致。sa_family_t は sys/socket.h/netinet/in.h と同じ
  `_RUBYCC_SA_FAMILY_T` ガードで共存。clean-room UAPI(linux/un.h)。
- どちらも実測値どおり。メインセッションで直接実装(極小のため)。
- 検証: tcp + un の 4 ケース(各 x86-64 + aarch64)green、test_header_abi.rb 全体 58 runs green、
  hermetic で tcp/un + sys/socket.h 併用 exit 0、既存 examples に参照なし。
- これで sys/socket.h + netinet/in.h + netinet/tcp.h + sys/un.h + arpa/inet.h のソケットヘッダ群が
  一通り揃い、TCP/UDP/UNIX ソケットを張る gem 拡張のコンパイルに必要な面が出そろった。

---

## Step 91 — 同梱 `<pthread.h>` の追加(M5 H2、census ギャップの最後)

hermetic census で判明した未同梱ヘッダ(signal/fcntl/poll/pthread/sys-socket/sys-mman/dlfcn)の最後の 1 本。

- **pthread.h は arch 層**(fcntl.h/sys-stat.h と同じ)。opaque 型のサイズが x86-64/aarch64 で異なる:
  `pthread_mutex_t` 40/48、`pthread_attr_t` 56/64、`pthread_mutexattr_t` 4/8、`pthread_condattr_t` 4/8。
  他(pthread_cond_t 48・rwlock_t 56・スカラ型・enum・初期化子・プロトタイプ)は両 arch 同一。
  `include/libc/glibc/{x86_64,aarch64}/pthread.h` の 2 本、差分は当該 4 型の `__size[N]` + provenance のみ。
- **opaque 型はサイズ/アライメントのみ実測再現**: `typedef union { char __size[N]; long/int __align; } T;`。
  glibc の内部フィールド構造は再現しない(「ABI に効く最小限だけ正確に、それ以外は不透明に」。
  sys/stat.h の予約スロットと同じ思想)。provenance は clean-room だが **glibc ABI 実測であって
  kernel UAPI ではない**旨を明記。pthread_* 関数は POSIX 宣言でホスト libc(glibc は libc に統合)から解決。
- snippet は初期化子(file-scope static)+ 全プロトタイプを **sizeof 下**に置く(dlfcn.h と同様、
  未評価=リンク参照を生まず静的 aarch64 プローブに pthread 実体を引き込まない)。
- 検証: pthread の 2 ケース(x86-64 + aarch64)green(opaque サイズがクロス gcc と一致)、
  test_header_abi.rb 全体 60 runs green、hermetic 解決(exit 0)、既存 examples に参照なし。
- **これで census 由来の未同梱ヘッダは全て埋まった**。以降のヘッダ追加は ROADMAP H3
  (コーパスの #include 集計)でデータ駆動に切り替える。

---

## Step 92 — コーパス #include 集計ツール(M5 H3 の第一要)

H2 の census 由来ヘッダギャップを埋めた後、ROADMAP どおり**ヘッダ追加をデータ駆動に切り替える**
基盤。ユーザ承認方針: **オンデマンドの dev タスク + 結果をコミット、`rake test` はネット不要のまま不変**。

- **設計**: `test/corpus/` に gems.rb(コミット済み選定リスト)・census.rb(集計)・README.md、
  `rake corpus:census`(独立 namespace、`:test` に非組込)、生成物 include-census.md(コミット対象の
  スナップショット)、test_corpus_census.rb(ネット非依存の hermetic テスト)。
- **census.rb は 2 層分離**: 純粋関数層(angle-include 抽出・同梱ヘッダ集合算出・bundled/gap 分類・
  R10 機械判定 = C++/configure 検出)は単体テスト対象。orchestration 層(`gem fetch`・tar 展開・
  レポート生成)だけがネット/FS に触れる。R11 で stdlib(Gem::Package)+ 素の Ruby で自作。
- **ネット隔離**: `rake test` のパターン `test/**/test_*.rb` は census.rb/gems.rb を拾わず、追加した
  test_corpus_census.rb のみ実行(11 runs / 0.009 秒・ネット非依存)。ネット依存は census 更新時のみ。
- **初回ベースライン(2026-07-22 実測)**: json/msgpack/bigdecimal/date/racc/redcarpet の 6 gem を全取得・
  R10 除外ゼロ。同梱ヘッダが実コーパスで使われていること(arpa/inet↔msgpack、sys/time↔date 等)も
  確認。ギャップ候補 7 本(arm_neon/cpuid/cstdbool/intrin/ieeefp/stdckdint/locale)は**全て SIMD/
  Windows/C++/have_header/ビルド時マクロのゲート下**で、glibc×rubycc の mkmf_shim ではインクルード
  されない見込み → **機械的に追加必須なヘッダは無し**。H2 の census 由来ギャップ充足が妥当だったこと、
  および推測でヘッダを増やす必要がないことをデータで裏付けた。
- **設計上の限界(記録)**: 生 grep はプラットフォーム/SIMD/C++ ゲート下のヘッダも拾う(過大計上)。
  ゲートの真偽判定は H3 スコープ外(受け入れ=初回ベースライン確定)。真の要否は H4 で、対象 gem を
  実際に rubycc + mkmf_shim でビルドした時に顕在化する。ネットワーク gem(puma/pg 等)は初期 6 gem に
  含まないため socket/signal 系の使用は本ベースラインには現れない(コーパス拡張で被覆)。

---

## Step 93 — `extern T name[];`(不完全配列の外部宣言)を受理(M5 H4、コーパス駆動の最初の修正)

**H4 ループが設計どおり機能した最初の例**。Step 92 の census で選んだ bigdecimal を実際に rubycc で
ビルド(`RUBYCC=1 gem install bigdecimal`、既存の mkmf_shim 機構)した結果、具体的な言語バグを検出:
`ruby/util.h` の `RUBY_EXTERN const signed char ruby_digit36_to_number_table[];` で
`array size missing` エラー。

- **バグ**: `extern T name[];`(サイズ省略=不完全配列型の外部宣言)を rubycc が誤って拒否。
  正当な C(C11 6.7.6.2p1/6.9.2:extern は定義でない宣言なので不完全型として合法。gcc は受理)。
- **切り分け**: サイズ付き extern 配列 + 添字は既に通る(生成器の `declare_extern_global` は extern 配列を
  扱える)ので、欠陥はパーサ 2 箇所(file/block scope の `array size missing` チェック)+ 生成器 1 箇所
  (`require_complete` が extern 不完全配列も拒否)に閉じていた。
- **修正**: `extern` かつ不完全**配列**のときのみ許可。parser は `spec_info.storage != :extern` を条件に追加、
  generator は `extern_incomplete_array?` ヘルパで `require_complete` をスキップし不完全配列型のまま
  `declare_extern_global` に渡す(記憶域なし、要素型のみで decay/添字が成立)。**スコープを厳密に限定**:
  file-scope 暫定定義配列(`T a[];`、[1] 完成は未実装)・block-scope 非 extern 不完全配列・extern の不完全
  struct/enum は**従来どおり診断エラー**(gcc と一致 or 意図的な既知制限)。
- **検証**: 2 TU gcc 差分の実行オラクル(定義 TU + extern 使用 TU をリンク・実行、gcc と exit/stdout 一致。
  gcc 定義 × rubycc 使用の混在リンクも一致)+ 否定テスト(block-scope 非 extern・不完全配列への sizeof が
  CompileError)。新規 `test/test_extern_incomplete_array.rb`(4 runs)+ 広範な回帰(parser 296・
  diagnostics 216・c-suite 221 等)無改変 green。
- **H4 の実データ**: この修正で bigdecimal は当該エラーを突破し、次は `bits.h` の
  「128 ビット整数の値渡し未対応」(§3 の既知負債)に到達。**bigdecimal が `__int128` の値渡しを使うことが
  実測で確認**され、当該負債の corpus 実害が顕在化した(§3 に記録)。bigdecimal のフルビルドは 128 ビット
  値渡しの実装(より大きな ABI 作業)を要するため後続 H4 ステップ。

---

## Step 94 — `__int128` の値渡し・値返し(M5 H4、bigdecimal ブロッカーの解消 + 16 バイト整列 ABI)

Step 93 で bigdecimal のブロッカーとして顕在化した「128 ビット整数の値渡し未対応」を解消。
rubycc は既に `__int128` を **16 バイトのメモリオブジェクト**(小構造体と同じ表現、Step 28 の
`new_int128_temp`)で持つため、値渡し/返しは **16 バイト 2-INTEGER eightbyte 集約**として
既存の構造体 ABI 経路に載せるのが素直な設計。`#aggregate_by_value?`(`struct? || wide128?`)を
導入し、`setup_parameters`・`struct_return_plumbing`・引数ロワリングの分類地点を全てこれに置換。
generator.rb の「128-bit by value は未対応」診断 2 件を撤去。

- **ABI 実測(measure-first)**: x86_64 System V は 2 連続 GP レジスタ(偶奇不問、rdi:rsi 等、
  返りは rax:rdx)。AAPCS64 は **16 バイト整列集約の偶数レジスタペア規則**(奇数個の整数レジスタの後は
  x2:x3 等の偶数ペアに載り、間の 1 本をパディング)。**スタック溢れ時の 16 バイト境界整列は両規約共通**
  (奇数 eightbyte 境界なら 1 スロット詰めて 16 バイト境界へ)。gcc のアセンブリ(`push`/`sub rsp` 列)で
  x86_64 のスタック pad も確認。
- **設計上の要点 — pad スロット機構**: 偶数ペア/16 バイト境界整列は placer が決めるが、従来
  バックエンドは kind 列を順送りで配るだけでパディングを尊重していなかった(**AAPCS64 偶数ペアは
  even_gp フラグが placer にあったのにバックエンド未配線=潜在バグ**。16 バイト整列集約の struct も
  同根)。これを **pad をひとつの ABI ピースとして表現**して橋渡し:placer が `pad_gp`(レジスタ 1 本、
  AAPCS64 のみ)/`pad_stack`(スタック 1 eightbyte、両規約)を報告 → `placed_pieces` が
  `:pad`/`:pad_stack` ピースを集約の先頭に前置 → フラット化した kind 列がそれを運び、バックエンドは
  pad 上でカウンタだけ進めてデータは動かさない。集約の再構成/分解(`bind_struct_parameter`・
  `lower_struct_argument`)は pad をスキップ。`va_start` の `named_gp`/`named_stack` も pad を計上。
- **命名の是正**: `even_gp` は AAPCS64 のレジスタ規則しか表さず、スタック整列は両規約共通なので
  実体は「16 バイト整列集約」。`align16` に改称し、両規約の `aggregate_plan` が `type.alignment >= 16`
  から設定。placer に NSAA(スタックオフセット)追跡を追加し、`ArgumentRequest#mem_eightbytes`
  (溢れ時の eightbyte 数)で正確に前進。
- **副次的解消**: この 1 変更で(1)128 ビット値渡し/返し、(2)スタック引数 16 バイト整列負債
  (x86_64/aarch64 共通、§3)、(3)AAPCS64 偶数レジスタペアのバックエンド未配線、が同時に解消。
- **検証(SEGV 直結のため必須)**: 新規 `test/test_int128_abi.rb`。**クロス TU 実行オラクル**:
  単一コンパイラビルドでは placement バグが自己整合で隠れる(rubycc 同士は互いに一致してしまう)ため、
  caller と callee を別翻訳単位にして rubycc↔gcc を混在させ、x86_64(host gcc)と
  aarch64(cross gcc + qemu)双方で全組合せが all-gcc と一致することを確認。ケースは
  レジスタ偶数ペア(1 本/3 本の long の後)・スタック境界整列(8 本=整列済/9 本=要 pad)・
  2 連続 int128・値返しを網羅。値は union で 2 分割し 128 ビット演算(未実装)に依存しない。
  aarch64 のクロス TU 検証のため support ヘルパに `link_units_and_run_aarch64` を追加。
- **未対応のまま**: 128 ビット整数の除算・シフト・ビット演算・可変長引数渡し(§3 の H4)。
  bigdecimal は値渡しを突破した先でこれらに到達する可能性があり、以降の H4 反復で対応。

---

## Step 95 — `__int128` のシフト `<<` / `>>`(M5 H4、bigdecimal のコンパイル通過)

Step 94 の直後に bigdecimal が到達した次のブロッカー(`bits.h` の `nlz_int128` が
`uint64_t y = (uint64_t)(x >> 64);` を使う)を解消。これで `bigdecimal.c` は rubycc で
コンパイル通過する。

- **二重ワードシフトとして合成**: 128 ビット値は 16 バイトオブジェクト(lo が +0、hi が +8)
  なので、64 ビット半分ずつのシフトを組み合わせる。要点は**どの 64 ビット半分も 64 以上
  シフトしてはならない**こと — x86_64 も aarch64 もシフト量をワード幅で剰余するため、
  `lo >> 64` は `lo >> 0` になってしまい黙って誤った値を返す。そこでカウント c を 3 範囲に分ける:
  - `c == 0` — 値をそのまま通す(この分岐が無いと下の式で `64 - c` が 64 になり破綻する)
  - `1 <= c <= 63` — 各半分を c シフトし、境界をまたぐ `bm = 64 - c` ビットを他方へ繰り上げる
  - `64 <= c <= 127` — 一方の半分は空(または符号埋め)になり、`c - 64` シフトした他方だけが結果を供給
- **符号の扱い**: 符号付き `>>` のみ上位半分を算術シフト(`:sar`)し、64 以上のカウントでは
  上位を符号ビットで埋める(`int128_high_fill` を再利用)。下位半分の右シフトは符号付きでも
  常に論理シフト(下位ビットなので)。`<<` は符号を問わない。
- **踏んだバグ(記録)**: 繰り上がりビットの合成に既存の `int128_bool_or` を流用したところ、
  両ターゲットで同じ誤りが出た。同ヘルパは比較結果の 0/1 用で `size:` を渡さない=**32 ビット幅**の
  `:or` を出すため、64 ビット半分の合成に使うと上位 32 ビットが切り捨てられる。
  症状は「繰り上がりを受け取る側の半分だけが下位 32 ビットに化ける」。64 ビット二項演算を
  `int128_op64`(`size: 8`)に統一して解消。**両アーチで同一の誤りが出たことが、
  バックエンドではなく共有ジェネレータの欠陥だと即座に切り分ける手がかりになった**。
- **検証**: gcc 差分の実行オラクル。x86_64(test_execution_harness.rb)は
  counts 0/1/63/64/65/96/127 × {`<<`, 論理 `>>`, 算術 `>>`(負値)} と定数
  `>>64`/`<<64`/`>>32`/`<<100` を網羅し、各結果を上下 8 バイトに分けて **128 ビット全体**を比較。
  aarch64(test_aarch64_execution.rb)も同等ケースを qemu 実走で比較。いずれも半分の取り出しは
  union 経由で、**抽出自体にシフトを使わない**(被検査機能で被検査機能を測らない)。
- **次のブロッカー**: `missing/dtoa.c:656` の `hi0bits(register ULong x)` —
  パラメータの `register` を rubycc が拒否する(C11 6.7.6.3 ではパラメータに限り合法)。Step 96 へ。

---

## Step 96 — パラメータの `register` を受理(M5 H4)

Step 95 の直後に bigdecimal が到達したブロッカー(`missing/dtoa.c:656` の
`hi0bits(register ULong x)`)を解消。

- **バグ**: C11 6.7.6.3p2 は「パラメータ宣言に現れてよい記憶域クラス指定子は `register` **だけ**」と
  定めるが、rubycc はパラメータの specifier 解析を `allow_storage_class: false` で呼んでおり、
  記憶域クラスを一律に拒否していた。`register` は K&R 由来の古いコードに広く残るため、
  実コーパスでは早期に踏む。
- **修正の勘所は「緩めすぎないこと」**: `allow_storage_class` を真にすると
  typedef/static/extern/auto まで通ってしまう。そこで `allow_register:` を独立の
  スイッチとして追加し、パラメータ宣言からのみ真で呼ぶ。通すのは `register` 1 語だけで、
  他の 4 語はパラメータでも従来どおり診断エラー。`register` 自体は既存の扱い
  (消費して無視、後段に何も残さない)のままなので、コード生成には一切影響しない。
- **スコープの限定**: メンバ宣言(`struct s { register int x; }`)と型名
  (`sizeof(register int)`)での `register` は `allow_register` が既定の偽なので
  引き続き拒否。C 標準どおり。
- **検証**: gcc 差分の実行オラクルで、`register` パラメータが通常のパラメータと同じく
  読み書き・シフト/ビット演算・他関数への受け渡しに耐えることを確認(dtoa.c の hi0bits 形と、
  本体中の `register` ローカルを含む)。否定テストは「パラメータでの register 以外」と
  「パラメータ以外での register」の 2 方向に整理。
- **次のブロッカー**: 同じ `missing/dtoa.c:1373` の静的初期化子
  `9007199254740992.*9007199254740992.e-256`(dtoa の `tinytens[]` 表)—
  **浮動小数点の定数式が静的初期化子で畳み込まれない**(`initializer element is not a constant`)。Step 97 へ。

---

## Step 97 — 静的初期化子の浮動小数点定数式(M5 H4、**bigdecimal フルビルド達成**)

bigdecimal の最後のブロッカー(`missing/dtoa.c:1373` の `tinytens[]` 表
`9007199254740992.*9007199254740992.e-256`)を解消。**これで bigdecimal は
rubycc でフルビルドが通り、gem 本体のテストスイートにも全合格した**(下記)。

- **バグ**: 静的初期化子の浮動小数点「定数式」(リテラル単体ではなく演算)が畳み込まれず、
  `fold_global_float` が Binary を整数定数評価器へ丸投げして
  `initializer element is not a constant` になっていた。
- **修正**: `fold_global_float` に Binary の枝を足し、`+ - * /` を浮動小数点で畳む。
- **設計上の肝は「整数定数式を浮動で畳まないこと」**: C の通常の算術変換では、
  どちらの被演算子も浮動でなければその式は**整数**定数式であり、変換前に整数の意味論を
  保たねばならない — `double d = 7/2;` は **3.0** であって 3.5 ではない。素朴に
  「double の初期化子だから浮動で畳む」と実装すると、この 1 行が静かに壊れる。
  そこで `floating_constant?` を「浮動*定数式*か」を判定する再帰述語へ拡張し
  (FloatLit / 単項マイナス / 算術二項のいずれかの辺が浮動)、真のときだけ浮動で畳み、
  偽なら従来どおり整数評価器へ委譲する。この述語は整数グローバルが
  「切り捨てを伴う浮動初期化子」を見分けるのにも使われるため、両者で一貫する。
- **既知の制限(範囲外・従来から同じ)**: 整数グローバルの初期化子に浮動定数式を書く形
  (`int gi = 3.75 * 4;`)はパーサが先に整数定数評価器で畳むため依然拒否される
  (`int gi = 1.5;` も本ステップ以前から同様に拒否)。定数評価器は「Float を見ない」
  整数専用の不変条件を意図的に持つ設計なので、その拡張は別ステップ。本ステップは
  浮動グローバル/配列側のみを直し、退行が無いことを修正前後の比較で確認済み。
- **検証**: gcc 差分の実行オラクル。dtoa の tinytens 形を含む double/float の定数式を
  `%.17g` で厳密比較(丸めた表示では差が隠れるため)。あわせて整数定数式の意味論
  (`7/2` が 3.0、`-9/4` が -2.0)が保たれることを同じテストで固定した。

### bigdecimal フルビルドと gem テストスイート全合格(H4 の受け入れ達成)

Step 93〜97 の 5 ステップで bigdecimal のブロッカーを順に潰した結果:

| Step | ブロッカー | 内容 |
|---|---|---|
| 93 | `ruby/util.h` | `extern T name[];`(不完全配列の外部宣言)の拒否 |
| 94 | `bits.h` | `__int128` の値渡し |
| 95 | `bits.h` | `__int128` のシフト `x >> 64` |
| 96 | `missing/dtoa.c:656` | パラメータの `register` |
| 97 | `missing/dtoa.c:1373` | 静的初期化子の浮動小数点定数式 |

`RUBYCC=1 gem install bigdecimal` が成功(rmake が MAKE、mkmf.log の CC が rubycc であることを確認、
`lib/bigdecimal.so` を生成)。さらに上流ソースの**テストスイートを rubycc ビルドの `.so` に対して実走 →
265 tests / 8,267 assertions / 0 failures / 0 errors**(11 件は `BIGDECIMAL_USE_VP_TEST_METHODS`
未設定による正常な omission)。**「ビルドが通る」だけでなく「gem 本体のテストが通る」水準で
C 拡張の動作を確認した 2 例目**(1 例目は json: 606 tests / 3,433 assertions / 0 failures)。

---

## Step 98 — redcarpet を通す4修正(M5 H4、**redcarpet フルビルド + テスト全合格**)

コーパス次点の redcarpet 3.6.1 を `RUBYCC=1 gem install` に掛け、順に現れた4つの
ブロッカー(ヘッダ2件・コンパイラ挙動2件)を解消。**redcarpet は rubycc でフルビルドが
通り、上流テストスイート(test/unit)にも全合格した**(下記)。いずれも既存の負債表・
コーパス census が予告していた項目で、実 gem のビルドが実物の証拠を与えた。

- **① `<string.h>` が `<strings.h>` を引き込む**(autolink.c の `strncasecmp`)。
  glibc の `<string.h>` は `__USE_MISC`(既定の GNU 環境)下で `<strings.h>` を include
  するため、`<string.h>` だけで `strcasecmp`/`strncasecmp` が見える。同梱ヘッダは
  feature-test マクロで glibc 拡張を出し分けない方針(`strdup`/`mempcpy` 等も無条件)なので、
  末尾で無条件に `#include <strings.h>` する。重複する `memchr` の宣言は同一で互換な再宣言。
- **② `<ctype.h>` に `isascii`/`toascii`**(html.c の `isascii`)。glibc は
  `__USE_MISC || __USE_XOPEN` 下でこれらを宣言する。両者は locale 分類表を使わない純粋な
  ビット判定(`(c) & ~0x7f`、`(c) & 0x7f`)なので、`isalpha` 系のような ABI 値の機微は無く、
  インライン値が glibc の out-of-line 値と厳密一致する。x86_64/aarch64 双方の同梱に追加。
- **③ 関数ポインタ配列の推論サイズ `[]`**(html_smartypants.c の `smartypants_cb_ptrs`)。
  `static int (*fp[])(int) = { ... };` のように括弧付き宣言子の内側に空 `[]` を書く形で、
  `parse_declarator_core` が括弧内の宣言子へ再帰する際 `allow_incomplete_array: false` を
  ハードコードしていたため拒否していた。括弧は単なるグルーピングで、その配列はオブジェクト
  自身の配列だから初期化子から寸法を推論できる(素の `int fp[] = {...}` と同じ、6.7.6.3)。
  `allow_incomplete_array` を再帰へ伝播。初期化子なしのローカル(`int (*fp[])(void);`)は
  従来どおりフラグが false なので `array size missing` を維持。
- **④ ポインタ指し先の符号性差の受理**(strncmp に `uint8_t*` を渡す)。gcc の
  `-Wpointer-sign`(警告どまりで受理)相当。同サイズ・逆符号の整数指し先は同じ寸法・整列の
  オブジェクトを指すため再解釈は無害。加えて 1 バイト文字型3種(`char`/`signed char`/
  `unsigned char`)は相互に互換とし、**Step 73 が開いた `char*`/`signed char*` 非互換化の
  負債(§3)も併せて解消**。同サイズでも文字族以外の別型(この型モデルでは該当が稀)や
  異サイズ(`int*`/`char*`・`int*`/`long*`)は従来どおり硬いエラーで、gcc の warn-and-accept
  より厳格を維持。`convert_for_assignment` はポインタ間で no-op なので受理側の追加のみ。
- **検証**: ①② は header-abi ハーネス(gcc+システムヘッダ vs rubycc+同梱ヘッダのバイト一致)で
  `strcasecmp`/`strncasecmp`/`isascii`/`toascii` を追加。③④ は gcc 差分の実行オラクル
  (関数ポインタ配列の dispatch と sizeof、符号性ミスマッチのバイト比較・カウント)を
  x86_64 に、③ は aarch64 実行オラクルにも追加。

### redcarpet フルビルドと gem テストスイート全合格(H4 の受け入れ達成 3 例目)

`RUBYCC=1 gem install redcarpet` が成功(rmake が MAKE、gem_make.out の CC が rubycc)。
上流ソース v3.6.1 の test/unit スイートを rubycc ビルドの `.so` に対して実走 →
**136 tests / 206 assertions / 0 failures / 0 errors / 0 skips**。あわせて次点の
**msgpack 1.8.3 はコンパイラ無改修でフルビルド + MRI spec 全合格**(468 examples 中、
失敗は JRuby 専用 `spec/jruby/` の 13 件のみ = MRI 対象は全パス、pending 1)を確認。

これで gem 本体テストまで通した C 拡張は **json / bigdecimal / redcarpet / msgpack の 4 例**。

---

## Step 99 — 多次元配列(M5 H4、date のブロッカー、racc テスト全合格)

コーパス最後の date 3.5.1 を `RUBYCC=1 gem install` に掛け、最初のブロッカー
`static const int monthtab[2][13]`(date_core.c:697)= **多次元配列**を実装。
配列の要素が別の配列である型(`int a[2][13]` = `int[13]` の 2 要素配列)を全面的に対応。

- **型モデルは既に対応済み**: `Type::Array(element:, length:)` の element は元から任意の型を
  取れ、`size`(element.size × length)・`alignment`・`incomplete?` は再帰的に正しい。
  多次元は「要素が配列の配列」を組み立てるだけ。
- **パーサ**: `apply_declarator_suffix` の「配列の要素は配列不可」ガードを撤去。宣言子接尾辞は
  内側から適用される(`parse_direct_declarator` の `reverse_each`)ため、`int a[2][13]` は
  内側 `[13]` が完全配列になってから外側 `[2]` が包む。**内側次元だけは不完全不可**
  (`int a[2][]` は要素型 `int[]` のストライド不明 = エラー)、最外次元は `[]` 可
  (初期化子から推論、またはパラメータで調整)。ガードを
  `error if inner.array? && inner.incomplete?` に置換。
- **添字と減衰**: `a[i]`(多次元の行)は配列でありロードせず、その先頭要素へのポインタに
  減衰する — `gen_subscript` に array 分岐を追加し、`Type::Pointer.new(element.element)` を返す
  (配列変数・配列メンバの減衰と同型)。`static_type` の Subscript 枝も、入れ子添字のために
  対象を `decay` してから `subscript_element_type` に渡すよう修正。
- **既存機構が自然に効いた箇所**(追加コードなしで gcc 一致を確認):入れ子ブレース初期化子、
  最外次元の初期化子からの推論(`int a[][3] = {...}`)、2 次元配列パラメータの
  `int(*)[3]` への調整、行を `int*` として渡す、配列へのポインタ `int(*)[3]`、
  `&a[i][j]` とその書き込み、各配列の `sizeof`、3 次元配列。
- **検証**: gcc 差分実行オラクル(静的 const 2D グローバル + 3D グローバル + ローカル 2D +
  2D パラメータ + 行渡し + 配列ポインタ + アドレス取得書き込み + 各 sizeof)を x86_64 に、
  同種を aarch64 実行オラクルにも追加。負のケース(`int a[2][]` 拒否、型の入れ子形状)も固定。

### racc の受け入れ完了(テスト全合格 5 例目)+ date の次ブロッカー

- **racc 1.8.1 はコンパイラ無改修で通過**: `RUBYCC=1 gem install racc` で cparse.so を rubycc が
  ビルド(gem_make.out の CC が rubycc、`Racc_Runtime_Type = c` で C ランタイム稼働を確認)。
  上流 v1.8.1 の test/unit スイートを実走 → **71 tests / 319 assertions / 0 failures / 0 errors**
  (生成ファイル `lib/racc/parser-text.rb` は rmake ビルド生成物から補完)。テスト全合格 5 例目。
- これで **コーパス 6 gem 中 5 gem がテスト全合格**(json / bigdecimal / redcarpet / msgpack / racc)。
- **date の次ブロッカー(Step 100 予定)**: 多次元配列突破後、`date_core.c:8735` の
  `char fmt[sizeof(timefmt) + sizeof(zone) + ...]` = **配列境界の定数式に含まれる
  `sizeof(式)`** に到達。パーサは配列境界を構文解析時に畳むが、`sizeof(変数)` は変数の型が要る
  一方でパーサの通常名スコープは型を保持しない(typedef 名のみ型を持つ)ため未解決。別ステップ。

---

## Step 100 — 配列境界の定数式に含まれる `sizeof(式)`(M5 H4、date のブロッカー)

date の次ブロッカー `char fmt[sizeof(timefmt) + sizeof(zone) + rb_strlen_lit(".%N") + ...]`
(date_core.c:8735)を解消。配列境界の定数式に `sizeof(式)` が含まれる場合を構文解析時に畳む。

- **背景**: パーサは配列境界を構文解析時に `ConstantEvaluator` で畳む。`ConstantEvaluator` は
  `sizeof(型名)` は畳めるが、`sizeof(式)` は式の型が要る一方で自身は型表を持たない。従来は
  境界内の `sizeof(式)` を一律「定数でない」として拒否していた(グローバル初期化子側は既に
  `references_sizeof_expr?` で生成器へ委譲する設計があったが、境界は畳みを遅延できない —
  境界は型の一部なので即値が要る)。
- **修正**: パーサの通常名スコープ(`OrdinaryName`)に**変数の型を保持**するよう変更
  (従来は typedef 名を隠すためだけの空ペイロード)。`declare_ordinary_name(name, type)` に型を渡す
  5 箇所を更新。境界畳み込みに `sizeof_expr` リゾルバ(`fold_time_sizeof`)を渡し、
  `sizeof(式)` の式の型を `sizeof_operand_type` で推論する。
- **対応する式の形**(実際の配列境界が使う範囲に限定): 名前付きオブジェクト(スコープの型)、
  文字列リテラル(char[N+1])、添字 `a[i]`・間接参照 `*p`(基底を減衰して要素/指し先型)、
  キャスト。**ruby.h の `rb_strlen_lit`** = `(sizeof(s "") / sizeof(s ""[0]) - 1)` は
  文字列リテラルとその要素の両方を要求するため、添字-of-文字列リテラルの対応が要だった。
  `sizeof` は直接の被演算子を減衰しない(6.5.3.4)ので配列は丸ごと測る。型が推論できない形・
  不完全/void/関数型は従来どおり非定数(境界は「整数定数でない」と診断)。
- **保守的なギャップ**(範囲外・意図的): `sizeof(x + 0)` のような算術式の被演算子は未対応
  (gcc は受理、rubycc は拒否)。配列境界では稀で、必要になれば拡張可能。受理側のみ追加のため退行なし。
- **検証**: gcc 差分実行オラクル(sizeof(変数配列)・sizeof(文字列)・sizeof(文字列[0]) を
  グローバル境界とローカル境界の両方で使用)。パーサ単体テストで畳んだ長さを固定。VLA・
  不完全 extern 配列の sizeof は従来どおり拒否されることも確認。
- **date の次ブロッカー(Step 101 予定)**: 静的初期化子の関数ポインタキャスト
  `(VALUE (*)(void *))m_real_year`(date_core.c:7159、関数ポインタの vtable 風 struct)。
  関数名を関数ポインタ型へキャストしたアドレス定数の畳み込みが必要。別ステップ。

---

## Step 101 — 静的初期化子の関数ポインタキャスト(M5 H4、date のブロッカー)

date の次ブロッカー `static const struct tmx_funcs tmx_funcs = { (VALUE (*)(void *))m_real_year, ... }`
(date_core.c:7159、関数ポインタの vtable 風 struct)を解消。関数名を別の関数ポインタ型へ
キャストしたものを静的初期化子のアドレス定数として畳む。

- **背景**: 静的ポインタ初期化子のうち、素の関数名 `f` / `&f` は既に
  `function_address_constant`(シグネチャ一致検査つき)で対応済み。だが date は
  `(VALUE (*)(void *))m_real_year` のように**関数名をキャストで別の関数ポインタ型に
  再解釈**する。この形は `fold_address_constant` → `pointer_value(Cast)` →
  `object_address(VariableRef)` に落ちるが、`object_address` はグローバル**変数**
  (`@global_bindings`)しか知らず、関数(`@signatures`)を扱えなかった → 「unsupported initializer」。
- **修正**:
  - `object_address` の VariableRef 枝に関数指示子の対応を追加。グローバル変数が束縛しない名前でも
    `@signatures` にあれば、その**関数シンボル自体**をアドレスとする AddressConstant
    (base_kind :symbol、pointee = 関数型)を返す。**明示キャストは自由に型を再解釈できる**ので
    シグネチャ検査はしない(素の名前の既存経路のみ検査を保つ)。
  - `pointer_value` の減衰枝で、配列だけでなく**関数指示子**も減衰対象に。関数指示子は関数への
    ポインタに減衰し(アドレスがそのままポインタ値)、pointee は関数型のまま返す。
  - これで Cast 経路 `inner.with(pointee: node.type.target)` がキャスト先の関数ポインタ型に
    正しく再解釈し、データ節へは関数シンボルへの :symbol 再配置が出る。
- **検証**: gcc 差分実行オラクル(関数ポインタの struct とその配列を、実シグネチャと異なる
  キャストで初期化し、再解釈したポインタ越しに呼ぶ)。素の名前・`&f`・キャスト配列も同時に確認。
  address-constant globals の既存テストが緑のままであることも確認(object_address の他の呼び出しに影響なし)。
- **date の次ブロッカー(Step 102 予定)**: `date_core.c` はフルコンパイル達成。
  次は `date_parse.c` の `zonetab.h:32` の **`#line` プリプロセッサ指令**(6.10.4)が未対応。別ステップ。

---

## Step 102 — `#line` プリプロセッサ指令(M5 H4、date のブロッカー)

date の `date_parse.c` が include する gperf 生成ヘッダ `zonetab.h` の `#line 1 "zonetab.list"`
(zonetab.h:32)を解消。`#line`(C11 6.10.4)を実装。従来は未認識ディレクティブとして診断エラーだった。

- **仕様**: `#line` の引数をまずマクロ展開し(6.10.4p5)、「桁列 + 任意の文字列リテラル」として読む。
  **次の行**の推定行番号をその値に、文字列があれば推定ファイル名を設定する(無ければ維持)。
  物理トークンの位置は動かさず、推定だけが変わる。
- **`__LINE__`/`__FILE__` への反映**: 推定行差分 `@presumed_line_delta`(物理行に加算)と推定ファイル名
  `@presumed_file`(トークン自身のファイル名を上書き)を持ち、`expand_builtin` で `__LINE__`/`__FILE__` に
  適用。#line が走るまでは恒等(従来どおり物理値)。
- **#include をまたぐ扱い**: 推定はファイル単位(6.10.4)。`process_include` で推定状態を保存し、
  includee は素の行/ファイル番号で開始、include から戻ると includer の推定が復帰する。
- **検証**: プリプロセッサ単体テスト5件(行/ファイル設定、ファイル名省略時の維持、引数のマクロ展開、
  #include をまたいで漏れないこと、非数値引数の拒否)+ gcc 差分実行オラクル(`#line N "virtual.c"` で
  __FILE__ を決定的にし、__LINE__/__FILE__ が gcc と一致)。C11-COVERAGE.md の 6.10.4 を実装済みに更新。
- **date の次ブロッカー(Step 103 予定)**: `date_core.c` はフルコンパイル済み、`date_parse.c` の
  `zonetab.h:814` の **手書き offsetof イディオム** `(int)(size_t)&((struct stringpool_t *)0)->member`
  が静的初期化子で「initializer element is not a constant」。null ポインタ基点のメンバアドレスを
  整数オフセット定数へ畳む対応が必要。別ステップ。

---

## Step 103 — 静的初期化子の手書き offsetof イディオム(M5 H4、date のブロッカー)

date の `date_parse.c` が include する gperf 生成 `zonetab.h:814` の
`(int)(size_t)&((struct stringpool_t *)0)->stringpool_str2`(手書き offsetof)を解消。
null ポインタ基点のメンバアドレスを整数オフセット定数へ畳む。

- **背景**: この式は `&((T*)0)->member`(メンバアドレス)を `(size_t)` で整数化し `(int)` する。
  ジェネレータのアドレス定数畳み込み(`pointer_value`/`member_address`)は
  `&((T*)0)->member` を **絶対アドレス定数**(base=null=0 + メンバオフセット = base_kind :absolute、
  offset = メンバオフセット)に畳める。だが整数初期化子を畳む `ConstantEvaluator` は
  `&`/`->` を扱えず、ポインタ→整数キャストの被演算子で NotConstant になっていた。
- **修正**:
  - `ConstantEvaluator` に `pointer_int` リゾルバのフック追加(既存の `sizeof_expr` と同型)。
    整数へのキャストの被演算子が整数定数として畳めないとき、リゾルバに委ねる。
  - ジェネレータが `address_int_resolver` を供給:被演算子を `pointer_value` で畳み、
    **base_kind が :absolute のときだけ** その offset(= オフセット値)を返す。シンボル相対
    (`(int)&global`)はリンク時再配置で定数でないため NotConstant(gcc も拒否)。
  - スカラー整数グローバルも対応: パーサは整数スカラー初期化子を構文解析時に畳むため、
    `references_address_of?` を追加し、アドレス取得を含む初期化子は(sizeof(式)同様)
    ジェネレータへ畳みを委譲する。構造体配列(date の形)は元から構造化初期化子として
    ジェネレータの `fold_global_constant` に届くので、フック追加だけで通る。
- **検証**: gcc 差分実行オラクル(構造体配列と スカラーの両方で `&((S*)0)->m` の各オフセットが
  gcc と一致)。シンボル相対 `(int)&global` が両者で拒否されることも確認。
- **date の次ブロッカー(Step 104 予定)**: `date_parse.c` までコンパイル済み、`date_strftime.c:214`
  の **`strlcpy` の暗黙宣言**。同梱 `<string.h>` に `strlcpy`/`strlcat`(BSD、glibc 2.38+、
  ホスト libc は提供)の宣言を追加すればよい。別ステップ。

---

## Step 104 — `<string.h>` に `strlcpy`/`strlcat`(M5 H4、**date フルビルド + テスト全合格**)

date の最後のブロッカー `date_strftime.c:214` の `strlcpy` 暗黙宣言を解消。同梱 `<string.h>` に
BSD の size 制限コピー `strlcpy`/`strlcat`(glibc 2.38+、ホスト libc が提供)の宣言を追加。
`strdup`/`mempcpy`/`strlcpy` 等の glibc 拡張を無条件に出す既存方針に沿う。

- **修正**: `size_t strlcpy(char *restrict, const char *restrict, size_t);` と `strlcat` を追加。
- **検証**: header-abi ハーネスの STRING snippet に `strlcpy`/`strlcat` 呼び出しを追加
  (gcc+システムヘッダ vs rubycc+同梱ヘッダの両方でコンパイル)。実 gem のフルビルドが最終検証。

### date フルビルドと gem テストスイート全合格(H4 の受け入れ達成 6 例目、**コーパス完走**)

Step 99〜104 の 6 ステップで date のブロッカーを順に潰した結果:

| Step | ブロッカー | 内容 |
|---|---|---|
| 99  | `date_core.c:697` | 多次元配列 `monthtab[2][13]` |
| 100 | `date_core.c:8735` | 配列境界の `sizeof(式)` |
| 101 | `date_core.c:7159` | 静的初期化子の関数ポインタキャスト |
| 102 | `zonetab.h:32` | `#line` プリプロセッサ指令 |
| 103 | `zonetab.h:814` | 手書き offsetof イディオム |
| 104 | `date_strftime.c:214` | `strlcpy` の宣言 |

`RUBYCC=1 gem install date` が成功(rmake が MAKE、gem_make.out の CC が rubycc、`lib/date_core.so` を生成)。
上流ソース v3.5.1 の test/unit スイート(ruby-core の test/lib/helper.rb + test-unit-ruby-core を
load path に補完)を rubycc ビルドの `.so` に対して実走 →
**143 tests / 162,593 assertions / 0 failures / 0 errors / 0 skips**。

**これで M5 コーパス 6 gem すべてがフルビルド + gem 本体テスト全合格に到達**:

| gem | テスト結果 | 要した実装 |
|---|---|---|
| json 2.21.1 | 606 tests / 3,433 assertions / 0 failures | 既存(M2 まで) |
| bigdecimal 4.1.2 | 265 tests / 8,267 assertions / 0 failures | Step 93〜97 |
| redcarpet 3.6.1 | 136 tests / 206 assertions / 0 failures | Step 98 |
| msgpack 1.8.3 | 468 examples(MRI 全パス、JRuby 専用13除く)| 無改修 |
| racc 1.8.1 | 71 tests / 319 assertions / 0 failures | 無改修 |
| date 3.5.1 | 143 tests / 162,593 assertions / 0 failures | Step 99〜104 |

---

## Step 105 — コンパイルスループット計測基盤(M5 H5 の第一要)

H5(N1: 20,000 行/秒)の入口として、ROADMAP の「まず測定を整備」を実装。
`rake bench:throughput`(benchmark/throughput.rb)が実 gem の C ソースに対する
コンパイラ自身の速度を「前処理後行数/秒」で計測し、
`benchmark/results/throughput-<stamp>.{md,json}` に環境情報付きで継続記録する。

- **ワークロード**: json 2.21.1(parser/generator)・msgpack 1.8.3(11 ファイル)・
  bigdecimal 4.1.2(bigdecimal.c/missing.c)= 16 ファイル。バージョン固定で
  経時比較可能。ステージングは WORK/tp-*(run.rb の実行速度ベンチと共有しない)。
- **extconf は mkmf shim 経由**(`-rrubycc/mkmf_shim`)で実行し、`RUBYCC=1 gem install`
  と同一の conftest 判定で -D セットを得る。**gcc で extconf すると rubycc の
  conftest では無効になる機能マクロが有効化され、実インストールではコンパイル
  しないソースを測ってしまう**ことを bigdecimal で実測: gcc extconf は
  `HAVE_RUBY_ATOMIC_H` を定義し、missing.c が `<ruby/atomic.h>` に突入して
  `RBIMPL_STATIC_ASSERT(…, sizeof *ptr == sizeof(size_t))` で停止する
  (rubycc の conftest では同ヘッダは `__atomic_*` 組み込み未実装により正しく
  無効判定される)。この副産物として `_Static_assert` の sizeof(式)未畳み込みが
  言語ギャップとして顕在化(→ Step 107)。
- **計測方式**: インプロセス・ウォーム(ウォームアップ 1 回 + `BENCH_RUNS`(既定 3)回の
  フルコンパイル(ソース → ELF オブジェクト)中央値)。Ruby 起動コストを含めない
  ことで N1 の趣旨(コンパイラ自身の速度)に合わせる。ステージ内訳
  (preprocess / tokenize / parse / IR)は 1 回計測の参考値として併記し、回帰時に
  再プロファイルなしで当たりを付けられるようにする。ABI 依存パラメータは
  `Compiler::TARGETS` の x86_64 エントリから取得し、Compiler 本体とドリフトしない。
- **「前処理後行数」の定義**: phase-4 出力にトークンを 1 つ以上産んだ一意な
  (ファイル, 物理行) 対の数(≒ `rubycc -E` が出す行)。phase-4 のトークン列に
  :newline は残らないため、素朴な改行トークン数は使えない。
- **YJIT**: 起動時に `RubyVM::YJIT.enable` を試み、結果(enabled / unavailable)を
  レポートに記録。本ホストの Ruby 3.4.5 は YJIT 非対応ビルドのため、N1 の受け入れ
  条件「YJIT 有効で」の実測は本環境では不可能なことが判明(unavailable と記録)。
- **初回ベースライン(2026-07-27、旧文字カーソル Scanner)**:
  **代表値 847 行/秒(ファイル別中央値)= 目標の 4.2%**。全 16 ファイルで
  preprocess がフルコンパイル時間の 9 割超(例: json parser.c 6.44s 中 6.34s)。
  H5 着手時のプロファイル(Scanner#scan が前処理の 9 割 ≒ 全体の 8 割)と整合する
  支配構造をベンチとしても固定化(`results/throughput-20260727-223054.md`)。

## Step 106 — Scanner の StringScanner 化(M5 H5、前処理の主ボトルネック解消)

H5 着手時のプロファイル(`Scanner#scan` が前処理の 9 割 ≒ コンパイル全体の 8 割)に
基づく、計測駆動の最初の最適化。`preprocess/scanner.rb` の文字カーソル方式
(`@src[@pos]` を 1 文字ずつ、メソッド呼び出し多数)を strscan(StringScanner)の
トークン単位正規表現マッチに全面書き換え。

- **継続行の扱いが設計の核心**。旧実装はカーソル内で backslash-newline を透過的に
  スキップして物理行/桁の正確さを守っていた(クラスコメントに「先に文字列を
  書き換えると桁が壊れる」と明記)。新実装は**先に全 `\\\n` 対を削除**した文字列を
  スキャンし、**削除位置(splice points)を記録して行/桁を復元**する:
  splice point 以降は次の物理行、という置換えで `#sync` が行カウンタと行頭
  オフセットを遅延再生する。桁は行頭からのバイト差(ASCII)/文字数
  (非 ASCII のみ byteslice で数える)。これで「トークンは削除済み文字列上で
  1 マッチ、位置は物理行/桁で真実」を両立し、旧実装と観測上同一のトークン列を出す。
- **正規表現の要点**: pp-number は `(?:[eEpP][+-]|[0-9A-Za-z_.])*`(符号は指数の
  直後だけ)。文字列/文字定数は `"(?:[^"\\\n]|\\[^\n])*(?:"|\\)?` — 末尾の
  `("|\)?` が「行末/EOF で切れた未終端リテラルは読めた分+孤立バックスラッシュを
  保持」という旧実装の挙動を正確に再現する(`\\\\\n` 由来で削除後文字列に
  `\` + 改行が残るケース含む)。ワイドリテラルは識別子 `L` を先に取り、引用符が
  直後に続くときだけ拡張。句読点は長さ降順の `Regexp.union` 1 発で最長一致。
- **等価性の検証**: 旧新実装を同プロセスにロードし、エッジケース 43 本
  (トークン内継続行・連続継続行・`\\\\\n`・未終端リテラル各種・ブロックコメント内
  改行/継続行・多バイト桁・space_before 境界など)+ リポジトリの全ヘッダ/例/
  テスト C ソース 309 ファイル + ステージ済み実 gem ソース 45 ファイルで
  トークン列(type/text/line/column/source_line/space_before)の**完全一致**を確認。
  併せてスキャナ直叩きの回帰テスト `test/test_scanner.rb`(16 件)を新設し、
  位置情報・未終端・最長一致・space_before の契約をピン留め。
- **効果(Step 105 のベンチ、同一環境・同一ステージング)**: スキャナ単体
  16.8k → 54.0k 行/秒(3.2 倍)。フルコンパイルの代表値 **847 → 2,601 行/秒
  (3.07 倍、目標 20,000 の 13.0%)**。preprocess は例えば json parser.c で
  6.34s → 1.76s。前処理は依然全体の 8 割強で、次の計測駆動候補は ROADMAP 記載の
  「同一ヘッダ再 #include のトークン列キャッシュ」
  (`results/throughput-20260727-223351.md`)。
- strscan は default gem(Ruby 同梱)で、R2(外部ツールチェーン非依存)を破らない。

## Step 107 — `_Static_assert` の `sizeof <式>` 畳み込み(M5 H5 の副産物)

Step 105 のハーネス整備中に顕在化した言語ギャップ: gcc で extconf した bigdecimal は
`HAVE_RUBY_ATOMIC_H` が付き、missing.c → `<ruby/atomic.h>` の
`RBIMPL_STATIC_ASSERT(sizeof_voidp, sizeof *ptr == sizeof(size_t))` が
「static assertion expression is not an integer constant」で停止した。
配列境界用に Step 100 で導入済みの parse 時 sizeof 解決(`fold_time_sizeof`)を
`parse_static_assert` の `evaluate_constant_expression` にも渡す 1 行で解消。

- サイズ関係の表明は _Static_assert の主用途で、宣言済みオブジェクト・仮引数の
  デリファレンス・文字列リテラルが Step 100 の解決器の守備範囲そのまま。
  解決できない名前は従来どおり「not an integer constant」で停まる。
- **atomic.h 自体は引き続きコンパイル不能**(ruby の config.h が焼き込む
  `HAVE_GCC_ATOMIC_BUILTINS` により `__atomic_fetch_add` 等の GCC 組み込みへ
  到達する。組み込み未実装 = M6 GCC 擬態の領域)。よって実インストール
  (`RUBYCC=1`)では conftest が同ヘッダを無効判定し続け、コーパスの挙動は不変。
  本修正は表明そのものの畳み込み能力を C11 6.7.10 として正しくするもの。
- テスト: 診断 4 件(式 sizeof の成立 2 形態・sizeof 込み失敗時のメッセージ・
  未宣言名の拒否)+ gcc 差分実行オラクル 1 件(配列全体 / 文字列リテラル /
  仮引数デリファレンスを 1 プログラムで)。

## Step 108 — ヘッダ scan 結果のキャッシュ(M5 H5、再 #include の再スキャン排除)

Step 106 後の再プロファイルで特定した次の支配項を解消。json parser.c の 1 コンパイルで
Scanner が **1,075 回**呼ばれるうち **873 回(81%)が同一パスの再スキャン**だった
(math.h 87 回・dllexport.h 82 回・value.h 80 回…)。ruby.h の include グラフは同じ
ヘッダを何百回も再 #include し、ガードで本文が捨てられる場合でも `#endif` を探すために
毎回フルスキャンしていた。

- **修正**: `process_include` の `Scanner.new(...).scan` を、解決済みパス文字列を
  キーに `@scan_cache` へメモ化(1 行 + 初期化)。**scan(phase 2–3)はファイル内容の
  純関数**(マクロ状態が届かない)、PPToken は完全 immutable(paint はコピー生成)、
  directive 走査(`process_lines`)はインデックス走査で配列非破壊 — なので同一
  トークン配列を再 #include 間で読み取り専用共有できる。directive 走査自体は毎回
  走るため、条件付き取り込み・マクロ展開は現在のマクロ状態を正しく見る。
- **キーは解決済みスペリング文字列**(`File.expand_path` ではなく)。同一実体が別
  スペリングで解決された場合はキャッシュを共有しない = トークンの filename
  (`__FILE__`・診断)が従来と完全一致。`@include_origin`(#include_next 用)は
  パス解決側で記録されるためキャッシュヒットでも無傷。`#pragma once` の抑止は
  従来どおり process_include 冒頭で先に効く。
- **残る「再スキャン」204 回は対象外が正しい**: `##` 連結の 2 トークン再スパル
  (site のファイル名で計上される)と `<built-in>`(_Pragma 等)で、いずれも微小。
- **検証**: 再 #include がマクロ文脈を再評価することを固定するリグレッション
  テストを追加(同一ヘッダを #define 変更を挟んで 2 回 include し、展開・条件分岐の
  両方が変わることを表明 — 「キャッシュしてよいのは scan までで、展開結果や
  条件判定は絶対にキャッシュしない」の契約をピン留め)。
- **効果(Step 105 ベンチ)**: 前処理 1.753s → 0.75s(json parser.c、プロファイル値)。
  フルコンパイル代表値 **2,601 → 5,865 行/秒(2.25 倍、Step 105 ベースラインから
  累計 6.9 倍、目標 20,000 の 29.3%)**(`results/throughput-20260727-224809.md`)。
  内訳は preprocess ~0.6s / parse ~0.13s / IR ~0.03s / 残り(バックエンド + ELF)
  ~0.15s 程度となり、前処理は依然最大項(全体の 6〜7 割)。次の計測駆動候補は
  scan 後の残り(directive 走査・マクロ展開・トークン変換)のプロファイル分解。

### Ruby 4.0.6 / YJIT での実測(2026-07-27、ユーザ指示)

rbenv に Ruby 4.0.6(YJIT 対応ビルド)が導入されたため、N1 の受け入れ条件
「YJIT 有効で 20,000 行/秒」を初めて本来の条件で計測(ステージングは
`/tmp/rubycc_bench_ruby40` に分離し、4.0.6 ヘッダ + shim extconf でやり直し):

| 環境 | 代表値(行/秒) | 対目標 |
|---|---:|---:|
| Ruby 3.4.5(YJIT 非対応ビルド) | 5,865 | 29.3% |
| Ruby 4.0.6(YJIT off, BENCH_YJIT=0) | 7,370 | 36.9% |
| **Ruby 4.0.6 + YJIT** | **11,984** | **59.9%** |

- インタプリタ移行だけで +26%、YJIT でさらに +63%(3.4.5 比 2.04 倍)。
- **rubycc は Ruby 4.0.6 上でそのまま動作**し、4.0.6 の ruby.h を含む全 16
  ファイルが追加修正なしでコンパイルできた(前処理後行数が僅かに増えるのは
  4.0 ヘッダの差分)。全テストスイートも 4.0.6 で実走して互換を確認:
  2,457 runs / 6,700 assertions / 0 failures / 47 skips(assertion 数の差は
  環境依存の実行テスト分)。
- レポート: `results/throughput-20260727-225800.md`(YJIT on)/
  `throughput-20260727-225913.md`(off)。N1 完達には YJIT 有効でさらに
  約 1.7 倍が必要 — 前処理の残り(directive 走査・マクロ展開)が次の対象。

## Step 109 — multiple-include optimization(M5 H5、ガード付きヘッダの再走査スキップ)

Step 108 後の再プロファイル分解で、前処理の残り時間の内訳が
「scan(ユニークファイル分)0.19s + directive 走査 ~0.2s」で、**1 TU に
process_directive 呼び出しが 36,052 回**あることを特定。ガード付きヘッダの
再 #include は本文が全て条件スキップされるのに、行単位の走査だけは毎回
支払っていた。gcc と同じ multiple-include optimization を実装。

- **修正**: `#detect_include_guard` がファイル全体の有意な内容が
  `#ifndef G … #endif`(または `#if !defined(G)` / `#if !defined G`)で
  包まれているかをトークン配列の純粋解析で 1 回判定し、`@guard_cache` に
  記録。再 #include 時にガードマクロが**現在**定義されていればファイル走査を
  丸ごとスキップ(`#undef` 後は再処理される — 判定はライブなマクロ表)。
- **不適格条件が正しさの要**: ガード深さ 1 の `#else`/`#elif`(ガード定義時に
  *別の内容*を出すので、スキップすると出力が変わる)、`#endif` 後の有意
  トークン(スキップで失われる)。C23 の `#elifdef`/`#elifndef` の綴りも
  防御的に不適格(本コンパイラは未処理だが、ガード解析が仮定してはならない)。
- **検証**: HEAD との `rubycc -E` 出力 A/B を staged 実 gem 36 ファイルで
  実施し完全一致。意味論テスト 5 件を追加(2 回 include で 1 回だけ出る/
  `#if !defined` 形/`#undef` 後の再取り込み/#else 付きはスキップ不可/
  `#endif` 後の残余で不適格)。
- **効果**: process_directive 呼び出し 36,052 → 7,527(-79%)。代表値
  3.4.5 で 5,865 → 6,416 行/秒(+9.4%、目標の 32.1%)、4.0.6+YJIT で
  11,984 → **12,716 行/秒(+6.1%、目標の 63.6%)**
  (`results/throughput-20260727-231209.md` / `-231104.md`)。
  時間の主残余は scan(ユニーク分)と活性領域のマクロ展開・トークン収集で、
  呼び出し回数の割に走査自体は軽かった — 次の一手はプロファイル分解の続き
  (collect_line・expand_tokens の中間配列削減、ROADMAP の残り候補)。

## Step 110 — include 解決のメモ化 + membership の O(1) 化(M5 H5、stackprof 駆動)

stackprof(開発時依存として導入、ROADMAP の明記どおり)による自己時間分析で、
ウォームな 1 コンパイル中の `File.file?` 3.6%(#include のパス解決が毎回探索パスを
総当たり)と `Array#include?` 2.1%(全識別子が通るキーワード判定・定数 membership の
線形探索)を特定して除去。**本ステップから実装は役割表どおり implementer(Sonnet)へ
移譲**し、メインは仕様確定・レビュー・検証統合を担当(ユーザ指示による運用是正)。

- **include 解決のメモ化**: `resolve_include` の成功結果を quote は
  `[includer のディレクトリ, name]`、angle は `name` をキーに `@resolve_cache` へ。
  キャッシュは `preprocess` ごとにリセット(@include_paths 依存のため)。ヒット時の
  `record_include_origin` 再呼び出しは不要(初回解決で同値記録済み)。raise 経路は
  キャッシュしない。`resolve_include_next` は origin 依存・低頻度のため対象外。
- **membership の O(1) 化**: `LexemeReader::KEYWORD_SET`(全識別子が通る
  `keyword?`/`keyword_spelling`)と、プリプロセッサの CONDITIONAL_DIRECTIVES /
  BUILTIN_MACROS / KNOWN_BUILTINS / KNOWN_ATTRIBUTES を membership 専用の凍結
  Hash に変更(`.include?` → `.key?`)。トークン毎に異なる小配列
  (`macro.params` / `tok.suppress`)は対象外のまま。
- **計測の教訓 — ペア計測の導入**: 単発の before/after 比較では本マシン
  (モバイル Ryzen)の ±10% ドリフトに改善が埋もれた(4.0.6+YJIT で
  12,716 → 12,605「横ばい」、3.4.5 で 6,416 → 5,942「悪化」に見えた)。
  同一セッションで HEAD → 作業ツリーを連続実行するペア計測(BENCH_RUNS=7)で
  判定し直し: **HEAD 12,028 → 変更後 12,855 行/秒(+6.9%、目標 20,000 の
  64.3%)**(4.0.6+YJIT、`results/throughput-20260727-234810.md`。3.4.5 の
  runs=3 参考値は `-234348.md`)。以後の性能ステップの採否判定はペア計測を標準とする。
- **検証**: `rubycc -E` 出力の対 HEAD A/B を staged 実 gem 36 ファイルで実施し
  完全一致(挙動不変)。テスト増なし(純内部最適化)。

## Step 111 — x86_64 emit 経路の割り当て排除(M5 H5、GC 圧 18% への第一手)

Step 110 後の objspace 割り当てプロファイル(1 コンパイル = 約 128 万オブジェクト)で、
バックエンドの命令エンコードが上位サイトに複数入ることを特定(emit の splat Array が
呼び出しごと、`modrm_rbp_disp` の pack×2+連結で String 3 個/回 ≒ 7.8 万、
`emit_bytes` の `.b` 再エンコードコピー 2.5 万)。code-explore による全数調査
(emit 全 120 呼び出しの引数個数分布、emit_bytes 全 25 箇所の引数型、
modrm_rbp_disp 全 11 箇所の用途)で仕様を確定し、implementer に移譲して実装。

- `emit(*bytes)` → 固定 4 引数(調査済みの最長呼び出し)でsplat の Array 生成を
  排除。唯一の splat 呼び出し(算術命令テーブル)は each で置換。
- `modrm_rbp_disp`(文字列を組み立てて返す)→ `emit_modrm_rbp_disp`(@code へ
  直接追記)。disp8 は `& 0xFF`、disp32 はシフト+マスクの 4 バイトで、
  `pack("c")`/`pack("l<")` とバイト同一(負値は Ruby の無限精度 2 の補数で一致)。
- `emit_bytes` の `.b` を除去(全呼び出しの引数が Array#pack の結果 =
  ASCII-8BIT 保証、という契約をコメントに明文化)。
- aarch64 は emit_word(4 バイト固定)のみで同種のパターンが無いことを調査で
  確認済み — x86_64 固有の作業。
- **検証**: バイト列同一性は golden・gcc 差分・決定的ビルドを含む全スイートで
  確認(2,462 runs / 0 failures、増減なし)。**ペア計測**(HEAD → 変更後、
  BENCH_RUNS=7、gcc 参照無効で条件統一): **13,235 → 13,854 行/秒(+4.7%、
  目標 20,000 の 69.3%)**(`results/throughput-20260728-001523.md`。HEAD 側
  results は worktree ごと破棄のため数値のみ本記録に残す)。

## Step 112 — スループットベンチに gcc -O0 参照値を併記(M5 H5、ユーザ指示)

「N1 の 20,000 行/秒は何に基づくか」という問いへの回答(DESIGN §3.2 の
体験要件からの逆算値であり外部基準を持たない)を受けたユーザ指示
「gcc -O0 の行/秒も同ハーネスで計測して併記」の実装。implementer に移譲。

- 各ファイルを **rubycc と同一の include パス・-D セット・-fPIC** で
  `gcc -O0 -c` し(argv 直接 exec、シェル非経由)、ウォームアップ 1 回 +
  BENCH_RUNS 回の中央値を計測。**分母は rubycc と同一の「前処理後行数」**
  なので倍率が直接読める。テーブルに `gcc-O0 行/秒`・`rubycc/gcc` 列、
  代表値行の直後に gcc -O0 代表値と倍率を併記。JSON にも
  gcc_median / gcc_lines_per_sec を追加。
- **非対称条件を明記**: gcc はプロセス起動込みの wall time、rubycc は
  インプロセス(ウォーム)。絶対値は同じものを測っておらず、倍率のみが
  参考値(コード・レポート脚注・README に記載)。gcc 不在または
  `BENCH_GCC=0` でスキップし env に理由を記録。失敗した行は "-" で続行。
- **初回実測(2026-07-28、4.0.6+YJIT、BENCH_RUNS=7)**:
  **gcc -O0 代表値 34,874 行/秒、rubycc 13,730 行/秒 = 0.39 倍**
  (`results/throughput-20260728-001650.md`)。これにより N1 目標
  20,000 行/秒は「本マシンの gcc -O0 の約 0.57 倍」という外部基準を得た。
  プロセス起動込みでこの値なので、gcc 本体のコンパイル速度はさらに上 —
  倍率は rubycc に不利側の保守的な参考値である。

## Step 113 — rmake の並列ビルド既定化(M5 H5、実インストールの体感直結)

Step 111 後のプロファイル再採取で、TU 内の残ボトルネックが StringScanner
プリミティブ(ユニークヘッダ初回スキャンの本質コスト、自己時間 24%)に収斂し
1 件 2〜4% 級の小粒だけになったため、ROADMAP の H5 残項目「rmake -j の既定化」
(マルチコアの実利用)へ転換。implementer に移譲して実装。

- **変更は CLI の既定値 1 行**: `parse_argv` の `jobs = 1` →
  `jobs = processor_count`(既存の bare `-j` と同じ Etc.nprocessors、失敗時 1)。
  gem install は rmake を素の `make` として呼ぶため、これだけで実インストールが
  全コアを使う。`-j1` が従来の直列。`-j N` 系の解析・Executor / Makefile#run の
  ライブラリ既定(jobs: 1)は不変。
- **並列でも成果物・出力が直列と同一である根拠**(B3 で実装済みの性質):
  スケジューラは依存 DAG を守り、各ステップの出力はバッファして丸ごと flush
  (make -O 相当)。今回はその既定を変えただけで、並列実行系のテスト
  (test_rmake_tools の jobs: 2 系)は既存のまま通用する。
- **実測(staged msgpack ext、11 TU、clean ビルド、6 コア機)**:
  `-j1` 9.23 秒 → 既定 **2.46 秒(3.76 倍、CPU 431%)**。msgpack.so 生成・
  exit 0 を両者で確認。単一 TU の行/秒(N1 の代表値)には影響しないが、
  実インストールの compile フェーズは TU 数分だけ短縮される。
- テスト: CLI 既定 = processor_count / `-j1` = 1 のユニット 2 件を追加。

## Step 114 — メンバアクセスの parse 時 sizeof 解決(M5 H5、sqlite3 参考計測の副産物)

ROADMAP H5 の「sqlite3 amalgamation(25 万行)の参考値実測」を実施したところ、
261,463 行の単一 TU が `sqlite3.c:62710` の
`char dbFileVers[sizeof(pPager->dbFileVers)];` で
「array size must be an integer constant」で停止。Step 100(配列境界)・
Step 107(`_Static_assert`)で導入した parse 時 sizeof 解決に**メンバアクセスの
形が無かった**ためで、同じ解決器に 1 分岐足して解消した(implementer に移譲)。

- `sizeof_operand_type` に `AST::MemberAccess` 分岐を追加。`->` なら base を
  `element_of` で先に剥がして(`p->m` ≡ `(*p).m`)、`member_sizeof_type` で
  メンバ型を引く。
- `member_sizeof_type` は**完成済み struct/union の実在メンバのみ**返し、
  ビットフィールドは nil(sizeof 不可、6.5.3.4p1)。不完全型は
  `StructType#member` が nil を返すため自然に安全。
- **移譲仕様の誤りをエージェントが検出**: 当初仕様の `type.struct? || type.union?`
  は `union?` が `Type::StructType` にしか無いため、非集約型に対して
  NoMethodError で落ちる。`struct?` は struct/union 双方に true を返す設計
  (type.rb のコメント)なので `!type.struct?` 単独が正しく、そのように修正された。
  レビューで実装を確認して採用。
- テスト: パーサ単体 1 件(`char c[sizeof(p->v)]` が `char[16]`)、診断 3 件
  (`.`/`->` 経由の `_Static_assert` 受理、未知メンバの拒否)、gcc 差分の実行
  オラクル 1 件(sqlite3 の形を模した `char dbFileVers[sizeof(pPager->dbFileVers)]`)。
- **sqlite3 の到達点**: この修正で 62710 行を通過し、**261k 行のパースが完走**して
  IR 生成段階まで到達(6.0 秒 / 最大 RSS 438MB。N6 の 1GB/TU 目安内)。
  次のブロッカーは `sqlite3.c:39063`(→ Step 115 で切り分け)。
  参考: 同ファイルの gcc -O0 は 4.21 秒 / 277MB。

## Step 115 — `<unistd.h>` の `pread`/`pwrite` と未宣言識別子の診断改善(M5 H5)

Step 114 で到達した sqlite3 の次のブロッカー
`sqlite3.c:39063: { "pread", (sqlite3_syscall_ptr)pread, 0 }` の切り分け結果、
**IR のギャップではなくヘッダの宣言漏れ**だった。同じ形の
`close`/`access`/`read`/`ftruncate`/`fcntl` は 39024〜39061 行を通過しており、
`pread` の行で初めて落ちる — 同梱 `<unistd.h>` に `pread`/`pwrite` が無いためで、
`#include <unistd.h>` して `pread(...)` を呼ぶと
「implicit declaration of function 'pread'」になることを実測で確認した。

- **修正 1(ヘッダ)**: `<unistd.h>` の `read`/`write` の直後に POSIX の位置指定 I/O
  `ssize_t pread(int, void *, size_t, off_t)` と `pwrite` を追加(`off_t` は
  同ファイル 24 行で既に定義、`lseek`/`ftruncate` と同じ型)。header-abi ハーネスの
  UNISTD snippet に両者の呼び出しを追加し、gcc+システムヘッダ /
  rubycc+同梱ヘッダの双方でコンパイル・実行されるようにした。
- **修正 2(診断、N3)**: 未宣言識別子が**静的初期化子の中**にあると、スカラー・
  集約とも「unsupported initializer for global variable」になり原因が読めなかった
  (同じ名前をローカル式で使えば正しく「undeclared variable 'X'」が出る)。
  **この誤誘導のせいで、今回ヘッダ不足を IR のギャップと誤読しかけた**のが修正の動機。
  `object_address` の VariableRef 分岐で、`@global_bindings` にも `@signatures` にも
  無い場合に `lookup_variable`(ローカルスコープも見る既存 API)を引き、
  **どのスコープにも束縛が無いときだけ** `undeclared variable 'X'` を報告する。
  「宣言はあるが定数式でない」(`static int *p = &local;`)は従来メッセージのまま
  = 退行防止テストで固定。未宣言識別子は C99 以降どの文脈でも常にエラーであり、
  この畳み込みが初期化子の最終判断の場なので投機的に握り潰す必要がない。
- テスト: 診断 3 件(集約・スカラーの未宣言報告 + ローカルアドレスの退行防止)、
  header-abi の UNISTD snippet 拡張。
- **sqlite3 の到達点**: 39063 を通過し、次は `sqlite3.c:42862` の
  `sysconf(_SC_PAGESIZE)` — 同梱 `<unistd.h>` は `sysconf` を宣言しているが
  `_SC_*` 定数を持たない、という**同種のヘッダ不足**(→ 次ステップ)。
  改善した診断がそのまま `undeclared variable '_SC_PAGESIZE'` と出し、
  原因が一読で分かる形になった。

## Step 116 — `<unistd.h>` の `_SC_*` 定数(**sqlite3 amalgamation のコンパイル成功**)

Step 115 で到達した `sqlite3.c:42862` の `sysconf(_SC_PAGESIZE)` を解消。同梱
`<unistd.h>` は `sysconf` を宣言しながら引数の `_SC_*` を 1 つも持たなかった。

- **値はホスト libc の ABI**: `sysconf()` は実行時 libc の関数なので、`__name` は
  ホストの番号付け(glibc の `<bits/confname.h>` の enum)と一致していなければ
  ならず、rubycc が決めてよい値ではない。glibc ではマクロではなく enum のため
  `gcc -E -dM` には現れず、**実行時に printf して実測**した値を使用
  (`_SC_ARG_MAX`=0 … `_SC_PAGESIZE`=30 … `_SC_AVPHYS_PAGES`=86 の 11 個。
  `_SC_PAGE_SIZE` は `_SC_PAGESIZE` の別名)。
- **機械検証**: 11 定数すべてを header-abi ハーネスの `ints:` に登録した。
  この仕組みは gcc+システムヘッダと rubycc+同梱ヘッダで**定数値の一致**を
  比較するので、値の取り違えは必ずテストが落とす。snippet にも
  `sysconf(_SC_PAGESIZE)` の実呼び出しを追加。
- 実使用の裏付け: sqlite3 が `_SC_PAGESIZE`、コーパス gem が別名の
  `_SC_PAGE_SIZE` を使用(実測 grep)。残りは sysconf の中核セット。

### sqlite3 amalgamation のコンパイル成功(ROADMAP H5 の参考値、N1/N6)

**261,463 行の単一 TU が rubycc で通った**(3.49.2 amalgamation):

| | rubycc | gcc -O0 |
|---|---:|---:|
| wall | **8.12 秒** | 4.21 秒 |
| 最大 RSS | **467 MB** | 277 MB |
| 出力 | sqlite3.o 5,117,472 バイト | — |

- N1 の「巨大な単一 TU は『動くが遅い』を許容し上限を設けない」に対し、
  gcc -O0 の **1.93 倍の時間**で完走。
- **行/秒(ベンチと同じ指標・同じ方法で別途実測)**: 物理 261,463 行のうち
  **前処理後は 88,261 行**(残りは `#if` で落ちる Windows/OS2/VxWorks 等の
  プラットフォーム分岐)。ウォーム・インプロセスのフルコンパイル中央値
  5.516 秒 ⇒ **16,001 行/秒(N1 目標 20,000 の 80.0%)**。物理行基準なら
  47,403 行/秒。コーパス gem の代表値 13,854 行/秒より**速い**のは、
  amalgamation がほぼ平坦な C でヘッダ展開(前処理)の比率が低いため。
  上表の 8.12 秒は CLI 実行のため Ruby 起動 + require + JIT 立ち上げを含み、
  ウォーム計測(5.516 秒)とは条件が異なる。
- N6 の「1 TU あたり 1GB 以内」に対し 467MB で収まった。
- ここに至るまでに要したのは Step 114(メンバ sizeof)・115(pread/pwrite)・
  116(`_SC_*`)の 3 件のみで、いずれも**言語機能の欠落 1 件 + ヘッダ不足 2 件**。
  25 万行級の実コードでも未対応の C 構文にはほぼ当たらないことが確認できた。

## Step 122 — 同梱 `<setjmp.h>` と `<locale.h>`(M5 H2、センサス駆動のヘッダ拡充)

Step 121 のコーパスセンサスが「同梱すべき libc ギャップ」として実測で挙げた
**C 標準ヘッダ 2 件**を追加(`setjmp.h` は google-protobuf、`locale.h` は
bigdecimal が使用)。同梱ヘッダは 53 → 56 本。

- **`<setjmp.h>`(アーキ層に 2 本)**: `jmp_buf`/`sigjmp_buf` はサイズが
  アーキ依存(**実測** x86_64 = 200/8、aarch64 = 312/8。クロス gcc + qemu で計測)
  のため `pthread.h` の前例に倣いアーキ層へ。glibc の内部フィールド
  (`__jmpbuf`/`__mask_was_saved`/`__saved_mask`)は**複製せず**、実測した
  サイズ・アラインメントだけを不透明ブロブとして再現。
- **`sigsetjmp` は関数ではなくマクロだった**: 素の関数宣言ではリンクに失敗する。
  `nm -D libc.so.6` で確認したところ glibc が export しているのは `__sigsetjmp`
  のみで、glibc 自身のヘッダも `sigsetjmp` をマクロとして展開している。
  ソースの複製ではなく**相互運用上の公開契約**なので、同じ形
  (`__sigsetjmp` を宣言 + マクロ定義)で再現した。
- **`<locale.h>`(共通層)**: `struct lconv` は全メンバが呼び出し側から直接
  使われるため不透明ブロブにできない。メンバ名・型・順序は **C11 7.11.1.1 が
  「以下のメンバを示した順で」と規定する公開契約**であり glibc の実装詳細では
  ないので再現可。サイズ(96)と全メンバのオフセットを両アーキで実測し
  **完全一致**したため(全メンバがポインタと char で LP64 では差が出ない)、
  アーキ非依存の共通層に配置した。`LC_*` の値は `setlocale` がホスト libc の
  関数である以上ホストの番号と一致必須なので実測(Step 116 の `_SC_*` と同じ理由)。
- **rubycc 固有の注記**: 最適化を行わず全値をスタックにスピルするため、
  `setjmp`/`longjmp` 間で変更された非 volatile 自動変数が不定になるという
  C11 7.13.2.1 の規定に対して**保守的側に倒れている**(実際には値が保持される)。
  依存すべきでない旨をヘッダのコメントに明記。
- `locale_t`/`newlocale`/`uselocale` 等の glibc 拡張は、実コードがセンサスに
  現れていないためスコープ外(その旨をヘッダに 1 行記録)。
- 検証: ABI ハーネスに SETJMP / LOCALE の Spec を追加し、x86_64 と aarch64 の
  両クラスに登録。gcc + システムヘッダと rubycc + 同梱ヘッダで型サイズ・
  `LC_*` の値・`struct lconv` の代表メンバのオフセットが一致することを機械検証する。
- 由来台帳(docs/HEADER-LICENSING.md §3.3 / §3.4)を更新(clean-room 23 → 26 本、
  合計 53 → 56 本)。§6 のワークフローが定める必須手順に従った。

## Step 123 — POSIX ヘッダ 7 本の同梱(M5 H2、センサス駆動の続き)

Step 121 のセンサスが挙げたギャップのうち POSIX 系 7 本を追加。同梱ヘッダは 56 → 63 本。

| ヘッダ | 使用 gem | 実測サイズ |
|---|---|---|
| `pwd.h` | etc | `struct passwd` 48 |
| `grp.h` | etc | `struct group` 32 |
| `sys/utsname.h` | etc | `struct utsname` 390 |
| `sys/uio.h` | oj | `struct iovec` 16 |
| `sys/resource.h` | oj | `struct rlimit` 16 / `struct rusage` 144 |
| `dirent.h` | bootsnap | `struct dirent` 280 |
| `sched.h` | etc, google-protobuf | `cpu_set_t` 128 |

- **7 本すべて共通層に配置**: 構造体サイズ・全メンバオフセット・定数値を
  x86_64(ホスト gcc)と aarch64(クロス gcc + qemu)で実測し**完全一致**したため。
  アーキ差があった `setjmp.h`(Step 122)とは対照的。
- **`struct utsname` が 390 バイトになる理由**: POSIX が規定する 5 フィールド
  (65 バイト × 5 = 325)だけでは sizeof が合わず、Linux が持つ 6 番目の
  `domainname` を含めて初めて一致する。**実測が唯一の根拠**である好例。
- **構造体の扱いは Step 122 で確立した原則どおり**: 呼び出し側がメンバを直接
  読む構造体(passwd / group / utsname / iovec / rlimit / rusage / dirent)は
  POSIX/kernel ABI の公開契約として再現し、サイズと全オフセットを実測で確認。
  一方 `cpu_set_t` は `pthread_mutex_t`/`jmp_buf` と同じく実測サイズ・アラインの
  不透明ブロブ。`DIR` は glibc 自身が公開ヘッダで実体を与えない不完全型なので
  `typedef struct __dirstream DIR;` のまま(常にポインタ経由でしか使われない)。
- `sched.h` はセンサスが示す実使用範囲(`sched_yield` / `sched_getcpu` /
  `cpu_set_t` / `CPU_SETSIZE`)に絞り、`CPU_SET` 等のアフィニティ操作マクロは対象外。
- `sys/utsname.h` / `sys/resource.h` / `sched.h` は glibc がフラットに公開する面を
  再現するため ABI ケースに `_GNU_SOURCE` を付与(fcntl.h / pthread.h の前例と同じ)。
- 検証: 7 Spec を ABI ハーネスに追加し x86_64・aarch64 の両クラスに登録
  (`struct dirent` は全メンバ、`struct rusage` は先頭数メンバのオフセットを照合)。
  由来台帳(§3.3 / §3.4)を clean-room 26 → 33 本、合計 56 → 63 本に更新。

## Step 124 — 残りの libc ギャップ 5 本の同梱(M5 H2、センサス駆動の完了)

Step 121 のセンサスが挙げた残りの gap 候補のうち、同梱すべき libc ヘッダ 5 本
(`sys/ioctl.h` / `termios.h` / `sys/param.h` / `sys/fcntl.h`(x86-64・aarch64 の
2 本))を追加。同梱ヘッダは 63 → 68 本。`sys/endian.h` は追加せず(理由は後述)、
`regex.h` / `stdatomic.h` / `stdckdint.h` の 3 本は今回のスコープ外(未着手)。

| ヘッダ | 使用 gem | 実測サイズ・値 |
|---|---|---|
| `termios.h` | io-console | `struct termios` 60(`NCCS`=32 を含む) |
| `sys/ioctl.h` | io-console | `struct winsize` 8、`TIOCGWINSZ`=0x5413、`TIOCSWINSZ`=0x5414 |
| `sys/param.h` | digest | 実質は薄い互換シム。`MIN`/`MAX`/`howmany`/`roundup` の 4 マクロのみ |
| `sys/fcntl.h`(x86-64・aarch64) | stringio | `#include <fcntl.h>` のみの 1 行シム |

- **`struct termios`/`struct winsize` は共通層**: `NCCS`(32)を含む `struct termios`
  の全メンバオフセットと `struct winsize` の全メンバオフセット、`TIOCGWINSZ`/
  `TIOCSWINSZ` の値を x86_64(ホスト gcc)と aarch64(クロス gcc + qemu)で実測し
  **完全一致**したため共通層に配置(glibc の termios レイアウトは alpha/mips/
  powerpc/sparc の一部を除く mainline アーキ共通の「generic」形状で、x86-64/
  aarch64 はどちらもこの形状を使う)。
- **io-console の corpus サンプルが実際に到達する経路にスコープを絞った**:
  `console.c` は `HAVE_TERMIOS_H` の分岐(Linux は必ずこちら)で
  `tcgetattr`/`tcsetattr`/`TCSANOW` を使い、`termio.h`/`sgtty.h` フォールバック
  (`TCGETA`/`TIOCGETP` 等)は分岐ごと到達しない。`ioctl` も `TIOCGWINSZ`/
  `TIOCSWINSZ` の 2 リクエストしか発行しない(`grep ioctl(` で確認)。
  `tcflush`/`tcdrain`/`tcsendbreak`/`cfgetispeed`/`cfsetispeed`/`cfgetospeed`/
  `cfsetospeed` は実際には呼ばれていないが、`pwd.h`/`grp.h` が確立した前例
  (実際に呼ばれない reentrant 版 API も POSIX の完備性として宣言する)にならい
  同じ 4 関数対を宣言。`tcflow`/`tcgetsid`/`cfsetspeed` と
  `NLDLY`/`CRDLY`/`TABDLY`/`BSDLY`/`VTDLY`/`FFDLY`(行送り遅延ビット、印字出力の
  タイミング用で raw モード切替に無関係)は対象外。
- **`sys/param.h` は実測で「薄いシム」であることを確認してから絞った**: ホストの
  `sys/param.h`(x86-64: `/usr/include/x86_64-linux-gnu/sys/param.h`、
  aarch64: `/usr/aarch64-linux-gnu/include/sys/param.h`)を読むと、ファイル冒頭の
  コメント自身が "Compatibility header for old-style Unix parameters and
  limits" と自称しており、`sys/types.h`/`limits.h`/`endian.h`/`signal.h` を
  引き込んで `MAXPATHLEN` 等の BSD 名エイリアスと `setbit`/`isset` 等のビット
  マップ操作、`MIN`/`MAX`/`howmany`/`roundup` を定義しているだけだった。
  digest のコーパスサンプルはこれらのどれも参照していない(`grep` で確認、ゼロ
  件)ため、"sys/param.h" という互換シムが伝統的に持つと期待される最小の 4
  マクロだけを追加し、BSD 名エイリアスと bitmap マクロ、glibc ソースの再取り込み
  は行わなかった(「広げすぎない」というユーザ指示どおり)。**4 マクロの値は
  rubycc 自身の式で再現**(`roundup` は glibc の 2 の冪最適化分岐を持たない
  常に同じ結果を返す単純な式にした。値としての ABI 事実は同一だが、glibc の
  `__builtin_constant_p` 分岐というテキストは写経していない)。
  さらに実測で判明したのは、**digest gem がこのヘッダに実行時に到達すること
  自体がない**という事実: `sha1.c` の `#include <sys/param.h>` は
  `#if defined(_KERNEL) || defined(_STANDALONE)` の内側にあり、
  ユーザ空間の Ruby 拡張ビルドではどちらのマクロも定義されないため、この
  `#include` は常に unreachable な dead code である(extconf.rb 側にもこれらを
  定義する経路は存在しない)。
- **`sys/fcntl.h` は既存 `fcntl.h` の配置に合わせてアーキ層へ複製**: ホストの
  `sys/fcntl.h`(x86-64・aarch64 とも)は `#include <fcntl.h>` のみの 1 行だった
  ため、その 1 行をそのまま再現。内容はアーキ間でバイト一致だが、`fcntl.h`
  自身が O_DIRECT/O_DIRECTORY/O_NOFOLLOW のアーキ差ゆえに `glibc/x86_64/` と
  `glibc/aarch64/` の 2 層に分かれているため、ディレクトリ構造の対称性を保つ
  ため同じ 2 か所(`glibc/x86_64/sys/fcntl.h` / `glibc/aarch64/sys/fcntl.h`)に
  複製した(`endian.h`/`ctype.h` がバイト一致でもアーキ層に複製されている
  Step 82 の前例と同じ扱い)。プリプロセッサの `#include <...>` は常に検索パス
  先頭から解決するため、この配置でも内側の `#include <fcntl.h>` は正しく
  同じアーキの `fcntl.h` を見つける。
- **`sys/endian.h` は追加せず**: 2 つの独立した根拠がある。(1) ホスト glibc に
  この名前のヘッダは**実在しない** — `dpkg -L libc6-dev libc6-dev-arm64-cross`
  で確認したところ、x86-64・aarch64 いずれの開発パッケージにも
  `sys/endian.h` は含まれない(BSD 系 libc 固有のヘッダで、glibc は
  `<endian.h>` のみを提供する)。(2) 仮に存在したとしても、digest の
  `rmd160.c` にある `#include <sys/endian.h>` は
  `#ifdef HAVE_SYS_ENDIAN_H_` の内側にあり、このマクロを定義する
  `have_header("sys/endian.h")` 呼び出しは `digest_conf.rb`/各 extconf.rb の
  どこにも存在しない(実測で確認)。したがって glibc ホストではこの
  `#include` は原理的に到達しえない dead code であり、センサスの
  gap 一覧の verdict(「review」)を「gated(BSD 専用・到達不能、追加不要)」
  へ訂正する材料になる。
- **スコープ外 3 本(未着手)の調査結果**:
  - `regex.h`(oj): `regex_t` を `struct _rxclass` に値で埋め込んでいる
    (`rxclass.c` の `regex_t rx;`)ため、ポインタ越しの不透明型では済まず全
    メンバの再現が要る。ホストで実測した `sizeof(regex_t)` は 64 バイトで、
    内部は `re_pattern_buffer`(バッファポインタ・fastmap・翻訳テーブル・
    glibc 内部の `re_dfa_t*` 等)という実装依存の状態を多数抱える。今回の
    バッチに見合う再現コストではないため見送り。
  - `stdatomic.h`(google-protobuf): C11 の `_Atomic` 型指定子はコンパイラの
    言語機能であり、ヘッダを足すだけでは意味がない。実測で確認: rubycc に
    `_Atomic int x = 0;` を通すと
    `error: expected ';'`(パーサが `_Atomic` を型指定子として認識しない)。
  - `stdckdint.h`(bigdecimal): C23 の `ckd_add`/`ckd_sub`/`ckd_mul` は通常
    `__builtin_add_overflow` 等のコンパイラ組み込みへ展開するマクロだが、
    rubycc はこの組み込みを実装していない。実測で確認:
    `ckd_add(&r, 1, 2)` を通すと
    `error: implicit declaration of function 'ckd_add'`(組み込みが無いため
    ヘッダを足しても展開先が存在しない)。
  - 3 本とも、rubycc 側の言語機能拡張(`_Atomic`・`__builtin_*_overflow`・
    POSIX regex 実行系)が先に必要であり、ヘッダ追加だけでは前進しないという
    構造が共通する。README の既知の制限・ROADMAP への反映は今後の課題として
    残す。
- 検証: TERMIOS / IOCTL / SYS_PARAM / SYS_FCNTL の 4 Spec を ABI ハーネスに追加。
  TERMIOS/IOCTL/SYS_PARAM は共通層のため x86_64 側 Spec を aarch64 クラスの
  「neutral 層」節で再実行、SYS_FCNTL は `fcntl.h` と同じ理由でアーキ固有節に
  x86_64・aarch64 それぞれ個別の期待値で登録(FCNTL の隣)。
  由来台帳(§3.3 / §3.4)を clean-room 33 → 38 本、合計 63 → 68 本に更新。

## Step 125 — ヘッダ拡充後のセンサス再実行(M5 H2、**libc ギャップの解消を確認**)

Step 122〜124 のヘッダ追加を受けてセンサスを再実行し、実効を実測で確認した。

- **同梱ヘッダ: 40 → 53 綴り**(angle spelling 基準。由来台帳の 68 本はファイル数で、
  アーキ層のペアを 2 本と数えるため一致しない)。
- **gap candidates: 60 → 47 件**。Step 122〜124 で追加した 13 綴り
  (`setjmp.h` / `locale.h` / `pwd.h` / `grp.h` / `sys/utsname.h` / `sys/uio.h` /
  `sys/resource.h` / `dirent.h` / `sched.h` / `termios.h` / `sys/ioctl.h` /
  `sys/param.h` / `sys/fcntl.h`)が**すべて gap 一覧から消えた**。
- **残る 47 件に「同梱すべき libc ヘッダ」はもう無い**。内訳は:
  - **到達しないプラットフォームゲート内**: SIMD(`arm_neon.h` / `cpuid.h` /
    `emmintrin.h` / `nmmintrin.h`)、Windows(`intrin.h` / `conio.h` /
    `winioctl.h` / `shlobj.h`)、macOS(`CommonCrypto/CommonDigest.h`)、
    BSD(`sys/endian.h` / `machine/endian.h` / `sys/systm.h`)、Solaris(`ieeefp.h`)、
    旧 SysV 端末(`termio.h` / `sgtty.h`)、C++ 専用(`cstdbool`)
  - **ホストが提供するシステムライブラリ**: `openssl/*.h`(20 件、openssl と puma)、
    `yaml.h`(psych)、`zlib.h`(zlib)、`sanitizer/*.h`、`valgrind/memcheck.h`。
    R10 が「システムライブラリ利用時」を想定内としており同梱対象ではない
  - **言語機能の実装が先に必要な 3 件**: `stdatomic.h`(`_Atomic` 未対応)、
    `stdckdint.h`(`__builtin_add_overflow` 相当が無い)、`regex.h`
    (oj が `regex_t` を値で埋め込むため不透明ブロブ不可)。**ヘッダだけ足しても
    無意味**であることを Step 124 で実測確認済み
- つまり **H2(ヘッダ体系)はコーパス実測ベースで飽和**した。以降のヘッダ追加は
  新しいコーパス gem を入れたときに再びセンサスが示す、という運用に移る。

## Step 126 — N4(決定的ビルド)の常時検証(M5 H6)

ROADMAP H6 が「同一入力 2 回ビルドのバイナリ一致を CI 化」と明記していた宿題を実装。
`test/test_deterministic_build.rb`(10 ケース)を新設し、パイプライン全段で
バイト一致を常時検証する。

- **調査の結論は「修正不要」**。非決定性の混入源を洗い出した結果:
  - **ar ヘッダは既に決定的**だった(Step 30 の時点で `DETERMINISTIC_MTIME`/
    `UID`/`GID` = "0" を書いており、`File.stat` も `Time.now` も参照しない)。
    伝統的な ar は実 mtime と実行ユーザの uid/gid を埋めるため**ここが最大の
    危険箇所**だったが、GNU ar の `-D` 相当が最初から既定になっていた。
  - `Time.now` は rmake のステイル判定(依存の mtime 比較)のみで、出力の中身には入らない。
  - `rand`/`SecureRandom` は不使用。`object_id` は 1 回の呼び出し内のローカルな
    ハッシュキー(同一エントリの再引き当て)としてのみ使われ、反復は元の配列順。
  - `__DATE__`/`__TIME__`/`__TIMESTAMP__`/`__COUNTER__` は**そもそも未実装**なので
    時刻由来マクロの混入経路が存在しない。
  - `__FILE__` 由来の `STT_FILE` シンボルは常に `File.basename` なので cwd 非依存。
  - Step 118 で Array → Set に変えた `defined_names`/`known_names` も、シンボルの
    並び順は `ir_program.globals` の配列順が決めるため影響なしと再確認。
- **テストの構成**: 同一プロセス内のコンパイル(x86_64 / aarch64)、**別プロセス 2 回**
  (プロセスごとのハッシュシードや `object_id` の影響を捕まえる)、異なる cwd・
  絶対パス、`TZ`/`LANG`/`LC_ALL` を変えた場合、`.so` と実行ファイルのリンク、
  アーカイブ、**メンバの mtime を未来に変えてからの再構築**(ar の mtime 埋め込みを
  直接検出)、rmake の clean を挟んだフルビルド。
- 検体はシンボルテーブルとリロケーションが十分埋まるよう、静的初期化子・文字列
  リテラル・複数関数・複数型のグローバル・未定義シンボル参照・浮動小数点定数を含む。
- 不一致時にバイナリ全体をダンプせず**最初に食い違ったバイトオフセット**を報告する
  ヘルパーを用意した。

## Step 133 — Ruby 3.3 の `String#to_f` が指数を落とす問題への対処(M5 H6)

**サポート下限を 3.3 に引き上げ(Step 131)て実機検証した結果、初めて見つかった
サイレントな誤コンパイル**。3.4.5 と 4.0.6 では再現せず、3.3.12 でのみ
`test_static_float_constant_folding_matches_gcc_stdout` が失敗した。

- **原因**: `lexeme_reader.rb` の `read_floating_constant` は変換を `String#to_f` に
  委ねているが、**Ruby 3.3.x の `String#to_f` は「`.` の直後に小数部の数字が無く
  指数が続く」形で指数を丸ごと落とす**(3.4 で修正済み)。
  `"1.e5".to_f` が `100000.0` ではなく **`1.0`** を返す。
- **実害はサイレントな誤値**。C11 6.4.4.2 はこの形を valid としているので拒否もできず、
  コンパイルはエラーも警告も出さずに完了し、**誤った定数がバイナリに焼き込まれる**。
  実際に踏むのは bigdecimal の `dtoa.c` が持つ `tinytens[]`/`bigtens[]`
  (`9007199254740992.*9007199254740992.e-256` — Step 97 で対応した実例そのもの)で、
  gcc が `8.112963841460668e-225` とする値を rubycc(3.3)は `8.11...e+31` にしていた。
  極端に大小な `BigDecimal` の変換が静かに壊れうる。
- **修正**: 小数部の数字を 1 桁も消費しなかった場合のみ、**`to_f` に渡す文字列だけ**を
  `"N."` → `"N.0"` に正規化する(同じ数なので意味は変わらない)。トークンの綴りや
  診断内容には影響しない(`Result` に綴りのフィールドが無く、`text` は変換専用の
  ローカルバッファであることを確認済み)。
- **採らなかった案**: `Kernel#Float()` への置き換えは、3.3 がこの形を `ArgumentError` で
  拒否するため「誤値の代わりにビルド失敗」となり、バージョン間で挙動が変わってしまう。
  独自 strtod 実装は、`String#to_f` に文法検証を委ねる既存設計と整合しない。
- **教訓**: 「静的スキャンで非互換が見つからない」ことは「動く」ことを意味しない。
  Step 127 のチェックリストで N5 を「静的確認のみ・実機未検証」と正直に判定し、
  実際に下限バージョンで走らせたからこそ見つかった。**サポートを宣言する
  バージョンは実際に回すべき**であり、CI マトリクスの必要性を裏付ける事例でもある。
- テスト: 字句解析の回帰 8 件(バグが再発すれば 3.3 で必ず落ちる形。3.4 では修正の
  有無に関わらず通るが、下限を守るための回帰である旨をコメントに明記)。
  **全スイートを 3.3.12 と 3.4.5 の両方で実行し、いずれも 2,531 runs / 0 failures**。

---

## Step 135 — GitHub Actions による CI の構築(M5 H6)

Step 133 が「サポートを宣言するバージョンは実際に回すべき」を実証し、
Step 127 のチェックリストが N5 を「CI 未整備」と正直に判定していた債務の解消。
`.github/` は本ステップまで**存在しなかった**ため、CI は完全な新規構築である。

- **3 層に分けた**([`CI.md`](CI.md) に構成表)。分割の基準は
  **「push ごとに払ってよいコストか」**。
  - **Tier A**(`test.yml`、push / PR): Ruby 3.3 / 3.4 / 4.0 のマトリクスで全スイート。
  - **Tier B**(`nightly.yml`、夜間): ネットワークと時間を食うもの =
    corpus census の差分検出・`RMAKE_ACCEPTANCE=1` の受け入れ・`tools/m2_acceptance.rb`・
    スループット計測。これらはもともと `rake test` に含まれていない。
  - **Tier C**(`release.yml`、`v*` タグ): Tier A の**再利用**(`workflow_call`)+
    タグと `Rubycc::VERSION` の整合 + gem の再現ビルド検証。
    リリースが通常の push と違う基準で通ることを防ぐため、Tier A を書き写さず呼び出す。
- **最大の設計課題は「skip は静かに緑になる」こと**。本スイートは差分テスト主体で、
  参照実装(gcc・aarch64 クロス・qemu・pkg-config)が無いときは**失敗ではなく skip**
  する。開発機では正しいが CI では「apt のパッケージが 1 つ落ちる → 数百件が skip に
  変わる → ジョブは緑」という、検証が消えたことに気付けない事故になる。二重に防いだ:
  1. ツールチェイン導入直後に各コマンドの `--version` と aarch64 sysroot の
     ローダ・libc の存在を確認し、**1 つでも欠けたらその場で失敗**させる。
  2. `tools/ci_check_skips.rb` が実行ログの Minitest サマリ行を読み、
     `skips > CI_MAX_SKIPS`(既定 60)・`runs < CI_MIN_RUNS`(既定 2400)・
     failures/errors のいずれかで失敗する。同時に**skip 理由のヒストグラム**を出す
     (理由中の絶対パスを `<path>`、数字を `<n>` に正規化して集計するので、一時
     ディレクトリ名で分類が無限に増えない)。数値が動いたとき「どのツールが消えたか」が
     ログ先頭で分かる。ローカル全実行のログで **47 skip を 47 件とも解析できる**ことを
     確認済み。閾値は初回 green run の実測値に締める運用を CI.md に明記。
- **`qemu-user-static` ではなく `qemu-user`**。`aarch64_execution_helper.rb` が探すのは
  `qemu-aarch64` という名前のコマンドで、static 版が置くのは `qemu-aarch64-static`。
  static 版だけを入れると aarch64 実行テストが**まるごと静かに skip される** —
  上記の事故の実例そのものなので、ワークフローと CI.md の両方に理由を残した。
- **夜間ベンチは合否判定をしない**。[`THROUGHPUT.md`](THROUGHPUT.md) が記録したとおり、
  本ベンチは開発機ですら ±10% ドリフトし、Step 110 の改善は単発比較では「悪化」に
  見えた。有意差はペア計測でしか取れない。共有ホストのランナーで引くしきい値は
  偽陽性か無意味かのどちらかにしかならないので、**計測ログを残すだけ**にした
  (ハーネス自体の生存確認と傾向蓄積が目的)。結果は `benchmark/results/` に
  コミットしない — あそこはペア計測可能な同一マシンの記録を置く場所だから。
- **census は差分が出たら失敗**させる。gem のバージョンは `test/corpus/gems.rb` で
  固定されているので、再生成の差分は**rubycc 側のヘッダ網羅性が変わった**ことしか
  意味しない。記録として残すべき情報なので、通知ではなく失敗にして
  「差分を確認してコミットする」を強制する。
- **リリースの再現ビルドは `SOURCE_DATE_EPOCH` の固定が前提**。RubyGems は gem 内の
  各エントリの mtime にこの環境変数を使うため、固定しないと同一入力でも 2 回のビルドが
  食い違い、**時計が進んだことを測っているだけ**になる。コミット時刻に固定したうえで
  別々の作業ディレクトリで 2 回ビルドし `cmp`(パス依存も検出できる)。
  N4「決定的ビルド」の配布物版にあたる。ローカルで実際にバイト一致を確認した。
- **`gem push` は意図的に置いていない**。取り消せない外向きの操作で、
  アカウント保有者の判断に属する。自動化する場合の 2 経路(trusted publishing /
  `RUBYGEMS_API_KEY`)をコメントとして残すだけにした。
- テスト増減なし(CI 設定とログ解析スクリプトのみで、`lib/` は無変更)。
  スクリプトは正常系・閾値超過・runs 不足・サマリ行なし・`--verbose` なしログ・
  不正な環境変数値の各系統を実ログで確認した。

---

## Step 136 — CI が初回実行で検出した 2 件の非互換と、実行コストの削減(M5 H6)

**Step 135 の CI を回した最初の実行が、いきなり実バグを 2 件検出した**。どちらも
「開発機の環境では構造的に検出できなかった」もので、CI を組んだ価値がそのまま出た形。

### 検出 1: Ruby 4.0 で `fiddle` が bundled gem になり、テストが起動しない

- Ruby 4.0.0 で `fiddle` は default gems から**bundled gem** になった。bundler 配下では
  Gemfile に宣言しないと `require "fiddle"` が `LoadError` になる。CI の 4.0 ジョブは
  **テストが 1 件も走らないまま**落ちた(44 秒)。
- `require "fiddle"` は `test/` の 8 ファイルのみで、`lib/`・`exe/` は不使用。よって
  **gem の実行時依存にはせず**、Gemfile の development グループに追加して解決した。
- **開発機の Ruby だけで回していると原理的に気付けない**種類の非互換であり、
  Step 133 の `String#to_f` と同じ構図(下限や最新を実際に回して初めて出る)。

### 検出 2: `rubycc-pkgconf` がシステムパスをフィルタしていない

- `pkg-config` / `pkgconf` は `--cflags` / `--libs` の出力から**システムの
  インクルード・ライブラリパスを除外する**という仕様を持つ。rubycc の実装には
  このフィルタが**どの層にも無かった**。本物が `""` を返すところで rubycc は
  `-I/usr/include` を返していた。
- **このテストはローカルでは永久に skip されていた**。開発機に `pkg-config` が
  無く、`test_pkgconf.rb` の `pkg_config_available?` ガードで飛ばされ続けていたため、
  「比較テストが存在するのに一度も比較していない」状態が続いていた。
  CI で初めて実際に走った。**skip は静かに緑になる**という Step 135 の設計動機が、
  設計した当人のスイートで実証された格好。
- **修正**: `Pkgconf::SystemPathFilter` を新設し、**出力段(CLI)**で適用した。
  `--cflags` と `--cflags-only-I` が同じトークン列を共有するので一貫性が保証される。
  Resolver 層に入れなかったのは、あそこが「Requires チェーンが何を言っているか」を
  返す層で、既存の resolver 単体テストがその意味論を固定しているため。
  環境変数(`PKG_CONFIG_SYSTEM_INCLUDE_PATH` / `..._LIBRARY_PATH` /
  `PKG_CONFIG_ALLOW_SYSTEM_CFLAGS` / `..._LIBS`)は、既存の
  `SearchPath.directories(env = ENV)` の流儀に合わせて**第 1 引数で注入**する形にし、
  テストがグローバル `ENV` を汚さずに検証できるようにした。
- **既存テスト 2 件が「バグ挙動を固定していた」**ので期待値を訂正した
  (`-I/usr/include` が出ることを assert していた)。テストがあることと、
  テストが正しいことは別だという例。
- 本物の pkg-config が無い環境でも回るよう、**フィクスチャだけで完結する
  ユニットテストを 8 観点**追加(フィルタ・両方の ALLOW 環境変数・パス上書き・
  非システムパスの素通し・末尾スラッシュ正規化)。
- **未解決の申し送り**: `--libs` は multiarch libdir(`/usr/lib/x86_64-linux-gnu`)の
  扱いと重複 `-L` の除去という 2 つの候補要因が残っており、**どちらが真因かは
  ローカルでは判定不能**(pkg-config が無いため)。推測で既定値を焼き込むと外れたときに
  誤った挙動を固定してしまうので、**実測を待つ**方針にした。これは ABI 事実を
  「測る、写さない」で扱ってきた本プロジェクトの流儀と同じ。
  1 回の CI 実行で 3 フラグすべての実測値が得られるよう、比較テストを
  「全フラグを集めてから 1 回だけ落とす」形に書き換えてある。

### CI 実行コストの削減

初回実行の実測で、当初案(3 バージョン毎 push + 毎晩 3 ジョブ)は
**月 5,000〜7,000 分**の見積りとなり、private リポジトリの無料枠 **2,000 分/月**の
2.5〜3.5 倍だと判明した。**private を維持したまま**削る方針を採り、3 つ実施した:

1. **push のマトリクスを両端 2 本に**(3.3 と 4.0)。中間の 3.4 は週次へ移した。
2. **毎晩 → 毎週**(`nightly.yml` → `weekly.yml` にリネーム、日曜 18:00 UTC)。
   3.4 の全スイートジョブ `ruby-3-4` をここに追加。
3. **ドキュメントのみの変更では Tier A を起動しない**(`paths-ignore`)。
   ただし `'**.md'` のような広いパターンは**使っていない** —
   `test/corpus/include-census.md` は `test_corpus_census.rb` が内容を検証しているため、
   変更されたらテストを走らせる必要がある。除外は実在するパスの列挙に留めた。

トレードオフは正直に記録する: **3.4 固有の非互換の検出が最大 1 週間遅れる**。
両端(下限 3.3・最新 4.0)を毎 push で見ているので中間だけで壊れる範囲は限られる、
という判断。

### CI と開発機の skip 数の差

初回実行の実測で **CI 52 skips / ローカル 47 skips** と分かった。内訳は
`47 − 1 + 6`:

- **−1**: ローカルは `pkg-config` 不在で 1 件 skip → CI では実行される(そして落ちた)。
- **+6**: `test_rmake_golden.rb` の `make -n` 突き合わせ 6 件が CI で skip される。
  フィクスチャの Makefile が**開発機の Ruby ヘッダの絶対パス**を含んでおり、
  CI にはそのパスが存在しないため `make -n` が失敗する。これは環境固有の
  構造的な差で、CI 側では解消できない。

---

## Step 137 — `--libs` の実測合致と、CI 閾値の較正(M5 H6)

Step 136 で**意図的に保留した** `--libs` の不一致を、**CI の実測が出てから**直した。

- **実測(CI ログ)**: `--modversion` と `--cflags` は一致。残るのは `--libs` のみ。

  | | 出力 |
  |---|---|
  | 本物の pkg-config | `-lz` |
  | rubycc | `-L/usr/lib/x86_64-linux-gnu -L/usr/lib/x86_64-linux-gnu -lz` |

- **2 つあった候補要因のうち、どちらが真因かが確定した**。Debian/Ubuntu の pkg-config は
  **multiarch の libdir(`/usr/lib/x86_64-linux-gnu`)もシステムライブラリパスとして扱い**、
  `-L` を落とす。Step 136 で入れたフィルタの既定値にこれが無かったのが原因。
  **重複除去は不要だった** — 2 つの `-L` は同一ディレクトリなので、フィルタが効けば
  両方消えて `-lz` になる。`resolver.rb` が「トークンを書かれたまま保つ」のは Step 59 の
  意図的な設計判断なので、実測の裏付けなしにそれを覆さずに済んだ。
- **推測で直していたら片方は外していた**。Step 136 で「実測を待つ」と決めた判断が、
  結果として正しかった事例。ABI 事実を「測る、写さない」で扱ってきた流儀と同じ。
- 既定値は `["/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib", "/lib",
  "/usr/lib64"]` にした。意味づけは「**rubycc 自身のリンカが既定で探索するディレクトリ**」
  で、`link/library_resolver.rb` の `DEFAULT_SYSTEM_DIRS` と
  `pkgconf/search_path.rb` の `DEFAULT_DIRECTORIES` にも同じ multiarch パスを
  ハードコードしている前例がある。そこに `-L` を出す意味がないから落とす、が理屈。
  **`/usr/local/lib` は意図的に含めない** — リンカは探索するが、本物の pkg-config は
  システムディレクトリ扱いしないため、落とすと実物と食い違う。
  `DEFAULT_INCLUDE_DIRECTORIES` は `--cflags` が実測で一致しているので触っていない。
- **CI 閾値を実測値に較正**した。`tools/ci_check_skips.rb` の既定を
  `CI_MAX_SKIPS` 60 → **55**、`CI_MIN_RUNS` 2400 → **2500** に締めた。
  Step 135 でスクリプト冒頭に書いた「最初の green run の実測値に合わせて締めること」の
  実行にあたる。緩いままだと「半分が skip になった」程度の劣化を検出できない。
- テスト: `--libs zlib` の出力が `-lz` のみになることを**実測値そのままで固定**した
  (CI の比較テストのローカル代替になる)。multiarch 2 種が落ちること、
  `/usr/local/lib` は落ちないことも固定。既存テスト 1 件は
  `-L/usr/lib/x86_64-linux-gnu` が出ることを期待していたので実測に合わせて訂正した。

---

## Step 138 — 検証済み gem データベースの更新(M5 H6)

`data/verified_gems.json` は `rubycc-doctor` が参照する DB で、**ここに載ると doctor は
ネットワークにもビルドにも触れずに `verified` と判定**し、ユーザに「手元で再検証する
必要はない」と伝える。したがって**実際に行われたことだけ**を書く必要がある。

- **調査の結論**: コーパス 25 gem のうち、**gem 本体のテストスイート実走・合格まで
  到達しているのは 6 gem のみ**。既存の json / msgpack に加えて、
  **bigdecimal 4.1.2・redcarpet 3.6.1・racc 1.8.1・date 3.5.1** の 4 件を追加した。
- **残り 19 gem は追加していない**。digest 以降の default gem 群と popular gem 群は
  **センサス(`#include` 集計)の対象になっただけ**で、ビルドもテストもしていない
  (Step 117 / 119 / 121 の記録が「コーパス定義の追加のみ」「テスト増なし」と
  明示している)。「ヘッダが揃っている」ことと「ビルドが通る」ことは別の主張である。
- **sqlite3 / nokogiri / grpc は R10 で対象外**と判断済みなので、当然追加しない。
  sqlite3 は amalgamation の単独コンパイル実績(Step 114〜116)があるが、
  それは extconf/mkmf/rmake の経路を一切通していないので gem のビルド成功ではない。
- **racc には限定条件を notes に明記した**: 生成ファイル `lib/racc/parser-text.rb` を
  rmake のビルド生成物から手動補完しており、**完全に無介入の `gem install` ではない**。
  この種の但し書きを省くと DB が実態より強い保証に見える。
- **環境はすべて glibc x86_64 / ruby 3.4.5**。musl と aarch64 での gem 検証は
  一度も行われていないので、その旨を各 notes に残した。

### 副作用として見つかった、テストの構造的な弱点

racc を DB に追加したら `test_doctor.rb` の 2 件が壊れた。どちらも racc を
**「検証済み DB に載っていない C 拡張 gem」の例**として使い、その場でビルドされる
経路を検証していたため。

- **gem 名を差し替える対症療法は採らなかった**。この DB は今後も増えるので、
  別の gem に差し替えても同じ壊れ方を繰り返す。テストが検証したいのは
  「DB に無い gem はその場でビルドされる」という**振る舞い**であって、
  「特定の gem が DB に無いこと」ではない。
- **テスト側が DB を制御する**形に変えた。`rubycc-doctor` には元々 `--data PATH` が
  あるので、テスト専用の一時 DB を渡すようにした。これで出荷 DB が何を持っていても
  テストの前提は崩れない。
- この過程で**潜在バグも 1 件見つかった**: テストヘルパ `run_cli` が `verified:` を
  常に先読みして渡していたため、**`--data` を渡しても無視されていた**。
  テストから `--data` を検証する手段が実質存在しなかったことになる。
  `lib/` は変更せず、ヘルパ側を CLI のフォールバックに委ねる形に直した。

---

## Step 139 — 人気 C 拡張 gem 11 件をコーパスに追加(M5 H6)

コーパスを **25 → 36 gem** に拡大した。選定は**ダウンロード数による客観的な足切り**
(rubygems.org の API、2026-07-29 取得、**1 億件以上**)。

- **判定は必ずダウンロードした `.gem` を直接検査**した。`gem specification --remote` の
  `extensions` は常に空を返す(rubygems.org の quick index が空で配信する)という
  Step 119 が記録した落とし穴を踏まないため。11 件すべて `extensions` は 1 件、
  C++ ソースは 0 件であることを確認済み。
- **選定方法の限界も明記した**: これは人気ランキングの特定順位帯を網羅走査したものでは
  なく、C 拡張を持つと分かっている候補をダウンロード数で足切りしたもの。
  「上位 N 位を全部見た」という主張はできない(Step 119 のグループとは選定方法が違う)。
- 追加: nio4r 669M / byebug 470M / pg 459M / mysql2 238M / thin 208M /
  http_parser.rb 176M / stackprof 153M / unicorn 118M / debug 116M /
  yajl-ruby 108M / nkf 105M。

### 除外した 2 件 — どちらも**アセンブラが必要**

- **ffi 1.17.4**(10.6 億 DL、候補中最多): `ext/ffi_c/libffi` に **48 本の `.S`** を同梱。
- **bcrypt 3.1.22**(4.0 億 DL): **C ソースだけ見ると通りそうに見える**が、
  `ext/mri/extconf.rb` が `$objs` に **`x86.o` を明示列挙**しており、これは同梱の
  `x86.S` から作られる。**extconf を読まないと分からない**類の除外理由で、
  「C++ ファイルの有無」だけを見る機械判定では捕まらない。

### センサスの結果と、機械判定の粗さ

10/11 が `ok`。**pg だけが `excluded`** になった。理由は extconf 内の mini_portile2 参照。
しかし実際には、その経路は **`--with-cross-build` 指定時(事前ビルド済みバイナリ gem を
作るクロスビルド)だけ**であり(`extconf.rb:26` の条件)、通常のソースインストールは
`pg_config` / pkg-config でシステムの libpq を探す。**DESIGN R10 は pg をスコープ内として
名指ししている**。

つまり **センサスの R10 機械判定は「mini_portile への参照があるか」しか見ておらず、
「既定経路で使われるか」を区別できない**。sqlite3 が同じ理由で excluded になっているのも
同型。これは判定の粗さとして記録しておく(判定を賢くするか、手動の上書きを設けるかは
別途の設計判断)。

### 新たに現れたギャップ候補

新規 11 gem が持ち込んだ未同梱ヘッダのうち、**実際に Linux/glibc で必要になりうるもの**:

| ヘッダ | 使う gem | 種別 |
|---|---|---|
| `sys/epoll.h` | nio4r, unicorn | Linux 固有・**実需** |
| `sys/wait.h` | nio4r | **POSIX の基本ヘッダなのに未同梱** |
| `sys/syscall.h` / `sys/timerfd.h` / `sys/inotify.h` / `sys/statfs.h` | nio4r | Linux 固有 |
| `langinfo.h` | nkf | POSIX |
| `linux/types.h` / `linux/fs.h` / `linux/aio_abi.h` | nio4r | カーネル UAPI |
| `stdatomic.h` | nio4r, google-protobuf | **`_Atomic` 未対応で言語機能側がブロック**(既知の制限) |

一方、**対応不要と分かるもの**も同時に切り分けられた: mysql2 の `mysql.h` 系は
ホストのクライアントライブラリが供給する(openssl と同じ類型)。nio4r の
`WinNT.h` / `AvailabilityMacros.h` / `port.h` / `mbarrier.h` / `sys/event.h`、
nkf の `os2.h` / `sys/utime.h` はいずれも他プラットフォーム向けの分岐。

**`sys/wait.h` が抜けていたのは収穫**。POSIX の基本ヘッダで、36 gem に広げるまで
コーパスに現れなかった。「実測駆動でヘッダを足す」方針が、想定ではなく実需で
穴を見つけている例。

---

## Step 140 — センサスが見つけた 3 ヘッダの追加(M5 H6)

Step 139 のセンサスが実需と判定したギャップを埋めた。**同梱ヘッダ 68 → 72 本、
angle スペリング 53 → 56**。

- **`sys/wait.h`**(nio4r): POSIX の基本ヘッダなのに未同梱だった。
- **`sys/epoll.h`**(nio4r・unicorn): Linux 固有だが、この 2 gem は 6.7 億 / 1.2 億 DL。
- **`langinfo.h`**(nkf、1.1 億 DL): POSIX。

### 実測が設計を 1 つ覆した: epoll は共通層に置けない

着手時の想定は「x86_64 で `__attribute__((packed))` が要る」だったが、**実測すると
aarch64 では packed を付けると壊れる**:

| | sizeof | _Alignof | events | data |
|---|---:|---:|---:|---:|
| x86_64 | 12 | 1 | 0 | 4 |
| aarch64 | 16 | 8 | 0 | 8 |

よって `fcntl.h` / `pthread.h` / `setjmp.h` と同じく **arch 層に 2 本**置く構成にした。
aarch64 の ABI ケースも「中立層の再確認」ではなく**arch 固有セクション**に置いてある。
**この差は qemu 上の実行オラクルでも再現**し、それぞれの gcc と byte 一致した。

### `WIFSIGNALED` を写経せずに導出し、全域で照合した

R8 は ABI 事実を「測る、写さない」と定めている。ステータス符号化のマクロは
観測(下位 7bit = 終了シグナル、bit7 = コアダンプ、bit8..15 = 終了コード、
低位バイト `0x7f` = stopped、`0xffff` = continued)から式を書き起こした。
`WIFSIGNALED` は glibc の `signed char` トリックとは**式の形が違う**
(`WTERMSIG` を 2 回展開すると引数が 2 回評価されるため、1 回評価を保つ形にした)。

**その代わり全 2^32 個の int ステータス値 × 8 マクロを glibc オラクルと照合し、
x86_64・aarch64 の両方で不一致 0 件**を確認した。`WCOREDUMP` が真偽値ではなく
`0x80` を返す非ブール性まで含めて厳密一致している。式を変えるなら、
等価であることを主張ではなく**実測**で示す、という R8 の趣旨の実行例。

### 副次的に見つかったこと

- **`rubycc -E` はブロックコメント内の `*/` による早期終了を検出できない**。
  コメントに `EPOLL_CTL_*/...` と書いたら `*/` がコメントを閉じ、後続のアポストロフィが
  `multi-character character constant` になった。**`-E` は通ってしまい**(TokenConverter を
  走らせないため)、ABI ハーネスで初めて露見した。C の仕様どおりの挙動で gcc も同じなので
  rubycc のバグではないが、**`-E` が通ることは「正しい」の証明にならない**という実例。
- `docs/HEADER-LICENSING.md` の §3 / §3.2 / §3.3 の見出し本数が**元から §3.4 の集計と
  ずれていた**(56 / 15 / 26 対 68)。台帳更新のついでに表の行数と一致するよう是正した。
- `waitid` の `siginfo_t` は複製せず `#include <signal.h>` にした(約 40 行の union を
  複製するとドリフト源になる。`string.h` → `strings.h` の前例と同じ)。
- `P_PIDFD` はヘッダには定義したが ABI ハーネスでは検証しない。比較的新しい追加で、
  検証するとホストの glibc バージョンに依存してしまうため。

---

## Step 142 — nio4r が要求する Linux 系ヘッダ 4 本の追加(M5 H6)

Step 140 に続く 2 巡目。**同梱 72 → 77 本、angle スペリング 56 → 60**。
対象は `sys/timerfd.h` / `sys/inotify.h` / `sys/statfs.h` / `sys/syscall.h`
(いずれも nio4r = 6.7 億 DL の libev が Linux バックエンドで参照する)。

### 実測が予想を 3 つ覆した

1. **`sys/statfs.h` にアーキ差は無かった**。着手時は「メンバの型がアーキで違う可能性が
   高い」と見込んでいた(カーネルに 32bit/64bit の 2 系統があり、`sys/stat.h` は実際に
   分かれている)。実測は **両アーキとも 120 バイト / _Alignof 8 / 全メンバ 8 バイト /
   パディングなしで完全一致**、共通層 1 本になった。
   代わりに**符号が一様でない**ことが見つかった: `f_type`・`f_bsize`・`f_namelen`・
   `f_frsize`・`f_flags`・`f_spare` は符号付き、カウンタ 5 本(`f_blocks`・`f_bfree`・
   `f_bavail`・`f_files`・`f_ffree`)は符号なし。libev が `f_type` を `0x9123683e` のような
   大きな magic と比較できるのは**この欄が符号付き 64bit 語だから**で、推測で書いていたら
   気付けなかった。
2. **`fsid_t` は `<sys/statfs.h>` 単独では見えない**(glibc では `<sys/types.h>` の担当)。
   また `__fsid_t` は **8 バイト / _Alignof 4**(= int 2 本)で、`long` 1 本ではない。
3. **`sizeof(struct inotify_event[3])` を rubycc が拒否した** —
   `array type has a struct with a flexible array member as its element`。
   調べると **C 6.7.2.1 が可変長メンバを持つ構造体の配列を禁じており、gcc が拡張として
   許している**側で、**rubycc のほうが規格に忠実**だった。ハーネスをコンパイラ拡張に
   依存させるわけにいかないのでこの検証は外し、代わりに実行時に意味のあるストライド
   `sizeof(struct inotify_event) + ev->len` を実行オラクルで走らせている。

`sys/syscall.h` が arch 層 2 本になるのは予想どおり(56 名中 **53 名が不一致**。
`SYS_read` は 0 対 63、`SYS_openat` は 257 対 56。一致したのは io_uring の 3 本だけ)。

### スコープを絞った判断

`sys/syscall.h` は**全数網羅しない**。glibc 版はカーネルヘッダから生成された数百項目だが、
実測で再現するとカーネルのリリースごとに再計測が必要な巨大面になり、消費者がいない
(`sched.h` が CPU_SET 群を対象外にしたのと同じ判断)。入れたのは 56 名 —
libev が生 syscall で発行するもの、今回のヘッダの裏にある呼び出し、および表の両端と
中間に散らした代表的な中核。**x86_64 専用の旧エントリ**(`open`・`poll`・`select`・
`fork` 等)は **aarch64 の asm-generic 表にそもそも存在しない**ため入れていない
(実測で `SYS_open` が aarch64 でコンパイルエラーになることを確認)。
副次効果として 2 本の arch ファイルは**番号だけが違い名前集合は同一**になり、
ABI ハーネスの Spec 1 つで両アーキを検証できる。

### 検証

タイマを**実際に発火**させて 8 バイトの満了カウントを読み、inotify で実ファイルの
`IN_CREATE` → `IN_MODIFY` → `IN_DELETE` を 96 バイト = 3 × (16 + len 16) で受け取り、
`statfs("/")` を印字し、`syscall(SYS_statfs, ...)` を**生番号で発行**するプログラムを
gcc と rubycc の両方でビルドし、**x86_64・aarch64(qemu)とも出力が byte 一致**した。
`raw statfs rc=0` は、実測した生番号(x86_64 の 137 / aarch64 の 43)が実際にカーネルの
statfs エントリに届いたことを意味する。

### センサス再生成後に残ったギャップ

4 本とも Gap candidates 表から消えた。残るのは性質別に:
**他プラットフォーム分岐**(`WinNT.h`・`windows.h`・`os2.h`・`AvailabilityMacros.h`・
`port.h`・`mbarrier.h`・`sys/event.h` 等)、**ホストライブラリが供給**(`mysql*`・
`openssl/*`・`yaml.h`・`zlib.h`)、**SIMD ゲート**(`arm_neon.h`・`cpuid.h` 等)、
**言語機能待ち**(`stdatomic.h` = `_Atomic`、`stdckdint.h` = `ckd_*`。どちらも README の
既知の制限)、**カーネル UAPI**(`linux/types.h`・`linux/fs.h`・`linux/aio_abi.h`)。
**Linux/POSIX の実需で残っているのは `utime.h`(nkf)と `regex.h`(oj、既知の制限)程度**。

---

## Step 143 — 人気 gem スキャナの整備とアセンブラ検出(M5 H6)

Step 119・139 のコーパス拡張は「人気ランキングを辿って `.gem` を落として中を見る」を
毎回手作業でやっており、手順が残っていなかった。それを `tools/scan_popular_gems.rb`
として道具にした。日本語の使い方は [`test/corpus/README.md`](../test/corpus/README.md)。

### R10 ゲートは再実装せず census.rb に委譲した

スキャナが独自に「C++ があるか」「configure 依存か」を判定すると、`rake corpus:census`
と**別々に劣化する 2 つの判定**ができてしまう。そこで `Corpus::Census` の
`fetch_gem` / `unpack_gem` / `ext_cpp_files` / `read_extconf` / `configure_dependency?` /
`ext_source_files` を呼ぶだけにし、`test/corpus/census.rb` は 1 行も触っていない。
スキャナが「候補」と言った gem は、コーパスに入れた後のセンサスでも同じ判定になる。

### 実走で見つけた設計の穴 — R10 通過 ≠ ビルド可能

初回の試走で **bcrypt が「追加候補」として報告された**。Step 139 では人手で除外して
いた gem である。原因は R10 のゲートが構造的にアセンブリを見ないこと:
R10 は「純 C 拡張か」の判定であって「rubycc がビルドできるか」ではなく、
**アセンブラバックエンドが無いのは rubycc 固有の制約**だから、R10 の関心事の外にある。
委譲した以上、この検査はスキャナ側の責務になる。

検査は 2 本立てで、**片方だけでは漏れる**ことを実測で確認した:

| gem | `.S`/`.s` ファイル走査 | `$objs` の未対応エントリ |
|---|---|---|
| ffi 1.17.4 | 48 本(`ext/ffi_c/libffi` 配下)で検出 | `$objs` に一切現れず **検出できない** |
| bcrypt 3.1.22 | `ext/mri/x86.S` で検出 | `x86.o` に `x86.c` が無く検出 |

ffi は「同梱しているが `$objs` に出ない」側、`$objs` チェックは「生成される・名前の違う
アセンブリ」側を押さえる。着手前は「bcrypt は `$objs` でしか見えない」と見込んでいたが、
**実測では bcrypt は両方に引っかかった**(`.S` が `ext/` 直下にある)。想定と違ったので
コード側のコメントも実測に合わせて書き直した。

`extconf.rb` は**実行せずテキストとして読む**。`$objs = %w(...)` / 配列リテラル /
`<<` `+=` `.concat` の追加代入を静的に拾い、各 `<base>.o` に対応する `<base>.c` が
gem ツリー内に無いものを報告する。任意の gem の extconf を実行するのは、この用途
(候補の絞り込み)に対して代償が釣り合わない。

検出された gem は `[1]`(追加候補)ではなく **`[1b]`(要確認: アセンブラが必要)** に
分類する。除外(`[2]`)にしないのは、R10 としては通っているという事実を歪めないため。

### ランキング取得元と、黙って嘘をつかないための自己検証

`https://rubygems.org/releases/popular` は **100 gem(10 ページ)でハードキャップ**され、
11 ページ目以降は**ページ 1 を黙って返す**。これを踏まなければランク 101〜200 を
スキャンしたつもりで 1〜10 を再検査するだけになる。そこでページが自己申告する
ランク範囲(`data-testid="entries-info"`)を毎回照合し、要求と食い違えば止める。
ランク 100 超は bestgems.org(全期間 DL 数、20 gem/ページ)にフォールバックする
(`SCAN_SOURCE=auto` が既定)。HTML のパースが 0 件になった場合も**空リストを返さず
例外にする**: 「人気 gem に C 拡張は無い」という結論が静かに出るほうが有害だから。

### 実測で分かった運用上の性質

- **ffi は現在 rubygems.org の人気 100 位に入っていない**(走査で確認)。ランキングは
  日次で動くので「ランク N に gem X がいる」形の再現手順は経年劣化する。検証は
  ランク指定ではなく gem 名指定(`inspect_gem` の直接呼び出し)で行った。
- bestgems.org は検証時点でサイト障害(Cloudflare 522)。外部ランキングは単一障害点に
  なるため、`auto` のフォールバックは片方が落ちても 100 位以内なら動く構成になっている。
- ランク 1〜20 の走査結果: C 拡張持ちは 2 件だけ(nokogiri = configure 依存で `[2]`、
  json = コーパス内で `[3]`)。**上位ほど純 Ruby gem が多い**ため、コーパス拡張の
  実入りはむしろランク 100 以降にある。

---

## Step 144 — gem 本体テストの実走ツールと verified_gems.json の生成経路(M5 H6)

`data/README.md` は当初から「長期的には手編集ではなくコーパスの結果から生成/拡張したい」と
書いていたが、実態は Step 54 以来ずっと手編集だった。それを `tools/verify_gem_tests.rb` に
した。scratch GEM_HOME への `RUBYCC=1 gem install` → rubycc が使われた痕跡の確認 →
上流タグ tarball の取得 → ビルド済み `.so` の差し込み → gem 自身のテストスイート実走 →
サマリ行の実測パース → `--update` で DB へ、という一本道。

### 中心にあるのは sanity チェック(合格するテストが嘘をつく)

このツールで一番重要なのは、テストを走らせる仕組みではなく **走らせる前のゲート**である。
C 拡張がロードされず純 Ruby のフォールバックや処理系同梱の別コピーが使われた状態でも、
**テストスイートは合格する**。その状態で記録を書けば「rubycc で検証済み」という
虚偽が DB に入る。

これは仮説ではなく**実測で確かめた**: racc の `cparse.so` を壊した状態でスイートを走らせると
**71 tests / 320 assertions / 0 failures / 100% passed** になる。純 Ruby ランタイムに
落ちているだけで、rubycc は 1 バイトも関与していない。同じ状態で sanity は
`the injected extension was not loaded: .../cparse.so` で落ちる。

そこで `sanity` 式を**レシピの必須フィールド**にし、無いレシピは実行を拒否する。
検査は 2 段構え:

1. **全 gem 共通**: 差し込んだ `.so` の realpath が子プロセスの `$LOADED_FEATURES` にあるか
   (= 別のコピーではなく *この* ビルドが読まれたか)
2. **gem 固有**: 純 Ruby フォールバックが勝っていないか。
   json は `JSON.parser.to_s == "JSON::Ext::Parser"`(`lib/json/ext.rb` が
   TruffleRuby 向けに純 Ruby generator を持つ)、racc は
   `Racc::Parser::Racc_Runtime_Type == "c"`(`lib/racc/parser.rb` が
   `require 'racc/cparse'` を `rescue LoadError` して勝者をこの定数に記録する)

msgpack / redcarpet / bigdecimal / date には「C か否か」の観測点が無い(MRI では
フォールバックが存在しない)。この 4 つは 1 のみ。ただし **date は default gem、
bigdecimal は同梱 gem** で「別のコピーが読まれる」危険は実在するので、1 が空振りの
チェックにはなっていない。

### rubycc が使われた証明

install が成功しただけでは不足で、gcc に落ちていた可能性が残る。RubyGems が残す痕跡
2 つを**両方**必須にした: `gem_make.out` の `$(MAKE)` が rubycc の `exe/rmake` であること、
生成された Makefile の `CC` が `exe/rubycc` であること。
**`mkmf.log` は必須にできなかった** — redcarpet と racc は extconf に probe が無く
mkmf.log を書かない(実測)。あれば追加証拠として報告するに留めている。

### 上書きしてはならない 2 つの欄

- **`notes`** は既存を保持する。機械が観測できない但し書き(racc の
  「`lib/racc/parser-text.rb` を手で供給した」)が入っており、再実行では復元できない。
  新規エントリで `--notes` 省略時は既定値を入れたうえで「notes は人間の責務」と警告する。
  例外は skip / pending / omission の件数で、これは実測なのでツールが事実文を追記する
  (既存の散文が同じ件数に言及していれば重複させない = bigdecimal の 11 omissions)。
- **`evidence`** は**追記**する(初版レビューで上書き実装だったのを是正)。この欄は
  確認したステップの履歴を溜める場所で、json は Step 54・61・64、msgpack は Step 138 の
  H4 の 1 文を持つ。今日の実走が証明するのは今日測った事実だけで、過去の確認が
  無かったことにはならない。上書きすれば再実行で復元できない部分が黙って消える。

### 書式を守るために独自エミッタを書いた

`JSON.pretty_generate` は `["2.21.1"]` を 3 行に展開するため、1 gem 更新するだけで
**既存 6 件すべてが差分**になり、レビューで意図した変更が埋もれる。インデント 2 ・
`versions` はインライン配列という既存の書式で出す小さなエミッタを持たせた。
実測で、redcarpet 1 件の更新の diff は `verified_at` と `evidence` の 2 行だけになる。

### 自分自身の検証 = 既存 6 件の再現

このツールの信用は「既存の記録を再現できるか」で立つ。**6 件すべてを実走**した:

| gem | 実測 | 既存記録 |
|---|---|---|
| redcarpet 3.6.1 | 136 tests / 206 assertions / 0 failures | 一致 |
| json 2.21.1 | 606 tests / 3,433 assertions / 0 failures | 一致 |
| msgpack 1.8.3 | 455 examples / 0 failures / 1 pending | 一致 |
| bigdecimal 4.1.2 | 265 tests / 8,267 assertions / 11 omissions | 一致 |
| date 3.5.1 | 143 tests / 162,593 assertions / 0 failures | 一致 |
| racc 1.8.1 | 71 tests / **320** assertions / 0 failures | tests は一致、**assertions が +1**(記録は 319) |

**racc の +1 は原因が特定できていない**。潰した仮説: 実行ごとのゆらぎ(2 回とも 320)、
test-unit-ruby-core のバージョン差、`-rhelper` の有無、`--enable-frozen-string-literal`、
load path を installed gem 側にする — いずれも 320。ファイル別内訳
(12+28+1+4+238+25+12)も 320 で内部整合している。Step 99 の記録側が別条件だったのか
転記の誤りなのかは**不明のまま**。判定に関わる数(71 tests / 0 failures / 0 errors)は
一致しているので DB はこのステップでは書き換えず、次に racc を `--update` したときに
両方の測定が日付付きで evidence に並ぶのに任せる。

### 実測で分かったこと

- **json に `JSON_DISABLE_SIMD=1` は不要だった**。`tools/m2_acceptance.rb` はホスト gcc で
  extconf を走らせるためフラグが要ったが、`RUBYCC=1 gem install` 経路では
  conftest 自体が rubycc を通るので **SIMD probe が自然に偽化する**(DB の既存 notes が
  Step 60 で述べていたとおり)。経路が違えば必要な配慮も違う、という実例。
- **date の `test-unit-ruby-core` load path 追加は、実測では無くても通った**。scratch
  GEM_HOME に入っていれば RubyGems の require フォールバックが解決する。レシピには
  その依存を断つ保険として残してある。
- サマリ行が読めなかった場合を `:unparsable` として**合格とも不合格とも断定しない**
  第 3 の状態にした。終了コードだけを信じて合格にするのが最も危ない。
  逆に、サマリが 0 failures なのに子プロセスが非ゼロ終了した場合は**不合格**にする
  (フレームワークの外で何かが壊れており、その実行は検証を勝ち取っていない)。

`test/test_doctor.rb` の許可リストは**自動編集しない**。DB のキー集合と食い違ったら
貼り付け用の `assert_equal %w[...]` 行を表示して警告するだけに留めている
(gem の追加を意識的な編集に留めるための意図的なゲート)。

---

## Step 145 — コーパス拡張ワークフローのスキル化(M5 H6)

Step 143(スキャナ)と Step 144(テスト実走・DB 更新)で道具は揃ったが、**道具の間を
つなぐ判断**が会話の中にしか無かった。`[1b]` に落ちた gem をどう扱うか、Gap candidate の
どれを埋めてどれを埋めないか、`verified_gems.json` に書いてよい証拠の水準は何か —
これらは道具の usage には書けない。`.claude/skills/corpus-expansion/SKILL.md` に集約した。

### 何を書き、何を書かなかったか

書いたのは**判断の基準**であって手順の反復ではない:

- **Gap candidate の仕分け表** — 「Linux/POSIX の実需だけ埋める」。他プラットフォーム分岐・
  ホストライブラリ供給・SIMD ゲート・言語機能待ち・カーネル UAPI は埋めない。
  この分類は Step 140・142 のセンサス再生成で実際に手を動かして固まったもの
- **(d) レベルの証拠しか DB に書かない** — 「ビルドできた」「`gem install` が成功した」は
  不十分で、gem 自身のテストスイート合格だけが根拠になる
- **sanity 式の選び方** — 純 Ruby フォールバックの観測点があるか、無ければ
  `$LOADED_FEATURES` を見る。`require` の成功は証拠にならない
- **測ってから書く** — epoll / statfs / `__fsid_t` で予想が 3 回覆った事実を根拠として
  明記。あわせて「`rubycc -E` が通ることは正しさの証明にならない」も

書かなかったのは、道具の man page 的な説明(それは `test/corpus/README.md` と
`data/README.md` の担当)と、R8 の全文(`docs/HEADER-LICENSING.md` §6 が正典で、
スキルは「§6 をプロンプトに要約して渡せ」と指すだけ)。**同じ内容を 2 箇所に書けば
必ず片方が腐る**ので、スキルは判断だけを持ち、事実は既存文書を指す。

### 横断規約を毎回書かなくてよくする

R11 の移譲プロンプトへの明記、テスト実行の test-runner への委譲、日本語出力、
1 ステップ 1 コミット、STEPS.md / ROADMAP.md の更新 —
これらは CLAUDE.md と役割表にあるが、**このワークフローの各段階でどれが効くか**は
毎回思い出す必要があった。スキル冒頭の「全フェーズ共通の規約」にまとめてある。

---

## Step 146 — stackprof / nkf の検証試行と、そこで見つかった 6 つのギャップ(M5 H6)

Step 144 の道具でコーパス中最小級の 2 gem を検証しようとした。**どちらも FAIL**。
`data/verified_gems.json` には**何も書いていない**。だがこのステップの成果は
その否定的結果そのもので、**最小再現の付いた 6 つの実在するギャップ**が出た。
6 件はそれぞれ Steps 147〜152 で解消しており、各ステップの記録が
「Step 146 のギャップ表の N 番」として個別の詳細を持つ
(未解消のギャップの一覧は docs/GAPS.md)。

### 「rubycc が悪いのか環境が悪いのか」を先に切り分けた

stackprof は `setitimer` / `SIGPROF` / `rb_profile_frames` に依存しており、
WSL2 のこの環境でシグナル周りが動かない可能性が先に疑われた。**ホスト gcc で
同じ上流ツリーをビルドして同じスイートを走らせる**対照を取り、
stackprof は 31 runs / 143 assertions / 0 failures、nkf は 8 tests / 46 assertions /
0 failures で完走した。**環境要因は否定され、原因は全て rubycc 側**と確定した。
この対照が無ければ「WSL2 では検証できない」で終わっていた。

### 最も価値が高いのは、一番地味な 1 番

`sigset_t` の typedef 衝突は**この 2 gem に固有の問題ではない**。
`include/libc/signal.h` はガード `_RUBYCC_SIGSET_T` で無名 struct を、
`include/libc/glibc/{x86_64,aarch64}/sys/select.h` はガード `__sigset_t_defined` で
`__sigset_t` + エイリアスを定義しており、**ガードが噛み合わないうえ型そのものが別物**。
`ruby/defines.h` が `<sys/select.h>` を引くので、**ruby.h と `<signal.h>` を併用する
任意の gem** が踏む。両方の include 順で再現する(select→signal は signal.h:47 で、
signal→select は select.h:38 で落ちる)。

同梱ヘッダを 77 本まで増やしても、**ヘッダ同士の整合はセンサスでは測れない**。
センサスは「その名前のヘッダがあるか」しか見ないので、
2 本が同じ型を別々に定義している状態を検出できない。実際の gem をビルドして初めて出る。

### 2 番は既にある機構が繋がっていないだけ

nkf が落ちる `enum {len = sizeof(str) - 1};` は、リゾルバ `Parser#fold_time_sizeof` が
**既に存在していて `_Static_assert` と配列長では渡されているのに**、
enumerator・ビットフィールド幅・case ラベル・配列デシグネータで `sizeof_expr:` が
未指定なだけ。「機能が無い」のではなく「配線が抜けている」型のギャップで、
最小再現(`enum { a = sizeof(int) };` は通るが `enum { len = sizeof(str) };` は通らない)が
それを端的に示している。

### ハンドパッチ実験は「残りが無いこと」の確認に使い、記録には使わない

1〜5 を scratch 内のコピーだけで塞ぐと**両 gem とも上流スイートが完走する**。
これは「このギャップ群の裏にさらにブロッカーが控えていないか」を先に知るための
偵察であって、**検証ではない**。特に `__dso_handle` はスタブ(`void *__dso_handle = 0;`)で
代用しており glibc の意味論(DSO 自身のハンドル)と違う — テストが `__cxa_atexit`
経路を踏んでいないだけの可能性がある(未実測)。したがってこの結果は
`verified_gems.json` に**書いていないし、書いてはならない**。

### レシピを残す判断

両 gem のレシピは `tools/verify_gem_tests.rb` に**入れたまま**にした。
`--all` がこの 2 件だけ FAIL を出し続ける状態が、そのまま**生きた TODO リスト**になる。
修正後にレシピを書き起こすことにすると、いちばん切り分けが要る場面で
「レシピが悪いのか修正が足りないのか」が混ざる。

### 副産物: コーパスの note の誤り

`test/corpus/gems.rb` の stackprof の note が「extconf.rb 16 lines **with no probes**」と
書いていたが、実物は `have_func('rb_postponed_job_preregister')` ほか 4 つの probe を持ち
mkmf.log も生成する。Step 139 でメタデータだけ見て書いた記述で、実際にビルドして初めて
食い違いが出た。是正済み。

---

## Step 147 — `sigset_t` の typedef 衝突の解消(M5 H6)

Step 146 のギャップ表の 1 番。`include/libc/signal.h` と
`include/libc/glibc/{x86_64,aarch64}/sys/select.h` が**同じ `sigset_t` を別々のガード名・
別々の型で定義していた**。`signal.h` 側を `sys/select.h` と**文字どおり同一**
(ガード `__sigset_t_defined`、`__sigset_t` + エイリアス)に揃えた。
`sys/select.h` は既にこの形だったので無変更。

レイアウトは元から実質同一(LP64 で `1024/(8*sizeof(unsigned long))` = 16、128 バイト)で、
**壊れていたのはガード名と綴りだけ**だった。ABI の値は 1 つも動いていないので
由来台帳(§3.3)と集計は変更なし。

### 同種の欠陥が他に無いことを機械的に確かめた

1 本直して終わりにすると、同じ形の地雷が残っているかどうかが分からない。
同梱ヘッダ全体を走査して「**同じ型名が 2 つ以上の異なるガードの下で定義されている箇所**」を
洗い出した。実ケースは **`sigset_t` ただ 1 件**。ほかに 2 件挙がったが
(`sa_family_t` @ `sys/un.h`、`size_t` @ `alloca.h` / `strings.h`)、いずれも
**ファイル全体のガードを内側のブロックのガードと二重に数えた誤検出**で、
実物は内側で `_RUBYCC_SA_FAMILY_T` / `_RUBYCC_SIZE_T` に正しく統一されていた。

### センサスでは絶対に見つからない種類の欠陥

これはヘッダの**有無**ではなく**相互の整合**の問題なので、
`rake corpus:census` は原理的に検出できない(「その名前のヘッダがあるか」しか見ない)。
ABI ハーネスも、従来は 1 Spec = 1 ヘッダで、`sys/select.h` 単独・`signal.h` 単独では
どちらも正常に通ってしまう。**2 本を同時に include して初めて出る**。

そこで `Spec` の `also:`(追加 include)を使い、**両方の include 順**を別々のケースにした:

- `SIGSET_SELECT_FIRST` — `sys/select.h` → `signal.h`
- `SIGSET_SIGNAL_FIRST` — `signal.h` → `sys/select.h`

順序を 2 つとも押さえるのは、修正前が**順序ごとに違う行で落ちていた**からである
(select→signal は `signal.h:47`、signal→select は `sys/select.h:38`)。
片方だけでは片方向のガード漏れを見逃す。
どちらの Spec も `sizes: %w[sigset_t __sigset_t]` を検査するので、
**レイアウトの一致だけでなく綴りが glibc と一致していること**も同時に確かめている。
snippet では `fd_set` と `sigset_t` を同じ関数の中で使い、両ヘッダの宣言が
同時に生きていることを証明している。

### 修正前後の対照を取った

「テストが通る」だけでは、そのテストが元の欠陥を捉えているかは分からない。
`git stash` で `signal.h` だけ修正前に戻して 2 本の再現 C をコンパイルし、
**修正前は両方とも `redefinition of typedef 'sigset_t'` で落ち、修正後は両方通る**ことを
実測した。2,564 → **2,568 runs**(新規 4 メソッド)/ 0 failures / 47 skips で、
新規 4 件が skip されず実際に走っていることも確認済み。

---

## Step 148 — `sizeof <式>` を全ての整数定数式文脈で畳む(M5 H6)

Step 146 のギャップ表の 2 番。`enum { a = sizeof(int) };`(型オペランド)は通るのに
`enum { len = sizeof(str) - 1 };`(**式オペランド**)は落ちていた。
同じ症状がビットフィールド幅・case ラベル・配列デシグネータでも出た。

### 機能の欠落ではなく配線漏れだった

リゾルバ `Parser#fold_time_sizeof` は**既に存在していた**。
`ConstantEvaluator` は型テーブルを持たないので `sizeof <式>` を単独では畳めず、
パーサが `sizeof_expr:` キーワードでリゾルバを渡す設計になっている。
ところが渡していたのは `_Static_assert`(Step 113 で追加)と配列長の **2 箇所だけ**で、
ほかの整数定数式文脈は素の `ConstantEvaluator` を呼んでいた。

配線したのは 6 箇所。いずれも C 標準が整数定数式または定数式を要求する:

| 文脈 | 根拠 |
|---|---|
| enumerator の値 | C 6.7.2.2p2 |
| ビットフィールド幅 | C 6.7.2.1p4 |
| 配列デシグネータ | C 6.7.9p6 |
| case ラベル | C 6.8.4.2p3 |
| `aligned` 属性の引数 | GNU 拡張(配列長と同じ扱い) |
| `__builtin_choose_expr` の第 1 引数 | 定数式 |

### 意図的に据え置いた 1 箇所

**グローバル変数の初期化子(`parser.rb:513`)は変更していない。**
その直前に `!references_sizeof_expr?(init)` というガードがあり、
`sizeof <式>` を含む初期化子は**ジェネレータ側へ回されている**。
ジェネレータは完全なシンボルテーブルを持つので、パーサ時解決より強い
(`(size_t)&((T*)0)->m` の offsetof イディオムも同じ経路に乗る)。
「同じものだから同じように直す」で手を入れると既存の設計判断を壊す側の変更になる。
**同じ症状に見えても、より良い解決経路が既にあるなら触らない**。

### テストが欠陥を捉えていることを確かめた

「テストが通る」だけでは、そのテストが元の欠陥を捉えているかは分からない。
`git stash` でパーサの変更だけ退避して追加した 4 件のパーサ単体テストを走らせ、
**4 件とも修正前の欠陥どおりのメッセージで失敗する**ことを確認した
(`enumerator value is not an integer constant` ほか)。Step 147 と同じ作法。

実行オラクルは 4 文脈を 1 プログラムにまとめて gcc 差分で検証している。
enumerator には nkf 実物のイディオム `len = sizeof(str) - 1` をそのまま入れた。

退行防止も入れた: `sizeof(未宣言名)` は `sizeof_operand_type` が nil を返して
`NotConstant` になり、**従来どおり診断が出る**(黙って誤った値にならない)。
これは想定どおりだった。

---

## Step 149 — pthread 宣言 2 本と `_POSIX_MONOTONIC_CLOCK`(M5 H6)

Step 146 のギャップ表の 3 番と 4 番。どちらも既存ヘッダへの追加で、
**新規ファイルは無いので由来台帳(§3.3)と集計(§3.4)・NOTICE は変更不要**
(不要であることを確認したうえで手を付けていない)。

### `_POSIX_MONOTONIC_CLOCK` の実測値は 0 だった

「対応しているなら正の値」と読みたくなるが、**実測は `0`**(x86_64・aarch64 とも一致)。
POSIX のオプションマクロの流儀で、0 は「この実装は対応するが、
実際に使えるかは `sysconf(_SC_MONOTONIC_CLOCK)` で実行時に確認せよ」を意味する。
**推測で正の値を書いていたら glibc と食い違っていた**。

stackprof がこれを必要とするのは `#ifdef` で分岐しているためで、
値そのものは使っていない。**未定義だと上流の死にコードである `#else` 側を通り、
そこに本物の構文エラー(セミコロン欠落・未定義変数)がある** —
つまりこのマクロを定義しない処理系では stackprof はそもそもビルドできない。

`_POSIX_*` を**網羅しない**判断は `sys/syscall.h` と同じ
(消費者のいない巨大な実測面はリリースごとの再計測を招く)。
そのうえで**コーパスが実際に参照している `_POSIX_*` を走査**した:
`_POSIX_TIMERS`(nio4r/libev)は `#if !(_POSIX_TIMERS > 0)` の形で
**未定義でも 0 扱いで安全にフォールバック**するので死にコードにならない。
`_POSIX_C_SOURCE` / `_POSIX_VERSION` は呼び出し側が定義する feature-test マクロで
libc ヘッダが供給するものではない。`_CS_POSIX_V7_*` は `confstr()` 用の別名前空間。
**「未定義だと壊れる」実需は `_POSIX_MONOTONIC_CLOCK` だけ**だった。

### `pthread_kill` は glibc では `<signal.h>` 側にいる

実測で分かったこと: ホスト glibc は `pthread_kill` を `<pthread.h>` 単独では宣言せず、
`<signal.h>` 経由でのみ公開する。rubycc の同梱ヘッダは**フラットな面を出す方針**
(`sys/stat.h` の `st_atim` を無条件に出しているのと同じ)なので `pthread.h` に置いた。
ABI ハーネスの `PTHREAD` Spec は既に `defines: ["_GNU_SOURCE"]` を持っており、
オラクル側でも同じ面が見えるので比較は成立する。

シグネチャは**関数ポインタ代入 + `-Werror=incompatible-pointer-types`** で測った
(型が食い違えばエラーになる仕掛け)。両アーキで一致。

### `pthread_atfork` は宣言してもリンクは通らない

これは承知のうえで入れた。glibc では共有 libc に無く `libc_nonshared.a` からのみ
供給され、そのメンバが `__dso_handle` を参照するため、rubycc のリンカが
`unsupported text relocation against external symbol '__dso_handle'` で落ちる
(ギャップ 6 番)。**この追加の効果は「コンパイルエラーがリンクエラーに変わる」
= 誤りの所在が正しくなること**であり、stackprof が動くようになるわけではない。
ヘッダのコメントとハーネスのコメントの両方にその旨を書いた
(ハーネス側は「ここで本当にリンクさせてはならない」という既存の
`sizeof(...)` 非評価の作法の理由と併せて)。

実測で確認したとおり、stackprof の失敗は**コンパイル段階からリンク段階へ移った**。
5 番(不完全配列型)は nkf 固有なので stackprof には現れない。

### テスト数が増えないケースの追加

`PTHREAD` / `UNISTD` の**既存 Spec を拡張**したので、新しいテストメソッドは無く
runs も assertions も変わらない(`assert_abi_matches` が 1 ケース = 1 assertion)。
検査項目は増えているが、それは runs には現れない。**「テストが増えていないから
検証していない」ではない**ことを記録しておく。

---

## Step 150 — 合成型(C11 6.2.7p3)による不完全配列型の補完(M5 H6)

Step 146 のギャップ表の 5 番。`extern int tbl[]; int tbl[3] = {1,2,3};` が
`conflicting types` で落ちていた。原因は宣言のマージが**厳密な型等価**で
判定していたことで、`Array(int, nil)` と `Array(int, 3)` は等しくない。
C11 6.2.7p3 は「一方が既知サイズの配列型、他方がサイズ未指定なら、
**合成型は既知サイズのほう**」と定めている。

### 規則を 1 箇所に置いた

`Type.composite(first, second)`(`lib/rubycc/type.rb`)を新設し、
非互換なら nil を返す形にした。型どうしの関係だけで決まる純粋な型システムの操作で
IR 生成の文脈に依存しないため、既に型同一性と `Type.character?` を持つ type.rb が
馴染む場所になる。generator 側は `composite_declaration_type` 1 つを介して呼ぶだけで、
**同じ条件式が 4 箇所にコピーされる形を避けた**。

配列以外は「同一なら合成可、そうでなければ非互換」で、これは修正前の等価比較と
**意味が一致する**(振る舞いの保存が読み取りやすい)。要素型へ再帰するので
多次元(`extern int m[][4];` 対 `int m[2][4]`)が自然に通り、
内側の次元は必ず既知なので食い違えば従来どおりエラーになる。

### 4 つの比較箇所のうち 1 つには適用しなかった

`declare_function` の比較は関数の戻り値型と仮引数型が対象で、
**配列型はここに到達しない** — C は配列の返却を禁じ、パーサが配列仮引数を
ポインタへ調整する(`parser.rb` の `adjust_parameter_type`)。
6.2.7p3 の残りの規則(プロトタイプ有無の合成)はこのサブセットが未モデル化なので、
等価比較のまま残した。**理由をコードのコメントに書いた**:
「同じ形の比較だから同じように直す」は、ここでは誤りになる。

### 宣言順を両方確かめた理由

不完全型が完全型を**上書きしてしまう**と、以降の `sizeof(tbl)` や添字計算が壊れる。
そこで両方の順(`extern` が先 / 定義が先)を実測し、**バインディングに残るのは
常に完全なほう**であることを確かめた。実行オラクルに `sizeof` を印字させているのは
まさにこのため — 型が壊れていれば値が変わる。

### 実測で分かった、残る gcc との差

`extern int tbl[3]; int tbl[] = {1,2};` は **gcc は受理して `sizeof` を 12 にする**
(先の宣言の境界が合成型として勝ち、初期化子は部分初期化になる)。
rubycc は `conflicting types` のまま。rubycc ではパーサと `InitializerResolver` が
初期化子から長さ 2 を確定させた後に generator が見るため、
「両方とも長さ既知で食い違い」に見える。対応するには「宣言された長さが初期化子由来か」を
AST に持たせ、合成型に対して初期化子を再解決する必要がある。
**nkf が使うのは逆順**(不完全 → 初期化子推論の定義)なので、今回は未対応とした。

スコープ外として据え置いたもの: ファイルスコープの仮定義 `int tbl[];`
(`extern` なし・初期化子なし)は C 6.9.2p2 で要素数 1 に補完されるが、
`array size missing` のまま(nkf は必要としない)。

### 結果

**nkf 0.3.0 が PASS した** — sanity ok、8 tests / 46 assertions / 0 failures。
Step 146 で立てた 6 つのギャップのうち 1〜5 が閉じ、nkf は完全に通った。
記録は Step 151。

---

## Step 151 — nkf 0.3.0 を検証済みに記録(M5 H6)

`data/verified_gems.json` が **6 → 7 件**。Step 144 で作った経路で
**初めて新規に追加された gem**で、ここまでの一連の作業(143 スキャナ →
144 実走ツール → 145 スキル → 146 ギャップ特定 → 147〜150 修正)が
初めて 1 本の線としてつながった。

### 経路そのものが検証された

これまでの 6 件は Step 54〜104 で人手で確認したものを後から DB に書き写したもので、
Step 144 のツールは**既存記録の再現**でしか自身を証明できていなかった。
今回は逆で、**ツールが「PASS」と言ったから記録した**。
手編集は 1 文字もしていない(`--update --step 151` のみ)。
差分は nkf のエントリ 8 行だけで、既存 6 件の行は 1 行も動いていない —
Step 144 で独自エミッタを書いた狙いがそのまま効いている。

### notes に機械が書けないことを書いた

ツールが自動生成するのは `evidence` / `environment` / `verified_at` だけで、
`notes` は人間の責務(Step 144 の設計)。今回書いたのは 3 点:

1. **nkf は Ruby にバンドル gem として同梱されている**ので、この検証が
   処理系同梱のコピーではなく**差し込んだ rubycc ビルドの `.so`** に対するもので
   あること(sanity が `$LOADED_FEATURES` で確認している)。
   これを書かないと、読んだ人は「本当に rubycc のビルドを試したのか」を
   記録から判断できない
2. **Step 150 の合成型(C11 6.2.7p3)が必要だった**こと。
   `nkf-utf8/utf8tbl.c` が `extern const unsigned short euc_to_utf8_1byte[];` の
   前方宣言と、初期化子で境界が決まる定義の組み合わせを使っている。
   **どのコンパイラ機能に依存した合格なのか**は再現条件そのもの
3. **musl と aarch64 は未検証**(既定 notes の趣旨を残した)

いずれも実測結果からは導けない。ツールが notes を上書きしない設計にしてあるので、
次に nkf を `--update` してもこの 3 点は残る。

### 許可リストは手で更新した

`test/test_doctor.rb` の `assert_equal %w[...]` にツールは触らない(意図的なゲート)。
貼り付け用の行を表示するだけで、実際の編集は人間が行う。
「gem が増えたら DB もテストも自動で追随する」構成にすると、
**誤って増えたときにも自動で追随してしまう**。

---

## Step 152 — `__dso_handle` の合成(M5 H6)

Step 146 のギャップ表の 6 番。`pthread_atfork` は共有 libc に無く
`libc_nonshared.a` の `pthread_atfork.oS` からのみ供給され、そのメンバが
`__dso_handle` を参照するため `unsupported text relocation against external symbol` に
なっていた。gcc では crt ファイル(`crtbegin_S.o`)が供給しており rubycc に相当物が無い、
というのが穴の正体。

### 実測してから設計した

`gcc -shared -fPIC` の出力を `readelf` で観測した事実(**crtstuff.c は読んでいない** — R11):

- `__dso_handle` は **`.data` 先頭の OBJECT シンボル**で、`.dynsym` には出ない
- **中身は自分自身のアドレス**(`.data` の 8 バイトがシンボル自身のアドレス)
- **`R_X86_64_RELATIVE` が 1 本**付き、offset と addend がともにそのアドレス
- 参照側は `R_X86_64_PC32 __dso_handle - 4`。gcc のリンクではローカルに定義されて
  いるので**内部参照として解決され、text relocation にならない**

値が自分自身のアドレスでなければならない理由も設計に効く: `__dso_handle` は
`__cxa_atexit` / `__register_atfork` に「どの DSO からの登録か」を伝える不透明な
クッキーで、**0 にすると主実行ファイルを名乗る**ことになり、`dlclose` 時の
ハンドラ処理が壊れる。**DSO ごとに一意なアドレス**であることが要件。

### 新しい機構を作らず、既存の 2 つをそのまま使った

素直に書けば「リンカが特別扱いでシンボルを 1 本足す」になるが、そうしていない:

1. **供給元を「1 メンバのアーカイブ」にして全リンクの末尾に足す**。
   `ar` の**遅延メンバ抽出がそのまま「未定義のときだけ供給」の条件**になる。
   参照が無ければメンバは取り込まれず、**既存の出力はバイト単位で変わらない**。
   入力側が自分で `__dso_handle` を定義していればそちらが勝ち、重複にもならない。
   ドライバがコンパイラサポートランタイムを足すのと同じやり方に揃えた
2. **自己参照を普通の絶対 64 ビットリロケーション(`R_X86_64_64` /
   `R_AARCH64_ABS64`)で表す**。既存の適用エンジンが、共有オブジェクトでは
   `rebase_internal?` によって **RELATIVE 1 本を出す** — 実測した gcc の出力そのもの。
   実行ファイルでは固定アドレスなので RELATIVE は出ない。**アーキ差も
   共有/実行ファイルの差も、既存の分岐が勝手に面倒を見る**

条件分岐を新設しないほうが、後から壊れにくい。

### LOCAL ではなく GLOBAL HIDDEN

着手時の想定は「gcc の出力が LOCAL なのだから LOCAL で作る」だったが、**それでは
動かない**。供給元が別オブジェクトである以上、**LOCAL シンボルは他オブジェクトの
未定義参照を解決できない**。HIDDEN の GLOBAL なら、マージ中は参照を解決でき、
かつ `.dynsym` には出ない(エクスポートは default/protected だけ)。
参照側の `libc_nonshared.a` のメンバ自身も `__dso_handle` を GLOBAL HIDDEN の
未定義として持っている。**実測した最終形(LOCAL)と、そこへ至る途中の形(HIDDEN)は
別物**で、再現すべきは前者ではなく「`.dynsym` に出ず、interpose されない」という性質。

### 供給しなかった半分を記録する

gcc の crt ファイルのもう半分 — **`__cxa_finalize(__dso_handle)` を呼ぶ
`.fini_array` エントリ**は合成していない。これは object がアンロードされるときに
glibc がこのハンドルで登録されたハンドラを落とすための仕掛け。
**登録側は無くても動く**(実測: rubycc が作った `.so` に対して手で
`__cxa_finalize(&__dso_handle)` を呼ぶと atfork ハンドラは確かに解除される =
ハンドルの値は正しい)が、**ハンドラを登録したまま `dlclose` された object は
アンマップされた領域を指すハンドラを残す**。合成には init/fini array のパイプラインが
要り、このリンカにはまだ無い。**「動いた」で済ませず、動いていない半分を書いておく。**

### 検証

追加は 14 件。単なる ELF の形の照合ではなく、**実際に動くこと**まで見ている:

- 合成された語が**自分自身のアドレスを指し、0 でない**ことを dlopen して読む
- **`pthread_atfork` を `libc_nonshared.a` 経由でリンクし、dlopen して
  実際に fork をまたいでハンドラが走る**(子インタプリタで実行 — fork ハンドラの
  登録は object がロードされている間プロセス全体を変えてしまうため)
- **参照が無ければ何も増えない**(既存出力の不変)
- 入力が自分で定義していればそれが使われる
- aarch64 は qemu で同じ性質を確認、実行ファイル経路は RELATIVE が出ないことを確認
- 決定的ビルド(N4)が保たれること

### 結果

**stackprof 0.2.28 が PASS**(31 runs / 0 failures / 0 errors)。
Step 146 で立てた 6 つのギャップが**全て閉じた**。記録は Step 153。

---

## Step 153 — stackprof 0.2.28 を検証済みに記録(M5 H6)

`data/verified_gems.json` が **7 → 8 件**。実測 31 tests / 184 assertions /
0 failures / 0 errors。差分は stackprof のエントリ 8 行だけで、既存 7 件の行は
1 行も動いていない。

### notes に「合格の再現条件」と「保証していないこと」を書いた

この gem の合格は**コンパイラ側の 2 つの修正に依存している**ので、それを書かないと
記録が再現条件を語らないことになる:

- **Step 152 の `__dso_handle` 合成** — stackprof が `pthread_atfork` を呼び、
  それは glibc の共有 libc に無く `libc_nonshared.a` からのみ供給され、
  そのメンバが `__dso_handle` を参照するため
- **Step 149 の `_POSIX_MONOTONIC_CLOCK`** — 未定義だと上流の死にコードである
  `#else` 側を通り、そこに構文エラーがあるため

加えて、**合格が保証していないこと**も書いた: `.fini_array` から
`__cxa_finalize(__dso_handle)` を呼ぶ仕掛けが rubycc にまだ無いので、
この `.so` を `dlclose` した場合の atfork ハンドラの後始末は保証されない。
**テストスイートは `dlclose` しないので合格判定には影響しない** — だからこそ
「合格した」という事実だけを残すと、読んだ人はこの穴を知らないまま使うことになる。

### Step 146 からの一巡が閉じた

Step 146 で「両方 FAIL」という否定的結果から 6 つのギャップを立て、
147〜152 で全て潰し、151 と 153 で 2 gem を記録した。
**FAIL の切り分けに 1 ステップ使ったことが、以降 6 ステップの設計図になった。**
先にホスト gcc で対照を取って環境要因を否定していなければ、
「WSL2 では検証できない」で終わっていた。

---

## Step 154 — `.init_array` / `.fini_array` のリンカ側パイプライン(M5 H6)

Step 152 で「合成しなかった半分」として記録した init/fini array の整備。3 段階の 1 つ目で、
**今回はリンカ側だけ**(フロントエンドの `__attribute__((constructor))` と
`__cxa_finalize` の合成は後続)。

### 欠けていたのは動的タグ 4 本だけだった

着手時の想定は「マージも配置もリロケーションも全部作る」だったが、**実測すると
ほとんど既に動いていた**:

- `PartialLinker` の `SKIPPED_TYPES` は ARRAY 型を除外しておらず、マージは
  **セクション名**で連結するので `SHT_INIT_ARRAY` / `SHT_FINI_ARRAY` は素通りしていた
- 配置も、既存の `input_sections { writable? && !NOBITS }` が拾い、
  `writable_dynamic_sections` の前に置くので **gcc と同じ位置**に来ていた
- リロケーションも既存機構でそのまま済んだ。スロットの `R_X86_64_64` は
  `rebase_internal?` を通って RELATIVE になり、addend も対象関数のアドレスと一致していた
  (**修正前の状態で実測して確認**)

つまり欠けていたのは `DT_INIT_ARRAY` / `DT_INIT_ARRAYSZ` / `DT_FINI_ARRAY` /
`DT_FINI_ARRAYSZ` の 4 本だけ。dlopen 実測でも、修正前は初期化子が 0 個走り、
タグを出した途端に走った。**因果がこれ以上ないほど明確に切り分けられた。**

「全部作る」で着手していたら、既にあるものを二重に作っていた。

### 優先度は実測で規則を確定させてから実装した

gcc は `__attribute__((constructor(101)))` を `.init_array.00101` という
**別セクション**として出す。並べ方は binutils のソースを読まず、
**gcc に実際にリンクさせた `.so` の配列の中身と実走順を観測**して決めた:

- 番号付きが**昇順で先**、無番号が**入力順で後**
- **番号付きの昇順はオブジェクト境界をまたぐ**(2 オブジェクトで `b150, a300, adef, bdef`)
- `.fini_array` も同じ規則(ランタイムが逆走するので構築子と鏡像になる)

ソートキーは `[優先度, マージ順の添字]` にした。同順位が入力順を保ち、
**Ruby の sort が安定か否かに依存しない**(N4 の要請)。

### 3 つの「黙って間違える」経路を塞いだ

このセクションは**シンボル経由ではなく `DT_*_ARRAY` でアドレス範囲として**指されるので、
配置を間違えても誰も気付かないまま**関数ポインタ配列に穴が空く**。
そこで推測せず拒否する経路を 3 つ入れた:

1. **未知の suffix**(`.init_array.late` 等)— 位置を推測すれば初期化順が黙って狂うので `LinkError`
2. **`SHF_WRITE` の無い ARRAY セクション** — 読み取り専用セグメントに落ちて
   ランから抜け、初期化子ごと消える。gcc は必ず WA にするので、来たら拒否
3. **ランが非連続** — 隙間はゼロ = null 関数ポインタになり、ローダがそれを呼ぶ

### 実行ファイルでも動く理由は crt ではなかった

rubycc の `_start` は `__libc_start_main` に `init = NULL` / `fini = NULL` を渡す。
それでも構築子は走る — **配列を歩くのは crt ではなく動的ローダ**だから。
実測で確認した(`ctor` → `main:ctor-ran` → `dtor`)。
非 PIE なのでスロットには最終アドレスが直接書かれ、RELATIVE は出ない。

### デストラクタを「`dlclose` に紐づく」ところまで確かめた

終了子は**自分のメモリに結果を残せない**(直後に unmap される)。そこで `fopen` で
ファイルを残させ、子インタプリタが `dlclose` の**前後両方**で存在を検査する。
`1,false,true` になることで、プロセス終了時ではなく **`dlclose` そのもの**に
紐づいていることまで示せている。

### 想定と違った実測

グローバル関数の構築子を gcc で `.so` にすると、スロットは RELATIVE ではなく
**シンボル付き `R_X86_64_64`** になる(グローバル関数は差し替え可能なため)。
`.init_array` の hex dump がゼロに見えるのはこのため。rubycc 側の意味論
(内部シンボルは RELATIVE)には影響しないが、**gcc の出力を読むときの落とし穴**として記録する。

### 不変性の担保

`.init_array` を持たない `.so` 3 本と実行ファイル 1 本について、
**修正前後の SHA256 が完全一致**することを確認した。タグは配列が空でないときだけ出す。

---

## Step 155 — `__attribute__((constructor))` / `((destructor))`(M5 H6)

init/fini array 整備の 3 段階の 2 つ目。Step 154 でリンカが `.init_array` /
`.fini_array` を扱えるようになったので、**rubycc 自身がそのセクションを出せる**ようにした。
これでコンパイル → リンク → 実行が一本の線でつながる。

### 属性は「名前 → 優先度」の表で解決する

gcc は属性を**定義より後の宣言**に書くことも許す(実測)。したがって
「関数定義を見た瞬間に登録する」設計では取りこぼす。パース中は名前引きの表に貯め、
パース完了後に**この TU が定義した関数**とだけ突き合わせる形にした。
宣言だけで定義が無い名前は何も出さない — スロットは定義した側のオブジェクトのものだから。

### 実測が 3 つ想定を覆した

1. **`constructor(65535)` は無印の `.init_array` になる**。65535 が gcc の既定値で、
   番号付きセクションにならない。rubycc は「番号なし」の内部表現を 65535 にすることで、
   **この一致を無償で得ている**
2. **ゼロ詰めは 5 桁**(`.init_array.00101`)。値域は 0〜65535 inclusive で、
   範囲外は gcc も**エラー**。0〜100 は「実装予約」だが gcc は警告どまりなので
   rubycc も受け入れる(警告チャネルが無いため、ここで拒否すると gcc より狭くなる)
3. **gcc は `static` 関数のスロットをセクションシンボル(`.text + offset`)で指す**。
   名前付きシンボルを使うのはグローバル関数のときだけ。rubycc は**常に関数シンボル**で
   出しており、ローカルシンボルへの ABS64 が正しく解決されることをテストで固定した

リンカ側の `array_priority` の正規表現との整合は、綴りを目で合わせるのではなく
**実際にリンクして実走順を見るテスト**で担保している。食い違えば `LinkError` か
実行順の誤りとして落ちる。

### gcc と意図的に違えた 3 点

いずれも「gcc は警告で済ませるが、rubycc には警告チャネルが無い」ことに起因する。
**警告が出せない処理系にとって『警告して続行』は『黙殺』と同義**なので、
落ちる側に倒した:

- **変数・struct 指定子・パラメータ・typedef・ブロックスコープ宣言に付いた場合は診断**。
  gcc は警告して無視するが、無視すれば初期化子が登録されず、しかも誰も気付かない。
  実装は `parse_attribute_specifiers` の既定を `:reject` にして、
  **新しい位置を足す人が明示的に `:allow` を書かない限り診断になる**ようにした
- **同一属性の優先度が食い違ったら診断**。gcc は黙って最初を採るが、
  それは「ソースが指定していない順で初期化子が走る」形になる
- **`static void f(void) __attribute__((constructor)) {}`(定義の宣言子の後)は受け入れる**。
  gcc は定義に対してのみエラーにする(宣言なら通す)。意図が一意な形を拒んでも得がない

### シグネチャ検査はしない

gcc も `void (*)(void)` 以外を警告付きで通す。**ローダは第 1 引数に argc/argv/envp を
渡す**ので `void f(int, char **, char **)` は実際に動く正当な形であり、
スロットは単なる関数ポインタで型は ELF に一切現れない。

### 不変性の担保

`examples/` の全 C ソース × 2 ターゲット = **67 通りのオブジェクトの SHA256 が
修正前後で完全一致**。属性を使わないソースの出力は 1 バイトも変わっていない。

### 未実測として残ること

musl での実走、および **aarch64 の共有オブジェクトでの構築子**(aarch64 は実行ファイルの
qemu 実走のみ確認、dlopen 実走は x86_64 のみ)。優先度 100 以下の実装予約域を
libc の初期化子と競合させる試験もしていない。

---

## Step 156 — `__cxa_finalize(__dso_handle)` の合成(M5 H6)

init/fini array 整備の 3 段階の最後。**Step 152 で「供給しなかった半分」として
記録した穴**を塞いだ。ハンドラを登録したまま `dlclose` された共有オブジェクトが
アンマップ領域を指すハンドラを残す、という問題が解消した。

### 実測が実装を 3 つ決めた

1. **NULL 検査は飾りではない**。gcc の該当関数を逆アセンブルすると
   `cmpq $0x0, __cxa_finalize@GOT(%rip)` / `je` で **GOT スロットを直接読んで**
   分岐している。`__cxa_finalize` は **WEAK の未定義**なので、
   持たない libc に対して無検査で呼べば落ちる
2. **引数は `mov`、`lea` ではない**。`__dso_handle` の**中身**を load して渡す。
   中身は自分自身のアドレスなので値は同じだが、C の
   `__cxa_finalize(__dso_handle)`(`void *` 変数を渡す)の意味論に一致するのは前者で、
   入力側が自前の `__dso_handle` を定義していた場合に差が出る
3. **合成した終了子は配列の先頭に置く**。gcc の `.fini_array` は
   `[__do_global_dtors_aux, dtor]` の順で、**ランタイムは逆順に歩く**ので
   実際は「ユーザの終了子 → `__cxa_finalize`」。ハンドラを落とすのは最後でなければならない

### 新しい配置ロジックを足さずに済んだ

3 を満たすのに、Step 154 の**優先度機構がそのまま使えた**: 番号付きセクションは
昇順で先に来るので **`.fini_array.00000`** で出せば先頭に入る。
優先度 0〜100 は gcc が「実装予約」とする域で、**まさにこれが実装自身**なので
用途としても正しい。

### `completed` ガードを省いた理由

gcc は一度だけ走るためのガードを持つが、それは `__do_global_dtors_aux` が
**`.fini_array` と `_fini` の両方**から到達しうるため。rubycc は `_fini` / `DT_FINI` を
出さないので**到達経路は 1 つだけ**で、ガードは要らない。省いた理由をコメントに書いた。

### リンカ側は 1 行も足さずに済んだ

「WEAK 未定義 + GOT + PLT」を扱えるかが最大の懸念だったが、**既存機構でそのまま通った**:
`external_import?` は WEAK 未定義も import として拾い、`PartialLinker` は WEAK バインドを
未定義のまま維持し、`register_got`(GLOB_DAT)と `register_plt`(JUMP_SLOT)は
同一シンボルに対して両方成立し、`ExecutableLinker#resolve_imports` の
「未解決は hard error」は既に weak を除外していた。変更は
`build_dso_handle_object` の拡張だけで済んだ。

### 検証は「バイト列を復号して到達先を再導出」まで

手で組んだ機械語は、`as` / `aarch64-linux-gnu-as` の出力とバイト列・リロケーションの
offset/addend が完全一致することを確認したうえで、**リンク後の `.so` を逆アセンブルして
3 つのオペランドの到達先**(GOT スロット・`.data` のハンドル語・PLT スタブ)を
実測で突き止めている。テスト側も同じことをバイト列の復号でやっているので、
命令列を書き換えれば落ちる。

本題の検証は **`__cxa_atexit` で登録したハンドラが `dlclose` だけで走ること**。
Step 152 のテストは「手で `__cxa_finalize` を呼べば解除される」までしか示せていなかった。

### 実測できなかったこと

**NULL 検査が実際に分岐することは確かめられていない**。ホストの glibc も
aarch64 sysroot の glibc も `__cxa_finalize` を必ず持つため、GOT スロットが 0 になる
状況を作れない。**検査命令が存在し正しい GOT スロットを読んでいることの逆アセンブル
確認で代替**している。musl でも未確認。

### 想定と違った挙動(実装定義として記録)

ユーザが `__attribute__((destructor(0)))` を書くと、rubycc は予約域を警告なしで
受け付けるため**同じ `.fini_array.00000` に入り**、リンク順でユーザのスロットが先・
合成スロットが後 = 逆順走査で**合成側が先に走る**。セクション内の順序なので
Step 154 の優先度機構では直せない。新しい配置ロジックを足さない方針に従い、
コメントに実装定義として記録した。実害は「予約域を自分で使った翻訳単位」に限られる。

### 古くなった記録を直した

`data/verified_gems.json` の stackprof の `notes` にあった
「`dlclose` 後始末は保証されない」という但し書きは、この変更で**事実でなくなった**ので
手で書き換えた。あわせて `data/README.md` に、**`notes` はこのファイルで唯一
人間が手で書き換えてよい欄**であることを明記した — ツールが上書きしないのは
「機械が人間の但し書きを消さない」ためであって、**人間が古くなった但し書きを直すのは
正しい操作**である。実測から生成される欄(`versions` / `verified_at` /
`environment` / `evidence`)は従来どおり手では触らない。

---

## Step 157 — コーパス未検証 gem の検証(strscan / stringio / etc / fcntl)(M5 H6)

センサス対象 36 件に対し検証済みは 8 件。**未検証 28 件のうち 26 件は R10 ゲートを
通過している**(除外は sqlite3 と pg だけ)ので、着手先には困らない。
最も形が揃っている `ruby/*` の default gem から 4 件に当たった。
`data/verified_gems.json` は **8 → 10 件**。

### 結果は 4 者 4 様だった

| gem | 結果 | 内容 |
|---|---|---|
| **strscan 3.1.6** | **PASS** | 150 tests / 1,049 assertions |
| **stringio 3.2.0** | **PASS** | 103 tests / 626 assertions |
| **fcntl 1.3.0** | **検証不能** | 上流にテストスイートが存在しない |
| **etc 1.4.6** | **FAIL** | rubycc 側のギャップ 3 つ(下記) |

### fcntl — (d) レベルの証拠が原理的に得られない

`ruby/fcntl` は **v1.3.0 にも master にも `test/` が無く**、Rakefile に test タスクも
無く、CI の "Run test" は `bundle exec rake compile` だけ(実測)。
`verified_gems.json` が要求する「gem 自身のテストスイート合格」は原理的に得られないので、
**レシピを書かず記録もしない**。ビルド自体は通る((b) レベル)が、それは記録の根拠にならない。

副産物として実測: rubycc ビルドの `Fcntl` は **24 定数、gcc ビルドは 26 定数**。
欠けるのは `F_GETPIPE_SZ` / `F_SETPIPE_SZ` で、同梱 `fcntl.h` に無いため。
**共通 24 定数の値はすべて一致**。

### etc — gcc 対照で rubycc 側の非を確定させ、ギャップを 3 つ立てた

同一の上流ツリーをホスト gcc でビルドして同じスイートを走らせると
**18 tests / 561 assertions / 0 failures**(omission 2 件は上流自身のもの)。
Step 146 と同じ作法で、**レシピは正しく非は rubycc 側**と確定した。

1. **rmake がシェルのバックスラッシュ除去をしない**。mkmf は
   `-DSYSCONFDIR=\"/.../etc\"` を Makefile に書く(`/bin/sh` が `\` を落とす前提)。
   rmake はシェルを介さず自前で分割するので `\` が残り、
   `unexpected character "\"` になる。**最小再現の対照表がコンパイラの無罪を示している**:

   | 組み合わせ | 結果 |
   |---|---|
   | GNU make + gcc | OK |
   | **GNU make + rubycc** | **OK** ← コンパイラは無罪 |
   | rmake + gcc | FAIL |
   | rmake + rubycc | FAIL |

   同一 argv での対照も取れており、`\` 付き argv では gcc も
   `stray '\' in program` で落ちる = **gcc と挙動は完全に一致**。差は rmake だけ。
   該当は `lib/rubycc/rmake/executor.rb` の `tokenize` で、POSIX の
   「引用符外の `\` は次の 1 文字をエスケープ」が未実装

2. **`__atomic_*` ビルトインが無い**。`ruby.h` が `HAVE_RUBY_ATOMIC_H` を定義するため
   `ruby/atomic.h` が取り込まれ、ruby の config.h が `HAVE_GCC_ATOMIC_BUILTINS` を
   定義しているのでその分岐に入る。**フォールバック連鎖の末尾は
   `#error Unsupported platform` で逃げ道が無い**

3. **`confstr` / `fpathconf` / `getlogin` の宣言が無い**。これが一番たちが悪い:
   **mkmf の `have_func` は自前で関数を宣言するのでプローブは通ってしまい**、
   `HAVE_CONFSTR` 等が定義され、**本体のコンパイルで暗黙宣言エラーになる**。
   「プローブが通ったのにビルドが落ちる」という形は他の gem でも起きうる系統的な穴

3 つを手で回避すると etc.c は最後までコンパイルできた。**ただしそれでも
スイートは静かに縮む**: `ext/etc/constdefs.h` は gcc のヘッダ下で **179 定数**を
定義するが rubycc の同梱ヘッダ下では **11 個**(`_SC_*` のみ)。
`test_etc.rb` は `if defined?(Etc::CS_PATH)` で守られているので、
**失敗ではなく「テストが定義されない」形**で 18 → 16 tests になる(予測。
コンパイルが通らないため未実走)。**skip が静かに緑になるのと同じ構図**が
gem 側のスイートでも起きる。

### sanity が空振りでないことを実測した

「処理系同梱の別コピーが読まれる」危険が実在することを stringio で確かめた:

| 条件 | ロードされた `.so` | sanity |
|---|---|---|
| ツールと同じ | 注入した `stringio-3.2.0/lib/stringio.so` | **ok** |
| `-Ilib` を外す | **処理系同梱の 3.1.2** | **FAIL** |

さらに、**`-Ilib` を外した状態でスイートは 100% passed になる**ことも実測した。
sanity が無ければそのまま「検証済み」として記録される状態で、
Step 144 でこのゲートを必須にした判断が 2 度目の裏付けを得た。

### ついでに直した古い記述

`tools/verify_gem_tests.rb` の stackprof / nkf のレシピの上にあった
「この 2 件はまだ通らない」というコメントが Step 151・153 以降**事実と食い違っていた**ので、
実態に直した。**生きた TODO リストとして残したコメントは、閉じたら直さないと嘘になる。**

---

## Step 158 — rmake の POSIX バックスラッシュ除去(M5 H6)

Step 157 のギャップ A。mkmf は `-DSYSCONFDIR=\"/.../etc\"` を Makefile に書く。
`/bin/sh` が `\` を落として `-DSYSCONFDIR="/.../etc"` を渡す前提だが、
**rmake はシェルを介さず自前で語分割する**ため `\` が残り、
コンパイラが `unexpected character "\"` で落ちていた。

### コンパイラの無罪は最小再現で確定していた

Step 157 の対照表(GNU make + rubycc は OK、rmake + gcc は FAIL)で、
**問題が語分割にあってコンパイラにないこと**は着手前に確定していた。
同一 argv では gcc も `stray '\' in program` で落ちるので**挙動は完全に一致**している。
だから直す場所は 1 箇所しかなかった。

### 規則は `/bin/sh` に実際に食わせて決めた

POSIX の条文だけで書くと 2 番目を間違える。**dash に食わせて 3 規則とも実測**した:

| 文脈 | `\` の扱い | 実測 |
|---|---|---|
| 引用符の外 | 次の 1 文字を保存(`\` は消える) | `a\"b` → `a"b`、`a\ b` → **1 語** `a b`、`a\\b` → `a\b` |
| 二重引用符の中 | **`$` / `` ` `` / `"` / `\` / 改行の前だけ**特別 | `"a\"b"` → `a"b` だが **`"a\bb"` → `a\bb`(`\` が残る)** |
| 単一引用符の中 | 完全にリテラル | `'a\b'` → `a\b` |

**2 番目は直感に反する**。「二重引用符の中でも `\` はエスケープ文字」と思って実装すると
`"a\nb"` が `anb` になってしまう。実測しなければ間違えていた。

エッジケースも実測した: `\` + 改行は**行継続**(両方消える)、
**末尾の孤立した `\` はそのまま残る**。

### 既存の分岐にそのまま入った

3 規則は互いに排他的な文脈(単一引用符内 / 二重引用符内 / 引用符外)なので、
既存の `case c` のディスパッチに `when "\\"` を足し、二重引用符の処理を
`scan_double_quoted` に切り出すだけで済んだ。単一引用符の既存処理は
「間の文字をそのまま連結」で**元から規則 3 に一致していた**ので無変更。

`\` を含まないコマンド行の語分割は 1 語も変わっていない(既存の rmake golden テストが担保)。

### etc の到達位置

ギャップ A は消え、**次はギャップ B(`__atomic_*`)で止まる**ことを実測で確認した:
`ruby/atomic.h:356: error: implicit declaration of function '__atomic_fetch_add'`。
Step 157 で立てた見立てのとおりの位置に進んだ。

---

## Step 159 — 「Pure Ruby」を「Almost Pure Ruby」に(M5 H6)

プロジェクトが「Pure Ruby」と謳っている文面を「Almost Pure Ruby」に改めた(ユーザ指示)。

### 変えたもの

gemspec の `summary` / `description`、README の見出し行、DESIGN のタイトル・1 章の
位置づけ・**R2**・R5、THROUGHPUT の N1 評価、security-dos-review の前提、
および `Rubycc::Compiler` を「Pure Ruby toolchain」と呼んでいたテスト側のコメント 2 箇所。

**R2 は要件そのもの**なので、ラベルだけを改め、実質(「Ruby 標準添付ライブラリ以外に
依存しない」)は 1 字も変えていない。要件の検証可能性を落とさないため。

### 変えなかったもの(と、その理由)

一括置換にしなかったのは、**同じ語が別のことを指している箇所がある**から:

- `benchmark/README.md` の「ハーネス(Pure Ruby)」— ベンチマークスクリプト
  `run.rb` 自体の説明であって、プロジェクトの主張ではない
- `docs/DESIGN.md` の「同機能の Pure Ruby 実装よりは十分速い」(N2)—
  **比較対象である他の実装**を指しており、rubycc の主張ではない
- `tools/verify_gem_tests.rb` と `lib/rubycc/pkgconf` の "pure-Ruby" —
  前者は**検証対象 gem のフォールバック**、後者は `.pc` パーサという
  個別コンポーネントの事実記述

---

## Step 160 — ギャップ B の見立ての訂正と、C・D の解消(M5 H6)

Step 157 の etc 検証が立てた 3 つのギャップのうち **C と D を閉じ、B の理解を訂正**した。

### 立てた仮説が実測で否定された

着手前、証拠が食い違っていた。**`ruby/atomic.h` がコンパイルされる理由が見当たらない**:
`etc.c` は `#ifdef HAVE_RUBY_ATOMIC_H` の中でしか include せず、生成された Makefile の
CPPFLAGS に `-DHAVE_RUBY_ATOMIC_H` は無く、extconf は probe しておらず、
Ruby の同梱ヘッダで `ruby/atomic.h` を textual に include しているものも無い。
そこから「**rubycc のプリプロセッサの欠陥ではないか**」という仮説を立てた —
もしそうなら他の gem にも静かに波及している重大な問題になる。

**実測は仮説を否定した**。実際の CPPFLAGS で `etc.c` を rubycc と gcc の両方で前処理して
比較すると、`__atomic_*` の出現は **14 個で完全一致**(gcc 側の 3 件の差は glibc の
pthread 内部ヘッダ由来で、同梱ヘッダに無いだけ)。取り込みの差はゼロで、
**`#ifdef` の評価にも `#include` 探索にも欠陥は無い**。

真相は単純だった: **`ruby.h:12` が `HAVE_RUBY_ATOMIC_H 1` を無条件に定義している**。
「この Ruby にはこれらのヘッダが同梱されている」を宣言するベタ書きのブロックで、
Makefile にも config.h にも無いという観測は正しかったが、
**そこから「だから偽であるべき」と結論したのが誤り**だった。

### bigdecimal が通って etc が落ちる理由

同じ `ruby/atomic.h` を使うのに結果が違うのは、**マクロの出所が非対称**だから:

| | etc 1.4.6 | bigdecimal 4.1.2 |
|---|---|---|
| 取り込み元 | `etc.c` が `ruby.h` を include | `missing.c` が `ruby/ruby.h` を include |
| `HAVE_RUBY_ATOMIC_H` | **`ruby.h:12` から常に真** | `ruby/ruby.h` は定義しない。`extconf.rb` の `have_header` だけ |
| rubycc 下の probe | **無い(逃げ道なし)** | `mkmf.rb` の `alias try_header try_compile` により**コンパイルが走り、まさにこのエラーで失敗** |
| 結果 | 取り込んでコンパイル失敗 | 取り込まれず、**非アトミックのフォールバック**でビルド成功 |

つまり **bigdecimal の PASS は「probe が rubycc 下で自然に偽になったおかげ」**で、
gcc ビルドとは**別のコードがビルドされている**。これは実測しなければ分からず、
記録にも現れない差なので、**`verified_gems.json` の bigdecimal の notes に書き加えた**。
`RUBY_ATOMIC_SIZE_INC` は `BIGDECIMAL_DEBUG` 内でしか使われないのでスイートは影響を受けないが、
**「合格した」という事実だけを残すと、読んだ人はこの差を知らないまま使う**。

`stackprof` / `nio4r` も同型で、どちらも非アトミックのフォールバックに守られている。
**`__sync_*` を実装しても逃げ道にはならない**ことも確認した:
`ruby/config.h` が `HAVE_GCC_ATOMIC_BUILTINS 1` を持つので `#elif` 連鎖は
`__atomic_*` の枝で止まり、`__sync_*` の枝には到達しない。

### ギャップ C — プローブが通ってビルドが落ちる

`confstr` / `fpathconf` の宣言が同梱 `unistd.h` に無い。
**mkmf の `have_func` は自前で関数を宣言する try_link なのでプローブは成功**し、
`-DHAVE_CONFSTR` が立ち、**本体のコンパイルで初めて暗黙宣言エラーになる**。
Step 142 で記録した「`-E` が通ることは正しさの証明にならない」と同じ系統で、
**プローブの成功も正しさの証明にならない**。

`pathconf` も対で入れた。コーパスに直接の消費者はいないが、
`unistd.h` は元から `execl` / `alarm` / `pause` のように特定 gem の実需に絞らない
一般 POSIX 宣言層として扱われており、かつ**数値サーフェスを持たない単一プロトタイプ**で
再計測コストが無いため。

### ギャップ D — 網羅せず 2 つだけ

`ext/etc/mkconstants.rb` が公開する `_CS_*` 26 個 / `_PC_*` 20 個を全て実測し、
**46 個すべてが両アーキに実在し値も完全一致**することを確認したうえで、
**入れたのは `_CS_PATH` と `_PC_PIPE_BUF` の 2 つだけ**。
`test_etc.rb` が `if defined?` で守りつつ実際にアサートしているのがこの 2 つだけだから。
`sys/syscall.h` / `_POSIX_*` と同じ「消費者のいない列挙は入れない」線引き。

### 副産物: ハーネスの穴を 1 つ塞いだ

`UNISTD` Spec に **aarch64 側のテストメソッドが無かった**(R8 は両アーキ必須)。
判断ではなく見落としで、`_SC_*` / `_CS_*` / `_PC_*` の値と宣言が両アーキ一致という主張は
まさに**クロス検査が担保すべきもの**だったので追加した。2,688 → 2,689 runs。

### etc の到達位置

C・D は消え、**残るはギャップ B の `__atomic_*` だけ**。
必要集合も実測で確定した: **メモリオーダは `__ATOMIC_SEQ_CST` のみ**(14 箇所すべて)、
**型幅は 4 と 8 の 2 種類だけ**、形は 9 つ。
`__atomic_compare_exchange_n` は**失敗時に `*expected` へ旧値を書き戻す副作用が
load-bearing**(戻り値は捨てられ直後に `*expected` を返す)で、ここを省くと
`RUBY_ATOMIC_CAS` が壊れる。

---

## Step 161 — `__atomic_*` ビルトイン(ギャップ B の解消)(M5 H6)

Step 157 の etc 検証が立てた 4 ギャップの最後、**B(`__atomic_*` ビルトインが無い)**を閉じた。
`ruby.h:12` が `HAVE_RUBY_ATOMIC_H` を無条件に定義し、`ruby/config.h` の
`HAVE_GCC_ATOMIC_BUILTINS` が `#elif` 連鎖を `__atomic_*` の枝で止め、連鎖の末尾が
`#error Unsupported platform` である以上、**`ruby.h` を引く翻訳単位には逃げ道が無い**
(Step 160)。これは「特定の gem の都合」ではなく **C 拡張の共通土台**である。

### 範囲は実測した必要集合ちょうどに絞った

Step 160 が `ruby/atomic.h` を実測して確定させた必要集合 —— **9 形・型幅 4 と 8 のみ** ——
をそのまま実装範囲にした。`__atomic_thread_fence` / `__atomic_test_and_set` /
非 `_n` の総称形 / `__sync_*` / C11 の `_Atomic` と `<stdatomic.h>` は入れていない。
入れなかったものは `__has_builtin` も**正直に 0 を返す**ので、
フォールバックを持つヘッダは rubycc が実際に供給できる枝を選ぶ。

幅 1 / 2 / 16 は**診断にした**。「アトミックでない列を黙って出す」のが最悪の選択肢だから
(呼び出し側にはアトミック性が落ちたことが観測できない)で、
Step 155 の「警告チャネルの無い処理系では『警告して続行』は『黙殺』と同義」と同じ線引き。

### メモリオーダは受理して捨てる —— 診断ではなく最強化

**設計の中心はここ**。rubycc は `__ATOMIC_RELAXED` を渡されても **seq_cst で降ろす**。
これは手抜きではなく、**オーダの強化は常に意味論的に妥当**だから正しい:
メモリオーダは処理系に許される並べ替えを*制約する*だけの指定なので、
要求より強い順序を与えることは呼び出し側の保証を全て満たしたうえで保証を足すだけになる。
`__atomic_compare_exchange_n` の `weak` を常に strong として扱うのも同じ理屈
(strong は「決して偽失敗しない weak」)。

代案は 2 つあり、どちらも劣る:

- **`__ATOMIC_SEQ_CST` 以外を診断する** —— 実測では消費者が seq_cst しか使っていないので
  今日は等価に見えるが、**妥当なプログラムを拒否する**ことになる。
- **オーダごとに降ろし分ける** —— rubycc は最適化を行わず -O0 相当の列を出すので、
  緩いオーダで得られるはずの余地はそもそも存在しない。複雑さだけが増える。

その結果 **IR はメモリオーダを一切運ばない**(`docs/IR.md` §5 のアトミック節)。
オーダ引数は「捨てる」のであって「無視する」のではなく、
**普通の関数引数として評価はする**(副作用がありうる)うえで整数型であることは検査する。

### 4 命令 —— なぜ `:load` / `:store` と別命令なのか

`:atomic_load` / `:atomic_store` / `:atomic_rmw` / `:atomic_cas` の 4 つ。
特に `:atomic_load` は x86-64 では**既存の `:load` と 1 バイトも変わらない**列に降りる
(整列した `mov` が既に seq_cst ロード)。それでも別命令にしたのは、
**「素の `mov` でよい」がターゲットのメモリモデルの性質であって IR の性質ではない**から。
aarch64 は `ldar` が要る。同じ IR 命令にしてしまうと、この非対称を表現する場所が無くなる。

### 2 ターゲットで形が違った箇所

| | x86-64 | aarch64 |
|---|---|---|
| load / store | `mov` / `xchg`(暗黙 lock が seq_cst ストアの後続バリアを兼ねる) | `ldar` / `stlr`(armv8 の LDAR/STLR は RCsc なので追加バリア不要) |
| `fetch_add` / `fetch_sub` | `lock xadd`(sub は先に `neg`) | 共通ループ |
| `add_fetch` / `sub_fetch` | **`lock xadd` から導出**(旧値 + 加数 = 新値)。オペランドを退避して足し直す | 共通ループ |
| `or_fetch` | 導出元が無く、**ここだけ `lock cmpxchg` リトライループ** | 共通ループ |

**aarch64 は 6 kind すべてが 1 本の LDAXR/STLXR ループを共有する**。x86-64 が
「旧値から新値を後から復元する」必要があるのに対し、ループ内では旧値も新値も
同時にレジスタにあるので、各 kind は**欲しい方の名前を言うだけ**で済む。
`or_fetch` に特別扱いが要らないのも同じ理由(どの kind もループしか選択肢が無い)。

LSE の単一命令(`casal` / `ldadd` / `swp`)は使っていない。armv8.1-a が要るうえ、
gcc のもう一つの選択肢である libgcc の outline atomics(`__aarch64_ldadd4_acq_rel` 等)は
**rubycc が他では一切リンクしないランタイムに出力を依存させる**ことになる。
armv8-a ベースラインなら全ての AArch64 部品で動く。逆アセンブル検査には
**LSE 命令と `__aarch64_*` が出て**いないことの否定形の確認も入れた。

### ループと分岐にラベル機構を使わない

リトライループの後方分岐も CAS の前方分岐も、**両端が 1 つの IR 命令の内側で閉じる**。
そのため `:label` / `@fixups` は使わず、発行済みバイト数から変位を直接計算する。
aarch64 は**既存の `#emit_memcpy_loop` と同じやり方**で、新しい機構は 1 つも足していない。

この性質は N4(決定的ビルド)で意味を持つ: 変位が「発行したバイト数」から出ている以上、
**バイト同一な再ビルドはその計算が周囲の状態に依存していないことの証拠**にもなる。
`test_deterministic_build.rb` に両ターゲット分のケースを足したのはそのため。

### `*expected` の書き戻しは分岐でガードする

`__atomic_compare_exchange_n` が失敗したとき、実際に読めた値を `*expected` へ書き戻す
副作用は **`<ruby/atomic.h>` の `RUBY_ATOMIC_CAS` が答えを取り出す唯一の経路**
(戻り値の真偽は捨てられる)なので必須。

**成功経路では書かない**ようにしてある。無条件に書くと同じビットを書くだけに見えるが、
**`expected` が対象自身に別名で重なっている場合に、交換したばかりの値を旧値で潰す**。
gcc 差分テストにこの別名ケースを明示的に入れた。

### gcc の同条件出力と命令単位で一致した

aarch64 の CAS を `-O0 -march=armv8-a -mno-outline-atomics` の gcc と突き合わせると、
`ldaxr` / `cmp` / `b.ne` でループを抜ける / `stlxr` / `cbnz` / `cset eq` /
分岐でガードした書き戻し、という**同じ形**だった。
ミスマッチ経路で `clrex` を出していない点も一致する(後続の `stlxr` は必ず
自分の `ldaxr` と対になっているので、モニタの残存は問題にならない)。

### 検証されていないもの

**メモリ順序そのものは単一スレッドでは観測できない**。ここで実測できたのは
「値と副作用が gcc と一致する」「命令選択が gcc と一致する」までで、
順序の正しさはアーキテクチャマニュアルの規定に依存している。
これは**この機能に固有の限界**として明示しておく。

### 波及: 2 つの gem のビルド経路が変わった

- **etc 1.4.6 が PASS した**(18 tests / 449 assertions / 0 failures / 2 omissions)。
  Step 158(rmake のバックスラッシュ)・Step 160(`confstr` 等)・本ステップの
  **3 つ全てが揃って初めて通る**。
- **bigdecimal は PASS のままだが経路が変わった**。Step 160 で記録したとおり、
  それまでは `have_header` プローブが rubycc 下で失敗して**非アトミックの
  フォールバック**がビルドされていた。プローブが通るようになったので、
  いまは本物の CAS(`lock xadd` / `lock cmpxchg` が `bigdecimal.so` に 12 箇所)が入る。
  **Step 160 の notes は古くなった。**

`ruby/atomic.h` を単体で include する翻訳単位のコンパイルを `test_ruby_smoke.rb` に
回帰テスト化した(distroless 経路にも入れた)。これがギャップ B の最小再現そのものである。

---

## Step 162 — etc 1.4.6 を記録し、bigdecimal を再記録する(M5 H6)

Step 158・160・161 で閉じたギャップの成果を `data/verified_gems.json` に落とすステップ。
**6 → 11 件**になった。

### etc 1.4.6 — 3 ステップが揃って初めて通る

18 tests / 449 assertions / 0 failures / 0 errors / 2 omissions で PASS。
このエントリは **Step 158(rmake の POSIX バックスラッシュ除去)・Step 160
(`confstr` / `fpathconf` / `pathconf` の宣言)・Step 161(`__atomic_*`)の
3 つ全てを必要とする**。どれか 1 つでも欠けるとビルドが落ちるので、
notes にその依存関係をそのまま書いた。**機械が観測できない但し書き**の典型で、
「18 tests 通った」だけを残すと、読んだ人はこれが 3 ステップ分の成果であることを知らない。

もう 1 つ notes に書いたのは **`_CS_*` / `_PC_*` の網羅が部分的**であること。
同梱 `unistd.h` は 46 個のうち `_CS_PATH` と `_PC_PIPE_BUF` の 2 つしか定義しないので、
`ext/etc/constdefs.h` は gcc 下の 179 定数に対し 11 定数で生成される。
`test_etc.rb` は `if defined?` で守っているため、これは**失敗ではなく
「テストが定義されない」形で静かに縮む**。合格件数だけを見ていると気付けない差なので、
記録に残さなければならない(Step 160 の線引きの帰結でもある)。

### bigdecimal — 合格件数は同じだが、同じビルドではない

265 tests / 8,267 assertions / 0 failures / 0 errors / 11 omissions で、
**数値は Steps 93-97 のときと 1 つも変わらない**。それでも再記録したのは、
**ビルドされたコードが変わった**から。

Step 160 で実測したとおり、それまでは extconf の `have_header("ruby/atomic.h")`
(mkmf が `try_header` を `try_compile` に alias しているので実際にコンパイルが走る)が
rubycc 下で失敗し、`HAVE_RUBY_ATOMIC_H` が定義されず、gem 自身の**非アトミックの
フォールバック**がビルドされていた。Step 161 でビルトインが降りるようになったので
**プローブが通り、いまは gcc と同じアトミック経路が入る**
(実測: `bigdecimal.so` に `lock xadd` / `lock cmpxchg` が 12 箇所。以前は 0)。

**Step 160 で書いた notes は事実でなくなったので手で書き換えた。**
`data/README.md` が定めるとおり `notes` はこのファイルで唯一人間が手で書き換えてよい欄で、
ツールが上書きしないのは「機械が人間の但し書きを消さない」ためであって、
**人間が古くなった但し書きを直すのは正しい操作**である(stackprof の `dlclose` の
記述を Step 156 で直したのと同じ)。

ここで残る教訓は**合格件数は変更を検出しない**ということ。スイートは
`RUBY_ATOMIC_SIZE_INC` を `BIGDECIMAL_DEBUG` の下でしか踏まないので、
2 つのビルドを区別しない。**「PASS のままだった」は「何も変わらなかった」ではない。**

### `evidence` は追記、許可リストは手で

bigdecimal の `evidence` には Steps 93-97 の 1 文が残ったまま Step 162 の 1 文が足された。
`evidence` はそのエントリを確認した全ステップの履歴を溜める欄なので、
上書きすると再実行では復元できない部分が黙って消える。

`test/test_doctor.rb` の許可リストは**ツールが貼り付け用の行を表示するだけで
自動編集しない**設計なので、`etc` の追加を手で書いた。gem の追加を意識的な編集に
留めるための意図的なゲートで、今回もそのとおりに働いた。

### 付随: c-testsuite がレポジトリを散らかしていた

`test/external/c-testsuite/single-exec/00187.c` は stdio の検査で
`fopen("fred.txt", "w")` を**相対パス**で書くため、実行時の作業ディレクトリだった
レポジトリのルートに `fred.txt` が落ちて残っていた。
`link_and_run_with_libm` は実行ファイルを既に tmpdir に作っているので、
`Open3.capture2e` に `chdir: dir` を渡すだけで発生源が消える。
**`.gitignore` で隠すのではなく散らかす側を直した**(利用者は `test_c_suite.rb` のみで、
cwd 相対でレポジトリ内のファイルを読むテストは無いことを確認済み)。

---

## Step 163 — 共有ライブラリの r-x ロードセグメントが `.plt` を覆っていなかった(M5 H6)

default gem 検証の 1 件目に io-nonblock 0.3.2 を選んだ(ROADMAP の 7 件表の 1 番。
単一ファイル ext で最も安く、差し込み手順の足場固めに使う想定だった)。
**足場固めのつもりの 1 件目が、11 gem を検証してきた間ずっと潜んでいたリンカのバグを引いた。**

### 症状と切り分け

ビルドは通り、mkmf の probe も全て gcc と同じ結果になった
(`rb_io_descriptor` yes / `O_NONBLOCK` yes / `F_GETFL` yes)。
にもかかわらず `require "io/nonblock"` が **[BUG] Segmentation fault** で落ちる。

`Fiddle.dlopen` は成功し、`dlsym("Init_nonblock")` もアドレスを返した。
つまり**壊れているのは動的リンクではなく、`Init_nonblock` を実行した瞬間**である。
逆アセンブルすると最初の命令列が `call 0xa020 <rb_ext_ractor_safe@plt>` で、
クラッシュ時の RIP がロードベース + `0xa020` と一致した。

セクションとセグメントを突き合わせて原因が確定した:

| | 範囲 |
|---|---|
| `.text` | `0x160`–`0x9b7b` |
| `.plt` | `0x9b80`–`0xa040` |
| r-x の PT_LOAD | offset 0 / vaddr 0 / **`p_filesz` = `0x9ee0`** |

正しい `p_filesz` は `0xa040`。差の **`0x160` は `.text` のファイルオフセット**、すなわち
ELF ヘッダ + プログラムヘッダテーブルの長さである。ローダは `p_filesz` をページ境界に
切り上げてマップするので `0xa000` までは載り、**`0xa000`–`0xa040` にある PLT エントリだけが
未マップページに落ちる**。`rb_ext_ractor_safe@plt` = `0xa020` がちょうどそこだった。

**ホスト gcc で同じ gem をビルドした対照は正常にロードできた**ので、非は rubycc 側に確定
(Step 146 で決めた「失敗したらまず gcc 対照を取る」の適用。今回は原因が自前の ELF 出力に
閉じていたので対照は追認にとどまったが、環境のせいにしない担保としては要る)。

### 原因

`lib/rubycc/link/shared_linker.rb` の `build_phdrs` が r-x セグメントの長さを
`segment_extent` から取っていた。このヘルパが返すのは

```ruby
{ offset: sections.first.offset, filesz: finish - sections.first.offset }
```

= **最初のセクションのオフセットを起点とした長さ**である。`ro` / `rw` セグメントは
`p_offset` にも同じ起点を入れるので整合するが、**r-x だけはファイルオフセット 0 から
マップする**(ELF ヘッダと phdr 自身を覆うため)。起点が違うのに同じ計算を使ったので、
先頭 `0x160` バイトぶん一貫して過小になっていた。

`lib/rubycc/link/executable_linker.rb` は**同じ箇所を最初から正しく**
`rx_last.offset + rx_last.size` と絶対値で計算していた。実行ファイル側だけが正しく、
共有ライブラリ側が取り残されていた形で、**両者が同じ不変条件を別々に書いていたことが
食い違いを見えなくしていた**。

### なぜ 11 gem を検証する間ずっと表面化しなかったか

**過小分がページ切り上げに吸収される限り実害が出ない**からである。
`align_up(過小な終端, 0x1000) >= 本当の終端` なら全バイトがマップされ、何事も起きない。
表面化するのは、過小な終端と本当の終端が**ページ境界をまたぐとき**だけ
(ここでは `0x9ee0` → `0xa000` < `0xa040`)。つまり**出力サイズ次第の宝くじ**であり、
既存の検証済み 11 gem はたまたま当たらなかっただけである。
「11 gem が通っている」ことは、この不変条件が守られている証拠には**なっていなかった**。

### 回帰テストはサイズ非依存の不変条件で書いた

**サイズ依存のテストを書かなかった**のは、このバグがサイズの偶然で表面化する以上、
特定の `.so` を固定したテストは次の同種のバグを捕まえられないからである。書いたのは:

> PT_LOAD に属する全 `SHF_ALLOC` セクションは、そのセグメントの
> `[p_vaddr, p_vaddr + p_memsz)` に収まり、`SHT_NOBITS` でなければ
> `[p_offset, p_offset + p_filesz)` にも収まる

x86_64(`test/test_shared_object.rb`)と aarch64(`test/test_aarch64_shared_object.rb`)の
両方に置いた。**修正前に落ちることを確認済み**で、そのときの落ち方が示唆的だった:
テスト用の小さな `.so` では過小分が `.text` の開始位置にすら届かず、
`.text at 0x160 must fall inside a PT_LOAD segment` = **どのセグメントにも属さない**
という形で落ちる。実際の gem では末尾の `.plt` だけが溢れ、小さな `.so` では
セグメントが `.text` の手前で終わる。**同じバグが規模によって別の顔で出る**ことの実例。

### この修正で io-nonblock は通った

再ビルドした `nonblock.so` の r-x は `FileSiz 0x00a040` になり `.plt` 末尾を覆う。
gem 自身のテストスイートは **2 tests / 8 assertions / 0 failures / 0 errors** で PASS。
記録は Step 164 に分けた(ROADMAP の横断ルール「ギャップの修正は別ステップに切る」)。

---

## Step 164 — io-nonblock 0.3.2 を記録する(M5 H6)

Step 163 の修正で通るようになったので `--update` で記録した。検証済み gem は **12 件**。

### 入れ子スキーマの初実走

`data/verified_gems.json` を「1 gem = 1 エントリ、環境ごとの記録がその内側」という
入れ子に拡張した直後の**最初の新規記録**でもある。ツールは `(new entry)` を選び、
`verifications` 1 本 + 空の `notes` を出力した。既定 notes は空文字で、
**「musl では未検証」といった但し書きはもう書かない**
(未検証はその環境の記録が無いことで既に表現されている)。

### 合格件数だけでは何も言えないので、経路を突き合わせた

このスイートは **2 tests / 8 assertions** しかない。上流がこのタグで持っているのが
それだけであって除外はしていないが、**件数の少なさは経路の正しさを何も保証しない**。
Step 160 の bigdecimal(probe が失敗して gcc とは別のフォールバックがビルドされていたのに
合格件数は同じだった)を踏まえ、extconf の probe 3 件をホスト gcc 対照と突き合わせた:

| probe | rubycc | host gcc |
|---|---|---|
| `rb_io_descriptor()` in `ruby/io.h` | yes | yes |
| `O_NONBLOCK` in `fcntl.h` | yes | yes |
| `F_GETFL` in `fcntl.h` | yes | yes |

3 件とも一致するので `HAVE_RB_IO_DESCRIPTOR` は両方で定義され、
`io_descriptor_fallback` は**両方で消える**。同じ経路がビルドされている。

### スイートが「何もロードしなくても合格しうる」形をしている

`test/io/nonblock/test_flush.rb` は自分の `require 'io/nonblock'` を
`rescue LoadError` で包み、さらにクラス全体を `if IO.method_defined?(:nonblock)` で
守っている。つまり**拡張が 1 バイトもロードされなくても、エラーではなく
「テストが 0 件」として静かに合格する**。これは Step 144 で `sanity` を必須にした
理由そのものの、別の現れ方である(racc は純 Ruby フォールバックに落ちて合格し、
こちらはテストが定義されずに合格する)。レシピは `io/nonblock` をその rescue の外で
require するので、その状態は PASS として記録されない。

---

## Step 165 — io-wait 0.4.0 を記録する(M5 H6)

7 件計画の 2 番。**リンカのバグを踏んだ 1 番と違い、コンパイラ側の変更は要らなかった。**
gem 自身の test/unit スイートが **26 tests / 41 assertions / 0 failures / 0 errors /
1 omission** で PASS。検証済み gem は **13 件**。

### probe が無い gem なので、経路の一致は構造的に保証される

`ext/io/wait/extconf.rb` は `require 'mkmf'` と `create_makefile("io/wait")` の
実質 2 行しかない。**configure 時の分岐が 1 つも無い**ので、bigdecimal(Step 160)や
io-nonblock(Step 164)で毎回突き合わせていた「rubycc と gcc で別の経路がビルドされて
いないか」という疑いが、この gem では**構造的に立たない**。同じ翻訳単位を両者が
コンパイルしている。

それでも**ホスト gcc 対照は取った**。同じ上流ツリーの `.so` だけ差し替えてスイートを
走らせ、**26 tests / 41 assertions / 0 failures / 0 errors / 1 omission と両者完全一致**。
omission の 1 件は `test_tty_wait` で、`/dev/tty` が開けない
(`Errno::ENXIO`、制御端末の無いセッション)という**環境の性質**であり、gcc 対照でも
同じように omit される。「omission が 1 件ある」という事実だけを記録して
理由を書かないと、後から読んだ人がここを rubycc の欠陥だと誤読しうるので notes に書いた。

### ツールに `runner_args` を足した — `exclude` では代用できない

io-wait の Rakefile は `Rake::TestTask#options` に
`--ignore-name=/ungetc_in_text/` を渡している。上流自身が
`test_after_ungetc_in_text_wait_readable` を走らせていないので、こちらも走らせては
いけない(走らせて落ちれば、上流が意図的に外したものを rubycc の非として記録する)。

既存の `exclude` は**ファイル単位**で test_glob から引くフィールドで、この 1 件は
実際に走る他のテストと同じ `test_io_wait_uncommon.rb` に同居しているため、
`exclude` を使うと**巻き添えで消える**。そこでスイートのランナー自身に渡す
`runner_args` を新設した。

**実装で 1 度踏んだ**: `ruby ... -e SCRIPT --ignore-name=...` と並べると、
**ruby は `-e` の後ろも自分のオプションとして解釈し続ける**ため
`invalid option --ignore-name=...` で子プロセスが死ぬ(判定は `unparsable`)。
`--` で ruby のオプション解析を終わらせて初めて ARGV に届き、test-unit の
autorunner が読む。`runner_args` が空のときは `--` も付けない。

### 許可リストのゲートが 12 gem で静かに効かなくなっていた

`test/test_doctor.rb` の許可リストは 12 gem 目(io-nonblock)で 120 桁を超えたので
2 行に折ったが、`tools/verify_gem_tests.rb` の `ALLOWLIST_RE` が
`\], raw\.keys\.sort` とリテラルの空白 1 個を要求していたため、
**折った瞬間にゲートが見つからなくなり**「could not find the allow-list assertion」
という警告に落ちていた。`\s*` に緩め、貼り付け用に印字する行も折った形にした。
**gem が増えて初めて効かなくなるゲート**だったので、増やしている最中に気づけたのは
運が良かった。

---

## Step 166 — erb 6.0.1.1 を記録する(M5 H6)

7 件計画の 3 番。gem 自身の test/unit スイートが
**48 tests / 143 assertions / 0 failures / 0 errors** で PASS。検証済み gem は **14 件**。
コンパイラ側の変更は不要だった。

### ROADMAP の見立ては半分外れた — この gem のスイートは自分のフォールバックを見ている

計画表には「**スイートの大半は純 Ruby の ERB を叩く**ので sanity 式が特に重要
(C 拡張を通らなくても合格しうる)」と書いていた。前半は正しい — C なのは
`ext/erb/escape` だけで、`lib/erb/util.rb` は `require 'erb/escape'` を
`rescue LoadError` で包み、`CGI.escapeHTML` を使う純 Ruby の
`ERB::Escape#html_escape` を裏に持っている。

**後半は実測で外れた**。差し込んだ `escape.so` を壊してスイートを走らせると、
**48 件中 47 件が通り、落ちるのは 1 件だけ** — しかもそれは上流自身の
`test_html_escape_extension` で、`ERB::Util.method(:html_escape).source_location`
が nil であること、つまり **C で定義されていること**を主張している。
racc(`cparse.so` を壊しても 71 tests / 0 failures で 100% passed)とは違い、
**erb のスイートは自分のフォールバックを検出する**。

ただし**検出できないものがある**: 上流のこのテストは「C 実装かどうか」しか見ないので、
**処理系同梱の `erb/escape.so` がロードされていても 48 件全部通る**。
sanity 式に `injected_so_loaded?` を残す理由はここにあり、併記した
`source_location.nil?` の側は**上流が既に走らせているテストの言い直し**でしかない。
両方残したのは上流がそのテストを落とした場合の保険だが、
**どちらが効いているかを取り違えないよう**レシピのコメントに実測を書いた。

「フォールバックがある gem は sanity 式が要る」は正しいが、
**その式のどの項が効くかは gem ごとに違い、測らないと分からない**。

### probe は 1 件、gcc と一致

`have_func("rb_ext_ractor_safe", "ruby.h")` が唯一の probe で、rubycc・gcc とも
`yes`。`HAVE_RB_EXT_RACTOR_SAFE` は両方で定義され、`Init_escape` は両方で
`rb_ext_ractor_safe(true)` を呼ぶ。

### 許可リストの印字を折り返し対応にした

gem 名の一覧が 14 件で `%w[]` の中まで 120 桁を超えた。Step 165 で `raw.keys.sort` を
折ったばかりだったが、今度は語のリスト自身が溢れる。ツールが印字する貼り付け用の行を
`allowlist_lines` で折り返すようにし、**印字した形とテストファイルの実際の形が
一致する**ようにした(一致していないと、貼り付けた人が毎回手直しする羽目になる)。

---

## Step 167 — 同梱ヘッダの `cfmakeraw` / `ttyname_r` 欠落(M5 H6)

7 件計画の 4 番、io-console 0.8.2 に着手して最初に出たギャップ。
`ext/io/console/console.c` のコンパイルが
`error: implicit declaration of function 'cfmakeraw'` で落ちる。

### Step 160 のギャップ C とまったく同型

`extconf.rb` の `have_func("cfmakeraw", "termios.h")` は **yes** を返す。
mkmf の `have_func` は**自分で関数を宣言する try_link** なので、ヘッダに宣言が
無くてもプローブは通り、`-DHAVE_CFMAKERAW` が立ち、**本体のコンパイルで初めて
暗黙宣言エラーになる**。Step 160 の `confstr` / `fpathconf` と同じ構図である。

ホスト gcc の対照はビルドに成功し、**probe 13 件の結果も rubycc と完全一致**した
(`rb_syserr_fail_str` / `rb_interned_str_cstr` / `rb_io_path` / `rb_io_descriptor` /
`rb_io_get_write_io` / `rb_io_closed_p` / `rb_io_open_descriptor` /
`rb_ractor_local_storage_value_newkey` / `termios.h` / `cfmakeraw` / `sys/ioctl.h` /
`HAVE_RUBY_FIBER_SCHEDULER_H` / `ttyname_r`、すべて yes)。
**probe の一致が「同じものがビルドされる」を意味しない**ことの、これ以上ないほど
はっきりした実例で、非は同梱ヘッダの宣言漏れに確定した。

### センサスは `#include` を見るが、呼ばれる関数は見ない

`termios.h` の provenance には「io-console の corpus サンプルが実際に到達する
`HAVE_TERMIOS_H` 経路にスコープを絞り」と書いてある(Step 124)。**この絞り込み自体は
正しい**が、`rake corpus:census` が観測するのは **`#include` の到達**であって、
到達したヘッダの**どの関数が呼ばれるか**ではない。`cfmakeraw` は新しいヘッダを
連れてこないので、センサスの網には最初から掛からない。

同じ理由で `unistd.h` に `ttyname_r` も無かった(`ttyname` はあった)。
console.c が使う termios/unistd 系のシンボルを数え直して、
**足りないのはこの 2 つだけ**であることを先に確かめてから足した
(`ioctl` / `struct winsize` / `TIOCGWINSZ` / `TIOCSWINSZ` / `TCSANOW` / `TC*FLUSH`
は既にある。`TCGETA` / `TCSETAF` / `TIOCGETP` / `TIOCSETP` は Linux で選ばれない
`termio.h` / `sgtty.h` 経路のもので、provenance が既に対象外と明記している)。

**「ヘッダが到達するか」で絞ったスコープは、実ビルドでしか検証できない。**
これはセンサスの欠陥ではなく、センサスに測れることの限界である。

### R8 の扱い

どちらも**数値サーフェスを持たない単一プロトタイプ**なので、新しい ABI ケースは
作らず、既存の `TERMIOS` / `UNISTD` Spec の snippet から呼ぶ形に足した
(Step 160 が `confstr` / `fpathconf` / `pathconf` でやったのと同じ)。
両 Spec とも共通層なので x86_64・aarch64 の両方から同じ Spec が再利用される。
シグネチャは glibc のヘッダテキストを写さず、**実ヘッダを include した上で自分の
宣言を並べ、矛盾する宣言としてエラーにならないことをホスト gcc で確認**して決めた。
ファイル数は変わらないので由来台帳の集計は据え置き、`termios.h` の行にだけ
`cfmakeraw` の追加と経緯を書き足した。

### これで io-console はまだ通らない

この修正でコンパイルは console.c の先へ進み、**次のギャップに当たった**:
`console.c` が `ruby/ractor.h` を取り込み、そこに

```c
static inline bool rb_ractor_shareable_p(VALUE obj)
{
    bool rb_ractor_shareable_p_continue(VALUE obj);   /* ブロックスコープの関数宣言 */
    ...
}
```

がある。rubycc はこれを `generator.rb` で明示的に拒否している
(「block-scope function declarations are not supported」)。**Step 168 で解消する。**
既存の検証済み gem はどれも `ruby/ractor.h` を取り込んでいなかったので、
このギャップは io-console で初めて露出した。

---

## Step 168 — ブロックスコープの関数宣言(M5 H6)

Step 167 のヘッダ修正で先へ進んだ io-console が次に当てたギャップ。
`console.c` が取り込む `ruby/ractor.h:248` に、
**Ruby 本体の公開ヘッダが実際に使っている**この形がある:

```c
static inline bool
rb_ractor_shareable_p(VALUE obj)
{
    bool rb_ractor_shareable_p_continue(VALUE obj);   /* ← */
    ...
}
```

rubycc は `generator.rb` でこれを明示的に拒否していた。
ROADMAP §3 の負債表に「外部リンケージ未モデルで診断エラー / 実害が出た時点」と
載っていた項目で、**c-testsuite 00078 の skip もこの理由で立っていた**。
**H4 で「実害が出た時点」と先送りしたものに、H6 で実害が来た。**

### 実装 — 新しい機構を作らず既存の署名テーブルへ合流させた

C11 6.2.2p5: ブロックスコープで宣言された関数識別子は、記憶域クラス指定子が無いか
`extern` なら**外部リンケージを持つ**。つまりファイルスコープで同名を宣言した場合と
**同じ実体を指す**。したがって

- **記憶域を消費しない**(ローカルスロットを割り当てない)
- 呼び出しはファイルスコープのプロトタイプと同じ外部シンボル参照として解決される

この 2 点は、既存の `declare_function` に流し込むだけで満たせた。IR 命令は増えていない。
型が矛盾すれば `declare_function` の既存の「conflicting types」検査に自然に掛かる。

**可視範囲は意図的にモデル化しなかった。** 本来この識別子はそのブロック内でしか
見えないが、署名テーブルは翻訳単位全体で 1 つのままにした。理由は
**外部リンケージだから**である — 同じ翻訳単位内の同名宣言は、ブロックの内外を問わず
同一の実体を互換な型で指していなければならない(6.2.2p4 / 6.2.7p2)。
緩めたことで余計に受理してしまうプログラムは、**そもそも単一の外部実体として
成立していないプログラム**だけであり、ブロック単位の第 2 の署名テーブルを持つ手間に
見合わない。この判断はコードのコメントに書いた。

### 診断は 2 つ増やした

- **`static` 付き**: 6.7.1p7 はブロックスコープの関数宣言に `extern` 以外の記憶域クラスを
  許さない。制約違反なので診断する
- **入れ子関数定義**: `int f(int) { ... }` をブロック内に書くのは GNU 拡張であり、
  囲みフレームを捕まえるトランポリンが要る。**引き続き非対応**だが、
  従来は素の `expected ';'` になっていたのを、パーサで
  「nested function definitions are not supported」と名指しするようにした。
  **宣言は通るのに定義は通らない**という区別を、利用者に分かる言葉で伝えるため

`docs/GCC-EXTENSIONS.md` には入れ子関数定義の側だけを「未実装」として載せ、
**標準 C のブロックスコープ関数宣言とは別物**であることを明記した(混同されやすい)。

### `ruby/ractor.h` は単体でコンパイルできない

`test/test_ruby_smoke.rb` には `ruby/atomic.h` を**単体で** include するケースがある
(Step 161)。同じ形にしようとしたが、`ruby/ractor.h` は
**ホスト gcc でも単体では通らない**ことが分かった
(`RUBY_ALIGNAS(SIZEOF_VALUE)` で `expected identifier or '(' before numeric constant`、
続いて `SIZE_MAX` 衝突)。このヘッダは `<ruby.h>` が先行することを前提にしている。
そこで**実際の C 拡張が到達する順**(`ruby.h` → `ruby/ractor.h`)の 2 行にし、
理由を実測値つきでテスト内に書いた。**「単体で通らない」ことも実測**である。

### io-console が通った

`tools/verify_gem_tests.rb io-console` が **28 tests / 109 assertions /
0 failures / 0 errors / 0 omissions** で PASS。sanity も ok。
記録は Step 169 に分ける。c-testsuite 00078 の skip も外れ、**skips が 47 → 45** になった。

---

## Step 169 — io-console 0.8.2 を記録する(M5 H6)

7 件計画の 4 番。**1 件の gem に 2 つのコンパイラ側修正(Steps 167・168)が要った**、
これまでで最も重い default gem。gem 自身の test/unit スイートが
**28 tests / 109 assertions / 0 failures / 0 errors / 0 omissions** で PASS。
検証済み gem は **15 件**。

### 「tty を要求するテストが多い」という事前の懸念は、実測では問題にならなかった

計画表には「**tty を要求するテストが多い**。非 tty 環境では omission/skip に落ちるので、
(d) レベルの証拠として十分かを個別に判断し、足りなければ pty 経由の実走を検討する」と
書いていた。実測は次のとおり:

- **omission も skip も pend も 0 件**だった
- `test_raw` / `test_noecho` / `test_getpass` / `test_intr` / `test_cursor_position` など、
  **tty を要する主要なテストは `PTY.open` 経由で実際に走って通っている**。
  `PTY.open` は制御端末を必要としないので、非 tty セッションでも成立する

一方、ソース中の `def test_` は **37 個あるのに走ったのは 28 個**である。差の内訳を
実測で詰めた:

| 件数 | 理由 |
|---|---|
| 5 | `IO.console` が真であることを条件とする `class_eval` の中にあり、制御端末が無いと**定義そのものがされない**(`test_get_winsize_console` / `test_set_winsize_console` / `test_getch_timeout` / `test_pressed_valid` / `test_pressed_invalid`) |
| 4 | 2 つの `class_eval` ブロックで同名が二重定義され、後の定義が勝つ(`test_close` / `test_console_kw` / `test_sync` / `test_ttyname`) |

**ホスト gcc 対照も同じ 28 tests / 109 assertions で完全一致**するので、
これは環境の性質であって rubycc の非ではない。「37 個あるはずが 28 個」という差は
記録に残さないと後から欠陥に見えるので notes に書いた。

### probe 13 件が全て gcc と一致していたのに、2 つのギャップが出た

io-console の extconf は 13 件の probe を持ち、**その全てが rubycc と gcc で一致**した。
それでもビルドは 2 度落ちた(Step 167 のヘッダ宣言漏れ、Step 168 のブロックスコープ
関数宣言)。**probe の一致は「同じものがビルドされる」を意味しない**という Step 160 以来の
教訓の、最も強い実例である — 一致していたのは probe の**結果**であって、
その先のコンパイルではない。

### 7 件計画の折り返し地点としての評価

1〜4 番(io-nonblock・io-wait・erb・io-console)で **3 つのギャップ**が出た
(リンカの LOAD セグメント、ヘッダの宣言漏れ 2 件、ブロックスコープ関数宣言)。
「安い順・リスクの低い順」に並べたはずの前半でこれだけ出たので、
**この計画の値打ちは検証済み gem の数ではなく、出てくるギャップの方にある**。
残る 5〜7 番(digest の多 ext、zlib・psych のシステムライブラリ依存)は
計画時点から「検証済み gem を増やす以上の意味がある」と見ていた 3 件である。

---

## Step 170 — digest 3.2.1 を記録する(M5 H6)

7 件計画の 5 番、**コーパス初の多 ext gem**。`ext/digest` の下に extconf.rb が 6 つ
(digest 本体 + bubblebabble / md5 / rmd160 / sha1 / sha2)あり、`.so` も 6 つ出る。
gem 自身の test/unit スイートが
**98 tests / 215 assertions / 0 failures / 0 errors / 0 omissions** で PASS。
検証済み gem は **16 件**。

### 「mkmf shim と rmake の入れ子 ext 対応が試される」— 何も要らなかった

計画表はここを難所と見ていたが、**6 つの `.so` が 1 回の `gem install` で
すべて rubycc + rmake からビルドされ、フラグも shim の変更も不要**だった。
RubyGems は `spec.extensions` の各 extconf.rb を順に回すだけで、
rubycc 側から見れば単一 ext の gem が 6 回来るのと変わらない。
**難所と見ていたところが素通りだった**ので、そう記録する。

### sanity は 6 つ全部を名指しする必要があった

sanity ゲートは**差し込んだ `.so` が 1 つ残らず `$LOADED_FEATURES` に現れること**を
要求する(`missing = injected - loaded_paths`)。`require "digest"` だけでは
`digest.so` と `sha2.so` の 2 つしかロードされない — 残りは `Digest` の
`const_missing` が**使われたときに初めて**取り込む遅延ロードだからである。
そこでレシピの `requires` に 6 つ全部を並べた。
**多 ext gem では sanity の書き方が単一 ext gem と変わる**ことが、この gem で分かった。

### この gem の証拠は他より直接的

digest のスイートは**既知の入力に対する既知の 16 進ダイジェスト**を突き合わせる。
つまり **round 関数を誤コンパイルすれば、落ちるのではなく値が違う**形で出る。
「クラッシュしなかった」ではなく「正しい値を出した」を確かめている点で、
コーパスの他の gem より証拠として直接的である。

### probe は 3 件、gcc と一致

`CommonCrypto/CommonDigest.h` は no(macOS 専用)、`u_int8_t` と `sys/cdefs.h` は yes。
rubycc・gcc とも同じで、**両者とも同梱のアルゴリズム実装をコンパイルしている**
(プラットフォーム側の実装ではなく)。

---

## Step 171 — zlib 3.2.3 を記録する(M5 H6)

7 件計画の 6 番、**コーパス初のホストシステムライブラリ依存 gem**。
R10 が「システムライブラリに依存する gem」として想定していたケースの第 1 号で、
ホストの `/usr/include/zlib.h` と `-lz` を実際に使う。gem 自身の test/unit スイートが
**97 tests / 540 assertions / 0 failures / 0 errors** で PASS。
検証済み gem は **17 件**。

### probe が失敗しても**ビルドは止まらない** — だから Makefile を読んだ

extconf.rb の `have_library('z', 'deflateReset(NULL)', 'zlib.h')` は try_link なので、
成功は「rubycc がホストの `zlib.h` を見つけ、かつ `-lz` にリンクできた」を意味する。
問題は**失敗したときで、ビルドは止まらず同梱 zlib のブランチに黙って切り替わる**
(そのソースを gem は同梱していないので、そこから先で別の失敗をする)。
つまり「ビルドが通った」だけでは**どちらの経路を通ったか分からない**。
そこで生成された Makefile を読み、`-DHAVE_ZLIB_SIZE_T_FUNCS` が立っていること、
`ZSRC` が空であることを確認した。Step 160 で払った
「合格件数だけを見て経路を確かめない」の代償を繰り返さないための手順である。

probe は 7 件すべて yes で、ホスト gcc 対照と一致した
(`deflateReset` in `-lz`、`crc32_combine`、`adler32_combine`、`z_crc_t`、`z_size_t`、
`crc32_z`、`adler32_z`)。

### DT_NEEDED に `libm.so.6` が入らない — 意図した差

ビルドされた `zlib.so` の DT_NEEDED には gcc 版と同じく `libz.so.1` が入る。
一方 **gcc 版には `libm.so.6` も入るが、rubycc 版には入らない**。
`LIBS` は両者とも `$(LIBRUBYARG_SHARED) -lz -lm -lpthread -lc` で同じであり、
差が出るのは **rubycc のリンカが「未定義シンボルを実際に供給したライブラリ」だけを
DT_NEEDED に記録する**ため。zlib.c は libm のシンボルを 1 つも参照していないので、
`-lm` は与えられても記録されない。未定義シンボルは全て解決し、
スイートはどちらでも通る。**バグではなく設計どおりの差**なので、そう記録する。

---

## Step 172 — psych 5.3.1 を記録する(M5 H6)

7 件計画の 7 番、最後の 1 件で最重量。ホストの libyaml に依存する。
gem 自身の test/unit スイートが
**633 tests / 1,598 assertions / 0 failures / 0 errors / 0 omissions** で PASS。
検証済み gem は **18 件**。これで **7 件計画は完了**。

### rubycc の pkg-config シムが、対照と**違う経路**を選ばせた

この gem の一番の発見はここである。extconf.rb はまず `pkg_config('yaml-0.1')` を試し、
空振りしたときだけ `find_header('yaml.h')` + `find_library('yaml', 'yaml_get_version')`
に落ちる。**このホストには pkg-config が 1 つも入っていない**ので、
gcc 対照は `not found` でフォールバック側を通る。ところが rubycc 経由では

```
checking for pkg-config for yaml-0.1... [" ", "", "-lyaml"]
```

と出る — **rubycc 自身の `exe/rubycc-pkgconf` が答えた**ので、pkg_config の枝が走った。
`RbConfig::CONFIG["PKG_CONFIG"]` は `""` だがキー自体は存在するため、シムが差し込まれる。

最終的な `LIBS` は両者とも `$(LIBRUBYARG_SHARED)  -lyaml -lm -lpthread  -lc` で一致し、
スイートも通る。**が、両者は同じ configure 経路を通っていない**。
Step 160 で払った代償(合格件数の一致を「同じものがビルドされた」証拠と読んだ)を
繰り返さないため、**合致した結果ではなく食い違った経路の方を記録する**。

### 副産物 — rmake に `MAKE` マクロが無い(GAPS F)

ビルド中に `cd libyaml &&  clean` という出力が出た。生成 Makefile の 287 行目は
`	-cd libyaml && $(MAKE) clean` で、**`$(MAKE)` が空に展開されている**。
最小再現を取ったところ:

| | `$(MAKE)` | `$(CC)` |
|---|---|---|
| rmake | `[]` | `[]` |
| GNU make | `[make]` | `[cc]` |

POSIX は `MAKE` を組み込みで定義することを要求している。
今回当たった規則は行頭 `-` でエラー無視、しかもこのビルドはホストの libyaml を使うので
**psych の合否には影響していない**。だが同じ Makefile の 282 行目
`cd libyaml && $(MAKE)` は**同梱 libyaml を実際にビルドする規則**で、
そこでは `cd libyaml &&` に潰れて**黙って no-op になる**。
横断の決まりごと「ギャップの修正は別ステップ」に従い、docs/GAPS.md の F として残した。

---

## Step 173 — rmake に組み込みマクロ `MAKE` を実装する(M5 H6)

Step 172(psych)が露出させたギャップ F の修正。横断ルール
「ギャップの修正は別ステップに切る」に従って独立したステップにした。

### 症状 — **失敗ではなく無音**

psych のビルド中に `cd libyaml &&  clean` という出力が出た。
生成 Makefile の該当行は `	-cd libyaml && $(MAKE) clean` で、
**`$(MAKE)` が空に展開されていた**。POSIX は `MAKE` を組み込みで定義することを
要求しているが、rmake は定義していなかった。最小再現:

| | `$(MAKE)` | `$(CC)` |
|---|---|---|
| rmake(修正前) | `[]` | `[]` |
| GNU make | `[make]` | `[cc]` |

この欠陥の質が悪いのは、**エラーにならない**ところである。
`cd sub && $(MAKE)` は `cd sub &&` に潰れる。同梱ライブラリを再帰 make で
ビルドする gem では、ビルドが走ったように見えて**何も作られない**。
psych で表に出たのは行頭 `-` でエラー無視の `clean` 側だったこと、
このビルドがホストの libyaml を使ったことの 2 つの偶然によるもので、
**同じ Makefile の同梱 libyaml をビルドする側の規則を踏んでいたら無音で壊れていた**。

### 値は「`make`」ではなく「rmake 自身の絶対パス」

ここが唯一の設計判断。GNU make に倣えば `make` だが、
**rubycc の前提はホストに make も gcc も無いこと**なので、それでは契約が壊れる
(再帰ビルドだけがホストの GNU make + gcc に流れる)。したがって値は

1. `ENV["MAKE"]` が非空ならその値(RubyGems の rubygems_plugin が
   rmake を指す値を設定して起動するので、それを再帰先へ伝播させる)
2. なければ `File.expand_path($PROGRAM_NAME)`

とし、**`make` へのフォールバックは置かない**。

### 優先順位 — `overrides` とは扱いを変える必要があった

`Parser` はコマンドライン `VAR=value` を `@overrides` に持ち、
Makefile 側の代入を `return if @overrides.key?(name)` で無効化している。
**組み込み既定値をこの経路に相乗りさせてはいけない** — make の規則では
Makefile の `MAKE = foo` は既定値に勝つからである。そこで
`defaults:` を別のキーワード引数として足し、**通常の変数として先に seed** した。
結果の優先順位は コマンドライン > Makefile の代入 > 既定値。

`CLI` が既定値の唯一の決定者で、`Parser` に `ENV` は読ませていない
(テストから既定値を注入できるようにするため)。

### `CC` は今回は入れない

上の表のとおり `$(CC)` も空だが、**実測された失敗が無い**。
mkmf は必ず `CC = ...` を書き出すし、rmake はどのみちコンパイラ語を
rubycc の Driver に差し替えるので、既定値を足しても mkmf コーパス全体の
挙動を変えるリスクの方が大きい。**推測でギャップを埋めない**方針に従って見送った。

### 検証

ユニットテスト 11 件のほか、実際に再帰起動が通ることを確認した:

```
$ rmake                       # all: cd sub && $(MAKE) hello
cd sub && /home/nuna/projects/rubycc/exe/rmake hello
recursed into sub
```

rmake はレシピをシェルに渡さず argv 配列で `Process.spawn` するので、
`cd` は組み込みで `state.cwd` を動かし、そこへ rmake 自身が子プロセスとして起動される。

---

## Step 174 — musl 検証ジョブを Tier B に足す(M5 H6)

「環境が無くて測れていないこと」3 件(ROADMAP §8)の 1 件目。**musl(x86_64)**。
このステップは**足場を作るところまで**で、実測値の記録は次のステップに分ける
(このステップは走らせる仕組みを足しただけで、まだ 1 度も走っていない)。

### なぜここが弱点なのか

M5 は「glibc/musl 互換ヘッダ」を掲げているが、**その主張を支える計測は全て
glibc 側で取られている** — ABI ハーネスも、コーパスも、
`data/verified_gems.json` の全 18 エントリ(全て `glibc x86_64 / ruby 3.4.5`)もである。
**掲げた主張の半分が一度も測られていない**。手元に Docker が無いので CI でしか測れず、
§3.1 の負債表で H3 に割り当てられたまま H6 まで来ていた。

### `container:` を使わない

GitHub Actions のジョブコンテナには、ランナーが**自前の glibc リンクの node** を
差し込む。Alpine イメージはそれを実行できないので、`container: ruby:4.0-alpine` に
すると `uses:` を使うステップが軒並み動かなくなる。
そこで**チェックアウトはホスト(glibc)側で済ませ、そのディレクトリを bind mount して
自分で `docker run` する**構成にした。Actions 側は glibc のまま、
**musl に置かれるのは rubycc だけ**になる。測りたいのはそこだけである。

コンテナ内で走るのは `.github/scripts/musl-suite.sh`。インラインの `run:` に
書かないのは、`docker run ... sh -c '...'` の入れ子クォートが読めなくなることと、
**ファイルなら CI の外で `sh -n` にかけられる**からである(このステップで実際にかけた。
それがローカルで取れる唯一の検証だった)。

### Alpine の /bin/sh には `pipefail` が無い

busybox ash では `set -o pipefail` が当てにできない。ログを `tee` で流しつつ
終了状態も取りたいので、**パイプラインの中でステータスをファイルに書いて外で読む**形にした。
90 分近く走るジョブなので、ログを最後まで溜め込む形(リダイレクト後に `cat`)は採らない
— どこで止まったか見えないのは実運用で困る。

### 週次は回帰、手動は記録

`tools/verify_gem_tests.rb` は `--update` に `--step N` を要求する(番号が evidence に入る)。
**週次のスケジュール実行には渡せる番号が無い**。ここは仕様の綻びに見えるが、
分けて考えると 2 つの別の問いになっている:

| 起動 | `verify_step` | phase 2 |
|---|---|---|
| 週次スケジュール | 空 | **読み取り専用** = 「この 3 gem は musl でまだビルドでき、テストが通るか」という**回帰**の問い |
| 手動 dispatch | ステップ番号 | `--update` で DB を書き、アーティファクトとして上げる。**そのファイルをそのままコミットする**ので、DB を書くのはツールだけという規約は保たれる |

記録用の dispatch では **musl 以外の 4 ジョブを走らせない**
(各ジョブに `if: inputs.verify_step == ''` を付けた)。他の 4 本を引き連れると
1 回 255 分になり、**記録そのものより随伴のほうが高くつく** — 無料枠 2,000 分/月
という前提では無視できない差である。`schedule` イベントでは `inputs` が null で、
GitHub の式評価は `null == ''` を真とするので、**週次は従来どおり 5 ジョブ全部**走る。

### `ci_check_skips.rb` をこのジョブでは回さない

**Alpine には aarch64-linux-musl のクロスツールチェインが無い**ので、
aarch64 差分テストは設計上まるごと skip される。Tier A の閾値は
**その skip だけで発火してしまい、musl について何も語らない**。
acceptance ジョブが回さない理由(実行形状が変わる)とは別の理由なので、両方を注記した。

### `zlib-dev` / `yaml-dev` を先に入れる

検証する 3 gem(io-wait / stringio / json)はどちらも使わないが、入れてある。
**パッケージが無いせいで落ちた probe を「musl の差」と読み違えないため**である。
Step 160 以降ずっと同じことをしている — 差が出たときに、それが測りたかった差なのかを
最初から切り分けられるようにしておく。

---

## Step 175 — musl の初回実測(M5 H6)

Step 174 で入れたジョブを初めて走らせた。**通らなかった。それがこのステップの成果である。**
`data/verified_gems.json` に musl の記録は 1 件も足さない — 通っていないからである。

### 実測値

```
ruby arch:  x86_64-linux-musl
gcc target: x86_64-alpine-linux-musl
```

| | runs | assertions | failures | errors | skips |
|---|---|---|---|---|---|
| glibc(Step 173) | 2,743 | 8,121 | 0 | 0 | 45 |
| **musl(初回)** | **2,743** | **6,968** | **21** | **18** | **550** |

**runs が同数**なのは同じテストが集まっている証拠。skips の +505 は
Alpine に aarch64 のクロスツールチェインが無いためで、これは設計どおり(Step 174)。

### 39 件の内訳 — 3 分の 1 は rubycc の欠陥ではない

| 種別 | 件数 | 中身 |
|---|---|---|
| **gcc 対照の方がコンパイルできなかった** | **13** | ABI ハーネスのケース自体が glibc 固有 |
| rubycc 側の差 | 26 | 下記 |

13 件は**参照実装が先に落ちている**ので rubycc の合否を判定できていない。実例:

- `features`: ケースが `__GLIBC__` / `__GLIBC_MINOR__` / `__GLIBC_PREREQ` を印字する。
  musl にこれらは無い。**このケースは musl では原理的に走らない。**
- `termios`: musl の `struct termios` のメンバは `__c_ispeed` / `__c_ospeed` で、
  ケースが名指しする `c_ispeed` / `c_ospeed` ではない。
- `pthread`: musl は `pthread_kill` を `<pthread.h>` で宣言しない。

**これらは「rubycc が musl で壊れている」ではなく「ハーネスが glibc で書かれている」**。
ただし**裏に rubycc の欠陥が隠れていないことの証明にはならない** — 対照が取れていない以上、
判定は保留である。ハーネスの機種・libc パラメタ化は別ステップになる。

### 残り 26 件 — 同梱ヘッダが glibc の ABI を焼き込んでいる

一番直接的なのが `<stdint.h>`:

```
-sizeof(int_fast16_t) = 4   ← gcc(musl)
+sizeof(int_fast16_t) = 8   ← rubycc
```

musl は `int_fast16_t` / `int_fast32_t` を 32 ビット型に、glibc は `long` にしている。
rubycc の同梱ヘッダは **glibc 側の値を焼き込んでいた**。
M5 が掲げた「glibc/musl 互換ヘッダ」の、**測っていなかった半分が実際に外れていた**。

`TestRubySmoke` の 5 件はいずれも同じ原因で、**同梱ヘッダに `stdckdint.h`(C23)が無い**。
ruby 4.0 の `ruby/internal/stdckdint.h` が musl 環境では `#include <stdckdint.h>` の枝を通る。
**ruby 4.0 + glibc では Tier A が緑**(`ad602f4`)なので、これは Ruby バージョンの差ではなく
musl 側の要因である — 交絡は推測ではなく実測で潰した。

### 初回実行で先に壊れたのは自分の足場だった

phase 2(gem install)は**走らなかった**。`set -e` が、パイプライン内のサブシェルを
rake の失敗直後に落とし、**終了ステータスを書き出す `echo` に到達しなかった**ためである。
その後 `cat tmp/ci/rake-status` が失敗し、スクリプトごと終わった。

`sh -n` は通っていた。**構文は正しく、意味が間違っていた**という、
ローカルで取れる検証の限界そのものの形で出た。
両フェーズとも「失敗するのが当たり前」の段階なので、errexit は 2 フェーズの手前で切り、
各フェーズの状態は明示的に拾う形に直した。

---

## Step 176 — コーパスの `version: nil` 4 件を固定する(M5 H6)

`docs/GAPS.md` §2 の負債。`test/corpus/gems.rb` の bigdecimal / date / racc / redcarpet が
`version: nil` = 最新追従のままだった。

固定先は `data/verified_gems.json` が保証しているバージョン
(4.1.2 / 3.5.1 / 1.8.1 / 3.6.1)。**これは committed スナップショットで
`latest` が既に解決していた値と同じ**なので、requested 列が変わるだけで
resolved 列は動かない。理由は 2 つ:

- **census ジョブは差分で落ちる**。`latest` のままだと、**上流がリリースしただけで赤くなる** —
  そのジョブが唯一検出したいこと(rubycc のヘッダ網羅性が変わった)ではない理由で。
- コーパスが記述するバージョンと、検証 DB が保証するバージョンが食い違いうる。

### 再生成で分かった副産物 — スナップショットが既に古かった

`rake corpus:census` をかけたところ、固定による差分(requested 列と fetched 日付)の他に
**stackprof の note が変わった**。`gems.rb` の note は Step 146 で
「probe は無い」→「実際には `rb_postponed_job_preregister` 等 have_func が 4 件ある」に
直されていたのに、**スナップショットの方が再生成されず古いままだった**。
週次の census ジョブはこれを差分として検出する設計なので、
**このステップまで気付かれずに来たのは、そのジョブの結果が見られていなかった**ということになる。

---

## Step 177 — オーバーフロー検査組み込み関数 3 つ(M5 H6)

Step 175 が露出させた**ギャップ H(`stdckdint.h` 欠落)を潰すための下ごしらえ**。
このステップでは**組み込み関数だけ**を実装し、ヘッダは次のステップに分ける。

```c
__builtin_add_overflow(a, b, res)
__builtin_sub_overflow(a, b, res)
__builtin_mul_overflow(a, b, res)
```

### なぜヘッダの前に組み込み関数なのか

ruby の `ruby/internal/stdckdint.h` は `<stdckdint.h>` を include したあと
`ckd_add` / `ckd_sub` / `ckd_mul` が**定義されている前提**で進み、
`ruby/internal/memory.h` は実際に `ckd_mul` を使う(`rbimpl_size_mul_overflow`)。
つまり **`ckd_*` を定義しない `stdckdint.h` を置くのは嘘**であって、
「include が通る」だけの解決にしかならない。C23 の `ckd_*` は型ジェネリックなので、
`_Generic` を持たない rubycc では**組み込み関数として実装するのが唯一まともな道**である。

### バックエンドのフラグを使わず 128 ビットに落とした

x86 の `seto` / aarch64 の `cset ... vs` を使えば 1 命令だが、
**2 つのバックエンドに手を入れることになるうえ、無限精度のセマンティクスと合わない**。
`__builtin_*_overflow` は「a op b を無限精度で計算し、格納先の型に収まらなければ 1」であって、
「計算した型の中で桁あふれしたか」ではない。**オペランドと格納先の型が違ってよい**のがその証拠で、
`int a = -1; unsigned b = 1;` を `unsigned` に足すと**無限精度では 0**、返り値は 0 になる。

そこで各オペランドを**自分の型のまま** 128 ビットへ拡張して計算する。
64 ビット以下同士なら加減乗のいずれも 128 ビットに厳密に収まる。

### 1 箇所だけ 128 ビットでも名前を付けられない値がある

非負同士の積だけは `(2**64-1)**2` が **符号付き 128 ビットに収まらない**
(ビットパターンは正確でも、符号付きとして読むと負に見える)。
負のオペランドを含む積は絶対値が `2**63 * 2**64 < 2**127` なので符号付き解釈で正確。
したがって**乗算のときだけ**「両オペランドが非負 かつ 積の符号ビットが立っている」を
無条件オーバーフローとして OR する。真の積が `2**127` 以上ということは、
64 ビット以下のどの格納先にも収まらないからである。
`size_t` 同士の `SIZE_MAX * SIZE_MAX` が実際にこの経路を通る。

### 検証

ホスト gcc との差分で確かめた(このプロジェクトの流儀)。
`SIZE_MAX * SIZE_MAX`、`LLONG_MIN - 1`、`int -1 + unsigned 1`、
`signed char` への `200 + 100` を含めて**出力がバイト単位で一致**する。

### 積み残し — aarch64 では乗算形が使えない

`__builtin_mul_overflow` は 128 ビット乗算経由なので **IR の `:mulhi` に依存する**。
aarch64 バックエンドは `:mulhi` を A4 の未実装項目として明示的に拒否しているため、
**aarch64 では乗算形だけがコンパイルできない**(加減算形は動く)。
サンプルも `test_examples_aarch64.rb` の `PENDING` に載せた。
`umulh` / `smulh` 1 命令で塞げるが、**`stdckdint.h` を出す前に塞がないと
aarch64 の ruby ビルドを壊す**(memory.h が `ckd_mul` を使うため)。次のステップにする。

---

## Step 178 — aarch64 に `:mulhi` を実装する(M5 H6 / M4 A4 の前倒し)

Step 177 の積み残し。**`UMULH` 1 命令**で塞がった。

これは本来 M4 A4 の残項目で、A4 受け入れ時に「aarch64 固有ではない既存の未実装機能」として
examples 3 件の不一致に数えられていたものである。**前倒ししたのは、
これを塞がずに `stdckdint.h`(ギャップ H)を出すと aarch64 の ruby ビルドを壊すから**である
— `ruby/internal/memory.h` は `ckd_mul` が定義されていればそれを使い、
`ckd_mul` は `__builtin_mul_overflow` = `:mulhi` に落ちる。
**ヘッダを足すことが、aarch64 でだけコンパイルを壊す**という形になっていた。

### エンコードは実測で確定させた

`UMULH Xd, Xn, Xm` = `0x9BC07C00 | (Rm << 16) | (Rn << 5) | Rd`。
推測で置かず、`aarch64-linux-gnu-as` で単発の `umulh x9, x9, x10` をアセンブルして
`9bca7d29` を得、rubycc が生成した語を `aarch64-linux-gnu-objdump` で逆アセンブルして
同じ語・同じニーモニックになることを確かめた(R8 と同じ「ABI は実測、写さない」の流儀)。

### 副産物 — 古い PENDING が 1 件外れた

`examples/m1/step28_wideint.c` も同じ `:mulhi` だけに依存しており、
`test_examples_aarch64.rb` の `PENDING` に「A4: 128-bit multiply」として残っていた。
**塞いだ結果この理由は成り立たなくなった**ので外した。
skips が 46 → 44 に減っているのはこの 2 件(step177 と step28_wideint)である。
**PENDING を消し込まないと、通るようになった機能が黙って検証されないまま残る。**

---

## Step 179 — `stdckdint.h` を同梱する(M5 H6)

Steps 177・178 の仕上げ。**ギャップ H が閉じた。**

### freestanding 側に置いた

C23 の `ckd_*` は**全整数型に対して型ジェネリック**で、コンパイラにしか表現できない。
だから C23 はこのヘッダを**処理系の責任**にしている。
rubycc でも `include/libc/` ではなく `include/`(`stdarg.h`・`stdbool.h` と同じ層)に置き、
中身は Step 177 の組み込み関数への 3 行のマクロにした。
台帳の freestanding は 8 → 9 本、合計 77 → 78 本。

`docs/HEADER-LICENSING.md` には **Step 135 の時点で「`stdckdint.h` は
`__builtin_add_overflow` が無いのでスコープ外」と書いてあった**。
その見送り理由が Step 177 で消えたので、同じ場所に消し込みを書いた。

### 引数の順が組み込み関数と違う

C23 は**結果ポインタを第 1 引数**に置く(`ckd_add(r, a, b)`)。
`__builtin_add_overflow(a, b, r)` とは逆なので、マクロで入れ替えている。

### musl の条件はローカルで再現できた

これが一番効いた発見である。この不具合は musl で見つかったが、**musl は必要ない**。
引き金は「ホストの ruby の `config.h` が `HAVE_STDCKDINT_H` を焼き込んでいるか」だけなので、
**`-DHAVE_STDCKDINT_H` を渡せばローカルの glibc + ruby 3.4.5 でそのまま再現する**:

```
$ rubycc -c rh.c -DHAVE_STDCKDINT_H -I<rubyhdrdir> -I<rubyarchhdrdir>
.../ruby/internal/stdckdint.h:48:1: error: stdckdint.h: No such file or directory
```

ヘッダを一時的に外して**このエラーが実際に出ることを確かめてから**回帰テストを書いた。
90 分の CI 往復を待たずに済むうえ、**Tier A(push ごと)で守られる**ようになる。
**「musl でしか出ない」と決めつけずに引き金を特定すると、テストがずっと安く手に入る。**

### gcc 対照が取れないケース

**このホストの gcc には `<stdckdint.h>` が無い**(実測: `fatal error`)。
このプロジェクトは差分テスト主体だが、**ここだけはオラクルが存在しない**。
そこで既知の期待出力と突き合わせる形にし、**その理由をテストのコメントに明記**した。
正しさの根拠は Step 177 側にある — `__builtin_*_overflow` そのものは
ホスト gcc との差分でバイト一致まで確かめてある。

### サンプルを追加しなかった(運用ルールからの逸脱)

**「ステップ完了ごとに `examples/` に C サンプルを追加する」というルールに従っていない。**
`test/test_examples.rb` は `examples/**/*.c` を無条件に gcc との差分で検証するので、
**gcc が `<stdckdint.h>` を持たない以上、サンプルを置けば必ず落ちる**。
除外の仕組みは `test_examples.rb` には無い(aarch64 側の `PENDING` は別ファイルの別機構)。
**このためだけに除外機構を作るのは割に合わない**と判断して見送った。
ヘッダの実行時挙動は `test_freestanding_headers.rb` 側で検証している。

---

## Step 180 — ABI ハーネスを libc でパラメタ化する(M5 H6)

Step 175 が露出させた**ギャップ I** への対処。ハーネスは機種(x86-64 / aarch64)で
パラメタ化されていたが、**libc の軸が無かった**。

### 問題は「rubycc が落ちた」ではなく「対照が先に落ちた」

musl では 13 ケースで**参照実装である gcc の方が先にコンパイルに失敗**していた。
プローブが glibc 自身の名前(`__GLIBC__`、`__sigset_t`、`_ISupper`、
`struct termios` の `c_ispeed`)で書かれているためである。
**この状態は rubycc について何も語らない** — 落ちているのはハーネスの前提であって、
コンパイラではない。にもかかわらず失敗として報告される。

### 2 種類ある

| 種別 | Spec の表現 | 例 |
|---|---|---|
| **ヘッダまるごとが片方にしか無い** | `libc: :glibc` | `features.h`(glibc 自身のバージョン機構)、`sys/cdefs.h`(musl には**インストールすらされない**) |
| ヘッダは共通だが**一部の名前が glibc 固有** | `glibc:` バンドル | `RTLD_DEEPBIND`、`LC_PAPER`、`POLLREMOVE`、`__fsid_t` ほか |

前者は `skip` にするが、**理由を必ずメッセージに書く**
(`<features.h> exists only on glibc; this host's libc is musl`)。
`docs/CI.md` が繰り返し書いているとおり、**静かに通る skip がこのプロジェクトの敵**である。

### glibc 側のプローブは 1 バイトも変えない、を不変条件にした

パラメタ化の目的は **musl を走らせられるようにすること**であって、
**長年緑だった glibc の基準線を動かすことではない**。
そこで「glibc ホストで生成されるプローブのソースが変更前とバイト単位で同一」を
不変条件に置き、テストにした。

ここで当初の設計(`glibc:` の項目をリストの**末尾に連結**する)が**破綻した**。
glibc 固有と実測された項目の多くは**リストの途中**にあるからである
(`LANGINFO` の `DECIMAL_POINT` は 60 項目中 4 番目)。末尾に足せば行順が変わる。
そこで **`GLIBC_ONLY` マーカー**を導入し、リスト中のその位置に差し戻す形にした。

検証は実測でやった。**変更前の 2 ファイルを `git show HEAD:` で取り出して別プロセスで読み、
47 個の Spec すべてのプローブ出力を突き合わせた**結果、**46 件がバイト単位で一致**。

**唯一動いたのが `PTHREAD`** で、これは避けられない。`pthread_kill` が
snippet の**式の途中**(`+ sizeof(pthread_kill(*t, 0))`)にあり、
リストの要素として動かせないためである。glibc 側で**検査内容は変わらない**が、
テキストは変わる。**「1 件だけ動いた」を隠さずに記録しておく。**

### aarch64 は常に glibc

`run_abi_case_aarch64` の実効 libc は**ホストが何であれ `:glibc`** に固定した。
クロスツールチェインが `aarch64-linux-gnu` = glibc だからである。
musl ホストでこれを取り違えると、**両側とも glibc のプローブから
glibc 固有の検査だけが落ちる**という無意味な比較になる。

### まだ閉じていない

gcc は**最初の数件でエラーを打ち切る**。したがって上の 13 件の陰に、
まだ分類されていない glibc 固有の項目が隠れている可能性がある。
**推測で分類を広げなかった** — 隣接する未実測の項目
(`_ISalpha` 以降、`RTLD_NODELETE`、`POLLRDHUP`、`LC_ADDRESS` 以降)は共通のまま残し、
「musl の gcc が報告していないので次の実走まで共通扱い」とコメントに書いた。
**ギャップ I は消さず、「分類が未完」に書き換えて残した。**

---

## Step 181 — musl 2 回目の実測と、その反映(M5 H6)

Steps 177〜180 を入れた状態で musl ジョブを回した。**測って初めて分かることばかりだった。**

### 数字

| | runs | assertions | failures | errors | skips |
|---|---|---|---|---|---|
| glibc | 2,763 | 8,172 | 0 | 0 | 44 |
| musl(1 回目・Step 175) | 2,763 | 6,968 | 21 | **18** | 550 |
| **musl(2 回目)** | 2,763 | 7,043 | 22 | **9** | 555 |

**errors が 18 → 9**。ギャップ I の対処(Step 180)が効いた分である。
failures が 21 → 22 に増えているのは**後退ではない** — **対照が取れるようになった結果、
「判定できない」だったものが「差がある」に変わった**ものが含まれる。
「分からない」が「分かった」に変わるのは前進である。

### 予告どおり、打ち切りの陰に隠れていた

Step 180 で「gcc は最初の数件でエラーを打ち切るので、この分類は完全とは限らない」と
書いたとおりになった。2 回目で新たに出たのは 3 系統:

| ケース | 隠れていたもの |
|---|---|
| `CTYPE` | `_ISalpha` / `_ISdigit`(1 回目は `_ISupper` / `_ISlower` まで) |
| `LOCALE` | `LC_ADDRESS` / `LC_TELEPHONE` / `LC_MEASUREMENT` |
| `LANGINFO` | `_NL_ITEM` / `_NL_ITEM_CATEGORY` / `_NL_ITEM_INDEX` |

**ここで系統ごと移すことにした。** `_IS*` は glibc の分類表ビットが 1 つの enum を成しており、
2 回の実測で 4 個が落ち、通ったものは 1 つも無い。残り 3 個を個別に名指しするには
**90 分の CI を 2 回以上**回すことになる。**推論であることをコメントに明記した上で**、
系統ごと移した。**黙って広げるのと、断って広げるのは別物である。**

### バンドルに区切りが要った — `langinfo.h`

`DECIMAL_POINT` は 60 項目中 3 番目、`_NL_ITEM*` は末尾。
**1 つのヘッダで挿入位置が 2 か所**になったので、`glibc:` バンドル自身が
`GLIBC_ONLY` を区切りとして持てるようにした(前が「マーカー位置」、後ろが「末尾」)。
Step 180 の不変条件(glibc のプローブはバイト単位で不変)を崩さないための拡張である。

検証は前回と同じやり方で、**60 個の Spec すべての glibc プローブを HEAD と突き合わせ、
全件バイト単位で一致**を確認した。

### 新しい壁 — `_Noreturn`(ギャップ J)

**`stdckdint.h` を埋めても `TestRubySmoke` は musl で落ちたままだった。**
理由が変わっていた:

```
/usr/include/stdlib.h:46:1: error: expected type specifier
_Noreturn void abort (void);
```

**rubycc は C11 の `_Noreturn` 関数指定子を受け付けない。**
glibc のヘッダは `__attribute__((__noreturn__))` を使うので当たらないが、
**musl のヘッダは素の `_Noreturn` を使う**。ローカルでも 2 行で再現する。

これは**既知だった** — `include/stdnoreturn.h` は
「rubycc は `_Noreturn` を受け付けないので `noreturn` を空に展開する」と自分で書いている。
だが**その回避はヘッダ経由の利用しか覆わない**。libc 自身のヘッダが素のキーワードを
使ってくる経路は覆えていなかった。**ギャップ J として記録し、修正は次のステップに切る。**

### 3 つ目のスクリプト欠陥 — `curl` が無い

phase 2 は今度こそ走ったが、**`RUBYCC=1 gem install io-wait` が musl で成功した直後**に
上流 tarball の取得で止まった。Alpine に `curl` が入っていないためである
(`tools/verify_gem_tests.rb` はこれを呼ぶ)。**パッケージ 1 つ足りないだけで
答えの手前まで来ていた。** apk のリストに足した。

なお **rubycc が musl 上で `.so` をビルドできること自体は、この失敗の手前で確認できている。**

---

## Step 182 — `_Noreturn` 関数指定子に対応する(M5 H6)

Step 181 が記録したギャップ J の解消。**受け取って捨てるだけ**である。

### 「既知の制限」が「壁」になっていた

この制限は誰も知らなかったわけではない。`include/stdnoreturn.h` が
**自分でそう書いていた** — 「rubycc は `_Noreturn` を受け付けないので
`noreturn` を空に展開する。指定子は最適化のヒントに過ぎず、
落としても観測可能な振る舞いは変わらない」。判断自体は正しい。

**覆えていなかったのは、libc 自身のヘッダが素のキーワードを書いてくる経路**である。
glibc は `__attribute__((__noreturn__))` を使うので当たらない。
musl は `_Noreturn void abort (void);` と書く。だから

**回避策がヘッダ 1 枚に閉じているとき、その外から同じ構文が来る経路を塞げているかは
別に確かめないといけない。** ここでは 1 つの libc でしか試していなかったので、
「マクロで避けられている」が「言語機能として無い」を隠していた。

### `inline` の通り道にそのまま載せた

`_Noreturn` は C11 6.7.4 の**関数指定子**で、`inline` と文法上の位置づけが同じである。
そこで `DeclSpecInfo` に `inline_p` と対称な `noreturn_p` を置き、
既存の `reject_object_specifiers` に相乗りさせた。**新しい仕組みは作っていない。**

意味は持たせない。根拠は上記のとおり `stdnoreturn.h` が既に書いていたものと同じで、
このステップでその根拠が変わったわけではない — **変わったのは適用範囲だけ**である。

### 関数以外への適用は gcc より厳しくした

```
rubycc: error:   variable 'x' declared '_Noreturn'
gcc:    warning: variable 'x' declared '_Noreturn'
```

文言は揃えたが、**gcc が warning のところを rubycc は error にしている**。
C11 の制約違反であり、黙って通すより落とす方がこのプロジェクトの方針に合う。

### `stdnoreturn.h` を本来の定義に戻した

`#define noreturn`(空)→ `#define noreturn _Noreturn`。
**回避策を残したままにすると、次に読む人が「rubycc は今も受け付けない」と読む。**
ヘッダのコメントも、いつ・何によって前提が変わったかを書き直した。

---

## Step 183 — musl 3 回目。**初の非 glibc 記録**と、次の壁(M5 H6)

### 数字

| | runs | failures | errors | skips |
|---|---|---|---|---|
| musl 1 回目(Step 175) | 2,763 | 21 | 18 | 550 |
| musl 2 回目(Step 181) | 2,763 | 22 | 9 | 555 |
| **musl 3 回目** | **2,776** | **18** | **5** | 556 |

**39 → 31 → 23。** Steps 177〜182 が効いている。

### `data/verified_gems.json` に初めて glibc 以外の記録が入った

**io-wait 0.4.0 が musl で PASS**(26 tests / 41 assertions / 0 failures / 0 errors)。
`environment` は `musl x86_64 / ruby 4.0.6`。
**Step 158 で入れ子スキーマにしたのは、この日のためだった** — 1 gem = 1 エントリのまま
環境ごとの記録を内側に持つ形。**それまで全 18 エントリの `environment` が同じ文字列で、
スキーマの「環境ごと」の半分が一度も使われていなかった。**
`test_doctor.rb` にその記録を固定する検査を足した。

### 3 gem 中 2 gem は入らなかった

stringio(`have_type`)と json(`append_cflags`)が **extconf の probe 段階**で落ちた。
**理由は分からない** — `gem install` は「mkmf.log を見ろ」と言うが、
**その mkmf.log をアーティファクトに含めていなかった**のでコンテナと一緒に消えた。
次の実行で拾えるようにスクリプトとワークフローを直した。**推測は書かない。**

io-wait だけ通ったことには**心当たりがある** — Step 165 に書いたとおり
**io-wait の extconf は probe を 1 つも持たない**。ただしこれは仮説であって、
mkmf.log を見るまでは確定させない。

### 新しい壁 — `offsetof` の cast 形が畳めない(ギャップ K)

`ruby.h` は musl でまだ通らない。**理由がまた変わった**:

```
ruby/internal/core/rtypeddata.h:382: error: static assertion expression is not an integer constant
RBIMPL_STATIC_ASSERT(data_in_rtypeddata, offsetof(struct RData, data) == offsetof(struct RTypedData, data));
```

**ローカルで 6 行に落とせた**:

```c
#define OFF(t, m) ((size_t)&((t *)0)->m)
_Static_assert(OFF(struct A, data) == 8, "");   // rubycc: not an integer constant
```

`__builtin_offsetof` 形は畳める。**cast 形が畳めない。** gcc は両方畳む
(厳密には ISO C の整数定数式ではなく gcc の拡張だが、musl のヘッダはこれを使う)。

ここでも **Step 179 と同じ収穫**があった。**musl で見つかったが musl は要らない。**
引き金は libc ではなく**この構文そのもの**なので、CI 往復なしで直せる。
`ruby 4.0.6 + glibc` では通ることも手元で確認した(Tier A も `4fc71e5` で緑)ので、
**Ruby バージョンの差ではない**ことは実測で潰してある。

---

## Step 184 — `offsetof` の cast 形を畳む(M5 H6)

ギャップ K。`((size_t)&((T *)0)->m)` が定数式として畳めなかった。

### 機構は既にあり、使われていない経路があった

`constant_evaluator.rb` の `evaluate_integer_or_address` には
**この用途そのものを名指ししたコメント**が最初から書かれていた
(「the "(size_t)&((T\*)0)->m" offsetof idiom」)。
`@pointer_int` リゾルバも `generator.rb` の `address_int_resolver` が供給していた。
**足りなかったのは、その経路が `_Static_assert` に届いていないこと**である
— リゾルバはグローバル初期化子の畳み込みにしか渡されておらず、
`_Static_assert` はパーサ側で評価されるので素通りしていた。

### リゾルバを増やさず、評価器の中に置いた

この畳み込みに要るのは**構造体のレイアウトだけ**で、
評価器は `evaluate_builtin_offsetof` のために既にそれを持っている。
シンボルテーブルは要らない。**評価器の中に置けば、パーサ経路(`_Static_assert`・
enum 値・ビットフィールド幅・配列長)と IR 生成経路(グローバル初期化子)の
両方で同時に効く**。コールバックにしていたら、パーサ側にオフセット計算の
第二実装を持つか、リゾルバを渡す配線を全呼び出し箇所に足すことになっていた。

`@pointer_int` は**消していない**。あちらが返すのは
「シンボル + addend」というリロケーションであって、評価器が返す整数とは別物である。
`&global.m` は今回の畳み込みでは畳めず、従来どおりリゾルバへ回る
(`test_address_constant_globals.rb` の 18 件が無変更で通ることがその証拠)。

### 引き算形はまだ畳めない — musl がどちらを使うかは未確認

```c
#define OFF_SUB(t, m) ((size_t)((char *)&((t *)0)->m - (char *)0))   // gcc: 通る / rubycc: 落ちる
```

伝統的な `offsetof` にはこの綴りの版も広く存在する。
**musl の `<stddef.h>` がどちらの綴りかは確認していない**(R11 により musl の
ソースは読めず、手元に musl も無い)。ギャップ K の最小再現(Step 183)は
直接の cast 形だったのでそちらを実装したが、**musl が引き算形なら
このステップだけでは `ruby.h` は通らない**。
**「直したので通るはず」とは書かない** — 次のステップで引き算形も畳み、
どちらであっても届くようにする。

---

## Step 185 — 対応しない gem を 1 つの文書にまとめる(M5 H6)

ユーザ依頼。**`docs/OUT-OF-SCOPE-GEMS.md` を新設**した。

### なぜ GAPS.md と分けたか

R10 は目標を「コーパスの 90% 以上」と**定量化**している。
つまり **残る 10% をどこに置くかを決めておかないと、90% の分母が読めない**。
「まだ通らない」(GAPS.md)と「通す気がない」を同じ場所に置くと、
**ギャップを消す作業と、対象外を確定させる作業が区別できなくなる。**

### 混同しやすい 2 件を節ごと分けた

**sqlite3 と pg はスコープ外ではない。** どちらも DESIGN R10 が
**スコープ内として名指し**しているのに、センサスの機械判定は `excluded` を出す。
判定が「extconf.rb のどこかに mini_portile への参照があるか」しか見ていないためである。
**判定が粗いのであって、gem が対象外なのではない。**
一覧に並べると嘘になるので、節を分けて「対象外ではないが `excluded` と出る」と書いた。

thin も同種の混同を招く。**thin 自身の拡張は純 C で対象内**であり、
対象外なのは実行時依存の eventmachine(C++)の方である。
**「gem が対象内か」と「その gem を install できるか」は別の問い**だと明記した。

### 根拠の種類を行ごとに書いた

- **実測**: ffi(`.S` 48 本)、bcrypt(extconf が `x86.o` を列挙)、
  nokogiri(configure 依存)、fcntl(上流にスイートが無い)
- **設計時の判断**: grpc、rice(いずれも C++。DESIGN が名指し、実測はしていない)

bcrypt が一番の教訓で、**C ソースだけ見ると通りそうに見える**のに
extconf を読むと `.S` 由来のオブジェクトを要求している。
**「対象外である」は extconf を読んで初めて確定することがある**ので、限界の節に書いた。

### 網羅ではないと明記した

人気上位を全走査した結果ではない。ランキングは日次で動き、
外部ランキングサイトは単一障害点になる(Step 143 で実際に片方が落ちていた)。
**「上位 N 位を全部見た」という主張はできない**ので、そう書いた。

---

## Step 186 — sqlite3 と pg の extconf を実測し、Step 185 の誤りを訂正する(M5 H6)

「センサスが sqlite3 と pg を適切に判定するよう直せるか」というユーザの問いから、
**両方の extconf.rb を実際に読んだ**。結果、**Step 185 で書いた記述が間違っていた**。

### 訂正 — sqlite3 の既定経路は本当に対象外だった

Step 185 は「sqlite3 はどちらの経路も `configure` を走らせない」と書いた。**誤りである。**
`ext/sqlite3/extconf.rb` の `configure_packaged_libraries` は
`MiniPortile` を使い `recipe.configure_options += [...]` を組み立てる。
**既定の `gem install sqlite3` は上流 sqlite3 の `configure` を実行する。**
対象内なのは `--enable-system-libraries`(または sqlcipher 系)を付けた経路だけである。

**DESIGN R10 が「sqlite3(システムライブラリ利用時)」と括弧書きしているのは、
まさにこの区別だった。** 括弧の意味を読み違えていた。

原因ははっきりしている。**DESIGN の記述だけを根拠に書き、extconf を読まなかった。**
Step 185 自身が「『対象外である』は extconf を読んで初めて確定することがある」と
bcrypt を例に書いておきながら、**同じ文書の中でそれをやらなかった。**
文書に「extconf を読んでから書くこと」を明記した。

### pg は本物の偽陽性だった

`ext/extconf.rb` の mini_portile 参照は
**26 行目の `if gem_platform = with_config("cross-build")` ブロックに丸ごと入っている**。
通常のソースインストールでは通らない。**判定が粗いのであって gem が対象外ではない。**

### つまり 2 件は同じ `excluded` でも中身が別物

| gem | 判定 | 実際 |
|---|---|---|
| sqlite3 | `excluded` | **正しい**(既定経路は configure を実行する) |
| pg | `excluded` | **誤り**(cross-build 指定時しか通らない経路を見ている) |

**「同じ判定が出ているから同じ問題」と読んではいけない**という例として記録する。

### ついでに拾った消し忘れ — センサスのスナップショット

**Step 179 で `include/stdckdint.h` を足したとき、センサスのスナップショットを
再生成していなかった。** 同梱ヘッダ集合が 60 → 61 に増え、
`stdckdint.h` の行が `gap` → `bundled` に変わり、
gap 候補の `review` 一覧からも落ちる。ここで再生成して取り込んだ。

**週次の census ジョブは差分で落ちる設計なので、これは次の週次で赤になっていた。**
Step 176 で「スナップショットが再生成されないまま古くなっていた」ことを
指摘したばかりで、**その 3 ステップ後に同じことをやっている。**
同梱ヘッダ**ファイル**を足したら、台帳(HEADER-LICENSING)だけでなく
**センサスのスナップショットも再生成する**。

---

## Step 187 — `offsetof` の引き算形も畳む(M5 H6)

Step 184 の残り。**ギャップ K はこれで両方の綴りを覆った。**

```c
#define OFF_SUB(t, m) ((size_t)((char *)&((t *)0)->m - (char *)0))
```

伝統的な `offsetof` にはこの綴りの版も広く存在し、cast 形だけでは覆えない。
**musl の `<stddef.h>` がどちらを使うかを確認できない**(R11 で musl のソースは読めず、
手元に musl も無い)以上、**両方に届かせるのが唯一「確かめずに済ませない」やり方**である。
「たぶん cast 形だろう」で止めれば、90 分の CI を回して外れを引く可能性が残る。

### ポインタ差は「指す型のサイズで割る」

`(char *)a - (char *)b` はバイト差だが `(int *)a - (int *)b` は要素数差になる。
**`char *` だから 1 で割る、という特別扱いはしていない** — 一般に指す型のサイズで割る。
両辺の指す型のサイズが違えば畳まず、`void *` のようにサイズを持たない型も畳まない
(gcc は拡張として 1 バイト扱いするが、**受理範囲をそこまで広げる理由が無い**)。
割り切れない差も**黙って切り捨てず**畳まない。

### 既存の仕組みにそのまま乗った

Step 184 で入れた `pointer_target` / `designator_address` がそのまま使えた。
足したのは `evaluate_binary` の `:sub` 分岐と、`pointer_target` の `AST::Binary` 分岐だけである。
後者のおかげで **ポインタ + 整数**(`&((t *)0)->m + 1`)も畳めるようになった —
**分岐 1 つで自然に入ったので見送らなかった。**

---

## Step 188 — センサスのスナップショットを決定的にする(M5 H6)

**週次の `census` ジョブは構造的に絶対に緑にならなかった。**

このジョブは再生成後に `git diff --exit-code` で差分を見て、
出たら失敗する設計である。検出したいのは「rubycc のヘッダ網羅性が変わった」ことだけ。
ところが**スナップショットには実行ごとに変わる情報が 3 種類**入っていた。

| 箇所 | 出所 | なぜ毎回変わるか |
|---|---|---|
| `- Generated:` | `Time.now.utc.iso8601` | 実行時刻 |
| `- Ruby:` | `RUBY_DESCRIPTION` | **開発機は 3.4.5、weekly ジョブは 4.0**。永久に一致しない |
| 各 gem 行の `fetched` 列 | `File.mtime(gem_path)` | キャッシュが空の CI では毎回「今日」。**36 行以上が毎回変わる** |

3 つ目が一番効いている。**表の全行が毎回変わる。**

### これは Step 176 の伏線だった

Step 176 で「stackprof の note が Step 146 で直されたのにスナップショットが
古いままだった」ことを見つけ、「**週次ジョブはこれを差分として検出する設計なので、
気付かれずに来たのはその結果が見られていなかったということ**」と書いた。
**なぜ見られていなかったのかが、ここで分かった** — 常に赤だったからである。
**常に赤い検査は、無い検査より悪い。** 見なくなるうえ、無いことにも気付かれない。

### 直し方 — スナップショットを「入力だけの関数」にした

`Generated` と `Ruby` の 2 行を本文から外し、`fetched` 列を落とした。
**情報は捨てていない** — 前者 2 つは実行時の診断として標準出力に出す。
消したかったのは「**コミットされるファイルに入ること**」だけである。
`fetched` は、バージョンが `gems.rb` で固定済み(Step 176)なので
`requested` / `resolved` があれば何を見たかは確定し、失うものが無い。

### 「決定的である」ことをテストに守らせた

同じ入力から 2 回レンダリングしてバイト単位で一致すること、
出力に日付らしき文字列(`\d{4}-\d{2}-\d{2}`)が現れないこと、
`RUBY_DESCRIPTION` が埋まらないこと、の 3 本。
**次に誰かが「生成日時を入れておくと便利」と思ったとき、テストが止める。**

---

## Step 189 — `F_GETPIPE_SZ` / `F_SETPIPE_SZ` を同梱 `fcntl.h` に足す(M5 H6)

ギャップ E。Step 157 から残っていた最後の小さいやつ。

### 値は導かず、両ターゲットで測った

`F_LINUX_SPECIFIC_BASE + 7` と `+ 8` なので**計算で出せる**が、R8 は
「**ABI は実測、写さない**」である。x86-64 はホスト gcc、aarch64 は
クロス gcc + qemu で実際に印字させ、**両方とも 1031 / 1032** を確認してから書いた。
ABI ハーネスの `FCNTL` ケースにも両定数を足したので、
以後はホストのヘッダと差が出た瞬間に落ちる。

### 「埋めても検証済み gem は増えない」は本当だった

GAPS E は最初から「fcntl は上流にテストスイートが無く (d) レベルの証拠が
原理的に得られないので、埋めても検証済み gem は増えない」と書いてあった。
それは変わらない。**では何が変わったか** — Ruby の `Fcntl` が公開する定数と
同梱ヘッダを突き合わせると、**残る差は `Fcntl::VERSION`(gem 自身のバージョン文字列で
fcntl のマクロではない)だけ**になった。**過不足なく一致**である。

「検証済み gem が増えないから直さない」と「直しても検証済み gem は増えない」は違う。
**前者を理由に放置し続けると、直せば消えるギャップが残り続ける。**

---

## Step 190 — musl 4 回目。**`ruby.h` が通った**と、その先(M5 H6)

| | runs | failures | errors |
|---|---|---|---|
| musl 1 回目(Step 175) | 2,763 | 21 | 18 |
| musl 2 回目(Step 181) | 2,763 | 22 | 9 |
| musl 3 回目(Step 183) | 2,776 | 18 | 5 |
| **musl 4 回目** | **2,803** | **16** | **1** |

**39 → 31 → 23 → 17。errors は 18 → 1。**

### `TestRubySmoke` が全部消えた — musl で `ruby.h` が通るようになった

これが本丸だった。**3 ステップかかっている**:

| Step | 壁 |
|---|---|
| 179 | `stdckdint.h` が無い |
| 182 | `_Noreturn` を受け付けない |
| 184・187 | `offsetof` を定数式に畳めない(cast 形・引き算形) |

**毎回「直したら次の壁が出た」** — しかも壁は 3 つとも別物だった。
ヘッダの欠落 → 言語機能の欠落 → 定数畳み込みの欠落、と層が違う。
**1 つ直して測り直す以外に、この列を見つける方法は無かった。**

### 残る 1 件のエラー — `__isoc_va_list`(ギャップ L)

Step 180 で `need_va_list` のプローブを libc 別にしたので、
musl 側では `__isoc_va_list` を使う。ところが
**rubycc の同梱ヘッダは `__gnuc_va_list` しか提供していない**ので、今度は rubycc が落ちる。
**対照が取れるようにした結果、rubycc 側の穴が見えた** — これも前進である。

### gem がまだ入らない理由が分かった — **リンカが musl の libc を見つけられない**

Step 183 では mkmf.log をアーティファクトに入れ忘れて分からなかった。今回は入っている:

```
rubycc: error: cannot locate the C library; pass libc: with its path
```

`ExecutableLinker::DEFAULT_LIBC_PATHS` は **glibc の `libc.so.6` の綴りしか並べていない**。
musl は**ローダと C ライブラリが同一ファイル**で、`libc.so.6` は存在しない。
**rubycc は `MUSL_INTERP = "/lib/ld-musl-x86_64.so.1"` を
インタプリタとしては既に知っていた**のに、libc の探索先には入っていなかった。

io-wait だけ通っていたのは、**extconf が probe を 1 つも持たない**ため
実行ファイルのリンクが一度も走らないからである(Step 165 に書いた性質が効いた)。
共有ライブラリのリンクは未定義シンボルを許すので libc の位置を要求しない。
**「1/3 しか通らない」の正体は gem の側ではなく、リンカの探索先だった。**

探索先に musl の 2 つの綴りを**glibc の後ろに**足した。
**このホストで検証できるのは「glibc の解決が変わらないこと」までで、
musl で通るかは次の実走まで確定しない。** そう書いておく。

---

## Step 191 — `__isoc_va_list` も提供する(M5 H6)

ギャップ L。musl 4 回目に残った**唯一のエラー**。

### 片方を選ばず、両方を無条件に出した

glibc は素の va_list 型を `__gnuc_va_list`、musl は `__isoc_va_list` と綴る。
libc を見て切り替えることもできたが、**両方を無条件に提供**した。理由は 3 つ:

- **同じ型の別名**であって、選ぶべき対立が存在しない。
- 重複した typedef は**同じ型なら合法**(C11 6.7p3)なので、
  ホストのヘッダが後から自分の分を定義しても衝突しない。
- 同梱ヘッダに**「今どの libc 上にいるか」を判断させずに済む**。
  ギャップ G(ABI の焼き込み)ではその判断が要るが、**ここでは要らない** —
  要らないところに分岐を入れない。

### gcc 対照が取れないケースがまた 1 つ

このホストの gcc は `__isoc_va_list` を知らない
(実測: `unknown type name '__isoc_va_list'; did you mean '__gnuc_va_list'?`)。
**両方の名前を同時に受け付けるオラクルが存在しない**ので、
`stdckdint.h`(Step 179)と同じく rubycc 単独で検査し、理由をコメントに書いた。

ただし**この検査は musl でも glibc でも意味を持つ** — 「ホストの libc が使う綴りを
rubycc が供給しているか」を、どちらのホストでも確かめる形にしてある。

---

## Step 192 — musl で **3/3 PASS**。gem が入るようになった(M5 H6)

Step 190 のリンカ修正(musl の libc の在処)が効いた。

| gem | musl での実走 |
|---|---|
| io-wait 0.4.0 | 26 tests / 41 assertions |
| **stringio 3.2.0** | **103 tests / 626 assertions** |
| **json 2.21.1** | **596 tests / 3,390 assertions**(`parser.so` + `generator.so`) |

いずれも 0 failures / 0 errors。**musl の検証済み記録が 1 → 3 件**になった。

### 直したのは gem 側ではなくリンカの探索先だった

Step 183 で「3 gem 中 2 gem が入らない」と分かったとき、**理由は書けなかった**
(mkmf.log をアーティファクトに入れ忘れていた)。入れてから 1 回回したら
`cannot locate the C library` が出て、**gem の問題ですらなかった**ことが分かった。

**「1/3 しか通らない」を gem の性質の話だと読まなくてよかった。**
io-wait だけ通っていたのは、その extconf が probe を持たず**実行ファイルのリンクが
一度も走らない**からで、gem の相性ではなく**踏む経路の違い**だった。

### 記録の中の「Step 191」表記について

`evidence` 文字列は **`(Step 191)`** と書かれている。CI を dispatch したとき
`verify_step=191` を渡した後で、`__isoc_va_list` の修正が Step 191 を取ったためである。
`data/verified_gems.json` は**ツール以外が書かない**規約なので、
**番号を手で書き換えることはしない。** ここに経緯を残す。

### スイート側も 17 → 16

`2,803 runs / 15 failures / 1 error`。エラー 1 件は `__isoc_va_list` で、
**この実走より後の Step 191 で解消済み**(次の実走で消えるはず)。

---

## Step 193 — 同梱ヘッダに libc の軸を入れ、musl の実測値を反映する(M5 H6)

**ギャップ G の本体。** M5 は「glibc/musl 互換ヘッダ」を掲げながら、
**その主張を支える値が全て glibc 側で取られていた**。musl 実走で差分が測れたので反映した。

### ディレクトリ層ではなくマクロ分岐にした

`include/libc/musl/<arch>/` を新設する形も採れたが、採らなかった。

- 差分は **10 ヘッダで 15 項目**しかない。arch 層 13 ファイル × 2 arch を複製すれば
  **中身の 95% が同じファイルが 26 個**でき、必ず腐る。
- 差分は**3 つの層にまたがる** — arch 層(`fcntl.h`・`stdint.h`・`limits.h`・`ctype.h`・
  `pthread.h`)と共通層(`stdio.h`・`math.h`・`unistd.h`・`sys/wait.h`・`sys/resource.h`)。
  ディレクトリ方式なら libc 共通層も新設することになる。
- **`#if` なら、差分 1 つ 1 つが両方の実測値を並べたコメントつきでその場に残る。**
  R8 の「ABI は実測、写さない」を**監査可能**にするのはこの形である。

前処理器に `libc:` の軸を足し、musl のとき `__RUBYCC_LIBC_MUSL__` を定義する。
既定はホストの libc を `RbConfig` の arch トリプレットから判定する
(**既に 3 か所にある同じ判定**に合わせた)。ユーザが `-D` で上書きすることはできない。

### 測れた 15 項目(左が musl)

| ヘッダ | 項目 | musl | glibc |
|---|---|---|---|
| `sys/resource.h` | `sizeof(struct rusage)` | **272** | 144 |
| `fcntl.h` | `O_ACCMODE` / `O_LARGEFILE` | **2097155 / 32768** | 3 / 0 |
| `stdint.h` | `[u]int_fast16_t` / `[u]int_fast32_t` | **4 バイト** | 8 バイト |
| `limits.h` | `MB_LEN_MAX` | **4** | 16 |
| `stdio.h` | `BUFSIZ` / `FOPEN_MAX` / `TMP_MAX` | **1024 / 1000 / 10000** | 8192 / 16 / 238328 |
| `pthread.h` | `_Alignof(pthread_rwlockattr_t)` | **4** | 8 |
| `math.h` | `math_errhandling` | **2** | 3 |
| `unistd.h` | `_POSIX_MONOTONIC_CLOCK` | **200809** | 0 |
| `sys/wait.h` | `WIFSTOPPED(0x007f)` | **0** | 1 |
| `ctype.h` | `isalpha('a')` 等 | **素の 0/1** | 分類表のビット |

`ctype.h` だけは**値ではなく実装形**の差である。glibc の `__isctype` マクロ
(`__ctype_b_loc()` の表引き)は **musl 上でも表が引けてしまう**ので、
musl の `isalpha()` が返す素の 0/1 ではなく分類表のビットが返っていた。
musl では表引きマクロを使わず関数呼び出しにした。

### aarch64 は**触っていない**

同じ分岐が要るはずの aarch64 の arch 層は、**glibc 値のまま残した**。
musl の測定は **x86-64 でしか取れていない**からである。
arch 層は**「機種で値が動く」ことを前提に存在する層**で、
`O_DIRECT` 群が x86-64 と aarch64 で入れ替わるのがその実例である。
そこへ x86-64 の測定値を写すのは**測定ではなく仮定**になる。
各ファイルに「なぜ触らないか」を英語で書き、ギャップ G は
**「musl 対応が x86-64 のみ」に書き換えて残した。**

### `WIFSTOPPED` だけ、引数を 2 回評価する

このファイルは「各マクロは引数を 1 回だけ評価する」を不変条件にしていたが、
musl 版だけ守れていない。「下位バイトが 0x7f かつ上位バイトが非ゼロ」を
補助関数なしで 1 回評価に書く綴りが無いためである。
**隠さずコメントに書いた。** 副作用のある引数を渡すと musl では 2 回評価される。

### このホストで検証できたこと・できないこと

**できた**: `libc: "musl"` を指定してコンパイル・実行し、
上の表の値が実測どおりに出ること。glibc 側の出力が 1 つも変わっていないこと。

**できない**: `ctype.h` のように**実行時に libc の関数を呼ぶ**ものは、
glibc ホストでは glibc にリンクされるので値が一致しない。
そこはコンパイルが通るところまでにとどめた。
**musl で実際に通るかは次の実走まで確定しない。**

---

## Step 194 — musl 6 回目。**ABI の失敗が全部消えた**(M5 H6)

Step 193 を入れて回した。

| 実走 | failures | errors |
|---|---|---|
| 1 回目(Step 175) | 21 | 18 |
| 5 回目(Step 192) | 15 | 1 |
| **6 回目** | **4** | **0** |

**39 → 4。** そして**内訳が変わった**のが重要である。

### 10 件あった header ABI の失敗が **1 件も残っていない**

`stdint` / `limits` / `math` / `stdio` / `unistd` / `fcntl` / `pthread` /
`resource` / `wait` / `ctype` — **Step 193 で反映した 15 項目がそのまま全部通った**。
`gem` も 3/3 PASS のままである。

**「glibc/musl 互換ヘッダ」の主張が、初めて musl 側でも測られた状態になった。**

### 残る 4 件はどれも ABI ではない

| 件 | 中身 |
|---|---|
| 2 件 | **テスト側が glibc の SONAME を決め打ち**していた(`libc.so.6`) |
| 1 件 | `rubycc-pkgconf` のシステムパス除外が Debian の綴り決め打ち(**ギャップ M**) |
| 1 件 | **共有ライブラリのコンストラクタが musl で 1 回しか走らない**(**ギャップ N**) |

**SONAME の 2 件は rubycc の非ではない** — むしろ Step 190 の修正が効いて
musl の libc を正しく見つけ、その SONAME(`libc.musl-x86_64.so.1`)を
正しく記録した結果、**「glibc だと書いてあるテスト」の方が落ちた**。
ギャップ I(ABI ハーネスが glibc 固有)と同じ形なので、同じように
ホストの libc から名前を読む形に直した。**アサーションの意図は
「libc に届いたか」であって「glibc に届いたか」ではない。**

### ギャップ N は原因を切り分けていない

gcc が `123L123L123L` を出すところ rubycc は `123L` しか出さない。
**glibc ホストでは一致する。** rubycc の `.init_array` 合成の問題か、
musl のローダの扱いの違いかを**まだ切り分けていない**ので、
「musl では複数コンストラクタが走らない」という**観測**だけを記録した。
優先度は高い — 複数の `__attribute__((constructor))` を持つ拡張が静かに壊れる形である。

---

## Step 195 — ギャップ N の原因を切り分ける(M5 H6)

Step 194 は「musl でコンストラクタが 1 回しか走らない」という**観測だけ**を記録した。
切り分けたら、**観測の読み方が間違っていた**。

### 最初の読みは外れていた

失敗はこう見えていた:

```
expected (gcc):  "123L123L123L"
actual  (rubycc): "123L"
```

「rubycc 側でコンストラクタが走っていない」と読める。**そうではなかった。**

### 機構はローカルで再現した

テストの `trace` / `marked` は**エクスポートされたグローバル**である。
`Fiddle.dlopen` は `RTLD_GLOBAL` を使うので、**先に載ったライブラリの `trace` が
後から載るライブラリの参照を横取りする**。glibc で 2 行で再現した:

```
gcc 版を 2 つ順に dlopen  →  first="123L"  second="123L123L"
```

**2 つ目のコンストラクタは 1 つ目の `trace` に書いている。** 意図された ELF の挙動である。

musl でこれが表に出たのは、**musl の `dlclose` が解放しない**ためである。
テストの `order` ラムダは毎回 `close` するが、musl ではそれが効かず、
前のテストで載ったライブラリが residents のまま介入していた。

### 本当の差はこちら — **rubycc の `.so` は介入を尊重しない**

同じソースから gcc 版と rubycc 版を作り、gcc 版を先に載せてから rubycc 版を載せた:

| 2 つ目に載せたもの | 書き込み先 |
|---|---|
| **gcc 版** | **1 つ目の `trace`**(介入する) |
| **rubycc 版** | **自分の `trace`**(介入しない) |

**これは glibc で再現する。musl は要らなかった** — 4 回目の同じ形である
(`stdckdint.h`・`_Noreturn`・`offsetof` に続く)。
musl は「介入が観測できる状態」を作っただけで、**欠陥は最初から glibc にもあった**。

つまり **rubycc は、共有ライブラリが自分で定義した外部データシンボルへの参照を
直接アドレスで解決している**。`-Bsymbolic` を指定したわけでも
protected 可視性を付けたわけでもないので、ELF の既定の意味論からの逸脱である。

### 直していない — トレードオフがあるため

修正は「PIC の共有ライブラリでは、自分で定義したグローバルデータも GOT 経由で読む」
という**コード生成の変更**になる。**性能と引き換え**であり、
`-Bsymbolic` 相当を既定にするという選択肢もありうる。
**ここで即断せず、ギャップ N を正確な記述に書き換えて残した。**

**観測を記録しておいたから、切り分けが後からできた。**
「コンストラクタが走らない」のまま直しにいっていたら、別のものを直していた。

---

## Step 196 — ギャップ M と I を閉じる(M5 H6)

小さい 2 件をまとめて片付けた。

### M — pkgconf のシステムパス除外が Debian の綴り決め打ちだった

`/usr/lib/x86_64-linux-gnu` と `/lib/x86_64-linux-gnu` を**無条件に**
システム libdir 扱いしていた。Alpine にはこのディレクトリが**存在しない**ので、
本物の pkgconf は `-L/usr/lib/x86_64-linux-gnu` を**残す**(そこでは
リンカが既に探すディレクトリではなく、ただのディレクトリだから)。
rubycc は落としていたので、`-L... -lz` に対して `-lz` を返していた。

**実在するときだけシステム扱いにする**形に直した。
これは元のコメントが自分で書いていた理屈
(「このシムのリンカが既定で探すディレクトリに `-L` を出す意味は無い」)に
そのまま従っただけである — **探さないディレクトリを落としてはいけない。**

`/usr/lib` / `/lib` / `/usr/lib64` は**無条件のまま**にした。
どこにあってもシステム libdir であり、ここを実在条件にすると
**他の測定を取ったホストでの出力が変わってしまう**。

### I — 分類が完了していることを 3 回の実走で確かめた

Steps 180・181 でハーネスを libc でパラメタ化したが、
**gcc が最初の数件でエラーを打ち切る**ため「まだ隠れているかもしれない」と
書いて残していた。今回**musl 実走 3 回分のログを数え直した**:

| 実走 | 「対照が先にコンパイルに失敗」した件数 |
|---|---|
| 4 回目 | **0** |
| 5 回目 | **0** |
| 6 回目 | **0** |

**3 回連続で 0 件。** 打ち切りの陰に残っているなら、
Step 181 のように次の実走で 1 件でも顔を出すはずだった。出なかったので閉じる。

**「出ないことを確かめる」には複数回要る**という形の証拠なので、そう書いておく。

---

## Step 197 — aarch64 + musl の ABI を測る足場(M5 H6)

ギャップ G の残り。**このステップは測る仕組みまで**で、
値の反映は次のステップに分ける(CI を 1 回回さないと値が手に入らないため)。

### ハーネスが x86_64 決め打ちだったことが先に出た

`run_abi_case` は `Rubycc::Compiler.new.compile(source, filename: ...)` を呼んでいる。
**この API の `target:` は既定が `"x86_64"` 固定**である。
つまり **aarch64 ホストの上では x86_64 のオブジェクトが出て、リンクも実行もできない。**

ドライバ(`exe/rubycc`)側は最初から `RbConfig::CONFIG["host_cpu"]` を既定にしていた。
**ライブラリ API とドライバで既定が食い違っていた**わけで、
ハーネスも同じ出所から読む形に直した。

未知の機種のときは **`skip` にして、黙って x86_64 に落とさない**ようにした。
落とせば「**別の機種を測って合格と言う**」ことになる。
ギャップ I(ハーネスが glibc 固有)と同じ種類の誤りである。

### 全スイートは走らせない

qemu 上の全スイートは遅すぎる(ROADMAP に明記がある)。このジョブが走らせるのは
**ABI を測る 2 本だけ** — `test_header_abi.rb` と `test_freestanding_headers.rb`。
`bundler` も使わず `gem install minitest` だけにした
(Gemfile の `fiddle` はソースビルドで、この 2 本は fiddle を使わない)。

### 失敗してよいジョブである

**このジョブの目的は測ることで、緑にすることではない。**
差分がログに残ることが成果なので `continue-on-error` は付けず、
**赤をそのまま出してログをアーティファクトに上げる**。
`uname -m` と `RbConfig` の arch、`gcc -dumpmachine` を先頭に記録して、
**本当に aarch64 かつ musl だったこと**を証拠として残す。

### 起動手段が「週次まるごと」しか無かったので直した

このジョブを `verify_step` だけで守ると、**起動できるのが週次の全ジョブ実行だけ**になる。
**1 ジョブの答えを得るのに他 5 ジョブ分の分数を払う**ことになるので、
`workflow_dispatch` に `only` 入力を足した。

| 起動 | 走るジョブ |
|---|---|
| 週次スケジュール | 6 つ全部 |
| `verify_step` 指定 | `musl` のみ(記録用) |
| `only: musl-aarch64` | **`musl-aarch64` のみ**(測定用) |

**初回の測定は `only` を入れる前に投げてしまった**ので、
そのぶんは週次まるごとを走らせている。**次からは 1 ジョブで済む。**

---

## Step 199 — pkgconf の `-L` 重複を畳む(M5 H6)

Step 196 の pkgconf 修正を musl で確かめたら、**直っていなかった**。

```
real:  -L/usr/lib/x86_64-linux-gnu -lz
ours:  -L/usr/lib/x86_64-linux-gnu -L/usr/lib/x86_64-linux-gnu -lz
```

**`-L` が 2 回出ていた。** 修正の方向は正しく(本物も `-L` を残す)、
**フィルタが隠していた別のバグを露出させた**形である。

出所は `.pc` 自身だった:

```
Libs: -L${libdir} -L${sharedlibdir} -lz
```

この環境では両方が**同じディレクトリ**に展開される。**本物の pkg-config は畳む。**
Debian では**フィルタが両方とも落としていた**ので、重複は一度も表に出ていなかった。

`-I` / `-L` の重複を**最初の 1 つだけ残して**畳む形にした。
同じディレクトリを 2 回探しても見つかるものは変わらないので、**落として安全**である。
**`-l` は畳んでいない** — 静的リンクでは繰り返しに意味がありうるし、
**それを裏づける実測が無い**。

### 3 件のテストが Debian の layout を前提にしていた

「multiarch の `-L` は落とされる」と書いてあるテストが 3 件あり、
**Alpine では落とされないのが正しい**(そこではシステムディレクトリではないため)。
ディレクトリが実在しないホストでは `skip` にした。
ギャップ I や Step 194 と**同じ形**である — 1 つの配布物の layout を
どこでも成り立つことのように書いていた。

---

## Step 200 — aarch64 + musl を初めて測った(M5 H6)

`only: musl-aarch64` で 1 ジョブだけ回した。**環境は本物である**ことを先に記録している:

```
uname -m:    aarch64
ruby arch:   aarch64-linux-musl, host_cpu: aarch64
gcc target:  aarch64-alpine-linux-musl
```

`115 runs / 6 failures / 2 errors`。**測れた値がこのステップの成果**である。

### `O_LARGEFILE` が機種で違った — 写さなかった判断が正しかった

| | x86-64 musl | **aarch64 musl** |
|---|---|---|
| `O_LARGEFILE` | 32768 | **131072** |

Step 193 で aarch64 に x86-64 の musl 値を**写さなかった**理由は
「arch 層は機種で値が動くことを前提に存在する層だから、写すのは測定ではなく仮定」だった。
**その仮定が実際に外れる値がここにあった。** 写していれば静かに間違っていた。

一方 `MB_LEN_MAX`(4)・fast 型の幅(4 バイト)・`O_ACCMODE`(2097155)・
`ctype` の戻り値は **x86-64 と同じ**だった。**同じものと違うものが混ざっている** —
だからこそ「たぶん同じ」で書いてはいけない。

### `pthread` は aarch64 の方が差が多い

x86-64 musl では `_Alignof(pthread_rwlockattr_t)` の 1 項目だけだったが、
aarch64 musl では **5 項目**が違う(`pthread_mutex_t` 40/48、`pthread_attr_t` 56/64、
`pthread_mutexattr_t` 4/8、`pthread_condattr_t` 4/8、`rwlockattr` の整列 4/8)。

### musl と無関係の発見が 2 つ出た

**ギャップ O — `float.h` が x86-64 の `long double` を全機種に出していた。**
aarch64 の `long double` は **128 ビット quad** で、`LDBL_MANT_DIG` は 113、
`LDBL_DIG` は 33。rubycc は x87 80 ビットの 64 / 18 を出す。
**これは musl とは無関係で、aarch64 では libc を問わず合わない。**
`float.h` は freestanding 層(1 ファイル)にあり、**arch で分ける仕組みが無い**。

**aarch64 の ABI ハーネスがこれまで `float.h` を検査していなかった**ので
見つかっていなかった。**測る対象を増やしたら、測っていなかった穴が出た。**

**ギャップ P — `stdio.h` のプローブが aarch64 musl でリンクできない。**
`ld: final link failed: bad value`。rubycc が出したオブジェクトを musl の ld が
受け付けていない。**原因は切り分けていない。**

### 値はまだ反映していない

**測っただけである。** ヘッダに書くのは次のステップにする —
反映したら**もう一度測って一致を確かめる**必要があり、
そこまでやって初めて「合った」と言える。

`alloca` のエラーは A4 の既知の未実装項目で、新しい発見ではない。

---

## Step 201 — `float.h` の `long double` を機種で分ける(M5 H6)

ギャップ O。**musl とは無関係の欠陥**で、aarch64 では libc を問わず合っていなかった。

| | x86-64(x87 80 ビット) | **aarch64(IEEE binary128)** |
|---|---|---|
| `LDBL_MANT_DIG` | 64 | **113** |
| `LDBL_DIG` | 18 | **33** |
| `DECIMAL_DIG` | 21 | **36** |
| `LDBL_MAX` | 1.18973149535723176502e+4932 | **…176508575932662800702e+4932** |

指数の範囲(`LDBL_MIN_EXP` 等)は**どちらも同じ** — 両形式とも指数 15 ビットだからである。
**違うのは仮数幅から出る値だけ**なので、共通部分と分岐部分を分けて書いた。

### 測り方を先に検証した

`float.h` は**コンパイラが供給する**ヘッダなので、値はアーキテクチャの性質である。
そこで手元のクロス gcc + qemu で全項目を印字させた。
**x86-64 側の実測が現行ヘッダと 1 文字も違わなかった**ことが、この測り方の妥当性である。

`%La` では桁が足りず `LDBL_MAX` が `0x2.0p+16383` に丸められていた。
仮数 113 ビットには 28 桁の 16 進が要る。**`LDBL_DECIMAL_DIG - 1` 桁の 10 進で測り直した。**
**丸められた値をそのままヘッダに書かなくてよかった。**

### なぜ見つかっていなかったか

`float.h` は **freestanding 層**(1 ファイル)にあり、
aarch64 の ABI ハーネスは **arch 層のヘッダしか見ていなかった**。
「freestanding なヘッダに機種依存は無い」という**思い込み**である。
このファイルがその反例だった。

**aarch64 のハーネスに `float.h` の検査を足した。** これが本体より重要である —
値を直すだけなら次に同じ思い込みで別のファイルが漏れる。

### 分岐は libc ではなく arch マクロで

Step 193 の libc 分岐と同じ手だが、条件は `__aarch64__`。
**前処理器がターゲットごとに定義済みにしているマクロ**なので、新しい仕組みは要らない。

---

## Step 202 — glibc / musl の真の distroless 相当で4 gemを受入れ(M5 H6)

Step 201 までの受入れは通常のツール環境またはhermeticヘッダ模擬だった。ここでは
`ruby:4.0-slim`(glibc) と `ruby:4.0-alpine`(musl) のコンテナで、rubycc gemを
インストールした後に `cc` / `gcc` / `clang` / `make` / `sh` と libc 開発ヘッダを
取り除き、`RUBYCC=1 RUBYCC_HERMETIC_HEADERS=1` の実物経路を確認した。

| 環境 | gem install | 実行確認 |
|---|---|---|
| glibc / Ruby 4.0.6 | `json:2.21.1`, `msgpack:1.8.3`, `sqlite3:2.9.5`, `pg:1.6.3` | JSON、MessagePack、SQLite in-memory、`PG.library_version` |
| musl / Ruby 4.0.6 | `json:2.21.1`, `msgpack:1.8.3`, `sqlite3:2.9.5`, `pg:1.6.3` | 同上 |

sqlite3 / pg は `--platform ruby` とし、外部 gem のヘッダと実行用 `.so` だけを残した。
libc ヘッダを復元したり、開発用 `.so` の symlink を追加したりしていない。両環境とも
PASSだった。今回の利用者向け再現例は `examples/distroless/Dockerfile` に置いた。

この受入れで露出した実装上の穴も回帰テスト化した。

- runtime-only の versioned `.so` と musl の統合 libc を `LibraryResolver` が解決する。
- mkmf のマクロ化 header-name、`(void *)0` と function pointer の conditional、
  GNUの構造体メンバー `[0]`、X-macro後の空外部宣言を受理する。
- musl Ruby と libpq の `restrict` 別名再定義を限定的に許容する。

> **番号の衝突について**: このブランチは当初この作業に Step 202・203 を使っており、
> コミットの件名にはその番号が残っている。並行して master に入った distroless の
> 作業が先に Step 202 を取っていたため、**この文書側を 204・205 に振り直した**。
> 番号で追うときはこの対応を見ること。

## Step 204 — aarch64 musl の実測値を反映する(M5 H6)

Step 200 で測った値を、Step 193 が意図的に空けておいた 5 ファイルに書いた。

| ファイル | 反映した項目 |
|---|---|
| `limits.h` | `MB_LEN_MAX` 4 |
| `stdint.h` | fast16/32 が 4 バイト、対応する `*_MAX` / `*_MIN` |
| `fcntl.h` | `O_ACCMODE` 2097155、**`O_LARGEFILE` 131072** |
| `ctype.h` | 実装形(musl では表引きマクロを使わず関数呼び出し) |
| `pthread.h` | 5 項目(mutex 40 / attr 56 / mutexattr 4 / condattr 4 / rwlockattr の整列 4) |

### 空けておいた判断が報われた

`O_LARGEFILE` は **x86-64 musl では 32768、aarch64 musl では 131072**。
Step 193 で「arch 層は機種で値が動く前提の層だから、x86-64 の値を写すのは
**測定ではなく仮定**」として空けておいた。**その仮定が外れる値がまさにここにあった。**
写していれば静かに間違っていた。コメントにその経緯を残した。

一方 `MB_LEN_MAX`・fast 型・`O_ACCMODE`・`ctype` は x86-64 と同じだった。
**同じものと違うものが混ざっている**から、写してよいかは事前には決められない。

### コンパイル時定数は musl が無くても検証できる

`sizeof` / `_Alignof` / マクロ値は**コンパイル時に決まる**ので、
リンク先が glibc でも値は変わらない。そこで
`target: "aarch64", libc: "musl"` でコンパイルし、クロス gcc でリンクして
**qemu で実際に印字**させ、実測表と全項目一致することを確かめた。

**「musl が無いから確かめられない」は、この範囲では正しくなかった。**
確かめられないのは**本物の musl gcc との突き合わせ**の方だけである。

### だからギャップ G は閉じていない

反映したものが正しいかは、**次の `only: musl-aarch64` 実走で確定する**。
「ヘッダが実測どおりの値を出す」ことと「本物の対照と一致する」ことは別なので、
G は後者に書き換えて残した。

---

## Step 205 — aarch64 musl で一致を確認。**ギャップ G が閉じた**(M5 H6)

Step 204 の反映を、`only: musl-aarch64` で 1 ジョブだけ回して確かめた。

| | failures | errors |
|---|---|---|
| 反映前(Step 200) | **6** | 2 |
| **反映後** | **0** | 2 |

**本物の aarch64 musl gcc と ABI が一致した。** `freestanding` 側も 0 failures。

これで **x86-64(Step 193)と aarch64(Step 202)の両方**が、
それぞれの機種の musl gcc と突き合わせて確認済みになった。
**ギャップ G — M5 が掲げながら一度も測っていなかった「glibc/musl 互換ヘッダ」の
主張 — が閉じた。**

### 手元での確認と、本物での確認は別だった

Step 204 の時点で「ヘッダが実測どおりの値を出す」ことは qemu で確かめてあった。
それでも G を閉じなかったのは、**それは自分が書いた表と自分が書いたヘッダを
突き合わせているだけ**だからである。**転記の誤りは捕まらない。**
本物の対照と突き合わせて初めて閉じられる。

### 残る 2 件は既知のもの

- `alloca` — M4 A4 の未実装項目。**新しい発見ではない**
- `stdio` のリンク失敗 — **ギャップ P**。原因は切り分けていない

---

## Step 206 — ギャップ P は rubycc の欠陥ではなかった(M5 H6)

aarch64 musl で `stdio.h` のプローブがリンクできなかった件。

```
ld: relocation R_AARCH64_ADR_PREL_PG_HI21 against symbol `stdout'
    which may bind externally can not be used when making a shared object
ld: final link failed: bad value
```

### glibc で再現した — **6 回目**

`aarch64-linux-gnu-gcc` で `-pie` を付けてリンクすると、**同じ relocation の
同じエラー**が出た。musl は要らなかった。
`stdckdint.h`・`_Noreturn`・`offsetof`・シンボル介入・`float.h` に続く 6 回目である。

### gcc も同じエラーを出す

決め手はこれだった。**gcc 自身の `-fno-pie` オブジェクト**を `-pie` でリンクすると、
**一字一句同じエラー**になる。つまり **rubycc は gcc と同じ振る舞いをしている**。

aarch64 では外部データシンボルへの ADRP+ADD は preemptible なシンボルに対して
解決できず、PIE に入れられない。**x86-64 では同じことができる**
(リンカが copy relocation で解決する)。**機種の性質**であって、
どちらのコンパイラの欠陥でもない。

### 本当の欠陥はハーネスにあった

**ハーネスが両側に違うフラグを渡していた。**
gcc 側は gcc の既定(最近のツールチェインでは `-fPIE`)、
rubycc 側は非 PIC。**PIE のビルドと非 PIE のビルドを比べていた。**

x86-64 では**この差が見えない**(リンカが吸収する)ので、
**aarch64 で初めて表に出た**。両側とも PIC で作る形に直した。

### 「対照と同じ条件で測る」を、また落としていた

ギャップ I(ハーネスが glibc 固有)、Step 194(SONAME 決め打ち)、
Step 197(ハーネスが x86_64 決め打ち)に続いて **4 回目**である。
**同じ場所が繰り返し同じ種類の間違いを起こしている** — 対照を用意するコードは、
対照と自分を同じ条件に置けているかを繰り返し疑う必要がある。

---

## Step 207 — ハーネスの環境前提を push ごとに検査する(M5 H6)

ユーザからの問い「**この間違いを繰り返さないにはどうすればいいか**」への回答の実装。

### 何が 4 回起きていたか

| | 環境で変わる値を、変わらない値として書いていた場所 |
|---|---|
| ギャップ I | プローブの**本文**(`__GLIBC__`・`_ISupper`) |
| Step 194 | アサーションの**リテラル**(`libc.so.6`) |
| Step 197 | rubycc 側の**既定値**(`target: "x86_64"`) |
| Step 206 | 両側の**フラグ**(gcc は `-fPIE`、rubycc は非 PIC) |

書いた場所は毎回違うが、**4 件とも開発機では見えず**、90 分の CI 実走で 1 つずつ出た。
そして**事故のたびにその場しのぎのパラメタを 1 つ足してきた** — 今 `harness.rb` には
環境対応が 7 か所に生えている。**次の軸を足せば 5 回目を踏む。**

### 「気をつける」ではなく、**開発機で落ちるようにした**

今回の 6 件は、原因が分かってからは**全部ローカルで再現できた**。
ならば**最初からローカルで落ちるべき**である。

`aarch64` 向けにコンパイルしたオブジェクトを、**PIE でリンクして qemu で走らせる**
テストを足した。外部データシンボル(`stdout`)を参照するので、
Step 206 の欠陥がそのまま再現する。

### 効かない置き場所を先に潰した

**既存の `run_abi_case_aarch64`(クロス経路)に `STDIO` を足しても通ってしまう**
ことを先に実測した。`-static` で非 PIE リンクするからである。
**歯が立たない場所に検査を置いても意味がない**ので、そこは採らなかった。

### 検査が「自分の転記」を見ないようにした

肝は、テストが**コンパイルオプションを書き写さない**ことである。
`run_abi_case` が使うのと**同じメソッド**(`rubycc_build_options`)を呼ぶ。
書き写せば、**自分が書いた値を自分で検証するだけ**の無意味な検査になる —
Step 204 で「qemu で確かめたが本物と突き合わせるまで G は閉じない」と書いたのと同じ理屈である。

### 歯があることを実証した

`pic: true` を一時的に外して、**追加したテストが実際に落ちること**を確かめた。
出たのは Step 206 で CI が出したのと**一字一句同じエラー**である:

```
ld: relocation R_AARCH64_ADR_PREL_PG_HI21 against symbol `stdout@@GLIBC_2.17'
    which may bind externally can not be used when making a shared object
```

**90 分の CI 往復が、開発機の数秒になった。**

### まだやっていないこと

ユーザに示した対策のうち、**2 番(プラットフォーム固有名をリテラルで書かせない検査)と
1 番(両側を 1 つのプロファイルから作る)は未着手**である。
3 番だけで今回の 6 件のうち少なくとも 4 件は防げていたので、
**まず 3 番だけ入れて様子を見る**という判断をした。

## Step 208 — aarch64 glibc の Ruby 上で gem install を実走する(M5 H6)

qemu-user を有効にした Docker の `ruby:4.0` arm64 コンテナで、aarch64 の Ruby 4.0.6
を実際に動かし、`tools/verify_gem_tests.rb` の gem install 経路を通した。
`RbConfig::CONFIG["arch"]` は `aarch64-linux`、libc は glibc である。

```text
VERIFY_WORK=/tmp/rubycc_verify_gem_tests
ruby tools/verify_gem_tests.rb --update --step 208 io-wait stringio
```

| gem | gem install / gem 自身のテスト | 記録 |
|---|---|---|
| `io-wait` 0.4.0 | **PASS**、26 tests / 41 assertions / 0 failures / 0 errors / 1 omission | `data/verified_gems.json` に `glibc aarch64 / ruby 4.0.6` を追加 |
| `stringio` 3.2.0 | **PASS**、103 tests / 626 assertions / 0 failures / 0 errors | 同上 |

どちらも `Makefile: CC=rubycc` と `gem_make.out: rmake` を証拠として確認した。
`io-wait` の 1 omission は `/dev/tty` が無い qemu コンテナでの `test_tty_wait` であり、
gcc 側の対照でも同じだった。従って gem のテストを除外したものではない。

### 実走で露出した aarch64 固有の探索バグ

最初に `json` / `msgpack` を候補に実行したところ、extconf の `-lm` probe で
`rubycc: error: cannot find -lm` になった。`LibraryResolver` が Debian の
`/usr/lib/x86_64-linux-gnu` を既定値にしており、aarch64 の
`/usr/lib/aarch64-linux-gnu` を探索していなかったことが原因だった。

`LibraryResolver` に target ごとの system library directory を持たせ、driver から
target を渡すよう修正した。aarch64 用の resolver 回帰テストを追加し、修正後に上記 2 gem
の実インストールが完走した。qemu 上の extconf は probe 数に比例して非常に遅いため、
このステップでは H6 の計画どおり軽量な C 拡張 default gem 2 件を受入れ対象とした。
修正後に `msgpack` 1.8.3 も単独で試し、`-lm` probe を越えて `rmake` のコンパイルまで
進んだが、検証ツールの 900 秒制限で未完了となった(機能エラーではなく qemu の速度による
タイムアウトで、`data/verified_gems.json` には記録していない)。`json` / `msgpack` の
完走と aarch64 全スイートは、別途 M4 の受入れとして残る。

---

## Step 209 — `__atomic_thread_fence` と `websocket-driver` の再実走(M5 H4)

`nio4r` 2.7.5 の再実走で、libev が要求する C11 の `__atomic_thread_fence` と
いくつかの POSIX 宣言が rubycc の同梱面から抜けていることが分かった。
`__atomic_thread_fence` を lexer/parser/AST/IR に追加し、x86-64 では MFENCE、
AArch64 では DMB ISH を生成するようにした。同梱の `<stdatomic.h>` は
`memory_order_*` と `atomic_thread_fence` だけを提供する部分実装であり、`_Atomic`
オブジェクトや load/store/RMW は引き続き未実装である。`test/test_atomic_builtins.rb`
は 23 runs / 94 assertions / 0 failures / 0 errors になった。

同じビルドで現れた `VARx` マクロ由来の struct 内空宣言は parser が無視する C の
`struct point { int x;; };` を追加して修正し、`syscall()` の宣言と `_POSIX_TIMERS`
も `unistd.h` に追加した。追加した `test/test_parser.rb` の回帰ケースと syscall ABI
ケースは green である。

この足場で、`websocket-driver` 0.8.2 を rubycc/rmake でビルドし、注入した
`websocket_mask.so` のロードを sanity で確認した後、上流 RSpec を実走した。
**196 examples / 0 failures** であり、`data/verified_gems.json` に glibc x86_64 /
Ruby 3.4.5 の記録を追加した。

なお `nio4r` 自体はビルドと sanity までは到達したが、上流は 112 examples / 44
failures / 1 pending だった。失敗は socket 作成・接続の `Errno::EPERM` で、同じソースを
gcc でビルドした対照も 112 examples / 44 failures になったため、rubycc の合格記録には
していない。sandbox の socket 制約が解除された環境で再実走する対象として残す。

## Step 210 — `bootsnap` 1.24.6 の gem 本体テスト(M5 H4)

`bootsnap.so` を rubycc/rmake で生成し、`bootsnap/compile_cache` 経由の sanity で
注入した拡張がロードされたことを確認した。上流の 20 ファイルを test/unit で実走し、
**154 tests / 331 assertions / 0 failures / 0 errors**。開発用 Gemfile の依存を持ち込ま
ない synthetic Gemfile と、上流の互換条件に合わせた minitest 5.25.5 を使用した。

## Step 211 — `yajl-ruby` 1.4.3 の gem 本体テスト(M5 H4)

`yajl.so` を rubycc/rmake で生成して sanity でロードを確認した。上流 RSpec 14 ファイル
を実走し、**416 examples / 0 failures** で合格した。`data/verified_gems.json` に
glibc x86_64 / Ruby 3.4.5 の記録を追加した。

## Step 212 — `prism` 1.8.1 の全テスト(M5 H4)

Prism のビルドで、ビットフィールド初期化子と aggregate/compound literal の指定初期化子
が露出したため、initializer resolver と IR の bitfield/aggregate 経路を補った。上流
source archive に含まれない生成 Ruby API ファイルは、gem package の生成物をそのまま
テストツリーへ注入する recipe とした。

`prism.so` の sanity 後、64 ファイルを test/unit で実走し、**17,306 tests /
1,762,400 assertions / 0 failures / 0 errors / 3 omissions**。omission は失敗ではなく、
`data/verified_gems.json` にはその事実を notes として残した。

## Step 213 — `fiddle` 1.1.8 の system-libffi 経路(M5 H4)

Fiddle の `Handle#file_name` が linker script を指すケースで nil になったため、
`dlfcn.h` に `RTLD_DI_LINKMAP`/`dlinfo`、`link.h` に必要な `link_map` の ABI 前半を追加した。
その後、`fiddle.so` を rubycc/rmake で生成し、dlfcn ABI の gcc 対照も通過した。
上流 14 ファイルを実走して **227 tests / 615 assertions / 0 failures / 0 errors**。

## Step 214 — R10 実測値の確定と残件の分類(M5 H4)

上記 5 件を `tools/verify_gem_tests.rb --update` で記録した後、R10 ゲートを通過した
分母 37 件を再計算した。検証済みは既存 20 件 + 新規 5 件の **25/37 = 67.6%**。
90% に必要な 34 件にはまだ 9 件足りず、ここで受入れ完了とはしない。

未合格 12 件は次の通りである。

- `nio4r`: rubycc ビルドは通るが sandbox の socket `EPERM`。gcc 対照も同じ。
- `byebug` / `debug`: PTY・socket 制約により上流の対話的テストを完走できない。
- `openssl`: ビルド後に socket 制約と KDF テストの実行時クラッシュがある。
- `oj`: rubycc と gcc の対照の双方で上流テストが失敗し、rubycc 固有の合格とは言えない。
- `puma`: 上流テストが要求する `minitest/proveit` 等の依存が利用できない。
- `google-protobuf`: `<stdatomic.h>` の `_Atomic` 言語機能が未実装。
- `rbs`: gem package に上流テストがなく、さらに designated initializer の typedef/aggregate
  解決が未実装のためビルドも止まる。
- `mysql2` / `thin` / `unicorn`: 必要な外部ライブラリ・依存拡張・上流テスト取得条件を
  この環境では揃えられない。
- `fcntl`: 上流にテストスイートがないため、証拠水準(d)の記録を作らない。

以上は未合格を分母から除外したり、build-only の結果を PASS にしたりせずに残した。
90% の再開条件は、socket/PTY と依存 gem を備えた実行環境でこの 12 件を再走し、
少なくとも 9 件を gem 自身の全テスト合格として確認することである。

## corpus-denominator-1 — 上流にテストが無い gem を分母から外す(M5 H4)

R10 は「コーパスの 90% 以上が **gem 自身のテストスイートに合格**」を目標にしている。
ところが分母に **`fcntl`** が入っていた。**上流にテストスイートが無い**ので、
証拠水準 (d) が**原理的に作れない** gem である(Step 157 の実測)。

**分母に「検証不能なもの」が入っていると、90% が rubycc の能力ではなく
コーパスの作り方で決まってしまう。**

### 機械判定にできなかった

センサスが展開するのは `.gem` パッケージだが、**コーパスのどの gem も
`.gem` にテストを同梱していない**(だから `verify_gem_tests.rb` は上流 tarball を
別途取りに行く)。「`.gem` に test があるか」で判定すると **json や msgpack まで除外される**。

そこで **curated リスト側の宣言**にした。`test/corpus/gems.rb` に
`upstream_tests: false` を書き、センサスがそれを読んで `excluded` にする。
**人が上流を見れば誰でも確認できる事実**なので、宣言でも検証可能性は落ちない。

### 「通らないものを外す」に使えない形にした

ここが設計上いちばん重要なところである。**汎用の `excluded:` にはしなかった。**
何でも除外できる逃げ道があると、**90% は「都合の悪いものを外した結果」になりうる**。

フィールド名を `upstream_tests` に限定し、説明コメントに
**「失敗するから」「テスト環境が無いから」は理由にできない**と明記した。

### R10 の実測値がどこにも出ていなかった

**90% という目標に対する現在値が、生成物のどこにも書かれていなかった**
(この分析でも手で計算した)。センサスに節を足して、
**分母・分子・合格率・90% までの残り件数**を出すようにした。

| R10 ゲート通過 | 検証済み | 合格率 | 90% まで |
|---|---|---|---|
| 36 | 25 | **69.4%** | **8 件** |

Step 188 の決定性は守っている(日時や実行環境を新しい節に入れていない)。
再生成を 2 回行って diff が空になることを確認済み。

---

## atomic-type-1 — `_Atomic` 型指定子を実装する(M5 H4)

google-protobuf が `_Atomic` 未実装だけで止まっていた(Step 214)ので着手した。

### 想定よりずっと小さい仕事だった

着手前に**測った**ところ、**アトミック演算そのものは既に実装済みで gcc と完全一致**していた
(`__atomic_load_n` / `store_n` / `fetch_add` / `exchange_n` / `compare_exchange_n` が
9 形すべてパーサに登録済み)。足りないのは **`_Atomic` 型指定子**と
**ヘッダの総称マクロ**の 2 つだけだった。

**「C11 アトミックの実装」と一括りにしていたら、既にあるものを作り直していた。**

### レイアウトは実測してから同一と決めた

`_Atomic T` を `T` と同じレイアウトとして扱ってよいかを、gcc と突き合わせた:

- **スカラは全て一致**(1/2/4/8/16 バイトのいずれも、サイズ・アラインメントとも)
- **struct は一致しない** — サイズが 2 のべき乗の struct は**アラインメントが引き上げられる**
  (`struct{char a,b;}` が align 1 → **2**、16 バイト struct が align 8 → **16**)

**仮定で進めていたら struct で静かに壊れていた。**

### 受け付ける範囲を決めて、範囲外は診断で落とす

**受理**: 整数・浮動小数・ポインタで幅が 1/2/4/8 バイト。
**拒否**: struct / union、16 バイトスカラ、配列、関数型。

16 バイトを拒否するのは、rubycc が出す ISA ベースライン
(cmpxchg16b 無しの x86-64、LSE 無しの armv8-a)に**単一命令が無い**ためである。
レイアウトは一致するが**アトミックにできない**ので、受けてはいけない。

### 提供しなかったものが、この作業のいちばんの判断

- **`atomic_fetch_or` / `_and` / `_xor` を提供しない。** 既存の組み込みは
  `__atomic_or_fetch`(**新しい値**を返す)であって `__atomic_fetch_or`(**古い値**を返す)ではない。
  **OR は非可逆なので新しい値から古い値を復元できない。**
  名前だけ生やせば**誤った値を返す**ので、出さない方が正しい。
- **`atomic_flag` を提供しない。** 1 バイトの test-and-set 組み込みが無く、
  幅を変えると gcc の `sizeof(atomic_flag) == 1` と ABI が食い違う。
- **`ATOMIC_*_LOCK_FREE` は gcc と意図的に値を変えた。** gcc は全て 2 だが、
  rubycc は拒否する幅を **0**(ロックフリーでない)と答える。
  **分岐する側が「ロックフリーでない」枝に落ちる**ので安全側である。

### 残る制限も書いた

`_Atomic` オブジェクトを**通常の演算子**で読み書きしても、C11 の seq_cst 順序は付かない。
受理幅では自然整列した単一命令になるので**不可分性は保たれる**が、順序が要るなら
マクロを使う必要がある。**黙って落とさず README とヘッダに明記した。**

### それでも google-protobuf は通らない

`ruby-upb.c` を実際にコンパイルして、**次の 3 件を実測**した(いずれも gcc は通る):

1. **`'\?'` 単純エスケープ**が `LexemeReader::ESCAPES` に無い(C11 6.4.4.4)
2. **flexible array member を持つ struct のファイルスコープ初期化**(gcc の拡張)
3. **`jmp_buf` と `sigjmp_buf` の型不一致** — 同梱 `setjmp.h` が別々の無名 union で
   宣言しているが、glibc は**同一の `struct __jmp_buf_tag[1]`** にしている

**「ブロッカーを 1 つ潰したら通る」ではなかった。** 測って初めて分かったことなので、
そのまま次の作業対象として記録する。

---

## atomic-type-2 — `ruby-upb.c` が通るまで詰める(M5 H4)

atomic-type-1 で `_Atomic` を入れたが google-protobuf は通らなかった。
**出てくるブロッカーを 1 件ずつ、最小再現 → gcc 実測 → 実装 → 差分テスト → 再コンパイル
で潰した。** 結果、`ruby-upb.c` を含む拡張の**全ソースがコンパイルできる**ようになった。

| # | ブロッカー |
|---|---|
| 1 | `'\?'` 単純エスケープが無い(C11 6.4.4.4) |
| 2 | flexible array member を持つ struct のファイルスコープ初期化(gcc 拡張) |
| 3 | `jmp_buf` と `sigjmp_buf` が**別々の無名 union** で型が食い違う |
| 4 | 集約サブオブジェクトへの**単一式**初期化子(`.str = f()`) |
| 5 | `_Alignas` 未実装 |
| 6 | **交換した添字** `0[x]`(upb の `ARRAY_SIZE` が使う) |
| 7 | `__builtin_offsetof` の**非定数添字**(upb の `UPB_SIZEOF_FLEX`) |

**7 件。「1 つ潰せば通る」ではなかった。** 測らずに見積もっていたら大きく外していた。

### `jmp_buf` — 同じレイアウトでも「同じ型」ではなかった

`jmp_buf` と `sigjmp_buf` を**別々の無名 union** で宣言していた。
C は無名 union のたびに**別の型**を作るので、`jmp_buf` を `siglongjmp()` に渡すと型エラーになる。
glibc は**ひとつの共有タグ**にしているので通る。

**サイズが同じでも型が同じとは限らない**という形の欠陥で、
`sizeof` を検査していた既存の ABI ハーネスでは**原理的に捕まらなかった**。
そこで **両方の関数族に互いのバッファを渡す** snippet を検査に足した — 幅ではなく**型の同一性**を固定するために。

### 私が入れた変更が回帰を作った

4 番(`.str = f()`)の最初の実装で、`Call` / `VariableRef` / `Cast` を**無条件に**
集約式として扱った。**これは誤りだった。**

```c
pt a[] = { 1, 2, 3, f(), 9, 10 };   /* gcc: 2 要素 / rubycc: 3 要素 */
```

波括弧省略中の `f()` は**内側のスカラが食うべき値**なのに、サブオブジェクト丸ごとを
食っていた。**エラーにならず、要素数が静かに変わる**形の壊れ方である。

分かれ目は式の種類ではなく **指示子の有無**だった:

- **指示子がある** — `.str = f()` は「どのメンバを初期化するか」が確定しており、省略の曖昧さが無い
- **指示子が無い** — 省略の途中なので、スカラとして読むのが正しい

`designated` を通して分けた。**回帰の方向(省略時)にもテストを足した** — 直した側だけ
テストすると、次に同じ誤りをしたとき気づけないからである。

### 設計判断: 自動変数の過大整列は拒否した

`_Alignas` で 16 バイトを超える整列を**自動変数**に要求されたら診断で落とす。
両バックエンドともフレーム基準は 16 バイトで、それを超えるにはランタイム再整列の
プロローグが要る(どちらも出さない)。**黙って弱い境界に置くより落とす。**
upb は静的記憶域しか使わないので影響しない。

### まだ残っているもの

**メンバに付いた `__attribute__((aligned(N)))` は今も捨てられている**
(実測: gcc は `_Alignof` 8、rubycc は 4)。`_Alignas` の配線ができたので数行で繋がるが、
`packed` との組み合わせと引数なし形の実測が別途要る。
**upb は `__GNUC__` を見ないのでブロッカーではない**ため、1 件 1 件の方針に従って残した。

---

## atomic-type-3 — `bundle exec` 下で検証ツールが動かなくなっていた(M5 H4)

`bundle exec ruby tools/verify_gem_tests.rb nio4r` が **scratch GEM_HOME を作る前に**落ちた:

```
FAILED: gem build rubycc.gemspec --output /tmp/rubycc_verify_gem_tests/rubycc.gem
Could not find rake-13.4.2, minitest-6.0.6, ... in locally installed gems (Bundler::GemNotFound)
```

`CLEARED_ENV` は `RUBYOPT` も `BUNDLE_*` も消していたのに、**bundler が子プロセスで
復活していた**。犯人は **`BUNDLER_SETUP`** である。

```ruby
# rubygems.rb の末尾(3.4.5)
require ENV["BUNDLER_SETUP"] if ENV["BUNDLER_SETUP"] && !defined?(Bundler)
```

`bundle exec` がこれに `bundler/setup` の絶対パスを入れる。すると **gem_prelude →
rubygems.rb → bundler/setup** の順で、`RUBYOPT` を経由せずに bundler へ再突入する。
bundler はチェックアウトの Gemfile を **scratch GEM_HOME に対して**解決しようとし、
当然 gem が無いので死ぬ。**環境変数を消す方式の穴**で、消し漏らした 1 個が
別経路(gem_prelude)から入ってきた形である。`BUNDLER_SETUP` を `CLEARED_ENV` に足した。

### 実行ビットの件は「直さず、書き方を直した」

`bundle exec tools/verify_gem_tests.rb` は **`not executable`** で拒否される。
`tools/` の 5 本はすべて **git 上 100644**(shebang はあるが実行ビットは追跡していない)
で、これはリポジトリの一貫した状態なので**そちらが正**とした。誤っていたのは
**ヘッダの Usage が `ruby` を省いていたこと**である(CI も STEPS.md も
`ruby tools/...` と書いていた)。`verify_gem_tests.rb` と `m2_acceptance.rb` の
Usage を実態に合わせ、**なぜ `ruby` が要るのか**を併記した。

### 真因は WSL2 ではなく `core.filemode = false` だった

実行ビットは Step 174・198 でも踏んでいる。**3 回目なので原因を測った。**
「WSL2 だから実行ビットが付かない」は**誤り**である:

| 測ったこと | 結果 |
|---|---|
| チェックアウトの FS | `/dev/sdd` **ext4**(WSL2 の VHD 内。`/mnt/c` の DrvFs ではない) |
| 作業ツリーで `chmod +x` | **効く**(リポジトリ直下に 755 のファイルを作れる) |
| `core.filemode` | **`.git/config` に `false`**(グローバルではなくリポジトリ局所) |

`core.filemode = false` は **git に作業ツリーのモードを見せなくする**。したがって
`chmod +x` しても **index は 100644 のまま**で、`git status` は何も言わない。
**手元では実行できるのに、CI のチェックアウトでは実行できない**という
Step 174・198 そのものの形が、ここから出る。実際に食い違っていた:

```
.claude/agents/code-explore.md          worktree=755  index=100644
references/role-based-model-selection.md worktree=755  index=100644
tools/collect_mkmf_corpus.rb            worktree=755  index=100644
tools/scan_popular_gems.rb              worktree=755  index=100644
.github/scripts/musl-suite.sh           worktree=755  index=100755  ← 正しく追跡されている
```

**`.md` に実行ビットが付いている**のは明らかに意図ではない。
`.github/scripts/*.sh` だけが 100755 で追跡できているのは、**追加時にたまたま
index へ入った**からで、規律があったからではない。

`core.filemode` は `.git/config`(**追跡されない**)なので、設定を直しても
**他の作業者には伝わらない**。伝わる形の防止策は別ステップに切る。

---

## atomic-type-4 — nio4r は環境制約が消えて通った(M5 H4)

PR #19 は nio4r を **「サンドボックスの socket/PTY 制約」で 44 failures** として
記録していた。**制約が今も有るのかを測り直した**ところ、TCP・PTY・UNIX ソケットの
いずれも**動く**。そのまま再走させると:

```
PASS  nio4r 2.7.5  112 examples, 0 failures, 2 pending
```

**rubycc 側の変更はゼロ**である。44 failures は rubycc の欠陥ではなく、
**測定環境の側の状態**だった。

### 教訓 — 「環境が理由で落ちた」は賞味期限付きの記録である

R10 の未検証リストには「環境が理由」の項目が他にもある。それらは
**その時の環境で測った結果**でしかなく、**環境が変われば黙って古くなる**。
今回は 1 件が 44 failures → 0 になった。**再測定を挟まずに未検証のまま数えると、
達成済みのものを未達成として数え続ける。**

同じ理由で保留していた byebug / debug も測り直したが、こちらは別の原因だった:

| gem | 実測した原因 |
|---|---|
| byebug | 535 runs / 22 failures / 6 errors(**内容未分析**) |
| debug | `test/unit/rr` が LoadError(**テスト依存 gem が無い**) |

**socket 制約ではなかった。**「同じ理由でまとめて保留」していたものが、
測り直すと**3 件とも別の理由**だったということである。

R10 通過率は **25/36 = 69.4% → 26/36 = 72.2%**(90% には 33 件、あと 7 件)。

---

## atomic-type-5 — 実行ビットの食い違いを常時検査する(M5 H4)

atomic-type-3 で真因が `core.filemode = false` だと分かったので、**伝わる形**にした。
`.git/config` は追跡されないため、設定を直しても他の作業者には届かない。
テストなら届く。

`test/test_repo_file_modes.rb` は **`git ls-files -s` を読む**。
`File.executable?` では**原理的に捕まらない** — 作業ツリーは 755 に見えるのに
index が 100644、というのがこの欠陥そのものだからである。

方針はディレクトリで割った。リポジトリが既にきれいに割れていたためである:

| 群 | モード | 起動のされ方 |
|---|---|---|
| `exe/`・`.github/scripts/` | **100755** | コマンドとして直に起動(gem の bindir、`run:` ステップ) |
| それ以外 | **100644** | インタプリタ経由(`ruby tools/x.rb`・`sh script.sh`) |

検査は 3 本:

1. 上記 2 ディレクトリの追跡ファイルが 100755 であること
   (失敗時は `git update-index --chmod=+x <path>` をそのまま出す)
2. **それ以外に 100755 が無い**こと — 逆方向。実際 `.claude/agents/*.md` と
   `references/*.md` が作業ツリーで 755 になっていた(明らかに意図ではない)
3. 100755 のファイルが `#!` で始まること

**両方向で実際に落ちることを確かめた**(index を一時的に壊して実測)。
片方向だけ確かめると、次に逆を踏んだとき気づけない。

作業ツリー側の 755 も 644 に揃え、**このチェックアウトの `core.filemode` を `true` に
戻した**(以後 `chmod +x` が `git status` に出る)。ただしこれは局所設定で、
**共有される防止策はテストの方**である。

---

## atomic-type-6 — レガシー `__sync_*` を実装する(M5 H4)

`RUBYCC=1 gem install unicorn` が**依存の raindrops 0.20.1** で止まっていた。
extconf.rb:119 の "GCC 4+ atomic builtins" プローブがコンパイル+リンクできず、
`atomic_ops.h` も無いので **abort する**(代替経路が無い)。

必要なのは実測で **4 種**だった: `__sync_lock_test_and_set`・
`__sync_bool_compare_and_swap`・`__sync_add_and_fetch`・`__sync_sub_and_fetch`。
**kgio 2.11.4 と unicorn 本体はアトミック組み込みを 1 つも使わない**(実測)。

### 範囲の決め方 — 「既存 IR 命令で意味が出せる形だけ」

10 形を実装し、**新しい IR 命令は 1 つも足さなかった**。バックエンドも無変更である
(kind の集合が `__atomic_*` と同じになるため)。

対応する IR 命令が無い 7 綴り(`__sync_fetch_and_or` / `_and` / `_xor` / `_nand`、
`__sync_and_and_fetch` / `_xor_and_fetch` / `_nand_and_fetch`)は
**意図的に未実装のまま**にした。`ATOMIC_BUILTINS` が最初から採っている
「黙って誤った lowering をするより undeclared identifier にする」方針の踏襲である。

### `__atomic_*` と同じノードにしなかった

`BuiltinAtomic` にフラグを足すのではなく **`BuiltinSync` を別ノード**にした。
2 族は**引数のレイアウトが違う**(メモリオーダ引数が無い・CAS が期待値を値で取る)ため、
同じノードを共有すると「`args[2]` はメモリオーダ」という前提のコードを
**取り違えて流用しやすい**。別ノードなら構造的に起こらない。

### 値で取る期待値 — 専用スタックスロットで橋渡しした

`:atomic_cas` は `__atomic_compare_exchange_n` に由来する形で、期待値を**メモリから読み、
失敗時は同じポインタへ書き戻す**。`__sync_*_compare_and_swap` は期待値を**値で**取る。
そこで**新規スタックスロット**を取って `oldval` を書き、そのアドレスを渡し、後で読み直す。

読み直した値が `val_` 形の返すべき「実際に読んだ値」に**両方の結果で**一致する:
失敗時は `:atomic_cas` が読んだ値で上書きしており、成功時は定義上 `oldval` がそのまま残る。
スロットは新規なのでアトミックオブジェクトと**絶対に別名にならず**、
書き戻しの別名ガードはここでは無関係になる。

### 実測して分かったこと

| 項目 | 実測結果 |
|---|---|
| ポインタ型への加算 | **スケールされず生バイト**。`int *p` に `__sync_fetch_and_add(&p, 1)` で **1 バイト**進む |
| `bool_` 形の結果 | **1 バイトの `_Bool`**(gcc のマニュアルは `bool` としか書かない) |
| 末尾の余分な引数 | gcc は**本当に黙って無視する**。`__sync_add_and_fetch(&i, 1, 2, 3)` が通る |
| `__sync_lock_release` | ポインタオブジェクトも**幅ぶんゼロ書き**して NULL にする |

ポインタ加算の件は `__atomic_*` 側のコメントに同じ主張があるが、
**引き写さずに独立の差分テストで測り直した**(`test_sync_pointer_add_is_unscaled`)。

引数の**固定アリティは rubycc 側で要求する**ことにした。gcc の「余分を無視」に
合わせても得るものが無く、綴り間違いが黙って通るだけだからである。

### 計測プログラム自体の落とし穴

最初の計測で `printf("%u %u\n", __sync_or_and_fetch(&u, x), u)` と書いたところ、
gcc(右→左)と rubycc(左→右)で出力が食い違った。**アトミックのバグではなく、
C が未規定にしている引数評価順の差**である。テストとサンプルは
「builtin を 1 文で実行 → 次の `printf` でオブジェクトを読む」形に統一した。

### 副作用として受け入れたもの

10 綴りを**キーワード**にしたので、`static inline unsigned long __sync_add_and_fetch(...)`
と**自前定義する**ソースはその分岐に入るとパースエラーになる。raindrops の場合その
`#else` は `HAVE_GCC_ATOMIC_BUILTINS` 未定義時のみで、プローブが通る以上到達しない。
`__atomic_*` 族が最初から持っている性質と同じである。

### まだ通っていない

raindrops の `raindrops.c` はコンパイルできるようになったが、
**`linux_inet_diag.c` が `AF_NETLINK` 未定義で落ちる** — 同梱の
`include/libc/sys/socket.h` が `AF_UNSPEC/UNIX/LOCAL/INET/INET6` の 5 つしか持たない。
**アトミックとは無関係のヘッダギャップ**なので、1 件 1 件の方針に従って次のステップに切る。

---

## atomic-type-7 — unicorn がインストールできるまでヘッダを埋める(M5 H4)

atomic-type-6 で `__sync_*` が通ったあと、`RUBYCC=1 gem install unicorn` を
**1 件ずつ実測で潰した**。ブロッカーは**すべて同梱ヘッダの欠落**で、
コンパイラ本体の変更は 1 行も要らなかった。

| # | 欠落 | 要求した側 | 実測値 |
|---|---|---|---|
| 1 | `AF_NETLINK` / `PF_NETLINK` | raindrops `linux_inet_diag.c` | 16(両 arch 一致) |
| 2 | `INET_ADDRSTRLEN` / `INET6_ADDRSTRLEN` | 同上 | 16 / 46 |
| 3 | TCP 状態機械の 11 状態 | 同上 + `tcp_info.c` | 1〜11 |
| 4 | `in6addr_any` / `in6addr_loopback` | 同上 | **マクロではなくオブジェクト** |
| 5 | `accept4` | kgio `accept.c` | Linux 拡張の宣言 |
| 6 | `_SC_IOV_MAX` | kgio `writev.c` | 60 |

**5 番と 4 番は種類が違う。** 1〜3・6 は整数値なので実測して書けば済むが、

- **`in6addr_any` は libc の実オブジェクト**である(実測: `nm -D` で
  `V in6addr_any@@GLIBC_2.2.5`)。同梱ヘッダは `IN6ADDR_ANY_INIT` マクロしか
  持っていなかった。raindrops は `memcmp(&in6addr_any, ...)` と**アドレスを取る**ので、
  初期化子マクロでは代替できない。**宣言が無いとリンク時にも解決されない。**
- **`accept4`** は `SOCK_CLOEXEC`/`SOCK_NONBLOCK` を accept 自体に畳み込む Linux 拡張で、
  glibc は `_GNU_SOURCE` で隠す。同梱ヘッダは既に `SOCK_CLOEXEC` を無条件に見せているので、
  **専用の feature-test マクロを増やさず**同じ扱いにした。

### AF_ を 1 個だけ足した理由

アドレスファミリは数十個ある番号空間で、`AF_NETLINK` だけ足すのは一見中途半端である。
それでも **名指しで要求された 1 個だけ**にした。残りは**誰も測っていない値**であり、
測っていない値を置くのはこのプロジェクトが一貫して避けてきたことだからである
(`sys/syscall.h` の番号表・`unistd.h` の `_CS_`/`_PC_` 名と同じ判断)。

### 検査

6 件すべてを ABI ハーネスに載せた(**x86_64・aarch64 の両方で自動再走**)。
整数は `ints:` に、`in6addr_*` と `accept4` は**実際に呼ぶ/参照する snippet** として
足した — 宣言があるだけでは、リンク時に解決されるかを検査したことにならない。
`accept4` の snippet は接続を待たない非ブロッキング listen ソケットに対して呼び、
**EAGAIN が返ること**を答えにしてある。

検査が効いていることは**壊して確かめた**: `AF_NETLINK` を 17 に書き換えると
**x86_64・aarch64 の両方で落ちる**。通ったことを通ったと言うには、
落ちるはずのものが落ちることを見ておく必要がある。

### 結果 — ビルドは通る。テストは gcc でも通らない

**`gem install unicorn` が成功する**(raindrops 0.20.1・kgio 2.11.4・unicorn 6.1.0 の
3 つとも rubycc がビルド)。上流テストを 15 ファイル走らせると:

```
224 tests 中、失敗は 3 ファイル
  test_request.rb  10 errors
  test_signals.rb   1 error
  test_util.rb      3 failures
```

**gcc で同じ 3 つを建てて同じ 3 ファイルを走らせたら、数値が完全に一致した**
(10 errors / 1 error / 3 failures)。unicorn 自身がロード時に
`Unicorn was only tested against MRI up to 3.0. It might not properly work with 3.4.5`
と言う。失敗の中身も `fp.external_encoding` が nil を返すといった **Ruby 3.4 側の
非互換**で、C 拡張には触れていない。unicorn 6.1.0 が最新版なので、上げて逃げる先も無い。

**つまり rubycc の非ではないが、(d) 水準の「gem 自身のテストが通った」証拠は得られない。**
oj と同じ形である(あちらも gcc 対照が落ちる)。R10 の分母をどう扱うかは
**測定とは別の判断**なので、ここでは記録だけして分母は動かしていない。

---

## atomic-type-8 — 対照を機械化し、分母の 2 つ目の除外理由を入れた(M5 H4)

R10 の分母には「**どの実装で建てても (d) 水準の証拠が取れない gem**」が混ざっていた。
corpus-denominator-1 で 1 つ目(上流にテストが無い)を外したので、
**2 つ目(上流テストが対照コンパイラでも通らない)**をここで外す。

ただしこれは **corpus-denominator-1 より強い主張**である。「テストが落ちる」と
「rubycc と無関係な理由でテストが落ちる」は **rubycc 側だけを見ても区別がつかない**。
nio4r がその反例として立っている — 44 failures で環境要因として記録され、
**rubycc を 1 行も変えずに 0 failures** になった。だから**測定を先に道具にした**。

### `tools/verify_gem_tests.rb --control`

`RUBYCC=1` を付けずに**まったく同じ手順**を回す。要点は 3 つ:

- **別の scratch GEM_HOME**(`gemhome-control`)。同じものを使い回すと、
  どちらのビルドの `.so` が残っているのか分からなくなる。
- **ビルド証拠の検査を裏返す**。通常は「rubycc が使われた証拠」が無ければ失敗にするが、
  対照では **rubycc の痕跡が有ったら失敗**にする。対照が黙って rubycc を使ってしまったら、
  比較が無意味になったことに気づけない。既存の sanity チェック(拡張がロードされずに
  テストが通るのを防ぐ)と同じ種類のガードである。
- **`--update` との併用を禁止**。対照の結果を「検証済み」として記録するのは、
  このツールが存在する理由そのものに反する。

これは ROADMAP §2 の不変条件「**差分テストは、対照と自分を同じ条件に置く**」の機械化でもある。
同じ落とし穴を 4 回踏んだ実績があり、5 回目は人手の注意では防げない。

### 測った結果 — 3 通りに割れた

| gem | 対照(gcc) | rubycc | 判定 |
|---|---|---|---|
| byebug | 535 runs / 22 fail / 6 err / 2 skip | **完全一致** | 除外 |
| debug | 305 tests / 1 fail / 1 omission | **完全一致** | 除外 |
| unicorn | 10 err・1 err・3 fail(ファイル別) | **完全一致** | 除外 |
| oj | 627 runs / 37 fail / **35 err** | 627 runs / 49 fail / **14 err** | **除外しない** |
| puma | 840 runs / 6 fail / **7 err** | 840 runs / 6 fail / **8 err** | **除外しない** |

**除外は「対照と数値が一致したときだけ」に限った。** 落ち方が違うということは、
その差は rubycc が出しているということで、**追うべき欠陥であって縮めるべき分母ではない**。
この線引きは `test/corpus/gems.rb` の `:control_suite_passes` の説明に書いた。

puma は **1 error 差**まで来ている。サーバを立てる時間依存のスイートなので
再測定が要るが、**どちらにせよ除外しない側**なので分母はそのままにした。
**保守的に外す方へ倒す**のが、分母を動かす変更での正しい誤り方である。

### 除外の前に確かめたことが 2 件を救った

debug と puma は最初 `UNPARSABLE` で、対照でも同じだった。中身を見たら
**テスト依存 gem が無いだけ**だった:

| gem | 欠けていたもの |
|---|---|
| debug | `test/unit/rr`(gem `test-unit-rr`) |
| puma | `minitest/proveit`・`minitest/stub_const`・`minitest/mock` ほか 5 本 |

**除外せずに入れたら走った**(debug 305 tests、puma 840 runs)。
「対照でも落ちる」で機械的に外していたら、**測れるものを測らずに捨てていた**。

### ツール自身の欠陥 — ピン留めが後から効かなくなる

puma は minitest を 5.x に固定する必要がある(6 系は `minitest/mock` を別 gem に
出しており、その別 gem は minitest ~> 5 に依存するので、6 系が activate された時点で
require が満たせない)。ところが**ピン留めの掃除が「未インストールのとき」しか
走っていなかった**。scratch GEM_HOME は全レシピ共有なので、後から走る byebug の
**ピン無し `minitest`** が 6.0.6 を引き戻し、puma が `require "minitest/mock"` で死ぬ。

**共有環境が後から書き換わる**形の事故で、症状(LoadError)は原因を少しも示さない。
掃除を**毎回**走らせるようにした。

### 結果

R10 通過率 **26/36 = 72.2% → 26/33 = 78.8%**(90% には 30 件、**あと 4 件**)。

---

## atomic-type-9 — 残り 4 件の内訳を測り切った(M5 H4)

atomic-type-8 で分母が 33・分子 26 になり、90% まで **4 件**。
残る未検証 6 件が**それぞれ何で止まっているのか**を、推測せず 1 件ずつ測った。

| gem | 止まっている理由 | 種類 |
|---|---|---|
| **mysql2** | **K&R(旧形式)の関数定義**が未実装 | **rubycc の欠陥**(GAPS Q) |
| **oj** | 対照と落ち方が違う(37/35 err 対 49/14 err) | **rubycc の欠陥**(未調査) |
| **puma** | 失敗は bundler 環境と不安定な結合テスト | 環境 |
| **thin** | 依存 eventmachine が C++ | 対象外(OUT-OF-SCOPE 基準 A) |
| **google-protobuf** | テスト取得に `protoc` が要る | 環境 |
| **rbs** | 未再測定 | 不明 |

### puma — 差は「両方向」に出た

対照と rubycc で失敗テスト**名の集合**を取って差を見た。回数ではなく名前で比べたのは、
サーバを立てる時間依存のスイートは回数が動くからである(実際、**同じ gcc ビルドの
2 回の実行で 6 failures と 7 failures**になった)。

| | 名前 |
|---|---|
| gcc にだけ | `TestIntegrationCluster#test_hot_restart_does_not_drop_connections_threads` |
| rubycc にだけ | `#test_phased_restart_does_not_drop_connections`・`#test_refork_phased_restart_with_fork_worker_and_high_worker_count` |

**14 件中 13 件は共通**で、残る 3 件はすべて同じ `TestIntegrationCluster`
(worker を fork して phased restart 中の接続断を見る族)である。
**rubycc が gcc の落ちるテストを通せるはずがない**ので、gcc 側にだけ出る 1 件は
不安定さの証拠になる。共通の 13 件は `TestWorkerGemIndependence` /
`TestPreserveBundlerEnv` など **bundler 環境**のテストで、C 拡張に触れていない。

除外はしない。**両方向に差が出るものを「対照と一致」とは呼べない**からである。

### mysql2 — ヘッダが入って、次のブロッカーが出た

`libmariadb-dev` の導入後、extconf の 18 個のプローブはすべて通る
(`mysql.h` / `errmsg.h` / `MYSQL.net.pvio` ほか)。止まるのは `client.c` で、
原因は同梱の `mysql_enc_name_to_ruby.h` — **gperf の生成物**で、旧形式定義である。

**ROADMAP §3 の既知債務「K&R `int ()` 型」に、ついに実害が出た。**
「実害が出た時点」で先送りしていたものが、コーパスの側から回ってきた形である。

### thin — 拒否の仕方が間違っている

`gem install thin` を実際に走らせた。eventmachine の `.cpp` 9 本に対して rubycc は
`warning: em.cpp: linker input file unused because linking not done` を出すだけで、
**何も生成せずに成功したふりをする**。落ちるのはずっと後のリンク段階で、
メッセージは `No such file or directory - binder.o` である。**原因を少しも示さない。**

C++ が対象外なのは R10 が明示しているとおりで、**そこは正しい**。
正しくないのは**言い方**で、ROADMAP §2 の「未対応機能は黙って壊さない —
明確な文言の診断で拒否する」に反している(GAPS R)。

---

## atomic-type-10 — K&R 旧形式の関数定義(M5 H4)

GAPS Q。mysql2 の同梱ヘッダ `mysql_enc_name_to_ruby.h`(**gperf の生成物**)が
旧形式定義で、`client.c` が止まっていた。ROADMAP §3 の既知債務
「K&R `int ()` 型」に**実害が出た**ので実装した。

### 設計の要点 — 「宣言された型」と「受け取る型」を分けた

旧形式定義の関数は**プロトタイプを持たない**ので、パラメタは既定の実引数拡張を受ける。
つまり `float f;` と書いてあっても、実際に届くのは `double` である。
そこで `AST::Parameter` に **`incoming_type`** を足し、

- **関数型の引数型 = 拡張後の型**(ABI とシグネチャを駆動)
- **`Parameter` の型 = 宣言どおりの型**(本体を駆動)

の 2 本立てにした。**この分離が本質**で、片方に寄せると本体が誤った型で書かれるか、
ABI が食い違うかのどちらかになる。

### 実測して分かったこと

| 実測 | 結果 |
|---|---|
| 狭い整数の受け取り | **変換命令が要らない**。gcc は昇格 `int` の**下位バイトを格納するだけ**で、`_Bool` を 0/1 に正規化しない(`take_bool(2)` は **2** を返す) |
| `float` の受け取り | ここだけ本物の変換が要る(`double` で受けて `ftof`) |
| プロトタイプ併記時 | gcc は**プロトタイプ側の ABI** を使う。`double h(float); double h(f) float f;` は `xmm0` に float をそのまま受け(`movss`)、プロトタイプ無しの同じ定義は double を受けて `cvtsd2ss` する |
| 6.7.6.3p14 の適合性 | gcc は**宣言どおりの型を書いたプロトタイプも受理**し、警告は `-Wpedantic` のときだけ |

**「昇格後の型と適合すること」という規格の文面どおりに実装していたら、
gcc が受理するものを拒否していた。** 測ってよかった箇所である。
`プロトタイプ型 == 宣言型 || プロトタイプ型 == 昇格型` のときプロトタイプ側を採る形にした。

gcc が**拒否する**組み合わせ(`int f(long); int f(a) int a;` ほか)は、
昇格型のまま既存の `conflicting types` に落ちて**同じ受理/拒否**になる。4 件をテストで固定した。

### 定義でない位置の識別子リストは診断で落とす

`int f(x);` を gcc は警告だけ出して `int f()` と読む。rubycc は**診断エラー**にした。
無プロトタイプ関数型を持たないので、そう読むと `(void)` シグネチャで全呼び出しを
誤検査することになるからである。**現状も落ちていた**(`expected type specifier`)ので
後退はなく、文言が正確になっただけである。

名前に付かない接尾辞(`int (*g)(a,b);`)も捕捉する。**黙って `()` と読まない。**

### 残した既存制限

`int f(); int f(a) int a; {...}` は `conflicting types` になる。これは
**`int f()` を `(void)` としてモデル化している既存の負債**(ROADMAP §3、
c-testsuite 00209 の skip 理由)そのもので、`f()` の挙動は今回変えていない。

---

## atomic-type-11 — 空ポインタ定数の判定が規格より狭かった(M5 H4)

mysql2 の**最後のブロッカー**:

```
client.c:1213:74: error: invalid operands to binary expression
  if (rb_thread_call_without_gvl(...) == Qfalse)
```

CRuby の `Qfalse` は `((VALUE)RUBY_Qfalse)` で、`RUBY_Qfalse` は**値 0 の enum 定数**。
`AST.null_pointer_constant?` は「値 0 の整数リテラル」か「それを `void *` へキャストしたもの」
しか認めていなかった。

**これは gcc 拡張への追随ではなく、rubycc 側の適合性の欠陥である。** ISO C11 6.3.2.3p3:

> **An integer constant expression with the value 0**, or such an expression
> cast to type `void *`, is called a null pointer constant.

整数型へのキャストは 6.6p6 により**整数定数式のまま**なので、`(unsigned long)0` は
規格の第 1 の選択肢そのものに当たる。`void *` へのキャストは**追加の**選択肢であって、
唯一の形ではなかった。

### 実測した境界

| 式 | gcc |
|---|---|
| `p == (VALUE)0` | 受理・無警告 |
| `p == (VALUE)(1 - 1)` | 受理・無警告 |
| `p == (char)0` | 受理(`-Wpointer-compare` の警告は出るが受理する) |
| `p == (VALUE)1` | `comparison between pointer and integer` = 空ポインタ定数ではない |
| `p == (double)0` | **error**。浮動小数型は整数定数式ではない |

### 既存の定数評価器に乗るだけで足りた

`ConstantEvaluator#evaluate_cast` は既に
「**整数型へのキャストのみ畳む・浮動小数型へのキャストは畳まない**」(6.6p6)という
規約を持っていた。判定をそこへ委譲すると、`(VALUE)0` / `(char)0` / `(VALUE)(1-1)` /
enum 定数が**一様に**「値 0 の整数定数式」として認識され、`(VALUE)1` は非ゼロ、
`(double)0` は畳めない、で自然に落ちる。**新しい規則を書かずに済んだ。**

**両方向をテストで固定した** — 受理側だけ書くと、次に広げすぎたときに気づけない。

### 結果

**`RUBYCC=1 gem install mysql2 --version 0.5.7` が成功する。**
extconf の 18 プローブ通過 → 全 5 翻訳単位のコンパイル → `mysql2.so` の生成まで通った。

---

## atomic-type-12 — 残り 3 件の正体を突き止めた(M5 H4)

atomic-type-10 / 11 で mysql2 のビルドが通ったので、
**oj・mysql2・rbs が本当は何で止まっているのか**を測り切った。

### oj — ランダムなテスト順が数値を揺らしていただけだった

これまでの計測で対照と rubycc の failures/errors が毎回違っていた
(37/35 対 49/14、次の回は 40/36 対 48/19)。**minitest が既定でテスト順を
ランダム化する**のが原因で、**回数を比べていたこと自体が誤り**だった。

`--seed 1234` で順を固定し、**失敗テスト名の集合**で比べたところ:

```
gcc    75 件
rubycc 76 件
gcc にだけ:    (無し)
rubycc にだけ: UsualTest#test_decimal
```

**差はちょうど 1 件。** 74 件の共通失敗は oj 側の事情で、rubycc は無関係である。

### その 1 件は `long double` だった

```
UsualTest#test_decimal:
ArgumentError: invalid value for BigDecimal(): "-nan"
```

oj の `usual.c:470`:

```c
static void add_float_as_big(ojParser p) {
    char buf[64];
    sprintf(buf, "%Lg", p->num.dub);   /* p->num.dub は long double */
```

最小再現:

| | 出力 | `sizeof(long double)` |
|---|---|---|
| gcc | `[1.23457]` | **16** |
| rubycc | `[7.46537e-4948]` | **8** |

rubycc は `long double` を `double` として扱う(DESIGN 3.3 の既知の制限)。
可変長引数に 8 バイトを積むが、**glibc の `sprintf` は `%Lg` で 16 バイトを読む**。
食い違った分だけずれた値が出る。

**ROADMAP §3 の負債「long double = double 扱い」に、初めて実害が出た。**
これまでは `max_align_t` の相違としてしか観測されておらず、
ABI ハーネスの該当検査を非 assert にして先送りしていたものである。
解消には x87 80 ビット対応が要り、1 ステップの仕事ではない。

**oj は分母に残す。** 対照が通すテストを rubycc が落としているのだから、
これは rubycc が負うべき差である。

### mysql2 — 対照と完全に並んだ

`libmariadb-dev` 導入 + atomic-type-10/11 でビルドが通り、上流 spec を走らせた。

| | 結果 |
|---|---|
| rubycc | **340 examples / 1 failure / 6 pending** |
| gcc | **340 examples / 1 failure / 6 pending**(**同じ 1 件**) |

残る 1 件は `result_spec.rb:240`「streaming が timeout で終わることの検査」で、
`net_write_timeout = 1` を設定して読み遅らせる形。**ループバック接続では発火しない**
(bridge / host どちらのネットワークでも同じ)。gcc でも落ちるので **rubycc の非ではない**。

### DB は Docker で用意した

ホストに MariaDB を入れる案もあったが、**コンテナの方が正しい** — 版を固定でき、
ホストを汚さず、このリポジトリが musl コンテナで既に採っている流儀と揃う。

```
docker run -d --name rubycc-mariadb --network host \
  -e MARIADB_ROOT_PASSWORD=rubycc -e MARIADB_DATABASE=test mariadb:11 --port=3307
```

**ホストに mariadb-server が居ると邪魔になる**という罠があった。
mysql2 の spec の 1 つが `host: 'localhost'` を直書きしており、MySQL の規約では
`localhost` は**ポート指定を無視して UNIX ソケット**を使うので、
コンテナではなく**ホストのサーバ**に当たる。そちらは `unix_socket` 認証なので
エラー番号が違い、spec が期待する例外クラスにならない。
`MYSQL_UNIX_PORT` を存在しないパスに向けて、ソケット経路を閉じて解決した。

### rbs — ビルドは通る

`RUBYCC=1 gem install rbs --version 3.10.0` は**成功する**(`rbs_extension.so` 生成)。
上流テストは開発依存が 15 本以上あり(`rspec` / `json-schema` / `goodcheck` /
`rubocop-on-rbs` ほか)、レシピ化は別途。**ビルド不可という以前の記録は誤りだった。**

---

## 現在のテスト規模

atomic-type-11 完了時点: **2,949 runs / 9,355 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-10 から +5 = 整数キャスト形の空ポインタ定数の gcc 差分実行(x86_64・aarch64)・
`(VALUE)1` と `(double)0` が落ちることの診断 + サンプル 1 本)
(以前) atomic-type-10 完了時点: **2,944 runs / 9,342 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-8 から +14 = K&R 定義の gcc 差分実行(x86_64・aarch64)・制約違反の診断・
既定の実引数拡張・プロトタイプ併記の受理/拒否 4 件 + サンプル 1 本。
atomic-type-9 は測定と文書のみでテスト増なし)
(以前) atomic-type-8 完了時点: **2,930 runs / 9,248 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-6 から +2 = `:control_suite_passes` の検出と、除外が測定を引用していることの検査。
atomic-type-7 はヘッダ追加のため ABI ハーネス既存ケースへの追記でテストメソッドは増えない)
(以前) atomic-type-6 完了時点: **2,928 runs / 9,230 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-5 から +23 = `__sync_*` の gcc 差分実行(x86_64・aarch64)・
未実装綴りの undeclared identifier・アリティ違反の診断 + サンプル 1 本)
(以前) atomic-type-5 完了時点: **2,905 runs / 9,065 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-4 から +3 = リポジトリの実行ビット検査)
(以前) atomic-type-4 完了時点: **2,902 runs / 9,059 assertions / 0 failures / 0 errors / 44 skips**
(atomic-type-2 からテストメソッドは増えず、assertions のみ +249 = nio4r の記録が
`data/verified_gems.json` を舐めるドクターのテストの照合対象に入ったため)
(以前) atomic-type-2 完了時点: **2,902 runs / 8,810 assertions / 0 failures / 0 errors / 44 skips**
(以前) atomic-type-1 完了時点: **2,874 runs / 8,698 assertions / 0 failures / 0 errors / 44 skips**
(以前) corpus-denominator-1 完了時点: **2,855 runs / 8,601 assertions / 0 failures / 0 errors / 44 skips**
(以前) master マージ後の統合スイート: **2,846 runs / 8,575 assertions / 0 failures / 0 errors / 44 skips**
(`rake test` の実測値)
Step 214 完了時点: **2,841 runs / 8,557 assertions / 0 failures / 0 errors / 44 skips**
(ホスト側 `rake test` の実測値。Step 208 から +7 runs / +137 assertions。atomic fence、
parser の空宣言、Doctor の5 gem許可リスト、dlfcn/link/regex ABI と aggregate 初期化子の
回帰テストを含む)
Step 207 完了時点: **2,833 runs / 8,395 assertions / 0 failures / 0 errors / 44 skips**

## differential-discipline-1 — 再発防止の 4 番と 2 番(M5 H6)

> **採番方式の変更はここから**: このブランチは当初 Step 208・209 を使っていたが、
> 並行して master に入った作業が先に Step 208 を取った。**Step 202 と同じ衝突の 2 度目**。
> そこで**ここから採番方式を変えた**(下の「採番方式」節)。この 2 件が新方式の最初の適用で、
> **コミットの件名には旧番号(Step 208・209)が残っている**ので、追うときはこの対応を見ること。

Step 207 の続き。提示した 4 つの対策のうち **4 番(レビューで訊く質問)と
2 番(固有名リテラルの検査)**を入れた。

### 4 番 — 規約に「1 問」を足した

`docs/ROADMAP.md` §2「実装規約と不変条件」(**違反はレビューで差し戻す**)に、
差分テストを書く・直すときの問いを 1 つ足した:

> **この行は、libc が違ったら / 機種が違ったら / ツールチェインの既定が違ったら、
> 間違いになるか?**

**一般論として書かないよう気をつけた。** 4 件の事故を表にして
「どこに書いていたか」を並べ、**実績のある落とし穴**として提示している。
「テストは慎重に」では 4 回とも防げなかったので、
**答えられるかどうかで判定できる形**にした。

### 2 番 — 検査を作る前に、範囲を実測で決めた

「プラットフォーム固有名をリテラルで書かない」を素直に検査すると
**66 箇所**が引っかかる(18 ファイル)。大半は正当である —
`aarch64-linux-gnu-gcc` はクロスツールの**プログラム名**、
`/usr/lib/x86_64-linux-gnu` は**そのホストの事実**であって仮定ではない。
**そのまま入れれば抑止コメントで埋まり、誰も読まなくなる。**

そこで **libc の同一性を名指しするものだけ**に絞った
(`libc.so.6` / `libc.musl-` / `__GLIBC__` 系)。**12 箇所**。
**繰り返し静かに壊れてきたのはこの軸だけ**だからである。
絞った理由も検査のコメントに書いた。

### 絞ったら、**未修正のバグが 3 件出てきた**

これが 2 番を入れた最大の収穫である。**Step 194 は同じバグの一部しか直していなかった**:

| 場所 | 状態 |
|---|---|
| `test_shared_object.rb` ×3 | `libc.so.6` を決め打ち。**未修正だった** |
| `test_elf_reader.rb` ×2 | 同上 |
| `test_aarch64_self_link.rb` | 同上(こちらはクロス sysroot が glibc なので注釈が正解) |

**「1 件直したから直った」と思っていた。** 検査を書くまで残りに気づかなかった。

### 3 つ目のコピーを作らずに済ませた

Step 194 で `host_libc_soname` を **2 ファイルに別々に**書いていた。
今回さらに増やすところだったので、`test/support/libc_helper.rb` に**1 つにまとめ**、
既存の 2 箇所もそちらを使うようにした。
**同じ知識が 3 か所にあると、次に環境が増えたとき 3 か所とも直す必要が出る。**

### 許可の仕組み — 正直な道を狭くしない

`# platform-literal: <理由>` があれば通す。**理由が空なら通さない**
(「なぜ許されるか」を書かせるのが目的)。

最初の実装は**同じ行か 1 行上だけ**を見ていた。
そのため**3 行にわたる理由が拾えず**、正当な注釈が落ちた。
**理由を短く書けと強制する検査になっていた**ので、
直前の連続したコメントブロック全体を見るように直した。
**検査が、正直な道を不正直な道より面倒にしてはいけない。**

### 歯があることを実証した

わざと違反を 1 行入れて、**実際に落ちること**を確かめた。

### 1 番は未着手

「両側を 1 つのプロファイルから作る」はまだ入れていない。

---

## differential-discipline-2 — 両側を 1 つのプロファイルから作る(M5 H6)

再発防止の**対策 1**。これで 4 つ全部が入った。

### 対症療法では構造が残っていた

Step 206 で `run_abi_case` に `pic: true` を足したが、
**「両側が独立に設定を決められる」構造はそのまま**だった。
次に軸(最適化レベル、`-D_FORTIFY_SOURCE`、エンディアン…)が増えれば同じことが起きる。

`BuildProfile`(`target` / `libc` / `pic`)を 1 つ作り、
**プローブ本文の libc も、rubycc のコンパイルオプションも、gcc 側のフラグも、
すべて 1 つのプロファイルから取る**ようにした。

### 肝は **gcc 側にも明示的に渡す**こと

これまで gcc 側は `compile_with_gcc` を素で呼び、**gcc の既定に任せていた**。
**それが Step 206 の原因そのもの**である。
`compile_with_gcc` に `pic:` を足し、プロファイルから組み立てたフラグを渡す。
**「片側だけ既定に任せる」ことが構造的にできなくなった。**

### 検査は「転記」ではなく「測定」にした

新しいテストは、**同じプロファイルから gcc と rubycc の両方を実際にコンパイルし、
外部データ参照の**リロケーション種別を `ELFReader` で読む**。
`pic` が真なら両者とも GOT 経由、偽なら両者とも直接参照 —
**それを値の書き写しではなく、出てきたオブジェクトから読んで確かめている。**

**このプロジェクトは「自分が書いた値を自分で検証する」検査を何度も書きかけている**
(Step 204 で G を閉じなかった理由、Step 207 のオプション共有)。同じ轍を踏まない形にした。

### `abi_probe_source` の 20 箇所は触らなかった

libc だけを振ってプローブ本文の安定性を確かめる検査が 20 箇所ある。
**あれらは libc しか関心が無い**ので、プロファイルを組ませるのは不必要な変更である。
**構造を直すことと、全部を書き換えることは違う。**

### 4 つの対策が出揃った

| | 対策 | 入った Step |
|---|---|---|
| 3 | 非既定プロファイルを開発機で毎回走らせる | 207 |
| 4 | レビューで訊く 1 問を規約に | 210 |
| 2 | 固有名リテラルの検査 | 210 |
| 1 | 両側を 1 つのプロファイルから作る | **211** |

**3 と 1 は「起こせなくする」、2 と 4 は「起きたら気づく」**。
前者だけでは新しい型を防げず、後者だけでは人の注意力に依存する。

---

## symbolic-decision-1 — シンボル介入は現状維持と決めた(M5 H6)

ギャップ N の**方針決定**。コードは変更していない。**「直さない」と決めた記録**である。

### まず測り直した — 関数でも同じだった

Step 195 で測ったのは**データ**シンボルだけだった。関数はどうかを測っていなかったので、
決める前に測った。介入する定義を先に載せてから両方を呼ぶ:

```
gcc    ask() = 99   ← 先に載った定義に束縛(介入する)
rubycc ask() = 1    ← 自分の定義に束縛(介入しない)
```

**データ・関数の両方**である。影響範囲は
**「その共有ライブラリが自分で定義し、かつ自分で参照しているグローバルシンボル」**だけ。
純粋な import は GOT/PLT を通らなければリンクすら通らないので、元から正しい。

### R9 の ABI は壊れていない

R9 が名指ししているのは**手続き呼び出し規約**である
(構造体の値渡し・返し、可変長引数、アラインメント、ビットフィールド)。**そこは無傷**。
逸脱しているのは **ELF の動的リンク時のシンボル解決**で、R9 の列挙には無い。
**「ABI 互換が壊れる」と一括りにすると判断を誤る**ので、層を分けて記録する。

### 前の整理は正確ではなかった

当初「(a) gcc の既定に合わせる = 正しい」「(b) 現状維持 = 妥協」と書いた。**そうではない。**

現状の挙動には **`-Bsymbolic` という名前が付いていて**、ld が意図的に提供するオプションであり、
**多くのディストリビューションが性能のために有効化している正規の構成**である。
gcc の既定に合わせれば自己呼び出しが PLT を経由する分**遅くなる**。
つまり (a) と (b) は「正/誤」ではなく**トレードオフ**だった。

### 決定 — (b)、ただし条件つき

**現状維持。切り替えも提供しない。** 実害が出る場面は 3 つに限られ、
Ruby 拡張の実運用ではいずれも稀である:

1. `LD_PRELOAD` による差し替えが効かない
2. 同じシンボルがプロセス内に既にあるとき、コピーが 2 つ生きる
3. 同じサードパーティ C ライブラリを 2 つの gem が同梱している場合(2 と同型)

**「実在の gem で実害が出たら再検討する」**(ユーザ判断、2026-08-06)。
**永久の決定ではない**ので、再検討の条件を `docs/GAPS.md` §4 に条件つきで書いた。

### 正規の構成との唯一の違い

`-Bsymbolic` は本来**リンカのオプション**で、`.so` を作るときに選ぶものである。
**rubycc は選択の余地なく常にそう振る舞う。** 利用者が指定していないのにそうなる点だけが、
正規の構成との違いである。**そこは隠さず README に書いた。**

### ついでに直したもの

README の「Known limitations」に**既に解消済みの項目が 2 つ**残っていた
(`ckd_*` は Step 177 で実装し `<stdckdint.h>` は Step 179 で同梱済み、
CI マトリクスは `test.yml` に存在する)。
**既知の制限の一覧に嘘が混ざっていると、隣に書いた本当の制限も信用されなくなる**ので、
書き足すついでに実態に合わせた。

---

## symbolic-decision-2 — v1.0 リリース準備(M5 H6)

**準備のみ。タグも `gem push` もしていない**(ユーザ指示)。

### やったこと

`0.1.0` → `1.0.0`、`CHANGELOG.md` 新設、README の実績を実測値に更新
(検証済み 18 gem、musl 3、aarch64 2)。

**gem を `SOURCE_DATE_EPOCH` 固定で 2 回ビルドしてバイト一致を確認**した
(474,112 bytes)。N4「決定的ビルド」の配布物版で、Tier C が同じことをする。

### 準備中に見つけた欠陥 2 件

**`rubycc-doctor --version` が「version unknown」を返していた。**
OptionParser は `--version` を自前で処理するが、**バージョンを渡していなかった**ので
既定のフォールバックが出ていた。**バージョンを知っているコマンドの答えとして不適切**である。

途中で「未知の `--flag` が全部 gem 名になる」と読んだが、**これは誤りだった** —
実際には `invalid option: --bogus` と正しく拒否される。**確かめてから書くべきだった。**

**`CHANGELOG.md` が gem に入らなかった。** 作ったファイルを gemspec の `files` に
足し忘れていた。**同梱物は毎回ビルドして確かめる**しかない。

### 測って「直さない」と決めたもの

`rmake --version` と `rubycc-pkgconf --version` は未対応のままにした。
mkmf の `pkg_config` が実際に渡すのは
`--exists` / `--modversion` / `--cflags*` / `--libs*` **だけ**で、
**`--version` は呼ばない**(実測)。

さらに **pkg-config の `--version` は本物ならツール自身のバージョンを返す**もので、
スクリプトがその形式を解釈しうる。**似て非なる値を返す方が危険**なので、
「5 つのコマンドで揃っていないから」という理由だけで足さない。

### 残っているのはタグと push だけ

`v1.0.0` を打てば Tier C が走り、タグと `Rubycc::VERSION` の一致と再現ビルドを検証する。
**`gem push` は方針として自動化しない**(アカウント保有者の操作)。

---

### master 側のマージ直前のテスト規模

differential-discipline-2 完了時点: **2,839 runs / 8,438 assertions / 0 failures / 0 errors / 44 skips**
(master の Step 208(aarch64 gem 実走)を取り込んだ後の実測値)
(以前) differential-discipline-1 完了時点: **2,834 runs / 8,397 assertions / 0 failures / 0 errors / 44 skips**
(Step 207 から +1 run = 固有名リテラルの検査。**master 側の Step 208 は別系統**)
(以前) Step 207 完了時点: **2,833 runs / 8,395 assertions / 0 failures / 0 errors / 44 skips**
(Step 206 から +1 run = PIE リンクの検査。skips は増えていない)
(以前) Step 206 完了時点: **2,832 runs / 8,392 assertions / 0 failures / 0 errors / 44 skips**
(Step 205 と同数 = ハーネスのフラグを揃えただけ。
**x86-64 では値が 1 つも変わらない**ことを確認済み)
(以前) Step 208 完了時点(aarch64 gem 実走、master 側): **2,834 runs / 8,420 assertions / 0 failures / 0 errors / 44 skips**
(ホスト側 `bundle exec rake test` の実測値。aarch64 の gem 実走記録と
resolver 回帰テストを含む)
(以前) Step 205 完了時点: **2,832 runs / 8,392 assertions / 0 failures / 0 errors / 44 skips**
(master の distroless 作業とこのブランチが**別々にテストを足していた**ので、
どちらか片方の数字はマージ後の値にならない。**マージしてから測り直した**。
2,829 + 2,819 − 2,816(共通の親)= 2,832 で辻褄が合う)
(以前) Step 202 完了時点(distroless、master 側): **2,829 runs / 8,386 assertions / 0 failures / 0 errors / 44 skips**
(以前) Step 204 完了時点(このブランチ側): **2,819 runs / 8,375 assertions / 0 failures / 0 errors / 44 skips**
(以前) Step 201 完了時点: **2,816 runs / 8,369 assertions / 0 failures / 0 errors / 44 skips**
(Step 200 から +1 run = aarch64 の `float.h` 検査。
**クロス gcc との差分で実際に通ることを確認済み**)
(以前) Step 200 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 199 と同数 = 測定と記録のみ。コードは変更していない)
(以前) Step 199 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 197 と同数。**`-L` の重複はこのホストではフィルタに隠れて見えない**ので、
ローカルでは `PKG_CONFIG_ALLOW_SYSTEM_LIBS=1` を付けて再現・確認した)
(以前) Step 197 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 196 と同数。`host_cpu` はこのホストで `"x86_64"` なので既定と一致し、
**同じソースから出るオブジェクトが 1,184 バイト完全一致**することを確かめた)
(以前) Step 196 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 195 と同数 = pkgconf の除外条件を実在条件にし、GAPS を消し込んだだけ。
**この修正が効くのは multiarch のディレクトリが無いホスト**なので、
このホストでは出力が 1 バイトも変わらない — それを確かめたことが結果である)
(以前) Step 195 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 194 と同数 = 切り分けと記録のみ。コードは変更していない)
(以前) Step 194 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 193 と同数 = テスト側の決め打ちを直しただけ)
(以前) Step 193 完了時点: **2,815 runs / 8,366 assertions / 0 failures / 0 errors / 44 skips**
(Step 192 から +11 runs = libc 軸の前処理器テスト 8 件と、
musl 分岐の値・glibc 側不変・ctype の 3 件)
(以前) Step 192 完了時点: **2,804 runs / 8,336 assertions / 0 failures / 0 errors / 44 skips**
(Step 188 から +1 run = 両方の va_list 綴りの検査。assertions の伸びは
musl の verification が 3 本入ったぶん DB のスキーマ検査が増えた分)
(以前) Step 188 完了時点: **2,803 runs / 8,308 assertions / 0 failures / 0 errors / 44 skips**
(Step 187 から +3 runs = センサスが決定的であることを守る検査 3 件)
(以前) Step 187 完了時点: **2,800 runs / 8,303 assertions / 0 failures / 0 errors / 44 skips**
(Step 186 からの差は引き算形のテスト 9 件と examples 1 件。
**aarch64 でも PENDING 無し**)
(以前) Step 184 完了時点: **2,789 runs / 8,254 assertions / 0 failures / 0 errors / 44 skips**
(Step 183 から +13 runs = cast 形の gcc 差分と回帰防止、examples 1 件。
**aarch64 でも PENDING 無し** — 畳み込みはフロントエンド完結でバックエンド非依存)
(以前) Step 183 完了時点: **2,776 runs / 8,216 assertions / 0 failures / 0 errors / 44 skips**
(Step 182 から +13 assertions = 初の musl 記録を固定する検査 1 件と、
DB のスキーマ検査が verification 1 本ぶん増えた分)
(以前) Step 182 完了時点: **2,776 runs / 8,203 assertions / 0 failures / 0 errors / 44 skips**
(Step 181 から +12 runs = パーサ 5 件・診断 2 件・gcc 差分の新ファイル 4 件・
examples 1 件。**aarch64 でも PENDING 無しで通る**)
(以前) Step 181 完了時点: **2,764 runs / 8,177 assertions / 0 failures / 0 errors / 44 skips**
(Step 180 から +1 run = バンドル自身の区切りの検証)
(以前) Step 180 完了時点: **2,763 runs / 8,172 assertions / 0 failures / 0 errors / 44 skips**
(Step 179 から +6 runs = パラメタ化そのものの検証 6 件。
**skips は不変** — glibc ホストでは 1 件も新たに飛ばない)
(以前) Step 179 完了時点: **2,757 runs / 8,157 assertions / 0 failures / 0 errors / 44 skips**
(Step 178 から +2 runs = `ruby.h` の `HAVE_STDCKDINT_H` 回帰テストと
freestanding の `stdckdint` ケース)
(以前) Step 178 完了時点: **2,755 runs / 8,152 assertions / 0 failures / 0 errors / 44 skips**
(Step 177 から +3 runs / **−2 skips** = aarch64 の逆アセンブル検証と qemu 差分実行、
および PENDING から外れた examples 2 件)
(以前) Step 177 完了時点: **2,752 runs / 8,148 assertions / 0 failures / 0 errors / 46 skips**
(Step 176 から +9 runs / +1 skip = 組み込み関数のテストと、
aarch64 では乗算形が通らないぶんの pending サンプル 1 件)
(以前) Step 176 完了時点: **2,743 runs / 8,125 assertions / 0 failures / 0 errors / 45 skips**
(Step 173 から +4 assertions = コーパスの 4 件が `latest` ではなく固定バージョンに
なったぶん `test_corpus_census.rb` の検査が増えた。Steps 174・175 は CI 設定と
ドキュメントだけなのでローカルのテスト規模は動かない)
(以前) Step 173 完了時点: **2,743 runs / 8,121 assertions / 0 failures / 0 errors / 45 skips**
(Step 172 から +11 runs = rmake の `MAKE` マクロのテスト
5 件(Makefile/Parser レベル)+ 6 件(CLI レベル))
(以前) Step 172 完了時点: **2,732 runs / 8,104 assertions / 0 failures / 0 errors / 45 skips**
(runs は Step 171 と同数 = DB のスキーマ検査が psych の 1 件分増え、
バージョン固定の検査を 1 件足しただけ)
(以前) Step 171 完了時点: **2,732 runs / 8,084 assertions / 0 failures / 0 errors / 45 skips**
(runs は Step 170 と同数 = DB のスキーマ検査が zlib の 1 件分増え、
バージョン固定の検査を 1 件足しただけ)
(以前) Step 170 完了時点: **2,732 runs / 8,064 assertions / 0 failures / 45 skips**
(runs は Step 169 と同数 = DB のスキーマ検査が digest の 1 件分増え、
バージョン固定の検査を 1 件足しただけ)
(以前) Step 169 完了時点: **2,732 runs / 8,044 assertions / 0 failures / 45 skips**
(runs は Step 168 と同数 = DB のスキーマ検査が io-console の 1 件分増え、
バージョン固定の検査を io-console と、Step 166 で入れ忘れていた erb の 2 件足しただけ)
(以前) Step 168 完了時点: **2,732 runs / 8,022 assertions / 0 failures / 45 skips**
(Step 167 から +15 runs = 新規テストファイル 13 件、`ruby/ractor.h` の smoke 1 件、
examples/m5 の追加で aarch64 側 1 件。**skips −2 は c-testsuite 00078 が
x86_64・aarch64 の両方で実際に通るようになったため**)
(以前) Step 167 完了時点: **2,717 runs / 7,979 assertions / 0 failures / 47 skips**
(Step 166 と同数 = 追加した 2 宣言は既存 Spec の snippet 内の呼び出しとして
検査されるので、テストメソッドも assertion も増えない)
(以前) Step 166 完了時点: **2,717 runs / 7,979 assertions / 0 failures / 47 skips**
(runs は Step 165 と同数 = DB のスキーマ検査が erb の 1 件分増えただけ)
(以前) Step 165 完了時点: **2,717 runs / 7,961 assertions / 0 failures / 47 skips**
(runs は Step 164 と同数 = DB のスキーマ検査が io-wait の 1 件分増え、
バージョン固定の検査を 1 件足しただけ)
(以前) Step 164 完了時点: **2,717 runs / 7,941 assertions / 0 failures / 47 skips**
(runs は Step 163 と同数 = DB のスキーマ検査が io-nonblock の 1 件分増え、
バージョン固定の検査を io-nonblock と etc の 2 件足しただけで、
新しいテストメソッドは足していない)
(以前) Step 163 完了時点: **2,717 runs / 7,919 assertions / 0 failures / 47 skips**
(Step 162 から +5 = PT_LOAD の不変条件 4 件(x86_64・aarch64 各 2)と、
`verified_gems.json` のスキーマを入れ子にしたときに足した
`matching_verifications` の 1 件)
(以前) Step 162 完了時点: **2,712 runs / 7,766 assertions / 0 failures / 47 skips**
(runs は Step 161 と同数 = DB のスキーマ検査が etc の 1 件分増えたのみで、
新しいテストメソッドは足していない)
(以前) Step 161 完了時点: **2,712 runs / 7,752 assertions / 0 failures / 47 skips**
(Step 160 から +23 = `__atomic_*` の gcc 差分実行・逆アセンブル検査・診断 21 件、
決定的ビルド 1 件、`ruby/atomic.h` 単体コンパイル 1 件)
(以前) Step 160 完了時点: **2,689 runs / 7,653 assertions / 0 failures / 47 skips**
(Step 159 から +1 = UNISTD の aarch64 ケース。`_CS_*` / `_PC_*` と 3 宣言は
既存 Spec の検査項目として増えているが runs には現れない)
(以前) Step 159 完了時点: **2,688 runs / 7,650 assertions / 0 failures / 47 skips**
(Step 158 と同数 = 文面の変更のみ)
(以前) Step 158 完了時点: **2,688 runs / 7,650 assertions / 0 failures / 47 skips**
(Step 157 から +9 = POSIX バックスラッシュの 3 規則・行継続・mkmf 実パターン再現)
(以前) Step 157 完了時点: **2,679 runs / 7,639 assertions / 0 failures / 47 skips**
(Step 156 と同数の runs = DB のスキーマ検査が 2 gem 分増えたのみ)
(以前) Step 156 完了時点: **2,679 runs / 7,607 assertions / 0 failures / 47 skips**
(Step 155 から +14 = メンバの形・スロット位置・WEAK/GOT/PLT・命令列の復号・
`dlclose` 実走・順序・不変性 2 件、実行ファイル 2 件、aarch64 3 件)
(以前) Step 155 完了時点: **2,665 runs / 7,509 assertions / 0 failures / 47 skips**
(Step 154 から +50 = パーサ・拒否経路・ELF ライタ・実行オラクル・dlopen 実走・
aarch64・診断・決定的ビルド・`__has_attribute`)
(以前) Step 154 完了時点: **2,615 runs / 7,318 assertions / 0 failures / 47 skips**
(Step 153 から +16 = 形状・タグ・順序・優先度・拒否経路・dlopen 実走・`dlclose` 実走・
実行ファイル 3 件・aarch64 2 件)
(以前) Step 153 完了時点: **2,599 runs / 7,241 assertions / 0 failures / 47 skips**
(Step 152 と同数の runs = DB のスキーマ検査が 1 gem 分増えたのみ)
(以前) Step 152 完了時点: **2,599 runs / 7,225 assertions / 0 failures / 47 skips**
(Step 151 から +14 = `__dso_handle` の合成・非合成・入力優先・形状・dlopen 実行・
fork 実走、aarch64 3 件、実行ファイル 3 件)
(以前) Step 151 完了時点: **2,585 runs / 7,171 assertions / 0 failures / 47 skips**
(Step 150 と同数の runs = 既存テストへの assertion 追加のみ)
(以前) Step 150 完了時点: **2,585 runs / 7,155 assertions / 0 failures / 47 skips**
(Step 149 から +11 = 実行オラクル・診断・ブロックスコープ 7 件と `Type.composite` の単体 4 件)
(以前) Step 149 完了時点: **2,574 runs / 7,128 assertions / 0 failures / 47 skips**
(Step 148 と同数 = 既存 Spec の検査項目を増やしたためテストメソッドは増えない)
(以前) Step 148 完了時点: **2,574 runs / 7,128 assertions / 0 failures / 47 skips**
(Step 147 から +6 = パーサ単体 4・診断 1・実行オラクル 1)
(以前) Step 147 完了時点: **2,568 runs / 7,118 assertions / 0 failures / 47 skips**
(Step 146 から +4 = sigset_t の include 順 2 通り × x86_64・aarch64)
(以前) Step 146 完了時点: **2,564 runs / 7,106 assertions / 0 failures / 47 skips**
(Step 145 と同数 = レシピ追加と文書のみ。ギャップの修正は次ステップ以降)
(以前) Step 145 完了時点: **2,564 runs / 7,106 assertions / 0 failures / 47 skips**
(Step 144 と同数 = スキルとドキュメントのみ)
(以前) Step 144 完了時点: **2,564 runs / 7,106 assertions / 0 failures / 47 skips**
(Step 143 と同数 = 追加したのは開発用ツールで、`rake test` の対象外)
(以前) Step 143 完了時点: **2,564 runs / 7,106 assertions / 0 failures / 47 skips**
(Step 142 と同数 = 追加したのは開発用ツールで、`rake test` の対象外)
(以前) Step 142 完了時点: **2,564 runs / 7,106 assertions / 0 failures / 47 skips**
(Step 140 から +8 = TIMERFD / INOTIFY / STATFS / SYSCALL の ABI ハーネスを両アーキで)
(以前) Step 140 完了時点: **2,556 runs / 7,082 assertions / 0 failures / 47 skips**
(Step 138 から +6 = WAIT / EPOLL / LANGINFO の ABI ハーネスを x86_64・aarch64 の両方で。
Step 139 はコーパス定義とセンサススナップショットの更新のみでテスト増減なし)
(以前) Step 138 完了時点: **2,550 runs / 6,998 assertions / 0 failures / 47 skips**
(Step 136 から +3 = pkgconf の multiarch フィルタのテスト。
CI 上では 52 skips = pkg-config があるため −1、rmake golden の `make -n` が
フィクスチャの絶対パス依存で走らないため +6)
(以前) Step 136 完了時点: **2,547 runs / 6,929 assertions / 0 failures / 47 skips**
(Step 133 から +16 = pkgconf のシステムパスフィルタのユニットテスト。
CI 上では 52 skips になる = 上記の内訳を参照)
(以前) Step 133 完了時点: **2,531 runs / 6,883 assertions / 0 failures / 47 skips**
(**Ruby 3.3.12 と 3.4.5 の両方で確認**。Step 126 から +8 = 浮動小数点リテラルの
指数消失に対する字句解析の回帰テスト。Step 127〜132 は文書とパッケージングのため増減なし)
(以前) Step 126 完了時点: **2,523 runs / 6,866 assertions / 0 failures / 47 skips**
(Step 124 から +10 = N4 決定的ビルドの専用テスト。Step 125 は census 再実行のみ)
(以前) Step 124 完了時点: **2,513 runs / 6,853 assertions / 0 failures / 47 skips**
(Step 123 から +8 = TERMIOS/IOCTL/SYS_PARAM/SYS_FCNTL の 4 Spec を x86_64・aarch64
の両クラスに追加)
(以前) Step 123 完了時点: **2,505 runs / 6,829 assertions / 0 failures / 47 skips**
(Step 122 から +14 = POSIX ヘッダ 7 本の ABI ケースを x86_64・aarch64 の両クラスに追加)
(以前) Step 122 完了時点: **2,491 runs / 6,787 assertions / 0 failures / 47 skips**
(Step 120 から +4 = setjmp / locale の ABI ケースを x86_64・aarch64 の両クラスに追加。
Step 121 は census スナップショットの更新のみでテスト増なし)
(以前) Step 120 完了時点: **2,487 runs / 6,775 assertions / 0 failures / 47 skips**
(Step 118 から +9 = rmake の展開予算 5・Scanner の桁計算 2・PartialLinker 2。
Step 119 はコーパス定義の追加のみでテスト増なし)
(以前) Step 118 完了時点: **2,478 runs / 6,691 assertions / 0 failures / 47 skips**
(Step 116 から +6 = 波括弧なし制御構造の入れ子拒否 3 + 上限内の退行防止 1 + ar の
パストラバーサル拒否 2。Step 117 はコーパス定義の追加のみでテスト増なし)
(以前) Step 116 完了時点: **2,472 runs / 6,594 assertions / 0 failures / 47 skips**
(Step 115 と同数 = _SC_* は header-abi の既存 UNISTD Spec への追記のため
テストメソッドは増えない。定数値 11 個の照合が既存ケース内で増える)
(以前) Step 115 完了時点: **2,472 runs / 6,594 assertions / 0 failures / 47 skips**
(Step 114 から +3 = 静的初期化子の未宣言識別子診断 2 件 + ローカルアドレスの退行防止 1 件。
pread/pwrite は header-abi の既存 UNISTD snippet への追記のためテスト数は増えない)
(以前) Step 114 完了時点: **2,469 runs / 6,585 assertions / 0 failures / 47 skips**
(Step 113 から +5 = メンバ sizeof のパーサ単体 1・診断 3・実行オラクル 1)
(以前) Step 113 完了時点: **2,464 runs / 6,578 assertions / 0 failures / 47 skips**
(Step 110 から +2 = rmake CLI の jobs 既定のユニットテスト。Step 111・112 はテスト増なし)
(以前) Step 110 完了時点: **2,462 runs / 6,576 assertions / 0 failures / 47 skips**
(Step 109 と同数 = 純内部最適化のためテスト増なし。挙動不変は -E 出力 A/B で担保)
(以前) Step 109 完了時点: **2,462 runs / 6,576 assertions / 0 failures / 47 skips**
(Step 108 から +5 = multiple-include optimization の意味論テスト)
(以前) Step 108 完了時点: **2,457 runs / 6,571 assertions / 0 failures / 47 skips**
(Step 107 から +1 = 再 #include のマクロ文脈再評価のリグレッションテスト)
(以前) Step 107 完了時点: **2,456 runs / 6,570 assertions / 0 failures / 47 skips**
(Step 104 の 2,435 から +21 = Step 106 のスキャナ単体回帰 16 件 + Step 107 の
診断 4 件・実行オラクル 1 件。Step 105 はベンチ基盤のみでテスト増なし)
(以前) Step 104 完了時点: **2,435 runs / 6,533 assertions / 0 failures / 47 skips**
(Step 103 と同数 = strlcpy は header-abi の既存 STRING snippet への追記のため新規テストメソッドは増えない)
(以前) Step 103 完了時点: **2,435 runs / 6,533 assertions / 0 failures / 47 skips**
(Step 102 の 2,434 から +1 = 手書き offsetof イディオムの実行オラクル)
(以前) Step 102 完了時点: **2,434 runs / 6,532 assertions / 0 failures / 47 skips**
(Step 101 の 2,428 から +6 = `#line` のプリプロセッサ単体テスト5件 + 実行オラクル1件)
(以前) Step 101 完了時点: **2,428 runs / 6,521 assertions / 0 failures / 47 skips**
(Step 100 の 2,427 から +1 = 静的初期化子の関数ポインタキャストの実行オラクル)
(以前) Step 100 完了時点: **2,427 runs / 6,519 assertions / 0 failures / 47 skips**
(Step 99 の 2,425 から +2 = 配列境界の sizeof(式)畳み込みの実行オラクルとパーサ単体テスト)
(`rake test`)。内訳: 字句・パーサ・型・ELF(ライタ + リーダ + 汎用ライタ)・
ar・リンク(ld -r 併合 + .so + 外部 import + ライブラリ解決 + 実行ファイル)・
ドライバ・PIC・DoS 耐性・診断・CLI・プリプロセッサのユニットテスト + 実行テスト
(gcc 差分比較・クロスリンク ABI 差分・gcc -E トークン列差分・Fiddle dlopen 実
呼び出し・生成実行ファイルの実走・一気通貫ビルド・C 拡張の require 実行込み)+
c-testsuite 220 ケース + ruby.h スモークテスト。
