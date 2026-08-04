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
| I | **ABI ハーネスの glibc 固有ケースの分類が未完(残りわずか)**。Step 180 で仕組みを入れ、Steps 180・181 の 2 回の musl 実測で 13 ケースを分類。**gcc がエラーを打ち切るため、`_IS*` / `LC_*` / `_NL_ITEM*` の 3 系統は「系統ごと」の推論で移した**(全メンバの個別実測はしていない) | 推論が外れていれば、その項目が musl で不要に落ちる | 低 | STEPS.md Steps 175・180・181。次の musl 実走で残りが出る |
| K | **`offsetof` の cast 形をコンパイル時定数に畳めない**。実測(最小再現): `#define OFF(t,m) ((size_t)&((t *)0)->m)` を `_Static_assert` に置くと `error: static assertion expression is not an integer constant`。`__builtin_offsetof` 形は畳める。gcc は両方畳む | musl の実測で `ruby/internal/core/rtypeddata.h` の `RBIMPL_STATIC_ASSERT(... offsetof(struct RData, data) == offsetof(struct RTypedData, data))` が通らず、**musl で `ruby.h` が前処理できない**(`TestRubySmoke` 4 件)。この形は musl に限らず広く使われる | **高** | STEPS.md Step 183。**ローカルで再現するので CI 往復は不要** |

## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|
| `tools/verify_gem_tests.rb` で racc を再現すると assertions のみ 319 → 320 になる | 原因未特定。合否は変わらない | 低 | STEPS.md Step 144 |
| **週次 census ジョブが構造的に必ず赤くなる**。`include-census.md` の `Generated:` 行に生成時刻が入るため、内容が同じでも `git diff --exit-code` が必ず差分を出す(実測: 再生成したら差分はタイムスタンプ 1 行だけ) | **そのジョブの結果が信用されなくなる**。実際 Step 176 で「スナップショットが再生成されないまま古くなっていた」ことが見つかっており、赤が常態化していたことと整合する | 中 | STEPS.md Step 187。生成時刻を本文から外すか、比較時に除外するかの二択 |

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
- **Step 175 の H**(musl の実測が露出。同梱ヘッダに `stdckdint.h` が無い):
  Steps 177〜179 で解消(組み込み関数 → aarch64 の `:mulhi` → ヘッダ本体)。
- **Step 181 の J**(musl の 2 回目が露出。`_Noreturn` 関数指定子の未対応):
  Step 182 で解消。**G と I は上の表に残っている。**

いずれも設計判断は STEPS.md の各ステップに記録がある。
