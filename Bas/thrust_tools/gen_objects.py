"""What stands in each cave: guns, fuel, the pod and the reactor.

Each level has four parallel arrays - X, Y, Y's high byte, and a type -
terminated by $FF in the type array, plus a gun parameter whose low two bits
index a firing table and whose next three bits do something the disassembly
has not pinned down.  Sizes come from obj_type_width / obj_type_height and
are in world units, so a gun is 5 columns by 8 scanlines.

  python gen_objects.py          emit the DATA fragment
  python gen_objects.py --png    caves with every object marked, to out/
"""
import sys

import thrustdata as td

# OBJECT_* constants, disassembly lines 66-74
TYPE_NAME = ['gun up-right', 'gun down-right', 'gun up-left', 'gun down-left',
             'fuel', 'pod on its stand', 'reactor', 'door switch right',
             'door switch left']


def objects(level):
    """(x, y, type, gun_param) per object, in world units."""
    xs = td.label('level_%d_obj_pos_X' % level)
    ys = td.label('level_%d_obj_pos_Y' % level)
    hi = td.label('level_%d_obj_pos_Y_EXT' % level)
    ty = td.label('level_%d_obj_type' % level)
    gp = td.label('level_%d_gun_param' % level)
    if ty[-1] != 0xFF:
        raise SystemExit('level %d object types are not $FF terminated' % level)
    ty = ty[:-1]
    n = len(xs)
    if not (len(ys) == len(hi) == len(ty) == len(gp) == n):
        raise SystemExit('level %d object arrays disagree: %d %d %d %d %d'
                         % (level, n, len(ys), len(hi), len(ty), len(gp)))
    return [(xs[i], hi[i] * 256 + ys[i], ty[i], gp[i]) for i in range(n)]


def sizes():
    w = td.label('obj_type_width')
    h = td.label('obj_type_height')
    return list(zip(w, h))


# ---------------------------------------------------------------- emit
def data_lines():
    out = td.bar('Objects')
    out[2:2] = [
        "'  Per level: how many, then x, y, type, gun parameter for each.",
        "'  x is a world column and y a world scanline.  Types are",
        "'    0-3 gun up-right, down-right, up-left, down-left",
        "'    4 fuel   5 pod on its stand   6 reactor",
        "'    7-8 door switch right, left",
        "'  Then the width and height of each type, in world units."]
    out.append('objdata:')
    for lvl in range(td.NUM_LEVELS):
        objs = objects(lvl)
        out.append("' level %d" % lvl)
        out.append('DATA %d' % len(objs))
        for x, y, t, g in objs:
            out.append('DATA %3d, %4d, %d, %2d       ' % (x, y, t, g)
                       + "' " + TYPE_NAME[t])
    out.append("' width, height of each object type")
    out.append('objsize:')
    for i, (w, h) in enumerate(sizes()):
        out.append('DATA %d, %2d                 ' % (w, h) + "' " + TYPE_NAME[i])
    return out


# ------------------------------------------------------- verification
def check():
    """No object may be entirely buried in rock.

    A strict "inside the cave" test is the wrong one: limpet guns are bolted
    into the wall and are meant to straddle it, and fuel cells rest on
    ledges.  What would signal a bad extraction is an object with no part of
    it in open ground at all.  The buried fraction per type is printed so
    that a shift in the data would show up as a change in the pattern.
    """
    import gen_terrain
    sz = sizes()
    per_type = {}
    bad = 0
    for lvl in range(td.NUM_LEVELS):
        L, R = gen_terrain.walls(lvl)
        for i, (x, y, t, g) in enumerate(objects(lvl)):
            w, h = sz[t]
            if y + h > len(L):
                print('  level %d object %d (%s) at y=%d runs past the end of '
                      'the level (%d deep)' % (lvl, i, TYPE_NAME[t], y, len(L)))
                bad += 1
                continue
            cells = open_cells = 0
            for yy in range(y, y + h):
                for xx in range(x, x + w):
                    cells += 1
                    if L[yy] <= xx < R[yy]:
                        open_cells += 1
            per_type.setdefault(t, []).append(1 - open_cells / cells)
            if open_cells == 0:
                print('  level %d object %d (%s) at %d,%d is wholly inside '
                      'rock' % (lvl, i, TYPE_NAME[t], x, y))
                bad += 1
    print('buried fraction by type:')
    for t in sorted(per_type):
        v = per_type[t]
        print('  %-18s n=%-3d  mean %.2f  max %.2f'
              % (TYPE_NAME[t], len(v), sum(v) / len(v), max(v)))
    print('%d object%s wholly inside rock' % (bad, '' if bad == 1 else 's'))
    return bad


def png():
    from PIL import Image, ImageDraw
    import gen_terrain
    land = td.label('level_landscape_colour')
    objc = td.label('level_object_colour')
    sz = sizes()
    for lvl in range(td.NUM_LEVELS):
        L, R = gen_terrain.walls(lvl)
        wall = td.RGB[td.BBC_COLOUR[land[lvl]]]
        oc = td.RGB[td.BBC_COLOUR[objc[lvl]]]
        w = td.WORLD_COLS * 2
        im = Image.new('RGB', (w, len(L)), (0, 0, 0))
        px = im.load()
        for y, (lx, rx) in enumerate(zip(L, R)):
            for x in range(min(lx, td.WORLD_COLS) * 2):
                px[x, y] = wall
            for x in range(max(rx, 0) * 2, w):
                px[x, y] = wall
        d = ImageDraw.Draw(im)
        for x, y, t, g in objects(lvl):
            ow, oh = sz[t]
            d.rectangle([x * 2, y, (x + ow) * 2 - 1, y + oh - 1], outline=oc)
        p = '%s/objects_%d.png' % (td.mkout(), lvl)
        im.save(p)
        print('%s  %d objects' % (p, len(objects(lvl))))


if __name__ == '__main__':
    if '--png' in sys.argv:
        png()
    elif '--check' in sys.argv:
        sys.exit(1 if check() else 0)
    else:
        lines = data_lines()
        td.emit(lines, 'objects.bas')
        check()
