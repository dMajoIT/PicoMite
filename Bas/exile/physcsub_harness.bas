' physcsub_harness.bas - replay the physics scenarios through the CSUB kernel.
' gen_csubtest.py appends the state layout, the player's starting values and
' the CSUB block to make physcsub.bas.  The feed files and the output format
' are those of exilephys.bas, so run_phystest.py checks it the same way.
Option EXPLICIT
Option DEFAULT INTEGER
Option BASE 0
' PRINT goes to the serial console only: the host script captures it and the screen is left alone
Option CONSOLE SERIAL

Dim st(127), world(8191), tbl(255)
Dim homeDir$

' @@CONSTS@@ (gen_csubtest.py puts the state layout here)

Main
End

Sub Main
  Local nm$, sx, sy, tk, n, i
  Local k, d, fn, a0, v0, a1, v1, a2, v2, w0, w1, w2, w3, w4, w5, w6, w7
  Local Float t0, t1, tk1
  homeDir$ = MM.Info(Path) : If homeDir$ = "NONE" Then homeDir$ = "A:/"
  Open homeDir$ + "world_types.bin" For Input As #3
  MEMORY INPUT 3, 65536, world()
  Close #3
  Open homeDir$ + "tables.bin" For Input As #3
  MEMORY INPUT 3, TABLES_BYTES, tbl()
  Close #3
  Open homeDir$ + "phys_list.txt" For Input As #2
  Do While Not Eof(#2)
    Line Input #2, nm$
    If nm$ = "" Or Asc(nm$) < 32 Then Exit Do
    InitState
    Open homeDir$ + "phys_" + nm$ + ".txt" For Input As #1
    Input #1, sx, sy, n
    If sx >= 0 Then st(S_X) = sx : st(S_Y) = sy : st(S_XF) = &H80 : st(S_YF) = 0 : st(S_VX) = 0 : st(S_VY) = 0
    Print "S "; nm$
    t0 = Timer : tk1 = 0
    For tk = 1 To n
      Input #1, k, d, fn, a0, v0, a1, v1, a2, v2, w0, w1, w2, w3, w4, w5, w6, w7
      st(S_KMASK) = k : st(S_RELTY) = d : st(S_FEEDN) = fn
      st(S_FEEDA0) = a0 : st(S_FEEDV0) = v0 : st(S_FEEDA1) = a1 : st(S_FEEDV1) = v1 : st(S_FEEDA2) = a2 : st(S_FEEDV2) = v2
      st(S_WL0) = w0 : st(S_WL1) = w1 : st(S_WL2) = w2 : st(S_WL3) = w3
      st(S_WL4) = w4 : st(S_WL5) = w5 : st(S_WL6) = w6 : st(S_WL7) = w7
      t1 = Timer
      ExileUpdate st(), world(), tbl()
      tk1 = tk1 + (Timer - t1)
      PrintState tk
      If st(S_FAULT) = 3 Then
        ' a tile whose collision routine is not modelled (nests, switches, doors, object tiles): note it and go on
        Print "N "; tk; " tile type &"; Hex$(st(S_FAULTARG)); " has a collision routine that is not modelled"
      ElseIf st(S_FAULT) Then
        Print "F "; tk; " fault "; st(S_FAULT); " arg &"; Hex$(st(S_FAULTARG)) : Exit For
      EndIf
      If st(S_FEEDI) < st(S_FEEDN) Then Print "F "; tk; " the game read at &"; Hex$(st(S_FEEDA0 + 2 * st(S_FEEDI))); " and the kernel did not"
    Next tk
    Close #1
    Print "E "; nm$; " "; n; " "; Int(Timer - t0); " "; Int(tk1)
  Loop
  Option CONSOLE BOTH
  Close #2
End Sub

Sub PrintState(tk)
  Print "T ";tk;" ";st(S_X)*256+st(S_XF);" ";st(S_Y)*256+st(S_YF);" ";st(S_VX);" ";st(S_VY);" ";st(S_FLAGS);
  Print " ";st(S_STATE);" ";st(S_SPRITE);" ";st(S_ENERGY);" ";st(S_JETHI)*256+st(S_JETLO);" ";st(S_ANGLE);" ";st(S_FACING);
  Print " ";st(S_IMMOB);" ";st(S_TIMMOB);" ";st(S_JETOK);" ";st(S_TIMER);" ";st(S_FRAME);" ";st(S_PALETTE)
End Sub

' the player's slot and the game variables as the game starts
Sub InitState
  Local i, v
  For i = 0 To 127 : st(i) = 0 : Next i
  Restore PlayerInit
  Read st(S_SPRITE), st(S_X), st(S_XF), st(S_Y), st(S_YF), st(S_FLAGS), st(S_PALETTE), st(S_VX), st(S_VY)
  Read st(S_ENERGY), st(S_STATE), st(S_TIMER), st(S_TOUCHING)
  Read st(S_JETLO), st(S_JETHI), st(S_SUITHI), st(S_FIRECOOL), st(S_JETOK), st(S_BOOSTERCOL), st(S_SUITCOL)
  For i = 0 To 38 : Read st(S_KH0 + i) : Next i
  Restore ObjectFlagsInit
  Read st(S_TYPEFLAGS), st(S_PALDEFAULT), st(S_MAXACC0), st(S_NPCW0)
  st(S_ANGLE) = &HC0
  st(S_FEEDMODE) = 1
End Sub
