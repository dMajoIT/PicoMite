' worldview.bas - fly around Exile's planet
'
' Phase 2 of docs/Exile_Port_Design_Review.html: the world on screen with
' no physics.  The two tileset images and the two map files come from
' Bas/exile_tools (gen_world.py, gen_tiles.py, gen_objects.py) and sit beside
' this program: exile_tiles1.bmp, exile_slot2.bmp, exile_w1.map, exile_w2.map.
' Slot 2 holds the tail of the tileset with the object sheet below it, because
' the third flash slot is the library's, where the physics kernel lives.
'
' The tiles are drawn last with black transparent, over a black sky and
' the four waterlines, which is the render order the game will use.  The
' view is 256 x 240 (8 by 7.5 squares, the enhanced BBC version's width)
' beside a 64-pixel panel that is drawn once and never cleared - decision
' D4 of the review, taken for the creature population the view size sets
' as much as for the 0.6 ms a frame it saves.
'
'   arrows   scroll (a square a press; hold for repeat)
'   1 2 3    the landing site, the ship close up, Triax's lab
'   S        screenshot to exile_view1.bmp, 2, 3 ... beside the program
'   Q        quit
Option EXPLICIT
Option BASE 0
' the screen is for the world; what is printed goes to the serial console
Option CONSOLE SERIAL

Const TW = 32, TH = 32                 ' a square is 16 x 32 BBC pixels, drawn 2:1
Const WORLDW = 256 * TW, WORLDH = 256 * TH
Const VIEWW = 256, VIEWH = 240         ' the play area
Const PANELX = 256, PANELW = 64        ' the panel beside it
Const HOMEX = &H8A * TW, HOMEY = &H4A * TH
Dim integer vx, vy, frames, wlx(4), wly(3), r, xs0, xs1, ys, shots
Dim float t0, ms
Dim k$, homeDir$
homeDir$ = MM.Info(Path) : If homeDir$ = "NONE" Then homeDir$ = "A:/"

wlx(0) = 0 : wlx(1) = &H54 : wlx(2) = &H74 : wlx(3) = &HA0 : wlx(4) = 256
wly(0) = &HCE : wly(1) = &HDF : wly(2) = &HC1 : wly(3) = &HC1

MODE 2
CLS
FRAMEBUFFER CREATE
Print "Exile: loading the tilesets into flash ..."
Flash LOAD IMAGE 1, homeDir$ + "exile_tiles1.bmp", O
Flash LOAD IMAGE 2, homeDir$ + "exile_slot2.bmp", O
Print "loading the planet ..."
Tilemap CLOSE
t0 = Timer
Tilemap LOAD homeDir$ + "exile_w1.map", 1, 1, TW, TH, 8
Tilemap LOAD homeDir$ + "exile_w2.map", 2, 2, TW, TH, 8
Print "two 256 x 256 maps in " + Str$(Int(Timer - t0)) + " ms"
vx = HOMEX : vy = HOMEY
DrawPanel
t0 = Timer
Do
  k$ = Inkey$
  If k$ = Chr$(128) Then vy = vy - TH
  If k$ = Chr$(129) Then vy = vy + TH
  If k$ = Chr$(130) Then vx = vx - TW
  If k$ = Chr$(131) Then vx = vx + TW
  If k$ = "1" Then vx = HOMEX : vy = HOMEY
  If k$ = "2" Then vx = &H96 * TW : vy = &H47 * TH
  If k$ = "3" Then vx = &H7F * TW : vy = &HBF * TH
  If vx < 0 Then vx = 0
  If vy < 0 Then vy = 0
  If vx > WORLDW - VIEWW Then vx = WORLDW - VIEWW
  If vy > WORLDH - VIEWH Then vy = WORLDH - VIEWH
  FRAMEBUFFER WRITE F
  Box 0, 0, VIEWW, VIEWH, 0, RGB(BLACK), RGB(BLACK)
  ' water: colour 0 below each range's waterline, a cyan line at the surface
  For r = 0 To 3
    xs0 = wlx(r) * TW - vx : xs1 = wlx(r + 1) * TW - vx : ys = wly(r) * TH - vy
    If xs0 < 0 Then xs0 = 0
    If xs1 > VIEWW Then xs1 = VIEWW
    If xs1 > xs0 And ys < VIEWH Then
      If ys < 0 Then ys = 0
      Box xs0, ys, xs1 - xs0, VIEWH - ys, 0, RGB(BLUE), RGB(BLUE)
      Line xs0, ys, xs1 - 1, ys, 1, RGB(CYAN)
    EndIf
  Next r
  Tilemap DRAW 1, F, vx, vy, 0, 0, VIEWW, VIEWH, 0
  Tilemap DRAW 2, F, vx, vy, 0, 0, VIEWW, VIEWH, 0
  ' the panel's live figures; the rest of it stays from DrawPanel
  Text PANELX + 4, 200, "&" + Hex$(vx \ TW, 2) + " &" + Hex$(vy \ TH, 2), "LT", 7, 1, RGB(WHITE), RGB(BLACK)
  Text PANELX + 4, 212, Str$(Int(ms)) + " ms  ", "LT", 7, 1, RGB(WHITE), RGB(BLACK)
  FRAMEBUFFER COPY F, N
  frames = frames + 1
  If frames Mod 16 = 0 Then ms = (Timer - t0) / 16 : t0 = Timer
  If UCase$(k$) = "S" Then
    FRAMEBUFFER WRITE N
    shots = shots + 1
    Save IMAGE homeDir$ + "exile_view" + Str$(shots) + ".bmp"
    FRAMEBUFFER WRITE F
  EndIf
Loop Until UCase$(k$) = "Q"
FRAMEBUFFER WRITE N
Tilemap CLOSE
Option CONSOLE BOTH
End

' The panel, drawn once.  What the game will put here is what the BBC
' could not afford: energy, the weapon in use and its charge, the pockets.
' For now the layout, with placeholders.
Sub DrawPanel
  Local integer i
  FRAMEBUFFER WRITE F
  Box PANELX, 0, PANELW, VIEWH, 0, RGB(BLACK), RGB(BLACK)
  Line PANELX, 0, PANELX, VIEWH - 1, 1, RGB(WHITE)
  Text PANELX + 32, 6, "EXILE", "CT", 1, 1, RGB(YELLOW)
  Text PANELX + 4, 28, "ENERGY", "LT", 7, 1, RGB(CYAN)
  Box PANELX + 4, 38, 56, 6, 1, RGB(WHITE)
  Box PANELX + 5, 39, 40, 4, 0, RGB(GREEN), RGB(GREEN)
  Text PANELX + 4, 54, "JETPACK", "LT", 7, 1, RGB(CYAN)
  Box PANELX + 4, 64, 56, 6, 1, RGB(WHITE)
  Box PANELX + 5, 65, 30, 4, 0, RGB(GREEN), RGB(GREEN)
  Text PANELX + 4, 80, "POCKETS", "LT", 7, 1, RGB(CYAN)
  For i = 0 To 4
    Box PANELX + 4 + i * 11, 90, 10, 12, 1, RGB(WHITE)
  Next i
  Text PANELX + 4, 188, "square", "LT", 7, 1, RGB(CYAN)
End Sub
