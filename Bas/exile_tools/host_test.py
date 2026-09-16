"""host_test.py - check the whole-scene kernel on the PC, against the traces, in seconds.

Builds csub/exile.c as a Windows DLL with the Visual Studio compiler (the
kernel is plain 32-bit integer C, so the same source serves the CSUB and the
DLL), then replays every scene in out/traces2/ through it exactly as
exiletest.bas does on the board, comparing every slot of every tick.  The
board run (run_exiletest.py) stays the final word; this is for iterating.

    python host_test.py exile-disassembly.txt [names...] [-v] [--nopart]

--nopart replays out/traces2np, the traces taken with the game's particle
system patched out, and switches the kernel's off to match: that run has no
approximation left in it anywhere.
"""
import ctypes
import json
import os
import struct
import subprocess
import sys

from exile6502 import load_listing
from exilegame import OBJ, FIELDS
from gen_exiletest import GAME, GAME_SIZE, NSLOT, game_init, spawn_into, TABLES, read_tables_bas, MIRROR, mirror_index
from gen_phystest import key_mask
from run_exiletest import fmt_slot

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')

# Scenes that do not match yet, with what is known about each.  They are run
# and reported, but they do not count as failures: a defect that is understood
# and written down is more use than a deleted test.
KNOWN = {}

# Game-array names the kernel does not model, so their mirror is not checked.
# Each one is a decision, not an oversight: add a name here only with the reason.
UNMODELLED = set()

# Names checked on some of their bits only, with why the rest are dead.
MASKED = {
    # &1cd2 indexes objects_type with the whole of this_object_touching, whose
    # top bit means "touching nothing", so the read runs past the sixteen slots
    # and the flags it ORs in are junk.  It cannot matter: every consumer
    # (&1cdc BPL, &2b03 BIT/BMI) looks at bit 7 alone, and when touching has its
    # top bit set that bit comes from tbcoll after the EOR #&80, whatever the
    # junk was.  So bit 7 is checked and the rest is left to the original.
    'heldcoll': 0x80,
}
# The mirror check can be turned into a report rather than a failure while a
# scene's drift is being triaged: EXILE_GAME=report.
GAME_CHECK = os.environ.get('EXILE_GAME', 'fail')
# the eight bytes the game keeps for each particle, at &28d6
PART_FIELDS = ('vx', 'vy', 'xf', 'yf', 'x', 'y', 'ttl', 'colour')
scratch = os.environ.get('EXILE_SCRATCH', os.path.join(out, 'host'))
VCVARS = r"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"


def build():
    os.makedirs(scratch, exist_ok=True)
    src = os.path.join(here, 'csub', 'exile.c')
    dll = os.path.join(scratch, 'exile.dll')
    if not os.environ.get('EXILE_DEBUG') and os.path.exists(dll) and os.path.getmtime(dll) > max(os.path.getmtime(src), os.path.getmtime(os.path.join(here, 'csub', 'exilestate2.h'))):
        return dll
    debug = '/DHOST_DEBUG' if os.environ.get('EXILE_DEBUG') else ''
    cmd = 'call "%s" >nul 2>&1 && cl /nologo /O2 /W3 /std:c11 /LD %s /I"%s" /Fe:exile.dll "%s"' % (
        VCVARS, debug, os.path.join(here, 'csub'), src)
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=scratch)
    if r.returncode or not os.path.exists(dll):
        print(r.stdout[-3000:], r.stderr[-3000:])
        raise SystemExit("the host build failed")
    return dll


def pack_tables(mem):
    tabs = read_tables_bas()
    packed = bytearray()
    for cname, src, size in TABLES:
        if isinstance(src, (list, tuple)):
            vals = list(src)[:size]
        else:
            vals = tabs[src][:size] if isinstance(src, str) else [mem[src + i] for i in range(size)]
        if cname == 'NOREPEAT':
            vals = [v & 1 for v in vals]
        packed += bytes(vals)
    while len(packed) % 8:
        packed.append(0)
    return bytes(packed)


def scene_arrays(mem, t):
    slots = [0] * (NSLOT * len(FIELDS))
    for f in FIELDS:
        for sl in range(NSLOT):
            slots[FIELDS.index(f) * NSLOT + sl] = mem[OBJ[f] + sl]
    if t['start']:
        x, y = t['start']
        slots[FIELDS.index('x') * NSLOT] = x; slots[FIELDS.index('y') * NSLOT] = y
        slots[FIELDS.index('xf') * NSLOT] = 0x80; slots[FIELDS.index('yf') * NSLOT] = 0
        slots[FIELDS.index('vx') * NSLOT] = 0; slots[FIELDS.index('vy') * NSLOT] = 0
    if t.get('lonely') or t.get('clear'):
        for sl in range(1, NSLOT):
            slots[FIELDS.index('y') * NSLOT + sl] = 0
    for spec in t['objects']:
        slot, typ, x, y = spec[:4]
        spawn_into(slots, mem, slot, typ, x, y)
        for k, v in (spec[4] if len(spec) > 4 else {}).items():
            slots[FIELDS.index(k) * NSLOT + slot] = v
    g = game_init(mem, t.get('pokes'))
    g['eventson'] = 1 if t.get('events') else 0
    g['promoteon'] = 1 if t.get('promote') else 0
    g['partsoff'] = 0 if t.get('particles', True) else 1
    for n, v in t.get('screen0', {}).items():
        g[n] = v
    game = [g[n] for n in GAME] + [0] * (GAME_SIZE - len(GAME))
    words = []
    for keys, tk in zip(t['keys'], t['ticks']):
        km = key_mask(keys)
        words += [km & 0xFFFFFFFF, km >> 32] + tk['wl'] + tk['scr'] + [tk['d4'], len(tk['feed'])]
        for site, val in tk['feed']:
            words += [site, val]
    feed = struct.pack('<%dI' % len(words), *words)
    return slots, game, feed


def run_scene(lib, mem, world, tables, t, parts, verbose=False):
    slots, game, feed = scene_arrays(mem, t)
    obj_a = (ctypes.c_longlong * len(slots))(*slots)
    game_a = (ctypes.c_longlong * len(game))(*game)
    world_a = ctypes.create_string_buffer(world, len(world))
    tab_a = ctypes.create_string_buffer(tables, len(tables))
    feed_a = ctypes.create_string_buffer(feed + b'\0' * 64, len(feed) + 64)
    part_a = (ctypes.c_longlong * 256)()      # the particle system, eight words a particle
    yi, fi = FIELDS.index('y'), FIELDS.index('flags')
    nslots = 1 if t.get('lonely') else NSLOT
    gf, ga = GAME.index('fault'), GAME.index('faultarg')
    gnp = GAME.index('npart')
    # the game array's mirror of the original's memory, as a run of (game index,
    # trace position, name) for the names this kernel claims to keep
    mirror = [(gi, pos, GAME[gi], MASKED.get(GAME[gi], 0xFF))
              for pos, (gi, _a) in enumerate(mirror_index()) if GAME[gi] not in UNMODELLED]
    want_game = list(t.get('game0') or [])
    drift = set()
    notes = []
    if want_game:
        bad = [(n, want_game[pos], game[gi]) for gi, pos, n, k in mirror
               if (game[gi] ^ want_game[pos]) & k]
        if bad and GAME_CHECK == 'fail':
            return 0, "before the first tick the game array differs: " + ", ".join(
                "%s game &%02x kernel &%02x" % b for b in bad[:6]), notes
    for n, tk in enumerate(t['ticks']):
        if t.get('lonely'):
            for s in range(1, NSLOT):
                obj_a[yi * NSLOT + s] = 0
        lib.exile_tick(obj_a, game_a, world_a, tab_a, feed_a, part_a)
        if game_a[gf]:
            code, arg = game_a[gf], game_a[ga]
            if code == 3:
                notes.append("tick %d: tile type &%02x has a collision routine that is not modelled" % (n + 1, arg))
                game_a[gf] = 0
            else:
                return n, "tick %d: fault %d arg &%x" % (n + 1, code, arg), notes
        # The particle system is counted, not required to match.  A particle
        # lives or dies by what the game read back from the pixel it had just
        # plotted, and the kernel has no screen to read; &2267 also leaves the
        # velocity add pointing wherever update_particle left X.  So particles
        # drift, and the count below is the measure of how far: it is reported,
        # and a change that makes it worse is meant to be seen.
        if 'npart' in tk:
            want_n = tk['npart']
            got_n = (game_a[gnp] + 1) & 255
            if want_n or got_n:
                parts[1] += 1
                if want_n == got_n and all(part_a[i] == tk['part'][i] for i in range(want_n * 8)):
                    parts[0] += 1
        for i, v in tk.get('gd', ()):
            if i < len(want_game):
                want_game[i] = v
        if want_game:
            bad = [(n, want_game[pos], game_a[gi]) for gi, pos, n, k in mirror
                   if ((game_a[gi] ^ want_game[pos]) & k) and n not in drift]
            if bad:
                if GAME_CHECK == 'fail':
                    keys = "+".join(t['keys'][n]) or "-"
                    return n, "tick %d keys %s: the game array differs\n%s" % (
                        n + 1, keys, "\n".join(
                            "  %-12s game &%02x  kernel &%02x" % b for b in bad[:8])), notes
                for b in bad:
                    drift.add(b[0])
                    notes.append("tick %d: %s game &%02x kernel &%02x" % (n + 1, b[0], b[1], b[2]))
        for s in range(nslots):
            want = list(tk['slots'][s])
            got = [obj_a[f * NSLOT + s] for f in range(len(FIELDS))]
            if want[yi] == 0:
                if got[yi] != 0:
                    return n, "tick %d slot %d: the game has no object here, the kernel has %s" % (n + 1, s, fmt_slot(got)), notes
                continue
            if got[yi] == 0:
                return n, "tick %d slot %d: the game has %s, the kernel has nothing" % (n + 1, s, fmt_slot(want)), notes
            want[fi] &= 0xFE; got[fi] &= 0xFE
            if want != got:
                diff = [FIELDS[i] for i in range(len(FIELDS)) if want[i] != got[i]]
                keys = "+".join(t['keys'][n]) or "-"
                prev = t['ticks'][n - 1]['slots'][s] if n else None
                lines = ["tick %d keys %s slot %d: %s differ" % (n + 1, keys, s, ", ".join(diff))]
                if prev:
                    lines.append("  before  %s" % fmt_slot(prev))
                lines.append("  kernel  %s" % fmt_slot(got))
                lines.append("  game    %s" % fmt_slot(want))
                return n, "\n".join(lines), notes
        if verbose:
            print("  %4d " % (n + 1) + "  ".join("%d:%s" % (s, fmt_slot([obj_a[f * NSLOT + s] for f in range(len(FIELDS))]))
                                              for s in range(nslots) if obj_a[yi * NSLOT + s]))
    return len(t['ticks']), None, notes


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    verbose = '-v' in sys.argv
    if not args:
        print(__doc__)
        return 2
    mem = load_listing(args[0])
    world = open(os.path.join(out, 'world_types.bin'), 'rb').read()
    tables = pack_tables(mem)
    dll = build()
    lib = ctypes.CDLL(dll)
    lib.exile_tick.restype = ctypes.c_longlong
    lib.exile_tick.argtypes = [ctypes.c_void_p] * 6
    tdir = os.path.join(out, 'traces2np' if '--nopart' in sys.argv else 'traces2')
    names = args[1:] or sorted(f[:-5] for f in os.listdir(tdir) if f.endswith('.json'))
    failed = 0
    known = []
    total_ticks = 0
    parts = [0, 0]              # ticks where the particles matched, ticks with any
    for name in names:
        t = json.load(open(os.path.join(tdir, name + '.json')))
        n, problem, notes = run_scene(lib, mem, world, tables, t, parts, verbose)
        total = len(t['ticks'])
        total_ticks += n
        if problem is None:
            print("%-22s %4d/%-4d ticks match" % (name, n, total))
        elif name in KNOWN:
            known.append(name)
            print("%-22s %4d/%-4d ticks match, then (a known one):\n%s" % (name, n, total, problem))
        else:
            failed += 1
            print("%-22s %4d/%-4d ticks match, then:\n%s" % (name, n, total, problem))
        for w in notes[:3]:
            print("    note: " + w)
    if known:
        print()
        for nm in known:
            print("known and not counted: %s" % nm)
            print("   %s" % KNOWN[nm])
    print("%d scenes, %d failed, %d known, %d ticks%s" % (
        len(names), failed, len(known), total_ticks,
        ", particles excluded on both sides" if '--nopart' in sys.argv else ""))
    if parts[1]:
        print("particles: %d of %d ticks match exactly (%.0f%%); they are counted, not required"
              % (parts[0], parts[1], 100.0 * parts[0] / parts[1]))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
