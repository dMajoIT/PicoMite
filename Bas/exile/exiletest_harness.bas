' exiletest_harness.bas - replay whole scenes through the CSUB kernel, all sixteen slots.
' gen_exiletest.py puts the layouts before Main and the CSUB block at the end to
' make exiletest.bas.  For each scene in sc_list.txt: read sc_<name>.txt (tick
' count, feed size, the slot tables, the game array), pull sc_<name>.bin (the
' feed) into memory, then tick and print every live slot.  run_exiletest.py
' compares the output with the trace of the real game.
Option EXPLICIT
Option DEFAULT INTEGER
Option BASE 0
' PRINT goes to the serial console only: the host script captures it and the screen is left alone
Option CONSOLE SERIAL

Dim obj(287), game(639), world(25599), tbl(511), feed(65535)   ' world: 64 KB of tiles, the two tertiary-object maps, then the mapped-square bits
Dim homeDir$

' @@CONSTS@@

Main
End

Sub Main
  Local nm$, n, fb, lonely, tk, i, s
  Local Float t0, t1, tk1
  homeDir$ = MM.Info(Path) : If homeDir$ = "NONE" Then homeDir$ = "A:/"
  Open homeDir$ + "world_types.bin" For Input As #3
  MEMORY INPUT 3, 204800, world()
  Close #3
  Open homeDir$ + "tables2.bin" For Input As #3
  MEMORY INPUT 3, TABLES_BYTES, tbl()
  Close #3
  Open homeDir$ + "sc_list.txt" For Input As #2
  Do While Not Eof(#2)
    Line Input #2, nm$
    If nm$ = "" Or Asc(nm$) < 32 Then Exit Do
    Open homeDir$ + "sc_" + nm$ + ".txt" For Input As #1
    Input #1, n
    Input #1, fb
    Input #1, lonely
    For i = 0 To 287 : Input #1, obj(i) : Next i
    For i = 0 To 639 : game(i) = 0 : Next i
    For i = 0 To NGAME - 1 : Input #1, game(i) : Next i
    Close #1
    Open homeDir$ + "sc_" + nm$ + ".bin" For Input As #1
    MEMORY INPUT 1, fb, feed()
    Close #1
    Print "S "; nm$
    t0 = Timer : tk1 = 0
    For tk = 1 To n
      ' a lonely scene has only the player: the game wiped the other slots before every tick
      If lonely Then
        For s = 1 To 15 : obj(O_Y * 16 + s) = 0 : Next s
      EndIf
      t1 = Timer
      ExileTick obj(), game(), world(), tbl(), feed()
      tk1 = tk1 + (Timer - t1)
      For s = 0 To 15
        If obj(O_Y * 16 + s) Then PrintSlot tk, s
      Next s
      If game(G_FAULT) Then
        Print "F "; tk; " fault "; game(G_FAULT); " arg &"; Hex$(game(G_FAULTARG))
        If game(G_FAULT) <> 3 Then Exit For
        game(G_FAULT) = 0
      EndIf
    Next tk
    Print "E "; nm$; " "; n; " "; Int(Timer - t0); " "; Int(tk1)
  Loop
  Option CONSOLE BOTH
  Close #2
End Sub

Sub PrintSlot(tk, s)
  Local f
  Print "O "; tk; " "; s;
  For f = 0 To 17
    Print " "; obj(f * 16 + s);
  Next f
  Print ""
End Sub
