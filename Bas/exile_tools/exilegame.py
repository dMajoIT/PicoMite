"""exilegame.py - the original game, one tick at a time, as an oracle for the port.

Runs main_game_loop (&19B6) on the level7 image with the vsync gate
pre-satisfied and the key table driven from here, and reads the object
slots back after each tick.  The physics, the creatures, the tertiary
objects, the water: all of it is the real 6502 code, so a trace from
here is what the BASIC has to reproduce.

    g = Game(mem)                  # mem from exile6502.load_listing
    g.teleport(0x90, 0x40)         # put the player somewhere
    for _ in range(50):
        g.tick({'P'})              # hold the thrust-up key
        print(g.player())

Keys are the action names in the listing's actions table: COPY f0-f9 G
SPACE I LEFT RIGHT UP DOWN K O @ CTRL TAB Y U T R > M < S V Q W P L SHIFT,
with 'JUMP' for the second P entry (the non-repeating one).
"""
import copy

MAIN_GAME_LOOP = 0x19B6
DAMAGE_OBJECT = 0x24A6
CHECK_RELIABILITY = 0x2D92
REDUCE_WEAPON_ENERGY = 0x2D79
CHECK_COPY_PROTECTION = 0x394E
CONSIDER_PROMOTING = 0x0BE8
UPDATE_EVENTS = 0x259A
RND_READ_STOPS = frozenset([MAIN_GAME_LOOP, DAMAGE_OBJECT, CHECK_RELIABILITY, REDUCE_WEAPON_ENERGY])

# the second-generation feed: every place the code takes a random number.
# RND_ENTRY is the generator itself (the site is the JSR that called it and
# the value what it returned); RND_SITES are the instructions that read a
# byte of rnd_state directly (the site is the instruction, the value the
# byte); CARRY_SITES record the carry flag on arrival.
RND_ENTRY = 0x2587
RND_SITES = [0x14E0, 0x2174, 0x220D, 0x2243, 0x24AD, 0x24DA, 0x257A, 0x25E8, 0x2677, 0x2682, 0x26A7,
             0x2754, 0x2771, 0x27A7, 0x283F, 0x2DA0, 0x31DA, 0x3D48, 0x3D78, 0x3D85, 0x3F2A, 0x3F76,
             0x4035, 0x403A, 0x40AC, 0x41EB, 0x426A, 0x427A, 0x42BA, 0x42CE, 0x42DB, 0x44C5, 0x4621,
             0x46AB, 0x4720, 0x4726, 0x4738, 0x473A, 0x4749, 0x478A, 0x47D7, 0x4809, 0x4815, 0x4914,
             0x491A, 0x4A94, 0x4A96, 0x4AD8, 0x4ADA, 0x4B4D, 0x4B51, 0x4BCD, 0x4BCF, 0x4C21, 0x4C38,
             0x4E1F, 0x4EA5, 0x4F05, 0x4F33, 0x4F39, 0x4F88, 0x4FBD, 0x4FD0, 0x60B3, 0x60B5]
CARRY_SITES = [REDUCE_WEAPON_ENERGY]
# Zero-page scratch the physics reads after the plotting code has used it for
# its own purposes, which a kernel that does not plot cannot derive, so the
# feed hands the byte over at the instruction that reads it:
#   &22fe calculate_normalised_relative_position_of_centres: bit 7 of the sign
#         register (&99) is the borrow of its x subtraction, and by then the
#         byte is whatever the sprite plotting, particle plotting and sound
#         code last left in it;
#   &39b2 check_for_space_to_side_of_object: "half the object's width" (&4b)
#         is really the width the last sprite plot left, clipped and adjusted.
SCRATCH_SITES = {0x22FE: 0x99, 0x39B2: 0x4B}
SIGNS_SITE = 0x22FE
# get_tile_and_check_for_tertiary_objects calls a tile's own routine here (JSR
# call_tile_update_routine) when the processing mode wants it: the feed records
# the tile (x in bits 0-7, y in 8-15) and the mode (bits 16-23), so that the
# calls the plotting makes, which the kernel does not model, can be replayed
TILE_SITE = 0x1787
FEED_STOPS = frozenset([MAIN_GAME_LOOP, RND_ENTRY, TILE_SITE] + list(SCRATCH_SITES) + RND_SITES + CARRY_SITES)
# the slot tables in the order a trace records them
FIELDS = ['type', 'sprite', 'xf', 'x', 'yf', 'y', 'flags', 'palette', 'vx', 'vy', 'target', 'tx',
          'energy', 'ty', 'touching', 'timer', 'tdata', 'state']
VSYNC_STATE = 0x11E4
ACTION_KEYS = 0x126B
FRAME_COUNTER = 0xC0
RND_STATE = 0xD9

# slot tables, one byte per primary object
OBJ = {
    'type': 0x0860, 'sprite': 0x0870, 'xf': 0x0880, 'x': 0x0891, 'yf': 0x08A3, 'y': 0x08B4,
    'flags': 0x08C6, 'palette': 0x08D6, 'vx': 0x08E6, 'vy': 0x08F6, 'target': 0x0906,
    'tx': 0x0916, 'energy': 0x0926, 'ty': 0x0936, 'touching': 0x0946, 'timer': 0x0956,
    'tdata': 0x0966, 'state': 0x0976,
}
# actions in the order of the key table; 'P' is thrust up (repeats), 'JUMP' the second P
ACTIONS = ['COPY', 'f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'SAVE', 'G', 'SPACE', 'I',
           'LEFT', 'RIGHT', 'UP', 'DOWN', 'K', 'O', '@', 'CTRL', 'TAB', 'Y', 'U', 'T', 'R', '>', 'M', '<',
           'S', 'V', 'Q', 'W', 'P', 'JUMP', 'L', 'SHIFT']


def s8(v):
    return v - 256 if v & 0x80 else v


class Game:
    def __init__(self, mem, promote=True, events=True):
        """promote=False stops secondary objects becoming primary ones, events=False
        stops update_events (nests, water, earthquakes...): the scene then holds
        exactly the objects put in it."""
        from exile6502 import CPU
        self.mem = bytearray(mem)
        self.cpu = CPU(self.mem)
        self.ticks = 0
        self.reads = []
        self.feed = []
        self.screen = []
        if not promote:
            self.mem[CONSIDER_PROMOTING] = 0x60
        if not events:
            self.mem[UPDATE_EVENTS] = 0x60
        # what relocate_binary_and_saved_position (&78ed) does to the
        # variables before the first frame: zero page &01-&df wiped,
        # acceleration_power 5 tiles, player upright, no object held
        for a in range(1, 0xE0):
            self.mem[a] = 0
        self.mem[0x35] = 0x28
        self.mem[0xDE] = 0xC0
        self.mem[0xDD] = 0xFF
        # nobody typed the protection word, so the game would count as a demo
        # and wipe itself with a 1 in 256 chance every 32 frames: make the check return
        self.mem[CHECK_COPY_PROTECTION] = 0x60

    def snapshot(self):
        return bytes(self.mem), (self.cpu.a, self.cpu.x, self.cpu.y, self.cpu.sp), self.ticks

    def restore(self, snap):
        self.mem[:] = snap[0]
        self.cpu.a, self.cpu.x, self.cpu.y, self.cpu.sp = snap[1]
        self.ticks = snap[2]

    def tick(self, keys=()):
        """One iteration of the main loop with these action keys held."""
        m = self.mem
        for i, name in enumerate(ACTIONS):
            a = ACTION_KEYS + i
            # the interrupt shifts the history right and puts 'pressed now' in bit 7
            m[a] = (m[a] >> 1) | (0x80 if (name in keys or (name == 'JUMP' and 'P' in keys) or (name == 'P' and 'JUMP' in keys)) else 0)
        m[VSYNC_STATE] = 2
        # note what the game's code sees at the places the player's physics
        # depends on something a transcription cannot derive: the random byte
        # at damage_object and check_reliability, and the carry brought into
        # reduce_energy_of_weapon_X (left by add_particle: the jetpack drains
        # one unit when its thrust particle could not be added, two when it could)
        self.reads = []
        pc = MAIN_GAME_LOOP
        while True:
            self.cpu.run_until(pc, RND_READ_STOPS, max_steps=5_000_000)
            pc = self.cpu.pc
            if pc == MAIN_GAME_LOOP:
                break
            self.reads.append([pc, self.cpu.c if pc == REDUCE_WEAPON_ENERGY else m[RND_STATE + 1]])
        self.ticks += 1

    def tick2(self, keys=()):
        """One tick, recording every random number the code took as (site, value)
        in self.feed, and the screen position afterwards in self.screen."""
        m = self.mem
        for i, name in enumerate(ACTIONS):
            a = ACTION_KEYS + i
            m[a] = (m[a] >> 1) | (0x80 if (name in keys or (name == 'JUMP' and 'P' in keys) or (name == 'P' and 'JUMP' in keys)) else 0)
        m[VSYNC_STATE] = 2
        self.feed = []
        cpu = self.cpu
        pc = MAIN_GAME_LOOP
        while True:
            cpu.run_until(pc, FEED_STOPS, max_steps=5_000_000)
            pc = cpu.pc
            if pc == MAIN_GAME_LOOP:
                break
            if pc == RND_ENTRY:
                # the value is A on return, with the carry the generator leaves in bit 8:
                # several callers add that carry straight into their arithmetic
                ret = ((m[0x102 + cpu.sp] << 8) | m[0x101 + cpu.sp]) + 1
                cpu.run_until(pc, ret, max_steps=1000)
                self.feed.append([ret - 3, cpu.a | (cpu.c << 8)])
                pc = ret
                if pc in RND_SITES:
                    # the instruction after the call is itself a read of the state;
                    # run_until would step over it before looking for stops
                    self.feed.append([pc, m[m[pc + 1]]])
            elif pc in CARRY_SITES:
                self.feed.append([pc, cpu.c])
            elif pc in SCRATCH_SITES:
                self.feed.append([pc, m[SCRATCH_SITES[pc]]])
            elif pc == TILE_SITE:
                self.feed.append([pc, m[0x95] | (m[0x97] << 8) | (m[0x2D] << 16)])
            else:
                self.feed.append([pc, m[m[pc + 1]]])
        self.screen = [m[0xC8], m[0xCA]] + list(m[0x0B91:0x0B99])
        self.ticks += 1

    def spawn(self, slot, type, x, y, xf=0x80, yf=0x00):
        """Put an object of `type` in a slot as create_new_object_in_slot_Y would:
        default sprite and palette, newly created, touching nothing, full energy."""
        m = self.mem
        m[OBJ['type'] + slot] = type
        m[OBJ['palette'] + slot] = m[0x02EF + type] & 0x7F
        m[OBJ['sprite'] + slot] = m[0x028A + type]
        m[OBJ['flags'] + slot] = 0x05
        m[OBJ['touching'] + slot] = 0xFF
        m[OBJ['target'] + slot] = slot
        for k in ('tdata', 'state', 'timer', 'vx', 'vy'):
            m[OBJ[k] + slot] = 0
        r = 10
        while True:
            r -= 1
            if type >= m[0x29EE + r]:
                break
        m[OBJ['energy'] + slot] = m[0x29F8 + r]
        m[OBJ['x'] + slot] = x
        m[OBJ['y'] + slot] = y
        m[OBJ['xf'] + slot] = xf
        m[OBJ['yf'] + slot] = yf

    def slots(self):
        """All sixteen slots, each a list in FIELDS order."""
        m = self.mem
        return [[m[OBJ[f] + s] for f in FIELDS] for s in range(16)]

    def obj(self, slot):
        m = self.mem
        o = {k: m[a + slot] for k, a in OBJ.items()}
        o['vx'] = s8(o['vx'])
        o['vy'] = s8(o['vy'])
        o['px'] = o['x'] * 256 + o['xf']       # position in fractions, 256 a square
        o['py'] = o['y'] * 256 + o['yf']
        o['slot'] = slot
        return o

    def player(self):
        return self.obj(0)

    def teleport(self, x, y, xf=0x80, yf=0x00, slot=0):
        m = self.mem
        m[OBJ['x'] + slot] = x
        m[OBJ['y'] + slot] = y
        m[OBJ['xf'] + slot] = xf
        m[OBJ['yf'] + slot] = yf
        m[OBJ['vx'] + slot] = 0
        m[OBJ['vy'] + slot] = 0

    def live_objects(self):
        return [self.obj(s) for s in range(16) if self.mem[OBJ['y'] + s] != 0]


def fmt(o):
    return "(&%02x.%02x,&%02x.%02x) v=(%+3d,%+3d) flags=&%02x state=&%02x spr=&%02x en=%d" % (
        o['x'], o['xf'], o['y'], o['yf'], o['vx'], o['vy'], o['flags'], o['state'], o['sprite'], o['energy'])


if __name__ == '__main__':
    import sys
    import time
    from exile6502 import load_listing
    g = Game(load_listing(sys.argv[1]))
    t0 = time.time()
    print("in the ship, no keys:")
    for i in range(12):
        g.tick()
        if i % 4 == 3:
            print("  tick %2d %s" % (g.ticks, fmt(g.player())))
    print("dropped into the sky at (&90,&40), no keys:")
    g.teleport(0x90, 0x40)
    for i in range(60):
        g.tick()
        if i % 5 == 4 or i < 3:
            print("  tick %2d %s" % (g.ticks, fmt(g.player())))
    print("%d ticks, %.1f s, %d live objects" % (g.ticks, time.time() - t0, len(g.live_objects())))
