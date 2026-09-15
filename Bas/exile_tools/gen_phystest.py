"""gen_phystest.py - build the BASIC physics test from the kernel, the tables and the traces.

Writes Bas/exile/physics.bas (Bas/exile/exilephys.bas with the player's
starting slot, the action table and out/tables.bas appended) and, in
out/phys/, one feed file per trace scenario plus the list of them:

    phys_list.txt        scenario names, one per line
    phys_<name>.txt      line 1: start square x,y (-1,-1 for none) and the
                         number of ticks; then per tick: key mask, the &d4
                         temporary, the number of values the game read,
                         three address,value pairs, and the eight bytes of
                         the water level tables (the level moves with time)

The key mask has one bit per action in exilegame.ACTIONS.  run_phystest.py
puts these on the PC3, runs the program and checks its output against
out/traces/.

    python gen_phystest.py exile-disassembly.txt
"""
import json
import os
import sys

from exile6502 import load_listing
from exilegame import ACTIONS, OBJ

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')
MAX_READS = 3


def key_mask(keys):
    m = 0
    for i, name in enumerate(ACTIONS):
        if name in keys or (name == 'JUMP' and 'P' in keys) or (name == 'P' and 'JUMP' in keys):
            m |= 1 << i
    return m


def player_init(mem):
    m = mem
    vals = [m[OBJ['sprite']], m[OBJ['x']], m[OBJ['xf']], m[OBJ['y']], m[OBJ['yf']], m[OBJ['flags']],
            m[OBJ['palette']], m[OBJ['vx']], m[OBJ['vy']], m[OBJ['energy']], m[OBJ['state']],
            m[OBJ['timer']], m[OBJ['touching']],
            m[0x084E], m[0x0854], m[0x0859], m[0x29D6], m[0x358A], m[0x080E], m[0x0813]]
    keys = [m[0x126B + i] for i in range(len(ACTIONS))]
    norepeat = [m[0x121D + i] & 1 for i in range(len(ACTIONS))]
    lines = ["' the player's slot as the listing has it, then jetpack energy low/high, suit energy high,",
             "' firing cooldown, jetpack functioning, booster collected, suit collected, and the key history",
             "PlayerInit:",
             "Data " + ",".join(str(v) for v in vals),
             "Data " + ",".join(str(v) for v in keys),
             "' per action: 1 if holding the key does not repeat it",
             "ActionNoRepeat:",
             "Data " + ",".join(str(v) for v in norepeat), ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mem = load_listing(sys.argv[1])
    kernel = open(os.path.join(here, '..', 'exile', 'exilephys.bas'), encoding='utf-8').read()
    tables = open(os.path.join(out, 'tables.bas'), encoding='utf-8').read()
    prog = kernel.rstrip('\n') + "\n\n" + player_init(mem) + "\n" + tables
    dest = os.path.join(here, '..', 'exile', 'physics.bas')
    open(dest, 'w', newline='\r\n').write(prog)
    print("wrote", os.path.normpath(dest), "(%d lines)" % prog.count('\n'))

    pdir = os.path.join(out, 'phys')
    os.makedirs(pdir, exist_ok=True)
    tdir = os.path.join(out, 'traces')
    names = sorted(f[:-5] for f in os.listdir(tdir) if f.endswith('.json'))
    total = 0
    for name in names:
        t = json.load(open(os.path.join(tdir, name + '.json')))
        idx = {f: i for i, f in enumerate(t['fields'])}
        lines = []
        start = t['start'] or (-1, -1)
        lines.append("%d,%d,%d" % (start[0], start[1], len(t['ticks'])))
        for keys, row in zip(t['keys'], t['ticks']):
            reads = row[idx['reads']]
            if len(reads) > MAX_READS:
                raise SystemExit("%s: %d reads in one tick, the feed holds %d" % (name, len(reads), MAX_READS))
            vals = [key_mask(keys), row[idx['d4']], len(reads)]
            for a, v in reads:
                vals += [a, v]
            vals += [0, 0] * (MAX_READS - len(reads))
            vals += row[idx['wl']]          # the water level moves with time: y fraction x4, y x4
            lines.append(",".join(str(v) for v in vals))
        # no newline after the last line: INPUT # would read one more, empty, tick
        open(os.path.join(pdir, 'phys_%s.txt' % name), 'w', newline='\n').write("\n".join(lines))
        total += len(t['ticks'])
    open(os.path.join(pdir, 'phys_list.txt'), 'w', newline='\n').write("\n".join(names) + "\n")
    print("wrote %d feed files, %d ticks, to %s" % (len(names), total, os.path.normpath(pdir)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
