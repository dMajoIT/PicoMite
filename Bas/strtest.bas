' strtest.bas - edge cases for the string functions split into cores in the
' string-cores branch (LEFT$ RIGHT$ MID$ UCASE$ LCASE$ CHR$ SPACE$ STRING$).
'
' The point is a byte-exact BEFORE/AFTER: run it on the firmware without the
' refactor, keep the output, run it again on the firmware with it, and diff.
' Every result is printed as its length and its bytes in hex, so a difference of
' one character in one case cannot hide.
Option console both
Option BASE 0

Dim s$, e$, m$, long$
Dim i

e$ = ""
s$ = "Hello, World"
long$ = String$(255, "A")

Print "--- LEFT$ ---"
Show "L empty 0", Left$(e$, 0)
Show "L empty 5", Left$(e$, 5)
Show "L 0",       Left$(s$, 0)
Show "L 1",       Left$(s$, 1)
Show "L exact",   Left$(s$, 12)
Show "L over",    Left$(s$, 200)
Show "L long 255",Left$(long$, 255)

Print "--- RIGHT$ ---"
Show "R empty 0", Right$(e$, 0)
Show "R empty 5", Right$(e$, 5)
Show "R 0",       Right$(s$, 0)
Show "R 1",       Right$(s$, 1)
Show "R exact",   Right$(s$, 12)
Show "R over",    Right$(s$, 200)
Show "R long 255",Right$(long$, 255)

Print "--- MID$ ---"
Show "M 1",        Mid$(s$, 1)
Show "M 1,5",      Mid$(s$, 1, 5)
Show "M mid",      Mid$(s$, 8, 5)
Show "M last",     Mid$(s$, 12, 1)
Show "M past",     Mid$(s$, 13, 5)
Show "M way past", Mid$(s$, 200, 5)
Show "M n=0",      Mid$(s$, 3, 0)
Show "M n over",   Mid$(s$, 3, 200)
Show "M empty",    Mid$(e$, 1, 5)
Show "M all",      Mid$(long$, 1, 255)

Print "--- case ---"
Show "U mixed", UCase$("aBc123xYz")
Show "L mixed", LCase$("aBc123xYz")
Show "U empty", UCase$(e$)
Show "L empty", LCase$(e$)
Show "U punct", UCase$("a-z_[]{}~")
Show "L punct", LCase$("A-Z_[]{}~")

Print "--- CHR$ ---"
Show "C 0",   Chr$(0)
Show "C 32",  Chr$(32)
Show "C 65",  Chr$(65)
Show "C 255", Chr$(255)

Print "--- SPACE$ / STRING$ ---"
Show "SP 0",    Space$(0)
Show "SP 1",    Space$(1)
Show "SP 10",   Space$(10)
Show "SP 255",  Space$(255)
Show "ST 0",    String$(0, "x")
Show "ST 5 s",  String$(5, "x")
Show "ST 5 n",  String$(5, 65)
Show "ST 255",  String$(255, 90)

Print "--- nested ---"
Show "N 1", UCase$(Mid$(s$, 8, 5))
Show "N 2", Left$(Right$(s$, 5), 3)
Show "N 3", Mid$(UCase$(s$), 1, 5) + Chr$(33)

Print "DONE"
End

' name, then length, a checksum over every byte, and the first and last few in
' hex. A full hex dump would overflow a 255-character string on the long cases,
' and the checksum catches any difference the head and tail would miss.
Sub Show nm$, v$
  Local Integer j, ck, n
  Local h$
  n = Len(v$)
  ck = 0
  For j = 1 To n
    ck = (ck * 31 + Asc(Mid$(v$, j, 1))) Mod 1000000007
  Next j
  h$ = ""
  For j = 1 To n
    If j <= 8 Or j > n - 8 Then
      h$ = h$ + Hex$(Asc(Mid$(v$, j, 1)), 2)
    ElseIf j = 9 Then
      h$ = h$ + ".."
    EndIf
  Next j
  Print nm$; " len="; n; " ck="; ck; " ["; h$; "]"
End Sub
