' BBCSoundTest.bas - exercises PLAY BBC SOUND / PLAY BBC ENVELOPE
' Listen for: a clean scale, a chord that starts together, a rising
' and falling envelope note, a laser and an explosion, a siren, a
' tune that paces itself by blocking on a full queue, and the eight
' noises - 0 to 2 buzzy and pitched, 4 to 6 hissy, 3 and 7 taking
' their pitch from channel 1 - and last an A/B of Elite's explosion
' with the noise tuned and then not, which is the difference the
' tuned settings make.
' Needs OPTION AUDIO configured (PWM, I2S or VS1053).

OPTION EXPLICIT
DIM INTEGER p, i, t

PRINT "1. Scale on channel 1, C4 to C5"
FOR p = 53 TO 101 STEP 4
  PLAY BBC SOUND 1, -15, p, 5
NEXT p
PRINT "   MM.INFO(SOUND) = "; MM.INFO(SOUND)
WaitQuiet

PRINT "2. C major chord, three channels synchronised with &H2xx"
PLAY BBC SOUND &H201, -10, 53, 20
PLAY BBC SOUND &H202, -10, 69, 20
PLAY BBC SOUND &H203, -10, 81, 20
WaitQuiet

PRINT "3. Envelope 1: the User Guide's rising and falling note"
PLAY BBC ENVELOPE 1, 1, 4, -4, 4, 10, 10, 10, 126, -2, 0, -10, 120, 100
PLAY BBC SOUND 1, 1, 100, 30
WaitQuiet

PRINT "4. Laser (envelope 2, flushed) and explosion (envelope 3, noise)"
PLAY BBC ENVELOPE 2, 1, -8, 0, 0, 20, 0, 0, 126, -8, 0, -20, 126, 100
PLAY BBC ENVELOPE 3, 4, 0, 0, 0, 0, 0, 0, 126, -1, -1, -4, 126, 80
FOR i = 1 TO 3
  PLAY BBC SOUND &H11, 2, 220, 4
  PAUSE 300
NEXT i
PLAY BBC SOUND &H10, 3, 6, 15            ' white noise, low
WaitQuiet

PRINT "5. Siren for three seconds, then PLAY STOP"
PLAY BBC ENVELOPE 4, 6, 2, -2, 0, 12, 12, 0, 126, 0, 0, -10, 126, 126
PLAY BBC SOUND 2, 4, 120, 255
PAUSE 3000
PLAY STOP
PRINT "   after PLAY STOP: "; MM.INFO(SOUND)

PRINT "6. Twenty short notes on one channel: the queue holds 8, so the"
PRINT "   loop should take about 4 s, paced by the engine, not by PAUSE"
t = TIMER
FOR i = 1 TO 20
  PLAY BBC SOUND 1, -12, 53 + (i MOD 12) * 4, 4
NEXT i
PRINT "   queued 20 notes in "; TIMER - t; " ms (expect roughly 2400)"
WaitQuiet

PRINT "7. Two independent melodies on channels 1 and 2"
FOR i = 0 TO 7
  PLAY BBC SOUND 1, -12, 53 + i * 4, 6
  PLAY BBC SOUND 2, -12, 77 + i * 4, 6
NEXT i
WaitQuiet

PRINT "8. The eight noises. 0-2 periodic (buzzy), 4-6 white (hiss),"
PRINT "   3 and 7 clocked by channel 1 rather than at a fixed rate"
FOR i = 0 TO 7
  PRINT "   pitch"; i
  ' 3 and 7 need channel 1 to have a pitch to be tuned by.  Amplitude 0
  ' sets it without being heard, which is the noise's own business.
  PLAY BBC SOUND 1, 0, 100, 10
  PLAY BBC SOUND &H10, -12, i, 8
  WaitQuiet
NEXT i

PRINT "9. Noise 3 tuned by channel 1 at three pitches: the buzz should"
PRINT "   rise with it, and 7 should hiss higher the same way"
FOR i = 0 TO 2
  PLAY BBC SOUND 1, 0, 53 + i * 24, 8
  PLAY BBC SOUND &H10, -12, 3, 8
  WaitQuiet
  PLAY BBC SOUND 1, 0, 53 + i * 24, 8
  PLAY BBC SOUND &H10, -12, 7, 8
  WaitQuiet
NEXT i

PRINT "10. Elite's explosion, with the game's own numbers.  Envelope 3 is"
PRINT "    almost silent (it rises to level 1) - what it is really for is"
PRINT "    the pitch sweep, and noise 7 follows channel 1 down."
' From the cassette loader's E% table, which is where Elite's four
' envelopes live: 3, T=1, PI 1/-1/-3 over 17/32/128 steps, and an
' amplitude that only ever reaches 1.  Then SFX 16 and SFX 24 of the
' game's own SFX table, the two halves of a kill, fired together.
PLAY BBC ENVELOPE 3, 1, 1, -1, -3, 17, 32, 128, 1, 0, 0, -1, 1, 1
PLAY BBC SOUND &H11, 3, &HF0, &H18
PLAY BBC SOUND &H10, -15, 7, &H1A
WaitQuiet

PRINT "11. The same, with the noise on a fixed rate instead (pitch 6)."
PRINT "    This is what it sounded like before: a flat hiss, no crash."
PLAY BBC SOUND &H11, 3, &HF0, &H18
PLAY BBC SOUND &H10, -15, 6, &H1A
WaitQuiet

PRINT "Done."
END

' Wait until the engine has gone quiet and released the output
SUB WaitQuiet
  DO WHILE MM.INFO(SOUND) = "BBC"
    PAUSE 50
  LOOP
  PAUSE 300
END SUB
