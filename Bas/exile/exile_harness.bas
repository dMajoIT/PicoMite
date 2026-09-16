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
Dim glowPal, glowShown                 ' the palette the reserved slots are wearing
Dim kdown(38), kprev(38)               ' what is down now, and what was down last tick
Dim wantSave, wantLoad                 ' F11 and F12, which are this port's own
Dim kRepeat(38)                        ' 1 if the action repeats while held (&121d)
Dim sAct(3), sWhat(3), sNext           ' which of the four channels are sounding, and with what
Dim sEv(7), sDur(7), sSoff(7), sSdur(7), sLoop(7), sLoff(7)
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
  sNext = 1
  ' which actions repeat while held, from the game's own table at &121d;
  ' every other action fires once and waits for the key to be let go
  Local kr, kri
  For kri = 0 To 14
    Read kr : kRepeat(kr) = 1
  Next kri
  Data 0, 11, 14, 19, 20, 21, 22, 28, 29, 30, 33, 34, 35, 37, 38
  pcol(0) = RGB(BLACK)  : pcol(1) = RGB(RED)     : pcol(2) = RGB(GREEN) : pcol(3) = RGB(YELLOW)
  pcol(4) = RGB(BLUE)   : pcol(5) = RGB(MAGENTA) : pcol(6) = RGB(CYAN)  : pcol(7) = RGB(WHITE)
  LoadAll
  t0 = Timer
  tNext = Timer + MSPERTICK
  Do
    ReadKeys
    If quitting Then quit = 1
    game(G_KMASK) = KeyMask()
    If wantSave Then SaveGame : wantSave = 0
    If wantLoad Then LoadGame : wantLoad = 0
    t1 = Timer
    ExileTick obj(), game(), world(), tbl(), feed(), part()
    tickAcc = tickAcc + (Timer - t1)
    If game(G_FAULT) Then
      Print "fault "; game(G_FAULT); " arg &"; Hex$(game(G_FAULTARG)); " at frame "; game(G_FRAME)
      game(G_FAULT) = 0
    EndIf
    StepSounds
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
  ' The colour map survives a RUN, so a previous run's glow would still be in
  ' the slots.  Start from the board's own sixteen.
  Map RESET
  Map SET
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

' ---------------------------------------------------------------- saved games
' The whole of a game is three arrays: the sixteen object slots, the game array
' - which carries the world's tertiary data, the player's pockets, the weapons,
' the waterlines and the screen - and the particles.  Everything else is either
' constant (the tiles, the tables, the sprite sheet) or derived.  So a saved
' game is those three written out, and restoring is reading them back.
'
' The game has a save of its own, on f9, which writes to tape through the
' loader; that is not something this port can use, so F11 and F12 are ours.
Sub SaveGame
  Save DATA homeDir$ + "exile_obj.sav", Peek(VARADDR obj()), 288 * 8
  Save DATA homeDir$ + "exile_game.sav", Peek(VARADDR game()), NGAME * 8
  Save DATA homeDir$ + "exile_part.sav", Peek(VARADDR part()), 256 * 8
  Option CONSOLE BOTH
  Print "saved at &"; Hex$(obj(O_X * NSLOT), 2); " &"; Hex$(obj(O_Y * NSLOT), 2)
  Option CONSOLE SERIAL
End Sub

Sub LoadGame
  Local f$
  f$ = homeDir$ + "exile_obj.sav"
  If Dir$(f$, FILE) = "" Then
    Option CONSOLE BOTH
    Print "no saved game"
    Option CONSOLE SERIAL
    Exit Sub
  EndIf
  Load DATA f$, Peek(VARADDR obj())
  Load DATA homeDir$ + "exile_game.sav", Peek(VARADDR game())
  Load DATA homeDir$ + "exile_part.sav", Peek(VARADDR part())
  ' the view has to be told to catch up with wherever the player now is
  Option CONSOLE BOTH
  Print "restored at &"; Hex$(obj(O_X * NSLOT), 2); " &"; Hex$(obj(O_Y * NSLOT), 2)
  Option CONSOLE SERIAL
End Sub

' ---------------------------------------------------------------- the keys
' KEYDOWN(0) is how many keys are held and KEYDOWN(1..6) their characters, so
' the whole set is read once a tick.  Every KEYDOWN call empties the console
' input buffer, so nothing else may read it.
Sub ReadKeys
  Local i, k, sh
  For i = 0 To 38 : keyHeld(i) = 0 : kdown(i) = 0 : Next i
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
      kdown(k - 144) = 1
    Else
      Select Case k
        Case 113 : kdown(K_Q) = 1            ' left
        Case 119 : kdown(K_W) = 1            ' right
        Case 112 : kdown(K_P) = 1 : kdown(K_JUMP) = 1   ' the game has P twice: thrust
        '                                     up while it is held, and a jump on
        '                                     the press, which is what carries
        '                                     the player when the jetpack is flat
        Case 108 : kdown(K_L) = 1            ' down
        Case 32  : kdown(K_SPACE) = 1        ' fire
        Case 128 : kdown(K_UP) = 1           ' the arrows move the view alone
        Case 129 : kdown(K_DOWN) = 1
        Case 130 : kdown(K_LEFT) = 1
        Case 131 : kdown(K_RIGHT) = 1
        Case 9   : kdown(K_TAB) = 1          ' the map
        Case 103 : kdown(K_G) = 1            ' retrieve from a pocket
        Case 115 : kdown(K_S) = 1            ' store into one
        Case 116 : kdown(K_T) = 1            ' teleport
        Case 114 : kdown(K_R) = 1            ' remember where you are
        Case 121 : kdown(K_Y) = 1            ' the whistles
        Case 117 : kdown(K_U) = 1
        Case 109 : kdown(K_M) = 1            ' pick up and drop
        Case 107 : kdown(K_K) = 1            ' aim
        Case 111 : kdown(K_O) = 1
        Case 46  : kdown(K_GT) = 1           ' throw
        Case 44, 60 : kdown(K_LT) = 1        ' pick up - comma, and shifted
        Case 105 : kdown(K_I) = 1            ' centre the aim
        Case 64  : kdown(K_AT) = 1           ' the booster
        Case 118 : kdown(K_V) = 1            ' sound on and off
        Case 155 : wantSave = 1              ' F11 and F12 are ours, not the game's
        Case 156 : wantLoad = 1
        Case 27  : quitting = 1              ' quit, which is not the game's
      End Select
    EndIf
  Next i
  If sh Then kdown(K_SHIFT) = 1
  ' Ctrl is a modifier, not a character: KEYDOWN(7) carries it in bit 1
  ' (input/Keyboard.c), and the game uses it to lie down and crawl.
  If (KEYDOWN(7) And 2) Then kdown(K_CTRL) = 1
  ' The game's table at &121d says which actions repeat while the key is held
  ' and which fire once.  One that repeats just wants the state.  One that fires
  ' once wants the press, and KEYDOWN goes on reporting a key for as long as it
  ' is down, so the press is the tick it first appears: after that nothing more
  ' happens until KEYDOWN stops seeing it, and only then does the next push
  ' count.  Without waiting for the release, one long push is a run of presses.
  For i = 0 To 38
    If kRepeat(i) Then
      keyHeld(i) = kdown(i)
    ElseIf kdown(i) And kprev(i) = 0 Then
      keyHeld(i) = 1
    EndIf
    kprev(i) = kdown(i)
  Next i
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
  SetGlowColours
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
' What the three reserved slots are wearing this frame.  The map is one for the
' whole screen, so everything drawn this way glows together where the game gives
' each its own phase; seven slots are spare, so a second such object could have
' its own three if that ever matters.
Sub SetGlowColours
  Local pc
  If glowPal < 0 Or glowPal = glowShown Then Exit Sub
  glowShown = glowPal
  pc = sheet(OS_PALCOL + glowPal)
  Map(GLOW0) = pcol(pc And 7)
  Map(GLOW1) = pcol((pc >> 8) And 7)
  Map(GLOW2) = pcol((pc >> 16) And 7)
  Map SET
End Sub

Sub DrawObjects(vx, vy)
  Local s, spr, pal, flg, fl, i, st, cn, pr, geo, ox, oy, ow, oh, sx, sy
  glowPal = -1
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
        ' An object whose palette the sheet does not hold was drawn as nothing at
        ' all.  Some change palette as they live - a coronium boulder cycles
        ' through thirty-odd as it glows - and no sheet has room for every one.
        ' Those sprites carry one copy drawn in the three reserved display slots, and
        ' SetGlowColours says what the three mean.  The display applies a map
        ' change at scanout, so it costs nothing and redraws nothing.
        If pr < 0 Then
          For i = 0 To cn - 1
            If sheet(OS_PAL + st + i) = GLOW_PALETTE Then
              pr = st + i : glowPal = pal : Exit For
            EndIf
          Next i
        EndIf
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

' ---------------------------------------------------------------- the sound
' The game drives the sound chip itself: on every vsync its interrupt steps a
' volume envelope and a frequency envelope for each channel and writes the
' chip's registers.  This runs those envelopes exactly as the 6502 does, from
' the game's own two hundred and eight byte table, and hands each step to
' PLAY BBC SOUND as a flushed fifty millisecond note.  A tick is forty
' milliseconds and a vsync twenty, so every channel takes two steps a tick.
'
' The kernel does not make a noise: it leaves the numbers of the sounds that
' started on a queue, and this starts them.
' n carries the sound in its low byte and how far off the middle of the screen
' it happened in the next, which is how much quieter it is.
Sub StartSound(q)
  Local ch, i, b, at, n, far, v, pit
  n = q And 255 : far = (q >> 8) And 15 : pit = (q >> 16) And 255
  at = T_SOUND + n * 5
  If Peek(VAR tbl(), at + 4) Then       ' the call that takes channel zero
    ch = 0
  Else
    ch = -1
    For i = 1 To 3                      ' one already playing this sound takes it again
      If sAct(i) And sWhat(i) = n Then ch = i : Exit For
    Next i
    If ch < 0 Then
      For i = 1 To 3
        If sAct(i) = 0 Then ch = i : Exit For
      Next i
    EndIf
    If ch < 0 Then ch = sNext : sNext = sNext + 1 : If sNext > 3 Then sNext = 1
  EndIf
  sWhat(ch) = n
  b = Peek(VAR tbl(), at + 1)
  v = (b And &HF0) - (far << 4)
  If v < 0 Then v = 0
  sEv(ch * 2) = v : sDur(ch * 2) = b And 15
  sSoff(ch * 2) = Peek(VAR tbl(), at)
  b = Peek(VAR tbl(), at + 3)
  If pit Then b = pit                   ' an imp patches its own pitch before it calls
  sEv(ch * 2 + 1) = b And &HF0 : sDur(ch * 2 + 1) = b And 15
  sSoff(ch * 2 + 1) = Peek(VAR tbl(), at + 2)
  sSdur(ch * 2) = 0 : sSdur(ch * 2 + 1) = 0
  sLoop(ch * 2) = 0 : sLoop(ch * 2 + 1) = 0
  sLoff(ch * 2) = 0 : sLoff(ch * 2 + 1) = 0
  sAct(ch) = 1
End Sub

' One vsync of the game's update_sound_envelope for one envelope.  Returns 1
' while it is still running, 0 once it has ended.
Function EnvStep(k)
  Local y, a
  If sDur(k) = 0 Then EnvStep = 0 : Exit Function
  y = sSoff(k)
  If sSdur(k) = 0 Then
    If sLoop(k) = 0 Then                 ' not inside a loop: one of the duration's stages
      sDur(k) = sDur(k) - 1
      If sDur(k) = 0 Then EnvStep = 0 : Exit Function
    EndIf
    y = y + 1
    a = Peek(VAR tbl(), T_ENVELOPE + y)
    If a >= 128 Then                     ' a loop marker: an end, a start, or both
      sLoop(k) = (sLoop(k) - 1) And 255
      If sLoop(k) >= 128 Then             ' it went negative: start the loop this byte describes
        sLoop(k) = a And 127
        y = y + 1
        sLoff(k) = y
      EndIf
      y = sLoff(k)                        ' back to the top of the loop body
      a = Peek(VAR tbl(), T_ENVELOPE + y)
    EndIf
    sSdur(k) = a                          ' first byte of a stage: how many steps
    y = y + 1
    sSoff(k) = y                          ' second byte: the delta, added each step
  EndIf
  sEv(k) = (sEv(k) + Peek(VAR tbl(), T_ENVELOPE + y)) And 255
  sSdur(k) = sSdur(k) - 1
  EnvStep = 1
End Function

' The chip period the game writes for an eight bit frequency value
Function SndPeriod(v)
  Local a
  a = 255 - v
  If a >= &HB6 Then
    SndPeriod = ((a - &H80) And 255) << 3
  ElseIf a >= &H84 Then
    SndPeriod = ((a - &H4A) And 255) << 2
  ElseIf a >= &H40 Then
    SndPeriod = ((a - &H10) And 255) << 1
  Else
    SndPeriod = (a + &H20) And 255
  EndIf
End Function

' Two vsyncs for every channel that is sounding, then one note each
Sub StepSounds
  Local ch, i, k, loud, per, pit, skip
  Local Float f
  For i = 0 To game(G_NSND) - 1
    StartSound game(G_SND0 + i)
  Next i
  For ch = 0 To 3
    If sAct(ch) Then
    k = ch * 2
    For i = 1 To 2
      skip = 0
      If EnvStep(k) = 0 Then              ' the volume envelope is over: fade by two a vsync
        If sEv(k) < 2 Then skip = 1 Else sEv(k) = sEv(k) - 2
      EndIf
      If skip = 0 Then skip = EnvStep(k + 1)
    Next i
    loud = sEv(k) >> 4
    If loud = 0 Then
      sAct(ch) = 0
      Play BBC SOUND &H10 + ch, 0, 0, 1
    Else
      per = SndPeriod(sEv(k + 1))
      If per < 1 Then per = 1
      f = 125000.0 / per
      pit = Cint(89 + 48 * Log(f / 440) / Log(2))
      If pit < 0 Then pit = 0
      If pit > 255 Then pit = 255
      Play BBC SOUND &H10 + ch, -loud, pit, 1
    EndIf
    EndIf
  Next ch
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
