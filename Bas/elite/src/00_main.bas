' =====================================================================
'  E L I T E        PicoMite MMBasic, PicoComputer 3
'  after the 1984 BBC Micro game by Ian Bell and David Braben
'
'  Phase 2: the flight core.  Universe slots, player controls, ship
'  movement, the four views, ship / planet / sun / stardust rendering,
'  the dashboard and the 3D scanner.  No trading, no galaxy, no combat
'  yet - those are phases 3 and 4.
'
'  Geometry.  The BBC space view is 256 x 192 pixels centred on
'  (128, 96), with the dashboard in the bottom 64 rows of a 256 row
'  screen.  Ours is 320 x 176 centred on (160, 88) with the dashboard in
'  rows 176..239, and the projection keeps the BBC's focal length of 256
'  pixels, so every ship is exactly the size it was in 1984 and the
'  extra width is extra peripheral vision.
'
'  Ship meshes and statistics come straight out of the original 6502
'  source: Bas/elite_tools/blueprints.py turns the SHIP_* blueprints
'  into the DATA blocks at the end of this file.
'
'  Built by elite_tools/build.py from src/*.bas - do not edit elite.bas.
' =====================================================================
' The trace cache compiles each statement to bytecode on its first run and
' replays it thereafter, which removes the variable-name lookups and the
' re-parsing that dominate an interpreted frame loop.  It has to come before
' OPTION EXPLICIT and the DIMs, because those invalidate its entries.  The
' two named SUBs are the per-particle and per-contact loops, where the same
' handful of statements run hundreds of times a frame.
' Rounded up to 128 slots by the firmware.  100 rather than 80 because the
' PicoCalc needs the extra: DrawStardust alone fills a smaller cache.
OPTION TRACECACHE ON 100
OPTION CACHE DEBUG ON
'OPTION PROFILING ON                ' [PERF] report of the hottest statements
OPTION CACHE SUB DrawStardust, DrawScanner

OPTION EXPLICIT
OPTION BASE 0
OPTION DEFAULT NONE

' ------------------------------------------------------------ geometry
CONST SCRW = 320, SCRH = 240
CONST VIEWH = 176                  ' space view occupies rows 0..VIEWH-1
CONST VCX = 160, VCY = 88          ' space view centre
CONST DASHY = 176                  ' first dashboard row
CONST VPLANE = 256                 ' focal length in pixels, as the BBC
CONST DEMOFRAMES = 0               ' >0 runs a scripted demo and exits; 0 plays
CONST DEMOSCENE = 1                ' 1 flight and combat, 2 docking, 3 the docked
                                   ' screens, 4 the ship hangar, 5 the briefings,
                                   ' 6 both missions end to end, 7 the NEWB flags,
                                   ' 8 a trader docking itself, 9 the hyperspace
                                   ' countdown and what a hit costs
CONST PANY = VCY - (SCRH \ 2 - 1)  ' shifts Draw3D's centre up to VCY

' ------------------------------------------------------- universe size
' NOSH: planet, sun or station, and the ships.  The cassette game allows ten
' ships and four police; the Second Processor version, with a whole second
' computer to spend, allows eighteen and seven.  Only maxObj of them can hold
' a mesh at once - the rest are drawn as the original's distant dashes.
CONST NSLOT = 20
CONST NBP = 29                     ' twelve from the cassette, seventeen more from
                                   ' the 6502 Second Processor version
CONST SLOT_PLANET = 0              ' FRIN slot 0 is always the planet
CONST SLOT_STAR = 1                ' slot 1 is the sun or the station

' -------------------------------------------------------- Elite scales
CONST PRADIUS = 24576              ' planet radius, (96 0) in the original
CONST FAROFF = 57344               ' beyond this on any axis a ship is gone
CONST SAFEZONE = 49152             ' station safe zone, (192 0)

' -------------------------------------------------------- object types
CONST T_PLANET = 128, T_SUN = 129, T_CRATER = 130
CONST T_SIDEWINDER = 1, T_VIPER = 2, T_MAMBA = 3, T_PYTHON = 4
CONST T_COBRA3 = 5, T_THARGOID = 6, T_TRADER = 7, T_STATION = 8
CONST T_MISSILE = 9, T_ASTEROID = 10, T_CANISTER = 11, T_THARGON = 12
CONST T_ESCAPE = 13, T_COUGAR = 14
' The 6502 Second Processor version's ships.  The first six are the pack a
' group of pirates is drawn from, then the two a lone bounty hunter flies, the
' two big traders, and the rubble.
CONST T_KRAIT = 15, T_ADDER = 16, T_GECKO = 17, T_COBRA1 = 18, T_WORM = 19
CONST T_ASP = 20, T_FERDELANCE = 21
CONST T_BOA = 22, T_ANACONDA = 23
CONST T_BOULDER = 24, T_SPLINTER = 25, T_HERMIT = 26
' Station traffic: the two the station sends out, and the two the hangar
' shows you standing on the deck when you dock.
CONST T_SHUTTLE = 27, T_TRANSPORT = 28
' The ship mission one is about, which appears in exactly one system and is
' the only thing in the game a military laser is needed for.
CONST T_CONSTRICT = 29
' The original carries what a ship is in its type as well as in its flags, and
' keeps two entries for the two ships that fly on both sides of the law: a
' Cobra Mk III and a Python for the trade lanes, and another of each for the
' pirates.  Same blueprint, same statistics, different flags - and ours does
' the same, with T_TRADER as the honest Cobra and T_PYTHONP as the dishonest
' Python.
CONST T_PYTHONP = 30
CONST NTYPE = 30                   ' highest ship type number

' ============================================================ globals
' Player.  pRoll and pPitch are the original's JSTX and JSTY: 1..255
' centred on 128.  alp1 / bet1 are the magnitudes the game derives from
' them, alp2 / bet2 the signs, and alpha / beta the same angles in
' radians for the rotation maths.
DIM INTEGER pRoll, pPitch, alp1, alp2, bet1, bet2, dSpeed
DIM FLOAT alpha, beta
DIM INTEGER pEnergy, pFsh, pAsh, pFuel, pCabT, pLasT, pAltit, pMissl
DIM INTEGER vw                     ' 0 front, 1 rear, 2 left, 3 right
DIM INTEGER mcnt                   ' the original's main loop counter
DIM INTEGER inSafe                 ' inside the station's safe zone

' Universe slots, as parallel arrays.  sObj is the Draw3D object number
' this slot owns, or 0 when it has none and is drawn as a dot.
DIM INTEGER sTyp(NSLOT-1), sBp(NSLOT-1), sObj(NSLOT-1)
DIM FLOAT sX(NSLOT-1), sY(NSLOT-1), sZ(NSLOT-1)
DIM FLOAT sQ(4, NSLOT-1)           ' orientation quaternion w,x,y,z,m
DIM INTEGER sSpd(NSLOT-1), sAcc(NSLOT-1), sRol(NSLOT-1), sPit(NSLOT-1)
DIM INTEGER sEne(NSLOT-1), sAI(NSLOT-1), sFlg(NSLOT-1), sExp(NSLOT-1)
DIM INTEGER sTgt(NSLOT-1)   ' a missile's quarry: a slot, or -2 for us
' The disc version's NEWB flags, byte #36.  sAI is the original's byte #32 and
' says how a ship behaves; this says what it is, and the two are not the same
' question - a Viper and a pirate can both be flying at us with the same
' aggression, but only one of them is a policeman, and shooting it has
' consequences the other one does not.
'
' Bit 7 means two things in the original and it means them here too: in the
' table of defaults it says the ship type carries an escape pod, and on a ship
' in the bubble it says the ship has docked or been scooped.  A spawned ship
' therefore starts with bits 4 and 7 cleared, and whether a pilot has a pod to
' bail out in is asked of the table, not of the ship.
CONST NB_TRADER = 1, NB_HUNTER = 2, NB_HOSTILE = 4, NB_PIRATE = 8
CONST NB_DOCKING = 16, NB_INNOCENT = 32, NB_COP = 64, NB_POD = 128
' Bit 7 again, under the name it goes by on a ship rather than in the table:
' this one has docked or been scooped and is on its way out of the bubble.
CONST NB_GONE = 128
DIM INTEGER sNewb(NSLOT-1)
DIM INTEGER tNewb(NTYPE)
' Staged for the next ship created, which is how the original does it: the
' spawner sets NEWB, NWSHP ORs it into the new ship and it is cleared again.
DIM INTEGER newbFlags
DIM INTEGER sMis(NSLOT-1)   ' missiles this ship still has to fire at us
DIM INTEGER nUsed                  ' slots in use, 0..NSLOT

' Ship blueprint statistics, indexed by blueprint 0..NBP-1.
DIM bName$(NBP-1) LENGTH 16
DIM INTEGER bNv(NBP-1), bNf(NBP-1), bNfv(NBP-1), bNf0(NBP-1), bNv0(NBP-1)
DIM INTEGER bCan(NBP-1), bArea(NBP-1), bBty(NBP-1), bVis(NBP-1)
DIM INTEGER bEne(NBP-1), bSpd(NBP-1), bLas(NBP-1), bMis(NBP-1)
DIM INTEGER bGun(NBP-1), bExp(NBP-1), bSize(NBP-1)
DIM INTEGER tBp(NTYPE)             ' ship type 1..NTYPE -> blueprint index

' Scratch mesh buffers, big enough for the largest blueprint (Missile:
' 33 vertices, 25 polygons, 80 face-vertex entries).
DIM FLOAT mV(2, 47), mNrm(2, 15)
DIM INTEGER mFc(31), mHost(31), mF(159), mEc(31), mFl(31)
DIM INTEGER col(7)
' The 6502 Second Processor version's two colour tables, shpcol and scacol,
' keyed on our own type numbers: what colour a ship is drawn in the space
' view, and what colour its blip is on the scanner.  shpCol holds an index
' into col() because a mesh's edge colours are chosen when it is created;
' scaCol holds the colour itself.
DIM INTEGER shpCol(NTYPE), scaCol(NTYPE)
CONST C_WHITE = 0, C_CYAN = 1, C_YELLOW = 2, C_RED = 3
DIM INTEGER cGreen, cYellow, cWhite, cBlack, cCyan, cDim, cRed, cSel
DIM INTEGER cMagenta, cBlue

' Draw3D object pool.  objOwn(n) is the slot that owns object n, or -1.
DIM INTEGER maxObj, objOwn(35)

' Quaternion scratch.  Draw3D and MATH both want a 5 element float array.
DIM FLOAT qA(4), qB(4), qC(4), qV(4), qP(4), vwQ(4, 3)

' Keyboard flags, refreshed once per frame.
DIM INTEGER kRollL, kRollR, kUp, kDn, kFaster, kSlower, kFire, kQuit
DIM INTEGER kView, kPause, kTarget, kMissile, kECM, kDock, kJump, kChart
DIM INTEGER kBomb, kHop, kGal
' KEYDOWN reports what is held, not what has just been pressed, so the
' one-shot keys are turned into edges against the previous frame's set.
DIM INTEGER kHeld
CONST KB_TARGET = 1, KB_MISSILE = 2, KB_ECM = 4, KB_DOCK = 8, KB_JUMP = 16
CONST KB_SCREEN = 32               ' F5, then one bit per key up to F10
CONST KB_SCREENS = 32+64+128+256+512+1024
CONST KB_BOMB = 2048, KB_HOP = 4096, KB_GAL = 8192

' Frame timing.  tFlight accumulates only the time spent flying, so the
' average is not diluted by however long the player spends docked.
DIM FLOAT frameMs, tFrame, tStage, tFlight
DIM INTEGER frames

DIM FLOAT prof(5)                  ' cls, stardust, planet, ships, dash, move

' The galaxy.  Three 16-bit seeds and the fields the current system's
' seeds decode to.  The two-letter fragments names are built from are
' held as one string and indexed rather than as 32 separate entries.
DIM INTEGER gs0, gs1, gs2, gSys, gGal
' sysY is halved, because that is what both charts plot and what the distance
' between two systems is worked out from.  sysYr is the original's own QQ1,
' unhalved: the missions name their systems by exact coordinates and the
' bottom bit of y is the difference between one system and its neighbour.
DIM INTEGER sysX, sysY, sysYr, sysGov, sysEco, sysTech, sysPop, sysProd, sysRad
' Where we are, where the chart cursor is, and which system it picked.
' All in raw galaxy coordinates: y is the unhalved value, and the charts
' halve it themselves.
DIM INTEGER homeX, homeY, homeSys, curX, curY, selSys, inWitch
CONST DIGRAPHS = "ALLEXEGEZACEBISOUSESARMAINDIREA?ERATENBERALAVETIEDORQUANTEISRION"

' The market: seventeen commodities, priced from the system's economy and
' the one random byte drawn on arrival.
' Combat.  The laser does not travel: firing tests what is lined up and
' hits it at once, so the only timing is how often it can be fired and
' how hot it has got.
' Iterations between pulse laser shots.  The original's LASCT is 10 at 50 Hz,
' which it documents as five pulses a second; at twelve iterations a second
' the nearest whole number is 2.
CONST LASPULSE = 2
DIM INTEGER lasTimer, lasFlash, kills, dead, energyUnit, shots, hits
' The original's TP: four bits that are the whole of both missions.  It is
' saved with the commander, because a mission half done has to survive being
' put down.
'   bit 0  mission 1 in progress     bit 2  mission 2 started
'   bit 1  mission 1 completed       bit 3  the plans are aboard
CONST MI_1RUN = 1, MI_1DONE = 2, MI_2RUN = 4, MI_2PLANS = 8
DIM INTEGER mission
' Set while we are in the Constrictor's own system, worked out on arrival.
DIM INTEGER conHere
' A mount for each view, holding that laser's power, as the original: 15 is
' a pulse laser and 143 a beam.  A new commander has one on the front only.
DIM INTEGER lasView(3)
' Docking.  All five approach tests are angles, expressed as fractions of
' a unit vector: about 26 degrees off the slot's face, 22 degrees off dead
' ahead, and 34 degrees of roll.
CONST DOCKRANGE = 280              ' touching distance: the station spans 160
CONST DOCKFACE = 0.896             ' the station's nose back towards us
CONST DOCKCONE = 0.927             ' how nearly dead ahead it must be
CONST DOCKROLL = 0.833             ' 80 of 96: the slot within 33.6 deg of level
' What a ship flying itself in has to do before it goes for the slot.  The
' original will not let it accelerate until its wings lie along the letterbox
' - 33 out of 96 - and until then it slows right down and waits for the
' station's own roll to bring the slot round to it.
CONST DOCKAPPR = 2200              ' near enough to start caring about the slot
CONST DOCKALIGN = 0.344            ' 33 of 96

CONST MSTURN = 0.22                ' how hard a missile swings onto a bearing
CONST ECMFRAMES = 32               ' the original's countdown, in iterations
DIM INTEGER msLock, ecmActive, legal, docked, dockComp
' The hyperspace countdown.  hypCount is the number on the screen, hypTick the
' internal counter that steps it: the original starts both at 15 and resets the
' internal one to 5 after each step, so the first second of the countdown is
' three times as long as the ones that follow.
DIM INTEGER hypCount, hypTick
' Whose E.C.M. is going off: only ours costs us energy to run.
DIM INTEGER ecmMine
' The original's EV: how many spawning passes to sit out before the next
' bounty hunter or pack of pirates, so the bubble does not fill up at once.
DIM INTEGER spawnEV

' Arrival distances are in units of the step the original's sign byte moves in.
CONST UNIT = 65536                 ' one step of the original's sign byte
CONST LAUNCHSPD = 12               ' speed immediately after launching

' Chart geometry, converted from the original x * 1.25.
CONST CHTOP = 24                   ' first chart row, under the title rule
CONST SRCX = 130                   ' short range chart centre, ours
CONST SRCY = 90
CONST SRDX = 5                     ' our pixels per galaxy unit across
CONST SRDY = 2                     ' and down

' Equipment on offer, gated by the system's technology level.
CONST NEQUIP = 13
' Rows of the shop that other code has to know about by name.
CONST EQ_ECM = 2, EQ_PULSE = 3, EQ_BEAM = 4, EQ_SCOOPS = 5, EQ_POD = 6
CONST EQ_BOMB = 7, EQ_ENERGY = 8, EQ_DOCK = 9, EQ_GALHYP = 10
' The disc version's two extra lasers, in its own order and at the same
' place in the list - which is why both appear at once, at tech level 9.
CONST EQ_MILITARY = 11, EQ_MINING = 12
' A laser is a power with bit 7 meaning it fires continuously rather than in
' pulses, which is the original's own encoding.  A beam is a pulse laser that
' does not stop; a military laser is a beam at half again the damage; and a
' mining laser hits far harder than any of them but only in pulses, and is the
' only thing that will break an asteroid up.
CONST LAS_PULSE = 15, LAS_BEAM = 143
CONST LAS_MINING = 50                  ' Mlas in the original
CONST LAS_MILITARY = 151               ' INT(128.5 + 1.5 * 15), as the original
' The disc version's extended token table, its two-letter digrams and the
' base token of each random group - all generated into data/tokens.bas.
DIM tk$(255) LENGTH 160
DIM dg$(31) LENGTH 2
DIM INTEGER rgBase(37)
DIM INTEGER rndS(3)                ' the original's four byte random state
' Four tokens are longer than a string can hold, and all four are mission
' briefings.  Each is generated in parts that join back up into the whole
' token, and the expander walks them one after another.  tokens.py prints the
' two figures these have to cover every time it runs.
CONST NLONG = 4, NLPART = 16
DIM INTEGER ltNo(NLONG-1), ltFirst(NLONG-1), ltCnt(NLONG-1)
DIM ltPart$(NLPART-1) LENGTH 160
' A briefing borrows a few phrases from the standard token table, which is a
' different table with a different encoding.  Carrying all 147 of them for
' three phrases is not worth it, so tokens.py expands those three.
CONST NSTD = 3
DIM INTEGER stdNo(NSTD-1)
DIM stdTx$(NSTD-1) LENGTH 20
' Control code 4 prints the commander's name, which the status screen has
' always had hard coded.
CONST CMDRNAME$ = "JAMESON"
' Setting a briefing: the line being built, the word not yet placed on it,
' the row it goes on and the column it starts at.
CONST BRWIDE = 36, BRLEFT = 20, BRTOP = 24, BRROW = 9
DIM brLine$ LENGTH 60
DIM brWord$ LENGTH 32
DIM INTEGER brY, brCol, brShip
DIM descBuf$ LENGTH 250
' How the token table's letters are cased on the way out.  The original keeps
' three flags and this is the same three: DTW1/DTW6 become dtCase, DTW2 becomes
' dtInWord and DTW8 becomes dtCapNext.
'   dtCase 0  all caps - print the letters as the table stores them
'          1  sentence case - lower, except the first letter of each word
'          2  lower case - lower, with no exceptions
CONST DT_CAPS = 0, DT_SENT = 1, DT_LOWER = 2
DIM INTEGER dtCase, dtInWord, dtCapNext
' Where expanded text goes: 0 builds up descBuf$ for the data screen, 1 sets
' it straight onto a briefing page, which is far longer than a string.
DIM INTEGER dtSink, dtStd
' The token expander's own stack.  Eleven deep is what a description
' actually reaches; sixteen leaves room and costs nothing.
CONST EXDEPTH = 15
DIM INTEGER exTok(EXDEPTH), exPos(EXDEPTH), exPart(EXDEPTH)

DIM eqName$(NEQUIP-1) LENGTH 24    ' "Extra Military Lasers" is 21 of them
DIM INTEGER eqPrice(NEQUIP-1), eqTech(NEQUIP-1), eqOwned(NEQUIP-1)

CONST NGOODS = 17
DIM mkName$(NGOODS-1) LENGTH 14, mkUnit$(NGOODS-1) LENGTH 2
DIM INTEGER mkBase(NGOODS-1), mkFact(NGOODS-1), mkQty(NGOODS-1), mkMask(NGOODS-1)
DIM INTEGER mkPrice(NGOODS-1), mkStock(NGOODS-1), mkByte
DIM INTEGER cargo(NGOODS-1), holdSize, cashTenths

' Rendering options and the view transform's output.
DIM INTEGER solidMode, showDot, shotNo
' The station is the one mesh given faces as well as edges, so that it
' blots out the planet behind it instead of showing its lines through.
CONST BP_CORIOLIS = 6, C_FILL = 7, STNSOLID = 1
' The other station.  A system of technology level 10 or above has a Dodo
' instead of a Coriolis, and the original arranges it by swapping the
' blueprint the space station ship type points at - so this is a blueprint
' number and not a ship type, and nothing outside StationBlueprint names it.
CONST BP_DODO = 27
' Set while the ship hangar is on the screen, when everything in it is given
' faces so that the floor and the back wall stop at the hull.
DIM INTEGER fillBlack
DIM FLOAT tx, ty, tz

' ------------------------ constants belonging to the other modules
' MMBasic executes CONST and DIM, so every one of them has to run before
' the main flow reaches END - they cannot live beside the SUBs that use
' them further down the file.

' --- the original's control constants, all in units per frame
CONST JCENTRE = 128                ' the centre of the 1..255 range
CONST JROLLSTEP = 7                ' a held roll key moves JSTX this far
CONST JPITCHSTEP = 14              ' a held pitch key moves JSTY this far
CONST JDAMPROLL = 2                ' the spring pulls roll back this fast
CONST JDAMPPITCH = 1               ' and pitch this fast
CONST MAXSPEED = 40                ' DELTA's ceiling
CONST ANGSCALE = 256               ' ALP1 / 256 is the angle in radians

CONST SELFROT = 0.0625             ' a ship's own roll / pitch, radians per frame
CONST NPCSPEED = 1.5               ' a ship of speed s moves 1.5 * s per frame
CONST TIDYEVERY = 16               ' renormalise one ship's orientation this often

CONST NEARZ = 32                   ' nearer than this and nothing is drawn
CONST FARXY = 30000                ' Draw3D clamps its offsets at +-32766
' The original compares the blueprint's visibility byte directly against the
' high byte of z, so its unit is 256 world units.  Two hard cut-offs sit
' either side of that comparison: nothing at all is drawn beyond z_hi 192,
' and below z_hi 16 the mesh is always drawn whatever the blueprint says -
' which is why the escape pod, canister and missile, whose bytes are under
' 16, all turn into dots at exactly 4096.
CONST ZHI = 256                    ' world units per step of the visibility scale
CONST VISFLOOR = 16                ' below this the mesh is always drawn
CONST VISCUT = 192                 ' beyond this the ship is not drawn at all
CONST NSTAR = 18                   ' stardust particles, as the original
CONST NSEG = 16                    ' segments in a planet surface ellipse

DIM FLOAT ctab(NSEG-1), stab(NSEG-1), pgx(NSEG-1), pgy(NSEG-1)
DIM FLOAT stX(NSTAR-1), stY(NSTAR-1), stZ(NSTAR-1)
DIM INTEGER spx(4*NSTAR-1), spy(4*NSTAR-1), spc(4*NSTAR-1)
DIM INTEGER DLY(5), DRY(6)         ' dashboard bar rows, left and right
DIM LLAB$(5) LENGTH 3, RLAB$(6) LENGTH 3

' Dashboard columns, from the original's screen addresses.  Left column
' BBC x 16..47 -> ours 20..59; right column BBC x 208..239 -> ours
' 260..299.  A bar is 16 steps of 2.5 of our pixels.
CONST DL = 20                      ' left column, the status bars
CONST DR = 260                     ' right column, speed / roll / pitch / energy
CONST DW = 40                      ' a full length bar

' Scanner ellipse: BBC centre (124, 220), semi-axes 69 x 18.
CONST SCX = 155                    ' scanner centre
CONST SCY = 204
CONST SCA = 86                     ' scanner semi-axis across
CONST SCB = 18                     ' and down
CONST SCDOTX = 154                 ' BBC 123, the dot's x origin
CONST SCXDIV = 204.8               ' 256 world units per BBC pixel, x 1.25
CONST SCZDIV = 1024                ' a quarter of z's high byte, down the ellipse
CONST SCYDIV = 512                 ' half of y's high byte, for the stick
CONST SCTOP = 178                  ' BBC 194, the dot's clip
CONST SCBOT = 230                  ' BBC 246

' Compass: BBC centre (195, 203), a normalised component of +-96 becoming
' +-9 pixels.  Yellow and two rows deep when the target is ahead, green
' and one row deep when it is behind.
' The two indicator bulbs, which the original puts on the dashboard either
' side of the scanner.  Ours go under it, in the one strip of the dashboard
' with room: the left column ends at x 60, the right bars at y 231, and the
' scanner clears everything between.
CONST BULBX = 64, BULBY = 232
CONST CPX = 244
CONST CPY = 187
CONST CPR = 9
CONST PROFILE = 1                  ' accumulate per-stage frame times

' ------------------------------------------------------------------- time
' The original's constants are all per iteration of its main loop, and that
' loop ran at something like ten or twelve times a second on a 2 MHz 6502.
' Ours draws forty frames a second, so applying them once a frame made
' everything three or four times too quick - and, worse, tied the speed of
' the game to the frame rate, so a busy bubble played slower than an empty
' one.  Instead each frame works out how much of one of the original's
' iterations it represents and scales by that: motion stays as smooth as
' the frame rate allows while happening at the original's pace.
'
' Anything the original did once per iteration rather than continuously -
' the counters, the schedules, the joystick spring - is gated on tickWhole
' instead, which is true on the frames where a whole iteration has elapsed.
' The original's main loop, times a second.  This is not a guess: LASCT is
' decremented by the vertical sync interrupt fifty times a second, and the
' source says of the death sequence that "the main loop decrements it by 4" -
' so one iteration of the main loop is four vertical syncs, or 12.5 a second.
' It checks out against the other clock in the game: an in-flight message is
' held for 22 iterations, which at this rate is 1.76 seconds.
CONST TICKRATE = 12.5
CONST TICKMAX = 0.5                ' never let one frame move the world further
DIM FLOAT tick, tickAcc, tickPrev
DIM INTEGER tickWhole

' ---------------------------------------------------------------- sound
' The original's ten effects; see 45_sound.bas for how its SFX table
' converts.  SOUNDON 0 plays the game in silence.
' In-flight messages, at the original's column 9 of row 22.
CONST MSGX = 90, MSGY = 160, MSGTIME = 1800
DIM msgText$ LENGTH 40
DIM FLOAT msgUntil

CONST SOUNDON = 1
CONST NSFX = 9
CONST SFX_LASER = 0, SFX_HIT = 1, SFX_BOOM = 2, SFX_BOOMT = 3, SFX_BEEP = 4
CONST SFX_BOOP = 5, SFX_LAUNCH = 6, SFX_HYPER = 7, SFX_ECM = 8
DIM INTEGER sfxCh(NSFX-1), sfxWv(NSFX-1), sfxF0(NSFX-1), sfxF1(NSFX-1)
DIM INTEGER sfxMs(NSFX-1), sfxVol(NSFX-1), sfxWb(NSFX-1)
DIM INTEGER chWv(4), chF0(4), chF1(4), chVol(4), chWb(4), chLast(4)
DIM FLOAT chT0(4), chT1(4)

' ------------------------------------------------------- the game shell
' Which docked or information screen is showing, and what the market
' screen's action key does.
CONST SCR_STATUS = 0, SCR_INVENT = 1, SCR_MARKET = 2, SCR_EQUIP = 3
CONST SCR_LONG = 4, SCR_SHORT = 5, SCR_DATA = 6
' Where the commander is saved and where the title picture is looked for.
' Both are set at start up from the directory the program was loaded out of,
' so nothing here is tied to one drive letter.
DIM homeDir$ LENGTH 48
DIM cmdrFile$ LENGTH 64
DIM INTEGER quitGame, dscreen, dsel, dbuy, titleKey
' How far one press moves the chart cursor: one notch, or eight with shift.
CONST CHARTFAST = 8
DIM INTEGER chartStep

' ------------------------------------------------------ the attract demo
' A game that plays itself, for showing the thing off.  It stands in for
' the keyboard rather than replacing any of the game, so any key at all
' hands the controls back to whoever pressed it.
CONST DEMOPLAY = 1                 ' 1 lets an idle title screen start the demo
DIM titlePic$ LENGTH 64            ' drawn by elite_tools/titlescreen.py
CONST TITLEWAIT = 20000            ' idle this long on the title and the demo runs
CONST DEMOLOOP = 1                 ' and the demo starts over when it ends
CONST HANGWAIT = 900             ' the hangar, 44/50 of a second as the BBC
CONST HANGDEMO = 4000            ' and longer while the demo is showing it off
CONST DEMOREAD = 3000              ' how long an information screen is held
CONST DEMOHELP = 9000              ' and how long the controls page is shown
DIM INTEGER demoMode, demoStop, demoStep, demoLeg, demoTick, demoTgt, demoTakeover
' Set while the equipment shop is asking which laser mount, so the demo's F1
' answer is not mistaken for a launch.
DIM INTEGER demoAsk
' How long the next information screen opened from the cockpit is held.  The
' system data screen carries a paragraph of description now, so the demo gives
' that one longer than the rest.
DIM INTEGER demoScrn
' Leg three mines a rock.  demoMined is what was in the hold before it
' started, so the demo can tell when it has what it came for; demoPhase is
' nought while there is still rock to break and one on the way home; demoRock
' and demoScoop are the ticks the last rock was put up and the run at the
' splinters began.
DIM INTEGER demoMined, demoPhase, demoRock, demoScoop
DIM INTEGER dkKey(191), dkWait(191), dkCount
DIM demoCap$ LENGTH 40

