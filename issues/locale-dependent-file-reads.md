---
status: done
kind: gap
opened: 2026-08-20
closed: 2026-08-25
branch: locale-dependent-file-reads
pr: 95
steps: [locale-dependent-file-reads-1]
---

# C ソース以外の `File.read` が 4 か所残っており、ロケールの無い環境で落ちる

## 課題

`default-external-encoding` は **C のソースとヘッダ**の読み出しをバイト列に直した
(`File.binread` + Scanner がバイト列を走査する)。**rubycc が読むテキストファイルは
それだけではない**。次の 4 か所は `File.read` のまま残っており、返る文字列の encoding は
`Encoding.default_external` = ロケール依存である。

| 読み出し | 対象ファイル |
|---|---|
| `lib/rubycc/pkgconf/resolver.rb:37` | `.pc`(pkg-config のメタデータ) |
| `lib/rubycc/rmake/cli.rb:52` | `Makefile` |
| `lib/rubycc/doctor/gemfile.rb:38`, `:40` | `Gemfile.lock` / `Gemfile` |
| `lib/rubycc/link/library_resolver.rb:309` | リンカスクリプト(`libc.so` 等) |

**2 か所は実測で落ちる**(2026-08-20、ホスト、Ruby 3.4.5、`LANG= LC_ALL= LANGUAGE=`)。

`.pc` の `Description` に `\xC2\xA9`(U+00A9)を含めて解決させた場合:

```
Encoding::CompatibilityError: invalid byte sequence in US-ASCII
  lib/rubycc/pkgconf/parser.rb:47:in 'String#strip'
  lib/rubycc/pkgconf/parser.rb:47:in 'Rubycc::Pkgconf::Parser#parse_line'
```

`Gemfile` の 1 行目に日本語のコメントを置いて `rubycc-doctor` の読み出しを走らせた場合:

```
ArgumentError: invalid byte sequence in US-ASCII
  lib/rubycc/doctor/gemfile.rb:103:in 'String#sub'
  lib/rubycc/doctor/gemfile.rb:103:in 'block in Rubycc::Doctor::Gemfile.parse_gemfile'
```

残り 2 か所(`Makefile`、リンカスクリプト)は**同じ形だが個別には測っていない**。

## 影響

**非 ASCII は例外ではなく通常である。**

- `.pc` の `Name` / `Description` に非 ASCII が入っているものは実在する
  (著作権記号、開発者名のアクセント記号)。`pkg_config()` を使う gem のビルドが対象
- **`Gemfile` は UTF-8 のコメント入りが普通**である(日本語のコメントを含む Gemfile は珍しくない)。
  `rubycc-doctor` は導入判断のために最初に叩かれるコマンドなので、そこで Ruby の
  バックトレースが出るのは体裁として最も悪い

`default-external-encoding` と同じく、**`LANG` を設定しないあらゆる環境**(cron、
systemd のユニット、CI のコンテナ、Docker の既定)が対象で、最小環境固有の問題ではない。

## 見込み(実測ではない)

4 か所のパーサが使う正規表現は**いずれも ASCII のみで書かれている**ように見えるので、
`File.binread` に替えれば ASCII-8BIT 文字列のままでも動く見込みである。
**これは読んだ上での見込みであって、実測ではない。**
`default-external-encoding` では「読み出しだけでは足りず、下流(列の数え方・トークンの
切り出し・診断の組み立て)にも変更が要った」ので、ここでも下流を確かめてから直すこと。

## 受け入れ条件

- `LANG= LC_ALL= LANGUAGE=` の環境で、次のいずれも Ruby の例外を出さずに処理できること
  - `Description` に非 ASCII を含む `.pc` の `--cflags` / `--libs` 解決
  - UTF-8 のコメントを含む `Gemfile` / `Gemfile.lock` の `rubycc-doctor` 読み出し
  - UTF-8 のコメントを含む `Makefile` の `rmake` 実行
  - 非 ASCII を含むリンカスクリプトの解決
- 上記を検証するテストが `test/` にあり、`bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256 が変更前後で一致)

## 作業ログ

### 2026-08-20(起票)

`default-external-encoding` の実装中に、同種の読み出しが他にも残っていることに気づいて
調査した。上の 2 件の実測はそのとき取ったもの。**その場では直さず**、規約どおり別課題として
起票した(C ソースの読み出しとは対象ファイルもパーサも別で、1 PR の粒度が変わるため)。

## 決着

設計判断の本文は `docs/development/STEPS.md` の `locale-dependent-file-reads-1`。

要点だけ記す。

- **挙げた 4 か所に加えて 5 件目があった** — `doctor/verified_gems.rb` が同梱の
  `data/verified_gems.json` を `File.read` していた。**Gemfile の内容と無関係に、
  ロケールの無い環境の `rubycc-doctor` は必ずここで死んでいた**。JSON は UTF-8 と
  規格が決めている(RFC 8259 §8.1)ので、ここだけはバイト列にせず encoding を明示した
- **「見込み」は外れた。** 起票時は「パーサの正規表現は ASCII だからバイト列でも動く」と
  書いた。パーサの内側ではそのとおりだったが、**外側で新しく壊れた** —
  BINARY の非 ASCII は UTF-8 と連結できないので、パス結合・変数展開・`Dir.children` の
  戻り・`-l` 名の 5 か所に修正が要った
- **境界は `File.join` だけではなかった。** 非 ASCII を含む文字列はエンコーディングが
  違えば `==` も `eql?` も `hash` も一致しない。これで **`rmake <非 ASCII の target>` が
  無出力・exit 0 で終わる退行**が入りかけていた(HEAD では動く)。
  例外ではなく沈黙なので、クロスレビューで指摘されるまで気づいていなかった
- **範囲外として残したもの** — `doctor/builder.rb` の `Open3.capture2e` は戻り値が
  ロケール依存のままである。用途が `.lines` / `.chomp` / `.reject` / `.join` だけで
  例外にならないことを実測した。ファイルの読み出しではないので本課題の対象ではないが、
  **用途に依存した安全性**である
