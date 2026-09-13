' =====================================================================
'  The traffic: who turns up, and why
'
'  Once every 256 frames the original decides whether to put something new
'  in the bubble.  It is three decisions taken in order, and each one can
'  end the pass:
'
'    1  something harmless - a trader, an asteroid, a cargo canister
'    2  the police, if our record or our cargo hold warrants it
'    3  a bounty hunter, a Thargoid, or a pack of pirates
'
'  The second is what makes Elite a game rather than a shooting gallery.
'  It weighs the hold - slaves and narcotics count double, firearms once -
'  and doubles that, and if a Viper is already nearby it takes the worse of
'  the result and our legal record, because by then they have scanned us.
'  A random byte is drawn against the total, so a clean ship carrying
'  nothing is almost never troubled, while a full hold of slaves brings a
'  Viper on nearly every pass.  Nothing here asks whether we have done
'  anything: it asks what we are carrying and what is on our record, and
'  those two are the whole of the player's relationship with the law.
'
'  The third asks the system's government.  An anarchy always rolls the
'  dice; everywhere else has to pass two tests that the safer governments
'  fail more often, which is why the trouble on the chart is always in the
'  Feudal and Anarchic systems.
'
'  Witchspace spawns nothing - what is out there arrived with us - and
'  neither does the inside of a station's safe zone, except for traders.
' =====================================================================

SUB SpawnTraffic
  IF mcnt <> 0 THEN EXIT SUB              ' once every 256 frames, as MCNT
  IF docked OR dead OR inWitch THEN EXIT SUB
  ' --- 1: something harmless, on one pass in eight
  IF INT(RND * 256) < 35 THEN
    IF CountType(T_ASTEROID) < 3 THEN
      IF SpawnBenign() THEN EXIT SUB
    ENDIF
  ENDIF
  ' Nothing hostile is ever created inside the station's zone.
  IF inSafe THEN EXIT SUB
  IF SpawnPolice() THEN EXIT SUB
  SpawnHostiles
END SUB

' A trader, a rock or a canister, a long way off and off to one side.
' Returns 1 when this is the whole of the pass: a trader is, and so is
' being inside the safe zone, where nothing else may be created.
FUNCTION SpawnBenign() AS INTEGER
  LOCAL INTEGER n, t
  LOCAL FLOAT x, y, z
  SpawnBenign = 0
  z = 38 * 256                            ' far enough to be a dot at first
  x = INT(RND * 256)
  IF RND < 0.5 THEN x = x + 512           ' and sometimes half a unit further
  IF RND < 0.5 THEN x = -x
  y = INT(RND * 256)
  IF RND < 0.5 THEN y = -y

  IF RND < 0.5 THEN
    ' A Cobra Mk III on its way somewhere, with no AI at all: it will not
    ' evade, it will not shoot, and it will not thank you for either.
    n = NewFacing(TraderShip(), x, y, z, 180)
    IF n >= 0 THEN
      sAI(n) = 0
      sSpd(n) = 16 + INT(RND * 16)
      sRol(n) = INT(RND * 128)            ' clockwise, and rarely undamped
    ENDIF
    SpawnBenign = 1
    EXIT FUNCTION
  ENDIF

  ' The station keeps its own space clear of rocks.
  IF inSafe THEN SpawnBenign = 1 : EXIT FUNCTION
  ' The original's own proportions: a rock hermit about one pass in eighty, a
  ' canister about one in fifty, and otherwise a boulder or an asteroid evenly.
  IF INT(RND * 256) >= 252 THEN
    t = T_HERMIT
  ELSEIF INT(RND * 256) < 5 THEN
    t = T_CANISTER
  ELSEIF RND < 0.5 THEN
    t = T_BOULDER
  ELSE
    t = T_ASTEROID
  ENDIF
  n = NewFacing(t, x, y, z, 180)
  IF n >= 0 THEN
    ' Tumbling: half of them roll and travel, half pitch on the spot, and
    ' half of each turn for ever rather than winding down.
    IF RND < 0.5 THEN
      sSpd(n) = 16 + INT(RND * 16)
      sRol(n) = INT(RND * 256) OR 111
    ELSE
      sPit(n) = INT(RND * 256) OR 127
    ENDIF
  ENDIF
END FUNCTION

' The police.  Returns 1 if a Viper is about, whether it has just arrived
' or was already here - either way the law is this pass's business.
FUNCTION SpawnPolice() AS INTEGER
  LOCAL INTEGER bad, n
  bad = Contraband() * 2
  ' A Viper already in the bubble has had a good look at us, so our record
  ' counts as well as the hold - whichever of the two is worse.
  IF CountType(T_VIPER) > 0 THEN bad = bad OR legal
  IF INT(RND * 256) < bad THEN n = Aggressor(T_VIPER, 0)
  SpawnPolice = 0
  IF CountType(T_VIPER) > 0 THEN SpawnPolice = 1
END FUNCTION

' A lone bounty hunter, something much worse, or a pack of pirates.
SUB SpawnHostiles
  LOCAL INTEGER r, i, t, ai, cnt, n
  ' Not every pass: the last spawning sets how many to sit out.
  spawnEV = spawnEV - 1
  IF spawnEV >= 0 THEN EXIT SUB
  spawnEV = 0

  r = INT(RND * 256)
  IF sysGov <> 0 THEN
    ' Anywhere but an anarchy has to pass both of these, and the higher the
    ' government number the safer the system, so the more often it does not.
    IF r >= 90 THEN EXIT SUB
    IF (r AND 7) < sysGov THEN EXIT SUB
  ENDIF

  r = INT(RND * 256)
  IF r >= 200 THEN
    ' One to four pirates, and a rest afterwards.  The cassette game has only
    ' Sidewinders and Mambas to send; the Second Processor version has a pack
    ' of eight to draw from.
    cnt = INT(RND * 4)
    spawnEV = cnt
    FOR i = 0 TO cnt
      n = Aggressor(PackShip(), 0)
    NEXT i
    EXIT SUB
  ENDIF

  ' A lone hunter in something serious, and a pass off afterwards.
  spawnEV = spawnEV + 1
  t = (r AND 3) + 3                       ' Mamba, Python, Cobra Mk III, Thargoid
  ai = 192
  IF INT(RND * 256) >= 200 THEN ai = ai OR 1     ' 22 per cent carry an E.C.M.
  IF t = T_THARGOID THEN
    ' And only sometimes, because a Thargoid is not a bounty hunter.
    IF INT(RND * 256) >= 200 THEN
      ' Once in thirty-two it is not a Thargoid at all but a Cougar, which is
      ' the rarest thing in Elite.  The Second Processor version reaches this
      ' test by another road - its police check, one draw in 256 - but the
      ' test itself is the original's: five bits of the planet's z, and a
      ' Cougar only when every one of them is zero.  Reached from here the
      ' odds work out at about one spawning in nine thousand, which is what
      ' they are in the Second Processor version too.
      IF (INT(ABS(sZ(SLOT_PLANET))) AND 62) = 0 THEN
        ' No AI, so it sits there minding its own business: the original's
        ' way of giving it a cloaking device it has no code for.  Shoot at it
        ' and the laser turns its AI on, and then it has an E.C.M., sixty
        ' aggression out of sixty-three, four missiles and a beam laser.
        n = Aggressor(T_COUGAR, 121)
        IF n >= 0 THEN sSpd(n) = 18
      ELSE
        IF Aggressor(T_THARGOID, ai) >= 0 THEN n = Aggressor(T_THARGON, 129)
      ENDIF
    ENDIF
    EXIT SUB
  ENDIF
  ' Everything but the Thargoid is a lone bounty hunter, and the Second
  ' Processor version puts a heavier ship in that seat than the cassette game
  ' does: a Cobra Mk III, an Asp, a Python or a Fer-de-Lance.
  n = Aggressor(HunterShip(), ai)
END SUB

' The eight a pirate group is drawn from, in the original's own order.  It
' chooses with the AND of two random numbers, so a bit is set only a quarter
' of the time and the small fighters at the bottom of the list come up far
' more often than the Cobra at the top.
FUNCTION PackShip() AS INTEGER
  LOCAL INTEGER i
  i = (INT(RND * 256) AND INT(RND * 256)) AND 7
  SELECT CASE i
    CASE 0 : PackShip = T_SIDEWINDER
    CASE 1 : PackShip = T_MAMBA
    CASE 2 : PackShip = T_KRAIT
    CASE 3 : PackShip = T_ADDER
    CASE 4 : PackShip = T_GECKO
    CASE 5 : PackShip = T_COBRA1
    CASE 6 : PackShip = T_WORM
    CASE ELSE : PackShip = T_COBRA3
  END SELECT
END FUNCTION

FUNCTION HunterShip() AS INTEGER
  SELECT CASE INT(RND * 4)
    CASE 0 : HunterShip = T_COBRA3
    CASE 1 : HunterShip = T_ASP
    CASE 2 : HunterShip = T_PYTHON
    CASE ELSE : HunterShip = T_FERDELANCE
  END SELECT
END FUNCTION

' A trader flies whatever the route will bear.  The cassette game has only the
' Cobra Mk III; the Second Processor version adds the two fat ones, which is
' why a magenta blip on the scanner is worth a look.
FUNCTION TraderShip() AS INTEGER
  SELECT CASE INT(RND * 4)
    CASE 0 : TraderShip = T_PYTHON
    CASE 1 : TraderShip = T_BOA
    CASE 2 : TraderShip = T_ANACONDA
    CASE ELSE : TraderShip = T_COBRA3
  END SELECT
END FUNCTION

' The original's Ze: a ship a fair way off in one of the four corners,
' already hostile.  Bit 7 of the AI flag means it has AI at all and bits
' 1 to 6 are how aggressive it is; 192 is the least it is ever given.
' It arrives stationary and its own tactics wind it up to speed.
FUNCTION Aggressor(t AS INTEGER, ai AS INTEGER) AS INTEGER
  LOCAL INTEGER n, a
  LOCAL FLOAT x, y
  x = 8192 : IF RND < 0.5 THEN x = -x
  y = 8192 : IF RND < 0.5 THEN y = -y
  a = ai
  IF a = 0 THEN
    a = 192
    IF INT(RND * 256) >= 245 THEN a = a OR 1     ' 4 per cent carry an E.C.M.
  ENDIF
  n = NewFacing(t, x, y, 8192, 180)
  IF n >= 0 THEN sAI(n) = a
  Aggressor = n
END FUNCTION

' What is in the hold that we would rather the police did not see.  Slaves
' and narcotics are twice as illegal as firearms, which is the original's
' own arithmetic and the reason a hold of slaves is such a bad idea.
FUNCTION Contraband() AS INTEGER
  Contraband = (cargo(3) + cargo(6)) * 2 + cargo(10)
END FUNCTION

FUNCTION CountType(t AS INTEGER) AS INTEGER
  LOCAL INTEGER n, c
  c = 0
  FOR n = 2 TO nUsed - 1
    IF sTyp(n) = t THEN
      IF sExp(n) = 0 THEN c = c + 1
    ENDIF
  NEXT n
  CountType = c
END FUNCTION
