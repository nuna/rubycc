# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | 何が足りないか | 誰が困るか | 確からしさ | 詳細 |
|---|---|---|---|---|
| **S** | **`long double` が 8 バイト**(`double` として扱う。DESIGN 3.3 の既知の制限) | **oj**。`usual.c` が `sprintf(buf, "%Lg", (long double)x)` を使い、glibc は 16 バイトを読むので値が壊れる(`BigDecimal(): "-nan"`)。**対照と食い違う唯一のテスト** `UsualTest#test_decimal` の原因 | **実測**(2026-08-08)。最小再現: gcc `[1.23457]` / rubycc `[7.46537e-4948]` | ROADMAP §3 の負債に**初めて実害が出た**。解消には x87 80 ビット対応が要り、1 ステップの仕事ではない |

| **T** | **配列の要素数をパーサが数える文脈で、struct を返す式が単一式初期化子として読めない** | `pt b[] = { {1,2}, fp(), {5,6} };` が `excess elements in scalar initializer` になる(gcc は 3 要素)。パーサは `[]` の長さをここで確定させる必要があるが、型表を持たないので `fp()` の型が分からない | **実測**(2026-08-08) | struct を直接初期化する形は通る(atomic-type-13)。解消にはパーサ側に型を引く手段が要る |

| **U** | **既定のシステム include 探索パスが x86-64 の multiarch ディレクトリ決め打ち** | `LIBC_SYSTEM_INCLUDE_PATHS` が `/usr/include/x86_64-linux-gnu` を無条件に持つ(`lib/rubycc/preprocess/preprocessor.rb`)。target にもホスト CPU にも依存しないので、**aarch64 ホストで `rubycc` を素で使うと存在しないディレクトリを探し、`/usr/include/aarch64-linux-gnu` を探さない**。同梱 libc ヘッダが先に当たるため多くの場合は表面化しないが、同梱に無いヘッダがホストの multiarch 側 `bits/` を引く経路で崩れる | **実測**(`test-ci-implementation-2` の作業中に判明)。`test/support/host_target.rb` のコメントが「`Compiler#compile` の既定 target はホストの検出ではない」と明記しているとおり、テスト側は機種対応済みだが**製品側は未対応** | native smoke は `system_includes: false` で既定パスを迂回するため、**この死角を検出できない**。解消には `LIBC_SYSTEM_INCLUDE_PATHS` を target 別にする(`float.h`・`math.h` と同じ per-target 化)必要がある |

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

いずれも設計判断は STEPS.md の各ステップに記録がある。
