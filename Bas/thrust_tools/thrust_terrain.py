"""Decode Thrust's terrain RLE and ask the question that decides the port:
how many separate fills does one screenful of cave wall actually cost?"""
import re
import os
import sys

# The disassembly is not vendored - see README.md.  Give its path as the
# first argument, or drop thrust.6502 next to this script.
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), 'thrust.6502')
if not os.path.exists(SRC):
    raise SystemExit('thrust.6502 not found - see README.md for where to get it')
txt = open(SRC, encoding='utf-8', errors='replace').read()

tables = {}
for m in re.finditer(r'\.terrain_data_level_(\d)_([ABCD])\s*\n((?:\s*EQUB[^\n]*\n)+)',
                     txt):
    lvl, tag, body = int(m.group(1)), m.group(2), m.group(3)
    vals = [int(v, 16) for v in re.findall(r'\$([0-9A-Fa-f]{2})', body)]
    tables[(lvl, tag)] = vals


def profile(counts, incs):
    """x position of the wall at each successive scanline."""
    x, out = 0, []
    for c, i in zip(counts, incs):
        inc = i - 256 if i > 127 else i
        for _ in range(c):
            x = (x + inc) & 0xFF
            out.append(x)
    return out


def runs_in_window(prof, y0, n):
    """Consecutive scanlines at the same X collapse into one rectangle."""
    w = prof[y0:y0 + n]
    if not w:
        return 0
    r = 1
    for a, b in zip(w, w[1:]):
        if a != b:
            r += 1
    return r


VIEW = 120          # half-resolution scanlines across a 240 row screen
print('lvl  scanlines   left runs (max/mean)   right runs (max/mean)   worst frame')
print('---  ---------   --------------------   ---------------------   -----------')
for lvl in range(6):
    L = profile(tables[(lvl, 'A')], tables[(lvl, 'B')])
    R = profile(tables[(lvl, 'C')], tables[(lvl, 'D')])
    n = min(len(L), len(R))
    lr = [runs_in_window(L, y, VIEW) for y in range(0, n - VIEW)]
    rr = [runs_in_window(R, y, VIEW) for y in range(0, n - VIEW)]
    worst = max(a + b for a, b in zip(lr, rr))
    print('%3d  %9d   %7d / %-10.1f   %7d / %-11.1f   %d'
          % (lvl, n, max(lr), sum(lr) / len(lr), max(rr), sum(rr) / len(rr), worst))

# object counts per level
print()
for lvl in range(6):
    m = re.search(r'\.level_%d_obj_pos_X\s*\n((?:\s*EQUB[^\n]*\n)+)' % lvl, txt)
    if m:
        n = len(re.findall(r'\$([0-9A-Fa-f]{2})', m.group(1)))
        print('level %d: %d objects' % (lvl, n))
