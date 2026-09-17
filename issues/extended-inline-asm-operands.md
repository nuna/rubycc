---
status: open
kind: gap
opened: 2026-09-18
closed:
branch:
pr:
steps: []
---

# 出力オペランド付きの拡張インラインアセンブリが無い

## 課題

**オペランドを持つ `__asm__` を rubycc は拒否する。** gcc は通す。
2026-09-18 にこのホスト(WSL2 / gcc 13.3)で測った:

```c
static inline unsigned s(unsigned v) { __asm__("bswapl %0" : "=r"(v) : "0"(v)); return v; }
int main(void) { return s(0x12345678u) == 0x78563412u ? 0 : 1; }
```

| | 結果 |
|---|---|
| gcc 13.3 | ok |
| rubycc | **`error: non-empty inline assembly is not supported`** |

`glibc-public-headers-mixed-1` の混在調査で、残る 5 本のうち 3 本がこれに当たる:

- `netatalk/at.h` と `sys/rseq.h` — どちらも `asm/swab.h:10` の `__asm__("bswapl %0" : "=r"(val) : "0"(val))` に至る
  (経路は `gcc -H` で確認: `netatalk/at.h` → `linux/atalk.h` → `asm/byteorder.h` → `linux/byteorder/little_endian.h` → `linux/swab.h` → `asm/swab.h`)
- `sys/platform/x86.h` — glibc 側の `bits/platform/features.h:37` の `__asm__("mov %%fs:72, %0" : "=r"(__feature_1))`
  (セグメント相対のオペランド)

どれもカーネル UAPI か glibc のファイルで、**同梱ヘッダで肩代わりできない**。

## 影響

これらのヘッダを含む gem。**実在の gem ではまだ見ていない**。
DESIGN の要件にインラインアセンブリの実装は無く、空のアセンブリだけを受け付ける現状は意図的である。

## 受け入れ条件

**先に方針を決める**(実装するか、対象外を明文化するか)。実装する場合は 2 段に分けて考える。

- (実装する場合・第 1 段)出力・入力オペランドと clobber を持つ基本形が、x86-64 と AArch64 で gcc と同じ値を返す
  (`"=r"` / `"r"` / `"0"` の制約、`%0` の置換、レジスタ割り当てとの整合)
- (実装する場合・第 2 段)`%%fs:` のようなセグメント相対のオペランドを含む形
- (対象外にする場合)診断の文言を保ったまま、ROADMAP §3 と `docs/reference/OUT-OF-SCOPE-GEMS.md` の基準 B の
  説明に「オペランド付きの `__asm__` を必須の経路で使うヘッダ」を加える
- どちらの場合も `rake test` が 0 failures

## 作業ログ

### 2026-09-18(起票)

`glibc-public-headers-mixed-1` の調査で見つかった 3 本の共通原因。最小再現で確かめた。

## 決着

(未着手)
