# スコープ外の gem

rubycc が **対応しないと判断している** gem と、対象内との境界を理由つきで示す。

DESIGN の R10 は、gem のインストール成功と gem 自身のテスト合格を
コーパスの 90% 以上で満たすことを目標にする。ここでは、rubycc の設計上
対応しないものと、R10 の分母から除外されるだけでスコープ外ではないものを
分けて記載する。

**この一覧は網羅ではない。** `test/corpus/gems.rb` の候補と DESIGN が
明示する対象を中心に、現在の判断に必要な例を載せている。

## 1. 対象外とR10分母除外の基準(DESIGN §3.3 / R10)

| # | 基準 | 理由・扱い |
|---|---|---|
| **A** | **C++ を使う** | rubycc は C コンパイラであり、C++ フロントエンドは対象外である |
| **B** | **実体のあるアセンブリ(`.S` / インライン asm)を含む** | rubycc にアセンブラはなく、`.S` を受け取る経路もない |
| **C** | **autoconf の `configure` を実行する vendored ビルド**(mini_portile 系) | `configure` は POSIX シェルを必要とし、シェル非依存という要件に反する |
| **D** | **上流にテストスイートがない** | gem 自身のテスト合格というR10の検証証拠を得られないため、R10の分母から除外する |

Cには例外がある。`--use-system-libraries` や `--enable-system-libraries` など、
gemが提供するシステムライブラリ利用モードは対象内である。DESIGN R10が
「sqlite3(システムライブラリ利用時)」を対象内の例としているのもこのためである。

## 2. 対象外の経路とR10分母から除外する gem

| gem | 基準 | 理由 | 根拠 |
|---|---|---|---|
| **ffi** | B | `ext/ffi_c/libffi` に `.S` アセンブリを含む | gem の ext ソースとビルド対象の確認 |
| **bcrypt** | B | `ext/mri/extconf.rb` が `$objs` に `x86.o` を列挙し、同梱の `x86.S` から生成する | gem の extconf とソースの確認 |
| **nokogiri の vendored ビルド** | C | mini_portile 経由で libxml2 等の `configure` を実行する | gem の extconf とインストール経路の確認 |
| **grpc** | A | C++ 拡張 | DESIGN §3.3 |
| **rice** | A | C++ 拡張を作るためのライブラリ | DESIGN §3.3 |
| **eventmachine** | A | C++ 拡張であり、これに依存する `thin` の通常インストールも止まる | `test/corpus/gems.rb` の依存情報と census 結果 |
| **fcntl** | D | 上流にテストスイートがなく、R10の検証証拠を得られないため分母から除外する | `test/corpus/gems.rb` の `upstream_tests: false` |
| **sqlite3 の既定インストール** | C | bundled sqlite3 のビルドで mini_portile と上流 `configure` を使う | `ext/sqlite3/extconf.rb` の経路確認 |

`nokogiri --use-system-libraries` と `sqlite3 --enable-system-libraries` は、
それぞれシステムライブラリを使う対象内の経路である。

### thin の扱い

`thin` 自身の拡張は純Cであり、ソースだけなら対象内である。ただし通常の
`gem install thin` はC++拡張の `eventmachine` もビルドするため、インストール
全体は対象外となる。`unicorn` の依存である `kgio` と `raindrops` はC拡張なので、
この理由では対象外にならない。

## 3. R10の分母から除外される境界例

R10の分母は `test/corpus/census.rb` の機械判定を通過した gem である。
この判定には、対象外基準A〜Cに加えて、テスト証拠の有無、基準コンパイラでの
上流テスト結果、対象外依存の有無が含まれる。したがって、`excluded` は常に
「rubyccがそのgemをビルドできない」という意味ではない。

| gem | 現在の扱い | 理由 |
|---|---|---|
| `byebug` / `unicorn` / `debug` | R10分母から除外 | 上流テストが基準コンパイラでも合格せず、R10の検証証拠を得られない |
| `pg` | **分母に含む**(`pg-native-source` profile) | mini_portile と `configure` の参照は `--with-cross-build` 経路だけで、通常のソースインストールは `pg_config` / pkg-config でシステムの libpq を使う。raw 判定の偽陽性だったものを profile で上書きしている |
| `thin` | censusでは除外 | 自身は純Cだが、インストール時に対象外の `eventmachine` を必要とする |

`fcntl` は §2 の基準Dによる分母除外である。`sqlite3` は既定経路が基準Cに当たるが、
`sqlite3-system-libraries` profile を宣言して**分母に含めている**。

### raw 判定と profile 判定

`census.rb` の通常判定は「extconf.rb のどこかに `mini_portile` という文字列があるか」
を含む保守的な raw チェックで、`pg` と `sqlite3` を同じ `excluded` にしていた。
現在は DESIGN が名指しする実行経路を profile として明示し、`pg-native-source` と
`sqlite3-system-libraries` の 2 つだけが、宣言された extconf 引数と実ソース中の
branch marker を両方満たしたときに raw 判定を上書きする。未知の profile も条件不足も
fail-closed で除外のままである。

profile は**対象範囲の宣言であって検証記録ではない**。install・extension load・
upstream suite の証拠は `data/verified_gems.json` が持つもので、profile がそれを
代用することはない。この 2 件を分母に入れた結果、R10 の分母は 32 から 34 になった。

## 4. 対象内である境界例

**システムライブラリに依存すること自体は対象外の理由にならない。**
システムライブラリ利用はR10が想定する対象内の形である。

| gem | 依存先 | 状態 |
|---|---|---|
| `zlib` | ホストの libz | 検証済み |
| `psych` | ホストの libyaml | 検証済み |
| `mysql2` | ホストの libmysqlclient / libmariadb | 検証済み |
| `openssl` | ホストの OpenSSL | 対象内・未検証 |

## 5. この一覧の限界

- **網羅ではない。** 対象外の判断は `test/corpus/gems.rb` と DESIGN の対象に
  基づくもので、人気ランキング全体を意味しない。
- **基準A・Bはextconfの確認が必要な場合がある。** C++ファイルの有無だけでは
  bcryptのようなアセンブリ由来のオブジェクトを検出できない。
- **R10の分母除外とスコープ外は別である。** upstreamテストの不合格や
  censusの保守的な偽陽性は、直ちにrubyccの対応対象外を意味しない。
- **システムライブラリ利用経路は対象内である。** vendoredビルドと
  system-librariesオプションの経路を分けて判断する。

## 参照

- `docs/development/DESIGN.md` §3.1(R10の定量化)・§3.3(スコープ外の明示)
- `docs/development/GAPS.md` — 通す対象だが未達のギャップ
- `test/corpus/gems.rb` — 候補、依存、R10分母除外の宣言
- `test/corpus/census.rb` — 現在の機械判定
- `test/corpus/include-census.md` — 生成された現在の判定結果
