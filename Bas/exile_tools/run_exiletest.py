"""run_exiletest.py - run the whole-scene CSUB kernel on the PC3 and check every slot against the game.

Puts the scene files from gen_exiletest.py (and world_types.bin) on the
board, uploads Bas/exile/exiletest.bas, runs it and compares every printed
slot of every tick with the trace in out/traces2/, reporting the first
tick and slot that differ.

    python run_exiletest.py [--nofiles] [--noworld] [--log file] [names...]

--nofiles skips putting the data files; --noworld puts the scene files but
not world_types.bin; names restrict the scenes run (sc_list.txt is rewritten).
The board is the one PC3_PORT names.
"""
import json
import os
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..', 'elite_tools'))
os.environ.setdefault('PC3_PORT', 'COM17')
from pc3 import PC3   # noqa: E402
from exilegame import FIELDS   # noqa: E402

out = os.path.join(here, 'out')


def parse(output):
    runs, problems = {}, []
    cur = None
    for line in output.splitlines():
        line = line.strip()
        if line.startswith('S '):
            cur = line[2:].strip()
            runs[cur] = {}
        elif line.startswith('O ') and cur:
            v = [int(x) for x in line[2:].split()]
            runs[cur].setdefault(v[0], {})[v[1]] = v[2:]
        elif line.startswith('F '):
            problems.append((cur, line[2:]))
        elif 'Error' in line[:12]:
            problems.append((cur, line))
    return runs, problems


def fmt_slot(s):
    d = dict(zip(FIELDS, s))
    vx = d['vx'] - 256 if d['vx'] & 128 else d['vx']
    vy = d['vy'] - 256 if d['vy'] & 128 else d['vy']
    return "type %02x (&%02x.%02x,&%02x.%02x) v=(%+d,%+d) fl=%02x sp=%02x pal=%02x en=%3d st=%02x tm=%02x tch=%02x tgt=%02x tx=%02x ty=%02x td=%02x" % (
        d['type'], d['x'], d['xf'], d['y'], d['yf'], vx, vy, d['flags'], d['sprite'], d['palette'], d['energy'],
        d['state'], d['timer'], d['touching'], d['target'], d['tx'], d['ty'], d['tdata'])


def compare(runs):
    failed = 0
    tdir = os.path.join(out, 'traces2')
    yi = FIELDS.index('y')
    fi = FIELDS.index('flags')
    for name in sorted(runs):
        trace = json.load(open(os.path.join(tdir, name + '.json')))
        ticks = runs[name]
        total = len(trace['ticks'])
        bad = None
        # a lonely trace wipes slots 1-15 before every tick, so only the player counts
        nslots = 1 if trace.get('lonely') else 16
        for n, tk in enumerate(trace['ticks']):
            mine = ticks.get(n + 1)
            if mine is None:
                bad = "stopped after tick %d" % n
                break
            for s, want in enumerate(tk['slots'][:nslots]):
                got = mine.get(s)
                if want[yi] == 0:
                    if got is not None:
                        bad = "tick %d slot %d: the game has no object here, the board has %s" % (n + 1, s, fmt_slot(got))
                    continue
                if got is None:
                    bad = "tick %d slot %d: the game has %s, the board has nothing" % (n + 1, s, fmt_slot(want))
                    break
                w = list(want); m = list(got)
                w[fi] &= 0xFE; m[fi] &= 0xFE
                if w != m:
                    diff = [FIELDS[i] for i in range(len(FIELDS)) if w[i] != m[i]]
                    keys = "+".join(trace['keys'][n]) or "-"
                    lines = ["tick %d keys %s slot %d: %s differ" % (n + 1, keys, s, ", ".join(diff))]
                    prev = ticks.get(n, {}).get(s)
                    if prev:
                        lines.append("  before  %s" % fmt_slot(prev))
                    lines.append("  board   %s" % fmt_slot(m))
                    lines.append("  game    %s" % fmt_slot(w))
                    bad = "\n".join(lines)
                    break
            if bad:
                break
        if bad is None:
            print("%-22s %4d/%-4d ticks match" % (name, len(ticks), total))
        else:
            failed += 1
            print("%-22s %4d/%-4d ticks match, then:\n%s" % (name, n, total, bad))
    return failed


def main():
    args = sys.argv[1:]
    log = args[args.index('--log') + 1] if '--log' in args else None
    names = [a for a in args if not a.startswith('--') and a != log]
    sdir = os.path.join(out, 'scene')
    if names:
        open(os.path.join(sdir, 'sc_list.txt'), 'w', newline='\n').write("\n".join(names) + "\n")
    b = PC3()
    try:
        b.attention()
        if '--nofiles' not in args:
            files = sorted(os.path.join(sdir, f) for f in os.listdir(sdir)
                           if f == 'tables2.bin' or f == 'sc_list.txt' or
                           (f.startswith('sc_') and (not names or f[3:].rsplit('.', 1)[0] in names)))
            if '--noworld' not in args:
                files.insert(0, os.path.join(out, 'world_types.bin'))
            for f in files:
                data = open(f, 'rb').read()
                t0 = time.time()
                b.xmodem_send(os.path.basename(f), data)
                print("put %-28s %6d bytes %5.1fs" % (os.path.basename(f), len(data), time.time() - t0))
        elif names:
            b.xmodem_send('sc_list.txt', ("\n".join(names) + "\n").encode())
        src = open(os.path.join(here, '..', 'exile', 'exiletest.bas'), encoding='utf-8').read()
        saved, n = b.upload(src, timeout=120)
        print("uploaded %d lines, saved %s bytes" % (n, saved))
        t0 = time.time()
        output = b.run(1200)
        print("ran in %.0f s, %d lines of output" % (time.time() - t0, output.count('\n')))
    finally:
        b.close()
    if log:
        open(log, 'w').write(output)
    runs, problems = parse(output)
    for cur, p in problems[:20]:
        print("%s: %s" % (cur or '-', p))
    if not runs:
        print(output[-2000:])
        return 1
    return 1 if compare(runs) else 0


if __name__ == '__main__':
    sys.exit(main())
