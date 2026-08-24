---
status: done
kind: gap
opened: 2026-08-20
closed: 2026-08-25
branch: argv-encoding-classification
pr: 98
steps: [argv-encoding-classification-1]
---

# ロケールのエンコーディングで不正なバイトを含む引数を渡すと、ファイルを読む前に落ちる

## 課題

`Driver#handle_arg` はコマンドライン引数を `case arg` の正規表現で分類する
(`lib/rubycc/driver.rb:158` が最初の正規表現 `/\A--?target=(.+)\z/m`)。**ARGV の
文字列にはロケールのエンコーディングが付く**ので、そのエンコーディングで不正なバイト列を
含む引数があると、**最初の正規表現比較で `ArgumentError` が上がる**。ファイルを 1 バイトも
読む前である。

実測(2026-08-20、ホスト、Ruby 3.4.5)。ファイル名の 1 バイトを ISO-8859-1 の `é`
(`\xE9`)にして、UTF-8 のロケールでコンパイルする:

```sh
f=$(printf '/tmp/x-\xe9.c'); : > "$f"
LANG=C.UTF-8 LC_ALL=C.UTF-8 ruby -Ilib exe/rubycc -c "$f" -o /tmp/x.o
```

```
lib/rubycc/driver.rb:158:in 'Regexp#===': invalid byte sequence in UTF-8 (ArgumentError)
	from lib/rubycc/driver.rb:158:in 'Rubycc::Driver#handle_arg'
	from lib/rubycc/driver.rb:138:in 'Rubycc::Driver#parse'
```

**master でも同じように落ちる**(`git archive HEAD` で切り出した無改変ツリーで確認)。
`default-external-encoding` の修正とは無関係な既存欠陥である。

**引き金は `default-external-encoding` と逆向きである**という点に注意すること。

| | ロケール | 引き金 |
|---|---|---|
| `default-external-encoding` | **無し**(ARGV は BINARY になるので ARGV 側は無事) | ファイルの**中身**の非 ASCII バイト |
| これ | **有り**(UTF-8) | **引数**のバイト列がそのエンコーディングで不正 |

対象はファイル名だけではない。`-I` のパス、`-D` の値、`-l` の名前など、`handle_arg` を
通る**すべての引数**が同じ経路である。

## 影響

ファイル名やディレクトリ名が UTF-8 でない環境 — 別ロケールで作られたツリーを
UTF-8 のロケールで扱う場合、外部から取得したソース、ファイル名の壊れたアーカイブを
展開した場合 — で、**診断ではなく Ruby のバックトレースが出て exit 1** になる。

頻度は `default-external-encoding` より低い(あちらは `#include <stddef.h>` を書いた
だけで落ちた)。一方で、症状の見え方は同じ「rubycc が壊れたように見える」であり、
利用者には原因を切り分ける手掛かりが無い。

## 見込み(実測ではない)

引数はパスとフラグの綴りであって文字ではないので、**ARGV も入口でバイト列として扱う**のが
筋に見える(`Driver#parse` の入口で `arg.b` にする、など)。ただしその場合、診断ヘッダの
ファイル名がバイト列になるため、**`Diagnostics.render` がバイト列で組み立てられている**こと
(`default-external-encoding` で対応済み)に依存する。副作用の確認が要る。

## 受け入れ条件

- UTF-8 のロケールで、UTF-8 として不正なバイトを含むファイル名・`-I` パス・`-D` 値を
  渡しても、Ruby のバックトレースではなく**通常の動作か rubycc の診断**になること
- 上記を検証するテストが `test/` にあり、`bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256 が変更前後で一致)

## 作業ログ

### 2026-08-20(起票)

`default-external-encoding` の修正で、診断メッセージがファイル名とソース行を連結する
経路を確かめていて見つけた。根本原因が別(ARGV の分類がロケール依存)であり、
`default-external-encoding` の受け入れ条件にも含まれないので、別課題として起票した。

## 決着

設計判断の本文は `docs/development/STEPS.md` の `argv-encoding-classification-1`。

要点だけ記す。

- **「見込み」は当たったが、規則はすでに書かれていた。** 起票時は「ARGV も入口で
  `arg.b` にするのが筋に見える」と書いた。実際に `lib/rubycc.rb` のクラスコメントが
  **ARGV を名指しで**その扱いだと定めており、`locale-dependent-file-reads-1` の時点で
  **Driver だけが従っていない**状態だった。決めたのは境界の場所だけである
- **依存すると書いた `Diagnostics.render` は手を入れずに済んだ。** 起票時の懸念どおり
  診断ヘッダにはバイト列が流れるが、`default-external-encoding-1` が既にバイト列で
  組み立てるようにしていた
- **貼り直して壊れたのは `File.expand_path` だった。** 相対のバイト列パスは
  `Dir.pwd`(プロセス由来)に繋がれるので、**作業ディレクトリ名が非 ASCII だと落ちる**。
  preprocessor の 5 か所を `absolute_path` に集約した
- **引き金が「不正なバイト」ではない欠陥も同時に消えた** — 非 ASCII の `-I` と
  非 ASCII のヘッダ名の `File.join`。本課題の再現条件からは外れていた
- **範囲外として切り出したもの** — 自前で ARGV を分類する
  [`rmake` と `rubycc-ar`](argv-encoding-sibling-clis.md)(実測済み。`rubycc-pkgconf` は
  落ちない)、および[ヘッダ探索路の同梱ディレクトリだけがバイト列でない件](system-include-path-encoding.md)
  (**master でも再現する**ことを確かめてから外した)
