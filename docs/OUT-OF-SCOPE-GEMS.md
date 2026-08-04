# スコープ外の gem

rubycc が **対応しないと判断済み**の gem を、理由と根拠つきで並べる。

DESIGN の R10 は目標を「コーパスの 90% 以上」と定量化しており、**残りの 10% を
どこに置くかを決めているのがこの文書**である。「まだ通らない」と「通す気がない」は
別物で、前者は `docs/GAPS.md`、後者はここに書く。

**この一覧は網羅ではない。** 人気ランキングを全走査した結果ではなく、
コーパス拡張(`.claude/skills/corpus-expansion/SKILL.md`)の過程で実際に当たったものと、
DESIGN が設計時に名指ししたものを集めたものである。
根拠の種類(実測か、設計時の判断か)を各行に明記する。

## 1. 判断基準(DESIGN §3.3 / R10)

| # | 基準 | なぜ対象外か |
|---|---|---|
| **A** | **C++ を使う** | rubycc は C コンパイラである。C++ フロントエンドは v1.0 のスコープに無い |
| **B** | **実体のあるアセンブリ(`.S` / インライン asm)を含む** | rubycc にアセンブラは無い。ELF を直接書き出す設計で、`.S` を受け取る経路そのものが無い |
| **C** | **autoconf の `configure` を実行する vendored ビルド**(mini_portile 系) | `configure` は POSIX シェルを必要とする。**シェルへの非依存は rubycc の存在理由そのもの**(R1)であり、ここを緩めると要件が崩れる |
| **D** | **上流にテストスイートが無い** | 検証済みと言えるのは「gem 自身のテストが rubycc がビルドした `.so` に対して通った」ときだけ(証拠水準 (d))。スイートが無いと**原理的にその証拠が得られない** |

**C には重要な例外がある** — `--use-system-libraries` などでシステムライブラリを使う
モードがあるなら、**そのモードは対象内**である。DESIGN R10 は
「sqlite3(システムライブラリ利用時)」を**想定内の例**として名指ししている。

## 2. 対象外と判断した gem

| gem | 基準 | 理由 | 根拠 |
|---|---|---|---|
| **ffi** | B | `ext/ffi_c/libffi` に **`.S` を 48 本**同梱する | **実測**(STEPS.md Step 139 のコーパス走査)。候補中でダウンロード最多(10.6 億)だった |
| **bcrypt** | B | `ext/mri/extconf.rb` が `$objs` に **`x86.o` を明示列挙**しており、これは同梱の `x86.S` から作られる | **実測**(同上)。**C ソースだけ見ると通りそうに見える**のが要点で、「C++ ファイルがあるか」しか見ない機械判定では捕まらない |
| **nokogiri** | C | vendored ビルドが mini_portile 経由で `configure` を実行する | **実測**(STEPS.md Step 143、人気ランク 1〜20 の走査)。ただし**システムライブラリ利用モードなら基準 C の例外に当たる**ので、将来そのモード限定で対象化する余地はある |
| **grpc** | A | C++ | **設計時の判断**(DESIGN §3.3 が名指し)。実測はしていない |
| **rice** | A | C++ 拡張を書くためのライブラリそのもの | **設計時の判断**(DESIGN §3.3) |
| **eventmachine** | A | C++ 拡張 | **観測**(`test/corpus/include-census.md` の thin の注記。thin 自身の拡張は純 C だが、実行時依存の eventmachine が C++ なので `gem install thin` は結局 C++ を要求する) |
| **fcntl** | D | 上流にテストスイートが無い | **実測**(STEPS.md Step 157)。**同梱ヘッダの穴埋め対象からも外している** — 埋めても検証済み gem は増えないため(GAPS.md の E がその記録) |
| **sqlite3(既定のインストール)** | C | 既定では `MiniPortile` が上流 sqlite3 の `configure` を実行する | **実測**(STEPS.md Step 186)。**`--enable-system-libraries` を付けた経路は対象内**。詳細は §3 |

### thin の扱いに注意

**thin 自身の C 拡張は純 C で、対象内**である(センサスも `ok` と判定している)。
対象外なのは**実行時依存の eventmachine** の方で、
`gem install thin` を丸ごと通すには C++ が要る。
**「gem が対象内か」と「その gem を install できるか」は別の問い**であり、
この一覧は前者を扱う。unicorn も同じ形(依存の kgio / raindrops が C 拡張)だが、
そちらは C なので対象内である。

## 3. 機械判定が `excluded` と出す 2 件 — **中身は別物**

`test/corpus/census.rb` の R10 判定は
**「extconf.rb のどこかに `mini_portile` という文字列があるか」しか見ていない**
(`configure_dependency?`)。この粗さで sqlite3 と pg が同じ `excluded` になっているが、
**実物の extconf を読むと 2 件は性質がまったく違う**(Step 186 で実測)。

### sqlite3 — 既定の経路は**本当に対象外**。判定は正しい

`ext/sqlite3/extconf.rb` は `system_libraries?`
(`--enable-system-libraries` か sqlcipher 系オプション)で経路を分ける。

| 経路 | 中身 | R10 |
|---|---|---|
| **既定**(`configure_packaged_libraries`) | `MiniPortile` を使い、`recipe.configure_options += [...]` で**上流 sqlite3 の `configure` を実行する** | **対象外**(基準 C) |
| `--enable-system-libraries` | システムの libsqlite3 を探す | **対象内** |

**DESIGN R10 が「sqlite3(システムライブラリ利用時)」と括弧書きしているのは、
まさにこの区別**である。**既定の `gem install sqlite3` は対象外で正しい。**

(なお rubycc は **sqlite3 amalgamation 26 万行を単体でコンパイル済み**である
(STEPS.md Step 116)。ただしそれは「amalgamation をコンパイルできる」話であって、
「既定の `gem install` が通る」話ではない。**混同しないこと。**)

### pg — こちらは**判定の誤り(偽陽性)**

`ext/extconf.rb` の mini_portile 参照は **26 行目の
`if gem_platform = with_config("cross-build")` ブロックの中に丸ごと入っている**。
これは**事前ビルド済みバイナリ gem を作るときだけ**通る経路で、
通常のソースインストールは `pg_config` / pkg-config でシステムの libpq を探す。

**DESIGN R10 は pg をスコープ内として名指ししている。**
つまり pg については、**判定が粗いのであって gem が対象外なのではない。**

## 4. 対象内である境界例(念のため)

**システムライブラリに依存すること自体は対象外の理由にならない。**
むしろ R10 が想定内として名指しする形である。

| gem | 依存先 | 状態 |
|---|---|---|
| zlib | ホストの libz | **検証済み**(STEPS.md Step 171) |
| psych | ホストの libyaml | **検証済み**(Step 172) |
| openssl | ホストの OpenSSL | 未検証(対象内) |
| mysql2 | ホストの libmysqlclient / libmariadb | 未検証(対象内) |

## 5. この一覧の限界

- **網羅ではない。** 「人気上位 N 位を全部調べた」という主張はできない。
  ランキングは日次で動くうえ、外部ランキングサイトは単一障害点になる
  (STEPS.md Step 143 で実際に片方がダウンしていた)。
- **基準 A・B は機械判定では取りこぼす。** bcrypt がその実例で、
  C++ ファイルの有無だけを見ると通りそうに見えるのに、
  extconf を読むと `.S` 由来のオブジェクトを要求している。
  **「対象外である」は extconf を読んで初めて確定することがある。**
- **grpc と rice は実測していない。** DESIGN の設計時の判断をそのまま載せている。
  実測したら別の理由が出る可能性はあるが、C++ であること自体は動かないので
  結論は変わらないと見ている。
- 対象外の判断は**永久ではない**。基準 C は「システムライブラリ利用モードなら対象内」という
  例外を持ち、nokogiri と sqlite3 はその余地がある。
- **この文書の初版(Step 185)は sqlite3 について誤りを書いていた** —
  「既定の経路でも `configure` は走らない」としていたが、実物の extconf を読むと
  既定は `MiniPortile` 経由で上流の `configure` を実行する(Step 186 で訂正)。
  **DESIGN の記述だけを根拠に書き、extconf を読まなかったのが原因**である。
  この文書に載せる判断は、**その gem の extconf を実際に読んでから**書くこと。

## 参照

- `docs/DESIGN.md` §3.1(R10 の定量化)・§3.3(スコープ外の明示)
- `docs/GAPS.md` — **通す気はあるがまだ通らない**もの。この文書とは別物
- `test/corpus/include-census.md` — センサスの機械判定結果
- `docs/STEPS.md` Step 139(ffi / bcrypt)・Step 143(nokogiri)・Step 157(fcntl)
