# rubycc 中間表現(IR)仕様

コンパイラの中間表現(`lib/rubycc/ir/ir.rb`)の仕様書。フロントエンド
(`IR::Generator`)が AST から IR を構築し、バックエンド
(`Backend::X86_64`)が IR から機械語を生成する。両者はこの仕様だけを
接点とする。

**正本は `ir.rb` のコメント**(命令一覧)と `backend/x86_64.rb` 冒頭の
値表現規約。本書はそれらを 1 か所にまとめた読み物であり、命令の追加・変更時は
`ir.rb` のコメントと本書の両方を更新すること(ROADMAP §2)。

対応コミット時点: Step 23(可変長引数)完了。

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
- **機種非依存性は限定的**。IR は x86_64 System V を第一ターゲットとした
  抽象化であり、命令の粒度(32/64 bit 演算の区別、符号別の除算・シフト・
  比較)はコード選択がほぼ 1:1 で済むように切ってある。aarch64(M4)でも
  同じ粒度で対応付けられる見込み。

各設計要素がどこまで一般概念・公開仕様由来で、どこが本プロジェクト固有かは
§8 に明記する。

## 2. プログラム構造

```
IR::Program
├── functions : [IR::Function]   関数定義(ソース順)
├── strings   : [String]         読み取り専用文字列プール(:string_addr の id で索引)
└── globals   : [IR::Global]     ファイルスコープ変数(ソース順)
```

### IR::Function

| フィールド | 意味 |
|---|---|
| `name` | シンボル名(String) |
| `insts` | 命令のフラットな配列 |
| `vreg_count` | 使用 vreg 数(バックエンドのフレームサイズ計算用) |
| `param_count` | パラメータ数。**パラメータは vreg 0..param_count-1 を占める**規約で、バックエンドが着信引数レジスタ(および 7 個目以降のスタック引数)をこのスロットへ写す |
| `stack_objects` | オブジェクト id で索引する配列。各要素は集約オブジェクト(配列・struct)のバイトサイズ。バックエンドは vreg スロットの下に配置し :object_addr を解決する |
| `linkage` | `:external`(通常)/ `:internal`(`static`。STB_LOCAL で発行) |
| `variadic` | `...` 付き定義なら true。バックエンドがレジスタ退避領域つきプロローグを出す |

### IR::Global / GlobalInit / GlobalReloc

- `Global(name, size, align, init, linkage)` — `init` が nil なら .bss
  (ゼロ初期化)、`GlobalInit` なら .data。
- `GlobalInit(bytes, relocations)` — `size` バイトのリトルエンディアン像。
  ポインタスロットは 8 バイトのゼロのまま置き、`GlobalReloc` がリンク時に
  埋める。「全ゼロだが明示初期化」は nil init(.bss)と区別される。
- `GlobalReloc(offset, kind, symbol, string_id)` — グローバル像内のバイト
  オフセット `offset` にある 8 バイトスロットへの再配置。
  - `kind: :symbol` — 他のファイルスコープオブジェクトまたは関数のアドレス
    (`&global`・グローバル配列名の減衰・関数名 `f`/`&f`)。絶対 64 bit
    (R_X86_64_64)で解決。
  - `kind: :string` — 文字列リテラル。`string_id` が文字列プールを指し、
    コンパイラが .rodata オフセットへ解決。

## 3. 値表現規約(スロット規約)

バックエンドとの最重要契約。`backend/x86_64.rb` 冒頭に原文がある。

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
| :call / :call_indirect | **非 nil = 可変長 callee**(値は固定パラメータ数)。バックエンドは call 直前に al=0 を出す |
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
| :ret | a = 値 vreg または nil | 関数から戻る。nil は void の `return;` / 末尾到達(値ロードなし) |

### 呼び出し

| 命令 | 形 | 意味 |
|---|---|---|
| :call | dst ← f(args)。a = callee 名(String)、b = 引数 vreg 配列(左から右) | 7 個目以降の引数は SysV 規約でスタック渡し(先頭 6 個のレジスタの下に逆順 push)。size 非 nil = 可変長 callee(al=0) |
| :call_indirect | dst ← (*a)(args)。a = 関数アドレスの vreg、b = 引数 vreg 配列 | 引数・size の扱いは :call と同一。バックエンドはスクラッチレジスタ(r10)経由で call |
| :func_addr | dst ← &func。a = 関数名(String) | 関数指示子の退化・`&f` の値。:global_addr 同様の PC 相対再配置で解決 |

### アドレス生成

| 命令 | 形 | 意味 |
|---|---|---|
| :addr_of | dst ← &slot(a) | vreg a のスタックスロット自体の絶対アドレス(スカラローカルの `&x`) |
| :object_addr | dst ← &object(a)。a = オブジェクト id | stack_objects の基底アドレス(配列の先頭要素) |
| :string_addr | dst ← &string(a)。a = 文字列プール id | 読み取り専用文字列のアドレス(減衰済み char *) |
| :global_addr | dst ← &global(a)。a = シンボル名(String) | ファイルスコープ変数のアドレス。グローバルの読み書き・`&g`・配列減衰はすべてこれを経由 |

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
| :va_start | a = __va_list_tag のアドレス vreg、b = 取り囲む関数の固定パラメータ数 | SysV va_list の 4 フィールド(gp_offset / fp_offset / overflow_arg_area / reg_save_area)を初期化。reg_save_area は可変長プロローグが確保した退避領域を指す。**va_arg / va_end に専用命令は無い** — ジェネレータが通常の load/store/分岐に降ろす |

## 6. バックエンドとの契約(参考)

IR 自体の仕様ではないが、IR を書く側・読む側が共有する前提。

- **フレーム配置**(rbp から下へ): vreg スロット(8 バイト × vreg_count、
  16 バイト整列)→ stack_objects(各 16 バイト整列)→ 可変長関数のみ
  GP レジスタ退避領域 48 バイト。
- **パラメータ**: 先頭 6 個は edi..r9d から vreg 0..5 へ spill、7 個目以降は
  [rbp + 16 + 8k] からコピー。狭い整数パラメータの 32 bit 正規化は
  ジェネレータが :sext/:zext で行う(バックエンドは関知しない)。
- **再配置**: 関数コンパイル結果(`Backend::X86_64::Result`)の relocations
  は kind 付き — :call(call rel32、R_X86_64_PLT32)、:func(lea の関数
  アドレス、:call と同経路)、:global(lea のデータシンボル、R_X86_64_PC32)、
  :string(lea の .rodata、セクションシンボル + addend)。compiler.rb が
  ELF の .rela.text / .rela.data に変換する。
- **呼び出し時の整列**: プロローグが rsp を常に 16 バイト整列に保ち、
  スタック引数の push 本数が奇数のときだけ 8 バイトの先行パディングを入れる。

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
| 可変長呼び出しの al = 使用ベクタレジスタ数、レジスタ退避領域、va_list の 4 フィールド構造(gp_offset / fp_offset / overflow_arg_area / reg_save_area)(§5 :va_start・§6) | System V AMD64 psABI §3.5.7 |
| 再配置種別(R_X86_64_PLT32 / PC32 / 64)(§2 GlobalReloc・§6) | System V AMD64 psABI / System V gABI |
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
  x86_64 のコード選択がほぼ 1:1 で済む粒度に意図的に寄せている(§1)。

### 8.4 本プロジェクト固有の要素

- `size` フィールドの命令グループ別多義性(§4)— 特に :call / :call_indirect
  の「size 非 nil = 可変長 callee(値は固定パラメータ数)」という流用。
- 「パラメータは vreg 0..param_count-1 を占める」規約(§2)。
- va_arg / va_end に専用命令を置かず、:va_start だけを IR 命令とし
  va_arg をジェネレータで load/store/分岐に降ろす切り分け(§1・§5)。
- 値表現規約の定式化(§3)—「幅の変化はちょうど 2 か所」「狭い整数は
  32 bit 以上へ符号に従い拡張済み」というスロット契約の置き方。
