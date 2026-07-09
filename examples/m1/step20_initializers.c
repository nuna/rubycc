/* Step 20(初期化子・6.7.9)のサンプル。
   ローカル/グローバルの配列・struct・char 配列を、ブレース初期化子で埋める。
   位置指定・指示付き(designator)・ネスト・ブレース省略(elision)・"{0}"
   イディオム・"[]" の長さ推論・文字列リテラルによる char 配列/ポインタ初期化を
   横断的に使う。未指定の要素はゼロになる。終了コード = 集計した合計。 */

int puts(char *s);

struct point {
    int x;
    int y;
};

/* グローバル配列(位置指定)・グローバル struct・グローバル文字列ポインタ。 */
int weights[4] = {1, 2, 3, 4};
struct point origin = {.y = 5, .x = 5};
char *label = "initialized";

int main(void) {
    /* "[]" の長さ推論(位置指定の要素数から 3)+ 部分初期化のゼロ埋め。 */
    int primes[] = {2, 3, 5};
    int slots[4] = {7, 8}; /* slots[2], slots[3] は 0 */

    /* struct 配列へのブレース省略(平坦なリストが要素を順に埋める)。 */
    struct point path[2] = {1, 2, 3, 4};

    /* ネストしたブレース + 指示付きメンバ。 */
    struct point corner = {.x = 6, .y = 4};

    /* char 配列を文字列リテラルで初期化(NUL と余りはゼロ)。 */
    char tag[8] = "ok";

    /* "{0}" で配列全体をゼロにする。 */
    int cleared[3] = {0};

    int sum = 0;
    int i;
    for (i = 0; i < 4; i++) {
        sum = sum + weights[i]; /* 1+2+3+4 = 10 */
    }
    sum = sum + primes[0] + primes[1] + primes[2];      /* + 10 = 20 */
    sum = sum + slots[0] + slots[1] + slots[2] + slots[3]; /* + 15 = 35 */
    sum = sum + path[0].x + path[0].y + path[1].x + path[1].y; /* + 10 = 45 */
    sum = sum + origin.x + origin.y;   /* + 10 = 55 */
    sum = sum + corner.x + corner.y;   /* + 10 = 65 */
    sum = sum + cleared[0] + cleared[1] + cleared[2]; /* + 0 = 65 */
    sum = sum + tag[0] + tag[1] + tag[2]; /* 'o'(111)+'k'(107)+0 = 218; 65+218=283 */
    sum = sum - label[0] - 100;        /* label[0]='i'(105); 283-105-100 = 78 */

    puts(label);
    return sum; /* 78 */
}
