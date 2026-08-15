---
status: in-progress
kind: infra
opened: 2026-08-15
closed:
branch: qemu-aarch64-binfmt-flag
pr:
steps: []
---

# `rake test:qemu_aarch64` がこのホストの binfmt 設定では起動しない

## 課題

`Rakefile` の `test:qemu_aarch64` は、arm64 コンテナ内で名指しのテストを走らせる
(`docs/internals/CI.md` が「QEMU は native の代わりにはならないが、変更が触ったファイルを
先に回す往復を分単位にする」ために置いた手順)。

**このホストでは起動しない**(2026-08-14 実測):

```
exec /usr/bin/bash: exec format error
```

原因はホストの binfmt ハンドラである。arm64 のエントリが distro の
`qemu-user-binfmt` 由来で **F フラグ(インタプリタをあらかじめ開いておく)を持たない**
ため、コンテナの mount namespace からインタプリタが見えない。
`docker run --privileged --rm tonistiigi/binfmt --install arm64` は、同名エントリが
既にあるため no-op だった。

回避策は実証済みで、同じ `docker run` にホストの qemu を bind-mount する:

```
-v /usr/libexec/qemu-binfmt:/usr/libexec/qemu-binfmt:ro -v /usr/bin/qemu-aarch64:/usr/bin/qemu-aarch64:ro \
-v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro -v /lib64:/lib64:ro
```

## 影響

**文書化された手順が、この開発機では動かない。** 手順を信じた作業者は
`exec format error` の原因調査に時間を使う。ホストの binfmt 設定を書き換える
(distro のエントリを外して F フラグ付きで再登録する)のは**環境そのものの変更**なので、
リポジトリ側で選べる道ではない。

なお、ホストの `rake test` 自体は qemu-user と `aarch64-linux-gnu-gcc` で AArch64 の
差分実行を回しており(`TestAArch64Execution` / `TestExamplesAArch64` ほか)、
**AArch64 の検証手段が無いわけではない**。

## 受け入れ条件

- F フラグの無い binfmt でも `rake test:qemu_aarch64` が動く。少なくとも次のどちらか:
  - タスクが必要な bind-mount を自分で付ける(ホストに qemu がある場合)
  - 起動前に検出して、**何をすればよいかを述べて中止する**(`exec format error` を出さない)
- 選んだ方の根拠を `docs/internals/CI.md` に 1 段落で残す

## 作業ログ

### 2026-08-15(起票)

`register-allocation-3` の検証中に判明。回避策で AArch64 の差分実行は実施し、
既知のギャップ W 由来の 1 件を除いて 0 failures だった。

### 2026-08-15(実装)

- Docker デーモンの architecture を確認し、native AArch64 以外では同じ基底イメージの
  `/bin/true` を `--platform linux/arm64` で実行する preflight を追加した。
- preflight は `qemu_aarch64_image` の build より前に実行し、binfmt 由来の失敗には
  F フラグ付きハンドラまたは bind-mount の復旧手順を案内する。
- Docker クライアント側の `/proc` は判定の正にせず、失敗時の診断情報としてだけ使う。
- preflight の単体テスト 6 runs / 22 assertions と、現在の環境での早期終了を確認した。

## 決着

(未着手)
