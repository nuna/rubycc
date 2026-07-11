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
