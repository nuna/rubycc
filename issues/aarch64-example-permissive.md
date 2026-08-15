---
status: in-progress
kind: gap
opened: 2026-08-15
closed:
branch: aarch64-example-permissive
pr:
steps: []
---

# AArch64 のサンプル差分テストに `-fpermissive` の仕組みが無い

## 課題

`test/test_examples.rb`(x86-64)は `OBSOLETE_C_EXAMPLES` を持ち、そこに挙げたサンプルの
**対照 gcc にだけ** `-fpermissive` を渡す。gcc 14 が K&R 形式の関数定義を既定でエラーに
したためで、対照が拒否するのは rubycc の欠陥ではない(経緯は
`docs/development/STEPS.md` の `m4-aarch64-acceptance-3`)。

**`test/test_examples_aarch64.rb` には同じ仕組みが無い。** そのため gcc 14 以降の環境で
次が落ちる(2026-08-14、`register-allocation-3` の検証中に Debian trixie / gcc 14.2 の
エミュレート aarch64 コンテナで実測):

```
TestExamplesAArch64#test_example_aarch64_atomic_type_10_knr_definitions
```

**失敗しているのは対照側の gcc** で、rubycc の出力には到達していない。ホストの
gcc 13.3 では同じテストが pass するため、これまで露出していなかった。

## 影響

gcc 14 以降を積んだ AArch64 環境(将来の CI イメージ更新、開発者のローカル)で、
**rubycc に欠陥が無いのに 1 件落ちる**。`docs/development/GAPS.md` のギャップ W は
x86-64 側の同じ問題を扱っており、そこに AArch64 が抜けている。

## 受け入れ条件

- `test/test_examples_aarch64.rb` が x86-64 側と同じ根拠・同じ一覧で対照に
  `-fpermissive` を渡す(一覧を 2 か所に写さないこと — 共有するか、片方から参照する)
- gcc 14 のエミュレート環境で `test_example_aarch64_atomic_type_10_knr_definitions` が pass する
- gcc 13 のホストでも従来どおり pass する

## 作業ログ

### 2026-08-15(起票)

`register-allocation-3` の検証中に見つけ、**その場では直さずに切り出した**。
このステップとは独立の既存の穴である。

### 2026-08-15(実装・レビュー)

- gcc 14 で拒否されるサンプルの allowlist を `ExecutionHelper` に集約し、x86-64 と
  AArch64 の対照経路から共有するようにした。
- AArch64 の対照 gcc に `-std=gnu17` と、allowlist に該当する場合だけ
  `-fpermissive` を渡す回帰テストを追加した。
- gcc 13.3 のホストで x86-64 の examples 52 runs / 0 failures、AArch64 の
  examples + c-testsuite 548 runs / 0 failures / 28 skips を確認した。
- Debian trixie / AArch64 gcc 14.2 のエミュレート環境で、対象テスト
  `test_example_aarch64_atomic_type_10_knr_definitions` を 1 run / 0 failures で確認した。
  `-fpermissive` を外した同じ gcc コマンドは `-Wimplicit-int` で失敗する。
- PR 前の批判的レビューで、allowlist の重複・過剰適用・テスト不足を確認し、追加の修正は不要と判断した。

## 決着

(実装・検証済み。PR の master 取り込み後に `closed` / `pr` を記入する)
