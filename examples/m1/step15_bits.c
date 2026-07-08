/* Step 15(ビット演算子・シフト・複合代入)のサンプル。
   popcount(立っているビット数)とマスク・シフトによるビットフィールド抽出。
   202 = 11001010b なので popcount は 4、(202 >> 3) & 7 は 11001b の下位 3 ビットで 1。
   終了コード = 4 * 10 + 1 = 41。 */

int puts(char *s);

int popcount(int x) {
    int n = 0;
    while (x != 0) {
        n += x & 1;
        x >>= 1;
    }
    return n;
}

int extract_field(int value, int shift, int mask) {
    return (value >> shift) & mask;
}

int main(void) {
    int reg = 202;
    puts("popcount * 10 + field is the exit code");
    return popcount(reg) * 10 + extract_field(reg, 3, 7);
}
