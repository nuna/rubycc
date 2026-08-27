---
status: open
kind: debt
opened: 2026-08-27
closed:
branch:
pr:
steps: []
---

# `-fPIC` が定義済みエクスポートグローバルを PC32 で参照するため、GNU ld で `.so` に固められない

## 課題

`rubycc -fPIC -c` は、**その TU が定義していてエクスポートされるグローバル変数**への参照を
`R_X86_64_PC32` で出す。gcc は同じソースを `R_X86_64_REX_GOTPCRELX`(GOT 経由)で出す。
2026-08-27 にこのホスト(WSL2 / gcc 14.2 / GNU ld)で実測:

```c
/* g.c */
int shared_counter = 7;
int bump(void) { return ++shared_counter; }
```

| | 再配置 |
|---|---|
| `rubycc -fPIC -c` | `R_X86_64_PC32 shared_counter - 4`(2 件) |
| `gcc -fPIC -c` | `R_X86_64_REX_GOTPCRELX shared_counter - 4`(3 件) |

`gcc -shared` に渡すと、**rubycc の `.o` だけがリンクできない**:

```
/usr/bin/ld: g_rubycc.o: warning: relocation against `shared_counter' in read-only section `.text'
/usr/bin/ld: g_rubycc.o: relocation R_X86_64_PC32 against symbol `shared_counter'
             can not be used when making a shared object; recompile with -fPIC
/usr/bin/ld: final link failed: bad value
```

gcc の `.o` は成功する。Step 33/34 が記録した挙動が、そのまま現在も続いている。

rubycc 自身の `SharedLinker` は `S+A−P` で解決するので、**rubycc だけで完結する経路では
実行は正しい**(Step 34 で dlopen 実走まで確認済み)。

## 影響

**この課題は「介入の意味論」ではなく「他のリンカと組めるか」である。** 混同しないこと:

- **介入を尊重しない**(自分で定義したグローバルを直接束縛する = `-Bsymbolic` 相当)という
  意味論上の逸脱は、**方針として受け入れ済み**である(`docs/development/GAPS.md` §4、
  ユーザ判断 2026-08-06)。再検討の条件は「実在の gem で実害が出たとき」。
- **本課題はその副作用**で、GNU ld が「preemptible シンボルへの PC32」を共有オブジェクト
  規則違反として**拒否する**こと。`-Bsymbolic` を選ぶこと自体は正規の構成だが、
  それは**リンク時に指定するもの**で、コンパイル時に PC32 を焼き込むのとは別である。

困るのは、**rubycc でコンパイルして gcc / GNU ld で `.so` に固めたい**利用者と、
**その組み合わせを使う差分テスト**である。実際 Step 34 以降、gcc 互換テストは
「定義済みグローバルを含まない入力」(関数 + 文字列)を使って回避している。
つまり**テストのカバレッジがこの制限に合わせて狭められている**。

放置してもコーパスは通る(rubycc のドライバは自前のリンカを使うため)。

## 受け入れ条件

- 上の `g.c` が `rubycc -fPIC -c` → `gcc -shared` でリンクでき、
  生成された `.so` を dlopen して `bump()` を呼ぶと 8 を返す
- rubycc 自身の `SharedLinker` で固めた `.so` も同じ結果になる(退行させない)
- gcc 互換の再配置比較テストが、**定義済みエクスポートグローバルを含む入力**でも
  gcc と同じ再配置種別を出すことを検査する(Step 34 で外していたケースを戻す)
- スループットのペア計測(`BENCH_RUNS=7`、同一セッション連続実行)で、
  行/秒が有意に下がらない。下がる場合は `docs/development/THROUGHPUT.md` の
  「N1 の受け入れ条件と、行/秒の位置づけ」の回帰対応手順に従って判断する
- `rake test` が 0 failures

## 作業ログ

### 2026-08-27

ROADMAP §3 の散文にだけ載っていた負債を起票した。§3.1 の割り当ては「H4」だったが、
**H4 は終了している**ので受け皿が無くなっていた。

実測で現状を固定した(上の表とリンクエラー)。Step 33/34 の記録と一致する。

**未決**: 直し方が 2 通りある。(1) エクスポートされる定義済みグローバルも GOT 経由にする
(gcc の既定に合わせる。PLT/GOT 経由になる分だけ遅くなる)。(2) コンパイル時は GOT 経由にし、
`-Bsymbolic` 相当の直接束縛は**リンカ側の選択**に移す。**(2) の方が GAPS §4 の
「性能のため直接束縛する」という判断を保ったまま相互運用を回復できる**が、
リンカ側に緩和(GOTPCRELX → lea)を実装する必要があるかを先に確かめること
(Step 33 の記録が「リンカ将来最適化」として言及している)。

## 決着

(未着手)
