# rubycc ベンチマーク

2 種類のベンチマークを収める:

- **実行速度**(`run.rb`、下記)— rubycc が生成したコードの速度を gcc と比較(要件 N2)。
- **コンパイルスループット**(`throughput.rb`)— コンパイラ自身の速度を
  「前処理後行数/秒」で計測(要件 N1: YJIT 有効で 20,000 行/秒)。
  `rake bench:throughput` で実行。実 gem(json / msgpack / bigdecimal)を
  ステージし、**mkmf shim 経由で extconf を実行**(`RUBYCC=1 gem install` と同じ
  conftest 判定で -D セットを得る — gcc で extconf すると rubycc の conftest では
  無効になるヘッダ(例: bigdecimal の `HAVE_RUBY_ATOMIC_H`)が有効化され、実
  インストールではコンパイルしないソースを測ってしまう)。各 .c をインプロセスで
  ウォームアップ 1 回 + `BENCH_RUNS`(既定 3)回フルコンパイルし、中央値から
  行/秒を出す。ステージ内訳(preprocess / tokenize / parse / IR)は 1 回計測の
  参考値。「前処理後行数」= phase-4 出力にトークンを 1 つ以上産んだ一意な
  (ファイル, 物理行) 対の数。各ファイルは同じ include パス・`-D` 集合・
  `-fPIC` で `gcc -O0` でも 1 回コンパイルし(同じ「前処理後行数」を分母に
  使うので rubycc との比率がそのまま読める)、N1 の 20,000 行/秒目標に外部
  基準を与える。`gcc` はプロセス起動込みの wall time、rubycc はインプロセス
  (ウォーム)計測なので両者は非対称条件であり、比率のみが参考値。gcc が
  `PATH` に無い、または `BENCH_GCC=0` の場合はスキップされる。結果は
  `results/throughput-<stamp>.{md,json}`。

## rubycc vs gcc 実行速度ベンチマーク(run.rb)

**rubycc** が生成したネイティブコードの実行速度を、同じプログラムを
**gcc -O2** / **gcc -O0** でビルドしたものと比較する。rubycc は最適化を行わない
-O0 相当のコード(レジスタ割付なし・全値スピル)を出すため、本スイートはその差を
*定量化*することを目的とし、rubycc が明確に遅いケースも含める。DESIGN 要件 N2 は
「gcc -O2 比 2〜5 倍遅を許容」を掲げており、その許容範囲に対する評価と結果は
[`../docs/BENCHMARKS.md`](../docs/BENCHMARKS.md) に記録している。

本スイートは `rake test` には**含めない**(数分かかり、gcc とネットワークに
依存するため)。

## 構成

- `c/` — 自己完結の C 計算カーネル(各 1 ファイル)。**固定回数**の計算をして
  checksum のみを出力し、自分自身の時間は計測しない(計測はハーネスが担う)。
  - `sieve.c` — 整数 tight loop(エラトステネスの篩)。
  - `mandelbrot.c` — 倍精度 tight loop(escape-time、libm 不使用)。
  - `arrayscan.c` — L2 に収まらない配列への SAXPY(メモリ帯域)。
  - `treesum.c` — 再帰 + ポインタ追跡(BST 構築/走査)。呼び出し律速。
  - `strproc.c` — バイト単位の分岐 + FNV ハッシュ。制御フロー律速。
- `ruby/` — C 拡張を駆動する Ruby プログラム。
  - `bench_json.rb` — 中規模文書の generate + parse をループ。
  - `bench_msgpack.rb` — 中規模構造の pack + unpack をループ。
- `run.rb` — ハーネス(Pure Ruby)。
- `results/` — 環境情報付きで保存される Markdown + JSON レポート。

## 実行

```sh
ruby benchmark/run.rb                 # 全体。計測 5 回 + ウォームアップ 1 回
BENCH_RUNS=7 ruby benchmark/run.rb    # サンプルを増やす(中央値が安定)
BENCH_ONLY=c ruby benchmark/run.rb    # C カーネルのみ
BENCH_ONLY=ruby ruby benchmark/run.rb # json/msgpack のみ
BENCH_WORK=/path ruby benchmark/run.rb# gem 素材とビルド済み .so の置き場
```

ハーネスは各ワークロードについて次を行う:

1. `gcc -O2` / `gcc -O0` / `rubycc` の 3 通りでビルド。C 拡張は
   `tools/m2_acceptance.rb` のフローを踏襲する — `extconf.rb` を実行し、生成
   `Makefile` から `-D` 定義を抽出し、同じソースを各コンパイラでバリアント別の
   `.so` にコンパイルする。json は全バリアントで `JSON_DISABLE_SIMD=1` を付ける
   (rubycc は SSE 組み込み関数を持たない。gcc 側も SIMD を切ることでソースを
   同一に保ち、表がアルゴリズム差ではなくコンパイラのコード生成を反映するように
   する — SIMD 有効の素の gcc gem ビルドはさらに速い)。
2. 各ビルドをまず計測しない**ウォームアップ**として 1 回実行し、続いて
   `BENCH_RUNS` 回計測して**中央値** wall time(`Process::CLOCK_MONOTONIC`)・
   最小値・分散 `(max-min)/median` を記録する。いずれかのバリアントで分散が
   20% を超えた行はレポートで `*` を付ける。

Ruby ワークロードは Ruby の開発ヘッダとネットワークアクセス(json/msgpack を
一度 work dir へ `gem fetch`)を要する。C カーネルは gcc と rubycc のみで動く。

## 記録済み結果の再現

他の負荷をかけていない**アイドル状態のマシン**で実行すること(結果は wall time)。
`docs/BENCHMARKS.md` の数値には `BENCH_RUNS=7` を使用した。各実行は
`results/bench-<stamp>.md` と `.json` をタイムスタンプ付きで残すので差分を取れる。
