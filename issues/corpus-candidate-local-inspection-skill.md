---
status: in-progress
kind: infra
opened: 2026-08-16
closed:
branch: corpus-candidate-local-inspection-skill
pr: 69
steps:
  - corpus-candidate-local-inspection-skill-1
  - corpus-candidate-local-inspection-skill-2
  - corpus-candidate-local-inspection-skill-3
---

# corpus候補をローカルで一件ずつ検査するrepo-local skillを作る

## 課題

`corpus-expansion` skillは候補走査から正式追加、header gap対応、上流test、
`data/verified_gems.json`更新までを扱う。日次scanで得た未知の候補について、正式追加前に
name/version/SHAを固定し、静的判定、既存corpusとの差、build/load、環境不足を調べるだけの
狭い手順は独立していない。

候補ごとに手作業でコマンドを組むと、system RubyやHOMEのgem cacheを使う、versionを固定しない、
純Ruby fallbackを成功と誤認する、調査中のarchiveやlogをcommitする、といった差が生じる。
未知の `extconf.rb` やtestは任意コードでもあり、静的検査と実行検査を明確に分ける必要がある。

## 影響

候補の確認手順が一定でないと、同じgemを再調査できず、build成功とcorpusへ追加する価値も
混同される。小さなrepo-local skillに入力、停止条件、出力schemaを持たせれば、候補ごとのissueを
作る前に比較可能な調査記録を得られる。

## 受け入れ条件

- `.claude/skills/inspect-corpus-candidate/SKILL.md`を新規作成する
- front matterは`name`と`description`だけを持ち、skill名は
  `inspect-corpus-candidate`とする。descriptionには「corpus候補」「候補gemのローカル検査」
  「固定versionのbuild/load確認」に相当するtriggerを含める
- SKILL本文は簡潔な命令形で、詳細なscanner仕様を複製せず、既存の
  `test/corpus/README.md`、`tools/scan_popular_gems.rb`、`tools/verify_gem_tests.rb`を参照する
- 入力としてgem名、version、platform、期待SHA-256、元artifactを受け取る。
  versionまたはSHAが欠けた場合は実行検査へ進まない
- 次のphaseと停止条件を明示する
  1. archive再取得とSHA/name/version/platform照合
  2. gemspec、R10、未宣言native source、extension root、header差分の静的検査
  3. 既存corpus/popular候補との重複と増分価値の人手review
  4. 明示的に依頼された場合だけ、隔離した作業環境でbuild/load smoke
  5. recipeを作れる候補だけ、controlとrubyccの上流testへ進む
- Ruby下限確認ではrbenvの利用可能な3.3系を検出して明示的に選び、暗黙のsystem Rubyへ
  fallbackしない。特定patch versionを恒久的にhard-codeしない
- 実行作業は`mktemp -d`または明示された隔離directoryで行い、通常のHOME、既存GEM_HOME、
  repositoryのtracked fileを汚さない。未知コード実行前にsecretを除き、可能なら使い捨て
  container/VMを使う
- 出力は候補ごとに、入力identity、静的判定、header差分、build/load結果、環境不足、
  次の判断を含む。`build成功`を`verified`と表現せず、正式追加や
  `data/verified_gems.json`更新を自動で行わない
- 作業用archive、raw response、unpack tree、logを
  `docs/development/corpus-candidate-evaluation/artifacts/`へ置いた場合、すべてignore対象である。
  永続化する結論はissue/STEPSまたは専用reportへ要約する
- SKILL.md以外のREADME、quick reference、changelogを作らない。繰り返し処理に既存toolで
  足りない部分が確認できた場合だけbundled scriptを追加し、単体testを付ける
- `CLAUDE.md`のskill一覧へ用途と境界を追加する
- 少なくとも次の2プロンプトでfresh-context forward testを行い、結果を作業ログへ記録する
  - 固定artifactの候補を静的検査し、repoを変更せずreportする
  - build/loadまで依頼し、version/SHA固定、隔離、純Ruby fallback防止を守る

このPRでは候補gemの正式追加、header実装、日次Actions、手動Actions workflowを追加しない。

## 実装計画

3タスク、各タスクを1コミットの目安とする。

1. `corpus-candidate-local-inspection-skill-1`: `inspect-corpus-candidate` skillのfront matterと
   静的検査workflowを作り、既存toolへの参照を定義する
2. `corpus-candidate-local-inspection-skill-2`: SHA/version固定、隔離実行、build/load、sanity、
   control/testの停止条件と出力schemaを追加する
3. `corpus-candidate-local-inspection-skill-3`: CLAUDE.mdへ登録し、静的のみとbuild/loadの2つの
   fresh-context forward testでrepo非変更と安全境界を確認する

## 作業ログ

### 2026-08-16

既存`corpus-expansion`は正式追加までを扱うため、候補調査だけを依頼しても変更範囲が広がりやすい。
skill作成指針に従い、名前を動詞始まりにし、本文は既存toolを再利用する短いworkflowへ限定した。
静的検査は既定で進め、任意コードを実行するphaseは依頼範囲と隔離を確認してから進める。

`corpus-candidate-local-inspection-skill` branchで実装を開始した。`init_skill.py`でskillを初期化し、
既存scannerを参照する固定identity・静的分類・増分review・明示依頼時の隔離build/load・recipe限定の
upstream testを`SKILL.md`へまとめた。作業物はignored artifactsまたは一時directoryに限定する。

fresh-context forward testを固定artifactの`funnel_http 0.5.12`で2回実施した。静的のみの依頼では
archive SHA/name/version/platformを照合し、C/Hに加えてGo sourceと`go.mod`/`go.sum`を検出して
`review`で停止した。build/load依頼では同じ停止条件により未知コードを実行せず、`recipe_missing`も
記録した。両方ともRuby 3.3.12をrbenvから選び、repositoryの変更は無かった。

初回の2検査でGo/cgo sourceの報告が揃わなかったため、scannerのC/C++一覧をそのまま信頼しない
棚卸し規則とadditional native source/build manifest欄をskillへ追加して再検証した。修正版では
両方のfresh-context testがGo/cgoを`needs_review`として一致して扱った。

skillの有効性を、同じ固定artifactから取得した3ケースで追加実証した。`funnel_http 0.5.12`は
期待SHAとarchive SHAが一致した後、scannerの`candidate`だけではなくGo source 2件と
`go.mod`/`go.sum`を検出し、未知のGo/cgo build形態として`review`で停止した。明示的な
build/load依頼はこの停止条件により実行していない。`actionagent 1.2.1`はSHA/name/version/platform
照合後に`no_ext`として停止し、build/loadやupstream testへ進まなかった。さらに同じ
`funnel_http` archiveへ意図的に不一致SHAを与えたcontrolでは、gemspec確認・unpack・build/loadを
行わず`checksum_mismatch`で停止した。3件のJSON reportはignoredな
`docs/development/corpus-candidate-evaluation/artifacts/skill-demo/`に生成され、tracked fileの
変更は発生しなかった。

## 決着

(完了時に記入。結果と`docs/development/STEPS.md`の該当エントリへのリンクを残す。)
