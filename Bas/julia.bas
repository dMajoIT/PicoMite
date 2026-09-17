' julia.bas - Julia set, with plotjulia taking everything it needs as
' parameters so it is a self-contained routine (the first mmb2csub target).
Mode 2
CLS
map maximite
'Specify initial values
RealOffset = -1.30
ImaginOffset = -1.22
'------------------------------------------------*
'Set the Julia set constant [eg C = -1.2 + 0.8i]
CRealVal = -0.78
CImagVal = -0.20
'------------------------------------------------*
MAXIT=80 'max iterations
PixelWidth = MM.HRes
PixelHeight = MM.VRes
GAP = PixelHeight / PixelWidth
SIZE = 2.50
XDelta = SIZE / PixelWidth
YDelta = (SIZE * GAP) / PixelHeight
' MAP() has no CSUB CallTable slot, and in a fixed mode its sixteen values are
' constants - so look them up once here and pass the table in.
Dim mp%(15)
For i% = 0 To 15 : mp%(i%) = map(i%) : Next i%
plotjulia PixelWidth, PixelHeight, XDelta, YDelta, RealOffset, ImaginOffset, CRealVal, CImagVal, MAXIT, mp%()
' the rendered image, for comparing this against the CSUB version byte for byte.
' SAVE IMAGE records the framebuffer and ignores the colour map, so what lands in
' the file is exactly what plotjulia computed.
Save Image "julia.bmp"
Do
  a$ = Inkey$
Loop While a$ = ""
end
'
' w, h    picture size in pixels
' xd, yd  the step in the complex plane per pixel
' rOfs, iOfs   top-left corner of the view
' cRe, cIm     the Julia constant C
' mit          iteration limit
' mp%()        the sixteen colours, already resolved through MAP()
sub plotjulia w, h, xd, yd, rOfs, iOfs, cRe, cIm, mit, mp%()
Local X, Y, CX, CY, Zr, Zi, COUNT, new_Zr, new_Zi
'Loop processing - visit every pixel
For X = 0 To (w - 1)
  CX = X * xd + rOfs
  For Y = 0 To (h - 1)
    CY = Y * yd + iOfs
    Zr = CX
    Zi = CY
    COUNT = 0
'    Begin Iteration loop
    Do While (( COUNT <= mit ) And (( Zr * Zr + Zi * Zi ) < 4 ))
      new_Zr = Zr * Zr - Zi * Zi + cRe
      new_Zi = 2 * Zr * Zi + cIm
      Zr = new_Zr
      Zi = new_Zi
      COUNT = COUNT + 1
    Loop
    Pixel X,Y,mp%( COUNT Mod 16)
  Next Y
Next X
end sub
