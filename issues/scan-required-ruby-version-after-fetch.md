---
status: open
kind: infra
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 走査が、動いている Ruby を受け付けない gem を候補に入れる

## 課題

**`required_ruby_version` が動いている Ruby を満たさない gem が、候補 `[1]` に入る。**
2026-09-13 にランク 1501〜2500 を走査したとき、`string-scrub` 0.1.1(ランク 1,691)が候補に入った。
この gem は Ruby `>= 1.9.3, < 2.1` を要求しており、検証では rubycc・対照とも
インストールの段で止まった:

```
string-scrub-0.1.1 requires Ruby version >= 1.9.3, < 2.1. The current ruby version is 3.4.5.
```

`tools/scan_popular_gems.rb` が `running_ruby_satisfies?` を呼ぶのは、事前フィルタの 1 箇所
(1539 行)だけである。そこでは満たさないと分かっても、「アーカイブの取得は別の版に解決されうる」
という理由でダウンロードに回す。**ダウンロードした版の spec を、候補にする前に見直していない。**

## 影響

候補の数を多く見積もり、検証の手間を無駄にする。1 件あたりは rubycc と対照の 2 回分の
`gem install` の起動である。[`scan-gate-zero-c-sources`](scan-gate-zero-c-sources.md)
(C ソースが 0 件の gem が候補に混ざる)と同じ種類の弱点である。

## 受け入れ条件

- **どの版も動いている Ruby を満たさない gem** が候補 `[1]` に入らず、artifact の `decision` に
  理由(要求している版の範囲)が残る
- 動いている Ruby を満たす**古い版**がある gem は、これまでどおりその版を調べる(事前フィルタの
  1531〜1538 行のコメントが守っている性質を壊さない)
- `test/test_scan_popular_gems.rb` に上の 2 つのテストがあり、0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件の分類中に見つけた。

## 決着

(未着手)
