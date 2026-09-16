"""gen_exilegame.py - assemble the game itself from the pieces the other tools made.

Where gen_exiletest.py builds a harness that replays recorded scenes, this
builds the program that plays: the kernel runs free, drawing its own random
numbers and taking the keys from the game array a tick at a time.

Writes, all beside the program on the board:

    out/game/start_obj.bin    the sixteen slots as a new game begins
    out/game/start_game.bin   the game array to match, with the feed switched
                              off and the events and promotion switched on
    out/game/objsheet.bin     where every (sprite, palette, flip) lives in the
                              slot 2 image, as a lookup the draw can afford
    Bas/exile/exile.bas       Bas/exile/exile_harness.bas with the layouts

The screen state is left at zero, so the first tick finds the view nowhere
near the player and redraws the whole of it, which is what the game does when
it starts.

    python gen_exilegame.py exile-disassembly.txt [--start &8a,&4a | --saved]
"""
import json
import os
import struct
import sys

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')

from exile6502 import load_listing                              # noqa: E402
from exilegame import OBJ, FIELDS, ACTIONS                      # noqa: E402
from gen_exiletest import GAME, GAME_SIZE, NSLOT, game_init     # noqa: E402

# the sheet lookup, as offsets into one array of 64-bit words
NSPRITE = 128          # sprite ids run to 124
OS_START = 0                       # first pair for a sprite
OS_COUNT = OS_START + NSPRITE      # how many palettes that sprite has
OS_PAL = OS_COUNT + NSPRITE        # the palette of each pair
OS_GEO = None                      # x | y<<16 | w<<32 | h<<40, four flips a pair
OS_N = None


def tables_bytes():
    """The packed table file gen_exiletest.py writes, which the game reads too."""
    return os.path.getsize(os.path.join(out, 'scene', 'tables2.bin'))


# Where a new game puts the player.  The position in the binary is a saved one
# - the routine that loads it is called relocate_binary_and_saved_position -
# and it sits inside the ship, walled in by two doors that will not open until
# the view scrolls onto their tiles, which inside the ship it never does: from
# there the player can reach five squares by three and no more.  The landing
# site outside gives fifty by thirty-six, which is somewhere a game can be
# played and tested.  --start &xx,&yy overrides it.
LANDING_SITE = (0x8A, 0x4A)


def start_arrays(mem, start=LANDING_SITE):
    """The slots and the game array as a new game begins."""
    slots = [0] * (NSLOT * len(FIELDS))
    for f in FIELDS:
        for sl in range(NSLOT):
            slots[FIELDS.index(f) * NSLOT + sl] = mem[OBJ[f] + sl]
    if start:
        slots[FIELDS.index('x') * NSLOT] = start[0]
        slots[FIELDS.index('y') * NSLOT] = start[1]
        slots[FIELDS.index('xf') * NSLOT] = 0x80
        slots[FIELDS.index('yf') * NSLOT] = 0
    g = game_init(mem)
    g['feedmode'] = 0        # its own random numbers, and the keys from the array
    g['eventson'] = 1
    g['promoteon'] = 1
    for i in range(4):
        g['rnd%d' % i] = mem[0xD9 + i] or (i * 37 + 1)
    game = [0] * GAME_SIZE
    for i, n in enumerate(GAME):
        game[i] = g[n]
    return slots, game


def object_sheet():
    """The slot 2 image's index, packed small enough to read in a frame."""
    global OS_GEO, OS_N
    rows = json.load(open(os.path.join(out, 'objects.json')))
    pairs = sorted({(r['sprite'], r['palette']) for r in rows})
    assert max(s for s, _ in pairs) < NSPRITE, "a sprite id past the table"
    at = {(r['sprite'], r['palette'], r['flip']): r for r in rows}
    index = {sp: i for i, sp in enumerate(pairs)}
    OS_GEO = OS_PAL + len(pairs)
    OS_N = OS_GEO + len(pairs) * 4
    words = [0] * OS_N
    for sprite in range(NSPRITE):
        mine = [i for i, (s, _) in enumerate(pairs) if s == sprite]
        words[OS_START + sprite] = mine[0] if mine else 0
        words[OS_COUNT + sprite] = len(mine)
    for (s, p), i in index.items():
        words[OS_PAL + i] = p
        for fl in range(4):
            r = at.get((s, p, fl))
            if r is None:
                continue
            words[OS_GEO + i * 4 + fl] = r['x'] | (r['y'] << 16) | (r['w'] << 32) | (r['h'] << 40)
    return words, len(pairs)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mem = load_listing(sys.argv[1])
    start = LANDING_SITE
    if '--start' in sys.argv:
        a, b = sys.argv[sys.argv.index('--start') + 1].replace('&', '').split(',')
        start = (int(a, 16), int(b, 16))
    elif '--saved' in sys.argv:
        start = None                 # wherever the binary's saved position puts it
    gdir = os.path.join(out, 'game')
    os.makedirs(gdir, exist_ok=True)

    slots, game = start_arrays(mem, start)
    open(os.path.join(gdir, 'start_obj.bin'), 'wb').write(struct.pack('<%dq' % len(slots), *slots))
    open(os.path.join(gdir, 'start_game.bin'), 'wb').write(struct.pack('<%dq' % len(game), *game))
    print("the player starts at (&%02x, &%02x); game array %d of %d"
          % (slots[FIELDS.index('x') * NSLOT], slots[FIELDS.index('y') * NSLOT], len(GAME), GAME_SIZE))

    words, npairs = object_sheet()
    open(os.path.join(gdir, 'objsheet.bin'), 'wb').write(struct.pack('<%dq' % len(words), *words))
    print("object sheet: %d (sprite, palette) pairs, %d words" % (npairs, OS_N))

    consts = ["' the layouts, generated by gen_exilegame.py"]
    for i, f in enumerate(FIELDS):
        consts.append("Const O_%s = %d" % (f.upper(), i))
    want = ('kmask', 'fault', 'faultarg', 'scr0', 'scr1', 'orgxf', 'orgyf', 'frame',
            'angle', 'aim', 'weapon', 'held', 'feedmode', 'eventson', 'promoteon',
            'wl0', 'wldes0', 'pocket0', 'pockused', 'wlo0', 'whi0', 'viewpoint')
    for n in want:
        consts.append("Const G_%s = %d" % (n.upper(), GAME.index(n)))
    consts.append("Const NGAME = %d, NSLOT = %d" % (len(GAME), NSLOT))
    consts.append("Const NSPRITE = %d, TABLES_BYTES = %d" % (NSPRITE, tables_bytes()))
    consts.append("Const OS_START = %d, OS_COUNT = %d, OS_PAL = %d, OS_GEO = %d, OS_N = %d"
                  % (OS_START, OS_COUNT, OS_PAL, OS_GEO, OS_N))
    for i, a in enumerate(ACTIONS):
        consts.append("Const K_%s = %d" % (a.upper().replace('@', 'AT').replace('>', 'GT').replace('<', 'LT'), i))

    harness = os.path.join(here, '..', 'exile', 'exile_harness.bas')
    prog = open(harness, encoding='utf-8').read().replace('\' @@CONSTS@@', "\n".join(consts))
    dest = os.path.join(here, '..', 'exile', 'exile.bas')
    open(dest, 'w', newline='\r\n').write(prog)
    print("wrote %s (%d lines)" % (os.path.normpath(dest), prog.count("\n") + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
