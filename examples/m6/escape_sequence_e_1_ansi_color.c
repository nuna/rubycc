/* escape-sequence-e-1: the GNU extension escape "\e"/"\E" (ESC, 0x1B).
 *
 * Not one of the eleven simple escapes in C11 6.4.4.4, but gcc 13.3 accepts
 * both spellings unconditionally (only warning under -pedantic; measured
 * 2026-09-13, issues/escape-sequence-e.md). It is the usual way to spell an
 * ANSI terminal escape ("\e[31m" etc.), and it is also what blocked the
 * corpus candidate string_undump 0.1.1, whose
 * ext/string_undump/string_undump.c:37 writes plain `return "\e";`.
 *
 * This exercises "\e" and "\E" in both a string literal and a character
 * constant (including a wide character constant, L'\e'), and confirms by
 * execution -- not merely by a successful build -- that each one is 0x1B.
 */
#include <stdio.h>

static const char *reset_sequence(void) {
    return "\e[0m";
}

int main(void) {
    const char *red = "\e[31m";
    char esc_lower = '\e';
    char esc_upper = '\E';
    int wide_esc = L'\e';

    printf("%d %d %d %d %d\n",
           (unsigned char)red[0], (unsigned char)red[1],
           (unsigned char)esc_lower, (unsigned char)esc_upper, wide_esc);
    printf("%d\n", (unsigned char)reset_sequence()[0]);
    return (unsigned char)esc_lower == 0x1B && (unsigned char)esc_upper == 0x1B ? 0 : 1;
}
