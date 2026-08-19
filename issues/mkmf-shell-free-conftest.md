---
status: open
kind: gap
opened: 2026-08-20
closed:
branch:
pr:
steps: []
---

# シェルの無い環境で conftest が通らない — mkmf の実行経路を argv 化する

## 課題

**DESIGN R5 が想定する環境で、C 拡張のビルドが extconf 段で止まる。**

実測(2026-08-20、`dhi.io/ruby:4` = Docker Hardened Image。**Ruby 4.0.6 あり、
シェル・make・cc すべて無し**。イメージを export して確認済み):

| 段 | 結果 |
|---|---|
| rubycc の導入 | 成功 |
| rubygems プラグインの起動 | 成功(`MAKE` が rmake に差し替わる) |
| `RUBYCC=1 gem install json` | **失敗** — extconf の conftest |

**落ちているのは rubycc でも rmake でもない。** `mkmf.log` を読むと、mkmf は正しく
rubycc を呼んでいる:

```
"/gems/gems/rubycc-1.0.0/exe/rubycc -o conftest -I/usr/local/include/... conftest.c ... -lc"
```

しかし**コマンド全体が 1 個の文字列**で、mkmf はこれを `system()` に渡す。
このイメージでは:

```
system("echo hi")   -> nil     # シェル形式は黙って失敗する
```

`/bin/sh` が無いため文字列形式の `system` が失敗し、**エラー文言も残らない**
(`mkmf.log` は 11 行で終わる)。mkmf はこれを「コンパイラが無い」と誤診断し、
`You have to install development tools first` を出す。

**rmake の shell-less 設計は、この障壁の手前で無効化されている** — Automake レシピの
対応範囲([rmake-automake-shell-recipes](rmake-automake-shell-recipes.md))を
どう決めても、この環境では extconf を越えられない。

## 影響

R5 は「ミニマム環境には as / ld / ar / make / sh も存在しない」ことを前提に、
ツールチェイン全体を Almost Pure Ruby で提供すると定めている。**その前提の環境で、
実際には C 拡張をビルドできない。**

これまで気付かれなかったのは、`examples/distroless/Dockerfile` が
**コンパイルを `/bin/sh` のある builder 段で行う**構成だったためである
(冒頭コメントが「最終段を distroless *相当の姿勢* にする」と断っている)。
**シェルの無い環境で rmake が走った実績が無かった。**

## 対応の方向(実装前に測ること)

mkmf.rb は Ruby 同梱なので**書き換えられない**。しかし `lib/rubycc/mkmf_shim.rb` は
既に同じプロセス内で `RbConfig` のツールチェイン鍵を差し替えており、**`MakeMakefile`
にメソッドを prepend する余地がある**。現状の shim は「**何を呼ぶか**」だけを差し替え、
「**どう呼ぶか**」は手つかずである。

文字列をシェルに渡す代わりに argv へ分解して直接 spawn する処理は、
**rmake が Makefile のレシピに対して既に実装している**(`rmake/executor.rb` の
引用を尊重した語分割・`VAR=value` 前置・リダイレクト解釈)。新規に書くのではなく、
**既にある部品を conftest 経路にも使う**形になる。

**着手前に測るべきこと**:

1. mkmf が組み立てる文字列が、rmake の分割器で扱える範囲に収まるか。
   今回のログは `LD_LIBRARY_PATH=... "コマンド全体"` の形で、**環境変数の前置と
   全体の引用**が入っている。rmake が扱うレシピと似ているが同一ではない
2. conftest 以外にシェルへ委ねる経路があるか(`xpopen` = `try_run` の出力取得、
   `have_library` ほか)

### 2026-08-20(調査 — シェルへ委ねる経路は 2 つ、分岐は入力の形)

シェルへ委ねうる mkmf の経路は **2 つだけ**だった(`dhi.io/ruby:4` の
`/usr/local/lib/ruby/4.0.0/mkmf.rb` を読んで確認):

| メソッド | 位置 | 用途 |
|---|---|---|
| `MakeMakefile#xsystem` | mkmf.rb:439 | conftest のコンパイル・リンク |
| `MakeMakefile#xpopen` | mkmf.rb:458 | 出力を読む形(`try_run` ほか) |

どちらも `expand_command` を通してから `IO.popen(env, command)` / `system` を呼ぶ。
**`expand_command` は入力の形をそのまま保つ** — 配列で渡されれば配列(シェル不要)、
文字列で渡されれば文字列(シェル経由)。`$(VAR)` の展開をするだけで、
分割も結合もしない。

**つまりシェルに委ねるかどうかは、mkmf を呼ぶ側が何を渡したかで決まる。**
今回落ちた conftest は文字列で組み立てられていた(`RbConfig` のテンプレートを
`sprintf` で埋める形)。

この事実は shim の作りに直結する:

- 上書きすべきは **2 メソッドだけ**で、面積は小さい
- 上書きの中身は「**文字列で来たものを argv へ分解して spawn し直す**」で、
  分解器は rmake が既に持っている
- **配列で来たものはそのまま通してよい**(既にシェルを経由しない)

## 受け入れ条件

- `dhi.io/ruby:4`(またはシェルの無い同等イメージ)で
  **`RUBYCC=1 gem install json` が成功**し、インストールされた `.so` が
  **require で勝つ**こと(イメージ同梱の default gem ではないことを確認する)
- シェルのある環境での挙動が**変わらない**こと(コーパスの合格率が下がらない)
- 上記 2 点の測定結果を記録する。**扱えない構文が残るなら、それを明示して断る**
  (黙ってシェルに委ねない)
- 全スイートが 0 failures

## 作業ログ

### 2026-08-20(起票)

`rmake-automake-shell-recipes` の範囲を決めるための調査中に判明した。
利用者から Docker Hardened Image を教わり、**「Ruby はあるがシェルは無い」条件で
初めて実測**できたことによる。それ以前は distroless に Ruby が無いため、
この経路自体が試されていなかった。

## 決着

(未着手)
