# Thrust port tools

Working directory for the MMBasic port of Thrust (Jeremy C. Smith, Superior
Software, 1986). The plan is `docs/Thrust_Port_Plan.html`.

## The disassembly is not vendored here

These scripts read Kieran HJ Connell's reverse-engineered source, which carries
no licence and sits in a repository that also contains a disk image of the
commercial game. Fetch it yourself and leave it out of this tree:

    git clone https://github.com/kieranhj/thrust-disassembly
    # or just the one file:
    curl -LO https://raw.githubusercontent.com/kieranhj/thrust-disassembly/master/thrust.6502

Then point the scripts at it:

    python thrust_terrain.py path/to/thrust.6502

Its `docs/ship-physics.md`, `docs/landscape-drawing.md` and
`docs/sprite-drawing.md` are the three references the port plan is built on.

## Scripts

| Script | What it does |
| --- | --- |
| `thrust_terrain.py` | Decodes the six RLE terrain levels and reports how many merged rectangle fills one screenful of cave costs. This is the measurement the renderer design rests on. |
