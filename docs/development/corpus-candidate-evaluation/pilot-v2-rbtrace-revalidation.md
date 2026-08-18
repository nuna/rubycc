# rbtrace 0.5.5 再検証レポート

## 固定入力

| 項目 | 値 |
| --- | --- |
| name / version / platform | `rbtrace` / `0.5.5` / `ruby` |
| archive SHA-256 | `ed0200ffeac4251f3464412e52f36cd64c473673c2739129e0b48c568672fe68` |
| archive bytes | `522752` |
| source artifact | `artifacts/pilot-v2/2026-08-07/classification.json` |
| local Ruby | `3.3.12` (`x86_64-linux`) |
| Actions run | [31951987733](https://github.com/nuna/rubycc/actions/runs/31951987733) |
| Actions runner / Ruby | `ubuntu-24.04` / `4.0.6` |

ローカルではrepo-local `inspect-corpus-candidate` skillのstatic phaseと
`verify_corpus_candidate.rb --preflight-only`を実行した。いずれもarchive SHA、gemspecの
name/version/platform、`ext/extconf.rb`、`ext/rbtrace.c`、`Rakefile`を一致と確認した。
static artifactで確認済みの新規system headerは`sys/un.h`、gap headerは`env.h`、`msgpack.h`、
`node.h`、`st.h`、`sys/ipc.h`、`sys/msg.h`である。corpus、header、compiler、verified databaseは
変更していない。

## build/load結果

同一archiveを毎回新しいwork directoryとGEM_HOMEへ展開し、host controlとrubyccを分離した。
候補に固定recipeがなく、`tools/verify_gem_tests.rb --list`にも`rbtrace`のreview済みupstream
recipeは無かったため、documented entrypointや任意のupstream testは実行していない。

| 実行 | Ruby | compiler | 結果 | extension install | load sanity |
| --- | --- | --- | --- | --- | --- |
| local host control | 3.3.12 | host | `build_load_pass` | `pass` | `all_shared_objects_loaded` |
| local candidate | 3.3.12 | rubycc | `build_failed` (exit 1) | `failed` | `not_run` |
| Actions preflight | 4.0.6 | rubycc | `candidate` (exit 0) | `not_run` | `not_run` |
| Actions build/load | 4.0.6 | rubycc | `build_failed` (exit 1) | `failed` | `not_run` |

Actionsのpreflight reportとbuild/load reportは、次のignored artifactに保存した。

`docs/development/corpus-candidate-evaluation/artifacts/rbtrace/31951987733/`

## 失敗点

`ext/extconf.rb`は同梱の`msgpack-1.1.0.tar.gz`を展開し、次の順に実行する。

1. `./configure --disable-dependency-tracking --disable-shared --with-pic ...`
2. `make install`
3. installされたmsgpackを使ってrbtrace extensionのMakefileを生成する

configureは成功し、rubyccでもmsgpackのC sourceはcompile/linkまで進んだ。失敗したのは、
生成された`src/Makefile`の`install-libLTLIBRARIES` recipeである。recipeの要点は次の通り。

```make
list='libmsgpack.la libmsgpackc.la'; test -n "$(libdir)" || list=; list2=; for p in $$list; do if test -f $$p; then list2="$$list2 $$p"; else :; fi; done; test -z "$$list2" || {
  $(MKDIR_P) "$(DESTDIR)$(libdir)" || exit 1;
  $(LIBTOOL) --mode=install /usr/bin/install -c $$list2 "$(DESTDIR)$(libdir)";
}
```

host controlではこのrecipeを含む`make install`が成功する。rubycc/rmakeではC compile/link後に、
次の証拠が出て停止した。

```text
rmake: install-libLTLIBRARIES: recipe command failed (rubycc exited with status 1)
sh: 1: Syntax error: "fi" unexpected
sh: 1: Syntax error: "done" unexpected
/usr/bin/install: cannot stat '$list2': No such file or directory
sh: 1: Syntax error: "}" unexpected
```

candidate archiveを使わない最小の`Rubycc::Rmake::Executor`実行でも、同じrecipe形状に対して
`fi`、`done`、`}`の構文エラーとshell変数`$list2`の未展開を再現した。したがって失敗は
msgpackのC source、archive取得、Ruby version、runner toolchainではなく、shellless rmakeが
Automake/libtoolのcompound shell recipeを解釈できないことに起因する。

## 分類と判断

分類は **`rubycc_gap`（rmake build-executor gap）** とする。これはC compilerのfrontend/backend
codegen failureではないが、rubyccがRubyGemsの`MAKE`として提供するrmakeの、再現可能なbuild入力処理
の不足である。host controlが通過し、rubyccもmsgpackのconfigureおよび全C compile/linkまでは通過
しているため、`dependency_or_recipe_failure`、`environment_insufficient`、
`not_reproducible`には分類しない。

rbtraceはこの結果だけではcorpusへ追加しない。rmakeの対応は
[`rmake-automake-shell-recipes`](../../../issues/rmake-automake-shell-recipes.md)へ分離し、候補gemの
正式追加・header/compiler/database更新は別の人間レビューPRで判断する。
