/* Step test-ci-implementation-2: floating -> unsigned integer conversion.
 *
 * The IR used to widen every unsigned destination narrower than 8 bytes to a
 * 64-bit :ftoi, which is an x86 detail (its conversion is signed-only, so the
 * whole 0..UINT_MAX range needs the 64-bit form). AArch64 has a native unsigned
 * W-form, and the widened descriptor made it lose that. The IR now carries the
 * C destination width and each backend picks its own instruction.
 *
 * Every value here is inside the destination's range, so the conversions are
 * defined by 6.3.1.4p1 and both targets must agree with gcc. The interesting
 * ones are above INT_MAX: those are exactly what the signed 32-bit form cannot
 * represent.
 */

#include <stdio.h>

static unsigned int to_uint(double x) { return (unsigned int)x; }
static unsigned short to_ushort(double x) { return (unsigned short)x; }
static unsigned char to_uchar(double x) { return (unsigned char)x; }
static unsigned int float_to_uint(float x) { return (unsigned int)x; }
static int to_int(double x) { return (int)x; }

int main(void)
{
    /* Below, at, and above the signed 32-bit boundary. */
    printf("%u %u %u\n", to_uint(0.0), to_uint(1.5), to_uint(2147483647.0));
    printf("%u %u\n", to_uint(2147483648.0), to_uint(4294967295.0));

    /* Truncation is toward zero, not rounding. */
    printf("%u %u\n", to_uint(4294967294.75), to_uint(3000000000.9));

    /* Narrower unsigned destinations keep only their low bytes. */
    printf("%u %u\n", to_ushort(65535.0), to_uchar(255.0));

    /* binary32 source: 0xFFFFFF00 is exactly representable as a float, so this
     * stays in range after the source itself is rounded. */
    printf("%u\n", float_to_uint(4294967040.0f));

    /* The signed path must not have regressed. */
    printf("%d %d\n", to_int(-2147483648.0), to_int(2147483647.0));

    return 0;
}
