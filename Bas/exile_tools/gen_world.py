"""gen_world.py - Exile's planet, square by square, from the game's own code.

Runs get_tile_and_set_sprite_variables (&2398) for all 65,536 squares on
the 6502 in exile6502.py, with the tile-processing mode cleared so no
update routine runs and no object is created, and writes:

    out/world.map          TILEMAP LOAD file: 256 256, then a tile-variant
                           index per square (0 = nothing drawn)
    out/world_types.bin   204,800 bytes: the game's tile type (0-&3F) with
                           the flip bits in bits 6-7, as the physics sees it
    out/world_drawn.bin    65,536 bytes: the type actually drawn (a removed
                           leaf becomes TILE_SPACE here but not above)
    out/world_palette.bin  65,536 bytes: the palette byte for each square
    out/variants.json      index -> sprite, flips, offsets, palette, type

--check DIR compares every square against the C# census output in DIR
(map_bg.bin, map_or.bin, map_pal.bin from Bas/exile_tools/census) and
reports any disagreement.

    python gen_world.py exile-disassembly.txt [--check ../census/out] [--out out]

The listing is not vendored: fetch it from
http://www.level7.org.uk/miscellany/exile-disassembly.txt (the standard
version; the enhanced listing has the same code at other addresses).
"""
import json
import os
import struct
import sys
import time

from exile6502 import CPU, load_listing

SPRITE_NONE = 0x46          # tiles_sprite_and_y_flip_table entry &C6 & &7F
GET_TILE_AND_SET_SPRITE_VARIABLES = 0x2398
PLOT_MODE = 0x20            # tile_processing_mode as the game plots a tile
DOOR_TILES = (0x03, 0x04)   # the only tiles whose look a routine settles


def generate(mem, progress=True):
    """Return per-square arrays: types, drawn, flips, palette, sprite, yfrac, xfrac."""
    cpu = CPU(mem)
    n = 65536
    types = bytearray(n)
    drawn = bytearray(n)
    cdrawn = bytearray(n)       # as the census sees it, with no routine run
    cflips = bytearray(n)
    cpal = bytearray(n)
    flips = bytearray(n)
    pal = bytearray(n)
    spr = bytearray(n)
    yfrac = bytearray(n)
    xfrac = bytearray(n)
    tdata = bytearray(n)        # the tertiary object's data-byte offset (&bd), 0 for none
    frommap = bytearray(n >> 3)  # one bit per square: the tile came from the mapped data (&00)
    ttype = bytearray(n)        # and its type-byte offset (&be), meaningful only with the first
    t0 = time.time()
    for y in range(256):
        for x in range(256):
            mem[0x95] = x
            mem[0x97] = y
            mem[0x2D] = 0           # tile_processing_mode: call no update routine
            mem[0x00] = 0           # tile_was_from_map_data
            cpu.run(GET_TILE_AND_SET_SPRITE_VARIABLES)
            i = y * 256 + x
            types[i] = mem[0x08]
            flips[i] = mem[0x09]
            drawn[i] = cpu.y
            pal[i] = mem[0x73]
            spr[i] = mem[0x75]
            yfrac[i] = mem[0x51]
            xfrac[i] = mem[0x4F]
            tdata[i] = mem[0xBD]
            if mem[0x00] & 0x80:
                frommap[i >> 3] |= 1 << (i & 7)
            ttype[i] = mem[0xBE] if mem[0xBD] else 0
            cdrawn[i] = drawn[i]; cflips[i] = flips[i]; cpal[i] = pal[i]
            # A door's look comes from its own routine, so asked with the
            # routines off it answers blank and the square is drawn as nothing
            # at all.  That is how the player came to be standing on thin air
            # inside the ship: the floor there is a door.  Ask again and let
            # the routine run - for a door it only settles the type, it makes
            # no object and touches nothing else.
            if types[i] in DOOR_TILES:
                mem[0x95] = x
                mem[0x97] = y
                mem[0x2D] = PLOT_MODE
                mem[0x00] = 0
                cpu.run(GET_TILE_AND_SET_SPRITE_VARIABLES)
                flips[i] = mem[0x09]
                drawn[i] = cpu.y
                pal[i] = mem[0x73]
                spr[i] = mem[0x75]
                yfrac[i] = mem[0x51]
                xfrac[i] = mem[0x4F]
        if progress and (y & 15) == 15:
            sys.stderr.write("\r  row %3d of 256, %5.1f s" % (y + 1, time.time() - t0))
    if progress:
        sys.stderr.write("\r  %d squares in %.1f s, %d instructions\n" % (n, time.time() - t0, cpu.steps))
    return types, drawn, flips, pal, spr, yfrac, xfrac, tdata, ttype, frommap, cdrawn, cflips, cpal


def check(census_dir, drawn, flips, pal):
    """Compare with the C# census: FinalBackground, orientation, palette byte."""
    bg = open(os.path.join(census_dir, 'map_bg.bin'), 'rb').read()
    orient = open(os.path.join(census_dir, 'map_or.bin'), 'rb').read()
    cpal = open(os.path.join(census_dir, 'map_pal.bin'), 'rb').read()
    bad = []
    for i in range(65536):
        if drawn[i] != bg[i] or flips[i] != orient[i] or pal[i] != cpal[i]:
            bad.append(i)
    print("census check: %d of 65536 squares differ" % len(bad))
    for i in bad[:12]:
        print("  (&%02x,&%02x) 6502: type &%02x flip &%02x pal &%02x   C#: &%02x &%02x &%02x" % (
            i & 255, i >> 8, drawn[i], flips[i], pal[i], bg[i], orient[i], cpal[i]))
    return len(bad) == 0


def build_variants(drawn, flips, pal, spr, yfrac, xfrac):
    """Give every distinct drawn tile an index; 0 for squares that draw nothing."""
    index = {}
    variants = []
    cells = [0] * 65536
    for i in range(65536):
        if spr[i] == SPRITE_NONE:
            continue
        key = (spr[i], flips[i], yfrac[i], xfrac[i], pal[i])
        v = index.get(key)
        if v is None:
            v = len(variants) + 1
            index[key] = v
            variants.append({
                'index': v, 'sprite': spr[i], 'flipH': 1 if flips[i] & 0x80 else 0,
                'flipV': 1 if flips[i] & 0x40 else 0, 'yfrac': yfrac[i], 'xfrac': xfrac[i],
                'palette': pal[i], 'type': drawn[i], 'count': 0})
        variants[v - 1]['count'] += 1
        cells[i] = v
    # Number the variants by how many squares use them, most common first,
    # so that the first flash slot holds nearly every square and the second
    # slot's map is almost all zeros, which TILEMAP DRAW skips for free.
    order = sorted(range(len(variants)), key=lambda k: -variants[k]['count'])
    renumber = {old + 1: new + 1 for new, old in enumerate(order)}
    variants = [variants[k] for k in order]
    for new, var in enumerate(variants):
        var['index'] = new + 1
    cells = [renumber[c] if c else 0 for c in cells]
    return cells, variants


TILES_PER_SLOT = 280        # 8 across, 35 down at 32 x 32: 286,720 pixels, under a 144 KB slot


def write_map(path, cells, first, last, comment):
    """A TILEMAP LOAD file holding the variants first..last as 1-based slot indices, 0 elsewhere."""
    with open(path, 'w', newline='\n') as f:
        f.write("' Exile: " + comment + "\n")
        f.write("' generated by gen_world.py from the game's own landscape code\n")
        f.write("256 256\n")
        for y in range(256):
            row = cells[y * 256:(y + 1) * 256]
            f.write(",".join(str(c - first + 1) if first <= c <= last else "0" for c in row) + "\n")


def write_outputs(out_dir, cells, variants, types, drawn, flips, pal, tdata, ttype, frommap):
    os.makedirs(out_dir, exist_ok=True)
    n = len(variants)
    write_map(os.path.join(out_dir, 'world.map'), cells, 1, n, "the whole planet as tile-variant indices")
    write_map(os.path.join(out_dir, 'exile_w1.map'), cells, 1, TILES_PER_SLOT,
              "variants 1-%d, the tileset in flash slot 1" % min(n, TILES_PER_SLOT))
    write_map(os.path.join(out_dir, 'exile_w2.map'), cells, TILES_PER_SLOT + 1, 2 * TILES_PER_SLOT,
              "variants %d-%d, the tileset in flash slot 2" % (TILES_PER_SLOT + 1, n))
    tf = bytearray(65536)
    for i in range(65536):
        tf[i] = (types[i] & 0x3F) | (flips[i] & 0xC0)
    # the kernel's world array: the tile bytes, the two tertiary-object maps, then
    # one bit per square for the squares the mapped data placed
    open(os.path.join(out_dir, 'world_types.bin'), 'wb').write(bytes(tf) + bytes(tdata) + bytes(ttype) + bytes(frommap))
    open(os.path.join(out_dir, 'world_drawn.bin'), 'wb').write(bytes(drawn))
    open(os.path.join(out_dir, 'world_palette.bin'), 'wb').write(bytes(pal))
    with open(os.path.join(out_dir, 'variants.json'), 'w') as f:
        json.dump(variants, f, indent=1)


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith('--'):
        print(__doc__)
        return 2
    listing = args[0]
    census_dir = None
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
    i = 1
    while i < len(args):
        if args[i] == '--check':
            census_dir = args[i + 1]
            i += 2
        elif args[i] == '--out':
            out_dir = args[i + 1]
            i += 2
        else:
            print("unknown argument", args[i])
            return 2
    mem = load_listing(listing)
    (types, drawn, flips, pal, spr, yfrac, xfrac, tdata, ttype, frommap,
     cdrawn, cflips, cpal) = generate(mem)
    ok = True
    if census_dir:
        # against what the census walked, which is the world with no routine run
        ok = check(census_dir, cdrawn, cflips, cpal)
    cells, variants = build_variants(drawn, flips, pal, spr, yfrac, xfrac)
    write_outputs(out_dir, cells, variants, types, drawn, flips, pal, tdata, ttype, frommap)
    empty = sum(1 for c in cells if c == 0)
    print("variants: %d drawn tiles; %d squares draw nothing; %d types in use" % (
        len(variants), empty, len(set(drawn))))
    print("written to", out_dir)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
