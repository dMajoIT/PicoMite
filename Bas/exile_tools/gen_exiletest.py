"""gen_exiletest.py - build the whole-scene CSUB kernel and its test program.

Writes csub/exilestate2.h (the layout of the slot tables, the game array and
the packed tables, shared with the BASIC), compiles csub/exile.c into a CSUB
block with user-tools/armcfgen.py, packs the tables into out/scene/tables2.bin,
and for every trace in out/traces2/ writes a binary feed (the keys, water
level, screen position and random numbers of every tick) and an init file
(the sixteen slots and the game array as the scene starts).  Then it
assembles Bas/exile/exiletest.bas from Bas/exile/exiletest_harness.bas.  The
CSUB itself goes to out/scene/exile_lib.bas, which the program loads with
LIBRARY LOAD: pasted into the program its hex text would not fit.
run_exiletest.py puts it all on the PC3 and checks every slot of every tick.

    python gen_exiletest.py exile-disassembly.txt
"""
import json
import os
import struct
import subprocess
import sys

from exile6502 import load_listing
from exilegame import ACTIONS, OBJ, FIELDS
from gen_csubtest import read_tables_bas
from gen_phystest import key_mask

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, 'out')
root = os.path.normpath(os.path.join(here, '..', '..'))

NSLOT = 16
GAME = (['frame', 'angle', 'facing', 'immob', 'timmob', 'rotvel', 'lying', 'aim', 'aimvel', 'aimflip',
         'jetok', 'inwater', 'tbcoll', 'surr', 'wedged', 'signs', 'windsign', 'reltx', 'relty', 'walkspd',
         'maxacc0', 'firecool', 'watertile', 'boostercol', 'suitcol', 'crossx', 'crossy',
         'kmask', 'feedmode', 'feedpos', 'feedend', 'fault', 'faultarg', 'held', 'demat', 'heldcoll', 'redmush',
         'preang', 'premag', 'retrieve', 'viewpoint', 'npcw0',
         'tgtx', 'tgtxf', 'tgty', 'tgtyf', 'x17', 'y17', 'wlblock', 'doorsup', 'routebest',
         'exptimer', 'flood', 'bluemush', 'immunity', 'accpower', 'accsign', 'accdmg', 'lasttile', 'plotw',
         'fireimm', 'doortimer', 'quake', 'shipmoving', 'radimm', 'whistle1', 'whistle2', 'chatterres', 'eastof76']
        + ['clawavail%d' % i for i in range(4)] + ['clawtel%d' % i for i in range(4)]
        + ['weapon', 'fired', 'blaster', 'pockused', 'telrem', 'telnext', 'scrollx', 'scrolly']
        + ['wlo%d' % i for i in range(6)] + ['whi%d' % i for i in range(6)]
        + ['pocket%d' % i for i in range(5)] + ['telx%d' % i for i in range(5)] + ['tely%d' % i for i in range(5)]
        + ['eventson', 'promoteon'] + ['wldes%d' % i for i in range(4)]
        + ['orgxf', 'orgyf', 'fracx', 'sgnx', 'fracy', 'sgny', 'secsx', 'secsy',
           'svelx', 'svely', 'newtiles', 'secmode', 'secnext', 'secshuf', 'secdist']
        + ['gift%d' % i for i in range(5)]
        + ['wl%d' % i for i in range(8)] + ['rnd%d' % i for i in range(4)] + ['scr%d' % i for i in range(10)]
        + ['kh%d' % i for i in range(39)] + ['coll%d' % i for i in range(19)]
        + ['secx%d' % i for i in range(32)] + ['secy%d' % i for i in range(32)]
        + ['sect%d' % i for i in range(32)] + ['sece%d' % i for i in range(32)]
        + ['tert%d' % i for i in range(235)])
GAME_SIZE = 640

# the packed tables: (C name, tables.bas label or memory address, size)
TABLES = [('OBPAT', 'ObstructionPatterns', 168), ('OBOFF', 'ObstructionPatternOffsets', 40),
          ('YOFF', 'TileObstructionYOffsets', 64), ('PAT', 'TileYOffsetAndPattern', 64),
          ('SPRF', 'TileSprites', 64), ('RTFLAGS', 'UpdateRoutineFlags', 121),
          ('SPRW', 0x5E0C, 256), ('SPRH', 0x5E89, 256), ('HALFQ', 'AngleHalfQuadrants', 8),
          ('WATERVEL', 'WaterVelocities', 4), ('WLX', 'WaterRangeX', 4), ('WALKMAXANG', 'WalkMaxAngle', 7),
          ('WALKMAXACC', 'WalkMaxAccel', 7), ('WALKWEIGHT', 'WalkWeightShift', 7),
          ('WEAPONCOST', 'WeaponEnergyCost', 6), ('OBJFLAGS', 'ObjectFlags', 101),
          ('OBJPAL', 'ObjectPalettes', 101), ('NOREPEAT', 0x121D, 39),
          ('PLAYERWEIGHTS', 0x19AC, 8), ('DISTANCES', 0x19A6, 4), ('SCRSZF', 0x1117, 3), ('SCRSZ', 0x111A, 3),
          ('DIRFLAGS', 0x29DC, 3), ('ROUND', 0x29DF, 3), ('MASK', 0x29E2, 3), ('SOFLAGS', 0x29E7, 7),
          ('OBJSPRITE', 0x028A, 101), ('RANGES', 0x29EE, 10), ('RANGEENERGY', 0x29F8, 10),
          ('BIRDDMG', 0x4690, 4), ('BIRDEN', 0x4694, 4), ('FINDPROB', 0x3C21, 4),
          ('WALKTURN', 0x3977, 7), ('WALKJUMP', 0x397E, 7),
          ('PHOBIA', 0x316B, 10), ('NPCTARGET', 0x3175, 10), ('NPCFOOD', 0x317F, 10), ('NPCHOME', 0x3189, 10),
          ('NPCRESP', 0x3193, 10), ('IMPPROJ', 0x319D, 5), ('IMPEN', 0x31A2, 5), ('IMPGIFT', 0x31A7, 5),
          ('ROBOTMINE', 0x4F18, 6), ('ROBOTBULLET', 0x4F1E, 3), ('FIREPAL', 0x4ACE, 8), ('TRANSPAL', 0x4D82, 4),
          ('TERTTYPE', 0x0A71, 256), ('SWITCHFX', 0x4958, 68), ('TRANSX', 0x314A, 16), ('TRANSY', 0x315A, 16),
          ('DOORTILES', 0x3E91, 4), ('DOORSPEED', 0x4D72, 4), ('DOORENERGY', 0x4D76, 4), ('DOORPAL', 0x4D7A, 8),
          ('GARG', 0x418B, 20), ('SUCKTRIG', 0x4E37, 9), ('SUCKPOW', 0x4E40, 9), ('SUCKPAL', 0x4E49, 9),
          ('CLAWEN', 0x48A3, 4), ('WALKANG256', 0x3962, 256),
          ('WEAPONBULLET', 0x2CDC, 6), ('THROWVEL', 0x32D2, 8), ('SCROLLDELTA', 0x2C15, 4), ('SCROLLLIMIT', 0x2C19, 4),
          ('SCRCENTRE', 0x14C7, 4), ('SCROFFXF', 0x358C, 2), ('SCROFFX', 0x358E, 2),
          ('SCROFFYF', 0x3590, 2), ('SCROFFY', 0x3592, 2)]


def game_init(mem):
    """The game array as the game starts, from the listing's image and the start-up code."""
    m = mem
    g = {n: 0 for n in GAME}
    g['angle'] = 0xC0
    g['jetok'] = m[0x358A]
    g['weapon'] = m[0x084D]; g['fired'] = m[0x29D7]; g['blaster'] = m[0x36]
    g['pockused'] = m[0x0847]; g['telrem'] = m[0x0822]; g['telnext'] = m[0x0821]
    g['scrollx'] = m[0x14C8]; g['scrolly'] = m[0x14CA]
    for i in range(6):
        g['wlo%d' % i] = m[0x084E + i]; g['whi%d' % i] = m[0x0854 + i]
    for i in range(5):
        g['pocket%d' % i] = m[0x0848 + i]; g['telx%d' % i] = m[0x0823 + i]; g['tely%d' % i] = m[0x0828 + i]
    g['boostercol'] = m[0x080E]; g['suitcol'] = m[0x0813]
    g['firecool'] = m[0x29D6]
    g['maxacc0'] = m[0x3969]; g['npcw0'] = m[0x3970]
    g['held'] = 0xFF
    g['heldcoll'] = m[0x19B3]; g['demat'] = m[0x19B5]
    g['redmush'] = m[0x081A]; g['retrieve'] = m[0x316A]; g['viewpoint'] = m[0x14CB]
    # the bytes past the sixteen slots: the target pseudo-slot and the odd 18th entries
    g['tgtx'] = m[0x08A1]; g['tgtxf'] = m[0x0890]; g['tgty'] = m[0x08C4]; g['tgtyf'] = m[0x08B3]
    g['x17'] = m[0x08A2]; g['y17'] = m[0x08C5]
    g['wlblock'] = m[0x3598]; g['doorsup'] = m[0x3599]; g['routebest'] = m[0x3CE4]
    # the explosion and flooding states, the blue mushroom timer, the immunity pill, the
    # explosion acceleration's defaults (&35 = &28 from the start-up code), the imps' gifts
    g['exptimer'] = m[0x081D]; g['flood'] = m[0x081E]; g['bluemush'] = m[0x081B]; g['immunity'] = m[0x0815]
    g['fireimm'] = m[0x0814]; g['doortimer'] = m[0x0819]
    g['quake'] = m[0x081F]; g['shipmoving'] = m[0x19AB]; g['radimm'] = m[0x0818]
    g['whistle1'] = 0; g['whistle2'] = m[0x29D8]; g['chatterres'] = m[0x081C]; g['eastof76'] = m[0x19AA]
    for i in range(4):
        g['clawavail%d' % i] = m[0x083F + i]; g['clawtel%d' % i] = m[0x0843 + i]
    g['accpower'] = 0x28
    for i in range(5):
        g['gift%d' % i] = m[0x083A + i]
    g['feedmode'] = 1
    for i in range(8):
        g['wl%d' % i] = m[0x082E + i]
    for i in range(4):
        g['wldes%d' % i] = m[0x0836 + i]
    for i in range(39):
        g['kh%d' % i] = m[0x126B + i]
    for i in range(19):
        g['coll%d' % i] = m[0x0806 + i]
    for i in range(32):
        g['secx%d' % i] = m[0x0AF2 + i]; g['secy%d' % i] = m[0x0B12 + i]
        g['sect%d' % i] = m[0x0B32 + i]; g['sece%d' % i] = m[0x0B53 + i]
    for i in range(235):
        g['tert%d' % i] = m[0x0986 + i]
    return g


def spawn_into(slots, mem, slot, typ, x, y, xf=0x80, yf=0):
    """create_new_object_in_slot_Y, as exilegame.spawn does it, on a slot table."""
    r = 10
    while True:
        r -= 1
        if typ >= mem[0x29EE + r]:
            break
    # tx and ty are left as they were, as create_new_object_in_slot_Y leaves them
    vals = {'type': typ, 'sprite': mem[0x028A + typ], 'xf': xf, 'x': x, 'yf': yf, 'y': y, 'flags': 5,
            'palette': mem[0x02EF + typ] & 0x7F, 'vx': 0, 'vy': 0, 'target': slot,
            'energy': mem[0x29F8 + r], 'touching': 0xFF, 'timer': 0, 'tdata': 0, 'state': 0}
    for f, v in vals.items():
        slots[FIELDS.index(f) * NSLOT + slot] = v


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mem = load_listing(sys.argv[1])
    assert len(GAME) <= GAME_SIZE, len(GAME)
    cdir = os.path.join(here, 'csub')
    sdir = os.path.join(out, 'scene')
    os.makedirs(sdir, exist_ok=True)
    # the layouts
    hdr = ["/* exilestate2.h - generated by gen_exiletest.py: the layout of the slot tables,",
           "   the game array and the packed tables */", "#define NSLOT %d" % NSLOT]
    consts = ["' the layouts, generated by gen_exiletest.py"]
    for i, f in enumerate(FIELDS):
        hdr.append("#define O_%s %d" % (f.upper(), i))
        consts.append("Const O_%s = %d" % (f.upper(), i))
    for i, n in enumerate(GAME):
        hdr.append("#define G_%s %d" % (n.upper(), i))
        if not n[-1].isdigit() or n in ('wl0', 'rnd0', 'scr0', 'kh0', 'coll0', 'secx0', 'secy0', 'sect0', 'sece0', 'tert0', 'gift0', 'clawavail0', 'clawtel0', 'wlo0', 'whi0', 'pocket0', 'telx0', 'tely0', 'wldes0'):
            consts.append("Const G_%s = %d" % (n.upper(), i))
    hdr.append("#define GAME_SIZE %d" % GAME_SIZE)
    tabs = read_tables_bas()
    packed = bytearray()
    off = 0
    for cname, src, size in TABLES:
        vals = tabs[src][:size] if isinstance(src, str) else [mem[src + i] for i in range(size)]
        if cname == 'NOREPEAT':
            vals = [v & 1 for v in vals]
        assert len(vals) == size, (cname, len(vals), size)
        hdr.append("#define T_%s %d" % (cname, off))
        packed += bytes(vals)
        off += size
    while len(packed) % 8:
        packed.append(0)
    hdr.append("#define TABLES_BYTES %d" % len(packed))
    open(os.path.join(cdir, 'exilestate2.h'), 'w', newline='\n').write("\n".join(hdr) + "\n")
    open(os.path.join(sdir, 'tables2.bin'), 'wb').write(packed)
    print("tables2.bin: %d bytes; game array: %d of %d" % (len(packed), len(GAME), GAME_SIZE))

    # the CSUB
    block = os.path.join(cdir, 'exile_tick.txt')
    cmd = [sys.executable, os.path.join(root, 'user-tools', 'armcfgen.py'), os.path.join(cdir, 'exile.c'),
           '--compile', '-n', 'ExileTick', '-e', 'exile_tick', '-O', 's', '-I', cdir, '-o', block]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout)
        print(r.stderr[-3000:])
        return 1
    hexwords = sum(len(l.split()) for l in open(block) if l.strip() and not l.strip().startswith(("CSUB", "End", "'")))
    # the block goes to the board as a library file, not inside the program: the
    # hex text is 2.4 bytes for every byte of code and program memory cannot hold both
    lib = os.path.join(sdir, 'exile_lib.bas')
    open(lib, 'w', newline='\r\n').write(open(block).read())
    print("CSUB block: %d words (%d bytes of code), %d bytes as %s" % (
        hexwords, hexwords * 4, os.path.getsize(lib), os.path.basename(lib)))

    # the scenes
    tdir = os.path.join(out, 'traces2')
    names = sorted(f[:-5] for f in os.listdir(tdir) if f.endswith('.json'))
    listing = []
    for name in names:
        t = json.load(open(os.path.join(tdir, name + '.json')))
        # the feed: per tick kmask lo, hi, wl x8, scr x10, d4, n, (site, value) x n, all int32
        words = []
        for keys, tk in zip(t['keys'], t['ticks']):
            km = key_mask(keys)
            words += [km & 0xFFFFFFFF, km >> 32] + tk['wl'] + tk['scr'] + [tk['d4'], len(tk['feed'])]
            for site, val in tk['feed']:
                words += [site, val]
        feed = struct.pack('<%dI' % len(words), *words)
        open(os.path.join(sdir, 'sc_%s.bin' % name), 'wb').write(feed)
        # the init: nticks, feed bytes, the 288 slot values, the game array
        slots = [0] * (NSLOT * len(FIELDS))
        for f in FIELDS:
            for sl in range(NSLOT):
                slots[FIELDS.index(f) * NSLOT + sl] = mem[OBJ[f] + sl]    # the slots as the image has them
        if t['start']:
            spawn_x, spawn_y = t['start']
            slots[FIELDS.index('x') * NSLOT] = spawn_x; slots[FIELDS.index('y') * NSLOT] = spawn_y
            slots[FIELDS.index('xf') * NSLOT] = 0x80; slots[FIELDS.index('yf') * NSLOT] = 0
            slots[FIELDS.index('vx') * NSLOT] = 0; slots[FIELDS.index('vy') * NSLOT] = 0
        if t.get('lonely') or t.get('clear'):
            # the oracle wipes slots 1-15 before every tick of a lonely scene, once for a cleared one
            for sl in range(1, NSLOT):
                slots[FIELDS.index('y') * NSLOT + sl] = 0
        for spec in t['objects']:
            slot, typ, x, y = spec[:4]
            spawn_into(slots, mem, slot, typ, x, y)
            for k, v in (spec[4] if len(spec) > 4 else {}).items():
                slots[FIELDS.index(k) * NSLOT + slot] = v
        g = game_init(mem)
        g['eventson'] = 1 if t.get('events') else 0
        g['promoteon'] = 1 if t.get('promote') else 0
        for n, v in t.get('screen0', {}).items():
            g[n] = v
        lines = [str(len(t['ticks'])), str(len(feed)), "1" if t.get('lonely') else "0"] + [str(v) for v in slots] + [str(g[n]) for n in GAME]
        open(os.path.join(sdir, 'sc_%s.txt' % name), 'w', newline='\n').write("\n".join(lines) + "\n")
        listing.append(name)
    open(os.path.join(sdir, 'sc_list.txt'), 'w', newline='\n').write("\n".join(listing) + "\n")
    print("wrote %d scenes to %s" % (len(names), os.path.normpath(sdir)))

    # the program
    harness = open(os.path.join(here, '..', 'exile', 'exiletest_harness.bas'), encoding='utf-8').read()
    marker = "' @@CONSTS@@"
    assert marker in harness
    harness = harness.replace(marker, "\n".join(consts) + "\nConst TABLES_BYTES = %d\nConst NGAME = %d" % (len(packed), len(GAME)))
    prog = harness.rstrip('\n') + "\n"
    dest = os.path.join(here, '..', 'exile', 'exiletest.bas')
    open(dest, 'w', newline='\r\n').write(prog)
    print("wrote", os.path.normpath(dest), "(%d lines)" % prog.count('\n'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
