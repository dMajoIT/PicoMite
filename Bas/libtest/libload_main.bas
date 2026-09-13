' =====================================================================
'  LIBRARY LOAD: a program that guarantees its own library
'
'  The library is part of the program's deployment, not something the user
'  has to install by hand.  This is the whole point of the command: ship
'  lib.bas next to main.bas and the program sorts itself out.
'
'  It has to be the first statement.  The library's own top level runs at
'  RUN before the program's first line, so a library loaded after the
'  program had started declaring things would arrive too late to be
'  initialised - and MMBasic will not let the same name be declared twice.
'
'  The first run writes the library and starts the program again from the
'  top.  On that second pass, and on every later run, the hash matches and
'  the command does nothing at all - no erase, no write, no flash wear.
' =====================================================================

LIBRARY LOAD "A:/lib.bas"

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
DIM INTEGER p, q, r
RESTORE dat_numbers2
READ p, q, r
PRINT "restore  "; p; q; r
LibCallback "hello"
PRINT "checksum "; LIBVER + libReady + libSq(12) + LibAdd(2, 3) + libCalls + LibTotal() + p + q + r
PRINT "--- end ---"
END

SUB MainHook(tag$)
  PRINT "callback "; tag$
END SUB
