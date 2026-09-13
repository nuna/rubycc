---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# `#include` に絶対パスを書くと、実在するファイルでも開けない

## 課題

**ヘッダ名が絶対パスだと、rubycc はファイルが実在しても `No such file or directory` になる。**
gcc は開く。2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った
(`/abs/ext/extconf.h` は実在するファイル):

| 書き方 | gcc | rubycc |
|---|---|---|
| `#include "/abs/ext/extconf.h"` | ok | **`error: /abs/ext/extconf.h: No such file or directory`** |
| `#include </abs/ext/extconf.h>` | ok | 同じエラー |
| `#define H "/abs/ext/extconf.h"` の後に `#include H` | ok | 同じエラー |
| `-DRUBY_EXTCONF_H="/abs/ext/extconf.h"` の後に `#include RUBY_EXTCONF_H` | ok | 同じエラー |
| `-DRUBY_EXTCONF_H="ext/extconf.h"`(相対パス)の後に `#include RUBY_EXTCONF_H` | ok | **ok** |

**原因はコードで確かめた。** `lib/rubycc/preprocess/preprocessor.rb` の `resolve_include`(1240 行)は、
引用符形式ならまず `File.join(File.dirname(includer), name)` を試し、次に検索パスの各ディレクトリと
名前をつなぐ(`search_include_paths`)。名前が絶対パスだと、どちらの候補も「ディレクトリ + 絶対パス」になり、
**名前そのものは一度も試されない**。

## 影響

**実在の gem が落ちる。** コーパス候補 `numo-narray` 0.9.2.1 は `extconf.rb` が `RUBY_EXTCONF_H` を
**絶対パス**で設定する(生成された Makefile の `RUBY_EXTCONF_H = /…/ext/numo/narray/numo/extconf.h`)。
Ruby の `ruby/internal/config.h:25` が `#include RUBY_EXTCONF_H` するので、全ファイルのコンパイルが止まる。
**対照の gcc はビルドとロードに成功する**(2026-09-13 実測、buildable-gems-batch-3)。

mkmf の既定では `RUBY_EXTCONF_H` は相対パス(`extconf.h`)なので、多くの gem は影響を受けない。

## 受け入れ条件

- 上の表の 4 つの書き方がすべて通り、ヘッダの中身が使われる(gcc と同じ値を返す)
- 相対パスの解決順(引用符形式は取り込み元の隣 → 検索パス、山括弧形式は検索パスのみ)が変わらない
- `#include_next` の起点の記録(`record_include_origin`)が、絶対パスで開いたファイルでも矛盾しない
- `numo-narray` 0.9.2.1 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-3 で、rubycc だけが落ちて対照は通った 1 件。
最初は rmake が `-DRUBY_EXTCONF_H=\"…\"` のエスケープを残している疑いを持ったが、
エスケープが残る形なら `#include expects "FILENAME" or <FILENAME>` という別のエラーになることを確かめて退けた。

## 決着

(未着手)
