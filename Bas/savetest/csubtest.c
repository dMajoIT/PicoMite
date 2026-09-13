/* A CSUB with an answer that can be checked.
 *
 * It exists so the test can tell whether SaveProgramToFlash wrote the CSUB
 * binary to the right place with the right size word: if the three-pass
 * write mis-sizes or mis-places the blob, this either returns the wrong
 * number or does not run at all.
 *
 * CSUB arguments arrive as pointers.  a and b in, sum and a running mix out,
 * so a single wrong byte in the binary shows up in the result.
 */
void checksum_csub(long long *a, long long *b, long long *sum, long long *mix)
{
    long long x = *a, y = *b, m = 0x1234;
    int i;
    *sum = x + y;
    for (i = 0; i < 16; i++)
    {
        m = (m * 31) + x + (y << 1) + i;
        m &= 0x7fffffff;
    }
    *mix = m;
}
