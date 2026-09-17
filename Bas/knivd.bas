'test
Option explicit
Print "MMBASIC benchmark (C) KnivD 2016"

Dim integer t, i=0,n=1,o=100
Dim float x(1000), f=0.0
Dim string s=""
Print "Calculating... ";
Do
s=""
f=0.0
i=0
Timer =0
runit
Print Chr$(13)+"Performance: "+Str$((i*1024)\286,8,0)+" grains"
Loop
End
'
Sub runit
Do While Timer<30000
  i=i+2 : f=f+2.0002
  If (i Mod 2)=0 Then
    i=i*2 : i=i\2
    f=f*2.0002 : f=f/2.0002
  EndIf
  i=i-1
  For t=1 To 100
    f=f-1.0001
    If (f-Int(f))>=0.5 Then
      f=Sin(f*Log(i))
      s=Str$(f,6,6)
    EndIf
    f=(f-Tan(i))*(Rnd/i)
    If Instr(s,LEFT$(Str$(i),2))>0 Then s=s+"0"
  Next
  x(1+(i Mod 1000))=f
Loop
End Sub
