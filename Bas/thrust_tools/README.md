# Thrust port tools

Working directory for the MMBasic port of Thrust (Jeremy C. Smith, Superior
Software, 1986). The plan is `docs/Thrust_Port_Plan.html`.

## The disassembly is not vendored here

These scripts read Kieran HJ Connell's reverse-engineered source, which carries
no licence and sits in a repository that also contains a disk image of the
commercial game. Fetch it yourself and leave it out of this tree (it is in
`.gitignore`):

    curl -LO https://raw.githubusercontent.com/kieranhj/thrust-disassembly/master/thrust.6502

The scripts look for `thrust.6502` beside them, or at `$THRUST_6502`, or at a
path given as the first argument. Its `docs/ship-physics.md`,
`docs/landscape-drawing.md` and `docs/sprite-drawing.md` are the three
references the port plan is built on.

## Scripts

Every generator writes a `.bas` fragment into `out/` and most will also draw
what they extracted, which is how the extraction gets checked.

| Script | Emits | Verify with |
| --- | --- | --- |
| `gen_terrain.py` | `terrain.bas` — the six levels' RLE, decoded on the board at level load | `--stats` for the fills a frame costs, `--png` to draw all six caves |
| `gen_objects.py` | `objects.bas` — guns, fuel, pods, reactors, door switches | `--png` to draw them into the caves; the default run checks none is buried in rock |
| `gen_sprites.py` | `sprites.bas` — 17 ship headings, pod, shield and nine object shapes | `--png` for a contact sheet, `--art` for ASCII |
| `gen_sound.py` | `sound.bas` — four envelopes and nine sound blocks as `PLAY BBC` | play it on a board; see the envelope 2 note in the output |
| `thrustdata.py` | shared disassembly reader, colours and geometry | |

## What the checks are worth

`gen_objects.py` reports how much of each object sits inside rock. Across all
six levels every gun comes out at exactly 0.25 buried, every fuel cell at
0.30, every pod and door switch at 0.00 and every reactor at 0.10. Those
figures are identical level to level because the level designer placed objects
against the wall, so they only come out that clean if the terrain decoder and
the object tables agree to the column. If a change makes them scatter,
something has moved.

## Units

One terrain column is four BBC pixels and one terrain scanline is two, on a
display whose pixels are about 1.07x wider than tall. Keeping the game's
arithmetic in world units and scaling by 4 and 2 on the way to the screen
reproduces the original geometry, and keeps the deliberately elliptical
angle-to-force tables correct.
