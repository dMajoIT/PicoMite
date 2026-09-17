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

If it still does not fit, put the CSUB in the **library** — `LIBRARY SAVE`
stores the binary alone, without the hex text, which is the difference between
about 107 KB and 32 KB for a large blob.

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
strings; `IF`/`FOR`/`DO`/`WHILE`/`SELECT`/`EXIT`; all arithmetic and comparison;
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

---

## 5. Options

| | |
|---|---|
| `--list` | report what can be converted and what it costs; change nothing |
| `--dry-run` | build and report, leave the source alone |
| `--lean` | keep nothing but the CSUB |
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
takes three arguments: `x!`, `fx!` and the table. What rules it out now is size.
Its blob is 37 KB, which is about 89 KB of program text, and `minima`, `brent`
and `broot` — the three roots above it — are larger still.

So the choice is between two routes:

- **`LIBRARY SAVE`**, which stores the 37 KB binary without the hex text. If you
  have a spare flash slot, one conversion covers 15 of the 20 profiled routines
  and 99.8% of the calls.
- **Several smaller conversions** from the second listing, if you do not.
  `tdb2utc` at 9 KB carries `jbrent`, `jdfunc`, `utc2tdb` and `findleap` —
  between them nearly 5,000 calls; `gast2` at 6 KB carries `nut2000_lp`;
  `eci2topo` at 5 KB carries six more. Choose them so their closures do not
  overlap.

Two things to take from that. The listing, not the profile, tells you what to
convert. And when a routine is out of reach it is now nearly always about size
rather than shape — which is a question of where you put the blob, not whether
the tool can build it.
