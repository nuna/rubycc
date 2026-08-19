/* default-external-encoding-1: non-ASCII bytes in a source file.
 *
 * C reads a source file as a sequence of bytes (5.1.1.2), and so does rubycc:
 * the scanner works on bytes rather than on text in whatever encoding the
 * process's locale happens to name. Everything the language spells -- keywords,
 * punctuators, identifiers -- is in the basic character set, so the only thing
 * a byte past 0x7F can be is payload: a character in a comment, which is
 * skipped, or an element of a string literal, which is carried through
 * untouched.
 *
 * Reading the file as *text* instead made the compiler depend on the locale,
 * and this sample is what that cost. Under a locale of "C" (LANG unset -- cron,
 * systemd units, and the container images that ship no locale at all) the
 * source came back as US-ASCII, so the first byte past 0x7F anywhere in the
 * translation unit raised a Ruby exception rather than a diagnostic; the
 * bundled <stddef.h> has three of them, in a comment, which is why "#include
 * <stddef.h>" alone could not be compiled. A UTF-8 string literal was worse: it
 * failed under *every* locale, because a multibyte character was being asked
 * for its code point where a byte was wanted.
 *
 * So the sample's job is to hold bytes that no C construct is spelled with, and
 * to print them. test_examples.rb compares [exit status, stdout] against gcc,
 * which makes "the bytes come out as they went in" a checked property rather
 * than a claim -- and it holds with or without a locale, because the compiler
 * no longer consults one.
 *
 * Covered here: a UTF-8 block comment and a UTF-8 line comment; a UTF-8 string
 * literal printed verbatim; the same literal spelled with hexadecimal escapes,
 * compared byte by byte with the direct spelling; sizeof over such a literal
 * (one element per byte, not per character); indexing the individual bytes; and
 * the concatenation of two adjacent UTF-8 literals (translation phase 6).
 *
 * Identifiers stay ASCII on purpose: identifiers outside the basic character
 * set are a different question (C11 6.4.2.1 universal character names), and not
 * this step's.
 */
#include <stddef.h>
#include <stdio.h>

/* 日本語のコメント。ここに書いた文字は翻訳フェーズ 3 で空白に置き換わるので、
 * 何が書いてあってもコンパイル結果には現れない — em dash も、ハイフンも同じ。 */

/* The same three characters, spelled two ways: directly, and byte by byte with
 * hexadecimal escapes. They must be the same string. */
static const char direct[] = "あいう";
static const char escaped[] = "\xE3\x81\x82\xE3\x81\x84\xE3\x81\x86";

/* Adjacent string literals are concatenated in translation phase 6, before
 * anything looks at what the bytes mean. */
static const char joined[] = "cafe" "\xCC\x81";

static int same_bytes(const char *a, const char *b, size_t length)
{
    size_t i;

    for (i = 0; i < length; i++) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

int main(void)
{
    size_t i;

    /* ひらがなの行コメント。改行までが読み飛ばされる。 */
    printf("%s\n", direct);
    printf("%s\n", joined);

    /* sizeof counts elements, and an element is a byte: three characters of
     * three bytes each, plus the terminating null. */
    printf("sizeof direct = %d\n", (int)sizeof(direct));
    printf("same = %d\n", same_bytes(direct, escaped, sizeof(direct)));

    for (i = 0; i < sizeof(direct) - 1; i++) {
        printf("byte %d = %d\n", (int)i, (int)(unsigned char)direct[i]);
    }

    return 0;
}
