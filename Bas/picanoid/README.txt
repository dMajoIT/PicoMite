Picanoid for the PicoMite
=========================

A bat-and-ball brick game for the PicoMite, in the style of the 1980s
originals.  The title screen and all of the sound are original work.

Copy this whole directory to the board, keeping the files together, and

    RUN "picanoid.bas"

The program finds pic_art.bmp beside itself with MM.INFO(PATH), so the
directory can sit anywhere on any drive.  That one image holds the bricks,
every sprite and the title screen, and it needs one image slot.

On a board with PSRAM (the PicoComputer 3 has it) running 6.03.02b11 or
later it goes into RAM slot 1 - image slot 4 - at every start, which takes
a few tens of milliseconds and leaves all three flash slots alone.  Without
PSRAM it is written into flash slot 1 the first time the game runs and
checked, not rewritten, after that; flash slots 2 and 3 are left alone
either way, so a LIBRARY and this game can live together.

Needs an RP2350 (the brick field is a TILEMAP), MODE 2, firmware 6.03.02b8
or later, and a mouse.

Player's guide: docs/Picanoid_Player_Guide.md in the PicoMite repository.
