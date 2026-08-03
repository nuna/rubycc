/*
 * Step 168: block-scope function declarations (C11 6.2.2p5).
 *
 * A declarator that builds a function type inside a block declares a function,
 * not a local object: with no storage-class specifier, or with `extern`, the
 * identifier has external linkage, so it names the very same function a
 * file-scope declaration of that name would name. It reserves no storage, takes
 * no stack slot, and its calls are ordinary external calls.
 *
 * This is the shape CRuby's <ruby/ractor.h> uses -- rb_ractor_shareable_p()
 * forward-declares rb_ractor_shareable_p_continue() from inside its own body --
 * which is what io-console's console.c drags in.
 *
 * A function *definition* inside a block (a nested function) is a GNU
 * extension, not this, and rubycc rejects it.
 */

#include <stdio.h>

/* Counts the calls the block-declared functions actually made, so the sample
 * shows the calls reaching their definitions rather than merely compiling. */
static int calls;

static void banner(const char *what)
{
    printf("-- %s --\n", what);
}

int main(void)
{
    /* (1) No storage-class specifier. The identifier still has external
     * linkage, so it names the "scale" defined at the bottom of this file even
     * though no file-scope declaration of it precedes this point. */
    int scale(int, int);
    int total = 0;
    int i;

    banner("plain");
    for (i = 1; i <= 4; i++) {
        total += scale(i, 3);
    }
    printf("total=%d calls=%d\n", total, calls);

    {
        /* (2) The same declaration spelled with `extern`, in a nested block.
         * `extern` is the only storage-class specifier 6.7.1p7 allows here
         * (`static` is a constraint violation and rubycc diagnoses it), and it
         * changes nothing about the linkage the declaration already had. Each
         * call is given its own statement: two calls in one printf argument
         * list would compare rubycc's left-to-right evaluation against gcc's
         * right-to-left, which C leaves unspecified. */
        extern long widen(int);
        extern const char *label(void);
        long widened;
        const char *name;

        banner("extern");
        widened = widen(total);
        name = label();
        printf("widen=%ld label=%s calls=%d\n", widened, name, calls);
    }

    {
        /* (3) The declaration in (1) is visible in this nested block too, and
         * it is a declaration like any other: the function designator decays to
         * a pointer, so the address can be taken and the call made indirectly. */
        int (*through)(int, int) = scale;
        int indirect;

        banner("indirect");
        indirect = through(7, 6);
        printf("through=%d calls=%d\n", indirect, calls);
    }

    return 0;
}

int scale(int value, int factor)
{
    calls++;
    return value * factor;
}

long widen(int value)
{
    calls++;
    return (long)value * 1000;
}

const char *label(void)
{
    calls++;
    return "ok";
}
