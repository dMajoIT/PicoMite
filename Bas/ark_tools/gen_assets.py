"""Arkanoid port - phase 1 asset extraction.

Reads the composite &0600-&2FFF image from the annotated disassembly and
emits everything the MMBasic port needs:

    out/ark_tiles.bmp    16 tiles of 16x8 - the brick field's tileset
    out/ark_sprites.bmp  one sheet: ball, bats, aliens, capsules, ...
    out/arkdata.bas      round stream, sprite rectangles, tables, sound

Two things about the source data that the disassembly's own labels get
wrong, and that this file therefore has to state explicitly:

  * &0A95 is the sprite WIDTH in byte-columns and &0A20 is the HEIGHT in
    character rows.  The symbol names in ark.json are the other way round.
  * a round-data cell holding 9 is a SILVER brick.  The field-drawing loop
    at &1515 substitutes 254 - (roundNumber >> 3) for it, i.e. -2 .. -5,
    and HardenBrick counts it back up to zero.  So silver takes 2 hits in
    rounds 1-8, 3 in 9-16, 4 in 17-24 and 5 in 25-32.

MODE 2 on the BBC is 160x256 with pixels twice as wide as they are tall,
so every sprite is emitted at 2x horizontally and 1x vertically, which is
square-pixel 1:1 on our 320x240 screen.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
BIN = r"D:\Users\peter\Downloads\Arkanoid (1981)(Imagine)[h8]\disasm\arkanoid.bin"
BASE = 0x0600

# ---------------------------------------------------------------- source ---
with open(BIN, "rb") as f:
    IMG = f.read()


def at(addr, n):
    return list(IMG[addr - BASE:addr - BASE + n])


def byte(addr):
    return IMG[addr - BASE]


# --------------------------------------------------------------- palette ---
# The game runs on the default MODE 2 palette with logical 5 and 13
# redefined to black by its own VDU 19 string (&0C80).  Map the eight BBC
# physical colours onto their RGB121 codes; RGB121 is bit3 red, bits 2-1
# green, bit 0 blue, which is the nibble the flash image stores.
BBC_TO_121 = [0, 8, 6, 14, 1, 0, 7, 15,
              0, 8, 6, 14, 1, 0, 7, 15]  # 8-15 flash; never used in the artwork


def px_pair(b):
    """MODE 2 packs two pixels per byte: left from bits 7,5,3,1."""
    left = ((b >> 7 & 1) << 3) | ((b >> 5 & 1) << 2) | ((b >> 3 & 1) << 1) | (b >> 1 & 1)
    right = ((b >> 6 & 1) << 3) | ((b >> 4 & 1) << 2) | ((b >> 2 & 1) << 1) | (b & 1)
    return left, right


def sprite(addr, cols, rows):
    """Unpack to a list of rows of RGB121 indices, already 2x wide.

    Storage is one character row at a time; within a row the eight bytes of
    each byte-column run consecutively, left to right.
    """
    w, h = cols * 2, rows * 8
    out = [[0] * (w * 2) for _ in range(h)]
    for r in range(rows):
        for c in range(cols):
            for s in range(8):
                l, rt = px_pair(byte(addr + (r * cols + c) * 8 + s))
                y = r * 8 + s
                out[y][(c * 2 + 0) * 2 + 0] = BBC_TO_121[l]
                out[y][(c * 2 + 0) * 2 + 1] = BBC_TO_121[l]
                out[y][(c * 2 + 1) * 2 + 0] = BBC_TO_121[rt]
                out[y][(c * 2 + 1) * 2 + 1] = BBC_TO_121[rt]
    return out


# ------------------------------------------------------------------- BMP ---
def write_bmp(path, pix):
    """4-bit indexed BMP whose palette is the identity on RGB121, so that
    FLASH LOAD IMAGE's palette conversion is a round trip."""
    h = len(pix)
    w = len(pix[0])
    assert w % 2 == 0
    rowbytes = (w + 1) // 2
    pad = (-rowbytes) % 4
    stride = rowbytes + pad
    pal = b""
    for i in range(16):
        r = 255 if i & 8 else 0
        g = ((i >> 1) & 3) * 85
        b = 255 if i & 1 else 0
        pal += bytes((b, g, r, 0))          # BMP palette is BGRA
    body = bytearray()
    for y in range(h - 1, -1, -1):          # BMP rows are bottom-up
        row = pix[y]
        for x in range(0, w, 2):
            body.append((row[x] << 4) | row[x + 1])
        body += b"\x00" * pad
    off = 14 + 40 + 64
    hdr = b"BM" + struct.pack("<IHHI", off + len(body), 0, 0, off)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 4, 0, len(body), 2835, 2835, 16, 16)
    with open(path, "wb") as f:
        f.write(hdr + info + pal + bytes(body))
    return w, h


def blank(w, h):
    return [[0] * w for _ in range(h)]


def paste(dst, src, x, y):
    for j, row in enumerate(src):
        dst[y + j][x:x + len(row)] = row


# ------------------------------------------------------- the brick tiles ---
# ORIGINAL ARTWORK.  Nothing here is unpacked from the BBC game: the bricks
# and every sprite are drawn below.
#
# Everything is drawn in BBC-PIXEL space and doubled horizontally at the end,
# because a MODE 2 pixel was twice as wide as it was tall and the whole look
# of the thing depends on that chunkiness.  So a brick is drawn 8 x 8 and
# comes out 16 x 8; the bat is drawn 18 x 8 and comes out 36 x 8.
TILES_PER_ROW = 8
TW, TH = 16, 8

# RGB121: 0 black, 1 blue, 2 dk green, 3 blue-green, 4 mid green, 5 sky,
# 6 green, 7 cyan, 8 red, 9 magenta, 10 orange, 11 pink, 12 amber,
# 13 pale pink, 14 yellow, 15 white.
#
# The eight ordinary brick colours.  Deliberately a different set from the
# one the BBC game used (white, orange, cyan, green, red, blue, violet,
# yellow) so the screens read as ours.
BRICK_COLS = [0, 9, 6, 5, 11, 10, 3, 13, 4]

HARD_EDGE, HARD_CORE = 15, 8      # multi-hit: white ring, red centre
GOLD_BODY, GOLD_LIT = 12, 14      # indestructible: amber with a yellow top


def dbl(pix):
    """Double horizontally: BBC pixel space out to screen pixels."""
    return [[c for c in row for _ in (0, 1)] for row in pix]


def box(pix, x, y, w, h, col):
    H, W = len(pix), len(pix[0])
    for j in range(h):
        for i in range(w):
            if 0 <= x + i < W and 0 <= y + j < H:
                pix[y + j][x + i] = col


def draw_brick(value):
    """One 8 x 8 brick, in BBC pixels."""
    g = blank(8, 8)
    if value == 9:
        # Multi-hit.  A solid two-pixel ring in a contrasting colour around
        # a different centre, so it is obvious at a glance that this one is
        # not going to break first time.
        box(g, 0, 0, 7, 7, HARD_EDGE)
        box(g, 2, 2, 3, 3, HARD_CORE)
    elif value == 10:
        box(g, 0, 0, 7, 7, GOLD_BODY)
        box(g, 0, 0, 7, 1, GOLD_LIT)
        box(g, 0, 1, 1, 6, GOLD_LIT)
    else:
        col = BRICK_COLS[value]
        box(g, 0, 0, 7, 7, col)
        box(g, 0, 0, 7, 1, 15)          # lit top edge
    # the mortar: the eighth column and row stay black, which is what gives
    # the field its grid
    return dbl(g)


def build_tileset():
    # TILEMAP index n is the (n-1)th tile in the sheet, so brick value v
    # goes at image position v-1.
    sheet = blank(TILES_PER_ROW * TW, 2 * TH)
    for v in range(1, 11):
        i = v - 1
        paste(sheet, draw_brick(v), (i % TILES_PER_ROW) * TW, (i // TILES_PER_ROW) * TH)
    return sheet


# ------------------------------------------------------ the sprite sheet ---
# A 5 x 5 face for the capsule letters.
CAPFONT = {
    "G": ["11111", "10000", "10111", "10001", "11111"],
    "D": ["11110", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "11110", "10000", "11111"],
    "S": ["11111", "10000", "11111", "00001", "11111"],
    "L": ["10000", "10000", "10000", "10000", "11111"],
    "B": ["11110", "10001", "11110", "10001", "11110"],
    "P": ["11111", "10001", "11111", "10000", "10000"],
}
# letter, pill colour, letter colour - the same seven jobs, our own look
CAPSULES = [
    ("G", 6, 0), ("D", 7, 0), ("E", 5, 15), ("S", 14, 0),
    ("L", 8, 15), ("B", 15, 8), ("P", 9, 15),
]


def draw_ball():
    g = blank(6, 8)
    for y in range(8):
        for x in range(6):
            dx, dy = x - 2.5, y - 3.5
            if dx * dx * 1.6 + dy * dy <= 10:
                g[y][x] = 15 if dx + dy < 0 else 7
    return dbl(g)


def draw_bat(width, laser=False):
    """A chunkier bat: red caps, a cyan deck with a white lip and a dark
    keel under it."""
    g = blank(width, 8)
    box(g, 0, 1, width, 6, 7)               # cyan deck
    box(g, 0, 1, width, 2, 15)              # white lip
    box(g, 0, 5, width, 2, 1)               # blue keel
    box(g, 0, 1, 3, 6, 8)                   # red end caps
    box(g, width - 3, 1, 3, 6, 8)
    box(g, 0, 1, 3, 2, 11)
    box(g, width - 3, 1, 3, 2, 11)
    if laser:
        box(g, 3, 0, 2, 2, 14)              # two barrels
        box(g, width - 5, 0, 2, 2, 14)
    return dbl(g)


def draw_shot():
    g = blank(8, 8)
    box(g, 3, 0, 2, 8, 14)
    box(g, 3, 0, 2, 3, 15)
    return dbl(g)


def draw_capsule(n):
    letter, body, ink = CAPSULES[n]
    g = blank(8, 8)
    box(g, 0, 1, 8, 6, body)                # the pill
    box(g, 1, 0, 6, 1, body)
    box(g, 1, 7, 6, 1, body)
    box(g, 1, 1, 6, 1, 15)                  # a lit top
    for r, row in enumerate(CAPFONT[letter]):
        for c, ch in enumerate(row):
            if ch == "1":
                g[r + 2][c + 2] = ink
    return dbl(g)


def draw_alien(frame):
    """Four frames of a jellyfish: a domed bell over tentacles that wave."""
    g = blank(8, 16)
    # the bell
    for y in range(1, 9):
        for x in range(8):
            dx, dy = x - 3.5, y - 8.0
            if dx * dx * 1.1 + dy * dy * 0.8 <= 13 and y <= 8:
                g[y][x] = 5
    box(g, 1, 2, 6, 2, 7)                   # a lit crown
    box(g, 2, 1, 4, 1, 15)
    g[5][2] = 15 ; g[5][5] = 15             # two eyes
    g[6][2] = 9  ; g[6][5] = 9
    box(g, 0, 8, 8, 1, 11)                  # the bell's rim
    # tentacles - three of them, waving with the frame
    wave = [0, 1, 0, -1][frame]
    for t, bx in enumerate((1, 3, 5)):
        for k in range(6):
            x = bx + (wave if (k + t) % 2 else 0)
            y = 9 + k
            if 0 <= x < 8 and y < 16:
                g[y][x] = 11 if k < 4 else 9
    return dbl(g)


def draw_boom(frame):
    """Three frames of a starburst: bright and solid, then spokes, then
    a scatter."""
    g = blank(8, 16)
    cx, cy = 3.5, 7.5
    if frame == 0:
        for y in range(16):
            for x in range(8):
                dx, dy = (x - cx) * 1.5, y - cy
                if dx * dx + dy * dy <= 9:
                    g[y][x] = 15 if dx * dx + dy * dy < 3 else 14
    else:
        import math
        r0, r1 = (2.5, 5.0) if frame == 1 else (4.5, 7.5)
        col = 10 if frame == 1 else 8
        for k in range(8):
            ang = k * math.pi / 4 + (0.4 if frame == 2 else 0)
            for step in range(12):
                rr = r0 + (r1 - r0) * step / 11.0
                x = int(round(cx + math.cos(ang) * rr / 1.5))
                y = int(round(cy + math.sin(ang) * rr))
                if 0 <= x < 8 and 0 <= y < 16:
                    g[y][x] = 14 if step < 4 else col
        if frame == 1:
            box(g, 3, 7, 2, 2, 15)
    return dbl(g)


def draw_door(right):
    g = blank(4, 16)
    box(g, 0, 0, 4, 16, 3)
    box(g, 0 if not right else 3, 0, 1, 16, 15)
    for y in range(0, 16, 3):
        box(g, 1, y, 2, 1, 5)
    return dbl(g)


def draw_popup(which):
    g = blank(8, 8)
    col = 14 if which == 0 else 11
    box(g, 1, 2, 6, 3, col)
    box(g, 2, 1, 4, 1, col)
    box(g, 2, 5, 4, 1, col)
    box(g, 3, 3, 2, 1, 0)
    return dbl(g)


SPRITE_ORDER = ["BALL", "BAT", "BATBIG", "BATLAS", "SHOT", "POPUPA", "POPUPB",
                "CAPS0", "CAPS1", "CAPS2", "CAPS3", "CAPS4", "CAPS5", "CAPS6",
                "ALIEN0", "ALIEN1", "ALIEN2", "ALIEN3",
                "BOOM0", "BOOM1", "BOOM2", "DOORL", "DOORR"]


def draw_sprite(name):
    if name == "BALL":
        return draw_ball()
    if name == "BAT":
        return draw_bat(18)
    if name == "BATBIG":
        return draw_bat(22)
    if name == "BATLAS":
        return draw_bat(18, laser=True)
    if name == "SHOT":
        return draw_shot()
    if name.startswith("POPUP"):
        return draw_popup(0 if name.endswith("A") else 1)
    if name.startswith("CAPS"):
        return draw_capsule(int(name[4]))
    if name.startswith("ALIEN"):
        return draw_alien(int(name[5]))
    if name.startswith("BOOM"):
        return draw_boom(int(name[4]))
    if name == "DOORL":
        return draw_door(False)
    if name == "DOORR":
        return draw_door(True)
    raise KeyError(name)


SPRITES = [(n, 0, 0, 0) for n in SPRITE_ORDER]


def build_sheet():
    imgs = [(n, draw_sprite(n)) for n in SPRITE_ORDER]
    SHEETW = 192
    rects, x, y, rowh = {}, 0, 0, 0
    for n, im in imgs:
        w, h = len(im[0]), len(im)
        if x + w > SHEETW:
            x, y, rowh = 0, y + rowh, 0
        rects[n] = (x, y, w, h)
        x += w
        rowh = max(rowh, h)
    height = y + rowh
    height += (-height) % 2
    sheet = blank(SHEETW, height)
    for n, im in imgs:
        paste(sheet, im, rects[n][0], rects[n][1])
    return sheet, rects


# ------------------------------------------------------------------ sound ---
# ORIGINAL WORK.  The BBC game's own seventeen OSWORD 7 blocks and eleven
# envelopes are NOT used - these are written from scratch for Picanoid.  The
# seventeen slots keep their meanings so the game code is unchanged, but
# every number below was chosen here.
#
# Envelope order is PLAY BBC ENVELOPE's own: T, PI1-3, PN1-3, AA, AD, AS, AR,
# ALA, ALD.  Pitch is in quarter semitones and amplitude steps are per 1/100 s.
ENVELOPES = [
    # 1  tick - the brick.  Instant attack, very fast decay, nothing held.
    (1,   0,   0,  0,   0,  0,  0,  127, -45,   0, -70, 100, 35),
    # 2  tap - the bat.  Softer and a touch longer than a brick.
    (1,   0,   0,  0,   0,  0,  0,  127, -28,   0, -45,  82, 30),
    # 3  thud - something that would not break.  Dull and short.
    (1,   0,   0,  0,   0,  0,  0,  127, -70,   0, -90,  58, 10),
    # 4  chirp - a small rising blip for catching things.
    (1,  14,   0,  0,   4,  0,  0,  127, -12,   0, -26, 104, 62),
    # 5  zap - the laser.  Pitch falls away fast under a hard attack.
    (1, -22,  -8,  0,   6,  4,  0,  127, -22,   0, -34, 112, 40),
    # 6  fall - losing a ball.  Long, sagging, no hurry.
    (2,  -7,  -4, -2,  14, 10,  8,   96,  -5,  -2,  -7, 112, 70),
    # 7  bell - a clean sustained note for the tune.
    (1,   0,   0,  0,   0,  0,  0,   90,  -3,   0, -10, 108, 88),
    # 8  sweep - deliberately SILENT.  It exists only to move channel 1's
    #    pitch, which is what clocks the noise on channel 0.
    (1,  11,   7,  4,   8,  8,  8,    1,   0,   0,   0,   0,  0),
    # 9  pop - an alien.  Short, with the pitch dropping out from under it.
    (1, -34,   0,  0,   3,  0,  0,  127, -32,   0, -52, 114, 28),
    # 10 lift - the extra life.  Rises and rings.
    (1,  18,   9,  0,   6,  6,  0,  127,  -6,   0, -12, 116, 84),
    # 11 flourish - the escape.  The biggest thing in the game.
    (2,  12,   6,  3,  10,  8,  6,  110,  -4,  -1,  -9, 118, 90),
]

# (channel word, amplitude, pitch, duration) - amplitude 1-11 picks an
# envelope above, a negative one is a plain volume.  &10/&11/&12/&13 are
# channels 0-3 with the flush bit set, so nothing queues up in play.
SOUNDS = [
    (0x13,   1, 148,  2),   #  0 brick destroyed, and every hit on the boss
    (0x13,   2, 108,  2),   #  1 ball off the bat, and the launch
    (0x13,   3,  64,  2),   #  2 an indestructible brick struck
    (0x13,   4, 124,  3),   #  3 ball caught by the Grab capsule
    (0x10, -10,   7,  8),   #  4 capsule: white noise, clocked by channel 1
    (0x11,   8,  12,  8),   #  5 capsule: the silent sweep that clocks it
    (0x12,  10,  89,  4),   #  6 extra life, first note
    (0x12,  10, 101,  6),   #  7 extra life, second note
    (0x12,   5, 184,  2),   #  8 laser fired
    (0x11,   6,  56, 12),   #  9 life lost, the tone
    (0x10,  -8,   4, 12),   # 10 life lost, the noise under it
    (0x03,   0,   0,  4),   # 11 title tune, rest
    (0x03,   7,   0,  4),   # 12 title tune, note
    (0x00,   0,   0,  0),   # 13 spare
    (0x11,  11,  69,  5),   # 14 escape through the door, first
    (0x12,  11,  81,  8),   # 15 escape through the door, second
    (0x10,   9,   6,  3),   # 16 alien destroyed
]

N_ENV = len(ENVELOPES)
N_SND = len(SOUNDS)

SND_USE = {
    0: "brick destroyed; also every hit on the boss",
    1: "ball off the bat, and ball launched",
    2: "an indestructible brick struck",
    3: "ball caught by the Grab capsule",
    4: "capsule collected, the noise",
    5: "capsule collected, the silent sweep that clocks it",
    6: "extra life",
    7: "extra life",
    8: "laser fired",
    9: "life lost",
    10: "life lost",
    11: "title tune, rest",
    12: "title tune, note",
    13: "spare",
    14: "escape through the door",
    15: "escape through the door",
    16: "alien destroyed",
}


def envelopes():
    return [(i + 1, list(e), False) for i, e in enumerate(ENVELOPES)]


def soundblocks():
    return [(i,) + tuple(b) for i, b in enumerate(SOUNDS)]


# ------------------------------------------------------------ title screen ---
# ORIGINAL WORK.  The BBC game's own title bitmap is NOT used.  This one is
# drawn here, from a block font, out of the same kind of shape the game is
# made of - the name spelled in bricks.
FONT = {
    "P": ["1111 ", "1   1", "1   1", "1111 ", "1    ", "1    ", "1    "],
    "I": [" 111 ", "  1  ", "  1  ", "  1  ", "  1  ", "  1  ", " 111 "],
    "C": [" 1111", "1    ", "1    ", "1    ", "1    ", "1    ", " 1111"],
    "A": ["  1  ", " 1 1 ", "1   1", "1   1", "11111", "1   1", "1   1"],
    "N": ["1   1", "11  1", "1 1 1", "1  11", "1   1", "1   1", "1   1"],
    "O": [" 111 ", "1   1", "1   1", "1   1", "1   1", "1   1", " 111 "],
    "D": ["1111 ", "1   1", "1   1", "1   1", "1   1", "1   1", "1111 "],
}
# the RGB121 codes the artwork uses, brightest first
TITLE_COLS = [15, 7, 6, 14, 3, 8, 1]


def make_title():
    """A 320 x 240 title screen, drawn rather than borrowed.

    The name is spelled in solid blocks and a brick lattice is then laid
    over the whole picture, so everything on it looks built out of the same
    thing the game is made of without the mortar eating the letters.
    """
    W, H = 320, 240
    pix = blank(W, H)
    CW, CH = 6, 5                       # the lattice: one brick

    def fill(x, y, w, h, col):
        for j in range(h):
            for i in range(w):
                if 0 <= x + i < W and 0 <= y + j < H:
                    pix[y + j][x + i] = col

    # --- the name ------------------------------------------------------
    word = "PICANOID"
    lw = 5 * CW                          # a letter is five cells across
    gap = CW
    total = len(word) * lw + (len(word) - 1) * gap
    ox = (W - total) // 2
    oy = 22
    for n, letter in enumerate(word):
        g = FONT[letter]
        col = TITLE_COLS[n % len(TITLE_COLS)]
        for r in range(7):
            for c in range(5):
                if g[r][c] == "1":
                    fill(ox + n * (lw + gap) + c * CW, oy + r * CH, CW, CH, col)

    # --- three courses of bricks under it -------------------------------
    for r in range(3):
        for c in range(W // 16):
            fill(c * 16, 74 + r * CH * 2, 16, CH * 2, TITLE_COLS[(c + r * 3) % len(TITLE_COLS)])

    # --- bat and ball ----------------------------------------------------
    bx, by = (W - 48) // 2, 178
    for j in range(10):
        for i in range(48):
            c = 7
            if j < 2:
                c = 15
            if j > 6:
                c = 1
            if i < 4 or i >= 44:
                c = 8
            pix[by + j][bx + i] = c
    for j in range(8):
        for i in range(8):
            if (i - 3.5) ** 2 + (j - 3.5) ** 2 <= 14:
                pix[by - 22 + j][bx + 20 + i] = 15 if i + j < 7 else 7

    # --- the mortar, laid over everything that is not background --------
    for y in range(H):
        for x in range(W):
            if pix[y][x] and (x % CW == CW - 1 or y % CH == CH - 1):
                pix[y][x] = 0
    return pix



# --------------------------------------------------------------- motion ---
# OUR OWN TABLES.  Four speed steps of eight entries.  Index 1-6 are the six
# bat zones, outer edge to outer edge; 0 and 7 are reached by the mirror fold
# and by the three-ball capsule, which clones at d-1 and d+1.
#
# The shape that matters is kept: entries are symmetric about the middle, the
# magnitude climbs with the step, and a return off the END of the bat leaves
# faster and shallower than one off the middle - which is what makes where
# you catch the ball a decision rather than a detail.  The numbers themselves
# are chosen here.
BALL_VX = [
    [-3, -3, -2, -1,  1,  2,  3,  3],
    [-4, -4, -3, -1,  1,  3,  4,  4],
    [-5, -5, -3, -2,  2,  3,  5,  5],
    [-6, -6, -4, -2,  2,  4,  6,  6],
]
BALL_VY = [
    [2, 3, 4, 4, 4, 4, 3, 2],
    [3, 4, 5, 5, 5, 5, 4, 3],
    [4, 5, 6, 6, 6, 6, 5, 4],
    [4, 5, 7, 7, 7, 7, 5, 4],
]

# The enemy walk.  A five-bit counter is masked and its top three bits index
# these, so an enemy weaves as it descends.  y counts up from the bottom, so
# a negative entry is downward.
DRIFT_X = [0, -1, -2, -2, 0, 2, 2, 1]
DRIFT_Y = [-3, -3, -1, 0, 1, 0, -1, -3]

# How far down the screen an enemy is allowed before it is removed, by round
# group of four.
ENEMY_FLOOR = [14, 11, 15, 12]

# ---------------------------------------------------------- round stream ---
def round_stream():
    lens = at(0x0AD5, 32)
    total = sum(lens)
    assert total == 969, total
    data = at(0x0D00, total)
    return lens, data


def decode_round(data):
    """The nibble RLE at &0D00, decoded exactly as &1340 does it."""
    m = [0] * 256
    x = k = 0
    while k < len(data):
        t = data[k]
        k += 1
        v = t & 0x0F
        if v == 0x0F:                       # back-reference
            src = x - (t & 0xF0)
            while True:
                m[x] = m[src]
                x += 1
                src += 1
                if src & 0x0F == 0:
                    break
        elif v == 0x0E:                     # mirror columns 0-5 into 7-12
            for row in range(16):
                for col in range(6):
                    m[row * 16 + 7 + (5 - col)] = m[row * 16 + col]
        else:
            for _ in range((t >> 4) + 1):
                if x < 256:
                    m[x] = v
                x += 1
    return m


def sg(v):
    return v - 256 if v > 127 else v


# ------------------------------------------------------------- emit .bas ---
def hexblob(vals, per=64):
    out = []
    s = "".join("%02X" % v for v in vals)
    for i in range(0, len(s), per):
        out.append('  "%s"' % s[i:i + per])
    return out


def main():
    os.makedirs(OUT, exist_ok=True)

    # ------------------------------------------------------- one sheet ---
    # Everything goes into a single flash image.  TILEMAP indexes its tiles
    # from the image ORIGIN - src_col = (tile-1) % tiles_per_row, and the
    # image width is the row stride - so the tile band has to be the
    # top-left corner, but the image may be any size under 3840 x 2160 and
    # anything below the band is free.  BLIT FLASH takes an explicit source
    # rectangle and checks it against the image, not the screen, so the
    # sprites and the title can sit anywhere in it.
    #
    # That leaves flash slots 2 and 3 alone - and slot 3 is the one LIBRARY
    # uses, so a library and this game can now coexist.
    tiles = build_tileset()                 # 128 x 16, must be at 0,0
    sheet, rects = build_sheet()            # 192 x 40
    title = make_title()                    # 320 x 240, ours

    ART_W = 320
    SPR_OY = len(tiles)                     # sprites go under the tile band
    TITLE_OY = SPR_OY + len(sheet)
    ART_H = TITLE_OY + len(title)

    art = blank(ART_W, ART_H)
    paste(art, tiles, 0, 0)
    paste(art, sheet, 0, SPR_OY)
    paste(art, title, 0, TITLE_OY)
    rects = dict((n, (x, y + SPR_OY, w, h)) for n, (x, y, w, h) in rects.items())
    aw, ah = write_bmp(os.path.join(OUT, "pic_art.bmp"), art)
    tw, th = len(tiles[0]), len(tiles)
    sw, sh = len(sheet[0]), len(sheet)
    tw2, th2 = len(title[0]), len(title)

    lens, data = round_stream()
    grids = []
    p = 0
    for n in lens:
        grids.append(decode_round(data[p:p + n]))
        p += n

    # sanity: the checks the plan asks for
    assert len(grids) == 32
    silver = sum(1 for g in grids for r in range(16) for c in range(13) if g[r * 16 + c] == 9)
    gold = sum(1 for g in grids for r in range(16) for c in range(13) if g[r * 16 + c] == 10)
    assert grids[0].count(9) >= 13, "round 1 must open with a row of silver"

    vx = [v for blk in BALL_VX for v in blk]
    vy = [v for blk in BALL_VY for v in blk]
    dirx = DRIFT_X
    diry = DRIFT_Y
    floor = ENEMY_FLOOR

    def datablock(label, vals, per=16, signed=False):
        out = ["%s:" % label]
        for k in range(0, len(vals), per):
            chunk = vals[k:k + per]
            out.append("DATA " + ",".join(str(sg(v) if signed else v) for v in chunk))
        return out

    L = []
    L.append("' picdata.bas - GENERATED by the Picanoid build, do not edit by hand")
    L.append("'")
    L.append("' Strings in MMBasic cap at 255 characters, so every table here is DATA.")
    L.append("' Read them with RESTORE <label> : FOR .. : READ .. : NEXT.")
    L.append("")
    L.append("CONST N_ROUNDS = 32, RND_BYTES = %d" % sum(lens))
    L.append("CONST FLD_COLS = 13, FLD_ROWS = 16")
    L.append("' --- one flash image holds the lot: tiles at the origin, then the")
    L.append("' --- sprite sheet, then the title screen.")
    L.append("CONST ART_W = %d, ART_H = %d" % (aw, ah))
    L.append("CONST TITLE_X = 0, TITLE_Y = %d, TITLE_W = %d, TITLE_H = %d" % (TITLE_OY, tw2, th2))
    L.append("")
    L.append("' --- sprite sheet rectangles: x, y, w, h")
    for n, _, _, _ in SPRITES:
        x, y, w, h = rects[n]
        L.append("CONST S_%s_X = %d, S_%s_Y = %d, S_%s_W = %d, S_%s_H = %d" % (n, x, n, y, n, w, n, h))
    L.append("")
    L.append("' --- compressed length of each screen (sums to %d)" % sum(lens))
    L += datablock("ArkRoundLen", lens)
    L.append("")
    L.append("' --- the 32 screen maps, run-length coded a nibble at a time")
    L += datablock("ArkRoundData", data)
    L.append("")
    L.append("' --- ball velocities: four speed steps of eight entries, signed")
    L += datablock("ArkBallVX", vx, 8)
    L.append("")
    L += datablock("ArkBallVY", vy, 8)
    L.append("")
    L.append("' --- the enemy walk, indexed by the direction counter >> 2, signed")
    L += datablock("ArkAlienDX", dirx, 8)
    L.append("")
    L += datablock("ArkAlienDY", diry, 8)
    L.append("")
    L.append("' --- how low an enemy may go, by round group")
    L += datablock("ArkAlienFloor", floor, 4)
    L.append("")

    L.append("' --- ORIGINAL SOUND.  Eleven envelopes and seventeen blocks written")
    L.append("' --- for Picanoid; none of the BBC game's own sound data is used.")
    L.append("Sub ArkInitSound")
    for n, v, starred in envelopes():
        mark = ""
        L.append("  PLAY BBC ENVELOPE %d, %s%s" % (n, ", ".join(str(x) for x in v), mark))
    L.append("End Sub")
    L.append("")
    L.append("' --- channel, amplitude, pitch, duration.")
    blk = soundblocks()
    L.append("ArkSndCh:")
    L.append("DATA " + ",".join("&H%02X" % b[1] for b in blk))
    L.append("ArkSndAmp:")
    L.append("DATA " + ",".join(str(b[2]) for b in blk))
    L.append("ArkSndPitch:")
    L.append("DATA " + ",".join(str(b[3]) for b in blk))
    L.append("ArkSndDur:")
    L.append("DATA " + ",".join(str(b[4]) for b in blk))
    L.append("")
    for n, ch, amp, pit, dur in blk:
        L.append("' sound %2d  &%04X %4d %4d %4d   %s" % (n, ch, amp, pit, dur, SND_USE.get(n, "")))
    L.append("")

    with open(os.path.join(OUT, "ark_data.bas"), "w") as f:
        f.write("\n".join(L) + "\n")

    print("pic_art.bmp      %d x %d   one image:" % (aw, ah))
    print("   tiles         %d x %d at 0,0   (16 tiles of %dx%d)" % (tw, th, TW, TH))
    print("   sprites       %d x %d at 0,%d  (%d of them)" % (sw, sh, SPR_OY, len(SPRITES)))
    print("rounds           32, %d compressed bytes, %d silver cells, %d gold" % (sum(lens), silver, gold))
    print("round 1 silver   %d" % grids[0].count(9))
    print("   title         %d x %d at 0,%d  (drawn here, not borrowed)" % (tw2, th2, TITLE_OY))
    print("sound            %d envelopes, %d blocks" % (N_ENV, N_SND))
    print("ark_data.bas     %d lines" % len(L))


if __name__ == "__main__":
    main()
