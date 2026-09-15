' ExilePhysicsBench.bas - what an Exile tick would cost the interpreter
'
' Spike S2 of docs/Exile_Port_Design_Review.html.  Sixteen objects go
' through the shape of Exile's per-object update - integrate, collide
' with the tiles through eight-column obstruction profiles, resolve
' support, run a creature behaviour, apply accelerations with gravity,
' the velocity cap and the staggered inertia - plus thirty-two
' particles and the frame's drawing, on a real 256 x 256 TILEMAP.
' Each part is timed on its own over many ticks, then everything
' together, and the arithmetic parts are timed again done across all
' slots at once with MATH C_ADD / MATH ADD instead of a loop.
'
' The numbers are costs, not the game: the behaviours are stand-ins
' with the right amount of branching, table lookups and array traffic.
' Runs the whole set twice, without and with OPTION TRACECACHE.
Option EXPLICIT
Option BASE 0

Const NOBJ = 16, NPART = 32
Const TICKS = 200
Const TW = 32, TH = 32                 ' a square is 32 x 32 screen pixels
Const T_WALK = 1, T_FLY = 2, T_BULLET = 3
Const FRAME_BUDGET = 40

' ---- objects, one array per field as the 6502 keeps them
Dim integer ox(NOBJ - 1), oy(NOBJ - 1)         ' position, 256 fractions a square
Dim integer ovx(NOBJ - 1), ovy(NOBJ - 1)       ' velocity, fractions a tick, +/-64
Dim integer oax(NOBJ - 1), oay(NOBJ - 1)       ' acceleration for this tick
Dim integer otype(NOBJ - 1), oflags(NOBJ - 1), oenergy(NOBJ - 1), otimer(NOBJ - 1)
Dim integer otx(NOBJ - 1), oty(NOBJ - 1), omood(NOBJ - 1), oweight(NOBJ - 1)
Dim integer ow(NOBJ - 1), oh(NOBJ - 1), osprite(NOBJ - 1), ocollang(NOBJ - 1)
' ---- particles
Dim integer px(NPART - 1), py(NPART - 1), pvx(NPART - 1), pvy(NPART - 1)
Dim integer plife(NPART - 1), pcol(NPART - 1)
' ---- tables
Dim integer obst(7, 7)                          ' obstruction profile per tile type
Dim integer walkacc(3), walkmax(3), jumpprob(3), maxangle(3)
Dim integer wlx(3), wly(3)                      ' waterlines by x range
Dim integer tick, i, k, n, r
Dim float t0, tInt, tColl, tBeh, tPart, tDraw, tFull, tIntM, tPartM

MODE 2
CLS
FRAMEBUFFER CREATE
Print "Exile physics bench on " + MM.Device$ + " " + Str$(MM.Ver)
MakeTileset
Flash LOAD IMAGE 1, "bench_tiles.bmp", O
MakeMap
Tilemap CLOSE
Tilemap LOAD "bench.map", 1, 1, TW, TH, 8
LoadTables
ResetWorld

RunSuite "cache off"
On Error Skip 1
Option TRACECACHE ON 80
If MM.ErrNo <> 0 Then
  Print "OPTION TRACECACHE not available: " + MM.ErrMsg$
  On Error Clear
Else
  ResetWorld
  RunSuite "TRACECACHE ON 80"
EndIf
FRAMEBUFFER WRITE N
Print "done"
End

' =====================================================================
Sub RunSuite(label$)
  Local integer j
  Print
  Print "---- " + label$ + ", ms per tick over " + Str$(TICKS) + " ticks"
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : Integrate : Next j
  tInt = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : CollideAll : Next j
  tColl = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : BehaveAll : Next j
  tBeh = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : Particles : Next j
  tPart = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : DrawFrame : Next j
  tDraw = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : IntegrateMath : Next j
  tIntM = (Timer - t0) / TICKS
  t0 = Timer
  For j = 1 To TICKS : tick = tick + 1 : ParticlesMath : Next j
  tPartM = (Timer - t0) / TICKS
  ResetWorld
  t0 = Timer
  For j = 1 To TICKS
    tick = tick + 1
    Integrate : CollideAll : BehaveAll : Particles : DrawFrame
  Next j
  tFull = (Timer - t0) / TICKS
  Print "  integrate, 16 objects, loop   " + Fmt$(tInt) + "   with MATH " + Fmt$(tIntM)
  Print "  tile collision, 16 objects    " + Fmt$(tColl)
  Print "  behaviours, 16 objects        " + Fmt$(tBeh)
  Print "  particles, 32, loop           " + Fmt$(tPart) + "   with MATH " + Fmt$(tPartM)
  Print "  draw: 2 tilemaps, 16 blits, 32 pixels, copy   " + Fmt$(tDraw)
  Print "  FULL TICK, loops              " + Fmt$(tFull) + " of " + Str$(FRAME_BUDGET) + " ms  (" + Str$(Int(100 * tFull / FRAME_BUDGET)) + "%)"
  Print "  full tick if MATH replaced the loops: about " + Fmt$(tFull - tInt - tPart + tIntM + tPartM)
End Sub

Function Fmt$(v As float)
  Fmt$ = Str$(Int(v * 100) / 100) + " ms"
End Function

' =====================================================================
'  the kernel
' =====================================================================

' velocity into position, then this tick's accelerations into velocity
' with gravity, the +/-64 cap, and inertia on one object in sixteen
Sub Integrate
  Local integer j, v
  For j = 0 To NOBJ - 1
    ox(j) = ox(j) + ovx(j)
    oy(j) = oy(j) + ovy(j)
    v = ovx(j) + oax(j)
    If v > 64 Then v = 64
    If v < -64 Then v = -64
    ovx(j) = v
    v = ovy(j) + oay(j) + 1                 ' gravity is the carry
    If v > 64 Then v = 64
    If v < -64 Then v = -64
    ovy(j) = v
    If ((tick + j) And 15) = 0 Then         ' inertia, staggered by slot
      If ovx(j) > 0 Then ovx(j) = ovx(j) - 1
      If ovx(j) < 0 Then ovx(j) = ovx(j) + 1
      If ovy(j) > 0 Then ovy(j) = ovy(j) - 1
      If ovy(j) < 0 Then ovy(j) = ovy(j) + 1
    EndIf
    oax(j) = 0 : oay(j) = 0
  Next j
End Sub

' the same arithmetic across all slots at once with MATH, including the
' cap with MATH CLAMP; only the one inertia object needs its own code
Sub IntegrateMath
  Local integer j, v
  Math C_ADD ox(), ovx(), ox()
  Math C_ADD oy(), ovy(), oy()
  Math C_ADD ovx(), oax(), ovx()
  Math C_ADD ovy(), oay(), ovy()
  Math ADD ovy(), 1, ovy()
  Math SET 0, oax()
  Math SET 0, oay()
  Math CLAMP ovx(), -64, 64, ovx()
  Math CLAMP ovy(), -64, 64, ovy()
  j = (16 - (tick And 15)) And 15           ' the slot whose inertia tick this is
  If ovx(j) > 0 Then ovx(j) = ovx(j) - 1
  If ovx(j) < 0 Then ovx(j) = ovx(j) + 1
  If ovy(j) > 0 Then ovy(j) = ovy(j) - 1
  If ovy(j) < 0 Then ovy(j) = ovy(j) + 1
End Sub

Sub CollideAll
  Local integer j
  For j = 0 To NOBJ - 1 : Collide j : Next j
End Sub

' Exile samples the tiles along the object's top and bottom edges one
' obstruction column (two pixels) at a time and compares the profile
' height with the edge, then the sides.  Positions are 16 fractions a
' pixel across and 8 down; a square is 16 x 32 of the game's pixels,
' drawn 2:1, so a tile lookup takes (2 * xpx, ypx).
Sub Collide(j As integer)
  Local integer xl, xr, yt, yb, xp, t, h, c, hitb, hitt, hits, wl
  xl = ox(j) \ 16 : xr = xl + ow(j) - 1
  yt = oy(j) \ 8 : yb = yt + oh(j) - 1
  hitb = 0 : hitt = 0 : hits = 0
  For xp = xl To xr Step 2
    c = (xp And 15) \ 2
    t = Tilemap(TILE 1, xp * 2, yb)
    h = obst(t And 7, c)
    If ((yb And 31) << 3) >= 256 - h Then hitb = hitb Or 1
    t = Tilemap(TILE 1, xp * 2, yt)
    h = obst(t And 7, c)
    If ((yt And 31) << 3) < h Then hitt = hitt Or 1
  Next xp
  t = Tilemap(TILE 1, (xl - 1) * 2, yt + oh(j) \ 4)
  If obst(t And 7, 7) > 128 Then hits = hits Or 1
  t = Tilemap(TILE 1, (xl - 1) * 2, yb - oh(j) \ 4)
  If obst(t And 7, 7) > 128 Then hits = hits Or 1
  t = Tilemap(TILE 1, (xr + 1) * 2, yt + oh(j) \ 4)
  If obst(t And 7, 0) > 128 Then hits = hits Or 2
  t = Tilemap(TILE 1, (xr + 1) * 2, yb - oh(j) \ 4)
  If obst(t And 7, 0) > 128 Then hits = hits Or 2
  ' water: drag every four ticks below the waterline of this x range
  wl = wly(WaterRange(ox(j)))
  If oy(j) > wl And (tick And 3) = 0 Then
    ovx(j) = ovx(j) * 7 \ 8 : ovy(j) = ovy(j) * 7 \ 8
    If oweight(j) < 4 Then ovy(j) = ovy(j) - 2 Else ovy(j) = ovy(j) - 1
  EndIf
  ' resolve: supported, wedged, bounce
  oflags(j) = oflags(j) And (Not 2)
  If hitb Then
    If hitt Then
      oflags(j) = oflags(j) Or 4                    ' wedged
    Else
      oflags(j) = oflags(j) Or 2                    ' supported
      oy(j) = (((yb \ 32) * 32) - oh(j)) * 8        ' sit on the tile
      If ovy(j) > 16 Then
        ovy(j) = -((ovy(j) - 2) * 7 \ 8)             ' bounce
        If ovy(j) < -32 Then ovy(j) = -32
      Else
        ovy(j) = 0
      EndIf
    EndIf
    ocollang(j) = (h \ 32) * 8                       ' a stand-in for the slope angle
  ElseIf hitt Then
    ovy(j) = 2
  EndIf
  If hits Then
    ovx(j) = -((ovx(j) * 7) \ 8)
    If hits And 1 Then ox(j) = ox(j) + 32 Else ox(j) = ox(j) - 32
  EndIf
End Sub

Function WaterRange(x As integer) As integer
  If x >= wlx(3) Then
    WaterRange = 3
  ElseIf x >= wlx(2) Then
    WaterRange = 2
  ElseIf x >= wlx(1) Then
    WaterRange = 1
  Else
    WaterRange = 0
  EndIf
End Function

Sub BehaveAll
  Local integer j
  For j = 0 To NOBJ - 1
    Select Case otype(j)
      Case T_WALK
        Walker j
      Case T_FLY
        Flyer j
      Case T_BULLET
        Bullet j
    End Select
    If (tick And 3) = 0 Then                       ' the every-four-ticks distance check
      If Abs(ox(j) - ox(0)) > 12 * 256 Or Abs(oy(j) - oy(0)) > 12 * 256 Then otimer(j) = otimer(j) + 1
    EndIf
  Next j
End Sub

' a stand-in for the walking creatures: mood, line of sight to the
' player, remembered target, walking with turn and jump chances, the
' slope test, and a shot now and then
Sub Walker(j As integer)
  Local integer dx, dy, dr, rn, los, m, tp
  tp = otype(j)
  rn = Rnd() * 65536
  dx = ox(0) - ox(j) : dy = oy(0) - oy(j)
  If ((tick + j) And 15) = 0 Then
    If Abs(dx) < 4096 And Abs(dy) < 2048 Then omood(j) = omood(j) + 1 Else omood(j) = omood(j) - 1
    If omood(j) > 1 Then omood(j) = 1
    If omood(j) < -2 Then omood(j) = -2
  EndIf
  los = 1
  For m = 1 To 4
    If Tilemap(TILE 1, (ox(j) + dx * m \ 5) \ 8, (oy(j) + dy * m \ 5) \ 8) > 0 Then
      los = 0
      Exit For
    EndIf
  Next m
  If los Then otx(j) = ox(0) : oty(j) = oy(0)
  If oflags(j) And 2 Then
    dr = Sgn(otx(j) - ox(j))
    If (rn And 63) = 0 Then dr = -dr
    If omood(j) < 0 Then dr = -dr
    oax(j) = dr * walkacc(tp)
    If Abs(ovx(j)) > walkmax(tp) Then oax(j) = 0
    If ocollang(j) > maxangle(tp) Then oax(j) = -oax(j)
    If (rn And 255) < jumpprob(tp) Then ovy(j) = -(10 - oweight(j)) * 2
  Else
    oax(j) = Sgn(otx(j) - ox(j))
  EndIf
  If los And (rn And 127) = 0 Then Spawn j, T_BULLET
  If oenergy(j) <= 0 Then Explode j
End Sub

' flying creatures: thrust toward the remembered target, directness
' decides whether the path is straight or relaxed
Sub Flyer(j As integer)
  Local integer dx, dy, rn
  rn = Rnd() * 65536
  dx = otx(j) - ox(j) : dy = oty(j) - oy(j)
  If (rn And 3) = 0 Then otx(j) = ox(0) : oty(j) = oy(0)
  If (rn And 12) = 0 Then
    oax(j) = Sgn(dx) * 2 : oay(j) = Sgn(dy) * 2 - 1
  Else
    oax(j) = Sgn(dx) : oay(j) = -1
  EndIf
  If Abs(dx) < 512 And Abs(dy) < 512 Then oenergy(j) = oenergy(j) - 1
  If oenergy(j) <= 0 Then Explode j
End Sub

Sub Bullet(j As integer)
  otimer(j) = otimer(j) - 1
  oay(j) = -1                                        ' bullets are not pulled down
  If otimer(j) <= 0 Or (oflags(j) And 6) Then Explode j
End Sub

' put a new object in a free slot, as create_new_object_if_Y_slots_free
Sub Spawn(parent As integer, kind As integer)
  Local integer j
  For j = 1 To NOBJ - 1
    If otype(j) = 0 Then Exit For
  Next j
  If j >= NOBJ Then Exit Sub
  otype(j) = kind : ox(j) = ox(parent) : oy(j) = oy(parent)
  ovx(j) = Sgn(ox(0) - ox(parent)) * 48 : ovy(j) = -8
  oax(j) = 0 : oay(j) = 0 : oflags(j) = 0 : oenergy(j) = 1
  otimer(j) = 40 : ow(j) = 3 : oh(j) = 2 : osprite(j) = 5 : oweight(j) = 1
End Sub

' an explosion is particles and a freed slot; the bench refills the
' slot at once so the object count stays at sixteen
Sub Explode(j As integer)
  Local integer m, q
  For m = 0 To 7
    q = (tick + m) And (NPART - 1)
    px(q) = ox(j) : py(q) = oy(j)
    pvx(q) = (m - 4) * 6 : pvy(q) = -12 + m : plife(q) = 20 : pcol(q) = 8 + (m And 7)
  Next m
  otype(j) = T_WALK + (j Mod 2)
  ox(j) = ox(0) + (j - 8) * 512 : oy(j) = oy(0) - 512
  ovx(j) = 0 : ovy(j) = 0 : oenergy(j) = 20 + j : otimer(j) = 0
End Sub

' thirty-two particles: move, fall, age, respawn as jetpack exhaust
Sub Particles
  Local integer m
  For m = 0 To NPART - 1
    plife(m) = plife(m) - 1
    If plife(m) < 0 Then
      px(m) = ox(0) : py(m) = oy(0) + 160
      pvx(m) = (m And 7) - 4 : pvy(m) = 4 + (m And 3) : plife(m) = 8 + (m And 15) : pcol(m) = 14
    EndIf
    px(m) = px(m) + pvx(m)
    py(m) = py(m) + pvy(m)
    pvy(m) = pvy(m) + 1
  Next m
End Sub

Sub ParticlesMath
  Local integer m
  Math ADD plife(), -1, plife()
  Math C_ADD px(), pvx(), px()
  Math C_ADD py(), pvy(), py()
  Math ADD pvy(), 1, pvy()
  For m = 0 To NPART - 1
    If plife(m) < 0 Then
      px(m) = ox(0) : py(m) = oy(0) + 160
      pvx(m) = (m And 7) - 4 : pvy(m) = 4 + (m And 3) : plife(m) = 8 + (m And 15) : pcol(m) = 14
    EndIf
  Next m
End Sub

' the frame: background, objects, the tiles over them (twice, as the
' two flash-slot maps would be), particles, and the copy to the screen
Sub DrawFrame
  Local integer j, sx, sy, vx, vy
  vx = (ox(0) \ 8) - 160 : vy = (oy(0) \ 8) - 120
  If vx < 0 Then vx = 0
  If vy < 0 Then vy = 0
  FRAMEBUFFER WRITE F
  Box 0, 0, 320, 240, 0, RGB(BLACK), RGB(BLACK)
  Box 0, 200, 320, 40, 0, RGB(BLUE), RGB(BLUE)
  For j = 0 To NOBJ - 1
    sx = (ox(j) \ 8) - vx : sy = (oy(j) \ 8) - vy
    If sx > -32 And sx < 320 And sy > -32 And sy < 240 Then
      Blit FLASH 1, F, (osprite(j) And 7) * 32, 0, sx, sy, 32, 32, 0
    EndIf
  Next j
  Tilemap DRAW 1, F, vx, vy, 0, 0, 320, 240, 0
  Tilemap DRAW 1, F, vx, vy, 0, 0, 320, 240, 0
  For j = 0 To NPART - 1
    sx = (px(j) \ 8) - vx : sy = (py(j) \ 8) - vy
    If sx >= 0 And sx < 320 And sy >= 0 And sy < 240 Then Pixel sx, sy, pcol(j)
  Next j
  FRAMEBUFFER COPY F, N
End Sub

' =====================================================================
'  set-up
' =====================================================================
Sub ResetWorld
  Local integer j
  tick = 0
  For j = 0 To NOBJ - 1
    ox(j) = (128 + (j - 8) * 3) * 256 : oy(j) = 76 * 256 - j * 64
    ovx(j) = (j And 3) - 1 : ovy(j) = 0 : oax(j) = 0 : oay(j) = 0
    If j = 0 Then
      otype(j) = T_WALK
    ElseIf j < 10 Then
      otype(j) = T_WALK
    ElseIf j < 14 Then
      otype(j) = T_FLY
    Else
      otype(j) = T_BULLET
    EndIf
    oflags(j) = 0 : oenergy(j) = 30 + j : otimer(j) = 200
    otx(j) = ox(0) : oty(j) = oy(0) : omood(j) = 0 : oweight(j) = 1 + (j And 3)
    ow(j) = 5 + (j And 7) : oh(j) = 12 + (j And 7) : osprite(j) = j And 7 : ocollang(j) = 0
  Next j
  For j = 0 To NPART - 1
    px(j) = ox(0) : py(j) = oy(0) : pvx(j) = 0 : pvy(j) = 0 : plife(j) = j : pcol(j) = 14
  Next j
End Sub

Sub LoadTables
  Local integer t, c
  ' eight tile types: 0 open, 1-3 rock, 4-5 slopes, 6 half, 7 open
  For c = 0 To 7
    obst(0, c) = 0 : obst(1, c) = 255 : obst(2, c) = 255 : obst(3, c) = 255
    obst(4, c) = c * 32 : obst(5, c) = 224 - c * 32 : obst(6, c) = 128 : obst(7, c) = 0
  Next c
  walkacc(0) = 6 : walkacc(1) = 8 : walkacc(2) = 16 : walkacc(3) = 3
  walkmax(0) = 24 : walkmax(1) = 32 : walkmax(2) = 40 : walkmax(3) = 12
  jumpprob(0) = 0 : jumpprob(1) = 8 : jumpprob(2) = 16 : jumpprob(3) = 4
  maxangle(0) = 50 : maxangle(1) = 128 : maxangle(2) = 128 : maxangle(3) = 32
  wlx(0) = 0 : wlx(1) = &H54 * 256 : wlx(2) = &H74 * 256 : wlx(3) = &HA0 * 256
  wly(0) = &HCE * 256 : wly(1) = &HDF * 256 : wly(2) = &HC1 * 256 : wly(3) = &HC1 * 256
End Sub

' eight 32 x 32 tiles: open, three rocks, two slopes, a half, a bright one
Sub MakeTileset
  Local integer j
  CLS RGB(BLACK)
  Box 32, 0, 32, 32, 0, RGB(BROWN), RGB(BROWN)
  Box 64, 0, 32, 32, 0, RGB(RUST), RGB(RUST)
  Box 96, 0, 32, 32, 0, RGB(MYRTLE), RGB(MYRTLE)
  Triangle 128, 32, 160, 32, 160, 0, RGB(BROWN), RGB(BROWN)
  Triangle 160, 0, 160, 32, 192, 32, RGB(BROWN), RGB(BROWN)
  Box 192, 16, 32, 16, 0, RGB(BROWN), RGB(BROWN)
  Box 224, 0, 32, 32, 0, RGB(YELLOW), RGB(YELLOW)
  For j = 1 To 7 : Box j * 32 + 8, 8, 16, 16, 1, RGB(WHITE) : Next j
  Save IMAGE "bench_tiles.bmp", 0, 0, 256, 32
End Sub

' a cave: sky above row 78, corridors and chambers below, slopes where
' a chamber floor meets rock
Sub MakeMap
  Local integer x, y, v
  Local s$
  Print "writing bench.map ..."
  Open "bench.map" For Output As #1
  Print #1, "256 256"
  For y = 0 To 255
    For x = 0 To 255 Step 16
      s$ = ""
      For v = x To x + 15
        s$ = s$ + Str$(MapTile(v, y)) + " "
      Next v
      Print #1, s$
    Next x
  Next y
  Close #1
End Sub

Function MapTile(x As integer, y As integer) As integer
  Local integer isopen
  If y < 78 Then
    MapTile = 0
    Exit Function
  EndIf
  isopen = 0
  If (y Mod 9) >= 3 And (y Mod 9) <= 5 Then isopen = 1
  If ((x * 13 + y * 7) Mod 17) < 3 Then isopen = 1
  If ((x \ 8 + y \ 8) Mod 5) = 0 And (x Mod 8) > 1 And (y Mod 8) > 1 Then isopen = 1
  If isopen Then
    MapTile = 0
  ElseIf (y Mod 9) = 6 And ((x + y) Mod 5) = 0 Then
    MapTile = 4 + (x And 1)
  Else
    MapTile = 1 + ((x + y) Mod 3)
  EndIf
End Function
