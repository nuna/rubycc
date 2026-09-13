---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# スレッドローカル記憶域(`_Thread_local` / `__thread`)が無い

## 課題

**C11 の `_Thread_local` も GNU の `__thread` も、rubycc は受け付けない。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 14.2)で最小再現を測った:

```c
_Thread_local int t;          /* 2 つ目は __thread int t; */
int get(void) { return t; }
```

| 入力 | gcc | rubycc |
|---|---|---|
| `_Thread_local int t;` | ok | **`error: expected type specifier`** |
| `__thread int t;` | ok | **`error: expected type specifier`** |

**コンパイラのソースに、この 2 語の言及が 1 つも無い**(`grep -rn "_Thread_local\|__thread" lib/` が 0 件)。
一部だけ未対応なのではなく、**記憶域クラスとしてまるごと無い**。

## 影響

**実在の gem が落ちる。** コーパス候補 `pg_query` 6.2.3 は、同梱の postgres ヘッダ
`ext/pg_query/include/postgres/utils/elog.h:315` で

```c
extern PGDLLIMPORT __thread ErrorContextCallback *error_context_stack;
```

と宣言しているため rubycc ではコンパイルできない(2026-09-13 実測)。
**対照の gcc はビルドに成功する**(対照が落ちたのはロードの証明の段で、これは
ハーネス側の既知の盲点である)。

**規模は小さくない。** 字句・構文の受理だけでは終わらない:

- **ELF の TLS**: `.tbss` / `.tdata` セクション、`PT_TLS` プログラムヘッダ
- **TLS 再配置**: x86-64 の `R_X86_64_TPOFF32` / `R_X86_64_GOTTPOFF` / `R_X86_64_TLSGD` ほか、
  AArch64 の `R_AARCH64_TLSLE_*` / `R_AARCH64_TLSIE_*` / `R_AARCH64_TLSDESC_*` ほか
- **コード生成**: x86-64 は `%fs` 相対、AArch64 は `tpidr_el0` 相対のアクセス
- **共有ライブラリ**: 拡張は `.so` なので、**実行ファイル向けのローカル実行モデルでは足りず**、
  動的モデル(general dynamic / TLS descriptor)が要る

## 受け入れ条件

- 上の 2 つの最小再現が gcc と同じくコンパイルでき、**値の読み書きがスレッドごとに独立**である
  ことを実行して確かめる(2 スレッドで別の値を書いて読み戻す)
- **共有ライブラリの中で定義した TLS 変数**を、別の `.so` や実行ファイルから使えること
- x86-64 と AArch64 の**両方**で、gcc 差分の実行オラクルが一致する
- `pg_query` 6.2.3 が rubycc でビルドできる
- `rake test` が 0 failures

## 着手前に確かめること

- **どの TLS モデルから入るか**を決める。拡張は `.so` なので、ローカル実行モデル
  (`-ftls-model=local-exec`)だけを実装しても**実在の gem には効かない**
- **これはマイルストーン級である**。実装に入る前に、同じ理由で落ちる gem が
  コーパス候補に何件あるかを数え、規模に見合うかを判断すること
  (いま分かっているのは `pg_query` の 1 件だけ)

## 作業ログ

### 2026-09-13(起票)

コーパス候補の `build_load` で「両方失敗」と数えていた中に、**対照はビルドに成功していて
落ちたのはロードの証明だけ**のものが混ざっていた。取り直したところ pg_query は
rubycc だけが構文エラーで落ちており、原因がこれだった。

## 決着

(未着手)
