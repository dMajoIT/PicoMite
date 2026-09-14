' =====================================================================
'  The ship hangar
'
'  What you see for a moment when you dock: the inside of the station,
'  with whatever happens to be standing on the deck.  Half the time it is
'  one of the original's four fixed groups, half the time a single small
'  fighter somewhere random, and in every case each ship is spun on the
'  spot so it can be facing any way at all.  Bigger ships are drawn higher
'  up than smaller ones, worked out from the square root of the
'  blueprint's targetable area - which is to say everything stands on the
'  floor rather than at one height.
'
'  The floor is eleven screen-wide lines at 130/n below the centre for n
'  from 2 to 12, so they start well apart at the bottom of the view and
'  bunch together as they approach the horizon.  The back wall is vertical
'  lines every sixteen pixels from the top of the view down to that
'  horizon.  Both are the original's own arithmetic, and because our focal
'  length is the BBC's the numbers carry across unchanged.
'
'  Departure: the original draws the ships first and then threads the
'  background in from the edges of the screen, stopping each line where it
'  runs into something already drawn.  Ours draws the background first and
'  the ships over the top of it with their faces filled black - the same
'  trick the space station uses - which comes to the same picture without
'  reading the screen back a pixel at a time.
' =====================================================================

SUB HangarScreen
  LOCAL INTEGER t, hx, hz
  ' Every mesh made while this is set gets black faces, so the floor and
  ' the wall stop at the hull instead of showing through it.
  fillBlack = 1
  ClearSlots
  IF INT(RND * 2) = 0 THEN
    ' One of the four groups, evenly.  The original packs each ship into
    ' three bytes, with the sign of x and the high byte of z sharing bits
    ' with the other two; these are the numbers that come out of it, and
    ' its own comments quote the same ones.
    SELECT CASE INT(RND * 4)
      CASE 0                                ' a Shuttle and a Transporter
        HangarShip T_SHUTTLE, -84, 315
        HangarShip T_TRANSPORT, 130, 432
      CASE 1                                ' three cargo canisters
        HangarShip T_CANISTER, -80, 273
        HangarShip T_CANISTER, 209, 552
        HangarShip T_CANISTER, 64, 262
      CASE 2                                ' a Viper and a Krait
        HangarShip T_VIPER, 96, 400
        HangarShip T_KRAIT, -16, 465
      CASE ELSE                             ' the same two, further off
        HangarShip T_VIPER, 81, 760
        HangarShip T_KRAIT, -96, 373
    END SELECT
  ELSE
    ' Or a Sidewinder, Mamba, Krait or Adder, anywhere on the deck.
    SELECT CASE INT(RND * 4)
      CASE 0    : t = T_SIDEWINDER
      CASE 1    : t = T_MAMBA
      CASE 2    : t = T_KRAIT
      CASE ELSE : t = T_ADDER
    END SELECT
    hx = INT(RND * 64)
    IF RND < 0.5 THEN hx = -hx
    hz = 256 + INT(RND * 2) * 256 + INT(RND * 256)
    HangarShip t, hx, hz
  ENDIF

  CLS
  HangarFloor
  DrawShips
  ' The border the original's screen-clearing routine draws, without the
  ' crosshairs, which belong to a view with a laser in it.
  LINE 0, 0, SCRW - 2, 0, 1, cWhite
  BOX 0, 0, 2, VIEWH, 0, cWhite, cWhite
  BOX SCRW - 2, 0, 2, VIEWH, 0, cWhite, cWhite
  FRAMEBUFFER COPY F, N

  HangarHold
  ClearSlots
  fillBlack = 0
END SUB

' The original holds the hangar for 44/50 of a second and then puts up the
' status screen.  A key gets there sooner; the demo, which is showing the
' thing off rather than playing it, gets longer to look at it.
SUB HangarHold
  LOCAL INTEGER k
  LOCAL FLOAT t
  LOCAL kb$ LENGTH 2
  IF demoMode THEN
    k = DemoHold(HANGDEMO, 0)
    EXIT SUB
  ENDIF
  t = TIMER + HANGWAIT
  DO
    kb$ = INKEY$
    IF kb$ <> "" THEN EXIT SUB
  LOOP UNTIL TIMER > t
END SUB

' One ship on the deck, flat, facing anywhere.
SUB HangarShip(t AS INTEGER, x AS INTEGER, z AS INTEGER)
  LOCAL INTEGER n, h
  h = (100 - INT(SQR(bArea(tBp(t))))) \ 2
  IF h < 0 THEN h = 0
  n = NewFacing(t, x, -h, z, INT(RND * 360))
  IF n >= 0 THEN sSpd(n) = 0
END SUB

SUB HangarFloor
  LOCAL INTEGER q, y, x, horiz
  horiz = VCY + 130 \ 12
  FOR q = 2 TO 12
    y = VCY + 130 \ q
    LINE 2, y, SCRW - 3, y, 1, cRed
  NEXT q
  FOR x = 16 TO SCRW - 16 STEP 16
    LINE x, 1, x, horiz, 1, cRed
  NEXT x
END SUB
