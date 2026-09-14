' =====================================================================
'  Sound: the original's ten effects, played the way it played them
'
'  The 6502 source carries them as an SFX table, each entry being the four
'  bytes the BBC's SOUND statement was handed - a channel word, an
'  amplitude or an envelope number, a pitch and a duration:
'
'    0   &12,&01,&00,&10   lasers fired by us
'    8   &12,&02,&2C,&08   we are being hit by lasers
'    16  &11,&03,&F0,&18   we died / we made a kill, part 2
'    24  &10,&F1,&07,&1A   we died / we made a kill, part 1
'    32  &03,&F1,&BC,&01   short, high beep
'    40  &13,&F4,&0C,&08   long, low beep
'    48  &10,&F1,&06,&0C   missile launched, or we launched from the station
'    56  &10,&02,&60,&10   hyperspace drive engaged
'    64  &13,&04,&C2,&FF   E.C.M. on
'    72  &13,&00,&00,&00   E.C.M. off
'
'  PLAY BBC SOUND takes those four numbers as they stand, so the table at
'  the end of this file is the 6502 table transcribed and nothing more.
'  There is no conversion to hertz and milliseconds any more, and nothing
'  is approximated: what this used to do was slide a PLAY SOUND channel by
'  hand from a frequency to another frequency, because five of the ten ask
'  for envelopes 1 to 4 and those are set up by the cassette loader rather
'  than by the game, so they were in nothing we had.  They are in the
'  loader: four blocks of fourteen bytes at E%, handed to OSWORD 8 by its
'  FNE macro, and they are now defined below exactly as it defines them.
'
'  Envelope 3 is the one worth knowing about.  Its amplitude never rises
'  above 1 out of a possible 126, so it is not shaping a tone at all - what
'  it is for is the pitch, which it sweeps down over 177 steps.  SFX 24
'  asks for noise 7, and noise 7 is clocked by channel 1 rather than at a
'  fixed rate, so the explosion is the noise following that sweep down.
'  That is the whole sound, and it needs a firmware whose noise channel
'  does the BBC's tuned settings - which is why this now wants b6.
'
'  Nothing blocks.  Nine of the ten entries carry the flush bit, and a
'  flush empties the queue before the queue is tested for room, so it can
'  never wait; the tenth is the short beep, which can only ever queue
'  behind something already on channel 3 - which is what it did on a BBC
'  too.  The firmware sequences the notes itself, so there is no longer
'  anything to service from the frame loop, and no longer any way to break
'  the sound by forgetting to service it from somewhere else.
' =====================================================================

' How much of one of the original's iterations this frame is worth.  A long
' frame is clamped rather than allowed to move the world a long way at once,
' which is what would otherwise happen coming back from a chart or a tunnel.
SUB NextTick
  LOCAL FLOAT now
  now = TIMER
  tick = (now - tickPrev) * TICKRATE / 1000
  IF tick > TICKMAX THEN tick = TICKMAX
  IF tick < 0 THEN tick = 0
  tickPrev = now
  tickAcc = tickAcc + tick
  tickWhole = 0
  IF tickAcc >= 1 THEN
    tickAcc = tickAcc - 1
    tickWhole = 1
  ENDIF
END SUB

' Starting or restarting the clock, so the first frame after a pause does not
' count the pause.
SUB ResetTick
  tickPrev = TIMER
  tickAcc = 0
  tick = 0
  tickWhole = 0
END SUB

SUB LoadSounds
  LOCAL INTEGER i
  IF SOUNDON = 0 THEN EXIT SUB
  ' The four envelopes, as the loader's E% table has them.  The first
  ' number is the envelope, then T, the three pitch steps, the three
  ' pitch section lengths, attack, decay, sustain and release, and the
  ' levels the attack rises to and the decay falls to.
  PLAY BBC ENVELOPE 1, 1,  0, 111, -8,  4,  1,   8,  8, -2, 0,   -1, 112,  44
  PLAY BBC ENVELOPE 2, 1, 14, -18, -1, 44, 32,  50,  6,  1, 0,   -2, 120, 126
  PLAY BBC ENVELOPE 3, 1,  1,  -1, -3, 17, 32, 128,  1,  0, 0,   -1,   1,   1
  PLAY BBC ENVELOPE 4, 1,  4,  -8, 44,  4,  6,   8, 22,  0, 0, -127, 126,   0
  RESTORE dat_sfx
  FOR i = 0 TO NSFX - 1
    READ sfxCh(i), sfxAmp(i), sfxPit(i), sfxDur(i)
  NEXT i
END SUB

SUB Sfx(n AS INTEGER)
  IF SOUNDON = 0 THEN EXIT SUB
  PLAY BBC SOUND sfxCh(n), sfxAmp(n), sfxPit(n), sfxDur(n)
END SUB

SUB SoundOff
  PLAY STOP
END SUB

dat_sfx:
' The table above, in the order the SFX_ constants are numbered and in
' decimal because that is what PLAY BBC SOUND wants: &F1 is -15 and &F4
' is -12, an amplitude of 1 to 4 is an envelope, and 0 is silence.
'
'     channel  amp  pitch  duration
DATA      18,    1,     0,       16   ' our lasers
DATA      18,    2,    44,        8   ' being hit by lasers
DATA      16,  -15,     7,       26   ' explosion, the noise half
DATA      17,    3,   240,       24   ' explosion, the tone that sweeps it
DATA       3,  -15,   188,        1   ' short, high beep
DATA      19,  -12,    12,        8   ' long, low beep
DATA      16,  -15,     6,       12   ' missile away, or our own launch
DATA      16,    2,    96,       16   ' hyperspace drive
DATA      19,    4,   194,      255   ' E.C.M. on, until it is flushed
DATA      19,    0,     0,        0   ' E.C.M. off, which is that flush
