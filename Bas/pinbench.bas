' pinbench.bas - how fast can a pin be toggled, interpreted and as a CSUB.
' The empty loop is timed too, so the pin cost can be separated from the cost
' of the loop that drives it.
Option console both
Dim n%, p%
Dim te!, tt!, ce!, ct!
Dim pr!, pc!

SetPin GP4, DOUT
p% = MM.Info(PinNo GP4)
n% = 50000                     ' 2 toggles per pass

Print "toggling GP4, "; Str$(n% * 2); " transitions"
Print

Dim tx!
te! = Timer : EmptyRef n%, p% : te! = Timer - te!
tt! = Timer : TogRef   n%, p% : tt! = Timer - tt!
ce! = Timer : EmptyFast n%, p% : ce! = Timer - ce!
ct! = Timer : TogFast   n%, p% : ct! = Timer - ct!
tx! = Timer : TogXor    n%, p% : tx! = Timer - tx!

pr! = (tt! - te!) * 1e6 / (n% * 2)      ' ns per transition, loop removed
pc! = (ct! - ce!) * 1e6 / (n% * 2)

Print "                    empty      toggle     pin only    ns/toggle"
Print "interpreted    "; Fmt$(te!); Fmt$(tt!); Fmt$(tt! - te!); Str$(pr!, 6, 0)
Print "csub           "; Fmt$(ce!); Fmt$(ct!); Fmt$(ct! - ce!); Str$(pc!, 6, 0)
Print "csub + LATINV  "; Fmt$(ce!); Fmt$(tx!); Fmt$(tx! - ce!); Str$((tx! - ce!) * 1e6 / (n% * 2), 6, 0)
Print
Print "whole loop  "; Str$(tt! / ct!, 0, 1); "x faster"
Print "pin work    "; Str$((tt! - te!) / (ct! - ce!), 0, 1); "x faster"
Print "toggle rate "; Str$(n% * 2 / (tx! / 1000) / 1000, 0, 1); " kHz  (csub + LATINV)"
Print "            "; Str$(n% * 2 / (ct! / 1000) / 1000, 0, 1); " kHz  (csub)"
Print "            "; Str$(n% * 2 / (tt! / 1000) / 1000, 0, 1); " kHz  (interpreted)"
SetPin GP4, OFF
End

CSUB TogXor INTEGER, INTEGER
	00000000
	'TogXor
	6804B5F8 680B6845 2D00001F D101DC05 D1022C00 21002000 4E09BDF8 68332107 
	69DB0038 4798699B 21076833 003869DB 4798699B 42522201 18A417D3 E7E4415D 
	E000ED08 
End CSUB


Function Fmt$(ms!)
  Fmt$ = Str$(ms!, 9, 1) + " ms"
End Function

Sub EmptyRef(n%, p%)
  Local i%
  For i% = 1 To n%
  Next i%
End Sub

Sub TogRef(n%, p%)
  Local i%
  For i% = 1 To n%
    Pin(p%) = 1
    Pin(p%) = 0
  Next i%
End Sub

' --- mmb2csub: EmptyFast is now the CSUB below (original in pinbench2.bas.bak)

' --- mmb2csub: TogFast is now the CSUB below (original in pinbench2.bas.bak)

' --- mmb2csub: generated code for EmptyFast
CSUB EmptyFast INTEGER, INTEGER
	00000000
	B5F02200 B0834E23 00046833 6FDB69DB 601A605A 69DB6833 683D6FDF D1114295
	6B1B2080 47980140 68332180 69DB6038 6FDB0149 6833605D 6FDB69DB 428A685A
	605DD900 68676833 250069DB 685B6FDB 68239300 93012401 69DB6833 42BD6FDA
	D108DC03 429C9B01 2000D905 9B002100 B0036053 6893BDF0 60933301 D103059B
	69DB6833 47986A9B 23002201 415D18A4 46C0E7E2 E000ED08
End CSUB

' --- mmb2csub: generated code for TogFast
CSUB TogFast INTEGER, INTEGER
	00000000
	B5F02200 B0854E2C 00046833 910169DB 605A6FDB 6833601A 6FDF69DB 4295683D
	2080D111 01406B1B 21804798 60386833 014969DB 605D6FDB 69DB6833 685A6FDB
	D900428A 6833605D 69DB6867 6FDB2500 9302685B 24016823 68339303 6FDA69DB
	DC0342BD 9B03D108 D905429C 21002000 60539B02 BDF0B005 33016893 059B6093
	6833D103 6A9B69DB 22DE4798 98016833 005269DB 2101589B 47986800 683322DE
	69DB0052 589B2100 68109A01 22014798 18A42300 E7D0415D E000ED08
End CSUB
