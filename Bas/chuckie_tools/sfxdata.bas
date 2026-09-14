' ======================================================================
'  Sound tables, in the BBC Micro's own units, because PLAY BBC SOUND
'  takes them unchanged: a pitch is 0 to 255 in quarter semitones with 89
'  = the A above middle C and 4 to a semitone, and a duration is in
'  twentieths of a second.  A pitch of -1 ends a table and 0 is a rest.
' ======================================================================

' ------------------------------------------------------------ .dead_tune
'  The original's own sixteen notes, from the disassembly, played on
'  channel 3 through envelope 2.  In hex, as they read there:
'      21 04  29 02  21 04  19 02  15 04  05 02  0D 04  01 02
'      05 0C  05 01  0D 01  15 01  19 01  21 01  31 01  35 01
'  (nothing may follow a DATA line but data, so they are here instead)
deadtune:
DATA  33,4,  41,2,  33,4,  25,2
DATA  21,4,   5,2,  13,4,   1,2
DATA   5,12,  5,1,  13,1,  21,1
DATA  25,1,  33,1,  49,1,  53,1

' -------------------------------------------------------------- fanfares
'  Ours.  The BBC game was silent at all four of these moments, so these
'  are the tunes this version has always played, written out as notes.
' a new floor:    C5 E5 G5 C6 - G5 C6
tune0:
DATA 101,2, 117,2, 129,2, 149,3, 0,1, 129,2, 149,5, -1,0
' floor cleared:  G5 B5 D6 G6 B6
tune1:
DATA 129,2, 145,2, 157,2, 177,2, 193,5, -1,0
' game over:      C5 B4 A4 G4 E4
tune2:
DATA 101,4, 97,4, 89,4, 81,4, 69,10, -1,0
' ten thousand:   C6 E6 G6 C7 G6 C7
extratune:
DATA 149,2, 165,2, 177,2, 197,2, 177,2, 197,4, -1,0


' ----------------------------------------------------- hens per floor
'  How many of the five hen squares each floor uses on cycles 1 and 3.
'  Cycle 2 uses none, cycles 4 and 5 use all five.
hendata:
DATA 3, 4, 4, 4, 3, 3, 3, 3
