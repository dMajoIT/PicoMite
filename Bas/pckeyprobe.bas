' pckeyprobe.bas - dump raw PicoCalc southbridge key events
'
' Reads the keyboard FIFO (register 9) at I2C address &H1F directly, the same
' way CheckPicoCalcKeyboard() in io/I2C.c does, and prints every event.
' Purpose: find out what the BIOS actually reports before deciding whether
' KEYDOWN() can be supported from the built-in keyboard.
'
' What to look for
'   1. Hold two or three keys at once.  Does each one produce its own
'      "press" line, or does the matrix only ever report one at a time?
'   2. Release them one at a time.  Does every key get a "release" line?
'      A lost release would leave a key stuck down in any held-key table.
'   3. Hold one key still.  Do "hold" lines repeat, or arrive just once?
'   4. Press CTRL alone.  Does it send press(1) then hold(2), or only hold?
'   5. Watch the fifo column - does it climb when several keys go down
'      together?  That says how many events a single poll must drain.
'
' The firmware polls the same FIFO every 20 ms and would steal events, so by
' default this program holds the I2C bus (HOLD = 1), which makes
' SystemI2CBusHeld() true and keeps the firmware out.  That turns the read
' into a repeated start rather than the STOP the firmware uses; if the BIOS
' dislikes it (errors, or every word reads back the same) set HOLD = 0 and
' accept that the firmware will take roughly every other event.
'
' The keyboard is dead to MMBasic while this runs.  ESC or the Break key quits
' and releases the bus.  Ctrl-C over the serial console also works.

Const ADDR = &H1F
Const HOLD = 1

Dim integer lo, hi, w, k, st, cnt, flags, t0
Dim string s

t0 = Timer
Print "PicoCalc key probe - ESC quits"
Print "  ms  word state   fifo lock"

Do
  ' register 4: key count in the low bits, lock flags above
  I2C2 Write ADDR, HOLD, 1, 4
  Pause 2
  I2C2 Read ADDR, HOLD, 2, lo, hi
  If MM.I2C <> 0 Then
    Print "i2c error "; MM.I2C
    Exit Do
  End If
  cnt = lo And &H1F
  flags = lo And &HE0

  ' register 9: pop one event.  &H0000 means the FIFO is empty
  I2C2 Write ADDR, HOLD, 1, 9
  Pause 2
  I2C2 Read ADDR, HOLD, 2, lo, hi
  If MM.I2C <> 0 Then
    Print "i2c error "; MM.I2C
    Exit Do
  End If

  w = lo + hi * 256
  If w <> 0 Then
    st = lo : k = hi
    Select Case st
      Case 1 : s = "press  "
      Case 2 : s = "hold   "
      Case 3 : s = "release"
      Case Else : s = "state" + Str$(st)
    End Select
    Print Str$(Timer - t0, 6, 0); " "; Hex$(w, 4); " "; s; " "; Str$(cnt, 2); " "; Hex$(flags, 2)
    If k = &HB1 Or k = &HD0 Then Exit Do    ' ESC or Break
  End If
Loop

I2C2 Write ADDR, 0, 1, 9      ' a transaction without hold frees the bus again
Print "done - keyboard handed back to the firmware"
