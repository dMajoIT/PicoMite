' exile_harness.bas - Exile, playing.  gen_exilegame.py puts the layouts where
' the marker is to make exile.bas.
'
' The kernel that ran the recorded scenes now runs free: it draws its own
' random numbers and takes the keys from the game array, a tick at a time.
' Everything the game knows lives in obj() and game(), which the kernel reads
' and writes; this program only reads them back to draw.
'
' The kernel is a CSUB of some 35 KB.  Pasted into a program it costs its hex
' text as well, which is more than program memory holds, so it lives in the
' library.  LIBRARY LOAD must be the program's first statement, and it hashes
' the file, so loading an unchanged one costs nothing.  The path is literal
' because MM.INFO(PATH) is "NONE" for a program that arrived over AUTOSAVE.
'
'   Q W      walk or fly left and right
'   P L      up and down
'   SPACE    fire, once a weapon has been found and picked up
'   F1-F10   pick a weapon up (F1 is the jetpack, which fires nothing);
'            with shift, pour energy from the one in use into it
'   arrows   move the view on its own
'   TAB      the map
'   ESC      quit
LIBRARY LOAD "A:/exile_lib.bas", O
Option EXPLICIT
Option DEFAULT INTEGER
Option BASE 0
' the screen is the game's; what is printed goes to the serial console
Option CONSOLE SERIAL

Const TW = 32, TH = 32                 ' a square is 16 x 32 BBC pixels, drawn 2:1
Const VIEWW = 256, VIEWH = 240         ' the play area, 8 by 7.5 squares
Const PANELX = 256, PANELW = 64        ' the panel beside it
Const WORLDW = 256 * TW, WORLDH = 256 * TH
Const MSPERTICK = 40                      ' 25 Hz, the rate the BBC's replot fixed
Const SHOTAT = 60                      ' the one screenshot, for checking from the desktop

' @@CONSTS@@

Dim obj(287), game(NGAME - 1), world(25599), tbl(511), feed(7)
Dim part(255)                          ' the particle system, eight words a particle
Dim sheet(OS_N - 1)
Dim wlx(4)
Dim pcol(7)                            ' the eight colours a particle can be
Dim keyHeld(38)
Dim quitting
Dim homeDir$
Dim Float frameMs, tickMs, drawMs

Main
End

Sub Main
  Local n, quit, shown
  Local Float t0, t1, tNext, tickAcc, drawAcc
  homeDir$ = MM.Info(Path) : If homeDir$ = "NONE" Then homeDir$ = "A:/"
  wlx(0) = 0 : wlx(1) = &H54 : wlx(2) = &H74 : wlx(3) = &HA0 : wlx(4) = 256
  pcol(0) = RGB(BLACK)  : pcol(1) = RGB(RED)     : pcol(2) = RGB(GREEN) : pcol(3) = RGB(YELLOW)
  pcol(4) = RGB(BLUE)   : pcol(5) = RGB(MAGENTA) : pcol(6) = RGB(CYAN)  : pcol(7) = RGB(WHITE)
  LoadAll
  t0 = Timer
  tNext = Timer + MSPERTICK
  Do
    ReadKeys
    If quitting Then quit = 1
    game(G_KMASK) = KeyMask()
    t1 = Timer
    ExileTick obj(), game(), world(), tbl(), feed(), part()
    tickAcc = tickAcc + (Timer - t1)
    If game(G_FAULT) Then
      Print "fault "; game(G_FAULT); " arg &"; Hex$(game(G_FAULTARG)); " at frame "; game(G_FRAME)
      game(G_FAULT) = 0
    EndIf
    t1 = Timer
    DrawFrame
    drawAcc = drawAcc + (Timer - t1)
    n = n + 1
    If n Mod 25 = 0 Then
      frameMs = (Timer - t0) / 25 : tickMs = tickAcc / 25 : drawMs = drawAcc / 25
      tickAcc = 0 : drawAcc = 0 : t0 = Timer
    EndIf
    ' one screenshot, once the view has settled, so the rendering can be
    ' checked from the desktop: nothing here can press the board's keys
    If n = SHOTAT And shown = 0 Then
      shown = 1
      FRAMEBUFFER WRITE N
      Save IMAGE homeDir$ + "exile_shot.bmp"
      FRAMEBUFFER WRITE F
      Print "screenshot at tick "; n; ", view &"; Hex$(game(G_SCR0), 2); " &"; Hex$(game(G_SCR1), 2)
    EndIf
    ' the game is a lockstep 25 Hz: every constant in the kernel assumes it
    Do While Timer < tNext : Loop
    tNext = tNext + MSPERTICK
    If Timer > tNext + MSPERTICK Then tNext = Timer + MSPERTICK
  Loop Until quit
  FRAMEBUFFER WRITE N
  Tilemap CLOSE
  Option CONSOLE BOTH
  Print "played "; n; " ticks"
End Sub

' ---------------------------------------------------------------- loading
Sub LoadAll
  Local Float t0
  MODE 2
  CLS
  FRAMEBUFFER CREATE
  Print "Exile: the tilesets into flash ..."
  Flash LOAD IMAGE 1, homeDir$ + "exile_tiles1.bmp", O
  Flash LOAD IMAGE 2, homeDir$ + "exile_slot2.bmp", O
  Tilemap CLOSE
  t0 = Timer
  Tilemap LOAD homeDir$ + "exile_w1.map", 1, 1, TW, TH, 8
  Tilemap LOAD homeDir$ + "exile_w2.map", 2, 2, TW, TH, 8
  Print "the planet in "; Int(Timer - t0); " ms"
  Open homeDir$ + "world_types.bin" For Input As #1
  MEMORY INPUT 1, 204800, world()
  Close #1
  Open homeDir$ + "tables2.bin" For Input As #1
  MEMORY INPUT 1, TABLES_BYTES, tbl()
  Close #1
  Open homeDir$ + "objsheet.bin" For Input As #1
  MEMORY INPUT 1, OS_N * 8, sheet()
  Close #1
  Open homeDir$ + "start_obj.bin" For Input As #1
  MEMORY INPUT 1, 288 * 8, obj()
  Close #1
  Open homeDir$ + "start_game.bin" For Input As #1
  MEMORY INPUT 1, NGAME * 8, game()
  Close #1
  Print "the player starts at &"; Hex$(obj(O_X * NSLOT), 2); " &"; Hex$(obj(O_Y * NSLOT), 2)
End Sub

' ---------------------------------------------------------------- the keys
' KEYDOWN(0) is how many keys are held and KEYDOWN(1..6) their characters, so
' the whole set is read once a tick.  Every KEYDOWN call empties the console
' input buffer, so nothing else may read it.
Sub ReadKeys
  Local i, k, sh
  For i = 0 To 38 : keyHeld(i) = 0 : Next i
  quitting = 0
  For i = 1 To 6
    k = KEYDOWN(i)
    If k = 0 Then Exit For
    ' KEYDOWN gives characters, not modifiers, so an upper case letter is how
    ' the shift key shows: which is what shift means to the game anyway
    If k >= 65 And k <= 90 Then sh = 1 : k = k + 32
    ' the function keys pick a weapon up, or with shift pour energy into it;
    ' the game calls them f0 to f9 and F1 is its f0, so the numbers line up
    If k >= 145 And k <= 154 Then
      keyHeld(k - 144) = 1
    Else
      Select Case k
        Case 113 : keyHeld(K_Q) = 1          ' left
        Case 119 : keyHeld(K_W) = 1          ' right
        Case 112 : keyHeld(K_P) = 1          ' up
        Case 108 : keyHeld(K_L) = 1          ' down
        Case 32  : keyHeld(K_SPACE) = 1      ' fire
        Case 128 : keyHeld(K_UP) = 1         ' the arrows move the view alone
        Case 129 : keyHeld(K_DOWN) = 1
        Case 130 : keyHeld(K_LEFT) = 1
        Case 131 : keyHeld(K_RIGHT) = 1
        Case 9   : keyHeld(K_TAB) = 1        ' the map
        Case 103 : keyHeld(K_G) = 1          ' retrieve from a pocket
        Case 115 : keyHeld(K_S) = 1          ' store into one
        Case 116 : keyHeld(K_T) = 1          ' teleport
        Case 114 : keyHeld(K_R) = 1          ' remember where you are
        Case 121 : keyHeld(K_Y) = 1          ' the whistles
        Case 117 : keyHeld(K_U) = 1
        Case 109 : keyHeld(K_M) = 1          ' pick up and drop
        Case 107 : keyHeld(K_K) = 1          ' aim
        Case 111 : keyHeld(K_O) = 1
        Case 46  : keyHeld(K_GT) = 1         ' throw
        Case 27  : quitting = 1              ' quit, which is not the game's
      End Select
    EndIf
  Next i
  If sh Then keyHeld(K_SHIFT) = 1
End Sub

Function KeyMask()
  Local i, m
  For i = 0 To 38
    If keyHeld(i) Then m = m Or (1 << i)
  Next i
  KeyMask = m
End Function

' ---------------------------------------------------------------- the frame
Sub DrawFrame
  Local vx, vy
  ' the view's top left in world pixels: the origin is a square and an eighth
  ' of a pixel, and a square is TW across however wide the game thinks it is
  vx = game(G_SCR0) * TW + (game(G_ORGXF) \ 8)
  vy = game(G_SCR1) * TH + (game(G_ORGYF) \ 8)
  If vx < 0 Then vx = 0
  If vy < 0 Then vy = 0
  If vx > WORLDW - VIEWW Then vx = WORLDW - VIEWW
  If vy > WORLDH - VIEWH Then vy = WORLDH - VIEWH
  FRAMEBUFFER WRITE F
  Box 0, 0, VIEWW, VIEWH, 0, RGB(BLACK), RGB(BLACK)
  DrawWater vx, vy
  DrawObjects vx, vy
  DrawParticles vx, vy
  Tilemap DRAW 1, F, vx, vy, 0, 0, VIEWW, VIEWH, 0
  Tilemap DRAW 2, F, vx, vy, 0, 0, VIEWW, VIEWH, 0
  DrawPanel
  DrawGauges
  FRAMEBUFFER COPY F, N
End Sub

' The four waterlines, each a row and a fraction the events move a tick at a
' time, over their own range of the world.
Sub DrawWater(vx, vy)
  Local r, xs0, xs1, ys
  For r = 0 To 3
    xs0 = wlx(r) * TW - vx : xs1 = wlx(r + 1) * TW - vx
    ys = game(G_WL0 + 4 + r) * TH + (game(G_WL0 + r) \ 8) - vy
    If xs0 < 0 Then xs0 = 0
    If xs1 > VIEWW Then xs1 = VIEWW
    If xs1 > xs0 And ys < VIEWH Then
      If ys < 0 Then ys = 0
      Box xs0, ys, xs1 - xs0, VIEWH - ys, 0, RGB(BLUE), RGB(BLUE)
      Line xs0, ys, xs1 - 1, ys, 1, RGB(CYAN)
    EndIf
  Next r
End Sub

' Every live slot, from the kernel's own tables.  The sheet holds each
' (sprite, palette) in its four orientations; a sprite has six palettes at
' most and usually one, so finding the pair is a short walk.
Sub DrawObjects(vx, vy)
  Local s, spr, pal, flg, fl, i, st, cn, pr, geo, ox, oy, ow, oh, sx, sy
  For s = 0 To NSLOT - 1
    If obj(O_Y * NSLOT + s) <> 0 Then
      spr = obj(O_SPRITE * NSLOT + s)
      pal = obj(O_PALETTE * NSLOT + s) And &H7F
      flg = obj(O_FLAGS * NSLOT + s)
      fl = ((flg >> 7) And 1) Or ((flg >> 5) And 2)
      pr = -1
      If spr < NSPRITE Then
        st = sheet(OS_START + spr) : cn = sheet(OS_COUNT + spr)
        For i = 0 To cn - 1
          If sheet(OS_PAL + st + i) = pal Then pr = st + i : Exit For
        Next i
      EndIf
      If pr >= 0 Then
        geo = sheet(OS_GEO + pr * 4 + fl)
        If geo <> 0 Then
          ox = geo And &HFFFF
          oy = (geo >> 16) And &HFFFF
          ow = (geo >> 32) And &HFF
          oh = (geo >> 40) And &HFF
          sx = obj(O_X * NSLOT + s) * TW + (obj(O_XF * NSLOT + s) \ 8) - vx
          sy = obj(O_Y * NSLOT + s) * TH + (obj(O_YF * NSLOT + s) \ 8) - vy
          ' BLIT clips to the framebuffer and takes a negative corner, so a
          ' sprite may hang off any edge.  What it cannot do is stop at the
          ' view's right-hand edge, but the panel is drawn over that after.
          If sx > -ow And sx < VIEWW And sy > -oh And sy < VIEWH Then
            Blit FLASH 2, F, ox, oy, sx, sy, ow, oh, 2
          EndIf
        EndIf
      EndIf
    EndIf
  Next s
End Sub

' The particle system, straight from the kernel's own array.  A particle is one
' BBC pixel, which is two of ours across, and its colour is the low three bits
' of its flags byte.  They go under the tiles, as the game has them: a particle
' that reaches solid ground is gone by the next tick anyway.
Sub DrawParticles(vx, vy)
  Local i, n, sx, sy
  n = game(G_NPART)
  If n > 127 Then Exit Sub               ' &FF is the game's way of saying none
  For i = 0 To n
    sx = part(i * 8 + P_X) * TW + (part(i * 8 + P_XF) \ 8) - vx
    sy = part(i * 8 + P_Y) * TH + (part(i * 8 + P_YF) \ 8) - vy
    If sx >= 0 And sx < VIEWW - 1 And sy >= 0 And sy < VIEWH - 1 Then
      Box sx, sy, 2, 2, 0, pcol(part(i * 8 + P_CF) And 7), pcol(part(i * 8 + P_CF) And 7)
    EndIf
  Next i
End Sub

' ---------------------------------------------------------------- the panel
Sub DrawPanel
  Local i
  FRAMEBUFFER WRITE F
  Box PANELX, 0, PANELW, VIEWH, 0, RGB(BLACK), RGB(BLACK)
  Line PANELX, 0, PANELX, VIEWH - 1, 1, RGB(WHITE)
  Text PANELX + 32, 6, "EXILE", "CT", 1, 1, RGB(YELLOW)
  Text PANELX + 4, 28, "ENERGY", "LT", 7, 1, RGB(CYAN)
  Text PANELX + 4, 54, "JETPACK", "LT", 7, 1, RGB(CYAN)
  Text PANELX + 4, 80, "POCKETS", "LT", 7, 1, RGB(CYAN)
  For i = 0 To 4
    Box PANELX + 4 + i * 11, 90, 10, 12, 1, RGB(WHITE)
  Next i
End Sub

Sub DrawGauges
  Local e, j, w, i
  e = obj(O_ENERGY * NSLOT) * 56 \ 255
  j = game(G_WHI0) * 56 \ 255
  Box PANELX + 4, 38, 56, 6, 1, RGB(WHITE)
  If e > 2 Then Box PANELX + 5, 39, e - 2, 4, 0, RGB(GREEN), RGB(GREEN)
  Box PANELX + 4, 64, 56, 6, 1, RGB(WHITE)
  If j > 2 Then Box PANELX + 5, 65, j - 2, 4, 0, RGB(GREEN), RGB(GREEN)
  ' how many pockets are in use, which is the only thing that says they hold
  ' anything: the five type bytes keep whatever was last in them.  And the
  ' weapon the function keys have picked up.
  ' Weapon 0 is the jetpack, which fires nothing: a new game starts there and
  ' with none of the others collected, so there is nothing to fire until one
  ' has been found.
  For i = 0 To 4
    If i < game(G_POCKUSED) Then Box PANELX + 5 + i * 11, 91, 8, 10, 0, RGB(YELLOW), RGB(YELLOW)
  Next i
  w = game(G_WEAPON)
  Text PANELX + 4, 108, "WEAPON " + Str$(w) + " ", "LT", 7, 1, RGB(CYAN), RGB(BLACK)
  Box PANELX + 4, 118, 56, 6, 1, RGB(WHITE)
  e = game(G_WHI0 + w) * 56 \ 255
  If e > 2 Then Box PANELX + 5, 119, e - 2, 4, 0, RGB(GREEN), RGB(GREEN)
  Text PANELX + 4, 200, "&" + Hex$(obj(O_X * NSLOT), 2) + " &" + Hex$(obj(O_Y * NSLOT), 2), "LT", 7, 1, RGB(WHITE), RGB(BLACK)
  ' the tick and the draw against the 40 ms a frame the game is paced to
  Text PANELX + 4, 212, "t" + Str$(Int(tickMs * 1000)) + " d" + Str$(Int(drawMs * 1000)) + "us  ", "LT", 7, 1, RGB(WHITE), RGB(BLACK)
End Sub
