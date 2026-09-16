"""install_game.py - put Exile in a folder on the board and start it from there.

Everything a player needs is eleven files in one directory: the program, the
kernel as a library, the two flash images, the two tile maps, the world, the
tables, the sprite index and the state a new game starts from.  Nothing is
installed anywhere else and nothing is left at the root of a drive.

    python install_game.py [--dir B:/Exile] [--norun] [--seconds n]

The program finds the rest through MM.INFO(PATH), which is the directory it was
loaded from, so the folder can be anywhere on any drive and one RUN starts it:
LIBRARY LOAD writes the kernel and restarts the program by itself on the first
run, and the flash slots are written only if they are not already programmed.
The board is the one PC3_PORT names (COM4 if unset).
"""
import os
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..', 'elite_tools'))
os.environ.setdefault('PC3_PORT', 'COM4')
from pc3 import PC3                                  # noqa: E402
from run_exiletest import put_one                    # noqa: E402
from run_exilegame import ASSETS                     # noqa: E402

FILES = ASSETS + [('exile.bas', os.path.join(here, '..', 'exile')),
                  ('README.txt', os.path.join(here, '..', 'exile'))]


def main():
    args = sys.argv[1:]
    folder = args[args.index('--dir') + 1] if '--dir' in args else 'B:/Exile'
    folder = folder.rstrip('/')
    secs = int(args[args.index('--seconds') + 1]) if '--seconds' in args else 15
    items = []
    for name, d in FILES:
        path = os.path.join(d, name)
        if not os.path.exists(path):
            print("missing: %s" % path)
            return 1
        items.append((name, open(path, 'rb').read()))

    b = PC3()
    try:
        b.attention()
        # MKDIR on a directory that is already there fails with "Access denied",
        # not with anything that says so, and the message is not worth reading:
        # make it, ignore whatever it says, then prove the folder exists.
        b.cmd('ON ERROR SKIP 1 : MKDIR "%s"' % folder, timeout=20)
        b.cmd('ON ERROR CLEAR', timeout=10)
        got = b.cmd('PRINT "[" + DIR$("%s", DIR) + "]"' % folder, timeout=20)
        leaf = folder.rsplit('/', 1)[-1]
        if "[%s]" % leaf not in "".join(got.split()):
            print("could not make or find %s on the board:" % folder)
            print(got.strip())
            return 1
        print("%s: ready" % folder)
        t0 = time.time()
        total = 0
        for name, data in items:
            t1 = time.time()
            put_one(b, '%s/%s' % (folder, name), data)
            total += len(data)
            print("  %-22s %7d bytes %5.1fs" % (name, len(data), time.time() - t1))
        b.drain()
        print("%d files, %d bytes in %.0f s" % (len(items), total, time.time() - t0))
        if '--norun' in args:
            return 0
        # one RUN, by path: that is what puts the folder in MM.INFO(PATH)
        print('RUN "%s/exile.bas"' % folder)
        b.send_line('RUN "%s/exile.bas"' % folder)
        # The program has no OVERWRITE on its LIBRARY LOAD, so a board carrying
        # a different library is asked before it is replaced.  A person would
        # answer; this is a script, so it answers for itself.
        text, t0, asked = "", time.time(), False
        while time.time() - t0 < secs:
            text += b._read()
            if not asked and ('Y/N' in text or 'y/n' in text):
                b.send_raw('Y')
                asked = True
        print(text.strip() or "(nothing on the console yet)")
        if asked:
            print("(answered the library question)")
    finally:
        b.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
