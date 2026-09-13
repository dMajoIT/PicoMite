' =====================================================================
'  chain_boot: the launcher, and the only place globals are declared
'
'  CHAIN switches which program is running without clearing the variables,
'  so a set of overlays share one state.  What they do NOT share is code:
'  every CHAIN re-prepares the subroutine table from the program it has
'  just switched to, so an overlay can only call its own SUBs.
'
'  Hence the one absolute rule: exactly one program declares the globals
'  and the constants, and a chained program must never redeclare them.
'  The guard below is how a launcher survives being chained back into -
'  bootDone is never DIMmed, so it is zero on the first entry and the DIM
'  block runs, and one on every later entry and the block is jumped over.
'
'  And one trap, found by experiment and not in any manual: RAM FILE LOAD
'  leaves the running program's subroutine table pointing into the slot it
'  has just written, so the next call to one of your own SUBs fails with
'  "Inconsistent type suffix".  A CHAIN puts it right, because that
'  re-prepares.  So a loader must do its loading last and chain straight
'  out of it, which is what this one does.
' =====================================================================

IF bootDone THEN GOTO reentry

DIM INTEGER cVisits, cTrailN, cTrail(19), bIdx
DIM bTxt$ LENGTH 80
DIM FLOAT cAcc
DIM cWho$ LENGTH 16
cVisits = 0 : cTrailN = 0 : cAcc = 0
bootDone = 1
cWho$ = "boot"
Note 1
PRINT "boot     first entry"

' Nothing below this line may call one of our own SUBs.
RAM ERASE ALL
RAM FILE LOAD 1, "A:/chain_a.bas"
RAM FILE LOAD 2, "A:/chain_b.bas"
RAM CHAIN 1
END

reentry:
cWho$ = "boot"
Note 1
PRINT "boot     back again, visits "; cVisits; " acc "; cAcc
bTxt$ = ""
FOR bIdx = 0 TO cTrailN - 1 : bTxt$ = bTxt$ + STR$(cTrail(bIdx)) + " " : NEXT bIdx
PRINT "trail    "; bTxt$
PRINT "visits   "; cVisits
PRINT "acc      "; cAcc
PRINT "checksum "; cVisits * 1000 + cAcc + cTrailN
PRINT "--- end ---"
END

SUB Note(v AS INTEGER)
  cTrail(cTrailN) = v : cTrailN = cTrailN + 1
END SUB
