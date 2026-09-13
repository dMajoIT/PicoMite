' =====================================================================
'  savetest signature: what SaveProgramToFlash actually wrote
'
'  The region to check is program memory, but a program that checksums
'  program memory has to be IN program memory, which changes what it is
'  checksumming.  So the driver snapshots the region with FLASH SAVE 1
'  first - a straight copy of all MAX_PROG_SIZE bytes - and this reads
'  that back from the slot instead.
'
'  The checksum is over the whole region, not just the program text, so
'  it covers the CSUB and font binaries that passes 2 and 3 append after
'  the terminator, and the erased 0xFF tail as well.  Any single byte
'  written to a different place, or a size word back-filled wrongly,
'  changes it.
' =====================================================================

DIM INTEGER base, a, w, n, k
DIM INTEGER h1, h2, plen, blobs

base = MM.INFO(FLASH ADDRESS 1)
n = 147456 / 8                       ' MAX_PROG_SIZE in 64 bit words

' Two independent running sums, so a transposition shows up as well as a
' substitution.  Kept inside 62 bits to stay exact in a signed integer.
h1 = 0 : h2 = 0
FOR k = 0 TO n - 1
  w = PEEK(INTEGER base + k * 8)
  h1 = (h1 * 31 + w) AND &H3FFFFFFFFFFFFFF
  h2 = (h2 + (h1 XOR k)) AND &H3FFFFFFFFFFFFFF
NEXT k

' Where the program text ends: the two zero bytes, then the 0xFF header of
' the binary area.  Reported separately because it localises a difference -
' a change here is pass 1, a change only in the checksum is pass 2 or 3.
plen = 0
FOR k = 0 TO 147454
  IF PEEK(BYTE base + k) = 0 AND PEEK(BYTE base + k + 1) = 0 THEN plen = k : EXIT FOR
NEXT k

' How many CSUB/font blobs follow, and how long each says it is.
a = plen
DO WHILE PEEK(BYTE base + a) <> &HFF AND a < 147452
  a = a + 1
LOOP
a = a + 4
blobs = 0
DO WHILE a < 147448
  w = PEEK(WORD base + a + 4)
  IF w = &HFFFFFFFF OR w = 0 OR w > 147456 THEN EXIT DO
  blobs = blobs + 1
  PRINT "blob     "; blobs; " at "; a; " size "; w
  a = a + w + 8
LOOP

PRINT "proglen  "; plen
PRINT "blobs    "; blobs
PRINT "hash1    "; HEX$(h1, 16)
PRINT "hash2    "; HEX$(h2, 16)
PRINT "--- sig end ---"
END
