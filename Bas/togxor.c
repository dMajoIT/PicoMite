/* TogXor n%, pin%  -  toggle a pin the fast way.
 *
 * PIN(n) = v goes through ExtSet, which checks the pin's mode and then calls
 * PinSetBit(LATSET) or PinSetBit(LATCLR) - and each of those re-establishes the
 * pull configuration before writing the level. Three SDK calls a write.
 *
 * LATINV is one gpio_xor_mask64 and nothing else. There is no MMBasic statement
 * for it - PIN(n) = v has to say WHICH level - so it is only reachable from a
 * CSUB, which is the point of the comparison.
 */
#include "mmcsub.h"

long long TogXor(void *a0, void *a1)
{
    MMINTEGER n = *(MMINTEGER *)a0;
    int pin = (int)*(MMINTEGER *)a1;
    while (n-- > 0)
    {
        PinSetBit(pin, LATINV);
        PinSetBit(pin, LATINV);
    }
    return 0;
}
