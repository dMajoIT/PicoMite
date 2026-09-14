' =====================================================================
'  T H R U S T        PicoMite MMBasic
'  after the 1986 BBC Micro game by Jeremy C. Smith for Superior Software
'
'  A port of the whole game (see docs/Thrust_Port_Plan.html): the flight
'  model, the pod on its tether, fuel, limpet guns, bullets, the reactor
'  and the missions.
'
'  Lift the Klystron pod off its stand with the tractor beam and carry it
'  up out of the cave.  Shoot the reactor fifty times and the planet goes
'  with it, which is worth two thousand but leaves ten seconds to get
'  clear.  Six caves, then round again with the guns firing harder each
'  time - and after the first six, with gravity reversed, or the cave
'  invisible, or both.
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
'  Timing is one clock, and it is the BBC's.  Its loop waits for the
'  centisecond counter to reach 3 before going round again, so a frame
'  is 30 ms and level_tick_counter - which gates the rotation, the
'  forces and the tether torque - advances once per frame at 33.3 Hz.
'  We pace to the same 30 ms and take one simulation step per frame, so
'  every rate in the game falls out at the rate it had in 1986.
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
'            Tractor beam ... RETURN, or A  (also the shield, and refuels)
'            Fire ........... down arrow, or F
'            Level .......... N, P
'            Restart ........ R
'            Screenshot ..... S  (to A:/thrust.bmp)
'
'  For testing: N completes the mission, P swaps the cave under you, G
'  puts the ship beside the pod with a full tank and it already
'  attached, and B runs the
'  entity benchmark - a full particle pool and every object on the level,
'  drawn and simulated flat out.
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
'  The original's frame is three centiseconds, not one fiftieth of a
'  second.  draw_player_timed_to_vsync spins on OSWORD 1 until the BBC's
'  centisecond clock reads 3 and then zeroes it, and level_tick_counter
'  advances once per pass - so the whole game, and every rate derived
'  from that counter, runs at 33.3 Hz.  The disassembly's notes say 50 in
'  four places; its own code says otherwise, and taking the notes at
'  their word made this port half again too fast to fly.
CONST FRAMEMS = 30                ' 33.3 frames a second, as the BBC does

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
CONST SIMPF = 1.0                 ' one simulation step to a drawn frame
CONST ROTMASK = 3                 ' rotate on three frames in four
CONST THRDIV = 16                 ' thrust is the table value over 16
CONST DRAGX = 64                  ' velX -= velX / 64   per active tick
CONST DRAGY = 256                 ' velY -= velY / 256  - weaker, because
                                  ' gravity is always adding to it
'  Eight hull points a heading, taken off the ship's own outline by
'  gen_sprites.py rather than a ring drawn round it, so the nose leads
'  when you fly nose-first and the flanks catch when you slew.
CONST NHULL = 8
'  The shield bubble is a 17 pixel circle, which is wider than the ship
'  in both axes.  That is not an oversight in the original and it is not
'  one here: the field is a thing you put around yourself, and it fouls
'  the rock sooner than the hull does.
CONST SHIELDR = 8.5               ' pixels
CONST SHIELDDUTY = 2              ' on two frames in four, as the BBC does
'  You start a game with an empty tank, which looks like a bug until you
'  notice where the ship is put down: directly above the first fuel cell.
'  You fall onto it, hold the tractor key, and fly off with a full tank.
'  add_fuel puts on $11 BCD a frame while the beam is on; use_fuel takes
'  one off per active tick, so a second of hovering buys half a minute.
CONST FUEL0 = 0
CONST FUELADD = 11                ' $11 BCD, per frame on the beam
CONST FUELMAX = 9999
'  A cell is not a range but a box, and a tight one: it has to be 1 to 5
'  columns to the right of the ship's plot origin and 0 to 27 scanlines
'  below it.  Both subtractions in the 6502 are unsigned, which is what
'  makes it one-sided - you have to be above the cell and almost on top
'  of it.  Our shipX,shipY is the sprite's centre rather than its origin,
'  4 columns and 5 scanlines further on, so the window moves with it.
CONST FUELDX0 = -3, FUELDX1 = 1
CONST FUELDY0 = -5, FUELDY1 = 22
'  And a cell is a fixed ration: 26 frames on the beam and it is spent,
'  worth 30 points and 286 units of fuel.
CONST FUELFRAMES = 26
CONST SCOREFUELCELL = 30

' ------------------------------------------------------- the world
CONST MAXOBJ = 20                 ' nineteen is the most any level has
CONST OBJ_FUEL = 4
CONST OBJ_POD = 5
CONST OBJ_REACTOR = 6
CONST RHP0 = 50              ' $32, generator_total_damage
'  Ten seconds, counted in frames: the original holds a seconds counter
'  and steps it once every $20 frames, which at 33.3 Hz is very nearly a
'  second, sounding a note each time.
CONST CDOWNSEC = 32
CONST CDOWN0 = 10 * CDOWNSEC
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
'  Firing is one shot to a press, not a repeat rate: test_fire_key
'  latches player_pressed_fire and will not fire again until the key has
'  been let go.  And holding the tractor key blocks the gun outright -
'  ship_input_fire sets the latch and returns without testing anything -
'  so the field and the gun are two modes, not two buttons.

' ------------------------------------------------------------- a game
'  Escaping is a test on the midpoint alone: above world scanline 288 and
'  you are in orbit.  With the pod that finishes the mission; without it,
'  it costs a life, which is what the branch after the escape test does.
CONST ORBITY = 288
CONST LIVES0 = 4                  ' INITIAL_LIVES
CONST GUNPROB0 = 2                ' in 256 per gun per step, and it
                                  ' climbs from mission 3
CONST GUNPROBMAX = 35             ' $23
CONST GUNPENALTY = 8              ' for blowing the planet and not leaving
CONST BONUSBASE = 400             ' 400 * (level + 5), plus 2000 for the
CONST BONUSPLANET = 2000          ' planet - so 2000 to 6000 a mission
'  The two modifiers turn over on a two-bit counter, one step at the end
'  of every six missions: start_new_level inverts reverse gravity, and
'  only when that switch turns it OFF does it invert the invisible
'  landscape.  So the rotation is normal, reversed, invisible, both, and
'  round again after twenty-four missions.
CONST ANGLEDOWN = 16              ' where you start when down is up

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
DIM FLOAT hullX(NANG - 1, NHULL - 1), hullY(NANG - 1, NHULL - 1)
DIM FLOAT shX(NHULL - 1), shY(NHULL - 1)
DIM INTEGER shieldOn
DIM FLOAT midX, midY, podX, podY, podHomeX, podHomeY
DIM FLOAT tethAng, tethVel
DIM INTEGER podAtt, beamOn, hasPod, keepPod
DIM INTEGER nObj, nGun
DIM FLOAT objX(MAXOBJ - 1), objY(MAXOBJ - 1)
DIM INTEGER objT(MAXOBJ - 1), objG(MAXOBJ - 1), objLive(MAXOBJ - 1)
DIM INTEGER objTC(MAXOBJ - 1)
DIM INTEGER objW(8), objH(8)
DIM FLOAT paX(MAXPART - 1), paY(MAXPART - 1)
DIM FLOAT paDX(MAXPART - 1), paDY(MAXPART - 1)
DIM INTEGER paLife(MAXPART - 1), paType(MAXPART - 1)
DIM INTEGER score, reactorHP, countdown, fuelBeam, fireHeld, nPart
DIM INTEGER lives, mission, gunProb, gunPen, planetDead, ending, gameOver
DIM INTEGER warnUp, revGrav, invLand, hiScore, saidRev, saidInv
DIM INTEGER sndOK
CONST HIFILE = "A:/thrust.hi"
DIM INTEGER shipAng, tick, fuel, crashed, deaths
DIM INTEGER kLeft, kRight, kThrust, kTract
DIM INTEGER kNext, kPrev, kQuit, kShot, kReset, kGrab, kFire, kBench
DIM INTEGER nBox, drawMs
DIM INTEGER nextFrame, t0, caveTop

' ======================================================================
'  main
' ======================================================================
Setup
DO
  TitleScreen
  NewGame
  RunGame
LOOP
END

SUB RunGame
nextFrame = TIMER + FRAMEMS
DO
  ReadKeys
  IF kQuit <> 0 THEN EXIT DO
  ' N finishes the mission as though the pod had been carried out, which
  ' is the only way to reach the later caves and their modifiers without
  ' playing there.  P just swaps the cave under you.
  IF kNext <> 0 THEN ending = 1
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

  IF ending <> 0 THEN
    EndLevel
  ELSE
    DO WHILE TIMER < nextFrame : LOOP
    nextFrame = nextFrame + FRAMEMS
  ENDIF
LOOP UNTIL gameOver <> 0
IF gameOver = 1 THEN GameOverScreen
END SUB

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

  ' The hull, eight points for each of the seventeen stored headings.
  ' Headings 17 to 31 are 32-n with x negated - the same mirror the
  ' sprite is drawn with, so the outline and the picture agree.
  RESTORE hulldata
  FOR i = 0 TO 16
    FOR j = 0 TO NHULL - 1
      READ hullX(i, j), hullY(i, j)
    NEXT j
  NEXT i
  FOR i = 17 TO NANG - 1
    FOR j = 0 TO NHULL - 1
      hullX(i, j) = -hullX(NANG - i, j)
      hullY(i, j) = hullY(NANG - i, j)
    NEXT j
  NEXT i
  ' and a circle for the shield bubble
  FOR i = 0 TO NHULL - 1
    a = i * 2 * PI / NHULL
    shX(i) = SHIELDR / COLPX * SIN(a)
    shY(i) = -SHIELDR / ROWPX * COS(a)
  NEXT i
  hiScore = 0
  ON ERROR SKIP 3
  OPEN HIFILE FOR INPUT AS #1
  INPUT #1, hiScore
  CLOSE #1
  ON ERROR CLEAR
  IF hiScore < 0 OR hiScore > 99999999 THEN hiScore = 0

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
  ' initialise_level_pointers reverses gravity by EOR $FF on the fraction
  ' with the integer byte set to -1, which comes to -(FRAC + 1) / 256 -
  ' a shade stronger than the pull it replaces, not a mirror of it.
  IF revGrav <> 0 THEN gravY = -(gravY + 1 / 256)
  ' An invisible cave is the landscape drawn in the background colour.
  IF invLand <> 0 THEN colLand = colBack

  ' The objects.  Their x and y are the sprite's plot origin, so they are
  ' kept as they come and the drawing does not shift them.  The pod is the
  ' exception: its sphere sits at pixel (9, 5) inside the pod_stand shape,
  ' which is 2.25 columns and 2.5 scanlines in, and that is where the
  ' tether has to reach.
  hasPod = 0
  nObj = 0
  nGun = 0
  RESTORE objdata
  FOR i = 0 TO lv
    READ n
    FOR j = 1 TO n
      READ c, inc, k, x
      IF i = lv AND nObj < MAXOBJ THEN
        objX(nObj) = c : objY(nObj) = inc
        objT(nObj) = k : objG(nObj) = x : objLive(nObj) = 1
        objTC(nObj) = 0
        IF k < OBJ_FUEL THEN nGun = nGun + 1
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
  shipAng = 0
  IF revGrav <> 0 THEN shipAng = ANGLEDOWN
  tick = 0 : simAcc = 0
  fuel = FUEL0 : crashed = 0
  podAtt = 0 : beamOn = 0 : tethAng = 0 : tethVel = 0
  podX = podHomeX : podY = podHomeY
  countdown = 0 : fuelBeam = 0 : fireHeld = 0
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
  fuel = 2000                     ' a testing state is no use without fuel
  podAtt = 1 : beamOn = 1
  ' Hang the pod straight down and put the pair a little above the stand,
  ' which is open ground on every cave; angling the tether tended to post
  ' the ship into the rock beside it.
  tethAng = 0 : tethVel = 0
  velX = 0 : velY = 0
  midX = podHomeX
  midY = podHomeY - TETHK * 2.5
  DeriveShip
  crashed = 0
  camX = midX - VIEWC \ 2
  camY = INT(midY) - VIEWR \ 2
  ClampCamera
END SUB

' ======================================================================
'  a game
' ======================================================================
SUB NewGame
  lives = LIVES0 : score = 0 : mission = 1
  gunProb = GUNPROB0 : gunPen = 0 : planetDead = 0
  gameOver = 0 : deaths = 0 : keepPod = 0
  revGrav = 0 : invLand = 0 : saidRev = 0 : saidInv = 0
  LoadLevel 0
  ending = 0
END SUB

' level_number = (mission_number - 1) MOD 6, and from mission 3 the guns
' fire harder every time, capped at 35 in 256.
SUB NextMission
  LOCAL INTEGER b
  b = BONUSBASE * (level + 5)
  IF planetDead <> 0 THEN b = b + BONUSPLANET
  score = score + b
  mission = mission + 1
  IF mission >= 3 THEN
    gunProb = gunProb + 1
    IF gunProb > GUNPROBMAX THEN gunProb = GUNPROBMAX
  ENDIF
  planetDead = 0 : keepPod = 0
  Banner "MISSION " + STR$(mission - 1) + " COMPLETE", "BONUS " + STR$(b)
  IF score > hiScore THEN hiScore = score : SaveHiScore
  ' Every sixth mission the two modifiers step round.  Inverting reverse
  ' gravity, and inverting the invisible landscape only when that leaves
  ' gravity normal again, gives: normal, reversed, invisible, both.
  IF ((mission - 1) MOD NLEVEL) = 0 THEN
    IF revGrav <> 0 THEN revGrav = 0 ELSE revGrav = 1
    IF revGrav = 0 THEN
      IF invLand <> 0 THEN invLand = 0 ELSE invLand = 1
    ENDIF
    IF revGrav <> 0 AND saidRev = 0 THEN
      saidRev = 1
      Banner "GRAVITY IS REVERSED", "DOWN IS UP"
    ENDIF
    IF invLand <> 0 AND saidInv = 0 THEN
      saidInv = 1
      Banner "THE CAVE IS INVISIBLE", "FLY BY MEMORY"
    ENDIF
  ENDIF
  LoadLevel((mission - 1) MOD NLEVEL)
  ending = 0
END SUB

SUB LoseLife(why$)
  lives = lives - 1
  IF planetDead <> 0 THEN gunPen = GUNPENALTY
  planetDead = 0
  IF lives <= 0 THEN
    Banner why$, "NO SHIPS LEFT"
    IF score > hiScore THEN hiScore = score : SaveHiScore
    gameOver = 1
    EXIT SUB
  ENDIF
  Banner why$, STR$(lives) + " SHIP LEFT"
  StartShip
  ending = 0
END SUB

' The three ways a level ends, handled between frames rather than inside
' the simulation so that the screen is settled when the banner goes up.
SUB EndLevel
  SELECT CASE ending
    CASE 1 : NextMission
    CASE 2 : LoseLife "YOU LEFT WITHOUT THE POD"
    CASE 3 : LoseLife "SHIP LOST"
  END SELECT
END SUB

SUB Banner(a$, b$)
  DrawWorld
  DrawObjects
  DrawPod
  DrawShip
  DrawPanel
  BOX 40, 96, 240, 48, 1, colObj, RGB(BLACK)
  TEXT 160, 106, a$, "CT", FONTN, 1, pal(3), RGB(BLACK)
  TEXT 160, 124, b$, "CT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  FRAMEBUFFER COPY F, N
  PAUSE 1600
  nextFrame = TIMER + FRAMEMS
END SUB

SUB TitleScreen
  LOCAL INTEGER t
  LOCAL ky$ LENGTH 2
  FRAMEBUFFER WRITE F
  CLS RGB(BLACK)
  TEXT 160, 24, "T H R U S T", "CT", FONTN, 3, pal(3), RGB(BLACK)
  TEXT 160, 56, "after the 1986 Superior Software original", "CT", FONTN, 1, pal(6), RGB(BLACK)
  TEXT 160, 68, "by Jeremy C. Smith", "CT", FONTN, 1, pal(6), RGB(BLACK)
  TEXT 60, 100, "LEFT / RIGHT", "LT", FONTN, 1, pal(2), RGB(BLACK)
  TEXT 170, 100, "TURN", "LT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  TEXT 60, 114, "UP or SPACE", "LT", FONTN, 1, pal(2), RGB(BLACK)
  TEXT 170, 114, "THRUST", "LT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  TEXT 60, 128, "RETURN or A", "LT", FONTN, 1, pal(2), RGB(BLACK)
  TEXT 170, 128, "TRACTOR, REFUEL", "LT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  TEXT 60, 142, "DOWN or F", "LT", FONTN, 1, pal(2), RGB(BLACK)
  TEXT 170, 142, "FIRE", "LT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  TEXT 160, 168, "LIFT THE POD OUT OF THE CAVE", "CT", FONTN, 1, pal(1), RGB(BLACK)
  TEXT 160, 182, "THE REACTOR IS WORTH 2000 AND TEN SECONDS", "CT", FONTN, 1, pal(1), RGB(BLACK)
  IF sndOK = 0 THEN
    TEXT 160, 224, "no sound - needs firmware V6.03.02b6 or later", "CT", FONTN, 1, pal(1), RGB(BLACK)
  ENDIF
  IF hiScore > 0 THEN
    TEXT 160, 196, "BEST " + STR$(hiScore), "CT", FONTN, 1, pal(6), RGB(BLACK)
  ENDIF
  TEXT 160, 210, "PRESS SPACE", "CT", FONTN, 1, pal(3), RGB(BLACK)
  FRAMEBUFFER COPY F, N
  ' KEYDOWN empties the console buffer, so INKEY$ has to be read first or
  ' a key arriving over the serial console is thrown away unseen.
  DO WHILE INKEY$ <> "" : LOOP
  DO
    ky$ = INKEY$
    t = KEYDOWN(0)
  LOOP UNTIL ky$ <> "" OR t > 0
END SUB

SUB SaveHiScore
  ON ERROR SKIP 3
  OPEN HIFILE FOR OUTPUT AS #1
  PRINT #1, hiScore
  CLOSE #1
  ON ERROR CLEAR
END SUB

SUB GameOverScreen
  BOX 40, 96, 240, 48, 1, colObj, RGB(BLACK)
  TEXT 160, 106, "GAME OVER", "CT", FONTN, 2, pal(3), RGB(BLACK)
  TEXT 160, 124, "SCORE " + STR$(score), "CT", FONTN, 1, RGB(WHITE), RGB(BLACK)
  TEXT 160, 136, "BEST " + STR$(hiScore), "CT", FONTN, 1, pal(6), RGB(BLACK)
  FRAMEBUFFER COPY F, N
  PAUSE 3000
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

  IF ending <> 0 THEN EXIT SUB
  IF crashed <> 0 THEN
    crashed = crashed - 1
    IF crashed = 0 THEN ending = 3
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
  ' The shield.  One key does the tractor field and the bubble, which is
  ' what the original means by shield_tractor: holding it costs a unit of
  ' fuel a frame on two frames in four, draws the circle in place of the
  ' ship, and runs the engine.  It does not make you invulnerable - there
  ' is no path in the 6502 where it stops plot_ship_collision_detected
  ' reaching destroy_player_ship - so all it buys is the beam, and it
  ' costs a wider outline while it is up.
  IF (kTract <> 0) AND (fuel > 0) AND ((tick AND SHIELDDUTY) <> 0) THEN
    shieldOn = 1
    fuel = fuel - 1
    SndEngine
  ELSE
    shieldOn = 0
  ENDIF
  tick = tick + 1
  Tractor
  Refuel
  UpdateGuns
  UpdateParticles
  IF (kFire <> 0) AND (kTract = 0) AND (fireHeld = 0) THEN FirePlayer
  fireHeld = kFire
  IF kTract <> 0 THEN fireHeld = 1
  IF countdown > 0 THEN
    countdown = countdown - 1
    IF (countdown MOD CDOWNSEC) = 0 THEN SndCountdown
    IF countdown = 0 THEN Explode
  ENDIF
  ' Above scanline 288 is orbit.  Arriving with the pod finishes the
  ' mission; arriving without it costs a life, and if the planet has been
  ' blown the next mission's guns are angrier for it.
  IF ending = 0 AND crashed = 0 AND midY < ORBITY THEN
    SndEnterOrbit
    IF podAtt <> 0 THEN ending = 1 ELSE ending = 2
  ENDIF
  ' A warning band below the orbit line, so leaving without the pod is a
  ' decision rather than a surprise.
  IF podAtt = 0 AND midY < ORBITY + 40 THEN warnUp = 1 ELSE warnUp = 0

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
  LOCAL FLOAT dx, dy
  fuelBeam = -1
  IF crashed <> 0 OR kTract = 0 THEN EXIT SUB
  FOR fi = 0 TO nObj - 1
    IF objLive(fi) <> 0 THEN
      IF objT(fi) = OBJ_FUEL THEN
        dx = objX(fi) - shipX
        dy = objY(fi) - shipY
        IF dx >= FUELDX0 AND dx <= FUELDX1 THEN
          IF dy >= FUELDY0 AND dy <= FUELDY1 THEN
            fuelBeam = fi
            fuel = fuel + FUELADD
            IF fuel > FUELMAX THEN fuel = FUELMAX
            objTC(fi) = objTC(fi) + 1
            IF objTC(fi) >= FUELFRAMES THEN
              objLive(fi) = 0
              score = score + SCOREFUELCELL
              SndCollect1
              SndCollect2
            ENDIF
            EXIT SUB
          ENDIF
        ENDIF
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
  IF crashed <> 0 OR nGun = 0 THEN EXIT SUB
  ' The original rolls once per gun per frame at a probability of 2 in
  ' 256.  Rolling once for the whole level and then picking a gun gives
  ' the same firing rate for the same expected number of shots, and costs
  ' two statements instead of nineteen array scans and nineteen function
  ' calls - which is most of what the entity benchmark was measuring.
  ' one roll for the level in place of the original's one per gun, which
  ' is the same expected rate as long as it is scaled by the number of
  ' GUNS and not by every object on the level
  IF RND * 256 >= (gunProb + gunPen) * nGun THEN EXIT SUB
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
          IF ABS(x - shipX) < PODRX AND ABS(y - shipY) < PODRY THEN
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
      planetDead = 1
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
  LOCAL FLOAT wx, ox, oy
  HitWall = 1
  FOR i = 0 TO NHULL - 1
    IF shieldOn <> 0 THEN
      ox = shX(i) : oy = shY(i)
    ELSE
      ox = hullX(shipAng, i) : oy = hullY(shipAng, i)
    ENDIF
    wy = INT(shipY + oy)
    IF wy < 0 OR wy >= depth THEN EXIT FUNCTION
    wx = shipX + ox
    IF wx < wallL(wy) THEN EXIT FUNCTION
    IF wx >= wallR(wy) THEN EXIT FUNCTION
  NEXT i
  ' a towed pod scrapes the wall as readily as the ship does
  IF podAtt <> 0 THEN
    FOR i = 0 TO NHULL - 1
      wy = INT(podY + shY(i) * PODRY * ROWPX / SHIELDR)
      IF wy < 0 OR wy >= depth THEN EXIT FUNCTION
      wx = podX + shX(i) * PODRX * COLPX / SHIELDR
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
  IF shieldOn <> 0 THEN
    n = sx + SHIPCX - 8
    rot = sy + INT(SHIPCY) - 8
    IF Offscreen(n, rot) = 0 THEN SPRITE WRITE S_SHIELD, n, rot, 0
    EXIT SUB
  ENDIF
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
  s$ = "M" + STR$(mission) + " SHIPS " + STR$(lives) + " FUEL " + STR$(fuel)
  IF revGrav <> 0 THEN s$ = s$ + " REV"
  IF invLand <> 0 THEN s$ = s$ + " DARK"
  IF podAtt <> 0 THEN s$ = s$ + " POD"
  IF countdown > 0 THEN s$ = s$ + "  GET OUT " + STR$(countdown \ CDOWNSEC)
  IF warnUp <> 0 THEN s$ = s$ + "  NO POD - TURN BACK"
  TEXT 2, 4, s$, "LT", FONTN, 1, colLand, RGB(BLACK)
  TEXT SCRW - 2, 4, STR$(score), "RT", FONTN, 1, RGB(WHITE), RGB(BLACK)
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

' The ship's outline, eight points a heading, in world units -
' a column is four pixels across and a scanline two down, which
' is why the two columns look so different.  Headings 17 to 31
' are 32-n with x negated, the same mirror the sprite uses.
hulldata:
DATA   0.00, -4.75,   0.25, -4.25,   1.75,  0.25,   1.00,  2.25,  -0.75,  2.75,  -1.25,  1.75,  -1.75,  0.25,  -0.25, -4.25   ' ship0
DATA   0.50, -4.75,   0.75, -4.25,   1.75,  0.75,   1.50,  1.25,   0.50,  2.75,  -1.25,  1.75,  -1.75, -0.25,  -1.75, -0.25   ' ship1
DATA   0.75, -4.75,   1.00, -4.75,   1.50,  0.75,   1.50,  0.75,   0.25,  2.75,  -1.25,  1.25,  -1.75, -0.75,  -1.75, -1.25   ' ship2
DATA   1.25, -4.25,   1.50, -4.25,   1.50, -4.25,   1.50,  1.75,   0.00,  2.75,  -1.50,  0.25,  -1.50, -0.75,  -1.25, -2.25   ' ship3
DATA   1.25, -3.75,   1.75, -3.75,   1.75, -3.75,   1.00,  2.25,  -0.25,  2.75,  -0.50,  2.25,  -1.50, -0.75,  -1.25, -2.25   ' ship4
DATA  -1.00, -3.25,   2.00, -3.25,   2.00, -3.25,   1.00,  2.25,  -0.25,  2.75,  -0.50,  2.25,  -1.50, -0.75,  -1.00, -3.25   ' ship5
DATA  -0.50, -3.25,   2.25, -2.25,   2.25, -2.25,   0.75,  2.75,   0.25,  3.25,  -1.00,  1.75,  -1.50, -0.75,  -1.00, -2.25   ' ship6
DATA  -0.25, -3.75,   2.25, -1.75,   2.50, -1.25,   2.25, -0.75,   0.25,  3.25,  -1.00,  1.75,  -1.25, -1.75,  -1.25, -1.75   ' ship7
DATA   0.00, -3.75,   2.25, -0.75,   2.50, -0.25,   2.25,  0.25,   0.00,  3.25,  -1.25,  1.25,  -1.25,  1.25,  -1.25, -1.75   ' ship8
DATA   0.25, -3.75,   0.25, -3.75,   2.50,  0.75,   2.50,  0.75,  -0.25,  3.25,  -1.25,  1.25,  -1.25,  1.25,  -1.00, -2.25   ' ship9
DATA   0.25, -3.75,   0.75, -3.25,   2.25,  1.25,   2.25,  1.75,  -0.50,  2.75,  -1.00,  1.75,  -1.50,  0.25,  -1.00, -2.25   ' ship10
DATA  -0.25, -3.25,   0.75, -3.25,   2.00,  2.25,   2.00,  2.75,   1.00,  2.75,  -1.00,  2.75,  -1.50, -0.25,  -0.25, -3.25   ' ship11
DATA  -0.25, -3.25,   1.00, -2.75,   1.75,  2.25,   1.75,  3.25,   1.25,  3.25,  -1.25,  1.75,  -1.50, -0.75,  -1.25, -1.25   ' ship12
DATA   0.00, -3.25,   1.50, -2.25,   1.50, -2.25,   1.50,  3.75,   1.25,  3.75,  -1.50,  1.25,  -1.50,  1.25,  -1.25, -1.25   ' ship13
DATA   0.25, -3.25,   1.00, -2.25,   1.50, -1.25,   1.00,  4.25,   0.75,  4.25,  -1.50,  1.25,  -1.75,  0.25,  -1.25, -1.75   ' ship14
DATA   0.50, -2.75,   0.75, -2.75,   1.75, -0.75,   0.75,  4.25,   0.50,  4.75,   0.25,  4.25,  -1.75,  0.25,  -1.25, -1.75   ' ship15
DATA  -0.75, -2.75,   0.75, -2.75,   1.75, -0.25,   0.25,  4.25,   0.00,  4.75,   0.00,  4.75,  -1.75, -0.25,  -1.25, -1.75   ' ship16

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
DATA 0.0195312, 112,  406,  86,  292   ' level 0, 1 checkpoint
DATA 0.0273438, 112,  406,  86,  292   ' level 1, 1 checkpoint
DATA 0.0351562, 112,  406,  86,  292   ' level 2, 3 checkpoints
DATA 0.0429688, 112,  406,  86,  292   ' level 3, 3 checkpoints
DATA 0.0468750, 112,  406,  86,  292   ' level 4, 4 checkpoints
DATA 0.0507812, 112,  406,  86,  292   ' level 5, 5 checkpoints

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
  ' PLAY BBC arrived in V6.03.02b6.  On anything older these
  ' four fail, sndOK stays 0, and the game runs without sound
  ' rather than stopping with an error a player cannot read.
  sndOK = 0
  ON ERROR SKIP 4
  ' 01 02 FB FD FB 02 03 32 7E F9 F9 F4 7E 00
  PLAY BBC ENVELOPE 1, 2, -5, -3, -5, 2, 3, 50, 126, -7, -7, -12, 126, 0
  ' 02 02 FF 00 01 09 09 09 00 00 00 01 01  (+03), AR/ALA/ALD zeroed
  PLAY BBC ENVELOPE 2, 2, -1, 0, 1, 9, 9, 9, 0, 0, 0, 0, 0, 0
  ' 03 04 00 00 00 01 01 01 7E FC FE FC 7E 6E
  PLAY BBC ENVELOPE 3, 4, 0, 0, 0, 1, 1, 1, 126, -4, -2, -4, 126, 110
  ' 04 01 FF FF FF 12 12 12 32 F4 F4 F4 6E 46
  PLAY BBC ENVELOPE 4, 1, -1, -1, -1, 18, 18, 18, 50, -12, -12, -12, 110, 70
  IF MM.ERRNO = 0 THEN sndOK = 1
  ON ERROR CLEAR
END SUB

' ======================================================================
'  The nine sound blocks
' ======================================================================
' own_gun:      channel 2, flushed, envelope 1
'   the ship firing
SUB SndOwnGun
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H12, 1, 80, 2
END SUB

' explosion_1:  channel 1, flushed, envelope 2
'   explosion: the channel 1 tone that pitches the noise
SUB SndExplosion1
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H11, 2, 150, 100
END SUB

' explosion_2:  channel 0, flushed, envelope 3
'   explosion: the noise itself
SUB SndExplosion2
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H10, 3, 7, 100
END SUB

' hostile_gun:  channel 3, flushed, envelope 4
'   a limpet gun firing
SUB SndHostileGun
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H13, 4, 30, 20
END SUB

' collect_1:    channel 2, volume -15
'   picking something up
SUB SndCollect1
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND 2, -15, 190, 1
END SUB

' collect_2:    channel 2, silent
'   the second half of it
SUB SndCollect2
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND 2, 0, 190, 2
END SUB

' engine:       channel 0, flushed, volume -10
'   thrust, retriggered while the key is held
SUB SndEngine
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H10, -10, 5, 3
END SUB

' countdown:    channel 2, volume -15
'   the ten seconds after the reactor goes
SUB SndCountdown
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND 2, -15, 150, 1
END SUB

' enter_orbit:  channel 2, flushed, envelope 3
'   leaving the planet
SUB SndEnterOrbit
  IF sndOK = 0 THEN EXIT SUB
  PLAY BBC SOUND &H12, 3, 185, 1
END SUB
