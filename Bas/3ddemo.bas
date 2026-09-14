' Elite Ship - Converter v2.9.7 (Origin-based normals)
Option Explicit
MODE 5
FRAMEBUFFER create
FRAMEBUFFER write f
Option BASE 0
Dim INTEGER colours(4)
colours(0)=RGB(150,150,80):colours(1)=RGB(100,120,120)
colours(2)=RGB(120,50,50):colours(3)=RGB(60,60,120):colours(4)=RGB(150,150,170)
Dim Integer i,j,n=1,nv,nf,fc,camera=1,scale
Dim Integer viewplane=600, Ship
Dim FLOAT yaw=0,pitch=0,roll=0,q1(4)

'Viper Data
Data 15, 9, 33, 600
Data 0, 0, 72
Data 0, 16, 24
Data 0,-16, 24
Data 48, 0,-24
Data -48, 0,-24
Data 24,-16,-24
Data -24,-16,-24
Data 24, 16,-24
Data -24, 16,-24
Data -32, 0,-24
Data 32, 0,-24
Data 8, 8,-24
Data -8, 8,-24
Data -8,-8,-24
Data 8,-8,-24

Data 3,4,4,4,4,3,6,3,3

Data 1,7,8
Data 0,1,8,4
Data 0,3,7,1
Data 4,6,2,0
Data 2,5,3,0
Data 6,5,2
Data 3,5,6,4,8,7
Data 9,12,13
Data 14,11,10

'Thargoid Data
Data 20, 9, 39, 1600
Data 32,-48, 48
Data 32,-68, 0
Data 32,-48,-48
Data 32, 0,-68
Data 32, 48,-48
Data 32, 68, 0
Data 32, 48, 48
Data 32, 0, 68
Data -24,-116, 116
Data -24,-164, 0
Data -24,-116,-116
Data -24, 0,-164
Data -24, 116,-116
Data -24, 164, 0
Data -24, 116, 116
Data -24, 0, 164
Data -24, 64, 80
Data -24, 64,-80
Data -24,-64,-80
Data -24,-64, 80

Data 4,4,4,4,8,4,4,4,4

Data 8,9,1,0
Data 9,10,2,1
Data 10,11,3,2
Data 11,12,4,3
Data 1,2,3,4,5,6,7,0
Data 12,13,5,4
Data 13,14,6,5
Data 14,15,7,6
Data 0,7,15,8

'Pod Data
Data 4, 4, 11, 400
Data -7, 0, 36
Data -7,-14,-12
Data -7, 14,-12
Data 21, 0, 0

Data 3,3,3,3

Data 1,2,3
Data 0,3,2
Data 0,1,3
Data 2,1,0

'Asp Data
Data 19,13,49,800
Data 0,-18, 0
Data 0,-9,-45
Data 43, 0,-45
Data 69,-3, 0
Data 43,-14, 28
Data -43, 0,-45
Data -69,-3, 0
Data -43,-14, 28
Data 26,-7, 73
Data -26,-7, 73
Data 43, 14, 28
Data -43, 14, 28
Data 0, 9,-45
Data -17, 0,-45
Data 17, 0,-45
Data 0,-4,-45
Data 0, 4,-45
Data 0,-7, 73
Data 0,-7, 83

Data 5,5,5,3,4,4,4,3,3,3
Data 3,4,4

Data 0,4,8,9,7
Data 0,1,2,3,4
Data 7,6,5,1,0
Data 10,12,11
Data 10,11,9,8
Data 5,6,11,12
Data 12,10,3,2
Data 3,8,4
Data 7,9,6
Data 10,8,3
Data 6,9,11
Data 5,12,2,1
Data 16,14,15,13

'Asteroid Data
Data 9,14,41,1000
Data 0, 80, 0
Data -80,-10, 0
Data 0,-80, 0
Data 70,-40, 0
Data 60, 50, 0
Data 50, 0, 60
Data -40, 0, 70
Data 0, 30,-75
Data 0,-50,-60

Data 3,3,3,3,3,3,3,3,3,3
Data 3,3,3,3

Data 0,6,5
Data 5,6,2
Data 0,1,6
Data 1,2,6
Data 2,3,5
Data 3,4,5
Data 5,4,0
Data 7,1,0
Data 7,8,1
Data 8,7,3
Data 8,2,1
Data 8,3,2
Data 7,4,3
Data 0,4,7

'Canister Data
Data 10,7,29,300
Data 24, 16, 0
Data 24, 5, 15
Data 24,-13, 9
Data 24,-13,-9
Data 24, 5,-15
Data -24, 16, 0
Data -24, 5, 15
Data -24,-13, 9
Data -24,-13,-9
Data -24, 5,-15

Data 5,4,4,4,4,4,5

Data 0,1,2,3,4
Data 5,6,1,0
Data 6,7,2,1
Data 7,8,3,2
Data 8,9,4,3
Data 0,4,9,5
Data 9,8,7,6,5

'Cobra Data
Data 28,17,59,1000
Data 32, 0, 76
Data -32, 0, 76
Data 0, 26, 24
Data -120,-3,-8
Data 120,-3,-8
Data -88, 16,-40
Data 88, 16,-40
Data 128,-8,-40
Data -128,-8,-40
Data 0, 26,-40
Data -32,-24,-40
Data 32,-24,-40
Data -36, 8,-40
Data -8, 12,-40
Data 8, 12,-40
Data 36, 8,-40
Data 36,-12,-40
Data 8,-16,-40
Data -8,-16,-40
Data -36,-12,-40
Data 0, 0, 76
Data 0, 0, 90
Data -80,-6,-40
Data -80, 6,-40
Data -88, 0,-40
Data 80, 6,-40
Data 88, 0,-40
Data 80,-6,-40

Data 3,3,3,3,3,3,3,3,3,7
Data 4,4,3,3,4,4,4

Data 2,1,0
Data 2,5,1
Data 0,6,2
Data 5,3,1
Data 0,4,6
Data 2,9,5
Data 6,9,2
Data 5,8,3
Data 4,7,6
Data 6,7,11,10,8,5,9
Data 12,13,18,19
Data 14,15,16,17
Data 22,24,23
Data 25,26,27
Data 1,3,8,10
Data 0,1,10,11
Data 11,7,4,0

'Mamba Data
Data 25,9,29,600
Data 0, 0, 64
Data -64,-8,-32
Data -32, 8,-32
Data 32, 8,-32
Data 64,-8,-32
Data -4, 4, 16
Data 4, 4, 16
Data 8, 3, 28
Data -8, 3, 28
Data -20,-4, 16
Data 20,-4, 16
Data -24,-7,-20
Data -16,-7,-20
Data 16,-7,-20
Data 24,-7,-20
Data -8, 4,-32
Data 8, 4,-32
Data 8,-4,-32
Data -8,-4,-32
Data -32, 4,-32
Data 32, 4,-32
Data 36,-4,-32
Data -36,-4,-32
Data -38, 0,-32
Data 38, 0,-32

Data 3,3,4,3,3,4,4,3,3

Data 9,11,12
Data 10,13,14
Data 8,7,6,5
Data 2,1,0
Data 0,4,3
Data 2,3,4,1
Data 15,16,17,18
Data 24,21,20
Data 19,22,23

'Missile Data
Data 17,9,31,600
Data 0, 0, 68
Data 8,-8, 36
Data 8, 8, 36
Data -8, 8, 36
Data -8,-8, 36
Data 8, 8,-44
Data 8,-8,-44
Data -8,-8,-44
Data -8, 8,-44
Data 12, 12,-44
Data 12,-12,-44
Data -12,-12,-44
Data -12, 12,-44
Data -8, 8,-12
Data -8,-8,-12
Data 8, 8,-12
Data 8,-8,-12

Data 3,3,3,3,4,4,4,4,4

Data 0,3,4
Data 4,1,0
Data 0,1,2
Data 0,2,3
Data 6,5,2,1
Data 1,4,7,6
Data 8,7,4,3
Data 5,8,3,2
Data 7,8,5,6

'Python Data
Data 11,9,27,1500
Data 0, 0, 224
Data 0, 48, 48
Data 96, 0,-16
Data -96, 0,-16
Data 0, 48,-32
Data 0, 24,-112
Data -48, 0,-112
Data 48, 0,-112
Data 0,-48, 48
Data 0,-48,-32
Data 0,-24,-112

Data 3,3,3,3,3,3,3,3,4

Data 1,3,0
Data 0,2,1
Data 3,8,0
Data 0,8,2
Data 4,3,1
Data 2,4,1
Data 9,8,3
Data 2,8,9
Data 7,10,6,5

'Sidewinder Data
Data 10,8,25,600
Data -32, 0, 36
Data 32, 0, 36
Data 64, 0,-28
Data -64, 0,-28
Data 0, 16,-28
Data 0,-16,-28
Data -12, 6,-28
Data 12, 6,-28
Data 12,-6,-28
Data -12,-6,-28

Data 3,3,3,4,4,3,3,3

Data 0,1,4
Data 0,4,3
Data 1,2,4
Data 3,4,2,5
Data 6,7,8,9
Data 0,3,5
Data 5,1,0
Data 5,2,1

'Station Data
Data 16,15,51,2500
Data 160, 0, 160
Data 0, 160, 160
Data -160, 0, 160
Data 0,-160, 160
Data 160,-160, 0
Data 160, 160, 0
Data -160, 160, 0
Data -160,-160, 0
Data 160, 0,-160
Data 0, 160,-160
Data -160, 0,-160
Data 0,-160,-160
Data 10,-30, 160
Data 10, 30, 160
Data -10, 30, 160
Data -10,-30, 160

Data 4,4,3,3,3,3,4,4,4,4
Data 3,3,3,3,4

Data 1,2,3,0
Data 12,13,14,15
Data 0,3,4
Data 5,1,0
Data 6,2,1
Data 7,3,2
Data 7,11,4,3
Data 0,4,8,5
Data 2,6,10,7
Data 9,6,1,5
Data 10,11,7
Data 4,11,8
Data 8,9,5
Data 9,10,6
Data 8,11,10,9

'End Data
'=================================================

Do 'load the next object
Read nv,nf,fc,scale
Dim FLOAT vertices(2, nv-1)
Inc Ship

For i=0 To nv-1
  Read vertices(0,i),vertices(1,i),vertices(2,i)
Next i

Math SCALE vertices(),2.0,vertices()
Dim INTEGER facecount(nf-1)
For i=0 To nf-1
  Read facecount(i)
Next i

Dim INTEGER faces(fc)
For i=0 To fc
  Read faces(i)
Next i

Dim INTEGER edge(nf-1),fil(nf-1)
For i=0 To nf-1
  edge(i)=3:fil(i)=i Mod 5
Next i
'End Sub

Draw3D CREATE n,nv,nf,camera,vertices(),facecount(),faces(),colours(),edge(),fil()
Draw3D CAMERA camera,viewplane,0,0
CLS :j=0
Do 'spin the object
  Math Q_EULER yaw,pitch,roll,q1()
  Inc yaw,Rad(1):Inc pitch,Rad(2):Inc roll,Rad(0.5)
  Draw3D ROTATE q1(),1
  Draw3D SHOW 1,0,0,scale,0,1
  FRAMEBUFFER copy f,n
  Inc j
  Pause 12
Loop Until j>800
Draw3D Close n
Erase  vertices(),facecount(),faces(),edge(),fil()
If Ship=12 Then Restore :Ship=0
Loop
