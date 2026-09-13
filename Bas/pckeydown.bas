' pckeydown.bas - show what KEYDOWN() reports from the PicoCalc's own keyboard
'
' Prints one line whenever the set of held keys changes:
'   <ms>  <count>: <key codes in hex> m<modifier mask> c<lock flags>
'
' KEYDOWN(0) = how many keys are down, KEYDOWN(1..6) = their characters,
' KEYDOWN(7) = modifier mask (1 Alt, 2 Ctrl, 8 LShift, 128 RShift),
' KEYDOWN(8) = lock flags (1 caps, 2 num).
'
' Try: tap a key; hold a key; hold three at once and release them one by one;
' hold Shift and a letter; hold Ctrl and a letter.  Ctrl-C quits.

Dim string s, prev
Dim integer i, k, t0

t0 = Timer
Print "KEYDOWN test - Ctrl-C quits"

Do
  s = Str$(KeyDown(0)) + ":"
  For i = 1 To 6
    k = KeyDown(i)
    If k Then s = s + " " + Hex$(k, 2)
  Next i
  s = s + "  m" + Hex$(KeyDown(7), 2) + " c" + Hex$(KeyDown(8), 2)
  If s <> prev Then Print Str$(Timer - t0, 7, 0); "  "; s
  prev = s
  Pause 20
Loop
