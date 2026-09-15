"""bisect_cache.py - find which sub the trace cache gets wrong.

With OPTION TRACECACHE ON, physics.bas diverges from the game at the first
ceiling hit (cave_ceiling, tick 81).  This uploads variants of the program
that opt only a chosen set of subs into the cache (OPTION CACHE SUB) and runs
the cave_ceiling scenario alone, reporting whether the 120 ticks still match.

    python bisect_cache.py all              cache everything (the failing case)
    python bisect_cache.py none             cache nothing but leave the cache on
    python bisect_cache.py Sub1,Sub2,...    cache only these
    python bisect_cache.py bisect           halve the list until one sub is left

phys_list.txt on the board is replaced by one naming cave_ceiling only, and
put back to the full list at the end.
"""
import json
import os
import re
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..', 'elite_tools'))
os.environ.setdefault('PC3_PORT', 'COM17')
from pc3 import PC3   # noqa: E402
from run_phystest import parse, COMPARE   # noqa: E402

out = os.path.join(here, 'out')
SCENARIO = 'cave_ceiling'


def sub_names(src):
    return re.findall(r'^(?:Sub|Function) ([A-Za-z0-9_]+)', src, re.M)


def variant(src, names):
    """physics.bas with the cache on and only `names` opted in (None = all)."""
    lines = ["Option TRACECACHE ON 2048"]
    if names is not None:
        if not names:
            lines.append("Option CACHE SUB NoSuchSub")
        for i in range(0, len(names), 6):
            lines.append("Option CACHE SUB " + ", ".join(names[i:i + 6]))
    ins = "".join(l + "\r\n" for l in lines)
    assert src.count("Option BASE 0\r\n") == 1
    return src.replace("Option BASE 0\r\n", "Option BASE 0\r\n" + ins, 1)


def check(b, src, names):
    saved, n = b.upload(variant(src, names), timeout=120)
    output = b.run(300)
    runs, problems = parse(output)
    for line in output.splitlines():
        if line.startswith('E '):
            problems.append((SCENARIO, "timing: " + line))
    trace = json.load(open(os.path.join(out, 'traces', SCENARIO + '.json')))
    idx = {f: i for i, f in enumerate(trace['fields'])}
    rows = runs.get(SCENARIO, [])
    for k, row in enumerate(trace['ticks']):
        if k >= len(rows):
            return k, problems
        oracle = {f: row[idx[f]] for f in COMPARE}
        mine = dict(rows[k])
        oracle['flags'] &= 0xFE
        mine['flags'] &= 0xFE
        if any(mine[f] != oracle[f] for f in COMPARE):
            return k, problems
    return len(trace['ticks']), problems


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else 'all'
    src = open(os.path.join(here, '..', 'exile', 'physics.bas'), encoding='utf-8', newline='').read()
    names = sub_names(src)
    b = PC3()
    try:
        b.attention()
        b.xmodem_send('phys_list.txt', (SCENARIO + "\n").encode())
        if what == 'bisect':
            good = []           # subs known safe to cache
            pool = list(names)
            while len(pool) > 1:
                half = pool[:len(pool) // 2]
                t0 = time.time()
                k, problems = check(b, src, good + half)
                print("  %2d subs cached (%s...): %d ticks ok  [%.0fs]" % (
                    len(half), ", ".join(half[:3]), k, time.time() - t0))
                if k < 120:
                    pool = half
                else:
                    good += half
                    pool = pool[len(pool) // 2:]
            k, problems = check(b, src, good + pool)
            print("culprit: %s (%d ticks ok with it, %d subs safe)" % (pool[0], k, len(good)))
        else:
            sel = None if what == 'all' else ([] if what == 'none' else what.split(','))
            k, problems = check(b, src, sel)
            print("%s: %d/120 ticks match" % (what, k))
            for cur, p in problems:
                print("  " + p)
    finally:
        try:
            b.xmodem_send('phys_list.txt', open(os.path.join(out, 'phys', 'phys_list.txt'), 'rb').read())
        finally:
            b.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
