# 残ギャップ

**未解消のものだけ**を置く。解消済みギャップの経緯・設計判断は
`docs/STEPS.md` の該当ステップにあり、ここには残さない。

各行は「何が足りないか」「誰が困るか」「どれだけ確からしいか」までで、
背景・実測値・最小再現は参照先を見ること。

## 1. 未解消のギャップ

| # | ギャップ | 影響 | 優先 | 詳細 |
|---|---|---|---|---|
| E | `F_GETPIPE_SZ` / `F_SETPIPE_SZ` が同梱 `fcntl.h` に無い(`Fcntl` 定数が 24 対 26。**共通 24 個の値は一致**) | fcntl のみ | 低 | STEPS.md Step 157。**埋めても検証済み gem は増えない** — fcntl は上流にテストスイートが無く (d) レベルの証拠が原理的に得られないため |

## 2. 未解消の負債

| 負債 | 影響 | 優先 | 詳細 |
|---|---|---|---|
| `test/corpus/gems.rb` の 4 エントリ(bigdecimal・date・racc・redcarpet)が `version: nil` = 最新追従 | `rake corpus:census` のスナップショットが上流のリリースだけで動き、Tier B(`weekly.yml`)の census ジョブが赤くなる。`data/verified_gems.json` 側は厳密なバージョンを固定しているので、記述と検証済みバージョンが食い違いうる | 中 | STEPS.md Step 149。固定するとスナップショットが動くので別ステップの作業 |
| `tools/verify_gem_tests.rb` で racc を再現すると assertions のみ 319 → 320 になる | 原因未特定。合否は変わらない | 低 | STEPS.md Step 144 |

## 3. 環境が無くて測れていないこと

「rubycc の欠陥」ではなく**未測定**である点でギャップと区別する。
解消には環境整備(コンテナ / CI マトリクス)が要る。
**計画は ROADMAP §8 H6「環境が無くて測れていないことの解消」(Steps 170〜172 予定)。**

| 未測定 | 詳細 |
|---|---|
| **musl** での全検証 | `data/verified_gems.json` のどのエントリにも musl 環境の verification 記録が無い(全記録が `glibc x86_64 / ruby 3.4.5`) |
| **aarch64 での gem install 実走** | qemu 上で動く aarch64 版 Ruby が要る。ROADMAP §「M4 受け入れ」と同じ枠 |
| 真の distroless コンテナ検証 | ROADMAP の M3 残項目 |

## 4. 閉じたギャップ(参照のみ)

- **Step 146 の 6 件**(stackprof / nkf の検証が露出): Steps 147〜152 で全て解消。
- **Step 157 の A〜D**(etc の検証が露出): Steps 158〜161 で全て解消し、
  Step 162 で etc 1.4.6 が検証済みになった。**E だけが上の表に残っている。**

いずれも設計判断は STEPS.md の各ステップに記録がある。
