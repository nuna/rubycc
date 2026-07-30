# data/ — repository-attached reference data

## verified_gems.json

The build-verified gem database `rubycc doctor` consults as its **primary
reference** before attempting any on-the-fly build. JSON carries no comments, so
the schema is documented here.

Top level is an object keyed by **gem name**. Each value is an object:

| key           | type            | meaning |
|---------------|-----------------|---------|
| `versions`    | array of string | Verified version strings (e.g. `"2.21.1"`) or version ranges (e.g. `">= 1.8, < 2"`). A gem at one of these versions is reported as **verified** without a build. |
| `verified_at` | string `YYYY-MM-DD` | Date the verification was recorded. |
| `environment` | string          | The environment the verification held in, e.g. `"glibc x86_64 / ruby 3.4.5"`. |
| `evidence`    | string          | How it was confirmed — which rubycc step/test proved it (e.g. the gem's own test suite passing). |
| `notes`       | string          | Known caveats (flags needed, platforms not yet covered, etc.). Empty string if none. |

### Version matching

`versions` entries are matched against a gem's resolved version with RubyGems'
own requirement grammar (`Gem::Requirement`): an exact string like `"2.21.1"`
matches only that version, and a range like `">= 1.8, < 2"` matches any version
inside it. A gem is **verified** when its version satisfies at least one entry.

### What may be added here

Only versions that were **actually built and exercised in this repository** — the
initial data is `json 2.21.1` and `msgpack 1.8.3`, both of which built with
rubycc and passed their own upstream test suites (Step 54, re-confirmed via the
in-process rmake build in Step 61 and the hermetic gem install in Step 64). The
intended long-term flow is to generate/extend this file from the corpus CI
results (ROADMAP H3) rather than hand-editing it.

### 更新は `tools/verify_gem_tests.rb` 経由で行う(手編集ではなく)

上記の「手編集ではなくコーパス CI の結果から生成/拡張したい」という意図は
**`tools/verify_gem_tests.rb` として実現済み**である。このツールは

1. scratch GEM_HOME に本チェックアウトの rubycc を入れ、
2. `RUBYCC=1 gem install <gem>` でその gem の C 拡張を rubycc でビルドし、
3. 本当に rubycc が使われたことを RubyGems が残す痕跡
   (`gem_make.out` の `$(MAKE)` = rubycc の `exe/rmake`、生成 Makefile の
   `CC = <...>/exe/rubycc`)で確認し、
4. 上流タグの tarball を取得して、そこへビルド済み `.so` を差し込み、
5. **その gem 自身のテストスイート**を実走してサマリ行を実測パースする。

**書き込み経路はこのツールの `--update --step N` だけ**である。PASS した gem
だけが記録され、失敗した gem・サマリ行を読み取れなかった gem は決して書かれない。
`evidence` / `environment` / `verified_at` はすべて**その実行の実測値**から生成
される。書式(インデント 2、`versions` は 1 行のインライン配列)も既存に合わせて
出力されるため、意図した行以外に差分は出ない。

```
tools/verify_gem_tests.rb --all                          # 実走して報告するだけ
tools/verify_gem_tests.rb --update --step 143 redcarpet  # 合格した gem を記録する
```

このツールを使ううえでの決まりごと:

- **レシピには `sanity` 式が必須**。gem によっては C 拡張がロードされず純 Ruby の
  フォールバック(racc)や処理系同梱の別コピー(date・bigdecimal・json)が使われても
  テストスイートは合格しうる。実測例: racc の `cparse.so` を壊したままスイートを走らせると
  **71 tests / 0 failures / 100% passed** になる(純 Ruby ランタイムに落ちている)。
  sanity 式が無ければ、この状態が「rubycc で検証済み」として記録されてしまう。
  そのためツールは `sanity` を持たないレシピの実行を拒否する。
- **`notes` は人間の責務**。新規エントリで `--notes` を省略すると既定値が入り、
  警告が出る。「機械が観測できない但し書き」(racc の
  `lib/racc/parser-text.rb` を手で補った、など)は必ず手で書き加えること。
  既存エントリを更新する場合、`notes` は保持される(実測できる skip / pending /
  omission の件数だけはツールが事実として追記する)。
- **既存エントリの `evidence` は上書きではなく追記**される。`evidence` はその gem を
  確認した全ステップの履歴を溜める欄で(json は Step 54・61・64、msgpack は Step 138 で
  H4 の 1 文が足された)、今日の実走は「今日測った事実」を足すだけであり、
  過去の確認が無かったことにはならない。上書きすると再実行では復元できない部分が
  黙って消える。
- **`test/test_doctor.rb` の許可リストは手で更新する**。
  `test_verified_gems_json_holds_only_confirmed_gems` が持つ gem 名の許可リストと
  DB のキー集合が食い違うと、ツールは貼り付け用の `assert_equal` 行を表示して警告する
  だけで、テストファイルは決して自動編集しない(gem の追加を意識的な編集に留める
  ための意図的なゲート)。
