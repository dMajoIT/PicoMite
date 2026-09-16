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
# an optional fifth element switches update_events on for the scene, a
# sixth brings back objects that were put aside when they went offscreen,
# and a seventh pokes the game's own memory before the first tick, which is
# how a scene starts with a weapon collected or a pocket already full
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
    # where a new game starts, walking east off the ledge: the square to the
    # player's right is open for three squares down, so it should fall
    'ship_gap': ((0x9B, 0x3B), [], [((), 20), (('W',), 80)], 'clear'),
    # The player's weapons, which nothing had ever checked: a new game has none
    # collected and the jetpack selected, so the firing key does nothing and the
    # whole of handle_firing goes unrun.  These start with one in hand.
    # &0806 + 8 + n is "weapon n collected", &084d is the one in use.
    'fire_pistol': ((0x88, 0x4D), [], [((), 10), (('SPACE',), 10), ((), 20), (('SPACE',), 10), ((), 30)],
                    'clear', False, False, {0x080F: 0x80, 0x084D: 1}),
    'fire_icer': ((0x88, 0x4D), [], [((), 10), (('SPACE',), 10), ((), 20), (('SPACE',), 10), ((), 30)],
                  'clear', False, False, {0x0810: 0x80, 0x084D: 2}),
    'fire_plasma': ((0x88, 0x4D), [], [((), 10), (('SPACE',), 10), ((), 40)],
                    'clear', False, False, {0x0812: 0x80, 0x084D: 4}),
    # picking a weapon up with a function key, and pouring energy into it with shift
    'change_weapon': ((0x88, 0x4D), [], [((), 5), (('f1',), 5), ((), 5), (('f2',), 5), ((), 5),
                                         (('f1', 'SHIFT'), 10), ((), 10), (('SPACE',), 10), ((), 20)],
                      'clear', False, False, {0x080F: 0x80, 0x0810: 0x80}),
    # the aim, which moves the firing angle up and down
    'aim': ((0x88, 0x4D), [], [((), 5), (('K',), 15), ((), 5), (('O',), 15), ((), 5),
                               (('I',), 10), ((), 10), (('SPACE',), 10), ((), 20)],
            'clear', False, False, {0x080F: 0x80, 0x084D: 1}),
    # both whistles, which need the things that let you blow them
    'whistles': ((0x88, 0x4D), [], [((), 5), (('Y',), 10), ((), 20), (('U',), 10), ((), 40)],
                 'clear', False, False, {0x0816: 0x80, 0x0817: 0x80}),
    # The eleven object types the coverage audit found had never been run.
    # Each is put beside the player where it can be watched for a while.
    'untested_a': ((0x88, 0x4D), [(1, 0x08, 0x8B, 0x4D), (2, 0x0B, 0x8D, 0x4D)],
                   [((), 120)], 'clear'),                      # invisible frogman, yellow slime
    'dense_nest': ((0x88, 0x4D), [(1, 0x0C, 0x8B, 0x4C)], [((), 150)], 'clear'),
    'sucking_nest': ((0x88, 0x4D), [(1, 0x0D, 0x8D, 0x4C)], [((), 150)], 'clear'),
    # the two together: a sucking nest with something it can pull at
    'two_nests': ((0x88, 0x4D), [(1, 0x0C, 0x8B, 0x4C), (2, 0x0D, 0x8D, 0x4C)], [((), 150)], 'clear'),
    'untested_c': ((0x88, 0x4D), [(1, 0x12, 0x8A, 0x4C), (2, 0x14, 0x8C, 0x4C)],
                   [((), 120)], 'clear'),                      # active grenade, tracer bullet
    'untested_d': ((0x88, 0x4D), [(1, 0x28, 0x8B, 0x4B), (2, 0x30, 0x8D, 0x4A)],
                   [((), 150)], 'clear'),                      # gargoyle, red magenta bird
    'untested_e': ((0x88, 0x4D), [(1, 0x38, 0x8B, 0x4D), (2, 0x3B, 0x8D, 0x4D)],
                   [((), 150)], 'clear'),                      # inactive chatter, engine fire
    'untested_f': ((0x88, 0x4D), [(1, 0x42, 0x8A, 0x4D)],
                   [((), 20), (('W',), 40), ((), 60)], 'clear'),   # a switch, walked into
    # The tiles the coverage audit found had never been touched: the player is
    # dropped just above each and left to fall onto it.
    'water_tile': ((0x57, 0x68), [], [((), 140)], 'clear'),
    'wind_variable': ((0x40, 0x80), [], [((), 140)], 'clear'),
    'wind_constant': ((0xB8, 0x60), [], [((), 140)], 'clear'),
    'switch_tile': ((0x46, 0x54), [], [((), 40), (('W',), 40), (('Q',), 60)], 'clear'),
    'door_tile': ((0x99, 0x4A), [], [((), 60), (('W',), 40), ((), 60)], 'clear'),
    # the invisible switch at &87,&77, walked over: the world has twelve of them
    # and this is the only one with open ground either side of it
    'invisible_switch': ((0x8A, 0x77), [], [((), 30), (('Q',), 70), ((), 40)], 'clear'),
    # carrying something and putting it down, and the weight slowing the walk
    'drop_boulder': ((0x88, 0x4D), [(1, BOULDER, 0x8A, 0x4C)],
                     [((), 20), (('<',), 10), (('W',), 30), (('M',), 10), ((), 40)], 'clear'),
    'carry_piano': ((0x88, 0x4D), [(1, PIANO, 0x8A, 0x4C)],
                    [((), 20), (('<',), 10), (('W',), 60), (('Q',), 60)], 'clear'),
    # the arrow keys, which move the view without moving the player
    'scroll_view': ((0x88, 0x4D), [], [((), 10), (('RIGHT',), 30), (('DOWN',), 30),
                                       (('LEFT',), 30), (('UP',), 30)], 'clear'),
    # a stone door, which the player can fall onto here
    'stone_door': ((0x50, 0x5E), [], [((), 60), (('W',), 40), (('Q',), 40)], 'clear'),
    # the remote control device worked at a door, which is what it is for and
    # what nothing had tried: every key is collected so the lock will turn
    # the remote control device worked at a locked door.  The device starts in a
    # pocket and is taken out with G, which is the only way to get it in hand
    # without solving the touching geometry as well; the door at &9f,&71 has a
    # floor beside it at &a0,&71, so the player can stand level with it and face
    # it, and any other angle is too wide for the game to accept.
    'remote_door': ((0xA0, 0x71), [],
                    [((), 20), (('Q',), 10), (('G',), 4), ((), 6),
                     (('SPACE',), 10), ((), 30), (('SPACE',), 10), ((), 30)],
                    'clear', False, False,
                    dict([(0x0806 + i, 0x80) for i in range(16)] + [(0x0847, 1), (0x0848, 0x4E)])),
    # a door walked into.  Every door in the world starts locked, so this one
    # only leans on it: the code that swings a door open is in door_unlocked.
    'door_touch': ((0xAC, 0x62), [], [((), 30), (('W',), 60), ((), 30), (('Q',), 40)], 'clear'),
    # the same door as remote_door, unlocked with the control and then walked
    # through: it opens above the player's head and it is the only way to see a
    # door finish its travel
    'door_unlocked': ((0xA0, 0x71), [],
                      [((), 20), (('Q',), 10), (('G',), 4), ((), 6),
                       (('SPACE',), 10), ((), 10), (('Q',), 70), ((), 30)],
                      'clear', False, False,
                      dict([(0x0806 + i, 0x80) for i in range(16)] + [(0x0847, 1), (0x0848, 0x4E)])),
    # a metal door of colour pair zero (&bf,&80), which is the kind that shuts
    # itself again once it is fully open: unlock it and wait
    'door_auto': ((0xC1, 0x80), [],
                  [((), 20), (('Q',), 10), (('G',), 4), ((), 6),
                   (('SPACE',), 10), ((), 130)],
                  'clear', False, False,
                  dict([(0x0806 + i, 0x80) for i in range(16)] + [(0x0847, 1), (0x0848, 0x4E)])),
    # a plasma ball, and something for it to run into
    'plasma_ball': ((0x88, 0x4D), [(1, 0x19, 0x8B, 0x4B), (2, BOULDER, 0x8D, 0x4C)],
                    [((), 140)], 'clear'),
    # a plasma ball driven into a boulder: it becomes a fireball on contact
    'plasma_hit': ((0x88, 0x4D), [(1, 0x19, 0x8B, 0x4C, {'vx': 0x40}), (2, BOULDER, 0x8D, 0x4C)],
                  [((), 100)], 'clear'),
    # the river at the bottom of Triax's lab, whose wind tiles carry no data of
    # their own and so run the variable water routine instead
    'water_variable': ((0x68, 0xDE), [], [((), 140)], 'clear', True),
    # water processed as an event, which is the one place the game insists on
    # making an object whether or not a slot is free
    'water_event': ((0x57, 0x68), [], [((), 140)], 'clear', True),
    # an active chatter, which looses lightning at what it can see
    'chatter_lightning': ((0x88, 0x4D), [(1, 0x01, 0x8D, 0x4B)], [((), 160)], 'clear'),
    # a chatter with something to shoot at.  It fires only at a cyan/red turret,
    # only within about fourteen degrees of horizontal and never backwards.  The
    # turret needs a tertiary data byte of its own: with the zero a bare spawn
    # leaves, the game reads a projectile type of zero and runs the turret as a
    # rolling robot instead, which no turret on the planet ever does.  Tertiary
    # slots 0 to 2 belong to no square, so slot 0 is free to borrow: &2a is what
    # the turret at &aa,&98 carries, a live turret firing cannonballs.
    'chatter_fire': ((0x88, 0x4D), [(1, 0x01, 0x8B, 0x4B), (2, 0x20, 0x90, 0x4B)],
                     [((), 160)], 'clear', False, False, {0x0986: 0x2A}),
    # worms and maggots crawling out of the ground, which is an event rather than
    # anything an object does.  It takes a random tile within four squares of the
    # player being solid earth, one frame in sixteen, and the deeper the likelier;
    # &a1,&c8 is an open square with 79 of its 81 neighbours earth, far enough
    # down that the odds are worth having.
    'worm_emerges': ((0xA1, 0xC8), [], [((), 200)], 'clear', True),
    # the game's own opening: the player standing in the ship.  The two hatches
    # are the only doors of the fifty in the world whose tertiary byte has bit 7
    # clear in the snapshot the listing was taken from, which tells the game they
    # have already become primary objects and stops it ever making them; the
    # pokes put them back as a new game has them.  Nothing here is pressed: what
    # is being watched is whether the first redraw makes the hatches at all.
    'ship_start': ((0x9B, 0x3B), [], [((), 120)], 'clear', False, False,
                   {0x0995: 0x81, 0x09AF: 0x81}),
    # the same, with the events running, which is how the game plays it: the
    # stars drifting in the sky above the ship are made in update_events, one
    # at a time at a random tile near the player, so with the events off there
    # is no stardust at all.
    'ship_stars': ((0x9B, 0x3B), [], [((), 120)], 'clear', True, False,
                   {0x0995: 0x81, 0x09AF: 0x81}),
    # the arrow keys moving the view on its own, pressed and released one at a
    # time.  They suppress auto-repeat, so holding one does nothing after the
    # first tick and each separate press is worth one tile, up to two tiles in
    # x and four in y.  What is being checked is that every press counts.
    'view_scroll': ((0x9B, 0x3B), [],
                    [((), 10), (('UP',), 2), ((), 3), (('UP',), 2), ((), 3), (('UP',), 2), ((), 3), (('UP',), 2), ((), 3), (('DOWN',), 2), ((), 3), (('DOWN',), 2), ((), 3), (('LEFT',), 2), ((), 3), (('LEFT',), 2), ((), 3), (('RIGHT',), 2), ((), 3), (('RIGHT',), 2), ((), 3), ((), 10)],
                    'clear'),
    # a rolling robot shot by the cannon.  A cannonball does 110 damage, which is
    # the easiest way to kill something outright, and the noisy kinds of creature
    # take a different exit from the quiet ones.
    'cannon_kill': ((0x9C, 0x47), [(2, 0x46, 0x9E, 0x47), (3, 0x1C, 0xA0, 0x47)],
                    [((), 24), (('G',), 4), ((), 8), (('SPACE',), 10), ((), 90)],
                    'clear', False, False, {0x0847: 1, 0x0848: 0x4F}),
    # plasma balls under water, which have a one-in-four chance each tick of
    # simply going out.  The waterline is per x range, not global: for x below
    # &54 it is row &ce, so &23,&d1 is three rows under.  Five balls, because one
    # has a short life and one chance in four needs a few tries.
    'plasma_water': ((0x23, 0xCF), [(s, 0x19, 0x23, 0xD1) for s in range(1, 6)],
                     [((), 120)], 'clear'),
    # Four conversions, each of which turns one object into another.  They are
    # cheap to set up because they need only two objects touching, and none had
    # ever run: the game has to be watched doing them or the port's transcription
    # of them is guesswork.
    #
    # a fireball landing on a mushroom ball, which makes a coronium crystal
    'mushroom_fireball': ((0x88, 0x4D), [(1, 0x33, 0x8A, 0x4C), (2, 0x37, 0x8A, 0x4C)],
                          [((), 60)], 'clear'),
    # a green slime fed a coronium crystal, which turns it yellow.  It needs the
    # events on: with them off the slime never takes the crystal, wherever the
    # crystal is put.  Slot 1 is the one that changes, from &0a to &0b, so it is
    # this slime being fed and not one an event brought in.
    'slime_crystal': ((0x88, 0x4D), [(1, 0x0A, 0x8A, 0x4C), (2, 0x58, 0x8A, 0x4C)],
                      [((), 200)], 'clear', True),
    # a red drop falling on a yellow slime, which makes a coronium boulder
    'slime_boulder': ((0x88, 0x4D), [(1, 0x0B, 0x8A, 0x4C), (2, 0x36, 0x8A, 0x4B)],
                      [((), 80)], 'clear'),
    # an inactive chatter woken by whistle one.  Two things about this are not
    # what they look like.  The key is U, not Y: the listing's key table lists the
    # two whistle handlers against the wrong keys, and the routine it calls
    # handle_playing_whistle_two is the one that tests whistle ONE collected and
    # sets whistle_one_active, which is what the chatter listens for.  And the
    # chatter wakes only while its energy reserve is above zero; the reserve
    # starts empty, so the scene fills it, as feeding it crystals would in play.
    'chatter_whistle': ((0x88, 0x4D), [(1, 0x38, 0x8B, 0x4C)],
                        [((), 5), (('U',), 10), ((), 85)],
                        'clear', False, False, {0x081C: 4, 0x0816: 0x80}),
    # standing still on the flat ledge the cannon scene uses, with nothing else
    # in it: the control against which that scene's faults are read
    'flat_ledge': ((0x9C, 0x47), [], [((), 60)], 'clear'),
    # the cannon, which fires when the player shoots its own control device at it.
    # The cone it will accept is narrow: the angle from the device to the cannon
    # has the distance added to it before the test, so both the height and the
    # range matter.  &9c,&47 is flat ground five squares wide, which is what it
    # takes for the player to stand still with the device level with the cannon;
    # on the sloping ledge tried first the player slid east and the shot missed.
    'cannon_fire': ((0x9C, 0x47), [(2, 0x46, 0x9E, 0x47)],
                    [((), 24), (('G',), 4), ((), 8),
                     (('SPACE',), 10), ((), 54)],
                    'clear', False, False, {0x0847: 1, 0x0848: 0x4F}),
    # a boulder carried into the air: the player's weight while holding one is
    # six, which is the only way the walking acceleration gets halved
    'hold_fly': ((0xA0, 0x71), [],
                 [((), 20), (('G',), 4), ((), 6), (('P',), 60), ((), 30)],
                 'clear', False, False, {0x0847: 1, 0x0848: 0x45}),
    # two boulders and a piano in a heap
    'heap': ((0x88, 0x4D), [(1, BOULDER, 0x8B, 0x4A), (2, BOULDER, 0x8B, 0x47), (3, PIANO, 0x8C, 0x44)], [((), 120)], False),
}

# What each scene is for.  A scene that passes proves nothing unless the code it
# was written for actually ran, and three scenes here have at some point passed
# while never entering the routine they were aimed at: the aim was too wide, the
# object was never picked up, the door was never touched.  Each entry below names
# routines in the listing that the scene must reach; audit_coverage.py --proves
# checks them, and a scene that stops exercising its subject fails there rather
# than sitting green.
PROVES = {
    'remote_door': ['consider_toggling_lock', 'check_if_object_hit_by_other_control'],
    # this one never toggles the door: unlocking it sets it opening already, so
    # what it is for is the travel afterwards and the door coming to rest
    'door_unlocked': ['stop_door', 'not_at_end_of_track', 'is_unlocked'],
    'door_auto': ['toggle_door_opening'],
    'door_touch': ['update_door', 'skip_toggling_door_lock'],
    'cannon_fire': ['update_cannon', 'create_projectile_with_zero_velocity_y',
                    'update_cannonball'],
    'chatter_fire': ['create_lightning'],
    'mushroom_fireball': ['convert_mushroom_ball_to_coronium_crystal'],
    'slime_crystal': ['change_slime_type'],
    'slime_boulder': ['convert_yellow_slime_to_coronium_boulder'],
    'cannon_kill': ['explode_object_with_loud_squeal'],
    'ship_start': ['update_door', 'update_metal_door_tile'],
    'worm_emerges': ['emerge_worm_or_maggot', 'spawn_object_in_event'],
    'plasma_water': ['remove_plasma_ball_or_fireball'],
    'chatter_whistle': ['activate_chatter'],
    'hold_fly': ['consider_dropping_held_object'],
    'plasma_ball': ['update_plasma_ball'],
    'stone_door': ['update_door'],
    'sucking_nest': ['update_sucking_nest'],
    'two_nests': ['update_sucking_nest', 'update_dense_nest'],
    'whistles': ['handle_playing_whistle_one', 'handle_playing_whistle_two'],
    'teleport_back': ['handle_teleporting'],
}


def run_scenario(mem, name, spec):
    start, objects, phases, lonely = spec[:4]
    events = spec[4] if len(spec) > 4 else False
    promote = spec[5] if len(spec) > 5 else False
    pokes = spec[6] if len(spec) > 6 else {}
    g = Game(mem, promote=promote, events=events)
    clear = lonely == 'clear'
    if clear:
        lonely = False
        for s in range(1, 16):
            g.mem[OBJ['y'] + s] = 0
    for addr, val in pokes.items():          # the seventh element sets the game up:
        g.mem[addr] = val                    # a weapon collected, a pocket filled
    if start:
        g.teleport(start[0], start[1])
    for spec in objects:
        slot, typ, x, y = spec[:4]
        g.spawn(slot, typ, x, y)
        for k, v in (spec[4] if len(spec) > 4 else {}).items():
            g.mem[OBJ[k] + slot] = v
    trace = {'name': name, 'start': start, 'objects': objects, 'lonely': lonely, 'clear': clear,
             'events': events, 'promote': promote, 'pokes': pokes, 'fields': FIELDS,
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
