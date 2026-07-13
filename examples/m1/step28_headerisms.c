/* Step 28 (part 2): features found blocking <ruby.h>. Adjacent string-literal
   concatenation (translation phase 6, including a stringize result abutting a
   plain literal); the wide character constant L'x' (value equal to a plain
   constant for the single-byte characters this subset lexes); the _Pragma
   operator accepted and discarded; and System V bit-field LAYOUT reported
   through sizeof/_Alignof (a bit-field's value is never read — access is
   diagnosed — so only the layout is exercised). Uses only features available
   through this step. */
int printf(const char *format, ...);

/* Ruby's static-assert fallback expands to three adjacent literals; #x abutting
   ": " abutting a literal is exactly that shape. */
#define LABEL(x) #x ": " "ok"

/* config.h defines its symbol-export markers as _Pragma(...); accepted here and
   dropped, so it may sit at file scope with no effect. */
_Pragma("GCC visibility push(default)")

struct Flags { int a : 3; int b : 5; };          /* both share one int unit */
struct Split { int a : 30; int b : 5; };         /* b straddles -> next unit */
struct Bytes { char a : 3; char b : 6; };        /* b straddles a byte -> next */
struct Force { int a : 5; int : 0; int b : 3; }; /* :0 realigns to next int */
struct Pad   { int : 32; int : 32; };            /* the timex padding pattern */

int main(void) {
    /* Two, then three, adjacent literals fold into one string. */
    printf("%s\n", "abc" "def");
    printf("%s\n", LABEL(name));

    /* A wide character constant folds to the same int value as 'A'/'\0'. */
    int wide = L'A';
    int nul = L'\0';
    printf("wide %d nul %d\n", wide, nul);

    /* Bit-field layout matches the System V x86-64 rules gcc follows. */
    printf("Flags %d/%d\n", (int)sizeof(struct Flags), (int)_Alignof(struct Flags));
    printf("Split %d/%d\n", (int)sizeof(struct Split), (int)_Alignof(struct Split));
    printf("Bytes %d/%d\n", (int)sizeof(struct Bytes), (int)_Alignof(struct Bytes));
    printf("Force %d/%d\n", (int)sizeof(struct Force), (int)_Alignof(struct Force));
    printf("Pad %d/%d\n", (int)sizeof(struct Pad), (int)_Alignof(struct Pad));

    return wide - nul - 65;
}
