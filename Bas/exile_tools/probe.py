"""probe.py - stop the game at chosen addresses during one tick of a trace scenario
and print the registers and some zero page, for chasing a divergence.

    python probe.py listing scenario tick addr[,addr...] [zp,zp,...]
"""
import re
import sys
sys.path.insert(0, '.')
from exile6502 import load_listing
from exilegame import Game, OBJ, MAIN_GAME_LOOP, RND_READ_STOPS, ACTIONS, ACTION_KEYS, VSYNC_STATE
from gen_traces import SCENARIOS


def labels_of(path):
    labels = {}
    prev = None
    for line in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^; ([a-z_0-9]+)', line)
        if m:
            prev = m.group(1)
            continue
        m = re.match(r'^[&#]([0-9a-f]{4})', line)
        if m and prev:
            labels.setdefault(int(m.group(1), 16), prev)
            prev = None
    return labels


def main():
    listing, name, tick = sys.argv[1], sys.argv[2], int(sys.argv[3])
    stops = {int(a, 16) for a in sys.argv[4].split(',')}
    zps = [int(a, 16) for a in sys.argv[5].split(',')] if len(sys.argv) > 5 else []
    labels = labels_of(listing)
    mem = load_listing(listing)
    start, phases = SCENARIOS[name]
    keys = [k for k, n in phases for _ in range(n)]
    g = Game(mem)
    if start:
        g.teleport(*start)
    for i in range(tick - 1):
        for s in range(1, 16):
            g.mem[OBJ['y'] + s] = 0
        g.tick(set(keys[i]))
    for s in range(1, 16):
        g.mem[OBJ['y'] + s] = 0
    m = g.mem
    k = keys[tick - 1]
    for i, nm in enumerate(ACTIONS):
        pressed = nm in k or (nm == 'JUMP' and 'P' in k) or (nm == 'P' and 'JUMP' in k)
        m[ACTION_KEYS + i] = (m[ACTION_KEYS + i] >> 1) | (0x80 if pressed else 0)
    m[VSYNC_STATE] = 2
    print("tick %d keys %s" % (tick, '+'.join(k) or '-'))
    pc = MAIN_GAME_LOOP
    while True:
        g.cpu.run_until(pc, stops | {MAIN_GAME_LOOP}, max_steps=5_000_000)
        pc = g.cpu.pc
        if pc == MAIN_GAME_LOOP:
            break
        c = g.cpu
        print("  &%04x %-40s A=%02x X=%02x Y=%02x C=%d N=%d  %s" % (
            pc, labels.get(pc, ''), c.a, c.x, c.y, c.c, c.n if hasattr(c, 'n') else -1,
            ' '.join("%02x=%02x" % (z, m[z]) for z in zps)))
    print("  end: x=%02x.%02x y=%02x.%02x v=%02x,%02x" % (m[OBJ['x']], m[OBJ['xf']], m[OBJ['y']], m[OBJ['yf']], m[OBJ['vx']], m[OBJ['vy']]))


if __name__ == '__main__':
    main()
