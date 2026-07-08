/* Step 16(switch/case/default・goto・ラベル文)のサンプル。
   switch のフォールスルー(case を並べる)で母音を数え、'.' に当たったら
   goto で switch とループを一度に抜けて走査を打ち切る。
   終了コード = ピリオドまでの母音の数。 */

int puts(char *s);

int count_vowels_until_period(char *s) {
    int n = 0;
    int i;
    for (i = 0; s[i] != 0; i++) {
        switch (s[i]) {
        case 'a': case 'e': case 'i': case 'o': case 'u':
            n++;
            break;
        case '.':
            goto done;
        default:
            break;
        }
    }
done:
    return n;
}

int main(void) {
    char *text = "pure ruby c compiler. this tail is not scanned";
    puts(text);
    puts("vowel count before the period is the exit code");
    return count_vowels_until_period(text);
}
