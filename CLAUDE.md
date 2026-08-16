@references/role-based-model-selection.md
<!-- 上記の役割別モデル選択・サブエージェント移譲の方針は、次の記事を下敷きにしている:
     okkun0524(GENDA Inc.)「サブエージェント活用で Claude Fable 5 をコスパよく運用する」
     2026-06-12, https://zenn.dev/genda_jp/articles/b6045575e2e13d
     設計判断とレビューは上位モデル、コード調査は中位、テスト実行は下位、という
     タスク種別ごとのモデル振り分けの考え方を本プロジェクト向けに具体化したもの。 -->

# プロジェクトドキュメント(必要時に読むこと。@ 展開はしない)

**置き場所と書き方の基準は `docs/README.md`**。置き場は**読み手**と**種別**の 2 軸で決まる:

| | 仕様(**古くなったら直す**) | 記録(**日付を添えて残す**) |
|---|---|---|
| 利用者向け | `docs/reference/` | — |
| 開発者向け | `docs/internals/`(IR・CI) | `docs/development/` |

**維持の規則は種別で決まる**(仕様は直す、記録は残す)。
**事実と判断を同じ段落に混ぜない** — 事実にはいつ・どこで測ったかを添える。
文書を足すときは `docs/README.md` の索引にも 1 行足す(`test/test_doc_links.rb` が検査する)。

# 未消化の作業の残し方・出し方

**未消化の作業は `issues/` に置く。他の文書の散文に書かない。**
規約の詳細は `issues/README.md`、雛形は `issues/TEMPLATE.md`。

## 出し方(まずこれを見る)

```sh
grep -l "^status: open" issues/*.md | grep -vE "(README|TEMPLATE)\.md"   # 未着手
grep -l "^status: in-progress" issues/*.md                               # 着手中(branch あり)
```

## 残し方

1. **作業中に別の課題を見つけたら、その場で直さずに issue を立てる**。
   `issues/<着手するブランチ名>.md` を `TEMPLATE.md` から作る(**連番は使わない** —
   並行作業で衝突した実績があるため)
2. 課題節は**事実を先に**書く(測定値・最小再現・エラー出力と、いつ・どこで測ったか)。
   受け入れ条件は**検証可能な形**で書く(「テストが通る」ではなく「`test/x.rb` が
   0 failures で gcc 対照と一致する」)
3. 着手したら `status: in-progress` と `branch:`、完了したら `status: done` と
   `closed:` / `pr:` / `steps:` を埋める。**PR を伴わない作業(タグ push 等)は `pr: none`**
4. **設計判断の本文は `docs/development/STEPS.md` が本体**。issue の「決着」節はそこを指すだけ
5. 完了しても**削除しない**。作業ログとして残す(未解消の索引である `GAPS.md` からは消す)

`test/test_issue_docs.rb` が front matter の語彙と状態の整合を検査する
(`done` なのに `pr` が無い、など)。

- `docs/development/DESIGN.md` — 要件(R1〜R11)・アーキテクチャ選定・マイルストーン定義・
  参考資料(参照した規格・仕様の一覧)
- `docs/development/ROADMAP.md` — 開発ワークフロー(1 ステップのサイクル)・実装規約と不変条件・
  既知の負債・今後の全ステップ/マイルストーンの実行計画。**新しいステップに着手する前に必読**
- `docs/development/GAPS.md` — **未解消**のギャップ・負債・未測定事項の一覧(1 行 1 件、詳細は参照先)。
  解消したらこのファイルから消し、経緯は STEPS.md に書く
- `docs/reference/OUT-OF-SCOPE-GEMS.md` — **対応しないと判断済み**の gem と、その理由・根拠。
  GAPS.md(通す気はあるがまだ通らない)とは別物。コーパスに gem を足す前に確認する
- `docs/development/STEPS.md` — 完了済みステップの設計判断・トレードオフの記録。
  触るコンポーネントに関連するステップを着手前に読むこと
- `docs/internals/IR.md` — 中間表現の仕様(命令一覧・値表現規約・バックエンドとの契約)。
  IR 命令の追加・変更時は ir.rb のコメントと両方を更新すること

# 運用ルール

- ステップ完了ごとに 1 コミット(`<英語サマリ> (<ステップ ID>)` + 日本語箇条書き本文)
- **ステップ ID は `<ブランチ名>-<連番>`**(例 `differential-discipline-1`)。
  連番は並行作業で 2 回衝突したので変更した。**過去の `Step N` は振り直さない**。
  経緯と理由は `docs/development/STEPS.md` の冒頭「採番方式」
- ステップ完了ごとに、そのステップの機能を使う C サンプルを
  `examples/m1/step<NN>_<名前>.c` に追加して残す(後のステップの機能は使わない)。
  全サンプルは `test/test_examples.rb` が gcc 差分でビルド・実行を常時検証する。
  詳細は `examples/README.md`
- ステップ完了時に docs/development/STEPS.md へ設計記録を追記し、docs/development/ROADMAP.md の計画を消し込む
- 実装をエージェントに移譲するときは R11(既存 OSS 類似実装の禁止)をプロンプトに明記し、
  レビュー観点に含める

# スキル

- `inspect-corpus-candidate` — 固定したcorpus候補gemを一件ずつ検査する。archiveのidentity・SHA、静的分類、既存corpusとの差分を先に確認し、明示依頼時だけ隔離build/load、recipeがある場合だけupstream testへ進む。正式追加や`verified_gems.json`更新は行わない。
  定義は `.claude/skills/inspect-corpus-candidate/SKILL.md`
- `corpus-expansion` — コーパス拡張(人気 gem のスキャン → `test/corpus/gems.rb` 追加 →
  `rake corpus:census` → ヘッダギャップ充填)と検証済み gem 追加(gem 本体テストの実走 →
  `data/verified_gems.json` 更新)の一連のワークフロー。
  定義は `.claude/skills/corpus-expansion/SKILL.md`
- `codex:rescue` — OpenAI の Codex プラグイン(モデル `gpt-5.6-luna` / effort `max`)。
  用途は **(1) 1 ファイルに閉じた単純・無依存の実装が複数あるときの多重起動**と
  **(2) 行き詰まったときに別系統の意見を得る**の 2 つに限る。
  **`--model` / `--effort` は渡さない**(`~/.codex/config.toml` の設定が効く。
  プラグインの `--effort` は `max` を受け付けず、明示すると効果が下がる)。
  判断基準は `references/role-based-model-selection.md`
