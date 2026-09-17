' filecmp.bas - byte-exact comparison of two files on the PicoMite's own drive.
'
' Written for the mmb2csub work: render a picture with the interpreted BASIC,
' SAVE IMAGE it, render it again with the CSUB, SAVE IMAGE that, and compare the
' two here. Everything stays on the board, so there is no transfer to get wrong.
'
'   RUN, or from another program:  FileCmp "julia_i.bmp", "julia_c.bmp"
'
' Strings cap at 255 characters, so the files are walked a block at a time and
' compared whole - one MMBasic operation per block, not per byte.

FileCmp "julia_i.bmp", "julia_c.bmp"
End

Sub FileCmp f1$, f2$
  Local a$, b$
  Local n = 0, bad = 0, first = -1
  If Not Mm.Info(Exists File f1$) Then Print "missing: "; f1$ : Exit Sub
  If Not Mm.Info(Exists File f2$) Then Print "missing: "; f2$ : Exit Sub
  Open f1$ For input As #1
  Open f2$ For input As #2
  Do While Not Eof(#1) And Not Eof(#2)
    a$ = Input$(255, #1)
    b$ = Input$(255, #2)
    If a$ <> b$ Then
      Inc bad
      If first < 0 Then first = n
    EndIf
    Inc n
  Loop
  ' one file longer than the other is a difference in its own right, counted
  ' separately so the block tally stays truthful
  Local lendiff = 0
  If Not Eof(#1) Or Not Eof(#2) Then lendiff = 1
  Close #1
  Close #2
  If bad = 0 And lendiff = 0 Then
    Print "IDENTICAL -"; n; " blocks compared"
  Else
    If lendiff Then Print "LENGTHS DIFFER"
    If bad Then
      Print "DIFFER -"; bad; " of"; n; " blocks, first at block"; first;
      Print " (byte"; first * 255; ")"
    EndIf
  EndIf
End Sub
