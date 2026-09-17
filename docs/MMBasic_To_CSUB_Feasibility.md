# MMBasic SUB → CSUB in one step: a feasibility review

*Can a single Python program take an MMBasic subroutine and turn it into a CSUB?*

September 2026. Written against PicoMite 6.03.02b8 and the Fuzix `mmb2c` transpiler.

---

## The short answer

Yes, and the reason is that **both halves already exist**. What is missing between
them is not a language problem but a runtime one, and most of it is now solved in
the firmware.

- **The front end — the expensive part — is written.** `mmb2c.py` (10,912 lines, in
  `FUZIX/Applications/mmb2c/`) already lexes MMBasic, parses its expressions, infers
  types from suffixes and `OPTION DEFAULT`, lowers its control flow, and covers
  228 of 353 keywords, with a `.bas`/`.expected` test corpus beside it. None of that
  work is specific to the Fuzix target.
- **The back end — C to CSUB — is written.** `user-tools/armcfgen.py --compile` is
  already a one-step C → CSUB tool, with the position-independence, linker-script
  and alignment traps solved.

So the "single Python program" is really **a second emitter inside mmb2c**
(`--target csub`) that drives armcfgen. A backend, not a fork, so keyword-coverage
work keeps being shared between the two targets.

---

## What a CSUB actually is, as a compilation target

A CSUB is a blob of position-independent Thumb code stored in the program's flash
and called by `CallCFunction` in `core/CFunction.c`. It links with
`-nostartfiles -nostdlib`, so it has **no libc and no libgcc**. Everything it can
do beyond its own arithmetic comes from the CallTable in `PicoMite.c`, which it
finds at runtime through vector slot 7.

That gives an emitter five constraints, in order of how much they shape the design.

### 1. A CSUB sees only its arguments

`CallCFunction` passes **at most ten `void *`**, each a pointer to an `int64`, a
`double`, an MMBasic string, or an array's element 0 — and **no dimensions**.
MMBasic globals are invisible.

This is the deepest mismatch, because a real SUB reads globals and calls other
SUBs. Two ways out:

- **Restrict to pure SUBs** whose entire footprint is their parameters. This is
  what the Exile port does by hand, marshalling state into `obj()`, `game()`,
  `world()`, `tbl()`, `feed()`. It is also exactly the case where a CSUB pays.
- **Look globals up at runtime.** CallTable `0x60`/`0x64` expose `&g_vartbl` and
  `&g_varcnt`, and `PicoCFunctions.h` publishes `struct s_vartbl`. A CSUB can find
  a global by name and cache the pointer once per call. This makes automatic
  global support possible rather than requiring hand marshalling.

Array bounds must be passed explicitly or recovered from `g_vartbl`.

### 2. A CSUB is a statement, not a function

`MMBasic.c` discards `CallCFunction`'s return value. So:

- `SUB` → `CSUB` is genuinely **drop-in**: same call syntax, same name, no call
  sites change.
- `FUNCTION` → `CSUB` is **not**: it has to become a SUB with an out-parameter,
  and every call site has to be rewritten.

Phase 1 should be SUBs only.

### 3. No writable static data

There is no `.data` and no `.bss` — the blob lives in flash. Anything an emitter
would naturally make a global has to go into `CFuncRam` (256 bytes, `0x7c`), a
`GetMemory` block, or the argument arrays.

### 4. The stack belongs to the interpreter

Core0's stack is 8 KB on several variants, and has already been overflowed by
`cmd_fm`. MMBasic `LOCAL` arrays must be emitted onto the MMBasic heap via
`GetMemory`/`GetTempMemory` (`0x2c`/`0x30`), never as C locals.

### 5. The CallTable is the whole API

Available: `sin`/`cos`/`sqrt`/`atan2`/`pow` in both precisions, print, `error`,
`CheckAbort`, memory, pins, some drawing. **Not** available: `tan`, `log`, `exp`,
`asin`, `acos`, `RND`, any string function, any file I/O. The table is append-only
and it is our firmware, so adding slots is cheap — but each addition is a permanent
ABI commitment.

The general fallback is `CallExecuteProgram` (`0x74`): a CSUB can hand an arbitrary
MMBasic statement string back to the interpreter. That means the tool need never
fail outright — but it costs all the speed, and the re-entered statement runs in a
fresh local frame, so it only sees globals and what the CSUB can name.

---

## The arithmetic question, measured

An emitter carrying MMBasic semantics has to do `int64` integer arithmetic and
`double` float arithmetic, because that is what `INTEGER` and `FLOAT` are. Silently
narrowing to 32 bits would produce a CSUB that disagrees with the SUB it replaced.

**Doubles were never a problem**: `FAdd`/`FSub`/`FMul`/`FDiv`/`FCmp` plus
`IntToFloat`/`FloatToInt64` and both precisions of the maths functions have been in
the CallTable for a long time. An emitter simply emits the wrapper call, as
`Bas/bubble.c` does by hand. No host library is involved.

For `long long`, compiling for `-mcpu=cortex-m0plus` and inspecting the undefined
symbols of each operation in isolation gives a short and precise list:

| Operation on `long long` | Helper needed? |
|---|---|
| `+` `-` unary `-` | inline |
| `<` `>` `==` … | inline |
| `&` `\|` `^` `~` | inline |
| shift by a **constant** | inline |
| shift by a **variable** | `__aeabi_llsl` / `__aeabi_lasr` / `__aeabi_llsr` |
| `*` | `__aeabi_lmul` |
| `/` `%` | `__aeabi_ldivmod` / `__aeabi_uldivmod` |
| ↔ `double` | `__aeabi_d2lz` / `__aeabi_l2d` — already covered (`0x88`, `0x84`) |
| 32-bit `/` | `__aeabi_idiv` — already covered (`IDiv` `0xC8`) |

So only five operations were genuinely missing, and `IDiv`/`IMod` could not stand in
for them because both are declared `int IDiv(int, int)` — 32-bit.

**Fixed in 6.03.02b8** by appending nine slots, in the same idiom as everything
else in the table rather than by linking a host library:

```
LMul   0x140    long long LMul(long long, long long)
LDiv   0x144    long long LDiv(long long, long long)
LMod   0x148    long long LMod(long long, long long)
LShl   0x14C    long long LShl(long long, int)
LAsr   0x150    long long LAsr(long long, int)
LLsr   0x154    unsigned long long LLsr(unsigned long long, int)
memcpy 0x158    void *memcpy(void *, const void *, size_t)
memset 0x15C    void *memset(void *, int, size_t)
memmove 0x160   void *memmove(void *, const void *, size_t)
```

They have to be C wrappers, not pointers straight at the `__aeabi_` routines:
`__aeabi_ldivmod` returns the quotient in `r0:r1` and the remainder in `r2:r3`,
which is not a C ABI.

Two semantic notes an emitter must get right:

- MMBasic's `\` is C's `/` and `MOD` is C's `%` on `int64` (`op_divint`, `op_mod`),
  so `LDiv`/`LMod` match for every sign.
- MMBasic's `>>` is a **logical** shift — `op_shiftright` casts to
  `unsigned long long` — so `>>` maps to `LLsr`, not `LAsr`. `LAsr` has no MMBasic
  operator and exists for transcribed C.

### The block moves are different from every other slot

The compiler emits calls to `memcpy`/`memset`/`memmove` **by name**, without anyone
writing one: `char buf[64] = {0}`, a struct assignment or an array copy all become
one. A CallTable macro cannot catch that, so the *symbols* have to exist in the
blob. `PicoCFunctions.h` now provides shims behind `#define CSUB_MEM_SHIMS` that
forward to the vectors — about eight instructions each.

An emitter has a second option here: never generate aggregate initialisers or
struct assignment, so the implicit calls never arise. The shims are worth having
anyway for hand-written CSUBs.

---

## What is now reachable, tier by tier

| Tier | Content | Verdict |
|---|---|---|
| 1 | Integer and float maths, `IF`/`FOR`/`DO`/`SELECT`, scalar and array parameters | **Very practical.** The bubble and Exile case, and where the 10x lives. |
| 2 | `LOCAL`s including arrays, several transpiled SUBs calling each other in one blob | **Practical.** armcfgen's `merge` mode already resolves intra-blob `bl`. |
| 3 | Globals via `g_vartbl`, `PRINT`, full maths library, MMBasic strings | **Practical, more work.** Needs a string runtime (length-prefixed, `GetTempMemory`) and either a libm subset in the blob or more CallTable slots. |
| 4 | File I/O, graphics, `ON ERROR`, `INPUT`, interpreter state | **Only via `CallExecuteProgram`** — correct, but no speed benefit. |

---

## Suggested staging

**Phase 0 — done (6.03.02b8).** The nine slots above, the `CSUB_MEM_SHIMS` shims,
and `Bas/lltest.c` + `Bas/lltest.bas` as a regression test that compares every one
against the interpreter's own operator on the same values. This was worth doing on
its own account: it lifts a restriction hand-written CSUBs have always had.

**Phase 1.** `mmb2c --target csub`, restricted to SUBs whose whole footprint is
their parameters. Emits the C, the `CSUB name INTEGER, FLOAT, …` declaration line,
and the hex block spliced back into the `.bas`. One command, one step.

**Phase 2.** Heap-allocated locals, arrays with passed bounds, multi-SUB blobs,
string runtime.

**Phase 3.** Globals through `g_vartbl`; maths completeness; and a **generated
differential harness** — transpile, build the same C as a host DLL (the
`EXPORT`/`_MSC_VER` trick in `Bas/exile_tools/csub/exile.c`), and replay the same
vectors through interpreter and CSUB comparing state after every call. Given the
Exile experience this is mandatory, not optional: a silently wrong CSUB surfaces as
a hard fault with no line number.

**Phase 4.** `CallExecuteProgram` fallback for the tail.

---

## Two things worth weighing first

**The subset that pays is narrow.** The measured win is real — bubble went from
233 ms/frame to 23 ms, the Exile kernel runs a whole tick in 0.23 ms — but it
applies to hot, pure, self-contained kernels, which are exactly the ones we have
been willing to hand-write in C anyway. Phases 2 and 3 are where most of the effort
sits, and they buy coverage rather than speed.

**Program memory, not speed, is the real ceiling for big blobs.** A CSUB costs its
hex text as well as its binary, roughly 3.5x the code size, and a 44 KB kernel
already overflowed a PC3's 144 KB of program memory. A transpiler that makes CSUBs
easy to produce will hit this sooner than a human writing them one at a time, so
phase 1 should emit `-Os` by default and phase 2 should know about putting a large
blob in the library.

**Recommendation:** build phase 1 as a small emitter and use what it feels like in
practice to decide whether phases 2 and 3 are worth it. That gets a working
`MMBasic SUB → CSUB` button for the case that matters most without committing to
the whole language.

---

## Open questions about mmb2c

Answered from the firmware side only; these need a look at the transpiler:

1. Is mmb2c's emitter already separable from its front end — a `--target` hook, or
   an entangled rewrite?
2. Does its generated C lean on a Fuzix runtime library? That determines how much
   freestanding prelude phase 1 has to supply.
3. mmb2c deliberately avoids `re`, f-strings, `typing` and `enum` so it can run
   under MicroPython on the Pico. A CSUB emitter has to run the ARM toolchain, so
   it is host-only regardless — but staying inside those restrictions keeps one
   codebase rather than two.
