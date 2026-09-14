' =====================================================================
'  T H R U S T        PicoMite MMBasic
'  after the 1986 BBC Micro game by Jeremy C. Smith for Superior Software
'
'  Phase 3 of the port (see docs/Thrust_Port_Plan.html): the flight
'  model.  There is no pod and there are no objects yet - this is the
'  ship, gravity, thrust, and hitting the walls, which is the part the
'  whole port stands or falls on.
'
'  The physics is the original's, in its order and with its constants,
'  but in floating point rather than Q7.8: on this interpreter a float
'  costs what an integer costs, so there is nothing to be gained by
'  reproducing the fixed point, and a good deal of clarity to lose.
'  What does have to be copied exactly is the pair of angle tables.
'  They are an ellipse, 2.5 in Y against 1.25 in X, because MODE 1's
'  pixels were not square; work out SIN and COS instead and that
'  compensation is thrown away and the ship stops feeling right.
'
'  Timing is two clocks.  The original integrates position every frame
'  at 50 Hz and updates forces on six ticks in sixteen, and both of
'  those cadences are part of the feel, so the simulation runs at a
'  fixed 50 Hz off an accumulator while the screen is drawn at the 33 ms
'  we pace at.  Rescaling the constants to 30 Hz would not survive the
'  irregular tick pattern.
'
'  The cave is two numbers per scanline: the X of the left wall and the
'  X of the right, with open ground between.  So a frame is one fill of
'  the playfield in the landscape colour and then the cave punched out
'  of it in black.  Scanlines that share a wall pair collapse into one
'  box, which is what makes this affordable - punching out the cave
'  costs fewer boxes than drawing the two walls separately, because the
'  walls rarely change on the same scanline.  Measured over all six
'  levels: 93 boxes in the worst frame, and nearer twenty typically.
'
'  Units are the BBC's own throughout.  One terrain column is four
'  pixels across and one terrain scanline two pixels down; the game's
'  arithmetic stays in those units and only the drawing scales, which
'  is what keeps the angle tables correct.
'
'  Keys      Turn ........... left / right arrows
'            Thrust ......... up arrow, or SPACE
'            Level .......... N, P
'            Restart ........ R
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
'  The window Y in the original's level reset table sits 73 scanlines
'  above the top of the visible area - the $49 that landscape_draw adds.
CONST VIEWOFF = 73

' -------------------------------------------------------- flight model
CONST NANG = 32                   ' 32 headings, 11.25 degrees apart
CONST SIMPF = 50.0 / 30.30        ' simulation steps per drawn frame
CONST ROTMASK = 3                 ' rotate on three frames in four
CONST THRDIV = 16                 ' thrust is the table value over 16
CONST DRAGX = 64                  ' velX -= velX / 64   per active tick
CONST DRAGY = 256                 ' velY -= velY / 256  - weaker, because
                                  ' gravity is always adding to it
CONST NHULL = 8                   ' hull points tested against the walls
CONST HULLRX = 1.6                ' in columns
CONST HULLRY = 3.2                ' in scanlines
CONST FUEL0 = 999                 ' placeholder: the real economy is the
                                  ' tractor beam's, and arrives in phase 5

' ------------------------------------------------------------ sprites
CONST S_SHIP = 1                  ' buffers 1..17 are headings 0..16
' where the ship's centre of rotation sits in its sprite
' box, in pixels - see gen_sprites.py
CONST SHIPCX = 10
CONST SHIPCY = 9.5
CONST SHIPW = 21
CONST SHIPH = 20

' ======================================================================
'  globals
' ======================================================================
DIM INTEGER wallL(MAXROW), wallR(MAXROW)
DIM INTEGER depth, level, colLand, colObj, colBack
DIM FLOAT camX
DIM INTEGER camY
DIM INTEGER pal(15)
DIM INTEGER img(1023)
DIM hexd$ LENGTH 20

DIM FLOAT angX(NANG - 1), angY(NANG - 1)
DIM INTEGER actTick(15)
DIM FLOAT gravY, startX, startY
DIM INTEGER startCamY
DIM FLOAT shipX, shipY, velX, velY, simAcc
DIM FLOAT hullX(NHULL - 1), hullY(NHULL - 1)
DIM INTEGER shipAng, tick, fuel, crashed, deaths
DIM INTEGER kLeft, kRight, kThrust, kNext, kPrev, kQuit, kShot, kReset
DIM INTEGER nBox, drawMs
DIM INTEGER nextFrame, t0, caveTop

' ======================================================================
'  main
' ======================================================================
Setup
LoadLevel 0
nextFrame = TIMER + FRAMEMS
DO
  ReadKeys
  IF kQuit <> 0 THEN EXIT DO
  IF kNext <> 0 THEN LoadLevel((level + 1) MOD NLEVEL)
  IF kPrev <> 0 THEN LoadLevel((level + NLEVEL - 1) MOD NLEVEL)
  IF kReset <> 0 THEN StartShip
  IF kShot <> 0 THEN SAVE IMAGE "A:/thrust.bmp"

  ' The simulation runs at 50 Hz whatever the frame rate is.
  simAcc = simAcc + SIMPF
  DO WHILE simAcc >= 1
    SimStep
    simAcc = simAcc - 1
  LOOP
  FollowCamera

  t0 = TIMER
  DrawWorld
  DrawShip
  DrawPanel
  FRAMEBUFFER COPY F, N
  drawMs = TIMER - t0

  DO WHILE TIMER < nextFrame : LOOP
  nextFrame = nextFrame + FRAMEMS
LOOP
FRAMEBUFFER WRITE N
CLS RGB(BLACK)
PRINT "Thrust phase 3 - flight model."
END

' ======================================================================
'  one-time set-up
' ======================================================================
SUB Setup
  LOCAL INTEGER i, j
  LOCAL FLOAT a

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
  hexd$ = "0123456789ABCDEF"

  RESTORE angdata
  FOR i = 0 TO NANG - 1 : READ angX(i) : NEXT i
  FOR i = 0 TO NANG - 1 : READ angY(i) : NEXT i
  RESTORE tickdata
  FOR i = 0 TO 15 : actTick(i) = 0 : NEXT i
  FOR i = 0 TO 5
    READ j
    actTick(j) = 1
  NEXT i

  ' An octagon standing in for the ship's outline.  The real shape turns
  ' with the heading, but a ring this size is close enough to fly by and
  ' costs eight comparisons instead of a per-pixel test.
  FOR i = 0 TO NHULL - 1
    a = i * 2 * PI / NHULL
    hullX(i) = HULLRX * SIN(a)
    hullY(i) = -HULLRY * COS(a)
  NEXT i

  SPRITE CLOSE ALL
  LoadSprites
  ON ERROR SKIP 1
  FRAMEBUFFER CREATE
  ON ERROR CLEAR
  FRAMEBUFFER WRITE F
  CLS RGB(BLACK)
  SndInit
  deaths = 0
END SUB

' ----------------------------------------------------------------------
'  Sprites.  Two bits a pixel, one hex digit to two pixels, logical
'  colour 0 to 3; 1 is the ship's yellow.  Only the seventeen ship
'  headings are wanted yet - the objects come in phase 5 and need
'  reloading per level anyway, because 2 and 3 are level colours.
' ----------------------------------------------------------------------
SUB LoadSprites
  LOCAL INTEGER n, w, h, j, i, d, k, c
  LOCAL nm$ LENGTH 20
  LOCAL bits$ LENGTH 40
  RESTORE sprdata
  n = 0
  DO
    READ nm$, w, h
    IF nm$ = "" THEN EXIT DO
    n = n + 1
    IF n <= 17 THEN
      k = 0
      FOR j = 0 TO h - 1
        READ bits$
        FOR i = 0 TO w - 1
          d = INSTR(hexd$, MID$(bits$, i \ 2 + 1, 1)) - 1
          IF (i AND 1) = 0 THEN c = d \ 4 ELSE c = d AND 3
          IF c = 1 THEN img(k) = pal(3) ELSE img(k) = 0
          k = k + 1
        NEXT i
      NEXT j
      SPRITE LOADARRAY n, w, h, img()
    ELSE
      FOR j = 0 TO h - 1 : READ bits$ : NEXT j
    ENDIF
  LOOP
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

  RESTORE lvldata
  FOR i = 0 TO lv
    READ gravY, startX, startY, j, k
  NEXT i
  startCamY = k + VIEWOFF

  caveTop = 0
  FOR i = 1 TO depth - 1
    IF wallL(i) <> wallL(0) OR wallR(i) <> wallR(0) THEN
      caveTop = i
      EXIT FOR
    ENDIF
  NEXT i
  StartShip
END SUB

SUB StartShip
  shipX = startX : shipY = startY
  velX = 0 : velY = 0
  shipAng = 0 : tick = 0 : simAcc = 0
  fuel = FUEL0 : crashed = 0
  camY = startCamY
  camX = shipX - VIEWC \ 2
  ClampCamera
END SUB

SUB ClampCamera
  IF camY < 0 THEN camY = 0
  IF camY > depth - VIEWR THEN camY = depth - VIEWR
END SUB

' ======================================================================
'  the flight model
'
'  ship_input_rotate, midpoint_add_force_vector and then
'  ship_input_thrust_calculate_force, in that order: the force computed
'  at the end of one step is integrated at the start of the next, which
'  is the original's one-step-behind Euler.
' ======================================================================
SUB SimStep
  LOCAL INTEGER t

  IF crashed <> 0 THEN
    crashed = crashed - 1
    IF crashed = 0 THEN StartShip
    EXIT SUB
  ENDIF

  ' 1. rotation, rate limited to three frames in four.  That is 37.5
  '    steps a second and a full turn in under a second - the
  '    disassembly's notes say 8.4, but its own code is AND #3 / BEQ.
  IF (tick AND ROTMASK) <> 0 THEN
    IF kLeft <> 0 THEN shipAng = (shipAng + NANG - 1) AND (NANG - 1)
    IF kRight <> 0 THEN shipAng = (shipAng + 1) AND (NANG - 1)
  ENDIF

  ' 2. integrate - every step, not just the active ones
  shipX = shipX + velX
  shipY = shipY + velY

  ' 3. gravity, thrust and drag, on six ticks in sixteen
  t = tick AND 15
  IF actTick(t) <> 0 THEN
    velY = velY + gravY
    IF (kThrust <> 0) AND (fuel > 0) THEN
      ' The table's sign is the direction of flight: heading 0 is up and
      ' its Y entry is -2.5, and the 6502 adds it.  (The disassembly's
      ' own notes say the thrust is negated; the ADC says otherwise, and
      ' negating it would drive the ship backwards.)
      velX = velX + angX(shipAng) / THRDIV
      velY = velY + angY(shipAng) / THRDIV
      fuel = fuel - 1
      SndEngine
    ENDIF
    velX = velX - velX / DRAGX
    velY = velY - velY / DRAGY
  ENDIF
  tick = tick + 1

  IF HitWall() <> 0 THEN
    crashed = 40
    deaths = deaths + 1
    SndExplosion1
    SndExplosion2
  ENDIF
END SUB

' ----------------------------------------------------------------------
'  Collision.  The original got this free from XOR plotting and only
'  noticed a hit on the frame after it happened; eight points against
'  the wall arrays is both cheaper here and better behaved.
' ----------------------------------------------------------------------
FUNCTION HitWall() AS INTEGER
  LOCAL INTEGER i, wy
  LOCAL FLOAT wx
  HitWall = 1
  FOR i = 0 TO NHULL - 1
    wy = INT(shipY + hullY(i))
    IF wy < 0 OR wy >= depth THEN EXIT FUNCTION
    wx = shipX + hullX(i)
    IF wx < wallL(wy) THEN EXIT FUNCTION
    IF wx >= wallR(wy) THEN EXIT FUNCTION
  NEXT i
  HitWall = 0
END FUNCTION

' ----------------------------------------------------------------------
'  The camera keeps the ship inside a band rather than centred, which is
'  what the original's damped scroll amounts to once it settles.
' ----------------------------------------------------------------------
SUB FollowCamera
  LOCAL FLOAT r, c
  r = shipY - camY
  IF r > 80 THEN camY = camY + INT(r - 80)
  IF r < 47 THEN camY = camY + INT(r - 47)
  c = shipX - camX
  IF c > 46 THEN camX = camX + (c - 46)
  IF c < 34 THEN camX = camX + (c - 34)
  ClampCamera
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

' ----------------------------------------------------------------------
'  Headings 0 to 16 are their own sprite; 17 to 31 are 32-n drawn with
'  the horizontal mirror, which is exact because the shapes share a box
'  centred on the point the ship turns about.  Rotation 0 and 1 keep
'  transparency; 4 to 7 are the same mirrors without it.
' ----------------------------------------------------------------------
SUB DrawShip
  LOCAL INTEGER sx, sy, n, rot
  IF crashed <> 0 THEN
    IF (crashed AND 2) = 0 THEN EXIT SUB
  ENDIF
  sx = INT((shipX - camX) * COLPX) - SHIPCX
  sy = PLAYTOP + INT((shipY - camY) * ROWPX) - SHIPCY
  IF sx < -SHIPW OR sx > SCRW OR sy < PLAYTOP - SHIPH OR sy > SCRH THEN EXIT SUB
  IF shipAng <= 16 THEN
    n = S_SHIP + shipAng : rot = 0
  ELSE
    n = S_SHIP + NANG - shipAng : rot = 1
  ENDIF
  SPRITE WRITE n, sx, sy, rot
END SUB

SUB DrawPanel
  LOCAL s$ LENGTH 48
  BOX 0, 0, SCRW, PANELH, 0, RGB(BLACK), RGB(BLACK)
  s$ = "LEVEL " + STR$(level + 1) + "  FUEL " + STR$(fuel)
  IF deaths > 0 THEN s$ = s$ + "  CRASH " + STR$(deaths)
  TEXT 2, 4, s$, "LT", FONTN, 1, colLand, RGB(BLACK)
  s$ = STR$(nBox) + " BOX " + STR$(drawMs) + "MS"
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
  kLeft = 0 : kRight = 0 : kThrust = 0
  kNext = 0 : kPrev = 0 : kQuit = 0 : kShot = 0 : kReset = 0
  ky$ = INKEY$
  IF ky$ = CHR$(27) THEN kQuit = 1
  IF ky$ = "n" OR ky$ = "N" THEN kNext = 1
  IF ky$ = "p" OR ky$ = "P" THEN kPrev = 1
  IF ky$ = "s" OR ky$ = "S" THEN kShot = 1
  IF ky$ = "r" OR ky$ = "R" THEN kReset = 1
  IF ky$ = " " THEN kThrust = 1
  FOR i = 1 TO 6
    k = KEYDOWN(i)
    SELECT CASE k
      CASE 130, 122, 90  : kLeft = 1        ' left, Z
      CASE 131, 120, 88  : kRight = 1       ' right, X
      CASE 128, 32       : kThrust = 1      ' up, space
      CASE 110, 78       : kNext = 1
      CASE 112, 80       : kPrev = 1
      CASE 115, 83       : kShot = 1
      CASE 114, 82       : kReset = 1
      CASE 27            : kQuit = 1
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
'  Ship shapes 0 to 16 are headings 0 to 16 and share one box that
'  is symmetric about the ship's centre of rotation, so headings 17
'  to 31 are shape 32-n drawn with SPRITE's horizontal mirror and do
'  not shift.  The centre sits at SHIPCX, SHIPCY within that box.
' ======================================================================
sprdata:
DATA "ship0", 21, 20
DATA "00000400000"
DATA "00001100000"
DATA "00001100000"
DATA "00004040000"
DATA "00004040000"
DATA "00010010000"
DATA "00010010000"
DATA "00040004000"
DATA "00040004000"
DATA "00500001400"
DATA "01000000100"
DATA "00400000400"
DATA "00100001000"
DATA "00101501000"
DATA "00044044000"
DATA "00010010000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship1", 21, 20
DATA "00000040000"
DATA "00000110000"
DATA "00000410000"
DATA "00001010000"
DATA "00001010000"
DATA "00004004000"
DATA "00010004000"
DATA "00010004000"
DATA "00540004000"
DATA "01000004000"
DATA "00400001400"
DATA "00400000100"
DATA "00100000400"
DATA "00105401000"
DATA "00050104000"
DATA "00000050000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship2", 21, 20
DATA "00000014000"
DATA "00000044000"
DATA "00000104000"
DATA "00001404000"
DATA "00004004000"
DATA "00010004000"
DATA "00540004000"
DATA "01000004000"
DATA "01000004000"
DATA "00400004000"
DATA "00400001000"
DATA "00100000400"
DATA "00115001000"
DATA "00040414000"
DATA "00000440000"
DATA "00000100000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship3", 21, 20
DATA "00000000000"
DATA "00000001400"
DATA "00000014400"
DATA "00000140400"
DATA "00000400400"
DATA "00145000400"
DATA "00410001000"
DATA "00400001000"
DATA "00400001000"
DATA "00400001000"
DATA "00400004000"
DATA "00150001000"
DATA "00004000400"
DATA "00001001400"
DATA "00001054000"
DATA "00000500000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship4", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000001500"
DATA "00000054100"
DATA "00040500100"
DATA "00111000400"
DATA "00104000400"
DATA "00100000400"
DATA "00400001000"
DATA "00400001000"
DATA "00400004000"
DATA "00140010000"
DATA "00010004000"
DATA "00004001000"
DATA "00004054000"
DATA "00001500000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship5", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00050005540"
DATA "00044550040"
DATA "00101000100"
DATA "00100000100"
DATA "00100000400"
DATA "00400000400"
DATA "00400001000"
DATA "00140004000"
DATA "00010004000"
DATA "00004010000"
DATA "00004004000"
DATA "00004004000"
DATA "00001550000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship6", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00004000000"
DATA "00011000000"
DATA "00040555550"
DATA "00040000010"
DATA "00100000040"
DATA "00400000100"
DATA "00140000400"
DATA "00010000400"
DATA "00010001000"
DATA "00010004000"
DATA "00040010000"
DATA "00014010000"
DATA "00001410000"
DATA "00000140000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship7", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00001000000"
DATA "00004400000"
DATA "00010400000"
DATA "00040155000"
DATA "00100000550"
DATA "00100000004"
DATA "00040000010"
DATA "00010000040"
DATA "00010000500"
DATA "00010001000"
DATA "00040014000"
DATA "00040040000"
DATA "00014040000"
DATA "00001440000"
DATA "00000100000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship8", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000400000"
DATA "00001100000"
DATA "00014100000"
DATA "00040050000"
DATA "00100005000"
DATA "00040000500"
DATA "00010000050"
DATA "00010000004"
DATA "00010000050"
DATA "00040000500"
DATA "00100005000"
DATA "00040050000"
DATA "00014100000"
DATA "00001100000"
DATA "00000400000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship9", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000100000"
DATA "00001440000"
DATA "00014040000"
DATA "00040040000"
DATA "00040014000"
DATA "00010001000"
DATA "00010000500"
DATA "00010000040"
DATA "00040000010"
DATA "00100000004"
DATA "00100000550"
DATA "00040155000"
DATA "00010400000"
DATA "00004400000"
DATA "00001000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship10", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000140000"
DATA "00001410000"
DATA "00014010000"
DATA "00040010000"
DATA "00010004000"
DATA "00010001000"
DATA "00010000400"
DATA "00140000400"
DATA "00400000100"
DATA "00100000040"
DATA "00040000010"
DATA "00040555550"
DATA "00011000000"
DATA "00004000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship11", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00001550000"
DATA "00004004000"
DATA "00004004000"
DATA "00004010000"
DATA "00010004000"
DATA "00140004000"
DATA "00400001000"
DATA "00400000400"
DATA "00100000400"
DATA "00100000100"
DATA "00101000100"
DATA "00044550040"
DATA "00050005540"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship12", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00001500000"
DATA "00004054000"
DATA "00004001000"
DATA "00010004000"
DATA "00140010000"
DATA "00400004000"
DATA "00400001000"
DATA "00400001000"
DATA "00100000400"
DATA "00104000400"
DATA "00111000400"
DATA "00040500100"
DATA "00000054100"
DATA "00000001500"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "ship13", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000500000"
DATA "00001054000"
DATA "00001001400"
DATA "00004000400"
DATA "00150001000"
DATA "00400004000"
DATA "00400001000"
DATA "00400001000"
DATA "00400001000"
DATA "00410001000"
DATA "00145000400"
DATA "00000400400"
DATA "00000140400"
DATA "00000014400"
DATA "00000001400"
DATA "00000000000"
DATA "00000000000"
DATA "ship14", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000100000"
DATA "00000440000"
DATA "00040414000"
DATA "00115001000"
DATA "00100000400"
DATA "00400001000"
DATA "00400004000"
DATA "01000004000"
DATA "01000004000"
DATA "00540004000"
DATA "00010004000"
DATA "00004004000"
DATA "00001404000"
DATA "00000104000"
DATA "00000044000"
DATA "00000014000"
DATA "00000000000"
DATA "ship15", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000050000"
DATA "00050104000"
DATA "00105401000"
DATA "00100000400"
DATA "00400000100"
DATA "00400001400"
DATA "01000004000"
DATA "00540004000"
DATA "00010004000"
DATA "00010004000"
DATA "00004004000"
DATA "00001010000"
DATA "00001010000"
DATA "00000410000"
DATA "00000110000"
DATA "00000040000"
DATA "ship16", 21, 20
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00000000000"
DATA "00010010000"
DATA "00044044000"
DATA "00101501000"
DATA "00100001000"
DATA "00400000400"
DATA "01000000100"
DATA "00500001400"
DATA "00040004000"
DATA "00040004000"
DATA "00010010000"
DATA "00010010000"
DATA "00004040000"
DATA "00004040000"
DATA "00001100000"
DATA "00001100000"
DATA "00000400000"
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
'  Flight model
'  The 32 angle-to-force entries, as Q7.8 in the original: the X
'  component reaches 1.25 and the Y component 2.5, an ellipse rather
'  than a circle, because MODE 1's pixels are not square.  Copy them
'  rather than computing SIN and COS, or that compensation is lost.
'  Angle 0 points up, 8 right, 16 down, 24 left.
'  Then per level: gravity per active tick, the ship's starting
'  position and the camera's, in world units.
' ======================================================================
angdata:
' angle to x
DATA  0.00000,  0.24219,  0.47656,  0.69141,  0.88281,  1.03906,  1.15234,  1.22266
DATA  1.25000,  1.22266,  1.15234,  1.03906,  0.88281,  0.69141,  0.47656,  0.24219
DATA  0.00000, -0.24219, -0.47656, -0.69141, -0.88281, -1.03906, -1.15234, -1.22266
DATA -1.25000, -1.22266, -1.15234, -1.03906, -0.88281, -0.69141, -0.47656, -0.24219
' angle to y
DATA -2.50000, -2.44922, -2.30859, -2.07812, -1.76562, -1.38672, -0.95312, -0.48438
DATA  0.00000,  0.48438,  0.95312,  1.38672,  1.76562,  2.07812,  2.30859,  2.44922
DATA  2.50000,  2.44922,  2.30859,  2.07812,  1.76562,  1.38672,  0.95312,  0.48438
DATA  0.00000, -0.48438, -0.95312, -1.38672, -1.76562, -2.07812, -2.30859, -2.44922
' per level: gravity, ship x, ship y, camera x, camera y
lvldata:
DATA 0.0195312, 108,  401,  86,  292   ' level 0, 1 checkpoint
DATA 0.0273438, 108,  401,  86,  292   ' level 1, 1 checkpoint
DATA 0.0351562, 108,  401,  86,  292   ' level 2, 3 checkpoints
DATA 0.0429688, 108,  401,  86,  292   ' level 3, 3 checkpoints
DATA 0.0468750, 108,  401,  86,  292   ' level 4, 4 checkpoints
DATA 0.0507812, 108,  401,  86,  292   ' level 5, 5 checkpoints

' The six ticks in sixteen on which gravity, thrust and drag run.
tickdata:
DATA 0, 3, 5, 8, 11, 13

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
