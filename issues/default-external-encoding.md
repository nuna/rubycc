---
status: open
kind: gap
opened: 2026-08-20
closed:
branch:
pr:
steps: []
---

# `LANG` の無い環境で、同梱ヘッダを読んだ瞬間に落ちる(`File.read` がロケール依存)

## 課題

**rubycc はソースとヘッダを `File.read` で読む。返る文字列の encoding は
`Encoding.default_external` = ロケール依存であり、ロケールが無い環境では
US-ASCII になる。同梱ヘッダには非 ASCII バイトがあるので、そこで
`ArgumentError` が上がって落ちる。**

ホストで再現する(2026-08-20、Ruby 3.4.5、`LANG` を空にするだけ。
`-EUS-ASCII` でも同じ):

```sh
printf '#include <stddef.h>\nint main(void){return 0;}\n' > /tmp/enc.c
LANG= LC_ALL= LANGUAGE= ruby -Ilib exe/rubycc -c /tmp/enc.c -o /tmp/enc.o
```

```
lib/rubycc/preprocess/scanner.rb:74:in 'String#split': invalid byte sequence in US-ASCII (ArgumentError)

        @lines = source.split("\n", -1)
```

**診断ではなく Ruby の例外バックトレースが出て exit 1** になる(`CompileError`
ですらない)。

引き金になる非 ASCII バイトは**同梱ヘッダのコメント中の em dash**である:

| ファイル | 非 ASCII バイト数 | 最初の位置 |
|---|---|---|
| `include/stdatomic.h` | 21 | offset 94(3 行目 `_Atomic T` … `— same size, same alignment`) |
| `include/stddef.h` | 3 | offset 1397(54 行目 `as well as at run time — unlike …`) |

読んでいる箇所(いずれも encoding 指定なし):

- `lib/rubycc/preprocess/preprocessor.rb:1268`(`#include` の解決)
- `lib/rubycc/compiler.rb:310`
- `lib/rubycc/driver.rb:425`, `:445`

実環境での確認(同日):

| イメージ | `LANG` | `Encoding.default_external` |
|---|---|---|
| `dhi.io/ruby:4` | (未設定) | **US-ASCII** |
| `ruby:4.0-slim` | `C.UTF-8` | UTF-8 |

## 影響

**最小環境固有の問題ではない。** `LANG` を設定しない**あらゆる**環境 — cron、
systemd のユニット、CI のコンテナ、Docker の既定 — で、**`#include <stddef.h>`
を書いただけのソースがコンパイルできない**。

利用者側のソースが UTF-8 のコメントを含む場合(日本語コメントなど)も同じ形で落ちる。
つまり「rubycc が読むファイルはすべて」この欠陥の対象である。

## 受け入れ条件

- `LANG= LC_ALL= LANGUAGE= ruby -Ilib exe/rubycc -c` で上記 `/tmp/enc.c` が
  **gcc と同じオブジェクトを生成して成功**すること
- 非 ASCII バイトを含む**利用者ソース**(UTF-8 のコメント、および UTF-8 として
  不正なバイト列の両方)を、ロケール未設定の環境でコンパイルできること
  ── C の字句解析はバイト列に対して行うのが正しく、コメントの中身は
  **バイト列として読み飛ばせれば足りる**
- 上記を検証するテストが `test/` にあり、`bundle exec rake test` が 0 failures

## 作業ログ

### 2026-08-20(起票)

`mkmf-shell-free-conftest` の受け入れ測定中、`dhi.io/ruby:4`(`LANG` 未設定)で
conftest が rubycc の起動に成功した直後に、この例外で落ちて判明した。
その場では最小環境固有に見えたが、**ホストで `LANG` を空にするだけで再現した**ので
環境の問題ではない。

## 決着

(未着手)
