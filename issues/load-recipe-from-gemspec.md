---
status: open
kind: infra
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# ロードレシピの依存を、試行ではなく gemspec から決める

## 課題

**ロードレシピを要した gem は、graphql-c_parser を除いて 8 件になった。** そのうち 7 件
(バッチ 1 の ox / kgio / raindrops、バッチ 2 の ruby-ll / oga / smarter_csv / bson_ext)は
**入口の Ruby を前提にする拡張**で、ビルドした `.so` を単独で `require` すると
`uninitialized constant` か `cannot load such file` で落ち、入口から読めば通る。
残る 1 件の oj-introspect は、`extconf.rb` 自身が `require "oj"` するので、
**ビルドの前に**依存を入れておく必要がある形である。

レシピの依存は**手で、試しながら**決めている。2026-09-13 の ruby-ll では、
`require "ll"` を試して `ast` が無いと分かり、入れて試し直して `ansi` が無いと分かった。
**どちらも gemspec の `runtime_dependencies` に最初から書いてあった**。bson_ext の `base64` は
gemspec に無く(Ruby 3.4 で既定 gem から外れたため)、試さないと分からなかった。

## 影響

レシピ 1 件ごとに、依存を見つけるための試行が数回かかる。
**台帳を 100 件にする途中で、この形はさらに増える**(2 バッチの候補 80 件のうち 8 件で、約 1 割)。

## 受け入れ条件

- 候補の gemspec の `runtime_dependencies` から、**版を固定した**依存一覧の下書きを出す手段がある
  (版はその時点の最新を解決して固定する。レシピは再現できなければ意味がない)
- 下書きを使って、上の 8 件のレシピの依存が再現できる(`base64` のような gemspec に無いものは
  差分として出る)
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 でレシピを 5 件書いたときに、試行の回数が見えた。

## 決着

(未着手)
