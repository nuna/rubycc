# rubycc GCC 拡張カバレッジ

## `__GNUC__` を定義しない方針とその帰結

rubycc は DESIGN.md R7 の方針により **`__GNUC__` を定義しない**(独自マクロ
`__RUBYCC__` のみを定義する)。ruby.h や多くの gem のヘッダは
`#ifdef __GNUC__` の `#else` 側にポータブルなフォールバック実装を持つため、
`__GNUC__` を名乗らないだけで実装すべき GNU 拡張の表面積は大幅に減る
(例: Step 50 の RB_GC_GUARD は、`__GNUC__` を名乗らないことで自ら
「asm バリア版」ではなく「extern 関数呼び出し版」のフォールバックへ入り、
rubycc はその関数を互換ランタイムとして供給するだけで済んだ)。
この方針が機能する前提が **`__has_builtin` / `__has_attribute` の正直な応答**
(Step 27, 44)である。実装していないビルトイン・属性を偽って「ある」と
答えると、ガード付きコードがフォールバックへ回避せず実装のない機能を呼んで
しまう。逆に正直に「無い」と答え続ける限り、gem 側のポータブルな代替経路が
自動的に選ばれ、rubycc が用意すべき実装面積を最小化できる。

## 分類の定義

| 分類 | 意味 |
|---|---|
| **意味論まで正確に対応** | gcc と同じ効果を持つコード・診断を生成する。実行テスト(多くは gcc 差分比較)またはトークン列比較で検証済み |
| **受理するが実体は何もしない**(無害化) | 構文は受理するが、コード生成や状態変更を一切行わない no-op。rubycc が最適化を行わない・並べ替えを行わないという性質上、no-op であること自体が意味論的に正しいケースを含む(例: `__builtin_expect` のヒント無視、`__asm__` バリア) |
| **正直に非対応と答えてフォールバック誘導** | 「対応しているか」を問い合わせる仕組み(`__has_builtin` 等)に対して、実装していない項目は偽(0)を返す。ガード付きコードは gcc に対しても存在するポータブルなフォールバック経路へ自然に回避する |

各項目には拡張名・分類・実装内容・検証方法・導入 Step を記載する。

---

## 拡張一覧

| 拡張名 | 分類 | 実装内容 | 検証方法 | 導入 Step |
|---|---|---|---|---|
| GNU 文式 `({ 文...; 式; })` | 意味論まで正確に対応 | 一次式で `(` の直後が `{` のとき複合文をパースし、最後の式文の値・型を式全体の値・型とする。`sizeof` 用の静的型推論(`static_statement_expr_type`)も同じ規則で実装 | 実行テスト(gcc 差分比較)+ c-testsuite 00213/00214 合格。ruby.h の `TypedData_Make_Struct`/`Data_Make_Struct` の展開先が通ることを実 gem ビルドで確認(Step 39→40) | Step 40 |
| `?:` の片側 void アーム | 意味論まで正確に対応 | ISO C は両アーム void のみ許容するが、GCC は片側 void を許容する。`conditional_result_type` で片側 void を void 合成とし、`gen_conditional` に各アームを値変換せず副作用のみ実行する経路を追加 | c-testsuite 00213(`1 ? printf(...) : ({ ...; goto L; })` を含むケース) | Step 40 |
| `__builtin_offsetof(type, member-designator)` | 意味論まで正確に対応 | ネスト `.name`・添字 `[expr]`・匿名メンバに対応したオフセット計算。ConstantEvaluator が畳むため static 初期化子・配列サイズ・case ラベルの定数文脈でも使える。ビットフィールドは診断 | gcc の offsetof 値との一致確認 + 定数文脈での使用を回帰テスト化。同梱 stddef.h の `offsetof` マクロをこの展開へ変更(Step 41 の実行時限定版から置換) | Step 42 |
| GNU 名前付き可変長マクロ `#define F(args...)` | 意味論まで正確に対応 | 可変長部の名前(ISO 裸 `...` = `__VA_ARGS__`、GNU 名前付き形 = その識別子)を `Macro#va_name` に一元化し、実引数束縛・stringize・paste・再定義同一性判定を両形で同じ経路に通す | gcc -E のトークン列比較で全組み合わせを検証。glibc の `<sys/types.h>` → `linux/posix_types.h` 経由の `__struct_group` マクロが実際に展開できることを msgpack 実ビルドで確認 | Step 43 |
| GNU カンマ削除 `, ## __VA_ARGS__` | 意味論まで正確に対応 | `##` の左が literal カンマ・右が可変長引数の並びだけを検出し、可変長実引数が省略されたときのみ直前のカンマを削除(存在すれば空でも残す)。`gcc` の `Z()`(削除)/`F(a,)`(残す)の細部を再現 | gcc -E のトークン列比較で全組み合わせを検証 | Step 43 |
| `__builtin_constant_p` | 意味論まで正確に対応 | ConstantEvaluator で引数を評価してみて、成功なら 1・非定数(NotConstant/DivisionByZero)なら 0 を返す「試し畳み」。引数自体は評価しない | gcc の `__builtin_constant_p` の真偽と比較。ruby.h の `INT2FIX` 経路(`__builtin_choose_expr` と組み合わせ)が実 gem ビルドで通ることを確認 | Step 44 |
| `__builtin_choose_expr(const, a, b)` | 意味論まで正確に対応 | 第 1 引数を既存の定数評価で畳み、選ばれた側の AST ノードをそのまま返す(専用 AST を作らない)。選ばれない側は構文チェックのみで評価もコード生成もされない | 定数文脈(static 初期化子)でも実行時文脈でも選択結果が gcc と一致することを確認 | Step 44 |
| `__builtin_ctz`/`__builtin_ctzll`/`__builtin_clz`/`__builtin_clzll` | 意味論まで正確に対応 | 新 IR 命令 `:bit_scan`(a=対象, b=`:forward`/`:reverse`, size=4/8)を追加し、backend で `bsf`(0F BC)/`bsr`(0F BD)+ 補正演算に降ろす。定数畳み込みも同値対応 | gcc の演算結果とビット単位で一致することを実行テストで確認。オペランド 0 は両者とも UB につき未定義のまま(ゼロ処理コードを追加しない) | Step 44 |
| `__atomic_*` ビルトイン 10 形(データ 9 形 + `thread_fence`) — `load_n`/`store_n`/`exchange_n`/`compare_exchange_n`/`fetch_add`/`fetch_sub`/`add_fetch`/`sub_fetch`/`or_fetch`/`thread_fence` — + `__ATOMIC_*` メモリオーダマクロ 6 種 | 意味論まで正確に対応(対応範囲内) | 新 IR 命令 4 つ(`:atomic_load` / `:atomic_store` / `:atomic_rmw` / `:atomic_cas`)。x86-64 は `mov` / `xchg` / `lock xadd` / `lock cmpxchg`(`or_fetch` のみ cmpxchg リトライループ)と MFENCE、aarch64 は `ldar` / `stlr`、LDAXR/STLXR リトライループと DMB ISH(**LSE も libgcc の outline atomics も使わない**)。**メモリオーダは受理するが検査せず、常に最強(seq_cst)で降ろす**。`compare_exchange_n` の `weak` も常に strong として扱う。**型幅は 4 と 8 のみ**で、1/2/16 バイトは診断。`compare_exchange_n` の失敗時の `*expected` 書き戻しも実装 | gcc 差分の実行テストでデータ 9 形の戻り値・副作用と fence を確認。逆アセンブルで x86-64 の `lock`/MFENCE と aarch64 の LDAXR/STLXR/DMB ISH を検査し、aarch64 は qemu で実走 | Step 161 / Step 209 |
| `__builtin_add_overflow` / `__builtin_sub_overflow` / `__builtin_mul_overflow` | 意味論まで正確に対応 | 整数の無限精度で演算し、格納先の型への変換でオーバーフローしたかを `_Bool` で返す。符号付き・符号なし、幅の異なる整数、64 ビット境界まで対応。非整数・128 ビットの組み合わせは診断 | gcc との戻り値・格納値の差分実行と `__has_builtin` の結果を検証 | Step 177 |
| `__sync_*` ビルトイン 10 形(`fetch_and_add`/`fetch_and_sub`/`add_and_fetch`/`sub_and_fetch`/`or_and_fetch`/`lock_test_and_set`/`lock_release`/`synchronize`/`bool_compare_and_swap`/`val_compare_and_swap`) | 意味論まで正確に対応(対応範囲内) | x86-64 は lock 命令列と MFENCE、aarch64 は LDAXR/STLXR ループと DMB ISH に降ろす。整数・ポインタの 4/8 バイトを対象とし、legacy family 固有の full barrier 契約を保つ | gcc 差分の戻り値・副作用、ポインタ加算、signedness、両 target の命令列を検証 | atomic-type-6 |
| `__builtin_unreachable()` | 受理するが実体は何もしない | rubycc は最適化を行わないため、void 値を返すだけのコードで意味論上安全(到達すればそのまま実行が続く。gcc は UB として最適化に使うが、rubycc は使わないため無害) | CRuby `assert.h` の `UNREACHABLE_RETURN` マクロ(`return (__builtin_unreachable(), val)` のコンマ式)が既存の void 対応で通ることを確認 | Step 44 |
| `__builtin_memcpy` | 意味論まで正確に対応 | パース時に `Call("memcpy", …)` へ書き換え、組み込みプロトタイプを seed(未宣言でも可)。実体は libc の `memcpy` に UND 解決される | gcc ビルドとのリンク・実行結果比較 | Step 44 |
| `<x86intrin.h>`(空スタブ) | 受理するが実体は何もしない | ヘッダを空で提供する。実 intrinsic の使用箇所は全て `__AVX2__`/`__LZCNT__` 等の別ガードで守られており、rubycc はそれらのマクロを定義しないため到達しない(実測確認) | CRuby config.h が焼き込む `HAVE_X86INTRIN_H` ガード付きの `#include <x86intrin.h>` が実 gem ビルドで通ることを確認 | Step 44 |
| 2 進整数リテラル `0b0001` | 意味論まで正確に対応 | 6.4.4.1 の整数定数の基数の 1 つとして 2 進を追加し、通常の整数リテラルと同じ型決定規則に乗せる | gcc との値一致。msgpack のフラグ定数で使用されることを実 gem ビルドで確認 | Step 44 |
| `__has_builtin(x)` | 正直に非対応と答えてフォールバック誘導 | 対応ビルトインの表(KNOWN_BUILTINS)に一致する名前のみ 1、それ以外は 0 を返す。`#ifdef __has_builtin` / `#if defined(__has_builtin)` の両形を真にする | json の `__has_builtin(__builtin_bswap64)` 等のガード付きコードが正直な 0 を受けてポータブルなフォールバックへ回避することを実 gem ビルドで確認(bswap 系の実装自体が不要になった) | Step 27(基本枠組み)/ Step 44(対応表を拡張) |
| `__has_include(<header>)` | 意味論まで正確に対応 | quote は問い合わせ元のディレクトリ → `-I`、angle は `-I` のみという実際の `#include` 探索と同じ規則で `File.file?` により判定 | gcc の判定結果と一致することを確認。適合修正(Step 49)で glibc の「非 gcc C99 準拠コンパイラ」判別経路が実際に選ばれることも確認済み | Step 27 |
| `__has_attribute(x)` | 正直に非対応と答えてフォールバック誘導 | 意味を実装した `aligned`/`packed` にのみ 1 を返し、他は常に 0 | gcc との一致は「意味を実装した属性のみ真」という限定範囲で確認 | Step 27(常に 0)/ Step 28(aligned/packed のみ 1) |
| `__attribute__((aligned(N)))` / `__attribute__((packed))`(struct/union) | 意味論まで正確に対応 | `StructType#define` にレイアウト上書き(packed/aligned)を実装。packed は psABI 3.2.3 により非整列フィールドを持つ集合体を MEMORY クラスに分類する ABI 上の帰結も反映 | gcc の `sizeof`/`_Alignof`/ABI eightbyte 分類との一致(struct RBasic の `aligned(8)` 等)。クロスコンパイラ ABI ハーネス(Step 25)で顕在化する ABI 差を検出・修正 | Step 28 |
| `__attribute__((...))` のその他の属性(CONSTFUNC・可視性属性等) | 受理するが実体は何もしない | 全宣言位置・型名・抽象宣言子で構文のみ受理し、aligned/packed 以外は効果を持たせない | Ruby の config.h(gcc ビルド成果物)が無条件に定義する CONSTFUNC 等が構文エラーにならず実 gem ビルドが通ることを確認 | Step 28 |
| `__asm__ volatile("" ::: "memory")`(コンパイラバリア) | 受理するが実体は何もしない | 空テンプレート・空オペランドのみ受理し、クロバー文字列は破棄。命令の並べ替えを行わない処理系ではメモリバリア自体が no-op で意味論的に正しい。**実体のあるインラインアセンブリは非対応** | 構文受理のみをユニットテストで確認(rubycc は最適化しないため実行差分の対象にならない) | Step 28 |
| `__extension__` | 受理するが実体は何もしない | cast 前置の読み飛ばし経路で吸収。ISO 厳格モード(`-pedantic` 等)を持たないため抑制すべき警告がそもそも存在せず、単純な読み飛ばしで十分 | `__extension__ ({ … })` が文式と組み合わさって構文的に通ることを確認 | Step 28 |
| GNU 別名キーワード(`__signed__`/`__const__`/`__volatile__`/`__inline__` とその単一アンダースコア形) | 意味論まで正確に対応 | lexer が字句解析時に正規綴り(`signed`/`const`/`volatile`/`inline`)へ 1 回だけ写像(KEYWORD_ALIASES)。以降の全判定サイトは通常のキーワードとして扱われる | glibc の kernel UAPI ヘッダ(`asm-generic/int-ll64.h` の `typedef __signed__ char __s8;`)が実 gem ビルドで通ることを確認。適合修正(Step 49)が開いた新経路への対応として同時実装 | Step 49 |
| `restrict` / `__restrict` / `__restrict__` | 受理するが実体は何もしない | 型修飾子として構文は受理するが、rubycc はエイリアス解析に基づく最適化を行わないため意味上の効果を持たせない | 構文受理をユニットテストで確認 | Step 28 |
| `__int128`(算術サブセット) | 意味論まで正確に対応(対応範囲内) | 16 バイト値をスタックオブジェクトのアドレスとして表現し、加減算・乗算(半語 64bit 演算の合成)・比較・変換、値渡し/値返し、シフトを実装。**除算・剰余・ビット演算・可変長引数渡しは診断エラー** | gcc との演算結果・ABI 一致(CRuby `rb_mul_size_overflow`、`bits.h` の値渡し/シフト、onigmo.h のメンバレイアウト)を実測 | Step 28 / Steps 94–95 |
| `#pragma once` | 意味論まで正確に対応 | `#include` 解決後・読み込み前に `File.expand_path` をキーに照合し、2 回目以降の読み込みをスキップ | インクルードガード無しヘッダの多重インクルード防止が gcc と同じ効果を持つことを確認 | Step 27 |
| `#pragma` のその他(`push_macro`/`pop_macro` 等) | 受理するが実体は何もしない | `#pragma once` 以外の pragma は本文を読み飛ばして無視する(実際のマクロ退避・復元は行わない) | gcc 固有・ベンダ固有 pragma が構文エラーにならないことを確認。c-testsuite 00206(`push_macro`/`pop_macro` を使うケース)はマクロの退避・復元自体は再現されないため意図的にスキップ | Step 27 |
| `_Pragma("...")` 演算子 | 受理するが実体は何もしない | ディレクティブでなく演算子として、再走査中に `_Pragma ( 文字列 )` の 4 トークンを消費して丸ごと破棄する | config.h が無条件に吐く `_Pragma("GCC visibility push(default)")` 等が実 gem ビルドで通ることを確認 | Step 28 |
| `__builtin_expect(exp, c)` | 受理するが実体は何もしない | 両オペランドを `long` へ変換し値は `exp` 側をそのまま返す。rubycc に分岐予測最適化が無いためヒントは意味を持たない(no-op が正確な実装) | `exp` の値がそのまま得られることを実行テストで確認 | Step 28 |
| `__builtin_alloca(n)` / `alloca(n)` | 意味論まで正確に対応(対象 target 内) | x86-64 では新 IR `:alloca` で 16 の倍数に切り上げてスタックを確保し、同梱 `<alloca.h>` が `alloca` を `__builtin_alloca` へ展開する。aarch64 backend では現在も診断する | gcc との動的スタック確保サイズ・内容比較(実行テスト)。aarch64 は pending として明示 | Step 28(ビルトイン)/ Step 63(同梱 `alloca.h`) |
| 定義済みターゲット/数値限界マクロ(`__x86_64__`/`__linux__`/`__LP64__`/`__LONG_MAX__` 等 36 種) | 意味論まで正確に対応 | 予約形のみ(`__GNUC__`・非予約形の `linux`/`unix` は定義しない)。数値系はサフィックス込みで gcc -dM の綴りと一致させる | `gcc -dM -E` の出力値との一致をユニットテストで検証 | Step 28 |
| `#include_next` | 意味論まで正確に対応 | 各ファイルの解決元 `-I` ディレクトリを記録し、その次のディレクトリから探索を再開する | gcc の `#include_next` と同じ解決順で、fixinclude 由来の limits.h 連鎖が通ることを確認 | Step 28 |
| RB_GC_GUARD 互換ランタイム(`rb_gc_guarded_ptr_val`) | 意味論まで正確に対応 | `__GNUC__` を名乗らないため CRuby の `RB_GC_GUARD` は asm バリア版でなく extern 関数呼び出し版へ展開される。rubycc ドライバがリンク入力の末尾に自動追加する互換アーカイブ(libgcc 相当の位置づけ、シンボル参照時のみ実体化)でこの関数を供給し、ポインタをそのまま返すことで「呼び出しの存在自体が最適化バリア」という契約を満たす | msgpack 実 gem を rubycc 単体ツールチェーンで .so 化・require・round-trip テストして正常動作を確認 | Step 50 |

---

## 現在も未実装または部分対応の GNU 拡張(参考)

以下は実コーパスでまだ要求されていないか、対応範囲を限定している。
未対応の名前は通常の構文エラー(未認識の記号・識別子)になる:

- **入れ子関数定義**(ブロック内の関数 *定義*。`int main(void) { int f(int) { … } … }`)—
  囲むフレームを捕捉するトランポリンが要る GNU 拡張。「nested function definitions are
  not supported」と診断する。**ブロックスコープの関数 *宣言*(`int f(int);` を
  ブロック内に書く形)とは別物**で、そちらは GNU 拡張ではなく標準 C(C11 6.2.2p5:
  記憶域指定子が無いか `extern` なら外部リンケージ)であり、Step 168 で対応済み
  (CRuby の `<ruby/ractor.h>` が使う形)。本ファイルは GNU 拡張の対応表なので
  宣言側の項目はここには載せない
- `case a ... b:`(case 範囲指定子)
- `[a ... b] = x`(配列の範囲指示付き初期化子)
- `typeof` / `__typeof__`
- `__attribute__((__mode__(...)))` 等、aligned/packed 以外で意味を持たせている属性
- 実体のあるインラインアセンブリ(オペランド・クロバーを実際に処理する asm 文)
- **`__atomic_test_and_set` / `__atomic_clear`、データ操作の generic
  `__atomic_load` / `__atomic_store` / `__atomic_exchange` /
  `__atomic_compare_exchange`**、`__sync_*` の未対応 7 形
  (`__sync_fetch_and_or` / `__sync_fetch_and_and` / `__sync_fetch_and_xor` /
  `__sync_fetch_and_nand` / `__sync_and_and_fetch` / `__sync_xor_and_fetch` /
  `__sync_nand_and_fetch`)、および `__atomic_fetch_or` /
  `__atomic_fetch_and` / `__atomic_fetch_xor` / `__atomic_fetch_nand` /
  `__atomic_and_fetch` / `__atomic_xor_fetch` / `__atomic_nand_fetch`は未実装。
  `__atomic_fetch_add` など表に記載した 9 形と `__atomic_thread_fence` は対応範囲内である。
  C11 の `_Atomic` と `<stdatomic.h>` は限定的に実装済みだが、`atomic_fetch_or`/
  `_and`/`_xor`、`atomic_flag`、`atomic_is_lock_free`は提供しない
  (atomic-type-1)。

---

## 出典

- docs/DESIGN.md R7(`__GNUC__` 非定義方針)
- docs/STEPS.md Step 27・28・40・42・43・44・49・50・94・95・161・177・209、
  `atomic-type-1`・`atomic-type-6` の設計記録
- docs/ROADMAP.md §3(既知の逸脱・技術的負債の一覧表)
