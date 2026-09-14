' =====================================================================
'  Ship blueprints, the universe slot table, and the Draw3D object pool
' =====================================================================

' Read every blueprint once: the header statistics, and the mesh (which
' we throw away again) so we can record each ship's size.  Slow, but it
' happens once at start up and it means nothing else has to guess.
SUB LoadStats
  LOCAL INTEGER b
  FOR b = 0 TO NBP - 1
    LoadMesh b
  NEXT b
  tBp(1) = 0 : tBp(2) = 1 : tBp(3) = 2 : tBp(4) = 3 : tBp(5) = 4
  tBp(6) = 5 : tBp(7) = 4 : tBp(8) = 6 : tBp(9) = 7 : tBp(10) = 8
  tBp(11) = 9 : tBp(12) = 10 : tBp(13) = 11 : tBp(T_COUGAR) = 12
  tBp(T_KRAIT) = 13 : tBp(T_ADDER) = 14 : tBp(T_GECKO) = 15
  tBp(T_COBRA1) = 16 : tBp(T_WORM) = 17 : tBp(T_ASP) = 18
  tBp(T_FERDELANCE) = 19 : tBp(T_BOA) = 20 : tBp(T_ANACONDA) = 21
  tBp(T_BOULDER) = 22 : tBp(T_SPLINTER) = 23 : tBp(T_HERMIT) = 24
  tBp(T_SHUTTLE) = 25 : tBp(T_TRANSPORT) = 26
  tBp(T_CONSTRICT) = 28 : tBp(T_PYTHONP) = 3
  NewbTable
END SUB

' The original's E%: what each kind of ship is, before the spawner says
' anything about the particular one it is making.
'
' The two ships that fly on both sides of the law have an entry each way, as
' they do in the original: T_TRADER and T_PYTHON are the honest ones,
' T_COBRA3 and T_PYTHONP the pirates.
SUB NewbTable
  LOCAL INTEGER i
  FOR i = 0 TO NTYPE : tNewb(i) = 0 : NEXT i
  tNewb(T_ESCAPE) = NB_TRADER
  tNewb(T_SHUTTLE) = NB_TRADER OR NB_INNOCENT
  tNewb(T_TRANSPORT) = NB_TRADER OR NB_INNOCENT OR NB_COP
  tNewb(T_COBRA3) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_TRADER) = NB_INNOCENT OR NB_POD
  tNewb(T_PYTHON) = NB_INNOCENT OR NB_POD
  tNewb(T_PYTHONP) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_BOA) = NB_INNOCENT OR NB_POD
  tNewb(T_ANACONDA) = NB_TRADER OR NB_INNOCENT OR NB_POD
  tNewb(T_HERMIT) = NB_TRADER OR NB_INNOCENT OR NB_POD
  tNewb(T_VIPER) = NB_HUNTER OR NB_COP OR NB_POD
  tNewb(T_SIDEWINDER) = NB_HOSTILE OR NB_PIRATE
  tNewb(T_MAMBA) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_KRAIT) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_ADDER) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_GECKO) = NB_HOSTILE OR NB_PIRATE
  tNewb(T_COBRA1) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_WORM) = NB_HOSTILE OR NB_TRADER
  tNewb(T_ASP) = NB_HOSTILE OR NB_PIRATE OR NB_POD
  tNewb(T_FERDELANCE) = NB_HUNTER OR NB_POD
  tNewb(T_THARGOID) = NB_HOSTILE OR NB_PIRATE
  tNewb(T_THARGON) = NB_HOSTILE
  tNewb(T_CONSTRICT) = NB_HOSTILE
  tNewb(T_COUGAR) = NB_INNOCENT
END SUB

' Load blueprint b into the scratch mesh buffers and fill in its stats.
' The DATA layout is fixed by elite_tools/blueprints.py:
'   name, nv, nf, nfv, nf0, nv0, canisters, area, bounty, visdist,
'   energy, speed, laser, missiles, gun vertex, explosion count
'   then nv vertices, nf face vertex counts, nf host faces,
'   nf0 stored normals, nfv face vertex indices.
SUB LoadMesh(b AS INTEGER)
  LOCAL INTEGER j, k
  SELECT CASE b
    CASE 0  : RESTORE dat_sidewinder
    CASE 1  : RESTORE dat_viper
    CASE 2  : RESTORE dat_mamba
    CASE 3  : RESTORE dat_python
    CASE 4  : RESTORE dat_cobra_mk_3
    CASE 5  : RESTORE dat_thargoid
    CASE 6  : RESTORE dat_coriolis
    CASE 7  : RESTORE dat_missile
    CASE 8  : RESTORE dat_asteroid
    CASE 9  : RESTORE dat_canister
    CASE 10 : RESTORE dat_thargon
    CASE 11 : RESTORE dat_escape_pod
    CASE 12 : RESTORE dat_cougar
    CASE 13 : RESTORE dat_krait
    CASE 14 : RESTORE dat_adder
    CASE 15 : RESTORE dat_gecko
    CASE 16 : RESTORE dat_cobra_mk_1
    CASE 17 : RESTORE dat_worm
    CASE 18 : RESTORE dat_asp_mk_2
    CASE 19 : RESTORE dat_fer_de_lance
    CASE 20 : RESTORE dat_boa
    CASE 21 : RESTORE dat_anaconda
    CASE 22 : RESTORE dat_boulder
    CASE 23 : RESTORE dat_splinter
    CASE 24 : RESTORE dat_rock_hermit
    CASE 25 : RESTORE dat_shuttle
    CASE 26 : RESTORE dat_transporter
    CASE 27 : RESTORE dat_dodo
    CASE 28 : RESTORE dat_constrictor
  END SELECT
  READ bName$(b), bNv(b), bNf(b), bNfv(b), bNf0(b), bNv0(b)
  READ bCan(b), bArea(b), bBty(b), bVis(b), bEne(b), bSpd(b)
  READ bLas(b), bMis(b), bGun(b), bExp(b)
  FOR j = 0 TO bNv(b) - 1 : READ mV(0, j), mV(1, j), mV(2, j) : NEXT j
  FOR j = 0 TO bNf(b) - 1 : READ mFc(j) : NEXT j
  FOR j = 0 TO bNf(b) - 1 : READ mHost(j) : NEXT j
  FOR j = 0 TO bNf0(b) - 1 : READ mNrm(0, j), mNrm(1, j), mNrm(2, j) : NEXT j
  FOR j = 0 TO bNfv(b) - 1 : READ mF(j) : NEXT j
  ' Ships are white lines, as on the BBC; the fill colours only matter
  ' when faces are asked for, which is the station always and everything
  ' else only under the solid renderer.
  FOR j = 0 TO bNf(b) - 1
    mEc(j) = 0
    ' The hangar wants its ships filled as well, so the floor and the back
    ' wall stop at the hull instead of showing through it.
    IF b = BP_CORIOLIS OR b = BP_DODO OR fillBlack THEN
      mFl(j) = C_FILL
    ELSE
      mFl(j) = 1 + (mHost(j) MOD 6)
    ENDIF
  NEXT j
  bSize(b) = 0
  FOR j = 0 TO bNv0(b) - 1
    FOR k = 0 TO 2
      IF ABS(mV(k, j)) > bSize(b) THEN bSize(b) = ABS(mV(k, j))
    NEXT k
  NEXT j
END SUB

' ------------------------------------------------------- the slot table
SUB ClearSlots
  LOCAL INTEGER n
  CloseAll
  FOR n = 0 TO NSLOT - 1
    sTyp(n) = 0 : sObj(n) = 0
  NEXT n
  nUsed = 0
END SUB

' Create a ship of type t at x, y, z with orientation q (5 elements) and
' return its slot, or -1 if the bubble is full.  Slot 0 is reserved for
' the planet and slot 1 for the sun or the station, exactly as FRIN.
FUNCTION NewShip(t AS INTEGER, x AS FLOAT, y AS FLOAT, z AS FLOAT, q() AS FLOAT) AS INTEGER
  LOCAL INTEGER n, i, first
  first = 2
  IF t = T_PLANET OR t = T_CRATER THEN first = 0
  IF t = T_SUN OR t = T_STATION THEN first = 1
  n = -1
  IF first < 2 THEN
    IF sTyp(first) = 0 THEN n = first
  ELSE
    FOR i = 2 TO NSLOT - 1
      IF sTyp(i) = 0 THEN n = i : EXIT FOR
    NEXT i
  ENDIF
  NewShip = n
  IF n < 0 THEN EXIT FUNCTION

  sTyp(n) = t
  sX(n) = x : sY(n) = y : sZ(n) = z
  MATH INSERT sQ(), , n, q()
  sQ(4, n) = 1                      ' Draw3D scales by this squared
  sObj(n) = 0
  sSpd(n) = 0 : sAcc(n) = 0 : sRol(n) = 0 : sPit(n) = 0
  sFlg(n) = 0 : sAI(n) = 0
  ' What this ship is: the type's own flags, less the two that only mean
  ' something once it is flying, plus whatever the spawner staged for it.
  ' The planet and the sun are types 128 and up and are not ships at all,
  ' so they are not in the table and have nothing to be.
  sNewb(n) = 0
  IF t <= NTYPE THEN sNewb(n) = (tNewb(t) AND 111) OR newbFlags
  newbFlags = 0
  ' Every field the slot carries has to be cleared, not most of them.  A
  ' slot that last held something which blew up keeps its explosion
  ' counter, and the next ship to be given that slot is killed on its
  ' first frame - no cloud, no kill, just gone - which is exactly what
  ' the second ship in every fight used to do.
  sExp(n) = 0 : sTgt(n) = -1
  sMis(n) = 0
  IF t < T_PLANET THEN
    sBp(n) = tBp(t)
    sEne(n) = bEne(sBp(n))
    sMis(n) = bMis(sBp(n))
  ELSE
    sBp(n) = -1                     ' planet and sun are drawn by hand
    sEne(n) = 0
  ENDIF
  IF n >= nUsed THEN nUsed = n + 1
END FUNCTION

' A ship at x, y, z turned hdg degrees about the vertical.  180 faces us,
' which is how the original creates almost everything: its ZINF leaves a
' new ship's nose vector at (0, 0, -1), pointing back down the z axis at
' the player.
FUNCTION NewFacing(t AS INTEGER, x AS FLOAT, y AS FLOAT, z AS FLOAT, hdg AS INTEGER) AS INTEGER
  MATH Q_EULER RAD(hdg), 0, 0, qA() : qA(4) = 1
  NewFacing = NewShip(t, x, y, z, qA())
END FUNCTION

' Remove a slot.  The original shuffles the table down to close the gap
' so the loop over ships never sees a hole; we do the same, because the
' AI and the scanner both walk the table in order.
SUB KillShip(n AS INTEGER)
  LOCAL INTEGER i
  DropObject n
  IF n < 2 THEN
    ' The planet and the sun / station keep their reserved slots.
    sTyp(n) = 0 : sObj(n) = 0
    EXIT SUB
  ENDIF
  FOR i = n TO nUsed - 2
    CopySlot i, i + 1
  NEXT i
  sTyp(nUsed - 1) = 0
  sObj(nUsed - 1) = 0
  sExp(nUsed - 1) = 0
  sTgt(nUsed - 1) = -1
  nUsed = nUsed - 1
END SUB

SUB CopySlot(d AS INTEGER, s AS INTEGER)
  LOCAL INTEGER i
  sTyp(d) = sTyp(s) : sBp(d) = sBp(s) : sObj(d) = sObj(s)
  sX(d) = sX(s) : sY(d) = sY(s) : sZ(d) = sZ(s)
  MATH SLICE sQ(), , s, qA()
  MATH INSERT sQ(), , d, qA()
  sSpd(d) = sSpd(s) : sAcc(d) = sAcc(s)
  sRol(d) = sRol(s) : sPit(d) = sPit(s)
  sEne(d) = sEne(s) : sAI(d) = sAI(s) : sFlg(d) = sFlg(s)
  sExp(d) = sExp(s) : sTgt(d) = sTgt(s) : sMis(d) = sMis(s)
  IF sObj(d) > 0 THEN objOwn(sObj(d)) = d
  sTyp(s) = 0 : sObj(s) = 0
  sExp(s) = 0 : sTgt(s) = -1
END SUB

' ------------------------------------------------- Draw3D object pool
' A slot only needs an object while its ship is close enough to be drawn as a
' mesh, and there are fewer objects than slots: the firmware allows twelve and
' the bubble holds eighteen ships.  So the drawing pass asks for one when a
' ship comes into mesh range and gives it back when it leaves, rather than a
' ship taking one for life the moment it is created - which handed the twelve
' to whichever ships happened to arrive first and left a Cobra filling the
' screen drawn as a dash while a speck on the horizon held an object.
SUB GetObject(n AS INTEGER)
  LOCAL INTEGER o, b, faces, j, e
  IF sObj(n) > 0 THEN EXIT SUB
  FOR o = 1 TO maxObj
    IF objOwn(o) < 0 THEN
      b = sBp(n)
      LoadMesh b
      ' Draw3D bakes the colours into the object, so the ship's colour has
      ' to be chosen now rather than at drawing time.
      e = shpCol(sTyp(n))
      FOR j = 0 TO bNf(b) - 1 : mEc(j) = e : NEXT j
      faces = solidMode
      IF fillBlack THEN faces = 1
      IF STNSOLID THEN
        IF b = BP_CORIOLIS OR b = BP_DODO THEN faces = 1
      ENDIF
      ' The probe counts what fits in an empty heap, and by the time a ship
      ' wants an object the title screen's picture has been and gone and the
      ' bubble is full.  So the create is allowed to fail: this ship keeps
      ' its dash for now and the cap comes down to what the machine really
      ' has, rather than the program stopping with a heap error.
      IF faces THEN
        ON ERROR SKIP 1
        Draw3D CREATE o, bNv(b), bNf(b), 1, mV(), mFc(), mF(), col(), mEc(), mFl()
      ELSE
        ON ERROR SKIP 1
        Draw3D CREATE o, bNv(b), bNf(b), 1, mV(), mFc(), mF(), col(), mEc()
      ENDIF
      IF MM.ERRNO <> 0 THEN
        ON ERROR CLEAR
        maxObj = o - 1
        EXIT SUB
      ENDIF
      objOwn(o) = n
      sObj(n) = o
      EXIT SUB
    ENDIF
  NEXT o
END SUB

SUB DropObject(n AS INTEGER)
  IF sObj(n) <= 0 THEN EXIT SUB
  Draw3D CLOSE sObj(n)
  objOwn(sObj(n)) = -1
  sObj(n) = 0
END SUB

' ----------------------------------------------------- view transform
' Front leaves the universe alone; rear turns it through 180 degrees
' about the vertical axis; left and right through plus and minus 90.
' Written out rather than done with a quaternion because it runs for
' every slot every frame.
SUB ViewXform(n AS INTEGER)
  SELECT CASE vw
    CASE 0 : tx = sX(n)  : ty = sY(n) : tz = sZ(n)
    CASE 1 : tx = -sX(n) : ty = sY(n) : tz = -sZ(n)
    CASE 2 : tx = sZ(n)  : ty = sY(n) : tz = -sX(n)
    CASE 3 : tx = -sZ(n) : ty = sY(n) : tz = sX(n)
  END SELECT
END SUB

' The ship's orientation seen from the current view.  Leaves the result
' in qC() ready for Draw3D ROTATE.
' MATH SLICE lifts one ship's quaternion out of the 5 x NSLOT table in a
' single call, and a whole-array assignment copies one in a single memcpy;
' both replace five interpreted statements, which is what this costs when
' it runs for every ship every frame.
SUB ViewOrient(n AS INTEGER)
  MATH SLICE sQ(), , n, qA()
  IF vw = 0 THEN
    qC() = qA()
  ELSE
    MATH SLICE vwQ(), , vw, qB()
    MATH Q_MULT qB(), qA(), qC()
  ENDIF
  qC(4) = 1
END SUB
