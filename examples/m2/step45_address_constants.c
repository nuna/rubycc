/*
 * Step 45: address constants in global initializers. A static pointer may be
 * initialized with any constant address: a string literal seen through a
 * pointer cast (json's jeaiii-ltoa digit table casts one long string literal
 * to a struct-pair pointer), an element or member of a static object
 * ("&arr[i]", "arr + n", "&rec.field"), all folded to symbol+offset
 * relocations at compile time. Compiled by rubycc, linked with libc's printf.
 */

int printf(const char *, ...);

/* The jeaiii-ltoa shape: a string literal, cast to a pointer to two-char
 * cells, indexed as a lookup table. */
struct digit_pair { char dd[2]; };
static const struct digit_pair *digits = (const struct digit_pair *)(
    "00" "01" "02" "03" "04" "05" "06" "07" "08" "09"
    "10" "11" "12" "13" "14" "15" "16" "17" "18" "19");

/* Element and member address constants against a static object. */
static int table[5] = { 10, 20, 30, 40, 50 };
static int *third = &table[2];
static int *fourth = table + 3;

struct rec { char tag; long id; int score; };
static struct rec sample = { 'r', 77, 9 };
static long *sample_id = &sample.id;
static int *sample_score = &sample.score;

/* A cast around a symbol address keeps the bits. */
static void *raw = (void *)&table[4];

int main(void) {
  /* digits[13] is the "13" cell of the flattened string. */
  printf("cell=%c%c\n", digits[13].dd[0], digits[13].dd[1]);
  printf("third=%d fourth=%d\n", *third, *fourth);
  printf("id=%ld score=%d last=%d\n", *sample_id, *sample_score, *(int *)raw);

  return *third + *fourth + (int)*sample_id - 105; /* 30+40+77-105 = 42 */
}
