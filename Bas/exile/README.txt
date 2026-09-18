================================================================
 E X I L E        for the PicoMite            version 0.9
================================================================

A port of Exile (Superior Software, 1988) for the BBC Micro.

This is not a remake.  The creatures, the physics, the weather and
the planet are the original's, driven by a transcription of the
game's own 6502 code, checked against it instruction by instruction.


THE STORY
---------
You are Mike Finn, a leading member of the space-exploration
organisation Columbus Force, ordered to the planet Phoebus on a
rescue mission.

Somewhere below you are Commander David Sprake and what is left of
the crew of the Pericles, a ship disabled and stranded on Phoebus.
Getting them off it is your job.

What stranded them is still down there.  Triax - the exile of the
title - is a genetic engineer, a renegade, and by every account
that reached Columbus Force, insane.  The creatures of Phoebus are
largely his work.

He does not wait for you to land.  At the very start of the game he
appears aboard your own ship, the Perseus, long enough to take the
Destinator - a piece of equipment you cannot leave the planet
without - and is gone again.  You will have to go and get it back.


THE PLANET
----------
Phoebus is a single connected world of caves, chasms, seas and open
sky, and you may go anywhere in it from the first minute.  Nothing
is locked off by chapter; what stops you is what you are carrying,
what you have learned, and how much energy you have left.

The game explains nothing.  That is deliberate, and it was
deliberate in 1988: almost everything in Exile is discovered by
trying it.  Objects you find have uses that are not written down.
Creatures have habits, and the habits can be used.  If something
seems to react to you, it probably does.

Three things are worth knowing before you start, because the
original's packaging said them too:

  - Your jetpack is not a weapon.  A new game carries nothing else,
    so the fire key does nothing until you find something that
    fires.
  - Energy is everything.  It runs your jetpack, your weapons and
    you.  You can pour it from one thing into another.
  - You can carry only so much.  Pockets hold objects you are not
    holding; there are five.


INSTALLING
----------
You need PicoMite firmware 6.03.02b7 or later.  The game checks and says
so if the board is older; PRINT MM.VER at the prompt reports what you
have.

Copy the whole Exile folder onto a drive on the board, keeping the
files together.  It does not matter which drive, or what the folder
is called - the game finds everything beside itself.  Then:

    RUN "B:/Exile/exile.bas"

That is the only command needed.

On a board with PSRAM the game's kernel is loaded into RAM as a
library at every start and the flash library is never touched, so
whatever you keep there stays.  Without PSRAM the first run installs
the kernel into the flash library instead, and if the board already
holds a library belonging to another program it will ask once before
replacing it.

On a board with PSRAM (the PicoComputer 3 has it) the two tilesets
are loaded into RAM at every start, which takes a moment and leaves
the flash slots alone.  On a board without PSRAM the first run
writes them into flash slots 1 and 2 instead, which takes about a
minute; every run after that starts in a second or two, because they
are already there.  They stay in flash between runs and between
programs, and to take them out again:

    FLASH ERASE 1
    FLASH ERASE 2

The game needs the whole folder at run time, not just at install
time: it reads the world, the tables and the sprite index from it
every run, and writes saved games back into it.


THE KEYS
--------
These are the BBC Micro's own keys, with three of this port's added.

  Moving
    Q  W        thrust or walk left and right
    P           thrust up.  P is two of the game's keys at once: it
                also jumps on the press, which is what moves you
                when the jetpack is empty
    L           thrust down
    @           booster - doubles the thrust while it is held
    CTRL        lie down
    TAB         turn round

  Fighting
    SPACE       fire
    F1 - F10    choose a weapon.  F1 is the jetpack, which fires
                nothing.  With shift, pour energy from the weapon
                in use into the one chosen
    I  K  O     centre, lower and raise the aim

  Handling things
    ,           pick up               M    drop
    .           throw                 S    store in a pocket
    G           fetch back from a pocket

  Elsewhere
    T           teleport to a remembered place
    R           remember this place
    Y  U        play whistle one, play whistle two
    V           sound on and off
    arrows      move the view without moving yourself

  This port's own
    F11         save the game
    F12         restore it
    ESC         stop

Saving and restoring say so in the panel for a couple of seconds,
and write three .sav files into the game's own folder.  There is one
save slot.  The original saved to tape through its loader, which is
no use here, so this is new.


ABOUT THIS PORT
---------------
The part of the game that decides what happens - all sixteen
creature slots, the collisions, the weather, the tile routines, the
events - is a transcription of the original 6502 code into C, run
as a CSUB.  It is checked against the real thing by replaying 128
recorded scenes, 16,219 ticks, and comparing every byte of state
after every tick.  At the time of this release all of them match.

What is NOT the original:

  - The panel down the right-hand side.  The BBC version had no
    status display of any kind.  It costs 64 pixels of width, and
    from the top it shows:

      ENERGY     yours.  At zero you are in trouble
      JETPACK    what is left in it
      POCKETS    how many of the five are in use
      WEAPON n   which one the function keys have chosen, and its
                 own energy.  Weapon 0 is the jetpack
      X, Y       which square of the planet you are standing on.
                 The world is 256 squares by 256, so each runs 0 to
                 255.  Quote these if you report something
      TICK       milliseconds the game itself took, averaged over
                 the last twenty-five frames
      DRAW       milliseconds drawing it took, the same way

    TICK and DRAW together have to fit inside 40 ms, which is the
    rate the BBC's own screen refresh fixed the game at.  They are
    there because this is a test release; if they are a distraction
    they can go.
  - The view is 256 x 240 pixels - eight squares across by seven and
    a half down - which is slightly narrower than the BBC's, so a
    little less of the planet is in sight at once.  That matters
    more than it sounds: creatures are created when the ground they
    stand on is drawn, so a narrower view meets marginally fewer of
    them.
  - Saving and restoring, and the ESC key.

KNOWN GAPS in 0.9
-----------------
  - The particles - dust, the jetpack flame, explosions - are close
    to the original but not exact.  The BBC decided a particle's
    fate by reading back the pixel it had just drawn on the screen,
    and there is no screen here to read back.  They look right;
    they are not identical.
  - The BBC's on-screen map is not in yet.


IF SOMETHING GOES WRONG
-----------------------
Please say which version you are running - it is printed as the game
loads - where you were, and what you were doing.

If the planet itself looks wrong, rather than the creatures in it,
the tileset files in the folder are probably from another version of
the game: reinstall the folder.  On a board without PSRAM another
program may instead have left an image in the flash slots.  The game
checks for both and says so, but if it starts and the scenery is
nonsense, try:

    FLASH ERASE 1
    FLASH ERASE 2

and run it again.

If it stops at once with "Unknown command" and asked you nothing, the
board is carrying another program's library.  There is only one library
slot on the machine, and Exile's kernel needs it.  Firmware up to and
including 6.03.02b9 can lose track of what is in that slot, so Exile is
told it already has its library when it has not.  The cure is:

    LIBRARY DELETE

and then run the game again.  Be aware that this removes whatever
library was there, so if another program put it in, that program will
need to install it again.

If the game stops with an error, the board remembers it: at the
prompt, PRINT MM.ERRNO, MM.ERRMSG$, MM.ERRLINE will say what and
where.  Those three, with the version, are the most useful thing
you can send.


Exile was written by Peter Irvin and Jeremy Smith and published by
Superior Software in 1988.  This port carries none of their code -
only their design, transcribed.
