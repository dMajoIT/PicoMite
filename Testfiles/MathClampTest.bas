' MathClampTest.bas - MATH CLAMP in(), lo, hi, out()
'
' Every element of in() is limited to lo..hi and written to out(), which
' may be the same array.  Integer and float arrays in any combination,
' and structure member arrays, as with MATH SCALE.
Option EXPLICIT
Option BASE 0

Type Obj
  vx As INTEGER
  vy As FLOAT
End Type

Dim integer a(7), b(7), c(3), v(15), i, fails, tests
Dim float f(7), g(7), t0
Dim o(7) As Obj

' integer, in place
For i = 0 To 7 : a(i) = (i - 4) * 30 : Next i        ' -120 .. 90
Math CLAMP a(), -64, 64, a()
Check "integer in place", a(0) = -64 And a(3) = -30 And a(4) = 0 And a(7) = 64

' integer to a second array, source untouched
For i = 0 To 7 : a(i) = (i - 4) * 30 : Next i
Math CLAMP a(), -64, 64, b()
Check "integer to another array", a(0) = -120 And b(0) = -64 And b(5) = 30 And b(7) = 64

' float
For i = 0 To 7 : f(i) = (i - 4) * 0.5 : Next i       ' -2 .. 1.5
Math CLAMP f(), -1.25, 1.0, g()
Check "float", g(0) = -1.25 And g(2) = -1 And g(5) = 0.5 And g(6) = 1 And g(7) = 1

' integer in, float out
Math CLAMP a(), -10, 10, g()
Check "integer to float", g(0) = -10 And g(4) = 0 And g(7) = 10

' float in, integer out
For i = 0 To 7 : f(i) = i * 0.5 : Next i             ' 0 .. 3.5
Math CLAMP f(), 1, 3, b()
Check "float to integer", b(0) = 1 And b(2) = 1 And b(4) = 2 And b(7) = 3

' limits equal: everything becomes that value
Math CLAMP a(), 7, 7, b()
Check "equal limits", b(0) = 7 And b(7) = 7

' structure members, integer and float
For i = 0 To 7 : o(i).vx = (i - 4) * 50 : o(i).vy = (i - 4) * 0.5 : Next i
Math CLAMP o().vx, -64, 64, o().vx
Math CLAMP o().vy, -1, 1, o().vy
Check "structure integer member", o(0).vx = -64 And o(5).vx = 50 And o(7).vx = 64
Check "structure float member", o(0).vy = -1 And o(4).vy = 0 And o(6).vy = 1

' refused: low above high, size mismatch
On Error Skip 1
Math CLAMP a(), 10, -10, b()
Check "low above high is refused: " + MM.ErrMsg$, MM.ErrNo <> 0
On Error Clear
On Error Skip 1
Math CLAMP a(), 0, 1, c()
Check "size mismatch is refused: " + MM.ErrMsg$, MM.ErrNo <> 0
On Error Clear

' cost for the sixteen velocities of an Exile tick
For i = 0 To 15 : v(i) = (i - 8) * 20 : Next i
t0 = Timer
For i = 1 To 1000 : Math CLAMP v(), -64, 64, v() : Next i
Print "MATH CLAMP of 16 integers: " + Str$(Int(Timer - t0)) + " us a call"

Print Str$(tests - fails) + " of " + Str$(tests) + " checks passed"
If fails = 0 Then Print "PASS" Else Print "FAIL"
End

Sub Check(what$, ok As integer)
  tests = tests + 1
  If ok Then
    Print "ok:   " + what$
  Else
    Print "FAIL: " + what$
    fails = fails + 1
  EndIf
End Sub
