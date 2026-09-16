# Auditing the Exile port against the original

## What the eighty scenes actually prove

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

## What to do about it

Close the gaps by adding scenes, in this order:

1. The player's weapons: a scene that starts with one collected and fires it.
2. The switches and doors, which are how the world opens up.
3. The eleven object types, a scene each, placed where they live.
4. The aim, the whistles and dropping with shift.

Every scene added is cheap to run and permanent, and each one either confirms
a piece of the port or finds a fault in it. Both are worth having.
