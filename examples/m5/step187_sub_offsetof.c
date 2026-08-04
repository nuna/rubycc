/*
 * Step 187: folding the subtraction form of offsetof to a compile-time
 * constant.
 *
 * Step 184 folded one traditional spelling of offsetof, the cast form:
 *
 *     #define offsetof(type, member) ((size_t)&((type *)0)->member)
 *
 * A second spelling is at least as common, and takes a byte difference
 * instead of a bare address:
 *
 *     #define offsetof(type, member) \
 *         ((size_t)((char *)&((type *)0)->member - (char *)0))
 *
 * Both name the same distance -- the member's offset from the struct's own
 * base -- but the subtraction form reaches it through a pointer difference
 * (ISO C 6.5.6p9) rather than a bare cast-to-integer, so folding the cast
 * form alone (#absolute_pointer_value) did not cover it: the base and the
 * member's address are each an address this evaluator already places, but
 * their difference is a different operator (#pointer_difference) that had
 * never been taught to look at them.
 *
 * The rule the fold applies is 6.5.6p9's own: the byte difference divides by
 * the pointed-to type's size, which must be shared by both sides. That is
 * "char *" for the traditional macro, but nothing pins the fold to a
 * one-byte stride -- a difference between "int *" values divides by
 * sizeof(int) instead, and this sample checks that stride alongside the
 * byte one.
 */

#include <stddef.h>
#include <stdio.h>

/* The subtraction-form macro, written out rather than taken from
 * <stddef.h> -- rubycc's own header expands offsetof to
 * __builtin_offsetof, and it is this traditional form that is the point of
 * the sample. */
#define OFFSET_OF_SUB(type, member) \
    ((size_t)((char *)&((type *)0)->member - (char *)0))

struct plain_data {
    unsigned long flags;
    const char *klass;
    void *data;
};

struct typed_data {
    unsigned long flags;
    const char *klass;
    const struct type_info *type;
    void *data;
};

struct type_info {
    const char *name;
};

/* Two subtraction-form offsets compared with "==": both sides must fold
 * before the comparison can, exactly as the CRuby assertion this mirrors
 * (rtypeddata.h) requires of the cast form in Step 184's sample. */
_Static_assert(OFFSET_OF_SUB(struct plain_data, data) != OFFSET_OF_SUB(struct typed_data, data),
               "the two layouts deliberately disagree here");

struct frame {
    char tag;
    int samples[8];
};

_Static_assert(OFFSET_OF_SUB(struct frame, tag) == 0, "leading member");
_Static_assert(OFFSET_OF_SUB(struct frame, samples) == 4, "aligned member");

/* A stride other than one byte: subtracting two "int *" values divides by
 * sizeof(int), not by one, so the two middle elements are 2 apart, not 8. */
_Static_assert((int *)&((struct frame *)0)->samples[4] - (int *)&((struct frame *)0)->samples[2] == 2,
               "int-pointer difference divides by sizeof(int)");

/* Advancing a folded address by an integer (6.5.6p8) is itself foldable, so
 * the byte offset just past a member is the subtraction form applied to
 * "&member + 1". */
#define OFFSET_OF_SUB_END(type, member) \
    ((size_t)((char *)(&((type *)0)->member + 1) - (char *)0))

_Static_assert(OFFSET_OF_SUB_END(struct frame, tag) == 1, "one past a char member");

static void describe(const char *name, size_t offset)
{
    printf("%s at %zu\n", name, offset);
}

int main(void)
{
    struct frame frame;
    char *base = (char *)&frame;

    describe("plain_data.data", OFFSET_OF_SUB(struct plain_data, data));
    describe("typed_data.data", OFFSET_OF_SUB(struct typed_data, data));
    describe("frame.tag", OFFSET_OF_SUB(struct frame, tag));
    describe("frame.samples", OFFSET_OF_SUB(struct frame, samples));
    printf("samples[4] - samples[2] = %d\n",
           (int)((int *)&((struct frame *)0)->samples[4] - (int *)&((struct frame *)0)->samples[2]));
    describe("one past frame.tag", OFFSET_OF_SUB_END(struct frame, tag));

    /* The offset really is the distance a run-time member access uses:
     * adding it to an object's own address reaches that object's member. */
    frame.samples[3] = 4321;
    printf("through the offset: %d\n", *(int *)(base + OFFSET_OF_SUB(struct frame, samples) + 3 * sizeof(int)));

    return 0;
}
