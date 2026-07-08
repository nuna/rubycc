/* switch のフォールスルー(case を並べる)と文字列走査。
   Step 16 で入った switch/case/default を使い、文字列中の母音を数える。
   終了コード = 母音の数。 */

int puts(char *s);

int count_vowels(char *s) {
    int n = 0;
    int i;
    for (i = 0; s[i] != 0; i++) {
        switch (s[i]) {
        case 'a': case 'e': case 'i': case 'o': case 'u':
            n++;
            break;
        default:
            break;
        }
    }
    return n;
}

int main(void) {
    char *text = "pure ruby c compiler";
    puts(text);
    puts("vowel count is the exit code");
    return count_vowels(text);
}
