---
status: open
kind: gap
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 長さ 0 の配列(GNU 拡張)を拒否する

## 課題

**`int z[0];` を rubycc は拒否する。** gcc は GNU 拡張として受理する。
2026-09-13 にこのホスト(WSL2 / gcc 14.2)で実測:

```c
static int z[0];
int main(void) { return sizeof(z); }
```

| | 結果 |
|---|---|
| gcc | **ok**(`sizeof(z)` は 0) |
| rubycc | **`error: array size must be positive`** |

C の規格は配列の要素数を 0 より大きいと定めており(6.7.6.2p1)、**rubycc の診断は
規格には忠実**である。ただし gcc は**長さ 0 の配列を拡張として認めて**おり、
構造体末尾の可変長メンバや「場所だけ確保したい」用途で実コードに現れる。

## 影響

**実在の gem が落ちる。** コーパス候補 `binding_ninja` 0.2.3 は
`ext/binding_ninja/binding_ninja.c:78` で

```c
static VALUE dummy_proc_args, dummy_method_arg[0];
```

と書いているため `build_load` に失敗する(2026-09-13 実測)。**対照(host gcc)は成功する。**

## 受け入れ条件

次のどちらかを、**根拠付きで決めてから**実装する。

**A. 受理する場合**
- 上の最小再現が gcc と同じく通り、`sizeof` が **0** になる
- **構造体の末尾に置いた場合**の `sizeof` とオフセットが gcc と一致する
  (`struct { int n; char b[0]; }` の `sizeof` と `offsetof(.., b)`)
- 配列の要素数が**負**のときは引き続き診断する(拡張は 0 までである)
- `binding_ninja` 0.2.3 が `build_load` を通る

**B. 受理しない場合**
- `docs/reference/OUT-OF-SCOPE-GEMS.md` に基準と `binding_ninja` の行を足し、
  **再検討の条件**を書く
- 「規格に忠実だから直さない」で止めず、**同じ形の gem が他に何件あるか**を
  コーパス走査の結果から数えて記録する

## 着手前に確かめること

- **フレキシブル配列メンバ(`char b[];`、C99)を既に受理しているか**を先に測ること。
  受理しているなら、`[0]` はその綴り違いに過ぎず、受理する側に倒す理由が強くなる
- gcc は `-pedantic` で警告するが既定では黙って受理する。**既定に合わせるかどうか**が
  この判断の本体である

## 作業ログ

### 2026-09-13(起票)

コーパス候補 46 件の `build_load` で、rubycc だけが落ちて対照は通る 5 件のうちの 1 件。

## 決着

(未着手)
