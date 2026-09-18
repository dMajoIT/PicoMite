Option EXPLICIT
Dim STRING c
Dim INTEGER n
Print "press keys; 0 ends"
Do
  c = Inkey$
  If c <> "" Then
    n = Asc(c)
    Print "code"; n
    If n = 48 Then Exit Do
  End If
Loop
Print "probe done"
