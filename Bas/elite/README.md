# Elite on the PicoComputer 3

A port of the 1984 BBC Micro *Elite* by Ian Bell and David Braben, written in
MMBasic. The galaxy, the market, the ship blueprints and the flight model all
come from the published 6502 source, so Lave is the Lave you remember.

## Getting it running

You need a PicoMite HDMI build and a screen, and the firmware must be
**version 6.03.02b4 or above**, or b5 for the automatic library install below.
`PRINT MM.VER` at the prompt: it must report 6.030204 or more. Earlier firmware
will not do - b3 and before had `MAX3D` set to 8, where the bubble wants 12 objects for the station and a full complement
of ships, and the `DRAW3D` and `FRAMEBUFFER CLOSE` fixes this leans on all
landed after b3 was released.

It was written and timed on a PC3 running PicoMiteHDMIWEB at 378 MHz, where it
holds about 18 ms a frame; it will run slower on a slower clock. The program
sets `MODE 2` itself.

Elite comes in two files. `elite_lib.bas` holds the declarations - every
constant, every variable and the ship blueprints - and is installed as the
PicoMite's library; `elite.bas` is the code. One MMBasic program cannot be more
than 144 KB and this is heading past it, so the declarations are kept in the
library instead, where they cost the program nothing.

Copy both to the drive:

```
python Bas/elite_tools/pc3.py put Bas/elite/elite_lib.bas A:/elite_lib.bas
python Bas/elite_tools/pc3.py put Bas/elite/elite.bas     A:/elite.bas
LOAD "A:/elite.bas"
RUN
```

The first `RUN` installs the library and starts again by itself - that takes a
second or two. Every run after that finds the library already matches and goes
straight into the game. Nothing else to do: the program's first line is
`LIBRARY LOAD`, so it looks after its own library.

`LIBRARY LOAD` needs firmware **6.03.02b5 or above**. On b4 you can install the
library by hand instead - `LOAD "A:/elite_lib.bas"` then `LIBRARY SAVE`, once -
and then load and run `elite.bas` as normal.

The title screen is a picture file. Copy `Bas/elite/data/title.jpg` to the
drive as `A:/title.jpg` - `pc3.py put Bas/elite/data/title.jpg A:/title.jpg`
will do it. Without the file the title screen draws the words instead, so
nothing is broken if you skip this.

## Starting

The title screen waits for you.

| | |
|---|---|
| any key | start a game |
| `H` | the controls, on one page |
| `Esc` | leave the program |

Leave it alone for twenty seconds and the demo plays a whole game by itself - 
trading at Lave, a fight on the way out, a hyperspace jump and a docking at the
far end. Press any key during the demo and you get a game of your own.

`Esc` in a game takes you back to the title.

## Flying

| | |
|---|---|
| `<` `>` or left/right arrows | roll |
| `S` / `X`, or down/up arrows | climb / dive |
| `Space` / `/` | faster / slower |
| `A` | fire |
| `T` then `M` | lock a missile, then launch it |
| `E` | E.C.M., which destroys every missile in the area |
| `C` | docking computer on and off |
| `H` | hyperspace |
| `J` | in-system jump, when nothing but rocks is about |
| `G` | galactic hyperdrive, if one is fitted |
| `Tab` | energy bomb |
| `Esc` | escape pod if one is fitted, otherwise back to the title |
| `P` | pause; `D` while paused writes the screen to the card |
| `F1` `F2` `F3` `F4` | fore, aft, left, right views |

On either chart, `F` asks for a system name and moves the cursor to it, and
holding `Shift` with an arrow moves the cursor eight notches instead of one.

`F5` to `F10` reach the same six screens whether you are flying or docked:
galactic chart, short range chart, system data, market prices, status,
inventory. On the charts the arrows move the cursor and it picks out the
nearest system; `F7` then tells you about it. A view key or `Return` puts you
back where you were.

### The dashboard

Down the left: forward shield, aft shield, fuel, cabin temperature, laser
temperature, altitude. Down the right: speed, roll, dive/climb, and the four
energy banks. Red means trouble in both directions - a high reading is bad for
speed and the temperatures, a low one is bad for everything else.

The altitude bar is your height above the planet, and it reads full until you
are within about 65000 units of it; fly to one planet radius and you are dead.
Cabin temperature climbs as you approach the sun, reaches the fuel scooping
threshold at about 32000 units, and kills you at about 22400.

The ellipse is the scanner. Each contact is a dash with a stick down to the
plane you are flying in, so the stick tells you how far above or below you it
is, and its colour says what it is: **red** a rock, **blue** a canister or an
escape pod, **green** the space station, **magenta** a Python, **yellow** a
missile, **cyan** everything else. The dial to its right is the compass: it
points at the station when you are near one and at the planet when you are not,
yellow and two rows deep when the thing is ahead of you, green and one row deep
when it is behind.

Out of the window, ships are cyan, rocks red, a missile yellow, a Thargoid
white, and the planet and the sun green. A red beam across the view means
somebody is shooting at you.

## Docked

| | |
|---|---|
| `F1` | launch |
| `F2` / `F3` | buy / sell cargo |
| `F4` | equip the ship |
| arrows | choose a row |
| `Space` | buy or sell one |
| `Return` | buy or sell a stated number - type it and press `Return` again |
| `F` | fill the tank, on the equipment screen |
| `S` / `L` | save / load your commander |

The quantity prompt shows the most you could trade - what the system has, what
your money will cover and what the hold will take - and refuses a digit that
would take you past it, rather than accepting the number and quietly trimming
it. `Escape` backs out without trading.

Saving writes `A:/cmdr.txt`, which is plain text and one value to a line.

## Making a living

Buy what a system makes and sell it where they don't. Lave is a Rich
Agricultural world, so food and textiles are cheap there and
radioactives, computers and machinery are dear - an Industrial system further
along the chart is where you sell the one and buy the other. Prices are set the
moment you arrive and do not move while you trade.

A full tank is seven light years and costs 14 credits. On the galactic chart
the green circle is what the tank will reach; put the cursor on something
inside it, check `F7` for what is there, then launch.

**Hyperspace only works once you are clear of the station's zone**, which means
flying away from it for about half a minute at full speed. Press `H` when you
are out.

## Docking

The station turns all the time, and its docking slot is a letterbox. Getting in
means five things at once: the station not angry with you, its slot facing you,
the station nearly dead ahead, and your wings lined up with the long axis of
the slot - which means rolling to match a station that will not stop turning.

Below speed 5 a failed approach is a bump. Above it, it is the end of you.

The docking computer (`C`) does the whole thing, including the rolling - and
that is ours, not the original's. In the cassette version pressing `C` docks
you instantly; the flown approach only appeared in the later 6502 Second
Processor and Master versions. You have to buy the computer either way: a new
commander has a front pulse laser, three missiles, seven light years of fuel
and nothing else, so every docking is hand-flown until you can afford 1500 Cr.

## The law

Slaves, narcotics and firearms are contraband, and slaves and narcotics count
double. Leaving a station with any of it aboard goes straight onto your record,
and out in space it is what you are **carrying** that calls the police out - 
your record only makes things worse once a Viper is already watching you. Shoot
one and you are a Fugitive on the spot. Arriving somewhere new halves whatever
is on your record, because nobody that far away has heard the details.

Where you are matters as much as what you have done. An anarchy spawns roughly
four times the pirates of a Corporate State, which is what the government
column on the system data screen is telling you.

## How it is put together

Two files, and the split is not arbitrary. `elite_lib.bas` is the declarations
and the ship data - `src/00_main.bas` and `data/ships.bas`, which between them
contain not one executable statement. `elite.bas` is everything else. A
PicoMite library initialises itself before the program's first line, so the
constants and variables are in place before any code runs, and `RESTORE` finds
a label in the library from the program because the two halves share one table
of subroutine, function and label names.

Measured on a PC3: the program is 80 K of the 144 K a program may have, and the
library 19 K of its own 144 K. As one file, before the extra ships, it was 91 K.

The bubble holds eighteen ships and the firmware allows 32 Draw3D objects, so
every ship in it can be a mesh. An object is asked for when a ship comes into
mesh range and given back when it leaves, rather than taken for life when the
ship is created - which used to hand the pool to whichever ships arrived first
and could leave a Cobra filling the screen drawn as a dash while a speck on the
horizon held an object. What limits a crowded bubble now is the frame, not the
pool: seventeen ships all close at once costs about 76 ms a frame, where five
costs 41. The game's speed does not depend on the frame rate, so a busy moment
looks choppy rather than running fast.

The library also carries `OPTION LOCAL VARIABLES 128`, which has to be the
first thing executed anywhere and so can only go there. MMBasic splits a fixed
pool of 736 variable slots between locals and globals, and the default leaves
only 480 globals - Elite declares 374 of them, and a constant costs a slot just
as a variable does. At 128 locals there are 608, and measured on the board
there is room for 243 more.

Three rules come out of the split, and `build.py` now checks all of them
rather than leaving them to be remembered.

**The trace cache stays in the main program.** `OPTION TRACECACHE`, `OPTION
CACHE` and every subroutine they name must be in the program, never the
library: the cache compiles a subroutine against the program it was prepared
from.

**A library must contain nothing program-specific.** It runs its top level in
front of *every* program, not just its own. `OPTION CACHE SUB` names two of
Elite's subroutines, and with it in the library no other program would start at
all - `Sub/function not found` before its first line. `build.py` moves it, and
every option not required to precede a `DIM`, into the program.

**And there must be no `END` in a library** - the interpreter runs the whole of
it at `RUN`, and an `END` would stop the run before the program began.

## What the later BBC versions had

This is a port of the cassette version, which is the one most people played and
the smallest of the family. Elite went on being rewritten, and the BBC Micro
disc version, the 6502 Second Processor version and the BBC Master all carry
things that are simply not in the cassette game and so are not here either.

From the **disc version** (and the Master, which is built on it):

- Kill credit for canisters, asteroids, escape pods and Thargons - which this
  port already gives, having been written to the simpler rule. The cassette
  game awards nothing for junk; this and the disc version award for everything.
- A real docking computer that flies you in, which is where our flown approach
  comes from.
- A disc access menu and printer support.
- Ships carrying the NEWB flags - the pirate, trader, hostile, cop and innocent
  markers that the disc version's spawner works from. Ours reproduces the
  cassette version's own spawning rules instead.

Taken from it so far:

- **Buying and selling a stated number of tonnes** rather than one at a time.
  `Space` still trades one, so nothing that used to be quick got slower.
- **Mining and military lasers**, at the original's own powers and prices: a
  mining laser is 50 at 800 Cr, a military laser 151 at 6000 Cr - and 151 has
  the top bit set, so it fires continuously like a beam at half again a beam's
  damage. Both appear at tech level 9, which is where the original unlocks the
  whole list at once.
- **The system descriptions**, built from the disc version's extended token
  table. The cassette game's data screen stops at the planet's radius; this
  adds the paragraph underneath, and it is the disc version's own, because the
  generator is seeded from the system's two seeds before it starts choosing.
  Lave really is most famous for its vast rain forests and the Lavian tree
  grub.
- **Moving the chart cursor a long way with SHIFT**, eight notches at a time.
  This one needed the firmware: it reported shift with the down and right
  arrows as DOWNSEL and RIGHTSEL but gave shift with left and up no code of
  their own, so only half the feature was reachable. They are now LEFTSEL
  (&HA2) and UPSEL (&HA4).
- **Finding a system by typing its name.** `F` on either chart asks for a
  name and moves the cursor to it. The cassette game has no such thing - you
  hunt for the dot yourself, and with 256 systems to a galaxy that is a chore.
- **Asteroids worth splitting.** A mining laser is the only thing that breaks a
  rock into anything: an asteroid or a rock hermit gives nought to three
  boulders, a boulder gives splinters, and a splinter scooped is minerals - or,
  one time in eight, gem-stones. Anything else you shoot a rock with simply
  destroys it, as before.
- **The two missions.** The whole of both of them is four bits in one byte -
  the original calls it TP - and every branch of what happens when you dock
  comes out of those four bits. Reach a combat rating of Competent with 256
  kills in one of the first two galaxies and the Navy asks you to hunt down a
  stolen Constrictor; it is hiding in the second galaxy at galactic
  coordinates (144, 33), which our own galaxy generator turns into Orarra,
  and nothing but a military laser will scratch it - then only at a quarter
  of the damage it would do to anything else. Five thousand credits and 256
  kill points for bringing it down. In the third galaxy, once that is done
  and you are most of the way from Dangerous to Deadly, Naval Intelligence
  wants the Thargoid defence plans carried from Ceerdi (215, 84) to Birera
  (63, 72); while they are aboard the Thargoids come after you on one
  spawning pass in five, and delivering them earns the Navy's own energy
  unit, which recharges half as fast again as the one the shops sell.
  The briefings are the original's own words, from the extended token table.
- **The Dodo station.** A system of technology level 10 or above has a
  dodecahedron rather than a Coriolis - which is to say a screen that reads
  technology level 11 or better, because the data screen shows one more than
  the number the game works in. It is not a second station and it needs no
  code of its own: the original swaps the blueprint that the space station
  ship type points at, and our five docking tests read the station orientation
  vectors rather than its shape, so they work on either without being told
  which one is in front of them.
- **The ship hangar**, which is what you see for a moment when you dock. Half
  the time it is one of the original's four groups - a Shuttle and a
  Transporter, three cargo canisters, or a Viper and a Krait at one of two
  spacings - and half the time a single Sidewinder, Mamba, Krait or Adder
  somewhere random. Each is spun on the spot so it can face any way, and the
  height each stands at comes from the square root of its targetable area, so
  a big ship sits higher off the deck than a small one. The floor is the
  original's eleven lines at 130/n below the centre for n from 2 to 12, and
  the back wall its fifteen verticals up to the horizon.

From the **6502 Second Processor version**, which had a whole second computer
to spend - and which this port now follows, because a PicoComputer has that
much spare and a great deal more:

- **Colour in space.** The cassette game's space view is black and white. The
  Second Processor's has four colours, and its two tables say what gets which:
  ships are cyan, a missile yellow, rocks red, a Thargoid white, and the planet
  and the sun green. Both tables are the original's, read out of its source.
- **Six colours on the scanner**, which is the best of the lot: a rock is red,
  a canister or an escape pod blue, the station green, a big fat Python
  magenta, a missile yellow, everything else cyan. You can read the bubble at a
  glance now instead of flying over to look.
- **Lasers in red** - both ours and theirs. Being shot at also *looks* like
  something at last: a ship that fires draws a red beam across the screen, as
  every version from the cassette on has, and which this port did not.
- **A bigger bubble.** Ten ships and four police become eighteen and seven.
- **The Cougar**, which appears in no earlier version and is the rarest thing
  in Elite - about one spawning in nine thousand. It sits still and ignores
  you, because it was given no AI, which is the original's way of faking a
  cloaking device. Shoot at it and it wakes up with a beam laser, four
  missiles, an E.C.M. and an aggression of sixty out of sixty-three.
- **Rock hermits that are not just rocks.** One asteroid in eighty is somebody's
  house. It sits there ignoring you - the original gives it no AI at all - but
  shoot at it, as shooting at anything turns its AI on, and from then on there
  is about one chance in five, each time it is serviced, of a Mamba, Krait,
  Adder or Gecko coming out of it with an E.C.M. and an aggression of 56 out of
  63. It settles down again afterwards, so the next one costs another shot.
  (The original's own comment says the pick includes a Sidewinder; its
  arithmetic says otherwise, because the carry is set by the time it reaches
  the addition.)
- **The station's own traffic.** A Shuttle or a Transporter, about one pass in
  128, and never a second while the first is still about - which is what the
  two fat slow ships in the hangar are for. Neither carries a laser, so the
  aggression the original hands them only means they come over for a look.
- **A screenshot key.** Press `P` to pause, then `D`, and the frame is written
  to the card as `SCREEN1.BMP`, `SCREEN2.BMP` and so on - which is what CTRL-D
  does there.

- **Its ships.** The cassette game has twelve designs; thirteen more are here,
  taken from the Second Processor source through the same generator: the Krait,
  Adder, Gecko, Cobra Mk I and Worm that fill out a pirate pack, the Asp Mk II
  and Fer-de-Lance a lone bounty hunter flies, the Boa and Anaconda that make a
  fat trader worth stopping, and boulders, splinters and rock hermits among the
  rubble. They arrive by the original's own rules: a pirate group is drawn with
  the AND of two random numbers so the small fighters come up far more often
  than the Cobra, and a rock hermit is about one asteroid in eighty. The
  Shuttle and the Transporter joined them with the hangar, which is where the
  fat end of that list is easiest to see.

Still missing from it: the log tables and Bitstik support, both of which are
meaningless here. The Moray is missing from
the Second Processor version too - it picks a lone bounty hunter from types 24
to 27 and the Moray is 28, so nothing in that game ever spawns one either.

None of the rest is difficult in the way the cassette game was difficult: the
blueprints for the Dodo and the rest are published, and the extended token
table is only data. It is a question of program memory, which is the one thing
here that is genuinely tight.

## How close is this to the real thing

Almost everything the cassette version does, it now does. The galaxy, the
market, the ship blueprints, the flight model, the tactics, the spawning, the
legal model and all five docking tests are the original's own arithmetic.
Ships are wireframe with the hidden faces removed, decided from the blueprint's
own face normals, as the original decides it. The cassette version has no
missions, and no mining or military lasers, so none of those are missing.

Three things here are deliberately not the cassette version's. The colour is
the first, and the section above says where it comes from: a cassette Elite is
black and white out of the window and one colour on the scanner. The second is
the flown docking approach described above. The third is the space station,
which is given black faces behind its edges so that it blots out the planet,
the sun and the stardust instead of showing their lines straight through
itself - on a BBC the station is hollow like everything else, and a planet's
great circles run across its face. Every other ship is left hollow, as it
should be. Switch the station back with `STNSOLID = 0` in `00_main.bas`;
filling it costs about eight tenths of a millisecond a frame at docking range
and does not move the frame rate, which is paced by the display rather than by
the drawing.

The sound is the original's ten effects, converted from the SFX table in its
source. Five of the ten are its exact numbers; the other five ask for sound
envelopes that the cassette *loader* defined rather than the game, so those are
approximated by a pitch sweep and are marked as approximated in the table and
in `tests/sfxtest.bas`, which plays all ten by name so they can be judged.

What is left:

- **The hyperspace countdown.** The jump happens at once behind its tunnel of
  rings; the original counts down from 15 while you keep flying, and you can be
  attacked during it.
- **The pace.** Every one of the original's constants is per iteration of its
  main loop, which ran at something like ten or twelve a second. The game now
  scales by how much of one of those iterations each frame is worth, so the
  speed no longer depends on the frame rate, but the rate itself - `TICKRATE`
  in `00_main.bas` - is an estimate rather than a measured fact.
- **No indicator for the safe zone.** Getting clear of it to hyperspace takes
  about half a minute of flying away from the station and nothing tells you
  when you are out; press `H` and see.
- **Equipment cannot be damaged.** In the original a hit can take out your
  E.C.M.

Everything else on this list has been closed: sound, in-flight messages, the
per-view laser mounts, cargo scooping and fuel scoops, the altitude and cabin
temperature gauges with the planet and the sun that drive them, collisions,
the escape pod, the energy bomb, the in-system jump, the other seven galaxies,
ships that fire missiles at you and jam yours with their own E.C.M., pilots
who bail out of a dying ship, and equipment that has to be bought before it
works.
