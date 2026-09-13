DIM INTEGER cTrailN, cTrail(19)
cTrailN = 0
Note 1
PRINT "before load  cTrail(0) ="; cTrail(0)
RAM ERASE ALL
RAM FILE LOAD 1, "A:/chain_a.bas"
PRINT "load done"
Note 2
PRINT "after load   cTrail(1) ="; cTrail(1)
PRINT "PASS"
END
SUB Note(v AS INTEGER)
  cTrail(cTrailN) = v : cTrailN = cTrailN + 1
END SUB
