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
