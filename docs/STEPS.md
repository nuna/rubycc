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

---

## 現在のテスト規模

Step 114 完了時点: **2,469 runs / 6,585 assertions / 0 failures / 47 skips**
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
