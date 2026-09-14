---
status: open
kind: debt
opened: 2026-09-13
closed:
branch:
pr:
steps: []
---

# 同梱ヘッダの抜けを 1 件ずつではなく、ヘッダごとに glibc と突き合わせて洗い出す

## 課題

**同梱ヘッダの宣言・型の抜けで、実在の gem が落ちた件が 2026-09-13 の 1 日で 5 件起票された。**
どれも対照の gcc(glibc 本体のヘッダ)ではビルドできる:

| GAPS | 同梱ヘッダ | 抜けていたもの | gem |
|---|---|---|---|
| AF | `stdlib.h` | `getloadavg`(`__USE_MISC`) | vmstat |
| AM | `sched.h` | `struct sched_param`(`<spawn.h>` がメンバに持つ) | posix-spawn |
| AQ | `sys/types.h` | 内部名 `__caddr_t`(`<net/if.h>` が使う) | network_interface |
| AR | `stdlib.h` | `qsort_r`(`__USE_GNU`) | enumerable-statistics |
| — | `termios.h` | `tcflow` と `TCO*` / `TCI*` の定数(POSIX) | ruby-termios([issue](bundled-termios-tcflow.md)) |

同梱ヘッダは、Step 123 / 124(M5 H2)などで**コーパスのサンプルが使った分だけ**を再現する方針で作られた
(各ヘッダの冒頭のコメントが「corpus sample census hit needs」と範囲を述べている)。
**コーパスの外の gem を流し始めると、この絞り込みが当たり続ける。**

もう 1 つの形もある。AU(同梱 `pthread.h` が glibc のガード `__have_pthread_attr_t` を立てない)は、
**同梱ヘッダと glibc 本体のヘッダが混ざる所**で起きた。Ruby の拡張は `_GNU_SOURCE` のもとで
コンパイルされる(Ruby の `config.h:17`)ので、glibc 本体の GNU の枝が同梱ヘッダの隣に並ぶ。

## 影響

1 件ずつ塞ぐと、**gem を 1 つ流すたびに次の抜けに当たる**。起票・最小再現・ABI の突き合わせ・由来台帳の
更新が毎回かかる。

## 受け入れ条件

- 同梱ヘッダ 1 本ごとに、**glibc 本体の同名ヘッダが `_GNU_SOURCE` のもとで宣言する名前**(関数・型・マクロ)の
  一覧と、同梱ヘッダが宣言する名前の一覧を機械的に出し、差分を表にする(x86-64 と aarch64 の両方)
- 差分の各項目を「足す / 意図して外す(理由)」に分け、意図して外すものは各ヘッダの冒頭のコメントに書く
- **glibc 本体のヘッダと共有するガード**(`__have_*` / `__*_defined`)を、同梱ヘッダが立てているかを一覧にする(AU の形)
- 上の 5 件の issue を、この表から足す形で閉じられることを確かめる(閉じるのは各 issue の側)
- ヘッダのテキストを写経しない。測ってから書く(`docs/reference/HEADER-LICENSING.md` §6)

## 作業ログ

### 2026-09-13(起票)

buildable-gems-batch-4 で termios が 5 件目になったので、1 件ずつ塞ぐ前に全体を見る作業として起票した。

### 2026-09-14(第 1 段、`gap-fixes-wave-4`、PR 151)

- `bundled-headers-coverage-audit-1`: 突き合わせの道具 `tools/audit_bundled_headers.rb` と、その生成物
  [`BUNDLED-HEADERS-COVERAGE.md`](../docs/development/BUNDLED-HEADERS-COVERAGE.md) を作った。同梱ヘッダ 54 本すべてについて、
  glibc が `_GNU_SOURCE` のもとで宣言する名前との差分(x86-64 / aarch64)、共有ガード、glibc 本体のヘッダとの混在を出す
- `bundled-headers-coverage-audit-2`: 表から AF・AM・AQ・AR・BA・BB・BG と、途中で見つかった BL(`union sigval`)を直した。
  共有ガードの点検で `siginfo_t` にも同じ穴があり(`<sys/pidfd.h>` と並べると両順とも落ちる)、同じ形で直した。
  混在の調査では、同梱しない glibc の公開ヘッダ 186 本のうち rubycc だけが落ちるものが 37 本から 23 本に減った

**受け入れ条件のうち、残っているもの:**

- 差分の分類(足す / 意図して外す)が済んだのは 54 本のうち 5 本(`stdlib.h`・`sched.h`・`termios.h`・`sys/ioctl.h`・`sys/types.h`)だけ。
  `signal.h` はガードだけを直し、名前の不足(x86-64 152 / aarch64 177)は分類していない
- 共有ガードの点検は x86-64 だけ。aarch64 は [`aarch64-cross-sysroot-include`](aarch64-cross-sysroot-include.md)(BI)が直るまで測れない
- `fsid_t` は、glibc の `bits/types.h` がガード無しの構造体で定義するので足さなかった。同梱 `sys/statfs.h` の `__fsid_t` も、
  `bits/types.h` を読む glibc ヘッダと並べると衝突するはず(未測定)

見つかった別の課題は、それぞれ起票した: [`bundled-sys-types-ushort`](bundled-sys-types-ushort.md)(BN)、
[`glibc-alloca-without-gnuc`](glibc-alloca-without-gnuc.md)(BO)、[`glibc-public-headers-mixed`](glibc-public-headers-mixed.md)(BP)。

## 決着

(未着手)
