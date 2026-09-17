/* lltest.c - exercise the 64-bit integer and block-move CallTable slots from a
 * hand-written CSUB, so the results can be compared with the interpreter's own
 * operators on the same values.
 *
 * Slots under test (added in 6.03.02b8):
 *     LMul 0x140  LDiv 0x144  LMod 0x148
 *     LShl 0x14C  LAsr 0x150  LLsr 0x154
 *     memcpy 0x158  memset 0x15C  memmove 0x160
 *
 * On Cortex-M0+ these are the only long long operations GCC cannot emit inline,
 * and a CSUB links without libgcc - so before these slots existed a CSUB could
 * not multiply, divide, take a remainder or shift by a variable count at 64
 * bits at all.  Add, subtract, negate, compare, AND/OR/XOR and shifts by a
 * CONSTANT all compile inline and are checked here too, to show they need no
 * vector.
 *
 * Build:
 *     python user-tools/armcfgen.py Bas/lltest.c --compile -n lltest -e lltest \
 *            -O s -I . -o Bas/lltest.txt
 *
 * Call from BASIC (see lltest.bas):
 *     CSUB lltest INTEGER, INTEGER
 *     lltest a(), r()
 *
 * a(): 0 = x, 1 = y, 2 = n (the shift count)
 * r(): the results, one per operation - lltest.bas names them.
 */
#define CSUB_MEM_SHIMS /* we want the memcpy/memset/memmove symbols in the blob */
#include "PicoCFunctions.h"

long long lltest(long long *a, long long *r)
{
    long long x = a[0], y = a[1];
    int n = (int)a[2];
    int i;

    /* the six vectors */
    r[0] = LMul(x, y);
    r[1] = LDiv(x, y);
    r[2] = LMod(x, y);
    r[3] = LShl(x, n);
    r[4] = LAsr(x, n);
    r[5] = (long long)LLsr((unsigned long long)x, n);

    /* the operations GCC emits inline - no vector needed, checked to prove it */
    r[6] = x + y;
    r[7] = x - y;
    r[8] = -x;
    r[9] = (x < y) ? 1 : 0;
    r[10] = (x & y) | (x ^ y);
    r[11] = x << 5;  /* constant count */
    r[12] = x >> 3;  /* constant count */

    /* block moves. buf is deliberately initialised with an aggregate
       initialiser so the compiler emits an IMPLICIT memset call by name - that
       is the case a CallTable macro cannot catch and the shim exists for. */
    {
        unsigned char buf[48] = {0};
        long long sum = 0;

        for (i = 0; i < 48; i++)
            sum += buf[i]; /* must be 0: the implicit memset ran */
        r[13] = sum;

        for (i = 0; i < 16; i++)
            buf[i] = (unsigned char)(i * 7 + 1);
        memcpy(buf + 16, buf, 16); /* explicit memcpy through the shim */
        memmove(buf + 8, buf, 24); /* overlapping, forward - memmove must cope */
        memset(buf + 40, 0xA5, 8);

        sum = 0;
        for (i = 0; i < 48; i++)
            sum += (long long)(buf[i] * (i + 1)); /* 32-bit multiply, widened: no lmul needed */
        r[14] = sum;
    }

    r[15] = 0x600302B8; /* a marker, so a stale blob is obvious */
    return 0;
}
