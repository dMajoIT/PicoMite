/* jbench.c - is --single worth building?
 *
 * Copies of one Julia inner loop, differing only in the types the arithmetic
 * is done in, plus a set of single multiplies that separate the cost of the
 * operation from the cost of reaching it:
 *
 *   0  double + long long   what mmb2csub emits today
 *   1  float  + long long   --single, the float half only
 *   2  float  + int         --single, both halves
 *   3  neither              the bare loop, to subtract the harness
 *   4  double from an MMBasic array   the shape where values are not local
 *   5  float  from an MMBasic array   - every element needs a DtoS
 *   6  one float multiply, slot called directly
 *   7  one float multiply, through the mmcsub.h C shim
 *   8  one float multiply, through a naked tail-jump stub
 *   9  one double multiply, through the C shim
 *  10  one double multiply, through a tail-jump stub
 *
 * Everything stays in LOCALS. Nothing here touches an interpreter-owned array
 * or global, so no value is converted at the boundary - this is the shape
 * --single is best at, and what it measures is the ceiling, not the average.
 *
 * The loop runs a fixed count and RESETS on escape instead of breaking out, so
 * all four do identical work per iteration and the timing cannot be an artefact
 * of one of them escaping sooner.
 */
#include "mmcsub.h"

/* --- the __aeabi_f* runtime, which mmcsub.h does not yet carry --------------
 * The double twins of these are already in mmcsub.h; they forward to the F*
 * CallTable slots. These forward to the S* slots, which have been on the table
 * since the first commit. If --single happens, this block is most of it. */
float __aeabi_fadd(float a, float b) { return SAdd(a, b); }
float __aeabi_fsub(float a, float b) { return SSub(a, b); }
float __aeabi_fmul(float a, float b) { return SMul(a, b); }
float __aeabi_fdiv(float a, float b) { return SDiv(a, b); }
int __aeabi_fcmpeq(float a, float b) { return SCmp(a, b) == 0; }
int __aeabi_fcmplt(float a, float b) { return SCmp(a, b) < 0; }
int __aeabi_fcmple(float a, float b) { return SCmp(a, b) <= 0; }
int __aeabi_fcmpge(float a, float b) { return SCmp(a, b) >= 0; }
int __aeabi_fcmpgt(float a, float b) { return SCmp(a, b) > 0; }
int __aeabi_fcmpun(float a, float b) { (void)a; (void)b; return 0; }
float __aeabi_i2f(int a) { return ItoS((long long)a); }
float __aeabi_ui2f(unsigned a) { return ItoS((long long)a); }
float __aeabi_l2f(long long a) { return ItoS(a); }
double __aeabi_f2d(float a) { return StoD(a); }
float __aeabi_d2f(double a) { return DtoS(a); }

/* StoI ROUNDS; a C cast truncates toward zero. Same correction the existing
   __aeabi_d2lz makes, for the same reason. */
long long __aeabi_f2lz(float a)
{
    long long t = StoI(a);
    if (SCmp(a, 0.0f) >= 0) { if (SCmp(ItoS(t), a) > 0) t -= 1; }
    else                    { if (SCmp(ItoS(t), a) < 0) t += 1; }
    return t;
}
int __aeabi_f2iz(float a) { return (int)__aeabi_f2lz(a); }

/* --- the four loops ------------------------------------------------------ */
#define CX (-0.4)
#define CY (0.6)

static MMINTEGER jul_double(MMINTEGER n)
{
    double zx = 0.0, zy = 0.0, t;
    MMINTEGER i, esc = 0;
    for (i = 0; i < n; i++) {
        mm_poll();
        t  = zx * zx - zy * zy + CX;
        zy = 2.0 * zx * zy + CY;
        zx = t;
        if (zx * zx + zy * zy > 4.0) { zx = 0.0; zy = 0.0; esc++; }
    }
    return esc;
}

static MMINTEGER jul_float_ll(MMINTEGER n)
{
    float zx = 0.0f, zy = 0.0f, t;
    MMINTEGER i, esc = 0;
    for (i = 0; i < n; i++) {
        mm_poll();
        t  = zx * zx - zy * zy + (float)CX;
        zy = 2.0f * zx * zy + (float)CY;
        zx = t;
        if (zx * zx + zy * zy > 4.0f) { zx = 0.0f; zy = 0.0f; esc++; }
    }
    return esc;
}

static MMINTEGER jul_float_i(int n)
{
    float zx = 0.0f, zy = 0.0f, t;
    int i, esc = 0;
    for (i = 0; i < n; i++) {
        mm_poll();
        t  = zx * zx - zy * zy + (float)CX;
        zy = 2.0f * zx * zy + (float)CY;
        zx = t;
        if (zx * zx + zy * zy > 4.0f) { zx = 0.0f; zy = 0.0f; esc++; }
    }
    return esc;
}

static MMINTEGER jul_empty(MMINTEGER n)
{
    MMINTEGER i, esc = 0;
    for (i = 0; i < n; i++) { mm_poll(); esc += i; }
    return esc;
}

/* --- the other shape: values that live in MMBasic's memory ----------------
 * An MMBasic float array is an array of DOUBLE, and the generated code indexes
 * it directly. A --single routine therefore has to convert every element it
 * reads - which is another CallTable call, on top of the cheaper multiply. */
static MMINTEGER filt_double(MMINTEGER n, double *buf)
{
    double s = 0.0;
    MMINTEGER i;
    for (i = 0; i < n; i++) {
        mm_poll();
        s = s + buf[i & 255] * 1.0000001;
    }
    return (MMINTEGER)s;
}

static MMINTEGER filt_float(MMINTEGER n, double *buf)
{
    float s = 0.0f;
    MMINTEGER i;
    for (i = 0; i < n; i++) {
        mm_poll();
        s = s + (float)buf[i & 255] * 1.0000001f;   /* the (float) is a DtoS call */
    }
    return (MMINTEGER)s;
}

/* --- what the shim layer itself costs -------------------------------------
 * Every float op in generated code goes through TWO calls: GCC emits
 * `bl __aeabi_fmul`, the shim in mmcsub.h loads the CallTable slot, and only
 * then does it blx into the firmware. These two loops are identical except
 * that one calls the slot directly and the other goes via the shim, so the
 * difference is the cost of that extra level - the same for float and double,
 * and payable by every CSUB ever built.
 *
 * k is just over 1, so 200000 multiplies take s from 1.0 to about 1.02:
 * nothing overflows and no reset is needed to keep the two loops symmetric. */
static MMINTEGER mul_direct(MMINTEGER n)
{
    float s = 1.0f, k = 1.0000001f;
    MMINTEGER i;
    for (i = 0; i < n; i++) { mm_poll(); s = SMul(s, k); }
    return (MMINTEGER)(s * 1000.0f);
}

static MMINTEGER mul_shim(MMINTEGER n)
{
    float s = 1.0f, k = 1.0000001f;
    MMINTEGER i;
    for (i = 0; i < n; i++) { mm_poll(); s = s * k; }
    return (MMINTEGER)(s * 1000.0f);
}

/* --- the shim, done as a tail jump ---------------------------------------
 * The C shim above costs a bl in, a push, a blx, the callee's return BACK TO
 * THE SHIM, and a pop. Everything after the lookup is avoidable: the firmware
 * routine can return straight to the original caller.
 *
 * The soft-float ABI puts the arguments in r0-r3 and the stub never touches
 * them, so for a two-float call r2 and r3 are free and this needs no stack at
 * all. A two-DOUBLE call uses all four, so that one has to park the target in
 * r12 - still cheaper than a second return hop. */
__attribute__((naked)) static float fmul_tail(float a, float b)
{
    (void)a; (void)b;
    __asm volatile(
        ".syntax unified\n"
        "ldr  r2, =0xE000ED08\n"
        "ldr  r2, [r2]\n"
        "ldr  r2, [r2, #28]\n"
        "adds r2, #0xFF\n"
        "adds r2, #0x0D\n"
        "ldr  r2, [r2]\n"
        "bx   r2\n"
        ".ltorg\n");
}

__attribute__((naked)) static double dmul_tail(double a, double b)
{
    (void)a; (void)b;
    __asm volatile(
        ".syntax unified\n"
        "push {r4}\n"
        "ldr  r4, =0xE000ED08\n"
        "ldr  r4, [r4]\n"
        "ldr  r4, [r4, #28]\n"
        "adds r4, #0xA0\n"
        "ldr  r4, [r4]\n"
        "mov  r12, r4\n"
        "pop  {r4}\n"
        "bx   r12\n"
        ".ltorg\n");
}

static MMINTEGER mul_tail_f(MMINTEGER n)
{
    float s = 1.0f, k = 1.0000001f;
    MMINTEGER i;
    for (i = 0; i < n; i++) { mm_poll(); s = fmul_tail(s, k); }
    return (MMINTEGER)(s * 1000.0f);
}

static MMINTEGER mul_shim_d(MMINTEGER n)
{
    double s = 1.0, k = 1.0000001;
    MMINTEGER i;
    for (i = 0; i < n; i++) { mm_poll(); s = s * k; }
    return (MMINTEGER)(s * 1000.0);
}

static MMINTEGER mul_tail_d(MMINTEGER n)
{
    double s = 1.0, k = 1.0000001;
    MMINTEGER i;
    for (i = 0; i < n; i++) { mm_poll(); s = dmul_tail(s, k); }
    return (MMINTEGER)(s * 1000.0);
}

/* CSUB JBench INTEGER, INTEGER, INTEGER, FLOAT
   JBench(result%, mode%, n%, buf!()) */
long long JBenchK(void *a0, void *a1, void *a2, void *a3)
{
    MMINTEGER mode = *(MMINTEGER *)a1;
    MMINTEGER n = *(MMINTEGER *)a2;
    MMINTEGER r;
    mm_scratch_reset();
    if (mode == 0)      r = jul_double(n);
    else if (mode == 1) r = jul_float_ll(n);
    else if (mode == 2) r = jul_float_i((int)n);
    else if (mode == 3) r = jul_empty(n);
    else if (mode == 4) r = filt_double(n, (double *)a3);
    else if (mode == 5) r = filt_float(n, (double *)a3);
    else if (mode == 6) r = mul_direct(n);
    else if (mode == 7) r = mul_shim(n);
    else if (mode == 8) r = mul_tail_f(n);
    else if (mode == 9) r = mul_shim_d(n);
    else                r = mul_tail_d(n);
    *(MMINTEGER *)a0 = r;
    return 0;
}
