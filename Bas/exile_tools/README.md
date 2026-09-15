# Exile port tools

Working directory for the MMBasic port of Exile (Peter Irvin and Jeremy Smith,
Superior Software, 1988). The design review is `docs/Exile_Port_Design_Review.html`;
the game will live in `Bas/exile/`.

## The listing is not vendored here

Everything is generated from the level7 disassembly of the standard version,
which carries no licence beyond the game's own. Fetch it yourself and keep it
out of this tree:

    curl -LO http://www.level7.org.uk/miscellany/exile-disassembly.txt

The scripts take its path as their first argument.

## How the generators work

The listing prints the machine-code bytes of every instruction and every
table at its run-time address. `exile6502.py` loads those bytes back into a
64 KB image and runs the game's own routines on a small 6502 interpreter, so
the landscape generator, the tertiary-object lookup and the palette logic are
not transcribed: they are executed, self-modifying code included, and the
result is exact by construction. The same interpreter will run the sound
envelopes, the angle tables and the obstruction lookups when those are needed.

Two typos in the listing are corrected on loading: the line at `&4b91` after
the collect-object sound belongs at `&4b9a`, and the second sound of a scream
at `&249e` is printed as `JSR &14fa` (the middle of the save-game encryption,
which ends by wiping memory) where the comment, and the game, say `play_sound`
at `&13fa`.

## Scripts

| Script | Emits | Verify with |
| --- | --- | --- |
| `exile6502.py` | nothing; the loader and CPU the others import | `python exile6502.py listing` prints four known squares |
| `gen_world.py` | `out/world.map`, `out/exile_w1.map`, `out/exile_w2.map` (TILEMAP LOAD files), `out/world_types.bin` (204,800 bytes: the tile type and flips per square, then the tertiary object's data-byte and type-byte offsets, then one bit per square for the squares the mapped data placed), `out/world_drawn.bin`, `out/world_palette.bin`, `out/variants.json` | `--check census/out` compares every square with the C# census (0 of 65,536 differ) |
| `gen_tiles.py` | `out/exile_tiles1.bmp`, `out/exile_tiles2.bmp` (4-bit, for `FLASH LOAD IMAGE` slots 1 and 2), `out/tiles1.png`, `out/tiles2.png`, `out/world_preview.png`, `out/landing_site.png` | `landing_site.png` against `census/landing_site.png`, which came from the C# generator |
| `render_window.py` | a 320 x 240 PNG of any view, drawn exactly as the board should draw it | compare with a `SAVE IMAGE` screenshot from `Bas/exile/worldview.bas` |
| `gen_tables.py` | `out/tables.bas` (51 tables as DATA under labels: obstruction profiles, tile tables, particle types, walking tables, object types, sprite sizes, waterlines, the tertiary and secondary lists, sound envelopes...), `out/tables.json` (all 255 tables in the listing) | every table is cut from the listing under its own label, address and size in the comment |
| `gen_objects.py` | `out/exile_slot2.bmp` (for `FLASH LOAD IMAGE` slot 2: `exile_tiles2.bmp` with the object sheet below it, 213 sprite-palette pairs used by the 101 object types in all four orientations, 126 KB together), `out/objects.bas` (DATA: sprite, palette, flip, x, y, w, h, with y counting the tile rows above), `out/objects.json`, `out/objects.png` | `test_objects.py` |
| `test_objects.py` | `Bas/exile/objview.bas` and `out/ref_objects.png` | run the program on the board and compare its screenshot with the reference (0 pixels differ) |
| `exilegame.py` | nothing; runs the game itself one tick at a time on the 6502 (the oracle for the physics) | `python exilegame.py listing` prints the player falling from the sky |
| `gen_traces.py` | `out/traces/<scenario>.json`: the player's slot after every tick of eighteen key-press scenarios (standing, falling, walking, jumping, jetpack, water, lying down, turning, a cave ceiling and wall, two slopes), with the random bytes and temporaries the physics read | each trace is the real game's answer |
| `exilephys.py` | nothing; the player's physics transcribed to Python at the 8-bit level, the reference for the BASIC | `python exilephys.py listing` replays every trace and reports the first tick that differs (none do) |
| `probe.py` | nothing; stops the game at chosen addresses in one tick of a scenario and prints registers and zero page | for chasing a divergence |
| `gen_phystest.py` | `Bas/exile/physics.bas` (`Bas/exile/exilephys.bas`, the kernel in MMBasic, with the tables and the starting slot appended) and `out/phys/phys_*.txt`, one feed file per scenario | `run_phystest.py` |
| `run_phystest.py` | nothing; puts the feeds, `tables.bin` and `world_types.bin` on the PC3, runs `physics.bas` (or `--prog physcsub.bas`) and checks every printed tick against the traces | 18 scenarios, 2,384 ticks, all match for both; the BASIC kernel costs 9.8 ms a tick, the CSUB 0.1 ms |
| `csub/exilephys.c` | the kernel in C for a CSUB, the same transcription again; `csub/exilestate.h` (generated) is the layout of its state array | `gen_csubtest.py` |
| `gen_csubtest.py` | `csub/exilestate.h`, `csub/exile_csub.txt` (the `CSUB ExileUpdate` block, built with `user-tools/armcfgen.py` at -O2), `out/phys/tables.bin` (the tables the kernel reads, packed), and `Bas/exile/physcsub.bas` (`Bas/exile/physcsub_harness.bas` with the state constants, the starting slot and the block) | `run_phystest.py --prog physcsub.bas` |
| `bisect_cache.py` | nothing; opts subs into `OPTION TRACECACHE` a group at a time to find one the cache gets wrong | found `CollTiles`; the cache is also slower than none on this kernel |
| `gen_traces2.py` | `out/traces2/<scene>.json`: whole scenes from the game, every slot every tick, with the water level, the screen position, every random number the code drew keyed by the address that drew it, two zero-page scratch bytes the physics reads after the plotting code has used them (`SCRATCH_SITES`: the sign register at &22fe, the sprite width at &39b2), and every tile routine the plotting called (`TILE_SITE` &1787: the tile and the mode), which the kernel replays in place of the screen scrolling it does not model yet | each is the real game's answer; promotion and events are switched off so a scene holds what was put in it; a scene is `lonely` (slots 1-15 wiped every tick), `'clear'` (wiped once: the image's slot 1 is Triax) or neither |
| `probe2.py` | nothing; `probe.py` for the whole-scene scenes: stops the game at chosen addresses in one tick and prints registers, the slot being updated and any memory bytes asked for | for chasing a divergence |
| `csub/exile.c` | the whole-scene kernel: update_objects for all sixteen slots (the collision pass between objects, held objects, removal and demotion, the teleport countdown, the per-type dispatch), every object type's behaviour, the player's actions (thrust, jump, aim, pick up and drop, the weapons and firing, pocketing and retrieving, throwing, the whistles, teleporting and remembering, scrolling the viewpoint), the tile routines that make objects and the winds, and `update_events` (the waterlines, Triax's lab, the earthquake, the creatures that emerge, the stars, the summonings) | `gen_exiletest.py` |
| `host_test.py` | `out/host/exile.dll`, the same kernel built with the Visual Studio compiler; replays every scene through it in seconds (`EXILE_DEBUG=1` for the kernel's debug prints) | the board run is the final word; this is for iterating |
| `gen_exiletest.py` | `csub/exilestate2.h`, `csub/exile_tick.txt` (the `CSUB ExileTick` block), `out/scene/tables2.bin`, per scene a binary feed and an init file, and `Bas/exile/exiletest.bas` from `Bas/exile/exiletest_harness.bas` | `run_exiletest.py` |
| `run_exiletest.py` | nothing; puts the scenes on the PC3, runs `exiletest.bas` and checks every slot of every tick against the traces | 76 scenes, 9,620 ticks, all match; 0.22 ms a tick on average, 0.46 at worst |
| `census/` | the C# harness that walked the world before any of this existed, and its images | see `census/README.md` |

The physics chain is `gen_traces.py` (the game's answers), `exilephys.py`
(the transcription, checked against them), then `gen_phystest.py` and
`run_phystest.py` (the same check for the MMBasic translation on the board).
The feed files carry, per tick, the keys held and the few things the game's
code reads that the kernel cannot derive: the random byte at `damage_object`
and `check_reliability`, the carry `add_particle` leaves for the jetpack
drain, the creature temporary that decides which way a steep slope is
climbed, and the water level, which the game moves every tick.

The player-only CSUB is called as `ExileUpdate st(), world(), tbl()`; the
whole-scene one as `ExileTick obj(), game(), world(), tbl(), feed()`, one
call being one tick of all sixteen slots, with the keys held this tick as a
bit mask (one bit per action in `exilegame.ACTIONS`) in the game array, or
in the feed when replaying a trace. Three things a CSUB will
not tolerate were met on the way: a `switch` (or an if-chain GCC turns into
one) wants a libgcc jump-table helper, so `armcfgen.py` now compiles with
`-fno-jump-tables`; writable static data does not exist, so the state is
copied in and out of the argument array; and on the BASIC side `tab` is the
TAB function, a line over about 250 characters stops AUTOSAVE where it
stands, and a CONST must run before it is used.

The scarce resource is program memory, not time. A CSUB pasted into a
program costs its hex text as well as the binary it becomes: eight words to
a line is about 2.5 bytes of text for every byte of code, so a 44 KB kernel
wanted 152 KB of the PC3's 144 KB and AUTOSAVE stopped part way through with
`Not enough memory` (the tell is a missing `Saved nnn bytes`, after which the
rest of the transfer echoes at the prompt; the program that is left then dies
with `Internal fault 5(sorry)`, which is `CallCFunction` failing to find the
code). Building with `-O s` instead of `-O 2` took the kernel from 44 KB to
33 KB and cost nothing measurable: 0.217 ms a tick against 0.229. For the
game itself the CSUB belongs in the library, where `LIBRARY SAVE` keeps the
binary and throws the hex text away.

Run them in that order:

    python gen_world.py exile-disassembly.txt --check census/out
    python gen_tiles.py exile-disassembly.txt
    python gen_tables.py exile-disassembly.txt
    python gen_objects.py exile-disassembly.txt
    python render_window.py exile-disassembly.txt 0x96 0x47 ref_ship.png

Then copy `exile_tiles1.bmp`, `exile_slot2.bmp`, `exile_w1.map` and
`exile_w2.map` from `out/` to the board and run `Bas/exile/worldview.bas`.

There are three flash slots and the library takes the third, because that is
where the physics kernel has to live: a CSUB pasted into a program costs its
hex text as well as its binary, and there is not enough program memory for
both it and the game. So the graphics have two slots, not three, which they
fit because two of the three images were half empty:

| Slot | Holds | Of 144 KB |
| --- | --- | --- |
| 1 | `exile_tiles1.bmp`, tile variants 1-280 | 97% |
| 2 | `exile_slot2.bmp`: variants 281-399, then the object sheet below them | 85% |
| 3 | the library, with the physics kernel | 23% |

`TILEMAP` indexes its tiles from the top left of the image and `BLIT FLASH`
takes pixel coordinates, so one image serves both: the tileset's last rows
are the first 480 of slot 2 and the objects follow, with the y in
`objects.bas` already counting them. Objects are blitted with transparent
colour 2 (the key colour, a green the BBC palette never produces, so black
inside a sprite stays black). Slot 1 is the one with no room left, 4 KB
spare, so any growth in the tileset has to go into slot 2's remaining 21 KB.

## What the checks are worth

The world generator is checked square for square against an independent
transcription (Jon Saffron's C# ExileWorldGenerator), and the tile renderer's
landing site is identical to that generator's own drawing. On the board,
screenshots of the view at the ship (`2` in the viewer) and at Triax's lab
(`3`) match `render_window.py` pixel for pixel, including the tiles that
come from the second flash slot.

## Units and layout

A square is 16 x 32 of the game's pixels, which are 2:1, so a tile here is
32 x 32 screen pixels and world pixel (x, y) is drawn at (2x, y). Positions in
the game are a square plus an 8-bit fraction: 16 fractions to a pixel across
and 8 down. Tile variants are numbered most common first; slot 1 holds
variants 1-280 (99.7% of the drawn squares) and slot 2 the rest, so the second
`TILEMAP DRAW` finds almost nothing to do.
