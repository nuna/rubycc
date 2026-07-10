/* Step 22(static / extern の意味論)のサンプル。
   内部リンケージ(static)の関数とファイルスコープ変数、ブロックスコープの
   static カウンタ(初期化は一度だけ・呼び出しをまたいで保持)、_Static_assert
   と _Alignof を横断的に使う小さな集計プログラム。static シンボルは ELF 上
   ローカルになり、この翻訳単位の外からは見えない。終了コード = 集計した合計。 */

int puts(char *s);

/* 内部リンケージ(static)のヘルパ関数: この TU の外からは見えない。 */
static int square(int n) { return n * n; }

/* ファイルスコープの static const テーブル(内部リンケージのグローバル)。 */
static const int weights[4] = {1, 2, 3, 4};

/* テーブルの版面を守る静的表明(sizeof と _Alignof を定数式で使う)。 */
_Static_assert(sizeof(int) * 4 == 16, "weights are four ints");
_Static_assert(_Alignof(int) == 4, "int aligns to 4");

/* ブロックスコープの static カウンタ: 初期化子は一度だけ効き、値は呼び出しを
   またいで保持される(自動変数ではなく静的記憶域)。 */
static int next_id(void) {
    static int counter = 0;
    counter = counter + 1;
    return counter;
}

int main(void) {
    int sum = 0;
    int i;

    /* 各呼び出しで 1,2,3,4 を返す static カウンタで重み付き総和を作る。 */
    for (i = 0; i < 4; i++) {
        sum = sum + next_id() * weights[i]; /* 1*1 + 2*2 + 3*3 + 4*4 = 30 */
    }

    int s = square(3); /* 9 */

    puts("static storage");
    /* _Alignof はコンパイル時定数として算術に混ざる。 */
    return sum + s + _Alignof(int) - 1; /* 30 + 9 + 4 - 1 = 42 */
}
