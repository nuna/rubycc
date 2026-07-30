# rubycc — Almost Pure Ruby C ツールチェイン 要件・設計書

## 1. 背景と目的

Ruby の C 拡張ライブラリ(native extension)のビルドには GCC / Clang 等の C コンパイラと
binutils(as / ld / ar)、make、libc 開発ヘッダが必要である。distroless やミニマムな
コンテナイメージではこれらを導入するとイメージサイズ・攻撃面・ビルド依存が増大する。

本プロジェクト(仮称 **rubycc**)は、**Ruby 標準添付ライブラリのみに依存する Almost Pure Ruby の
C ツールチェイン**を gem として提供し、Ruby さえあれば C 拡張 gem をインストールできる
状態を実現する。

## 2. 与えられた要件(前提)

- R1. gem としてインストールできる
- R2. Almost Pure Ruby で書かれており、Ruby 標準添付ライブラリ以外に依存しない
- R3. Ruby の C 拡張ライブラリの「ほとんど」を本ツールチェインでビルドできる
- R4. C 拡張ライブラリ側は本ツールチェイン向けの修正を必要とせず、**無修正のまま**
  ビルドできる互換性をツールチェインが持つこと。互換性確保の負担はすべて
  ツールチェイン側が負う。
  - 「修正」とみなすもの: ソースコード・extconf.rb・gemspec の変更、インストール時の
    パッチ適用、gem 側への rubycc 対応コード(`#ifdef __RUBYCC__` 等)の追加要求。
  - 「修正」とみなさないもの: ツールチェイン自体の有効化設定(環境変数等)、
    gem が公式に提供するインストールオプションの選択
    (例: nokogiri の `--use-system-libraries`)。
- R11. 既存の OSS(chibicc、tcc、8cc、lacc 等の既存 C コンパイラ実装を含む)に
  類似した実装にしないこと。類似とみなす対象はファイル構成、クラス・メソッド・関数の
  インターフェイス、関数内のロジック、教材(compilerbook 等)特有の命名・構成。
  高次の設計方針(多段パイプライン、再帰下降構文解析、spill-everything コーデジェン等の
  一般的なアーキテクチャパターン)の共通は問題としない。
  - 文法の非終端記号の命名は特定実装の慣習ではなく ISO C 標準の文法用語に従う。
  - レビュー時の確認観点に含める。

## 3. 不足していた要件の洗い出し

### 3.1 機能要件(追加)

- **R5. コンパイラ単体では不十分 — ツールチェイン全体が必要**
  ミニマム環境には as / ld / ar / make / sh も存在しない。したがって以下すべてを
  Almost Pure Ruby で提供する必要がある。
  - C プリプロセッサ(ruby.h はマクロを多用する)
  - C コンパイラ本体(機械語を直接生成。外部アセンブラに依存しない)
  - ELF オブジェクトファイル(.o)ライタ
  - リンカ(共有ライブラリ .so と、conftest 用の実行ファイルの両方を出力)
  - アーカイバ(ar 互換。vendored ライブラリの静的リンクで必要)
  - **make 互換ツール(rmake)**: mkmf が生成する Makefile を処理できるサブセット。
    ミニマム環境には /bin/sh が無いため、mkmf が生成する典型的レシピ
    (単純コマンド、`&&`、リダイレクト程度)をシェル無しで実行できること。

- **R6. mkmf / RubyGems / Bundler との統合**
  - `gem install` / `bundle install` の標準フローで透過的に使えること。
    RubyGems は `ENV["MAKE"]` / `ENV["make"]` を尊重するため、rubygems_plugin で
    rmake を差し込み、rmake が CC/LD/AR を本ツールチェインに差し替える。
  - extconf.rb の conftest(`have_header` / `have_func` / `try_link` / `try_run`)が
    動作すること。→ 実行ファイル出力と最小限の内蔵 crt(_start)が必要。
  - GCC 互換の CLI(`-c -o -I -D -U -O2 -fPIC -shared -l -L -Wl,...`)を受理し、
    RbConfig 由来の未知の GCC 固有フラグ(-fno-fast-math 等)は警告のみで無視すること。
  - mkmf の `pkg_config` 対応: 純 Ruby の .pc パーサを実装し、`ENV["PKG_CONFIG"]` に
    シムを設定して差し込む。

- **R7. C 言語仕様のサポート範囲の明確化**
  - ベース: **C11(VLA・アトミクスはオプション扱い)+ 実用上必須の拡張**。
  - `__GNUC__` は**定義しない**(独自マクロ `__RUBYCC__` を定義)。ruby.h や多くの
    gem のヘッダは `#ifdef __GNUC__` の #else 側にポータブルなフォールバックを持つため、
    実装すべき GNU 拡張の表面積が大幅に減る。
  - それでも必要な最小限の拡張:
    - `__attribute__((...))` の構文受理(aligned / packed のみ意味を実装、他は無視)
    - `__builtin_expect`, `__builtin_alloca`, `__builtin_va_*`, 主要な `__builtin_*`
    - `__has_attribute` / `__has_builtin` / `__has_include`(プリプロセッサ)
    - 空テンプレートのインラインアセンブリ(`__asm__ volatile("" ::: "memory")` を
      コンパイラバリアとして受理)。**実体のあるインラインasmは非対応**。
    - `__atomic_*` / `__sync_*` ビルトインの主要セット(シングル命令 or lock 前置で実装)

- **R8. libc 互換ヘッダの同梱**
  ミニマム環境には stdio.h 等の libc 開発ヘッダが無い。tcc と同様に、ターゲット libc
  (glibc / musl)の ABI に一致する独自のホスト環境ヘッダ一式を gem に同梱する。
  型幅(off_t, time_t 等)・構造体レイアウトはターゲット別に切り替える。
  ライセンス上クリーンルームで書くか、MIT の musl から派生させる(要ライセンス表記)。

- **R9. ABI 完全互換**
  生成コードは System V AMD64 ABI / AArch64 AAPCS64 に厳密準拠すること。
  構造体の値渡し・返し、可変長引数(`rb_funcall` は variadic)、アラインメント、
  ビットフィールドを含む。ここのバグは即クラッシュに直結するため最重要要件とする。

- **R10. 「ほとんど」の定量化**
  - 対象コーパス: rubygems.org ダウンロード上位の C 拡張 gem のうち、
    「C++ 不使用・実体 asm 不使用・configure スクリプト非依存」のもの。
  - 目標: コーパスの **90% 以上が gem install 成功かつ各 gem 自身のテストスイートに合格**。
  - 例(想定内): json, msgpack, bigdecimal, date, racc, redcarpet, puma, pg, mysql2,
    sqlite3(システムライブラリ利用時), openssl, psych(同), stringio 等。
  - 例(想定外→ 3.3 参照): grpc(C++), ffi(libffi の .S), nokogiri の vendored ビルド
    (mini_portile が autoconf configure を実行 → シェル必須)。

### 3.2 非機能要件(追加)

- **N1. コンパイル速度**: YJIT 有効時に目安 20,000 行/秒以上(前処理後)。
  典型的な gem(数千〜数万行)を数十秒以内でビルドできること。
  巨大な単一 TU(sqlite3 amalgamation ≒ 25 万行)は「動くが遅い」を許容し上限を設けない。
- **N2. 生成コード品質**: 最適化なし(-O0 相当)を初期目標とする。gcc -O2 比で
  実行速度 2〜5 倍遅を許容。ただし同機能の Pure Ruby 実装よりは十分速いことを確認する。
- **N3. 診断品質**: エラーメッセージにファイル名・行・桁・ソース抜粋を含む。
  ビルド失敗時に原因を特定できることは採用可否を左右する。
- **N4. 決定的ビルド**: 同一入力から同一バイナリを生成する(タイムスタンプ等を埋めない)。
- **N5. サポート Ruby**: Ruby 3.3 以上(YJIT 安定版)。**変更(Step 131)**: 当初は
  3.2 以上としていたが、2026 年 7 月時点で Ruby 3.2 は EOL 済み(2022-12 リリース、
  通常のメンテナンス期限 2026-03 を経過)であるため 3.3 に引き上げた。N5 の根拠である
  「YJIT 安定版」は 3.3 以降の方がよりよく満たす。
- **N6. メモリ**: 1 TU あたり 1GB 以内を目安とする。
- **N7. テスト容易性**: 各コンポーネント(CPP/フロントエンド/コーデジェン/リンカ)を
  独立にテスト可能なこと。開発時は gcc との差分テスト(実行結果比較)を行う
  (gcc は開発時 CI のみの依存であり、実行時依存にはしない — R2 と矛盾しない)。

### 3.3 スコープ外(明示)

- C++(grpc, rice 系 gem は対象外)
- 実体のあるインラインアセンブリ / .S ファイル(ffi の vendored libffi は対象外)
- autoconf configure を実行する vendored ビルド(mini_portile 系)。
  → これらの gem はシステムライブラリ利用モード(`--use-system-libraries`)なら対象内。
- 最適化(v1 では -O は受理して無視)
- DWARF デバッグ情報(将来課題。行番号テーブルのみ検討)
- long double の x87 80bit 精度(double として扱い、既知の制限として文書化)
- スレッドローカル(`__thread` / `_Thread_local`)は初期バージョンでは未対応
- クロスコンパイル(v1 はホスト=ターゲット)

## 4. ターゲット環境の選定

### 4.1 候補と評価

| 候補 | メリット | デメリット | 判定 |
|---|---|---|---|
| **Linux x86_64 / glibc** | 公式 ruby Docker イメージ(slim 含む)の主流。需要最大 | glibc ヘッダは同梱できない(LGPL・複雑)→ 互換ヘッダ自作が必要 | **第一ターゲット** |
| **Linux aarch64 / glibc** | ARM サーバ・Apple Silicon 上の Linux コンテナで需要増 | バックエンド追加コスト(中程度。AAPCS64 は SysV より素直) | **第一ターゲット(x86_64 の直後)** |
| **Linux / musl (Alpine)** | ミニマムコンテナの代表格で本プロジェクトの動機と合致。musl は ABI が単純でヘッダ互換層を作りやすい | glibc とヘッダ/型幅の差異を吸収する分岐が必要 | **第一ターゲット** |
| macOS (Mach-O) | 開発者の手元環境。`-undefined dynamic_lookup` の bundle 形式 | Mach-O ライタ/リンカを別途実装。コンテナ用途という動機から外れる | 第二段階 |
| Windows (PE/COFF) | — | MSVC ABI・PE・mingw の複雑さ。コンテナ用途でほぼ需要なし | 対象外(v1) |

**結論**: v1 は Linux(x86_64 → aarch64)、glibc と musl の両対応。
リトルエンディアン・LP64 のみを仮定してよい。

### 4.2 前提とする環境条件

- Ruby 本体のヘッダ(`ruby.h` 一式)と `rbconfig` が存在すること
  (公式 ruby イメージは充足。distro の ruby はdev パッケージ相当が必要 — README に明記)。
- リンク対象のシステム共有ライブラリ(libc.so, libz.so 等)の**バイナリ**は存在すること
  (リンカは .so の .dynsym を読んでシンボル解決し DT_NEEDED を張るだけなので、
  開発ヘッダは不要 — ヘッダは R8 の同梱分で賄う)。
- Linux では拡張ライブラリは rb_* を未解決シンボルのまま .so 化し dlopen 時に解決される
  ため、libruby の静的ライブラリは不要。ただし conftest の `try_link` は実行ファイルを
  リンクするため、--enable-shared でビルドされた Ruby(公式イメージは該当)を推奨環境とする。

## 5. ツールチェイン構成の選定

### 5.1 アーキテクチャ候補

| 案 | 構成 | メリット | デメリット | 判定 |
|---|---|---|---|---|
| **A. 完全統合型(tcc モデル)** | CPP→コンパイル→機械語直接生成→内蔵リンカで .so まで一気通貫 | 外部依存ゼロ(要件充足)。テキスト asm を経由しないため速い | 実装量が最大(特にリンカ)。ELF 動的リンクの知識が必要 | **採用** |
| B. asm 出力 + 外部 as/ld | コンパイラのみ実装 | 実装量最小 | binutils 依存が残り目的を達成できない | 却下 |
| C. .o 出力 + 外部 ld | アセンブラ不要化のみ | 同上 | ld 依存が残る | 却下 |
| D. C→WASM + ランタイム | バックエンド簡略化 | wasm ランタイム依存・C API 境界・性能で破綻 | 却下 |
| E. C→Ruby トランスパイル | 依存ゼロ | ポインタ/ABI 意味論が再現不能、性能絶望的 | 却下 |

### 5.2 コンパイラ内部構成

| 案 | メリット | デメリット | 判定 |
|---|---|---|---|
| 単一パス直接生成(tcc 流) | 最速・省メモリ | テスト困難・拡張困難・コード品質最低 | 却下 |
| **AST→単純IR→スタック型コーデジェン(chibicc 流の多段)** | 各段が独立にテスト可能。後から最適化パスを差し込める。実装難度が現実的 | tcc 流よりやや遅い | **採用** |
| SSA 最適化(QBE/LLVM 流) | コード品質最良 | Ruby 上では実装コスト・コンパイル時間とも過大 | 却下(IR は将来 SSA 化できる設計に留める) |

### 5.3 コンポーネント一覧

```
rubycc(gem)
├── exe/rubycc        # gcc 互換ドライバ(cc として振る舞う)
├── exe/rmake         # mkmf Makefile 用 make サブセット(内蔵コマンド実行器つき)
├── exe/rubycc-ar     # ar 互換
├── exe/rubycc-pkgconf# pkg-config シム(純Ruby .pc パーサ)
├── lib/rubycc/
│   ├── preprocessor/ # C11 CPP + __has_* 拡張
│   ├── front/        # 字句解析・再帰下降パーサ・型検査(AST)
│   ├── ir/           # 三番地コード風の単純 IR、定数畳み込みのみ
│   ├── backend/
│   │   ├── x86_64/   # SysV ABI、機械語直接エンコード
│   │   └── aarch64/  # AAPCS64
│   ├── objfile/      # ELF64 リロケータブル .o ライタ/リーダ
│   ├── linker/       # .so / 実行ファイル出力。.dynsym/.gnu.hash+.hash/PLT/GOT/
│   │                 # RELA/DT_NEEDED、-l は対象 .so の .dynsym を読んで解決
│   ├── crt/          # conftest 実行ファイル用の最小 _start(Ruby 内で合成)
│   ├── headers/      # 同梱 libc 互換ヘッダ(glibc/musl × arch で切替)
│   └── rubygems_plugin.rb  # ENV["MAKE"]=rmake, ENV["PKG_CONFIG"]=シム を注入
```

### 5.4 統合フロー(gem install 時)

1. rubygems_plugin が起動時に環境を判定:
   `RUBYCC=1` で強制有効 / `cc` と `make` が PATH に無ければ自動有効(`RUBYCC=0` で無効)。
2. 有効時、`ENV["MAKE"] = "rmake"`・`ENV["PKG_CONFIG"]` を設定。
3. extconf.rb → mkmf は通常どおり Makefile を生成(conftest のコンパイル・リンク・実行は
   rubycc が処理)。
4. RubyGems が rmake を起動。rmake は Makefile を解釈し、レシピ中の `$(CC)` 等を
   rubycc 内部呼び出しに置換して実行(プロセス起動すら不要な in-process 実行で高速化)。

## 6. その他の技術選定

- **実装言語仕様**: Ruby 3.3+(N5、Step 131)、標準添付ライブラリのみ(`stringio`, `strscan`, `etc`,
  `rbconfig`, `fileutils` 等)。ネイティブ拡張 gem には当然依存しない。
- **バイナリ生成**: `String#unpack`/`Array#pack` と `IO#binwrite`。ELF 構造体は
  pack テンプレートを持つ純 Ruby クラスで表現。
- **C の整数演算**: Ruby Integer は多倍長なので、各演算後にビット幅でマスクして
  ラップアラウンド意味論を再現。符号は 2 の補数解釈ヘルパで統一。
- **浮動小数点**: double は Ruby Float と IEEE754 で一致。float(32bit)演算は
  `[x].pack('f').unpack1('f')` で丸めて再現。
- **可変長引数**: SysV の va_list(reg_save_area 方式)/AAPCS64 の va_list を
  呼び出し側・定義側とも完全実装(rb_funcall / rb_raise が variadic のため必須)。
- **並列化**: TU 単位で `Process.fork`(Linux 前提なので使用可)により並列コンパイル。
  rmake の -j 相当を実装。
- **VLA**: alloca への脱糖で対応(スコープ寿命の差異は既知の制限として文書化)。
- **テスト戦略**:
  1. ユニット: 各段の golden テスト。
  2. 実行テスト: 小さな C プログラムを自前ツールチェインでビルドして実行結果を検証。
     開発 CI では gcc ビルドとの差分比較、c-testsuite / gcc torture の流用。
  3. ABI テスト: gcc でビルドした呼び出し側と rubycc でビルドした被呼び出し側を
     相互リンクするファジングハーネス(構造体レイアウト・varargs の網羅)。
  4. コーパス CI: 対象 gem 群を実際に `gem install` してテストスイートを実行する
     Docker マトリクス(glibc/musl × x86_64/aarch64)。
- **配布**: gem 名 `rubycc`。同梱ヘッダのライセンス表記を LICENSE/NOTICE に明記。

## 7. リスクと未解決課題

| リスク | 影響 | 緩和策 |
|---|---|---|
| ABI 不一致バグ | 拡張ロード時に SEGV(診断困難) | ABI ファジング(6. テスト 3)を最優先で整備 |
| コンパイル速度不足 | 巨大 TU で数分〜数十分 | YJIT 前提、字句解析の strscan 化、TU 並列。v1 では許容と明記 |
| libc 互換ヘッダの網羅性 | マイナーヘッダ不足でビルド失敗 | コーパス CI で不足を検出し漸進追加。`#include_next` で実ヘッダ併用も可能に |
| `__GNUC__` 非定義で fallback パスが無い gem | 個別 gem のビルド失敗 | 頻出パターン(可視性属性等)は `__RUBYCC__` 向けにヘッダで吸収。GCC 擬態モードを将来オプションで検討 |
| 静的リンクのみの Ruby(--disable-shared) | conftest の try_link 失敗 | 既知の制限として文書化。mkmf の DLDFLAGS で回避可能なケースを調査 |
| /bin/sh 前提の extconf.rb(`xsystem` で sh 構文使用) | 一部 gem 失敗 | rmake の内蔵実行器で頻出構文をカバー。残りはスコープ外と明記 |

## 8. マイルストーン

1. **M1**: プリプロセッサ + C11 サブセットコンパイラ + x86_64 ELF .o 出力。自己テスト合格。
2. **M2**: リンカ(.so / 実行ファイル)+ ar。json / msgpack 級の gem を手動ビルドし
   テスト合格。
3. **M3**: rmake + rubygems_plugin + pkg-config シム + conftest 完全対応。
   `gem install json msgpack sqlite3 pg` が distroless 相当のイメージで成功。
4. **M4**: aarch64 バックエンド。
5. **M5**: glibc/musl 互換ヘッダの拡充、コーパス 90% 達成、v1.0 リリース。
6. **M6(以降)**: macOS(Mach-O)、基本最適化(レジスタ割付・簡単な CSE)、行番号
   デバッグ情報、GCC 擬態モード。

## 9. 参考資料

本書および docs/ROADMAP.md の計画立案にあたって参照した資料。なお計画は
これらの資料の内容に関する一般知識に基づいて立案したものであり、実装・
レビューで仕様の詳細が問題になった箇所では必ず原典を確認すること。

### 9.1 一次資料(規格・仕様 — 実装の根拠とするもの)

| 資料 | 用途 |
|---|---|
| ISO/IEC 9899(C11/C17)。参照版は **ISO/IEC 9899:201x Committee Draft N1570**(C11 最終ワーキングドラフト、無償公開): https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf | 文法の非終端記号の命名(R11)、意味論の根拠(ヌルポインタ定数 6.3.2.3、構造体タグのスコープ 6.7.2.3、翻訳フェーズ 5.1.1.2 等)。**コード・ドキュメント中の条番号引用はすべて N1570 の章立てに従う** |
| System V AMD64 psABI | 呼び出し規約、引数分類アルゴリズム(MEMORY/INTEGER/SSE)、構造体レイアウト、va_list、リロケーション種別(R_X86_64_*) |
| System V gABI(ELF 仕様) | ELF64 のファイル構造・セクション・シンボルテーブル・リロケーション。M2 リンカは「仕様だけを一次資料にする」(ROADMAP §5) |
| Intel SDM / AMD APM | x86-64 命令エンコーディング(REX プレフィクス、ModRM/SIB、各オペコード) |
| Arm AAPCS64 / Arm ARM(A64)/ AArch64 ELF psABI | M4 計画(呼び出し規約の差分、ADRP+ADD のリロケーションペア、BL+R_AARCH64_CALL26) |
| Ruby 公式ドキュメント(Fiddle、mkmf、RubyGems プラグイン仕様) | M2 の .so 受け入れテスト(Fiddle#dlopen)、M3 の mkmf/conftest 互換・rubygems_plugin 統合 |
| GNU binutils ドキュメント | `ld -r` によるリロケータブルマージの意味論(M2 中間検証)、readelf/objdump による生成物検証 |

### 9.2 アーキテクチャ選定時の比較参照(コードは参照しない)

5.1〜5.2 の候補比較で、既存実装の**アーキテクチャ分類・開発方法論のレベルでのみ**
名前を参照した。R11 により、これらのソースコード・章立て・ファイル構成・
インターフェイス・関数内ロジック・命名は一切参照していないし、今後も参照しない。

- **tcc** — 「完全統合型(CPP→コンパイル→機械語直接生成→内蔵リンカ)」という
  アーキテクチャモデルの実在例として(5.1 候補 A)。
- **chibicc** — 「多段パイプライン(各段が独立にテスト可能)」という内部構成
  モデルの分類名として(5.2)。
- **compilerbook(低レイヤを知りたい人のための C コンパイラ作成入門)** —
  「常に動くコンパイラを保ち、小さいステップで拡張し続ける」というインクリ
  メンタル開発方法論の出典として(ROADMAP のステップ分解の進め方)。
