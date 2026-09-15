' ExileTeleportSound.bas - Exile's teleport sound through PLAY BBC SOUND
'
' Exile (Superior Software, 1988) drives the sound chip itself: on every
' vsync its interrupt steps a volume envelope and a frequency envelope for
' each channel and writes the chip's registers.  This program runs those
' two envelopes exactly as the 6502 does, from the game's own envelope
' table (208 bytes at &2DB9) and the four-byte block that follows the
' play_sound call in play_sound_for_teleporting (&4410: 29 C2 37 F3),
' then hands every 20 ms step to PLAY BBC SOUND as a flushed 50 ms note.
'
' The pitch is rounded to the nearest BBC pitch unit (a quarter of a
' semitone).  Decision D2 in docs/Exile_Port_Design_Review.html asks
' whether that rounding is audible; key B plays the same steps through
' PLAY SOUND at the exact frequency so the two can be compared by ear.
'
'   A  the sound through PLAY BBC SOUND (quarter-semitone pitch)
'   B  the same steps through PLAY SOUND at the exact frequency
'   Q  quit
'
' How the numbers come out (see the disassembly around &1323 and &1399):
'   the chip period is (255 - value) put through four ranges,
'     < &40: +&20     < &84: -&10 then x2     < &B6: -&4A then x4
'     else: -&80 then x8,    and the frequency is 4 MHz / (32 * period);
'   the loudness is the top nibble of the 8-bit volume value; once the
'   volume envelope has run out the value falls by 2 every vsync.
Option EXPLICIT
Option BASE 0

Const CH = 1                          ' BBC channel used; &H10 flushes it first
Const VOLENV = &H29, VOLINIT = &HC2   ' volume: envelope offset; start nibble / duration nibble
Const FRQENV = &H37, FRQINIT = &HF3   ' frequency: the same
Const MAXSTEP = 600                   ' 12 seconds, more than any Exile sound
Const REFVOL = 25                      ' PLAY SOUND volume that stands for loudness 15

Dim integer env(207)
Dim integer ev(1), dur(1), stageoff(1), stagedur(1), loops(1), loopoff(1)
Dim integer stepLoud(MAXSTEP - 1), stepPeriod(MAXSTEP - 1), nsteps
Dim integer i
Dim k$

Restore envtable
For i = 0 To 207 : Read env(i) : Next i
Decode
Report
Print "A: through PLAY BBC SOUND ..."
PlayBBC
Pause 700
Print "B: through PLAY SOUND at the exact frequency ..."
PlayExact
Print
Print "A = PLAY BBC SOUND   B = exact reference   Q = quit"
Do
  k$ = UCase$(Inkey$)
  If k$ = "A" Then PlayBBC
  If k$ = "B" Then PlayExact
Loop Until k$ = "Q"
End

' One vsync of update_sound_envelope for envelope k (0 volume, 1 frequency).
' Returns 1 while the envelope is running (the 6502 leaves with carry set),
' 0 once it has ended.
Function EnvUpdate(k As integer) As integer
  Local integer y, a
  If dur(k) = 0 Then
    EnvUpdate = 0
    Exit Function
  EndIf
  y = stageoff(k)
  If stagedur(k) = 0 Then
    If loops(k) = 0 Then                  ' not inside a loop: one of the duration's stages
      dur(k) = dur(k) - 1
      If dur(k) = 0 Then
        EnvUpdate = 0
        Exit Function
      EndIf
    EndIf
    y = y + 1
    a = env(y)
    If a >= 128 Then                       ' loop marker: end of a loop, start of one, or both
      loops(k) = (loops(k) - 1) And 255
      If loops(k) >= 128 Then              ' went negative: start the loop this byte describes
        loops(k) = a And 127
        y = y + 1
        loopoff(k) = y
      EndIf
      y = loopoff(k)                       ' back to the start of the loop body
      a = env(y)
    EndIf
    stagedur(k) = a                        ' first byte of a stage: how many steps
    y = y + 1
    stageoff(k) = y                        ' second byte: the delta, applied each step
  EndIf
  ev(k) = (ev(k) + env(y)) And 255
  stagedur(k) = stagedur(k) - 1
  EnvUpdate = 1
End Function

' The chip period the game writes for an 8-bit frequency value
Function Period(v As integer) As integer
  Local integer a
  a = 255 - v
  If a >= &HB6 Then
    Period = ((a - &H80) And 255) << 3
  ElseIf a >= &H84 Then
    Period = ((a - &H4A) And 255) << 2
  ElseIf a >= &H40 Then
    Period = ((a - &H10) And 255) << 1
  Else
    Period = (a + &H20) And 255
  EndIf
End Function

' Run both envelopes as update_sound_channel_loop does, one vsync per
' step, until the sound has faded to nothing
Sub Decode
  Local integer skip, loud
  ev(0) = VOLINIT And &HF0 : dur(0) = VOLINIT And 15 : stageoff(0) = VOLENV
  ev(1) = FRQINIT And &HF0 : dur(1) = FRQINIT And 15 : stageoff(1) = FRQENV
  stagedur(0) = 0 : stagedur(1) = 0 : loops(0) = 0 : loops(1) = 0
  loopoff(0) = 0 : loopoff(1) = 0
  nsteps = 0
  Do
    skip = 0
    If EnvUpdate(0) = 0 Then               ' volume envelope over: fade by 2 a vsync
      If ev(0) < 2 Then
        skip = 1                           ' (and the frequency is left alone that vsync)
      Else
        ev(0) = ev(0) - 2
      EndIf
    EndIf
    If skip = 0 Then skip = EnvUpdate(1)
    loud = ev(0) >> 4
    stepLoud(nsteps) = loud
    stepPeriod(nsteps) = Period(ev(1))
    nsteps = nsteps + 1
  Loop Until loud = 0 Or nsteps >= MAXSTEP
End Sub

Function BBCPitch(f As float) As integer
  Local integer p
  p = Cint(89 + 48 * Log(f / 440) / Log(2))   ' 4 units a semitone, 89 = A4
  If p < 0 Then p = 0
  If p > 255 Then p = 255
  BBCPitch = p
End Function

Sub Report
  Local integer j, p
  Local float f, fq, c, worst, fmin, fmax
  fmin = 1e9 : fmax = 0 : worst = 0
  For j = 0 To nsteps - 1
    f = 125000 / stepPeriod(j)
    If f < fmin Then fmin = f
    If f > fmax Then fmax = f
    p = BBCPitch(f)
    fq = 440 * 2 ^ ((p - 89) / 48)
    c = Abs(1200 * Log(fq / f) / Log(2))
    If c > worst Then worst = c
  Next j
  Print "Exile teleport sound: " + Str$(nsteps) + " steps of 20 ms = " + Str$(nsteps * 20) + " ms"
  Print "frequency " + Str$(Int(fmin)) + " to " + Str$(Int(fmax)) + " Hz, loudness starts at " + Str$(stepLoud(0)) + " of 15"
  Print "worst quarter-semitone rounding: " + Str$(Int(worst * 10) / 10) + " cents"
  Print "first steps (loudness, period, Hz, BBC pitch):"
  For j = 0 To 11
    f = 125000 / stepPeriod(j)
    Print "  " + Str$(stepLoud(j)) + "  " + Str$(stepPeriod(j)) + "  " + Str$(Int(f)) + "  " + Str$(BBCPitch(f))
  Next j
End Sub

' Each 20 ms step is a flushed 50 ms note, so the channel is always
' carrying the latest step and goes quiet by itself 50 ms after the last
Sub PlayBBC
  Local integer j
  Local float t
  t = Timer
  For j = 0 To nsteps - 1
    Play BBC Sound &H10 + CH, -stepLoud(j), BBCPitch(125000 / stepPeriod(j)), 1
    t = t + 20
    Do While Timer < t : Loop
  Next j
  Pause 100
  Play Stop
  Pause 100
End Sub

' The same steps as a square wave at the exact frequency, for comparison
Sub PlayExact
  Local integer j
  Local float t
  t = Timer
  For j = 0 To nsteps - 1
    Play Sound 1, B, Q, 125000 / stepPeriod(j), stepLoud(j) * REFVOL \ 15
    t = t + 20
    Do While Timer < t : Loop
  Next j
  Play Sound 1, B, O
  Play Stop
  Pause 100
End Sub

' envelopes_table, 208 bytes at &2DB9 in the standard version
envtable:
Data 136,3,16,3,240,128,3,192,1,4,5,6,130,12,254,3    ' &2DB9
Data 3,128,1,249,2,1,2,255,8,240,8,248,1,251,135,3    ' &2DC9
Data 161,3,129,128,131,2,163,2,129,128,62,0,1,6,10,12    ' &2DD9
Data 10,0,120,254,15,16,15,244,248,4,2,5,254,128,8,240    ' &2DE9
Data 10,248,12,252,146,3,2,3,1,3,0,3,255,3,254,128    ' &2DF9
Data 3,3,3,1,3,0,12,255,4,32,5,16,5,8,4,224    ' &2E09
Data 5,240,5,248,225,1,248,8,1,225,1,26,13,254,128,1    ' &2E19
Data 24,100,0,136,2,0,1,64,2,0,1,188,144,3,0,1    ' &2E29
Data 12,3,0,1,244,128,16,0,1,47,16,0,1,249,16,0    ' &2E39
Data 1,241,131,16,240,135,4,32,2,253,2,192,128,11,20,131    ' &2E49
Data 3,240,3,16,128,3,188,7,6,130,2,254,4,2,128,17    ' &2E59
Data 255,11,20,1,2,2,131,10,3,4,9,136,1,11,1,224    ' &2E69
Data 1,21,172,1,20,1,236,128,16,255,20,248,40,2,1,0    ' &2E79
