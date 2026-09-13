' =====================================================================
'  The two missions
'
'  The disc version gives you two jobs, and the whole of both of them is
'  four bits in one byte - the original calls it TP and so does the
'  comment on ours.  Everything else is a consequence of those bits: what
'  you are told when you dock, what is waiting for you in one particular
'  system, and what gets shot at you on the way to another.
'
'  Mission one.  Reach a combat rating of Competent with 256 kills to your
'  name, in one of the first two galaxies, and the Navy asks you to hunt
'  down a stolen Constrictor.  It is in the second galaxy at galactic
'  coordinates (144, 33), it has an E.C.M. and an aggression of 60 out of
'  63, and nothing but a military laser will scratch it - and then only at
'  a quarter of the damage it would do to anything else.  Five thousand
'  credits and 256 kill points for bringing it down.
'
'  Mission two.  In the third galaxy, once the first job is done and you
'  are most of the way from Dangerous to Deadly, Naval Intelligence wants
'  the Thargoids' defence plans carried from Ceerdi to Birera.  While you
'  have them aboard the Thargoids come after you - one spawning pass in
'  five - and delivering them earns an energy unit that recharges half as
'  fast again as the one the shops sell.
'
'  The checks below are the original's DOENTRY, in its own order: what
'  happens when you dock depends on which of the four bits are set, and
'  only one thing can happen at a time.
' =====================================================================

' The second galaxy at (144, 33), settled when the bubble was built.
FUNCTION ConstrictorHere() AS INTEGER
  ConstrictorHere = conHere
END FUNCTION

' The system we are docked at, by the original's own coordinates.
FUNCTION AtSystem(x AS INTEGER, y AS INTEGER) AS INTEGER
  AtSystem = 0
  IF sysX = x AND sysYr = y THEN AtSystem = 1
END FUNCTION

' Called once, on docking, after the hangar.  At most one of these happens.
'
' The system variables are left pointing wherever the chart cursor last went,
' so they are put back on the system we are actually sitting in first - the
' same thing the equipment shop does before it asks what this world sells.
SUB MissionCheck
  LOCAL INTEGER m
  GotoSystem gGal, homeSys
  SysData
  m = mission AND 3
  IF m = 0 THEN
    ' Not started.  The Navy only approaches a commander who has killed 256
    ' things, and only in the first two galaxies.
    IF kills >= 256 AND gGal <= 2 THEN
      mission = mission OR MI_1RUN
      MissionBrief 10, T_CONSTRICT
    ENDIF
    EXIT SUB
  ENDIF
  IF m = 3 THEN
    ' In progress and completed at the same time means it was completed since
    ' the last time we docked.
    mission = mission AND (255 - MI_1RUN)
    kills = kills + 256
    cashTenths = cashTenths + 50000
    MissionBrief 15, 0
    EXIT SUB
  ENDIF
  IF m <> 2 THEN EXIT SUB
  ' Mission one is done and put away, so mission two is what is left - and
  ' only in the third galaxy.
  IF gGal <> 3 THEN EXIT SUB
  m = mission AND 15
  IF m = MI_1DONE THEN
    IF kills >= 1280 THEN
      mission = mission OR MI_2RUN
      MissionBrief 11, 0
    ENDIF
  ELSEIF m = (MI_1DONE OR MI_2RUN) THEN
    IF AtSystem(215, 84) THEN
      ' Ceerdi, where the plans are handed over.
      mission = (mission AND 240) OR MI_1DONE OR MI_2PLANS
      MissionBrief 222, 0
    ENDIF
  ELSEIF m = (MI_1DONE OR MI_2PLANS) THEN
    IF AtSystem(63, 72) THEN
      ' Birera, where they are handed on.
      mission = mission OR MI_2RUN
      energyUnit = 2
      MissionBrief 223, 0
    ENDIF
  ENDIF
END SUB

' Are the Thargoids hunting us?  Only while the plans are aboard, which is
' bit 3 set and bit 2 clear.
FUNCTION CarryingPlans() AS INTEGER
  CarryingPlans = 0
  IF (mission AND (MI_2RUN OR MI_2PLANS)) = MI_2PLANS THEN CarryingPlans = 1
END FUNCTION

' Should a Constrictor be put in this bubble?  Only in its own system, only
' while the job is on, and only one at a time.
FUNCTION WantConstrictor() AS INTEGER
  WantConstrictor = 0
  IF ConstrictorHere() = 0 THEN EXIT FUNCTION
  IF (mission AND MI_1RUN) = 0 THEN EXIT FUNCTION
  IF (mission AND MI_1DONE) <> 0 THEN EXIT FUNCTION
  IF CountType(T_CONSTRICT) > 0 THEN EXIT FUNCTION
  WantConstrictor = 1
END FUNCTION
