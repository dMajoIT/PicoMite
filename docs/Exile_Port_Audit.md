# Auditing the Exile port against the original

## What the scenes actually prove

The port is trusted because eighty recorded scenes match the original tick for
tick, slot for slot, 9,980 ticks of them, on the desktop and on the board. That
is a strong claim, but it only reaches as far as the scenes go.

So the first question of any audit is not "is the code right" but "what has
never been looked at". That can be measured rather than guessed:
`Bas/exile_tools/audit_coverage.py` runs every scene on the 6502 interpreter
with the program counter recorded, and reports each labelled routine in the
listing as reached or not reached.

    python audit_coverage.py exile-disassembly.txt --csv coverage.csv

## The result

| | routines |
|---|---|
| in the game's own code | 1,531 |
| reached by at least one scene | 1,127 |
| never reached by any scene | 404 |
| in the loader, the screen or the sound chip, which the port does not model | 261 |

So roughly a quarter of the game's own code has never been compared with
anything. A routine in that quarter may be perfectly transcribed or completely
wrong; nothing here can tell the difference yet.

## The gaps that matter

**Eleven of the hundred and one object types have never been run.** Each is
written and compiles, and none has ever been checked.

    active grenade      dense nest        engine fire       gargoyle
    inactive chatter    invisible frogman sucking nest      switch
    tracer bullet       whistling bird    yellow slime

**Most of what the player can do has never been run.** The scenes walk, fly,
push, carry, throw, teleport and collect, but they never:

    fire a weapon           change weapon or move energy between weapons
    raise, lower or centre the aim
    blow either whistle     drop what is held with shift
    move the view on its own            pause

Firing is the one that matters most. It is a core action, it is reached by a
key the scenes never press, and the code behind it creates objects, spends
energy and rolls for reliability.

Why the scenes miss it is simple: a new game has no weapon collected and the
jetpack selected, so pressing the key does nothing and nothing downstream runs.
Testing it needs a scene that starts with a weapon in hand.

**Some machinery has never been run**: switches and their effects, doors
actually toggling, stone doors, water and wind tiles, the invisible switch.

## What this does not tell you

Coverage says a routine ran, not that the port agrees with it. A routine that
is reached is checked properly, because the comparison is field by field on
every tick. A routine that is not reached is unchecked, full stop.

It also says nothing about the parts that were never meant to match: the
particle system is close rather than exact by design, and sound is not compared
at all because the recording does not carry it.

## What the first pass found

Acting on the list above, in one sitting:

**The player's weapons were right all along.** Six scenes now fire the pistol,
the icer and the plasma gun, change weapon with a function key, pour energy
between weapons with shift, move the aim and blow both whistles. All six
matched first time. Nothing had ever asked them, and the answer was yes.

That took fixing the test rig rather than the port. The first run failed at
the tick the first shot should appear: the game made a bullet and the kernel
made nothing. It looked exactly like a bug in firing. It was not: a scene can
now set the game up before its first tick, and the kernel's starting state was
still being built from the untouched image, so it had no weapon either and the
code under test was never entered.

**Ten of the eleven untested object types were right too.** Scenes now place
the invisible frogman, yellow slime, dense nest, sucking nest, active grenade,
tracer bullet, gargoyle, red magenta bird, inactive chatter, engine fire and
switch beside the player and watch them. All but one matched.

**One real bug, and it only appeared with two objects.** A dense nest and a
sucking nest side by side diverged at tick 82. Either nest alone matched for
all 150 ticks, so the fault was in the pair, not the pieces.

It turned out to be a table read running off the end. A sucking nest picks its
trigger, its power and its colour out of three nine-entry tables, indexed by
its own data byte. That byte is not bounded, and here it was &80. The game
reads straight past the end of its own table into the code that follows and
uses whatever byte is there. The port packs its tables next to each other in a
different order, so it read a different byte, decided the nest was still
working, and went looking for something to pull.

The fix is to pack those three tables a whole page long, so the port reads the
same bytes the game does when the index runs off the end. This is the sort of
thing only a comparison against the original can find: the code was a correct
transcription of the routine, and the routine reads out of bounds.

Ninety-four scenes now, 11,565 ticks, all matching.

## What the second pass found

The list above was worked through scene by scene. Sixteen more scenes, and
four more real faults — three of them from a single scene.

### The doors could never be opened

`update_door` and `update_transporter_beam` both call `consider_toggling_lock`,
one with the flag that says "a door" and one with the flag that says "a
transporter beam". The port had them the wrong way round. The flag decides
which key the lock asks for, so a door asked for a beam's key and a beam asked
for a door's, and nothing ever unlocked.

Every door on the planet starts locked. So this one swapped argument is why no
door in the port had ever opened, and why a player who walked into a closed
room could not get out again.

It had been invisible until now because reaching it takes a very particular
scene: the player has to be carrying the remote control device *and* the key of
the door's colour, standing within three tiles of the door, level with it and
facing it, and press fire. Get any of that wrong and the code is never entered
and the test passes anyway. That trap — a scene that proves nothing and looks
exactly like one that proves something — cost most of the effort here. A small
coverage probe now answers "did this scene actually reach that routine", and
every scene written to reach something specific is checked against it.

### Everything you carry sat on the wrong side of you

The routine that puts a held object beside the player ends with

    ADC #&10
    DEX
    JSR invert_if_negative

`invert_if_negative` tests the sign flag as it stands, and the `DEX` in between
has just set it from &FF. So the game *always* negates there; the comment in the
listing even says "not necessarily the sign of A". The port tested the value's
own sign, found it positive, and left it alone, so anything carried while facing
left was placed to the right instead.

### The remote control device stayed turned round

`create_aim_particle` flips the device to put its particles on the player's
side, and then runs off the end of itself straight back into
`flip_this_object_horizontally`, flipping it back. The port did the first flip
and not the second.

### Water made no debris

Wind and water tiles, while the tiles are being swept for an event rather than
for a collision, drop a piece of invisible debris into the air, up to four at
once, and insist on a slot for it even when all sixteen are taken. That is what
makes a river look as though it is flowing. The port had no such routine.

## Where it stands

| | routines |
|---|---|
| in the game's own code | 1,531 |
| reached by at least one scene | 1,255 |
| never reached by any scene | 276 |
| in the loader, the screen or the sound chip, which the port does not model | 261 |

116 scenes, 14,635 ticks, all matching. Most of the 276 are labels on variables
and tables rather than code. The behaviour still not reached by anything is:
dropping a held object because it has drifted too far, the earthquake and the
flood once they are running, a worm emerging, summoning Triax, a slime turning,
a mushroom ball becoming a crystal, Triax absorbing the destinator, a chatter
being activated, route finding, and the background flash of a coronium
explosion. Pause, the copy protection and the palette registers are in that list
too and are not the port's job.

## What this exercise is worth

Six real faults in two sittings, from a port that passed a hundred scenes
before it started. Not one of them would have been found by reading the code:

- a table read running off its own end into whatever follows, twice
- a carry taken from a shift the reader would not think to look at
- a sign flag set by an unrelated instruction
- a routine that falls through into the one after it
- two arguments the wrong way round, in code that looks right
- a routine simply absent

The lesson is the same each time. Reading finds what you thought about.
Comparing against the original finds what you did not.

## The second pass: a scene that passes may prove nothing

The first pass closed gaps by adding scenes. The second pass found something
worse than a gap.

Three scenes were written to exercise a particular routine, passed, and never
entered it. `remote_door` fired the remote control at a door the player could
not see from where it stood, because the acceptance cone is narrow and the
player was above the door rather than level with it. `cannon_fire` put the
cannon on the far side of a door, and a door counts as an obstruction, so the
control never arrived; moved clear of the door, the player then stood on a
ledge it slid off, and the shot missed anyway. `door_unlocked` claimed to toggle
a door open when what it actually shows is a door finishing its travel.

All three were green. A green scene that exercises nothing looks exactly like a
green scene that confirms something, and there is no way to tell them apart by
reading the list of results.

So the scenes now say what they are for. `gen_traces2.PROVES` names, for each
scene that has a subject, the routines it must reach:

    PROVES = {
        'cannon_fire': ['update_cannon', 'create_projectile_with_zero_velocity_y',
                        'update_cannonball'],
        ...
    }

and `audit_coverage.py --proves` checks each claim against *that scene's own*
coverage, not the pooled total. Measuring it against the pool would let any
other scene answer for it: the first attempt did exactly that and reported eight
false failures, because scenes run in alphabetical order and `door_auto` reaches
the door code before `remote_door` does.

A scene that stops exercising its subject now fails, instead of sitting green.

## What the second pass found

**The door and the transporter beam had their locks swapped.** `update_door`
called `toggle_lock` with the argument that means "transporter beam" and
`update_transporter_beam` with the one that means "door". A door decides which
key it needs from its own colour bits; a beam uses keys three to six. Each was
therefore consulting the other's rule. Nothing had ever unlocked either one, so
nothing had ever noticed.

**A held object sat in the wrong place.** The offset used `invert_if_negative`
where the `DEX` before it always sets the sign flag, so the game always inverts
and the port only sometimes did.

**The remote control device never made its aim particle**, and never performed
the second horizontal flip that the game falls through into, so it ended each
tick facing the wrong way.

**Four conversions had never run.** A fireball landing on a mushroom ball, a
green slime fed a coronium crystal, a red drop falling on a yellow slime, and a
chatter woken by a whistle. All four matched the game first time, for 440 ticks.

Getting the chatter to wake needed two facts that are not in the code as
written. Its energy reserve starts empty and it will not wake on an empty
reserve, so the scene fills it. And the key is U, not Y: the listing's key table
lists the two whistle handlers against the wrong keys, and the routine it calls
`handle_playing_whistle_two` is the one that tests whether whistle *one* has
been collected and sets `whistle_one_active`, which is what the chatter listens
for.

## The third pass: the events, and a borrow

Two of the last three gaps were the event system: creatures crawling out of the
ground. It takes a random tile within four squares of the player being solid
earth, one frame in sixteen, and the deeper the square the likelier, so the
scene stands at &a1,&c8, an open square with seventy-nine of its eighty-one
neighbours earth and far enough down for the odds to be worth having.

**It failed at once, and it was a real bug.** A worm came out with an x velocity
of minus three in the port and minus four in the game. The game aims a new
creature at the player with

    &26ab JSR &2760 ; spawn_object_in_event   # Returns carry set if it couldn't
    &26ae BCS skip
    &26b3 LDA &0891 ; objects_x + 0 (player)
    &26b6 SBC &95   ; tile_x

`spawn_object_in_event` returns carry *clear* when it made the object — the
branch above skips on carry set — so that `SBC` borrows. The port passed a carry
of one, and every creature in the game started off aimed one step wide. Fixed,
and the scene went from 127 ticks to all 200.

Reading that routine closely showed a second fault in the same eight lines. The
game weighs how many of that kind are left *before* it makes the creature, and
only calls `spawn_object_in_event` if the weighing passes. The port spawned
first and weighed afterwards, so a failed weighing would have left a creature
the game never made. Reordered; still 200 of 200.

## Some routines cannot be reached at all

The third gap was `find_route_to_target`, and it is not a gap: the listing marks
it **"Unused entry point"**. Every real call goes to
`find_route_to_target_with_angle_range_A` two bytes further on. The same is true
of `explode_object_with_duration_from_energy`, which had also been sitting in
the list of things to write a scene for.

So `audit_coverage.py` now reads that marker and counts those separately. Six
labels carry it:

    get_and_plot_tile                 dampen_this_object_velocities_four_times
    divide_by_sixteen                 find_route_to_target
    create_primary_object_from_tertiary_if_eight_slots_free
    explode_object_with_duration_from_energy

Three of the six had been on the list of gaps. No scene can reach them however
many are written, and an audit that keeps asking for them is one that can never
be finished.

## Where it stands

| | |
|---|---|
| scenes | 124 |
| ticks compared | 15,591 |
| failures | 0 |
| routines reached | 1,263 of 1,531 |
| claims checked | 27, all met |

Nothing is left that names a behaviour and has never run. What is still
unreached is tables, branch labels inside routines that do run, the six entry
points nothing calls, the pause, the copy protection and the palette registers,
none of which the port models or could reach.

That is not the same as saying the port is right. It says every routine the
game's own code can reach has been compared with it, field by field, on every
tick of every scene. A routine that has run under one set of conditions can
still be wrong under another, which is exactly what the worm showed: the
emergence code had been running through three passes of this audit, inside
scenes that never once watched a creature emerge.
