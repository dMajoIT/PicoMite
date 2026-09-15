' exilephys.bas - the player's physics from Exile, in MMBasic.
' A routine-for-routine translation of Bas/exile_tools/exilephys.py, which is
' itself the game's update_object (&1a17) for the player at the 8-bit level.
' Every value is the byte the 6502 holds; cy and ov are its carry and overflow.
'
' This file is the kernel and a replay harness.  gen_phystest.py appends the
' tables and the player's starting slot as DATA to make physics.bas, and
' writes one feed file per scenario: the keys held each tick and the few
' values the game reads that the kernel cannot derive (two random bytes and
' one carry).  The harness prints the player's state after every tick and
' run_phystest.py compares it with the trace of the real game.
Option EXPLICIT
Option DEFAULT INTEGER
Option BASE 0
' PRINT goes to the serial console only: the host script captures it and the screen is left alone
Option CONSOLE SERIAL

' ---- tables from the listing (filled from the DATA at the end) ----
Dim obPat(167), obOff(39), tYoffT(63), tPatT(63), tSprF(63), rtFlags(19)
Dim sprW(124), sprH(124), halfQ(7), waterVel(3), wlX(3), wlYF(3), wlY(3)
Dim walkMaxAng(6), walkMaxAcc(6), walkWeight(6), weaponCost(5), objFlags(100), objPal(100)
Dim noRepeat(38)
Dim homeDir$
' ---- the world: 65,536 bytes, tile type in bits 0-5 and flips in 6-7 ----
Dim world(8191), wbase
' ---- the player's slot; the pairs are indexed 0 for x and 2 for y as the 6502 does ----
Dim ps(2), pf(2), vel(2), acc(2), siz(2), mxp(2), mxf(2), cross(2), vec(2), qps(2), qpf(2), obs(3)
Dim oFlags, oSpr, oPal, oEnergy, oState, oTimer, oTouch, weight, typeFlags, palDefault
' ---- game variables ----
Dim frm, fc, fc16, kh(38), pAngle, pFacing, immob, tImmob, rotVel, lying, aim, aimVel, aimFlip
Dim jetOk, inWater, tbColl, surr, wedged, signs, windSign, relTX, relTY, walkSpd, maxAcc0, npcW0
Dim fireCool, waterTile, jetLo, jetHi, suitHi, boosterCol, suitCol
' ---- temporaries of one tick ----
Dim wlFrac, wlRow, aimAccT, objCY, objCX, preMag, preAng, child, tileAng, upright, cYF, cYS, anyB, collTop
Dim tileX, tileY, tYoff, tFlip, tAddr, bYoff, bFlip, bAddr, topR, botR, waterline, mag, xFlip, yFlip, xFlipP
Dim cy, ov, rc, mxCarry, vecA
' ---- the feed: what the game read that the kernel cannot derive ----
Dim feedN, feedI, feedA(7), feedV(7)

Main
End

' ===================================================================
' the harness
' ===================================================================
Sub Main
  Local nm$, sx, sy, tk, n, kmask, d4, i
  Local Float t0, t1, tk1
  homeDir$ = MM.Info(Path) : If homeDir$ = "NONE" Then homeDir$ = "A:/"
  LoadTables
  LoadWorld
  Open homeDir$ + "phys_list.txt" For Input As #2
  Do While Not Eof(#2)
    Line Input #2, nm$
    ' XMODEM pads the file to a block boundary with Ctrl-Z
    If nm$ = "" Or Asc(nm$) < 32 Then Exit Do
    InitPlayer
    Open homeDir$ + "phys_" + nm$ + ".txt" For Input As #1
    Input #1, sx, sy, n
    If sx >= 0 Then ps(0) = sx : ps(2) = sy : pf(0) = &H80 : pf(2) = 0 : vel(0) = 0 : vel(2) = 0
    Print "S "; nm$
    t0 = Timer : tk1 = 0
    For tk = 1 To n
      Input #1, kmask, d4, feedN, feedA(0), feedV(0), feedA(1), feedV(1), feedA(2), feedV(2), wlYF(0), wlYF(1), wlYF(2), wlYF(3), wlY(0), wlY(1), wlY(2), wlY(3)
      feedI = 0
      relTY = d4
      t1 = Timer
      DoTick kmask
      tk1 = tk1 + (Timer - t1)
      PrintState tk
      If feedI < feedN Then Print "F "; tk; " the game read at &"; Hex$(feedA(feedI)); " and the kernel did not"
    Next tk
    Close #1
    Print "E "; nm$; " "; n; " "; Int(Timer - t0); " "; Int(tk1)
  Loop
  Option CONSOLE BOTH
  Close #2
End Sub

Sub PrintState(tk)
  Print "T ";tk;" ";ps(0)*256+pf(0);" ";ps(2)*256+pf(2);" ";vel(0);" ";vel(2);" ";oFlags;" ";oState;" ";oSpr;" ";oEnergy;" ";jetHi*256+jetLo;" ";pAngle;" ";pFacing;" ";immob;" ";tImmob;" ";jetOk;" ";oTimer;" ";frm;" ";oPal
End Sub

Function NextFeed(addr)
  If feedI >= feedN Then
    Print "F kernel reaches &"; Hex$(addr); " which the game did not" : End
  EndIf
  If feedA(feedI) <> addr Then
    Print "F kernel reaches &"; Hex$(addr); " where the game read at &"; Hex$(feedA(feedI)) : End
  EndIf
  NextFeed = feedV(feedI) : feedI = feedI + 1
End Function

Sub LoadWorld
  Open homeDir$ + "world_types.bin" For Input As #3
  MEMORY INPUT 3, 65536, world()
  Close #3
  wbase = Peek(VARADDR world())
End Sub

Sub ReadTable(a(), n)
  Local i
  For i = 0 To n - 1 : Read a(i) : Next i
End Sub

Sub LoadTables
  Local i
  Restore ObstructionPatterns : ReadTable obPat(), 168
  Restore ObstructionPatternOffsets : ReadTable obOff(), 40
  Restore TileObstructionYOffsets : ReadTable tYoffT(), 64
  Restore TileYOffsetAndPattern : ReadTable tPatT(), 64
  Restore TileSprites : ReadTable tSprF(), 64
  Restore UpdateRoutineFlags : ReadTable rtFlags(), 20
  Restore SpriteWidths : ReadTable sprW(), 125
  Restore SpriteHeights : ReadTable sprH(), 125
  Restore AngleHalfQuadrants : ReadTable halfQ(), 8
  Restore WaterVelocities : ReadTable waterVel(), 4
  Restore WaterRangeX : ReadTable wlX(), 4
  Restore WaterYFrac : ReadTable wlYF(), 4
  Restore WaterY : ReadTable wlY(), 4
  Restore WalkMaxAngle : ReadTable walkMaxAng(), 7
  Restore WalkMaxAccel : ReadTable walkMaxAcc(), 7
  Restore WalkWeightShift : ReadTable walkWeight(), 7
  Restore WeaponEnergyCost : ReadTable weaponCost(), 6
  Restore ObjectFlags : ReadTable objFlags(), 101
  Restore ObjectPalettes : ReadTable objPal(), 101
  Restore ActionNoRepeat : ReadTable noRepeat(), 39
End Sub

' the player's slot and the game variables as the game starts: the listing's
' values plus what relocate_binary_and_saved_position does (upright, nothing held)
Sub InitPlayer
  Local i
  Restore PlayerInit
  Read oSpr, ps(0), pf(0), ps(2), pf(2), oFlags, oPal, vel(0), vel(2), oEnergy, oState, oTimer, oTouch
  Read jetLo, jetHi, suitHi, fireCool, jetOk, boosterCol, suitCol
  For i = 0 To 38 : Read kh(i) : Next i
  typeFlags = objFlags(0) : palDefault = objPal(0) And &H7F
  maxAcc0 = walkMaxAcc(0) : npcW0 = walkWeight(0)
  frm = 0 : pAngle = &HC0 : pFacing = 0 : immob = 0 : tImmob = 0 : rotVel = 0 : lying = 0
  aim = 0 : aimVel = 0 : aimFlip = 0
  cross(0) = 0 : cross(2) = 0 : inWater = 0 : tbColl = 0 : surr = 0 : wedged = 0 : signs = 0 : windSign = 0
  relTX = 0 : relTY = 0 : walkSpd = 0 : waterTile = 0
End Sub

' one tick: shift the key history, count the frm, update the player
Sub DoTick(kmask)
  Local i
  For i = 0 To 38
    kh(i) = (kh(i) >> 1) Or (((kmask >> i) And 1) << 7)
  Next i
  frm = (frm + 1) And 255
  UpdateObject
End Sub

' ===================================================================
' 8-bit helpers
' ===================================================================
Function Add8(a, b, c)        ' A + B + C; sets cy and ov
  Local t
  t = a + b + c
  Add8 = t And 255 : cy = t >> 8
  ov = ((((a Xor b) Xor 255) And (a Xor (t And 255))) And 128) <> 0
End Function

Function Sub8(a, b, c)        ' A - B - (1 - C); cy clear means a borrow; sets ov
  Local t
  t = a - b - 1 + c
  Sub8 = t And 255 : cy = (t >= 0)
  ov = (((a Xor b) And (a Xor (t And 255))) And 128) <> 0
End Function

Function InvNeg(a)            ' invert_if_negative: two's complement if bit 7 set
  If a And 128 Then InvNeg = (-a) And 255 Else InvNeg = a
End Function

Function Asr(a)               ' CMP #&80 ; ROR A: halve keeping the sign; cy = bit shifted out
  cy = a And 1 : Asr = (a And 128) Or (a >> 1)
End Function

Function SevenEighths(a)      ' lose an eighth, the eighth rounded up
  Local p, e
  p = InvNeg(a) : p = (p + 7) And 255 : e = p >> 3
  If a And 128 Then e = (-e) And 255
  SevenEighths = (a - e) And 255
End Function

Function KeepRange(a, rng)    ' clamp a signed byte to -rng..rng
  If InvNeg(a) < rng Then
    KeepRange = a
  ElseIf a And 128 Then
    KeepRange = (-rng) And 255
  Else
    KeepRange = rng
  EndIf
End Function

Function HalveTowardZero(v)   ' CMP #&80 ; ROR A ; BPL ; ADC #&00
  Local a, c
  a = Asr(v) : c = cy
  If a And 128 Then a = (a + c) And 255
  HalveTowardZero = a
End Function

Function Jumping()            ' state's low nibble counts frames off a walkable surface
  Jumping = ((oState And &H0F) >= &H0A)
End Function

' ===================================================================
' update_object (&1a17) for the player
' ===================================================================
Sub UpdateObject
  Local a, c, prevFlags, flp
  qps(0) = ps(0) : qps(2) = ps(2) : qpf(0) = pf(0) : qpf(2) = pf(2)
  prevFlags = oFlags
  xFlip = oFlags : yFlip = (oFlags << 1) And 255
  fc = frm : fc16 = frm And 15
  GetWaterline ps(0)
  weight = typeFlags And 7
  siz(0) = sprW(oSpr) And &HF0 : siz(2) = sprH(oSpr) And &HF8
  acc(0) = 0 : acc(2) = 0 : aimAccT = 0 : objCY = 0 : objCX = 0 : preMag = 0 : child = 0 : tileAng = 0
  upright = 255
  AddToPos 2, vel(2), vel(2) And 128
  AddToPos 0, vel(0), vel(0) And 128
  Maxima
  CollWaterTiles
  c = rc
  ' body collision damage: angle of the collision against the player's own angle, plus speed
  a = Sub8(tileAng, pAngle, c) : a = Sub8(a, &H40, cy)
  a = InvNeg(a) : a = a >> 1 : c = a And 1 : a = a >> 1
  a = Add8(a, &HC0, c) : a = Add8(a, preMag, cy)
  If cy Then oEnergy = DamageWithoutDestroying(a >> 1)
  ' support and wedging
  anyB = cYF Or objCY
  collTop = ((objCY << 1) And 255) Or cYS
  wedged = wedged >> 1
  oFlags = oFlags And &HFD
  If (collTop And 128) = 0 Then
    If anyB And 128 Then oFlags = oFlags Or 2
  ElseIf prevFlags And 2 Then
    wedged = 128 Or (wedged >> 1)
    If obs(2) <> obs(0) Then
      a = &H10
      If (obs(2) - obs(0)) And 128 Then a = &HF0
      AddToPos 0, a, a And 128
      Maxima
    EndIf
  EndIf
  If ps(2) < &H4F Then SurfaceWind
  UpdatePlayer
  ApplyAcceleration
  flp = (xFlip And 128) Or ((yFlip And 128) >> 1)
  oFlags = ((oFlags And &HC0) Xor oFlags Xor flp) And &HF3
  oTouch = oTouch Or 128
  oFlags = oFlags And &HFE      ' bit 0 is "off screen", never for the viewpoint object
End Sub

Sub GetWaterline(x)
  Local xi
  xi = 4
  Do
    xi = xi - 1
  Loop Until x >= wlX(xi)
  wlFrac = wlYF(xi) : wlRow = wlY(xi)
  ' lower (greater y) than range 1, Triax's lab?  then that level applies
  If wlRow * 256 + wlFrac > wlY(1) * 256 + wlYF(1) Then wlFrac = wlYF(1) : wlRow = wlY(1)
End Sub

' add A to a position; the borrow is decided by n, the 6502's N flag on entry
Sub AddToPos(xi, a, n)
  Local t
  If n Then ps(xi) = (ps(xi) - 1) And 255
  t = a + pf(xi) : pf(xi) = t And 255
  If t > 255 Then ps(xi) = (ps(xi) + 1) And 255
End Sub

Sub Maxima              ' the extents; mxCarry = bit 0 of the old crosses_x byte, the carry it leaves
  Local xi, t
  mxCarry = cross(0) And 1
  For xi = 2 To 0 Step -2
    t = siz(xi) + pf(xi) : mxf(xi) = t And 255
    mxp(xi) = (ps(xi) + (t >> 8)) And 255
    cross(xi) = ((t >> 8) << 7) Or (cross(xi) >> 1)
  Next xi
End Sub

' ===================================================================
' collisions with water and tiles
' ===================================================================
Sub SetObsVars(which)   ' set_obstruction_data_variables for the top (0) or bottom (1) tile
  Local v, t, flp, a, h, q, fl, addr, yo
  v = Peek(BYTE wbase + tileY * 256 + tileX)
  t = v And &H3F : flp = v And &HC0
  TileEffect t, flp
  yo = tYoffT(t)
  If flp And &H40 Then yo = (yo << 4) And 255
  yo = yo And &HF0
  If yo Then yo = yo Or &H0F
  h = flp >> 7 : q = (flp << 1) And 255
  fl = q Xor tSprF(t)
  a = ((tPatT(t) << 1) Or h) And 255
  a = ((a << 1) Or (q >> 7)) And &H3F
  addr = obOff(a)
  If which = 0 Then
    tYoff = yo : tFlip = fl : tAddr = addr
  Else
    bYoff = yo : bFlip = fl : bAddr = addr
  EndIf
End Sub

Sub TileEffect(t, flp)   ' the tile's update routine as called while checking collisions
  Local wv
  If t >= &H10 Then Exit Sub
  If (rtFlags(t) And &H20) = 0 Then Exit Sub
  If t = &H0D Then
    wv = waterVel(((flp >> 7) << 1) Or ((flp >> 6) And 1))
    If wv Then
      WindFromA wv
    Else
      waterTile = 128 Or (waterTile >> 1)
    EndIf
  EndIf
End Sub

Sub WindFromA(a)         ' moving water and wind: top nibble y velocity, bottom nibble x
  Local xi, yy
  vec(0) = (a << 4) And 255 : vec(2) = a
  For xi = 2 To 0 Step -2
    yy = weight
    If yy < 4 Then yy = yy + 1
    If waterline And 128 Then yy = yy + 1
    If (inWater And 128) <> 0 And (frm And &H10) = 0 Then Exit Sub
    WeightedAccel vec(xi), yy, xi, &H0C
  Next xi
End Sub

Sub WeightedAccel(desired, yy, xi, maxacc)   ' move a velocity towards desired, weighted and limited; rc = carry
  Local a, accl
  a = Sub8(desired, vel(xi), 1)
  accl = WeightLimit(a, cy, ov, yy, maxacc)
  vel(xi) = Add8(accl, vel(xi), 0)
  rc = cy
End Sub

Function WeightLimit(av, c, v, yy, maxacc)   ' scale an acceleration by 2^-yy and limit it
  Local a, n, m, times, i, cc
  a = av
  If v Then a = (&H7F + c) And 255
  n = a And 128
  m = InvNeg(a)
  If yy < 128 Then times = yy + 1 Else times = 1
  cc = 0
  For i = 1 To times
    cc = m And 1 : m = m >> 1
  Next i
  m = ((m << 1) Or cc) And 255
  If m >= maxacc Then m = maxacc
  If n Then m = (-m) And 255
  WeightLimit = m
End Function

Sub CollWaterTiles       ' check_for_collision_with_water_and_tiles; rc = the carry it leaves
  Local a, a2, xi, tw, yy, h4, c, c2, old
  surr = surr >> 1
  a = Sub8(mxf(2), wlFrac, 1) : xi = a : c = cy
  a2 = Sub8(mxp(2), wlRow, c) : c2 = cy
  If a2 <> 0 Then
    If c2 Then xi = 255 Else xi = 0
  EndIf
  waterline = xi
  tileX = ps(0) : tileY = ps(2)
  xi = 0 : waterTile = 0
  SetObsVars 0
  c = waterTile >> 7 : waterTile = (waterTile << 1) And 255
  If c Then xi = 255
  If cross(2) And 128 Then
    tileY = (tileY + 1) And 255
    SetObsVars 1
    c = waterTile >> 7 : waterTile = (waterTile << 1) And 255
    If c Then xi = xi Or mxf(2)
  Else
    bYoff = tYoff : bAddr = tAddr : bFlip = tFlip
  EndIf
  If xi < waterline Then xi = waterline
  tw = xi
  yy = weight
  If yy = 0 Then yy = 1
  h4 = siz(2) >> 2
  xi = 4 : a = tw
  If a Then c = 0 Else c = 1
  old = inWater : inWater = (c << 7) Or (old >> 1) : c = old And 1
  If (inWater And 128) = 0 Then
    Do
      a = Sub8(a, h4, c) : c = cy
      If c = 0 Then Exit Do
      yy = (yy - 1) And 255
      If yy And 128 Then
        vel(2) = (vel(2) - 1) And 255
      ElseIf yy = 0 Then
        vel(2) = (vel(2) - 2) And 255
      EndIf
      xi = xi - 1
      If xi = 0 Then Exit Do
    Loop
    If frm Mod 4 = 0 Then vel(0) = SevenEighths(vel(0)) : vel(2) = SevenEighths(vel(2))
  EndIf
  CollTiles
End Sub

Function CheckTB(yy)     ' check_for_top_and_bottom_tile_collisions for section yy; rc = carry
  Local a, a2, a3
  a2 = 0 : a3 = 0
  a = Add8(obPat(tAddr + yy), tYoff, 0)
  If cy Then a = 255
  a = Sub8(a, topR, 1)
  If cy Then
    If a >= siz(2) Then a = siz(2)
    a2 = a
  EndIf
  a = siz(2)
  If cross(2) And 128 Then
    a = Add8(obPat(bAddr + yy), bYoff, 0)
    If cy Then a = 255
    If a >= botR Then a = botR
    a3 = a
    If (bFlip And 128) = 0 Then a3 = Sub8(botR, a3, 1)
    a = Sub8(0, topR, 1)
  EndIf
  If (tFlip And 128) = 0 Then a2 = Sub8(a, a2, 1)
  a = Add8(a2, a3, 0) : a = Add8(a, 6, cy)
  a = (cy << 7) Or (a >> 1)
  a = a >> 1
  a = a And &HFE
  a = ((a Xor 255) + 1) And 255
  rc = (a = 0)
  CheckTB = a
End Function

Sub CollTiles            ' check_for_collision_with_tiles; rc = the carry it leaves
  Local yy, lft, top, rgt, bot, sections, a, c, topRel, botRel, p, done
  topR = (pf(2) And &HF8) Or 4
  botR = (mxf(2) And &HF8) Or 4
  yy = pf(0) >> 5
  lft = CheckTB(yy)
  top = 0 : bot = 0
  sections = siz(0) >> 5
  done = 0
  Do
    a = Sub8(topR, tYoff, 1)
    If cy Then topRel = a Else topRel = 0
    a = Sub8(botR, bYoff, 1)
    If cy Then botRel = a Else botRel = 0
    Do
      p = obPat(tAddr + yy)
      If ((p >= topRel) Xor (tFlip >> 7)) = 0 Then top = (top - 1) And 255
      p = obPat(bAddr + yy)
      If ((p >= botRel) Xor (bFlip >> 7)) = 0 Then bot = (bot - 1) And 255
      sections = (sections - 1) And 255
      If sections And 128 Then done = 1 : Exit Do
      yy = yy + 1
      If yy < 8 Then Continue Do
      tileX = (tileX + 1) And 255
      SetObsVars 1
      If cross(2) And 128 Then
        tileY = (tileY - 1) And 255
        SetObsVars 0
      Else
        tYoff = bYoff : tAddr = bAddr : tFlip = bFlip
      EndIf
      yy = 0
      Exit Do
    Loop
    If done Then Exit Do
  Loop
  bot = (bot << 3) And 255 : top = (top << 3) And 255
  a = Sub8(top, bot, 1)
  vec(0) = a : vec(2) = 0
  cYS = a
  cYF = ((a Xor 255) + 1) And 255
  c = ((bot Or top) >= 1)
  tbColl = (c << 7) Or (tbColl >> 1)
  rgt = CheckTB(yy)
  a = Sub8(rgt, lft, 1) : c = cy
  vec(2) = a
  obs(0) = lft : obs(1) = top : obs(2) = rgt : obs(3) = bot
  If (a Or vec(0)) <> 0 Then
    TileCollision
  ElseIf (lft Or top) = 0 Then
    rc = c
  Else
    HalveClear
  EndIf
End Sub

Sub HalveClear           ' entirely inside tiles: stay put, halve the velocities; rc = carry
  ps(0) = qps(0) : ps(2) = qps(2) : pf(0) = qpf(0) : pf(2) = qpf(2)
  vel(0) = Asr(vel(0)) : vel(2) = Asr(vel(2))
  Maxima
  rc = mxCarry
  cYF = 255 : cYS = 255 : surr = 255
  obs(0) = 0 : obs(1) = 0 : obs(2) = 0 : obs(3) = 0
End Sub

Function AbsC(v)         ' get_absolute_vector_component, noting the sign in signs
  Local c
  c = (v <= &H7F)
  If c Then AbsC = v Else AbsC = ((v Xor 255) + 1) And 255
  signs = ((signs << 1) Or c) And 255
End Function

Function AngleFromVec()  ' calculate_angle_from_vector: the angle of vec(), 0-255; mag = the larger component
  Local ay, ax, a, c, ang, m
  ay = AbsC(vec(2)) : ax = AbsC(vec(0))
  m = ay : a = ax
  c = (a >= m)
  If c Then a = m : m = ax
  signs = ((signs << 1) Or c) And 255
  ang = 8
  Do
    a = (a << 1) And 255
    If a >= m Then
      a = (a - m) And 255 : c = 1
    Else
      c = 0
    EndIf
    ang = (ang << 1) Or c
    If ang And 256 Then ang = ang And 255 : Exit Do
  Loop
  mag = m
  AngleFromVec = ang Xor halfQ(signs And 7)
End Function

Sub VecFromMagAngle(m, ang)   ' calculate_vector_from_magnitude_and_angle: vec(0), vec(2) and vecA = vec(2); rc = carry
  Local bx, q, a, i, bt, c, yv
  bx = m : q = ang : a = 0
  For i = 1 To 5
    bt = q And 1 : q = q >> 1 : c = 0
    If bt Then a = Add8(a, bx, 0) : c = cy
    a = (c << 7) Or (a >> 1)
  Next i
  bt = q And 1 : q = q >> 1
  If bt Then
    yv = bx : bx = a : bx = Sub8(yv, bx, 1) : a = yv
  EndIf
  bt = q And 1 : q = q >> 1
  If bt Then
    yv = ((a Xor 255) + 1) And 255 : a = bx : bx = yv
  EndIf
  bt = q And 1 : c = 0
  If bt Then
    yv = ((a Xor 255) + 1) And 255 : bx = Sub8(0, bx, 1) : c = cy : a = yv
  EndIf
  vec(0) = bx : vec(2) = a : vecA = a : rc = c
End Sub

Sub TileCollision        ' apply_tile_collision_to_position_and_velocity; rc = the carry it leaves
  Local a, c, yy, xi, n, angl
  tileAng = AngleFromVec()
  a = Sub8(tileAng, &H60, 1)
  yy = (a And &HC0) >> 6
  xi = yy Xor 2
  a = obs(yy)
  If a < obs(xi) Then a = obs(xi)
  If a = 0 Then a = &HFE
  a = (a << 2) And 255
  yy = (yy - 1) And 255
  xi = (yy And 1) << 1
  If xi = 0 Then
    a = Add8(a, &H0F, 1)
    If cy Then a = &HFE
  EndIf
  ' CPY #2 ; BCC ; INY ; PHP: the N flag comes from the INY for top and left
  If yy < 2 Then n = 1 Else n = ((yy + 1) And 128) <> 0
  If n = 0 Then a = (-a) And 255
  AddToPos xi, a, n
  Maxima
  vec(0) = vel(0) : vec(2) = vel(2)
  preAng = AngleFromVec() : preMag = mag
  a = Sub8(preAng, tileAng, 1) : c = cy
  angl = a
  If (a And 128) = 0 Then
    ' moving towards the obstruction: bounce at a reduced angle, losing speed
    a = Sub8(a, &H3F, 1)
    a = Asr(a) : a = Asr(a) : a = Asr(a) : c = cy
    a = Add8(a, angl, c)
    a = a Xor 255
    angl = Add8(a, tileAng, 1)
    a = preMag
    c = (a >= &H20)
    If c Then a = &H20
    a = Sub8(a, 2, c)
    If cy = 0 Then a = 0
    a = SevenEighths(a)
    VecFromMagAngle a, angl
    vel(2) = vecA : vel(0) = vec(0)
  Else
    ' moving away: a fast graze is halved and held, anything else is left alone
    a = Sub8(a, &HC0, c)
    a = InvNeg(a)
    If a >= &H2A Then
      rc = 1
    ElseIf preMag < &H40 Then
      rc = 0
    Else
      HalveClear
    EndIf
  EndIf
End Sub

' ===================================================================
' damage and the surface wind
' ===================================================================
Function DamageWithoutDestroying(dv)
  Local dmg, da, i, c, old, a
  dmg = dv
  da = NextFeed(&H24A6)
  If (da And 128) = 0 Then
    lying = lying >> 1
    If dmg >= immob Then immob = dmg
  EndIf
  For i = 1 To 3                  ' eightfold, as far as it fits in a byte
    c = dmg >> 7 : dmg = (dmg << 1) And 255
    If c Then dmg = (dmg >> 1) Or 128
  Next i
  old = oEnergy
  a = Sub8(old, dmg, 1)
  If cy = 0 Then a = 0
  If a = 0 And old <> 0 Then a = 1
  DamageWithoutDestroying = a
End Function

Sub SurfaceWind          ' apply_surface_wind: centred on (&9b, &4e), stronger further out
  Local a, c, xi, yy
  vec(0) = 0 : vec(2) = 0
  a = Sub8(ps(2), &H4E, 0) : c = cy
  xi = 2
  Do
    yy = (weight + 1) And 255
    windSign = (c << 7) Or (windSign >> 1)
    a = InvNeg(a)
    If a < &H1E Then
      c = 0
    Else
      If a < &H32 Then
        c = 0
      Else
        yy = (yy - 1) And 255
        If a < &H3C Then
          c = 0
        Else
          yy = (yy - 1) And 255 : c = 1
        EndIf
      EndIf
      a = Sub8(a, 8, c)
      a = (a << 1) And 255
      If a And 128 Then yy = (yy - 2) And 255 : a = &H7F
      yy = (yy + 1) And 255
      If yy And 128 Then yy = 0
      If windSign And 128 Then a = (-a) And 255
      vec(xi) = a
      WeightedAccel vec(xi), yy, xi, &H0C
      c = rc
    EndIf
    a = Sub8(ps(0), &H9B, c) : c = cy
    xi = xi - 2
    If xi <> 0 Then Exit Do
  Loop
End Sub

' ===================================================================
' update_player (&4a11)
' ===================================================================
Sub UpdatePlayer
  ProcessActions
  If (oFlags And &H10) = 0 Then AngleFacingSprite
  AimingAngle
  fireCool = (fireCool - 1) And 255
  If fireCool = 0 Then kh(13) = kh(13) >> 1
End Sub

Sub ProcessActions
  Local i, k
  For i = &H26 To 0 Step -1
    k = kh(i)
    If (k And 128) = 0 Then Continue For
    If (k And &HC0) = &HC0 And noRepeat(i) Then Continue For
    DoAction i
  Next i
End Sub

Sub DoAction(i)
  Select Case i
    Case 34                 ' W: thrust right
      acc(0) = (acc(0) + 1) And 255
    Case 33                 ' Q: thrust left
      acc(0) = (acc(0) - 1) And 255
    Case 37                 ' L: thrust down
      acc(2) = (acc(2) + 1) And 255
    Case 35                 ' P: thrust up (and fly, if the jetpack works)
      acc(2) = (acc(2) - 1) And 255
      If jetOk And 128 Then oState = oState Or &H0F
    Case 36                 ' P once: jump
      HandleJumping
    Case 21                 ' @: booster
      UseBooster
    Case 22                 ' CTRL: lie down
      oState = oState Or &H0F
    Case 23                 ' TAB: turn round
      pFacing = pFacing Xor 128
    Case 14                 ' I: centre the aim
      aim = 0 : aimVel = 0 : aimAccT = (aimAccT - 1) And 255
    Case 20                 ' O: raise the aim
      aimAccT = (aimAccT - 1) And 255
    Case 19                 ' K: lower the aim
      aimAccT = (aimAccT + 1) And 255
    Case Else
      Print "F action "; i; " is not modelled" : End
  End Select
End Sub

Sub HandleJumping
  Local a, c
  If (oState And &H0F) >= 5 Then Exit Sub
  If kh(&H15) And 128 Then a = &HF0 Else a = &HF6
  a = Add8(a, weight, 0)
  c = a >> 7 : a = (a << 1) And 255
  vel(2) = Add8(a, vel(2), c)
  upright = upright >> 1
End Sub

Sub UseBooster
  If ((jetOk And boosterCol) And 128) = 0 Then Exit Sub
  If (acc(2) And 128) = 0 And acc(0) <> 0 Then oState = oState Or &H0F
  acc(0) = (acc(0) << 1) And 255 : acc(2) = (acc(2) << 1) And 255
End Sub

Function CheckReliability(xi)   ' 1 if the weapon (0 jetpack, 5 suit) works this time
  Local da, hi, c, a, i, nc
  da = NextFeed(&H2D92)
  If xi = 0 Then hi = jetHi Else hi = suitHi
  If hi >= 4 Then CheckReliability = 1 : Exit Function
  c = (xi = 0)
  a = hi
  For i = 1 To 3
    nc = a And 1 : a = (c << 7) Or (a >> 1) : c = nc
  Next i
  CheckReliability = (a >= da)
End Function

Sub DrainJetpack         ' reduce_energy_of_weapon_X for the jetpack: the cost, plus a borrow the
  Local c, lo, hi        ' particle code usually leaves (the port will take two every time)
  c = NextFeed(&H2D79)
  lo = Sub8(jetLo, weaponCost(0), c) : c = cy
  hi = Sub8(jetHi, 0, c)
  If cy = 0 Then hi = 0 : lo = 0
  jetLo = lo : jetHi = hi
End Sub

Sub AngleFacingSprite    ' update_player_angle_facing_and_sprite
  Local a, c, old, ax, ay, drain
  acc(0) = (acc(0) << 1) And 255
  c = acc(2) >> 7 : acc(2) = (acc(2) << 1) And 255
  If frm Mod 16 = 0 Then
    a = Add8(oEnergy, 4, c)
    If cy = 0 Then oEnergy = a
    c = CheckReliability(0)
    old = jetOk : jetOk = (c << 7) Or (old >> 1) : c = old And 1
  EndIf
  a = Sub8(&H10, oEnergy, c)
  If cy Then immob = a
  If immob >= 6 Then jetOk = jetOk >> 1
  If tImmob Then tImmob = (tImmob - 1) And 255 : jetOk = jetOk >> 1
  lying = lying >> 1
  a = Sub8(pAngle, &HCF, 1) : c = (a >= &HE1)
  upright = ((c << 7) Or (a >> 1)) And upright
  ax = acc(0) : ay = acc(2)
  drain = 1
  If ay = 0 Then
    If ax = 0 Then lying = surr Or wedged Or kh(&H16)
    If Jumping() Then
      If anyB And 128 Then vel(2) = SevenEighths(SevenEighths(SevenEighths(vel(2))))
    Else
      drain = 0
    EndIf
  EndIf
  If drain And (jetOk And 128) <> 0 And (acc(0) Or acc(2)) <> 0 Then
    ' every_eight | booster key, masked by every_two: an even frm that is a
    ' multiple of eight or has the booster held
    If (frm And 1) = 0 And ((frm And 7) = 0 Or (kh(&H15) And 128) <> 0) Then DrainJetpack
  EndIf
  If immob Then RotatingPlayer Else AngleAndFacing
  UpdateWalking
  If (jetOk And 128) = 0 Then
    acc(2) = 0
    If Jumping() Then acc(0) = 0
  EndIf
  SpriteAndPalette pAngle, pFacing
End Sub

Sub RotatingPlayer       ' immobilised by damage: the player spins
  Local a, a2, c, hit, n
  immob = (immob - 1) And 255
  a2 = (pAngle << 1) And 255
  hit = 0
  If tbColl And 128 Then
    a = preAng : hit = 1
  ElseIf oTouch And 128 Then
    a = rotVel
  Else
    a = &H40 : hit = 1
  EndIf
  If hit Then
    a = (a << 1) And 255
    a = Sub8(a, a2, 1) : c = cy
    a = (c << 7) Or (a >> 1)
    n = a And 128
    a = (preMag >> 2) Or 1
    If n Then a = (-a) And 255
    a = Add8(a, rotVel, 0)
    a = KeepRange(a, &H20)
  EndIf
  If frm Mod 4 = 0 And a >= 4 And a < &HFD Then a = SevenEighths(a)
  rotVel = a
  pAngle = (pAngle + a) And 255
End Sub

Sub AngleAndFacing       ' update_player_angle_and_player_facing
  Local xi, c, a, yy, kept
  vec(0) = acc(0) : vec(2) = acc(2)
  xi = ((acc(2) <> 0) << 1) Or (acc(0) <> 0)
  c = 0
  If xi <> 0 And (jetOk And 128) <> 0 Then
    a = AngleFromVec() : c = 1
  Else
    a = &HC0
    If lying And 128 Then
      If pFacing And 128 Then a = &H83 Else a = &HFD
    EndIf
  EndIf
  a = Sub8(a, pAngle, c)
  yy = a : kept = 0
  If xi = 2 Then
    a = Sub8(a, &H74, 1)
    If a < &H18 Then yy = 0 : xi = 0 : kept = 1
  EndIf
  If kept = 0 Then
    If acc(0) = 0 Or (upright And 128) = 0 Then xi = 0
  EndIf
  c = Jumping()
  a = yy
  If c = 0 And (lying And 128) = 0 Then a = 0
  a = Asr(a) : a = Asr(a) : c = cy
  pAngle = Add8(a, pAngle, c)
  a = pAngle Xor acc(0) Xor 128
  If (((xi - 1) And 255) And 128) = 0 Then pFacing = a
End Sub

Sub UpdateWalking        ' consider_updating_walking_player
  Local c, yy, a
  walkSpd = &H1F
  c = (fc16 >= 2)
  yy = Sub8(weight, 5, c) : c = cy
  If c Then
    If Jumping() And (anyB And 128) = 0 Then
      Do
        acc(2) = HalveTowardZero(acc(2)) : acc(0) = HalveTowardZero(acc(0))
        yy = (yy - 1) And 255
        If yy And 128 Then Exit Do
      Loop
      WalkPlayer
      Exit Sub
    EndIf
  EndIf
  a = &H0F
  yy = (yy + 1) And 255
  Do
    c = a And 1 : a = a >> 1
    yy = (yy - 1) And 255
    If yy And 128 Then Exit Do
  Loop
  a = Add8(a, 1, c)
  relTX = acc(0)
  If acc(0) = 0 Then walkSpd = 0 : a = 1
  maxAcc0 = a
  If Jumping() = 0 Then acc(0) = 0
  WalkPlayer
End Sub

Function WalkState()     ' update_walking_state: returns the state
  Local c, a
  If (upright And 128) = 0 Then
    oState = oState Or &H0F : WalkState = oState : Exit Function
  EndIf
  c = 1
  If (tbColl Or objCY) And 128 Then c = (InvNeg(tileAng) >= &H32)
  a = oState And &HF0
  If c = 0 Then
    oState = a : WalkState = oState : Exit Function
  EndIf
  If (a Xor oState) < &H0F Then oState = (oState + 1) And 255
  WalkState = oState
End Function

Sub WalkPlayer           ' update_walking_npc_or_player with the player's walking type
  Local a, c, maxacc, yy, spd
  a = WalkState()
  If a And &H0F Then Exit Sub
  maxacc = maxAcc0 : yy = npcW0
  a = InvNeg(tileAng)
  c = (a >= &H32)
  a = Sub8(a, &H2C, c)
  c = (a >= &H28)
  spd = walkSpd
  If c = 0 Then ClimbSteep spd, yy, maxacc Else WalkAlong spd, yy, maxacc
End Sub

Sub WalkAlong(spd, yy, maxacc)   ' walk_along_flat_or_shallow_slope
  Local a, c, accl, angl, m
  If relTX And 128 Then a = (-spd) And 255 Else a = spd
  a = Sub8(a, vel(0), 1)
  accl = WeightLimit(a, cy, ov, yy, maxacc)
  a = (accl And 128) Xor tileAng
  a = Add8(a, &H40, 0)
  c = a >> 7
  If relTX = 0 Then accl = 0
  If c = 0 Then angl = Add8(&H10, tileAng, 0) Else angl = Add8(&H6F, tileAng, 1)
  m = InvNeg(accl)
  VecFromMagAngle m, angl
  acc(2) = vecA : acc(0) = vec(0)
  vel(2) = SevenEighths(SevenEighths(vel(2)))
End Sub

Sub ClimbSteep(spd, yy, maxacc)  ' climb_steep_slope: up or down as the last creature's target says
  Local a
  If relTY And 128 Then a = (-spd) And 255 Else a = spd
  WeightedAccel a, yy, 2, maxacc
  If tileAng And 128 Then acc(0) = 8 Else acc(0) = &HF8
  vel(0) = SevenEighths(SevenEighths(SevenEighths(vel(0))))
End Sub

Sub SpriteAndPalette(a, yy)     ' set_spacesuit_sprite_and_palette
  Local flsh, pal, c, t
  If (child And 128) = 0 Then xFlipP = yy : SpriteFromAngle a
  flsh = ((((fc And &H1F) << 1) And 255) >= oEnergy)
  pal = palDefault
  c = CheckReliability(5)
  t = ((c << 7) Or (pal >> 1)) And suitCol
  If t And 128 Then pal = &H33 Else pal = &H3E
  If flsh Then pal = oPal Xor &H0B
  oPal = pal
End Sub

Sub SpriteFromAngle(av)   ' set_spacesuit_sprite_from_angle
  Local a, c, i, h, stg
  a = av : c = 0
  For i = 1 To 5
    c = a And 1 : a = a >> 1
  Next i
  a = Add8(a, 0, c)
  If (xFlipP And 128) = 0 Then a = a Xor 7 : a = Add8(a, 1, 0)
  h = a
  c = ((a And 4) = 4)
  xFlip = (c << 7) Or ((a And 4) >> 1)
  yFlip = xFlip Xor xFlipP
  a = h And 3
  If a <> 2 Then ChangeSprite a : Exit Sub
  If (InvNeg(vel(0)) >> 1) = 0 Then ChangeSprite 4 : Exit Sub
  If Jumping() Then ChangeSprite 2 : Exit Sub
  a = SpriteOffset(8)
  stg = a >> 1
  If (vel(0) Xor xFlip) And 128 Then stg = stg Xor 3
  stg = (stg + 4) And 255
  ChangeSprite stg
End Sub

Function SpriteOffset(modulus)   ' update_sprite_offset_using_velocities: faster animation when faster
  Local a, c, b
  a = InvNeg(vel(0)) : b = InvNeg(vel(2))
  If b > a Then a = b
  a = a >> 4
  a = Add8(a, oTimer, 1)
  c = 1
  Do
    a = Sub8(a, modulus, c) : c = cy
    If c = 0 Then Exit Do
  Loop
  a = Add8(a, modulus, c)
  oTimer = a
  SpriteOffset = a
End Function

Sub ChangeSprite(a)       ' change_object_sprite_to_A, keeping the centre where it was
  Local d, c
  If a = oSpr Then Exit Sub
  oSpr = a
  d = Sub8(siz(2), sprH(a), 1) : c = cy
  d = ((c << 7) Or (d >> 1)) Xor 128
  AddToPos 2, d, d And 128
  d = Sub8(siz(0), sprW(a), 1) : c = cy
  d = ((c << 7) Or (d >> 1)) Xor 128
  AddToPos 0, d, d And 128
End Sub

Sub AimingAngle           ' update_player_aiming_angle
  Local a
  a = aimAccT
  If a Then a = Add8(a, aimVel, 0) : a = KeepRange(a, &H10)
  aimVel = a
  a = Add8(a, aim, 0)
  a = KeepRange(a, &H3F)
  aim = a
  If xFlip And 128 Then a = ((a Xor &H7F) + 1) And 255
  aimFlip = a
End Sub

' ===================================================================
' apply_acceleration_to_velocities (&1f01): gravity, the limit, inertia
' ===================================================================
Sub ApplyAcceleration
  Local xi, c, a, n, yy, old
  For xi = 2 To 0 Step -2
    c = (xi = 2)
    a = acc(xi) : n = a And 128
    a = Add8(a, vel(xi), c)
    If ov Then a = (&H7F + cy) And 255
    yy = a
    If n Then a = (-a) And 255
    a = Sub8(a, &H3F, 0)
    If a < &H40 Then
      old = vel(xi) : yy = old
      If InvNeg(old) < &H40 Then
        If old And 128 Then yy = &HC0 Else yy = &H40
      EndIf
    EndIf
    If frm Mod 16 = 0 And yy <> 0 Then
      If yy And 128 Then yy = (yy + 1) And 255 Else yy = (yy - 1) And 255
    EndIf
    vel(xi) = yy
  Next xi
End Sub

' ---- tables and the starting slot follow, appended by gen_phystest.py ----
