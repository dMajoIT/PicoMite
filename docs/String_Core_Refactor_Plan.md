# Separating parsing from operation in the string functions

*A plan to make MMBasic's own string routines callable from a CSUB, without
duplicating them.*

September 2026. No code changes yet — this is the design and the order to do it in.

---

## 1. Why

The string functions the transpiler needs — `MID$`, `INSTR`, `LEFT$`, `UCASE$`,
`VAL`, `STR$` and the rest — all exist in the firmware and are well tested. None
of them can be called from a CSUB, because each is welded to the expression
evaluator. `fun_mid` is typical:

```c
void fun_mid(void) {
    getcsargs(&ep, 5);                       /* parses TOKENISED text     */
    s = getstring(argv[0]);                  /* re-enters the evaluator   */
    spos = getint(argv[2], 1, MAXSTRLEN);
    sret = GetTempStrMemory(); targ = T_STR; /* returns through globals   */
}
```

No arguments, no return value. The alternative to this plan is re-implementing
the same dozen operations inside `mmcsub.h`, which means two implementations of
`MID$` that can drift apart — and the second one would be the untested one.

Splitting each function into a **core** (plain C, no parsing) and a **wrapper**
(the existing `fun_` entry point, which only parses) gives one implementation
with two callers: the interpreter, and — via a CallTable slot — a CSUB.

## 2. The pattern, which the file already uses

This is not a new idea in `Functions.c`. `fun_schange` (which handles `LEFT$`,
`RIGHT$`, `UCASE$` and `LCASE$`) already parses its arguments and then calls
helpers that take plain ones:

```c
void fun_left(unsigned char *p, int i)       /* line 1523 - plain arguments! */
{
    unsigned char *s = GetTempStrMemory();
    Mstrcpy(s, p);
    if (i < *s) *s = i;
    sret = s;                                 /* ...but still global-returning */
    targ = T_STR;
}
```

It is half way there already: parsing is separated, allocation and the result
convention are not. The work is to finish that split, and to apply the same
shape to the others:

```c
/* core: plain arguments, caller's buffer, no globals, no parsing */
unsigned char *StrLeft(unsigned char *dst, const unsigned char *s, int n);

/* wrapper: unchanged from every caller's point of view */
void fun_left(unsigned char *p, int i)
{
    sret = StrLeft(GetTempStrMemory(), p, i);
    targ = T_STR;
}
```

## 3. The four rules for a core

1. **Plain C arguments.** No `ep`, no `argv`, no `getcsargs`, no `evaluate`.
2. **The caller owns the destination.** A core never calls
   `GetTempStrMemory()`; it writes into a buffer it is given and returns it.
   Where the destination's capacity can vary — a `LENGTH`-declared array
   element — the capacity is an argument.
3. **No globals in or out.** No `sret`, `targ`, `iret`, `fret`. The value is
   returned.
4. **No `error()`.** This one matters more than it looks: `error()` *longjmps*
   (to `mark`, or to `ErrNext` when trapping is armed). From inside a CSUB that
   abandons the CSUB's frame entirely — it never returns, and anything it was
   holding is leaked. So a core **clamps or returns a status**, and all
   validation stays in the wrapper where the interpreter's error machinery is
   the right answer.

Rule 4 is also what keeps the refactor honest: every `StandardError` and range
check in today's code belongs to parsing, not to the operation.

## 4. Naming and placement

- Cores named `Str<Operation>` — `StrMid`, `StrInstr`, `StrLeft`, `StrCase`,
  `StrVal`, `StrFormat`.
- Declared in `core/MMBasic.h` beside `Mstrcpy`/`Mstrcat`/`Mstrcmp`, which are
  already the clean primitives of exactly this kind.
- Kept in `core/Functions.c` next to their wrappers, so the pair stays visible
  as a pair.
- Exposed to CSUBs by appending CallTable slots — **append only**, and each one
  is a permanent ABI commitment, so the batch is decided once rather than
  drip-fed.

Note the token tables are *not* affected: this adds no keywords, so the 7-bit
function-token limit (PICORP2350 already sits at 127 entries) is untouched.

## 5. Inventory

Assessed against the current `core/Functions.c`. "Shape" is what the wrapper
has to keep doing.

| Function | Line | Proposed core | Shape / difficulty |
|---|---|---|---|
| `LEN` | 1163 | `int StrLen(const uchar*)` | Trivial — it is `*s`. Arguably not worth a slot |
| `LEFT$` | 1523 | `uchar *StrLeft(uchar*, const uchar*, int)` | **Already split**; finish it |
| `RIGHT$` | 1535 | `uchar *StrRight(uchar*, const uchar*, int)` | **Already split**; finish it |
| `UCASE$`/`LCASE$` | 1549 | `uchar *StrCase(uchar*, const uchar*, int up)` | Easy; body is inline in `fun_schange` |
| `MID$` | 1185 | `uchar *StrMid(uchar*, const uchar*, int pos, int n)` | Easy; clamping moves into the core |
| `CHR$` | 908 | `uchar *StrChr(uchar*, int)` | Easy |
| `SPACE$` | 1422 | `uchar *StrFill(uchar*, int ch, int n)` | Easy; shares with `STRING$` |
| `STRING$` | 1491 | same as above | Easy |
| `INSTR` | 1025 | `int StrInstr(const uchar *hay, const uchar *needle, int start)` | Moderate — the wrapper keeps the 3/5/7-arity and polymorphic first argument |
| `HEX$`/`OCT$`/`BIN$` | 968 | `uchar *StrBase(uchar*, long long, int base, int width)` | Moderate |
| `STR$` | 1435 | `uchar *StrFormat(uchar*, MMFLOAT, long long, int isint, int m, int n, char pad)` | Moderate — mostly delegates to `FloatToStr`/`IntToStr`, which are already CallTable slots |
| `VAL` | 1336 | `int StrVal(const uchar*, MMFLOAT*, long long*)` | **Hardest** — number parsing, `&h`/`&o`/`&b` forms, returns a type |
| `FIELD$` | 281 | `uchar *StrField(uchar*, const uchar*, const uchar *sep, int n, ...)` | Moderate |
| `STR2BIN`/`BIN2STR` | 316/432 | leave alone | Type-table driven; no CSUB demand yet |
| `EVAL` | 1379 | **never** | Re-enters the interpreter by definition |

Already clean and needing only a slot, no refactor at all:
`MtoC`, `CtoM`, `Mstrcpy`, `Mstrcat`, `Mstrcmp` ([MMBasic.h:656-660](../core/MMBasic.h)).

## 6. Phasing

**Phase A — the free ones.** Expose `MtoC`, `CtoM`, `Mstrcpy`, `Mstrcat`,
`Mstrcmp` as CallTable slots. No refactoring, no behaviour change, and it
already covers assignment, concatenation and comparison — the three operations
in nearly every string expression. This alone makes a large class of string
SUBs convertible.

**Phase B — the easy split.** `LEFT$`, `RIGHT$`, `UCASE$`/`LCASE$`, `MID$`,
`CHR$`, `SPACE$`/`STRING$`, `LEN`. All mechanical, and two are half-done. Do
them as one batch so the CallTable grows once.

**Phase C — the moderate ones.** `INSTR`, `STR$`, `HEX$`/`OCT$`/`BIN$`,
`FIELD$`. Each wrapper keeps real parsing work; the cores are still small.

**Phase D — `VAL`.** On its own, because number parsing is where a subtle
difference would hide and it deserves its own verification pass.

Stop after any phase and the result is still coherent: what has been split is
callable, what has not is simply not yet available to a CSUB.

## 7. Verifying that nothing changed

The whole risk of this refactor is a behaviour change in well-tested firmware,
so the verification has to be stronger than "it compiles".

1. **Differential test at the BASIC level.** Before touching anything, generate
   a table of calls and results for every function in scope — every edge the
   code has (empty strings, position past the end, zero and negative counts,
   maximum lengths, the `LENGTH`-declared array case). Run it on the current
   firmware and keep the output. After each phase, run the identical program
   and diff. This is the real gate, and it costs one board run per phase.
2. **The existing MMBasic test suites** in `Testfiles/`, unchanged.
3. **Size check.** The split should be close to flash-neutral; the wrapper loses
   the body it delegates. Watch it per phase — the RP2040 VGA build has around
   1 KB of margin and a surprise there is expensive (`FLASH_TARGET_OFFSET` moves
   only in 16 KB steps).
4. **A CSUB differential**, once `mmb2csub` can use the new slots: the same
   MMBasic routine interpreted and as a CSUB, compared — which is what the tool
   should be generating anyway.

## 8. What it unlocks

Strings are the single biggest blocker in the transpiler survey — about 35 of
the 131 routines in mmb2c's corpus, between the ones refused outright (string
parameters, string FUNCTIONs, string globals) and the ones that fail to build.
No other gap is close.

It also removes the thing I would otherwise have to write: a second
implementation of MMBasic's string semantics inside `mmcsub.h`, maintained
separately from the first and guaranteed to drift.

## 9. Risks

**The refactor touches code that currently works.** Nothing here is required by
the interpreter; every change is for a second caller that does not exist yet.
That argues for the phasing above, and for phase A first — it is pure addition
with no refactoring at all.

**The capacity question is still open** and should be settled during phase B,
not after: `Mstrcpy` and the `fun_` helpers assume a destination of
`STRINGSIZE`, but a `DIM s$(10) LENGTH 20` array has a smaller stride, and
mmb2c's own `strsz()` honours that while some of its paths cast to
`char (*)[MM_STRSZ]`. Whichever way that resolves, the cores should take an
explicit capacity wherever the destination can be an array element — that is
cheap to design in now and expensive to retrofit.

**Slot budget.** Phases A–D would add roughly 18 CallTable entries. That is
cheap (one word each, plus a small wrapper where one is needed) and the table
has no practical limit — but the entries are append-only and permanent, so the
signatures want to be right the first time. Settling the capacity question
before phase B is part of that.
