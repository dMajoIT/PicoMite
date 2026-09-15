"""run_phystest.py - run the BASIC physics kernel on the PC3 and check it against the game.

Puts world_types.bin and the feed files from gen_phystest.py on the board,
uploads Bas/exile/physics.bas, runs it, and compares every printed tick with
the trace in out/traces/, reporting the first tick that differs, exactly as
exilephys.py does for the Python.

    python run_phystest.py [--nofiles] [--noworld] [--prog physcsub.bas] [--log file]

--nofiles skips putting the data files (they only change with the traces);
--noworld puts the feed files but not world_types.bin; --prog runs another
program from Bas/exile (the CSUB kernel's harness is physcsub.bas).
The board is the one PC3_PORT names (COM4 if unset).
"""
import json
import os
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..', 'elite_tools'))
os.environ.setdefault('PC3_PORT', 'COM4')
from pc3 import PC3   # noqa: E402

out = os.path.join(here, 'out')
COMPARE = ['px', 'py', 'vx', 'vy', 'flags', 'state', 'sprite', 'energy', 'jetpack',
           'angle', 'facing', 'immob', 'thrust_immob', 'jet_ok', 'timer', 'frame', 'palette']


def s8(v):
    return v - 256 if v & 0x80 else v


def parse(output):
    """{scenario: [tick dicts]}, plus any F lines."""
    runs, problems = {}, []
    cur = None
    for line in output.splitlines():
        line = line.strip()
        if line.startswith('S '):
            cur = line[2:].strip()
            runs[cur] = []
        elif line.startswith('T ') and cur:
            v = [int(x) for x in line[2:].split()]
            d = dict(zip(['tick'] + COMPARE, v))
            d['vx'] = s8(d['vx'])
            d['vy'] = s8(d['vy'])
            runs[cur].append(d)
        elif line.startswith('F '):
            problems.append((cur, line[2:]))
        elif line.startswith('Error') or 'Error' in line[:12]:
            problems.append((cur, line))
    return runs, problems


def fmt_row(d):
    return "(&%02x.%02x,&%02x.%02x) v=(%+d,%+d) fl=%02x st=%02x sp=%02x en=%3d jet=%5d ang=%02x fc=%02x im=%02x/%02x ok=%02x tm=%02x pal=%02x" % (
        d['px'] >> 8, d['px'] & 255, d['py'] >> 8, d['py'] & 255, d['vx'], d['vy'], d['flags'], d['state'],
        d['sprite'], d['energy'], d['jetpack'], d['angle'], d['facing'], d['immob'], d['thrust_immob'],
        d['jet_ok'], d['timer'], d['palette'])


def compare(runs):
    failed = 0
    tdir = os.path.join(out, 'traces')
    for name in sorted(runs):
        trace = json.load(open(os.path.join(tdir, name + '.json')))
        idx = {f: i for i, f in enumerate(trace['fields'])}
        rows = runs[name]
        total = len(trace['ticks'])
        bad = None
        for n, row in enumerate(trace['ticks']):
            if n >= len(rows):
                bad = "stopped after tick %d" % n
                break
            oracle = {f: row[idx[f]] for f in COMPARE}
            oracle['flags'] &= 0xFE
            mine = dict(rows[n])
            mine['flags'] &= 0xFE
            diff = [f for f in COMPARE if mine[f] != oracle[f]]
            if diff:
                keys = "+".join(trace['keys'][n]) or "-"
                lines = ["tick %d keys %s: %s differ" % (n + 1, keys, ", ".join(diff))]
                if n:
                    lines.append("  before  %s" % fmt_row(rows[n - 1]))
                lines.append("  board   %s" % fmt_row(mine))
                lines.append("  game    %s" % fmt_row(oracle))
                bad = "\n".join(lines)
                break
        if bad is None:
            print("%-22s %4d/%-4d ticks match" % (name, len(rows), total))
        else:
            failed += 1
            print("%-22s %4d/%-4d ticks match, then:\n%s" % (name, n, total, bad))
    return failed


def main():
    args = sys.argv[1:]
    log = args[args.index('--log') + 1] if '--log' in args else None
    b = PC3()
    try:
        b.attention()
        if '--nofiles' not in args:
            pdir = os.path.join(out, 'phys')
            files = sorted(os.path.join(pdir, f) for f in os.listdir(pdir) if f.startswith('phys_') or f == 'tables.bin')
            if '--noworld' not in args:
                files.insert(0, os.path.join(out, 'world_types.bin'))
            for f in files:
                data = open(f, 'rb').read()
                t0 = time.time()
                b.xmodem_send(os.path.basename(f), data)
                print("put %-28s %6d bytes %5.1fs" % (os.path.basename(f), len(data), time.time() - t0))
        prog = args[args.index('--prog') + 1] if '--prog' in args else 'physics.bas'
        src = open(os.path.join(here, '..', 'exile', prog), encoding='utf-8').read()
        saved, n = b.upload(src, timeout=120)
        print("uploaded %d lines, saved %s bytes" % (n, saved))
        t0 = time.time()
        output = b.run(900)
        print("ran in %.0f s, %d lines of output" % (time.time() - t0, output.count('\n')))
    finally:
        b.close()
    if log:
        open(log, 'w').write(output)
    runs, problems = parse(output)
    for cur, p in problems:
        print("%s: %s" % (cur or '-', p))
    if not runs:
        print(output[-2000:])
        return 1
    return 1 if compare(runs) else 0


if __name__ == '__main__':
    sys.exit(main())
