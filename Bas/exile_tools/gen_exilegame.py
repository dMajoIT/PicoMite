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

    python gen_exilegame.py exile-disassembly.txt [--start &8a,&4a | --landing]
"""
import json
import os
import struct
import sys

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')

from exile6502 import load_listing                              # noqa: E402
from exilegame import OBJ, FIELDS, ACTIONS                      # noqa: E402
from gen_exiletest import GAME, GAME_SIZE, NSLOT, game_init, TABLES   # noqa: E402

# the sheet lookup, as offsets into one array of 64-bit words
NSPRITE = 128          # sprite ids run to 124
OS_START = 0                       # first pair for a sprite
OS_COUNT = OS_START + NSPRITE      # how many palettes that sprite has
OS_PAL = OS_COUNT + NSPRITE        # the palette of each pair
OS_GEO = None                      # x | y<<16 | w<<32 | h<<40, four flips a pair
OS_PALCOL = None                   # the three colours of each of the 128 palettes
OS_N = None
GLOW_PALETTE = 0xFF                # the sheet entry drawn in MAP's reserved colours


def table_offset(name):
    """Where a packed table starts, so the program can read it out of tbl()."""
    off = 0
    for cname, _, size in TABLES:
        if cname == name:
            return off
        off += size
    raise KeyError(name)


def tables_bytes():
    """The packed table file gen_exiletest.py writes, which the game reads too."""
    return os.path.getsize(os.path.join(out, 'scene', 'tables2.bin'))


# Where a new game puts the player.  The position in the binary is a saved one
# - the routine that loads it is called relocate_binary_and_saved_position -
# and it is inside the ship, which is where Exile begins and so where this
# begins: the first screen is the ship's hull with the player standing in it.
#
# From there the player can reach eight squares and no more, which was once
# read here as the start being broken and answered by moving it outside to the
# landing site.  That was treating the symptom.  The square the player stands
# on is an invisible switch that only OBJECT_DESTINATOR (&4a) can trip, the
# destinator is in the ship at &99,&3c, and the two doors out at &9c,&3c and
# &9c,&3d are locked to keys of colour 0 and 2 that a new game does not have.
# Getting out is the game's own opening puzzle, not a fault to be worked
# around, and a start that skips it is a start that never tests it.
#
# --start &xx,&yy puts the player anywhere; LANDING_SITE is the open ground
# outside, fifty squares by thirty-six, which is useful for exercising the
# world but is not how the game begins.
LANDING_SITE = (0x8A, 0x4A)
SHIP = None

# The tile types whose update routine makes an object out of the tertiary data.
TERTIARY_CREATORS = (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0C)


def unmade_tertiaries(mem):
    """The tertiary bytes a new game should have waiting, but this one does not.

    A tile that carries an object only makes it while bit 7 of its tertiary data
    byte is set; the game clears that bit as it makes the object (&408a, "clear
    &80 to indicate object is now primary") so it is made once and no more.  The
    listing is a snapshot of a game in progress, so everything that happened to
    be a live object at that moment has the bit clear - and the sixteen object
    slots it carries are empty, so those objects exist nowhere at all.

    Six squares are in that state and five of them are in the ship, which is
    where the snapshot was taken: both hatches, the switch that opens them, and
    both engines.  Without this the player begins sealed in a ship with no way
    out, no switch to press and no engines.

    Bit 7 is only ever that flag - it is stripped when the object is made - so
    putting it back cannot change what the object is.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    w = open(os.path.join(here, 'out', 'world_types.bin'), 'rb').read()
    tf, tdata = w[0:65536], w[65536:131072]
    offs = set()
    for i in range(65536):
        if (tf[i] & 0x3F) not in TERTIARY_CREATORS:
            continue
        off = tdata[i]
        if off and not (mem[0x0986 + off] & 0x80):
            offs.add(off)
    return sorted(offs)                      # None means the binary's own saved position


def start_arrays(mem, start=SHIP):
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
    # relocate_binary_and_saved_position (&78ed) wipes zero page &01-&df before
    # the first frame, which exilegame.Game copies and this must too.  It is not
    # housekeeping: the screen origin lives at &c7-&d1, so wiping it leaves the
    # view nowhere near the player, and the first tick answers that with
    # redraw_screen - which looks at every tile on the screen and makes the
    # objects they carry.  Without it the view starts already correct, nothing
    # is ever swept, and every door, beam and tile-borne object that the player
    # does not walk into simply never exists.  That is why the ship had no
    # hatches even once their tertiary bytes were put back.
    mem = bytearray(mem)
    for a in range(1, 0xE0):
        mem[a] = 0
    mem[0x35] = 0x28         # acceleration_power, five tiles
    mem[0xDE] = 0xC0         # the player upright
    mem[0xDD] = 0xFF         # holding nothing
    g = game_init(mem)
    for off in unmade_tertiaries(mem):      # see the note there: the ship's own fittings
        g['tert%d' % off] |= 0x80
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
    global OS_GEO, OS_PALCOL, OS_N
    rows = json.load(open(os.path.join(out, 'objects.json')))
    pairs = sorted({(r['sprite'], r['palette']) for r in rows})
    assert max(s for s, _ in pairs) < NSPRITE, "a sprite id past the table"
    at = {(r['sprite'], r['palette'], r['flip']): r for r in rows}
    index = {sp: i for i, sp in enumerate(pairs)}
    OS_GEO = OS_PAL + len(pairs)
    OS_PALCOL = OS_GEO + len(pairs) * 4
    OS_N = OS_PALCOL + 128
    words = [0] * OS_N
    for sprite in range(NSPRITE):
        mine = [i for i, (s, _) in enumerate(pairs) if s == sprite]
        words[OS_START + sprite] = mine[0] if mine else 0
        words[OS_COUNT + sprite] = len(mine)
    # what each palette's three colours are, so an object drawn in the reserved
    # colours can have MAP told what they mean
    from gen_tiles import palette_colours
    for pal in range(128):
        c1, c2, c3 = palette_colours(pal)
        words[OS_PALCOL + pal] = (c1 & 7) | ((c2 & 7) << 8) | ((c3 & 7) << 16)
    for (s, p), i in index.items():
        words[OS_PAL + i] = p
        for fl in range(4):
            r = at.get((s, p, fl))
            if r is None:
                continue
            words[OS_GEO + i * 4 + fl] = r['x'] | (r['y'] << 16) | (r['w'] << 32) | (r['h'] << 40)
    return words, len(pairs)


def flash_image_bytes(path):
    """Exactly what FLASH LOAD IMAGE leaves in a slot after its eight-byte
       header, worked out from the BMP.  The board writes the picture top row
       first, two pixels a byte with the left pixel in the LOW nibble, and it
       converts each colour with RGB121() - which is not the BMP's own index,
       so the palette has to be run through the same arithmetic.  Verified
       against a board word for word at both ends of the image."""
    d = open(path, 'rb').read()
    off = struct.unpack('<I', d[10:14])[0]
    w, h = struct.unpack('<ii', d[18:26])
    h = abs(h)
    hdr = struct.unpack('<I', d[14:18])[0]
    pal = d[14 + hdr:off]
    nib = {}
    for i in range(16):
        b, g, r, _ = pal[i * 4:i * 4 + 4]
        c = (r << 16) | (g << 8) | b
        nib[i] = ((c & 0x800000) >> 20) | ((c & 0xC000) >> 13) | ((c & 0x80) >> 7)
    stride = ((w * 4 + 31) // 32) * 4
    out = bytearray()
    for r in range(h - 1, -1, -1):
        row = d[off + r * stride:off + r * stride + w // 2]
        for bb in row:
            out.append(nib[bb >> 4] | (nib[bb & 15] << 4))
    return bytes(out), w, h


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mem = load_listing(sys.argv[1])
    start = SHIP                     # the ship, as the game itself begins
    if '--start' in sys.argv:
        a, b = sys.argv[sys.argv.index('--start') + 1].replace('&', '').split(',')
        start = (int(a, 16), int(b, 16))
    elif '--landing' in sys.argv:
        start = LANDING_SITE         # open ground outside, for exercising the world
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
            'wl0', 'wldes0', 'pocket0', 'pockused', 'wlo0', 'whi0', 'viewpoint', 'npart', 'nsnd', 'snd0')
    for n in want:
        consts.append("Const G_%s = %d" % (n.upper(), GAME.index(n)))
    consts.append("Const NGAME = %d, NSLOT = %d" % (len(GAME), NSLOT))
    consts.append("Const NSPRITE = %d, TABLES_BYTES = %d" % (NSPRITE, tables_bytes()))
    # a particle is eight words: the two velocities, the two position fractions,
    # the two squares, the time to live, and the colour with its flags
    consts.append("Const P_VX = 0, P_VY = 1, P_XF = 2, P_YF = 3, P_X = 4, P_Y = 5, P_TTL = 6, P_CF = 7")
    # where the sound chip's envelopes and the forty-eight sounds sit in tbl()
    consts.append("Const T_ENVELOPE = %d, T_SOUND = %d, NSOUND = 48"
                  % (table_offset('ENVELOPE'), table_offset('SOUND')))
    consts.append("Const OS_START = %d, OS_COUNT = %d, OS_PAL = %d, OS_GEO = %d, OS_N = %d"
                  % (OS_START, OS_COUNT, OS_PAL, OS_GEO, OS_N))
    consts.append("Const OS_PALCOL = %d, GLOW_PALETTE = %d" % (OS_PALCOL, GLOW_PALETTE))
    from gen_objects import RESERVED
    consts.append("Const GLOW0 = %d, GLOW1 = %d, GLOW2 = %d" % RESERVED)
    # What must be in the flash slots for THIS build.  The size alone is not
    # enough: the door fix renumbered the tiles without changing slot 1's
    # height, so a board carrying the old sheet passed the size check and drew
    # the new maps through the old tiles.  So take some words of the real
    # picture too, spread through it, and compare those.
    probes = []
    for n, f in ((1, "exile_tiles1.bmp"), (2, "exile_slot2.bmp")):
        fb, w, h = flash_image_bytes(os.path.join(out, f))
        consts.append("Const SLOT%dW = %d, SLOT%dH = %d" % (n, w, n, h))
        for k in range(1, 7):
            o = (len(fb) * k // 7) & ~3
            # step on until the word is not blank: a run of zeroes matches any
            # other image's blank run and would prove nothing
            while o + 4 <= len(fb) and fb[o:o + 4] == bytes(4):
                o += 4
            probes.append((n, 8 + o, struct.unpack("<I", fb[o:o + 4])[0]))
    consts.append("Const NPROBE = %d" % len(probes))
    consts.append("TilesetProbes:")
    for n, o, v in probes:
        consts.append("Data %d, %d, &H%08X" % (n, o, v))

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
