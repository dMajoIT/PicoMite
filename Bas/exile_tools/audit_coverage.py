"""audit_coverage.py - which of the game's own code the test scenes actually run.

The port is trusted because eighty scenes match the original tick for tick.
That trust only reaches as far as the scenes go.  This runs every scene on the
6502 interpreter with the program counter recorded, then reports each routine
in the listing as reached or not reached.

A routine that is never reached has never been checked against anything,
whether or not the kernel implements it.  Those are where a fault would hide.

    python audit_coverage.py exile-disassembly.txt [--csv out.csv] [--proves]

--proves also checks gen_traces2.PROVES: every routine a scene claims to
exercise must be reached by that scene and not merely by some other one.

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
from gen_traces2 import SCENARIOS, PROVES                # noqa: E402

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
    rx_lab = re.compile(r'^; ([a-z_0-9]+)(.*)$')
    rx_addr = re.compile(r'^&([0-9a-f]{4}) ')
    out = []
    pend = []
    for line in open(listing, encoding='utf-8', errors='replace'):
        m = rx_lab.match(line)
        if m:
            # the listing marks entry points nothing calls; they cannot be
            # reached however many scenes are written, so they are not gaps
            pend.append((m.group(1), 'Unused entry point' in m.group(2)))
            continue
        m = rx_addr.match(line)
        if m:
            a = int(m.group(1), 16)
            if pend:
                for nm, unused in pend:
                    out.append([nm, a, a, unused])
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

    class Tee(bytearray):
        """Records into the pooled coverage and, while a scene with a claim is
           running, into that scene's own array as well.  A claim has to be met by
           the scene that makes it: measuring it as what the scene reached first
           would let any earlier scene answer for it."""
        scene = None
        def __setitem__(self, i, v):
            bytearray.__setitem__(self, i, v)
            if self.scene is not None:
                self.scene[i] = v
    cover = Tee(65536)
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
    per_scene = {}
    proves = '--proves' in sys.argv
    for i, name in enumerate(names):
        cover.scene = bytearray(65536) if proves and name in PROVES else None
        gen_traces2.run_scenario(mem, name, SCENARIOS[name])
        if cover.scene is not None:
            per_scene[name] = cover.scene
            cover.scene = None
        sys.stderr.write(chr(13) + "  %d of %d scenes" % (i + 1, len(names)))
    sys.stderr.write(chr(10))

    rts = routines(listing)
    unusable = [(nm, a) for nm, a, b, unused in rts if unused]
    if proves:
        # a scene that passes proves nothing unless the code it was written for
        # ran; each claim below is checked against that scene's own coverage
        spans = {}
        for nm, a, b, unused in rts:
            spans.setdefault(nm, (a, max(a + 1, b)))
        bad = 0
        print("what each scene claims to exercise:")
        for name in sorted(PROVES):
            cov = per_scene.get(name)
            for want in PROVES[name]:
                if want not in spans:
                    print("   %-18s %-46s NO SUCH ROUTINE" % (name, want)); bad += 1; continue
                a, b = spans[want]
                ok = cov is not None and any(cov[a:b])
                if not ok:
                    bad += 1
                print("   %-18s %-46s %s" % (name, want, "reached" if ok else "NEVER REACHED"))
        print("%d claims, %d not met" % (sum(len(v) for v in PROVES.values()), bad))
        print()
    hit, miss, apart = [], [], []
    for nm, a, b, unused in rts:
        if unused:
            continue                     # an entry point nothing calls
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
    print("%d are entry points the listing says nothing calls, so no scene can reach them: %s"
          % (len(unusable), ", ".join(nm for nm, a in unusable)))
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
