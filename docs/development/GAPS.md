# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/development/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | 何が足りないか | 誰が困るか | 確からしさ | 詳細 |
|---|---|---|---|---|
| **S**([第 2 段の issue](../../issues/platform-abi-alignment.md)) | **`long double` の幅が 8 バイト**(`double` として扱う。DESIGN 3.3 の既知の制限)。**可変長引数に渡す経路は解消済み**(`long-double-varargs-1`) | **残るのは幅に依存するもの** — `sizeof` / `_Alignof` / `max_align_t` / 構造体メンバのオフセット、および**名前付き引数と戻り値**(`frexpl` 等の libc 呼び出しは依然不整合) | **実測**(2026-08-13)。`printf("%Lg", x)` は gcc と一致し、oj の失敗テスト名の集合も対照と完全一致(687 runs / 1 failure / 2 errors、名前も同一) | **オブジェクトファイルの ABI が変わる**ので、他の既知逸脱(enum の底型、`wchar_t` の符号性)と**まとめて 1 つの major** で閉じる |
| **T**([issue](../../issues/struct-returning-initializer-element.md)) | **配列の要素数をパーサが数える文脈で、struct を返す式が単一式初期化子として読めない** | `pt b[] = { {1,2}, fp(), {5,6} };` が gcc では 3 要素になるのに rubycc は拒否する。パーサは `[]` の長さをここで確定させる必要があるが、型表を持たないので `fp()` の型が分からない | **実測**(2026-08-08) | struct を直接初期化する形は通る(atomic-type-13)。**`gaps-s-t-u-2` で診断だけ正直にした**(以前は `excess elements in scalar initializer` という的外れな文言だった)。解消にはパーサ側に型を引く手段が要る |
| **AG**([issue](../../issues/zero-length-array.md)) | **長さ 0 の配列(GNU 拡張)を拒否する**。規格(6.7.6.2p1)には忠実だが gcc は既定で受理する | `binding_ninja` 0.2.3 の `dummy_method_arg[0]` が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現で `array size must be positive`) | 受理するか対象外にするかを**根拠付きで決めてから**実装する。フレキシブル配列メンバの扱いを先に測る |
| **AH**([issue](../../issues/thread-local-storage.md)) | **スレッドローカル記憶域が無い** — C11 の `_Thread_local` も GNU の `__thread` も `expected type specifier` で拒否する。コンパイラに言及が 1 つも無く、記憶域クラスとしてまるごと無い | TLS 変数を宣言するヘッダを含む gem。`pg_query` 6.2.3 が同梱 postgres ヘッダの `__thread` で、`scout_apm` 6.3.0 が `allocations.c:29` の `static __thread` で落ち、**対照の gcc はどちらもビルドに成功する** | **実測**(2026-09-13、最小再現で両方とも拒否) | **マイルストーン級**。ELF の TLS セクション・TLS 再配置・`%fs` / `tpidr_el0` 相対の生成が要り、拡張は `.so` なので**動的モデルでないと実在の gem に効かない** |
| **AK**([issue](../../issues/labels-as-values.md)) | **ラベルのアドレス(`&&label` / `goto *p`、GNU 拡張)を受け付けない**。診断は `expected expression` で原因を伝えない | 表引きのディスパッチを持つ gem。`strptime` 0.2.5 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現) | **実装するか対象外(基準 H)にするかが未決**。どちらでも診断は直す |
| **AN**([issue](../../issues/incompatible-function-pointer-argument.md)) | **gcc 13 が警告にとどめる 4 つの診断をエラーにする** — 互換でないポインタ・暗黙の関数宣言・暗黙の int(`expected type specifier` で原因を伝えない)・整数とポインタの変換。gcc 14 はどれも既定でエラー | 古い書き方の gem。`hpricot` / `fast_xs` / `fast_trie` / `zipruby` / `github-markdown` / `gctools` / `semacode-ruby19` / `picky` / `allocation_tracer` / `ruby_deep_clone` の 10 件が該当し、**対照の gcc 13 はどれも通る** | **実測**(2026-09-13、gcc 13 のみ。gcc 14 はこのホストに無い) | **警告に下げるかエラーを保つかが未決**。対照の版で結論が変わる |
| **AS**([issue](../../issues/rmake-gnu-make-conditionals.md)) | **rmake が GNU make の条件文(`ifeq` など)を読めない**。パーサは代入とルール以外をすべて拒否する | 同梱ライブラリの手書き Makefile を make に渡す gem。`hiredis-client` 0.30.1 が該当し、**対照(GNU make)は通る** | **実測**(2026-09-13) | **対応するか対象外にするかが未決**。mkmf の Makefile は条件文を使わない |
| **AT**([issue](../../issues/typeof-operator.md)) | **`typeof`(GNU 拡張、C23 で標準化)を受け付けない**。未宣言の関数として報告される | `algorithms` 1.1.0 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現) | **実装するか対象外(基準 H)にするかが未決**。どちらでも診断は直す |
| **BI**([issue](../../issues/aarch64-cross-sysroot-include.md)) | **x86-64 ホストで `-target aarch64` のとき、同梱していないシステムヘッダをクロス sysroot(`/usr/aarch64-linux-gnu/include`)から探さない**。ホストの x86-64 版 `/usr/include/netdb.h` を読んで `bits/stdint-uintn.h` で落ちる | x86-64 ホストでの aarch64 クロステスト。`<netdb.h>` を含むコードを aarch64 で検証できない。**対照の `aarch64-linux-gnu-gcc` は通る** | **実測**(2026-09-14、`#include <netdb.h>` の最小再現)。ネイティブ aarch64 ホストは未測定 | sysroot を決め打ちにするか、クロス gcc に問い合わせるかを決める |
| **BQ**([issue](../../issues/aligned-attribute-member-typedef.md)) | **メンバの宣言子と typedef 名に付けた `aligned` 属性を捨てる**。`struct { long a __attribute__((aligned(16))); long b; }` の整列が gcc は 16、rubycc は 8。診断は出ない | 構造体の配置が gcc とずれ、gcc でコンパイルしたコードと構造体をやり取りすると壊れる。**実在の gem ではまだ見ていない** | **実測**(2026-09-14、`_Alignof` の最小再現) | メンバ・typedef・変数の宣言子の属性をまとめて gcc と突き合わせる |
| **BR**([issue](../../issues/sysv-over-aligned-aggregate-stack.md)) | **x86-64 で 32 バイト整列の集約を値で渡すと、スタックの置き場所が gcc とずれる**(gcc は 32 境界、rubycc は 16 まで) | 32 バイト以上に揃えた構造体を gcc の関数と値渡しするコード。**実在の gem ではまだ見ていない** | **実測**(2026-09-14、`aapcs64-aligned-attribute-aggregate-1` の行列の x86-64 側) | 固定引数と `va_arg` の両方で 32 / 64 境界を gcc に合わせる |
| **BS**([issue](../../issues/sysv-padding-eightbyte-class.md)) | **x86-64 で後半が詰め物だけの集約を可変長引数に渡すと、xmm を 1 つ余分に使う**(gcc は後半にレジスタを割り当てない) | `struct { float a, b; } __attribute__((aligned(16)))` のような形を可変長で gcc とやり取りするコード。固定引数は一致。**実在の gem ではまだ見ていない** | **実測**(2026-09-14、同上) | メンバの無い eightbyte の分類(psABI の NO_CLASS)を確かめてから直す |
| **BO**([issue](../../issues/glibc-alloca-without-gnuc.md)) | **glibc 本体の `<alloca.h>` を読む経路で、`alloca` がリンク時に未定義参照になる**(glibc は `__GNUC__` のときだけ組み込みに写し、rubycc は `__GNUC__` を定義しない) | aarch64 のクロス sysroot を使う例題テストなど、同梱ヘッダより先に glibc 本体の `<alloca.h>` を読む構成。**実在の gem ではまだ見ていない** | **実測**(2026-09-14、例題に `alloca` を入れて aarch64 で) | どの経路で glibc 本体の `<alloca.h>` を読むかを先に測る |
| **BP**([issue](../../issues/glibc-public-headers-mixed.md)) | **同梱しない glibc の公開ヘッダ 186 本のうち、rubycc だけが落ちるものが 23 本ある**(`__BEGIN_DECLS` が無いように見える形が多い) | それらのヘッダを含む gem。該当する gem は数えていない | **実測**(2026-09-14、`tools/audit_bundled_headers.rb` の混在の調査、x86-64) | 23 本の原因を最小再現で確かめ、同梱ヘッダの側と rubycc 本体の側に分ける |

## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|
| **同梱ヘッダの範囲が「コーパスが使った分だけ」**([issue](../../issues/bundled-headers-coverage-audit.md)) | 突き合わせの表([BUNDLED-HEADERS-COVERAGE.md](BUNDLED-HEADERS-COVERAGE.md))はできた。**差分の分類が済んだのは 54 本のうち 5 本**で、残りの同梱ヘッダでは抜けが当たり続ける。共有ガードの点検は x86-64 だけ | 中 | 表を使って、残りのヘッダも足す / 意図して外すを決める。aarch64 の点検は BI の後 |

## 3. 環境が無くて測れていないこと

「rubycc の欠陥」ではなく**未測定**である点でギャップと区別する。
解消には環境整備(コンテナ / CI マトリクス)が要る。
**計画は ROADMAP §8 H6「環境が無くて測れていないことの解消」(default gem 検証の 7 件計画の後、3 ステップ)。**

| 未測定 | 詳細 |
|---|---|
| ~~**musl** での全検証~~ | **測定した(Step 175)**。結果は緑ではなく、ギャップ G・H・I として §1 に移し、いずれも解消した(H は Steps 177〜179、I は Step 196、G は Steps 193・204 で、Step 205 に突き合わせの記録)。`data/verified_gems.json` の musl 記録は**3 件になった**(`json` / `stringio` / `io-wait`。2026-08-27 に実測)。**Tier B の `musl` ジョブは 2026-08-09 以降赤かったが、2026-09-01 に緑に戻した** — 原因は 2 つで、共有オブジェクト系 2 件は [PR #117](../../issues/musl-shared-object-regression.md)、glibc 専用フィクスチャの 1 error は [PR #119](../../issues/host-header-shim-glibc-only.md) で解消。[run 33526840347](https://github.com/nuna/rubycc/actions/runs/33526840347) が **3416 runs / 0 failures / 0 errors**(skips は 581 → 582 で、増えたのは意図した 1 件だけ)|
| ~~**aarch64 での gem install 実走**~~ | **限定測定済み(Step 208)**。qemu 上の glibc / aarch64 Ruby 4.0.6 で `io-wait` と `stringio` の gem install・gem 自身のテストが通った。**全スイートは `test-ci-implementation-4` で解消**([weekly run 31345396123](https://github.com/nuna/rubycc/actions/runs/31345396123)、native `ubuntu-24.04-arm` 上の Ruby 3.3 / 4.0 が success)。~~`json` / `msgpack` の aarch64 上 `gem install`~~ も **`m4-aarch64-acceptance-2` で完了**(arm64 コンテナの aarch64 Ruby 4.0.6 で json 596 tests / msgpack 455 examples が 0 failures。`data/verified_gems.json` に記録あり)|
| ~~真の distroless コンテナ検証~~ | **測定済み(Step 202)**。glibc / musl の `ruby:4.0` distroless相当で json / msgpack / sqlite3 / pg のビルドとrequireに成功 |

## 4. 方針として受け入れたもの(ギャップではない)

**直す気が無いのではなく、「直さない」と判断したもの。** 再検討の条件を必ず書くこと。

| 事項 | 判断 | 再検討の条件 |
|---|---|---|
| **共有ライブラリのシンボル介入を尊重しない**(自分で定義し自分で参照するグローバルシンボルを直接束縛する。データ・関数の両方で実測) | **現状維持**(`ld -Bsymbolic` 相当)。**R9 が列挙する ABI は影響を受けない** — 逸脱するのは ELF の動的リンク時のシンボル解決。多くのディストリビューションが性能のため意図的に有効化している正規の構成であり、gcc の既定に合わせると PLT 経由になって遅くなる | **実在の gem で実害が出たとき**。`LD_PRELOAD` による差し替えが効かない、または同名シンボルのコピーが 2 つ生きて片方への書き込みがもう片方から見えない、という形で現れる。**その時点で再検討する**(ユーザ判断、2026-08-06) |

## 5. 閉じたギャップ(参照のみ)

- **ギャップ BK**(AArch64 で型属性 `aligned(16)` の構造体の置き場所が gcc とずれる):
  `aapcs64-aligned-attribute-aggregate-1` で解消。AAPCS64 の偶数レジスタへの切り上げとスタックの 16 境界を、集約そのものの属性を除いた「メンバの整列」で決めるようにした。
  規則は gcc 13.3 の測定から導いた(AAPCS64 の文書は読んでいない)。
- **ギャップ BN**(同梱 `sys/types.h` の `ushort` が `unsigned char`):
  `bundled-sys-types-ushort-1` で解消。同じ節の BSD の省略名 11 個を両 arch で gcc と測り、食い違っていた `ushort` だけを `unsigned short` に直した。
- **ギャップ AF・AM・AQ・AR・BA・BB・BG・BL**(同梱ヘッダの抜けと共有ガード):
  `bundled-headers-coverage-audit-2` で解消。突き合わせの表(`bundled-headers-coverage-audit-1`)から同梱ヘッダの側に足した。
  共有ガードの点検で見つかった `siginfo_t` の同じ形の穴も直した。§2 の負債は、分類が残る分だけ優先を中に下げて残した。
- **ギャップ BM**(関数名を括弧で囲んだ関数定義を拒否する):
  `function-definition-parenthesized-name-1` で解消。括弧の中の宣言子が「接尾辞なし」を `nil` に落としていたため、外側の仮引数並びが捨てられ、typedef 経由の定義と取り違えていた。
- **ギャップ BC**(`__atomic_*` ビルトインが 1 / 2 バイトの対象を拒否する):
  `atomic-builtin-small-widths-1` で解消。フェンスを除く 18 形を 1 / 2 / 4 / 8 バイトに広げ、ビット演算の fetch 形 10 形を足した(x86-64 / AArch64)。
  iodine 0.7.59 は atomic の段を越え、残りは AT・BL・BM に移した。
- **ギャップ AJ**(可変長引数に構造体・共用体を値で渡せない):
  `variadic-aggregate-argument-1` で解消。呼び出し側は固定引数と同じ経路で渡し、呼ばれ側の `va_arg(ap, struct T)` は同じ分類で値を探す。
  x86-64 と AArch64 の両方で、両方向とも 238 通りの呼び出しが gcc 同士と一致した(2026-09-14)。
- **ギャップ BJ**(定義済み識別子 `__func__` が無い):
  `predefined-identifier-func-1` で解消。構文解析の段で、囲む関数の名前の文字列リテラルに置き換える。
  `__FUNCTION__` / `__PRETTY_FUNCTION__` も同じ(C モードの gcc の実測どおり)。ファイルスコープの `__func__` は gcc と同じ警告を出して `""` になる。
- **ギャップ AU**(同梱 `pthread.h` が `pthread_attr_t` を glibc のガード無しで定義する):
  `bundled-pthread-attr-guard-1` で解消。glibc と同じく、typedef を `__have_pthread_attr_t` で 1 回に絞り、共用体の中身を別に定義した
  (x86_64 / aarch64 の両方)。`<netdb.h>` と `<pthread.h>` をどちらの順で含めても同じ型になる。他の同梱の型に glibc 共有のガードは無かった。
- **ギャップ BH**(rmake が、生成されるソースを経由して接尾辞規則をつなげない):
  `rmake-suffix-rule-generated-source-1` で解消。推論規則のソースが存在しなくても、明示規則や別の推論規則で作れるなら使う。
  作れない前提条件は GNU make と同じ文言(`No rule to make target ...`)でその場で止める。これに合わせて、前提条件の
  ワイルドカード(`gen/*.rb` など)を展開するようにした(以前は黙って無視していた)。
- **ギャップ BE**(ラベルの直後に単独で置いた属性の文を拒否する):
  `attribute-statement-after-label-1` で解消。AY の属性の空文の処理を切り出し、ラベルの後の 1 文を読む経路からも使った。
- **ギャップ BF**(旧形式で宣言した名前付き関数を、仮引数付きで再宣言・定義・呼び出しできない):
  `unprototyped-function-redeclaration-1` で解消。関数の宣言表に `prototyped` を持たせ、再宣言を BD の合成型の規則(6.2.7p3)で
  合成する。旧形式の宣言しか見えていない関数の呼び出しには、既定の実引数拡張をかける。
- **ギャップ BD**(仮引数付きの関数ポインタを旧形式の `void (*)()` へ代入できない):
  `unprototyped-function-pointer-compat-1` で解消。関数型に `prototyped` を足し、C11 6.7.6.3p15 の互換と 6.2.7p3 の合成型を
  代入・比較・条件演算子・再宣言・ファイルスコープの初期化子に使った。旧形式の関数ポインタ経由の呼び出しは引数の数を
  照合せず、既定の実引数拡張をかける。名前付き関数の再宣言は残った(BF)。
- **ギャップ AL**(マクロ展開の予算がソースを素通りするトークンまで数える):
  `expansion-budget-source-tokens-1` で解消。予算を、マクロの置換が生んだトークンだけに課すようにした。
  上限の値(100 万)と、暴走するマクロを拒否する性質は変えていない。
- **ギャップ AZ**(`__builtin_strlen` が無い):
  `builtin-strlen-1` で解消。文字列リテラルの引数は構文段階で定数に畳み(gcc と同じく配列の大きさ・静的初期化子・
  `case` ラベルで使える)、それ以外は `strlen` の呼び出しに書き換える。同族の 11 綴りは需要が出るまで足さない。
  最初から登録した `strlen` のプロトタイプがプログラム自身の宣言と衝突した退行は、`builtin-strlen-2` で直した
  (登録したプロトタイプはプログラムの最初の宣言に譲る)。
- **ギャップ AV**(`-I/usr/include` で glibc 本体のヘッダが同梱ヘッダより先に見つかる):
  `include-duplicate-system-dir-1` で解消。gcc と同じく、システムのディレクトリと実ディレクトリが一致する
  `-I` / `-isystem` / `-idirafter` を探索パスから外した(末尾のスラッシュ・`..`・シンボリックリンクも同じとみなす)。
- **ギャップ AY**(文として書いた `__attribute__ ((fallthrough));` を拒否する):
  `attribute-statement-1` で解消。属性の並びの後が宣言でなく `;` なら、空の文として読む(gcc の「空の宣言」と同じ形)。
  R7 のとおり属性の中身は構文として受理して捨てる。**ラベルの直後に単独で置いた形は残った**(BE)。
- **ギャップ AW**(構造体のメンバ宣言の頭の `__extension__` を受け付けない):
  `extension-struct-member-1` で解消。メンバ宣言でも既存の読み飛ばしを使った。glibc の `<threads.h>` が
  rubycc でビルド・実行できるようになったので、`__STDC_NO_THREADS__` の定義を外した(C11 6.10.8.3)。
- **ギャップ AE**(CRLF の行末で行連結が働かない):
  `crlf-line-splice-1` で解消。翻訳フェーズ 1 で `\r\n` と単独の `\r` をどちらも改行に写像した。
  起票時は「単独の `\r` を改行扱いしない」と書いたが、gcc を測ると単独の `\r` もトークンの種類を問わず改行として扱う
  (文字列リテラルの中の生の CR もリテラルを終わらせる)ので、それに合わせた。
- **ギャップ AX**(エスケープ `\e` を未知のエスケープとして拒否する):
  `escape-sequence-e-1` で解消。`\e` / `\E` を ESC(0x1B)として、文字列・文字定数・wide 文字定数で受理した。
  規格に無い他のエスケープ(`\q` など)は gcc が警告止まりでも、従来どおりエラーのまま残した。
- **ギャップ AO**(`#include` に絶対パスを書くと、実在するファイルでも開けない):
  `include-absolute-path-1` で解消。`resolve_include` / `resolve_include_next` の両方に
  「名前が絶対パスならディレクトリ結合をせずそのまま試す」分岐を先頭に足した。絶対パスで開いた
  ファイルは `#include_next` の起点を記録しない(検索パスに沿って見つかったわけではないので)。
  `numo-narray` 0.9.2.1 のビルドは、マージ後にメインセッションが測る。
- **ギャップ AP**(VLA に対応しないのに `__STDC_NO_VLA__` を定義していない):
  `stdc-no-vla-macro-1` で解消。C11 6.10.8.3 の他の条件付き機能マクロも同時に測り、
  `__STDC_NO_COMPLEX__`/`__STDC_NO_THREADS__` は同じく未対応なので定義したが、
  `__STDC_NO_ATOMICS__` は `_Atomic`/`<stdatomic.h>` が実際に動くため定義しなかった。
  brotli 0.8.0 が実際に `build_load_pass` になるかは、マージ後に `rake corpus:census` で確かめる。
- **ギャップ AI**(ファイルスコープの `extern int x = 1;` を拒否する):
  `extern-initializer-file-scope-1` で解消。C11 6.9.2p1 の例のとおり外部定義として
  受理し、IR 生成器が `.data` に実体を出すよう変えた。制約違反はブロックスコープの
  場合だけ(6.7.9p5)なので、そちらのエラーはそのまま残した。
- **ギャップ AD**(`ELFReader` が返す名前が UTF-8 タグ付き):
  `elf-reader-name-encoding-1` で解消。**起票から解消まで同じ日**である —
  `ar-reader-name-encoding-1` が `ArReader` 側だけを規約に揃えた結果、
  食い違いが 2 つのリーダの間に移ったので、続けて閉じた。
  `#symbol` / `#section` が書いたときのバイト列で引けるようになり、
  ar のテストに残していた `.b` の回避も外れた。
- **ギャップ AC**(引数として渡されたマクロ名に hide-set を足していなかった):
  `macro-argument-hide-set-1` で解消。`f(f)(1)` が gcc と同じ `f(1)` になった。
  **起票から解消まで 1 日**で、前ステップ(`macro-hide-set-intersection-1`)の
  受け入れ条件を実測で確かめる過程で見つかったものである。
- **ギャップ AB**(`ArReader` が返す名前の綴りが名前の長さで変わる):
  `ar-reader-name-encoding-1` で解消。`force_encoding` を外して全部バイト列に揃え、
  `exe/rubycc-ar` 側で吸収していた `member_key` を外した。**懸念されていた
  「リンカの遅延展開」への波及は無かった**(リンカは ar のシンボル索引を消費していない)。
  代わりに、非 ASCII のメンバ名を UTF-8 のパスと補間する診断で**元から落ちていた**のが
  見つかり、同ステップで閉じた。ELF 側の同じ逸脱は AD に分けた。
- **ギャップ W**(差分テストが「gcc 13 ではこれは警告」を前提にしていた):
  `m4-aarch64-acceptance-3` で解消。**3 種類に分かれた**のが要点である。
  (1) 対照 gcc に `-std=gnu17` を明示(rubycc が実装しているのは C11/C17 で、
  gcc の既定は版で変わる)。(2) `TestAtomicType` は**テストのソースが誤っていた** —
  `int * _Atomic` に `_Atomic int *` を代入しており、gcc 13 が警告で見逃していただけ
  なので直した。(3) K&R の 2 件は rubycc が**意図的に受理している旧構文**(implicit int、
  C99 で削除)なので、対照にだけ `-fpermissive` をオプトインで渡す。
  **全体に適用しなかった**のは、他のテストでは「gcc が拒否すること」自体が
  テスト側の C の誤りを知らせる信号だからである(実際 (2) はその形で見つかった)。
  gcc 14.2 の環境で 3 件とも消えることを実測(76 runs / 0 failures)。
- **GAPS Q**(K&R 旧形式の関数定義): Step `atomic-type-10` で実装。
  mysql2 の別の最後のブロッカーも Step `atomic-type-11` で解消し、
  Step `atomic-type-15` で上流 spec が `340 examples / 0 failures / 6 pending` となったため閉じた。
- **Step 146 の 6 件**(stackprof / nkf の検証が露出): Steps 147〜152 で全て解消。
- **Step 157 の A〜D**(etc の検証が露出): Steps 158〜161 で全て解消し、
  Step 162 で etc 1.4.6 が検証済みになった。**E だけが上の表に残っている。**
- **Step 172 の F**(psych の検証が露出。rmake に `MAKE` マクロが無く再帰 make が
  no-op になる): Step 173 で解消。
- **Step 175 の H**(musl の実測が露出。同梱ヘッダに `stdckdint.h` が無い):
  Steps 177〜179 で解消(組み込み関数 → aarch64 の `:mulhi` → ヘッダ本体)。
- **Step 181 の J**(musl の 2 回目が露出。`_Noreturn` 関数指定子の未対応):
  Step 182 で解消。
- **Step 187 で記録した「週次 census ジョブが構造的に必ず赤くなる」**: Step 188 で解消
  (スナップショットから実行ごとに変わる 3 種類の情報を外した)。
- **Step 157 の E**(同梱 `fcntl.h` に `F_GETPIPE_SZ` / `F_SETPIPE_SZ` が無い):
  Step 189 で解消。両ターゲットで実測して追加し、Ruby の `Fcntl` が公開する
  定数と**過不足なく一致**することを確認した。
- **Step 183 の K**(`offsetof` を定数式に畳めない): Steps 184・187 で解消
  (cast 形と引き算形の両方)。**musl がどちらの綴りかを確かめずに済ませないため、
  両方に届かせた。**
- **Step 190 の L**(同梱ヘッダが musl の `__isoc_va_list` を提供しない):
  Step 191 で解消。両方の綴りを無条件に提供した(同じ型の別名なので
  片方だけを選ぶ理由が無い)。
- **Step 175 の I**(ABI ハーネスが glibc 固有): Steps 180・181 で分類し、
  **musl 実走 3 回連続で「対照が先に落ちる」ケースが 0 件**であることを確認して
  Step 196 で閉じた。
- **Step 194 の M**(`rubycc-pkgconf` のシステムパス除外が Debian 決め打ち):
  Step 196 で解消(multiarch のパスは実在するときだけシステム扱いにする)。
  ただし**その修正が隠れていた `-L` の重複を露出させ**、Step 199 で畳んだ。
- **Step 200 の O**(`float.h` が x86-64 の `long double` を全機種に出していた):
  Step 201 で解消。**aarch64 の ABI ハーネスに `float.h` の検査を足した**ので、
  同じ見落とし(freestanding 層は機種に依らないという思い込み)は繰り返さない。
- **Step 200 の P**(aarch64 musl で `stdio.h` のプローブがリンクできない):
  Step 206 で解消。**rubycc の欠陥ではなく ABI ハーネスが両側に違うフラグを
  渡していた** — gcc 側は既定の `-fPIE`、rubycc 側は非 PIC。gcc 自身の
  `-fno-pie` オブジェクトも同じリンクエラーになることを実測で確かめた。
- **Step 175 の G**(同梱ヘッダが glibc の ABI を焼き込んでいる):
  x86-64 は Step 193、aarch64 は Step 204 で解消。**両機種とも本物の musl gcc と
  突き合わせて 0 failures を確認した**(Step 205)。
- **真の distroless コンテナ検証**: Step 202 で glibc / musl の両方を実測。
  cc / gcc / clang / make / sh と libc 開発ヘッダを除いた状態で、4 gem の
  `--platform ruby` ビルドと実行に成功した。**この行が併記していた「musl 全スイートと
  aarch64 の `json` / `msgpack` は未完了」は古い** — aarch64 側は
  `m4-aarch64-acceptance-2` で完了し、musl 側も **2026-09-01 に週次が緑に戻った**
  ([共有オブジェクト系 2 件](../../issues/musl-shared-object-regression.md)と
  [glibc 専用フィクスチャの 1 error](../../issues/host-header-shim-glibc-only.md)の 2 つが原因だった)。

- **ギャップ V**(既定のシステム include 探索パスが x86-64 の multiarch 決め打ち):
  `test-ci-implementation-9` で解消。**当初 U と採番したが、§1 の U(`__GLIBC_MINOR__`)と
  衝突していたので、閉じた側をここで V に振り直した**(開いている側の記号を動かすと
  参照が壊れるため)。Debian の multiarch ディレクトリは target ごとに
  名前が違う(`bits/` の中身が別物)ので、同梱 arch 層とまったく同じく `libc_arch` に
  従わせた。**`float.h`(Step 201)・`math.h`(`test-ci-implementation-2`)に続いて
  3 件目の「freestanding/共通層は機種に依らない」という思い込み**である。

- **ギャップ U**(同梱 `features.h` が `__GLIBC_MINOR__ 39` をハードコードしていた):
  `gaps-s-t-u-1` で解消。libc 自身の `.gnu.version_d` から**実測**する形にした
  (ホスト固有のパスは書かない。測れないときは定義せず、従来値 39 をフォールバックに残す)。
  これで `test_header_abi.rb` の `__GLIBC_MINOR__` / `__GLIBC_PREREQ` 検査が
  **2.39 以外のホストでも通る**ようになった。

いずれも設計判断は STEPS.md の各ステップに記録がある。
