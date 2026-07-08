/* Step 10(char・文字/文字列リテラル)までの機能によるサンプル: FizzBuzz。
   ループ・剰余・if/else 連鎖(Step 4-5)、関数(Step 6)、ローカル配列と
   ポインタ演算(Step 8)、char と文字列リテラル・外部関数 puts の呼び出し
   (Step 10)を使う。printf はまだ無いので 10 進化は手書きの print_int。 */

int puts(char *s);

void print_int(int n) {
    char buf[12];
    int i = 11;
    buf[i] = 0;
    if (n == 0) {
        puts("0");
        return;
    }
    while (n > 0) {
        i = i - 1;
        buf[i] = '0' + n % 10;
        n = n / 10;
    }
    puts(buf + i);
}

int main(void) {
    int i;
    for (i = 1; i <= 20; i++) {
        if (i % 15 == 0) {
            puts("FizzBuzz");
        } else if (i % 3 == 0) {
            puts("Fizz");
        } else if (i % 5 == 0) {
            puts("Buzz");
        } else {
            print_int(i);
        }
    }
    return 0;
}
