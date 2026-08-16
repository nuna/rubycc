---
name: corpus-expansion
description: rubycc のコーパス拡張と検証済み gem 追加の一連のワークフロー。人気 gem のスキャン、test/corpus/gems.rb への追加、rake corpus:census の実行、センサスが見つけたヘッダギャップの充填、gem 本体テストの実走、data/verified_gems.json への記録までを扱う。「コーパスに gem を追加」「センサスを回す」「検証済み gem を増やす」「verified_gems.json を更新」といった依頼で使う。
---

# コーパス拡張・検証済み gem 追加ワークフロー

rubycc が「実際の gem をビルドできる」ことを広げ、その事実を記録するまでの手順。
**フェーズ 1(コーパス追加・センサス)** と **フェーズ 2(検証済み gem 追加)** からなる。
片方だけ実施してもよいが、フェーズ 2 の対象はフェーズ 1 でコーパスに入っている gem に限る。

## 着手前に必ず読む

- `docs/development/ROADMAP.md` — 1 ステップのサイクル、実装規約と不変条件、H6 の残作業
- `docs/development/STEPS.md` — 直近のステップ(特に Step 139〜144)の設計判断
- `test/corpus/README.md` — センサスとスキャナの使い方
- `data/README.md` — `verified_gems.json` のスキーマと更新規約

## 全フェーズ共通の規約

- **ユーザへの出力は日本語**。コード内コメントは英語、ドキュメントは日本語
- **1 ステップ = 1 コミット**。`<英語サマリ> (Step N)` + 日本語箇条書き本文 +
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **ステップ完了時に `docs/development/STEPS.md` へ設計記録を追記し、`docs/development/ROADMAP.md` の計画を消し込む**。
  STEPS.md はメインセッションが書く(判断の記録なので移譲しない)
- **実装の移譲は `references/role-based-model-selection.md` の役割表に従う**。
  テスト・ベンチ・検証コマンドの実行は **必ず test-runner に委譲**(メインで直接 Bash しない)
- **移譲プロンプトには R11(既存 OSS 類似実装の禁止)を明記**し、レビュー観点に含める。
  chibicc / tcc / gcc / glibc / musl / Linux カーネルのソースを参照・引用・移植しない
- **推測を記録に混ぜない**。数値は実測値のみ。実測できなかったことは「確認できた」と書かない

---

## フェーズ 1 — コーパス追加とセンサス

### 1-1. 候補を機械的に洗い出す

```sh
tools/scan_popular_gems.rb <first_page> <last_page>     # 1 ページ = 10 ランク
SCAN_SOURCE=bestgems tools/scan_popular_gems.rb 12 20   # ランク 100 超
SCAN_VERBOSE=1 ...                                      # C 拡張なしの gem も一覧
tools/scan_popular_gems.rb --source timeframe \
  --from 2026-08-15T00:00:00Z --to 2026-08-16T00:00:00Z # 完了済みUTC期間
```

`timeframe` は rubygems.org の `/api/v1/timeframe_versions.json` を全 page 取得する。`from` /
`to` は ISO 8601 の UTC 境界で、期間は最大 7 日。prerelease と yanked を除き、v2 version API
で `platform=ruby` の source gem を確認してから version 固定で検査する。`[1]` は候補であり、
`test/corpus/gems.rb` への正式追加ではない。source gem を選べない version は理由付きで `[E]`
に残す。
RubyGems の spec cache は `SCAN_WORK/gem_spec_cache` に置かれるため、HOME が read-only な
実行環境でも writable な `SCAN_WORK` を使う。

比較可能な記録が必要なときは `--artifact PATH` を付ける。schema version、normalized input、
raw response / `.gem` SHA-256、release 選択理由、Census header 分類を保存し、同じ
`SCAN_WORK` の raw response と gem cache を再利用できる。`[R]` は未宣言 native source または
`ext/` 外 extension の review bucket、`[1b]` は assembly 専用である。artifact は候補資料で、
`test/corpus/gems.rb` への正式追加や `data/verified_gems.json` の更新を自動では行わない。

出力グループの扱い:

| | 意味 | どうするか |
|---|---|---|
| `[1]` | R10 ゲート通過・未収載 | **追加候補**。ここから選ぶ |
| `[1b]` | R10 は通るがアセンブラが必要 | **追加しない**。rubycc にアセンブラバックエンドが無い |
| `[2]` | R10 ゲートで除外 | 追加しない(C++ / configure 依存) |
| `[3]` | すでにコーパス内 | 現在のゲート判定の再確認に使う |
| `[E]` | fetch / unpack のエラー | 個別に確認 |

**上位ほど純 Ruby gem が多い**(ランク 1〜20 では C 拡張持ちが 2 件だけだった)。
実入りはランク 100 以降にある。

### 1-2. `test/corpus/gems.rb` に追加する

各エントリは `:name` / `:version`(nil で最新)/ `:note`。

- **バージョンは固定する**(再現性のため)
- `:note` には「なぜコーパスに入れるか」を書く
- **手作業で除外した gem は理由をコメントに残す**。`[1b]` に落ちた gem を人手で
  除外する場合、根拠(どの `.S` / どの `$objs` エントリか)まで書く
- 選定の基準(ダウンロード数の閾値、選定日、データの出所)をグループコメントに書く。
  **網羅的な走査ではなく閾値で絞った候補リストである**という限界も正直に書く

### 1-3. センサスを回す

```sh
bundle exec rake corpus:census     # test/corpus/include-census.md を再生成
```

ネットワークが必要。`rake test` には含まれない。**test-runner に委譲すること**。

再生成された `test/corpus/include-census.md` の差分を読む。見るべきは:

- **Gap candidates 表** — コーパスの gem が `#include` していて同梱していないヘッダ
- **Bundled header set** の angle スペリング数(ヘッダを足したら増える)
- 各 gem の R10 判定が想定どおりか

### 1-4. ギャップを性質で仕分ける

Gap candidate は全部埋めるものではない。実測した分類:

| 性質 | 例 | 扱い |
|---|---|---|
| **Linux/POSIX の実需** | `sys/wait.h` `langinfo.h` `sys/epoll.h` | **埋める** |
| 他プラットフォーム分岐 | `windows.h` `os2.h` `sys/event.h` | 埋めない |
| ホストライブラリが供給 | `openssl/*` `zlib.h` `mysql*` | 埋めない |
| SIMD ゲート | `arm_neon.h` `cpuid.h` | 埋めない(gate で無効化される) |
| 言語機能待ち | `stdatomic.h`(`_Atomic`)`stdckdint.h` | README の「既知の制限」へ |
| カーネル UAPI | `linux/types.h` `linux/fs.h` | 個別判断 |

### 1-5. ヘッダを追加する(R8 規律)

`docs/reference/HEADER-LICENSING.md` §6 が必須手順。**移譲する場合はこの §6 をプロンプトに要約して渡す**。

1. **冒頭 provenance コメント**を書く(freestanding / musl-derived / clean-room のどれか)
2. **ABI 値は実測でのみ取得**。glibc / UAPI のヘッダテキストを写経しない。
   リファレンスコンパイラで `sizeof` / `_Alignof` / `offsetof` / マクロ値を印字して測る
3. **由来台帳(§3.3 の表)に 1 行追加し、§3 / §3.2 / §3.3 / §3.4 の集計を更新**
4. **ABI ハーネス(`test/test_header_abi.rb`)にケースを追加**。
   **x86_64 と aarch64 の両方**に入れること。アーキで差があるヘッダは
   `include/libc/glibc/{x86_64,aarch64}/` の arch 層に分ける
5. 疑義があればクリーンルームで書き直す

**実測が予想を覆すことが繰り返し起きている**(epoll はアーキ層が必要だったが statfs は
不要、`__fsid_t` は int 2 本)。**先に測ってから書く**こと。

> **`rubycc -E` が通ることは「正しい」の証明にならない。** `-E` は TokenConverter を
> 通さないため、ブロックコメント中の `*/` のような誤りを見逃す。ABI ハーネスまで通して初めて確認になる。

### 1-6. センサスを再生成してコミット

ヘッダを足したら `rake corpus:census` を再実行し、Gap candidates から消えたことを確認する。
`rake test` の全数(runs / failures / skips)も確認する(test-runner に委譲)。

---

## フェーズ 2 — 検証済み gem の追加

`data/verified_gems.json` に書いてよいのは **(d) レベルの証拠** —
「その gem 自身のテストスイートが rubycc ビルドの `.so` に対して合格した」——だけ。
「ビルドできた」「`gem install` が成功した」は**不十分**。

### 2-1. `tools/verify_gem_tests.rb` にレシピを書く

```sh
tools/verify_gem_tests.rb <gem>...                    # 実走して報告するだけ
tools/verify_gem_tests.rb --update --step N <gem>...  # 合格した gem を記録する
```

レシピのフィールド: `version` / `tarball`(上流タグの tar.gz)/ `sos`(差し込む `.so` の
対応表)/ `extra_copies` / `test_deps` / `runner`(`:test_unit` / `:rspec` / `:ruby_files`)/
`load_paths` / `test_glob` / `exclude` / `require_flags` / **`sanity`**。

**`sanity` は必須で、これが一番重要**。C 拡張がロードされず純 Ruby のフォールバックや
処理系同梱の別コピーが使われた状態でも**テストスイートは合格する**。実測例: racc の
`cparse.so` を壊しても 71 tests / 0 failures / 100% passed になる。sanity が無ければ
その状態が「rubycc で検証済み」として記録される。

sanity 式の選び方:

- 純 Ruby フォールバックがある gem → その勝者を示す観測点を使う
  (json: `JSON.parser.to_s == "JSON::Ext::Parser"`、racc: `Racc::Parser::Racc_Runtime_Type == "c"`)
- 観測点が無い gem → `injected_so_loaded?`(差し込んだ `.so` が `$LOADED_FEATURES` にあるか)。
  これは全 gem で常に評価されるので、**default gem / 同梱 gem の別コピーが読まれる**
  危険(date・bigdecimal)には対応できている
- **`require` が成功するだけでは不十分**

### 2-2. まず `--update` なしで走らせる

sanity・rubycc ビルドの証明・サマリ行のパースが通るかを先に確認する。
実行は **test-runner に委譲**。gem 1 件で数分〜十数分かかる。

判定の読み方:

- `PASS` — sanity ok かつ failures 0 / errors 0 かつ子プロセスが正常終了
- `FAIL` — 上のどれかが崩れた。**記録しない**
- `unparsable` — サマリ行が読めなかった。**合格とも不合格とも断定しない**。手で確認する

### 2-3. 合格したら記録する

```sh
tools/verify_gem_tests.rb --update --step N <gem>
```

- スキーマは **1 gem = 1 エントリ、環境ごとの記録がその内側**という入れ子。
  エントリは `verifications`(配列・挿入順)と `notes`、各記録は
  `versions` / `environment` / `verified_at` / `evidence`。
  `versions` が記録の内側にあるのは、環境ごとに検証したバージョンが違いうるため
- `versions` / `environment` / `verified_at` / `evidence` は実測から自動生成される
- 記録先はその実行の環境で決まる。**同じ環境の記録があればそれを更新**し
  (`evidence` は追記 = 確認したステップの履歴を溜める欄)、
  **無ければ `verifications` の末尾に新しい記録を足す**(`evidence` は新規形から始まる)
- **`notes` は人間の責務**。機械が観測できない但し書き
  (racc の「`lib/racc/parser-text.rb` を手で供給した」など)は**手で書き加える**。
  skip / pending / omission の件数だけはツールが事実文を自動追記する
- **`notes` に「X ではまだ未検証」と書かない**。未検証はその環境の記録が無いことで
  表現される。散文にも書くと二重管理になり必ず古くなる。新規エントリの既定 notes は空文字

### 2-4. `test/test_doctor.rb` の許可リストを手で更新する

`test_verified_gems_json_holds_only_confirmed_gems` の `assert_equal %w[...]` と
`assert_includes` を更新する。ツールは貼り付け用の行を表示するが**自動編集しない**
(gem の追加を意識的な編集に留めるための意図的なゲート)。

`rake test` を回して無回帰を確認する(test-runner に委譲)。

### 2-5. 手順が破綻したときの一次資料

`gem` 固有のつまずきは `docs/development/STEPS.md` の Step 93〜99・144 に実測が残っている。
既知の注意点:

- **`.gem` にテストは同梱されていない**。上流タグの tarball が必ず要る
- **scratch GEM_HOME は必ず非空**にする(空だとリポジトリを汚染する)
- 純 Ruby のテスト依存(`rspec` / `test-unit` / `test-unit-ruby-core`)は
  **RUBYCC を付けずに**入れる
- **経路が違えば必要な配慮も違う**。json の `JSON_DISABLE_SIMD` は
  `tools/m2_acceptance.rb`(ホスト gcc で extconf)では要るが、
  `RUBYCC=1 gem install` 経路では conftest が rubycc を通るので**不要**

---

## ステップの締め

1. `rake test` の全数を確認(test-runner に委譲)
2. `docs/development/STEPS.md` に設計記録を追記 — **判断と、予想を覆した実測を書く**。
   数値の羅列ではなく「なぜそうしたか」「何が想定と違ったか」
3. `docs/development/ROADMAP.md` の該当項目を消し込む(`~~取り消し線~~` + **完了(Step N)** の形式)
4. 1 コミットにまとめる
