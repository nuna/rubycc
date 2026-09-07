---
status: open
kind: gap
opened: 2026-09-08
closed:
branch:
pr:
steps: []
---

# `ELFReader` が返す名前が UTF-8 タグ付きで、バイト列の名前と突き合わせられない

## 課題

`ELFReader#read_string`(`lib/rubycc/objfile/elf_reader.rb:634`)が、文字列表から
読んだ名前を `force_encoding(Encoding::UTF_8)` している。この 1 か所を通るのは
**セクション名・シンボル名(`.symtab` / `.dynsym`)・`DT_SONAME` / `DT_NEEDED`**
の全部である(呼び出しは `:352` `:438` `:527` `:528` `:590`)。

実測(2026-09-08、ホスト、Ruby 3.4.5)。`RelocatableWriter` にバイト列の
シンボル名 `"helper_\xE6\x97\xA5"`(6 + 3 + 1 = 10 バイト)を渡して書き、
`ELFReader` で読み戻す:

```
書いた名前   encoding=ASCII-8BIT
読んだ名前   encoding=UTF-8   bytesize=10
ELFReader#symbol("helper_\xE6\x97\xA5".b)  #=> nil   # 同じ 10 バイトなのに引けない
```

同じオブジェクトを `ArWriter` でアーカイブに入れて `ArReader` で読むと、
シンボル索引の名前は **ASCII-8BIT** で返る(`ar-reader-name-encoding-1` で揃えた)。
**リーダ 2 つの綴りが食い違っている**のはここである。

## 影響

`lib/rubycc.rb` の規約は「rubycc が読むものはすべてバイト列」で、`ELFReader` は
そこから外れている。**非 ASCII を含む文字列は、エンコーディングが違えば `==` も
`eql?` も `hash` も一致しない**ので、

- `ELFReader#symbol` / `#dynamic_symbol` に**バイト列の名前を渡すと引けない**(上の実測)
- `ArReader#member_defining` に `ELFReader` 由来の名前を渡しても引けない(逆向きも同じ)

いまのところ実害は出ていない。リンカ(`PartialLinker`)は突き合わせの**両側とも
`ELFReader` 由来**なので綴りが揃っており、`ArReader` のシンボル索引は消費していない
(`ar-reader-name-encoding-1` で確認)。ドライバが持つ名前(`main` / `_start` など)は
ASCII なので、エンコーディングが違っても一致する。踏むとすれば**任意バイトの
シンボル名を持つオブジェクト**(アセンブラのラベル)を、名前で引く経路である。

C の識別子は非 ASCII になり得ない、という理由で先送りされてきた形だが、
`ar-reader-name-encoding` で **`ArReader` 側だけが規約に揃った**ため、
食い違いは 2 つのリーダの間に移っている。

**休眠していることは実測で確かめた**(2026-09-08):

| 調べたこと | 結果 |
|---|---|
| ELF から読んだ名前どうしの突き合わせ(`exporter_index` / `@undefined` / `@defined`) | **両側とも同じリーダ由来**なのでタグが揃う |
| ELF の名前と ARGV 由来の名前が出会う経路(`-u`、エントリシンボル、version script、`--wrap`) | **存在しない**(該当オプションが未実装) |
| ELF の名前とリテラルの比較 | `sec.name == ".interp"` のみ。ASCII なのでタグは影響しない |

## 受け入れ条件

- `ELFReader` が返すセクション名・シンボル名・`DT_SONAME` / `DT_NEEDED` の
  エンコーディングがすべて `ASCII-8BIT` であること
- `ELFReader.read(...).symbol(name)` が、**書いたときと同じバイト列**で引けること
  (非 ASCII のシンボル名で `test/` に検査があること)
- `ArReader#member_defining` と `ELFReader#symbol` が、同じシンボルについて
  同じ綴りの名前で引けること
- `bundle exec rake test` が 0 failures
- 生成物が変わらないこと(`benchmark/c/*.c` と `examples/m6/*.c` の sha256 が変更前後で一致)
- **診断メッセージへの補間が壊れないこと。** バイト列を UTF-8 リテラルへ補間すると、
  非 ASCII バイトを含む時点で `Encoding::CompatibilityError` になる。
  `ar-reader-name-encoding-1` では `PartialLinker#load_input` の境界で
  パスを `.b` に再タグ付けして受けた(**診断の文字列が例外の発生源になってはならない**)。
  ELF 側を揃えるときも同じ形で受けられるか、経路ごとに確かめること

## 作業ログ

### 2026-09-08(起票)

`ar-reader-name-encoding` の実装中に見つけた。`ArReader` を規約(バイト列)に
揃えたところ、リンカの遅延展開を検査するテストで `merged.symbol(name)` が
`nil` を返し、`ELFReader` 側の `force_encoding` に行き当たった。
そのテスト(`test/test_ar_archive.rb` の
`test_linker_pulls_the_member_defining_a_non_ascii_symbol`)は、どちらのメンバが
展開されたかだけを見れば足りるので、**名前を `.b` に落として比較**しており、
この課題を跨いでいる。解消したらその `.b` は外せる。

**`ELFReader` は `ArReader` より消費者が多い**(リンカ 3 種・`ArWriter` の索引生成・
ライブラリ解決・多数のテスト)。`ar-reader-name-encoding` と同じく、直すこと自体より
**直したことで壊れる側**を洗う作業になる見込み。

## 決着

(未着手)
