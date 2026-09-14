---
status: done
kind: gap
opened: 2026-09-14
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [predefined-identifier-func-1]
---

# 定義済み識別子 `__func__` が無い

## 課題

**rubycc は `__func__`(C99 6.4.2.2 の定義済み識別子)を知らず、関数の中で使っても「宣言されていない変数」にする。**
gcc は通す。2026-09-14 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
#include <stdio.h>
int main(void) {
  printf("[%s] %zu\n", __func__, sizeof __func__);
  printf("[%s]\n", __FUNCTION__);
  printf("[%s]\n", __PRETTY_FUNCTION__);
  return 0;
}
```

| | 結果 |
|---|---|
| gcc 13.3 | `[main] 5` / `[main]` / `[main]` |
| rubycc | **`error: undeclared variable '__func__'`** |

ファイルスコープの `const char *p = __func__;` は、gcc が
`warning: '__func__' is not defined outside of function scope` を出して通し、rubycc は同じエラーにする。

`lib/` に `__func__` / `__FUNCTION__` を扱うコードは無い(2026-09-14 に grep で確認)。

## 影響

**実在の gem が落ちる。** `trilogy` 2.13.0 は、`bundled-pthread-attr-guard-1`(AU)を入れた rubycc で
`trilogy.c:4416:9: error: undeclared variable '__func__'` で止まる(2026-09-14 実測)。OpenSSL 3 の
`ERR_put_error` が `OPENSSL_FUNC` に展開され、C99 以降では `__func__` になる(`/usr/include/openssl/macros.h:288`)。
OpenSSL のエラー報告マクロを使う拡張はどれも同じ形で落ちる。

## 受け入れ条件

- 上の再現が rubycc でコンパイルでき、出力が gcc と一致する(x86-64 と aarch64)
- `__func__` は C99 6.4.2.2 のとおり、関数本体の先頭で `static const char __func__[] = "関数名";` と
  宣言されたように振る舞う(型は `const char[N]`、`sizeof` は名前の長さ + 1)
- `__FUNCTION__` / `__PRETTY_FUNCTION__` の扱い、ファイルスコープでの扱いを gcc で測って決め、STEPS に書く
- `trilogy` 2.13.0 が `__func__` の段を越える
- `rake test` が 0 failures

## 作業ログ

### 2026-09-14(起票)

AU を直した後に trilogy を測り直して見つけた。

### 2026-09-14(実装)

構文解析の段で、3 つの綴りを囲む関数の名前の文字列リテラルに置き換えた。同じ名前の宣言が見えていれば、そちらを優先する。
`&__func__` のために、生成器に `&"文字列リテラル"`(`char[N]` へのポインタ)も足した。gcc を測ると、C モードでは
`__FUNCTION__` / `__PRETTY_FUNCTION__` も装飾の無い関数名になる。ファイルスコープの `__func__` は警告付きで `""` になる。

## 決着

**解消した**(`predefined-identifier-func-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 再現が通り、出力が gcc と一致する(x86-64 と aarch64) | `test/test_predefined_identifier_func.rb` と `examples/m6/predefined_identifier_func_1_predefined_identifiers.c`(両アーキの例題テスト) |
| `const char[N]` のように振る舞う(`sizeof` は名前の長さ + 1) | 同じテストで `sizeof`・入れ子ブロック・アドレスの一致を確認 |
| `__FUNCTION__` / `__PRETTY_FUNCTION__`・ファイルスコープを測って決める | 測った結果と、合わせなかった細部(ファイルスコープの `__PRETTY_FUNCTION__` が gcc では `"top level"`)を STEPS に記録 |
| `trilogy` 2.13.0 が `__func__` の段を越える | この PR の後に測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
