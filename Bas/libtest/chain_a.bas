' =====================================================================
'  Overlay A.  No DIM and no CONST: the launcher owns those.
' =====================================================================

cWho$ = "A"
cVisits = cVisits + 1
Trail 10 + cVisits
cAcc = cAcc + Work()
PRINT "A        visit "; cVisits; " acc "; cAcc; " (Work here = "; Work(); ")"
RAM CHAIN 2
END

' Both overlays define a Trail and a Work.  Each gets its own.
SUB Trail(v AS INTEGER)
  cTrail(cTrailN) = v : cTrailN = cTrailN + 1
END SUB

FUNCTION Work() AS FLOAT
  Work = 100
END FUNCTION

' Only overlay A has this one.  Overlay B tries to call it, to show what
' crossing the seam actually does.
SUB OnlyInA
  PRINT "OnlyInA ran"
END SUB
