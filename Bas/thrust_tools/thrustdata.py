"""Shared reader for Kieran Connell's Thrust disassembly.

The disassembly is not vendored - see README.md.  Every generator finds it
the same way: the path given on the command line, else $THRUST_6502, else
thrust.6502 beside these scripts.

Everything the port needs out of the 6502 source is a run of EQUB bytes
under a label, so one parser serves the lot.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')

# --- BBC physical colours, and the nearest MODE 2 (RGB121) equivalents -----
#     Thrust runs in MODE 1: colour 0 is the background, 1 is the ship and
#     the text, 2 is the landscape and 3 the objects, the last two set per
#     level from level_landscape_colour / level_object_colour.
BBC_COLOUR = ['BLACK', 'RED', 'GREEN', 'YELLOW', 'BLUE', 'MAGENTA', 'CYAN',
              'WHITE']
# index into the game's pal() array, which follows Chuckie Egg's
MM_PAL = {'BLACK': 0, 'BLUE': 1, 'MYRTLE': 2, 'COBALT': 3, 'MIDGREEN': 4,
          'CERULEAN': 5, 'GREEN': 6, 'CYAN': 7, 'RED': 8, 'MAGENTA': 9,
          'RUST': 10, 'FUCHSIA': 11, 'BROWN': 12, 'LILAC': 13, 'YELLOW': 14,
          'WHITE': 15}
# what each BBC physical colour becomes on screen
BBC_TO_MM = {'BLACK': 'BLACK', 'RED': 'RED', 'GREEN': 'GREEN',
             'YELLOW': 'YELLOW', 'BLUE': 'BLUE', 'MAGENTA': 'MAGENTA',
             'CYAN': 'CYAN', 'WHITE': 'WHITE'}
RGB = {'BLACK': (0, 0, 0), 'RED': (255, 0, 0), 'GREEN': (0, 255, 0),
       'YELLOW': (255, 255, 0), 'BLUE': (0, 0, 255), 'MAGENTA': (255, 0, 255),
       'CYAN': (0, 255, 255), 'WHITE': (255, 255, 255)}

# --- geometry ------------------------------------------------------------
#     One terrain column is four BBC pixels; one terrain scanline is two.
#     Keeping the game's arithmetic in these units and scaling by 4 and 2 on
#     the way to the screen reproduces the original geometry, and keeps the
#     elliptical angle tables correct - see docs/Thrust_Port_Plan.html.
COL_PX = 4
ROW_PX = 2
WORLD_COLS = 184          # X wraps here
NUM_LEVELS = 6

_src = None


def source(path=None):
    """The disassembly text, read once."""
    global _src
    if _src is None:
        p = (path or (sys.argv[1] if len(sys.argv) > 1 and
                      sys.argv[1].endswith('.6502') else None)
             or os.environ.get('THRUST_6502')
             or os.path.join(HERE, 'thrust.6502'))
        if not os.path.exists(p):
            raise SystemExit(
                'thrust.6502 not found (tried %s).\n'
                'See README.md - the disassembly is not vendored.' % p)
        _src = open(p, encoding='utf-8', errors='replace').read()
    return _src


def label(name):
    """The EQUB bytes following .<name>, up to the next label or blank line."""
    m = re.search(r'^\.%s\b[^\n]*\n((?:\s*EQUB[^\n]*\n)+)' % re.escape(name),
                  source(), re.M)
    if not m:
        raise SystemExit('label not found in the disassembly: .' + name)
    return [int(v, 16) for v in re.findall(r'\$([0-9A-Fa-f]{2})', m.group(1))]


def signed(b):
    return b - 256 if b > 127 else b


def mkout():
    os.makedirs(OUT, exist_ok=True)
    return OUT


def emit(lines, name):
    """Write a generated DATA fragment and say so."""
    p = os.path.join(mkout(), name)
    open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
    sys.stderr.write('%s: %d lines\n' % (name, len(lines)))
    return p


def bar(title):
    return ["' " + '=' * 70, "'  " + title, "' " + '=' * 70]
