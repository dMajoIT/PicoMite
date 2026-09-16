"""audit_coverage.py - which of the game's own code the test scenes actually run.

The port is trusted because eighty scenes match the original tick for tick.
That trust only reaches as far as the scenes go.  This runs every scene on the
6502 interpreter with the program counter recorded, then reports each routine
in the listing as reached or not reached.

A routine that is never reached has never been checked against anything,
whether or not the kernel implements it.  Those are where a fault would hide.

    python audit_coverage.py exile-disassembly.txt [--csv out.csv]

Routines whose names say they are never used in the standard version, and the
ones that belong to the loader, the screen or the sound chip rather than the
game's own behaviour, are listed separately: the kernel is not meant to have
them.
"""
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)

from exile6502 import load_listing                       # noqa: E402
from exilegame import Game                               # noqa: E402
from gen_traces2 import SCENARIOS                        # noqa: E402

# the parts of the binary that are not the game's behaviour: the port models
# none of them on purpose, so they are counted apart
NOT_OURS = (
    (0x0000, 0x0200, 'zero page and the stack'),
    (0x1000, 0x1200, 'the sound chip and the keyboard interrupt'),
    (0x1200, 0x1500, 'sound and the panel'),
    (0x6000, 0x8000, 'the loader, the save game and the copy protection'),
)


def routines(listing):
    """Every labelled routine in the listing: name, start, end."""
    rx_lab = re.compile(r'^; ([a-z_0-9]+)')
    rx_addr = re.compile(r'^&([0-9a-f]{4}) ')
    out = []
    pend = []
    for line in open(listing, encoding='utf-8', errors='replace'):
        m = rx_lab.match(line)
        if m:
            pend.append(m.group(1))      # several labels can sit on one address
            continue
        m = rx_addr.match(line)
        if m:
            a = int(m.group(1), 16)
            if pend:
                for nm in pend:
                    out.append([nm, a, a])
                pend = []
            elif out:
                out[-1][2] = a
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    listing = sys.argv[1]
    mem = load_listing(listing)
    cover = bytearray(65536)
    # run every scene through the generator's own setup, with the program
    # counter recorded, so this cannot drift from what the traces actually did
    import gen_traces2
    plain = gen_traces2.Game

    def watched(*a, **k):
        g = plain(*a, **k)
        g.cpu.cover = cover
        return g

    gen_traces2.Game = watched
    names = sorted(SCENARIOS)
    for i, name in enumerate(names):
        gen_traces2.run_scenario(mem, name, SCENARIOS[name])
        sys.stderr.write(chr(13) + "  %d of %d scenes" % (i + 1, len(names)))
    sys.stderr.write(chr(10))

    rts = routines(listing)
    hit, miss, apart = [], [], []
    for nm, a, b in rts:
        where = next((w for lo, hi, w in NOT_OURS if lo <= a < hi), None)
        reached = any(cover[x] for x in range(a, max(a + 1, b)))
        if where:
            apart.append((nm, a, where, reached))
        elif reached:
            hit.append((nm, a))
        else:
            miss.append((nm, a))
    print("%d labelled routines in the game's own code: %d reached by the scenes, %d never reached"
          % (len(hit) + len(miss), len(hit), len(miss)))
    print("%d more belong to the loader, the screen or the sound chip and are not the port's job"
          % len(apart))
    print()
    print("never reached by any scene, so never checked against anything:")
    for nm, a in miss:
        print("   &%04x  %s" % (a, nm))
    if '--csv' in sys.argv:
        path = sys.argv[sys.argv.index('--csv') + 1]
        with open(path, 'w', newline='\n') as f:
            f.write("address,routine,reached\n")
            for nm, a in hit:
                f.write("&%04x,%s,yes\n" % (a, nm))
            for nm, a in miss:
                f.write("&%04x,%s,no\n" % (a, nm))
        print("\nwritten to", path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
