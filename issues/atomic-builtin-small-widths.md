---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# `__atomic_*` ビルトインが 1 バイト・2 バイトの対象を拒否する

## 課題

**`__atomic_exchange_n` を 1 バイトや 2 バイトの対象に使うと、rubycc はエラーにする。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
static unsigned char flag;
unsigned char f(void) { return __atomic_exchange_n(&flag, 1, __ATOMIC_SEQ_CST); }
unsigned short g(unsigned short *p) { return __atomic_exchange_n(p, 2, __ATOMIC_SEQ_CST); }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: '__atomic_exchange_n' supports atomic objects of 4 or 8 bytes only, but 'unsigned char' has width 1`** |

DESIGN R7 は「`__atomic_*` / `__sync_*` ビルトインの主要セット(シングル命令 or lock 前置で実装)」を
必須の拡張に挙げている。**文言が示すとおり、実装は 4 バイトと 8 バイトに限られている。**
x86-64 の `xchg` / `lock cmpxchg` などは 1 / 2 バイトの形も持ち、AArch64 も 1 / 2 バイトの排他ロード・ストア
(`ldaxrb` / `ldaxrh` など)を持つ。

## 影響

**実在の gem が落ちる。** コーパス候補 `iodine` 0.7.59 は、同梱の facil.io の `fio.h:3023` で
1 バイトのロック(`fio_lock_i`)に対して `fio_atomic_xchange` を使い、それが `__atomic_exchange_n` に展開される。
**対照の gcc はビルドに成功する**(2026-09-13 実測、buildable-gems-batch-4。対照が落ちたのはロードの証明の段)。

1 バイトのスピンロックはよくある書き方なので、他の gem にもあると見込む。

## 受け入れ条件

- 上の最小再現が通り、1 / 2 バイトの `__atomic_exchange_n` / `__atomic_compare_exchange_n` /
  `__atomic_fetch_add` などが、x86-64 と AArch64 の**両方**で gcc と同じ値を返す(複数スレッドでの実行を含む)
- **どのビルトインが 4 / 8 バイト限定か**を一覧にし、足す範囲を STEPS に書く
- `iodine` 0.7.59 が rubycc でビルドできる
- `rake test` が 0 failures

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で、rubycc だけが落ちて対照は通った 1 件。

## 決着

(未着手)
