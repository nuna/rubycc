# rubycc 開発ステップ記録(ステップ 1〜13)

各ステップで「何を作ったか」に加えて、**なぜそう設計したか・何を捨てたか(トレードオフ)**を
記録する。実装担当(人間・AI を問わず)は、関連する範囲のステップをここで読んでから
コードに入ること。今後の計画・開発規約は [ROADMAP.md](ROADMAP.md)、要件・アーキテクチャは
[DESIGN.md](DESIGN.md) を参照。

各ステップは 1 コミットに対応する(コミットメッセージ末尾の "(Step N)" が対応)。
コミット本文に変更内容の詳細があるので、`git log` と併読すること。

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

## 現在のテスト規模

Step 40 完了時点: **1,510 runs / 4,396 assertions / 0 failures / 17 skips**
(`rake test`)。内訳: 字句・パーサ・型・ELF(ライタ + リーダ + 汎用ライタ)・
ar・リンク(ld -r 併合 + .so + 外部 import + ライブラリ解決 + 実行ファイル)・
ドライバ・PIC・DoS 耐性・診断・CLI・プリプロセッサのユニットテスト + 実行テスト
(gcc 差分比較・クロスリンク ABI 差分・gcc -E トークン列差分・Fiddle dlopen 実
呼び出し・生成実行ファイルの実走・一気通貫ビルド・C 拡張の require 実行込み)+
c-testsuite 220 ケース + ruby.h スモークテスト。
