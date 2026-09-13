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

## 決着

(未着手)
