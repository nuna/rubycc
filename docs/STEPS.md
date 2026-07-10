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

## 現在のテスト規模

Step 23 完了時点: **770 runs / 2,443 assertions / 0 failures**(`rake test`)。
内訳: 字句・パーサ・型・ELF・診断・CLI のユニットテスト + 実行テスト(gcc 差分比較込み)。
