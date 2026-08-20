---
status: done
kind: gap
opened: 2026-08-20
closed: 2026-08-20
branch: env-less-shebang
pr: 91
steps: [env-less-shebang-1]
---

# `/usr/bin/env` の無い環境で rubycc の実行ファイルが起動できない

## 課題

**`exe/*` の shebang が `#!/usr/bin/env ruby` なので、`/usr/bin/env` を持たない
イメージでは kernel が exec に失敗し、status 127 で終わる。**

実測(2026-08-20、`dhi.io/ruby:4` = Docker Hardened Image。Ruby 4.0.6 あり、
シェル・make・cc 無し。`/usr/bin` の中身は `awk` `gawk` `debconf*` `openssl`
`c_rehash` `gawkbug` だけで、**coreutils ごと無い**):

```
File.exist?("/usr/bin/env")                                  -> false
system("/gems/gems/rubycc-1.0.0/exe/rubycc", "--version")     -> nil (status 127)
   shebang: #!/usr/bin/env ruby
system("/gems/bin/rubycc", "--version")                       -> true ("rubycc 1.0.0")
   shebang: #!/usr/local/bin/ruby   (RubyGems が生成した binstub)
```

argv 配列で直接 spawn しても同じである。**シェルの有無とは無関係の障害**で、
落ちているのは shebang 行の解決である。

この経路を踏むのは 2 か所:

| 何が | どこで | 値 |
|---|---|---|
| conftest のコンパイラ | `lib/rubycc/mkmf_shim.rb` の `RUBYCC_EXE` / `PKGCONF_EXE` | `<gem>/exe/rubycc` |
| 拡張のビルド | `lib/rubygems_plugin.rb` の `ENV["MAKE"] = RMAKE_EXE` | `<gem>/exe/rmake` |

**`MAKE` の側はまだ表面化していない** — dhi では conftest 段(`CC`)で先に止まるためで、
そこを越えれば同じ 127 になる。

## 影響

DESIGN R5 が想定する「Ruby はあるが他は無い」環境のうち、**coreutils を持たない
ものでは rubycc がまったく起動できない**。ハードニング済みイメージ(Docker Hardened
Image、distroless 系)はこの条件に該当する。

`#!/usr/bin/env ruby` にはもう一つ潜在的な問題がある。**PATH の先頭で見つかった
`ruby` が起動する**ので、複数の Ruby がある環境では、gem をインストールした Ruby と
別の Ruby でコンパイラが動きうる。

## 受け入れ条件

- `/usr/bin/env` を持たないイメージ(`dhi.io/ruby:4` 相当)で、
  `RUBYCC=1 gem install <C 拡張の gem>` が **conftest とビルドの両方で
  rubycc の実行ファイルを起動できる**こと(status 127 が出ないことを
  `gem_make.out` と `mkmf.log` で確認する)
- 選んだ方式が、**gem をインストールした Ruby と同じ Ruby** でコンパイラを
  動かすことを確認できること(複数 Ruby のある環境で、起動された Ruby の
  `RbConfig.ruby` を突き合わせる)
- `bundle exec rake test` が 0 failures

## 対応の候補(**B を採用、2026-08-20**)

| 案 | 中身 | 代償 |
|---|---|---|
| **A** | インストール済みなら RubyGems の binstub(`Gem.bindir` の下)を使う | **環境依存の分岐**が入る(ソースチェックアウトには binstub が無い)。「環境で結果が変わる状態を作らない」という `mkmf-shell-free-conftest` の方針と噛み合わない |
| **B** | `CC = "#{RbConfig.ruby} #{RUBYCC_EXE}"` と、**常に自インタプリタ経由**で起動する | 決定的で分岐が無く、上記「別の Ruby を拾う」潜在バグも同時に消える。**ただし rmake の `Makefile#tool_programs` が `$(CC)` の先頭語を拾う**ので、先頭語が `ruby` になると in-process のツール置換(B3)が壊れる。rmake 側の対応が要る |
| **C** | 保留(最小環境を coreutils 込みに限定する) | R5 の前提を狭める |

## 作業ログ

### 2026-08-20(起票)

`mkmf-shell-free-conftest` の実装中に、その受け入れ測定の副産物として判明した。
当初は「シェルが無いから conftest が落ちる」と診断されていたが、実測すると
Ruby はメタ文字の無いコマンド文字列を直接 exec しており、**dhi で落ちていた
第一の原因はこの shebang だった**。

## 決着

(未着手)

## 決着

**B を採用した**(2026-08-20)。設計判断は `docs/development/STEPS.md` の `env-less-shebang-1`。

| 条件 | 結果 |
|---|---|
| `/usr/bin/env` の無いイメージで 127 が出ない | **達成**(`mkmf.log` / `gem_make.out` の 127 出現 0。rubycc が自前の診断まで到達) |
| gem を入れた Ruby と同じ Ruby でコンパイラが動く | **達成**(囮の `ruby` を PATH 先頭に置いて起動回数 0。3 つの Ruby で確認) |
| `rake test` 0 failures | **3340 runs / 0 failures** |
| 生成物のバイト一致 | **12 / 12** |

**A(binstub があれば使う)は却下**した — 環境で分岐する形で、`mkmf-shell-free-conftest`
で決めた「環境で結果が変わる状態を作らない」と噛み合わない。

**`PKG_CONFIG` だけは 2 語にできない**(mkmf が 1 個のファイル名として stat するため、
2 語にすると pkg-config 対応が無言で無効化される)。値はパスのままにし、**spawn の瞬間に**
インタプリタを前置する形で解決した。環境を見ないので分岐にはならない。

**rmake のツール識別は「先頭語」から「引数列の前置一致」に変えた。** 当初の正規表現に
よる推測は、外れたときに外部 spawn へ落ちるのではなく**壊れた実行**になることが
クロスレビューで判明したためである(`jruby …` / `ruby -Ilib …` / `ruby /tmp/gcc …`)。

**残した宿題**: 再帰 `$(MAKE)` は展開文字列の検査止まりで、`cd sub && $(MAKE)` が実際に
子 rmake として起動するテストが無い。2 語化で壊れやすくなった箇所なので、
テストを足す価値はある(本ステップの範囲外)。