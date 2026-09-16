"""exile6502.py - run routines out of the level7 Exile listing on a small 6502.

The level7 disassembly prints the machine-code bytes of every instruction
and every table at its run-time address, so the listing can be loaded back
into a 64 KB image and the game's own routines executed: the landscape
generator, the tertiary-object lookup, the palette logic, the sound
envelopes, the angle tables.  Running the real code is exact by
construction, self-modifying code included, which is why the generators
here do it instead of transcribing the algorithms.

    mem = load_listing("exile-disassembly.txt")
    cpu = CPU(mem)
    mem[0x95], mem[0x97], mem[0x2d] = x, y, 0
    cpu.run(0x2398)                # get_tile_and_set_sprite_variables
    tile, flip = mem[0x08], mem[0x09]

Only the documented NMOS instruction set is implemented; decimal mode is
not (the game never sets it).  BRK and undefined opcodes raise.
"""
import re

LISTING_LINE = re.compile(r'^&([0-9a-f]{4}) ((?:[0-9a-f]{2} )*[0-9a-f]{2})(?=\s|$)')


def load_listing(path, limit=0x8000):
    """Return a 64 KB bytearray holding every byte the listing prints below 'limit'."""
    mem = bytearray(65536)
    n = 0
    expected = -1
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = LISTING_LINE.match(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            if addr >= limit:
                continue
            data = [int(b, 16) for b in m.group(2).split()]
            # The listing is in address order; a line that steps back inside
            # the previous line is a typo in its address (there is one, at
            # &4b91 for &4b9a) and belongs where the previous line ended.
            if 0 <= expected - addr <= 16 and addr != expected:
                addr = expected
            for i, b in enumerate(data):
                mem[addr + i] = b
                n += 1
            expected = addr + len(data)
    if n < 20000:
        raise ValueError("%s does not look like the level7 Exile listing (%d bytes)" % (path, n))
    # The second sound of a scream is printed as JSR &14fa (20 fa 14) at &249e;
    # the comment says play_sound, which is &13fa, and &14fa is the middle of
    # the save-game encryption, which ends by wiping memory.  A typo in the hex.
    if mem[0x249E:0x24A1] == bytearray([0x20, 0xFA, 0x14]):
        mem[0x24A0] = 0x13
    return mem


class Halt(Exception):
    pass


class CPU:
    SENTINEL = 0xFFFF   # RTS to here ends run()

    ring = None      # set to a collections.deque(maxlen=n) to keep the last n program counters

    def __init__(self, mem):
        self.mem = mem
        self.a = self.x = self.y = 0
        self.sp = 0xFF
        self.pc = 0
        self.cover = None          # set to a bytearray(65536) to record what was executed
        self.c = self.z = self.n = self.v = 0
        self.i = self.d = 0
        self.steps = 0

    # ---- flags
    def _nz(self, v):
        self.z = 1 if (v & 0xFF) == 0 else 0
        self.n = 1 if v & 0x80 else 0
        return v & 0xFF

    def status(self):
        return (self.n << 7) | (self.v << 6) | 0x20 | (self.d << 3) | (self.i << 2) | (self.z << 1) | self.c

    def set_status(self, p):
        self.n = (p >> 7) & 1
        self.v = (p >> 6) & 1
        self.d = (p >> 3) & 1
        self.i = (p >> 2) & 1
        self.z = (p >> 1) & 1
        self.c = p & 1

    # ---- stack
    def push(self, v):
        self.mem[0x100 + self.sp] = v & 0xFF
        self.sp = (self.sp - 1) & 0xFF

    def pop(self):
        self.sp = (self.sp + 1) & 0xFF
        return self.mem[0x100 + self.sp]

    # ---- operand fetch: each returns an effective address
    def _imm(self):
        a = self.pc
        self.pc += 1
        return a

    def _zp(self):
        a = self.mem[self.pc]
        self.pc += 1
        return a

    def _zpx(self):
        a = (self.mem[self.pc] + self.x) & 0xFF
        self.pc += 1
        return a

    def _zpy(self):
        a = (self.mem[self.pc] + self.y) & 0xFF
        self.pc += 1
        return a

    def _abs(self):
        a = self.mem[self.pc] | (self.mem[self.pc + 1] << 8)
        self.pc += 2
        return a

    def _abx(self):
        return (self._abs() + self.x) & 0xFFFF

    def _aby(self):
        return (self._abs() + self.y) & 0xFFFF

    def _inx(self):
        z = (self.mem[self.pc] + self.x) & 0xFF
        self.pc += 1
        return self.mem[z] | (self.mem[(z + 1) & 0xFF] << 8)

    def _iny(self):
        z = self.mem[self.pc]
        self.pc += 1
        return ((self.mem[z] | (self.mem[(z + 1) & 0xFF] << 8)) + self.y) & 0xFFFF

    # ---- arithmetic
    def _adc(self, v):
        r = self.a + v + self.c
        self.v = 1 if (~(self.a ^ v) & (self.a ^ r) & 0x80) else 0
        self.c = 1 if r > 0xFF else 0
        self.a = self._nz(r)

    def _sbc(self, v):
        r = self.a - v - (1 - self.c)
        self.v = 1 if ((self.a ^ v) & (self.a ^ r) & 0x80) else 0
        self.c = 0 if r < 0 else 1
        self.a = self._nz(r & 0xFF)

    def _cmp(self, reg, v):
        r = reg - v
        self.c = 0 if r < 0 else 1
        self._nz(r & 0xFF)

    def _branch(self, cond):
        off = self.mem[self.pc]
        self.pc += 1
        if cond:
            self.pc = (self.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF

    # ---- read-modify-write helpers on memory
    def _asl_m(self, a):
        v = self.mem[a]
        self.c = v >> 7
        self.mem[a] = self._nz(v << 1)

    def _lsr_m(self, a):
        v = self.mem[a]
        self.c = v & 1
        self.mem[a] = self._nz(v >> 1)

    def _rol_m(self, a):
        v = self.mem[a]
        r = (v << 1) | self.c
        self.c = v >> 7
        self.mem[a] = self._nz(r)

    def _ror_m(self, a):
        v = self.mem[a]
        r = (v >> 1) | (self.c << 7)
        self.c = v & 1
        self.mem[a] = self._nz(r)

    def run(self, pc, max_steps=2_000_000):
        """Call the routine at pc as a subroutine and return when it returns."""
        self.push((self.SENTINEL - 1) >> 8)
        self.push((self.SENTINEL - 1) & 0xFF)
        return self.run_until(pc, self.SENTINEL, max_steps)

    def run_until(self, pc, stop, max_steps=2_000_000):
        """Execute from pc until the program counter next reaches stop
        (an address, or a set of addresses: self.pc then says which)."""
        m = self.mem
        self.pc = pc
        steps = 0
        first = True
        stops = stop if isinstance(stop, (set, frozenset)) else {stop}
        ring = self.ring
        while True:
            if self.pc in stops and not first:
                self.steps += steps
                return
            first = False
            steps += 1
            if ring is not None:
                ring.append(self.pc)
            if self.cover is not None:
                self.cover[self.pc] = 1
            if steps > max_steps:
                raise Halt("runaway at &%04x" % self.pc)
            op = m[self.pc]
            self.pc += 1
            # --- loads and stores
            if op == 0xA9: self.a = self._nz(m[self._imm()])
            elif op == 0xA5: self.a = self._nz(m[self._zp()])
            elif op == 0xB5: self.a = self._nz(m[self._zpx()])
            elif op == 0xAD: self.a = self._nz(m[self._abs()])
            elif op == 0xBD: self.a = self._nz(m[self._abx()])
            elif op == 0xB9: self.a = self._nz(m[self._aby()])
            elif op == 0xA1: self.a = self._nz(m[self._inx()])
            elif op == 0xB1: self.a = self._nz(m[self._iny()])
            elif op == 0xA2: self.x = self._nz(m[self._imm()])
            elif op == 0xA6: self.x = self._nz(m[self._zp()])
            elif op == 0xB6: self.x = self._nz(m[self._zpy()])
            elif op == 0xAE: self.x = self._nz(m[self._abs()])
            elif op == 0xBE: self.x = self._nz(m[self._aby()])
            elif op == 0xA0: self.y = self._nz(m[self._imm()])
            elif op == 0xA4: self.y = self._nz(m[self._zp()])
            elif op == 0xB4: self.y = self._nz(m[self._zpx()])
            elif op == 0xAC: self.y = self._nz(m[self._abs()])
            elif op == 0xBC: self.y = self._nz(m[self._abx()])
            elif op == 0x85: m[self._zp()] = self.a
            elif op == 0x95: m[self._zpx()] = self.a
            elif op == 0x8D: m[self._abs()] = self.a
            elif op == 0x9D: m[self._abx()] = self.a
            elif op == 0x99: m[self._aby()] = self.a
            elif op == 0x81: m[self._inx()] = self.a
            elif op == 0x91: m[self._iny()] = self.a
            elif op == 0x86: m[self._zp()] = self.x
            elif op == 0x96: m[self._zpy()] = self.x
            elif op == 0x8E: m[self._abs()] = self.x
            elif op == 0x84: m[self._zp()] = self.y
            elif op == 0x94: m[self._zpx()] = self.y
            elif op == 0x8C: m[self._abs()] = self.y
            # --- transfers
            elif op == 0xAA: self.x = self._nz(self.a)
            elif op == 0x8A: self.a = self._nz(self.x)
            elif op == 0xA8: self.y = self._nz(self.a)
            elif op == 0x98: self.a = self._nz(self.y)
            elif op == 0xBA: self.x = self._nz(self.sp)
            elif op == 0x9A: self.sp = self.x
            # --- stack
            elif op == 0x48: self.push(self.a)
            elif op == 0x68: self.a = self._nz(self.pop())
            elif op == 0x08: self.push(self.status() | 0x10)
            elif op == 0x28: self.set_status(self.pop())
            # --- arithmetic
            elif op == 0x69: self._adc(m[self._imm()])
            elif op == 0x65: self._adc(m[self._zp()])
            elif op == 0x75: self._adc(m[self._zpx()])
            elif op == 0x6D: self._adc(m[self._abs()])
            elif op == 0x7D: self._adc(m[self._abx()])
            elif op == 0x79: self._adc(m[self._aby()])
            elif op == 0x61: self._adc(m[self._inx()])
            elif op == 0x71: self._adc(m[self._iny()])
            elif op == 0xE9: self._sbc(m[self._imm()])
            elif op == 0xE5: self._sbc(m[self._zp()])
            elif op == 0xF5: self._sbc(m[self._zpx()])
            elif op == 0xED: self._sbc(m[self._abs()])
            elif op == 0xFD: self._sbc(m[self._abx()])
            elif op == 0xF9: self._sbc(m[self._aby()])
            elif op == 0xE1: self._sbc(m[self._inx()])
            elif op == 0xF1: self._sbc(m[self._iny()])
            # --- logic
            elif op == 0x29: self.a = self._nz(self.a & m[self._imm()])
            elif op == 0x25: self.a = self._nz(self.a & m[self._zp()])
            elif op == 0x35: self.a = self._nz(self.a & m[self._zpx()])
            elif op == 0x2D: self.a = self._nz(self.a & m[self._abs()])
            elif op == 0x3D: self.a = self._nz(self.a & m[self._abx()])
            elif op == 0x39: self.a = self._nz(self.a & m[self._aby()])
            elif op == 0x21: self.a = self._nz(self.a & m[self._inx()])
            elif op == 0x31: self.a = self._nz(self.a & m[self._iny()])
            elif op == 0x09: self.a = self._nz(self.a | m[self._imm()])
            elif op == 0x05: self.a = self._nz(self.a | m[self._zp()])
            elif op == 0x15: self.a = self._nz(self.a | m[self._zpx()])
            elif op == 0x0D: self.a = self._nz(self.a | m[self._abs()])
            elif op == 0x1D: self.a = self._nz(self.a | m[self._abx()])
            elif op == 0x19: self.a = self._nz(self.a | m[self._aby()])
            elif op == 0x01: self.a = self._nz(self.a | m[self._inx()])
            elif op == 0x11: self.a = self._nz(self.a | m[self._iny()])
            elif op == 0x49: self.a = self._nz(self.a ^ m[self._imm()])
            elif op == 0x45: self.a = self._nz(self.a ^ m[self._zp()])
            elif op == 0x55: self.a = self._nz(self.a ^ m[self._zpx()])
            elif op == 0x4D: self.a = self._nz(self.a ^ m[self._abs()])
            elif op == 0x5D: self.a = self._nz(self.a ^ m[self._abx()])
            elif op == 0x59: self.a = self._nz(self.a ^ m[self._aby()])
            elif op == 0x41: self.a = self._nz(self.a ^ m[self._inx()])
            elif op == 0x51: self.a = self._nz(self.a ^ m[self._iny()])
            elif op == 0x24 or op == 0x2C:
                v = m[self._zp() if op == 0x24 else self._abs()]
                self.z = 1 if (self.a & v) == 0 else 0
                self.n = v >> 7
                self.v = (v >> 6) & 1
            # --- compares
            elif op == 0xC9: self._cmp(self.a, m[self._imm()])
            elif op == 0xC5: self._cmp(self.a, m[self._zp()])
            elif op == 0xD5: self._cmp(self.a, m[self._zpx()])
            elif op == 0xCD: self._cmp(self.a, m[self._abs()])
            elif op == 0xDD: self._cmp(self.a, m[self._abx()])
            elif op == 0xD9: self._cmp(self.a, m[self._aby()])
            elif op == 0xC1: self._cmp(self.a, m[self._inx()])
            elif op == 0xD1: self._cmp(self.a, m[self._iny()])
            elif op == 0xE0: self._cmp(self.x, m[self._imm()])
            elif op == 0xE4: self._cmp(self.x, m[self._zp()])
            elif op == 0xEC: self._cmp(self.x, m[self._abs()])
            elif op == 0xC0: self._cmp(self.y, m[self._imm()])
            elif op == 0xC4: self._cmp(self.y, m[self._zp()])
            elif op == 0xCC: self._cmp(self.y, m[self._abs()])
            # --- increments and decrements
            elif op == 0xE6: a = self._zp(); m[a] = self._nz(m[a] + 1)
            elif op == 0xF6: a = self._zpx(); m[a] = self._nz(m[a] + 1)
            elif op == 0xEE: a = self._abs(); m[a] = self._nz(m[a] + 1)
            elif op == 0xFE: a = self._abx(); m[a] = self._nz(m[a] + 1)
            elif op == 0xC6: a = self._zp(); m[a] = self._nz(m[a] - 1)
            elif op == 0xD6: a = self._zpx(); m[a] = self._nz(m[a] - 1)
            elif op == 0xCE: a = self._abs(); m[a] = self._nz(m[a] - 1)
            elif op == 0xDE: a = self._abx(); m[a] = self._nz(m[a] - 1)
            elif op == 0xE8: self.x = self._nz(self.x + 1)
            elif op == 0xC8: self.y = self._nz(self.y + 1)
            elif op == 0xCA: self.x = self._nz(self.x - 1)
            elif op == 0x88: self.y = self._nz(self.y - 1)
            # --- shifts
            elif op == 0x0A: self.c = self.a >> 7; self.a = self._nz(self.a << 1)
            elif op == 0x06: self._asl_m(self._zp())
            elif op == 0x16: self._asl_m(self._zpx())
            elif op == 0x0E: self._asl_m(self._abs())
            elif op == 0x1E: self._asl_m(self._abx())
            elif op == 0x4A: self.c = self.a & 1; self.a = self._nz(self.a >> 1)
            elif op == 0x46: self._lsr_m(self._zp())
            elif op == 0x56: self._lsr_m(self._zpx())
            elif op == 0x4E: self._lsr_m(self._abs())
            elif op == 0x5E: self._lsr_m(self._abx())
            elif op == 0x2A: r = (self.a << 1) | self.c; self.c = self.a >> 7; self.a = self._nz(r)
            elif op == 0x26: self._rol_m(self._zp())
            elif op == 0x36: self._rol_m(self._zpx())
            elif op == 0x2E: self._rol_m(self._abs())
            elif op == 0x3E: self._rol_m(self._abx())
            elif op == 0x6A: r = (self.a >> 1) | (self.c << 7); self.c = self.a & 1; self.a = self._nz(r)
            elif op == 0x66: self._ror_m(self._zp())
            elif op == 0x76: self._ror_m(self._zpx())
            elif op == 0x6E: self._ror_m(self._abs())
            elif op == 0x7E: self._ror_m(self._abx())
            # --- jumps and branches
            elif op == 0x4C: self.pc = self._abs()
            elif op == 0x6C:
                a = self._abs()
                self.pc = m[a] | (m[(a & 0xFF00) | ((a + 1) & 0xFF)] << 8)
            elif op == 0x20:
                a = self._abs()
                r = self.pc - 1
                self.push(r >> 8)
                self.push(r & 0xFF)
                self.pc = a
            elif op == 0x60:
                lo = self.pop()
                self.pc = ((lo | (self.pop() << 8)) + 1) & 0xFFFF
            elif op == 0x40:
                self.set_status(self.pop())
                lo = self.pop()
                self.pc = lo | (self.pop() << 8)
            elif op == 0x10: self._branch(not self.n)
            elif op == 0x30: self._branch(self.n)
            elif op == 0x50: self._branch(not self.v)
            elif op == 0x70: self._branch(self.v)
            elif op == 0x90: self._branch(not self.c)
            elif op == 0xB0: self._branch(self.c)
            elif op == 0xD0: self._branch(not self.z)
            elif op == 0xF0: self._branch(self.z)
            # --- flags
            elif op == 0x18: self.c = 0
            elif op == 0x38: self.c = 1
            elif op == 0x58: self.i = 0
            elif op == 0x78: self.i = 1
            elif op == 0xB8: self.v = 0
            elif op == 0xD8: self.d = 0
            elif op == 0xF8: raise Halt("decimal mode at &%04x is not supported" % (self.pc - 1))
            elif op == 0xEA: pass
            elif op == 0x00: raise Halt("BRK at &%04x" % (self.pc - 1))
            else:
                raise Halt("undefined opcode &%02x at &%04x" % (op, self.pc - 1))


if __name__ == '__main__':
    import sys
    mem = load_listing(sys.argv[1])
    cpu = CPU(mem)
    # the player's starting square, and one below the surface
    for x, y in ((0x9b, 0x3b), (0x9b, 0x4f), (0x40, 0x4f), (0x80, 0x80)):
        mem[0x95], mem[0x97], mem[0x2d], mem[0x00] = x, y, 0, 0
        cpu.run(0x2398)
        print("(&%02x,&%02x): tile &%02x flip &%02x drawn as &%02x palette &%02x sprite &%02x  (%d steps)" % (
            x, y, mem[8], mem[9], cpu.y, mem[0x73], mem[0x75], cpu.steps))
        cpu.steps = 0
