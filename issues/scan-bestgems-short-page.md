---
status: open
kind: infra
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# bestgems のページが 1 行欠けると、走査全体が止まる

## 課題

**ランキングの 1 ページで行数が見出しと合わないと、`tools/scan_popular_gems.rb` は走査全体を止める。**
2026-09-13 にランク 8501〜12500(位置引数 `851 1250`)を走査したとき、2 ページ目で止まった:

```
==> ranking: https://bestgems.org/total?page=427 (expecting rank 8521...)
scan failed (RuntimeError): https://bestgems.org/total?page=427: row ranks 8521-8539 disagree with the header (8521-8540)
```

このページは 20 件を名乗りながら 19 行しか載せていなかった。走査は終了コード 1 で終わり、
**それまでに読んだページの分も含めて、候補は 1 件も出なかった**。

回避として、そのページを飛ばしてランク 8541 から走査し直した(位置引数 `855 1250`)。
**同じ日の 2 回目も止まった。** 今度は行が欠けたのではなく、ランクがずれていた:

```
==> ranking: https://bestgems.org/total?page=448 (expecting rank 8941...)
scan failed (RuntimeError): https://bestgems.org/total?page=448: row ranks 8940-8960 disagree with the header (8941-8960)
```

ランク 8500 を越えると、ダウンロード数が並ぶ gem が増えるためか、この種のページに続けて当たる
(2 回とも、それまでに読んだ 20 ページ前後を無駄にした)。3 回目は、読めていたランク 8541〜8940
(位置引数 `855 894`)に窓を絞って回避した。

## 影響

走査の窓を広げるほど、こうしたページに当たる確率は上がる。**1 ページの欠けで数十分の走査が無駄になる**うえ、
どこから再開すればよいかを人が読み取る必要がある。

欠けた 1 行が何だったのか(取り下げられた gem か、bestgems 側の表示の都合か)は確かめていない。

## 受け入れ条件

- 行数が見出しと合わないページに当たっても、走査は**残りのページを続け**、artifact と要約にそのページと
  食い違い(見出しの範囲・実際の行)を記録する
- ランクの整合を確かめる既存の検査(ランクの重複・逆転)は弱めない。**欠けは記録して続け、矛盾は止める**、の
  区別を決めて STEPS に書く
- `test/test_scan_popular_gems.rb` に、19 行のページを返す FakeHttp で上の挙動を固定したテストがあり、0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 の後、100 件の残りを探す走査で当たった。

## 決着

(未着手)
