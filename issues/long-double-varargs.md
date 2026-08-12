---
status: done
kind: gap
opened: 2026-08-12
closed: 2026-08-13
branch: long-double-varargs
pr:
steps: [long-double-varargs-1]
---

# 可変長引数に渡した `long double` を libc が読める形で積む

## 課題

rubycc は `long double` を 8 バイトの `double` として扱う(DESIGN §3.3 の既知の制限)。
x86-64 psABI は 80 ビット x87 を 16 バイトで、AArch64 は IEEE binary128 を渡す。

可変長引数に渡すと**呼ばれた側が読む幅と積んだ幅が食い違う**。最小再現
(2026-08-08、glibc x86-64 / gcc 13):

```c
printf("[%Lg]\n", (long double)1.234567);
```

| | 出力 |
|---|---|
| gcc | `[1.23457]` |
| rubycc | `[7.46537e-4948]` |

実 gem での実害も測れている: `oj` の `usual.c:470` が
`sprintf(buf, "%Lg", p->num.dub)` を使い、`UsualTest#test_decimal` が
`ArgumentError: invalid value for BigDecimal(): "-nan"` で落ちる。
**gcc 対照と食い違う唯一のテスト**である(`atomic-type-12` で失敗テスト名の集合を突き合わせ、
gcc 75 件・rubycc 76 件、差分はこの 1 件だけと確認)。

## 影響

`long double` を計算に使うだけなら double の範囲と精度で動くが、**libc の境界を越えると
値が壊れる**。壊れ方が「エラー」ではなく「もっともらしい別の数値」なので、
利用者が気づきにくい。

R10 では `oj` が唯一の未通過要因として残っている(コーパス合格率は 31/34 = 91.2% で
達成済みなので、合格率のためではなく正しさのために直す)。

## 受け入れ条件

- `printf("%Lg", (long double)x)` の出力が gcc と一致する(x86-64・AArch64 の両方)
- `oj` の上流スイートで `UsualTest#test_decimal` が通り、失敗テスト名の集合が gcc 対照と一致する
- 既存の ABI ハーネスと全スイートに回帰がない

## 作業ログ

### 2026-08-12

着手前の設計方針を 2 段階で決めた(`docs/development/ROADMAP.md` §3 の負債表に記録済み)。

- **第 1 段**: 可変長引数に渡すときだけ、double を 80 ビット拡張形式(AArch64 は
  binary128)に変換して積む。**double は両形式の部分集合なので変換は無損失**で、
  観測されている実害はこれで閉じる。`sizeof(long double)` が 8 のままである食い違いは残る
- **第 2 段**: x87 / binary128 の演算そのもの。パーサ・定数畳み込み・ABI 分類・`va_arg` に及ぶ

**第 2 段はこの課題では扱わない。** `sizeof(long double)` を 8 から 16 へ動かすので、
他の ABI 逸脱(enum の底型、`wchar_t` の符号性)とまとめて 1 つの major で閉じる
([platform-abi-alignment](platform-abi-alignment.md)、ユーザ判断 2026-08-13)。
**第 1 段は `sizeof` を動かさないので 1.x で出せる** — 版は oj が通るかで決まる
(通れば合格率が上がるので minor、変わらなければ patch)。

v1.0 では挙動を変えず、README と CHANGELOG の既知の制限に明記する判断を取った
(`gaps-s-t-u-3`)。理由: 実害が測定済みで oj の 1 テストに限定される一方、
可変長引数の `long double` を診断エラーにすると**今ビルドできている gem が
ビルドできなくなる**副作用の方が広い。

### 2026-08-13(着手)

実装前に、**現状の測定**と**設計判断**を記録する。

#### 測ったこと

- `long double` は**パース時点で `Type::Double` に潰されている**(`front/parser.rb:1290`
  の `return Type::Double`)。したがって呼び出し側では「これは long double だった」と
  知りようがなく、**型の識別を取り戻すのが第 1 段の前提**である
- `Type::Double` を直接比較している箇所は **lib 全体で 9 箇所**
  (generator 3・parser 3・type 2・ast 1)。`FloatType` は `Data.define(:name, :size)` なので、
  名前違いの新インスタンスは自然に別値になる

#### 設計判断

1. **`Type::LongDouble`(`FloatType.new("long double", 8)`)を足す。**
   **サイズは 8 のまま**にする — `sizeof` を動かすのは ABI 変更であり、
   [platform-abi-alignment](platform-abi-alignment.md) の 2.0.0 に属するため
2. **演算は double と同一**。通常の算術変換でも double として振る舞い、
   新しい IR 命令は足さない。変わるのは**呼び出し側の 1 点だけ**である
3. **可変長引数に渡すときだけ**、double のビット列を対象機種の long double 形式へ
   変換し、その機種の ABI に従って渡す(x86-64 SysV は X87/X87UP = メモリ級で
   16 バイト整列、AArch64 は IEEE binary128)
4. **変換はビット操作で行う**(x87 命令のエンコーダを新設しない)。double は
   80 ビット拡張・binary128 のいずれの部分集合でもあるので**変換は無損失**。
   ゼロ・±inf・NaN・非正規数は個別に扱う
5. **`va_arg(ap, long double)` は現状の診断エラーのままとする** — 受け取り側は
   この段の対象外。範囲を「libc 境界へ渡す」に絞る

#### 変えないもの

`sizeof(long double)` = 8、構造体レイアウト、`float.h` の `LDBL_*`、`max_align_t`。
これらは 2.0.0 で一括して動かす。

## 決着

**解消した**(`long-double-varargs-1`)。可変長引数に渡すときだけ、double のビット列を
対象機種の long double 形式へ変換するようにした。設計判断と、実装中に見つかった
既存バグ 2 件は `docs/development/STEPS.md` の該当ステップにある。

受け入れ条件の確認:

| 条件 | 結果 |
|---|---|
| `printf("%Lg", x)` が gcc と一致(x86-64 / AArch64) | **一致**。±0・±inf・NaN・非正規数 52 段・DBL_MAX/MIN を含む。gcc 製 callee に `va_arg` で読み戻させた**生バイトも一致** |
| oj の `UsualTest#test_decimal` が通る | **通る**。`BigDecimal` への変換が `-nan` → `0.123457e1` |
| 失敗テスト名の集合が gcc 対照と一致 | **一致**。個別実行・シード 1234 で両側とも 687 runs / 1 failure / 2 errors、名前も同一(`DebJuice#test_as_json_object_compat_hash_cached` と `SajTest#test_file`)。**rubycc 側だけの失敗はゼロ** |
| 既存の ABI ハーネスと全スイートに回帰なし | **無し**。3,131 runs / 0 failures / 41 skips |

**残るのは 2.0.0 の範囲**である。`sizeof(long double)` は 8 のまま(gcc は 16)、
名前付き引数と戻り値の `long double` も依然 double として ABI に載るので、
`frexpl` のような libc 関数との受け渡しは不整合が残る。これらは
[platform-abi-alignment](platform-abi-alignment.md) で一括して閉じる。
