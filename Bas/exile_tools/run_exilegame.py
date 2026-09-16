"""run_exilegame.py - put the game on the PC3 and start it.

Everything the game needs beside it on the drive: the two flash images, the two
tile maps, the world, the tables, the sprite index and the state a new game
starts from, plus the kernel as a library file.  Only what changed is put, by
the same list the board keeps for the tests (see run_exiletest.py).

    python run_exilegame.py [--nofiles] [--reput] [--seconds n]

The game does not end by itself, so this starts it and reads the console for a
few seconds to show that it began.  It keeps playing on the board afterwards;
ESC on the board's own keyboard stops it.  The board is the one PC3_PORT names (COM4 if unset).
"""
import os
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..', 'elite_tools'))
os.environ.setdefault('PC3_PORT', 'COM4')
from pc3 import PC3                                              # noqa: E402
from run_exiletest import board_manifest, put_files, save_manifest   # noqa: E402

out = os.path.join(here, 'out')

# what the game opens, and where it comes from here
ASSETS = [
    ('exile_tiles1.bmp', out),
    ('exile_slot2.bmp', out),
    ('exile_w1.map', out),
    ('exile_w2.map', out),
    ('world_types.bin', out),
    ('tables2.bin', os.path.join(out, 'scene')),
    ('exile_lib.bas', os.path.join(out, 'scene')),
    ('objsheet.bin', os.path.join(out, 'game')),
    ('start_obj.bin', os.path.join(out, 'game')),
    ('start_game.bin', os.path.join(out, 'game')),
]


def main():
    args = sys.argv[1:]
    secs = int(args[args.index('--seconds') + 1]) if '--seconds' in args else 12
    b = PC3()
    try:
        b.attention()
        if '--nofiles' not in args:
            manifest = board_manifest(b, '--reput' in args)
            items = []
            for name, d in ASSETS:
                path = os.path.join(d, name)
                if not os.path.exists(path):
                    print("missing: %s" % path)
                    return 1
                items.append((name, open(path, 'rb').read()))
            t0 = time.time()
            put, skipped = put_files(b, manifest, items)
            save_manifest(b, manifest, put)
            print("put %d files in %.0f s, %d already on the board" % (put, time.time() - t0, skipped))
        src = open(os.path.join(here, '..', 'exile', 'exile.bas'), encoding='utf-8').read()
        saved, n = b.upload(src, timeout=120)
        print("uploaded %d lines, saved %s bytes" % (n, saved))
        b.send_line('RUN')
        # the game does not stop, so read for a while rather than wait for a prompt
        text, t0 = "", time.time()
        while time.time() - t0 < secs:
            text += b._read()
        print(text.strip() or "(nothing on the console yet)")
    finally:
        b.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
