@references/role-based-model-selection.md
<!-- 上記の役割別モデル選択・サブエージェント移譲の方針は、次の記事を下敷きにしている:
     okkun0524(GENDA Inc.)「サブエージェント活用で Claude Fable 5 をコスパよく運用する」
     2026-06-12, https://zenn.dev/genda_jp/articles/b6045575e2e13d
     設計判断とレビューは上位モデル、コード調査は中位、テスト実行は下位、という
     タスク種別ごとのモデル振り分けの考え方を本プロジェクト向けに具体化したもの。 -->

# プロジェクトドキュメント(必要時に読むこと。@ 展開はしない)

- `docs/DESIGN.md` — 要件(R1〜R11)・アーキテクチャ選定・マイルストーン定義・
  参考資料(参照した規格・仕様の一覧)
- `docs/ROADMAP.md` — 開発ワークフロー(1 ステップのサイクル)・実装規約と不変条件・
  既知の負債・今後の全ステップ/マイルストーンの実行計画。**新しいステップに着手する前に必読**
- `docs/GAPS.md` — **未解消**のギャップ・負債・未測定事項の一覧(1 行 1 件、詳細は参照先)。
  解消したらこのファイルから消し、経緯は STEPS.md に書く
- `docs/OUT-OF-SCOPE-GEMS.md` — **対応しないと判断済み**の gem と、その理由・根拠。
  GAPS.md(通す気はあるがまだ通らない)とは別物。コーパスに gem を足す前に確認する
- `docs/STEPS.md` — 完了済みステップの設計判断・トレードオフの記録。
  触るコンポーネントに関連するステップを着手前に読むこと
- `docs/IR.md` — 中間表現の仕様(命令一覧・値表現規約・バックエンドとの契約)。
  IR 命令の追加・変更時は ir.rb のコメントと両方を更新すること

# 運用ルール

- ステップ完了ごとに 1 コミット(`<英語サマリ> (<ステップ ID>)` + 日本語箇条書き本文)
- **ステップ ID は `<ブランチ名>-<連番>`**(例 `differential-discipline-1`)。
  連番は並行作業で 2 回衝突したので変更した。**過去の `Step N` は振り直さない**。
  経緯と理由は `docs/STEPS.md` の冒頭「採番方式」
- ステップ完了ごとに、そのステップの機能を使う C サンプルを
  `examples/m1/step<NN>_<名前>.c` に追加して残す(後のステップの機能は使わない)。
  全サンプルは `test/test_examples.rb` が gcc 差分でビルド・実行を常時検証する。
  詳細は `examples/README.md`
- ステップ完了時に docs/STEPS.md へ設計記録を追記し、docs/ROADMAP.md の計画を消し込む
- 実装をエージェントに移譲するときは R11(既存 OSS 類似実装の禁止)をプロンプトに明記し、
  レビュー観点に含める

# スキル

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
