**Beta for testing.** This is the release after b9 — b10 was an interim build
and was never published, so everything below has accumulated since b9. Please
try it on programs you already have and report anything that behaves
differently; that is the most useful testing there is. **Four variants move
their A: drive this time** — see the upgrade note at the end before you flash
one of those.

## New: image slots in PSRAM

`FLASH LOAD IMAGE` puts a BMP into a flash slot in RGB121 form, and `BLIT
FLASH`, `TILEMAP` and `MM.INFO(FLASH ADDRESS)` read it back. There are only
three flash slots, the third is the one the library uses, and writing one
takes a moment and wears the flash. On an RP2350 with PSRAM there are now five
more: **image slots 4 to 8 are the RAM slots 1 to 5**, and every command that
takes a slot number takes them by the same number.

```
FLASH LOAD IMAGE 4, "tiles.bmp", O        ' RAM slot 1, every start
TILEMAP CREATE mapdata, 1, 4, 16, 16, 16, 20, 15
BLIT FLASH 4, F, 0, 0, 100, 40, 32, 32, 0
a = MM.INFO(FLASH ADDRESS 4)              ' the image, for a CSUB
```

A RAM image loads faster (a full 320x240 screen in 28 ms), costs no flash
wear, and leaves the flash slots to whoever else wants them. It is cleared at
every reset, so a program loads it at every start, with `O` because the slot
may still hold it after a `RUN`. Use a constant for the slot number and moving
an image between flash and RAM is one edit; the games below do exactly that
and fall back to flash on a board without PSRAM. `RAM LIST` and `FLASH LIST`
now say `image 256 x 1120` for a slot that holds an image, `RAM SAVE` refuses a
slot that holds one, and both loaders reject a bad or oversize file before
anything is erased.

Odd-width images were stored one byte short per row in flash and drew
skewed; both loaders now pack rows the way `BLIT FLASH` reads them.

## New: a library in RAM, alongside the one in flash

```
LIBRARY LOAD MM.INFO(PATH) + "mygame_lib.bas", RAM
```

On an RP2350 with PSRAM the library goes into RAM slot 5 and takes the place
of the flash library — which is left exactly as it was — until `END` or the
next `RUN`. A game can bring a large kernel of its own without disturbing the
routines you keep in flash, and nothing asks "are you sure". It lasts until
the program ends, so a program does this at every start; the slot keeps the
file's hash and a repeat load of the same file is immediate. Without PSRAM the
keyword is ignored and the library goes to flash as before, question and all.
While a RAM library is active, `RAM LIST` names it and `RAM SAVE 5`, `RAM
FILE LOAD 5` and `FLASH LOAD IMAGE 8` are refused; `RAM ERASE 5` lets it go.

## New: LIBRARY LOAD stores only the binary of a CSUB

A CSUB used to cost the library twice: the hex text of the block and the
binary built from it, about 3.4x the code. `LIBRARY LOAD` now splits the file
as it streams past and never keeps the text, so the library's ceiling is
measured against the code alone. Same command, same syntax; a program that
already says `LIBRARY LOAD "x.bas"` gets this without changing a line. The
37 KB `sefunc` example from the mmb2csub manual, which wanted 123 KB of
library before, now goes onto a 100 KB board with room to spare.

## New: PIN(n) and PIN(n) = v inside a CSUB

Setting a pin up is a one-off and belongs in BASIC; watching or driving one in
a tight loop is what a CSUB is for. Two CallTable entries, appended so
existing CSUBs are unaffected: `PinVal` reads a pin exactly as `PIN(n)` does,
in every `SETPIN` mode the function supports, and `PinPut` drives one. Neither
raises an error from inside the CSUB — an invalid pin reads as 0 and a write
to a pin that is not an output is ignored. On a PicoMiteVGA, 20,000
write-then-read passes went from 654 ms to 83 ms. Documented in
`docs/armcfgen.md` and the mmb2csub manual, both inside the zip.

## New: BASE$

`BIN$`, `OCT$` and `HEX$` only reach bases 2, 8 and 16. `BASE$(base, number
[, chars])` reaches 2 to 36: `BASE$(12, 100)` is `84`, `BASE$(36, 1295)` is
`ZZ`, and `chars` zero-pads on the left as `HEX$` does. It was always there;
now it is in the manual and the help file.

## Games

- **Picanoid** (`Bas/picanoid`) is new: a bat-and-ball brick game with its
  own title screen and sound. One `.bas`, one `.bmp` and a README; copy the
  directory anywhere and `RUN "picanoid.bas"`. Its one image goes into RAM
  slot 1 on a board with PSRAM and into flash slot 1 otherwise. RP2350, MODE 2
  and a mouse.
- **Exile 0.9.1** loads both tilesets into RAM slots and its kernel as a RAM
  library on a board with PSRAM, so the flash slots and the flash library are
  never touched; without PSRAM it uses flash as before.
- **Elite** loads its declarations library the same way.

Both games now need this release, because the `RAM` keyword is a syntax error
on earlier firmware.

## HELP covers the supplementary manuals

Three text files are attached, generated from the user manual **and** the
separate SPRITE, TILEMAP, RAY, FRAME, STEPPER, STRUCT, DRAW3D, BLIT and GUI
manuals, which were absent before: 1152 topics, up from 872. Copy whichever
suits onto the A: drive as `help.txt`:

| file | size | what is in it |
|---|---|---|
| `help.txt` | 571 KB | the full entry: syntax, description, everything |
| `helpmin.txt` | 250 KB | syntax and a one-line summary |
| `helptiny.txt` | 108 KB | the syntax lines alone |

## Fixed

- **A stale library hash made `LIBRARY LOAD` do nothing.** The hash records
  which file the library in flash came from, but only `LIBRARY LOAD` ever wrote
  it, so a board that once had library X loaded that way and then had library
  Y put in by `LIBRARY SAVE` went on claiming to hold X. A program installing
  its own library was told it already had it, ran on, and failed with "Unknown
  command". `LIBRARY SAVE` and `LIBRARY DELETE` now clear the hash. A board
  already carrying a stale one is healed by one `LIBRARY DELETE`.
- **mmb2csub `--library` with a bare filename** put the library file wherever
  the tool was run from. It now lands beside the program, as the generated
  `.c` and `.txt` already did.

## Upgrade note

The flash region grew by 16 KB on four variants:

- **PicoMiteRP2350** (the plain RP2350 build — not USB, BT or BTH)
- **PicoMiteRP2040VGA**
- **PicoMiteRP2040VGAUSB**
- **PicoMiteRP2040USB**

On those four the A: drive moves with it and is reformatted by the first boot,
so back up anything on A: before flashing one of them. Every other variant
keeps its drive and its files.

## For anyone building from source

- `MAXIMAGESLOTS` (3 on the RP2040, 8 on the RP2350) and `ImageSlotAddress()`
  in `FileIO.c` are the one place a slot number becomes an address; nothing
  else computes `flash_target_contents + (slot - 1) * MAX_PROG_SIZE` any more.
- `LibPresent()` replaces the `LIBRARY_FLASH_SIZE == MAX_PROG_SIZE` test
  wherever it meant "a library is active"; the sites that mean "flash slot 3
  is taken" still read the option. `FileLoadLibrary()` takes the hash to skip
  as its last argument and `SaveLibraryImage()` a RAM base, `NULL` for flash.
- The CallTable gains `PinVal` at 0x1b8 and `PinPut` at 0x1bc, appended.
- `tools/gen_help.py` harvests the supplementary manuals as well as the User
  Manual, and hides the collective tokens (`SCHANGE$`, `TOPBOTTOM`,
  `PEEK(INT8`) that `tokenise()` rewrites several functions onto, reading the
  list out of the code rather than keeping one. `BASE$` is the deliberate
  exception.
- Two new board tests: `Testfiles/RamImageSlotTest.bas` and
  `Testfiles/RamLibraryTest.bas` (with `ramlib_lib.bas`).
