---
status: done
kind: gap
opened: 2026-08-25
closed: 2026-08-25
branch: system-include-path-encoding
pr: 102
steps: [system-include-path-encoding-1]
---

# 非 ASCII のパスに置いた rubycc が、見つからない非 ASCII のヘッダ名でバックトレースを出す

## 課題

**ヘッダの探索路は、同梱ヘッダのディレクトリだけがバイト列になっていない。**
`Preprocessor#preprocess` は探索路を 2 通りに持つ:

| 用途 | 変数 | 綴り |
|---|---|---|
| ファイルの同一性(`#pragma once` の鍵・`#include_next` の起点・システムヘッダ判定) | `@system_include_paths` | **バイト列**(`absolute_path` を通す) |
| **探索そのもの** | `@include_paths` | `-I` はバイト列、**同梱・libc のディレクトリはそのまま** |

`@include_paths` の要素は `File.join(dir, name)` に渡る
(`lib/rubycc/preprocess/preprocessor.rb:1262`)。`name` はソース由来なのでバイト列である
(`default-external-encoding-1` 以降)。**`dir` が非 ASCII の UTF-8 で `name` が非 ASCII の
バイト列だと、この連結が `Encoding::CompatibilityError` になる。**

同梱ヘッダのディレクトリは `__dir__` から作る(`preprocessor.rb:33` の `BUNDLED_INCLUDE_DIR`)
ので、**rubycc 自身が非 ASCII のパスに置かれていれば非 ASCII になる**。

実測(2026-08-25、ホスト、Ruby 3.4.5)。rubycc のツリーを `日本/` の下に展開し、
**存在しない**非 ASCII のヘッダを include する:

```sh
mkdir 日本 && git archive HEAD | tar -x -C 日本
printf '#include "日.h"\nint main(void){return 0;}\n' > s.c
ruby -EUTF-8 -I日本/lib 日本/exe/rubycc -c s.c -o s.o
```

```
日本/lib/rubycc/preprocess/preprocessor.rb:1257:in 'File.join': incompatible character
encodings: UTF-8 and BINARY (ASCII-8BIT) (Encoding::CompatibilityError)
	from ...:1257:in 'block in Rubycc::Preprocess::Preprocessor#search_include_paths'
```

**master で再現する。**`argv-encoding-classification` の変更を当てたツリーでも、行が
1257 から 1262 へずれるだけで同一である(同日、両方で確認)。**引数の扱いとは独立した既存欠陥**
であり、あちらの受け入れ条件にも含まれない。

## 影響

**引き金は 2 つ揃ったときだけ**である。(1) rubycc が非 ASCII のパスに置かれている
(利用者名が非 ASCII のホームディレクトリ、そこに置かれた gem のインストール先)。
(2) 非 ASCII のヘッダ名が `-I` のどのディレクトリでも見つからない。

(2) は書き間違いでも起きる。**探索は `-I` を尽くしたあとシステムディレクトリへ進む**ので、
「見つからない」経路は必ずそこを通る。つまり利用者から見れば、**綴りを間違えただけで
`file not found` の診断ではなく Ruby のバックトレースが出る**。

`rubycc` を非 ASCII のパスへ置く利用者がどれだけ居るかは測っていない。

## 受け入れ条件

- 非 ASCII のパスに置いた rubycc で、非 ASCII のヘッダ名が **(a) 解決できる場合は解決し、
  (b) 解決できない場合は rubycc の診断になる**こと(いずれも Ruby のバックトレースを出さない)
- 上記を検証するテストが `test/` にあり、`bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256 が変更前後で一致)

## 作業ログ

### 2026-08-25(起票)

`argv-encoding-classification` のレビュー中に見つけた。メインセッションと別系統の
クロスレビュー(codex)が独立に同じ箇所を指したので、最小再現を作って HEAD でも出ることを
確かめ、**今回の変更が作ったものではない**と確定させてから切り出した。

直し方の見込みは `@include_paths` の綴りを揃えることだが、**同梱ヘッダのディレクトリを
バイト列にすると、それを起点に組み立てた候補パスの綴りも変わる**ので、`absolute_path` を
通した `@system_include_paths` との比較・`resolve_include` のキャッシュ鍵まで含めて
下流を確かめる必要がある。先行 2 ステップと同じく、**直した側ではなく直したことで壊れる側**が
本題になる見込みである。

## 決着

設計判断の本文は `docs/development/STEPS.md` の `system-include-path-encoding-1`。

要点だけ記す。

- **直す位置は 3 案から選んだ。**`File.join` の呼び出し側でも、`BUNDLED_INCLUDE_DIR` などの
  定数の定義時でもなく、**`@include_paths` を組み立てるとき**にした。2 つの出所
  (呼び出し元の `-I` と `__dir__` 由来の同梱ディレクトリ)が**合流する唯一の場所**だからである
- **「引き金はテストでは作れない」は思い込みだった。**移すのに要るのは `lib/` `include/`
  `exe/` の 3 つだけで、2.3 MB・148 ファイル・27 ms。クロスレビューの指摘で測り直し、
  **引き金そのものを組み立てるテスト**を足した。コピーであってリンクではない —
  `__dir__` はリンクを解決するので、リンクでは元のパスが返って何も試さない
- **`__has_include`(`include_exists?`)にも同じ連結があった。**issue が挙げていたのは
  `search_include_paths` だけだが、`@include_paths` を共有しているので同時に直った
