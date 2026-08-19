# rubycc C11(N1570)適合状況

## 参照規格

**ISO/IEC 9899:201x Committee Draft — N1570**(C11 最終ワーキングドラフト、無償公開):
https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf

条番号・見出し(英語原文)は本書の章立てに従う。本書はコンパイラ本体(第 5 章・第 6 章)と、
rubycc がコンパイラおよび同梱ヘッダとして提供する範囲(第 7 章)の現状を記載する。

## 状態の定義

| 状態 | 意味 |
|---|---|
| **実装済み** | 条項の意味論を提供する |
| **部分実装** | 条項の一部のみ提供し、未対応の範囲・制限を備考に記載する |
| **非対応(診断)** | 未対応の構文または意味論を明確な CompileError で拒否する |
| **スコープ外** | rubycc の対象範囲に含めない機能 |

## 実コーパスと R10

rubycc の互換性目標は、C 拡張 gem のインストール成功と gem 自身のテスト合格を含む
R10 の検証対象を 90%以上にすることである。C11 の全条項を一律に提供するのではなく、
実際の C 拡張が必要とする範囲を優先する。未対応機能は、黙って誤ったコードを生成せず、
診断または明示した制限として扱う。

---

## 5. Environment(関連条項のみ)

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 5.1.1.2 | Translation phases | 実装済み | 行継続、コメント除去、前処理トークン化、`#include`/マクロ展開、条件コンパイル、隣接文字列リテラル連結、コンパイル、リンクを提供する。`#line` による `__LINE__`/`__FILE__` の制御にも対応する |
| 5.1.2.2.1 | Program startup(`main` / argc,argv) | 実装済み | `int main(void)` と `int main(int argc, char *argv[])` の両形式に対応し、自前 crt から libc の起動処理へ接続する |
| 5.2.4.2 | Numerical limits(`<limits.h>` / `<float.h>` の値) | 部分実装 | 同梱ヘッダは対象 ABI の値を提供する。binary32 の丸めに対応する。`long double` はコンパイラ内部では `double` として扱うため、long double の表現と `max_align_t` は glibc の実装と一致しない |

---

## 6. Language

### 6.2 Concepts

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.2.1 | Scopes of identifiers | 実装済み | ブロック・関数・ファイル・関数プロトタイプスコープに対応する |
| 6.2.2 | Linkages of identifiers | 部分実装 | 外部・内部・無リンケージ、ブロックスコープの外部リンケージ関数宣言に対応する。ブロックスコープ関数宣言・extern の束縛は翻訳単位内で保持する |
| 6.2.3 | Name spaces of identifiers | 実装済み | ラベル・タグ・メンバ・通常識別子の 4 名前空間に対応する |
| 6.2.4 | Storage durations of objects | 部分実装 | static/automatic 記憶域期間に対応する。allocated 記憶域は libc の機能に委ねる。VLA の自動記憶域は対象外 |
| 6.2.5 | Types | 部分実装 | 基本型、ポインタ、配列、struct/union、関数、enum に対応する。多次元配列の添字・初期化に対応する。VLA は対象外。`_Atomic` は下記の限定範囲で対応する |
| 6.2.6 | Representations of types | 部分実装 | スカラ値と ABI に必要な型表現を提供する。`long double` を `double` として扱うため、long double の表現は対象 ABI とビット単位では一致しない |
| 6.2.7 | Compatible type and composite type | 部分実装 | 関数ポインタ署名、struct/union タグ、tentative definition の合成に対応する。細かな composite type 規則の一部は対象外 |
| 6.2.8 | Alignment of objects | 部分実装 | `_Alignof` と、オブジェクト・メンバに対する `_Alignas` に対応する。自然アラインメントを弱める指定、関数・引数・ビットフィールド・typedef・型名への指定、保証できない過剰アラインメントは診断する |

### 6.3 Conversions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.3.1.1 | Boolean, characters, and integers | 実装済み | 整数昇格に対応する |
| 6.3.1.2 | Boolean type | 実装済み | `_Bool` への変換に対応する |
| 6.3.1.3 | Signed and unsigned integers | 実装済み | 整数の拡大・縮小・符号変換に対応する |
| 6.3.1.4 | Real floating and integer | 実装済み | float/double と整数の相互変換に対応する |
| 6.3.1.5 | Real floating types | 部分実装 | float と double の変換に対応する。`long double` は `double` として扱う |
| 6.3.1.6 | Complex and imaginary | スコープ外 | `_Complex` / `_Imaginary` は対象外 |
| 6.3.1.7 | Real and complex | スコープ外 | complex 型を対象外とする |
| 6.3.1.8 | Usual arithmetic conversions | 実装済み | 対象 ABI の整数・浮動小数点型に対する通常算術変換に対応する |
| 6.3.2.1 | Lvalues, arrays, and function designators | 実装済み | 配列および関数指示子の退化に対応する |
| 6.3.2.2 | void | 実装済み | void 不完全型、`sizeof` の制約、`(void)` 式に対応する |
| 6.3.2.3 | Pointers | 実装済み | ヌルポインタ定数、ポインタと整数の相互変換に対応する |

### 6.4 Lexical elements

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.4.1 | Keywords | 部分実装 | `_Alignas` / `_Atomic` / `_Noreturn` を認識する。`_Generic` / `_Thread_local` / `_Complex` / `_Imaginary` は対象外 |
| 6.4.2 | Identifiers | 部分実装 | ASCII 識別子に対応する |
| 6.4.3 | Universal character names | 非対応 | `\uXXXX` / `\UXXXXXXXX` は診断する |
| 6.4.4.1 | Integer constants | 実装済み | 10/8/16 進、u/l/ll 接尾辞に対応する。2 進リテラルは GNU 拡張として対応する |
| 6.4.4.2 | Floating constants | 部分実装 | 小数・指数・f/l 接尾辞に対応する。binary32 は round-to-nearest, ties-to-even で丸め、`long double` は内部で `double` として扱う |
| 6.4.4.3 | Enumeration constants | 実装済み | enum 定数に対応する |
| 6.4.4.4 | Character constants | 実装済み | 通常の文字定数と wide 文字定数に対応する |
| 6.4.5 | String literals | 部分実装 | 隣接文字列リテラルの連結に対応する。wide 文字列リテラルは診断する |
| 6.4.6 | Punctuators | 実装済み | C11 の記号に対応する |
| 6.4.7 | Header names | 実装済み | `"file"` / `<file>` のヘッダ名に対応する |
| 6.4.8 | Preprocessing numbers | 実装済み | 前処理数の走査と、C 定数としての妥当性診断に対応する |
| 6.4.9 | Comments | 実装済み | `//` と `/* */` に対応する |

### 6.5 Expressions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.5.1 | Primary expressions | 実装済み | 識別子・定数・文字列リテラル・括弧式に対応する。GNU 文式は GCC 拡張として対応する |
| 6.5.1.1 | Generic selection(`_Generic`) | 非対応(診断) | `_Generic` は対象外 |
| 6.5.2 | Postfix operators | 実装済み | 添字、関数呼び出し、`.`/`->`、後置 `++`/`--` に対応する |
| 6.5.2.5 | Compound literals | 部分実装 | ブロックスコープの複合リテラルに対応する。ファイルスコープ形は診断する |
| 6.5.3 | Unary operators | 実装済み | `& * + - ~ !`、`sizeof`、`_Alignof` に対応する |
| 6.5.4 | Cast operators | 実装済み | cast-expression と複合リテラルの型名に対応する |
| 6.5.5 | Multiplicative operators | 実装済み | 乗算・除算・剰余に対応する |
| 6.5.6 | Additive operators | 実装済み | 加算・減算・ポインタ演算に対応する |
| 6.5.7 | Bitwise shift operators | 実装済み | 符号付き算術シフトと符号無し論理シフトに対応する |
| 6.5.8 | Relational operators | 実装済み | 対象型の大小比較に対応する |
| 6.5.9 | Equality operators | 実装済み | 等価・非等価比較に対応する |
| 6.5.10 | Bitwise AND operator | 実装済み | ビット AND に対応する |
| 6.5.11 | Bitwise exclusive OR operator | 実装済み | ビット XOR に対応する |
| 6.5.12 | Bitwise inclusive OR operator | 実装済み | ビット OR に対応する |
| 6.5.13 | Logical AND operator | 実装済み | 短絡評価に対応する |
| 6.5.14 | Logical OR operator | 実装済み | 短絡評価に対応する |
| 6.5.15 | Conditional operator | 実装済み | 条件演算子に対応する。GNU 拡張の片側 void アームにも対応する |
| 6.5.16 | Assignment operators | 実装済み | 単純代入と複合代入に対応する |
| 6.5.17 | Comma operator | 実装済み | 式文脈の comma-expression に対応する |

### 6.6 Constant expressions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.6 | Constant expressions | 部分実装 | 整数定数式を評価する。`#if` 定数式で intmax_t 幅に丸める厳密な規則の一部は対象外 |

### 6.7 Declarations

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.7.1 | Storage-class specifiers | 部分実装 | `typedef`/`static`/`extern` に対応する。`register`/`auto` は構文のみ受理する。`_Thread_local` は対象外 |
| 6.7.2.1 | Struct or union specifiers(ビットフィールド・FAM 含む) | 実装済み | struct/union レイアウト、ビットフィールド、可変長配列メンバに対応する。無名メンバ内のタグ付き無宣言子は診断する |
| 6.7.2.2 | Enumeration specifiers | 部分実装 | enum を `int` 型として扱うため、gcc の enum 基底型選択と一致しない場合がある |
| 6.7.2.3 | Tags | 部分実装 | 前方宣言、自己参照、タグスコープに対応する。内側スコープでのタグ再宣言の一部は対象外 |
| 6.7.2.4 | Atomic type specifiers | 部分実装 | `_Atomic T` / `_Atomic(T)` を受理する。整数・浮動小数・ポインタの 1/2/4/8 バイト型は非修飾型と同じレイアウト・ABIにする。struct/union、16 バイトスカラ、配列、関数型は診断する |
| 6.7.3 | Type qualifiers | 部分実装 | `const` のトップレベル修飾を追跡する。`volatile` と `restrict` は構文のみ受理する。`_Atomic` の通常読み書きには C11 の seq_cst 順序を付けない |
| 6.7.4 | Function specifiers | 部分実装 | `inline` は構文のみ受理する。`_Noreturn` は受理するが、最適化や到達性診断には利用しない |
| 6.7.5 | Alignment specifier | 部分実装 | `_Alignas` と `stdalign.h` の `alignas` に対応する。自然アラインメントを弱める指定、対象外の宣言位置、保証できない過剰アラインメントは診断する |
| 6.7.6 | Declarators | 部分実装 | 6.7.6.1〜6.7.6.3 の範囲に対応する |
| 6.7.6.1 | Pointer declarators | 実装済み | ポインタ宣言と `restrict`/`const`/`volatile` 修飾に対応する |
| 6.7.6.2 | Array declarators | 部分実装 | 1 次元・多次元配列に対応する。VLA は対象外 |
| 6.7.6.3 | Function declarators(プロトタイプ含む) | 部分実装 | プロトタイプ形式と K&R 形式の旧式パラメータリストに対応する。未指定引数型を関数パラメータ型として使う形は対象外 |
| 6.7.7 | Type names | 実装済み | `sizeof(型名)` とキャスト式の型名に対応する |
| 6.7.8 | Type definitions | 部分実装 | `typedef` に対応する。同一型への再 typedef は診断する |
| 6.7.9 | Initialization | 実装済み | brace 省略、指示付き初期化子、配列長推論、文字列初期化に対応する |
| 6.7.10 | Static assertions | 実装済み | `_Static_assert` に対応する |

### 6.8 Statements and blocks

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.8.1 | Labeled statements | 実装済み | `case`/`default`、ラベル文、`goto` に対応する |
| 6.8.2 | Compound statement | 実装済み | ブロックスコープに対応する |
| 6.8.3 | Expression and null statements | 実装済み | 式文と null 文に対応する |
| 6.8.4 | Selection statements | 実装済み | `if`/`else` と `switch` に対応する |
| 6.8.5 | Iteration statements | 実装済み | `while`/`do-while`/`for` と C99 の for スコープに対応する |
| 6.8.6 | Jump statements | 実装済み | `goto`/`continue`/`break`/`return` に対応する |

### 6.9 External definitions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.9.1 | Function definitions | 部分実装 | プロトタイプ形式と K&R 形式の関数定義に対応する。未指定引数型を関数パラメータ型として使う形は対象外 |
| 6.9.2 | External object definitions | 実装済み | tentative definition の合成と `static`/内部リンケージに対応する |

### 6.10 Preprocessing directives

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.10.1 | Conditional inclusion | 実装済み | `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif` と `defined` に対応する。`__has_include`/`__has_attribute`/`__has_builtin` は拡張として対応する |
| 6.10.2 | Source file inclusion | 部分実装 | `"file"` / `<file>`、`#include_next` に対応する。マクロ展開結果をヘッダ名にする形式は対象外 |
| 6.10.3 | Macro replacement | 実装済み | オブジェクト/関数マクロ、`#`/`##`、`__VA_ARGS__`、GNU 名前付き可変長引数、カンマ削除に対応する。病的な自己参照入れ子の一部は gcc と異なる |
| 6.10.4 | Line control | 実装済み | `#line` と `__LINE__`/`__FILE__` の制御に対応する |
| 6.10.5 | Error directive | 実装済み | `#error` に対応する。**C11 に無い `#warning`**(長く GNU 拡張、C23 6.10.2p2 で標準化)にも拡張として対応する — 同じ書式の診断を標準エラーに出し、コンパイルは継続する(終了コードは 0) |
| 6.10.6 | Pragma directive | 部分実装 | `#pragma once` に対応する。それ以外の pragma は受理して無視する |
| 6.10.7 | Null directive | 実装済み | 空ディレクティブに対応する |
| 6.10.8 | Predefined macro names | 部分実装 | `__FILE__`/`__LINE__`/`__STDC__`/`__STDC_VERSION__`/`__RUBYCC__` を提供する。`__GNUC__` は定義しない |
| 6.10.9 | Pragma operator(`_Pragma`) | 部分実装 | `_Pragma("...")` を受理して破棄する。pragma の意味論は処理しない |

### 6.11 Future language directions

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 6.11 | Future language directions | スコープ外 | 現行の言語機能を規定しない条項 |

---

## 7. Library(フリースタンディングヘッダ + 同梱 libc ヘッダの範囲)

rubycc は libc の実装ではないため、第 7 章はコンパイラが供給する **C11 のフリースタンディング
ヘッダ**(5.1.2.1 が列挙する 9 本)、C11 の部分実装である `<stdatomic.h>`、追加の C23
`<stdckdint.h>`、および同梱する **libc 互換ヘッダ**(musl 派生 + glibc 実測 ABI)の範囲に限定する。

### 7.x フリースタンディングヘッダ

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 7.7 | Characteristics of floating types `<float.h>` | 部分実装 | float/double は対象 ABI に対応する。binary32 の丸めに対応する。`long double` のコンパイラ内部表現は `double` のままだが、機種ごとの定数を提供する |
| 7.9 | Alternative spellings `<iso646.h>` | 実装済み | 同梱する |
| 7.10 | Sizes of integer types `<limits.h>` | 実装済み | 対象アーキテクチャの型幅を提供する |
| 7.15 | Alignment `<stdalign.h>` | 部分実装 | `alignof` → `_Alignof`、`alignas` → `_Alignas` に対応する。対象外の宣言位置などは診断する |
| 7.16 | Variable arguments `<stdarg.h>` | 実装済み | 整数・ポインタ・浮動小数点の可変長引数に対応する |
| 7.18 | Boolean type and values `<stdbool.h>` | 実装済み | `_Bool` と真偽値マクロを提供する |
| 7.19 | Common definitions `<stddef.h>` | 実装済み | `offsetof` を含む共通定義を提供する |
| 7.20 | Integer types `<stdint.h>` | 実装済み | 対象アーキテクチャの整数型と境界値を提供する |
| 7.23 | `_Noreturn` `<stdnoreturn.h>` | 部分実装 | `noreturn` は `_Noreturn` に展開する。最適化・到達性診断には利用しない |

### 7.17 Atomics `<stdatomic.h>`

| 条番号 | 見出し | 状態 | 備考 |
|---|---|---|---|
| 7.17 | Atomics `<stdatomic.h>` | 部分実装 | `_Atomic` の型指定子と typedef、`atomic_init`/`ATOMIC_VAR_INIT`/`kill_dependency`、memory-order 定数、thread/signal fence、load/store/exchange/compare-exchange/fetch-add/fetch-sub の総称マクロを提供する。組み込み操作の対応幅は 4/8 バイトで、メモリオーダは常に seq_cst、weak CAS は strong として扱う。`fetch_or/and/xor`、`atomic_flag`、`atomic_is_lock_free` は提供しない。通常の C 演算子による読み書きには seq_cst 順序を付けない |

### その他の第 7 章

| 状態 | 備考 |
|---|---|
| 部分実装(範囲限定) | `include/` に 81 物理ファイル、arch 層を正規化した 64 の angle spellings を同梱する。stdio/stdlib/string/errno/ctype/math/time/sys-types/sys-stat、socket/netinet/tcp/un、epoll、timerfd、inotify、syscall 等の Linux/POSIX surface を含む。宣言は musl 派生または clean-room、型幅・レイアウト・マクロ値は対象 ABI に合わせる。libc 全体ではなく、C 拡張が使う宣言・ABI の範囲に限定する |

---

## 出典

- ISO/IEC 9899:201x Committee Draft — N1570
- docs/development/DESIGN.md §3.3(スコープ外の明示)・§9.1(規格資料)
- docs/development/ROADMAP.md §3(既知の制限)
