"""The six caves.

Thrust stores, for every scanline of the world, the X of the left wall and
the X of the right wall; the cave is the gap between them.  Both are run
length encoded as (count, signed increment) pairs, which is so compact -
under 250 bytes for all six levels - that the port ships the RLE and decodes
it on the board at level load.

That throws away the whole reason the original's decoder is complicated.  It
walks the data forwards *and backwards* so that a 256 byte circular window
can be extended at whichever edge the camera is moving toward; we decode the
level once into two arrays and never think about it again.

  python gen_terrain.py            emit the DATA fragment
  python gen_terrain.py --stats    how many merged fills a frame costs
  python gen_terrain.py --png      render all six caves to out/
"""
import sys

import thrustdata as td

VIEW_ROWS = 120           # terrain scanlines down a 240 pixel screen


def rle(level, wall):
    """(count, increment) pairs.  A and B are the left wall, C and D right."""
    tag = {'L': ('A', 'B'), 'R': ('C', 'D')}[wall]
    counts = td.label('terrain_data_level_%d_%s' % (level, tag[0]))
    incs = td.label('terrain_data_level_%d_%s' % (level, tag[1]))
    if len(counts) != len(incs):
        raise SystemExit('level %d wall %s: %d counts but %d increments'
                         % (level, wall, len(counts), len(incs)))
    return list(zip(counts, [td.signed(i) for i in incs]))


def decode(pairs, x0):
    """Wall X at each successive scanline.

    initialise_landscape sets the left wall's X to 0 and the right wall's to
    $FF - off the right of the 184 column world, so the sky is open - and
    starts both at segment 1 with a counter of $FF.  Segment 0 is therefore
    never read, which is why this skips it; every level has (255, 0) in both
    of the first two segments, so the initial counter and count[1] agree.

    The game runs two decoders per wall, one for odd scanlines and one for
    even, and it is the second (starting at segment 1) whose values survive
    in the wall array.  Reading it the other way puts the cave 255 scanlines
    below every object on the level, which is how this was settled.
    """
    x, out = x0, []
    for count, inc in pairs[1:]:
        for _ in range(count):
            x = (x + inc) & 0xFF
            out.append(x)
    return out


def walls(level):
    L = decode(rle(level, 'L'), 0x00)
    R = decode(rle(level, 'R'), 0xFF)
    n = min(len(L), len(R))
    return L[:n], R[:n]


def cave_start(L, R):
    """The first scanline where either wall moves.

    The top two thirds of every level is sky at a constant X - one fill -
    and the player never flies up there, so averaging over the whole level
    flatters the renderer.  The figures below are measured from here down.
    """
    return next(i for i in range(len(L)) if L[i] != L[0] or R[i] != R[0])


# ---------------------------------------------------------------- emit
def data_lines():
    out = td.bar('Terrain')
    out[2:2] = [
        "'  Per level: the count of left and right segments, then count and",
        "'  increment pairs for the left wall and then for the right.  One",
        "'  step of a pair is one terrain scanline and the increment is added",
        "'  to that wall's X each step.  Decoded at level load into wallL()",
        "'  and wallR()."]
    out.append('trndata:')
    for lvl in range(td.NUM_LEVELS):
        L, R = rle(lvl, 'L'), rle(lvl, 'R')
        deep = min(len(decode(L, 0)), len(decode(R, 0xFF)))
        out.append("' level %d - %d scanlines deep" % (lvl, deep))
        out.append('DATA %d, %d' % (len(L), len(R)))
        for pairs in (L, R):
            row = []
            for c, i in pairs:
                row.append('%d,%d' % (c, i))
                if len(row) == 8:
                    out.append('DATA ' + ', '.join(row))
                    row = []
            if row:
                out.append('DATA ' + ', '.join(row))
    return out


# ------------------------------------------------------------ measuring
def runs(prof, y0, n):
    """Consecutive scanlines at the same X collapse into one rectangle."""
    w = prof[y0:y0 + n]
    if not w:
        return 0
    return 1 + sum(1 for a, b in zip(w, w[1:]) if a != b)


def stats():
    print('Merged rectangle fills for one %d scanline screenful of cave,'
          % VIEW_ROWS)
    print('measured from cave_start() down - the sky above it is one fill.')
    print()
    print('lvl  depth  cave at   median   mean    max wall   worst frame')
    print('---  -----  -------   ------   ----   --------   -----------')
    worst_overall = 0
    for lvl in range(td.NUM_LEVELS):
        L, R = walls(lvl)
        n = len(L)
        lr = [runs(L, y, VIEW_ROWS) for y in range(n - VIEW_ROWS)]
        rr = [runs(R, y, VIEW_ROWS) for y in range(n - VIEW_ROWS)]
        tot = [a + b for a, b in zip(lr, rr)]
        start = cave_start(L, R)
        cave = tot[max(0, start - VIEW_ROWS):]
        worst = max(tot)
        worst_overall = max(worst_overall, worst)
        print('%3d %6d %8d %8d %6.1f %10d %13d'
              % (lvl, n, start, sorted(cave)[len(cave) // 2],
                 sum(cave) / len(cave), max(max(lr), max(rr)), worst))
    print()
    print('worst frame across all six levels: %d merged fills' % worst_overall)


# ------------------------------------------------------------- pictures
def png():
    from PIL import Image
    land = td.label('level_landscape_colour')
    for lvl in range(td.NUM_LEVELS):
        L, R = walls(lvl)
        col = td.RGB[td.BBC_COLOUR[land[lvl]]]
        w = td.WORLD_COLS * 2
        im = Image.new('RGB', (w, len(L)), (0, 0, 0))
        px = im.load()
        for y, (lx, rx) in enumerate(zip(L, R)):
            for x in range(0, min(lx, td.WORLD_COLS) * 2):
                px[x, y] = col
            for x in range(max(rx, 0) * 2, w):
                px[x, y] = col
        p = '%s/cave_%d.png' % (td.mkout(), lvl)
        im.save(p)
        print('%s  %d x %d, cave starts at %d'
              % (p, im.width, im.height, cave_start(L, R)))


if __name__ == '__main__':
    if '--stats' in sys.argv:
        stats()
    elif '--png' in sys.argv:
        png()
    else:
        lines = data_lines()
        td.emit(lines, 'terrain.bas')
        print('\n'.join(lines[:12]))
        print('...')
