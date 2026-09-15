"""gen_tiles.py - the tileset images for Exile's world.

Renders every tile variant that gen_world.py found - a sprite from the
game's 128 x 81 two-bit sheet, drawn through its one-byte palette, flipped
and offset as the plotter would - into 32 x 32 RGB121 tiles (the game's
16 x 32 square with each pixel doubled across, since its pixels are 2:1)
and packs them into the two flash-slot tileset images:

    out/exile_tiles1.bmp   variants 1-280, 8 across, 4-bit BMP for FLASH LOAD IMAGE 1
    out/exile_tiles2.bmp   variants 281 on; gen_objects.py puts the object sheet
                           below these to make out/exile_slot2.bmp, the image
                           slot 2 actually holds (slot 3 is the library's)
    out/tiles1.png, tiles2.png   the same as contact sheets
    out/world_preview.png  the whole planet at 4 pixels a square
    out/landing_site.png   30 x 12 squares from (&8A, &4A), to compare with
                           the C# census render in Bas/exile_tools/census

Colour 0 in a tile is left black, which TILEMAP DRAW treats as transparent
when asked, so objects drawn first show through the open squares.

    python gen_tiles.py exile-disassembly.txt [--out out]
"""
import json
import os
import struct
import sys

from exile6502 import load_listing
from gen_world import TILES_PER_SLOT

SHEET = 0x53EC          # 128 x 81 pixels, 2 bits each, 32 bytes a row
WIDTH_TBL = 0x5E0C      # 8421.... width - 1, .......1 flip horizontally
HEIGHT_TBL = 0x5E89     # 84218... height - 1, .......1 flip vertically
XOFF_TBL = 0x5F06       # b1 b0 p1 p0 0 b4 b3 b2: byte and pixel offset along the row
YOFF_TBL = 0x5F83       # r4 r3 r2 r1 r0 0 r6 r5: row
TILES_PER_ROW = 8

# The sixteen colour pairs a palette byte's low nibble selects for logical
# colours 1 and 2, as two packed pixels; and the physical colour each two-bit
# pair means.  From the plotter's tables, via the census generator.
PAIR_TABLE = [0xCA, 0xC9, 0xE3, 0xE9, 0xEB, 0xCE, 0xF8, 0xE6, 0xCC, 0xEE, 0x30, 0xDE, 0xEF, 0xCB, 0xFB, 0xFE]
BBC_RGB = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]


def game_colour(bits):
    """A packed pixel's bits (r at 0, g at 2, b at 4, priority at 6) as a 0-15 colour."""
    return (bits & 1) | (((bits >> 2) & 1) << 1) | (((bits >> 4) & 1) << 2) | (((bits >> 6) & 1) << 3)


def palette_colours(pal):
    """Logical colours 1, 2, 3 of a palette byte as 0-15 game colours (bit 3 = priority)."""
    packed = PAIR_TABLE[pal & 15]
    c1 = game_colour(packed & 0x55)
    c2 = game_colour((packed & 0xAA) >> 1)
    return c1, c2, pal >> 4


class Sheet:
    def __init__(self, mem):
        self.mem = mem

    def pixel(self, x, y):
        b = self.mem[SHEET + (x >> 2) + (y << 5)]
        n = x & 3
        if n == 0:
            return ((b & 0x80) >> 6) | ((b & 0x08) >> 3)
        if n == 1:
            return ((b & 0x40) >> 5) | ((b & 0x04) >> 2)
        if n == 2:
            return ((b & 0x20) >> 4) | ((b & 0x02) >> 1)
        return ((b & 0x10) >> 3) | (b & 0x01)

    def sprite(self, s):
        """left, top, width, height, flipH, flipV of sprite s on the sheet."""
        a = self.mem[XOFF_TBL + s]
        b = self.mem[YOFF_TBL + s]
        w = self.mem[WIDTH_TBL + s]
        h = self.mem[HEIGHT_TBL + s]
        return (((a & 7) << 4) | (a >> 4), ((b & 3) << 5) | (b >> 3), (w >> 4) + 1, (h >> 3) + 1, w & 1, h & 1)


def render_square(sheet, var):
    """The 16 x 32 square for a variant as rows of BBC colours 0-7, 0 = nothing."""
    sq = [[0] * 16 for _ in range(32)]
    left, top, w, h, src_fh, src_fv = sheet.sprite(var['sprite'])
    flip_h, flip_v = var['flipH'], var['flipV']
    c1, c2, c3 = palette_colours(var['palette'])
    colours = (0, c1 & 7, c2 & 7, c3 & 7)
    off_y = var['yfrac'] >> 3          # this_object_y_fraction, 8 to a pixel
    for y in range(h):
        ty = (h - 1 - y) if (flip_v ^ src_fv) else y
        ty += off_y
        for x in range(w):
            li = sheet.pixel(left + x, top + y)
            if li == 0:
                continue
            if not flip_h and not src_fh:
                tx = x
            elif not flip_h:
                tx = (w - 1) - x
            elif not src_fh:
                tx = 15 - x
            else:
                tx = (16 - w) + x
            if 0 <= tx < 16 and 0 <= ty < 32:
                sq[ty][tx] = colours[li]
    return sq


def read_bmp4(path):
    """A 4-bit BMP written by write_bmp4, back as (width, height, rows)."""
    b = open(path, 'rb').read()
    offset = struct.unpack_from('<I', b, 10)[0]
    width, height = struct.unpack_from('<ii', b, 18)
    row_bytes = ((width * 4 + 31) // 32) * 4
    rows = []
    for y in range(height):
        src = offset + (height - 1 - y) * row_bytes
        row = []
        for x in range(width):
            v = b[src + (x >> 1)]
            row.append(v >> 4 if (x & 1) == 0 else v & 15)
        rows.append(row)
    return width, height, rows


def write_bmp4(path, width, height, rows, palette=None):
    """A 4-bit uncompressed BMP; the palette is the eight BBC colours unless given."""
    if palette is None:
        palette = BBC_RGB + [(0, 0, 0)] * 8
    row_bytes = ((width * 4 + 31) // 32) * 4
    data = bytearray()
    for y in range(height - 1, -1, -1):
        row = bytearray(row_bytes)
        r = rows[y]
        for x in range(width):
            if x & 1:
                row[x >> 1] |= r[x]
            else:
                row[x >> 1] |= r[x] << 4
        data += row
    palette = b''.join(struct.pack('<BBBB', b, g, r, 0) for (r, g, b) in palette[:16])
    offset = 14 + 40 + len(palette)
    with open(path, 'wb') as f:
        f.write(struct.pack('<2sIHHI', b'BM', offset + len(data), 0, 0, offset))
        f.write(struct.pack('<IiiHHIIiiII', 40, width, height, 1, 4, 0, len(data), 2835, 2835, 16, 16))
        f.write(palette)
        f.write(data)


def save_png(path, width, height, rows, palette=None):
    try:
        from PIL import Image
    except ImportError:
        return False
    if palette is None:
        palette = BBC_RGB
    im = Image.new('P', (width, height))
    pal = []
    for rgb in (list(palette) + [(0, 0, 0)] * 256)[:256]:
        pal += list(rgb)
    im.putpalette(pal)
    im.putdata([v for r in rows for v in r])
    im.save(path)
    return True


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, 'out')
    if '--out' in args:
        out_dir = args[args.index('--out') + 1]
    mem = load_listing(args[0])
    sheet = Sheet(mem)
    variants = json.load(open(os.path.join(out_dir, 'variants.json')))
    tiles = {}                         # index -> 32 x 32 rows
    for var in variants:
        sq = render_square(sheet, var)
        tiles[var['index']] = [[px for px in row for _ in (0, 1)] for row in sq]

    # the two slot images
    n = len(variants)
    for slot in (1, 2):
        first = (slot - 1) * TILES_PER_SLOT + 1
        last = min(n, slot * TILES_PER_SLOT)
        count = last - first + 1
        if count <= 0:
            continue
        rows_of_tiles = (count + TILES_PER_ROW - 1) // TILES_PER_ROW
        width, height = TILES_PER_ROW * 32, rows_of_tiles * 32
        rows = [[0] * width for _ in range(height)]
        for k in range(count):
            tile = tiles[first + k]
            ox, oy = (k % TILES_PER_ROW) * 32, (k // TILES_PER_ROW) * 32
            for y in range(32):
                rows[oy + y][ox:ox + 32] = tile[y]
        write_bmp4(os.path.join(out_dir, 'exile_tiles%d.bmp' % slot), width, height, rows)
        save_png(os.path.join(out_dir, 'tiles%d.png' % slot), width, height, rows)
        print("slot %d: variants %d-%d, %d x %d pixels, %d bytes of tile data" % (
            slot, first, last, width, height, width * height // 2))

    # previews from the whole-planet map
    lines = open(os.path.join(out_dir, 'world.map')).read().split('\n')
    cells = [int(v) for line in lines[3:259] for v in line.split(',')]
    prev = [[0] * 1024 for _ in range(1024)]
    for y in range(256):
        for x in range(256):
            c = cells[y * 256 + x]
            if c:
                t = tiles[c]
                for j in range(4):
                    for i in range(4):
                        prev[y * 4 + j][x * 4 + i] = t[j * 8 + 4][i * 8 + 4]
    save_png(os.path.join(out_dir, 'world_preview.png'), 1024, 1024, prev)
    x0, y0, w, h = 0x8A, 0x4A, 30, 12
    site = [[0] * (w * 32) for _ in range(h * 32)]
    for y in range(h):
        for x in range(w):
            c = cells[(y0 + y) * 256 + x0 + x]
            if c:
                t = tiles[c]
                for j in range(32):
                    site[y * 32 + j][x * 32:(x + 1) * 32] = t[j]
    save_png(os.path.join(out_dir, 'landing_site.png'), w * 32, h * 32, site)
    print("written to", out_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main())
