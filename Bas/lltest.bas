' lltest.bas - check the 64-bit integer and block-move CallTable slots added in
' 6.03.02b8 by running each one in a CSUB and comparing with the interpreter's
' own operator on the same values.
'
' Every line prints PASS or FAIL and the two values, so a mismatch names itself.
' Regenerate the CSUB block at the bottom with:
'   python user-tools/armcfgen.py Bas/lltest.c --compile -n lltest -e lltest -O s -I . -o Bas/lltest.txt
Option EXPLICIT
Option DEFAULT INTEGER
Option BASE 0

Dim a(2), r(15)
Dim fails = 0
Dim x, y, n, b(47)

Print "CallTable 64-bit / block-move slot test"
Print "firmware "; MM.VER; "   marker expected &H600302B8"
Print

' ---- case 1: large positive values -------------------------------------
x = 1234567890123 : y = 98765 : n = 17
Call1

' ---- case 2: negative x, to check the sign of divide, mod and >> --------
x = -1234567890123 : y = 98765 : n = 17
Call1

' ---- case 3: negative divisor ------------------------------------------
x = 1234567890123 : y = -98765 : n = 3
Call1

' ---- case 4: small values, big shift -----------------------------------
x = 3 : y = 7 : n = 40
Call1

Print
If fails = 0 Then
  Print "ALL PASSED"
Else
  Print fails; " FAILED"
EndIf
End

Sub Call1
  Local k
  a(0) = x : a(1) = y : a(2) = n
  For k = 0 To 15 : r(k) = 0 : Next k
  lltest a(), r()
  Print "x ="; x; "  y ="; y; "  n ="; n
  Chk "LMul", r(0), x * y
  Chk "LDiv", r(1), x \ y
  Chk "LMod", r(2), x Mod y
  Chk "LShl", r(3), x << n
  ' MMBasic's >> is a LOGICAL shift (op_shiftright casts to unsigned), so it is
  ' LLsr that must match it. LAsr is the arithmetic one and has no MMBasic
  ' operator, so its expectation is built by hand: for x < 0,
  ' asr(x,n) = floor(x/2^n) = -(((-x) + 2^n - 1) >> n).
  Chk "LAsr", r(4), Asr(x, n)
  Chk "LLsr", r(5), x >> n
  Chk "add  ", r(6), x + y
  Chk "sub  ", r(7), x - y
  Chk "neg  ", r(8), -x
  Chk "cmp  ", r(9), (x < y)
  Chk "bits ", r(10), (x And y) Or (x Xor y)
  Chk "shl 5", r(11), x << 5
  Chk "shr 3", r(12), Asr(x, 3)
  Chk "memset(implicit)", r(13), 0
  Chk "memcpy/memmove/memset", r(14), MemModel()
  Chk "marker", r(15), &H600302B8
  Print
End Sub

' the same buffer work the CSUB does, in BASIC, for the checksum comparison
Function MemModel()
  Local j, s = 0
  For j = 0 To 47 : b(j) = 0 : Next j
  For j = 0 To 15 : b(j) = (j * 7 + 1) And &HFF : Next j
  For j = 0 To 15 : b(16 + j) = b(j) : Next j            ' memcpy(buf+16, buf, 16)
  For j = 23 To 0 Step -1 : b(8 + j) = b(j) : Next j     ' memmove(buf+8, buf, 24), overlapping
  For j = 0 To 7 : b(40 + j) = &HA5 : Next j             ' memset(buf+40, 0xA5, 8)
  For j = 0 To 47 : s = s + b(j) * (j + 1) : Next j
  MemModel = s
End Function

' arithmetic (sign-propagating) right shift, which MMBasic's >> is not
Function Asr(v, k)
  If v >= 0 Then
    Asr = v >> k
  Else
    Asr = -(((-v) + (1 << k) - 1) >> k)
  EndIf
End Function

Sub Chk name$, got, want
  If got = want Then
    Print "  PASS  "; name$; " ="; got
  Else
    Print "  FAIL  "; name$; " got"; got; " want"; want
    Inc fails
  EndIf
End Sub

CSUB lltest INTEGER, INTEGER
	0000000F
	'memcpy
	B5104B03 69DB681B 6DDB33FC BD104798 E000ED08 
	'memset
	B5104B03 69DB681B 6E1B33FC BD104798 E000ED08 
	'memmove
	B5104B03 69DB681B 6E5B33FC BD104798 E000ED08 
	'lltest
	6882B5F0 680668C3 B0956847 93019200 69034D60 9303000C 0030682B 003969DB 
	6C5B33FC 9A00001D 47A89B01 60204D59 682B6061 69DB0030 33FC0039 001D6C9B 
	9B019A00 4D5347A8 60E160A0 0030682B 003969DB 6CDB33FC 9A00001D 47A89B01 
	61204D4C 682B6161 69DB9A03 33FC0030 00396D1B 682B4798 61E161A0 9A0369DB 
	6D5B33FC 00390030 682B4798 62616220 9A0369DB 6D9B33FC 00390030 9A004798 
	19929B01 6322417B 00326363 62A0003B 980062E1 1A129901 63A2418B 230063E3 
	41BB4272 64229901 22016463 42B92300 D102DC05 42B19900 2200D801 64A22300 
	9B0064E3 43330EF2 9B016523 433BAD08 017B6563 65E34313 65A30173 08F3077A 
	66234313 210010FB 22306663 F7FF0028 2000FF63 23002100 33015CEA 22009204 
	9E049205 19809F05 2B304179 002AD1F4 66E166A0 70133B2F B2DB3307 2B713201 
	2210D1F9 A80C0029 FF3CF7FF 00292218 F7FFA80A 21A5FF4B A8122208 FF3CF7FF 
	21002000 5CEA2300 435A3301 17D29206 9E069207 19809F07 2B304179 6720D1F3 
	23006761 21002000 67A24A03 B01567E3 46C0BDF0 E000ED08 600302B8 
End CSUB
