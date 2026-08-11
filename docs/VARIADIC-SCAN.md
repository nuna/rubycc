# 可変長引数コーパス調査

`tools/scan_corpus_variadics.rb` は、構造体を可変長引数へ渡す箇所や
`va_arg` の候補を列挙するための lexical scanner である。コンパイラ、
preprocessor、ネットワークは起動しない。したがって、この結果は不在証明・
R10合否判定・実装可否の自動判定には使わない。

## 再現コマンド

```sh
ruby tools/scan_corpus_variadics.rb \
  --root test/external/c-testsuite --format json
```

2026-08-09時点の vendored c-testsuite 走査結果は次のとおりである。

| 項目 | 件数 |
|---|---:|
| 走査ファイル | 220 |
| 構造体・unionの `va_arg` 候補 | 14 |
| 構造体・unionのvariadic caller候補 | 142 |
| variadic function pointer候補 | 1 |
| 合計finding | 157 |

`va_arg`候補14件はすべて `single-exec/00204.c` のHFAおよび小構造体の
ケースであり、現在の暫定仕様（struct `va_arg`を診断拒否）と一致する。
これらは実装済みとは数えない。caller候補は、既知の `printf` 宣言に対する
ヒューリスティック候補が大半であるため、scanner結果だけで「実際にstructが
渡される」とは分類しない。

R10対象gemについては、live M2 acceptanceが取得した json/msgpack のextツリーを
同じscannerで走査し、JSONをCI artifactへ保存する。取得できた2 gemの結果を
R10全体の不在証明へ拡張せず、macro展開・生成コード・他の対象gemは手動分類の
対象として残す。

typedef経由の `va_arg(ap, payload_t)` も、同一ソース内で
`typedef struct/union` が検出できる場合は `va_arg_struct_or_union` として報告する。
include解決とmacro展開は行わないため、検出できない場合があるという制限は維持する。
