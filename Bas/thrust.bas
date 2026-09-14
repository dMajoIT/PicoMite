' =====================================================================
'  T H R U S T        PicoMite MMBasic
'  after the 1986 BBC Micro game by Jeremy C. Smith for Superior Software
'
'  Phase 2 of the port (see docs/Thrust_Port_Plan.html): the landscape
'  on its own.  There is no physics and no ship yet - the cursor keys
'  fly the camera around a cave, N and P change level, and the panel
'  says what a frame costs.
'
'  The cave is two numbers per scanline: the X of the left wall and the
'  X of the right, with open ground between.  So a frame is one fill of
'  the playfield in the landscape colour and then the cave punched out
'  of it in black.  Scanlines that share a wall pair collapse into one
'  box, which is what makes this affordable - punching out the cave
'  costs fewer boxes than drawing the two walls separately, because the
'  walls rarely change on the same scanline.  Measured over all six
'  levels: 112 boxes in the worst frame, and nearer thirty typically.
'
'  Units are the BBC's own throughout.  One terrain column is four
'  pixels across and one terrain scanline two pixels down; the game's
'  arithmetic stays in those units and only the drawing scales, which
'  keeps the original's geometry and, later, its angle tables.
'
'  Keys      Camera ......... arrow keys
'            Level .......... N, P
'            Screenshot ..... S  (to A:/thrust.bmp)
'            Quit ........... ESC
' =====================================================================

OPTION EXPLICIT
OPTION DEFAULT NONE

' ------------------------------------------------------------ geometry
CONST SCRW = 320, SCRH = 240
CONST PANELH = 16                 ' status strip across the top
CONST PLAYTOP = PANELH
CONST PLAYH = SCRH - PANELH       ' 224 rows of cave
CONST COLPX = 4                   ' a terrain column is four pixels
CONST ROWPX = 2                   ' a terrain scanline is two
CONST VIEWC = SCRW \ COLPX        ' 80 columns across
CONST VIEWR = PLAYH \ ROWPX       ' 112 scanlines down
CONST FONTN = 7, FW = 6, FH = 8   ' font 7 is the 6 x 8 one
CONST FRAMEMS = 33                ' about 30 frames a second

' --------------------------------------------------------------- world
'  The world is 184 columns wide and the original wraps X at its edge.
'  We do not need to: the widest cave is 137 columns and the camera is
'  held inside it, so no view ever straddles the seam.  gen_terrain.py
'  --stats reports the span, and would say so if that stopped being true.
CONST WORLDC = 184
CONST MAXROW = 1400               ' the deepest level is 1262 scanlines
CONST NLEVEL = 6

DIM INTEGER wallL(MAXROW), wallR(MAXROW)
DIM INTEGER depth, level, colLand, colObj, colBack
DIM FLOAT camX
DIM INTEGER camY
DIM INTEGER pal(15)
DIM INTEGER kUp, kDown, kLeft, kRight, kNext, kPrev, kQuit, kShot
DIM INTEGER nBox, drawMs
DIM INTEGER nextFrame, t0
DIM INTEGER caveTop

' ======================================================================
'  main
' ======================================================================
Setup
Benchmark
LoadLevel 4
nextFrame = TIMER + FRAMEMS
DO
  ReadKeys
  IF kQuit <> 0 THEN EXIT DO
  IF kNext <> 0 THEN LoadLevel((level + 1) MOD NLEVEL)
  IF kPrev <> 0 THEN LoadLevel((level + NLEVEL - 1) MOD NLEVEL)
  IF kShot <> 0 THEN SAVE IMAGE "A:/thrust.bmp"


  IF kLeft <> 0 THEN camX = camX - 1.5
  IF kRight <> 0 THEN camX = camX + 1.5
  IF kUp <> 0 THEN camY = camY - 3
  IF kDown <> 0 THEN camY = camY + 3
  ClampCamera

  t0 = TIMER
  DrawWorld
  DrawPanel
  FRAMEBUFFER COPY F, N
  drawMs = TIMER - t0

  DO WHILE TIMER < nextFrame : LOOP
  nextFrame = nextFrame + FRAMEMS
LOOP
FRAMEBUFFER WRITE N
CLS RGB(BLACK)
PRINT "Thrust phase 2 - landscape only."
END

' ======================================================================
'  one-time set-up
' ======================================================================
SUB Setup
  IF MM.HRES <> 320 OR MM.VRES <> 240 THEN
    ON ERROR SKIP 1
    MODE 2
  ENDIF
  IF MM.HRES <> 320 OR MM.VRES <> 240 THEN
    ON ERROR CLEAR
    PRINT "Thrust needs a 320 x 240 screen (MODE 2)."
    PRINT "This display is"; MM.HRES; " x"; MM.VRES
    END
  ENDIF
  ON ERROR CLEAR

  ' The BBC's eight physical colours, in the order the palette table
  ' uses them: black, red, green, yellow, blue, magenta, cyan, white.
  pal(0) = RGB(BLACK)   : pal(1) = RGB(RED)     : pal(2) = RGB(GREEN)
  pal(3) = RGB(YELLOW)  : pal(4) = RGB(BLUE)    : pal(5) = RGB(MAGENTA)
  pal(6) = RGB(CYAN)    : pal(7) = RGB(WHITE)
  colBack = RGB(BLACK)

  ON ERROR SKIP 1
  FRAMEBUFFER CREATE
  ON ERROR CLEAR
  FRAMEBUFFER WRITE F
  CLS RGB(BLACK)
END SUB

' ======================================================================
'  a level
'
'  The terrain is (count, increment) pairs, one step to a scanline.
'  initialise_landscape starts the left wall at 0 and the right at $FF -
'  off the right of the world, so the sky is open - and both decoders
'  begin at segment 1, so segment 0 is never read.  Skipping it is not
'  an optimisation: read it and the cave lands 255 scanlines below every
'  object on the level.
' ======================================================================
SUB LoadLevel(lv AS INTEGER)
  LOCAL INTEGER i, j, k, nL, nR, c, inc, x, n, dL, dR

  level = lv
  RESTORE trndata
  FOR i = 0 TO lv - 1
    READ nL, nR
    FOR j = 1 TO (nL + nR) * 2 : READ c : NEXT j
  NEXT i
  READ nL, nR

  x = 0 : n = 0
  FOR j = 0 TO nL - 1
    READ c, inc
    IF j > 0 THEN
      FOR k = 1 TO c
        x = (x + inc) AND 255
        IF n <= MAXROW THEN wallL(n) = x
        n = n + 1
      NEXT k
    ENDIF
  NEXT j
  dL = n

  x = 255 : n = 0
  FOR j = 0 TO nR - 1
    READ c, inc
    IF j > 0 THEN
      FOR k = 1 TO c
        x = (x + inc) AND 255
        IF n <= MAXROW THEN wallR(n) = x
        n = n + 1
      NEXT k
    ENDIF
  NEXT j
  dR = n

  depth = dL
  IF dR < depth THEN depth = dR
  IF depth > MAXROW THEN depth = MAXROW

  RESTORE palfdata
  FOR i = 0 TO lv
    READ j, k
  NEXT i
  colLand = pal(j)
  colObj = pal(k)

  ' start looking at the top of the cave
  caveTop = 0
  FOR i = 1 TO depth - 1
    IF wallL(i) <> wallL(0) OR wallR(i) <> wallR(0) THEN
      caveTop = i
      EXIT FOR
    ENDIF
  NEXT i
  camY = caveTop - 8
  camX = (wallL(camY + VIEWR \ 2) + wallR(camY + VIEWR \ 2)) / 2 - VIEWC \ 2
  ClampCamera
END SUB

' ======================================================================
'  Spike S1, run at startup so the numbers are never guessed at.
'
'  Fly the camera down every level a scanline at a time, drawing every
'  frame exactly as the game will, and report what it cost.  The plan
'  predicted a worst frame of 112 boxes from the terrain data alone; this
'  is the same question asked of the board.
' ======================================================================
SUB Benchmark
  LOCAL INTEGER lv, y, n, tot, mx, t, ms, msMax, msTot
  FRAMEBUFFER WRITE N
  CLS RGB(BLACK)
  PRINT "Thrust phase 2 - landscape renderer"
  PRINT
  PRINT "lvl  frames   box avg  max    ms avg  max   fps"
  FOR lv = 0 TO NLEVEL - 1
    LoadLevel lv
    FRAMEBUFFER WRITE F
    n = 0 : tot = 0 : mx = 0 : msTot = 0 : msMax = 0
    FOR y = caveTop - VIEWR TO depth - VIEWR
      IF y >= 0 THEN
        camY = y
        t = TIMER
        DrawWorld
        FRAMEBUFFER COPY F, N
        ms = TIMER - t
        n = n + 1 : tot = tot + nBox : msTot = msTot + ms
        IF nBox > mx THEN mx = nBox
        IF ms > msMax THEN msMax = ms
      ENDIF
    NEXT y
    FRAMEBUFFER WRITE N
    PRINT STR$(lv, 3); STR$(n, 8); STR$(tot \ n, 10); STR$(mx, 5);
    PRINT STR$(msTot / n, 10, 1); STR$(msMax, 5); STR$(n * 1000 \ msTot, 6)
  NEXT lv
  PRINT
  PRINT "any key for the camera"
  DO WHILE INKEY$ = "" : LOOP
  FRAMEBUFFER WRITE F
END SUB

SUB ClampCamera
  IF camY < 0 THEN camY = 0
  IF camY > depth - VIEWR THEN camY = depth - VIEWR
  IF camX < -VIEWC THEN camX = -VIEWC
  IF camX > WORLDC + VIEWC THEN camX = WORLDC + VIEWC
END SUB

' ======================================================================
'  the landscape
'
'  Fill the playfield with rock, then punch the cave out of it.  One box
'  per run of scanlines that share a wall pair; nBox counts them so the
'  panel can show what the frame actually cost.
' ======================================================================
SUB DrawWorld
  LOCAL INTEGER row, wy, l, r, pl, pr, start, y, h, lx, rx

  BOX 0, PLAYTOP, SCRW, PLAYH, 0, colLand, colLand
  nBox = 0
  pl = -1 : pr = -1 : start = 0
  FOR row = 0 TO VIEWR
    wy = camY + row
    IF row = VIEWR OR wy < 0 OR wy >= depth THEN
      l = -1 : r = -1
    ELSE
      l = wallL(wy) : r = wallR(wy)
    ENDIF
    IF (l <> pl) OR (r <> pr) THEN
      IF pl >= 0 AND row > start THEN
        lx = INT((pl - camX) * COLPX)
        rx = INT((pr - camX) * COLPX)
        IF lx < 0 THEN lx = 0
        IF rx > SCRW THEN rx = SCRW
        IF rx > lx THEN
          y = PLAYTOP + start * ROWPX
          h = (row - start) * ROWPX
          BOX lx, y, rx - lx, h, 0, colBack, colBack
          nBox = nBox + 1
        ENDIF
      ENDIF
      pl = l : pr = r : start = row
    ENDIF
  NEXT row
END SUB

SUB DrawPanel
  LOCAL s$ LENGTH 48
  BOX 0, 0, SCRW, PANELH, 0, RGB(BLACK), RGB(BLACK)
  s$ = "LEVEL " + STR$(level) + "  X" + STR$(INT(camX)) + " Y" + STR$(camY)
  TEXT 2, 4, s$, "LT", FONTN, 1, colLand, RGB(BLACK)
  s$ = STR$(nBox) + " BOX " + STR$(drawMs) + "MS"
  IF drawMs > 0 THEN s$ = s$ + " " + STR$(1000 \ drawMs) + "FPS"
  TEXT SCRW - 2, 4, s$, "RT", FONTN, 1, RGB(WHITE), RGB(BLACK)
END SUB

' ======================================================================
'  keyboard
'
'  KEYDOWN(0) gives the number of keys held and KEYDOWN(1..6) the
'  character of each.  Every KEYDOWN call also empties the console input
'  buffer, so INKEY$ has to be read first or it never sees anything.
' ======================================================================
SUB ReadKeys
  LOCAL INTEGER i, k
  LOCAL ky$ LENGTH 2
  kUp = 0 : kDown = 0 : kLeft = 0 : kRight = 0
  kNext = 0 : kPrev = 0 : kQuit = 0 : kShot = 0
  ky$ = INKEY$
  IF ky$ = CHR$(27) THEN kQuit = 1
  IF ky$ = "n" OR ky$ = "N" THEN kNext = 1
  IF ky$ = "p" OR ky$ = "P" THEN kPrev = 1
  IF ky$ = "s" OR ky$ = "S" THEN kShot = 1
  FOR i = 1 TO 6
    k = KEYDOWN(i)
    SELECT CASE k
      CASE 128 : kUp = 1
      CASE 129 : kDown = 1
      CASE 130 : kLeft = 1
      CASE 131 : kRight = 1
      CASE 110, 78 : kNext = 1
      CASE 112, 80 : kPrev = 1
      CASE 115, 83 : kShot = 1
      CASE 27 : kQuit = 1
    END SELECT
  NEXT i
END SUB

' ======================================================================
'  Terrain
'  Per level: the count of left and right segments, then count and
'  increment pairs for the left wall and then for the right.  One
'  step of a pair is one terrain scanline and the increment is added
'  to that wall's X each step.  Decoded at level load into wallL()
'  and wallR().
' ======================================================================
trndata:
' level 0 - 692 scanlines deep
DATA 9, 7
DATA 255,0, 255,0, 171,0, 1,85, 15,1, 1,21, 12,1, 1,25
DATA 255,0
DATA 255,0, 255,0, 171,0, 1,-73, 9,-1, 1,-15, 255,0
' level 1 - 833 scanlines deep
DATA 13, 10
DATA 255,0, 255,0, 175,0, 1,74, 11,1, 1,25, 23,1, 54,0
DATA 23,-1, 20,0, 15,1, 1,20, 255,0
DATA 255,0, 255,0, 175,0, 1,-76, 27,-1, 58,0, 17,1, 21,0
DATA 24,-1, 255,0
' level 2 - 929 scanlines deep
DATA 16, 17
DATA 255,0, 255,0, 185,0, 1,-121, 80,0, 10,-1, 50,0, 1,-30
DATA 10,-1, 30,0, 1,-15, 10,-1, 85,0, 10,1, 1,21, 255,0
DATA 255,0, 255,0, 185,0, 1,-76, 19,0, 1,-23, 60,0, 1,24
DATA 20,0, 10,-1, 1,-20, 60,0, 1,-30, 50,0, 1,-20, 9,-1
DATA 255,0
' level 3 - 1229 scanlines deep
DATA 22, 15
DATA 255,0, 255,0, 160,0, 1,90, 19,1, 1,17, 21,0, 38,-1
DATA 20,0, 10,1, 6,0, 20,-1, 34,0, 1,25, 20,1, 1,33
DATA 38,0, 28,-1, 36,0, 10,1, 255,0, 255,0
DATA 255,0, 255,0, 160,0, 1,-115, 103,0, 1,-30, 18,0, 24,1
DATA 1,40, 132,0, 24,-1, 20,0, 1,-12, 255,0, 255,0
' level 4 - 1174 scanlines deep
DATA 29, 26
DATA 255,0, 255,0, 165,0, 1,88, 21,1, 22,0, 1,23, 56,0
DATA 1,-10, 12,-1, 28,0, 1,10, 40,0, 20,-1, 1,-20, 86,0
DATA 20,1, 14,0, 1,-10, 28,0, 12,1, 1,18, 30,0, 12,1
DATA 1,20, 82,0, 8,1, 1,10, 255,0
DATA 255,0, 255,0, 165,0, 1,-109, 100,0, 1,14, 10,1, 30,0
DATA 1,-36, 40,0, 1,8, 40,0, 10,-1, 1,-34, 34,0, 32,1
DATA 44,0, 1,10, 10,1, 22,0, 1,16, 62,0, 16,1, 30,0
DATA 12,-1, 255,0
' level 5 - 1262 scanlines deep
DATA 23, 30
DATA 255,0, 255,0, 127,0, 1,77, 62,0, 1,23, 80,1, 40,0
DATA 1,-20, 10,-1, 162,0, 1,-17, 54,0, 13,-1, 20,0, 54,1
DATA 14,0, 13,-1, 31,0, 10,-1, 57,0, 1,11, 255,0
DATA 255,0, 255,0, 127,0, 1,-73, 43,-1, 20,0, 55,1, 65,0
DATA 20,1, 20,0, 1,-25, 28,-1, 34,0, 18,1, 20,0, 10,-1
DATA 50,0, 1,-21, 39,0, 44,1, 30,0, 7,1, 7,-1, 56,0
DATA 28,-1, 35,0, 1,13, 22,0, 1,-15, 255,0

' ======================================================================
'  Objects
'  Per level: how many, then x, y, type, gun parameter for each.
'  x is a world column and y a world scanline.  Types are
'    0-3 gun up-right, down-right, up-left, down-left
'    4 fuel   5 pod on its stand   6 reactor
'    7-8 door switch right, left
'  Then the width and height of each type, in world units.
' ======================================================================
objdata:
' level 0
DATA 4
DATA 143,  445, 5,  0       ' pod on its stand
DATA 160,  427, 6,  0       ' reactor
DATA 110,  435, 4,  0       ' fuel
DATA 125,  443, 0, 30       ' gun up-right
' level 1
DATA 5
DATA 127,  568, 5,  0       ' pod on its stand
DATA 100,  433, 6,  0       ' reactor
DATA 139,  571, 4,  0       ' fuel
DATA 116,  532, 1,  6       ' gun down-right
DATA 158,  522, 3, 15       ' gun down-left
' level 2
DATA 13
DATA  78,  718, 5,  0       ' pod on its stand
DATA 164,  451, 6,  0       ' reactor
DATA 120,  433, 4,  0       ' fuel
DATA 151,  545, 4,  0       ' fuel
DATA 157,  545, 4,  0       ' fuel
DATA 163,  545, 4,  0       ' fuel
DATA 125,  606, 4,  0       ' fuel
DATA 103,  657, 4,  0       ' fuel
DATA  93,  663, 2, 27       ' gun up-left
DATA  62,  626, 1,  6       ' gun down-right
DATA  88,  584, 1, 10       ' gun down-right
DATA 171,  542, 2, 22       ' gun up-left
DATA 129,  522, 1,  4       ' gun down-right
' level 3
DATA 12
DATA 142,  729, 5,  0       ' pod on its stand
DATA  91,  576, 6,  0       ' reactor
DATA 172,  593, 8,  0       ' door switch left
DATA 172,  647, 8,  0       ' door switch left
DATA 146,  599, 4,  0       ' fuel
DATA 114,  464, 1,  6       ' gun down-right
DATA  90,  513, 0,  6       ' gun up-right
DATA  90,  534, 1,  6       ' gun down-right
DATA 120,  548, 3, 18       ' gun down-left
DATA 109,  588, 0, 31       ' gun up-right
DATA 138,  658, 1,  6       ' gun down-right
DATA 162,  698, 2, 30       ' gun up-left
' level 4
DATA 19
DATA 162,  909, 5,  0       ' pod on its stand
DATA 143,  553, 6,  0       ' reactor
DATA 164,  805, 8,  0       ' door switch left
DATA 152,  885, 7,  0       ' door switch right
DATA 124,  457, 4,  0       ' fuel
DATA 154,  555, 4,  0       ' fuel
DATA 160,  555, 4,  0       ' fuel
DATA 104,  647, 4,  0       ' fuel
DATA 105,  778, 4,  0       ' fuel
DATA 111,  778, 4,  0       ' fuel
DATA 137,  821, 4,  0       ' fuel
DATA 143,  821, 4,  0       ' fuel
DATA 114,  525, 1,  5       ' gun down-right
DATA 162,  524, 3, 20       ' gun down-left
DATA 134,  643, 2, 26       ' gun up-left
DATA  93,  772, 0,  2       ' gun up-right
DATA 142,  768, 3, 18       ' gun down-left
DATA 123,  815, 0, 30       ' gun up-right
DATA 172,  867, 3, 25       ' gun down-left
' level 5
DATA 17
DATA 154,  996, 5,  0       ' pod on its stand
DATA 169, 1028, 6,  0       ' reactor
DATA 161,  920, 7,  0       ' door switch right
DATA 190,  861, 8,  0       ' door switch left
DATA 154,  760, 4,  0       ' fuel
DATA 193,  599, 4,  0       ' fuel
DATA 175,  959, 2, 26       ' gun up-left
DATA 155,  940, 1,  6       ' gun down-right
DATA 162,  902, 1,  9       ' gun down-right
DATA 155,  814, 3, 18       ' gun down-left
DATA 123,  799, 1,  6       ' gun down-right
DATA 172,  705, 2, 22       ' gun up-left
DATA 172,  680, 3, 18       ' gun down-left
DATA 172,  615, 2, 27       ' gun up-left
DATA 202,  574, 3, 18       ' gun down-left
DATA 153,  569, 1,  5       ' gun down-right
DATA 153,  460, 3, 14       ' gun down-left
' width, height of each object type
objsize:
DATA 5,  8                 ' gun up-right
DATA 5,  8                 ' gun down-right
DATA 5,  8                 ' gun up-left
DATA 5,  8                 ' gun down-left
DATA 4, 10                 ' fuel
DATA 5,  8                 ' pod on its stand
DATA 5, 10                 ' reactor
DATA 2,  8                 ' door switch right
DATA 2,  8                 ' door switch left

' ======================================================================
'  Sprites
'  Per shape: name, width, height, then one string per row holding
'  two bits per pixel - logical colour 0 to 3, one hex digit to two
'  pixels, leftmost pixel first.  Colour 1 is the ship's yellow, 2
'  the landscape colour and 3 the object colour; the last two are
'  set per level from the palette table below.
'  Ship shapes 0 to 16 are headings 0 to 16 and share one box, so
'  they can be swapped without the ship shifting; headings 17 to 31
'  are shape 32-n mirrored.
' ======================================================================
sprdata:
DATA "ship0", 18, 20
DATA "000100000"
DATA "000440000"
DATA "000440000"
DATA "001010000"
DATA "001010000"
DATA "004004000"
DATA "004004000"
DATA "010001000"
DATA "010001000"
DATA "140000500"
DATA "400000040"
DATA "100000100"
DATA "040000400"
DATA "040540400"
DATA "011011000"
DATA "004004000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship1", 18, 20
DATA "000010000"
DATA "000044000"
DATA "000104000"
DATA "000404000"
DATA "000404000"
DATA "001001000"
DATA "004001000"
DATA "004001000"
DATA "150001000"
DATA "400001000"
DATA "100000500"
DATA "100000040"
DATA "040000100"
DATA "041500400"
DATA "014041000"
DATA "000014000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship2", 18, 20
DATA "000005000"
DATA "000011000"
DATA "000041000"
DATA "000501000"
DATA "001001000"
DATA "004001000"
DATA "150001000"
DATA "400001000"
DATA "400001000"
DATA "100001000"
DATA "100000400"
DATA "040000100"
DATA "045400400"
DATA "010105000"
DATA "000110000"
DATA "000040000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship3", 18, 20
DATA "000000000"
DATA "000000500"
DATA "000005100"
DATA "000050100"
DATA "000100100"
DATA "051400100"
DATA "104000400"
DATA "100000400"
DATA "100000400"
DATA "100000400"
DATA "100001000"
DATA "054000400"
DATA "001000100"
DATA "000400500"
DATA "000415000"
DATA "000140000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship4", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000540"
DATA "000015040"
DATA "010140040"
DATA "044400100"
DATA "041000100"
DATA "040000100"
DATA "100000400"
DATA "100000400"
DATA "100001000"
DATA "050004000"
DATA "004001000"
DATA "001000400"
DATA "001015000"
DATA "000540000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship5", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "014001550"
DATA "011154010"
DATA "040400040"
DATA "040000040"
DATA "040000100"
DATA "100000100"
DATA "100000400"
DATA "050001000"
DATA "004001000"
DATA "001004000"
DATA "001001000"
DATA "001001000"
DATA "000554000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship6", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "001000000"
DATA "004400000"
DATA "010155554"
DATA "010000004"
DATA "040000010"
DATA "100000040"
DATA "050000100"
DATA "004000100"
DATA "004000400"
DATA "004001000"
DATA "010004000"
DATA "005004000"
DATA "000504000"
DATA "000050000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship7", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000400000"
DATA "001100000"
DATA "004100000"
DATA "010055400"
DATA "040000154"
DATA "040000001"
DATA "010000004"
DATA "004000010"
DATA "004000140"
DATA "004000400"
DATA "010005000"
DATA "010010000"
DATA "005010000"
DATA "000510000"
DATA "000040000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship8", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000100000"
DATA "000440000"
DATA "005040000"
DATA "010014000"
DATA "040001400"
DATA "010000140"
DATA "004000014"
DATA "004000001"
DATA "004000014"
DATA "010000140"
DATA "040001400"
DATA "010014000"
DATA "005040000"
DATA "000440000"
DATA "000100000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship9", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000040000"
DATA "000510000"
DATA "005010000"
DATA "010010000"
DATA "010005000"
DATA "004000400"
DATA "004000140"
DATA "004000010"
DATA "010000004"
DATA "040000001"
DATA "040000154"
DATA "010055400"
DATA "004100000"
DATA "001100000"
DATA "000400000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship10", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000050000"
DATA "000504000"
DATA "005004000"
DATA "010004000"
DATA "004001000"
DATA "004000400"
DATA "004000100"
DATA "050000100"
DATA "100000040"
DATA "040000010"
DATA "010000004"
DATA "010155554"
DATA "004400000"
DATA "001000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship11", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000554000"
DATA "001001000"
DATA "001001000"
DATA "001004000"
DATA "004001000"
DATA "050001000"
DATA "100000400"
DATA "100000100"
DATA "040000100"
DATA "040000040"
DATA "040400040"
DATA "011154010"
DATA "014001550"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship12", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000540000"
DATA "001015000"
DATA "001000400"
DATA "004001000"
DATA "050004000"
DATA "100001000"
DATA "100000400"
DATA "100000400"
DATA "040000100"
DATA "041000100"
DATA "044400100"
DATA "010140040"
DATA "000015040"
DATA "000000540"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "ship13", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000140000"
DATA "000415000"
DATA "000400500"
DATA "001000100"
DATA "054000400"
DATA "100001000"
DATA "100000400"
DATA "100000400"
DATA "100000400"
DATA "104000400"
DATA "051400100"
DATA "000100100"
DATA "000050100"
DATA "000005100"
DATA "000000500"
DATA "000000000"
DATA "000000000"
DATA "ship14", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000040000"
DATA "000110000"
DATA "010105000"
DATA "045400400"
DATA "040000100"
DATA "100000400"
DATA "100001000"
DATA "400001000"
DATA "400001000"
DATA "150001000"
DATA "004001000"
DATA "001001000"
DATA "000501000"
DATA "000041000"
DATA "000011000"
DATA "000005000"
DATA "000000000"
DATA "ship15", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000014000"
DATA "014041000"
DATA "041500400"
DATA "040000100"
DATA "100000040"
DATA "100000500"
DATA "400001000"
DATA "150001000"
DATA "004001000"
DATA "004001000"
DATA "001001000"
DATA "000404000"
DATA "000404000"
DATA "000104000"
DATA "000044000"
DATA "000010000"
DATA "ship16", 18, 20
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "000000000"
DATA "004004000"
DATA "011011000"
DATA "040540400"
DATA "040000400"
DATA "100000100"
DATA "400000040"
DATA "140000500"
DATA "010001000"
DATA "010001000"
DATA "004004000"
DATA "004004000"
DATA "001010000"
DATA "001010000"
DATA "000440000"
DATA "000440000"
DATA "000100000"
DATA "pod", 11, 11
DATA "005400"
DATA "050140"
DATA "100010"
DATA "100010"
DATA "400004"
DATA "400004"
DATA "400004"
DATA "100010"
DATA "100010"
DATA "050140"
DATA "005400"
DATA "shield", 17, 17
DATA "000554000"
DATA "005001400"
DATA "010000100"
DATA "040000040"
DATA "100000010"
DATA "100000010"
DATA "400000004"
DATA "400000004"
DATA "400000004"
DATA "400000004"
DATA "400000004"
DATA "100000010"
DATA "100000010"
DATA "040000040"
DATA "010000100"
DATA "005001400"
DATA "000554000"
DATA "gun_up_right", 20, 14
DATA "003C3FC000"
DATA "03C3C03C00"
DATA "3C003C0300"
DATA "C00003C0C0"
DATA "FFFF003CC0"
DATA "0000FC03C0"
DATA "000003C03C"
DATA "0000003C03"
DATA "0000000303"
DATA "00000000C3"
DATA "00000000C3"
DATA "0000000033"
DATA "0000000033"
DATA "000000000F"
DATA "gun_down_right", 20, 13
DATA "000000003F"
DATA "0000000033"
DATA "00000000C3"
DATA "00000000C3"
DATA "0000000303"
DATA "0000003C03"
DATA "000003C03C"
DATA "0000FC03C0"
DATA "FFFF003CC0"
DATA "C00003C0C0"
DATA "3C003C0300"
DATA "03C3C03C00"
DATA "003C3FC000"
DATA "gun_up_left", 20, 14
DATA "0003FC3C00"
DATA "003C03C3C0"
DATA "00C03C003C"
DATA "0303C00003"
DATA "033C00FFFF"
DATA "03C03F0000"
DATA "3C03C00000"
DATA "C03C000000"
DATA "C0C0000000"
DATA "C300000000"
DATA "C300000000"
DATA "CC00000000"
DATA "CC00000000"
DATA "F000000000"
DATA "gun_down_left", 20, 13
DATA "FC00000000"
DATA "CC00000000"
DATA "C300000000"
DATA "C300000000"
DATA "C0C0000000"
DATA "C03C000000"
DATA "3C03C00000"
DATA "03C03F0000"
DATA "033C00FFFF"
DATA "0303C00003"
DATA "00C03C003C"
DATA "003C03C3C0"
DATA "0003FC3C00"
DATA "fuel", 16, 13
DATA "15555554"
DATA "40000001"
DATA "4A222881"
DATA "48222081"
DATA "4A222881"
DATA "48222081"
DATA "482A28A1"
DATA "40000001"
DATA "14000014"
DATA "01555540"
DATA "00C00300"
DATA "03C003C0"
DATA "030000C0"
DATA "pod_stand", 11, 19
DATA "00FC00"
DATA "0F03C0"
DATA "300030"
DATA "300030"
DATA "C0000C"
DATA "C0000C"
DATA "C0000C"
DATA "300030"
DATA "300030"
DATA "0F03C0"
DATA "00FC00"
DATA "040040"
DATA "115510"
DATA "100010"
DATA "050140"
DATA "004400"
DATA "004400"
DATA "004400"
DATA "010100"
DATA "generator", 20, 17
DATA "00155554FC"
DATA "01400001CC"
DATA "04000000CC"
DATA "10000000CC"
DATA "10000000CC"
DATA "40000000CD"
DATA "40000000CD"
DATA "40000000CD"
DATA "40000000CD"
DATA "10000000CC"
DATA "10000000CC"
DATA "04000000CC"
DATA "FFFFFFFFCF"
DATA "C000000003"
DATA "CA00000003"
DATA "CA00000003"
DATA "CA00000003"
DATA "door_switch_right", 8, 14
DATA "5400"
DATA "0140"
DATA "0010"
DATA "0004"
DATA "0004"
DATA "0001"
DATA "0001"
DATA "0001"
DATA "0001"
DATA "0004"
DATA "0004"
DATA "0010"
DATA "0140"
DATA "5400"
DATA "door_switch_left", 8, 14
DATA "0015"
DATA "0140"
DATA "0400"
DATA "1000"
DATA "1000"
DATA "4000"
DATA "4000"
DATA "4000"
DATA "4000"
DATA "1000"
DATA "1000"
DATA "0400"
DATA "0140"
DATA "0015"
DATA "", 0, 0

' Per level: the physical colour of logical colour 2 (the
' landscape) and 3 (the objects).  0 black 1 red 2 green
' 3 yellow 4 blue 5 magenta 6 cyan 7 white.
palfdata:
DATA 1, 2                  ' level 0: red cave, green objects
DATA 2, 1                  ' level 1: green cave, red objects
DATA 6, 2                  ' level 2: cyan cave, green objects
DATA 2, 5                  ' level 3: green cave, magenta objects
DATA 1, 5                  ' level 4: red cave, magenta objects
DATA 5, 6                  ' level 5: magenta cave, cyan objects

' ======================================================================
'  Sound
'  The original's four envelopes and nine sound blocks.  PLAY BBC
'  ENVELOPE and PLAY BBC SOUND take the BBC's parameters unchanged,
'  so these are its numbers.  An amplitude of 1 to 4 selects an
'  envelope; a negative one is a plain volume.
' ======================================================================
'
'  Envelope 2 is not quite the original's bytes, and here is why.
'
'  Its block in the source is thirteen bytes, not fourteen - the ENVELOPE
'  calls are 14, 13 and 14 bytes apart - so OSWORD 8 read its last parameter
'  out of the first byte of envelope 3.  The bytes it does have are
'
'      02 02 FF 00 01 09 09 09 00 00 00 01 01  (+03 from its neighbour)
'
'  which is AA=0 rising to ALA=1: the attack never gets off zero, so the
'  note is silent for its whole five seconds.  That is deliberate.  The
'  explosion is two notes - a tone on channel 1 and noise pitch 7 on
'  channel 0 - and pitch 7 clocks the noise from channel 1's pitch.  So
'  channel 1 is not there to be heard; it is there to be swept, and the
'  pitch envelope (-1 for 9 steps, 0 for 9, +1 for 9, repeating) is what
'  bends the noise.  An amplitude of 0 would have set the pitch too, but it
'  could not have swept it.
'
'  What does not carry across is AR=1.  A positive release makes no sense
'  to the BBC, which stops a note when the release reaches zero, but our
'  engine adds AR each step and would ramp this note up to full volume and
'  leave it there.  AR, ALA and ALD are zeroed below so the note stays
'  silent and ends cleanly.  The pitch sweep, which is the whole point, is
'  untouched.
' ======================================================================
SUB SndInit
  ' 01 02 FB FD FB 02 03 32 7E F9 F9 F4 7E 00
  PLAY BBC ENVELOPE 1, 2, -5, -3, -5, 2, 3, 50, 126, -7, -7, -12, 126, 0
  ' 02 02 FF 00 01 09 09 09 00 00 00 01 01  (+03), AR/ALA/ALD zeroed
  PLAY BBC ENVELOPE 2, 2, -1, 0, 1, 9, 9, 9, 0, 0, 0, 0, 0, 0
  ' 03 04 00 00 00 01 01 01 7E FC FE FC 7E 6E
  PLAY BBC ENVELOPE 3, 4, 0, 0, 0, 1, 1, 1, 126, -4, -2, -4, 126, 110
  ' 04 01 FF FF FF 12 12 12 32 F4 F4 F4 6E 46
  PLAY BBC ENVELOPE 4, 1, -1, -1, -1, 18, 18, 18, 50, -12, -12, -12, 110, 70
END SUB

' ======================================================================
'  The nine sound blocks
' ======================================================================
' own_gun:      channel 2, flushed, envelope 1
'   the ship firing
SUB SndOwnGun
  PLAY BBC SOUND &H12, 1, 80, 2
END SUB

' explosion_1:  channel 1, flushed, envelope 2
'   explosion: the channel 1 tone that pitches the noise
SUB SndExplosion1
  PLAY BBC SOUND &H11, 2, 150, 100
END SUB

' explosion_2:  channel 0, flushed, envelope 3
'   explosion: the noise itself
SUB SndExplosion2
  PLAY BBC SOUND &H10, 3, 7, 100
END SUB

' hostile_gun:  channel 3, flushed, envelope 4
'   a limpet gun firing
SUB SndHostileGun
  PLAY BBC SOUND &H13, 4, 30, 20
END SUB

' collect_1:    channel 2, volume -15
'   picking something up
SUB SndCollect1
  PLAY BBC SOUND 2, -15, 190, 1
END SUB

' collect_2:    channel 2, silent
'   the second half of it
SUB SndCollect2
  PLAY BBC SOUND 2, 0, 190, 2
END SUB

' engine:       channel 0, flushed, volume -10
'   thrust, retriggered while the key is held
SUB SndEngine
  PLAY BBC SOUND &H10, -10, 5, 3
END SUB

' countdown:    channel 2, volume -15
'   the ten seconds after the reactor goes
SUB SndCountdown
  PLAY BBC SOUND 2, -15, 150, 1
END SUB

' enter_orbit:  channel 2, flushed, envelope 3
'   leaving the planet
SUB SndEnterOrbit
  PLAY BBC SOUND &H12, 3, 185, 1
END SUB
