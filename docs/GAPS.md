# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | ギャップ | 影響 | 優先 | 詳細 |
|---|---|---|---|---|
| N | **rubycc の共有ライブラリが、自分で定義した外部データシンボルの介入(interposition)を尊重しない**。実測(**glibc で再現**): 同じソースから作った gcc 版と rubycc 版を `RTLD_GLOBAL` で順に `dlopen` すると、**gcc 版は先に載っている方の `trace` に書く**が、**rubycc 版は自分の `trace` に書く** | ELF の既定の意味論(`-Bsymbolic` でも protected 可視性でもないのに直接参照している)からの逸脱。`LD_PRELOAD` による差し替えや同一シンボルを持つ複数ライブラリの共存で挙動が gcc と変わる | **高** | STEPS.md Step 195。musl の実走で露出したが**musl は要らない** — musl は `dlclose` が解放しないので介入が観測できただけ。**修正は PIC のデータアクセスを GOT 経由にする話で、性能とのトレードオフがある**(未着手) |
## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|
| `tools/verify_gem_tests.rb` で racc を再現すると assertions のみ 319 → 320 になる | 原因未特定。合否は変わらない | 低 | STEPS.md Step 144 |

## 3. 環境が無くて測れていないこと

「rubycc の欠陥」ではなく**未測定**である点でギャップと区別する。
解消には環境整備(コンテナ / CI マトリクス)が要る。
**計画は ROADMAP §8 H6「環境が無くて測れていないことの解消」(default gem 検証の 7 件計画の後、3 ステップ)。**

| 未測定 | 詳細 |
|---|---|
| ~~**musl** での全検証~~ | **測定した(Step 175)**。結果は緑ではなく、ギャップ G・H・I として §1 に移した。`data/verified_gems.json` に musl の記録が 1 件も無いのは変わらないが、それは**環境が無いからではなく通っていないから**になった |
| ~~**aarch64 での gem install 実走**~~ | **限定測定済み(Step 208)**。qemu 上の glibc / aarch64 Ruby 4.0.6 で `io-wait` と `stringio` の gem install・gem 自身のテストが通った。`json` / `msgpack` と全スイートは M4 受け入れとして未完了 |
| ~~真の distroless コンテナ検証~~ | **測定済み(Step 202)**。glibc / musl の `ruby:4.0` distroless相当で json / msgpack / sqlite3 / pg のビルドとrequireに成功 |

## 4. 閉じたギャップ(参照のみ)

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
