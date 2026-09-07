---
status: done
kind: gap
opened: 2026-08-25
closed: 2026-09-08
branch: ar-reader-name-encoding
pr: 123
steps: [ar-reader-name-encoding-1]
---

# `ArReader` が返すメンバ名の綴りが、名前の長さで変わる

## 課題

`ArReader` はアーカイブから読んだ名前を**長さによって違うエンコーディングで返す**。
短い名前(ヘッダに直接入る 16 バイト未満)はバイト列のまま、長い名前(名前表へ追い出される
もの)は `force_encoding(Encoding::UTF_8)` を通る(`lib/rubycc/objfile/ar_archive.rb:204`)。
シンボル索引の名前も同じ形である(`:226`)。

実測(2026-08-25、ホスト、Ruby 3.4.5)。同じ 1 本のアーカイブに、同じ非 ASCII バイトを
含む短い名前と長い名前を入れて読み戻す:

```
"s\xE6\x97\xA5.o"                bytesize=6   encoding=ASCII-8BIT
"llllllllllllllllllll\xE6\x97\xA5.o"  bytesize=25  encoding=UTF-8
```

**非 ASCII を含む文字列は、エンコーディングが違えば `==` も `eql?` も `hash` も
一致しない。**したがって「リーダの戻り値を、別の出所の名前と突き合わせる」コードは、
**名前の長さによって当たったり外れたりする**。

## 影響

`argv-encoding-sibling-clis-1` の時点で、実際に外れているのは
**`exe/rubycc-ar` の `ar r`(置換)と `ar x`(展開)**だった。コマンドラインの名前は
ARGV 由来なので、短い名前とは一致せず、置換すべきところで**重複追加**になり、
展開は**無出力・exit 0**で終わっていた。これは同ステップで CLI 側に `member_key` を
置いて吸収したので、`rubycc-ar` からは見えなくなっている。

**リーダ自体は直していない。**戻り値はリンカの遅延展開も消費しており
(`member_defining` とシンボル索引)、そちらで同じ形が残っているかは測っていない。
C の識別子は非 ASCII になり得ないので、素直な経路では踏まない。踏むとすれば
アセンブラのラベルなど、任意バイトのシンボル名を持つオブジェクトである。

## 受け入れ条件

- `ArReader` が返すメンバ名とシンボル名の綴りが、**名前の長さによらず同じ**であること
- **リンカ側の消費経路が壊れないこと** — アーカイブの遅延展開が、非 ASCII のシンボル名を
  含む場合も含めて従来どおり解決すること(`test/` に検査があること)
- `exe/rubycc-ar` の `member_key` が不要になるなら外す。残すなら、なぜ残すかを書く
- `bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256 が変更前後で一致)

## 作業ログ

### 2026-08-25(起票)

`argv-encoding-sibling-clis` の実装中に見つけた。**リーダを直すとリンカまで影響が及ぶ**ため、
そのステップでは CLI 側で吸収し、リーダの非対称は事実として残した。

`lib/rubycc.rb` の規則(rubycc が読むものはバイト列)に照らせば、**`force_encoding` を
外してバイト列に揃えるのが筋**に見える。ただし先行 3 ステップがいずれも
「直した側ではなく直したことで壊れた側」に手間を取られているので、**リンカ側の
突き合わせを先に洗ってから**着手すること。

## 決着

**解消した**(`ar-reader-name-encoding-1`。設計判断の本文は
[STEPS.md](../docs/development/STEPS.md) の該当節)。

`force_encoding` を 2 箇所とも外して**全部バイト列**に揃え、CLI 側で吸収していた
`member_key` を外した。受け入れ条件の照合:

| 条件 | 結果 |
|---|---|
| 名前の綴りが長さによらず同じ | 同じ非 ASCII バイトを持つ短い名前・長い名前を 1 本のアーカイブで検査(`test_member_names_are_bytes_whatever_their_length`)。シンボル索引側も同様 |
| リンカ側の消費経路が壊れない | 非 ASCII シンボルを持つメンバの遅延展開を検査(`test_linker_pulls_the_member_defining_a_non_ascii_symbol`) |
| `member_key` を外すか、残す理由を書く | **外した**。説明は ARGV 再タグ付けのコメントへ統合し、過去の症状(`r` が重複追加、`x` が無出力・exit 0)も残した |
| `rake test` が 0 failures | **3421 runs / 0 failures / 0 errors / 39 skips**(master 3417 に対し +4 は追加テスト) |
| 生成物が変わらない | `benchmark/c/*.c` 5 件 + `examples/m6/*.c` 7 件の計 12 件すべて sha256 一致 |

**着手前に「先に洗え」と書いた懸念は、実装上は存在しなかった。** `PartialLinker` は
`ArReader` のシンボル索引(`member_defining` / `symbol_index`)を一度も呼ばず、
各メンバを `ELFReader` に食わせ直している。226 行目の `force_encoding` が届く先は
テストだけだった。

**代わりに、別の壊れ方が実測で出てきた。** 非 ASCII のメンバ名を UTF-8 タグの
アーカイブパスと補間する診断ラベル(`partial_linker.rb:201`)が
`Encoding::CompatibilityError` を上げる。**変更前から短い名前で落ちていた**もので、
リーダを揃えると長い名前もそこに揃ってしまう。`load_input` の境界でパスを `.b` に
再タグ付けして閉じた(`lib/rubycc.rb` の境界規則そのもの)。

| メンバ名 | パス `libascii.a` | パス `libあ.a`(UTF-8) |
|---|---|---|
| 短い(変更前) | ok | **CompatibilityError** |
| 長い(変更前) | ok | ok |
| 短い・長い(本ステップ) | ok | **ok** |

`ELFReader` にも同じ `force_encoding` があり、**今回 `ArReader` 側だけが規約に揃った
結果、食い違いは 2 つのリーダの間に移った**。その場では直さず
[`elf-reader-name-encoding`](elf-reader-name-encoding.md)(GAPS の **AD**)に起票した。
