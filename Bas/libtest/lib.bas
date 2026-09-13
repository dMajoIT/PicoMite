' =====================================================================
'  libtest: the library half
'
'  LIBRARY SAVE takes whatever is in program memory and writes it to the
'  library flash area, then clears program memory.  From then on every
'  program sees what is in here, and none of it costs a byte of the
'  program's own space.
'
'  Four things are being proved:
'
'    1  Top level statements in a library run at RUN, before the main
'       program's first line, so CONST and DIM can live here.
'    2  SUBs and FUNCTIONs here are callable from the main program.
'    3  DATA here, and the labels that name it, are readable from the
'       main program with RESTORE.
'    4  The two halves share one table of subroutines, so a library SUB
'       can call back into a SUB the main program defines.
'
'  Two rules.  There must be no END in a library - the interpreter runs
'  the whole of it at RUN and an END would stop the run before the main
'  program started.  And the library cannot use anything the main program
'  defines at its top level, because it runs first.
'
'  Comments here cost nothing: LIBRARY SAVE strips them, along with blank
'  lines and runs of spaces, exactly as AUTOSAVE C does.
' =====================================================================

CONST LIBTAG$ = "libtest"
CONST LIBVER = 103
CONST LIBSQN = 16

DIM INTEGER libReady, libCalls
DIM FLOAT libSq(LIBSQN - 1)
DIM libShip$(2) LENGTH 12

LibInit                          ' runs at RUN, before the program's first line

SUB LibInit
  LOCAL INTEGER i
  FOR i = 0 TO LIBSQN - 1 : libSq(i) = i * i : NEXT i
  RESTORE dat_ships
  FOR i = 0 TO 2 : READ libShip$(i) : NEXT i
  libCalls = 0
  libReady = 1
END SUB

SUB LibBump(n AS INTEGER)
  libCalls = libCalls + n
END SUB

' A library FUNCTION calling a library SUB.
FUNCTION LibAdd(a AS INTEGER, b AS INTEGER) AS INTEGER
  LibBump 1
  LibAdd = a + b
END FUNCTION

FUNCTION LibShipName$(n AS INTEGER)
  LibShipName$ = libShip$(n)
END FUNCTION

' RESTORE and READ from inside the library itself.
FUNCTION LibTotal() AS INTEGER
  LOCAL INTEGER i, v, t
  RESTORE dat_numbers
  t = 0
  FOR i = 0 TO 9
    READ v
    t = t + v
  NEXT i
  LibTotal = t
END FUNCTION

' Calls a SUB that exists only in the main program.
SUB LibCallback(tag$)
  MainHook tag$
END SUB

dat_ships:
DATA "Cobra", "Viper", "Mamba"

dat_numbers:
DATA 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

dat_numbers2:
DATA 100, 200, 300
