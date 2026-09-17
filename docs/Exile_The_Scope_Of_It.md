# Exile: the scope of it

*What the PicoMite port actually contains, and what it took to do the same thing
in 1988 on a machine with 32 KB.*

---

## The machine they had

A BBC Micro Model B: a 6502 running at 2 MHz, 8 bits wide, with **32 KB of RAM
and no more** — and the screen comes out of that same 32 KB.

Exile takes essentially the whole of it. The game image runs from `&0200` to
`&7FFF`, and the top 8 KB of that is the screen: `&6000` upward holds a 128 x 128
pixel display at four bits a pixel. Everything else — every routine, every table,
every variable the game owns — lives in the **23.5 KB** underneath.

In that 23.5 KB there are **8,528 instructions**.

The game runs at 25 frames a second, because the player's redraw waits for two
of the BBC's 50 Hz screen refreshes. At 2 MHz that is **80,000 clock cycles per
frame** — call it twenty-five thousand instructions — to run the whole world
*and* draw it.

---

## What runs in that budget

**A planet of 65,536 squares.** The world is 256 by 256, each square a tile of
16 x 32 pixels: caves, seas, chasms, open sky, all one connected place you can
walk or fly across from the first minute. 38,341 squares are solid rock, 26,213
are open (1,308 of them windy), and 802 carry some feature — a nest, a pipe, a
switch, a door, a transporter.

**A hundred and one kinds of thing**, from the player and the crew to birds,
imps, frogmen, worms, slimes, piranha, wasps, robots, gargoyles, fireballs,
grenades, flasks, pills, whistles, keys and Triax himself.

**Physics in 8.8 fixed point.** Every object has a position as a square plus a
fraction of a square, a velocity capped at a fixed maximum, gravity pulling it
down one unit a tick, inertia bleeding a unit off every sixteen ticks on a
counter offset per object so they do not all lurch together, and buoyancy taking
seven-eighths of its velocity every fourth tick underwater. Wind pushes things
about. The ground is not a grid of blocks: each tile carries an obstruction
profile — the height of solid matter in each of its eight columns — so slopes are
slopes and you walk up them.

**Creatures that behave.** They have moods and respond to stimuli. They look for
you along a line of sight that the waterline can block. When the way is barred
they try four random angles within a range and take the first clear one, or the
longest if none is clear.

**And on top of that**: 32 particles of eleven kinds for dust, flame and
explosions; a four-channel sound engine with two-stage envelopes driving 49
distinct sounds; earthquakes; a flood; doors that open and close on timers;
objects you can pick up, throw, pocket, retrieve and teleport.

---

## The three ideas that made it fit

**The world is not stored — it is computed.** There is no map in those 32 KB.
The planet comes out of a generator: ask it for a square and it tells you what is
there. 65,536 squares for the price of the algorithm.

**Objects live at three levels of detail.** Only **16** objects are fully
simulated at once. Another **32** are remembered as little more than a position.
Below those, **254** more are a single byte each, sitting in the world until you
come near enough to matter. Creatures are promoted as you approach and demoted as
you leave, so the planet stays populated everywhere while the machine only ever
does sixteen objects' worth of work.

**Nothing is drawn that the hardware can move instead.** The screen scrolls by
reprogramming the CRTC's start address, not by shifting 8 KB of pixels. Only the
newly uncovered strip gets drawn.

And underneath, the small economies of someone counting every byte. Tables of
object properties interleaved into 11-byte records so one index reaches all of
them. A `BIT` instruction used purely to swallow the byte of the instruction
after it, so two exit paths can share one tail. A rotate that folds a flag into a
value while keeping the rest. A lookup deliberately allowed to run off the end of
a table, because the answer could not matter.

---

## What the same game costs us

The PicoMite port ships **895 KB** — nearly thirty times the whole machine they
were working in:

| | |
|---|---|
| Tile pictures | 290 KB |
| The world, as data | 479 KB |
| The game kernel | 92 KB |
| Everything else | 34 KB |

Almost all of that is the world. We *store* what they *computed* — every square's
tile index and every square's type, worked out in advance on a desktop, because
it is cheaper for us to ship half a megabyte than to run their generator. The
tile pictures are the same story: they drew roughly four hundred distinct
squares from one sprite sheet using flips and palette substitution, and we keep
the four hundred finished pictures.

The processor is a 32-bit core at 378 MHz — **189 times the clock**, with a far
better instruction set and hardware multiply. The game logic, transcribed
instruction for instruction into C, takes **0.28 ms** a tick. Drawing the frame
takes **6.8 ms**.

They did the logic *and* the drawing in 40 ms, at 2 MHz, in 8 bits.

---

## The point

The port is faithful: the kernel matches the original tick for tick across 128
recorded scenarios and 16,219 ticks, every byte of shared state compared after
every tick. That is how we know it is really their game and not an impression of
it.

Which means the credit is all one way. Peter Irvin and Jeremy Smith put a living
planet — physics, weather, ecology, a hundred kinds of creature, and a world of
65,536 places — into 23.5 KB of 6502, and made it run in 80,000 cycles a frame.
Thirty-eight years of hardware later, doing the same thing takes thirty times
the storage and a hundred and eighty-nine times the clock.

It is worth remembering what that used to be worth.
