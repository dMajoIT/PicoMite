' =====================================================================
'  The phase 2 test scene: just launched from the station
'
'  Not yet the real arrival geometry - SOLAR places the planet and the
'  sun on arrival in a system, and NWSPS puts the station in orbit, and
'  both of those belong to phase 3.  This is a hand-placed bubble that
'  exercises every part of the flight core: a rotating station near
'  enough to fill part of the view, ships at three different ranges,
'  something tumbling, and the planet close enough to show its curve
'  along the bottom of the screen.
' =====================================================================
' A brand new commander at Lave, with a hundred credits, three missiles
' and a pulse laser.  Everything the game needs to start is set here, so
' the test scene and a real new game begin from the same state.
SUB NewCommander
  LOCAL INTEGER i
  pRoll = JCENTRE : pPitch = JCENTRE
  pEnergy = 255 : pFsh = 255 : pAsh = 255 : pFuel = 70
  pCabT = 30 : pLasT = 0 : pAltit = 200 : pMissl = 3
  cashTenths = 1000 : holdSize = 20
  ' A new commander carries a pulse laser on the front view only.
  lasView(0) = LAS_PULSE : lasView(1) = 0 : lasView(2) = 0 : lasView(3) = 0
  lasTimer = 0 : lasFlash = 0
  kills = 0 : dead = 0 : energyUnit = 0 : legal = 0 : mission = 0
  shots = 0 : hits = 0
  docked = 0 : dockComp = 0 : msLock = -1
  vw = 0 : inWitch = 0
  FOR i = 0 TO NEQUIP - 1 : eqOwned(i) = 0 : NEXT i
  FOR i = 0 TO NGOODS - 1 : cargo(i) = 0 : NEXT i
  InitStardust
  LoadMarket

  ' Find Lave and make it home.
  gGal = 1
  SetGalaxy 1
  FOR i = 0 TO 255
    SysData
    IF SysName$() = "LAVE" THEN EXIT FOR
    NextSystem
  NEXT i
  homeSys = i : selSys = i
  homeX = sysX : homeY = sysY * 2
  curX = homeX : curY = homeY
  mkByte = 0
  MakeMarket sysEco, mkByte
END SUB

' Just launched from the station at Lave.  The bubble is built by the
' same code the game uses on arrival, so the planet's markings, the
' station's spin and the sun's position all come from Lave's seeds
' rather than being placed by hand.
SUB TestScene
  LOCAL INTEGER n
  NewCommander
  LaunchState

  ' Some traffic to look at.
  ' A Cobra coming straight at us with its AI off - a trader, which flies
  ' on and does not evade, so a fixed forward shot can actually connect.
  MATH Q_EULER RAD(180), 0, 0, qA() : qA(4) = 1
  n = NewShip(T_COBRA3, 0, 0, 9000, qA())
  IF n >= 0 THEN sSpd(n) = 12 : sAI(n) = 0
  ' And a hostile Viper, which does evade and does shoot back.
  MATH Q_EULER RAD(-70), RAD(10), 0, qA() : qA(4) = 1
  n = NewShip(T_VIPER, -1200, -300, 5000, qA())
  IF n >= 0 THEN sSpd(n) = 20 : sAI(n) = 128 OR (24 * 2)
  ' An asteroid dead ahead and tumbling.  It has no AI at all, so it
  ' cannot evade, and it is the one thing a fixed forward shot is certain
  ' to connect with - which is what makes it the honest test of the whole
  ' hit, damage, explode and score path.
  MATH Q_EULER RAD(30), RAD(20), RAD(10), qA() : qA(4) = 1
  n = NewShip(T_ASTEROID, 0, 0, 4000, qA())
  IF n >= 0 THEN sPit(n) = 127
END SUB

' ------------------------------------------------- the scripted demo
' Stands in for the keyboard so the flight core can be exercised and
' photographed without anyone at the keys.  Each stretch of frames tests
' one thing: accelerating, rolling, pitching, and each of the views.
SUB DemoInput(f AS INTEGER)
  kRollL = 0 : kRollR = 0 : kUp = 0 : kDn = 0
  kFaster = 0 : kSlower = 0 : kFire = 0 : kQuit = 0
  kTarget = 0 : kMissile = 0 : kECM = 0
  kJump = 0 : kChart = 0
  SELECT CASE f
    CASE 0 TO 9     : kFaster = 1                  ' ease forward only
    CASE 20 TO 120  : kFire = 1                    ' hold the trigger down
    CASE 130        : kTarget = 1                  ' lock on
    CASE 132        : kMissile = 1                 ' and launch
    CASE 200        : kECM = 1                     ' burst the E.C.M.
    CASE 160 TO 179 : vw = 1                       ' look behind
    CASE 180 TO 199 : vw = 3                       ' and to the right
    CASE 200 TO 209 : vw = 0
  END SELECT
  ' Halfway through, jump somewhere: this rebuilds the whole bubble from
  ' the destination's seeds and charges the tank for the distance.
  IF f = 250 THEN
    Hyperspace selSys
  ENDIF
  SELECT CASE f
    CASE 260 TO 999 : kFaster = 1
  END SELECT
END SUB

' --- both missions, without flying any of them
'
' The missions are a state machine over four bits, so driving those bits
' directly is the honest test of them: every branch of MissionCheck gets
' taken in the order a player would take it, and each briefing is
' photographed on the way past.  What this cannot test is the flying, which
' is the Constrictor turning up in its own system and refusing to die to
' anything but a military laser.
SUB MissionScene
  NewCommander

  ' First: do the three systems the original names actually exist where it
  ' says they do in the galaxies we generate?
  MissionFind 2, 144, 33
  MissionFind 3, 215, 84
  MissionFind 3, 63, 72

  PRINT
  PRINT "mission byte at the start:"; mission
  ' Not enough kills yet, so nothing should happen.
  kills = 100 : gGal = 1
  MissionCheck
  PRINT "after docking with 100 kills:"; mission

  kills = 300
  MissionCheck
  PRINT "after docking with 300 kills:"; mission; " (expect 1)"

  ' In the Constrictor's system now, with the job on.  conHere is what the
  ' arrival code works out; setting it here stands in for flying there.
  gGal = 2 : conHere = 1
  PRINT "in its system, want one?"; WantConstrictor(); " (expect 1)"
  conHere = 0
  PRINT "somewhere else, want one?"; WantConstrictor(); " (expect 0)"

  ' Shoot it down, and dock.
  mission = mission OR MI_1DONE
  gGal = 2
  MissionCheck
  PRINT "after killing it and docking:"; mission; " (expect 2)"
  PRINT "  kills"; kills; " (expect 556)  cash"; cashTenths / 10; " Cr"

  ' Mission two needs the third galaxy and a much better rating.
  gGal = 3
  MissionCheck
  PRINT "third galaxy, 556 kills:"; mission; " (expect 2)"
  kills = 1300
  MissionCheck
  PRINT "third galaxy, 1300 kills:"; mission; " (expect 6)"

  ' Ceerdi, where the plans are picked up.  MissionCheck puts the system
  ' variables back on homeSys, so the fixture has to move homeSys itself.
  MissionGoto 3, 215, 84
  MissionCheck
  PRINT "docked at Ceerdi:"; mission; " (expect 10)"
  PRINT "  carrying the plans?"; CarryingPlans(); " (expect 1)"

  ' Birera, where they are handed over.
  MissionGoto 3, 63, 72
  MissionCheck
  PRINT "docked at Birera:"; mission; " (expect 14)"
  PRINT "  carrying the plans?"; CarryingPlans(); " (expect 0)"
  PRINT "  energy unit"; energyUnit; " (expect 2, the navy's own)"
END SUB

' Make the system at these coordinates the one we are docked at.
SUB MissionGoto(g AS INTEGER, x AS INTEGER, y AS INTEGER)
  LOCAL INTEGER i
  gGal = g
  SetGalaxy g
  FOR i = 0 TO 255
    SysData
    IF sysX = x AND sysYr = y THEN EXIT FOR
    NextSystem
  NEXT i
  homeSys = i : selSys = i
  homeX = sysX : homeY = sysY * 2
END SUB

' Which system sits at these galactic coordinates, if any.
SUB MissionFind(g AS INTEGER, x AS INTEGER, y AS INTEGER)
  LOCAL INTEGER i, found
  found = -1
  SetGalaxy g
  FOR i = 0 TO 255
    SysData
    IF sysX = x AND sysYr = y THEN found = i : EXIT FOR
    NextSystem
  NEXT i
  IF found < 0 THEN
    PRINT "galaxy"; g; " ("; STR$(x); ","; STR$(y); ") - nothing there"
  ELSE
    PRINT "galaxy"; g; " ("; STR$(x); ","; STR$(y); ") is "; SysName$()
  ENDIF
  SetGalaxy gGal
END SUB

' --- what each kind of ship is, and what that makes it do
'
' The NEWB flags decide whether a ship is coming for us or going about its
' business, so this asks each kind directly rather than waiting to be shot
' at.  Peaceful is called a hundred times a row because one of its answers
' is deliberately random: a trader ignores us four times in five.
SUB NewbScene
  LOCAL INTEGER n
  NewCommander
  LaunchState
  PRINT "ship                flags   leaves us alone, clean / fugitive"
  NewbOne T_TRADER, "Cobra III trader"
  NewbOne T_COBRA3, "Cobra III pirate"
  NewbOne T_ANACONDA, "Anaconda"
  NewbOne T_VIPER, "Viper"
  NewbOne T_SIDEWINDER, "Sidewinder"
  NewbOne T_WORM, "Worm"
  NewbOne T_HERMIT, "Rock hermit"
  NewbOne T_THARGOID, "Thargoid"
  NewbOne T_CONSTRICT, "Constrictor"
  PRINT

  ' Shooting an innocent bystander is the station's business as well as ours.
  ClearSlots
  LaunchState
  PRINT "station AI before"; sAI(SLOT_STAR); " legal"; legal
  MATH Q_EULER 0, 0, 0, qA() : qA(4) = 1
  n = NewShip(T_TRADER, 0, 0, 4000, qA())
  IF n >= 0 THEN sAI(n) = 128 OR 56
  Angry n
  PRINT "after shooting a trader: station AI"; sAI(SLOT_STAR); " legal"; legal;
  PRINT " the trader is now hostile?"; (sNewb(n) AND NB_HOSTILE) <> 0

  ClearSlots
  LaunchState
  legal = 0
  MATH Q_EULER 0, 0, 0, qA() : qA(4) = 1
  n = NewShip(T_SIDEWINDER, 0, 0, 4000, qA())
  IF n >= 0 THEN sAI(n) = 128 OR 56
  Angry n
  PRINT "after shooting a pirate:  station AI"; sAI(SLOT_STAR); " legal"; legal
  PRINT
  PRINT "who carries an escape pod:"
  PRINT "  Krait"; (tNewb(T_KRAIT) AND NB_POD) <> 0;
  PRINT "  Gecko"; (tNewb(T_GECKO) AND NB_POD) <> 0;
  PRINT "  Thargoid"; (tNewb(T_THARGOID) AND NB_POD) <> 0
END SUB

SUB NewbOne(t AS INTEGER, nm$)
  LOCAL INTEGER n, i, c0, c1, keep
  MATH Q_EULER 0, 0, 0, qA() : qA(4) = 1
  n = NewShip(t, 0, 0, 4000, qA())
  IF n < 0 THEN PRINT nm$; " - no slot" : EXIT SUB
  sAI(n) = 128 OR 56
  keep = sNewb(n)
  legal = 0
  c0 = 0
  FOR i = 1 TO 100
    sNewb(n) = keep
    IF Peaceful(n) THEN c0 = c0 + 1
  NEXT i
  legal = 60
  c1 = 0
  FOR i = 1 TO 100
    sNewb(n) = keep
    IF Peaceful(n) THEN c1 = c1 + 1
  NEXT i
  PRINT nm$ + SPACE$(20 - LEN(nm$)); keep; SPACE$(6); c0; "%"; SPACE$(4); c1; "%"
  legal = 0
  KillShip n
END SUB

' --- a trader flying itself into the station
'
' The docking flag is only any use if something comes of it, so this puts a
' trader out beyond the station with the flag set and runs the game's own
' movement and tactics until it either docks or gives up.  What it must not
' do is blow up, pay a bounty or count as a kill: it docked, it did not die.
SUB DockNPCScene
  LOCAL INTEGER n, f, gone, k0
  NewCommander
  LaunchState
  ' Put the station in front of us rather than behind, so the ship coming in
  ' is somewhere we could watch it.
  MATH Q_EULER RAD(180), 0, 0, qA() : qA(4) = 1
  KillShip SLOT_STAR
  n = NewShip(T_STATION, 0, 0, 8000, qA())
  IF n >= 0 THEN sRol(n) = 255 : sAI(n) = 1
  dSpeed = 0

  ' A trader, well beyond the station, told to dock.
  newbFlags = NB_DOCKING
  n = NewFacing(T_TRADER, 600, -400, 14000, 180)
  IF n < 0 THEN PRINT "no slot for the trader" : EXIT SUB
  sSpd(n) = 20
  sAI(n) = 128 OR 64
  k0 = kills
  PRINT "trader in slot"; n; " flags"; sNewb(n); " at range"; ShipRange(n)
  PRINT "station at z"; sZ(SLOT_STAR)
  gone = 0
  ' One whole tick an iteration.  This drives the game's own movement without
  ' the frame clock, so the run is the same every time and takes no longer
  ' than the arithmetic does.
  tick = 1
  tickWhole = 1
  FOR f = 1 TO 4000
    MoveShips
    Tactics
    mcnt = (mcnt + 1) AND 255
    IF sTyp(n) <> T_TRADER THEN gone = f : EXIT FOR
    IF (f AND 255) = 0 THEN PRINT "  frame"; f; " range"; ShipRange(n); " speed"; sSpd(n)
  NEXT f
  IF gone THEN
    PRINT "docked at frame"; gone
  ELSE
    PRINT "still out there after 4000 frames, range"; ShipRange(n)
  ENDIF
  PRINT "kills went from"; k0; "to"; kills; " (must not change)"
  PRINT "slots in use"; nUsed; " (planet, station)"
END SUB

FUNCTION ShipRange(n AS INTEGER) AS INTEGER
  LOCAL FLOAT dx, dy, dz
  dx = sX(n) - sX(SLOT_STAR)
  dy = sY(n) - sY(SLOT_STAR)
  dz = sZ(n) - sZ(SLOT_STAR)
  ShipRange = SQR(dx*dx + dy*dy + dz*dz)
END FUNCTION

SUB SaveShot(f AS INTEGER)
  SAVE IMAGE "A:/fly" + STR$(f) + ".bmp"
END SUB

' One-shot diagnostic: what is actually in the bubble, and would the
' laser's alignment test accept it?
SUB DumpSlots
  LOCAL INTEGER n
  PRINT "slots at frame 60, nUsed"; nUsed; " fore laser"; lasView(0)
  FOR n = 0 TO nUsed - 1
    PRINT "  "; n; " typ"; sTyp(n); " bp"; sBp(n); " obj"; sObj(n);
    PRINT " x"; STR$(sX(n), 0, 0); " y"; STR$(sY(n), 0, 0); " z"; STR$(sZ(n), 0, 0);
    IF sBp(n) >= 0 THEN
      PRINT " area"; bArea(sBp(n)); " ene"; sEne(n); " ai"; sAI(n);
      IF ABS(sX(n)) < 256 AND ABS(sY(n)) < 256 AND sZ(n) > 0 THEN
        IF sX(n)*sX(n) + sY(n)*sY(n) < bArea(sBp(n)) THEN PRINT " <- IN THE SIGHTS";
      ENDIF
    ENDIF
    PRINT
  NEXT n
END SUB

' A scene that exists only to prove the docking approach: the station
' ahead with its slot facing us, and the computer flying us in.  The
' station rolls all the time, so the alignment test is only satisfied for
' part of each turn - the approach has to arrive at the right moment.
SUB DockScene
  LOCAL INTEGER n
  pRoll = JCENTRE : pPitch = JCENTRE
  pEnergy = 255 : pFsh = 255 : pAsh = 255 : pFuel = 70
  pCabT = 30 : pLasT = 0 : pAltit = 200 : pMissl = 3
  cashTenths = 1000 : holdSize = 20
  lasView(0) = LAS_PULSE : kills = 0 : dead = 0 : docked = 0
  vw = 0 : inWitch = 0 : msLock = -1
  InitStardust
  LoadMarket
  gGal = 1
  SetGalaxy 1
  FOR n = 0 TO 255
    SysData
    IF SysName$() = "LAVE" THEN EXIT FOR
    NextSystem
  NEXT n
  homeSys = n : selSys = n
  homeX = sysX : homeY = sysY * 2
  curX = homeX : curY = homeY

  ClearSlots
  StationBlueprint
  MATH Q_EULER RAD(35), RAD(40), 0, qA() : qA(4) = 1
  n = NewShip(T_CRATER, 0, -20000, 3 * UNIT, qA())
  IF n >= 0 THEN sRol(n) = 127

  ' Slot towards us, and turning as it always does.
  MATH Q_EULER RAD(180), 0, 0, qA() : qA(4) = 1
  n = NewShip(T_STATION, 0, 0, 7000, qA())
  IF n >= 0 THEN sRol(n) = 255 : sAI(n) = 1
  dSpeed = 0
  inSafe = 1
  mcnt = 0
  eqOwned(EQ_DOCK) = 1 : dockComp = 1
END SUB

SUB DockInput(f AS INTEGER)
  kRollL = 0 : kRollR = 0 : kUp = 0 : kDn = 0
  kFaster = 0 : kSlower = 0 : kFire = 0 : kQuit = 0
  kTarget = 0 : kMissile = 0 : kECM = 0 : kDock = 0
  kJump = 0 : kChart = 0
END SUB

' Draw each docked screen once and photograph it.  Nothing here is
' interactive: it exists to prove the screens render from real state.
SUB DockedScreens
  LOCAL INTEGER n, i
  pFuel = 44 : cashTenths = 1000 : holdSize = 20
  pEnergy = 255 : pFsh = 255 : pAsh = 255 : pMissl = 3
  lasView(0) = LAS_PULSE : kills = 20 : legal = 0 : docked = 1 : energyUnit = 0
  gGal = 1
  LoadMarket
  EquipTable
  SetGalaxy 1
  FOR n = 0 TO 255
    SysData
    IF SysName$() = "LAVE" THEN EXIT FOR
    NextSystem
  NEXT n
  homeSys = n : selSys = n
  homeX = sysX : homeY = sysY * 2
  curX = homeX : curY = homeY
  mkByte = 0
  MakeMarket sysEco, mkByte

  ' Trade a little so the screens have something to show.
  FOR i = 1 TO 5 : BuyOne 0 : NEXT i        ' five tonnes of food
  FOR i = 1 TO 3 : BuyOne 12 : NEXT i       ' and some minerals
  eqOwned(EQ_ECM) = 1                       ' fitted with E.C.M.

  MarketScreen 6
  FRAMEBUFFER COPY F, N
  SAVE IMAGE "A:/dock_market.bmp"
  StatusScreen
  FRAMEBUFFER COPY F, N
  SAVE IMAGE "A:/dock_status.bmp"
  EquipScreen 2
  FRAMEBUFFER COPY F, N
  SAVE IMAGE "A:/dock_equip.bmp"
  InventoryScreen
  FRAMEBUFFER COPY F, N
  SAVE IMAGE "A:/dock_inv.bmp"

  PRINT "cash after trading "; STR$(cashTenths / 10); " Cr, hold "; STR$(HoldUsed()); "/"; STR$(holdSize)
  SaveCommander "A:/cmdr.txt"
  cashTenths = 0 : kills = 0
  IF LoadCommander("A:/cmdr.txt") THEN
    PRINT "commander reloaded: cash "; STR$(cashTenths / 10); " Cr, kills "; STR$(kills); ", at "; SysName$()
  ELSE
    PRINT "** commander file did not load **"
  ENDIF
END SUB
