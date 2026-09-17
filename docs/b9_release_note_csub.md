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
seconds instead of 119 on an RP2040, and 2.5 instead of 86 on an RP2350 - 20x
and 35x - and draws a byte-identical image either way.

**The heavy lifting is not ours.** The MMBasic-to-C translation is done by
`mmb2c.py`, Alan Cox's MMBasic translator from the Fuzix project — a far more
complete piece of work than we could have justified writing, and it already
understood MMBasic's scope rules, string semantics and array layouts. What has
been added here is the other half: a driver that picks one routine out of your
program and works out what it needs, and a runtime that maps the translated C
onto the firmware's *own* routines through the CallTable.

That second part is what makes the result trustworthy. `SIN`, `MID$`, `STR$`,
`RGB` and the drawing commands inside a CSUB call the same firmware code the
interpreter calls, so a converted routine cannot quietly disagree with the
original about what `MID$` means — and the compiled blob stays small, because
none of it is duplicated.

**One converted program runs on every PicoMite.** The same file — same bytes
— works on the RP2040 and the RP2350 and on every firmware variant, because
the code is built for the Cortex-M0+, is position-independent, and finds the
firmware's routines through a table it locates at run time rather than an
address fixed when it was compiled. Tested both ways round: byte-identical
output from one file on a PicoMiteVGA (RP2040) and a PicoMiteHDMIWEB
(RP2350B). So a converted program can be posted or shipped exactly like any
other `.bas`.

**What to expect.** Loops, array work and arithmetic run 10–20x faster.
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
to build the firmware — and one Python package (`pip install pyelftools`). The manual inside covers
setting both up on Windows and Linux, and the recommended workflow. Firmware
6.03.02b9 or later is required on the board.
