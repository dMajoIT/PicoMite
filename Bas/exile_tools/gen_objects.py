"""gen_objects.py - the object sprite sheet, and the flash slot 2 image it shares.

Every object type has a default sprite and a palette; creatures animate
through a family of sprites (the imp's walking, climbing and jumping
frames, the frogman's three, the bullets' six angles, the spacesuit's
eight).  This renders each family member in each palette an object type
uses, unflipped and doubled 2:1 like the tiles, packs them into a 4-bit
BMP with a key colour behind them, and writes where each one is.

All four orientations are stored, since the sheet is small and BLIT FLASH
cannot mirror: flip 0 as drawn, 1 mirrored left-right, 2 upside down, 3
both, matching the object flag bits (&80 horizontal, &40 vertical) shifted
down.  Every object is then one BLIT FLASH a frame with no RAM buffers.

There are three flash slots and the library takes the third, so the object
sheet cannot have one to itself.  It goes below the tail of the tileset in
slot 2 instead: TILEMAP indexes its tiles from the top left and BLIT FLASH
takes pixel coordinates, so one image serves both, and the y in the object
table already includes the tile rows above.

    out/exile_slot2.bmp     for FLASH LOAD IMAGE 2: out/exile_tiles2.bmp
                            (variants 281 on) with the object sheet below it
    out/objects.png         contact sheet of the objects alone
    out/objects.bas         DATA: per entry sprite, palette, flip, x, y, w, h
    out/objects.json        the same, with the object types each serves

The key colour is RGB121 index 2 (a dark green the BBC palette never
produces), so black inside a sprite stays black; blit with transparent 2.

    python gen_objects.py exile-disassembly.txt [--out out]
"""
import json
import os
import sys

from exile6502 import load_listing
from gen_tables import read_tables
from gen_tiles import Sheet, palette_colours, read_bmp4, write_bmp4, save_png, BBC_RGB

KEY = 8                      # palette slot in the BMP that quantises to RGB121 index 2
KEY_RGB = (0, 100, 0)
GLOW_PALETTE = 0xFF          # the sheet entry that means "colour me with MAP"
# The display slots MAP will fill in.  They have to be ones nothing else lands
# in, and the eight BBC colours do NOT occupy slots 0-7: the board puts each
# colour in whichever of its sixteen is nearest, which for these works out as
# black 0, blue 1, green 6, cyan 7, red 8, MAGENTA 9, yellow 14, white 15, with
# the transparency key on 2.  That leaves 3, 4, 5, 10, 11, 12 and 13 free.
# Slot 9 was reserved here first, and every magenta line in the game changed
# colour with the glow.
RESERVED = (10, 11, 12)

# The sheet is a four-bit image, so what matters is which of the sixteen display
# slots each colour lands in when the board loads it, and the board picks the
# slot whose colour is nearest.  Slots 0-7 take the BBC colours and 8 the key,
# which leaves 9-15 spare; writing the board's own colours for 9, 10 and 11
# (MAP16DEF in graphics/HDMI.c) puts the reserved pixels in exactly those slots,
# and the game then says what they mean with MAP as it draws.
MAP16DEF = [0x000000, 0x0000FF, 0x005500, 0x0055FF, 0x00AA00, 0x00AAFF, 0x00FF00, 0x00FFFF,
            0xFF0000, 0xFF00FF, 0xFF5500, 0xFF55FF, 0xFFAA00, 0xFFAAFF, 0xFFFF00, 0xFFFFFF]
SHEET_PALETTE = (BBC_RGB + [KEY_RGB] +
                 [((MAP16DEF[i] >> 16) & 255, (MAP16DEF[i] >> 8) & 255, MAP16DEF[i] & 255)
                  for i in RESERVED] +
                 [(0, 0, 0)] * (7 - len(RESERVED)))
SHEET_WIDTH = 256
SLOT_BYTES = 144 * 1024          # MAX_PROG_SIZE on the PC3: one flash slot

# Animation families: a type whose default sprite falls in a range gets all of it
FAMILIES = [(0x00, 0x07), (0x08, 0x0D), (0x10, 0x12), (0x1C, 0x1F), (0x4F, 0x51),
            (0x52, 0x54), (0x59, 0x5C), (0x64, 0x69), (0x6D, 0x6F), (0x72, 0x74)]


def family(sprite):
    for lo, hi in FAMILIES:
        if lo <= sprite <= hi:
            return list(range(lo, hi + 1))
    return [sprite]


# The palette bytes the sheet renders are the ones an object is born with, but
# some objects change palette as they live: a coronium crystal and a coronium
# boulder cycle theirs as they glow, through dozens of values apiece, and no
# sheet has room for that.  Those are rendered once in colours 9, 10 and 11
# instead - three of the seven of the sixteen that nothing else uses - and the
# game sets what those three mean with MAP as it draws, which the display
# applies at scanout, so the glow costs nothing and needs no redrawing.


def render_sprite_reserved(sheet, sprite):
    """Rows as render_sprite, but in the three colours MAP will fill in."""
    left, top, w, h, src_fh, src_fv = sheet.sprite(sprite)
    colours = (KEY,) + RESERVED
    rows = []
    for y in range(h):
        sy = (h - 1 - y) if src_fv else y
        row = []
        for x in range(w):
            sx = (w - 1 - x) if src_fh else x
            row += [colours[sheet.pixel(left + sx, top + sy)]] * 2
        rows.append(row)
    return rows


def render_sprite(sheet, sprite, pal):
    """Rows of colour indices, 2w x h, key colour where the sprite is clear."""
    left, top, w, h, src_fh, src_fv = sheet.sprite(sprite)
    c1, c2, c3 = palette_colours(pal)
    colours = (KEY, c1 & 7, c2 & 7, c3 & 7)
    rows = []
    for y in range(h):
        sy = (h - 1 - y) if src_fv else y
        row = []
        for x in range(w):
            sx = (w - 1 - x) if src_fh else x
            row += [colours[sheet.pixel(left + sx, top + sy)]] * 2
        rows.append(row)
    return rows


def pack(items, width):
    """Shelf packing by height: items are (key, w, h); returns {key: (x, y)} and the height used."""
    order = sorted(items, key=lambda it: (-it[2], -it[1]))
    pos = {}
    x = y = shelf = 0
    for key, w, h in order:
        if x + w > width:
            x = 0
            y += shelf
            shelf = 0
        pos[key] = (x, y)
        x += w
        shelf = max(shelf, h)
    return pos, y + shelf


def door_palettes(mem, sprites_of_type):
    """The palettes a door can wear, which are not the one in the types table.

    object_types_palette_and_pickup_table gives each type one palette, and for
    most objects that is the only one they ever have.  A door is not like that:
    update_door (&4d64) looks its palette up in doors_palette_table by its own
    colour, and clears colour three while it is unlocked, so one door type wears
    two palettes for each of the eight colours.  A pair the sheet does not hold
    cannot be drawn at all, which is why the ship's hatches were invisible even
    once the objects existed.

    Only the colours that are actually on the planet are rendered - all fifty
    doors between them want a dozen pairs, where covering every colour would
    want fifty-eight and the slot has no room to waste.
    """
    world = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'world_types.bin')
    w = open(world, 'rb').read()
    tf, tdata = w[0:65536], w[65536:131072]
    want = {}
    for i in range(65536):
        t = tf[i] & 0x3F
        if t not in (0x03, 0x04):
            continue
        flip = tf[i] & 0xC0
        colour = (mem[0x0986 + tdata[i]] >> 4) & 7
        base = mem[0x4D7A + colour]
        vertical = 1 if (bool(flip & 0x80) ^ bool(flip & 0x40)) else 0
        ty = (0x3C if t == 0x03 else 0x3E) + vertical
        for pal in (base, base & 0x0F):        # locked, and unlocked
            want.setdefault((sprites_of_type[ty], pal & 0x7F), []).append(ty)
    return want


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, 'out')
    if '--out' in args:
        out_dir = args[args.index('--out') + 1]
    os.makedirs(out_dir, exist_ok=True)
    mem = load_listing(args[0])
    sheet = Sheet(mem)
    tables = read_tables(args[0])
    sprites_of_type = tables['object_types_sprite_table'][1]
    palettes_of_type = tables['object_types_palette_and_pickup_table'][1]

    # (sprite, palette) -> the object types that use it
    entries = {}
    for t, (s, p) in enumerate(zip(sprites_of_type, palettes_of_type)):
        for member in family(s):
            entries.setdefault((member, p & 0x7F), []).append(t)
    for (s, p), ts in door_palettes(mem, sprites_of_type).items():
        for member in family(s):
            entries.setdefault((member, p & 0x7F), []).extend(ts)
    for t in (0x55, 0x58):                 # coronium boulder and coronium crystal
        for member in family(sprites_of_type[t]):
            entries.setdefault((member, GLOW_PALETTE), []).append(t)
    images = {}
    for (s, p) in entries:
        base = render_sprite_reserved(sheet, s) if p == GLOW_PALETTE else render_sprite(sheet, s, p)
        images[(s, p, 0)] = base
        images[(s, p, 1)] = [list(reversed(r)) for r in base]
        images[(s, p, 2)] = list(reversed(base))
        images[(s, p, 3)] = [list(reversed(r)) for r in reversed(base)]
    items = [(key, len(img[0]), len(img)) for key, img in images.items()]
    pos, height = pack(items, SHEET_WIDTH)
    height = (height + 7) // 8 * 8
    rows = [[KEY] * SHEET_WIDTH for _ in range(height)]
    for key, img in images.items():
        x, y = pos[key]
        for j, r in enumerate(img):
            rows[y + j][x:x + len(r)] = r
    save_png(os.path.join(out_dir, 'objects.png'), SHEET_WIDTH, height, rows,
             palette=SHEET_PALETTE)
    # slot 2 carries the tail of the tileset and these objects in one image.  The
    # tiles use colours 0-7 only, so the object sheet's palette (which adds the key
    # colour at 8) serves both, and the tiles keep colour 0 for TILEMAP's transparent.
    tw, tile_h, tile_rows = read_bmp4(os.path.join(out_dir, 'exile_tiles2.bmp'))
    if tw != SHEET_WIDTH:
        print("the tileset is %d wide and the object sheet %d: they cannot share a slot" % (tw, SHEET_WIDTH))
        return 1
    write_bmp4(os.path.join(out_dir, 'exile_slot2.bmp'), SHEET_WIDTH, tile_h + height, tile_rows + rows,
               palette=SHEET_PALETTE)

    ordered = sorted(images, key=lambda k: (k[0], k[1], k[2]))
    with open(os.path.join(out_dir, 'objects.json'), 'w') as f:
        json.dump([{'sprite': s, 'palette': p, 'flip': fl, 'x': pos[(s, p, fl)][0], 'y': pos[(s, p, fl)][1] + tile_h,
                    'w': len(images[(s, p, fl)][0]), 'h': len(images[(s, p, fl)]), 'types': entries[(s, p)]}
                   for s, p, fl in ordered], f, indent=1)
    with open(os.path.join(out_dir, 'objects.bas'), 'w', newline='\n') as f:
        f.write("' objects.bas - the object sprite sheet in flash slot 2, generated by gen_objects.py\n")
        f.write("' %d entries in sprite, palette, flip order: sprite, palette, flip (0 plain, 1 mirrored,\n" % len(ordered))
        f.write("' 2 upside down, 3 both), then x, y, width, height in the slot 2 image, whose first\n")
        f.write("' %d rows are the tail of the tileset, so y already counts them.\n" % tile_h)
        f.write("' Blit with transparent colour 2.  The first DATA value is the number of entries\n")
        f.write("' (a Const here would sit after the program's End and never run).\n")
        f.write("ObjectSheet:\n")
        f.write("Data %d\n" % len(ordered))
        for s, p, fl in ordered:
            x, y = pos[(s, p, fl)]
            f.write("Data %d,%d,%d,%d,%d,%d,%d\n" % (s, p, fl, x, y + tile_h, len(images[(s, p, fl)][0]), len(images[(s, p, fl)])))
    used = sum(w * h for _, w, h in items)
    print("%d images (%d sprite-palette pairs in four orientations) for %d object types; sheet %d x %d, %d bytes, %.0f%% used" % (
        len(ordered), len(entries), len(sprites_of_type), SHEET_WIDTH, height, SHEET_WIDTH * height // 2, 100.0 * used / (SHEET_WIDTH * height)))
    total = 8 + SHEET_WIDTH * (tile_h + height) // 2
    print("slot 2 image: %d x %d, %d bytes of a %d byte slot (%.0f%%): %d tile rows then %d of objects" % (
        SHEET_WIDTH, tile_h + height, total, SLOT_BYTES, 100.0 * total / SLOT_BYTES, tile_h, height))
    return 0


if __name__ == '__main__':
    sys.exit(main())
