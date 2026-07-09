/* Step 21(関数ポインタ)のサンプル。
   関数ポインタのディスパッチ表・コールバック(関数を引数に取る)・関数ポインタ
   変数経由の呼び出し(& と * の両形)・7 引数のスタック渡しを横断的に使う、
   小さな整数演算プログラム。演算はグローバルな関数ポインタ表から選び、配列は
   コールバックで畳み込む。終了コード = 集計した合計。 */

int puts(char *s);

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }
int mul(int a, int b) { return a * b; }

/* コールバック: 配列の各要素に二項関数を適用して畳み込む。 */
int reduce(int *v, int n, int (*f)(int, int), int acc) {
    int i;
    for (i = 0; i < n; i++) {
        acc = f(acc, v[i]);
    }
    return acc;
}

/* 7 引数(System V AMD64 では 7 個目がスタック渡し)。 */
int weighted(int a, int b, int c, int d, int e, int f, int g) {
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7;
}

/* グローバルの関数ポインタ・ディスパッチ表(関数名で初期化)。 */
int (*table[3])(int, int) = {add, sub, mul};

int main(void) {
    int data[4] = {1, 2, 3, 4};

    /* ディスパッチ表経由で選んだ演算を呼ぶ。 */
    int product = table[2](6, 7); /* mul(6, 7) = 42 */

    /* コールバックで総和を計算(add を関数ポインタとして渡す)。 */
    int total = reduce(data, 4, add, 0); /* 1+2+3+4 = 10 */

    /* 関数ポインタ変数を経由した呼び出し("&f" と "(*fp)(...)")。 */
    int (*fp)(int, int) = &sub;
    int diff = (*fp)(total, 4); /* sub(10, 4) = 6 */

    /* 7 引数のスタック渡し。 */
    int w = weighted(1, 1, 1, 1, 1, 1, 1); /* 1+2+3+4+5+6+7 = 28 */

    puts("function pointers dispatched");
    return product + total + diff + w - 44; /* 42+10+6+28-44 = 42 */
}
