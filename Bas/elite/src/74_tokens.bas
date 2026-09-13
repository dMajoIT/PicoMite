' =====================================================================
'  System descriptions, from the disc version's extended token table
'
'  The cassette game's data screen stops at the planet's radius.  The disc
'  version adds a paragraph - "Lave is most famous for its vast rain
'  forests and the Lave tree grub" - and this builds it the way the
'  original does.
'
'  A description is extended token 5, which reads
'
'     {lower case}{justify}{single cap}[18?] IS [19?].{cr}{left align}
'
'  where [n] is another token, [n?] is one of five chosen at random, and
'  {n} is a control code.  Expanding it recursively gives the sentence.
'
'  The randomness is not random.  Before expanding, the generator is seeded
'  from the system's own s1 and s2, so a system always reads the same - which
'  is why everyone who played this remembers Lave's rain forests.  DORND
'  below is the original's own generator, byte for byte, because anything
'  else would give every system the wrong description.
'
'  Tokens, digrams and the random groups are all generated into
'  data/tokens.bas by elite_tools/tokens.py, straight from the 6502 source.
' =====================================================================

SUB LoadTokens
  LOCAL INTEGER i
  RESTORE dat_tokens
  FOR i = 0 TO 255 : READ tk$(i) : NEXT i
  RESTORE dat_digrams
  FOR i = 0 TO 31 : READ dg$(i) : NEXT i
  RESTORE dat_rndgroups
  FOR i = 0 TO 37 : READ rgBase(i) : NEXT i
END SUB

' The original's random number generator: a four byte state, a feeder
' sequence and a main one, and the byte it returns is the second.  Seeded
' from the system it is a fixed sequence, which is the whole point.
FUNCTION Dornd() AS INTEGER
  LOCAL INTEGER a, x, c
  a = rndS(0) * 2                      ' ROL A with the carry clear
  c = (a >> 8) AND 1                   ' and the bit that fell out of the top
  a = a AND 255
  x = a
  a = a + rndS(2) + c
  c = (a >> 8) AND 1
  rndS(0) = a AND 255
  rndS(2) = x
  a = rndS(1)
  x = a
  a = a + rndS(3) + c
  rndS(1) = a AND 255
  rndS(3) = x
  Dornd = rndS(1)
END FUNCTION

' One of five, each as likely as the others: count how many of 51, 102, 153
' and 204 the random byte reaches.  256 does not divide by five, and this is
' how the original spends the remainder.
FUNCTION RndPick() AS INTEGER
  LOCAL INTEGER r, n
  r = Dornd()
  n = 0
  IF r >= 51 THEN n = n + 1
  IF r >= 102 THEN n = n + 1
  IF r >= 153 THEN n = n + 1
  IF r >= 204 THEN n = n + 1
  RndPick = n
END FUNCTION

' Append one character, applying the case the control codes have asked for.
' The original does this with AND and OR masks over the whole string; the
' effect is the same.
SUB PutCh(c$)
  LOCAL ch$ LENGTH 1
  ch$ = c$
  ' The original's character set has no apostrophe and uses a backtick for one.
  IF ch$ = CHR$(96) THEN ch$ = CHR$(39)
  ' Two spaces in a row happen where one token ends with one and the next
  ' begins with one.  The original is in justified mode here and absorbs it
  ' while spreading the line; we are not, so drop it.
  IF ch$ = " " THEN
    IF LEN(descBuf$) = 0 THEN EXIT SUB
    IF RIGHT$(descBuf$, 1) = " " THEN EXIT SUB
  ENDIF
  IF ch$ >= "A" AND ch$ <= "Z" THEN
    IF dtCapNext THEN
      dtCapNext = 0
    ELSEIF dtLower THEN
      ch$ = LCASE$(ch$)
    ENDIF
  ENDIF
  IF LEN(descBuf$) < 250 THEN descBuf$ = descBuf$ + ch$
END SUB

' A name goes in as it stands.  The original switches to Sentence Case to
' print one, which comes to the same thing: a capital and then small
' letters, whatever case the rest of the sentence is being set in.
SUB PutName(s$)
  IF LEN(descBuf$) + LEN(s$) < 250 THEN descBuf$ = descBuf$ + s$
  dtCapNext = 0
END SUB

SUB PutStr(s$)
  LOCAL INTEGER i
  FOR i = 1 TO LEN(s$) : PutCh MID$(s$, i, 1) : NEXT i
END SUB

' The system's name with its first letter capital and the rest small, which
' is what the original's sentence case comes to for a name.
FUNCTION NameCap$()
  LOCAL nm$ LENGTH 10
  nm$ = SysName$()
  IF LEN(nm$) = 0 THEN NameCap$ = "" : EXIT FUNCTION
  NameCap$ = LEFT$(nm$, 1) + LCASE$(MID$(nm$, 2))
END FUNCTION

' And the same name as an adjective: drop a trailing vowel and add IAN, so
' Lave becomes Lavian and Zaonce becomes Zaoncian.
FUNCTION NameAdj$()
  LOCAL nm$ LENGTH 12
  LOCAL last$ LENGTH 1
  nm$ = NameCap$()
  IF LEN(nm$) = 0 THEN NameAdj$ = "" : EXIT FUNCTION
  last$ = UCASE$(RIGHT$(nm$, 1))
  IF INSTR("AEIOU", last$) > 0 THEN nm$ = LEFT$(nm$, LEN(nm$) - 1)
  NameAdj$ = nm$ + "ian"
END FUNCTION

' One to four random two-letter tokens, capitalised: this is where the made
' up words come from, the tree grubs and the mud weed.
SUB PutAlien
  LOCAL INTEGER n, i, k
  dtCapNext = 1
  n = Dornd() AND 3
  FOR i = 0 TO n
    k = (Dornd() AND 62) \ 2
    PutStr dg$(k)
  NEXT i
END SUB

SUB DoControl(n AS INTEGER)
  SELECT CASE n
    CASE 2  : dtLower = 1              ' sentence case
    CASE 3  : PutName NameCap$()       ' the system's name
    CASE 12 : PutCh " "                 ' a carriage return, which we wrap
    CASE 13 : dtLower = 1              ' lower case
    CASE 17 : PutName NameAdj$()       ' the name as an adjective
    CASE 18 : PutAlien                 ' a made up word
    CASE 19 : dtCapNext = 1            ' capitalise the next letter only
    CASE ELSE                          ' 14 justify, 15 left align: no matter here
  END SELECT
END SUB

' Walk a token and everything it names.  This is done with a stack of its
' own rather than by recursion, and the reason is MMBasic's: a DO loop is
' tracked on a stack of twenty, and a description nests eleven tokens deep -
' so a recursive version with a loop in it runs the interpreter out of DO
' loops and fails with "LOOP without a matching DO" instead of anything that
' points at the real trouble.  One loop, one explicit stack, no limit worth
' worrying about.
SUB ExpandTok(start AS INTEGER)
  LOCAL INTEGER sp, v, j, isRnd, p
  LOCAL t$ LENGTH 160
  LOCAL c$ LENGTH 1
  LOCAL m$ LENGTH 8
  sp = 0
  exTok(0) = start
  exPos(0) = 1
  DO
    t$ = tk$(exTok(sp))
    p = exPos(sp)
    IF p > LEN(t$) THEN
      sp = sp - 1                        ' this token is finished
      IF sp < 0 THEN EXIT DO
    ELSE
      c$ = MID$(t$, p, 1)
      IF c$ = "[" THEN
        j = INSTR(p, t$, "]")
        m$ = MID$(t$, p + 1, j - p - 1)
        isRnd = 0
        IF RIGHT$(m$, 1) = "?" THEN
          isRnd = 1
          m$ = LEFT$(m$, LEN(m$) - 1)
        ENDIF
        v = VAL(m$)
        exPos(sp) = j + 1                ' step the parent past the marker
        IF isRnd THEN v = rgBase(v) + RndPick()
        IF sp < EXDEPTH AND v >= 0 AND v <= 255 THEN
          sp = sp + 1
          exTok(sp) = v
          exPos(sp) = 1
        ENDIF
      ELSEIF c$ = "{" THEN
        j = INSTR(p, t$, "}")
        DoControl VAL(MID$(t$, p + 1, j - p - 1))
        exPos(sp) = j + 1
      ELSE
        PutCh c$
        exPos(sp) = p + 1
      ENDIF
    ENDIF
  LOOP
END SUB

' The whole description for the system the charts are pointing at.
FUNCTION SysDesc$()
  rndS(0) = gs1 AND 255
  rndS(1) = (gs1 >> 8) AND 255
  rndS(2) = gs2 AND 255
  rndS(3) = (gs2 >> 8) AND 255
  descBuf$ = ""
  dtLower = 0
  dtCapNext = 0
  ExpandTok 5
  SysDesc$ = descBuf$
END FUNCTION

' Lay the description out under the rest of the data, breaking it between
' words.  Returns the row after the last one written.
FUNCTION DrawDesc(y AS INTEGER, wide AS INTEGER) AS INTEGER
  LOCAL INTEGER i, yy
  LOCAL t$ LENGTH 255
  LOCAL ln$ LENGTH 50
  LOCAL w$ LENGTH 30
  t$ = SysDesc$() + " "
  ln$ = "" : w$ = "" : yy = y
  FOR i = 1 TO LEN(t$)
    IF MID$(t$, i, 1) = " " THEN
      IF LEN(ln$) + LEN(w$) + 1 > wide THEN
        TEXT 20, yy, ln$, "LT", 7, 1, cWhite
        yy = yy + 9
        ln$ = w$
      ELSEIF ln$ = "" THEN
        ln$ = w$
      ELSE
        ln$ = ln$ + " " + w$
      ENDIF
      w$ = ""
    ELSE
      IF LEN(w$) < 29 THEN w$ = w$ + MID$(t$, i, 1)
    ENDIF
  NEXT i
  IF ln$ <> "" THEN TEXT 20, yy, ln$, "LT", 7, 1, cWhite : yy = yy + 9
  DrawDesc = yy
END FUNCTION
