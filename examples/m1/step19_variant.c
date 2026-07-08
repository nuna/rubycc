/* Step 19(union・無名 struct/union メンバ)のサンプル。
   タグ付きの値(variant)を、共通ヘッダ(kind)+ 無名 union のバリアントで
   表す(ruby.h の RBasic 風)。union は全メンバが同じ場所に重なるので、
   int で書いた値を char で読み直すとリトルエンディアンの下位バイトが見える
   (型パンニング)。終了コード = 集計した合計。 */

int puts(char *s);

/* kind == INT なら n を、kind == PAIR なら無名 struct の a/b を使う。
   無名 union と無名 struct のメンバは cell から直接アクセスできる。 */
struct cell {
    int kind;
    union {
        int n;
        struct {
            char a;
            char b;
        };
    };
};

int main(void) {
    struct cell c;

    /* INT バリアント: n に書いて、同じ領域を char で読む。
       0x00000029 の下位バイトは 0x29 = 41。 */
    c.kind = 0;
    c.n = 0x29;
    int low = c.a; /* 無名 union 経由で無名 struct の a に透過アクセス */

    /* PAIR バリアント: a と b を別々に書く(同じ領域を上書き)。 */
    c.kind = 1;
    c.a = 10;
    c.b = 20;
    int sum = c.a + c.b; /* 30 */

    /* union のサイズは最大メンバ(int, 4 バイト)ぶん。 */
    int width = sizeof(struct cell); /* kind(4) + union(4) = 8 */

    puts("packed an int and a char pair into one union cell");
    return low + sum - width + 27; /* 41 + 30 - 8 + 27 = 90 */
}
