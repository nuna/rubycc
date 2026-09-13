# data/ — repository-attached reference data

## 2 つの台帳 — 何を証拠として受け付けるか

ここには gem について**主張の強さが違う台帳が 2 つ**ある。分けてある理由は、
弱い証拠と強い証拠を同じ数に混ぜると、その数が何を意味するのか誰にも言えなくなるからである。

| ファイル | 受け付ける証拠 | 書くツール | 1 件あたりの費用(2026-09-12 実測) |
|---|---|---|---|
| `verified_gems.json` | **(d) 水準** — **その gem 自身のテストスイートが、rubycc がビルドした `.so` に対して合格した** | `tools/verify_gem_tests.rb --update` | 20〜40 分(レシピを書いて実走する) |
| `buildable_gems.json` | **build_load 水準** — **install できて `.so` がロードできた**。テストスイートについては**何も言わない** | `tools/verify_corpus_candidate.rb --mode build_load --update` | 1〜2 分 |

**R10 の分母・分子は `buildable_gems.json` を見ない。** 合格率の分母は
`test/corpus/gems.rb`(ゲートを通った gem)、分子は `verified_gems.json` に (d) 水準の
記録がある gem で決まる。build_load はそのどちらにも入らない — 安いほうの証拠で率が動けば、
その率はもう「gem 自身のテストが通った割合」ではなくなる。
この 2 つの経路が新しい台帳を**読まない**ことは `test/test_buildable_gems.rb` が
(名前を grep するのではなく、センサス生成と doctor が実際に開いたファイルを見て)固定している。

「ビルドできない」と分かった gem の置き場はどちらでもない。基準つきで
`docs/reference/OUT-OF-SCOPE-GEMS.md` に書く。

## verified_gems.json

The build-verified gem database `rubycc doctor` consults as its **primary
reference** before attempting any on-the-fly build. JSON carries no comments, so
the schema is documented here.

Top level は **gem 名**をキーとするオブジェクト。1 gem = 1 エントリで、値は次のオブジェクト:

| key             | type                       | meaning |
|-----------------|----------------------------|---------|
| `verifications` | array of verification 記録 | その gem を確認した**環境ごとの記録**。挿入順(古い順)。空にはしない |
| `notes`         | string                     | 既知の但し書き(必要だったフラグ、手で補った手順など)。無ければ空文字 |

`verifications` の各要素:

| key           | type                | meaning |
|---------------|---------------------|---------|
| `versions`    | array of string     | この環境で検証したバージョン文字列(例 `"2.21.1"`)またはバージョン範囲(例 `">= 1.8, < 2"`)。ここに合致する gem は**ビルドせずに verified** と報告される |
| `environment` | string              | その検証が成り立った環境。例 `"glibc x86_64 / ruby 3.4.5"` |
| `verified_at` | string `YYYY-MM-DD` | その環境での検証を記録した日付 |
| `evidence`    | string              | どう確認したか — どの rubycc ステップ/テストが証明したか(その gem 自身のテストスイートの合格など) |

`versions` が**トップレベルではなく各記録の内側にある**のは、環境ごとに実際に検証した
バージョンが違いうるからである。トップレベルに 1 本置くと、ある環境でしか測っていない
バージョンまで全環境で検証済みだと主張することになる。

同じ理由で、**ある環境で未検証であることは「その環境の記録が無いこと」で表す**。
散文で書かない(下記「更新は…」節を参照)。

### Version matching

`versions` の各要素は、gem の解決済みバージョンに対して RubyGems の要求文法
(`Gem::Requirement`)で照合される。`"2.21.1"` のような完全一致はそのバージョンだけに、
`">= 1.8, < 2"` のような範囲はその内側の全バージョンに一致する。**どれか 1 つの記録の
どれか 1 つの要素**を満たせばその gem は verified、つまり**どれか 1 つの環境で検証
されていれば verified** である。`rubycc doctor` の note 欄には、実際に合致した記録の
環境名が並ぶ。

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

記録先の選び方は、その実行が**どの環境で走ったか**で決まる:

- そのエントリに `environment` が一致する記録がある → **その記録だけ**を更新する
  (`versions` は和集合、`verified_at` は当日、`evidence` は追記)。他の環境の記録は触らない
- エントリはあるが、その環境の記録が無い → `verifications` の**末尾に新しい記録を足す**。
  `evidence` はこのとき新規形から始める(他環境で測った証拠を引き継ぐと、
  そこで測っていない事実をその環境で測ったことにしてしまう)
- エントリ自体が無い → 記録 1 本と `notes` を持つ新エントリを作る

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
- **`notes` は人間の責務**であり、**このファイルで唯一、手で書き換えてよい欄**。
  エントリ階層にあり、環境をまたいだ但し書きを書く。新規エントリで `--notes` を省略すると
  空文字が入り、警告が出る。
  「機械が観測できない但し書き」(racc の `lib/racc/parser-text.rb` を手で補った、など)は
  必ず手で書き加えること。既存エントリを更新するとき、ツールは `notes` を**保持**する
  (実測できる skip / pending / omission の件数だけは事実として追記する)。
  ツールが上書きしないのは「機械が人間の但し書きを消さない」ためであって、
  **人間が古くなった但し書きを直すのは正しい操作**である
  (実例: stackprof の「`dlclose` 後始末は保証されない」は Step 156 で解消したので
  手で書き換えた)。`versions` / `environment` / `verified_at` / `evidence` は
  verification 記録の側にあり、実測から生成される欄なので、**手では触らない**こと。
- **`notes` に「X ではまだ未検証」と書いてはならない**。ある環境で未検証であることは
  **その環境の verification 記録が無いこと**で既に表現されている。散文にも書くと
  同じ事実の管理箇所が 2 つになり、片方(必ず散文の側)が古くなる。実際、
  全エントリが持っていた "musl and aarch64 not yet verified." がこれで、
  スキーマを入れ子にしたときに削除した。
- **既存の verification 記録の `evidence` は上書きではなく追記**される。`evidence` は
  **その環境で**その gem を確認した全ステップの履歴を溜める欄で(json は Step 54・61・64、
  msgpack は Step 138 で H4 の 1 文が足された)、今日の実走は「今日測った事実」を
  足すだけであり、過去の確認が無かったことにはならない。上書きすると再実行では
  復元できない部分が黙って消える。ただし**その環境の記録を新たに作るときは新規形から
  始める**(他環境の履歴を引き継ぐと、そこで測っていない事実を主張することになる)。
- **`test/test_doctor.rb` の許可リストは手で更新する**。
  `test_verified_gems_json_holds_only_confirmed_gems` が持つ gem 名の許可リストと
  DB のキー集合が食い違うと、ツールは貼り付け用の `assert_equal` 行を表示して警告する
  だけで、テストファイルは決して自動編集しない(gem の追加を意識的な編集に留める
  ための意図的なゲート)。

## buildable_gems.json

「**rubycc でビルドできる**」gem の台帳。1 件の記録が主張するのは
**`gem install` が成功し、そのとき rubycc がビルドした `.so` を require でロードできた**
ことだけで、その gem のテストスイートについては何も言わない。

構造は `verified_gems.json` と同じ入れ子(1 gem = 1 エントリ、環境ごとの記録がその内側)で、
配列のキーだけが違う:

| key      | type            | meaning |
|----------|-----------------|---------|
| `builds` | array of 記録   | その gem をビルドできた**環境ごとの記録**。挿入順(古い順)。空にはしない |
| `notes`  | string          | 既知の但し書き。無ければ空文字 |

`builds` の各要素は `verified_gems.json` の verification 記録と同じ 4 欄
(`versions` / `environment` / `verified_at` / `evidence`)を持つ。
`versions` が各記録の内側にある理由も、ある環境で未検証であることを
「その環境の記録が無いこと」で表すのも同じである(上節を参照)。

配列名を `verifications` にしなかったのは、**主張が違うものに同じ名前を使わないため**である。
同じ名前なら、2 つのファイルを `verifications` の件数で足し合わせるコードや読み手が
いずれ現れる。

初期状態は空オブジェクト `{}` である(器を先に用意し、記録はツールが足す)。

### 更新は `tools/verify_corpus_candidate.rb --mode build_load --update` 経由で行う

このツールは固定された identity(name / version / platform / SHA-256)の archive を取得し、
静的ゲートを通したうえで隔離 `GEM_HOME` に `RUBYCC=1 gem install` し、
`.so` が本当にロードできることまで確かめる。台帳に書かれるのは
**`status: build_load_pass` かつ `rubycc_build_evidence: pass`** の結果だけである。

- `rubycc_build_evidence` は `gem_make.out` が `exe/rmake` を、生成 Makefile が `exe/rubycc` を
  指していることの実測であり、これが無い install は「rubycc でビルドできた」ことの証拠にならない。
  `--compiler host` の対照実行は `not_applicable` になるので**決して記録されない**
- `--mode load_sanity` の `documented_load_pass` も記録しない。あれはレシピ固有の
  別の主張(文書化された entrypoint が動く)であり、混ぜない
- 記録先の選び方は `verify_gem_tests.rb` と同じ。**その実行が走った環境の記録だけ**を更新し
  (`versions` は和集合、`verified_at` は当日)、その環境の記録が無ければ `builds` の末尾に足す
- ただし `evidence` は**追記ではなく再生成**する。(d) 水準の evidence はステップ履歴を溜める欄で
  再実行では復元できないが、こちらの evidence はステップにもバージョンにも触れないため、
  再実行すると**同じ 1 文がもう一度できるだけ**であり、追記は重複にしかならない
- `evidence` に「テストスイートが合格した」系の主張は書けない。ツール側が
  `BuildableGemsLedger::CLAIM_OUT_OF_SCOPE` で拒否し、`test/test_buildable_gems.rb` が
  ファイルの側でも固定している。(d) 水準の主張は `verified_gems.json` にしか置けない
- `notes` はこちらでも**人間の責務**であり、ツールは既存の値を保持する

CI(`.github/workflows/corpus-candidate-validation.yml`)はこのフラグを渡さない。
dispatch された実行がチェックアウトを書き換えてはならないためで、
`--update` は**結果を人がすぐ確認するローカル実行のためのもの**である。

書式(インデント 2、`versions` は 1 行のインライン配列)と `environment` の綴りは
`tools/gem_ledger_format.rb` にあり、`verified_gems.json` と共有している。
主張は違ってよいが、**同じ機械が 2 つの名前で記録されては困る**。
