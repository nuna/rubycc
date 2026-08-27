---
status: open
kind: infra
opened: 2026-08-27
closed:
branch:
pr:
steps: []
---

# 文書再編で置き去りになった census スナップショットを再生成して、週次 census を緑に戻す

## 課題

**Tier B(`weekly.yml`)の `census` ジョブが赤い。** 2026-08-27 に `gh run` で確認した実測:

| スケジュール実行 | run | census |
|---|---|---|
| 2026-08-02 | 30763091287 | failure |
| 2026-08-09 | 31330038506 | success |
| 2026-08-16 | 31965072086 | failure |
| 2026-08-23 | [32658611908](https://github.com/nuna/rubycc/actions/runs/32658611908) | failure |

原因は **`test/corpus/include-census.md` が再生成されないまま古い文書パスを抱えている**ことである。
`docs-audience-split-1` の文書再編で `test/corpus/gems.rb` の `note` に書かれた参照先が
移動したのに、そこから生成されるスナップショットを commit し直していない:

```diff
-... (measured against v1.3.0 and master, docs/STEPS.md Step 157); ...
+... (measured against v1.3.0 and master, docs/development/STEPS.md Step 157); ...
-| fcntl | excluded | ... (docs/OUT-OF-SCOPE-GEMS.md basis D) |
+| fcntl | excluded | ... (docs/reference/OUT-OF-SCOPE-GEMS.md basis D) |
```

差分が出ているのは `fcntl` / `sqlite3` / `byebug` / `thin` / `unicorn` / `debug` の
note 行と、R10 basis の 2 行。**現在のコミット済みスナップショットには古い綴りが 8 箇所残っている**
(`grep -c "docs/STEPS.md\|docs/OUT-OF-SCOPE-GEMS.md" test/corpus/include-census.md` = 8、
2026-08-27 に master で実測)。

**ヘッダのカバレッジは動いていない。** 差分は文書パスの文字列だけである。

## 影響

`census` ジョブの目的は「rubycc 自身のヘッダカバレッジが動いたら知らせる」ことで、
gem のバージョンは `test/corpus/gems.rb` に固定されているから差分は上流の変動では
ありえない、という前提で組まれている(`weekly.yml` のコメント)。

**その通知路が、文字列の差分で塞がっている。** いま本当にカバレッジが動いても、
同じ「赤」としてしか出ないので区別できない。

`musl` ジョブ([issue](musl-shared-object-regression.md))と合わせて **Tier B の 2 ジョブが
定常的に赤い**状態であり、週次の結果を見る意味が薄れている。

## 受け入れ条件

- `bundle exec rake corpus:census` を実行し、再生成された
  `test/corpus/include-census.md` を commit する(**このタスクはネットワークが要る**)
- `git diff --exit-code -- test/corpus/include-census.md` が差分無しで終わる
- 差分が**文書パスの文字列だけ**であることを確認する。ヘッダのカバレッジ・R10 の
  分母/分子・合格率が動いていたら、**それは別の事実**なので切り分けて記録する
- 次のスケジュール実行、または `workflow_dispatch` での `census` ジョブが緑になる
- `rake test` が 0 failures(`test/test_doc_links.rb` を含む)

## 作業ログ

### 2026-08-27

GAPS.md の棚卸し中に、週次の赤を辿って見つけた。**消し込み漏れであって、
rubycc の欠陥ではない。**

`rake corpus:census` は `Rakefile` のコメントが明記するとおり
「on-demand dev task; NOT part of `rake test`」でネットワークを要するため、
`rake test` では捕まらない。捕まえているのは週次の `census` ジョブだけで、
それが 2 週間赤いまま放置されていた。

## 決着

(未着手)
