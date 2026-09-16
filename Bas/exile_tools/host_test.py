"""host_test.py - check the whole-scene kernel on the PC, against the traces, in seconds.

Builds csub/exile.c as a Windows DLL with the Visual Studio compiler (the
kernel is plain 32-bit integer C, so the same source serves the CSUB and the
DLL), then replays every scene in out/traces2/ through it exactly as
exiletest.bas does on the board, comparing every slot of every tick.  The
board run (run_exiletest.py) stays the final word; this is for iterating.

    python host_test.py exile-disassembly.txt [names...] [-v]
"""
import ctypes
import json
import os
import struct
import subprocess
import sys

from exile6502 import load_listing
from exilegame import OBJ, FIELDS
from gen_exiletest import GAME, GAME_SIZE, NSLOT, game_init, spawn_into, TABLES, read_tables_bas
from gen_phystest import key_mask
from run_exiletest import fmt_slot

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')

# Scenes that do not match yet, with what is known about each.  They are run
# and reported, but they do not count as failures: a defect that is understood
# and written down is more use than a deleted test.
KNOWN = {}
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


def run_scene(lib, mem, world, tables, t, verbose=False):
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
    notes = []
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
    tdir = os.path.join(out, 'traces2')
    names = args[1:] or sorted(f[:-5] for f in os.listdir(tdir) if f.endswith('.json'))
    failed = 0
    known = []
    total_ticks = 0
    for name in names:
        t = json.load(open(os.path.join(tdir, name + '.json')))
        n, problem, notes = run_scene(lib, mem, world, tables, t, verbose)
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
    print("%d scenes, %d failed, %d known, %d ticks" % (len(names), failed, len(known), total_ticks))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
