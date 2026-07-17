# examples — ステップごとのサンプル C プログラム

M1 の各ステップ完了時点の rubycc でビルドできる C ソースを
`m1/step<NN>_<名前>.c` として残す。「そのステップで何ができるようになったか」を
実行可能な形で示すドキュメントであり、`test/test_examples.rb` が全サンプルを
gcc と差分比較(終了コード + 標準出力)するため、後続の変更でサンプルが壊れれば
テストが検出する。

## 運用

- **ステップ完了時に、そのステップの代表機能を使うサンプルを 1 本追加する**
  (ステップ完了サイクルの一部。ROADMAP §1 参照)。
- ファイル名は `step<NN>_<名前>.c`。そのステップ時点のコンパイラでビルドできる
  機能だけを使うこと(後のステップの機能を混ぜない)。
- 各サンプルの先頭コメントに、実演するステップと機能を書く。
- サンプルは追加後に変更しない(以降のどのステップでも常にビルドできることが
  不変条件)。
- M2 以降のマイルストーンも同様に `m<N>/` を作ってステップごとに追加する。

## ビルド方法(M1 時点)

コンパイルは rubycc、リンクはシステムの gcc(自作リンカは M2)。

```sh
ruby -Ilib exe/rubycc -o fizzbuzz.o examples/m1/step10_fizzbuzz.c
gcc -o fizzbuzz fizzbuzz.o
./fizzbuzz
```

## m1 のサンプル一覧

Step 1〜9 の機能(式・変数・if/ループ・関数・ポインタ・配列など)は単体では
プログラムの体を成しにくいため、Step 10 以降のサンプルが横断的に使う形で
カバーしている。ステップごとの追加は Step 14 以降で徹底する。

| ファイル | 実演するステップと機能 |
|---|---|
| `step10_fizzbuzz.c` | Step 10 までの総合(ループ・剰余・関数・ローカル配列・ポインタ演算・char/文字列リテラル・外部 `puts` 呼び出し) |
| `step14_list.c` | Step 14: ヌルポインタ定数・ポインタ条件式(+ Step 13 の struct)による NULL 終端連結リスト |
| `step15_bits.c` | Step 15: ビット演算・シフト・複合代入(popcount とビットフィールド抽出) |
| `step16_vowels.c` | Step 16: switch/case/default のフォールスルーと goto/ラベル(母音数え・走査打ち切り) |
| `step17_checksum.c` | Step 17: long/short/unsigned/_Bool・16 進 8 進リテラル・接尾辞(unsigned long のチェックサム計算・short の再解釈・long の桁あふれ) |
| `step18_traffic.c` | Step 18: enum(既定値・明示値)・typedef(enum/unsigned int の別名)による信号機の状態遷移(case ラベルに enumerator・do-while で 1 周) |
| `step19_variant.c` | Step 19: union・無名 struct/union メンバ(共通ヘッダ + バリアント・型パンニング・sizeof(union))による variant セル |
| `step20_initializers.c` | Step 20: 初期化子(6.7.9)。ローカル/グローバルの配列・struct・char 配列を、位置指定・指示付き・ネスト・ブレース省略・`{0}`・`[]` の長さ推論・文字列リテラルで初期化(未指定要素はゼロ) |
| `step21_dispatch.c` | Step 21: 関数ポインタ。ディスパッチ表(グローバル関数ポインタ配列)・コールバック(関数を引数に取る畳み込み)・`&f`/`(*fp)(...)` 経由の呼び出し・7 引数のスタック渡しによる整数演算 |
| `step22_counter.c` | Step 22: static / extern の意味論。内部リンケージ(static)の関数とファイルスコープ const テーブル・ブロックスコープ static カウンタ(初期化は一度だけ・呼び出しをまたいで保持)・`_Static_assert`/`_Alignof` を使った重み付き集計 |
| `step23_sum.c` | Step 23: 可変長関数。`__builtin_va_list` と `__builtin_va_start`/`__builtin_va_arg`/`__builtin_va_end`(整数の可変長 sum(レジスタ→スタック overflow 跨ぎ)・`__builtin_va_list` パラメータへの転送・libc `vprintf` へ転送する printf 風ロガー) |
| `step24_floats.c` | Step 24: float/double の呼び出し規約(System V xmm ABI)。float/double のパラメータ・戻り値(xmm 引数渡し・xmm0 戻り)・混合 9 引数のレジスタ/スタック境界・可変長呼び出しの al(使用 xmm 数)・`__builtin_va_arg(ap, double)`(fp_offset を独立に走査)・.data/.bss の浮動小数点グローバル初期化子・`printf` の `%f`/`%g` 出力 |
| `step25_records.c` | Step 25: struct の値渡し・値返し(System V AMD64 分類)。レジスタ返し(INTEGER=rax/rdx、SSE=xmm0/xmm1)・混合分類 `[:gp, :sse8]`・16 バイト超の MEMORY 返し(隠れポインタ)・struct 引数渡し・戻り値の連鎖(`f(g(s))`)・`return *p;`・struct 初期化 `struct S t = f(s);`・`printf` 出力 |
| `step26_selftune.c`(+ `step26_config.h`) | Step 26: 条件コンパイルとオブジェクトマクロ。quote include(includer のディレクトリ基準で解決)・インクルードガード(`#ifndef`/`#define`/`#endif`)・`#if`/`#elif`/`#else` による定数選択・`#undef` 後の再定義・`#if defined(...) && ...` によるブロックガード・マクロを畳んだ `printf` 出力(`.h` は `*.c` glob 対象外なので直接コンパイルされない) |
| `step27_report.c`(+ `step27_logging.h`) | Step 27: 関数マクロと `#` / `##` 演算子・可変引数マクロ・定義済みマクロ。`#pragma once` ヘッダの二重 include(1 回だけ読む)・引数展開マクロ(`MAX`/`MIN`)・`#expr` による stringize(`SHOW`)・`##` による識別子合成(`COUNTER`)・`__VA_ARGS__` を `printf` へ転送(`LOG`)・`__FILE__`/`__LINE__`(gcc と同一パスでコンパイルされるため出力一致) |
| `step28_extensions.c` | Step 28: GNU 拡張。`__attribute__((packed))`(パディング無し)/`__attribute__((aligned(16)))`(サイズを 16 の倍数へ切り上げ)の struct を `sizeof` で確認・`__builtin_expect` を if 条件の分岐ヒントに使用・`__builtin_alloca` でスタック上のスクラッチバッファを確保(書き込み→関数呼び出しを跨いで読み戻し・16 バイト整列を確認)・`__extension__`・`__asm__ volatile("" ::: "memory")` のコンパイラバリア |
| `step28_headerisms.c` | Step 28(後半): `<ruby.h>` を塞いでいた機能群。隣接文字列リテラルの連結(翻訳フェーズ 6、stringize 結果との隣接込み)・ワイド文字定数 `L'x'`・`_Pragma` 演算子の受理(ファイルスコープで無効果)・ビットフィールドの System V レイアウト(単位共有・跨ぎ・`:0` 強制整列・無名パディング)を `sizeof`/`_Alignof` で確認(値の読み書きは M2 まで診断エラー) |
| `step28_declarations.c` | Step 28(宣言まわりの ISO 適合): 一時定義(6.9.2、複数回宣言 + 初期化 1 回・カンマ形式・static 版)・関数プロトタイプとオブジェクトが混在する 1 宣言(`int f(int), g(int), a;`)・パラメータ配列の `[static N]`/型修飾子・glibc 流の `__restrict` 修飾・不完全 enum へのポインタ・`char *` と `void *` の条件演算子合成(6.5.15p6) |
| `step28_wideint.c` | Step 28(Phase C4): `__int128` / `unsigned __int128` の最小サブセット(`<ruby.h>` の config.h を塞いでいた最後の機能)。狭い整数からの変換(符号/ゼロ充填)・128 ビット乗算(memory.h の `rb_mul_size_overflow` 形状)・キャリー/ボローを跨ぐ加減算・混合型比較(狭いオペランドを 128 ビットへ昇格)・`sizeof`/`_Alignof`・16 バイトの struct メンバ(char の後にオフセット 16)。未実装の演算(除算・シフト・ビット演算・値渡し/返し・可変長渡し)は診断エラー |

## m2 のサンプル一覧

M2 のリンカ基盤ステップ(Step 29〜36: ELF リーダ・ar・ld -r 併合・PIC・.so
ライタ・ライブラリ解決)は C 言語機能を追加しないため、サンプルは持たない
(実地検証は各コンポーネントのテストが担う)。実行ファイルを作れるようになった
Step 37(L7)から M2 のサンプルを追加する。

| ファイル | 実演するステップと機能 |
|---|---|
| `step37_conftest.c` | Step 37: 実行ファイルと crt(mkmf の try_run プローブの形)。libc 関数(`strlen`/`printf`)を使い、終了コードと stdout の両方で結果を報告する — rubycc の `ExecutableLinker` が合成 crt の `_start`→`__libc_start_main` で C ランタイムを初期化して実行する経路の実演。`test_examples.rb` は gcc 差分で、`test_executable.rb` は rubycc 自身の実行ファイルライタでエンドツーエンド駆動する |
| `step38_driver.c` | Step 38: gcc 互換ドライバ(`Rubycc::Driver`)が 1 コマンドでビルドするプログラムの形。libc(`printf`)を呼び計算結果を終了コードと stdout に反映する — `rubycc -o prog step38_driver.c` のコンパイル+リンク一気通貫の実演。ドライバ自体(複数 TU 一気通貫・`-shared`/`-lz`・`-D`/`-U`・`-E`)は `test_driver.rb` が駆動し、本サンプルは `test_examples.rb` が gcc 差分で検証する |
| `step40_stmtexpr.c` | Step 40(M1 追補): GNU 文式 `({ 文... 最後の式 })`。実 C 拡張を塞いでいた機能で、ruby.h の `TypedData_Make_Struct`/`Data_Make_Struct`/`rb_intern` 等が文式に展開される。最後の式文の値・型が構文全体の値・型になること・ブロック独自スコープ(内側 `a` が外側を汚さない)・入れ子・マクロ本体としての文式(`CLAMP`、ruby.h の割り当てマクロの形)・void 形(最後が for 文で値を持たず副作用のみ)・`__extension__` 前置を実演。`test_examples.rb` が gcc 差分で検証する |
| `step41_freestanding.c` | Step 41(M2 追補): rubycc 同梱の freestanding ヘッダ(`<stdarg.h>`/`<stddef.h>`/`<stdbool.h>`/`<stdalign.h>`/`<iso646.h>`)。**`-I` を一切渡さず**、rubycc が自前の既定インクルードパスでこれらを解決する(gcc 内部 include ディレクトリへの依存を断った)。varargs 和・`offsetof`(実行時文脈)・`size_t`/`NULL`・`bool`・`alignof`・`and`/`or` の演算子綴りを実演。`test_examples.rb` が `-I` 無しでコンパイルし gcc 差分で検証する |
| `step42_offsetof.c` | Step 42(M2 追補): `__builtin_offsetof`(`<stddef.h>` の `offsetof` マクロ経由)。従来型 `((size_t)&(((t*)0)->m))` と違い真の定数式に畳まれるため、**static 初期化子・配列サイズ・case ラベルの定数文脈**で使える — 実 C 拡張の「フィールド名 → バイトオフセットの静的テーブル」の形。パディング入りレイアウトでの各メンバ・ネスト designator(`where.y`)・配列添字 designator(`history[2]`)を実演。`test_examples.rb` が gcc 差分で検証する |
| `step43_variadic_macros.c` | Step 43(M2 追補): GNU 可変長マクロ拡張。**名前付き可変長引数** `#define m(head, rest...)`(linux/stddef.h の `__struct_group(…, MEMBERS...)` の形。`<sys/types.h>` を使う全 TU が踏む)と **GNU カンマ削除** `fmt, ##__VA_ARGS__` / `, ##args`(可変長実引数が無いとき直前のカンマを落とす。glibc/CRuby ヘッダの printf 転送マクロの形)を実演。`test_examples.rb` が gcc 差分で検証する |
| `step44_builtins.c` | Step 44(M2 追補): CRuby config.h の `HAVE_BUILTIN_*` 焼き込みで実 C 拡張が踏む gcc ビルトイン群。`__builtin_constant_p`(定数なら 1・そうでなければ 0、エラーにしない)+ `__builtin_choose_expr`(コンパイル時選択、選ばれた側の型が sizeof に出る — ruby.h の INT2FIX 経路の形)・`__builtin_ctz/clz/ctzll/clzll`(bsf/bsr へ降ろす新 IR :bit_scan)・`__builtin_memcpy`・`__has_builtin`(正直な 1/0 でフォールバック選択)・2進リテラル `0b0001`(msgpack のフラグ定数)を実演。`test_examples.rb` が gcc 差分で検証する |
| `step45_address_constants.c` | Step 45(M2 追補): グローバル初期化子のアドレス定数(ISO C 6.6)。文字列リテラルの**ポインタキャスト越し**参照(json の jeaiii-ltoa が 200 文字の文字列リテラルを `struct digit_pair *` に化かして桁テーブルにする形)・`&arr[i]`・`arr + n`・`&rec.member`・`(void *)&arr[k]` を symbol/rodata + addend の R_X86_64_64 に畳む。`test_examples.rb` が gcc 差分で検証する |
| `step46_flexible_array.c` | Step 46(M2 追補): 可変長配列メンバ(ISO C 6.7.2.1p18)。struct の最終メンバ `long tail[];` が sizeof に寄与しない(ヘッダのみの 8 バイト)こと・`malloc(sizeof(struct) + n * sizeof(要素))` で確保した領域を `h->tail[i]` で読み書きする msgpack held-buffer の形を実演。`test_examples.rb` が gcc 差分で検証する |
| `step47_pointer_sentinels.c` | Step 47(M2 追補): グローバル初期化子の整数→ポインタキャスト。CRuby の `RUBY_TYPED_DEFAULT_FREE` = `(RUBY_DATA_FUNC)-1` が `static const rb_data_type_t` の関数ポインタスロットに置く**番兵値**の形 — アドレスでない生ビットを relocation 無しでスロットへ直書きする。`(void *)0x1000` の絶対アドレスと `(char *)16 + 2` の絶対値算術も実演。`test_examples.rb` が gcc 差分で検証する |
| `step48_bitfields.c` | Step 48(M2 追補): ビットフィールドの読み書き(§3 記録済み負債の解消)。msgpack unpacker の形(`_Bool f:1` × 複数のフラグ語をセッタ関数・ポインタ越しに読み書き)・混在幅の単位共有(隣接フィールド非破壊)・**符号付きフィールドの符号拡張**(`int delta:6` に -9)・代入式の値の切り詰め・sizeof を実演。格納単位の load → shift/mask → read-modify-write store に降ろす。`test_examples.rb` が gcc 差分で検証する |
| `step49_defined_conformance.c` | Step 49(M2 追補): `defined`/#ifdef のビルトインマクロ認識(N1570 6.10.8p1)と gcc 別名キーワード。`defined(__STDC__)`・`#ifdef __FILE__`・`__STDC_VERSION__` の版数ラダー(glibc sys/cdefs.h がコンパイラ判別に使う形)が gcc と一致することを実演。この適合修正で glibc が「gcc 以外の C99 準拠コンパイラ」経路を選ぶようになり、kernel UAPI ヘッダの `__signed__` 等の別名キーワード対応(lexer 正規化)も本ステップに含む。`test_examples.rb` が gcc 差分で検証する |
| `step51_float_thresholds.c` | Step 51(M2 追補): 浮動小数点定数の整数キャストのコンパイル時畳み込み(N1570 6.3.1.4p1 のゼロ方向切り捨て)。json の jeaiii-ltoa が 10 進しきい値を `u32(1e2)`〜`u64(1e15)`(double リテラル → unsigned long キャスト)と綴り、比較・除算・剰余のオペランドに使う形を実演。`(int)-2.9` → -2 の切り捨ても確認。`test_examples.rb` が gcc 差分で検証する |
