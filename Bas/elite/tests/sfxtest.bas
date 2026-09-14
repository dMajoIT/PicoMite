' Play each of Elite's ten sounds in turn, named, so they can be judged by
' ear.  Standalone: it carries its own copy of the SFX table from
' 45_sound.bas and of the four envelopes from the cassette loader's E%.
'
' Nothing here is approximated.  Each effect is the four bytes the 6502
' source holds it as, handed straight to PLAY BBC SOUND, and the envelopes
' are the loader's own numbers.
'
' Needs firmware 6.03.02b6 or above.  The explosion's noise is pitch 7,
' which is clocked by channel 1 rather than at a fixed rate, and earlier
' firmware has no tuned noise setting to clock it with - it would come out
' as a flat hiss instead of a crash.
'
'   RUN, and press a key between each.  ESC stops.

OPTION EXPLICIT
OPTION DEFAULT NONE

CONST TXN = 10
DIM INTEGER txCh(TXN-1), txAmp(TXN-1), txPit(TXN-1), txDur(TXN-1)
DIM txNm$(TXN-1) LENGTH 44
DIM INTEGER txI

' envelope, T, three pitch steps, three section lengths, ADSR, two levels
PLAY BBC ENVELOPE 1, 1,  0, 111, -8,  4,  1,   8,  8, -2, 0,   -1, 112,  44
PLAY BBC ENVELOPE 2, 1, 14, -18, -1, 44, 32,  50,  6,  1, 0,   -2, 120, 126
PLAY BBC ENVELOPE 3, 1,  1,  -1, -3, 17, 32, 128,  1,  0, 0,   -1,   1,   1
PLAY BBC ENVELOPE 4, 1,  4,  -8, 44,  4,  6,   8, 22,  0, 0, -127, 126,   0

RESTORE dat_tx
FOR txI = 0 TO TXN - 1
  READ txNm$(txI), txCh(txI), txAmp(txI), txPit(txI), txDur(txI)
NEXT txI

CLS
PRINT "Elite's sounds - a key plays the next, ESC stops"
PRINT
FOR txI = 0 TO TXN - 1
  PRINT txI; "  "; txNm$(txI)
  PLAY BBC SOUND txCh(txI), txAmp(txI), txPit(txI), txDur(txI)
  IF TxKey() = 27 THEN PLAY STOP : END
NEXT txI

' The two halves of a kill are fired together by the game, and they belong
' together: the tone on channel 1 sweeps down under envelope 3 and the noise
' is clocked by it.  Heard apart, neither is the sound.
PRINT
PRINT "and the two halves of an explosion together, as the game plays them"
PLAY BBC SOUND txCh(3), txAmp(3), txPit(3), txDur(3)
PLAY BBC SOUND txCh(2), txAmp(2), txPit(2), txDur(2)
IF TxKey() = 27 THEN PLAY STOP : END
PLAY STOP
PRINT "done"
END

FUNCTION TxKey() AS INTEGER
  LOCAL k$ LENGTH 2
  DO
    k$ = INKEY$
  LOOP UNTIL k$ <> ""
  TxKey = ASC(k$)
END FUNCTION

dat_tx:
'      name                              channel  amp  pitch  duration
DATA "our lasers",                            18,    1,     0,  16
DATA "being hit by lasers",                   18,    2,    44,   8
DATA "explosion, the noise half",             16,  -15,     7,  26
DATA "explosion, the tone that sweeps it",    17,    3,   240,  24
DATA "short, high beep",                       3,  -15,   188,   1
DATA "long, low beep",                        19,  -12,    12,   8
DATA "missile away, or our own launch",       16,  -15,     6,  12
DATA "hyperspace drive",                      16,    2,    96,  16
DATA "E.C.M. on, until it is flushed",        19,    4,   194, 255
DATA "E.C.M. off, which is that flush",       19,    0,     0,   0
