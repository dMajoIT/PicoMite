' =====================================================================
'  Start up, then either the game or one of the scripted demos
'
'  DEMOFRAMES is 0 for a game anyone can play and non-zero for a demo
'  that flies itself, photographs a few frames and reports; the demos are
'  how each phase was tested and they are kept working.
' =====================================================================
SetupScreen
LoadStats
ProbeObjects
SetupViews
ShipColours
EquipTable
LoadTokens
LoadSounds

IF DEMOFRAMES = 0 THEN

  ' Title, game, title.  Escape on the title is the way out; waiting there
  ' starts the demo, and any key during the demo takes the controls.
  DO
    titleKey = TitleScreen()
    IF titleKey = 27 THEN EXIT DO
    IF titleKey = 0 AND DEMOPLAY THEN
      RunDemo
      IF demoTakeover = 0 THEN titleKey = -1
    ENDIF
    IF titleKey <> -1 THEN
      NewGame
      RunGame
    ENDIF
  LOOP

ELSE

  IF DEMOSCENE = 9 THEN
    ' The framebuffer stays open: the jump draws its tunnel of rings through
    ' it, and closing it first stops the countdown ever arriving anywhere.
    LeftScene
    FRAMEBUFFER CLOSE
    RestoreScreen
    PRINT "left-list done"
    END
  ELSEIF DEMOSCENE = 8 THEN
    FRAMEBUFFER CLOSE
    RestoreScreen
    DockNPCScene
    PRINT "npc dock done"
    END
  ELSEIF DEMOSCENE = 7 THEN
    ' Nothing here draws anything, and the console is easier to read when it
    ' is the console rather than the framebuffer.
    FRAMEBUFFER CLOSE
    RestoreScreen
    NewbScene
    PRINT "newb done"
    END
  ELSEIF DEMOSCENE = 6 THEN
    MissionScene
    FRAMEBUFFER CLOSE
    RestoreScreen
    PRINT "missions done,"; shotNo; " pages"
    END
  ELSEIF DEMOSCENE = 5 THEN
    ' The four mission briefings, which are the whole of the long end of the
    ' token table and the only tokens that need the page layout.
    NewCommander
    MissionBrief 10, 0
    MissionBrief 11, 0
    MissionBrief 222, 0
    MissionBrief 223, 0
    FRAMEBUFFER CLOSE
    RestoreScreen
    PRINT "briefings done,"; shotNo; " pages"
    ' The briefings and the system descriptions share one set of case rules,
    ' so this fixture is also where a change to them shows up.
    GotoSystem gGal, homeSys
    SysData
    PRINT SysName$(); ": "; SysDesc$()
    END
  ELSEIF DEMOSCENE = 4 THEN
    ' The hangar, eight times over, which is enough passes to see each of
    ' the four groups and a solo ship or two.
    FOR frames = 1 TO 8
      HangarScreen
      SaveShot frames
    NEXT frames
    FRAMEBUFFER CLOSE
    RestoreScreen
    PRINT "hangar done"
    END
  ELSEIF DEMOSCENE = 3 THEN
    DockedScreens
    FRAMEBUFFER CLOSE
    RestoreScreen
    PRINT "docked screens done"
    END
  ELSEIF DEMOSCENE = 2 THEN
    DockScene
  ELSE
    TestScene
  ENDIF

  frames = 0
  tFrame = TIMER
  ' The scene fixtures predate the frame clock, and everything that moves is
  ' scaled by tick - so without these two the whole universe stands still and
  ' the fixtures photograph a frozen bubble while reporting a frame rate.
  ResetTick
  DO
    NextTick
    IF DEMOSCENE = 2 THEN DockInput frames ELSE DemoInput frames
    IF kQuit OR dead OR docked THEN EXIT DO
    UpdatePlayer
    IF kFire THEN FireLaser
    IF kTarget THEN TargetMissile
    IF kMissile THEN LaunchMissile
    IF kECM THEN FireECM
    IF kDock THEN
      IF eqOwned(EQ_DOCK) THEN dockComp = 1 - dockComp ELSE Sfx SFX_BOOP
    ENDIF
    IF dockComp THEN DockingComputer
    IF lasTimer > 0 THEN lasTimer = lasTimer - 1
    IF lasFlash > 0 THEN lasFlash = lasFlash - 1
    tStage = TIMER
    MoveShips
    Contact
    Missiles
    Tactics
    ECMService
    Recharge
    Altitude
    CabinTemp
    StationCheck
    StationPolice
    SpawnTraffic
    DockCheck
    prof(5) = prof(5) + TIMER - tStage
    DrawFrame
    FRAMEBUFFER COPY F, N
    mcnt = (mcnt + 1) AND 255
    frames = frames + 1
    IF frames = 40 OR frames = 80 OR frames = 120 OR frames = 250 THEN SaveShot frames
    IF frames >= DEMOFRAMES THEN EXIT DO
  LOOP
  tFlight = TIMER - tFrame

ENDIF

IF dead THEN DeathScreen : PAUSE 1500
SoundOff
CloseAll
FRAMEBUFFER CLOSE
RestoreScreen
frameMs = 0
IF frames > 0 THEN frameMs = tFlight / frames
PRINT "frames"; frames; "  average"; STR$(frameMs, 4, 2); " ms per frame"
PRINT "shots"; shots; " hits"; hits; "  kills"; kills; "  cash"; cashTenths / 10; " Cr  rank "; RankName$()
PRINT "energy"; pEnergy; " fore shield"; pFsh; " laser temp"; pLasT; " fuel"; pFuel / 10; " LY"
PRINT "slots in use"; nUsed; "  dead"; dead; "  witchspace"; inWitch
PRINT "missiles left"; pMissl; "  legal status "; LegalName$()
PRINT "docked"; docked; "  docking computer"; dockComp
IF PROFILE THEN
 IF frames > 0 THEN
  PRINT "  CLS      "; STR$(prof(0) / frames, 5, 2); " ms"
  PRINT "  stardust "; STR$(prof(1) / frames, 5, 2); " ms"
  PRINT "  planet   "; STR$(prof(2) / frames, 5, 2); " ms"
  PRINT "  ships    "; STR$(prof(3) / frames, 5, 2); " ms"
  PRINT "  dash     "; STR$(prof(4) / frames, 5, 2); " ms"
  PRINT "  move     "; STR$(prof(5) / frames, 5, 2); " ms"
  PRINT "  the rest is the background framebuffer copy, which paces to 60 Hz"
 ENDIF
ENDIF
END
