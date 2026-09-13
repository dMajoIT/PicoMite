' =====================================================================
'  Mission briefings
'
'  The disc version's two missions are given to you on docking, as a
'  message from the Navy with a ship turning on the screen above it.  All
'  of the text is in the extended token table we already carry for the
'  system descriptions - the briefings are tokens 10, 11, 222 and 223 -
'  so nothing here writes any of it.  What this does is give the expander
'  somewhere to put a page of text instead of a single sentence, and
'  answer the control codes that only mean something on a page: clear the
'  screen, move to a row, tab to a column, break the line, show the ship,
'  wait for a key.
'
'  The four briefings are the only tokens in the table too long to hold in
'  one MMBasic string, so tokens.py generates them in parts and the
'  expander walks them one after another.
'
'  Departure: the original justifies the text, spreading each line to the
'  full width.  Ours is left aligned, which is what every other screen in
'  this port does.
' =====================================================================

' Clear the screen and start a page at the top.
SUB BriefPage
  CLS
  brLine$ = ""
  brWord$ = ""
  brY = BRTOP
  brCol = 0
  IF brShip >= 0 THEN DrawShips
  FRAMEBUFFER COPY F, N
END SUB

' Move to a row, counted in the original's eight pixel character rows.
SUB BriefRow(r AS INTEGER)
  BriefBreak
  brY = r * 8
END SUB

SUB BriefTab(c AS INTEGER)
  BriefBreak
  brCol = c
END SUB

' One character.  Words are held back until they are known to fit, which is
' what makes the line breaks fall between words.
SUB BriefPut(ch$)
  IF ch$ = " " THEN
    BriefWord
  ELSE
    IF LEN(brWord$) < 30 THEN brWord$ = brWord$ + ch$
  ENDIF
END SUB

' Place the word that has been building on the line, taking a new line if it
' will not fit on this one.
SUB BriefWord
  IF brWord$ = "" THEN EXIT SUB
  IF brLine$ = "" THEN
    brLine$ = brWord$
  ELSEIF LEN(brLine$) + 1 + LEN(brWord$) > BRWIDE - brCol THEN
    BriefFlush
    brLine$ = brWord$
  ELSE
    brLine$ = brLine$ + " " + brWord$
  ENDIF
  brWord$ = ""
END SUB

' End the line wherever it has got to: a carriage return, or a change of
' row or column.
SUB BriefBreak
  BriefWord
  BriefFlush
END SUB

SUB BriefFlush
  IF brLine$ = "" THEN EXIT SUB
  TEXT BRLEFT + brCol * 6, brY, brLine$, "LT", 7, 1, cWhite
  brY = brY + BRROW
  brLine$ = ""
  FRAMEBUFFER COPY F, N
END SUB

' "INCOMING MESSAGE", for two seconds, which is how every briefing opens.
SUB BriefIncoming
  CLS
  TEXT VCX, 80, "INCOMING MESSAGE", "CT", 7, 1, cWhite
  FRAMEBUFFER COPY F, N
  HoldFor 2000
  BriefPage
END SUB

' Show the ship turning, and wait for a key.  The original does the same
' thing twice in the middle of the first briefing, which is what gives it
' its pace.
SUB BriefShip
  LOCAL INTEGER k
  BriefBreak
  IF brShip < 0 THEN BriefWait : EXIT SUB
  ' The fixtures have nobody at the keyboard, so they photograph the page
  ' and move on instead of waiting for one.
  IF DEMOFRAMES > 0 THEN
    FOR k = 1 TO 40 : BriefSpin : NEXT k
    BriefShot
    EXIT SUB
  ENDIF
  DO
    BriefSpin
    k = INKEY$ <> ""
  LOOP UNTIL k
END SUB

' One frame of the ship turning on the spot, with whatever text is already
' on the page left where it is.
SUB BriefSpin
  IF brShip < 0 THEN EXIT SUB
  sRol(brShip) = 127
  sPit(brShip) = 127
  MoveShips
  DrawShips
  FRAMEBUFFER COPY F, N
END SUB

SUB BriefWait
  IF DEMOFRAMES > 0 THEN BriefShot : EXIT SUB
  DO WHILE INKEY$ <> "" : LOOP
  DO WHILE INKEY$ = "" : LOOP
END SUB

' What a fixture does instead of waiting: keep the page.
SUB BriefShot
  shotNo = shotNo + 1
  SAVE IMAGE "A:/brief" + STR$(shotNo) + ".bmp"
  HoldFor 400
END SUB

' A briefing, start to finish: the message, the ship flying in, and then the
' token, which lays itself out with the control codes above.
SUB MissionBrief(tok AS INTEGER, t AS INTEGER)
  LOCAL INTEGER i
  ClearSlots
  brShip = -1
  dtSink = 1
  dtStd = 0
  dtCase = DT_CAPS
  dtCapNext = 0
  dtInWord = 0
  BriefIncoming
  IF t > 0 THEN
    ' The ship turns in the top third of the screen while the briefing is
    ' read underneath it.
    MATH Q_EULER 0, 0, 0, qA() : qA(4) = 1
    brShip = NewShip(t, 0, 80, 384, qA())
    IF brShip >= 0 THEN
      sSpd(brShip) = 0
      sAI(brShip) = 0
      FOR i = 1 TO 64
        BriefSpin
      NEXT i
    ENDIF
  ENDIF
  brY = BRTOP
  brCol = 0
  brLine$ = ""
  brWord$ = ""
  ExpandTok tok
  BriefBreak
  BriefWait
  dtSink = 0
  brShip = -1
  ClearSlots
END SUB
