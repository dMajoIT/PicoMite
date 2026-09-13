# Characterisation test for `SaveProgramToFlash`

`LIBRARY LOAD` needs `SaveProgramToFlash` to be able to write somewhere other
than program memory. That looked like a small change and is not. This directory
records exactly what the function does today, so the change can be proved to
have altered nothing.

## Why the function is delicate

It writes a tokenised program to flash in **three passes**:

1. Walk the source text and tokenise it into flash.
2. Scan back over **what pass 1 just wrote** - not the source - for `CSUB` and
   `DefineFont` blocks, writing each blob to measure it, and record the sizes
   in `storedupdates[]`.
3. Rewind `realflashpointer` to where pass 2 started and write the blobs again,
   this time back-filling each size word.

Three things in passes 2 and 3 are hardwired to program memory:
`p = (unsigned char *)flash_progmemory` as the scan base, twice, and a bounds
check against `PROGSTART` inside the hex-word reader. Those are what would have
to be parameterised by region.

`SaveProgramToRAM` is the same function with the destination already
parameterised (`p = (unsigned char *)ram`, same `storedupdates[]`, same rewind),
so there is a shipped twin to diff against - but `SaveProgramToFlash` is shared
by `SAVE`, `LOAD` and the editor, so getting it wrong breaks everything rather
than just the new command.

## What the test captures

For each route into program memory:

| | |
|---|---|
| `basic` | an ordinary computation - proves pass 1 is untouched |
| `fontw`, `fonth` | the test font's metrics - proves the `DefineFont` branch |
| `csub1`, `csub2` | a CSUB's answers for known inputs |
| `blob n at a size s` | every CSUB/font blob, where it landed, and the size word back-filled into it |
| `proglen` | length of the tokenised program text |
| `hash1`, `hash2` | two running hashes over all `MAX_PROG_SIZE` bytes of the region |

The blob lines and `proglen` localise a difference - a change in `proglen`
is pass 1, a change only in the blob sizes or the hashes is pass 2 or 3.

The CSUB is the sharp end. `csubtest.c` computes a sum and a sixteen-round mix
of its two arguments, and `expected.txt` carries the answers worked out
independently in Python, so a blob written to the wrong place or with a wrong
size word gives a wrong number rather than a clean failure. It compiles to 136
bytes of `.text` with **no relocations and no undefined symbols** (checked with
`objdump -r` / `-t`), so it needs no libgcc helpers and no `MM.INFO(CALLTABLE)`
- it runs standalone.

## Running it

    set PC3_PORT=COM17
    python savetest.py --baseline     before the change: records baseline.txt
    python savetest.py --check        after: diffs against it, non-zero on any difference

Every figure must be identical. A program cannot checksum the memory it is
running from, so the driver snapshots the region with `FLASH SAVE 1` and
`sig.bas` reads it back from the slot.

## The files

| | |
|---|---|
| `csubtest.c` | the CSUB's source |
| `csub_block.txt` | it compiled, via `user-tools/armcfgen.py` |
| `fixture.bas` | ordinary BASIC + a `DefineFont` + the CSUB, with checks |
| `sig.bas` | reads the snapshot back and reports the signature |
| `savetest.py` | the driver |
| `expected.txt` | the CSUB's answers, computed on the host |
| `baseline.txt` | the recorded pre-change signature |

Regenerate the CSUB with:

    python ../../user-tools/armcfgen.py csubtest.c --compile -n CHECKSUM         -e checksum_csub -O 2 -o csub_block.txt

## Note for the change itself

`LIBRARY LOAD` must not go into the **PICOMIN** build - that variant has no
flash to spare. The writer refactor itself costs nothing (a parameter), but the
new command needs `#ifndef PICOMITEMIN`.
