---
status: done
kind: gap
opened: 2026-08-20
closed: 2026-08-20
branch: mkmf-shell-free-conftest
pr: 88
steps: [mkmf-shell-free-conftest-1]
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

### 訂正(2026-08-20 — 上の診断は実測が否定した)

**上の「コマンド全体が 1 個の文字列だから `/bin/sh` の無い環境では黙って失敗する」は
誤りである。** 起票時の推測として消さずに残す。実測(`dhi.io/ruby:4`、2026-08-20):

| 呼び方 | 結果 |
|---|---|
| `system("<ruby> -e 0")`(シェルメタ文字なし) | **成功** — Ruby が空白で分割して直接 exec する |
| `system("<ruby> -e '0'")`(引用符あり) | nil / 127 |
| `system("<ruby> -e 0 > /tmp/x")`(リダイレクト) | nil / 127 |

(起票時に根拠にした `system("echo hi") -> nil` も、シェルではなく **`echo`
という実行ファイルがイメージに無い**ことによる。dhi の PATH 上に `echo` も `sh` も
1 つも無いことを確認した。)

Ruby は文字列コマンドに**シェルメタ文字が無ければシェルを使わない**。mkmf が
組み立てた json の conftest 行にはメタ文字が 1 つも無かったので、**この経路は
シェルが無くても通っていた**(シェルを剥いだ `ruby:4.0-slim` 上で、変更前の
rubycc でも `RUBYCC=1 gem install json` が成功することを確認済み)。

`RUBYCC=1 gem install json` が dhi で落ちていた本当の理由は 3 つあり、
**どれもシェルではない**:

1. **`/usr/bin/env` が無い** — `exe/rubycc` の shebang が解決できず status 127。
   → [env-less-shebang](env-less-shebang.md)
2. **`Encoding.default_external` が US-ASCII**(`LANG` 未設定)— 同梱ヘッダの
   非 ASCII バイトで `ArgumentError`。→ [default-external-encoding](default-external-encoding.md)
3. **`jemalloc/jemalloc.h` をイメージが同梱していない** — `ruby/config.h` が
   `RUBY_ALTERNATIVE_MALLOC_HEADER` を定義しているのにヘッダが無く、
   `#include "ruby.h"` が**どのコンパイラでも**通らない

**それでも文字列を argv 化する意味は残る。** メタ文字を含む conftest —
mkmf が実際に吐く `-DSYSCONFDIR=\"…\"` の形 — **だけ**がシェルを要求し、
シェルの無い環境では黙って false になって「コンパイラが無い」と誤診断されるからである。
前後比較(シェルを剥いだ `ruby:4.0-slim` 上、`$CPPFLAGS` に `-DGREETING=\"hi\"` を
足した `try_compile`):

| | 結果 |
|---|---|
| 変更前 | `RuntimeError: The compiler failed to generate an executable file.` |
| 変更後 | `true` |

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

**受け入れ環境は `dhi.io/ruby:4` ではない。** このイメージは jemalloc のヘッダを
欠くため `#include "ruby.h"` がどのコンパイラでも通らず、ゲートに使えない(上の訂正の
3 番)。代わりに **`ruby:4.0-slim` からシェルを全て取り除いたイメージ**を使う。同イメージは
`cc` / `gcc` / `make` / `ld` / `as` / `ar` を元から持たない。

- そのイメージで実行時に `File.exist?("/bin/sh") == false` を確かめたうえで
  **`RUBYCC=1 gem install json` が成功**し、`require "json"` で読み込まれる `.so` が
  **`/opt/gems/gems/json-2.21.1/lib/json/ext/parser.so`**(イメージ同梱の default gem
  `/usr/local/lib/ruby/4.0.0/x86_64-linux/json/ext/parser.so` ではない)であること
- 同イメージで、**メタ文字を含む conftest**(`$CPPFLAGS` に `-DGREETING=\"hi\"` を
  足した `try_compile`)が**変更前は失敗し、変更後は true** になること
  ── これが本変更の効果が出る唯一の形なので、証拠としてこれを取る
- 分解できない構文(パイプ・`&&`・`||`・`;`・リダイレクト・`` ` ``・`(`・`<`・
  未終端引用符・先頭の `VAR=value`・空コマンド)で**例外を上げ、mkmf.log に構文名入りの
  理由が残る**こと。**黙ってシェルに委ねる経路を残さない**
- シェルのある環境での挙動が**変わらない**こと(`bundle exec rake test` が 0 failures、
  rmake の外向き挙動は不変)

## 作業ログ

### 2026-08-20(起票)

`rmake-automake-shell-recipes` の範囲を決めるための調査中に判明した。
利用者から Docker Hardened Image を教わり、**「Ruby はあるがシェルは無い」条件で
初めて実測**できたことによる。それ以前は distroless に Ruby が無いため、
この経路自体が試されていなかった。

### 2026-08-20(実装 — mkmf-shell-free-conftest-1)

`MakeMakefile#xsystem` / `#xpopen` を `lib/rubycc/mkmf_shim.rb` の
`ShellFreeCommands` で prepend し、**文字列で来たコマンドを argv 配列にしてから
`super` に渡す**ようにした。配列はそのまま素通しする。分解器は新規に書かず、
rmake が持っていたものを `lib/rubycc/command_line.rb`(`Rubycc::CommandLine`)へ
**移設して共有**した — `Executor` は `tokenize` / `parse_line` の中で
`CommandLine::UnsupportedSyntaxError` を `UnsupportedRecipeError`(target 付き)に
包み直すだけになり、rmake の外向き挙動と文言は変わっていない。

展開の順序は「mkmf が `$(VAR)` を展開 → シェルが語分割」に合わせ、
`expand_command` を通してから分割する。1 語のコマンドは `[[prog, prog]]` の形で渡す
(`system(env, "1 個の文字列")` だと**Ruby 自身が**メタ文字を見てシェル経由か直接 exec かを
選んでしまうため、その判断を残さない)。

分解できない構文は `Rubycc::MkmfShim::ShellRequiredError` を**上げる**。false を返すと
mkmf が「コンパイラが無い」と誤診断する — 今回の誤診断そのものになる。raise の前に
mkmf 自身の `MakeMakefile::Logging.message` で **mkmf.log に構文名入りの理由を書く**。

測定:

| 測ったこと | 結果 |
|---|---|
| シェルを剥いだ `ruby:4.0-slim`(`/bin/sh` `/bin/bash` `/bin/dash` 等を削除、`cc`/`gcc`/`make`/`ld`/`as`/`ar` は元から無し)で `RUBYCC=1 gem install json` | **成功**。require で勝つのは `/opt/gems/gems/json-2.21.1/lib/json/ext/parser.so`(default gem ではない) |
| 同イメージ・**変更前**の rubycc で同じ install | **成功してしまう**(json の conftest 行にメタ文字が無いため。上の訂正を参照) |
| 同イメージで `-DGREETING=\"hi\"` 付きの `try_compile` | 変更前 `The compiler failed to generate an executable file.` → **変更後 `true`** |
| `bundle exec rake test` | **3313 runs / 13012 assertions / 0 failures / 0 errors / 41 skips** |

シェルへ委ねうる経路が `xsystem` / `xpopen` の 2 つで全部であることを再確認した。
`try_run` / `check_sizeof` が渡す `"./conftest"` もこの経路に含まれる。pkg-config 経路
(mkmf.rb:1973, 1985)は**元から配列**なので素通しである。`lib/` 側でプロセスを起こすのは
`rmake/executor.rb` と `doctor/builder.rb` だけで、どちらも argv 形式だった。

受け入れに使ったイメージの定義(`ruby:4.0-slim` からシェルを剥ぐ。ビルド文脈は
`rubycc.gem` と `json-2.21.1.gem` を置いたディレクトリ):

```dockerfile
FROM ruby:4.0-slim
COPY rubycc.gem /tmp/rubycc.gem
COPY json-2.21.1.gem /tmp/json.gem
ENV GEM_HOME=/opt/gems \
    GEM_PATH=/opt/rubycc:/opt/gems
RUN GEM_HOME=/opt/rubycc gem install --local --no-document /tmp/rubycc.gem \
    && mkdir -p /work /opt/gems && chmod 777 /work /opt/gems \
    && rm -f /bin/sh /bin/bash /bin/dash /usr/bin/sh /usr/bin/bash /usr/bin/dash
WORKDIR /work
```

### 2026-08-20(行き止まり — `dhi.io/ruby:4` は受け入れゲートに使えない)

**シェルの無い実イメージを当たったら、シェル以外の壁が 3 つ出た。** 順に潰した記録:

1. conftest は rubycc を argv で起動するようになったが、なお失敗。原因は
   `#!/usr/bin/env ruby` の shebang で、**`/usr/bin/env` がイメージに無い**(status 127)。
   → [env-less-shebang](env-less-shebang.md)
2. 調査用に `/usr/bin/env` 相当を差し込むと rubycc は起動したが、
   `scanner.rb:74 invalid byte sequence in US-ASCII` で落ちた。**`LANG` 未設定 →
   `Encoding.default_external` が US-ASCII** で、同梱ヘッダの非 ASCII バイトが読めない。
   ホストで `LANG=` にするだけで再現する。→ [default-external-encoding](default-external-encoding.md)
3. UTF-8 を与えると次は `ruby/missing.h:25: jemalloc/jemalloc.h: No such file or directory`。
   **イメージが jemalloc のヘッダを同梱していない**(`Dir.glob("/usr/**/jemalloc*")` が空)のに
   `ruby/config.h` が `RUBY_ALTERNATIVE_MALLOC_HEADER` を定義しており、
   **gcc でも `#include "ruby.h"` は通らない**。

したがって `dhi.io/ruby:4` は**現状どんなコンパイラでも C 拡張をビルドできない**ので、
受け入れ条件のイメージを差し替えた。1 と 2 は rubycc 側の欠陥なので issue に切った。

## 決着

(未決着。完了時に `docs/development/STEPS.md` の該当エントリを指す)
