/* Step 15 のビット演算・シフトと、Step 16 の goto による多重ループ脱出。
   popcount(立っているビット数)と、i*i + j*j == 25 の最初の (i, j) 探索。
   終了コード = popcount(202) * 10 + i  (202 = 11001010b → 4 ビット、i=3, j=4
   → 43)。 */

int puts(char *s);

int popcount(int x) {
    int n = 0;
    while (x != 0) {
        n += x & 1;
        x >>= 1;
    }
    return n;
}

int main(void) {
    int i;
    int j;
    for (i = 1; i < 10; i++) {
        for (j = 1; j < 10; j++) {
            if (i * i + j * j == 25) {
                goto found;
            }
        }
    }
    puts("not found");
    return 1;
found:
    puts("found a pythagorean pair");
    return popcount(202) * 10 + i;
}
