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
| **AE**([issue](../../issues/crlf-line-splice.md)) | **CRLF の行末で行連結(`\` + 改行)が働かない**。`\` の次に `\n` を期待するところへ `\r` が来て字句エラーになる | CRLF で配られ、継続行を 1 行でも持つ gem。**ソースの見た目に問題が無いのに字句エラー**になるので原因に辿り着きにくい | **実測**(2026-09-13)。CRLF の単純なファイルは通り、継続行だけが落ちる。`murmurhash3` 0.1.7 が該当し、**対照の gcc は通る** | 翻訳フェーズ 1 で `\r\n` を改行に正規化すれば閉じる見込み。`\r` 単独を改行扱いしないこと |
| **AF**([issue](../../issues/bundled-stdlib-getloadavg.md)) | **同梱 `stdlib.h` に `getloadavg` の宣言が無い**(glibc は `__USE_MISC` の枝に置く) | `getloadavg` を呼ぶ gem。`vmstat` 2.3.1 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現で `implicit declaration`) | **`_DEFAULT_SOURCE` の枝ごと見て決める** — 1 つずつ塞ぐと回数が増える |
| **AG**([issue](../../issues/zero-length-array.md)) | **長さ 0 の配列(GNU 拡張)を拒否する**。規格(6.7.6.2p1)には忠実だが gcc は既定で受理する | `binding_ninja` 0.2.3 の `dummy_method_arg[0]` が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現で `array size must be positive`) | 受理するか対象外にするかを**根拠付きで決めてから**実装する。フレキシブル配列メンバの扱いを先に測る |
| **AH**([issue](../../issues/thread-local-storage.md)) | **スレッドローカル記憶域が無い** — C11 の `_Thread_local` も GNU の `__thread` も `expected type specifier` で拒否する。コンパイラに言及が 1 つも無く、記憶域クラスとしてまるごと無い | TLS 変数を宣言するヘッダを含む gem。`pg_query` 6.2.3 が同梱 postgres ヘッダの `__thread` で、`scout_apm` 6.3.0 が `allocations.c:29` の `static __thread` で落ち、**対照の gcc はどちらもビルドに成功する** | **実測**(2026-09-13、最小再現で両方とも拒否) | **マイルストーン級**。ELF の TLS セクション・TLS 再配置・`%fs` / `tpidr_el0` 相対の生成が要り、拡張は `.so` なので**動的モデルでないと実在の gem に効かない** |
| **AJ**([issue](../../issues/variadic-aggregate-argument.md)) | **可変長引数に構造体・共用体を値で渡せない**(`not supported yet` と自己申告) | `semctl` に `union semun` を渡す gem。`semian` 0.28.4 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現) | 固定引数の構造体渡しは実装済み。x86-64 と AArch64 の両方で、呼ぶ側・呼ばれる側の両向きを gcc と突き合わせる |
| **AK**([issue](../../issues/labels-as-values.md)) | **ラベルのアドレス(`&&label` / `goto *p`、GNU 拡張)を受け付けない**。診断は `expected expression` で原因を伝えない | 表引きのディスパッチを持つ gem。`strptime` 0.2.5 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現) | **実装するか対象外(基準 H)にするかが未決**。どちらでも診断は直す |
| **AL**([issue](../../issues/expansion-budget-source-tokens.md)) | **マクロ展開の予算(100 万)がソースを素通りするトークンまで数える**。マクロの無い大きな表が「暴走マクロ」として止まる | 巨大な表を持つ gem。`unicode` 0.4.4.5 の `unidata.map`(24,555 行)が該当し、**対照の gcc は通る** | **実測**(2026-09-13、80,000 行の生成入力で再現。45,000 行は通る) | 置換で生まれたトークンだけを数えれば、上限はコメントどおりの意味になる |
| **AM**([issue](../../issues/bundled-sched-param.md)) | **同梱 `sched.h` に `struct sched_param` が無い**。glibc の `<spawn.h>` がメンバに持つので、`<spawn.h>` ごと読めない | `<spawn.h>` を含む gem。`posix-spawn` 0.3.15 が該当し、**対照の gcc は通る** | **実測**(2026-09-13、最小再現で `incomplete type`) | AF と同じ系統。**`<spawn.h>` が他に何を要るかを先に測って**まとめて決める |
| **AN**([issue](../../issues/incompatible-function-pointer-argument.md)) | **互換でない関数ポインタの実引数をエラーにする**。gcc 13 は警告、gcc 14 はエラー | 古い書き方の gem。`hpricot` 0.8.6 の `rb_rescue` 呼び出しが該当し、**対照の gcc 13 は通る** | **実測**(2026-09-13、gcc 13 のみ。gcc 14 はこのホストに無い) | **警告に下げるかエラーを保つかが未決**。対照の版で結論が変わる |

## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|

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
