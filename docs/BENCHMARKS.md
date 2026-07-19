# rubycc 実行速度ベンチマーク(Step 66)

**rubycc** が生成したネイティブコードの実行速度を、同じプログラムを
**gcc -O2** / **gcc -O0** でビルドしたものと比較した実測記録。rubycc は
最適化を行わない(レジスタ割付なし・全値をスタックにスピルする)コンパイラなので、
本ベンチの目的は、計算カーネルと実 C 拡張ワークロードの双方でその差を
**定量化**し、DESIGN 要件 **N2**(「gcc -O2 比 2〜5 倍遅を許容」)に照らして
評価することにある。

ベンチのコードとハーネスは [`../benchmark/`](../benchmark/) にある。本ファイルは
1 回分の実測結果と考察を記録する。再現は `ruby benchmark/run.rb`
([`benchmark/README.md`](../benchmark/README.md) 参照)。

## 実行環境

- **日付**: 2026-07-19
- **CPU**: AMD Ryzen 5 4500U with Radeon Graphics(6 コア)
- **カーネル**: Linux 6.6.87.2-microsoft-standard-WSL2(WSL2)
- **Ruby**: ruby 3.4.5 (2025-07-16 revision 20cda200d3) +PRISM [x86_64-linux]
- **gcc**: gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
- **rubycc**: 本ツリー(M3、x86_64 バックエンド、-O0 相当のコード生成)
- **サンプリング**: ウォームアップ 1 回(破棄)+ 計測 7 回、中央値の wall time
  (`Process::CLOCK_MONOTONIC`)

コンパイルフラグ: C カーネルは単一翻訳単位を `gcc -O2` / `gcc -O0` / `rubycc`
でビルド(rubycc は `-O*` を無視)。C 拡張は各 gem の `extconf` 生成 `Makefile`
から抽出した `-D` 定義を付けて `-shared -fPIC` でビルド。json は全バリアントで
`JSON_DISABLE_SIMD=1` を付与(下記の注記参照)。

計測の作法: 各ケース 7 回の中央値・ウォームアップ 1 回。本測定は WSL2 上の
ラップトップで実施したが、他の負荷はかけていない。サンプルの分散
`(max-min)/median` は、`sieve` の gcc-O0(19.9%、ウォームアップ直後の 1 サンプルが
遅かったのが要因。中央値自体は代表値として妥当)を除き、全セルで ~10% 未満に
収まった。絶対秒はホストごとに異なる。**倍率**が可搬な結果である。

## 結果 — C 計算カーネル

固定回数の計算をして checksum(全 3 ビルドで一致)を出力するだけの自己完結
実行ファイル。時間計測はハーネス側が担う。中央値の wall time(秒)。

| ベンチマーク | gcc-O2 | gcc-O0 | rubycc | rubycc / gcc-O2 | rubycc / gcc-O0 |
|---|---|---|---|---|---|
| arrayscan(メモリ帯域・SAXPY)   | 0.418 | 1.571 | 3.100 | **7.41x** | 1.97x |
| sieve(整数 tight loop)         | 0.515 | 2.346 | 3.359 | **6.52x** | 1.43x |
| mandelbrot(浮動小数 tight loop) | 0.551 | 1.467 | 2.770 | **5.02x** | 1.89x |
| strproc(バイト単位分岐 + hash)  | 1.083 | 2.953 | 5.242 | 4.84x | 1.78x |
| treesum(再帰・ポインタ追跡)     | 1.440 | 1.575 | 1.750 | 1.22x | 1.11x |

## 結果 — C 拡張を使う Ruby ワークロード

json / msgpack gem の実 `ext/**/*.c` をコンパイラバリアントごとに 1 度ずつ
ビルドし、同一の Ruby ドライバスクリプト(`benchmark/ruby/bench_*.rb`)を各 `.so`
に対して実行。子プロセス全体の中央値 wall time(秒)。

| ベンチマーク | gcc-O2 | gcc-O0 | rubycc | rubycc / gcc-O2 | rubycc / gcc-O0 |
|---|---|---|---|---|---|
| json 2.21.1(generate + parse ループ) | 1.619 | 4.270 | 12.381 | **7.65x** | 2.90x |
| msgpack 1.8.3(pack + unpack ループ)  | 2.759 | 4.515 | 7.161 | 2.60x | 1.59x |

json は全バリアントで `JSON_DISABLE_SIMD=1` を付けてビルドしている。rubycc は
SSE 組み込み関数を持たず(Step 44: `x86intrin.h` はスタブ)、json の SIMD 経路は
probe に通ると `_mm_*` + `__builtin_cpu_supports` を無条件に使う。gcc 側も SIMD を
無効化することでコンパイル対象ソースを同一にし、表が**コンパイラのコード生成**の
差だけを反映するようにしている。実運用の `gem install json`(SIMD 有効)なら gcc は
さらに速くなる — つまり本番での rubycc/gcc 差は表の値以上であって、以下にはならない。

## 考察

### rubycc が最も劣位になる箇所と理由

**gcc -O2** に対する差が最大なのは、ロードマップの想定どおりのケースだった。

- **json — 7.65x**(全体で最大)。generator/parser の内側ループはバイト操作と
  数値整形が密な計算。SIMD を切っても、gcc -O2 のスカラなレジスタ割付とループ
  最適化は rubycc の全スピルコードを大きく引き離す。2 つの Ruby ワークロードのうち、
  Ruby VM ではなく C 拡張が実行時間を支配する側である。
- **arrayscan — 7.41x** と **sieve — 6.52x**。本体が些末なメモリ上の tight loop。
  gcc -O2 は帰納変数とアキュムレータをレジスタに保持し(arrayscan は
  ベクトル化も)、rubycc は毎反復で全値をリロード/ストアするため、演算ごとに
  メモリ往復のコストを払う。レジスタ割付が無いことの代償が最も純粋に出る例。
- **mandelbrot — 5.02x**。escape ループで 4 つの double がライブ。gcc は XMM
  レジスタに保持し、rubycc はスピルする。5 倍差の内訳は毎反復のストア/リロードの
  トラフィックである。

### 差が縮まる箇所

- **treesum — 1.22x**(最小)。再帰的な BST 構築 + 走査で、実行時間は関数呼び出し
  オーバーヘッド・分岐予測ミス・malloc ノードへのキャッシュミスを伴うポインタ
  追跡に支配される。いずれもレジスタ割付では隠せないため、rubycc が gcc -O2 に
  ほぼ並ぶ。
- **msgpack — 2.60x**。pack/unpack は実行時間の多くを Ruby VM(オブジェクト
  生成・ハッシュ走査・メソッドディスパッチ)に費やし、その部分は全ビルドで同一。
  C 拡張が wall time に占める割合が小さいためコンパイラ差が薄まる。実 Ruby
  ワークロードでは VM オーバーヘッドが体感差を縮めるという想定を裏付ける
  結果で、msgpack 経路の遅延は計算律速の json 経路のおよそ半分に留まる。

### DESIGN N2(gcc -O2 × 2〜5)に対する評価

- **gcc -O0 に対して**測ると — rubycc 自身が -O0 相当なのでこれが公平な等価比較 —
  全ケースが **1.1x〜2.9x** に収まり、N2 の許容範囲内かわずかに上に位置する。
  rubycc の非最適化コードは gcc の非最適化コードと十分競合し、spill-everything の
  分だけ gcc -O0 の軽いスタック使用に対して最大 ~2x 程度余分に払う。
- **gcc -O2 に対して**測ると、tight loop カーネル群と計算律速の json が
  **5x〜7.7x** に達し、2〜5 倍の目標を**超過**する。超過分はすべて gcc -O2 が
  加える価値(hot loop のレジスタ割付と自動ベクトル化)であり、rubycc が構造的に
  持てないものである。分岐/呼び出し/VM 律速のケース(treesum・msgpack)は
  範囲内に十分収まる。

すなわち N2 は、制御フロー律速・VM 律速のコードと -O0 基準に対しては成立する一方、
最適化が効く tight loop の -O2 比では(rubycc が省いているものの帰結として)
超過する。これは想定どおりの形であり、レジスタ割付を計画する具体的な動機になる。

### 根本要因と将来の改善余地

支配的な単一要因は**レジスタ割付が無い**こと。rubycc は全中間値をスタックスロットに
materialize し、次の使用時にリロードするため、レジスタ常駐でできる算術を
ロード/ストアの列に変えてしまう。tight loop の 5〜7.7 倍差はこの選択の直接的な
コストであり、arrayscan では gcc のベクトル化がそれに上乗せされる。計画中の
**M6 レジスタ割付**でこの大半は回収可能: ループ帰納変数・アキュムレータ・少数の
hot な double をレジスタに保持できれば、最大の差は gcc -O0 比で既に成立している
~2x 域へ収束するはずである。ベクトル化は -O2 比の別個の、後段の差として残る。

## 再現方法

```sh
BENCH_RUNS=7 ruby benchmark/run.rb        # 本ドキュメントに使ったフル実行
BENCH_ONLY=c ruby benchmark/run.rb        # C カーネルのみ
BENCH_ONLY=ruby ruby benchmark/run.rb     # json/msgpack のみ
```

ハーネスは本 Markdown を標準出力に出すと同時に、タイムスタンプ付きコピーと
全サンプルの生 JSON を `benchmark/results/` に保存する。ビルドフローとオプションは
[`benchmark/README.md`](../benchmark/README.md) を参照。他の負荷をかけていない
マシンで実行すること。Ruby ワークロードは Ruby の開発ヘッダと、json/msgpack を
一度 `gem fetch` するためのネットワークアクセスを要する。
