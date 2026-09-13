---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-3
pr: 150
steps: [rmake-suffix-rule-generated-source-1]
---

# rmake が、別の規則で生成されるソースを経由して接尾辞規則をつなげない

## 課題

**`x.o` を接尾辞規則(`.c.o`)で作るとき、その元の `x.c` が別の明示規則で生成されるものだと、rmake は
`x.c` も `x.o` も作らずに進み、リンクで失敗する。** GNU make は `x.c` → `x.o` → `prog` と作る。
2026-09-14 にこのホストで、次の Makefile を使って測った(`gen/src.txt` は中身のある C ソース):

```make
all: prog

prog: x.o
	cc -o prog x.o

x.c: gen/src.txt
	cp gen/src.txt x.c

.SUFFIXES: .c .o
.c.o:
	cc -c -o $@ $<
```

| | `x.c` | `x.o` | `prog` |
|---|---|---|---|
| GNU make | 作られる | 作られる | 作られる |
| rmake | **作られない** | **作られない** | `/usr/bin/ld: cannot find x.o` で失敗 |

**rmake は `x.o` を作れないことを報告せずに先へ進む。** 失敗が表に出るのはリンクの段で、原因の場所
(`x.o` に使える規則が無いと判断したこと)とは離れている。

同じ日に、前提条件にワイルドカード(`gen/*.rb`)を含む生成規則を単独で作らせる形も測ったが、そちらは rmake でも
作られた。**壊れているのは、生成規則と接尾辞規則のつながり**である。

## 影響

**実在の gem が落ちる。** コーパス候補 `numo-narray` 0.9.2.1 の Makefile は、`t_bit.c` などの型ごとのソースを
`t_bit.c: gen/def/bit.rb $(DEPENDS)` の規則で生成し(レシピは `ruby $(COGEN) -l -o $@ ...`)、`t_bit.o` は
mkmf の `.c.o` で作る。rmake は `t_*.c` を 1 つも生成せず、`narray.so` のリンクで
`No such file or directory @ rb_sysopen - t_bit.o` になる(2026-09-14 実測、ledger-after-wave-1-2)。
**対照(GNU make)はビルドとロードに成功する**(buildable-gems-batch-3 の実測)。

numo-narray は、[`include-absolute-path`](include-absolute-path.md)(AO)と
[`unprototyped-function-pointer-compat`](unprototyped-function-pointer-compat.md)(BD)を直した後に、
この 3 つ目の不足で止まった。

## 受け入れ条件

- 上の Makefile で rmake が `x.c` → `x.o` → `prog` の順に作る(GNU make と同じ)
- 作れない前提条件があるときは、rmake がその場で「`x.o` を作る規則が無い」と報告して止まる
  (リンクまで黙って進まない)。GNU make の文言と動作を先に測る
- `numo-narray` 0.9.2.1 が rubycc(rmake)でビルドできる
- `rake test` が 0 failures

## 着手前に確かめること

- [`rmake-automake-shell-recipes`](rmake-automake-shell-recipes.md)(done)と
  [`rmake-gnu-make-conditionals`](rmake-gnu-make-conditionals.md)(AS)が決めた・決めていない rmake の範囲を読み、
  矛盾しない方針にすること

## 作業ログ

### 2026-09-14(起票)

2 回目の修正(#148)の後に numo-narray を測り直して見つけた。最初は前提条件のワイルドカードを疑い、
最小再現で退けてから、接尾辞規則のつながりに辿り着いた。

### 2026-09-14(実装)

推論規則のソースは、存在するものを先に探し、無ければ「作れる」もの(明示規則のターゲット、または別の推論規則で
再帰的に作れるもの)を使うようにした。作れない前提条件は GNU make と同じ文言でその場で止める。

**起票時の対照実験の読み方を訂正する。** 上の課題節に「前提条件にワイルドカード(`gen/*.rb`)を含む生成規則は rmake でも
作られた」と書いたが、**実際は rmake が `gen/*.rb` を展開せず、黙って無視していたから通って見えていた**。作れない前提条件で
止めるようにした時点で、numo-narray は `No rule to make target '.../gen/*.rb'` で止まった。そこで前提条件のワイルドカードを
GNU make と同じく展開するようにした(Makefile のディレクトリ基準、一致をソート、一致が無ければ字面のまま残してエラー)。

numo-narray 0.9.2.1 は rmake の段を越え、`t_bit.c` などが生成されてコンパイルまで進んだ。次は
`t_int8.c:20:1: error: emmintrin.h: No such file or directory` で止まる(SSE2 の組み込み関数のヘッダ。rmake の範囲外)。

## 決着

**解消した**(`rmake-suffix-rule-generated-source-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 上の Makefile で rmake が `x.c` → `x.o` → `prog` の順に作る | `test/test_rmake_suffix_rule_generated_source.rb` で確認(2 段・3 段の連鎖も) |
| 作れない前提条件はその場で報告して止まる(GNU make の文言と動作を先に測る) | `rmake: No rule to make target 'x.o', needed by 'prog'.  Stop.`(exit 2)。GNU make と違って手前の手順も実行せずに止まる点は STEPS に記録 |
| `numo-narray` 0.9.2.1 が rmake でビルドできる | **rmake の段は越えた**。その先は `emmintrin.h` で止まる(rmake の範囲外) |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
