/* Step 28 (Phase C3): ISO declaration conformance gaps found by c-testsuite
   triage, plus the conditional void-pointer composite. Exercises tentative
   definitions (6.9.2), a single external declaration mixing function prototypes
   and an object, a parameter array declarator with `static` and type
   qualifiers, the __restrict pointer qualifier spelling glibc prototypes use, a
   pointer to an incomplete enum, and a "?:" whose arms are a char* and a void*.
   Uses only features available through this step; output is deterministic. */
int printf(const char *format, ...);

/* Tentative definitions: one object declared several times, initialized once
   (00095 shape), and the single-declaration comma form (00096 shape). */
int gx;
int gx = 42;
int gx;

int gy, gy = 7, gy;

static int gz;
static int gz = 5;
static int gz;

/* One declaration with two function prototypes and an object (00121 shape):
   the leading function declarator does not make the whole line a definition. */
int addone(int a), subone(int a), counter;

/* A pointer to an incomplete (never-defined) enum: valid as a pointer. */
enum Color *palette;

/* A "?:" whose second and third operands are a char* and a void*; ISO 6.5.15p6
   makes the result void*. */
void *pick(int cond, char *s, void *v)
{
    return cond ? (char *)s : v;
}

/* A parameter array declarator carrying `static` and a type qualifier: both are
   accepted and adjust to a plain pointer. */
int sum5(int a[static 5])
{
    return a[0] + a[1] + a[2] + a[3] + a[4];
}

int first_const(int a[const 3])
{
    return a[0];
}

/* __restrict on the pointer parameters, exactly as a glibc prototype spells it. */
int add_through(int *__restrict p, int *__restrict q)
{
    return *p + *q;
}

int addone(int a) { return a + 1; }
int subone(int a) { return a - 1; }

int main(void)
{
    int nums[5] = { 1, 2, 3, 4, 5 };
    int pair_a = 20, pair_b = 22;
    char label[4];
    void *picked;

    counter = addone(10) + subone(10); /* 11 + 9 = 20 */

    label[0] = 'k';
    picked = pick(1, label, 0);        /* char* arm -> void* */

    printf("gx=%d gy=%d gz=%d\n", gx, gy, gz);
    printf("counter=%d\n", counter);
    printf("sum5=%d\n", sum5(nums));
    printf("first_const=%d\n", first_const(nums));
    printf("add_through=%d\n", add_through(&pair_a, &pair_b));
    printf("picked=%c palette_null=%d\n", *(char *)picked, palette == 0);

    return 0;
}
