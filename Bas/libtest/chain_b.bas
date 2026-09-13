' =====================================================================
'  Overlay B.
' =====================================================================

cWho$ = "B"
Trail 20 + cVisits
cAcc = cAcc + Work()
PRINT "B        visit "; cVisits; " acc "; cAcc; " (Work here = "; Work(); ")"

' A subroutine that lives in the other overlay.  The table was rebuilt on
' the way in, so it is not there any more.
ON ERROR SKIP 1
OnlyInA
IF MM.ERRNO <> 0 THEN
  PRINT "seam     calling into overlay A: "; MM.ERRMSG$
ELSE
  PRINT "seam     overlay A's SUB was still callable"
ENDIF
ON ERROR CLEAR

IF cVisits < 2 THEN
  RAM CHAIN 1
ELSE
  RAM CHAIN 0
ENDIF
END

SUB Trail(v AS INTEGER)
  cTrail(cTrailN) = v : cTrailN = cTrailN + 1
END SUB

FUNCTION Work() AS FLOAT
  Work = 7
END FUNCTION
