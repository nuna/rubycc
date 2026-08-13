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
| `step52_unsigned_float.c` | Step 52(M2 追補): 実行時の unsigned long ⇔ float/double 変換(§3 負債の本体を解消)。x86-64 の cvt 命令は符号付きのみのため、符号ビット両側の分岐合成(u64→double は「半分+sticky ビット → 変換 → 2 倍」、double→u64 は「2^63 未満は直行 / 以上は 2^63 引いて変換後に最上位ビットを戻す」)を実演。json jeaiii の「double 式 × 実行時値を unsigned long に切り捨てる」形も含む。`test_examples.rb` が gcc 差分で検証する |
| `step53_compound_literals.c` | Step 53(M2 追補): 複合リテラル(ISO C 6.5.2.5)— json の最後の壁。無名の自動記憶域オブジェクトを式中で生成・初期化する: 指示付き初期化子で struct を**値渡し**(json parser のスタックフレーム push の形)・未指定メンバのゼロ埋め・`&(T){...}` のアドレス渡し・配列複合リテラルの decay・スカラー形・ループ毎の再初期化を実演。`test_examples.rb` が gcc 差分で検証する |

## m4 のサンプル一覧

M4(aarch64 バックエンド)のステップは**新しい C 言語機能を足さない** — 同じ
言語を第二の機種で実現するマイルストーンなので、Step 68〜80 はサンプルを持たない
(検証は `test_c_suite_aarch64.rb` と `test_examples_aarch64.rb` が、既存の全
サンプルをクロス gcc + qemu で差分実行することで担う)。

サンプルを置くのは、**x86-64 では通っていた機能が aarch64 では通らず、
`test_examples.rb` の `AARCH64_PENDING` に載っていた**ステップだけである。
その穴を塞いだ証拠として、両機種で実行される形で残す。

| ファイル | 実演するステップと機能 |
|---|---|
| `aarch64_alloca_bitscan_1_bit_scan.c` | Step m4/aarch64-alloca-bitscan-1: ビットスキャン組み込み(`__builtin_ctz`/`clz`/`ctzll`/`clzll`)の aarch64 対応。言語機能自体は Step 44 からあり、本サンプルが示すのは**同じ答えに別の命令列で到達する第二バックエンド**である — x86-64 は「最上位セットビットの位置」を返す `bsr` を幅から引いて clz を作るが、aarch64 の `clz` は答えそのもので、ctz は `rbit` でビット順を反転してから同じ `clz` に掛ける。ケースはほぼすべて**カウントの幅**を分離するために選んである(`0x80000000` の clz は unsigned int で 0・unsigned long で 32)。オペランドは配列と関数引数を通して実行時の値にし、0 は未定義動作なので意図的に外した。`test_examples.rb` が gcc 差分で、`test_examples_aarch64.rb` がクロス gcc + qemu 差分で検証する |
| `aarch64_alloca_bitscan_2_alloca.c` | Step m4/aarch64-alloca-bitscan-2: `__builtin_alloca` の aarch64 対応。x86-64 では全スロットが rbp 基準なので rsp を下げるだけで済むが、aarch64 は sp 基準のフレーム(ldr/str の即値が上方向に 32 KiB・下方向に 256 バイトしか届かないための設計)なので、alloca を含む関数だけフレームを x29 で固定する。実演するのはその帰結 4 つ — **記憶域はスコープではなく関数の終わりまで生きる**(ループ内 alloca は毎周 別のブロックを返し、先に書いた内容が最後まで読める)・**スタック引数を持つ呼び出しは alloca ブロックの下に領域を取り直す**(AAPCS64 は callee が `bl` 時点の sp から読むため。10 引数で 2 個がスタックに載る)・**可変長関数の va_arg 走査も固定フレーム基準**・**確保サイズによらず 16 バイト整列**。番地そのものは印字せず関係(相異・整列・非重複)だけを見る。`test_examples.rb` が gcc 差分で、`test_examples_aarch64.rb` がクロス gcc + qemu 差分で検証する |

## m5 のサンプル一覧

M3〜M5 のステップ(同梱ヘッダ・ドライバ・mkmf/rmake・コーパス検証)は
C 言語機能をほとんど追加しないため、サンプルを持つのは言語機能を足した
ステップだけである。

| ファイル | 実演するステップと機能 |
|---|---|
| `step168_block_scope_function_decl.c` | Step 168: ブロックスコープの関数宣言(C11 6.2.2p5)。ブロック内で関数型の宣言子を書くと、記憶域指定子が無いか `extern` のとき外部リンケージを持つ**関数**の宣言になり、ローカルスロットを取らない。同一ファイルの後方で定義した関数の前方宣言・入れ子ブロックでの `extern` 形・関数指示子のポインタへの decay(間接呼び出し)を実演。CRuby の `<ruby/ractor.h>` が `rb_ractor_shareable_p_continue` をこの形で前方宣言しており、io-console のビルドを塞いでいた。**入れ子関数定義(GNU 拡張)は別物で、引き続き診断エラー**。`test_examples.rb` が gcc 差分で検証する |
| `step177_overflow_builtins.c` | Step 177: 整数オーバーフロー検査ビルトイン `__builtin_add_overflow` / `__builtin_sub_overflow` / `__builtin_mul_overflow`。`a op b` を無限精度(128 ビット中間値)で計算し、第 3 引数の指す型へ変換して**必ず格納**したうえで、表現できなければ 1・できれば 0 を返す。オペランドは**各自の型のまま**で通常の算術変換を行わない(`int -1` + `unsigned 1` は UINT_MAX ではなく 0)ことと、オーバーフロー時も値が格納されることを実演。C23 `<stdckdint.h>` の `ckd_add`/`ckd_sub`/`ckd_mul` と、ruby の確保サイズ計算(`count * size` が `size_t` に収まるか)の形。`test_examples.rb` が gcc 差分で検証する(aarch64 は :mulhi 未実装のため `test_examples_aarch64.rb` の PENDING) |
| `step182_noreturn.c` | Step 182: `_Noreturn` 関数指定子(C11 6.7.4)。最適化ヒントに過ぎないため受理して読み捨てる(意味は持たせない)。裸のプロトタイプ・記憶域クラスとの両順序での混在・指定子の重複(C11 が認める)を実演し、`safe_divide` がゼロ除算で `_Noreturn void die(...)` を実際に呼んで `exit()` する経路を通す。musl の `<stdlib.h>` が `abort()` 等をこの裸綴りで宣言する(glibc は `__attribute__((__noreturn__))` を使うため踏まない)形。`test_examples.rb` が gcc 差分で検証する |
| `step184_cast_offsetof.c` | Step 184: `offsetof` の cast 形 `((size_t)&((T *)0)->m)` のコンパイル時畳み込み。アドレスは定数ベースからのメンバオフセットに過ぎず、struct のレイアウトだけで決まるので定数評価器が自力で畳む。入れ子メンバ・配列メンバの要素・要素のメンバ・非 0 のベース・キャスト自身への添字・単なる間接参照の各形と、無名メンバ越しの解決を実演する。CRuby の `<ruby/internal/core/rtypeddata.h>` が `struct RData` と `struct RTypedData` の `data` オフセット一致を `_Static_assert` で主張しており、`<stddef.h>` がこの形で `offsetof` を定義する libc(musl)では、その 1 行だけで `<ruby.h>` の前処理が止まっていた(ギャップ K)。`test_examples.rb` が gcc 差分で検証する |
| `step187_sub_offsetof.c` | Step 187: `offsetof` の引き算形 `((size_t)((char *)&((T *)0)->m - (char *)0))` のコンパイル時畳み込み。Step 184 の cast 形と同じ距離をポインタ差(ISO C 6.5.6p9)経由で綴る、もう一方の伝統的な形。両辺が絶対アドレスへ畳める限り、指す型のサイズで割った差を畳む(`char *` に限らず `int *` 同士の差も要素数として畳む)ことと、`&member + 1` のようなポインタ+整数の折り込みも実演する。`test_examples.rb` が gcc 差分で検証する |
| `step215_atomic_type.c` | Step 215: C11 の `_Atomic` 型指定子と `<stdatomic.h>` の総称マクロ。`_Atomic int` / `int _Atomic` の型修飾子綴りと `_Atomic(size_t)` の括弧付き綴りの両方を、ファイルスコープ・ローカル・struct メンバ・ポインタ修飾・パラメータで実演する。rubycc は `_Atomic T` を `T` と**同じサイズ・同じアラインメント・同じ ABI** で扱い(gcc との実測で確認)、整数・浮動小数・ポインタの 1/2/4/8 バイトに限って受理する(集成体・16 バイトスカラ・配列・関数は診断エラー)。演算は `<stdatomic.h>` の `atomic_load` / `atomic_store` / `atomic_exchange` / `atomic_fetch_add` / `atomic_fetch_sub` / `atomic_compare_exchange_strong` / `_weak`(と各 `_explicit` 版)・`atomic_init`・`atomic_thread_fence` で、いずれも既存の `__atomic_*` 組み込みへ載せているため実際に lock 付き命令列になる。google-protobuf 同梱の upb が `#define UPB_ATOMIC(T) _Atomic(T)` で使う形そのもの。`test_examples.rb` が gcc 差分で検証する |
| `atomic_type_6_sync_builtins.c` | Step atomic-type-6: gcc のレガシー `__sync_*` アトミック組み込み関数。`__atomic_*` との違いは 2 点で、**メモリオーダ引数を持たない**(定義上つねに完全バリア)ことと、**compare-and-swap 2 形が期待値をポインタでなく値で取る**こと。`__sync_fetch_and_add` / `__sync_fetch_and_sub` / `__sync_add_and_fetch` / `__sync_sub_and_fetch` / `__sync_or_and_fetch` / `__sync_lock_test_and_set` / `__sync_lock_release` / `__sync_synchronize` / `__sync_bool_compare_and_swap` / `__sync_val_compare_and_swap` の 10 形を 4/8 バイト幅・符号あり/なし・ポインタ型オブジェクトで実演し、`val_` 形が成功・失敗の**両方**で「実際に読んだ値」を返すこと、ポインタ型への加算が**スケールされず生のバイト**であること(gcc 実測)、`bool_` 形の結果が 1 バイトの `_Bool` であることを示す。対応する IR 命令が無い `__sync_fetch_and_or` 等 7 綴りは**意図的に未実装**(undeclared identifier)。raindrops の extconf.rb がこの族を直接プローブし、失敗するとビルドを中止するため `gem install unicorn` が依存で止まっていた形。`test_examples.rb` が gcc 差分で検証する |
| `atomic_type_10_knr_definitions.c` | Step atomic-type-10: 旧形式(K&R)の関数定義(ISO C 6.7.6.3 の識別子リスト宣言子 + 6.9.1 の宣言リスト)。括弧の中には引数の**名前だけ**を書き、型は宣言子と `{` の間の宣言リストで与える。宣言されなかった識別子は `int`(6.9.1p6)・記憶域指定子は `register` のみ許される(6.9.1p4)・**この形の関数はプロトタイプを持たない**ため引数は既定の実引数拡張を受けて渡される(6.9.1p10 + 6.5.2.2p6: `float` は `double`、`char`/`short`/`_Bool` は `int` として受け取る)一方、本体が見るのは宣言どおりの狭い型である、という 3 点を実演する。`take_char(300)` が 44・`take_bool(2)` が 2 になること(gcc は昇格後の下位バイトを格納するだけで `_Bool` を 0/1 に正規化しない — 実測)、配列・関数引数のポインタへの調整、関数ポインタを返す旧形式定義、プロトタイプ併記時(6.7.6.3p14)の受け渡し形も含む。gperf の生成物がこの形で、mysql2 同梱の `ext/mysql2/mysql_enc_name_to_ruby.h` がまさにこれ(`register` 付き引数の 2 関数)であり、`gem install mysql2` がここで止まっていた。`test_examples.rb` が gcc 差分で検証する |
| `atomic_type_11_null_pointer_constant.c` | Step atomic-type-11: 空ポインタ定数(6.3.2.3p3)の判定を、`void *` へのキャストに限らず**整数定数式で値が 0 であるもの全般**へ広げる。6.6p6 が整数定数式の中に整数型へのキャストを許すため、`(unsigned long)0` はそのキャスト式**自体**が値 0 の整数定数式であり、空ポインタ定数になる(浮動小数型へのキャストは 6.6p6 が整数型への変換しか許さないため対象外で、`(double)0` は該当しない)。列挙定数や `1 - 1` のような畳み込み可能な式も同じ扱いを実演し、初期化子(静的・ローカル)・代入・`==`/`!=`(両順序)・実引数・戻り値・`?:` の両アームを一通り試す。CRuby の `Qfalse` は `typedef unsigned long VALUE; #define Qfalse ((VALUE)RUBY_Qfalse)`(`RUBY_Qfalse` は値 0 の列挙定数)というまさにこの形で、`ext/mysql2/client.c` の比較がこれを踏んでおり、`gem install mysql2` の最後のブロッカーだった。`test_examples.rb` が gcc 差分で検証する |

## m6 のサンプル一覧

| ファイル | 実演するステップと機能 |
|---|---|
| `long_double_varargs_1.c` | Step long-double-varargs-1: 可変長関数へ渡す `long double`。rubycc は double の範囲・精度で計算する(`sizeof(long double)` は 8)が、C ライブラリはプラットフォーム固有の幅広形式(x86-64 は 80 ビット x87、AArch64 は IEEE binary128)で読み戻すため、可変長呼び出し側で静的型に従って変換する。通常の算術変換を跨いでも型が保たれること(`a + b` が単独の `a` と同じ幅で積まれること)も実演する。`test_examples.rb` が gcc 差分で検証する |
| `spill_traffic_cleanup_1_subscripts.c` | Step spill-traffic-cleanup-1: **C 機能の追加は無い**。IR 段の局所変換(添字の「要素幅との乗算 + ベースへの加算」を 1 命令の `:scaled_add` に融合・代入式を一時値経由でなく変数のスロットへ直接書く・読まれない結果を作らない)が壊れていないことを差分で守るサンプル。スケール 1/2/4/8 の添字(負の添字とポインタ経由の後ろ向き添字を含む)・**2 の冪でないストライド**(12 バイト構造体の配列。融合は起きず乗算が残る)・代入の連鎖(`acc = acc + …` のように生成側が自分の書き先を読む形を含む)・値が捨てられる文(`i++` と式文)を網羅する。`test_examples.rb` が gcc 差分で検証する |
| `spill_traffic_cleanup_2_residency.c` | Step spill-traffic-cleanup-2: **C 機能の追加は無い**。バックエンド側のスロットトラフィック削減(直前の命令がレジスタに残した値の読み戻し省略・第 2 オペランドのスロット直接参照・単一使用一時値のストア省略)が壊れていないことを差分で守るサンプル。**間違え方が最適化のそれ**(もう保持していないレジスタから取れば診断ではなく違う数値になる)なので、非可換演算の第 2 オペランドに来る一時値(減算・シフト・除算・ポインタストア)・浮動小数点レジスタファイルでの同型(幅の一致も含む)・呼び出しを跨ぐ値・**制御フローの合流を跨ぐ値**・union 経由のオブジェクト全体コピーを網羅する。`test_examples.rb` が gcc 差分で検証する |
