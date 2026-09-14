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
