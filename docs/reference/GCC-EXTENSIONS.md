# rubycc GCC 拡張カバレッジ

## `__GNUC__` を定義しない方針

rubycc は `__GNUC__` を定義せず、独自マクロ `__RUBYCC__` を定義する。GCC 固有経路を
選択するヘッダには、実装済みの拡張とポータブルなフォールバックを利用させる。
`__has_builtin` と `__has_attribute` は、rubycc が実装している項目だけを真として返す。

## 分類

| 分類 | 意味 |
|---|---|
| **意味論まで対応** | GCC 拡張の仕様に従ったコードまたは診断を提供する |
| **受理するが no-op** | 構文を受理するが、rubycc の性質上効果を持たせない |
| **非対応** | 未実装であることを診断し、誤ったコードを生成しない |

## 拡張一覧

| 拡張 | 分類 | 現在の仕様 |
|---|---|---|
| GNU 文式 `({ 文...; 式; })` | 意味論まで対応 | 最後の式文の値・型を式全体の値・型とする。`sizeof` の型推論にも対応する |
| `?:` の片側 void アーム | 意味論まで対応 | 片側が void の条件演算子を受理し、副作用を実行して void として扱う |
| `__builtin_offsetof(type, member-designator)` | 意味論まで対応 | ネストしたメンバ、添字、匿名メンバに対応する。ビットフィールドは診断する |
| GNU 名前付き可変長マクロ `#define F(args...)` | 意味論まで対応 | 実引数束縛、stringize、paste、再定義同一性判定を ISO 形式と同じ規則で処理する |
| GNU カンマ削除 `, ## __VA_ARGS__` | 意味論まで対応 | 可変長実引数が省略された場合に限り直前のカンマを削除する |
| `__builtin_constant_p` | 意味論まで対応 | 定数式なら 1、非定数なら 0 を返す。引数自体は評価しない |
| `__builtin_choose_expr(const, a, b)` | 意味論まで対応 | 定数条件で選択した AST を使用し、選ばれない式は評価・コード生成しない |
| `__builtin_ctz`/`__builtin_ctzll`/`__builtin_clz`/`__builtin_clzll` | 意味論まで対応 | 32/64 ビットのビット走査に対応する。0 の動作は GCC と同じく未定義 |
| `__atomic_*` 10 形 | 意味論まで対応 | `load_n`/`store_n`/`exchange_n`/`compare_exchange_n`/`fetch_add`/`fetch_sub`/`add_fetch`/`sub_fetch`/`or_fetch`/`thread_fence` に対応する。対象幅は 4/8 バイト。メモリオーダは受理するが seq_cst として処理し、weak CAS は strong として扱う。x86-64 は lock 命令と MFENCE、aarch64 は LDAR/STLR、LDAXR/STLXR、DMB ISH を使用する |
| `__builtin_add_overflow`/`__builtin_sub_overflow`/`__builtin_mul_overflow` | 意味論まで対応 | 符号付き・符号なし整数の演算結果を格納し、格納先の型でオーバーフローした場合に `_Bool` の 1 を返す。非整数・128 ビットの組み合わせは診断する |
| `__sync_*` 10 形 | 意味論まで対応 | `__sync_fetch_and_add`/`__sync_fetch_and_sub`/`__sync_add_and_fetch`/`__sync_sub_and_fetch`/`__sync_or_and_fetch`/`__sync_lock_test_and_set`/`__sync_lock_release`/`__sync_synchronize`/`__sync_bool_compare_and_swap`/`__sync_val_compare_and_swap` に対応する。整数・ポインタの 4/8 バイトを対象とし、full barrier 契約を持つ |
| `__builtin_unreachable()` | 受理するが no-op | 到達時に実行を継続する。GCC の最適化用途には利用しない |
| `__builtin_memcpy` | 意味論まで対応 | libc の `memcpy` 呼び出しとして扱う |
| `<x86intrin.h>` | 受理するが no-op | 空スタブを提供する。実 intrinsic は対象外 |
| 2 進整数リテラル `0b0001` | 意味論まで対応 | 通常の整数定数と同じ型決定規則で処理する |
| `__has_builtin(x)` | 非対応を正直に返す | 実装済みの組み込み名だけ 1、それ以外は 0 を返す |
| `__has_include(<header>)` | 意味論まで対応 | 実際の `#include` 探索規則に従って判定する |
| `__has_attribute(x)` | 非対応を正直に返す | 意味を実装した `aligned`/`packed` だけ 1、それ以外は 0 を返す |
| `__attribute__((aligned(N)))` / `__attribute__((packed))` | 意味論まで対応 | struct/union のレイアウトに反映する。その他の宣言位置や ABI 制約は診断する |
| その他の `__attribute__((...))` | 受理するが no-op | 構文を受理し、`aligned`/`packed` 以外の効果は持たせない |
| `__asm__ volatile("" ::: "memory")` | 受理するが no-op | 空テンプレート・空オペランドを受理する。実体のある inline asm は診断する |
| `__extension__` | 受理するが no-op | cast 前置として受理する |
| GNU 別名キーワード(`__signed__`/`__const__`/`__volatile__`/`__inline__`) | 意味論まで対応 | 通常の `signed`/`const`/`volatile`/`inline` として扱う |
| `restrict` / `__restrict` / `__restrict__` | 受理するが no-op | 型修飾子として受理するが、エイリアス解析や最適化には利用しない |
| `__int128` | 部分対応 | 加減算・乗算・比較・変換、値渡し・値返し、シフトに対応する。除算・剰余・ビット演算・可変長引数渡しは診断する |
| `#pragma once` | 意味論まで対応 | ファイル単位の重複インクルードを防止する |
| その他の `#pragma` | 受理するが no-op | 本文を読み飛ばし、マクロ退避・復元などの意味論は処理しない |
| `_Pragma("...")` | 受理するが no-op | 4 トークンを消費して破棄する |
| `__builtin_expect(exp, c)` | 受理するが no-op | `exp` の値を返し、分岐予測ヒントは利用しない |
| `__builtin_alloca(n)` / `alloca(n)` | 部分対応 | x86-64 では 16 バイト境界でスタックを確保する。aarch64 では診断する |
| 定義済みターゲット・数値限界マクロ | 意味論まで対応 | `__x86_64__`/`__aarch64__`/`__linux__`/`__LP64__`/`__LONG_MAX__` など対象環境の予約マクロを提供する。`__GNUC__` と非予約形の `linux`/`unix` は定義しない |
| `#include_next` | 意味論まで対応 | 現在の include directory の次から探索する |
| RB_GC_GUARD 互換ランタイム(`rb_gc_guarded_ptr_val`) | 意味論まで対応 | `__GNUC__` を定義しない経路で使用される外部関数を互換ランタイムとして提供する |

## 非対応または部分対応の拡張

- 入れ子関数定義、`case a ... b:`、`[a ... b] = x`、`typeof`/`__typeof__`。
- `__attribute__((__mode__(...)))` など、`aligned`/`packed` 以外で意味を持つ属性。
- 実体のある inline asm。
- `__atomic_test_and_set`/`__atomic_clear`、データ操作の generic
  `__atomic_load`/`__atomic_store`/`__atomic_exchange`/`__atomic_compare_exchange`。
- `__atomic_fetch_or`/`__atomic_fetch_and`/`__atomic_fetch_xor`/`__atomic_fetch_nand`、
  `__atomic_and_fetch`/`__atomic_xor_fetch`/`__atomic_nand_fetch`。
- `__sync_fetch_and_or`/`__sync_fetch_and_and`/`__sync_fetch_and_xor`/
  `__sync_fetch_and_nand`/`__sync_and_and_fetch`/`__sync_xor_and_fetch`/
  `__sync_nand_and_fetch`。
- C11 の `_Atomic` と `<stdatomic.h>` は部分対応で、`atomic_fetch_or`/`_and`/`_xor`、
  `atomic_flag`、`atomic_is_lock_free` は提供しない。
