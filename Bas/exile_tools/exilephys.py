"""exilephys.py - the player's physics from Exile, transcribed from the level7 listing.

This is update_object (&1a17) for the player, byte for byte: integration,
the extents, water and buoyancy, the tile collision scan, the push out of
an obstruction and the bounce, support and wedging, the surface wind,
update_player (actions, angle, facing, walking, jumping, jetpack, sprite,
palette) and apply_acceleration_to_velocities.  Every quantity is the
8-bit value the 6502 holds, including the carries that leak from one
routine into the next, so that the result can be checked tick by tick
against the game itself (gen_traces.py) before it is turned into BASIC.

What is not here: other objects (the traces are made with the player
alone), particles and sounds (they change nothing the player feels), and
the tile update routines other than water and wind (a warning is printed
if the player touches one).  Random numbers are not generated: the two
places the player's code looks at rnd_state are fed from the trace, so a
mismatch is a physics mismatch and never a random-number one.

    python exilephys.py exile-disassembly.txt [trace names...]

replays every trace in out/traces/ (or the named ones) and reports the
first tick at which this transcription and the game disagree.
"""
import json
import os
import sys

from exilegame import ACTIONS, OBJ, s8

DAMAGE_OBJECT = 0x24A6
CHECK_RELIABILITY = 0x2D92
REDUCE_WEAPON_ENERGY = 0x2D79

# --- 8-bit helpers -----------------------------------------------------------


def u8(v):
    return v & 0xFF


def adc(a, b, c):
    """A + B + C as the 6502 does it: (result, carry, overflow)."""
    r = a + b + c
    res = r & 0xFF
    return res, (1 if r > 0xFF else 0), (1 if (~(a ^ b) & (a ^ res) & 0x80) else 0)


def sbc(a, b, c):
    """A - B - (1 - C): (result, carry, overflow); carry clear means a borrow."""
    r = a - b - (1 - c)
    res = r & 0xFF
    return res, (0 if r < 0 else 1), (1 if ((a ^ b) & (a ^ res) & 0x80) else 0)


def neg(a):
    return (-a) & 0xFF


def negative(a):
    return bool(a & 0x80)


def inv_neg(a):
    """invert_if_negative (&3256): two's complement if bit 7 set.  Leaves carry clear."""
    return neg(a) if a & 0x80 else a


def asr(a):
    """CMP #&80 ; ROR A - halve keeping the sign; returns (result, bit shifted out)."""
    return ((a & 0x80) | (a >> 1)), a & 1


def divide_by_four(a):
    a, _ = asr(a)
    return asr(a)


def divide_by_eight(a):
    a, _ = asr(a)
    a, _ = asr(a)
    return asr(a)


def prevent_overflow(a, c, v):
    """&327f: after an ADC/SBC that overflowed, clamp to &7f or &80."""
    return u8(0x7F + c) if v else a


def seven_eighths(a):
    """&3235: lose an eighth, rounding the eighth up on the way."""
    p = inv_neg(a)
    p, _, _ = adc(p, 7, 0)
    e = p >> 3
    if negative(a):
        e = neg(e)
    r, _, _ = sbc(a, e, 1)
    return r


def keep_within_range(a, rng):
    """&325e: clamp a signed value to -rng..rng."""
    if inv_neg(a) < rng:
        return a
    return neg(rng) if negative(a) else rng


def halve_toward_zero(a):
    """CMP #&80 ; ROR A ; BPL ; ADC #&00 - used on accelerations."""
    a, c = asr(a)
    if negative(a):
        a, _, _ = adc(a, 0, c)
    return a


def every_byte(frame, n):
    """The every_N_frames bytes (&c1-&c6): negative when frame is a multiple of n,
    else a small positive count."""
    if frame % n == 0:
        return 0xFF
    return bin(frame & (n - 1)).count('1') - 1


class Unmodelled(Exception):
    pass


class Player:
    """The player's slot and the game variables its physics touches."""

    def __init__(self, mem, world):
        self.mem = mem
        self.world = world            # 65,536 bytes: tile type | flips, from gen_world.py
        m = mem
        # tables the code reads
        self.sprite_w = bytes(m[0x5E0C:0x5E0C + 125])
        self.sprite_h = bytes(m[0x5E89:0x5E89 + 125])
        self.yoff_tab = bytes(m[0x056B:0x056B + 0x40])
        self.sprflip_tab = bytes(m[0x04AB:0x04AB + 0x40])
        self.pattab = bytes(m[0x04EB:0x04EB + 0x40])
        self.lowaddr_tab = bytes(m[0x05AB:0x05AB + 0x40])
        self.routine_hi = bytes(m[0x0432:0x0432 + 0x14])
        self.half_quadrant = bytes(m[0x14BF:0x14BF + 8])
        self.water_vel = bytes(m[0x1E44:0x1E44 + 4])
        self.wl_x = bytes(m[0x14D2:0x14D2 + 4])
        self.wl = list(m[0x082E:0x0836])          # y fraction x4, y x4, per water range
        self.norepeat = [m[0x121D + i] & 1 for i in range(len(ACTIONS))]
        self.type_flags = m[0x0354]                # the player's: weight 3
        self.pal_default = m[0x02EF] & 0x7F
        self.weapon_cost = bytes(m[0x085A:0x085A + 8])
        self.booster_collected = m[0x080E]
        self.suit_collected = m[0x0813]
        self.weapons_hi = list(m[0x0854:0x0854 + 6])
        self.weapons_lo = list(m[0x084E:0x084E + 6])
        # the slot
        self.type = m[OBJ['type']]
        self.sprite = m[OBJ['sprite']]
        self.P = [m[OBJ['x']], 0, m[OBJ['y']]]        # x, -, y
        self.F = [m[OBJ['xf']], 0, m[OBJ['yf']]]      # fractions
        self.V = [m[OBJ['vx']], 0, m[OBJ['vy']]]      # velocities, two's complement bytes
        self.flags = m[OBJ['flags']]
        self.palette = m[OBJ['palette']]
        self.target_flags = m[OBJ['target']]
        self.tx = m[OBJ['tx']]
        self.ty = m[OBJ['ty']]
        self.energy = m[OBJ['energy']]
        self.touching = m[OBJ['touching']]
        self.timer = m[OBJ['timer']]
        self.tdata_off = m[OBJ['tdata']]
        self.state = m[OBJ['state']]
        # game variables (zero page is wiped at start; &de = &c0, &dd = &ff)
        self.frame = 0
        self.keys = [m[0x126B + i] for i in range(len(ACTIONS))]
        self.angle = 0xC0
        self.facing = 0
        self.immob = 0
        self.thrust_immob = 0
        self.rot_vel = 0
        self.lying = 0
        self.aim = 0
        self.aim_vel = 0
        self.aim_flip = 0
        self.jet_ok = m[0x358A]
        self.crosses = [0, 0, 0]      # &29d9 / &29db, rolling bytes
        self.in_water = 0             # &1f
        self.tbcoll = 0               # &1b
        self.surrounded = 0           # &17
        self.wedged = 0               # &19b4
        self.signs = 0                # &99
        self.wind_sign = 0            # &9d
        self.relative_tx = 0          # &d2
        self.relative_ty = 0          # &d4
        self.walking_speed = 0        # &04
        self.max_accel0 = m[0x3969]   # npc_walking_types_maximum_acceleration_table + 0
        self.npc_weight0 = m[0x3970]
        self.firing_cooldown = m[0x29D6]
        self.water_tile = 0           # &01
        self.reads = []
        self.warnings = []

    # --- driving -------------------------------------------------------------

    def teleport(self, x, y, xf=0x80, yf=0x00):
        self.P[0], self.P[2] = x, y
        self.F[0], self.F[2] = xf, yf
        self.V[0] = self.V[2] = 0

    def tick(self, keys=(), reads=None, wl=None, d4=None):
        for i, name in enumerate(ACTIONS):
            pressed = (name in keys or (name == 'JUMP' and 'P' in keys) or (name == 'P' and 'JUMP' in keys))
            self.keys[i] = (self.keys[i] >> 1) | (0x80 if pressed else 0)
        self.frame = u8(self.frame + 1)
        self.reads = list(reads or [])
        if wl:
            self.wl = list(wl)
        if d4 is not None:
            self.relative_ty = d4       # left by the last walking creature updated
        self.update_object()
        if self.reads:
            self.warn("the game reached %s this tick and the kernel did not"
                      % " ".join("&%04x" % r[0] for r in self.reads))

    def every(self, n):
        return self.frame % n == 0

    def read_rnd(self, where):
        """The byte rnd_state + 1 held when the game reached `where`, from the trace."""
        if not self.reads:
            raise Unmodelled("kernel reaches &%04x, which the game did not this tick" % where)
        addr, value = self.reads.pop(0)
        if addr != where:
            raise Unmodelled("kernel reaches &%04x, the game reached &%04x" % (where, addr))
        return value

    def warn(self, text):
        self.warnings.append("tick %d: %s" % (self.frame, text))

    def snapshot(self):
        return {
            'px': self.P[0] * 256 + self.F[0], 'py': self.P[2] * 256 + self.F[2],
            'vx': s8(self.V[0]), 'vy': s8(self.V[2]), 'flags': self.flags, 'state': self.state,
            'sprite': self.sprite, 'energy': self.energy,
            'jetpack': self.weapons_hi[0] * 256 + self.weapons_lo[0],
            'angle': self.angle, 'facing': self.facing, 'immob': self.immob,
            'thrust_immob': self.thrust_immob, 'jet_ok': self.jet_ok, 'timer': self.timer,
            'frame': self.frame, 'palette': self.palette,
        }

    # --- update_object (&1a17) -----------------------------------------------

    def update_object(self):
        self.prev_P = list(self.P)
        self.prev_F = list(self.F)
        prev_flags = self.flags
        self.xflip = self.flags
        self.yflip = u8(self.flags << 1)
        self.fc = self.frame                      # slot 0: frame counter pair
        self.fc16 = self.frame & 0x0F
        self.get_waterline_for_x(self.P[0])
        self.weight = self.type_flags & 7
        if self.weight == 7:
            raise Unmodelled("static object")
        self.S = [self.sprite_w[self.sprite] & 0xF0, 0, self.sprite_h[self.sprite] & 0xF8]
        self.A = [0, 0, 0]                        # accelerations
        self.aim_acc = 0
        self.obj_coll_y = 0
        self.obj_coll_x = 0
        self.pre_mag = 0
        self.child = 0
        self.tile_angle = 0
        self.upright = 0xFF
        self.add_velocities_to_position()
        self.calculate_maxima()
        carry = self.check_for_collisions()
        # body collision damage (player only)
        a, c, _ = sbc(self.tile_angle, self.angle, carry)
        a, c, _ = sbc(a, 0x40, c)
        a = inv_neg(a)
        a >>= 1
        c = a & 1
        a >>= 1
        a, c, _ = adc(a, 0xC0, c)
        a, c, _ = adc(a, self.pre_mag, c)
        if c:
            self.energy = self.damage_object_without_destroying(a >> 1)
        # support and wedging
        self.any_bottom = self.coll_y_flags | self.obj_coll_y
        self.coll_top = u8(self.obj_coll_y << 1) | self.coll_y_sign
        self.wedged >>= 1
        self.flags &= 0xFD
        if not negative(self.coll_top):
            if negative(self.any_bottom):
                self.flags |= 0x02
        elif prev_flags & 0x02:
            self.wedged = 0x80 | (self.wedged >> 1)
            if self.obstr[2] != self.obstr[0]:
                a = 0x10
                if negative(u8(self.obstr[2] - self.obstr[0])):
                    a = neg(a)
                self.add_A_to_position(0, a)
                self.calculate_maxima()
        if self.flags & 0x10:
            raise Unmodelled("teleporting")
        if self.P[2] < 0x4F:
            self.apply_surface_wind()
        self.update_player()
        if self.energy == 0:
            raise Unmodelled("player exploding")
        self.apply_acceleration_to_velocities()
        # write back
        flip = (self.xflip & 0x80) | ((self.yflip & 0x80) >> 1)
        self.flags = ((self.flags & 0xC0) ^ self.flags ^ flip) & 0xF3
        self.touching |= 0x80
        # update_object_sprite: bit 0 becomes "off screen", never for the viewpoint object
        self.flags &= 0xFE

    def get_waterline_for_x(self, x):
        X = 4
        while True:
            X -= 1
            if x >= self.wl_x[X]:
                break
        self.wl_yf, self.wl_y = self.wl[X], self.wl[4 + X]
        _, c, _ = sbc(self.wl_yf, self.wl[1], 0)
        _, c, _ = sbc(self.wl_y, self.wl[5], c)
        if c:
            self.wl_yf, self.wl_y = self.wl[1], self.wl[5]

    def add_A_to_position(self, X, a, n=None):
        """&2a38.  The borrow is decided by the N flag on entry, which is the sign
        of A everywhere except apply_tile_collision, where it comes from a CPY."""
        if negative(a) if n is None else n:
            self.P[X] = u8(self.P[X] - 1)
        self.F[X], c, _ = adc(a, self.F[X], 0)
        if c:
            self.P[X] = u8(self.P[X] + 1)
        return c

    def add_velocities_to_position(self):
        self.add_A_to_position(2, self.V[2])
        self.add_A_to_position(0, self.V[0])

    def calculate_maxima(self):
        """Extents; returns the carry the routine leaves (bit 0 of the old crosses_x byte)."""
        self.MF = [0, 0, 0]
        self.M = [0, 0, 0]
        out = self.crosses[0] & 1
        for X in (2, 0):
            self.MF[X], c, _ = adc(self.S[X], self.F[X], 0)
            self.M[X], _, _ = adc(self.P[X], 0, c)
            self.crosses[X] = (c << 7) | (self.crosses[X] >> 1)
        return out

    # --- collisions ----------------------------------------------------------

    def check_for_collisions(self):
        # check_for_collision_with_other_objects: nobody else is in the world
        return self.check_for_collision_with_water_and_tiles()

    def tile(self, tx, ty):
        v = self.world[(ty & 0xFF) * 256 + (tx & 0xFF)]
        return v & 0x3F, v & 0xC0

    def set_obstruction_vars(self, which):
        """set_obstruction_data_variables_for_top_tile (which=0) / bottom (which=1)."""
        t, flip = self.tile(self.tile_x, self.tile_y)
        self.tile_effect(t, flip)
        yoff = self.yoff_value(t, flip)
        h = flip >> 7
        q = u8(flip << 1)
        fl = q ^ self.sprflip_tab[t]
        a = u8((self.pattab[t] << 1) | h)
        a = u8((a << 1) | (q >> 7)) & 0x3F
        addr = self.lowaddr_tab[a]
        if which == 0:
            self.t_yoff, self.t_flip, self.t_addr = yoff, fl, addr
        else:
            self.b_yoff, self.b_flip, self.b_addr = yoff, fl, addr

    def yoff_value(self, t, flip):
        a = self.yoff_tab[t]
        if flip & 0x40:
            a = u8(a << 4)
        a &= 0xF0
        if a:
            a |= 0x0F
        return a

    def pattern(self, addr, s):
        return self.mem[0x0100 + addr + s]

    def tile_effect(self, t, flip):
        """The tile update routine, as called while checking collisions (mode &20)."""
        if t >= 0x10 or not (self.routine_hi[t] & 0x20):
            return
        if t == 0x0D:
            wv = self.water_vel[((flip >> 7) << 1) | ((flip >> 6) & 1)]
            if wv:
                self.apply_wind_velocities_from_A(wv)
            else:
                self.water_tile = 0x80 | (self.water_tile >> 1)
        else:
            self.warn("tile type &%02x at (&%02x,&%02x) has a collision routine that is not modelled"
                      % (t, self.tile_x, self.tile_y))

    def apply_wind_velocities_from_A(self, a):
        self.vector = [u8(a << 4), 0, a]
        for X in (2, 0):
            Y = self.weight
            if Y < 4:
                Y += 1
            if negative(self.waterline):
                Y += 1
            if negative(self.in_water) and not (self.frame & 0x10):
                return
            self.add_weighted_vector_component(Y, X)

    def add_weighted_vector_component(self, Y, X):
        return self.apply_weighted_acceleration(self.vector[X], Y, X, 0x0C)

    def apply_weight_and_limit(self, a, c, v, Y, maxacc):
        """&3201: scale an acceleration by 2^-Y and limit it to +/- maxacc."""
        a = prevent_overflow(a, c, v)
        n = negative(a)
        m = inv_neg(a)
        times = Y + 1 if Y < 0x80 else 1
        c = 0
        for _ in range(times):
            c = m & 1
            m >>= 1
        m = u8((m << 1) | c)
        if m >= maxacc:
            m = maxacc
        return neg(m) if n else m

    def apply_weighted_acceleration(self, desired, Y, X, maxacc):
        """&31f6: move a velocity towards `desired` by a weighted, limited amount."""
        a, c, v = sbc(desired, self.V[X], 1)
        acc = self.apply_weight_and_limit(a, c, v, Y, maxacc)
        self.V[X], c, _ = adc(acc, self.V[X], 0)
        return c

    def check_for_collision_with_water_and_tiles(self):
        self.surrounded >>= 1
        a, c, _ = sbc(self.MF[2], self.wl_yf, 1)
        X = a
        a2, c2, _ = sbc(self.M[2], self.wl_y, c)
        if a2 != 0:
            X = 0xFF if c2 else 0
        self.waterline = X
        self.tile_x, self.tile_y = self.P[0], self.P[2]
        X = 0
        self.water_tile = 0
        self.set_obstruction_vars(0)
        c = self.water_tile >> 7
        self.water_tile = u8(self.water_tile << 1)
        if c:
            X = 0xFF
        if negative(self.crosses[2]):
            self.tile_y = u8(self.tile_y + 1)
            self.set_obstruction_vars(1)
            c = self.water_tile >> 7
            self.water_tile = u8(self.water_tile << 1)
            if c:
                X |= self.MF[2]
        else:
            self.b_yoff, self.b_addr, self.b_flip = self.t_yoff, self.t_addr, self.t_flip
        if X < self.waterline:
            X = self.waterline
        tw = X
        Y = self.weight or 1
        h4 = self.S[2] >> 2
        X = 4
        a = tw
        c = 0 if a else 1
        old = self.in_water
        self.in_water = (c << 7) | (old >> 1)
        c = old & 1
        if not negative(self.in_water):
            while True:
                a, c, _ = sbc(a, h4, c)
                if not c:
                    break                     # splash particles: nothing the player feels
                Y = u8(Y - 1)
                if negative(Y):
                    self.V[2] = u8(self.V[2] - 1)
                elif Y == 0:
                    self.V[2] = u8(self.V[2] - 2)
                X -= 1
                if X == 0:
                    break
            if self.every(4):
                self.V[0] = seven_eighths(self.V[0])
                self.V[2] = seven_eighths(self.V[2])
        return self.check_for_collision_with_tiles()

    def check_top_bottom(self, Y):
        """check_for_top_and_bottom_tile_collisions (&2e8a) for the section Y of the
        current top and bottom tiles: (obstruction, carry)."""
        a2 = a3 = 0
        a, c, _ = adc(self.pattern(self.t_addr, Y), self.t_yoff, 0)
        if c:
            a = 0xFF
        a, c, _ = sbc(a, self.top_r, 1)
        if c:
            if a >= self.S[2]:
                a = self.S[2]
            a2 = a
        a = self.S[2]
        if negative(self.crosses[2]):
            a, c, _ = adc(self.pattern(self.b_addr, Y), self.b_yoff, 0)
            if c:
                a = 0xFF
            if a >= self.bot_r:
                a = self.bot_r
            a3 = a
            if not negative(self.b_flip):
                a3, _, _ = sbc(self.bot_r, a3, 1)
            a, _, _ = sbc(0, self.top_r, 1)
        if not negative(self.t_flip):
            a2, _, _ = sbc(a, a2, 1)
        a, c, _ = adc(a2, a3, 0)
        a, c, _ = adc(a, 6, c)
        a = (c << 7) | (a >> 1)
        a >>= 1
        a &= 0xFE
        a = u8((a ^ 0xFF) + 1)
        return a, (1 if a == 0 else 0)

    def check_for_collision_with_tiles(self):
        self.top_r = (self.F[2] & 0xF8) | 4
        self.bot_r = (self.MF[2] & 0xF8) | 4
        Y = self.F[0] >> 5
        left, c = self.check_top_bottom(Y)
        top = bottom = 0
        sections = self.S[0] >> 5
        while True:
            a, c, _ = sbc(self.top_r, self.t_yoff, 1)
            top_rel = a if c else 0
            a, c, _ = sbc(self.bot_r, self.b_yoff, 1)
            bot_rel = a if c else 0
            done = False
            while True:
                p = self.pattern(self.t_addr, Y)
                if ((1 if p >= top_rel else 0) ^ (self.t_flip >> 7)) == 0:
                    top = u8(top - 1)
                p = self.pattern(self.b_addr, Y)
                if ((1 if p >= bot_rel else 0) ^ (self.b_flip >> 7)) == 0:
                    bottom = u8(bottom - 1)
                sections = u8(sections - 1)
                if negative(sections):
                    done = True
                    break
                Y += 1
                if Y < 8:
                    continue
                self.tile_x = u8(self.tile_x + 1)
                self.set_obstruction_vars(1)
                if negative(self.crosses[2]):
                    self.tile_y = u8(self.tile_y - 1)
                    self.set_obstruction_vars(0)
                else:
                    self.t_yoff, self.t_addr, self.t_flip = self.b_yoff, self.b_addr, self.b_flip
                Y = 0
                break
            if done:
                break
        bottom = u8(bottom << 3)
        top = u8(top << 3)
        a, _, _ = sbc(top, bottom, 1)
        self.vector = [a, 0, 0]
        self.coll_y_sign = a
        self.coll_y_flags = u8((a ^ 0xFF) + 1)
        c = 1 if (bottom | top) >= 1 else 0
        self.tbcoll = (c << 7) | (self.tbcoll >> 1)
        right, c = self.check_top_bottom(Y)
        a, c, _ = sbc(right, left, 1)
        self.vector[2] = a
        self.obstr = [left, top, right, bottom]
        if (a | self.vector[0]) != 0:
            return self.apply_tile_collision()
        if (left | top) == 0:
            return c
        return self.halve_velocities_and_clear()

    def halve_velocities_and_clear(self):
        self.P = list(self.prev_P)
        self.F = list(self.prev_F)
        self.V[0], _ = asr(self.V[0])
        self.V[2], _ = asr(self.V[2])
        c = self.calculate_maxima()
        self.coll_y_flags = self.coll_y_sign = self.surrounded = 0xFF
        self.obstr = [0, 0, 0, 0]
        return c

    def calculate_angle_from_vector(self):
        """&22d4: the angle of self.vector, 0-255; sets self.mag to the larger component."""
        def absc(v):
            c = 1 if v <= 0x7F else 0
            a = v if c else u8((v ^ 0xFF) + 1)
            self.signs = u8((self.signs << 1) | c)
            return a
        ay = absc(self.vector[2])
        ax = absc(self.vector[0])
        mag, a = ay, ax
        c = 1 if a >= mag else 0
        if c:
            a, mag = mag, a
        self.signs = u8((self.signs << 1) | c)
        ang = 8
        while True:
            a = u8(a << 1)
            if a >= mag:
                a, _, _ = sbc(a, mag, 1)
                c = 1
            else:
                c = 0
            ang = (ang << 1) | c
            if ang & 0x100:
                ang &= 0xFF
                break
        self.mag = mag
        return ang ^ self.half_quadrant[self.signs & 7]

    def calculate_vector_from_magnitude_and_angle(self, mag, ang):
        """&2357: (vector_y, vector_x, carry)."""
        bx = mag
        q = ang
        a = 0
        for _ in range(5):
            bit = q & 1
            q >>= 1
            c = 0
            if bit:
                a, c, _ = adc(a, bx, 0)
            a = (c << 7) | (a >> 1)
        bit = q & 1
        q >>= 1
        if bit:
            y = bx
            bx = a
            bx, _, _ = sbc(y, bx, 1)
            a = y
        bit = q & 1
        q >>= 1
        if bit:
            y = u8((a ^ 0xFF) + 1)
            a = bx
            bx = y
        bit = q & 1
        c = 0
        if bit:
            y = u8((a ^ 0xFF) + 1)
            bx, c, _ = sbc(0, bx, 1)
            a = y
        self.vector = [bx, 0, a]
        return a, bx, c

    def apply_tile_collision(self):
        self.tile_angle = self.calculate_angle_from_vector()
        a, _, _ = sbc(self.tile_angle, 0x60, 1)
        Y = (a & 0xC0) >> 6
        X = Y ^ 2
        a = self.obstr[Y]
        if a < self.obstr[X]:
            a = self.obstr[X]
        if a == 0:
            a = 0xFE
        a = u8(a << 2)
        Y = u8(Y - 1)
        X = (Y & 1) << 1
        if X == 0:
            a, c, _ = adc(a, 0x0F, 1)
            if c:
                a = 0xFE
        # CPY #2 ; BCC ; INY ; PHP: the flag that decides the direction and the
        # borrow is N after the INY for top and left, after the CPY for right and bottom
        n = True if Y < 2 else negative(u8(Y + 1))
        if not n:
            a = neg(a)
        self.add_A_to_position(X, a, n)
        self.calculate_maxima()
        self.vector = [self.V[0], 0, self.V[2]]
        self.pre_angle = self.calculate_angle_from_vector()
        self.pre_mag = self.mag
        a, c, _ = sbc(self.pre_angle, self.tile_angle, 1)
        angle = a
        if not negative(a):
            a, _, _ = sbc(a, 0x3F, 1)
            a, c = divide_by_eight(a)
            a, _, _ = adc(a, angle, c)
            a ^= 0xFF
            angle, _, _ = adc(a, self.tile_angle, 1)
            a = self.pre_mag
            c = 1 if a >= 0x20 else 0
            if c:
                a = 0x20
            a, c, _ = sbc(a, 2, c)
            if not c:
                a = 0
            a = seven_eighths(a)
            vy, vx, c = self.calculate_vector_from_magnitude_and_angle(a, angle)
            self.V[2], self.V[0] = vy, vx
            return c
        a, _, _ = sbc(a, 0xC0, c)
        a = inv_neg(a)
        if a >= 0x2A:
            return 1
        if self.pre_mag < 0x40:
            return 0
        return self.halve_velocities_and_clear()

    # --- damage ----------------------------------------------------------------

    def damage_object_without_destroying(self, dmg):
        da = self.read_rnd(DAMAGE_OBJECT)
        if not negative(da):
            self.lying >>= 1
            if dmg >= self.immob:
                self.immob = dmg
        if negative(self.suit_collected):
            raise Unmodelled("protection suit")
        for _ in range(3):
            c = dmg >> 7
            dmg = u8(dmg << 1)
            if c:
                dmg = (dmg >> 1) | 0x80
        old = self.energy
        a, c, _ = sbc(old, dmg, 1)
        if not c:
            a = 0
        if a == 0 and old != 0:
            a = 1
        return a

    # --- the surface wind --------------------------------------------------------

    def apply_surface_wind(self):
        self.vector = [0, 0, 0]
        a, c, _ = sbc(self.P[2], 0x4E, 0)
        X = 2
        while True:
            Y = u8(self.weight + 1)
            self.wind_sign = (c << 7) | (self.wind_sign >> 1)
            a = inv_neg(a)
            if a < 0x1E:
                c = 0
            else:
                if a < 0x32:
                    c = 0
                else:
                    Y = u8(Y - 1)
                    if a < 0x3C:
                        c = 0
                    else:
                        Y = u8(Y - 1)
                        c = 1
                a, c, _ = sbc(a, 8, c)
                a = u8(a << 1)
                if negative(a):
                    Y = u8(Y - 2)
                    a = 0x7F
                Y = u8(Y + 1)
                if negative(Y):
                    Y = 0
                if negative(self.wind_sign):
                    a = neg(a)
                self.vector[X] = a
                c = self.add_weighted_vector_component(Y, X)
            a, c, _ = sbc(self.P[0], 0x9B, c)
            X -= 2
            if X != 0:
                break

    # --- update_player (&4a11) -----------------------------------------------------

    def jumping(self):
        return (self.state & 0x0F) >= 0x0A

    def update_player(self):
        if not negative(self.touching):
            raise Unmodelled("touching another object")
        self.process_actions()
        if not (self.flags & 0x10):
            self.update_player_angle_facing_and_sprite()
        self.update_player_aiming_angle()
        self.firing_cooldown = u8(self.firing_cooldown - 1)
        if self.firing_cooldown == 0:
            self.keys[13] >>= 1

    def process_actions(self):
        for i in range(0x26, -1, -1):
            k = self.keys[i]
            if not negative(k):
                continue
            if (k & 0xC0) == 0xC0 and self.norepeat[i]:
                continue
            self.action(ACTIONS[i])

    def action(self, name):
        if name == 'W':
            self.A[0] = u8(self.A[0] + 1)
        elif name == 'Q':
            self.A[0] = u8(self.A[0] - 1)
        elif name == 'L':
            self.A[2] = u8(self.A[2] + 1)
        elif name == 'P':
            self.A[2] = u8(self.A[2] - 1)
            if negative(self.jet_ok):
                self.state |= 0x0F
        elif name == 'JUMP':
            self.handle_jumping()
        elif name == '@':
            self.handle_using_booster()
        elif name == 'CTRL':
            self.state |= 0x0F
        elif name == 'TAB':
            self.facing ^= 0x80
        elif name == 'I':
            self.aim = self.aim_vel = 0
            self.aim_acc = u8(self.aim_acc - 1)
        elif name == 'O':
            self.aim_acc = u8(self.aim_acc - 1)
        elif name == 'K':
            self.aim_acc = u8(self.aim_acc + 1)
        else:
            raise Unmodelled("action %s" % name)

    def handle_jumping(self):
        if (self.state & 0x0F) >= 5:
            return
        a = 0xF0 if negative(self.keys[0x15]) else 0xF6
        a, _, _ = adc(a, self.weight, 0)
        c = a >> 7
        a = u8(a << 1)
        self.V[2], _, _ = adc(a, self.V[2], c)
        self.upright >>= 1

    def handle_using_booster(self):
        if not negative(self.jet_ok & self.booster_collected):
            return
        if not negative(self.A[2]) and self.A[0] != 0:
            self.state |= 0x0F
        self.A[0] = u8(self.A[0] << 1)
        self.A[2] = u8(self.A[2] << 1)

    def check_reliability(self, X):
        da = self.read_rnd(CHECK_RELIABILITY)     # the game is stopped at the entry, read or not
        hi = self.weapons_hi[X]
        if hi >= 4:
            return 1
        c = 1 if X == 0 else 0
        a = hi
        for _ in range(3):
            nc = a & 1
            a = (c << 7) | (a >> 1)
            c = nc
        return 1 if a >= da else 0

    def reduce_energy_of_weapon(self, X):
        # the carry on entry is whatever add_particle left: clear when the thrust
        # particle was added (so the drain is cost + 1), set when it was off screen
        # or the list was full.  The port drains two, the common case.
        c = self.read_rnd(REDUCE_WEAPON_ENERGY)
        lo, c, _ = sbc(self.weapons_lo[X], self.weapon_cost[X], c)
        hi, c2, _ = sbc(self.weapons_hi[X], 0, c)
        if not c2:
            hi = 0
            lo = 0
        self.weapons_lo[X], self.weapons_hi[X] = lo, hi

    def update_player_angle_facing_and_sprite(self):
        self.A[0] = u8(self.A[0] << 1)
        c = self.A[2] >> 7
        self.A[2] = u8(self.A[2] << 1)
        if self.every(16):
            a, c2, _ = adc(self.energy, 4, c)
            if not c2:
                self.energy = a
            c = self.check_reliability(0)
            old = self.jet_ok
            self.jet_ok = (c << 7) | (old >> 1)
            c = old & 1
        a, c2, _ = sbc(0x10, self.energy, c)
        if c2:
            self.immob = a
        if self.immob >= 6:
            self.jet_ok >>= 1
        if self.thrust_immob:
            self.thrust_immob = u8(self.thrust_immob - 1)
            self.jet_ok >>= 1
        self.lying >>= 1
        a, _, _ = sbc(self.angle, 0xCF, 1)
        c = 1 if a >= 0xE1 else 0
        self.upright = ((c << 7) | (a >> 1)) & self.upright
        ax, ay = self.A[0], self.A[2]
        drain = True
        if ay == 0:
            if ax == 0:
                self.lying = self.surrounded | self.wedged | self.keys[0x16]
            if self.jumping():
                if negative(self.any_bottom):
                    for _ in range(3):
                        self.V[2] = seven_eighths(self.V[2])
            else:
                drain = False
        if drain and negative(self.jet_ok) and (self.A[0] | self.A[2]) != 0:
            e8 = every_byte(self.frame, 8)
            e2 = every_byte(self.frame, 2)
            if negative((e8 | self.keys[0x15]) & e2):
                self.reduce_energy_of_weapon(0)
        if self.immob:
            self.update_rotating_player()
        else:
            self.update_player_angle_and_player_facing()
        self.consider_updating_walking_player()
        if not negative(self.jet_ok):
            self.A[2] = 0
            if self.jumping():
                self.A[0] = 0
        self.set_spacesuit_sprite_and_palette(self.angle, self.facing)

    def update_rotating_player(self):
        self.immob = u8(self.immob - 1)
        a2 = u8(self.angle << 1)
        hit = False
        if negative(self.tbcoll):
            a = self.pre_angle
            hit = True
        elif negative(self.touching):
            a = self.rot_vel
        else:
            a = 0x40
            hit = True
        if hit:
            a = u8(a << 1)
            a, c, _ = sbc(a, a2, 1)
            a = (c << 7) | (a >> 1)
            n = negative(a)
            a = (self.pre_mag >> 2) | 1
            if n:
                a = neg(a)
            a, _, _ = adc(a, self.rot_vel, 0)
            a = keep_within_range(a, 0x20)
        if self.every(4) and 4 <= a < 0xFD:
            a = seven_eighths(a)
        self.rot_vel = a
        self.angle = u8(self.angle + a)

    def update_player_angle_and_player_facing(self):
        self.vector = [self.A[0], 0, self.A[2]]
        X = ((1 if self.A[2] else 0) << 1) | (1 if self.A[0] else 0)
        c = 0
        if X and negative(self.jet_ok):
            a = self.calculate_angle_from_vector()
            c = 1
        else:
            a = 0xC0
            if negative(self.lying):
                a = 0x83 if negative(self.facing) else 0xFD
        a, _, _ = sbc(a, self.angle, c)
        Y = a
        only_vertical_kept = False
        if X == 2:
            a, _, _ = sbc(a, 0x74, 1)
            if a < 0x18:
                Y = 0
                X = 0
                only_vertical_kept = True
        if not only_vertical_kept:
            if self.A[0] == 0 or not negative(self.upright):
                X = 0
        c = 1 if self.jumping() else 0
        a = Y
        if not c and not negative(self.lying):
            a = 0
        a, c = divide_by_four(a)
        self.angle, _, _ = adc(a, self.angle, c)
        a = self.angle ^ self.A[0] ^ 0x80
        if not negative(u8(X - 1)):
            self.facing = a

    def consider_updating_walking_player(self):
        self.walking_speed = 0x1F
        c = 1 if self.fc16 >= 2 else 0
        Y, c, _ = sbc(self.weight, 5, c)
        if c:
            if self.jumping() and not negative(self.any_bottom):
                while True:
                    for X in (2, 0):
                        self.A[X] = halve_toward_zero(self.A[X])
                    Y = u8(Y - 1)
                    if negative(Y):
                        break
                self.update_walking_npc_or_player()
                return
        a = 0x0F
        Y = u8(Y + 1)
        while True:
            c = a & 1
            a >>= 1
            Y = u8(Y - 1)
            if negative(Y):
                break
        a, _, _ = adc(a, 1, c)
        self.relative_tx = self.A[0]
        if self.A[0] == 0:
            self.walking_speed = 0
            a = 1
        self.max_accel0 = a
        if not self.jumping():
            self.A[0] = 0
        self.update_walking_npc_or_player()

    def update_walking_state(self):
        if not negative(self.upright):
            self.state |= 0x0F
            return self.state
        c = 1
        if negative(self.tbcoll | self.obj_coll_y):
            c = 1 if inv_neg(self.tile_angle) >= 0x32 else 0
        a = self.state & 0xF0
        if not c:
            self.state = a
            return self.state
        if (a ^ self.state) < 0x0F:
            self.state = u8(self.state + 1)
        return self.state

    def update_walking_npc_or_player(self):
        a = self.update_walking_state()
        if a & 0x0F:
            return
        maxacc = self.max_accel0
        Y = self.npc_weight0
        a = inv_neg(self.tile_angle)
        c = 1 if a >= 0x32 else 0
        a, _, _ = sbc(a, 0x2C, c)
        c = 1 if a >= 0x28 else 0
        speed = self.walking_speed
        if not c:
            self.climb_steep_slope(speed, Y, maxacc)
        else:
            self.walk_along(speed, Y, maxacc)

    def walk_along(self, speed, Y, maxacc):
        a = neg(speed) if negative(self.relative_tx) else speed
        a, c, v = sbc(a, self.V[0], 1)
        acc = self.apply_weight_and_limit(a, c, v, Y, maxacc)
        a = (acc & 0x80) ^ self.tile_angle
        a, _, _ = adc(a, 0x40, 0)
        c = a >> 7
        if self.relative_tx == 0:
            acc = 0
        if not c:
            angle, _, _ = adc(0x10, self.tile_angle, 0)
        else:
            angle, _, _ = adc(0x6F, self.tile_angle, 1)
        vy, vx, _ = self.calculate_vector_from_magnitude_and_angle(inv_neg(acc), angle)
        self.A[2], self.A[0] = vy, vx
        self.V[2] = seven_eighths(self.V[2])
        self.V[2] = seven_eighths(self.V[2])

    def climb_steep_slope(self, speed, Y, maxacc):
        a = neg(speed) if negative(self.relative_ty) else speed
        self.apply_weighted_acceleration(a, Y, 2, maxacc)
        self.A[0] = 8 if negative(self.tile_angle) else neg(8)
        for _ in range(3):
            self.V[0] = seven_eighths(self.V[0])

    def set_spacesuit_sprite_and_palette(self, a, y):
        if not negative(self.child):
            self.xflip_param = y
            self.set_spacesuit_sprite_from_angle(a)
        flash = u8((self.fc & 0x1F) << 1) >= self.energy
        pal = self.pal_default
        c = self.check_reliability(5)
        a = ((c << 7) | (pal >> 1)) & self.suit_collected
        pal = 0x33 if negative(a) else 0x3E
        if flash:
            pal = self.palette ^ 0x0B
        self.palette = pal

    def set_spacesuit_sprite_from_angle(self, a):
        c = 0
        for _ in range(5):
            c = a & 1
            a >>= 1
        a, _, _ = adc(a, 0, c)
        if not negative(self.xflip_param):
            a ^= 7
            a, _, _ = adc(a, 1, 0)
        h = a
        c = 1 if (a & 4) == 4 else 0
        self.xflip = (c << 7) | ((a & 4) >> 1)
        self.yflip = self.xflip ^ self.xflip_param
        a = h & 3
        if a != 2:
            return self.change_sprite(a)
        if (inv_neg(self.V[0]) >> 1) == 0:
            return self.change_sprite(4)
        if self.jumping():
            return self.change_sprite(2)
        a = self.update_sprite_offset(8)
        stage = a >> 1
        if (self.V[0] ^ self.xflip) & 0x80:
            stage ^= 3
        return self.change_sprite(u8(stage + 4))

    def update_sprite_offset(self, modulus):
        a = max(inv_neg(self.V[0]), inv_neg(self.V[2]))
        a >>= 4
        a, _, _ = adc(a, self.timer, 1)
        c = 1
        while True:
            a, c, _ = sbc(a, modulus, c)
            if not c:
                break
        a, _, _ = adc(a, modulus, c)
        self.timer = a
        return a

    def change_sprite(self, a):
        if a == self.sprite:
            return
        self.sprite = a
        d, c, _ = sbc(self.S[2], self.sprite_h[a], 1)
        self.add_A_to_position(2, ((c << 7) | (d >> 1)) ^ 0x80)
        d, c, _ = sbc(self.S[0], self.sprite_w[a], 1)
        self.add_A_to_position(0, ((c << 7) | (d >> 1)) ^ 0x80)

    def update_player_aiming_angle(self):
        a = self.aim_acc
        if a:
            a, _, _ = adc(a, self.aim_vel, 0)
            a = keep_within_range(a, 0x10)
        self.aim_vel = a
        a, _, _ = adc(a, self.aim, 0)
        a = keep_within_range(a, 0x3F)
        self.aim = a
        if negative(self.xflip):
            a = u8((a ^ 0x7F) + 1)
        self.aim_flip = a

    # --- apply_acceleration_to_velocities (&1f01) ---------------------------------------

    def apply_acceleration_to_velocities(self):
        for X in (2, 0):
            c = 1 if X == 2 else 0
            a = self.A[X]
            n = negative(a)
            a, c, v = adc(a, self.V[X], c)
            a = prevent_overflow(a, c, v)
            Y = a
            if n:
                a = neg(a)
            a, _, _ = sbc(a, 0x3F, 0)
            if a < 0x40:
                # LDY old: a velocity already at the limit stays; below it, it lands on the limit
                old = self.V[X]
                Y = old
                if inv_neg(old) < 0x40:
                    Y = neg(0x40) if negative(old) else 0x40
            if self.every(16) and Y != 0:
                Y = u8(Y + 1) if negative(Y) else u8(Y - 1)
            self.V[X] = Y


# --- checking against the traces -------------------------------------------------------

COMPARE = ['px', 'py', 'vx', 'vy', 'flags', 'state', 'sprite', 'energy', 'jetpack',
           'angle', 'facing', 'immob', 'thrust_immob', 'jet_ok', 'timer', 'frame', 'palette']


def fmt_row(d):
    return "(&%02x.%02x,&%02x.%02x) v=(%+d,%+d) fl=%02x st=%02x sp=%02x en=%3d jet=%5d ang=%02x fc=%02x im=%02x/%02x ok=%02x tm=%02x pal=%02x" % (
        d['px'] >> 8, d['px'] & 255, d['py'] >> 8, d['py'] & 255, d['vx'], d['vy'], d['flags'], d['state'],
        d['sprite'], d['energy'], d['jetpack'], d['angle'], d['facing'], d['immob'], d['thrust_immob'],
        d['jet_ok'], d['timer'], d['palette'])


def replay(mem, world, trace, verbose=False):
    """Run the transcription through a trace; returns (ticks matched, first divergence or None)."""
    p = Player(mem, world)
    if trace['start']:
        p.teleport(*trace['start'])
    fields = trace['fields']
    idx = {f: i for i, f in enumerate(fields)}
    previous = None
    for n, (keys, row) in enumerate(zip(trace['keys'], trace['ticks'])):
        oracle = {f: row[idx[f]] for f in COMPARE}
        oracle['flags'] &= 0xFE
        try:
            p.tick(set(keys), reads=row[idx['reads']], wl=row[idx['wl']],
                   d4=row[idx['d4']] if 'd4' in idx else None)
        except Unmodelled as e:
            return n, "tick %d: %s" % (n + 1, e), p.warnings
        mine = p.snapshot()
        mine['flags'] &= 0xFE
        bad = [f for f in COMPARE if mine[f] != oracle[f]]
        if verbose:
            print("  %4d %-12s %s" % (n + 1, "+".join(keys), fmt_row(mine)), "" if not bad else "  <-- " + " ".join(bad))
        if bad:
            lines = ["tick %d keys %s: %s differ" % (n + 1, "+".join(keys) or "-", ", ".join(bad))]
            if previous:
                lines.append("  before  %s" % fmt_row(previous))
            lines.append("  kernel  %s" % fmt_row(mine))
            lines.append("  game    %s" % fmt_row(oracle))
            return n, "\n".join(lines), p.warnings
        previous = mine
    return len(trace['ticks']), None, p.warnings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    verbose = '-v' in sys.argv
    if not args:
        print(__doc__)
        return 2
    from exile6502 import load_listing
    here = os.path.dirname(os.path.abspath(__file__))
    mem = load_listing(args[0])
    world = open(os.path.join(here, 'out', 'world_types.bin'), 'rb').read()
    tdir = os.path.join(here, 'out', 'traces')
    names = args[1:] or sorted(f[:-5] for f in os.listdir(tdir) if f.endswith('.json'))
    failed = 0
    for name in names:
        trace = json.load(open(os.path.join(tdir, name + '.json')))
        matched, problem, warnings = replay(mem, world, trace, verbose)
        total = len(trace['ticks'])
        if problem is None:
            print("%-22s %4d/%-4d ticks match" % (name, matched, total))
        else:
            failed += 1
            print("%-22s %4d/%-4d ticks match, then:\n%s" % (name, matched, total, problem))
        for w in warnings[:5]:
            print("    note: " + w)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
