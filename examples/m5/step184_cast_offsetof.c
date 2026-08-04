/*
 * Step 184: folding the cast form of offsetof to a compile-time constant.
 *
 * Before <stddef.h> could rely on __builtin_offsetof, a member's byte offset
 * was written by pointing a null pointer at the struct and taking the address
 * of the member:
 *
 *     #define offsetof(type, member) ((size_t)&((type *)0)->member)
 *
 * The address never gets dereferenced; only the distance from the (constant)
 * base survives the cast back to an integer. That distance is fixed by the
 * struct's layout alone, so a compiler can settle it without emitting any
 * code -- which is what lets the form stand where a constant is required.
 *
 * rubycc used to fold it only in a global's initializer, where the address
 * constant machinery lives. Every other constant context -- a _Static_assert
 * above all -- saw a non-constant and stopped. CRuby's
 * <ruby/internal/core/rtypeddata.h> asserts that struct RData and struct
 * RTypedData put their "data" member at the same offset, and it spells both
 * offsets with the macro its libc supplies; with a libc whose <stddef.h>
 * writes the cast form, that assertion alone stopped <ruby.h> from being
 * preprocessed at all.
 *
 * This sample plays out that shape and the designators around it: a member of
 * a nested struct, an array member's element, a non-null base, a subscript
 * through the cast itself, and a plain dereference.
 */

#include <stddef.h>
#include <stdio.h>

/* The traditional macro, written out rather than taken from <stddef.h> --
 * rubycc's own header expands offsetof to __builtin_offsetof, and it is the
 * cast form that this sample is about. */
#define OFFSET_OF(type, member) ((size_t)&((type *)0)->member)

/* The CRuby shape: two structs that must agree on where "data" sits, so a
 * pointer to either can be read through the same member. */
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

/* Both offsets are constants, so their comparison is one too. This is the
 * assertion that stopped <ruby.h>. */
_Static_assert(OFFSET_OF(struct plain_data, data) != OFFSET_OF(struct typed_data, data),
               "the two layouts deliberately disagree here");

struct point {
    short x;
    int y;
};

struct frame {
    char tag;
    struct point origin;
    int samples[8];
    struct point corners[4];
};

/* A nested member, an array element, and an element's member. */
_Static_assert(OFFSET_OF(struct frame, origin.y) == 8, "nested member");
_Static_assert(OFFSET_OF(struct frame, samples[2]) == 20, "array element");
_Static_assert(OFFSET_OF(struct frame, corners[3].y) == 72, "element's member");

/* The base need not be null: any constant serves, and the offset is added to
 * it. A subscript applied to the cast itself strides by the whole struct, and
 * a bare dereference lands exactly on the base. */
_Static_assert((size_t) & ((struct frame *)64)->samples[1] == 64 + 16, "non-null base");
_Static_assert((size_t) & ((struct point *)0)[3] == 24, "subscript of the cast");
_Static_assert((size_t) & (*(struct frame *)128) == 128, "dereference of the cast");

/* The same form in a global's initializer, the one context that already
 * folded it. */
static size_t corner_y = OFFSET_OF(struct frame, corners[3].y);

/* A struct reached through an anonymous member resolves as if the member were
 * declared in the enclosing struct, so the macro reaches it too. */
struct packet {
    long header;
    struct {
        int channel;
        int sequence;
    };
};

_Static_assert(OFFSET_OF(struct packet, sequence) == 12, "anonymous member");

static void describe(const char *name, size_t offset)
{
    printf("%s at %zu\n", name, offset);
}

int main(void)
{
    struct frame frame;
    char *base = (char *)&frame;

    describe("plain_data.data", OFFSET_OF(struct plain_data, data));
    describe("typed_data.data", OFFSET_OF(struct typed_data, data));
    describe("frame.origin.y", OFFSET_OF(struct frame, origin.y));
    describe("frame.samples[2]", OFFSET_OF(struct frame, samples[2]));
    describe("frame.corners[3].y", corner_y);
    describe("packet.sequence", OFFSET_OF(struct packet, sequence));
    describe("(struct point *)0 [3]", (size_t) & ((struct point *)0)[3]);
    describe("(struct frame *)64 samples[1]", (size_t) & ((struct frame *)64)->samples[1]);

    /* The offset really is the distance a run-time member access uses: adding
     * it to an object's own address reaches that object's member. */
    frame.corners[3].y = 4321;
    printf("through the offset: %d\n", *(int *)(base + corner_y));

    return 0;
}
