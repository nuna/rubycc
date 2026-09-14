---
status: done
kind: gap
opened: 2026-09-13
closed: 2026-09-14
branch: gap-fixes-wave-4
pr: 151
steps: [variadic-aggregate-argument-1]
---

# 可変長引数に構造体・共用体を値で渡せない

## 課題

**可変長引数の位置に構造体や共用体を値で渡すと、rubycc はエラーにする。** gcc は通す。
2026-09-13 にこのホスト(WSL2 / gcc 13.3)で最小再現を測った:

```c
union u { int i; void *p; };
int f(int n, ...);
int g(void) { union u v; v.i = 1; return f(1, v); }
```

| | 結果 |
|---|---|
| gcc | ok |
| rubycc | **`error: passing a struct to a variadic function is not supported yet`** |

エラーは `lib/rubycc/ir/generator.rb:4313` で出る。**文言そのものが未実装を自己申告している**。
共用体でも同じ文言になる。

固定引数の構造体渡しは実装済みである(`lower_struct_argument`)。

## 影響

**実在の gem が落ちる。** コーパス候補 `semian` 0.28.4 は `ext/semian/sysv_semaphores.c:90` で

```c
union semun sem_opts;
...
semctl(sem_id, 0, IPC_STAT, sem_opts);
```

と書いている。`semctl` の第 4 引数は可変長で、`union semun` を**値で**渡すのが semctl(2) の
定める呼び方である。**対照の gcc はビルドに成功する**(2026-09-13 実測。対照が落ちたのは
ロードの証明の段で、ハーネス側の既知の盲点である)。

## 受け入れ条件

- 大きさと中身の違う構造体・共用体(8 バイト以下、9〜16 バイト、16 バイト超、`double` を含むもの)を
  可変長引数で渡し、**gcc でコンパイルした呼ばれ側が `va_arg` で読んだ値**が gcc 同士の場合と一致する。
  逆向き(gcc の呼び出し側 → rubycc の呼ばれ側)も同じ
- 上を x86-64 と AArch64 の**両方**で確かめる
- `semian` 0.28.4 が rubycc でビルドできる
- `rake test` が 0 failures

## 着手前に確かめること

- **固定引数の分類をそのまま使えるか**を先に測ること。x86-64 SysV では可変長でも分類
  (INTEGER / SSE / MEMORY)は固定引数と同じだが、`%al` に入れる SSE レジスタ数に数える必要がある。
  AArch64(AAPCS64)では 16 バイト超の複合型は参照渡しになる
- 呼ばれ側の `va_arg(ap, struct T)` も同じ規則で読めるかを、同じ行列で確かめる

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-2 の 34 件のうち、rubycc だけが落ちて対照は通った 1 件。

### 2026-09-14(実装)

修正前は、呼び出し側だけでなく呼ばれ側の `va_arg(ap, struct T)` も拒否していた(両アーキで確認)。呼び出し側は固定引数と
同じ経路に回し、呼ばれ側は同じ分類(`aggregate_plan`)で値を探す降ろしを足した。行列を回すなかで、AArch64 で型に付けた
`aligned(16)` の構造体の置き場所が gcc とずれることを見つけた。固定引数にもある既存の不一致なので、
[`aapcs64-aligned-attribute-aggregate`](aapcs64-aligned-attribute-aggregate.md)(BK)に起票した。

## 決着

**解消した**(`variadic-aggregate-argument-1`。設計判断の本文は [STEPS.md](../docs/development/STEPS.md) の該当節)。

| 受け入れ条件 | 結果 |
|---|---|
| 大きさと中身の違う構造体・共用体を可変長で渡し、両方向で gcc 同士と一致する | `test/test_variadic_aggregate_argument.rb`。17 形 × 前置き 14 通り = 238 呼び出しが両方向で一致 |
| x86-64 と AArch64 の両方で確かめる | 同じテストで両アーキ(AArch64 は qemu-aarch64) |
| `semian` 0.28.4 が rubycc でビルドできる | `ext/semian/*.c` の 4 本はコンパイルできた(2026-09-14)。gem としてのビルドとロードは、この PR の後に測り直して台帳に記録する |
| `rake test` が 0 failures | ブランチ全体の結果を PR に記録する |
