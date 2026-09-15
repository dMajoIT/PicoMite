"""probe2.py - stop the game at chosen addresses during one tick of a whole-scene
trace (gen_traces2.py scenarios) and print the registers and some zero page.

    python probe2.py listing scene tick addr[,addr...] [zp,zp,...]

Every stop prints the address and its label, A X Y, the carry, and the zero
page bytes asked for (hex).  &aa is the slot being updated.
"""
import sys
sys.path.insert(0, '.')
from exile6502 import load_listing
from exilegame import Game, OBJ, MAIN_GAME_LOOP, ACTIONS, ACTION_KEYS, VSYNC_STATE
from gen_traces2 import SCENARIOS
from probe import labels_of


def main():
    listing, name, tick = sys.argv[1], sys.argv[2], int(sys.argv[3])
    stops = {int(a, 16) for a in sys.argv[4].split(',')}
    zps = [int(a, 16) for a in sys.argv[5].split(',')] if len(sys.argv) > 5 else []
    labels = labels_of(listing)
    mem = load_listing(listing)
    spec = SCENARIOS[name]
    start, objects, phases, lonely = spec[:4]
    keys = [k for k, n in phases for _ in range(n)]
    g = Game(mem, promote=False, events=spec[4] if len(spec) > 4 else False)
    if lonely == 'clear':
        lonely = False
        for s in range(1, 16):
            g.mem[OBJ['y'] + s] = 0
    if start:
        g.teleport(*start)
    for spec in objects:
        slot, typ, x, y = spec[:4]
        g.spawn(slot, typ, x, y)
        for k, v in (spec[4] if len(spec) > 4 else {}).items():
            g.mem[OBJ[k] + slot] = v
    for i in range(tick - 1):
        if lonely:
            for s in range(1, 16):
                g.mem[OBJ['y'] + s] = 0
        g.tick2(set(keys[i]))
    if lonely:
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
        print("  &%04x %-36s A=%02x X=%02x Y=%02x C=%d slot=%x  %s" % (
            pc, labels.get(pc, '')[:36], c.a, c.x, c.y, c.c, m[0xAA],
            ' '.join("%02x=%02x" % (z, m[z]) for z in zps)))
    for s in range(16):
        if m[OBJ['y'] + s]:
            print("  end slot %d: x=%02x.%02x y=%02x.%02x v=%02x,%02x" % (s, m[OBJ['x'] + s], m[OBJ['xf'] + s], m[OBJ['y'] + s], m[OBJ['yf'] + s], m[OBJ['vx'] + s], m[OBJ['vy'] + s]))


if __name__ == '__main__':
    main()
