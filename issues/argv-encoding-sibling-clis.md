---
status: in-progress
kind: gap
opened: 2026-08-25
closed:
branch: argv-encoding-sibling-clis
pr:
steps: [argv-encoding-sibling-clis-1]
---

# `rmake` と `rubycc-ar` の引数分類が、`rubycc` と同じ形でロケール依存のまま残っている

## 課題

`rubycc` 本体の引数分類は `argv-encoding-classification-1` でバイト列になったが、
**自前で ARGV を分類する残り 2 つのコマンドは直っていない**。どちらも
`lib/rubycc.rb` が定める「プロセスから入る文字列は境界で `String#b` に貼り直す」に
従っておらず、ロケールのエンコーディングで不正なバイトを含む引数で Ruby の
バックトレースが出る。

実測(2026-08-25、ホスト、Ruby 3.4.5、`ruby -EUTF-8`。引数に `\xE9` を含めた):

| コマンド | 結果 |
|---|---|
| `exe/rmake` | **落ちる**。`lib/rubycc/rmake/cli.rb:93` の `Regexp#===` で `ArgumentError`。**goal 名(`rmake <bad>`)と `VAR=value` 上書きの両方**。`-f <bad>` は診断で済む |
| `exe/rubycc-ar` | **落ちる**。`exe/rubycc-ar:46` の `String#sub(/\A-/, "")`(先頭のフラグ語)で `ArgumentError`。`t` / `rcs` はアーカイブ名・メンバ名が不正バイトでも通る |
| `exe/rubycc-pkgconf` | **落ちない**。分類が `start_with?("--")` と literal の `case` だけで、生の引数に正規表現を当てない |
| `exe/rubycc-doctor` | バックトレースは出るが、発生箇所は Ruby の `optparse.rb:562` の `Regexp#match` であって rubycc のコードではない(`--gemfile <bad>`) |

```
$ ruby -EUTF-8 -Ilib exe/rmake "$(printf 'g\xe9')"
lib/rubycc/rmake/cli.rb:93:in 'Regexp#===': invalid byte sequence in UTF-8 (ArgumentError)
	from lib/rubycc/rmake/cli.rb:93:in 'Rubycc::Rmake::CLI#parse_argv'
```

## 影響

**`rmake` の方が `rubycc` 本体より踏みやすい**。`rmake` は mkmf が生成した Makefile を
実行する経路であり、goal 名とマクロ上書きは**利用者が打つのではなく Makefile と
`gem install` が渡す**。ファイル名の壊れたアーカイブを展開した gem では、
利用者が引数を打っていないのにバックトレースが出ることになる。

`rubycc-ar` の方は先頭のフラグ語(`rcs` 等)が不正バイトである場合に限られるので、
実際に踏む筋は薄い。

## 受け入れ条件

- `rmake` の goal 名・`VAR=value` 上書き・`-f` に不正なバイトを含む引数を渡しても、
  Ruby のバックトレースではなく**通常の動作か診断**になること
- `rubycc-ar` の先頭フラグ語についても同じこと
- 上記を検証するテストが `test/` にあり、`bundle exec rake test` が 0 failures
- **`rmake` は非 ASCII の goal 名が Makefile 側の綴りと一致し続けること**を検査すること。
  `locale-dependent-file-reads-1` は、ここで**例外ではなく無出力・exit 0**という
  沈黙の退行を入れかけている(経緯は `docs/development/STEPS.md` の該当ステップ)

## 作業ログ

### 2026-08-25(起票)

`argv-encoding-classification` の実装時に、範囲外として実測だけ行った。
`rubycc` 本体の受け入れ条件に含まれず、それぞれ別のテストが要るので切り出した。
直し方は本体と同じ(境界で `.b`)だが、**`rmake` は引数を Makefile の内容と突き合わせる**
ので、貼り直しで壊れる側の確認は本体より広い。

## 決着

設計判断の本文は `docs/development/STEPS.md` の `argv-encoding-sibling-clis-1`。

要点だけ記す。

- **起票時の表は 2 か所足りなかった。**「`-f <bad>` は診断で済む」は**分離綴りだけ**で、
  joined の `-fM<不正バイト>` は落ちる。**bare `-j` の次の語**も別の行(`cli.rb:98`)で落ちる。
  1 つのメソッドの中に同じ原因が 3 か所あった
- **貼り直して壊れたのは 2 か所。**`-f` の相対パスを `Dir.pwd` に繋ぐ `File.expand_path`
  (前ステップと同じ形)と、アーカイブのメンバ名の突き合わせ
- **`ar r` の重複追加は master の時点で既に起きていた。**`ArReader` が短い名前を
  バイト列、長い名前を UTF-8 で返す非対称のせいで、**短い**非 ASCII 名は
  UTF-8 の ARGV と一致していなかった。実測で確認(`s日.o` が 2 行になる)。
  つまり貼り直しは短い名前を直し長い名前を壊す関係で、両側を揃えて初めて両方通る
- **範囲外** — リーダの非対称そのものはリンカも消費するため
  [ar-reader-name-encoding](ar-reader-name-encoding.md) へ切り出した。
  `rubycc-pkgconf` は落ちず、`rubycc-doctor` のバックトレースは Ruby の `optparse.rb`
