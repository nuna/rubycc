# rubycc 中間表現(IR)仕様

コンパイラの中間表現(`lib/rubycc/ir/ir.rb`)の仕様書。フロントエンド
(`IR::Generator`)が AST から IR を構築し、バックエンド
(`Backend::X86_64` / `Backend::AArch64`)が IR から機械語を生成する。両者はこの仕様だけを
接点とする。

**正本は `ir.rb` のコメント**(命令一覧)と `backend/x86_64.rb` 冒頭の
値表現規約、および `backend/aarch64.rb` のターゲット固有規約。本書はそれらを
1 か所にまとめた読み物であり、命令の追加・変更時は
`ir.rb` のコメントと本書の両方を更新すること(ROADMAP §2)。

---

## 1. 設計方針

- **三番地コード + 無制限の仮想レジスタ(vreg)**。各命令は
  `dst <- a op b` の形を基本とし、vreg は使い捨てで無制限に採番する。
  レジスタ割り付けは行わない(spill-everything: バックエンドが vreg を
  1 つずつスタックスロットに割り当てる)前提の設計。
- **SSA ではない**。vreg は「スロット」であり、同じ vreg に複数回書いてよい。
  制御フローの合流は「両経路が同じ vreg に :copy してから合流ラベルに跳ぶ」
  ことで表現する(φ 関数は無い)。__builtin_va_arg の降ろしが代表例。
- **命令追加は最後の手段**。`!`・`&&`・`||`・ループ・複合代入・メンバアクセス・
  va_arg はすべて既存命令への脱糖で実現している。新命令はバックエンドしか
  知り得ない情報(フレーム内配置・ABI 詳細)を要するときだけ足す
  (:va_start がその例)。
- **ターゲット共通の契約を持つが、完全な機種非依存 IR ではない**。命令の粒度
  (32/64 bit 演算の区別、符号別の除算・シフト・比較)は x86-64 System V と
  AAPCS64 の両方でコード選択がほぼ 1:1 になるように切ってある。一方、
  ABI 分類、可変長引数、フレーム配置、再配置形式、未実装命令の扱いは
  ターゲットごとのバックエンド契約に依存する。

各設計要素がどこまで一般概念・公開仕様由来で、どこが本プロジェクト固有かは
§8 に明記する。

## 2. プログラム構造

```
IR::Program
├── functions     : [IR::Function]   関数定義(ソース順)
├── strings       : [String]         読み取り専用文字列プール(:string_addr の id で索引)
├── globals       : [IR::Global]     ファイルスコープ変数(ソース順)
├── array_entries : [IR::ArrayEntry] 初期化子/終了子配列のエントリ(既定 [])
└── visibility    : {String => Symbol} ELF シンボル可視性(既定 :default)
```

`visibility` は `visibility` 属性が付いた外部関数・外部オブジェクトの
シンボル名から ELF 可視性(`:default` / `:internal` / `:hidden` /
`:protected`)への対応表である。`static` の内部リンケージは `linkage` が
担い、可視性表の対象にはしない。

### IR::Function

| フィールド | 意味 |
|---|---|
| `name` | シンボル名(String) |
| `insts` | 命令のフラットな配列 |
| `vreg_count` | 使用 vreg 数(バックエンドのフレームサイズ計算用) |
| `param_count` | **ABI スロット数**(パラメータ数ではない)。スカラパラメータは 1 スロット、struct パラメータは規約が切り分ける**ピース数**(System V は eightbyte ごと、AAPCS64 の HFA はメンバごと、参照渡しはポインタ 1 つ)、レジスタ返しできない戻り値の関数は隠れ結果ポインタが先頭に 1 スロット加わる。**スロットは vreg 0..param_count-1 を占める**規約で、バックエンドが着信引数レジスタ / スタック引数をこのスロットへ写す。struct パラメータのスロットからの再組み立て(stack object への :store)はジェネレータがプロローグ IR で行う |
| `param_kinds` | 長さ param_count の配列。各 ABI スロットの**着信位置**(`:gp` 整数レジスタ、`:sse4`/`:sse8` ベクタレジスタ、`:mem` スタック)を宣言順に持つ。配置はジェネレータが呼び出し側と同じシミュレーションで確定済みで、バックエンドはこの指定に従うだけ(超過時は契約違反として raise)。**分類はターゲット依存**(`IR::CallConvention`): 整数引数レジスタ数は System V AMD64 が 6、AAPCS64 が 8 であり、さらに**集約の切り分け方自体が異なる** — `struct { float a, b; }` は System V では 1 個の `:sse8` スロット(xmm0)、AAPCS64 では HFA として 2 個の `:sse4` スロット(s0/s1)になる。一部の規約にしかない機構を名指すタグが 1 種ある — `:indirect_result` は専用レジスタ(AAPCS64 の x8)で渡す隠れ結果ポインタ。参照渡しされる集約に専用タグは不要で、ジェネレータが呼び出し側のコピーへの通常の `:gp` ポインタに落とす。**16 バイト整列集約(`__int128` や `_Alignas(16)`)には整列 pad スロットが 2 種入りうる** — `:pad` は整数レジスタ 1 本(AAPCS64 の偶数レジスタペア規則で 1 本を空ける)、`:pad_stack` はスタック 1 eightbyte(両規約でスタック溢れ時に 16 バイト境界へ詰める)。いずれも値を運ばず、バックエンドは該当カウンタを進めるだけ(スロットは書かれない)。ジェネレータが placer の報告(`pad_gp`/`pad_stack`)から集約ピースの直前に前置する |
| `stack_objects` | オブジェクト id で索引する配列。各要素は集約オブジェクト(配列・struct)のバイトサイズ。バックエンドは vreg スロットの下に配置し :object_addr を解決する |
| `linkage` | `:external`(通常)/ `:internal`(`static`。STB_LOCAL で発行) |
| `variadic` | `...` 付き定義なら true。バックエンドがレジスタ退避領域つきプロローグを出す |

### IR::Global / GlobalInit / GlobalReloc

- `Global(name, size, align, init, linkage)` — `init` が nil なら .bss
  (ゼロ初期化)、`GlobalInit` なら .data。
- `GlobalInit(bytes, relocations)` — `size` バイトのリトルエンディアン像。
  ポインタスロットは 8 バイトのゼロのまま置き、`GlobalReloc` がリンク時に
  埋める。「全ゼロだが明示初期化」は nil init(.bss)と区別される。
- `GlobalReloc(offset, kind, symbol, string_id, addend)` — グローバル像内のバイト
  オフセット `offset` にある 8 バイトスロットへの**絶対アドレス再配置**。
  `addend`(既定 0)は基点アドレスに加える定数バイト変位で、`&arr[i]`・`arr + n`・
  `&rec.member` のような計算アドレス定数(ISO C 6.6)で非ゼロになる。具体的な
  ELF 再配置型はターゲットの機種記述が選び、x86-64 は `R_X86_64_64`、
  AArch64 は `R_AARCH64_ABS64` として同じ addend を保持する。
  - `kind: :symbol` — 他のファイルスコープオブジェクトまたは関数のアドレス
    (`&global`・グローバル配列名の減衰・関数名 `f`/`&f`、および `&arr[i]` 等の
    計算アドレス)。絶対 64 bit 再配置(addend = `addend`)で解決。
  - `kind: :string` — 文字列リテラル。`string_id` が文字列プールを指し、
    コンパイラが .rodata オフセット + `addend` へ解決。

### IR::ArrayEntry

- `ArrayEntry(kind, priority, symbol)` — `__attribute__((constructor))` /
  `((destructor))` が付いた**この翻訳単位で定義された**関数 1 つの登録。
  `kind: :init` は .init_array(ローダが main 前 / dlopen で呼ぶ)、
  `kind: :fini` は .fini_array(exit / dlclose で呼ぶ)。
- `priority` は実行順の番号(整数)。既定値 65535
  (`ObjFile::ELFWriter::DEFAULT_ARRAY_PRIORITY`)は番号なしを意味し、
  番号付きより後に走る。**この既定値は gcc の実測値**で、
  `constructor(65535)` と番号なしの `constructor` は gcc でも同一の
  無印セクションになる。
- コンパイラは 1 エントリを 8 バイトスロット + そのシンボルへの
  絶対 64 bit 再配置(x86_64: R_X86_64_64 / aarch64: R_AARCH64_ABS64)に落とし、
  優先度ごとに別セクション(`.init_array.NNNNN`、5 桁ゼロ詰め)へ置く。
  セクション**名**が実行順を決めるため、この綴りはリンカ側の
  `SharedLinker#array_priority` と一致していなければならない。
- 宣言だけで定義がない名前はエントリにならない(スロットは関数を
  **定義する**オブジェクトのもの。gcc も同様に何も出さない)。

## 3. 値表現規約(スロット規約)

バックエンドとの最重要契約。`backend/x86_64.rb` と `backend/aarch64.rb` の
冒頭に原文がある。

- vreg のスロットは **8 バイト固定**で、常に 64 bit 単位で読み書きする
  (ポインタ値が必ず無傷で往復する)。
- **8 バイト未満の整数値**はスロットの下位 32 bit に、**型の符号に従って
  32 bit 以上へ拡張済み**の形で保持する(signed は符号拡張、unsigned は
  ゼロ拡張)。そのような値のビット 32..63 は不定。
- **8 バイト値**(long / unsigned long / ポインタ)はスロット全体を使う。
- **幅の変化はちょうど 2 か所でだけ起きる**:
  1. メモリ境界 — :load は符号拡張、:uload はゼロ拡張、:store は `size`
     バイトへの切り捨て。
  2. 明示変換命令 — :sext / :zext(`size` は**変換元**の幅)。
- 同幅で符号だけ変わる再解釈(int ↔ unsigned int)はビットパターンが同じ
  なのでコード不要。
- **浮動小数点値も同じスロット規律に従う**: `float` はスロット下位 4 バイトに
  IEEE754 単精度ビットパターンで(ビット 32..63 は狭い整数と同様に不定)、
  `double` は 8 バイトスロット全体に倍精度で保持する。浮動小数点命令は
  ターゲットのスクラッチレジスタを使ってスロットを直接読み書きするので、
  :const が整数即値として実体化した浮動小数点ビットパターンをそのまま拾える
  (x86-64 は xmm0/xmm1、AArch64 は v0/v1 を使用する)。
- **集約オブジェクト(配列・struct)の「値」はそのアドレス**。式の中では
  「アドレスを持つ vreg + その型」で流通し、実体は stack_objects または
  グローバルシンボルにある。

## 4. Instruction のフィールド

```ruby
Instruction(op, dst:, a:, b:, size:)
```

`dst` / `a` / `b` は原則 vreg 番号(Integer)。命令ごとの例外(ラベル id・
シンボル名 String・vreg 配列)は §5 に明記。未使用フィールドは nil。

`size` の意味は命令グループごとに異なる:

| 命令グループ | `size` の意味 |
|---|---|
| :load / :uload / :store | メモリアクセス幅(1/2/4/8) |
| 二項演算(算術・シフト・比較) | 8 = 64 bit 演算(long/unsigned long/ポインタ、ポインタオフセットのスケーリング)。nil または 4 = 既定の 32 bit 演算(4 バイト C 型の自然なラップアラウンドに一致) |
| :sext / :zext | **変換元**の幅(1/2/4) |
| :const | 8 = 64 bit 即値ロード(long/ポインタ定数)。それ以外は 32 bit 即値 |
| 浮動小数点演算(:fadd 系・:f 比較) | 浮動小数点オペランド幅(4 = float / 8 = double) |
| :itof / :ftoi / :ftof | :itof は変換**先**の浮動小数点幅、:ftoi / :ftof は変換**元**の幅(§5) |
| :call / :call_indirect | nil、または **[fixed, ret] ペア**(どちらかが非 nil のとき)。fixed = 可変長 callee の固定パラメータ数(非可変長は nil)で、x86-64 のバックエンドは call 直前に al = 使用 xmm 数を出し、AArch64 はこの値を使わない。ret = 戻り値が float/double なら :sse4/:sse8、レジスタ返しの struct なら **[buffer_vreg, pieces]**(pieces は `IR::AbiPiece` の配列で各ピースの offset / size / kind を持ち、戻りレジスタから散布)、それ以外は nil(ターゲットの整数戻りレジスタ) |
| :ret | nil = 整数/ポインタ戻り値(x86-64 は rax、AArch64 は x0)。4/8 = 浮動小数点戻り値(x86-64 は xmm0、AArch64 は v0)。**AbiPiece 配列** = レジスタ返しの struct(a の指すバッファから各ピースを自身の offset・幅で戻りレジスタへ収集) |
| :memcpy | コピーするバイト数(struct 全体代入) |

## 5. 命令一覧

### 定数・転送

| 命令 | 形 | 意味 |
|---|---|---|
| :const | dst ← a | a は即値 Integer。size 8 で movabs 相当の 64 bit ロード |
| :copy | dst ← a | スロット間転送(64 bit) |

### 算術・ビット演算

| 命令 | 形 | 意味 |
|---|---|---|
| :add / :sub / :mul | dst ← a op b | |
| :scaled_add | dst ← a + b × size | 添字が作るアドレス。a = ベースポインタ、b = 添字、`size` = 要素幅(1/2/4/8 のみ)。計算は常に 64 bit(結果がポインタのため)で、`size` はオペランド幅ではなくスケールを表す(:load/:store で `size` がアクセス幅を表すのと同じ読み)。**ジェネレータは出さない** — `IR::Simplify` が「定数要素幅との :mul」+「ベースへの :add」を融合して生成する。x86-64 は SIB の scale 付き `lea`、AArch64 はシフト付きレジスタの `add` に 1 命令で下りる |
| :mulhi | dst ← hi64(a × b) | 64 bit unsigned 乗算の上位 64 bit。`size` は常に 8。`__int128` の乗算を合成するために使い、x86-64 は `mul`、AArch64 は `umulh` へ下ろす |
| :div / :mod | dst ← a op b | 符号付き除算・剰余 |
| :udiv / :umod | dst ← a op b | 符号無し除算・剰余(バックエンドは edx をゼロにして `div`) |
| :and / :or / :xor | dst ← a op b | ビット演算 |
| :neg | dst ← -a | |

### シフト

| 命令 | 形 | 意味 |
|---|---|---|
| :shl | dst ← a << b | 論理左シフト。b の下位バイトがカウント(cl 経由) |
| :sar | dst ← a >> b | 算術右シフト(符号付き左オペランドの `>>`。符号ビット複製) |
| :shr | dst ← a >> b | 論理右シフト(符号無し左オペランドの `>>`)。:div/:udiv と同じ「機械命令が符号で分かれる」ための分割 |

### 浮動小数点演算

`size` は浮動小数点オペランド幅(4 = float / 8 = double)で ss/sd 形を選ぶ。
バックエンドは x86-64 では xmm0/xmm1、AArch64 では v0/v1 をスクラッチに使い、スロットを直接読み書きする。

| 命令 | 形 | 意味 |
|---|---|---|
| :fadd / :fsub / :fmul / :fdiv | dst ← a op b | 浮動小数点四則(addss/subss/mulss/divss と sd 版)。浮動小数点の単項マイナスは専用命令を置かず、符号ビットを整数 :xor(float 0x80000000 / double 0x8000000000000000、size 8)で反転して脱糖 |
| :feq / :fne | dst ← (a op b) ? 1 : 0 | NaN 対応の等値比較。ucomis(a,b) の後、:feq は sete かつ setnp(NaN で 0)、:fne は setne または setp(NaN で 1) |
| :flt / :fle / :fgt / :fge | dst ← (a op b) ? 1 : 0 | NaN 対応の大小比較。いずれも NaN で 0。:fgt/:fge は ucomis(a,b)+seta/setae、:flt/:fle はオペランドを反転した ucomis(b,a)+seta/setae で、NaN 時に必ず carry が立つ「above」判定に寄せる |

### 整数 ↔ 浮動小数点変換

| 命令 | 形 | 意味 |
|---|---|---|
| :itof | dst ← (float)a | 整数 → 浮動小数点(cvtsi2ss/cvtsi2sd)。size = 変換先の浮動小数点幅(4/8)、b = 整数**変換元**の [幅, signed?]。32 bit signed は REX.W なし、64 bit signed と 32 bit unsigned(スロット上位ゼロを利用)は REX.W 付き。unsigned long 変換はジェネレータが拒否するため到達しない |
| :ftoi | dst ← (int)a | 浮動小数点 → 整数(cvttss2si/cvttsd2si、ゼロ方向切り捨て)。size = 浮動小数点**変換元**幅(4/8)、b = 整数**変換先**の [幅, signed?]。REX.W は整数幅 8 のとき。幅 4 未満の変換先はジェネレータが後段で再整形する。unsigned long 変換は同様に上流で拒否 |
| :ftof | dst ← a | float↔double 幅変換(cvtss2sd / cvtsd2ss)。size = **変換元**の幅(4 なら double へ拡大、8 なら float へ縮小) |

### 比較(結果は 0/1)

| 命令 | 意味 |
|---|---|
| :eq / :ne | 符号非依存 |
| :lt / :le / :gt / :ge | 符号付き比較 |
| :ult / :ule / :ugt / :uge | 符号無し比較(setb 系)。ポインタの大小もアドレスが符号無しなのでこちら |

### 幅変換

| 命令 | 意味 |
|---|---|
| :sext(size 1/2/4) | a の下位 size バイトを符号拡張。size 4 は movsxd、1/2 は movsx |
| :zext(size 1/2/4) | a の下位 size バイトをゼロ拡張。size 4 は 32 bit mov(上位ゼロ化)、1/2 は movzx |

### 制御フロー

| 命令 | 形 | 意味 |
|---|---|---|
| :label | a = ラベル id | ジャンプ先。それ自体はコードを出さない |
| :jump | a = ラベル id | 無条件分岐 |
| :jump_if_zero | a = 条件 vreg、b = ラベル id | a == 0 のとき分岐 |
| :ret | a = 値 vreg または nil | 関数から戻る。nil は void の `return;` / 末尾到達(値ロードなし)。`size` nil = 整数/ポインタ戻り(x86-64 は rax、AArch64 は x0)、4/8 = 浮動小数点戻り(x86-64 は xmm0、AArch64 は v0)、AbiPiece 配列 = レジスタ返しの struct — a はジェネレータが memcpy 済みのスクラッチバッファのアドレス vreg で、バックエンドはそれをスクラッチにロードし各ピースの offset・幅で戻りレジスタへ収集する(System V は INTEGER = rax→rdx / SSE = xmm0→xmm1、AAPCS64 は :gp = x0→x1 / HFA メンバ = v0..v3)。レジスタ返しできない struct の `return` は隠れ結果ポインタへの :memcpy の後、そのポインタを size nil で返す |

### 呼び出し

| 命令 | 形 | 意味 |
|---|---|---|
| :call | dst ← f(args)。a = callee 名(String)、b = **[vreg, kind] ペアの配列**(左から右。kind は :gp / :sse4 / :sse8 / :mem、および §2 param_kinds の :indirect_result / :pad / :pad_stack。:pad / :pad_stack は 16 バイト整列集約の整列 pad で vreg は nil) | kind は**ジェネレータがターゲットの CallConvention で配置シミュレーションを行い確定済みの着信位置**(以下は x86_64 の場合): :gp は edi..r9d の次の空き、:sse4/:sse8 は xmm0..7 の次の空き(movss/movsd でロード)、:mem は 8 バイトスロット内容のまま逆順 push のスタック渡し(:mem 同士は左→右の順序を保つ)。バックエンドは指定に従うだけで、超過(7 個目の :gp 等)は契約違反として raise。struct 引数はジェネレータが規約のピースごとの複数ペアに展開済み(all-or-nothing 規則も配置時に適用済み。AAPCS64 が参照渡しする集約はコピーへの :gp ポインタ 1 つに縮約済み)。隠れ結果ポインタ戻りの callee には [vreg, kind] ペアが先頭に加わる。`size` = nil または [fixed, ret](§4)。可変長 callee には call 直前に al = 使用 xmm 数(mov al, imm8) |
| :call_indirect | dst ← (*a)(args)。a = 関数アドレスの vreg、b = [vreg, kind] ペアの配列 | 引数・size の扱いは :call と同一。バックエンドはターゲットの非引数 scratch レジスタ(x86-64 は r10、AArch64 は x9)経由で call |
| :func_addr | dst ← &func。a = 関数名(String) | 関数指示子の退化・`&f` の値。:global_addr 同様の PC 相対再配置で解決 |

### アドレス生成

| 命令 | 形 | 意味 |
|---|---|---|
| :addr_of | dst ← &slot(a) | vreg a のスタックスロット自体の絶対アドレス(スカラローカルの `&x`) |
| :object_addr | dst ← &object(a)。a = オブジェクト id | stack_objects の基底アドレス(配列の先頭要素) |
| :string_addr | dst ← &string(a)。a = 文字列プール id | 読み取り専用文字列のアドレス(減衰済み char *) |
| :global_addr | dst ← &global(a)。a = シンボル名(String) | ファイルスコープ変数のアドレス。グローバルの読み書き・`&g`・配列減衰はすべてこれを経由 |
| :got_addr | dst ← &symbol(a) via GOT。a = シンボル名(String) | `-fPIC` 指定時、この翻訳単位が定義しないファイルスコープのオブジェクト/関数のアドレスを、PC 相対で形成する代わりに Global Offset Table スロットから読み込む。x86-64 は `mov rax,[rip+disp32]`、AArch64 は `adrp` + `ldr` で GOT スロットを読む。具体的な再配置型は §6 の機種記述が選ぶ。他 DSO の定義が interpose し得るため。この TU が定義するシンボルは同一 DSO 内で必ず解決されるので `:global_addr`/`:func_addr` を保つ。データ・関数共通(GOT スロットにはシンボルの実アドレスが入るので以降の load/store は不変) |

### メモリアクセス

| 命令 | 形 | 意味 |
|---|---|---|
| :load | dst ← *a(size) | ポインタ a から size バイト読み、**符号拡張**(signed char/short は movsx。4/8 は素の mov) |
| :uload | dst ← *a(size) | :load のゼロ拡張版(unsigned char/short・_Bool 用) |
| :store | *a ← b(size) | b の下位 size バイトをポインタ a へ書く |
| :memcpy | *a ← *b(size) | b のアドレスから a のアドレスへ size バイトコピー(struct 全体代入 `s = t`) |

### 可変長引数

| 命令 | 形 | 意味 |
|---|---|---|
| :va_start | a = __va_list_tag のアドレス vreg、b = 取り囲む関数の固定パラメータ数 | ターゲットの va_list フィールドを初期化する。SysV は 4 フィールド(gp_offset / fp_offset / overflow_arg_area / reg_save_area)、AAPCS64 は 5 フィールド(__stack / __gr_top / __vr_top / __gr_offs / __vr_offs)。名前付きパラメータが消費済みの GP/SSE レジスタ数は b ではなく **Function.param_kinds のカウントから導出**する。SysV: gp_offset = 8×count(:gp)、fp_offset = 48 + 16×(count(:sse4)+count(:sse8))、overflow_arg_area の開始は count(:mem) を反映、reg_save_area は退避領域を指す。AAPCS64: __gr_offs = −(8−count(:gp)−count(:pad))×8、__vr_offs = −(8−count(:sse4/:sse8))×16(退避領域の末尾 __gr_top/__vr_top からの負オフセットで 0 に向かって増える)、__stack の開始は count(:mem)+count(:pad_stack) を反映し、__gr_top/__vr_top は退避領域とスタック引数の境界を指す。**va_arg / va_end / va_copy に専用命令は無い** — ジェネレータが通常の load/store/分岐に降ろす(SysV の double は fp_offset を `:ult 176` で分岐しレジスタ側 +=16 / あふれ側 +=8;AAPCS64 は offs を `:lt 0` で分岐しレジスタ側は top+offs、offs += 8/16;va_copy はタグ全体の :memcpy) |

### スタック領域確保

| 命令 | 形 | 意味 |
|---|---|---|
| :alloca | dst ← alloca(a) | a はバイト数を持つ vreg。関数の自動記憶域を動的に確保し、その基底アドレスを dst に置く。両ターゲットとも 16 バイト単位に切り上げてスタックポインタを下げ、関数復帰時にまとめて解放する(スコープ単位では解放しない)。x86-64 は `rsp` を動かすだけでよい(全スロットが `rbp` 基準)。AArch64 は sp 基準のフレームを持つため、**この命令を含む関数だけ x29 でフレームを固定**し、スロット参照と呼び出しの outgoing 領域を切り替える(§6.3) |

### ビットスキャン・ビット数え上げ

| 命令 | 形 | 意味 |
|---|---|---|
| :bit_scan | dst ← scan(a)。b = 方向、size = 4/8 | 整数 a の 0 ビット数を数える(__builtin_ctz/clz とその l 形・ll 形)。b = `:forward` は末尾 0 の個数(ctz)、`:reverse` は先頭 0 の個数(clz)。x86-64 は `:forward` を `bsf`、`:reverse` を `bsr` の後 (size*8−1) との `xor`(= (幅−1) − 最上位セットビット位置)に降ろす(size 8 は REX.W 付き)。AArch64 は `:reverse` を `clz` 単体、`:forward` を `rbit` + `clz` に降ろす(size 4 は W レジスタ形式、size 8 は X レジスタ形式)。オペランド 0 は未定義(gcc 準拠)なのでゼロ処理は出さない。結果は int |
| :popcount | dst ← ones(a)。size = 4/8、b は未使用 | 整数 a の 1 ビット数を数える(__builtin_popcount とその l 形・ll 形)。**オペランド 0 も定義**(0 を返す)で、ビットスキャンと違い未定義のケースは無い。**どちらのバックエンドもハードウェアの population count 命令を使わない** — x86-64 の `popcnt` は SSE4.2、AArch64 の `cnt` は AdvSIMD のベクタ命令であり、前者はベースラインに無く、後者はベクタレジスタを経由することになるため。代わりに両者とも同じ分割統治(SWAR)展開を出す: 2 ビット幅の部分和から始めて幅を倍にしながら 4 段(pair → nibble → byte → 全体)で畳み、最後の段は 1 バイトに 1 を置いた定数との乗算で全バイトを最上位バイトに集めて右シフトする。x86-64 は 15 命令(size 4)/ 19 命令(size 8、論理演算に imm64 が無いので各マスクを `movabs` で rdx に置く)、AArch64 は 13 命令(マスクも乗数もすべて bitmask immediate なので movz/movk は不要)。導出は `backend/x86_64.rb#emit_popcount` に書いてある。結果は int |

### アトミック操作

gcc の `__atomic_*` 組み込み(ジェネレータが扱う 5 つの IR 命令)の降ろし先。**IR はメモリオーダを
一切運ばない** — ジェネレータがソースの指定したオーダによらず全てを最強の順序
(seq_cst)で降ろすため。オーダの強化は常に意味論的に妥当(制約を増やすだけ)なので、
`__ATOMIC_RELAXED` を seq_cst として実装するのは正しく、診断にするより堅牢である
(同じ理由で `__atomic_compare_exchange_n` の `weak` も無視して常に strong)。
`size` は load/store/rmw/cas では 4 か 8 のみ — それ以外の幅はジェネレータが診断
するので、バックエンドに狭い/広いケースは無い。

| 命令 | 形 | 意味 |
|---|---|---|
| :atomic_fence | — | 逐次一貫なメモリフェンス。x86-64 は `mfence`、AArch64 は `dmb ish` |
| :atomic_load | dst ← atomic *a。size = 4/8 | ポインタ a から `size` バイトを逐次一貫に読む。`:load` と別命令なのは 2 ターゲットで形が違うから — x86-64 は整列した素の `mov` が既に seq_cst ロード、aarch64 は acquire 形(`ldar`)が要る |
| :atomic_store | *a ← b。size = 4/8 | ポインタ a へ b の `size` バイトを逐次一貫に書く。x86-64 は `xchg`(暗黙の lock が seq_cst ストアに必要な後続バリアを兼ねる)、aarch64 は `stlr` |
| :atomic_rmw | dst ← rmw(a, b)。b = [値 vreg, kind]、size = 4/8 | ポインタ a を通したアトミックな read-modify-write。kind は `:exchange` / `:fetch_add` / `:fetch_sub` / `:add_fetch` / `:sub_fetch` / `:or_fetch`。dst には対応する組み込みの戻り値(`:exchange` と `:fetch_*` は**読んだ値**、`:*_fetch` は**書いた値**。結果を捨てる場合は nil)。x86-64 は `xchg` / `lock xadd`(`:fetch_sub` は `neg` してから、`:*_fetch` はオペランドを退避して加え直す)で、`:or_fetch` だけ `lock cmpxchg` リトライループ。aarch64 は全 kind が LDAXR/STLXR リトライループ 1 本 |
| :atomic_cas | dst ← cas(a, b)。b = [expected ポインタ vreg, desired vreg]、size = 4/8 | `__atomic_compare_exchange_n`。*a が \*expected と等しければ *a ← desired で dst = 1、等しくなければ *a は不変で dst = 0 かつ**実際に読めた値を expected 経由で書き戻す**(`<ruby/atomic.h>` の RUBY_ATOMIC_CAS はこの副作用から答えを取り出すので必須)。書き戻しは失敗経路のみ(分岐でガード)— expected が a に別名で重なった場合に、交換したばかりの値を古い値で潰さないため。dst は _Bool(0/1)で nil にならない |

`:atomic_rmw` と `:atomic_cas` のリトライループ・分岐は **1 つの IR 命令の内側で閉じる**ので、
ラベル機構(`:label` / `@fixups`)は使わず、発行済みバイト数から変位を直接計算する
(aarch64 の `#emit_memcpy_loop` と同じやり方)。

## 6. バックエンドとの契約(参考)

IR 自体の仕様ではないが、IR を書く側・読む側が共有する前提。

### 6.1 共通契約

- **値と引数分類**: vreg は 8 バイトスロットに対応し、`param_kinds` は
  ジェネレータがターゲットの `IR::CallConvention` で確定する。バックエンドは
  `:gp` / `:sse4` / `:sse8` / `:mem` / `:indirect_result` / `:pad` /
  `:pad_stack` の指定に従って受け渡しを行い、集約の分解・再組み立ては
  `IR::AbiPiece` とジェネレータが担う。
- **コンパイル結果**: `Backend::X86_64` と `Backend::AArch64` は同じ
  `Result(bytes, symbols, relocations)` の形を返す。命令のレベルでは
  リロケーション語彙(`:call` / `:func` / `:string` / `:global` / `:got`)だけを
  記録し、ELF の具体的な型番号はバックエンドから分離する。
- **データ再配置**: `GlobalInit.relocations` の `:symbol` / `:string` は
  8 バイトの絶対アドレススロットを表す。addend は `GlobalReloc` に保持し、
  最終的な ELF 型への変換は機種記述が行う。

### 6.2 x86-64 System V

- **フレーム配置**: `rbp` を基準に vreg スロット(8 バイト × `vreg_count`)、
  stack object、可変長関数のレジスタ退避領域を負の方向へ配置する。各領域は
  16 バイト境界に揃え、退避領域は GP 6 本 × 8 バイト + xmm 8 本 × 16 バイト
  の 176 バイトである。`:alloca` は `rsp` を動かして動的領域を確保するが、
  vreg と stack object は `rbp` 基準なのでアドレスが変わらない。復帰時に
  フレーム全体と同時に解放する。
- **引数と呼び出し**: `param_kinds` の `:gp` は edi, esi, edx, ecx, r8d, r9d、
  `:sse4` / `:sse8` は xmm0..xmm7、`:mem` は `[rbp + 16 + 8k]` の
  スタック eightbyte に対応する。呼び出し側はスタック引数を逆順に配置し、
  必要な 16 バイト整列 pad を加えてから call し、終了後に領域を戻す。
  可変長 callee には call 前に al へ使用した xmm レジスタ数を入れる。
- **戻り値**: 整数・ポインタと MEMORY struct の隠れ結果ポインタは rax、
  float/double は xmm0。レジスタ返し struct は `IR::AbiPiece` の kind 順に
  INTEGER を rax→rdx、SSE を xmm0→xmm1 へ対応させる。呼び出し側と callee
  は同じ piece の offset・幅でスクラッチバッファへ散布・収集する。

### 6.3 AArch64 AAPCS64

- **フレーム配置**: フレーム基底レジスタを基準に、下から outgoing argument
  area、保存した x29/x30 の 16 バイト、vreg スロット、stack object を非負
  オフセットで置く。outgoing area は関数内の最も広い呼び出しに合わせて一度だけ
  確保し、各 call で push しない。可変長関数ではその上にベクタ 8 本 × 16 バイトと
  整数 8 本 × 8 バイトの 192 バイトのレジスタ退避領域を置く。
- **フレーム基底レジスタ**: 通常の関数は `sp`(プロローグ以降動かないため)。
  **`:alloca` を含む関数だけ `x29`** で、プロローグが x29/x30 を退避した直後に
  `mov x29, sp` で固定する。sp が本体中に動いてもスロットの番地が変わらない
  ようにするためで、エピローグは `mov sp, x29` で全ブロックを一括解放してから
  レコードを復元する。`:alloca` を含む関数は静的な outgoing area を確保せず
  (sp がフレーム底を指さなくなるので到達不能)、各 call が直前に sp を下げて
  確保し、復帰後に戻す(AAPCS64 は callee が `bl` 時点の sp からスタック引数を
  読むため、この領域だけは常に sp 基準)。
- **引数と呼び出し**: `param_kinds` の `:gp` は x0..x7、`:sse4` / `:sse8` は
  v0..v7、`:mem` は caller の stack area に対応する。`:pad` は整数レジスタ
  1 本、`:pad_stack` は stack eightbyte を予約するだけで値を運ばない。
  関数入口の stack 引数は `[sp + frame_size + 8k]`、呼び出し時の stack 引数は
  `[sp + 8k]` に置く。間接呼び出しのアドレスは引数レジスタでない scratch
  レジスタへ最後にロードする。可変長呼び出しで al は使わない。
- **戻り値**: 整数・ポインタは x0、float/double は v0、レジスタ返し struct
  は INTEGER を x0→x1、HFA の浮動小数点 piece を v0..v3 へ対応させる。
  レジスタに載らない集約は x8 の hidden result pointer 経由で書き込み、その
  ポインタを通常の整数戻り値として扱う。

### 6.4 機種別 ELF 再配置

`ObjFile::ELFWriter::MachineDescription` が、共通の kind からターゲット固有の
型・addend・解決シンボルへ変換する。

| 共通 kind | x86-64 System V | AArch64 |
|---|---|---|
| `.text :call` | `R_X86_64_PLT32` | `R_AARCH64_CALL26` |
| `.text :func` | `R_X86_64_PLT32` | `R_AARCH64_ADR_PREL_PG_HI21` + `R_AARCH64_ADD_ABS_LO12_NC` |
| `.text :string` | `R_X86_64_PC32` | `R_AARCH64_ADR_PREL_PG_HI21` + `R_AARCH64_ADD_ABS_LO12_NC` |
| `.text :global` | `R_X86_64_PC32` | `R_AARCH64_ADR_PREL_PG_HI21` + `R_AARCH64_ADD_ABS_LO12_NC` |
| `.text :got` | `R_X86_64_REX_GOTPCRELX` | `R_AARCH64_ADR_GOT_PAGE` + `R_AARCH64_LD64_GOT_LO12_NC` |
| `.data :symbol` / `:rodata` | `R_X86_64_64` | `R_AARCH64_ABS64` |

x86-64 の PC 相対 `.text` 再配置は、rel32 フィールドの位置に応じた
addend bias `−4` を使う。AArch64 のアドレス形成は `adrp` と `add`/`ldr` の
命令対になり、1 つの IR relocation record から複数の ELF relocation を生成する。
`.data` と init/fini array の絶対ポインタスロットは、両ターゲットとも 64 bit
絶対再配置で addend を保持する。

ターゲット選択は `Compiler::TARGETS` が target 名、バックエンド、
`MachineDescription`、ABI 規約を対応付けて行う。現在の target 名は
`x86_64` と `aarch64` である。

### 6.5 ターゲット別の実装範囲

**§5 の全命令を両ターゲットが実装する**(`m4/aarch64-alloca-bitscan-2` 時点)。
`Backend::UnsupportedError` を投げるバックエンドは現在存在しない。

この例外機構は残してある。新しいターゲットを書くときの規約が
「降ろせない命令は `raise UnsupportedError, "<target>: not yet supported: <機能>"`
で明示的に拒否し、もっともらしい誤ったコードを出さない」だからである
(ドライバは診断メッセージに変換して非ゼロ終了する)。

## 7. 不変条件チェックリスト(命令を追加・変更するとき)

1. `ir.rb` の命令一覧コメントと本書 §5 を両方更新したか。
2. 値表現規約(§3)と矛盾しないか — 幅が変わる箇所を増やしていないか。
3. 既存命令への脱糖で済まないか検討したか(§1)。
4. ジェネレータの gen_* 経路と static_type 経路(sizeof 用・副作用なし)の
   両方を同期したか。
5. 決定的出力(N4)を壊していないか — ラベル・vreg・シンボル採番がソース順で
   決まるか。

## 8. 既存 OSS・書籍・仕様との類似点(出典の明記)

R11(既存 OSS 類似実装の禁止)は「高次の設計方針(一般的なアーキテクチャ
パターン)の共通は問題としない」と定めている(DESIGN.md §5・§9.2)。本節は
その透明性のため、本 IR のどの要素が一般概念・公開仕様に由来し、どの要素が
本プロジェクト固有かを明記する。いずれの既存実装についても、ソースコードは
参照していない。

### 8.1 コンパイラ教科書の一般概念に由来するもの

- **三番地コード(three-address code)+ 無制限の仮想レジスタ**(§1)—
  Aho, Lam, Sethi, Ullman『Compilers: Principles, Techniques, and Tools』
  (通称ドラゴンブック)をはじめ、コンパイラ教科書が中間表現の標準形として
  扱う古典的概念。特定の実装に由来しない。
- **非 SSA・合流を :copy で表現**(§1)— SSA(φ 関数)を導入する前の
  三番地コードの素朴な形で、これも教科書的な構成。SSA 自体を採用していない
  点で、SSA を前提とする LLVM IR・GCC GIMPLE(SSA 形)などの現代的 IR とは
  設計が異なる。
- **糖衣構文の脱糖(`&&`・`||`・ループ・複合代入を基本命令列へ展開)**—
  中間表現設計の一般的手法。

### 8.2 公開仕様(一次資料)に由来するもの

DESIGN.md §9.1 の一次資料に基づく。仕様への準拠であり、実装の模倣ではない。

| 要素 | 出典 |
|---|---|
| 引数レジスタ順(rdi, rsi, rdx, rcx, r8, r9)、7 個目以降のスタック渡し、16 バイト整列(§5 :call・§6) | System V AMD64 psABI |
| 引数レジスタ本数のターゲット差(整数 x0..x7 の 8 本、ベクタ v0..v7 の 8 本)、スタック引数の 8 バイト単位・8 バイト整列(**16 バイト整列集約は 16 バイト境界へ pad**、`:pad_stack`)、隠れ結果ポインタの x8(§2 param_kinds の :indirect_result)、集約の分類(HFA は 4 メンバまで各自 v レジスタ、非 HFA は 16 バイト以下なら x レジスタ連番・16 バイト超は参照渡し、**16 バイト整列集約は偶数レジスタペアに載せ手前の 1 本を `:pad` で空ける**、レジスタ不足時は NGRN/NSRN が 8 に飽和) | AAPCS64 §6.4.2 |
| 可変長呼び出しの al = 使用ベクタレジスタ数、レジスタ退避領域、va_list の 4 フィールド構造(gp_offset / fp_offset / overflow_arg_area / reg_save_area)(§5 :va_start・§6) | System V AMD64 psABI §3.5.7 |
| 再配置種別(R_X86_64_PLT32 / PC32 / 64、R_AARCH64_CALL26 / ADR_PREL_PG_HI21 / ADD_ABS_LO12_NC / ABS64)(§2 GlobalReloc・§6) | System V AMD64 psABI / AArch64 ELF ABI / System V gABI |
| 符号別の命令分割(:div/:udiv、:sar/:shr、:lt/:ult 系)と movsx/movzx 対応(§5) | x86-64 の機械命令が符号で分かれること(Intel SDM)への 1:1 対応 |

### 8.3 既存実装との対比(参照していないが、結果の異同を明記)

- **spill-everything(レジスタ割り付けなし)** — 教育用・単純コンパイラで
  広く使われる一般パターン(R11 が許容する高次方針)。ただし compilerbook /
  chibicc 系統は AST から直接コード生成する**スタックマシン方式**
  (push/pop で式を評価)であり、rubycc の「vreg = 固定スタックスロット」
  による三番地コード経由の構成はそれとは異なる。
- **命令名 :sext / :zext** — LLVM IR にも `sext` / `zext` という命令名が
  あるが、sign-extend / zero-extend の標準的な略記が一致しただけである。
  意味論も異なる(LLVM は型付き SSA 値の型変換、本 IR は size =
  **変換元**幅を持つ非 SSA のスロット操作)。
- **命令の粒度** — QBE や LLVM のような機種独立を狙う IR と違い、本 IR は
  x86-64 と AArch64 のコード選択がほぼ 1:1 で済む粒度に意図的に寄せている(§1)。

### 8.4 本プロジェクト固有の要素

- `size` フィールドの命令グループ別多義性(§4)— 特に :call / :call_indirect
  の「size 非 nil = 可変長 callee(値は固定パラメータ数)」という流用。
- 「パラメータは vreg 0..param_count-1 を占める」規約(§2)。
- va_arg / va_end に専用命令を置かず、:va_start だけを IR 命令とし
  va_arg をジェネレータで load/store/分岐に降ろす切り分け(§1・§5)。
- 値表現規約の定式化(§3)—「幅の変化はちょうど 2 か所」「狭い整数は
  32 bit 以上へ符号に従い拡張済み」というスロット契約の置き方。
