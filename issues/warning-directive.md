---
status: in-progress
kind: gap
opened: 2026-08-19
closed:
branch: warning-directive
pr:
steps: [warning-directive-1]
---

# `#warning` を受理する — そのために警告チャネルを 1 つ作る

## 課題

rubycc は `#warning` を**エラーとして拒否**する。gcc は受理して警告を出し、
コンパイルは成功する。実測(2026-08-19、gcc 13.3.0):

```c
#warning "unrecognized compiler"
int main(void){return 0;}
```

| | 出力 | 終了 |
|---|---|---|
| gcc | `warning: #warning "unrecognized compiler" [-Wcpp]` | **成功** |
| rubycc | `error: invalid preprocessing directive '#warning'` | **失敗** |

`#warning` は長く GNU 拡張として使われ、**C23 で標準になった**。実ヘッダでは
「未知のコンパイラ/CPU です」と告げる分岐に置かれることが多く、
[corpus-candidate-pilot-v2-roaring](corpus-candidate-pilot-v2-roaring.md) の
`roaring.h` がまさにその形(`#warning "Warning. Unrecognized compiler."`)で、
**そこで rubycc のビルドが止まる**。

## 影響

**告知のための行が、ビルドを殺している。** gcc なら警告 1 行で通るコードが通らない。
コーパス候補 roaring がここで落ちており、同じ形は他の移植性ヘッダにも広く現れる。

**ただし単純な修正ではない。** `lib/rubycc/front/parser.rb` が明記しているとおり、
**警告はこのコンパイラが持たないチャネル**である。診断はエラーしかなく、
「出すが失敗しない」経路が存在しない。`#warning` を受理するとは、
**その最初の 1 本を作る**ということである。

## 受け入れ条件

- `#warning` を含む翻訳単位が**コンパイルに成功する**(終了コード 0、オブジェクトが出る)
- メッセージが**標準エラー**に出る(標準出力を汚さない — 差分テストは stdout を比較する)
- 位置(ファイル・行・列)が診断に含まれ、既存のエラー診断と同じ書式である
- **`#error` の挙動は変わらない**(引き続きコンパイルを止める)
- 引用符の有無に関わらずメッセージ本体をそのまま出す(gcc は `#warning foo bar` も受理する)
- 最小の preprocessor fixture と回帰テストを持つ。**gem のアーカイブを fixture にしない**
- **`-w` / `-Werror` を honor するかを決めて文書化する**。現状ドライバはこれらを
  「受理して無視」しており、警告チャネルが無かったので無害だった

## 作業ログ

### 2026-08-19(起票)

`corpus-candidate-pilot-v2-roaring` の第 1 段(再現と host 比較)で判明した。
issue の指示どおり、**gem のアーカイブを直接 fixture にせず**、コンパイラ側の
課題として分離した。

### 2026-08-19(実装 — warning-directive-1)

`lib/rubycc/diagnostics.rb` に警告チャネル(`Rubycc::Diagnostics`)を作り、
書式は `CompileError` と共有した。`#warning` は `#error` の隣に置き、
メッセージの組み立ても `directive_message` で共有した。
`-w` は honor、`-Werror` は honor しない(理由はドライバのコメントと STEPS.md)。

受け入れ条件の対応:

| 条件 | 対応 |
|---|---|
| 終了コード 0 でオブジェクトが出る | `test_driver.rb#test_warning_directive_compiles_and_reports_on_stderr` |
| 標準エラーに出て標準出力を汚さない | 同上 + `test_warning_during_dash_e_keeps_stdout_clean` |
| 位置が入り、エラーと同じ書式 | `test_diagnostics.rb#test_a_warning_is_spelled_like_an_error_apart_from_the_severity` |
| `#error` の挙動は不変 | `test_driver.rb#test_error_directive_still_fails_the_build` ほか |
| 引用符の有無を問わない | `test_preprocessor.rb` の quoted / unquoted 2 本 |
| 最小 fixture(gem アーカイブを使わない) | すべて数行のソース文字列と一時ディレクトリの `.c` |
| `-w` / `-Werror` の扱いを決めて文書化 | ドライバの `#silently_ignored?` 上のコメント、STEPS.md |

### 2026-08-19(クロスレビュー反映)

別系統のモデルによる事前レビューで 2 件の指摘を受けた。

**採用**: 診断ストリームがプロセス共有の可変状態だった点。**今日壊れる経路は無い**
(テストは逐次、rmake の並列ワーカーは fork した子の中で Driver を 1 つだけ動かす)が、
将来の罠なので**スレッドローカルに移した**。

その過程で自分でバグを 1 つ作って直した — **スレッドローカルは「nil を格納」と
「未設定」を区別できず**、`-w` の破棄が効かなくなっていた(警告が出てしまう)。
番兵オブジェクトで区別する形にし、破棄・継承・復元の 3 経路を確認した。

**採らない**: 差分テストで警告を捨てている点(「意図しない警告の回帰を検出できない」)。
現状 `#warning` が唯一の警告源で、使うサンプルは 1 本、その挙動は最小 fixture の
テスト 15 本がバイト単位で押さえている。**差分テストは終了コードと stdout を比べる
道具**であり、stderr の回帰をそこに担わせるのは筋が違う。警告の種類が増えたら再考する。

なお指摘に併記されていた「N4 の決定性にも反する」は採らない。警告は標準エラーに
出るだけで、生成されるバイトには影響しない。

## 決着

設計判断の本体は `docs/development/STEPS.md` の **warning-directive-1**。
要点は「難しかったのはディレクティブではなくチャネル」「書式は 1 か所」
「ストリームはプロセス全体の状態(fork 隔離なので安全)」「`-w` は honor、
`-Werror` は honor しない」。
