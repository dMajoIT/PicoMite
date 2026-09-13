' =====================================================================
'  savetest signature: what SaveProgramToFlash actually wrote
'
'  The region to check is program memory, but a program that checksums
'  program memory has to be IN program memory, which changes what it is
'  checksumming.  So the driver snapshots the region with FLASH SAVE
'  first - a straight copy of all MAX_PROG_SIZE bytes - and this reads
'  that back from the slot instead.
'
'  The hashes cover the whole region, so they include the CSUB and font
'  binaries that passes 2 and 3 append after the program text, and the
'  erased 0xFF tail as well.  binbase and the blob list localise any
'  difference: a change in binbase is pass 1 writing a different amount
'  of program text, a change only in the blob sizes or the hashes is
'  pass 2 or pass 3.
' =====================================================================

DIM INTEGER base, a, w, n, k
DIM INTEGER h1, h2, binbase, blobs
DIM head$ LENGTH 40

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

' Where the program text ends.  Looking for two zero bytes does not work -
' tokenised BASIC is full of them - so do what the firmware does and find
' the first 0xFF, which is the header of the CSUB and font area.
binbase = 0
FOR k = 0 TO 147454
  IF PEEK(BYTE base + k) = &HFF THEN binbase = k : EXIT FOR
NEXT k

' The first bytes of the image, so that a whole-image shift reads as a
' shift rather than as an unexplained difference in the hashes.
head$ = ""
FOR k = 0 TO 15
  head$ = head$ + HEX$(PEEK(BYTE base + k), 2)
NEXT k

' Each CSUB or font blob, and the size word pass 3 back-filled into it.
a = binbase + 4
blobs = 0
DO WHILE a < 147448
  w = PEEK(WORD base + a + 4)
  IF w = &HFFFFFFFF OR w = 0 OR w > 147456 THEN EXIT DO
  blobs = blobs + 1
  PRINT "blob     "; blobs; " at "; a; " size "; w
  a = a + w + 8
LOOP

PRINT "head     "; head$
PRINT "binbase  "; binbase
PRINT "blobs    "; blobs
PRINT "hash1    "; HEX$(h1, 16)
PRINT "hash2    "; HEX$(h2, 16)
PRINT "--- sig end ---"
END
