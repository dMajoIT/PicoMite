"""gen_traces.py - golden traces of the player from the original code, for the kernel port.

Each scenario places the player, holds keys tick by tick, and records the
player's slot after every tick: position in fractions, velocity, flags,
state, sprite, energy, and the jetpack charge.  The traces go to
out/traces/<name>.json and are what exilephys.py and the BASIC kernel are
checked against.

    python gen_traces.py exile-disassembly.txt [--out out] [scenario names...]
"""
import json
import os
import sys

from exile6502 import load_listing
from exilegame import Game, OBJ

JETPACK_ENERGY_LOW = 0x084E
JETPACK_ENERGY_HIGH = 0x0854

# name: (start square, [(keys, ticks), ...])
SCENARIOS = {
    # the ship's floor: standing still, then the settling that goes with it
    'stand_in_ship': (None, [((), 40)]),
    # standing on the surface, nothing pressed: the settle onto the ground
    'stand_on_surface': ((0x90, 0x4D), [((), 60)]),
    # free fall from the sky onto the surface, then rest
    'fall_to_surface': ((0x90, 0x40), [((), 140)]),
    # walk right along the surface, then stop and slide to a halt
    'walk_right': ((0x90, 0x4D), [((), 30), (('W',), 60), ((), 40)]),
    # walk left
    'walk_left': ((0x90, 0x4D), [((), 30), (('Q',), 60), ((), 40)]),
    # a jump from the surface, and coming down
    'jump': ((0x90, 0x4D), [((), 30), (('JUMP',), 1), ((), 60)]),
    # the jetpack: up for a second, then fall back
    'jetpack_up': ((0x90, 0x4D), [((), 30), (('P',), 25), ((), 80)]),
    # jetpack with the booster (not collected, so it should do nothing extra)
    'jetpack_boost': ((0x90, 0x4D), [((), 30), (('P', '@'), 25), ((), 60)]),
    # thrust right in the air
    'thrust_right_airborne': ((0x90, 0x40), [(('W',), 40), ((), 60)]),
    # drop into the western caves' water (waterline row &CE at x < &54)
    'into_water': ((0x40, 0xC8), [((), 120)]),
    # walk into the surface's ragged edge to find a slope or a wall
    'walk_far_right': ((0x90, 0x4D), [((), 30), (('W',), 200)]),
    # lie down, and get up again
    'lie_down': ((0x90, 0x4D), [((), 30), (('CTRL',), 20), ((), 40)]),
    # turn round on the spot
    'turn': ((0x90, 0x4D), [((), 30), (('TAB',), 1), ((), 10), (('TAB',), 1), ((), 10)]),
    # a long flight: up, across, and down under thrust
    'fly': ((0x90, 0x4D), [((), 30), (('P',), 30), (('P', 'W'), 30), (('W',), 20), (('L',), 20), ((), 60)]),
    # a plain cave three squares high: land on its floor, then jet up into the ceiling
    'cave_ceiling': ((0x5C, 0x61), [((), 40), (('P',), 40), ((), 40)]),
    # the same cave: walk into its end wall and keep pushing
    'cave_wall': ((0x5C, 0x61), [((), 40), (('W',), 80), ((), 20), (('Q',), 120), ((), 20)]),
    # an earth slope rising to the left of flat ground: walk up it and over
    'slope_up_left': ((0x6C, 0x80), [((), 40), (('Q',), 120), ((), 30)]),
    # a stone slope rising to the right: walk up it, then jump from it
    'slope_up_right': ((0x73, 0xA0), [((), 40), (('W',), 60), (('W', 'JUMP'), 1), (('W',), 40), ((), 30)]),
}


FIELDS = ['px', 'py', 'vx', 'vy', 'flags', 'state', 'sprite', 'energy', 'jetpack',
          'angle', 'facing', 'immob', 'thrust_immob', 'jet_ok', 'timer', 'frame', 'palette',
          'rnd', 'reads', 'wl', 'd4']


def record(g, rnd_before, d4_before):
    o = g.player()
    m = g.mem
    return [o['px'], o['py'], o['vx'], o['vy'], o['flags'], o['state'], o['sprite'], o['energy'],
            m[JETPACK_ENERGY_HIGH] * 256 + m[JETPACK_ENERGY_LOW],
            m[0xDE], m[0xDF], m[0xBA], m[0xBB], m[0x358A], o['timer'], m[0xC0], o['palette'],
            list(rnd_before), g.reads, list(m[0x082E:0x0836]), d4_before]


def run_scenario(mem, name, spec, lonely=True):
    """lonely: remove every other primary object before each tick, so the
    trace is the player against the landscape alone (creatures are removed
    by zeroing their row, which is how the game marks an empty slot)."""
    from exile6502 import Halt
    start, phases = spec
    g = Game(mem)
    if start:
        g.teleport(start[0], start[1])
    trace = {'name': name, 'start': start, 'lonely': lonely, 'fields': FIELDS,
             'keys': [], 'ticks': []}
    try:
        for keys, n in phases:
            for _ in range(n):
                if lonely:
                    for s in range(1, 16):
                        g.mem[OBJ['y'] + s] = 0
                rnd_before = bytes(g.mem[0xD9:0xDD])
                # &d4 is the relative ty of whichever walking creature was updated
                # last; the player's climb up a steep slope reads it as it stands
                d4_before = g.mem[0xD4]
                g.tick(set(keys))
                trace['keys'].append(sorted(keys))
                trace['ticks'].append(record(g, rnd_before, d4_before))
    except Halt as e:
        m = g.mem
        rets = []
        for a in range(0x100 + g.cpu.sp + 1, 0x1FF):
            ret = ((m[a + 1] << 8) | m[a]) + 1
            if 0x100 <= ret < 0x6800:
                rets.append("&%04x" % ret)
        trace['halt'] = "%s at tick %d; stack %s" % (e, g.ticks, " ".join(rets))
        print("  %s: %s" % (name, trace['halt']))
    return trace


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, 'out', 'traces')
    if '--out' in args:
        out_dir = os.path.join(args[args.index('--out') + 1], 'traces')
    os.makedirs(out_dir, exist_ok=True)
    mem = load_listing(args[0])
    wanted = [a for a in args[1:] if not a.startswith('-') and a in SCENARIOS]
    for name, spec in SCENARIOS.items():
        if wanted and name not in wanted:
            continue
        trace = run_scenario(mem, name, spec)
        with open(os.path.join(out_dir, name + '.json'), 'w') as f:
            json.dump(trace, f)
        t = trace['ticks']
        print("%-22s %4d ticks: start (&%02x.%02x,&%02x.%02x) end (&%02x.%02x,&%02x.%02x) v=(%+d,%+d) flags &%02x jetpack %d" % (
            name, len(t), t[0][0] >> 8, t[0][0] & 255, t[0][1] >> 8, t[0][1] & 255,
            t[-1][0] >> 8, t[-1][0] & 255, t[-1][1] >> 8, t[-1][1] & 255, t[-1][2], t[-1][3], t[-1][4], t[-1][8]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
