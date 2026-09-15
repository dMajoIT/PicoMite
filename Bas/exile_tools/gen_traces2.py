"""gen_traces2.py - traces of whole scenes from the original code: every slot, every tick.

The second generation of gen_traces.py.  Each scenario puts the player and
some objects in the world, holds keys tick by tick, and records after every
tick all sixteen slots (exilegame.FIELDS order), the water level, the screen
position, and every random number the code took as (site, value) pairs, so
that a kernel can be handed exactly the numbers the game drew at the places
it models and skip the rest.  Promotion of secondary objects and the events
are switched off in the oracle, so a scene holds only what was put in it.
The traces go to out/traces2/<name>.json.

    python gen_traces2.py exile-disassembly.txt [names...]
"""
import json
import os
import sys

from exile6502 import load_listing, Halt
from exilegame import Game, OBJ, FIELDS, SCREEN_STATE

# object types
BOULDER = 0x45
KEY = 0x51
PIANO = 0x43
GREEN_BIRD = 0x2E
WHITE_BIRD = 0x2F
RED_MAGENTA_IMP = 0x29
RED_YELLOW_IMP = 0x2A
CYAN_YELLOW_IMP = 0x2C
FLUFFY = 0x03
RED_FROGMAN = 0x06
GREEN_FROGMAN = 0x07
WORM = 0x0F
MAGGOT = 0x27
FIREBALL = 0x37
MOVING_FIREBALL = 0x39
HOVERING_BALL = 0x1A
RED_SLIME = 0x09
GREEN_SLIME = 0x0A
PIRANHA = 0x10
WASP = 0x11
MAGENTA_ROBOT = 0x1C

# name: (player start, [(slot, type, x, y[, {field: value}]), ...], [(keys, ticks), ...], lonely)
# an object's optional dict sets slot fields (exilegame.FIELDS names) after the spawn;
# lonely True wipes slots 1-15 before every tick, 'clear' wipes them once at the start
# (the image's slot 1 holds a teleporting Triax), False leaves the image's slots alone;
# an optional fifth element switches update_events on for the scene, and a
# sixth brings back objects that were put aside when they went offscreen
# lonely scenes wipe slots 1-15 before every tick, as the first-generation traces did
SCENARIOS = {
    # the player alone, as before
    'stand_in_ship': (None, [], [((), 40)], True),
    'stand_on_surface': ((0x90, 0x4D), [], [((), 60)], True),
    'fall_to_surface': ((0x90, 0x40), [], [((), 140)], True),
    'walk_right': ((0x90, 0x4D), [], [((), 30), (('W',), 60), ((), 40)], True),
    'walk_left': ((0x90, 0x4D), [], [((), 30), (('Q',), 60), ((), 40)], True),
    'jump': ((0x90, 0x4D), [], [((), 30), (('JUMP',), 1), ((), 60)], True),
    'jetpack_up': ((0x90, 0x4D), [], [((), 30), (('P',), 25), ((), 80)], True),
    'jetpack_boost': ((0x90, 0x4D), [], [((), 30), (('P', '@'), 25), ((), 60)], True),
    'thrust_right_airborne': ((0x90, 0x40), [], [(('W',), 40), ((), 60)], True),
    'into_water': ((0x40, 0xC8), [], [((), 120)], True),
    'walk_far_right': ((0x90, 0x4D), [], [((), 30), (('W',), 200)], True),
    'lie_down': ((0x90, 0x4D), [], [((), 30), (('CTRL',), 20), ((), 40)], True),
    'turn': ((0x90, 0x4D), [], [((), 30), (('TAB',), 1), ((), 10), (('TAB',), 1), ((), 10)], True),
    'fly': ((0x90, 0x4D), [], [((), 30), (('P',), 30), (('P', 'W'), 30), (('W',), 20), (('L',), 20), ((), 60)], True),
    'cave_ceiling': ((0x5C, 0x61), [], [((), 40), (('P',), 40), ((), 40)], True),
    'cave_wall': ((0x5C, 0x61), [], [((), 40), (('W',), 80), ((), 20), (('Q',), 120), ((), 20)], True),
    'slope_up_left': ((0x6C, 0x80), [], [((), 40), (('Q',), 120), ((), 30)], True),
    'slope_up_right': ((0x73, 0xA0), [], [((), 40), (('W',), 60), (('W', 'JUMP'), 1), (('W',), 40), ((), 30)], True),
    # (these stay west of x=&94: from there the view reaches the ship at &98, whose
    # tiles create a turret when they are drawn, which is a later phase)
    # a boulder falls onto the ground beside the player and comes to rest
    'boulder_rest': ((0x88, 0x4D), [(1, BOULDER, 0x8B, 0x4A)], [((), 80)], False),
    # the player and a boulder fall together; the player lands on the boulder
    'stand_on_boulder': ((0x88, 0x49), [(1, BOULDER, 0x88, 0x4C)], [((), 120)], False),
    # walk into a boulder and keep pushing
    'push_boulder': ((0x86, 0x4D), [(1, BOULDER, 0x89, 0x4D)], [((), 40), (('W',), 120), ((), 40)], False),
    # a boulder dropped onto the player's head
    'boulder_on_player': ((0x88, 0x4D), [(1, BOULDER, 0x88, 0x47)], [((), 100)], False),
    # a boulder dropped above an earth slope, rolling down it with the player watching
    'boulder_slope': ((0x6C, 0x80), [(1, BOULDER, 0x6A, 0x7D)], [((), 160)], False),
    # a key on the ground: walk to it, pick it up, carry it, drop it
    'collect_key': ((0x88, 0x4D), [(1, KEY, 0x8B, 0x4D)], [((), 40), (('W',), 30), ((), 10), (('<',), 1), ((), 10), (('Q',), 30), ((), 10), (('M',), 1), ((), 40)], False),
    # a green bird wandering in the sky over the player, and one over a cave floor
    'bird': ((0x88, 0x4D), [(1, GREEN_BIRD, 0x8A, 0x4A)], [((), 200)], False),
    'bird_cave': ((0x5C, 0x61), [(1, GREEN_BIRD, 0x5A, 0x61)], [((), 200)], False),
    # a white bird released on top of the player: it hurts
    'bird_hit': ((0x88, 0x4D), [(1, WHITE_BIRD, 0x88, 0x4C)], [((), 120)], False),
    # a red/magenta imp beside the player on the surface: it fears the player and lobs blue mushroom balls
    'imp_surface': ((0x88, 0x4D), [(1, RED_MAGENTA_IMP, 0x85, 0x4D)], [((), 200)], False),
    # a red/yellow imp, whose red bullets home in on the player and explode
    'imp_bullets': ((0x88, 0x4D), [(1, RED_YELLOW_IMP, 0x8C, 0x4D)], [((), 150)], False),
    # an imp in the cave, where the walls and drops make it turn and jump
    'imp_cave': ((0x5C, 0x61), [(1, CYAN_YELLOW_IMP, 0x5E, 0x61)], [((), 200)], False),
    # the player walks after an imp
    'imp_chase': ((0x86, 0x4D), [(1, RED_MAGENTA_IMP, 0x8A, 0x4D)], [((), 20), (('W',), 60), ((), 80)], False),
    # a fluffy beside the player: it purrs, flips about, and wanders when active
    'fluffy': ((0x88, 0x4D), [(1, FLUFFY, 0x8B, 0x4D)], [((), 200)], False),
    # a fluffy with a red/yellow imp about: it squeals and runs
    'fluffy_imp': ((0x88, 0x4D), [(1, FLUFFY, 0x86, 0x4D), (2, RED_YELLOW_IMP, 0x8C, 0x4D)], [((), 150)], False),
    # a green frogman hopping on the surface, and the player walking into its kicks
    'frogman': ((0x88, 0x4D), [(1, GREEN_FROGMAN, 0x8C, 0x4D)], [((), 150)], False),
    'frogman_kick': ((0x88, 0x4D), [(1, GREEN_FROGMAN, 0x8C, 0x4D)], [((), 10), (('W',), 40), ((), 30)], False),
    # a red frogman in the pool the player falls into
    'frogman_water': ((0x40, 0xC8), [(1, RED_FROGMAN, 0x44, 0xD0)], [((), 200)], False),
    # a worm on the surface, which shies away from the player and digs in; a maggot, which comes for it
    'worm': ((0x88, 0x4D), [(1, WORM, 0x8C, 0x4D)], [((), 200)], False),
    'maggot': ((0x88, 0x4D), [(1, MAGGOT, 0x7C, 0x4D)], [((), 100)], False),
    # a green slime in the cave, and a red slime on its ceiling dripping red drops
    'slime_cave': ((0x5C, 0x61), [(1, GREEN_SLIME, 0x5E, 0x61)], [((), 200)], False),
    'red_slime': ((0x5C, 0x61), [(1, RED_SLIME, 0x60, 0x60)], [((), 150)], False),
    # a piranha in the pool the player falls into; a wasp over the player, who walks off
    'piranha': ((0x40, 0xC8), [(1, PIRANHA, 0x46, 0xD0)], [((), 100)], False),
    'wasp': ((0x88, 0x4D), [(1, WASP, 0x8A, 0x48)], [((), 40), (('W',), 60)], False),
    # a magenta rolling robot on the surface, which fires pistol bullets at the player
    'robot': ((0x88, 0x4D), [(1, MAGENTA_ROBOT, 0x80, 0x4D)], [((), 100)], False),
    # a permanent fireball (as a nest's would be) beside the player, a temporary one that burns out,
    # and a moving one hunting the player in the cave
    'fireball': ((0x88, 0x4D), [(1, FIREBALL, 0x8A, 0x4D)], [((), 150)], False),
    'fireball_temp': ((0x88, 0x4D), [(1, FIREBALL, 0x8B, 0x4D, {'target': 0, 'timer': 30})], [((), 60)], False),
    'fireball_moving': ((0x5C, 0x61), [(1, MOVING_FIREBALL, 0x62, 0x61)], [((), 40)], False),
    # a hovering ball over the player
    'hoverball': ((0x88, 0x4D), [(1, HOVERING_BALL, 0x8A, 0x4A)], [((), 80)], False),
    # the cave under the surface: walking west uncovers two nests, one of which lets a white bird out
    # the moment it is seen; walking east bumps a pipe, which now and then lets an imp out
    'nest_view': ((0x7D, 0x54), [], [(('Q',), 40), ((), 25)], 'clear'),
    'pipe_cave': ((0x7C, 0x54), [], [(('W',), 40), ((), 100)], 'clear'),
    # walking east from the landing site to the ship: its turret, doors, engines and
    # transporter come alive as they scroll into view
    'ship_walk': ((0x8E, 0x4D), [], [(('W',), 100)], 'clear'),
    # the rest of the menagerie, one or two at a time beside the player
    'hoverrobot': ((0x88, 0x4D), [(1, 0x21, 0x8C, 0x49)], [((), 100)], False),
    'crew': ((0x88, 0x4D), [(1, 0x02, 0x8C, 0x4D)], [((), 120)], False),
    'grenade': ((0x88, 0x4D), [(1, 0x50, 0x8B, 0x4D)], [((), 40), (('W',), 30), ((), 10), (('<',), 1), ((), 10), (('Q',), 20), ((), 10), (('M',), 1), ((), 120)], False),
    'flask_full': ((0x88, 0x4D), [(1, 0x4D, 0x8B, 0x46)], [((), 100)], False),
    'flask_empty': ((0x40, 0xC8), [(1, 0x4C, 0x44, 0xD0)], [((), 60)], False),
    'bigfish': ((0x40, 0xC8), [(1, 0x0E, 0x44, 0xD0), (2, 0x10, 0x48, 0xD0)], [((), 100)], False),
    'maggotmachine': ((0x88, 0x4D), [(1, 0x48, 0x8C, 0x4D)], [((), 150)], False),
    'plasma': ((0x88, 0x4D), [(1, 0x19, 0x8E, 0x4C, {'vx': 0xD0})], [((), 60)], False),
    'lightning': ((0x88, 0x4D), [(1, 0x32, 0x8A, 0x4C, {'vx': 0x28})], [((), 40)], False),
    'cannonball': ((0x88, 0x4D), [(1, 0x15, 0x90, 0x4C, {'vx': 0xC0})], [((), 60)], False),
    'debris': ((0x88, 0x4D), [(1, 0x35, 0x8A, 0x4B)], [((), 60)], False),
    'coronium': ((0x88, 0x4D), [(1, 0x58, 0x8C, 0x4D), (2, 0x55, 0x8C, 0x48)], [((), 55)], False),
    'destinator': ((0x88, 0x4D), [(1, 0x4A, 0x8B, 0x4D)], [((), 60)], False),
    'powerpod': ((0x88, 0x4D), [(1, 0x4B, 0x8B, 0x4D)], [((), 60)], False),
    'chatter': ((0x88, 0x4D), [(1, 0x01, 0x8C, 0x4A)], [((), 100)], False),
    'clawed': ((0x88, 0x4D), [(1, 0x22, 0x8D, 0x4A)], [((), 85)], False),
    'triax': ((0x88, 0x4D), [(1, 0x26, 0x8C, 0x4D)], [((), 100)], False),
    'alienweapon': ((0x88, 0x4D), [(1, 0x47, 0x8B, 0x4D)], [((), 40)], False),
    # falling onto the red mushrooms in the cave
    'mushrooms': ((0x42, 0x5D), [], [((), 80)], 'clear'),
    # the player's own actions: remember a position and teleport back to it; pocket a key,
    # walk away and get it out again; throw a boulder
    'teleport_back': ((0x88, 0x4D), [], [((), 20), (('R',), 1), (('W',), 40), ((), 10), (('T',), 1), ((), 90)], 'clear'),
    'pocket_key': ((0x88, 0x4D), [(1, KEY, 0x8B, 0x4D)], [((), 30), (('W',), 30), ((), 5), (('<',), 1), ((), 5), (('S',), 1), ((), 20), (('Q',), 20), ((), 5), (('G',), 1), ((), 40)], False),
    'throw_boulder': ((0x86, 0x4D), [(1, BOULDER, 0x89, 0x4D)], [((), 30), (('W',), 40), ((), 5), (('<',), 1), ((), 10), (('>',), 1), ((), 60)], False),
    # with the events running: the water breathes, stars come out above the surface,
    # and worms and maggots dig their way out of the earth near the player
    'events_surface': ((0x88, 0x4D), [], [((), 200)], 'clear', True),
    'events_cave': ((0x5C, 0x61), [], [((), 200)], 'clear', True),
    'events_water': ((0x40, 0xC8), [], [((), 150)], 'clear', True),
    # with the secondary list live: the objects the game starts with, which sit
    # offscreen until the view reaches them, come back as the player walks east
    # to the ship (two grenades at &98,&4d, the cannon at &a0,&49) and in the cave
    'promote_ship': ((0x8E, 0x4D), [], [(('W',), 100)], 'clear', False, True),
    'promote_cave': ((0x5C, 0x61), [], [((), 60)], 'clear', False, True),
    # and with everything on at once, which is how the game will run
    'promote_events': ((0x8E, 0x4D), [], [(('W',), 100)], 'clear', True, True),
    # two boulders and a piano in a heap
    'heap': ((0x88, 0x4D), [(1, BOULDER, 0x8B, 0x4A), (2, BOULDER, 0x8B, 0x47), (3, PIANO, 0x8C, 0x44)], [((), 120)], False),
}


def run_scenario(mem, name, spec):
    start, objects, phases, lonely = spec[:4]
    events = spec[4] if len(spec) > 4 else False
    promote = spec[5] if len(spec) > 5 else False
    g = Game(mem, promote=promote, events=events)
    clear = lonely == 'clear'
    if clear:
        lonely = False
        for s in range(1, 16):
            g.mem[OBJ['y'] + s] = 0
    if start:
        g.teleport(start[0], start[1])
    for spec in objects:
        slot, typ, x, y = spec[:4]
        g.spawn(slot, typ, x, y)
        for k, v in (spec[4] if len(spec) > 4 else {}).items():
            g.mem[OBJ[k] + slot] = v
    trace = {'name': name, 'start': start, 'objects': objects, 'lonely': lonely, 'clear': clear,
             'events': events, 'promote': promote, 'fields': FIELDS,
             # everything the screen keeps, as it stands before the first tick: the
             # kernel works the viewport out from here rather than being told it
             'screen0': {n: g.mem[a] for n, a in SCREEN_STATE.items()},
             'keys': [], 'ticks': []}
    try:
        for keys, n in phases:
            for _ in range(n):
                if lonely:
                    for s in range(1, 16):
                        g.mem[OBJ['y'] + s] = 0
                g.tick2(set(keys))
                m = g.mem
                trace['keys'].append(sorted(keys))
                # the particle system, which the kernel does not model yet: the
                # count is the index of the last one, so &ff means none, and the
                # eight bytes a particle are velocity x and y, the two position
                # fractions, x, y, the time to live and the colour with its flags
                npart = (m[0x1E58] + 1) & 0xFF
                trace['ticks'].append({'slots': g.slots(), 'feed': g.feed, 'wl': list(m[0x082E:0x0836]),
                                       'scr': g.screen, 'd4': m[0xD4],
                                       'npart': npart, 'part': list(m[0x28D6:0x28D6 + npart * 8])})
    except Halt as e:
        trace['halt'] = "%s at tick %d" % (e, g.ticks)
        print("  %s: %s" % (name, trace['halt']))
    return trace


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, 'out', 'traces2')
    os.makedirs(out_dir, exist_ok=True)
    mem = load_listing(args[0])
    wanted = [a for a in args[1:] if a in SCENARIOS]
    for name, spec in SCENARIOS.items():
        if wanted and name not in wanted:
            continue
        trace = run_scenario(mem, name, spec)
        with open(os.path.join(out_dir, name + '.json'), 'w') as f:
            json.dump(trace, f)
        t = trace['ticks']
        live = [i for i, s in enumerate(t[-1]['slots']) if s[FIELDS.index('y')]]
        feed = sum(len(x['feed']) for x in t)
        print("%-20s %4d ticks, %d feed entries, live at the end: %s" % (name, len(t), feed, live))
    return 0


if __name__ == '__main__':
    sys.exit(main())
