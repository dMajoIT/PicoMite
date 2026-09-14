"""Every shape in the game, out of two quite different data formats.

The ship, the pod and the shield are a single stream of bytes in which bit 7
means "start a new row".  The clever part is that $81-$FE does double duty:
it ends the row *and* its low six bits are the first pixel of the next one,
because the plot code only ever masks bits 0-5 out of a pixel byte.  $80 is
an empty row and $FF ends the sprite.  One bit per pixel, one colour.

The objects use a second format: two parallel arrays where A is a position
(bit 7 starts a row, the low bits are the byte column times eight) and B is
a raw MODE 1 screen byte - four pixels, two bitplanes interleaved, so the
guns and the reactor are genuinely multi-coloured.

Both decode to the same thing here: a grid of logical colours 0-3, where 1
is the ship's yellow, 2 the landscape colour and 3 the object colour, both
of which the game sets per level.

  python gen_sprites.py          emit the DATA fragment
  python gen_sprites.py --png    a contact sheet of every shape, to out/
  python gen_sprites.py --art    ASCII, for when a shape looks wrong
"""
import sys

import thrustdata as td

NUM_SHIP = 17             # plot_ship_sprite_number 0-$10; 17-31 are mirrors

OBJ_SPRITES = ['gun_up_right', 'gun_down_right', 'gun_up_left',
               'gun_down_left', 'fuel', 'pod_stand', 'generator',
               'door_switch_right', 'door_switch_left']


# --------------------------------------------------------- the two formats
def decode_stream(data):
    """Ship, pod and shield: rows of pixel X positions."""
    rows = []
    for b in data:
        if b == 0xFF:
            break
        if b & 0x80:
            rows.append([])
            if b != 0x80:
                rows[-1].append(b & 0x3F)
        else:
            if not rows:
                rows.append([])
            rows[-1].append(b & 0x3F)
    return rows


def decode_object(a, b):
    """Objects: A positions, B MODE 1 bytes.  Returns {(x, y): colour}."""
    a = a[:a.index(0xFF)] if 0xFF in a else a
    px = {}
    row = -1
    for i, pos in enumerate(a):
        if i >= len(b):
            break
        if pos & 0x80:
            row += 1
        col = (pos & 0x7F) // 8          # byte column, 8 bytes apart
        v = b[i]
        for p in range(4):               # MODE 1: high bit 7-p, low bit 3-p
            c = (((v >> (7 - p)) & 1) << 1) | ((v >> (3 - p)) & 1)
            if c:
                px[(col * 4 + p, max(row, 0))] = c
    return px


# ------------------------------------------------------------- assembling
def ship_shapes():
    out = []
    for n in range(NUM_SHIP):
        rows = decode_stream(td.label('ship_sprite_%d_data' % n))
        px = {}
        for y, xs in enumerate(rows):
            for x in xs:
                px[(x, y)] = 1           # colour 1, the ship's yellow
        out.append(('ship%d' % n, px))
    return out


def other_shapes():
    out = []
    for name, lbl in (('pod', 'pod_sprite_data'),
                      ('shield', 'sheild_sprite_data')):
        rows = decode_stream(td.label(lbl))
        px = {}
        for y, xs in enumerate(rows):
            for x in xs:
                px[(x, y)] = 1
        out.append((name, px))
    for name in OBJ_SPRITES:
        out.append((name, decode_object(
            td.label('obj_sprite_data_A_' + name),
            td.label('obj_sprite_data_B_' + name))))
    return out


def bbox(shapes):
    """One box for a group, so a shape does not jump when it is swapped."""
    xs = [x for _, px in shapes for x, y in px]
    ys = [y for _, px in shapes for x, y in px]
    return min(xs), min(ys), max(xs), max(ys)


def grid(px, box):
    x0, y0, x1, y1 = box
    return [[px.get((x, y), 0) for x in range(x0, x1 + 1)]
            for y in range(y0, y1 + 1)]


def all_shapes():
    """(name, grid, box) for everything, ships sharing one common box."""
    ships = ship_shapes()
    sbox = bbox(ships)
    out = [(n, grid(px, sbox), sbox) for n, px in ships]
    for n, px in other_shapes():
        b = bbox([(n, px)])
        out.append((n, grid(px, b), b))
    return out


# ------------------------------------------------------------------ emit
def data_lines():
    out = td.bar('Sprites')
    out[2:2] = [
        "'  Per shape: name, width, height, then one string per row holding",
        "'  two bits per pixel - logical colour 0 to 3, one hex digit to two",
        "'  pixels, leftmost pixel first.  Colour 1 is the ship's yellow, 2",
        "'  the landscape colour and 3 the object colour; the last two are",
        "'  set per level from the palette table below.",
        "'  Ship shapes 0 to 16 are headings 0 to 16 and share one box, so",
        "'  they can be swapped without the ship shifting; headings 17 to 31",
        "'  are shape 32-n mirrored."]
    out.append('sprdata:')
    for name, g, box in all_shapes():
        h = len(g)
        w = len(g[0]) if h else 0
        out.append('DATA "%s", %d, %d' % (name, w, h))
        for row in g:
            s = ''
            for i in range(0, w, 2):
                lo = row[i + 1] if i + 1 < w else 0
                s += '%X' % (row[i] * 4 + lo)
            out.append('DATA "%s"' % s)
    out.append('DATA "", 0, 0')
    out += ["", "' Per level: the physical colour of logical colour 2 (the",
            "' landscape) and 3 (the objects).  0 black 1 red 2 green",
            "' 3 yellow 4 blue 5 magenta 6 cyan 7 white.", 'palfdata:']
    land = td.label('level_landscape_colour')
    objc = td.label('level_object_colour')
    for lvl in range(td.NUM_LEVELS):
        out.append('DATA %d, %d                  ' % (land[lvl], objc[lvl])
                   + "' level %d: %s cave, %s objects"
                   % (lvl, td.BBC_COLOUR[land[lvl]].lower(),
                      td.BBC_COLOUR[objc[lvl]].lower()))
    return out


# --------------------------------------------------------- verification
def art():
    for name, g, box in all_shapes():
        print('### %s  %dx%d  origin %d,%d'
              % (name, len(g[0]), len(g), box[0], box[1]))
        for row in g:
            print('   ' + ''.join(' .:#'[c] for c in row))


def png():
    from PIL import Image
    shapes = all_shapes()
    scale = 4
    pad = 3
    cw = max(len(g[0]) for _, g, _ in shapes) + pad
    ch = max(len(g) for _, g, _ in shapes) + pad
    cols = 9
    rows = (len(shapes) + cols - 1) // cols
    im = Image.new('RGB', (cols * cw * scale, rows * ch * scale), (16, 16, 20))
    px = im.load()
    # logical 1 yellow, 2 red (level 0 cave), 3 green (level 0 objects)
    col = {1: (255, 255, 0), 2: (255, 0, 0), 3: (0, 255, 0)}
    for i, (name, g, box) in enumerate(shapes):
        ox = (i % cols) * cw * scale
        oy = (i // cols) * ch * scale
        for y, row in enumerate(g):
            for x, c in enumerate(row):
                if not c:
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        px[ox + x * scale + dx, oy + y * scale + dy] = col[c]
    p = '%s/sprites.png' % td.mkout()
    im.save(p)
    print('%s  %d shapes, %d x %d' % (p, len(shapes), im.width, im.height))
    for name, g, box in shapes:
        print('   %-18s %2d x %-2d  origin %d,%d'
              % (name, len(g[0]), len(g), box[0], box[1]))


if __name__ == '__main__':
    if '--png' in sys.argv:
        png()
    elif '--art' in sys.argv:
        art()
    else:
        td.emit(data_lines(), 'sprites.bas')
