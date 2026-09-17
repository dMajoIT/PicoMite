**Beta for testing.** This is the release after b7 — b8 was an interim build
and was never published, so everything below has accumulated since b7. Please
try it on programs you already have and report anything that behaves
differently; that is the most useful testing there is.

## New: turn a slow SUB into a CSUB, without writing any C

Every PicoMite program has one routine doing the real work, and most of the
time the interpreter spends there goes on *reading* the code rather than
running it. `mmb2csub` compiles that routine to machine code and puts it back
into your program as a CSUB:

```
python mmb2csub.py myprogram.bas PlotJulia
```

That rewrites your program: the original routine is commented out, the CSUB is
appended, and **your call sites do not change** — MMBasic calls a CSUB exactly
as it calls a SUB. The Julia set demo included with the tool renders in 5.9
seconds instead of 119 on an RP2040, and 2.5 instead of 86 on an RP2350 — 20x
and 35x — and draws a byte-identical image either way.

**How it works.** The translation from MMBasic to C is done by `mmb2c.py`, a
complete MMBasic-to-C translator — the same one that, converted to C, runs as
a native application under the Fuzix port. It already understood MMBasic's
scope rules, string semantics and array layouts, which is the hard part. What
`mmb2csub` adds is the other half: a driver that picks one routine out of your
program and works out what it needs, and a runtime that maps the translated C
onto the firmware's *own* routines through the CallTable.

That second part is what makes the result trustworthy. `SIN`, `MID$`, `STR$`,
`RGB` and the drawing commands inside a CSUB call the same firmware code the
interpreter calls, so a converted routine cannot quietly disagree with the
original about what `MID$` means — and the compiled blob stays small, because
none of it is duplicated.

**One converted program runs on every PicoMite.** The same file — same bytes —
works on the RP2040 and the RP2350 and on every firmware variant, because the
code is built for the Cortex-M0+, is position-independent, and finds the
firmware's routines through a table it locates at run time rather than an
address fixed when it was compiled. Tested both ways round: byte-identical
output from one file on a PicoMiteVGA (RP2040) and a PicoMiteHDMIWEB
(RP2350B). So a converted program can be posted or shipped exactly like any
other `.bas`.

**What to expect.** Loops, array work and arithmetic run 10–35x faster.
Routines that mostly call the firmware already — graphics, `SIN`, string
formatting — gain much less, because only the interpreting overhead goes away.
The tool tells you which yours is before you commit to anything: `--list`
compiles and links every routine in your program and reports what each would
cost, without changing a thing.

It is also honest about what it cannot do. Anything unsupported is refused by
name, before anything is written, rather than producing a CSUB that is subtly
wrong.

**Getting it:** `mmb2csub-6.03.02b9.zip`, attached to this release. It needs
Python, the Arm GNU toolchain (`arm-none-eabi-gcc`) — the same compiler used
to build the firmware — and one Python package (`pip install pyelftools`). The
manual inside covers setting both up on Windows and Linux, and the recommended
workflow.

## New: a HELP file for the console

Three text files are attached, all generated from the user manual and covering
the same 872 topics. Copy whichever suits onto the A: drive as `help.txt`:

| file | size | what is in it |
|---|---|---|
| `help.txt` | 416 KB | the full entry: syntax, description, everything |
| `helpmin.txt` | 196 KB | syntax and a one-line summary |
| `helptiny.txt` | 83 KB | the syntax lines alone |

The smallest is for boards where the drive is tight but you still want the
argument order to hand.

## New: FLASH ERASE from inside a running program

It previously had to be typed at the prompt, which made a program that manages
its own flash slots impossible to write.

## Fixed

- **RP2040 boot loop.** Certain RP2040 builds could restart continuously
  instead of booting. littlefs's lookahead buffer lost its word alignment when
  `FileIO.c` was compiled for size, and the first block allocation faulted
  during the boot-time mount of A:. This is the important one on this release
  if you have ever seen a board cycle at power-on.
- **`SAVE IMAGE`** now writes the colours the screen is actually showing.
- **`OPTION DISK SAVE`** no longer drops the platform name or the telnet
  console mode from the saved options.
- **`MM.VER`** read past the end of the version string on a release build.

## For anyone building from source

- `buildpicomite.bat` reported success even when a variant had failed. Its
  `endlocal` discarded the exit code before `exit /b` read it, so every failed
  build exited 0. Fixed; a failing variant now stops the script.
- The flash/RAM/heap fit checks run *before* the `.uf2` is copied into `uf2/`,
  so a variant that fails them leaves the previous good image in place rather
  than deleting it for one that never arrives. They also gained a fourth
  check, for the alignment that caused the boot loop above.
- The CallTable has nineteen new entries — 64-bit arithmetic helpers,
  `memcpy`/`memset`/`memmove`, the MMBasic string routines, and the current
  `COLOUR`. They are appended, so existing CSUBs are unaffected. Documented in
  `docs/armcfgen.md`, which is also attached as a PDF inside the zip.
- A CSUB may now take sixteen arguments on the RP2350 (ten on the RP2040, as
  before).
