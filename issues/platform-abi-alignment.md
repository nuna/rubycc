---
status: open
kind: debt
opened: 2026-08-13
closed:
branch:
pr:
steps: []
---

# プラットフォーム ABI からの既知の逸脱 3 件を、1 つの major でまとめて閉じる

## 課題

rubycc の生成物は、次の 3 点でプラットフォームの ABI から意図的に逸脱している
(`docs/development/ROADMAP.md` §3)。**いずれも型の大きさ・整列・レイアウトを動かす**ので、
閉じると 1.x でビルドした `.o` / `.so` と ABI が合わなくなる。

| 逸脱 | 現状 | 本来 |
|---|---|---|
| `long double` の幅 | 8 バイト(`double` として扱う) | x86-64 は 80 ビット x87 を 16 バイト、AArch64 は IEEE binary128 |
| `enum` の底型 | すべて `int` へ写像 | gcc は全非負 enum を `unsigned int` に |
| `wchar_t` の符号性 | 同梱 `stddef.h` / `stdint.h` が `int` 固定 | AArch64 gcc は `unsigned int`(`__WCHAR_MAX__` = `0xffffffffU`) |

## 影響

**1 件ずつ直すと major が 3 回上がる。** 利用者から見れば「rubycc がプラットフォーム ABI に
揃った」という**ひとつの変更**なのに、そのたびに全 gem の再ビルドを強いることになる
(ユーザ判断、2026-08-13)。

放置した場合の実害は逸脱ごとに違う。`long double` は**実測済み**で、
`printf("%Lg", x)` に渡すと値が壊れる(GAPS S、oj の `UsualTest#test_decimal`)。
`enum` は c-testsuite 00170 のポインタ符号不一致で顕在化する。`wchar_t` は
ワイド文字を意図的に未対応にしているため、まだ観測不能である。

## 受け入れ条件

- 3 件すべてが同じリリースで閉じ、**major を 1 回だけ上げる**(2.0.0)
- `sizeof(long double)` / `_Alignof(long double)` / `max_align_t` / `float.h` の `LDBL_*` が
  **gcc と一致**する(x86-64 と AArch64 の両方。ABI ハーネスの該当検査を非 assert から戻す)
- 全非負 `enum` の底型が `unsigned int` になり、c-testsuite 00170 の skip が外れる
- `wchar_t` の符号性が機種の gcc と一致する
- **コーパスの合格率が下がらない**(31/34 = 91.2% 以上)。`oj` は通るようになる見込み
- x86-64 / AArch64 × glibc / musl の 4 通りで全スイートが 0 failures
- CHANGELOG に「1.x でビルドした成果物とは ABI 互換性が無い」ことを明記する

## 作業ログ

### 2026-08-13

**バージョニング方針を先に決めた**(README の Versioning 節に追記):
生成物の ABI が変わる変更は、合格率が上がっても major とする。そのうえで、
**既知の ABI 逸脱はまとめて閉じる**。

粒度の注意: この課題は **1 PR に収まらない**。着手時に 3 つ(以上)へ分割し、
**master へは個別に入れず**、まとめて 2.0.0 として出す形を検討する
(`long double` だけでも x87 と binary128 の両方が要る)。
[`long-double-varargs`](long-double-varargs.md) の**第 1 段(可変長引数に渡すときだけ
無損失変換)は、この一括には含めない** — `sizeof` を動かさないので 1.x で出せる。

## 決着

(未着手)
