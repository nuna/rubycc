---
status: in-progress
kind: feature
opened: 2026-08-13
closed:
branch: spill-traffic-cleanup
pr: 48, 49
steps: [spill-traffic-cleanup-1, spill-traffic-cleanup-2]
---

# 書いた直後に読み戻すのをやめ、gcc -O0 に並ぶ

## 課題

rubycc は **gcc -O0 より 1.07〜1.97 倍遅い**。どちらも spill-everything(全中間値をスタックに
materialize する)なので、**この差はレジスタ割付の有無では説明できない**。

実測(2026-08-13、glibc x86-64 / Ruby 3.4.5、`CLOCK_MONOTONIC` の 5 回中央値):

| カーネル | gcc -O0 | rubycc | rubycc / O0 |
|---|---|---|---|
| arrayscan | 1.603 | 3.156 | **1.97x** |
| mandelbrot | 1.487 | 2.800 | **1.88x** |
| strproc | 3.135 | 5.394 | 1.72x |
| sieve | 2.430 | 3.411 | 1.40x |
| treesum | 1.642 | 1.763 | 1.07x |

同じソース(`b[i] += scale * a[i]` のループ)を両者でコンパイルすると、
**gcc -O0 が 41 命令、rubycc が 76 命令**(1.85 倍)。逆アセンブルで見える差は 3 種類ある。

| 現象 | gcc -O0 | rubycc |
|---|---|---|
| 添字 × 4 のスケール | `lea 0x0(,%rax,4),%rdx` = **1 命令** | 定数 4 をスロットへ書き→読み→`imul` = **5 命令** |
| 直後の読み戻し | 途中結果をレジスタのまま次へ渡す | `mov %rax,-0x50(%rbp)` の**次の命令**が `mov -0x50(%rbp),%rax` |
| 定数の materialize | `movl $0x0,-0x4(%rbp)` = 1 命令 | レジスタへ→スロットへ→読み戻し = 3 命令 |

## 影響

N2(gcc -O2 比 2〜5 倍)が条件付き達成に留まる原因の一部である。**レジスタ割付より手前**の、
生存区間解析を必要としない局所変換で取れる分がここにある。

割付を先に入れてもこの無駄は残る(割付はスロットをレジスタに置き換えるが、
**そもそも不要な store/load を消しはしない**)。順序として先にこちらを片付ける。

## 受け入れ条件

- **gcc -O0 比が全カーネルで 1.2 倍以内**(現状 1.07〜1.97 倍)。`benchmark/run.rb` の
  5 カーネルすべてで測る
- **コーパスの合格率が下がらない**(31/34 = 91.2%)。バージョニング方針が
  「合格率の回帰は破壊的変更」と定めている
- 全スイートが 0 failures。**x86-64 と AArch64 の両方**で、差分実行テストが gcc と一致する
- **決定的ビルド(N4)を壊さない**
- 変更前後の実測を `docs/development/BENCHMARKS.md` に追記する(ペア計測)

## 作業ログ

### 2026-08-13(着手前の測定)

`register-allocation` の着手前調査から分岐した課題である。**測ってみたら、割付より先に
やるべきことがあった。**

**ベクトル化は主因ではなかった。** gcc の `-O1 → -O2` の比は全カーネルで **1.01〜1.14x**
しかない。`benchmark/c/arrayscan.c` のコメントは「gcc -O2 がベクトル化するので、この差は
ベクトル化と割付の両方を測る」と書いていたが、**実測がそれを否定した**(コメントは
推測で書かれ、測られていなかった)。修正する。

割付そのものの効果(gcc の `-O0 → -O1`)は **1.08〜4.62x** で、sieve と arrayscan で大きい。
これは第 2 段([register-allocation](register-allocation.md))で取りに行く。

**測定は単調時計で行うこと。** 最初 `date`(壁時計)で測ったところ `treesum` が
**-0.063 秒**という負の値になった。このホストは `systemd-timesyncd` が時計を step させる
(pg の検証時に測定済み)。

### 2026-08-13(第 1 段: IR 層 — `spill-traffic-cleanup-1`)

作業を 2 段に分けた。**IR 層**(このステップ)と**バックエンド層**
(`spill-traffic-cleanup-2`、別ブランチ `spill-traffic-cleanup-backend`)である。
IR 層で入れたのは生成器とバックエンドの間に置く `IR::Simplify` の 3 変換 —
単一使用コピーの前送り・添字融合(新 IR 命令 `:scaled_add`)・死結果の除去。

**速度の実測は第 2 段と合わせて 1 回で取る。** 片方だけの数字は、もう片方が入った後の姿を
説明しない。第 1 段だけで測って「ここまでで何倍」と書くと、あとで意味の無い比較が
記録に残るためである。設計判断は `docs/development/STEPS.md` の
`spill-traffic-cleanup-1` にある。

### 2026-08-13(第 2 段: バックエンド層 — `spill-traffic-cleanup-2`)

`Backend::SlotResidency` を両バックエンドに入れ、直後の読み戻し省略・第 2 オペランドの
スロット直接参照・単一使用一時値のストア省略を実装した。安全条件は
**「記録してから 1 バイトも emit されていない間だけ信じる」**という粗いもので、
例外は `:label`(合流点)1 つだけ。設計判断は `docs/development/STEPS.md` の
`spill-traffic-cleanup-2`。

**PR は 2 本**。#48(第 1 段 / ブランチ `spill-traffic-cleanup`)と
#49(第 2 段 / ブランチ `spill-traffic-cleanup-backend`、base は #48 の積み PR)。
**master に入った時点で `status: done` と `closed:` を埋める。**

## 決着

**受け入れ条件は 5 つとも満たした**(2026-08-13、glibc x86-64 / Ruby 3.4.5)。

| 条件 | 結果 |
|---|---|
| gcc -O0 比が全カーネルで 1.2 倍以内 | **0.67〜1.02x**(5/5。うち 3 件は -O0 より速い) |
| 全スイート 0 failures | **3160 runs / 11156 assertions / 0 failures / 0 errors / 41 skips** |
| x86-64 と AArch64 の差分実行が gcc と一致 | `test_examples.rb` ほか AArch64 実行系を含めて 0 failures |
| 決定的ビルド(N4)を壊さない | `test_deterministic_build.rb` が 0 failures |
| 前後の実測を BENCHMARKS.md に追記 | 追記済み(ペア計測・単調時計) |

**副次的に DESIGN N2(gcc -O2 比 2〜5 倍)が C カーネル 5 件すべてで成立した**
(4.84〜7.41x → 1.08〜3.24x)。設計判断の本体は `docs/development/STEPS.md` の
`spill-traffic-cleanup-1` / `-2`。

**コーパス合格率(31/34)は未再測**である。gem 本体テストの実走を伴う重い検証で、
このステップは C 機能を足しておらず全スイートと gcc 差分が通っているため、
**第 2 段(レジスタ割付)の受け入れとまとめて 1 回測る**。
[register-allocation](register-allocation.md) に申し送った。
