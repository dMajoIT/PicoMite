"""run_exiletest.py - run the whole-scene CSUB kernel on the PC3 and check every slot against the game.

Puts the scene files from gen_exiletest.py (and world_types.bin) on the
board, uploads Bas/exile/exiletest.bas, runs it and compares every printed
slot of every tick with the trace in out/traces2/, reporting the first
tick and slot that differ.

    python run_exiletest.py [--nofiles] [--noworld] [--lib] [--reput] [--log file] [names...]

--nofiles skips putting the data files; --noworld puts the scene files but
not world_types.bin; --lib puts only the kernel (out/scene/exile_lib.bas),
which is what changes when csub/exile.c does; names restrict the scenes run
(sc_list.txt is rewritten).  The board is the one PC3_PORT names.

Only the files that changed are put.  The board keeps a list of what it
already has, one digest a file, in `exile_put.txt` on its own drive, so a
drive that is wiped or a board that has never been used loses the list with
the files and everything is put again.  --reput ignores the list and puts
everything.  A full set is a hundred and sixty files and eleven minutes;
changing only the kernel is a few seconds.

The kernel is not in the program: it is a library file that the program loads
with LIBRARY LOAD, since its hex text and binary together are more than
program memory holds.  LIBRARY LOAD hashes the file, so putting an unchanged
one costs nothing.
"""
import hashlib
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


MANIFEST = 'exile_put.txt'   # on the board, beside the files it lists


def digest(data):
    return hashlib.sha256(data).hexdigest()[:16]


def board_manifest(b, force=False):
    """What the board says it already has: {name: digest}.  The list lives on
       the board's own drive, so it cannot outlive the files it describes."""
    if force:
        return {}
    try:
        # XMODEM pads its last block, so the file comes back longer than it was
        raw = b.grab(MANIFEST, timeout=60).rstrip(bytes([26, 0]))
        return json.loads(raw.decode())
    except Exception:
        return {}      # never been used, wiped, or unreadable: put everything


def put_files(b, manifest, items):
    """Put the (name, contents) the board does not already have."""
    put = skipped = 0
    for name, data in items:
        d = digest(data)
        if manifest.get(name) == d:
            skipped += 1
            continue
        t0 = time.time()
        b.xmodem_send(name, data)
        manifest[name] = d        # only after the put, so a failure re-puts
        put += 1
        print("put %-28s %6d bytes %5.1fs" % (name, len(data), time.time() - t0))
    return put, skipped


def save_manifest(b, manifest, put):
    """Leave the list on the board, but only if it changed."""
    if put:
        b.xmodem_send(MANIFEST, json.dumps(manifest, sort_keys=True).encode())


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
    b = PC3()
    try:
        b.attention()
        manifest = board_manifest(b, '--reput' in args)
        if '--nofiles' not in args:
            files = sorted(os.path.join(sdir, f) for f in os.listdir(sdir)
                           if f in ('tables2.bin', 'sc_list.txt', 'exile_lib.bas') or
                           (f.startswith('sc_') and (not names or f[3:].rsplit('.', 1)[0] in names)))
            if '--noworld' not in args:
                files.insert(0, os.path.join(out, 'world_types.bin'))
        elif '--lib' in args:
            files = [os.path.join(sdir, 'exile_lib.bas')]
        else:
            files = []
        items = [(os.path.basename(f), open(f, 'rb').read()) for f in files]
        if names:
            # the scenes to run, built here rather than written over the list
            # gen_exiletest.py generated, which is every scene there is
            items = [it for it in items if it[0] != 'sc_list.txt']
            items.append(('sc_list.txt', ("\n".join(names) + "\n").encode()))
        t0 = time.time()
        put, skipped = put_files(b, manifest, items)
        save_manifest(b, manifest, put)
        if files:
            print("put %d files in %.0f s, %d already on the board" % (put, time.time() - t0, skipped))
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
