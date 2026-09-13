# Twice the program space: a library plus a program

A PicoMite keeps BASIC in two separate flash areas, each `MAX_PROG_SIZE`
bytes. One is program memory. The other is the library. On this firmware
(PicoMiteHDMIWEB) `MAX_PROG_SIZE` is `HEAP_MEMORY_SIZE`, **144 KB**, so one
program can never be more than 144 KB - but a program with a library behind it
can be a good deal more than that, and the library costs the program nothing.

This directory proves it on real hardware. Nothing here is simulated: every
figure below was read back off a PC3 with the `MEMORY` command.

## What it measures

    program 138 K + library 132 K = 270 K of BASIC in one program

against a 144 KB ceiling for a program on its own. The bulk halves are
generated code - real subroutines that compute and real DATA that is read
back - and the program adds up a checksum at the end that the test compares
against a figure worked out independently in Python. It matches, so all 270 KB
is live, not merely resident.

## Running it

    set PC3_PORT=COM17
    python runtest.py                  the correctness test, about a minute
    python runtest.py --bulk           that, then fill both halves
    python runtest.py --bulk-only --kb=132

`runtest.py` drives the board over the serial console using `elite_tools/pc3.py`.
It leaves the library installed and slot 1 holding a copy of the program;
`LIBRARY DELETE` and `FLASH ERASE 1` put things back.

## The files

| | |
|---|---|
| `lib.bas` | the library half: CONSTs, globals, SUBs, FUNCTIONs, DATA |
| `main.bas` | a program that uses all of it and prints a checksum |
| `chain_boot.bas` | the overlay launcher: owns every global and constant |
| `chain_a.bas`, `chain_b.bas` | two overlays that share its state |
| `regress_fileload.bas` | the RAM FILE LOAD bug, kept as a regression test |
| `gen_bulk.py` | generates `biglib.bas` / `bigmain.bas` for the size proof |
| `runtest.py` | drives the board and reports pass or fail |

## What the test proves, item by item

- **Top level statements in a library run at RUN**, before the main program's
  first line. So `CONST` and `DIM` belong in the library - which is the whole
  game for a program like Elite, where the constants and globals are a big
  block that has to come first.
- **SUBs and FUNCTIONs in the library are callable** from the program.
- **DATA in the library is readable from the program**, by `RESTORE` on a label
  that is also in the library. Labels, subs and functions all live in one
  table shared between the two halves.
- **A library SUB can call back into a SUB the program defines.** One table,
  both ways.
- **The library survives everything the program does.** `NEW`, `FLASH SAVE`,
  `FLASH LOAD` and power-off all leave it alone; only `LIBRARY SAVE` and
  `LIBRARY DELETE` change it.
- **`FLASH SAVE` / `FLASH LOAD` snapshot the program only.** So the pattern is:
  write the library once, then snapshot and restore programs against it.

## The rules, and what goes wrong if you break them

- **No `END` in a library.** The interpreter runs the whole library at `RUN`;
  an `END` would stop the run before the program's first line.
- **The library runs first**, so it cannot use anything the program defines at
  its top level. Keep it self-contained.
- **One name table for both halves.** `MAXSUBFUN` is 512 on this firmware, and
  it counts every SUB, every FUNCTION *and every label* across the program and
  the library together. That is why the bulk filler is a few long routines
  rather than many short ones.
- **Names are unique irrespective of case and of type suffix.** `CONST LIBSQ`
  and `DIM FLOAT libSq()` are the same name, and the error - `LIBSQ already
  declared`, reported against the `DIM` line - does not say so. This test hit
  it on the first run.
- **Errors in library code are prefixed `[LIBRARY]`**, which is how you tell
  which half a failure is in.
- **The library takes flash slot 3.** `FLASH LIST` shows `Slot 3 in use:
  Library`, and `FLASH SAVE 3` answers `Error : Library is using Slot 3`.
  Slots 1 and 2 are still yours.
- **`LIBRARY SAVE` crunches on the way in**, stripping comments, blank lines
  and runs of spaces exactly as `AUTOSAVE C` does. Comments in a library source
  are free.

## The one real limit, and it is not the library

The library is allowed the same 144 KB as program memory. What runs out first
is the route in: **`LOAD` needs a little more room than the source file itself**,
so a 144 KB file answers `Error : Not enough memory` and leaves program memory
empty - and since `LIBRARY SAVE` works on whatever is in program memory, there
is then nothing to save. In this test a 138 KB source went in and a 144 KB one
did not.

That is a limit on the source text, not on the code. Crunch on the way in -
`AUTOSAVE C`, or `LOAD fname$, C` on 6.03.02b4 and later - and a source with
comments in it will go a good deal further, because what has to fit is the
crunched size.

## What this means for the Elite port

Elite is currently 95 KB in one program, of a 144 KB ceiling, and the ceiling
is the reason the disc version's extra ships and the extended token table have
been left out. Moving the parts that never change into a library - the ship
blueprints in `data/ships.bas`, the constants and globals of `00_main.bas`, and
the modules that are pure subroutines - would leave the whole 144 KB of program
memory for the game, and the library has room for around 130 KB more.

## Part two: overlays, and the seam between them

`chain_boot.bas`, `chain_a.bas` and `chain_b.bas` prove the other half of the
architecture. `RAM CHAIN n` and `FLASH CHAIN n` switch which program is running
**without clearing the variables** - there is no `ClearRuntime` on the CHAIN
path, only on `RUN` - so a set of overlays can share one state.

Measured, chaining boot -> A -> B -> A -> B -> boot:

    trail    1 11 21 12 22 1
    visits   2
    acc      214

Every global, array and string survived every hop, and the launcher survived
being chained back into.

### What is shared and what is not

- **Variables are shared.** Scalars, arrays and strings all carry across. This
  is the point of CHAIN.
- **Code is not.** Every CHAIN re-prepares the subroutine table from the
  program it has switched to. `chain_b.bas` calls `OnlyInA`, a SUB that exists
  only in the other overlay, and gets `Unknown command`. So the seam has to be
  a state machine - one CHAIN per screen transition - not a call.
- **Names are per overlay.** A and B each define their own `Trail` and `Work`,
  and each gets its own. The 512-name table is per prepared program, so
  overlays multiply it.
- **Exactly one program declares.** A `DIM` or a `CONST` that runs twice is an
  error, and a launcher can be chained back into, so the launcher owns every
  global and every constant and no overlay redeclares anything. The guard is
  `IF bootDone THEN GOTO reentry` over the `DIM` block, where `bootDone` is
  never itself DIMmed - it is auto-created as zero the first time.

### How much space that buys

| | slots | each | total |
|---|---|---|---|
| program memory | 1 | 144 K | 144 K |
| flash slots | 3 | 144 K | 432 K |
| PSRAM slots | 5 | 144 K | 720 K |

Flash slots survive power-off; PSRAM slots do not, but `RAM FILE LOAD n,
"file.bas"` tokenises a `.bas` straight off the card into a slot at boot, which
makes them the cheapest to deploy and the easiest to update.

### The bug in `RAM FILE LOAD` - found here, fixed in the firmware

`RAM FILE LOAD` is meant to be used from inside a running program: that is how
a launcher loads the overlays it is about to chain to. But `MemLoadProgram()`
calls `ClearRuntime()`, which NULLs the whole of `subfun[]`, and the
`SaveContext()` / `RestoreContext()` pair around it carries the variables and
the heap **but not the subroutine, function and label tables**. So the program
being handed control back had no idea where its own SUBs were, and its next
call to one of them found a null definition pointer and died with
`Error : Inconsistent type suffix` - an error that names a type suffix, points
at the call site, and is neither.

Bisected from a working program: a SUB call *before* the load works, the
identical call *after* it fails. `regress_fileload.bas` is that program, kept
as a regression test.

Fixed in `misc/FileIO.c` by re-preparing the current program after the restore
when there is one to return to. Verified on a PC3 running 6.03.02b4.

The rule the bug taught is still worth following, because it costs nothing:
**a loader should do its loading last and chain straight out of it.**
`chain_boot.bas` is written that way.

## The ceiling nobody expects: 480 global slots

Program memory is not the first thing to run out. There are **480 global
variable slots**, and a `CONST` costs exactly one, the same as a `DIM` -
measured on the board, both probes stopped at 478. Chaining does **not** relieve
this, because the whole point is that globals are shared.

Elite as it stands uses 230 DIMmed globals and 144 constants: **374 of 480**,
with 91 K of 144 K program memory used. The global table is 78% full and the
program memory 63% full, so on the present course the table runs out first.

What relieves it: inlining constants at build time (the source keeps readable
names, the built program gets literals, and 144 slots come back in one move),
and folding groups of related globals into arrays.
