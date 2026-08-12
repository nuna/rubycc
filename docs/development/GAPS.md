# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/development/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | 何が足りないか | 誰が困るか | 確からしさ | 詳細 |
|---|---|---|---|---|
| **S**([第 2 段の issue](../../issues/platform-abi-alignment.md)) | **`long double` の幅が 8 バイト**(`double` として扱う。DESIGN 3.3 の既知の制限)。**可変長引数に渡す経路は解消済み**(`long-double-varargs-1`) | **残るのは幅に依存するもの** — `sizeof` / `_Alignof` / `max_align_t` / 構造体メンバのオフセット、および**名前付き引数と戻り値**(`frexpl` 等の libc 呼び出しは依然不整合) | **実測**(2026-08-13)。`printf("%Lg", x)` は gcc と一致し、oj の失敗テスト名の集合も対照と完全一致(687 runs / 1 failure / 2 errors、名前も同一) | **オブジェクトファイルの ABI が変わる**ので、他の既知逸脱(enum の底型、`wchar_t` の符号性)と**まとめて 1 つの major** で閉じる |
| **T** | **配列の要素数をパーサが数える文脈で、struct を返す式が単一式初期化子として読めない** | `pt b[] = { {1,2}, fp(), {5,6} };` が gcc では 3 要素になるのに rubycc は拒否する。パーサは `[]` の長さをここで確定させる必要があるが、型表を持たないので `fp()` の型が分からない | **実測**(2026-08-08) | struct を直接初期化する形は通る(atomic-type-13)。**`gaps-s-t-u-2` で診断だけ正直にした**(以前は `excess elements in scalar initializer` という的外れな文言だった)。解消にはパーサ側に型を引く手段が要る |

## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|

## 3. 環境が無くて測れていないこと

「rubycc の欠陥」ではなく**未測定**である点でギャップと区別する。
解消には環境整備(コンテナ / CI マトリクス)が要る。
**計画は ROADMAP §8 H6「環境が無くて測れていないことの解消」(default gem 検証の 7 件計画の後、3 ステップ)。**

| 未測定 | 詳細 |
|---|---|
| ~~**musl** での全検証~~ | **測定した(Step 175)**。結果は緑ではなく、ギャップ G・H・I として §1 に移した。`data/verified_gems.json` に musl の記録が 1 件も無いのは変わらないが、それは**環境が無いからではなく通っていないから**になった |
| ~~**aarch64 での gem install 実走**~~ | **限定測定済み(Step 208)**。qemu 上の glibc / aarch64 Ruby 4.0.6 で `io-wait` と `stringio` の gem install・gem 自身のテストが通った。**全スイートは `test-ci-implementation-4` で解消**([weekly run 31345396123](https://github.com/nuna/rubycc/actions/runs/31345396123)、native `ubuntu-24.04-arm` 上の Ruby 3.3 / 4.0 が success)。`json` / `msgpack` の aarch64 上 `gem install` だけが未完了 |
| ~~真の distroless コンテナ検証~~ | **測定済み(Step 202)**。glibc / musl の `ruby:4.0` distroless相当で json / msgpack / sqlite3 / pg のビルドとrequireに成功 |

## 4. 方針として受け入れたもの(ギャップではない)

**直す気が無いのではなく、「直さない」と判断したもの。** 再検討の条件を必ず書くこと。

| 事項 | 判断 | 再検討の条件 |
|---|---|---|
| **共有ライブラリのシンボル介入を尊重しない**(自分で定義し自分で参照するグローバルシンボルを直接束縛する。データ・関数の両方で実測) | **現状維持**(`ld -Bsymbolic` 相当)。**R9 が列挙する ABI は影響を受けない** — 逸脱するのは ELF の動的リンク時のシンボル解決。多くのディストリビューションが性能のため意図的に有効化している正規の構成であり、gcc の既定に合わせると PLT 経由になって遅くなる | **実在の gem で実害が出たとき**。`LD_PRELOAD` による差し替えが効かない、または同名シンボルのコピーが 2 つ生きて片方への書き込みがもう片方から見えない、という形で現れる。**その時点で再検討する**(ユーザ判断、2026-08-06) |

## 5. 閉じたギャップ(参照のみ)

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
  `--platform ruby` ビルドと実行に成功した。**musl 全スイートと aarch64 の
  `json` / `msgpack` を含む M4 全面受入れは未完了**。

- **ギャップ V**(既定のシステム include 探索パスが x86-64 の multiarch 決め打ち):
  `test-ci-implementation-9` で解消。**当初 U と採番したが、§1 の U(`__GLIBC_MINOR__`)と
  衝突していたので、閉じた側をここで V に振り直した**(開いている側の記号を動かすと
  参照が壊れるため)。Debian の multiarch ディレクトリは target ごとに
  名前が違う(`bits/` の中身が別物)ので、同梱 arch 層とまったく同じく `libc_arch` に
  従わせた。**`float.h`(Step 201)・`math.h`(`test-ci-implementation-2`)に続いて
  3 件目の「freestanding/共通層は機種に依らない」という思い込み**である。

いずれも設計判断は STEPS.md の各ステップに記録がある。
