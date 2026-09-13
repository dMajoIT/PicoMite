' =====================================================================
'  libtest: the program half
'
'  Nothing in here defines LIBTAG$, libReady, LibAdd, dat_numbers2 or any
'  of the rest.  They all come out of the library, which is in a different
'  flash area entirely, and the figures this prints are the proof.
' =====================================================================

PRINT "--- from the library ---"
PRINT "tag      "; LIBTAG$
PRINT "version  "; LIBVER
PRINT "ready    "; libReady
PRINT "squares  "; libSq(3); libSq(12)
PRINT "names    "; LibShipName$(0); " "; LibShipName$(1); " "; LibShipName$(2)
PRINT "add      "; LibAdd(2, 3)
LibBump 10
PRINT "calls    "; libCalls
PRINT "total    "; LibTotal()

' The main program reading the library's DATA, by a label that is also in
' the library.
DIM INTEGER p, q, r
RESTORE dat_numbers2
READ p, q, r
PRINT "restore  "; p; q; r

LibCallback "hello"

' One number that only comes out right if every line above did.
PRINT "checksum "; LIBVER + libReady + libSq(12) + LibAdd(2, 3) + libCalls + LibTotal() + p + q + r
PRINT "--- end ---"
END

SUB MainHook(tag$)
  PRINT "callback "; tag$
END SUB
