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
| **E** | **gem 自身のビルド駆動系が、ツールチェインの提供しない外部ツールを必須にする** | `extconf.rb` ではなく Rakefile を拡張として宣言し、その中で `make` や `sed` を**リテラルに**呼ぶ形。RubyGems プラグインが差し込む `ENV["MAKE"]`(= rmake)は見られないので、**シェル非依存と同じ理由で**最小環境では完結しない。C の親戚だが、`configure` ではなくレシピの側にある |
| **F** | **上流ソースが別 gem のモノレポにあり、その gem 自身のスイートを取り出せていない** | ビルドできないのではなく**(d) 水準の証拠が作れない**という理由の除外である。取り出す手段が確立すれば分母に戻せる — D(そもそもテストが無い)とは性質が違う |
| **G** | **無効化できない経路でベクトル組み込み関数(SIMD intrinsics)を使う** | rubycc は `__m256i` 等のベクトル型も `_mm256_*` の組み込み関数も持たない。**ゲートで落とせるものは対象内である** — コーパスの多くの gem は `arm_neon.h` / `cpuid.h` をprobe の裏に置いており、probe が失敗すればスカラ経路になる。対象外になるのは、**gcc と同じ枝を選んだ上で**ベクトル経路が必須になる形である |
| **H** | **対応しないと決めた C の機能を必須の経路で使う** | VLA・`_Generic`・ワイド文字列・`#pragma push_macro` など、ROADMAP §3 で**診断エラーにすると決めた**もの。**基準 A/B と違い、これは rubycc 側の範囲の話**なので、決定が変われば対象内に戻る |
| **I** | **拡張が C 以外の言語(Rust)で書かれている** | rubycc は C コンパイラであり、`Cargo.toml` を持ち C ソースが 0 件の拡張(rb-sys / magnus 系)には、コンパイルする対象が無い。**基準 A(C++)を広げずに別に立てた** — A の既存の記録の意味を動かさないため |

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
| **digest-crc** | E | 拡張が `ext/digest/Rakefile` で、その中で `sh 'make'` と**リテラルに**書いている。RubyGems プラグインが差し込む `ENV["MAKE"]`(= rmake)を見ないので、システムの make が要る | **実測**(2026-09-10)。`tools/verify_corpus_candidate.rb` を rubycc と host の両方で実行し、隔離した GEM_HOME に rake が無くて**両方が同じ理由で** `build_failed`。Rakefile の該当行は `ext/digest/Rakefile` の `sh 'make', 'clean'` / `sh 'make'` |
| **graphql-c_parser** | F | 上流ソースが独立リポジトリではなく **graphql-ruby のモノレポの中**にあり、「その gem 自身のテストスイート」に相当する tarball が取れない | gem の `source_code_uri` が `rmosolgo/graphql-ruby` を指すことの確認(2026-09-10)。**install と documented load は rubycc で pass 済み**(`corpus-candidate-pilot-v2-graphql-c-parser`)なので、ビルドできないのではなく **(d) 水準の証拠が作れない**という理由での除外である |
| **roaring** | G | `roaring.c:894` の `static inline __m256i popcount256(__m256i v)`。`roaring.h:157` の `#if defined(__x86_64__) || defined(_M_X64)` で `CROARING_IS_X64` が立ち、**gcc も同じ枝を取る** — 分岐選択の食い違いではなく、gcc が `__attribute__((target("avx2")))` と実行時ディスパッチで本当に AVX2 を積んでいる。`ROARING_DISABLE_X64` を渡せば落とせるが、`extconf.rb` はそれを設定しないので、**archive に手を入れずには通らない** | **実測**(2026-08-26、[run 32880666098](https://github.com/nuna/rubycc/actions/runs/32880666098))。ここに至るまでに停止点を 3 つ解消している — `#warning`(PR #84)、`__BYTE_ORDER__`(PR #105)、同梱 cdefs.h の `__attr_*`(PR #106)。詳細は[issue](../../issues/corpus-candidate-pilot-v2-roaring.md) |
| **cbor** | H | `ext/cbor/packer.h:271` の `char buf[len];` — **可変長配列(VLA)**。上流のソースにも `/* XXX */` と注釈がある | **実測**(2026-09-13、`tools/verify_corpus_candidate.rb`)。rubycc は `array size must be an integer constant` で拒否、**対照の gcc は通る**。VLA は ROADMAP §3 で診断エラーと決めた既知の範囲外(c-testsuite 00207 も同じ理由で skip) |
| **thrift** | H | `ext/struct.c:243` の `char name_buf[RSTRING_LEN(field_name) + 2];` — 大きさが実行時の値で決まる**可変長配列(VLA)** | **実測**(2026-09-13、`tools/verify_corpus_candidate.rb`)。rubycc は `array size must be an integer constant` で拒否、**対照の gcc はビルドに成功する**。cbor と同じ文言だが、**同じ文言は定数畳み込みの欠陥でも出る**ので、該当行を読んで VLA と確かめてから記録した |
| **commonmarker** | I | `Cargo.toml` / `ext/commonmarker/Cargo.toml` を持ち、**C ソースは 0 件** | **実測**(2026-09-13、`tools/verify_corpus_candidate.rb` の静的段が `review_required` で停止。`static.native_sources` が空、`build_manifests` に Cargo 一式) |
| **prometheus-client-mmap** | I | 拡張 `ext/fast_mmaped_file_rs` が Rust で、**C ソースは 0 件** | **実測**(同日、同じ静的段で停止。`build_manifests` に Cargo 一式) |

`nokogiri --use-system-libraries` と `sqlite3 --enable-system-libraries` は、
それぞれシステムライブラリを使う対象内の経路である。

### thin の扱い

`thin` 自身の拡張は純Cであり、ソースだけなら対象内である。ただし通常の
`gem install thin` はC++拡張の `eventmachine` もビルドするため、インストール
全体は対象外となる。`unicorn` の依存である `kgio` と `raindrops` はC拡張なので、
この理由では対象外にならない。

### roaring の扱いと、再検討の条件

**対象外にしたのは gem ではなく「ベクトル組み込み関数を必須にする経路」である**(ユーザ判断、2026-09-10)。
選択肢は 3 つあった — (1) SIMD 組み込み関数を実装する、(2) 対象外として記録する、(3) 保留を続ける。
**(1) は M2〜M4 級の規模**で、要求もコーパスからの圧力もこの 1 件では足りない。
**(3) は最も高くつく** — 判断が出ないまま、次に候補を見る人が同じ調査を繰り返す。

**再検討の条件**(どれかが真になったら開き直す):

- **ベクトル組み込み関数を必須にする gem がもう 1 件以上現れたとき。** 1 件では規模に見合わないが、
  複数なら「SIMD を持たないこと」自体がコーパスの上限になる
- **rubycc が別の理由でベクトル型を持つことになったとき**(自動ベクトル化の実装など)。
  組み込み関数はその副産物として近くなる
- **roaring 側が `ROARING_DISABLE_X64` を `extconf.rb` で選べるようになったとき。**
  いま落とせないのは gem の build 設定の問題であって、rubycc の側の問題ではない

**`popcount` 系の組み込み関数は別件である。** roaring の 4 TU のうち 3 つは
`__builtin_popcountll` で止まっており、そちらは
[issue](../../issues/popcount-and-long-bit-scan-builtins.md) として分けてある —
**roaring とは独立に価値がある**ので、この判断では閉じない。

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
