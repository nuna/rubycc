# rubycc C11(N1570)適合状況

## 参照規格

**ISO/IEC 9899:201x Committee Draft — N1570**(C11 最終ワーキングドラフト、無償公開):
https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf

条番号・見出し(英語原文)は本書の章立てに従う(DESIGN.md §9.1 の一次資料指定と同じ)。
本書はコンパイラ本体(第 5 章・第 6 章)を中心に扱い、第 7 章(ライブラリ)は
rubycc がコンパイラ + 同梱ヘッダとして提供する範囲(フリースタンディングヘッダおよび
同梱 libc ヘッダ)に限定して簡潔にまとめる。

## 状態の定義

| 状態 | 意味 |
|---|---|
| **実装済み** | 条項の意味論を実装し、実行テスト(多くは gcc 差分比較)で検証済み |
| **部分実装** | 条項の一部のみ実装。未実装の範囲・制限を備考に記載 |
| **非対応(診断)** | 構文または意味論を認識せず、明確な文言の CompileError で拒否する(未対応機能は黙って壊さない、というプロジェクトの不変条件どおり) |
| **スコープ外** | DESIGN.md で最初から対象外と定めた機能。診断されるとは限らない(#include できない・キーワードが無いなど「そもそも存在しない」形で現れることが多い) |

## 実測コーパス駆動という方針(R10)について

rubycc は「rubygems.org 上位ダウンロードの C 拡張 gem コーパスの 90% が
gem install 成功 + テスト合格」を到達目標(DESIGN R10)とし、C11 全条項を
先回りで網羅する方針は採らない。**実コーパスで踏まれた機能から実装を追加する**
(ROADMAP §1 の開発ワークフロー、STEPS.md の「M2 追補」群が実例)。
そのため「非対応」は事故的な欠落ではなく、実測でまだ要求されていない、または
意図的に先送りした機能であり、いずれも**診断エラーで明確に失敗する**
(黙ってコンパイルが通り誤ったコードを生成することはない — N3 の不変条件)。

## 最終更新

2026-08-08 時点。**番号付き Step 215 まで**と、後続の
`atomic-type-1`〜`atomic-type-15` / `r-input-diagnostic-1` の実装状態を反映する。

---

## 5. Environment(関連条項のみ)

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 5.1.1.2 | Translation phases | 実装済み | フェーズ 1〜4(行継続・コメント除去・pp トークン化・#include/マクロ展開・条件コンパイル)は Step 26/27、フェーズ 5〜7(隣接文字列リテラル連結を含む)は Step 28 の TokenConverter、フェーズ 8(コンパイル・リンク)は Driver(Step 38)が担う。フェーズ 9(リンク)相当は自前リンカ(Step 34〜37)。#line(6.10.4)によるフェーズ間の行番号制御は Step 102 で対応 |
| 5.1.2.2.1 | Program startup(`main` / argc,argv) | 実装済み | 実行ファイルは自前 crt(_start)経由で `__libc_start_main` を呼び、`int main(void)` / `int main(int argc, char *argv[])` の両形式で argc/argv が実測どおり渡ることを検証済み(Step 37) |
| 5.2.4.2 | Numerical limits(`<limits.h>` / `<float.h>` の値) | 部分実装 | 同梱 limits.h/float.h の値は ABI 一致ハーネス(Step 62/63)で gcc + 実ヘッダと突き合わせ済み。binary32 の丸めは Step 69 で修正済みだが、`long double` を 8 バイト `double` として扱う簡略化(DESIGN §3.3)により、その表現と `max_align_t` は glibc 実測値と一致しない |

---

## 6. Language

### 6.2 Concepts

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.2.1 | Scopes of identifiers | 実装済み | ブロック・関数・ファイル・関数プロトタイプスコープ。tag/ordinary の 2 系統スコープスタックで実装(Step 3, 4, 13, 18) |
| 6.2.2 | Linkages of identifiers | 部分実装 | 外部・内部・無リンケージは Step 22(static の内部リンケージ、extern の束縛登録)で実装。ブロックスコープの関数宣言(6.2.2p5)は Step 168 で対応 — 記憶域を消費せず、ファイルスコープのプロトタイプと同じ署名テーブルへ合流する(`static` を伴う形は 6.7.1p7 の制約違反として診断)。既知の逸脱: ブロックスコープ関数宣言・ブロックスコープ extern の束縛は、外部リンケージが翻訳単位内で単一の実体を指すことを根拠にブロックを超えて残る |
| 6.2.3 | Name spaces of identifiers | 実装済み | ラベル・タグ・メンバ・通常識別子の 4 名前空間(Step 13 タグ、Step 16 ラベル、Step 18 通常識別子、Step 19 メンバ) |
| 6.2.4 | Storage durations of objects | 部分実装 | static/automatic は Step 3, 11, 22 で実装。allocated(malloc 等)は libc 任せ(通常の C 拡張同様)。VLA の自動記憶域はスコープ外(DESIGN §3.3) |
| 6.2.5 | Types | 部分実装 | 基本型・派生型(ポインタ・配列・struct/union・関数・enum=int)は Step 2〜24 で実装。多次元配列は添字・初期化を含め Step 99 で実装済みだが、c-testsuite の 00130/00151 は既存の skip 表に残る。VLA はスコープ外。`_Atomic` は下記の限定範囲で部分実装 |
| 6.2.6 | Representations of types | 部分実装 | 値表現規約(スロット 8 バイト固定・スカラは 32bit 以上へ符号拡張済み、backend/x86_64.rb 冒頭)で一貫実装。`long double` = `double` 扱いの簡略化(DESIGN §3.3)により表現がビット単位で glibc と一致しない既知の制限あり |
| 6.2.7 | Compatible type and composite type | 部分実装 | 関数ポインタ署名の一致検査(Step 21, 23)、struct/union タグの恒等同一性(Step 13)、tentative definition のマージ(Step 28 の「一時定義」)を実装。配列サイズ不一致等の細かな composite type 規則までは追跡しない |
| 6.2.8 | Alignment of objects | 部分実装 | `_Alignof` は実装(Step 22)、`_Alignas` はオブジェクト・メンバで実装(Step atomic-type-2)。自然アラインメントを弱める指定、関数・引数・ビットフィールド・typedef・型名への指定、16 バイトを超える自動オブジェクトは診断する。`__attribute__((aligned(N)))` は struct/union に限り実装(Step 28、GCC 拡張) |

### 6.3 Conversions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.3.1.1 | Boolean, characters, and integers | 実装済み | 整数昇格(Step 17) |
| 6.3.1.2 | Boolean type | 実装済み | `_Bool` への変換は「値 != 0」への脱糖(Step 17) |
| 6.3.1.3 | Signed and unsigned integers | 実装済み | 幅の拡大・縮小・符号変えを `#convert` に一元化(Step 17) |
| 6.3.1.4 | Real floating and integer | 実装済み | float/double ⇔ 整数(unsigned long を含む)を完全対応(Step 24 で符号付き、Step 51/52 で unsigned long の定数・実行時変換を解消) |
| 6.3.1.5 | Real floating types | 部分実装 | float ⇔ double の変換は実装(Step 24)。`long double` は `double` として扱う簡略化(DESIGN §3.3、x87 80bit 精度は非対応) |
| 6.3.1.6 | Complex and imaginary | スコープ外 | `_Complex` / `_Imaginary` は未対応(キーワード未実装) |
| 6.3.1.7 | Real and complex | スコープ外 | 同上に準ずる |
| 6.3.1.8 | Usual arithmetic conversions | 実装済み | LP64 前提でサイズ比較へ単純化した通常算術変換(Step 17) |
| 6.3.2.1 | Lvalues, arrays, and function designators | 実装済み | 配列→ポインタ退化(Step 8)、関数指示子→関数ポインタ退化(Step 21) |
| 6.3.2.2 | void | 実装済み | 不完全型としての扱い(変数不可・sizeof 不可)、`(void)式`(Step 12, 14) |
| 6.3.2.3 | Pointers | 実装済み | ヌルポインタ定数の暗黙変換(Step 14)、ポインタ⇔整数キャスト(Step 17) |

### 6.4 Lexical elements

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.4.1 | Keywords | 部分実装 | `_Alignas` / `_Atomic` / `_Noreturn` は認識する。`_Generic` / `_Thread_local` / `_Complex` / `_Imaginary` は未実装で、通常は診断になる |
| 6.4.2 | Identifiers | 実装済み | ASCII 識別子(Step 2〜) |
| 6.4.3 | Universal character names | 非対応 | `\uXXXX` / `\UXXXXXXXX` の字句解析は未実装 |
| 6.4.4.1 | Integer constants | 実装済み | 10/8/16 進、u/l/ll 接尾辞(Step 17)。2 進リテラル `0b...` は GNU 拡張として Step 44 で追加(詳細は GCC-EXTENSIONS.md) |
| 6.4.4.2 | Floating constants | 部分実装 | 小数・指数・f/l 接尾辞(Step 24)。binary32(float)への round-to-nearest, ties-to-even は Step 69 で修正済み。`long double` はコンパイラ内部では `double` として扱う |
| 6.4.4.3 | Enumeration constants | 実装済み | enum 定数はパーサが `IntLit(Type::Int)` へ畳み込む(Step 18) |
| 6.4.4.4 | Character constants | 実装済み | 通常の文字定数、および wide 文字定数 `L'x'`(int 型として扱う、Step 28) |
| 6.4.5 | String literals | 部分実装 | 隣接文字列リテラルの連結(Step 28)。**wide 文字列リテラル `L"..."` は非対応**(診断、c-testsuite 00220) |
| 6.4.6 | Punctuators | 実装済み | Step 2〜17 で全記号を段階的に追加 |
| 6.4.7 | Header names | 実装済み | `"file"` / `<file>` の逐語復元(Step 26) |
| 6.4.8 | Preprocessing numbers | 実装済み | 6.4.8 の広い形で走査し、C 定数としての妥当性は変換段で診断(Step 26) |
| 6.4.9 | Comments | 実装済み | `//` と `/* */`(Step 26) |

### 6.5 Expressions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.5.1 | Primary expressions | 実装済み | 識別子・定数・文字列リテラル・括弧式(Step 2〜)。GNU 文式 `({ ... })` は拡張として Step 40 で実装(詳細は GCC-EXTENSIONS.md) |
| 6.5.1.1 | Generic selection(`_Generic`) | 非対応(診断) | c-testsuite 00219 で確認済みのスキップ項目 |
| 6.5.2 | Postfix operators | 実装済み | 添字(Step 8)・関数呼び出し(Step 6, 21)・`.`/`->`(Step 13)・後置 `++`/`--`(Step 9) |
| 6.5.2.5 | Compound literals | 部分実装 | **ブロックスコープの複合リテラルのみ実装**(Step 53)。ファイルスコープ形(静的記憶域を持つ形)は診断エラー(c-testsuite 00149, 00150) |
| 6.5.3 | Unary operators | 実装済み | `& * + - ~ !`(Step 4, 7, 9, 15)、`sizeof`(Step 8)、`_Alignof`(Step 22) |
| 6.5.4 | Cast operators | 実装済み | cast-expression(Step 14)。`(型名){...}` は 6.5.2.5 複合リテラルとして同一分岐点で弁別(Step 53) |
| 6.5.5 | Multiplicative operators | 実装済み | Step 2, 17(符号別の除算・剰余) |
| 6.5.6 | Additive operators | 実装済み | Step 2, 8(ポインタ演算) |
| 6.5.7 | Bitwise shift operators | 実装済み | Step 15(符号付き算術シフト / Step 17 の符号無し論理シフト) |
| 6.5.8 | Relational operators | 実装済み | Step 4, 17(符号別の比較) |
| 6.5.9 | Equality operators | 実装済み | Step 4 |
| 6.5.10 | Bitwise AND operator | 実装済み | Step 15 |
| 6.5.11 | Bitwise exclusive OR operator | 実装済み | Step 15 |
| 6.5.12 | Bitwise inclusive OR operator | 実装済み | Step 15 |
| 6.5.13 | Logical AND operator | 実装済み | Step 9(短絡評価) |
| 6.5.14 | Logical OR operator | 実装済み | Step 9(短絡評価) |
| 6.5.15 | Conditional operator | 実装済み | Step 9。GNU 拡張の片側 void アームは Step 40 で追加 |
| 6.5.16 | Assignment operators | 実装済み | 単純代入(Step 3)、複合代入(Step 9, 15)。アドレス一度きり評価のヘルパで二重評価バグを構造的に防止 |
| 6.5.17 | Comma operator | 実装済み | Step 15(式文脈のみ comma-expression へ格上げ) |

### 6.6 Constant expressions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.6 | Constant expressions | 部分実装 | ConstantEvaluator による評価(Step 20)。整数演算は無限精度で行いキャスト時のみラップするため、`6.10.1p4` が要求する intmax_t 幅での厳密なラップは #if 定数式では未実装(トレードオフとして明記済み) |

### 6.7 Declarations

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.7.1 | Storage-class specifiers | 部分実装 | `typedef`/`static`/`extern` は意味論込みで実装(Step 18, 22)。`register`/`auto` は構文のみ受理し意味・制約検査なし(`&` 禁止 6.7.1p6 は未検査)。ブロックスコープの関数宣言に `extern` 以外の記憶域指定子が付く形は 6.7.1p7 の制約違反として診断(Step 168)。`_Thread_local` はスコープ外(DESIGN §3.3) |
| 6.7.2.1 | Struct or union specifiers(ビットフィールド・FAM 含む) | 実装済み | struct/union レイアウト(Step 13, 19)、ビットフィールドのレイアウト(Step 28)とアクセス(Step 48)、可変長配列メンバ(6.7.2.1p18、Step 46)。無名メンバ内のタグ付き無宣言子(`struct { struct Inner {...}; }` 形)は拒否(gcc は警告どまりだが M1 は簡略化しエラー、Step 19) |
| 6.7.2.2 | Enumeration specifiers | 部分実装 | enum 型は専用型を持たず `Type::Int` に一元化(Step 18)。**enum の基底型を常に符号付きとして扱う**ため、gcc の「全非負 enum は unsigned int」規則との不一致が bit-field 読み出し・ポインタ符号比較で顕在化(c-testsuite 00170, 00218、ROADMAP §3 の既知の負債) |
| 6.7.2.3 | Tags | 部分実装 | 前方宣言・自己参照・タグスコープ(Step 13)。内側スコープでの `struct S;` 再宣言は 6.7.2.3p7 に従わず外側タグを参照する既知の逸脱(ROADMAP §3) |
| 6.7.2.4 | Atomic type specifiers | 部分実装 | `_Atomic T` / `_Atomic(T)` を受理し、整数・浮動小数・ポインタの 1/2/4/8 バイトでは非修飾型と同じレイアウト・ABIにする。struct/union・16 バイトスカラ・配列・関数型は診断する(atomic-type-1) |
| 6.7.3 | Type qualifiers | 部分実装 | `const` はトップレベル修飾のみ宣言のフラグとして追跡し代入違反を診断(Step 22。指し先 const の書き込みは検出しない)。`volatile` は構文のみ受理し完全に無視、`restrict` は受理して意味を持たせない。`_Atomic` は上記の限定された型で同じ表現を持つが、通常の読み書きには C11 の seq_cst 順序を付けない |
| 6.7.4 | Function specifiers | 部分実装 | `inline` は構文のみ受理(意味論上の効果なし、Step 22)。`_Noreturn` は Step 182 で受理するが、最適化や到達性診断には使わない。同梱 stdnoreturn.h の `noreturn` は `_Noreturn` に展開する |
| 6.7.5 | Alignment specifier | 部分実装 | `_Alignas` と同梱 stdalign.h の `alignas` を実装(Step atomic-type-2)。要求値は自然アラインメント以上である必要があり、対象外の宣言位置やフレームで保証できない過剰アラインメントは診断する |
| 6.7.6 | Declarators | 部分実装 | 下記 6.7.6.1〜6.7.6.3 のとおり |
| 6.7.6.1 | Pointer declarators | 実装済み | `int *p` / `int **pp` 等(Step 7)、`restrict`/`const`/`volatile` 修飾は構文受理(Step 22, 28) |
| 6.7.6.2 | Array declarators | 部分実装 | 1 次元・多次元配列(Step 8, 99)を実装。**可変長配列(VLA)はスコープ外**(DESIGN §3.3)。c-testsuite の 00130/00151 は skip 表に残る |
| 6.7.6.3 | Function declarators(プロトタイプ含む) | 部分実装 | プロトタイプ形式(Step 6, 21)と K&R 形式の旧式パラメータリスト(atomic-type-10)を実装。未指定引数型を関数パラメータ型として使う形は未対応(c-testsuite 00209) |
| 6.7.7 | Type names | 実装済み | `sizeof(型名)`(Step 8)、キャスト式の型名(Step 14)。parse_type_name として共有 |
| 6.7.8 | Type definitions | 部分実装 | `typedef`(Step 18)。**同一型への再 typedef も一律拒否**(C11 6.7p3 は同一型なら許容するが M1 単純化として拒否) |
| 6.7.9 | Initialization | 実装済み | 定数式評価器と一体の初期化子リゾルバ(Step 20)。brace 省略・指示付き初期化子・`[]` 長さ推論・文字列初期化に対応。文字列初期化は NUL 込みで収まる長さを要求(`char s[2]="ab"` の NUL 落ちは C では合法だが診断) |
| 6.7.10 | Static assertions | 実装済み | `_Static_assert`(Step 22)。`sizeof <式>` の畳み込みは Step 107 |

### 6.8 Statements and blocks

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.8.1 | Labeled statements | 実装済み | `case`/`default`(Step 16)、ラベル文と `goto`(Step 16) |
| 6.8.2 | Compound statement | 実装済み | ブロックスコープ(Step 4) |
| 6.8.3 | Expression and null statements | 実装済み | Step 3 |
| 6.8.4 | Selection statements | 実装済み | `if`/`else`(Step 4)、`switch`(比較チェーンへの脱糖、Step 16) |
| 6.8.5 | Iteration statements | 実装済み | `while`/`do-while`/`for`(C99 for スコープ、Step 5) |
| 6.8.6 | Jump statements | 実装済み | `goto`/`continue`/`break`/`return`(Step 5, 16) |

### 6.9 External definitions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.9.1 | Function definitions | 部分実装 | プロトタイプ形式(Step 6〜25)と K&R 形式の関数定義(atomic-type-10)を実装。未指定引数型を関数パラメータ型として使う形は未対応 |
| 6.9.2 | External object definitions | 実装済み | tentative definition のマージ(Step 28 の「一時定義」)、`static`/内部リンケージ(Step 22) |

### 6.10 Preprocessing directives

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.10.1 | Conditional inclusion | 実装済み | `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`(Step 26)。`defined` 演算子は展開後の定義済みマクロ認識まで含めて完全対応(Step 49)。`__has_include`/`__has_attribute`/`__has_builtin` は演算子として同じ段で畳み込む拡張(詳細は GCC-EXTENSIONS.md) |
| 6.10.2 | Source file inclusion | 部分実装 | `"file"` / `<file>` の 2 形式(Step 26)、`#include_next`(Step 28)。**マクロ展開結果をヘッダ名にする第 3 形式は非対応** |
| 6.10.3 | Macro replacement | 実装済み | オブジェクト/関数マクロ、`#`/`##`、`__VA_ARGS__`、GNU 名前付き可変長引数とカンマ削除(Step 26, 27, 43)。既知の逸脱: hide-set 交差なしの青染めのため、病的な自己参照入れ子(`CAT(A,B)(x)` 越しの再展開)が gcc と発散しうる(c-testsuite 00201) |
| 6.10.4 | Line control | 実装済み | `#line`(Step 102)。引数をマクロ展開後に「桁列 + 任意の文字列」として読み、次行の推定行番号と推定ファイル名を設定して `__LINE__`/`__FILE__` に反映。推定は #include をまたいで保存・復元(ファイル単位)。gperf 生成の `zonetab.h`(date)が使う |
| 6.10.5 | Error directive | 実装済み | `#error`(Step 26) |
| 6.10.6 | Pragma directive | 部分実装 | `#pragma once` は意味論込みで実装(Step 27)。それ以外の `#pragma`(`push_macro`/`pop_macro` を含む)は受理して無視(c-testsuite 00206) |
| 6.10.7 | Null directive | 実装済み | 空ディレクティブは自然に無視される |
| 6.10.8 | Predefined macro names | 部分実装 | `__FILE__`/`__LINE__`/`__STDC__`/`__STDC_VERSION__`(201112L 固定)/`__RUBYCC__` を実装(Step 27)。**`__GNUC__` は意図的に定義しない**(DESIGN R7。GNU 拡張フォールバック面積を減らす方針) |
| 6.10.9 | Pragma operator(`_Pragma`) | 部分実装 | `_Pragma("...")` は 4 トークンとして受理し丸ごと破棄するのみ(Step 28)。文字列引数の実際の pragma 意味論は処理しない |

### 6.11 Future language directions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.11 | Future language directions | スコープ外 | 標準が将来の予約語・拡張の可能性として列挙する条項であり、現行の言語機能を規定しない |

---

## 7. Library(フリースタンディングヘッダ + 同梱 libc ヘッダの範囲)

rubycc はコンパイラであり libc の実装ではないため、第 7 章はコンパイラが供給すべき
**C11 のフリースタンディングヘッダ**(5.1.2.1 が列挙する 9 本)、C11 の部分実装である
`<stdatomic.h>`、追加の C23 `<stdckdint.h>`、および同梱する **libc 互換ヘッダ**
(R8、musl 派生 + glibc 実測 ABI)の範囲に限定して扱う。

### 7.x フリースタンディングヘッダ(5.1.2.1 が要求する 9 本)

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 7.7 | Characteristics of floating types `<float.h>` | 部分実装 | 同梱(Step 41)。ABI ハーネス(Step 62/63)で gcc と一致検証済み。binary32 の丸めは Step 69 で修正済みだが、`long double` のコンパイラ内部表現は `double` のまま(機種別定数は Step 201) |
| 7.9 | Alternative spellings `<iso646.h>` | 実装済み | 同梱(Step 41) |
| 7.10 | Sizes of integer types `<limits.h>` | 実装済み | 同梱(共通層 + glibc/x86_64 型幅切替層、Step 63) |
| 7.15 | Alignment `<stdalign.h>` | 部分実装 | `alignof` → `_Alignof`、`alignas` → `_Alignas` のマッピングと実体を実装(Step 41, atomic-type-2)。自然アラインメントを弱める指定や対象外の宣言位置など、コンパイラが保証できない形は診断する |
| 7.16 | Variable arguments `<stdarg.h>` | 実装済み | `__builtin_va_start`/`va_arg`/`va_end`(SysV reg_save_area 方式、整数・ポインタは Step 23、浮動小数点は Step 24) |
| 7.18 | Boolean type and values `<stdbool.h>` | 実装済み | 同梱(Step 41)。`_Bool` 自体は Step 17 |
| 7.19 | Common definitions `<stddef.h>` | 実装済み | 同梱(Step 41)。`offsetof` は `__builtin_offsetof` 展開で定数文脈にも対応(Step 42) |
| 7.20 | Integer types `<stdint.h>` | 実装済み | 同梱(glibc/x86_64 切替層、Step 63) |
| 7.23 | `_Noreturn` `<stdnoreturn.h>` | 部分実装 | `noreturn` は `_Noreturn` に展開し、指定子を受理する(Step 182)。ただし最適化・到達性診断には利用せず、実体は no-op |

### 7.17 Atomics `<stdatomic.h>`

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 7.17 | Atomics `<stdatomic.h>` | 部分実装 | `_Atomic` の型指定子と typedef、`atomic_init`/`ATOMIC_VAR_INIT`/`kill_dependency`、memory-order 定数、thread/signal fence、load/store/exchange/compare-exchange/fetch-add/fetch-sub の総称マクロを提供(atomic-type-1, Step 209)。組み込みの対応幅は 4/8 バイトで、メモリオーダは受理するが常に seq_cst、weak CAS は strong として降ろす。`fetch_or/and/xor`、`atomic_flag`、`atomic_is_lock_free` は未提供。通常の C 演算子による読み書きは非アトミック順序のまま |

### その他の第 7 章(同梱 libc ヘッダの範囲)

| 状態 | 備考 |
|---|---|
| 部分実装(範囲限定) | 実コーパスが `#include` する範囲を Step 62 以降の census で棚卸しし、現在は `include/` に 81 物理ファイル、arch 層を正規化した 64 の angle spellings を同梱する。stdio/stdlib/string/errno/ctype/math/time/sys-types/sys-stat に加え、socket/netinet/tcp/un、epoll、timerfd、inotify、syscall 等の Linux/POSIX surface も実需に応じて追加済み(Steps 123〜141)。宣言は musl 派生(MIT、NOTICE 表記)または clean-room、型幅・レイアウト・マクロ値は ABI ハーネスで glibc 実測値に合わせる方針(R8)。実装は libc 全体ではなく、C 拡張が使う宣言・ABI の範囲に限定する |

---

## 出典

- docs/DESIGN.md §3.3(スコープ外の明示)・§9.1(N1570 一次資料指定)
- docs/ROADMAP.md §3(既知の逸脱・技術的負債の一覧表)
- docs/STEPS.md 各ステップの設計記録(Step 1〜215、`atomic-type-*`、`r-input-diagnostic-1`。本書の「備考」列が引用する Step 番号の根拠)
- test/test_c_suite.rb の SKIP 表(c-testsuite の未対応ケースと理由)
