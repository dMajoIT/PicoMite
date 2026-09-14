' =====================================================================
'  T H R U S T        PicoMite MMBasic
'  after the 1986 BBC Micro game by Jeremy C. Smith for Superior Software
'
'  Phase 5 of the port (see docs/Thrust_Port_Plan.html): the flight
'  model, the pod, and the rest of the world - fuel, limpet guns,
'  bullets and the reactor.
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
'            Tractor beam ... RETURN, or A  (also refuels)
'            Fire ........... down arrow, or F
'            Level .......... N, P
'            Restart ........ R
'            Screenshot ..... S  (to A:/thrust.bmp)
'
'  For testing: N and P change level, G puts the ship beside the pod with
'  it already attached, and B runs the entity benchmark - a full particle
'  pool and every object on the level, drawn and simulated flat out.
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
'  You start a game with an empty tank, which looks like a bug until you
'  notice where the ship is put down: directly above the first fuel cell.
'  You fall onto it, hold the tractor key, and fly off with a full tank.
'  add_fuel puts on $11 BCD a frame while the beam is on; use_fuel takes
'  one off per active tick, so a second of hovering buys half a minute.
CONST FUEL0 = 0
CONST FUELADD = 11                ' $11 BCD, per frame on the beam
CONST FUELMAX = 9999

' ------------------------------------------------------- the world
CONST MAXOBJ = 20                 ' nineteen is the most any level has
CONST OBJ_FUEL = 4
CONST OBJ_POD = 5
CONST OBJ_REACTOR = 6
CONST RHP0 = 50              ' $32, generator_total_damage
CONST CDOWN0 = 500             ' ten seconds at 50 Hz
CONST SCOREGUN = 75               ' obj_type_score_value, $75 BCD
CONST SCOREFUEL = 15

' --------------------------------------------------------- particles
'  Bullets and debris share one pool of 32 slots, as the original's does.
'  A bullet's velocity is the angle table itself, unscaled - five pixels
'  a step either way, which is quick.
CONST MAXPART = 32
CONST PT_PLAYER = 0
CONST PT_HOSTILE = 3
CONST PT_DEBRIS = 4
CONST PARTLIFE = 40               ' $28 ticks
CONST BULLETADV = 2               ' steps of head start, to clear the ship
CONST GUNPROB = 2                 ' in 256, per gun per step
CONST FGAP = 12                ' steps between the player's shots

' ------------------------------------------------------- the pod
'  The tether is a circle of radius 20 pixels.  That is not obvious from
'  the tables, which are an ellipse: the delta is four times the table
'  value, so five columns by ten scanlines - and a column is four pixels
'  against a scanline's two, which makes both twenty.  attach_pod_to_ship
'  scales its search vector by 4 in X and 2 in Y for the same reason.
CONST TETHK = 4                   ' delta is four times the angle table
CONST THRDIVPOD = 32              ' thrust is halved when towing the pod
CONST TETHDAMP = 64               ' angular velocity loses 1/64 a tick
CONST TETHTORQ = 32               ' tangential thrust over 32
'  Manhattan-ish distance from ship to pod, in pixels: min + 3 * max.
'  Get within BEAMDIST with the tractor key held and the beam shows; pull
'  out to GRABDIST and the pod lifts off its stand.  It reads backwards
'  until you notice that the second number is larger than the first, and
'  that both straddle the tether's own 40 pixel length.
CONST BEAMDIST = 117              ' $75
CONST GRABDIST = 132              ' $84
'  The pod is an eleven pixel sphere, so its radius is 1.4 columns one
'  way and 2.8 scanlines the other - the same distance, in the two units.
CONST PODRX = 1.4
CONST PODRY = 2.8

' ------------------------------------------------------------ sprites
CONST S_SHIP = 1                  ' buffers 1..17 are headings 0..16
CONST S_POD = 18                  ' then the pod and the shield
CONST S_SHIELD = 19
CONST NSPRLOAD = 19
CONST S_OBJ = 20                  ' and the nine object shapes, 20..28
' <<<GENERATED CONSTANTS>>>

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
DIM FLOAT midX, midY, podX, podY, podHomeX, podHomeY
DIM FLOAT tethAng, tethVel
DIM INTEGER podAtt, beamOn, hasPod, keepPod
DIM INTEGER nObj
DIM FLOAT objX(MAXOBJ - 1), objY(MAXOBJ - 1)
DIM INTEGER objT(MAXOBJ - 1), objG(MAXOBJ - 1), objLive(MAXOBJ - 1)
DIM INTEGER objW(8), objH(8)
DIM FLOAT paX(MAXPART - 1), paY(MAXPART - 1)
DIM FLOAT paDX(MAXPART - 1), paDY(MAXPART - 1)
DIM INTEGER paLife(MAXPART - 1), paType(MAXPART - 1)
DIM INTEGER score, reactorHP, countdown, fuelBeam, fireGap, nPart
DIM INTEGER shipAng, tick, fuel, crashed, deaths
DIM INTEGER kLeft, kRight, kThrust, kTract
DIM INTEGER kNext, kPrev, kQuit, kShot, kReset, kGrab, kFire, kBench
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
  IF kReset <> 0 THEN keepPod = 0 : StartShip
  IF kGrab <> 0 THEN GrabPod
  IF kBench <> 0 THEN Benchmark
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
  DrawObjects
  DrawPod
  DrawShip
  DrawParticles
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
  LoadSprites 1, NSPRLOAD
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
' Load the sprites.  first = 1 loads the ship, pod and shield, which are
' all the ship's yellow and never change; first = NSPRLOAD + 1 loads the
' nine object shapes, which are genuinely four-coloured and have to come
' back whenever the level's palette does.
SUB LoadSprites(first AS INTEGER, last AS INTEGER)
  LOCAL INTEGER n, w, h, j, i, d, k, c
  LOCAL nm$ LENGTH 20
  LOCAL bits$ LENGTH 40
  RESTORE sprdata
  n = 0
  DO
    READ nm$, w, h
    IF nm$ = "" THEN EXIT DO
    n = n + 1
    IF n >= first AND n <= last THEN
      k = 0
      FOR j = 0 TO h - 1
        READ bits$
        FOR i = 0 TO w - 1
          d = INSTR(hexd$, MID$(bits$, i \ 2 + 1, 1)) - 1
          IF (i AND 1) = 0 THEN c = d \ 4 ELSE c = d AND 3
          SELECT CASE c
            CASE 1 : img(k) = pal(3)      ' the ship's yellow
            CASE 2 : img(k) = colLand     ' this level's rock
            CASE 3 : img(k) = colObj      ' and its objects
            CASE ELSE : img(k) = 0
          END SELECT
          k = k + 1
        NEXT i
      NEXT j
      ON ERROR SKIP 1
      SPRITE CLOSE n
      ON ERROR CLEAR
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
  keepPod = 0
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

  ' The objects.  Their x and y are the sprite's plot origin, so they are
  ' kept as they come and the drawing does not shift them.  The pod is the
  ' exception: its sphere sits at pixel (9, 5) inside the pod_stand shape,
  ' which is 2.25 columns and 2.5 scanlines in, and that is where the
  ' tether has to reach.
  hasPod = 0
  nObj = 0
  RESTORE objdata
  FOR i = 0 TO lv
    READ n
    FOR j = 1 TO n
      READ c, inc, k, x
      IF i = lv AND nObj < MAXOBJ THEN
        objX(nObj) = c : objY(nObj) = inc
        objT(nObj) = k : objG(nObj) = x : objLive(nObj) = 1
        IF k = OBJ_POD THEN
          podHomeX = c + 2.25
          podHomeY = inc + 2.5
          hasPod = 1
        ENDIF
        nObj = nObj + 1
      ENDIF
    NEXT j
  NEXT i
  RESTORE objsize
  FOR i = 0 TO 8 : READ objW(i), objH(i) : NEXT i
  LoadSprites NSPRLOAD + 1, NSPRLOAD + 9

  caveTop = 0
  FOR i = 1 TO depth - 1
    IF wallL(i) <> wallL(0) OR wallR(i) <> wallR(0) THEN
      caveTop = i
      EXIT FOR
    ENDIF
  NEXT i
  reactorHP = RHP0
  StartShip
END SUB

SUB StartShip
  shipX = startX : shipY = startY
  midX = startX : midY = startY
  velX = 0 : velY = 0
  shipAng = 0 : tick = 0 : simAcc = 0
  fuel = FUEL0 : crashed = 0
  podAtt = 0 : beamOn = 0 : tethAng = 0 : tethVel = 0
  podX = podHomeX : podY = podHomeY
  countdown = 0 : fuelBeam = 0 : fireGap = 0
  FOR nPart = 0 TO MAXPART - 1 : paLife(nPart) = 0 : NEXT nPart
  nPart = 0
  ' Crash while carrying the pod and you get it back, hanging straight
  ' below - level_reset_with_pod_flag, and angle $01 for normal gravity.
  IF keepPod <> 0 THEN
    podAtt = 1 : beamOn = 1 : tethAng = 1
    midX = shipX : midY = shipY
    DeriveShip
  ENDIF
  camY = startCamY
  camX = shipX - VIEWC \ 2
  ClampCamera
END SUB

' ======================================================================
'  Spike S2: what a busy frame costs.
'
'  Every level in turn, with the pod on the tether, every object alive and
'  the particle pool completely full - 32 bullets and pieces of debris,
'  which in play only happens for a moment when something large explodes.
'  The simulation and the drawing are timed apart, because only one of
'  them can be moved off the frame if it comes to that.
' ======================================================================
SUB Benchmark
  LOCAL INTEGER lv, np
  FRAMEBUFFER WRITE N
  CLS RGB(BLACK)
  PRINT "Thrust S2 - the entity budget"
  PRINT
  PRINT "lvl  obj  part    sim ms   draw ms   total   fps"
  FOR lv = 0 TO NLEVEL - 1
    LoadLevel lv
    GrabPod
    BenchRun lv, 6
    BenchRun lv, MAXPART
  NEXT lv
  PRINT
  PRINT "6 particles is a busy moment; "; STR$(MAXPART, 2);
  PRINT " is the instant after an explosion."
  PRINT "sim is scaled to the "; STR$(SIMPF, 4, 2); " steps a drawn frame"
  PRINT "any key"
  DO WHILE INKEY$ = "" : LOOP
  FRAMEBUFFER WRITE F
  LoadLevel level
END SUB

SUB BenchRun(lv AS INTEGER, np AS INTEGER)
  LOCAL INTEGER bq, n, t
  LOCAL FLOAT sim, drw
  FRAMEBUFFER WRITE F
  sim = 0 : drw = 0
  FOR bq = 1 TO 40
    FOR n = 0 TO MAXPART - 1
      IF n < np THEN paLife(n) = 60 ELSE paLife(n) = 0
      paType(n) = n AND 3
      paX(n) = camX + 8 + (n MOD 8) * 8
      paY(n) = camY + 12 + (n \ 8) * 24
      paDX(n) = 0.2 : paDY(n) = 0.15
    NEXT n
    crashed = 0
    t = TIMER
    SimStep
    sim = sim + (TIMER - t)
    t = TIMER
    DrawWorld
    DrawObjects
    DrawPod
    DrawShip
    DrawParticles
    DrawPanel
    FRAMEBUFFER COPY F, N
    drw = drw + (TIMER - t)
  NEXT bq
  FRAMEBUFFER WRITE N
  sim = sim / 40 * SIMPF : drw = drw / 40
  PRINT STR$(lv, 3); STR$(nObj, 5); STR$(np, 6);
  PRINT STR$(sim, 9, 2); STR$(drw, 10, 2); STR$(sim + drw, 8, 2);
  PRINT STR$(1000 / (sim + drw), 6, 0)
END SUB

' Testing only: stand the ship beside the pod with the tether taut, so
' the towing behaviour can be looked at without flying down to it.
SUB GrabPod
  IF hasPod = 0 THEN EXIT SUB
  podAtt = 1 : beamOn = 1
  tethAng = 4 : tethVel = 0
  velX = 0 : velY = 0
  midX = podHomeX + TETHK * AngXi(tethAng)
  midY = podHomeY + TETHK * AngYi(tethAng)
  DeriveShip
  crashed = 0
  camX = midX - VIEWC \ 2
  camY = INT(midY) - VIEWR \ 2
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
  LOCAL INTEGER t, d
  LOCAL FLOAT p

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

  ' 2. integrate the midpoint - every step, not just the active ones -
  '    and swing the tether with it
  midX = midX + velX
  midY = midY + velY
  IF podAtt <> 0 THEN
    tethAng = tethAng + tethVel
    DO WHILE tethAng < 0 : tethAng = tethAng + NANG : LOOP
    DO WHILE tethAng >= NANG : tethAng = tethAng - NANG : LOOP
  ENDIF

  ' 3/4. the ship and the pod hang either side of the midpoint along the
  '      tether.  With no pod the ship is the midpoint.
  DeriveShip

  ' 3. gravity, thrust and drag, on six ticks in sixteen
  t = tick AND 15
  IF actTick(t) <> 0 THEN
    velY = velY + gravY
    IF (kThrust <> 0) AND (fuel > 0) THEN
      ' The table's sign is the direction of flight: heading 0 is up and
      ' its Y entry is -2.5, and the 6502 adds it.  (The disassembly's
      ' own notes say the thrust is negated; the ADC says otherwise, and
      ' negating it would drive the ship backwards.)
      IF podAtt <> 0 THEN d = THRDIVPOD ELSE d = THRDIV
      velX = velX + angX(shipAng) / d
      velY = velY + angY(shipAng) / d
      fuel = fuel - 1
      SndEngine
      ' Thrust off the tether's axis is what swings the pod.  There is no
      ' gravity term here and that is right: gravity pulls equally on
      ' ship and pod, so it moves the midpoint without twisting the
      ' tether.  The pendulum is driven by thrust and momentum alone.
      IF podAtt <> 0 AND t <> 3 AND t <> 11 THEN
        p = tethVel
        tethVel = tethVel + AngXi(shipAng - tethAng) / TETHTORQ
        tethVel = tethVel - p / TETHDAMP
      ENDIF
    ENDIF
    velX = velX - velX / DRAGX
    velY = velY - velY / DRAGY
  ENDIF
  tick = tick + 1
  Tractor
  Refuel
  UpdateGuns
  UpdateParticles
  IF kFire <> 0 AND fireGap = 0 THEN FirePlayer
  IF fireGap > 0 THEN fireGap = fireGap - 1
  IF countdown > 0 THEN
    countdown = countdown - 1
    IF (countdown AND 15) = 0 THEN SndCountdown
    IF countdown = 0 THEN crashed = 40 : deaths = deaths + 1
  ENDIF

  IF HitWall() <> 0 THEN Explode
END SUB

' ----------------------------------------------------------------------
'  The tether is a circle of radius 20 pixels once the column and
'  scanline scales are taken out.  Linear interpolation between table
'  entries is what the original's fifteen-step accumulation amounts to.
' ----------------------------------------------------------------------
SUB DeriveShip
  IF podAtt = 0 THEN
    shipX = midX : shipY = midY
    EXIT SUB
  ENDIF
  shipX = midX + TETHK * AngXi(tethAng)
  shipY = midY + TETHK * AngYi(tethAng)
  podX = midX - TETHK * AngXi(tethAng)
  podY = midY - TETHK * AngYi(tethAng)
END SUB

FUNCTION AngXi(a AS FLOAT) AS FLOAT
  LOCAL INTEGER i
  LOCAL FLOAT w
  w = a
  DO WHILE w < 0 : w = w + NANG : LOOP
  DO WHILE w >= NANG : w = w - NANG : LOOP
  i = INT(w)
  AngXi = angX(i) + (angX((i + 1) AND (NANG - 1)) - angX(i)) * (w - i)
END FUNCTION

FUNCTION AngYi(a AS FLOAT) AS FLOAT
  LOCAL INTEGER i
  LOCAL FLOAT w
  w = a
  DO WHILE w < 0 : w = w + NANG : LOOP
  DO WHILE w >= NANG : w = w - NANG : LOOP
  i = INT(w)
  AngYi = angY(i) + (angY((i + 1) AND (NANG - 1)) - angY(i)) * (w - i)
END FUNCTION

' ----------------------------------------------------------------------
'  The tractor beam.  Hold the key near the pod and the beam appears;
'  then pull away, and at GRABDIST the pod lifts off its stand.  Both
'  thresholds straddle the tether's own length, so the grab happens just
'  as the line goes taut.
'
'  Attaching halves the velocity, because the moving mass has doubled,
'  and turns whatever of that velocity was tangential into swing.  The
'  original finds the starting angle with a seven-pass binary search over
'  the same tables; ATAN2 on the circle gives the same answer directly.
' ----------------------------------------------------------------------
SUB Tractor
  LOCAL FLOAT dx, dy, a, b, r
  IF hasPod = 0 OR podAtt <> 0 OR crashed <> 0 THEN EXIT SUB
  IF kTract = 0 THEN
    beamOn = 0
    EXIT SUB
  ENDIF
  ' the original's metric, in pixels: the smaller axis plus three times
  ' the larger
  a = ABS(shipX - podX) * COLPX
  b = ABS(shipY - podY) * ROWPX
  IF a > b THEN r = b + 3 * a ELSE r = a + 3 * b
  IF r < BEAMDIST THEN
    beamOn = 1
    EXIT SUB
  ENDIF
  IF beamOn = 0 OR r < GRABDIST THEN EXIT SUB

  midX = (shipX + podX) / 2
  midY = (shipY + podY) / 2
  velX = velX / 2
  velY = velY / 2
  dx = (shipX - midX) * COLPX          ' the tether circle, in pixels
  dy = (shipY - midY) * ROWPX
  tethAng = ATAN2(dx, -dy) * NANG / (2 * PI)
  DO WHILE tethAng < 0 : tethAng = tethAng + NANG : LOOP
  r = dx * dx + dy * dy
  IF r < 1 THEN r = 1
  ' the tangential part of the ship's velocity becomes swing
  tethVel = (dx * velY * ROWPX - dy * velX * COLPX) / r * NANG / (2 * PI)
  podAtt = 1
  beamOn = 1
  SndCollect1
  SndCollect2
  DeriveShip
END SUB

' ----------------------------------------------------------------------
'  Fuel.  A fuel cell is not towed like the pod - hold the beam on it and
'  the tank fills where it stands, which is what tick_fuel_pickup_draw_beams
'  does.  The beam reaches as far as the tractor beam's first threshold.
' ----------------------------------------------------------------------
SUB Refuel
  LOCAL INTEGER fi
  LOCAL FLOAT fa, fb, fr
  fuelBeam = -1
  IF kTract = 0 OR crashed <> 0 THEN EXIT SUB
  FOR fi = 0 TO nObj - 1
    IF objLive(fi) <> 0 AND objT(fi) = OBJ_FUEL THEN
      fa = ABS(shipX - objX(fi) - 2) * COLPX
      fb = ABS(shipY - objY(fi) - 5) * ROWPX
      IF fa > fb THEN fr = fb + 3 * fa ELSE fr = fa + 3 * fb
      IF fr < BEAMDIST THEN
        fuelBeam = fi
        fuel = fuel + FUELADD
        IF fuel > FUELMAX THEN fuel = FUELMAX
        EXIT SUB
      ENDIF
    ENDIF
  NEXT fi
END SUB

' ----------------------------------------------------------------------
'  The limpet guns.  gun_param is two fields: bits 2-4 are the angle the
'  gun points, in the same 32-step scale, and bits 0-1 index a spread
'  mask of 1, 3, 7 or 15.  A shot goes out at the base angle plus a
'  random value under the mask plus another 0 to 3, so a wide-mask gun
'  sprays and a narrow one aims.
' ----------------------------------------------------------------------
SUB UpdateGuns
  LOCAL INTEGER gi, base, mask, ga, gp
  IF crashed <> 0 OR nObj = 0 THEN EXIT SUB
  ' The original rolls once per gun per frame at a probability of 2 in
  ' 256.  Rolling once for the whole level and then picking a gun gives
  ' the same firing rate for the same expected number of shots, and costs
  ' two statements instead of nineteen array scans and nineteen function
  ' calls - which is most of what the entity benchmark was measuring.
  IF RND * 256 >= GUNPROB * nObj THEN EXIT SUB
  gi = INT(RND * nObj)
  IF objLive(gi) = 0 THEN EXIT SUB
  IF objT(gi) >= OBJ_FUEL THEN EXIT SUB
  IF OnScreen(objX(gi), objY(gi)) = 0 THEN EXIT SUB
  base = objG(gi) AND &H1C
  SELECT CASE objG(gi) AND 3
    CASE 0 : mask = 1
    CASE 1 : mask = 3
    CASE 2 : mask = 7
    CASE ELSE : mask = 15
  END SELECT
  ga = (base + (INT(RND * 256) AND mask) + INT(RND * 4)) AND (NANG - 1)
  gp = FreePart()
  IF gp < 0 THEN EXIT SUB
  paType(gp) = PT_HOSTILE : paLife(gp) = PARTLIFE
  paX(gp) = objX(gi) + 2 : paY(gp) = objY(gi) + 4
  paDX(gp) = angX(ga) : paDY(gp) = angY(ga)
  SndHostileGun
END SUB

' SPRITE WRITE takes -10 to 240 in each axis and errors outside it, so
' anything drawn has to be tested where it lands, not where it lives.
FUNCTION Offscreen(x AS INTEGER, y AS INTEGER) AS INTEGER
  Offscreen = 1
  IF x < -10 OR x > SCRW - 1 THEN EXIT FUNCTION
  IF y < -10 OR y > SCRH - 1 THEN EXIT FUNCTION
  Offscreen = 0
END FUNCTION

FUNCTION OnScreen(x AS FLOAT, y AS FLOAT) AS INTEGER
  OnScreen = 0
  IF x < camX - 6 OR x > camX + VIEWC + 6 THEN EXIT FUNCTION
  IF y < camY - 12 OR y > camY + VIEWR + 12 THEN EXIT FUNCTION
  OnScreen = 1
END FUNCTION

FUNCTION FreePart() AS INTEGER
  LOCAL INTEGER i
  FOR i = 0 TO MAXPART - 1
    IF paLife(i) = 0 THEN
      FreePart = i
      EXIT FUNCTION
    ENDIF
  NEXT i
  FreePart = -1
END FUNCTION

' The player's shot leaves the ship's centre with the angle table's own
' velocity and no inheritance from the ship, then is stepped twice at
' once so it clears the nose - create_new_player_bullet's LDY #$02 loop.
SUB FirePlayer
  LOCAL INTEGER p
  IF crashed <> 0 THEN EXIT SUB
  p = FreePart()
  IF p < 0 THEN EXIT SUB
  paType(p) = PT_PLAYER : paLife(p) = PARTLIFE
  paDX(p) = angX(shipAng) : paDY(p) = angY(shipAng)
  paX(p) = shipX + paDX(p) * BULLETADV
  paY(p) = shipY + paDY(p) * BULLETADV
  fireGap = FGAP
  SndOwnGun
END SUB

SUB UpdateParticles
  LOCAL INTEGER i, j, wy, t
  LOCAL FLOAT x, y
  FOR i = 0 TO MAXPART - 1
    IF paLife(i) > 0 THEN
      paLife(i) = paLife(i) - 1
      paX(i) = paX(i) + paDX(i)
      paY(i) = paY(i) + paDY(i)
      x = paX(i) : y = paY(i) : t = paType(i)
      wy = INT(y)
      IF wy < 0 OR wy >= depth THEN
        paLife(i) = 0
      ELSEIF x < wallL(wy) OR x >= wallR(wy) THEN
        paLife(i) = 0                          ' into the rock
      ELSEIF t = PT_HOSTILE THEN
        IF crashed = 0 THEN
          IF ABS(x - shipX) < HULLRX AND ABS(y - shipY) < HULLRY THEN
            paLife(i) = 0
            Explode
          ENDIF
        ENDIF
      ELSEIF t = PT_PLAYER THEN
        FOR j = 0 TO nObj - 1
          IF objLive(j) <> 0 AND objT(j) <> OBJ_POD THEN
            IF x >= objX(j) AND x < objX(j) + objW(objT(j)) THEN
              IF y >= objY(j) AND y < objY(j) + objH(objT(j)) THEN
                paLife(i) = 0
                HitObject j
                EXIT FOR
              ENDIF
            ENDIF
          ENDIF
        NEXT j
      ENDIF
    ENDIF
  NEXT i
END SUB

' Only guns and fuel can be destroyed; the reactor takes fifty hits and
' then the planet goes, which starts the ten seconds to get clear.
SUB HitObject(j AS INTEGER)
  IF objT(j) = OBJ_REACTOR THEN
    reactorHP = reactorHP - 1
    SndExplosion2
    IF reactorHP <= 0 THEN
      objLive(j) = 0
      countdown = CDOWN0
      Debris objX(j) + 2, objY(j) + 5, 8
      SndExplosion1
      SndExplosion2
    ENDIF
    EXIT SUB
  ENDIF
  objLive(j) = 0
  IF objT(j) = OBJ_FUEL THEN score = score + SCOREFUEL ELSE score = score + SCOREGUN
  Debris objX(j) + 2, objY(j) + 4, 6
  SndExplosion1
  SndExplosion2
END SUB

SUB Debris(x AS FLOAT, y AS FLOAT, n AS INTEGER)
  LOCAL INTEGER i, p, a
  FOR i = 1 TO n
    p = FreePart()
    IF p < 0 THEN EXIT SUB
    a = INT(RND * NANG)
    paType(p) = PT_DEBRIS : paLife(p) = PARTLIFE \ 2 + INT(RND * 20)
    paX(p) = x : paY(p) = y
    paDX(p) = angX(a) * 0.5 : paDY(p) = angY(a) * 0.5
  NEXT i
END SUB

SUB Explode
  IF crashed <> 0 THEN EXIT SUB
  crashed = 40
  keepPod = podAtt
  deaths = deaths + 1
  Debris shipX, shipY, 8
  SndExplosion1
  SndExplosion2
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
  ' a towed pod scrapes the wall as readily as the ship does
  IF podAtt <> 0 THEN
    FOR i = 0 TO NHULL - 1
      wy = INT(podY + hullY(i) * PODRY / HULLRY)
      IF wy < 0 OR wy >= depth THEN EXIT FUNCTION
      wx = podX + hullX(i) * PODRX / HULLRX
      IF wx < wallL(wy) THEN EXIT FUNCTION
      IF wx >= wallR(wy) THEN EXIT FUNCTION
    NEXT i
  ENDIF
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
  IF Offscreen(sx, sy) <> 0 THEN EXIT SUB
  IF shipAng <= 16 THEN
    n = S_SHIP + shipAng : rot = 0
  ELSE
    n = S_SHIP + NANG - shipAng : rot = 1
  ENDIF
  SPRITE WRITE n, sx, sy, rot
END SUB

' The pod, and the line to it.  The original draws the beam whenever
' pod_line_exists_flag is set, which is the whole time it is attached.
SUB DrawPod
  LOCAL INTEGER sx, sy, tx, ty
  IF hasPod = 0 THEN EXIT SUB
  sx = INT((podX - camX) * COLPX)
  sy = PLAYTOP + INT((podY - camY) * ROWPX)
  IF beamOn <> 0 THEN
    tx = INT((shipX - camX) * COLPX)
    ty = PLAYTOP + INT((shipY - camY) * ROWPX)
    LINE tx, ty, sx, sy, 1, colObj
  ENDIF
  IF Offscreen(sx - 5, sy - 5) <> 0 THEN EXIT SUB
  SPRITE WRITE S_POD, sx - 5, sy - 5, 0
END SUB

SUB DrawObjects
  LOCAL INTEGER i, sx, sy
  FOR i = 0 TO nObj - 1
    IF objLive(i) <> 0 THEN
      IF objT(i) <> OBJ_POD OR podAtt = 0 THEN
        sx = INT((objX(i) - camX) * COLPX)
        sy = PLAYTOP + INT((objY(i) - camY) * ROWPX)
        IF Offscreen(sx, sy) = 0 THEN SPRITE WRITE S_OBJ + objT(i), sx, sy, 0
      ENDIF
    ENDIF
  NEXT i
  IF fuelBeam >= 0 THEN
    sx = INT((shipX - camX) * COLPX)
    sy = PLAYTOP + INT((shipY - camY) * ROWPX)
    i = INT((objX(fuelBeam) + 2 - camX) * COLPX)
    LINE sx, sy, i, PLAYTOP + INT((objY(fuelBeam) + 5 - camY) * ROWPX), 1, colObj
  ENDIF
END SUB

SUB DrawParticles
  LOCAL INTEGER i, sx, sy, c
  FOR i = 0 TO MAXPART - 1
    IF paLife(i) > 0 THEN
      sx = INT((paX(i) - camX) * COLPX)
      sy = PLAYTOP + INT((paY(i) - camY) * ROWPX)
      IF sx >= 0 AND sx < SCRW AND sy >= PLAYTOP AND sy < SCRH THEN
        IF paType(i) = PT_PLAYER THEN c = pal(3) ELSE c = colObj
        PIXEL sx, sy, c
        PIXEL sx + 1, sy, c
      ENDIF
    ENDIF
  NEXT i
END SUB

SUB DrawPanel
  LOCAL s$ LENGTH 48
  BOX 0, 0, SCRW, PANELH, 0, RGB(BLACK), RGB(BLACK)
  s$ = "L" + STR$(level + 1) + " FUEL " + STR$(fuel) + " SC " + STR$(score)
  IF podAtt <> 0 THEN s$ = s$ + " POD"
  IF countdown > 0 THEN s$ = s$ + " GO " + STR$(countdown \ 50 + 1)
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
  kLeft = 0 : kRight = 0 : kThrust = 0 : kTract = 0 : kFire = 0
  kNext = 0 : kPrev = 0 : kQuit = 0 : kShot = 0 : kReset = 0 : kGrab = 0
  kBench = 0
  ky$ = INKEY$
  IF ky$ = CHR$(27) THEN kQuit = 1
  IF ky$ = "n" OR ky$ = "N" THEN kNext = 1
  IF ky$ = "p" OR ky$ = "P" THEN kPrev = 1
  IF ky$ = "s" OR ky$ = "S" THEN kShot = 1
  IF ky$ = "r" OR ky$ = "R" THEN kReset = 1
  IF ky$ = "g" OR ky$ = "G" THEN kGrab = 1
  IF ky$ = "b" OR ky$ = "B" THEN kBench = 1
  IF ky$ = " " THEN kThrust = 1
  IF ky$ = CHR$(13) OR ky$ = "a" OR ky$ = "A" THEN kTract = 1
  IF ky$ = "f" OR ky$ = "F" THEN kFire = 1
  FOR i = 1 TO 6
    k = KEYDOWN(i)
    SELECT CASE k
      CASE 130, 122, 90  : kLeft = 1        ' left, Z
      CASE 131, 120, 88  : kRight = 1       ' right, X
      CASE 128, 32       : kThrust = 1      ' up, space
      CASE 13, 97, 65    : kTract = 1       ' RETURN, A
      CASE 129, 102, 70  : kFire = 1        ' down, F
      CASE 110, 78       : kNext = 1
      CASE 112, 80       : kPrev = 1
      CASE 115, 83       : kShot = 1
      CASE 114, 82       : kReset = 1
      CASE 103, 71       : kGrab = 1
      CASE 98, 66        : kBench = 1
      CASE 27            : kQuit = 1
    END SELECT
  NEXT i
END SUB
