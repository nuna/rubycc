---
status: open
kind: docs
opened: 2026-08-27
closed:
branch:
pr:
steps: []
---

# `rbs` を R10 の分母に残すか外すかを決めて、`test/corpus/gems.rb` に宣言する

## 課題

`rbs` 3.10.0 は R10 の分母に入っているが FAIL である
(`corpus-sqlite3-pg-2` で実測、707 tests / 5,414 assertions / 18 failures / 7 errors / 10 omissions)。
落ちるのは `RDocPluginParserTest` で、**原因は C 拡張ではなく上流の純 Ruby 側** —
ホスト Ruby 3.4 同梱の `RDoc::TokenStream#collect_tokens` と引数が合っていない。
`RUBYCC=1 gem install rbs --version 3.10.0` 自体は成功し、`rbs_extension.so` は生成される。

**gcc 対照も桁まで同じ数字**だった。これは `byebug` / `unicorn` / `debug` に適用した除外基準
(どの実装で建てても (d) 水準の証拠が取れない = `control_suite_passes: false`)を満たす。

にもかかわらず分母に残してある。理由は当時の記録にある — `pg` が通った時点で 90% を
超えており、**分母を小さくして達成するのは達成の意味を薄める**からである
(`corpus-sqlite3-pg-2`)。判断そのものは「別ステップ」として ROADMAP §8 の散文に
残されたまま、起票されていなかった。

現在の R10 通過率は **31/34 = 91.2%**(一次情報は `test/corpus/include-census.md` の
「R10 pass rate」節で、`data/verified_gems.json` から生成される)。

## 影響

**どちらに決めても合格率は 90% を割らない。** 外せば 31/33 = 93.9%、残せば 31/34 = 91.2%。
つまりこれは達成/未達を動かす判断ではなく、**分母が何を意味するかを揃える**判断である。

放置した場合の実害は、除外基準の適用が gem によって揃わないこと。
`byebug` / `unicorn` / `debug` には `control_suite_passes: false` を付けて外したのに、
同じ基準を満たす `rbs` だけが分母に残っている状態が、理由の記録なしに続く。

## 受け入れ条件

次のどちらかが真になる。

**A. 外す場合**
- `test/corpus/gems.rb` の `rbs` エントリに `control_suite_passes: false` と、
  測定日・対照の数字・`corpus-sqlite3-pg-2` への参照を含む `note` が入る
  (先例は同ファイルの `byebug` / `debug` エントリ)
- `test/corpus/include-census.md` の「R10 pass rate」節が再生成され、分母が 33 になる
- README / CHANGELOG の合格率の記述が新しい値と一致する

**B. 残す場合**
- `test/corpus/gems.rb` の `rbs` エントリの `note` に、**基準を満たすのに残す理由**が書かれる
  (「分母を小さくして達成しない」という方針そのものが理由なら、それを明示する)
- ROADMAP §8 の「外すかどうかは別ステップの判断とし」の一文が消し込まれる

いずれの場合も `rake test` が 0 failures であること。

## 作業ログ

### 2026-08-27

ROADMAP §8 の散文に「別ステップの判断」として残っていた宿題を起票した。
測定は済んでいるので、**必要なのは判断と宣言だけ**である。新たに測るものは無い。

判断の材料として、除外の先例 3 件はいずれも「上流の suite が対照コンパイラでも通らない」
= `control_suite_passes: false` であり、`rbs` はこれに該当する
(2026-08-07 の `atomic-type-8` で byebug / debug、`corpus-sqlite3-pg-2` で rbs)。

## 決着

(未着手)
