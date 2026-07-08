/* Step 17(整数型の拡張: long/short/unsigned/_Bool、16進・8進リテラル、
   接尾辞)のサンプル。unsigned char の配列から unsigned long のチェックサムを
   計算し(16進・8進・接尾辞つきリテラルで初期化)、short と unsigned short の
   再解釈、long の桁あふれと _Bool への正規化を確かめる。
   終了コード = チェックサムの下位 8 ビット。 */

int puts(char *s);

unsigned long checksum(unsigned char *data, int n) {
    unsigned long sum = 0;
    int i;
    for (i = 0; i < n; i++) {
        sum = sum * 0x101 + data[i];
    }
    return sum;
}

_Bool is_negative(long x) {
    return x < 0;
}

int main(void) {
    unsigned char bytes[4];
    bytes[0] = 0x10;
    bytes[1] = 010;
    bytes[2] = 200u;
    bytes[3] = 7;

    unsigned long h = checksum(bytes, 4);
    puts("checksum computed over four unsigned char bytes");

    short s = -1;
    unsigned short us = (unsigned short)s;
    puts(us == 65535 ? "signed short reinterprets as 65535 unsigned" : "mismatch");

    long big = 4294967296L;
    _Bool overflowed = is_negative(-big);
    puts(overflowed ? "negative long detected" : "mismatch");

    return (int)(h & 255);
}
