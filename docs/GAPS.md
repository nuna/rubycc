# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | ギャップ | 影響 | 優先 | 詳細 |
|---|---|---|---|---|
| E | `F_GETPIPE_SZ` / `F_SETPIPE_SZ` が同梱 `fcntl.h` に無い(`Fcntl` 定数が 24 対 26。**共通 24 個の値は一致**) | fcntl のみ | 低 | STEPS.md Step 157。**埋めても検証済み gem は増えない** — fcntl は上流にテストスイートが無く (d) レベルの証拠が原理的に得られないため |
| G | **同梱ヘッダが glibc の ABI を焼き込んでいる**。実測(musl 初回実行): `int_fast16_t` / `int_fast32_t` が musl では 4 バイト、rubycc は 8 バイト(glibc の値) | **M5 が掲げた「glibc/musl 互換ヘッダ」の主張が musl 側で外れている**。musl では全スイート 21 failures / 18 errors | **高** | STEPS.md Step 175。`<stdint.h>` は最も直接的な 1 例で、26 件ある rubycc 側の差の全容はまだ分類しきれていない |
| H | **同梱ヘッダに `stdckdint.h`(C23)が無い** | musl + ruby 4.0 で `ruby.h` が通らない(`TestRubySmoke` 5 件)。ruby 4.0 の `ruby/internal/stdckdint.h` が musl 環境ではこの枝を通るため。**ruby 4.0 + glibc は Tier A が緑**なので Ruby バージョンの差ではない | **高** | STEPS.md Step 175。コーパスのセンサスも bigdecimal 由来で `stdckdint.h` を review に挙げていた |
| I | **ABI ハーネスのケースが glibc 固有**。musl では 13 件で**参照実装(gcc)の方が先にコンパイルに失敗**する(`__GLIBC__` を印字する `features`、`c_ispeed` を名指しする `termios`、`pthread_kill` を `<pthread.h>` に期待する `pthread` など) | **その 13 件については rubycc の合否が判定できていない**。「rubycc が壊れている」でも「無事である」でもなく、対照が取れていない | 中 | STEPS.md Step 175。§3.1 の負債表にある「ABI ファジングハーネスの機種パラメタ化」と同じ話で、libc も軸に加える必要がある |

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
| **aarch64 での gem install 実走** | qemu 上で動く aarch64 版 Ruby が要る。ROADMAP §「M4 受け入れ」と同じ枠 |
| 真の distroless コンテナ検証 | ROADMAP の M3 残項目 |

## 4. 閉じたギャップ(参照のみ)

- **Step 146 の 6 件**(stackprof / nkf の検証が露出): Steps 147〜152 で全て解消。
- **Step 157 の A〜D**(etc の検証が露出): Steps 158〜161 で全て解消し、
  Step 162 で etc 1.4.6 が検証済みになった。**E だけが上の表に残っている。**
- **Step 172 の F**(psych の検証が露出。rmake に `MAKE` マクロが無く再帰 make が
  no-op になる): Step 173 で解消。

いずれも設計判断は STEPS.md の各ステップに記録がある。
