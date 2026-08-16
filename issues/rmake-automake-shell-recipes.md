---
status: open
kind: gap
opened: 2026-08-16
closed:
branch:
pr:
steps:
  - rmake-automake-shell-recipes-1
  - rmake-automake-shell-recipes-2
---

# rmakeがAutomake/libtoolのshell compound recipeを実行できない

## 課題

`rbtrace 0.5.5`の同梱msgpackは、Automake/libtoolが生成した次のようなrecipeで静的ライブラリを
installする。

```make
list='libmsgpack.la libmsgpackc.la'; test -n "$(libdir)" || list=; list2=; for p in $$list; do if test -f $$p; then list2="$$list2 $$p"; else :; fi; done; test -z "$$list2" || { ...; }
```

GNU makeと`/bin/sh`では有効なrecipeだが、shellを使わない`rmake`のExecutorは`for`、`if`、
`done`、brace group、shell変数展開をこの形で扱えず、`fi`/`done`/`}`の構文エラーまたは
`$list2`の未展開を起こす。candidate archiveに依存せず再現できるrmakeの入力処理gapとして、
最小fixture、対応範囲、回帰テストを独立して定義する。

## 影響

現在のrmakeはmkmfの既知subsetをshelllessで実行する設計だが、bundled dependencyが一般的な
Automake/libtool recipeを使うgemでは、C compilerがcompile/linkできてもinstall段階で停止する。
任意の`/bin/sh` fallbackを追加すると、安全境界と再現性を失う。一方で対応範囲を定義しないまま
候補をcorpusへ追加すると、候補固有のbuild失敗とrmakeの制限を混同する。

## 受け入れ条件

- rbtrace archiveを使わない最小MakefileまたはExecutor fixtureで、GNU makeの結果とrmakeの失敗を
  同じrecipe入力から再現できる
- `for`/`if`/`done`/brace group、shell変数、libtool install呼び出しのどこを対応対象にするかを
  決め、対応する実装または明示的な停止理由を設計資料へ残す
- rmakeのshellless/R5境界を維持し、任意のshell commandや無制限の`/bin/sh` fallbackを追加しない
- 最小fixtureと既存mkmf fixtureに対する回帰テストを追加し、host makeとの意図した差分を固定する
- 対応後に固定SHAの`rbtrace 0.5.5`をhost/rubycc別GEM_HOMEで再実行し、msgpack installとrbtrace
  extensionの結果を候補reportへ追記する。成功してもcorpusを自動更新しない
- `test/corpus/gems.rb`、header、compiler、`data/verified_gems.json`はこのissueの対応で変更しない

## 実装計画

1. `rmake-automake-shell-recipes-1`: 最小fixtureを作り、GNU makeとrmakeのrecipe計画・実行結果、
   shellless設計上の対応境界をレビューする
2. `rmake-automake-shell-recipes-2`: 合意した限定構文を実装または明示的に拒否する回帰テストを追加し、
   rbtraceの固定archiveで再検証する

## 人間が行う手順

### 1. 最小fixtureの固定

1. `list`、`list2`、`for`、`if`、`done`、brace groupを含むinstall recipeだけを、一時directoryの
   Makefileへ抜き出す。gem archiveや`extconf.rb`はfixtureへコピーしない。
2. GNU makeの`make -n`と実行結果を保存し、生成物とexit statusを確認する。実行は一時directory内に
   限定し、ホストのsystem libraryやcorpusへinstallしない。
3. 同じMakefileを`RBENV_VERSION=3.3.12 rbenv exec ruby exe/rmake -j1 install`で実行し、最初の
   unsupported construct、展開前後のrecipe、exit statusを記録する。
4. `git status --short`でfixture、log、生成物がtracked領域へ混入していないことを確認する。

### 2. 対応範囲の設計

1. R5のshellless境界を維持したまま、固定されたAutomake/libtool recipeに必要な構文だけを対象にする。
   shell全体の文法を実装する、または候補gemだけの特例を追加する、という設計にはしない。
2. shell変数の代入・展開、限定されたloop/conditional、brace groupの評価順序、失敗時のexit statusを
   GNU makeと比較する。`/bin/bash -c`への丸投げは受け入れ条件を満たさない。
3. 実装が過大になる場合は、対象構文を`UnsupportedRecipeError`で安定して報告する案も含め、対応しない
   recipeを候補検査で`recipe_missing`またはbuild failureとして扱う運用を明文化する。

### 3. 実装・検証

1. 変更対象は`lib/rubycc/rmake`とrmake専用fixture/testに限定し、candidate archiveやcorpus databaseを
   変更しない。
2. 最小fixture、既存`test/fixtures/mkmf`、rmake CLIのtargeted testを実行する。host makeとrmakeの
   差分は、終了status・生成物・install pathで比較する。
3. 固定SHA `ed0200ffeac4251f3464412e52f36cd64c473673c2739129e0b48c568672fe68`のrbtraceを再検証し、
   bundled msgpack installを越えたか、次の失敗点がどこかをreportへ記録する。
4. 新しいrecipeや候補追加が必要になった場合は、rmake修正PRと混ぜず、候補ごとの独立issue/PRへ分ける。

## 作業ログ

rbtrace 0.5.5の再検証で、msgpackのconfigureおよびC compile/linkはrubyccでも成功し、Automakeの
`install-libLTLIBRARIES` recipeでのみrmakeが失敗することを確認した。このissueは候補gemの正式追加
ではなく、rmakeの最小再現と対応範囲を分離して追跡するために起票した。

## 決着

未着手。
