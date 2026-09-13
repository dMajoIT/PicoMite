' =====================================================================
'  Screen, camera, view and object-pool set up
' =====================================================================
SUB SetupScreen
  MODE 2
  FRAMEBUFFER CREATE
  FRAMEBUFFER WRITE F
  ' Draw3D's own centre is (W/2, H/2-1); pany lifts it to the space
  ' view's centre so ships sit above the dashboard, not behind it.
  Draw3D CAMERA 1, VPLANE, 0, 0, 0, PANY
  ' Every one of these has to be one of the sixteen the screen actually has,
  ' or it is rounded to the nearest and rarely to the one you meant: GRAY,
  ' which was here, is not in the palette at all.  A mesh's edges are drawn
  ' in col() entries chosen when the mesh is created, so these four are the
  ' whole of the 6502 Second Processor version's space view palette, plus
  ' black for the station's faces.
  col(C_WHITE) = RGB(WHITE) : col(C_CYAN) = RGB(CYAN)
  col(C_YELLOW) = RGB(YELLOW) : col(C_RED) = RGB(RED)
  col(4) = RGB(GREEN) : col(5) = RGB(MAGENTA) : col(6) = RGB(BLUE)
  col(C_FILL) = RGB(BLACK)
  ' Pre-resolved so the drawing loops assign a variable rather than call
  ' RGB(), which the trace cache cannot compile.
  cGreen = RGB(GREEN) : cYellow = RGB(YELLOW) : cWhite = RGB(WHITE)
  cBlack = RGB(BLACK) : cCyan = RGB(CYAN)
  ' Secondary text and the outlines of the scanner and compass.  This was
  ' RGB(64, 64, 64), which a sixteen colour screen rounds to MYRTLE - a
  ' green so dark it can barely be read.
  cDim = RGB(MIDGREEN)
  ' The band behind the chosen row.  RGB(32, 32, 64) was rounded to black,
  ' so the selection could not be seen at all.
  cSel = RGB(BLUE)
  cRed = RGB(RED) : cMagenta = RGB(MAGENTA) : cBlue = RGB(BLUE)
  ' One turn of the unit circle, for the planet's surface ellipses.
  LOCAL INTEGER k
  FOR k = 0 TO NSEG - 1
    ctab(k) = COS(2 * PI * k / NSEG)
    stab(k) = SIN(2 * PI * k / NSEG)
  NEXT k
  ' Bar rows, converted from the original's character rows.  Left column:
  ' forward shield, aft shield, fuel, cabin temperature, laser temperature,
  ' altitude.  Right column: speed, roll, dive/climb, four energy banks.
  DLY(0) = 178 : DLY(1) = 186 : DLY(2) = 194
  DLY(3) = 202 : DLY(4) = 210 : DLY(5) = 218
  DRY(0) = 178 : DRY(1) = 185 : DRY(2) = 193 : DRY(3) = 202
  DRY(4) = 210 : DRY(5) = 218 : DRY(6) = 226
  LLAB$(0) = "FS" : LLAB$(1) = "AS" : LLAB$(2) = "FU"
  LLAB$(3) = "CT" : LLAB$(4) = "LT" : LLAB$(5) = "AL"
  RLAB$(0) = "SP" : RLAB$(1) = "RL" : RLAB$(2) = "DC"
  RLAB$(3) = "1" : RLAB$(4) = "2" : RLAB$(5) = "3" : RLAB$(6) = "4"
END SUB

' The 6502 Second Processor version's two colour tables.
'
' Its space view runs in mode 1, which has four colours - black, yellow, red
' and cyan - so shpcol has only those to work with: ships are cyan, a missile
' is yellow, rocks are red, and a Thargoid is the cyan/red stripe its source
' calls WHITE.  The planet and the sun get the cyan/yellow stripe it calls
' GREEN.  With sixteen colours to hand the stripes are drawn as the colour
' they were standing in for.
'
' The scanner is mode 2 and has eight, so scacol is the richer of the two: it
' is what lets you tell a rock from a trader without flying over to look.
SUB ShipColours
  LOCAL INTEGER t
  FOR t = 0 TO NTYPE
    shpCol(t) = C_CYAN
    scaCol(t) = cCyan
  NEXT t
  shpCol(T_MISSILE) = C_YELLOW  : scaCol(T_MISSILE) = cYellow
  shpCol(T_ASTEROID) = C_RED    : scaCol(T_ASTEROID) = cRed
  shpCol(T_THARGOID) = C_WHITE  : scaCol(T_THARGOID) = cWhite
  shpCol(T_THARGON) = C_WHITE
  scaCol(T_STATION) = cGreen
  scaCol(T_PYTHON) = cMagenta
  scaCol(T_PYTHONP) = cMagenta
  scaCol(T_TRADER) = cCyan
  scaCol(T_CANISTER) = cBlue
  scaCol(T_ESCAPE) = cBlue
  ' The Second Processor version's own choices for its own ships: rubble red,
  ' the big traders magenta, the Worm blue with the other junk, and the rest of
  ' the fighters cyan like everything else.
  shpCol(T_BOULDER) = C_RED     : scaCol(T_BOULDER) = cRed
  shpCol(T_SPLINTER) = C_RED    : scaCol(T_SPLINTER) = cRed
  shpCol(T_HERMIT) = C_RED      : scaCol(T_HERMIT) = cRed
  scaCol(T_BOA) = cMagenta
  scaCol(T_ANACONDA) = cMagenta
  scaCol(T_WORM) = cBlue
END SUB

' The four views are rotations of the whole universe about the vertical
' axis: front none, rear 180, left +90, right -90.  Positions are
' transformed by hand in ViewXform (three assignments beat a quaternion
' multiply); orientations are pre-multiplied by these.
SUB SetupViews
  LOCAL INTEGER i
  MATH Q_EULER 0, 0, 0, qA()      : FOR i = 0 TO 4 : vwQ(i, 0) = qA(i) : NEXT i
  MATH Q_CREATE RAD(180), 0, 1, 0, qA() : FOR i = 0 TO 4 : vwQ(i, 1) = qA(i) : NEXT i
  MATH Q_CREATE RAD(90), 0, 1, 0, qA()  : FOR i = 0 TO 4 : vwQ(i, 2) = qA(i) : NEXT i
  MATH Q_CREATE RAD(-90), 0, 1, 0, qA() : FOR i = 0 TO 4 : vwQ(i, 3) = qA(i) : NEXT i
END SUB

' How many Draw3D objects does this firmware allow?  MAX3D was 8 and is
' 12 in the current build; creating one past the limit raises an error,
' so ask rather than assume.
SUB ProbeObjects
  LOCAL INTEGER n
  LoadMesh 0
  maxObj = 8
  FOR n = 9 TO 35
    ON ERROR SKIP 1
    Draw3D CREATE n, bNv(0), bNf(0), 1, mV(), mFc(), mF(), col(), mEc()
    IF MM.ERRNO <> 0 THEN EXIT FOR
    Draw3D CLOSE n
    maxObj = n
  NEXT n
  ON ERROR CLEAR
  FOR n = 0 TO 35 : objOwn(n) = -1 : NEXT n
END SUB

SUB CloseAll
  LOCAL INTEGER n
  FOR n = 1 TO maxObj
    IF objOwn(n) >= 0 THEN Draw3D CLOSE n
    objOwn(n) = -1
  NEXT n
END SUB
