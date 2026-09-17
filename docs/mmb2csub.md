# mmb2csub

*Turning an MMBasic SUB or FUNCTION into a CSUB, without writing any C.*

For PicoMite firmware 6.03.02b8 and later.

---

## 1. What it is for

Your program is too slow. Somewhere inside it is a routine doing the real work,
and the interpreter is spending most of its time reading that routine rather
than running it. `mmb2csub` compiles that routine to machine code and puts it
back into your program as a CSUB, so the interpreter calls it once instead of
interpreting it a million times.

```
python mmb2csub.py myprogram.bas PlotJulia
```

That rewrites `myprogram.bas`: the original routine is commented out, the CSUB
is appended, and **your call sites do not change** — MMBasic calls a CSUB
exactly as it calls a SUB.

What you can expect:

| what the routine does | speedup |
|---|---|
| loops, array work, integer and float arithmetic | 10–20x |
| transcendental maths (SIN, LOG), string formatting | 3–4x |
| mostly calling the firmware already (graphics, files) | very little |

The second row is not a disappointment, it is the arithmetic: `SIN` and `STR$`
run *the same firmware code* whether your BASIC calls them or the CSUB does, so
only the interpreting overhead goes away. A routine that spends its time inside
the firmware has little for this tool to remove.

---

## 2. The recommended workflow

### Step 1 — find out where the time goes

Run your program with profiling on. You are looking for the routine with the
most **self time**, not the most calls: a routine called 1,500 times that does
nothing much matters less than one called 500 times that does everything.

If your profile only gives call counts, treat them as a hint and use step 2 to
check the shape of the call graph before deciding.

### Step 2 — ask what can be converted, and what it costs

```
python mmb2csub.py myprogram.bas --list
```

This changes nothing. It compiles and links every routine in the program, so
the answer is the toolchain's, not a guess. It takes a minute or two on a large
program.

```
Convertible, and not already inside another one's blob:
  routine          args     blob    text closure  also brings in
  DrawFrame           6     4280     10k       3  Rotate, Project, Clip
  Julia              10     1136      2k       1  -

Also convertible, and worth having if a root above is out of reach:
  routine          args     blob    text closure  carried by
  Rotate              4      980      2k       1  DrawFrame

Not convertible:
  AskUser        needs mm_input_line, mm_input_next
  Report         parameter 'pt' is a user TYPE
```

The four numbers are the whole decision:

- **args** — how many arguments the CSUB will take. Your parameters, plus one
  for every global the routine reaches. Past ten, the globals stop being
  separate arguments and travel as a single array of their addresses, so a
  routine reaching twenty of them still takes only a handful.
- **blob** — the machine code.
- **text** — what it costs in **program memory**, which is what actually has to
  fit. A CSUB is stored as hex text as well as binary, so this is about 2.4x
  the blob. Compare it with what your board has spare.
- **closure** — how many routines travel with it.

### Step 3 — pick ONE routine, as high up as fits

This is the step people get wrong. **You do not pick a list of hot routines —
you pick one root, and everything it calls comes with it.** The first section
of the listing is exactly the routines that are not already inside somebody
else's blob.

Converting two routines from the same call tree gives you two CSUBs each
carrying its own copy of the shared code. The tool will say so:

```
note: DrawFrame already carries Rotate - converting both duplicates it
```

If the root you want is out of reach — too many arguments, or more program
memory than you have — drop to the largest routine below it that fits. That is
what the second section of the listing is for.

### Step 4 — convert it, keeping everything, and check it works

```
python mmb2csub.py myprogram.bas DrawFrame
```

The default keeps the original routine commented out and the generated C as
comments, so you can read what happened. Your previous version is saved as
`myprogram.bas.bak` regardless.

Load it and run it. If it works, go on. If it does not, `--dry-run` builds and
reports without touching your source, and `--keep-c` leaves the C on disk.

### Step 5 — if it does not fit, make it lean

The comments cost program memory — the interpreter stores the text.

```
python mmb2csub.py myprogram.bas DrawFrame --lean
```

`--lean` drops the commented-out original, the embedded C, and the CSUB's own
internal comments, and refills the hex eight words to a line. For a small
program that is the difference between 7.9 KB of program text and 4.5 KB.
Nothing is lost: the `.bak` has the original and the C regenerates.

`--no-c` and `--no-original` do one each if you want to keep the other.

If it still does not fit, put the CSUB in the **library**, which is what
`--library` is for:

```
python mmb2csub.py myprogram.bas DrawFrame --library mylib.bas --lean
```

The CSUBs and their wrappers go to `mylib.bas` instead of into your program,
and your program keeps only the originals, commented out. Then, on the board:

```
LOAD "mylib.bas"
LIBRARY SAVE
LOAD "myprogram.bas"
RUN
```

The library holds the binary alone, without the hex text, so the program is
left with almost all of program memory to itself. `--lean` applies to the
library file — there is nothing in your program to make lean. Several
routines named in one command all go into the same library file.

**Read A.8 before converting anything large this way.** `LIBRARY SAVE` takes
the CSUB out of *program* memory, so the library file has to load first, and
that costs the hex text and the binary together. The tool prints the figure to
check against `MEMORY`.

### Step 6 — prove it gives the same answer

This is not optional. A CSUB that is subtly wrong does not print a helpful
message; it hard-faults with no line number, or quietly returns a different
number.

- **If it draws**, `SAVE IMAGE` before and after and compare the files. The
  comparison can be done on the board — see `Bas/filecmp.bas`.
- **If it computes**, print the results both ways over the same inputs and diff
  them. Keep the `.bak`, which still has the interpreted version.
- **Then** time it.

Do the correctness check before the timing. A fast wrong answer is not progress.

---

## 3. What can be converted

**Yes:** SUBs and FUNCTIONs, numeric or string; numeric and string scalars,
and numeric arrays, as parameters or globals; `LOCAL`s including arrays and
strings; `STATIC`s, which the wrapper keeps for you; recursion; `IF`/`FOR`/`DO`/`WHILE`/`SELECT`/`EXIT`; all arithmetic and comparison;
`CONST`; and the MMBasic functions with firmware support — `SIN COS TAN LOG SQR
ATAN2 ASIN ACOS POWER INT FIX ABS SGN RND TIMER`, `LEFT$ RIGHT$ MID$ UCASE$
LCASE$ CHR$ SPACE$ STRING$ INSTR STR$ VAL LEN`, `PRINT`, and `PIXEL`.

**Not yet:** string *arrays* as parameters; `INPUT`; `ON ERROR`; interrupt
handlers; most graphics beyond `PIXEL`; file I/O; user-defined `TYPE`s.

String work inside a CSUB runs on the firmware's own string routines — the same
code `MID$` uses when your BASIC calls it — so a string-heavy routine gains what
the interpreting overhead was costing and no more. See the table in section 1.

You do not have to memorise that list. **Anything unsupported is refused**, by
name, before anything is written — either by the tool or by the C compiler,
which is the real scope check. The tool will not produce a CSUB it cannot
account for.

**Appendix A** explains where each restriction comes from, and covers two
things this list cannot: what a CSUB does *instead* of stopping with an error,
and what is deliberately not a limitation.

---

## 4. The limits, and what to do about them

**Arguments.** `MAX_CSUB_ARGS` is 16 on RP2350 and 10 on RP2040, and that
counts your parameters plus the globals the routine reaches. Past ten globals
the tool gathers them into one array of addresses instead, which lifts the
limit for practical purposes — the wrapper fills it with `PEEK(VARADDR x)`,
which is the same call the interpreter makes to build an argument pointer.
It costs a little wrapper text and nothing at run time.

**Program memory.** `text` in the listing, against what `MM.INFO(PROGRAM SIZE)`
tells you is free. Remedies, in order: `--lean`, then crunching the rest of the
program (`XMODEM C`, `AUTOSAVE C`, `LOAD ,C`), then `LIBRARY SAVE`.

**Self-contained is best.** A routine that only touches its parameters converts
cleanly and cheaply. Every global it reaches costs an argument and makes the
wrapper bigger.

**Interrupting it.** The interpreter tests the break key between statements, and
your converted routine is now *one* statement. The tool puts a break check
inside every loop so `Ctrl-C` still works; without that a long CSUB makes the
board stop answering.

**No range checks, no clean stop.** A CSUB cannot reach the interpreter's
error handling, so an out-of-range subscript writes to memory instead of
reporting `Index out of bounds`. Convert code that already works. Appendix
A.2 has the detail.

---

## 5. Options

| | |
|---|---|
| `--list` | report what can be converted and what it costs; change nothing |
| `--dry-run` | build and report, leave the source alone |
| `--library FILE` | write the CSUBs and wrappers to FILE, for `LIBRARY SAVE` |
| `--lean` | keep nothing but the CSUB (with `--library`, applies to FILE) |
| `--no-c` | do not keep the generated C as comments |
| `--no-original` | delete the original routine rather than commenting it out |
| `--keep-c` | also leave the generated `.c` on disk |
| `--no-backup` | do not write `<source>.bak` |
| `--name NAME` | name the CSUB yourself |
| `-O LEVEL` | optimisation level (default `s`; prefer it for anything large) |

When nothing needs wrapping, the CSUB **takes the original routine's name** and
your call sites go straight to it. A wrapper appears only when something must be
marshalled — a FUNCTION's result, an array's `BOUND()`, or globals — and then
the wrapper carries the original name instead.

---

## 6. Getting the program onto the board

`user-tools/xsend.py` sends a program by XMODEM straight into program memory:

```
python xsend.py COM7 myprogram.bas
python xsend.py COM7 myprogram.bas --crunch    # strip comments on the way in
```

Four seconds rather than a minute for a large program — and, more importantly,
**it is acknowledged**. Pasting a program at the prompt can fail silently and
leave the *previous* program running, which looks exactly like a successful run
of the new one. If you benchmark that, you benchmark the old code.

---

## 7. When something goes wrong

**`undefined reference to mm_xxx`** — that MMBasic feature has no CSUB runtime
yet. The name tells you which: `mm_input_next` is `INPUT`, `mm_map_get` is
`MAP()`. Take it out of the routine, or convert a different one.

**`undefined reference to __aeabi_xxx`** — an arithmetic helper is missing from
`mmcsub.h`. This one is a gap in the tool; report it rather than working around
it.

**`would need N arguments`** — see the limits above.

**`X calls Y ...` / `X is a string FUNCTION`** — the closure includes a routine
that cannot be converted. The message names the real culprit, which is often not
the routine you asked for.

**It compiled but the answer is wrong** — go back to step 6 and find the
smallest input that differs. The `.bak` has the interpreted original, so you can
run both. Please report it: the generated C is meant to be a faithful
translation, and a difference is a bug in the tool, not in your program.

---

## 8. A worked example, and an honest one

`solar_eclipse.bas` — 3,200 lines, 33 routines — profiles like this: `findleap`
1,455 calls, `utc2tdb` 1,455, `jdfunc` 1,454, `nut2000_lp` 954, then a dozen
routines around 480, and `sefunc` at 474.

The call-count ordering suggests converting `findleap`. The listing says
otherwise: `findleap` is *inside* `sefunc`'s blob, and converting `sefunc`
covers 15 of the 20 profiled routines and 99.8% of the calls.

`sefunc` reaches **twenty globals**, which used to put it out of reach on
argument count alone. It no longer does — they travel as one array, so the CSUB
takes three arguments: `x!`, `fx!` and the table. It converts, and the blob is
correct. What stops it is size, in a way worth following through because it is
the case `--library` was added for.

Its blob is 37 KB. In the program that is about 89 KB of text, which does not
fit. So it goes to a library instead — and it does not fit there either, for
the reason in A.8: loading the 86 KB library file costs its hex text and its
binary together, about 124 KB, on a board with 100 KB of program memory. The
load stops quietly, `LIBRARY SAVE` writes 752 bytes — the wrapper and the
declaration — and calling it gives `Internal fault 5`.

So the answer for this program is **several smaller conversions** from the
second listing, which is where it was heading anyway. `tdb2utc` has a 3.5 KB
blob and carries `jbrent`, `jdfunc`, `utc2tdb` and `findleap` — between them
nearly 5,000 calls; `gast2` carries `nut2000_lp`; `eci2topo` carries six more.
Choose them so their closures do not overlap, put them all in one library file
with a single command, and `LIBRARY SAVE` that.

`solar_eclipse` also needs `Dim decl, rasc, rb, rlsun, rmm` adding at program
level first — see A.7 for why.

Two things to take from that. The listing, not the profile, tells you what to
convert. And when a routine is out of reach it is now nearly always about size
rather than shape — which is a question of where you put the blob, not whether
the tool can build it.

---

## Appendix A — Limitations, and where they come from

Section 3 lists what converts and section 4 the practical limits. This
appendix explains *why*, because the reasons are more useful than the list:
almost every restriction below follows from one of four facts about what a
CSUB is, and once you know those four you can usually predict the answer
without looking anything up.

**The four facts.**

1. To the interpreter, a CSUB is **one statement**.
2. The blob is **code and constants only** — it has no writable data.
3. It links **without a C library**.
4. It has **no path back** to the interpreter's error handling.

---

### A.1 No writable data

The firmware loads the blob at an address of its choosing and gives it no
data segment. There is nowhere to put a variable that outlives a call.

**`STATIC` still works**, but not by living in the CSUB. The wrapper declares
an MMBasic `STATIC` of its own and passes its address in, which gives exactly
the lifetime the original had — one instance, initialised on the first call,
surviving every later one. Array bounds and initialisers are copied from your
declaration, so this:

```basic
Static hits%, acc! = 1.5
Static tab%(4)
```

becomes a wrapper holding the same three variables and passing all three. The
cost is one argument each, against the ceiling in A.5.

**What you cannot do** is keep state anywhere else. There is no equivalent of
a C `static` inside the routine, and the 256 bytes of `CFuncRam` that a CSUB
does own are already spoken for by the string scratch stack and the globals
table.

You will not hit this by accident. Since 6.03.02b8 the linker checks it:

```
this CSUB has writable static data (.bss); a CSUB has no data segment
```

That check exists because the failure it prevents is silent. The C is valid,
the compile is clean, the blob builds and runs — and every access goes to
memory belonging to something else. It is worth knowing about if you also
write CSUBs by hand, because it applies to those identically.

---

### A.2 No error path

`error()` in the firmware does a `longjmp`. A CSUB cannot call it: the jump
would abandon the CSUB's own stack frame. So a CSUB has no way to stop with a
message, and that has three consequences worth taking seriously.

**`ON ERROR` is refused.** Nothing to add — the tool tells you.

**Array subscripts are not checked.** This is the one that catches people.
MMBasic checks every subscript and stops with `Index out of bounds`. The
generated C does not check at all:

```c
__L->v_s[(int)(v_k)] = v_k;     /* no range test, by design */
```

A subscript one past the end writes to whatever is next in memory. In the
interpreted version that same line gives you a clean error and a line number.
**Convert code that is already correct**, and do not use a CSUB to find bugs.

**Stack overflow resets the board.** Recursion is supported and works, but
without the interpreter's depth check. A recursive routine with a `LOCAL`
array was measured both ways: MMBasic stopped it cleanly at depth 9 with
`Stack overflow, at depth 9`, while the converted CSUB ran past depth 100 and
reset the board somewhere before 150, with no message. Deep or unbounded
recursion is the wrong thing to convert.

The general rule: a CSUB fails the way C fails, not the way BASIC fails.

---

### A.3 One statement

The interpreter checks the break key *between* statements, and your routine is
now a single statement. The tool puts a break check inside every loop, so
`Ctrl-C` still works — without it a long CSUB makes the board stop answering.
The check costs a counter increment per iteration and fires once every 1024.

Two smaller consequences: a profiler cannot see inside a CSUB, so convert
before you profile again rather than after; and a run-time fault has no line
number to report, which is the other half of A.2.

---

### A.4 No C library

Everything routes to the firmware's own routines through the CallTable, so
there is no second copy of soft-float or string code in the blob. When
something has no route, you get a link error naming it:

- **`undefined reference to mm_xxx`** — an MMBasic feature with no CSUB
  runtime yet. The name says which: `mm_input_next` is `INPUT`, `mm_fb_copy`
  is the framebuffer.
- **`undefined reference to __aeabi_xxx`** — an arithmetic helper is missing.
  That one is a gap in the tool rather than in your program; please report it.

This is why the tool can be trusted not to produce a CSUB it cannot account
for: the compiler and linker are the scope check, so the supported list cannot
quietly drift out of date.

---

### A.5 The argument ceiling

`MAX_CSUB_ARGS` is **16 on RP2350 and 10 on RP2040**, counting your
parameters, one per global the routine reaches, and one per `STATIC`.

Past ten globals the tool stops passing them separately and gathers them into
a single array of addresses, which lifts the limit for practical purposes. The
wrapper fills it with `PEEK(VARADDR x)` — the same call the interpreter makes
to build an argument pointer — so it costs a little wrapper text and nothing
at run time.

A routine reaching twenty globals is still usually the wrong thing to convert,
for the reason in section 8: it is a sign the work is spread across the
program rather than contained in the routine.

---

### A.6 Strings

String work runs on the firmware's own routines — the same code `MID$` uses
when your BASIC calls it — so results are identical and the gain is only the
interpreting overhead. Three limits:

**A statement's temporaries are bounded.** String expressions build
temporaries in a 4 KB scratch arena, about sixteen full-length strings, thrown
away at the end of each statement. A single statement that builds more than
that wraps round and reuses the space rather than overrunning it, which would
corrupt that statement's own earlier temporaries. Splitting a monster
concatenation across several statements is the fix; in practice this is very
hard to reach.

**String arrays cannot be parameters.** A string array's element stride
follows the `LENGTH` it was declared with, and the CSUB is never told what
that is, so indexing one would be wrong *silently*. Refused for that reason.
Scalar string parameters are fine — they are already exactly what the ABI
passes. The same applies to a `STATIC` string array.

**`LENGTH` on a simple string variable is ignored** by MMBasic itself, which
always gives those 256 bytes — so nothing is lost in translation there.

---

### A.7 Globals the program never declares

A wrapper reaches a global with `PEEK(VARADDR x)`, which needs the variable to
**already exist**. Without `OPTION EXPLICIT`, MMBasic creates a global the
first time something assigns to it — so a global that only ever came into
being inside the routine you are converting will no longer be created by
anything, and the wrapper stops with:

```
Error : Cannot find DECL
```

The fix is one line at program level, naming the variables the message
complains about:

```basic
Dim decl, rasc, rb, rlsun, rmm
```

This is worth checking before you convert rather than after. `solar_eclipse`
has five such globals out of the twenty `sefunc` reaches: they are assigned
inside `sun` and never declared anywhere, so they exist only because `sun`
has run. Programs written with `OPTION EXPLICIT` cannot have the problem.

---

### A.8 Program memory

A CSUB is stored as hex text as well as binary, so it costs about **2.4x the
blob size** in program memory. The `text` column of `--list` is the number
that has to fit.

In order of what to try: `--lean`, then crunching the rest of the program
(`XMODEM C`, `AUTOSAVE C`, `LOAD ,C`), then `--library` and `LIBRARY SAVE`,
which stores the binary alone and drops the hex text entirely.

**The library has its own ceiling, and it is not the library's size.**
`LIBRARY SAVE` copies the CSUB out of *program* memory, so the library file
has to load into program memory first — and loading it costs the hex text
**and** the binary built from it, at the same time. Roughly 3.4x the blob.

On a 100 KB board that puts the largest single CSUB you can get into the
library at about **29 KB of blob**, whatever the library area has free.

Past that the failure is quiet, and worth recognising:

- the load stops early — the tell is a missing `Saved nnn bytes`
- `LIBRARY SAVE` reports a byte count far smaller than the blob
- `LIBRARY LIST` shows the CSUB, because its *declaration* did fit
- calling it gives `Error : Internal fault 5(sorry)`

A 3.5 KB blob saves as 3660 bytes and works. A 36.9 KB blob on the same board
reports 752 bytes — the wrapper and the declaration, with no code behind them.
The tool prints what the load will need; compare it with `MEMORY` first.

If a routine is over the line, convert something further down its call graph
instead, as in section 8.

---

### A.9 What is not translated at all

As of 6.03.02b8, 132 of the 166 routines in the test corpus convert. What the
remaining 34 are waiting on, largest group first:

| | |
|---|---|
| interrupt handlers (`SETTICK`, `ON KEY`, pin interrupts) | a CSUB cannot be one |
| user-defined `TYPE`s, as parameters or locals | not yet translated |
| `INPUT` | no CSUB runtime yet |
| graphics beyond `PIXEL`, framebuffers, file I/O | no CSUB runtime yet |
| `DIM` of a `LOCAL` array at run time | needs a heap the blob does not have |
| routine names containing dots | a tool bug, not a limitation |

You do not have to memorise any of it. Everything unsupported is refused by
name before anything is written, so the failure mode is a message rather than
a surprise.

---

### A.10 What is *not* a limitation

Worth stating, because it saves chasing imagined problems:

- **Arithmetic is identical.** Integer and floating-point operations, and
  every maths function, call the same firmware routines the interpreter calls.
  There is no reduced-precision path and no second implementation.
- **String functions are identical**, for the same reason.
- **Recursion works**, within A.2's caveat about depth.
- **`LOCAL` arrays and strings work**, including in recursive routines, each
  call getting its own.
- **Call sites do not change.** The CSUB takes the routine's name, or a
  wrapper does when something has to be marshalled.

So if a converted routine gives a different answer from the interpreted one,
that is a **bug in the tool**, not a rounding difference or a documented
limit. The `.bak` still has the original; please report the smallest input
that differs.
