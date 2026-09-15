"""gen_tables.py - the game's tables, out of the listing and into BASIC.

The level7 listing prints every table under a "; name" label followed by its
bytes, so tables are found by name and their extents come from the listing
itself; nothing here is transcribed by hand.

    out/tables.bas    DATA fragments under labels, one per table the port
                      needs, with the address and size in a comment
    out/tables.json   every table in the listing (name -> address, bytes),
                      for the other generators and for looking things up

    python gen_tables.py exile-disassembly.txt [--out out]
"""
import json
import os
import re
import sys

LABEL = re.compile(r'^; ([a-z_0-9]+)\s*(?:#.*)?$')
DATA = re.compile(r'^&([0-9a-f]{4}) ((?:[0-9a-f]{2} )*[0-9a-f]{2})(?:\s*[;#].*)?$')
FILLER = re.compile(r'^;( {2,}|$)')      # the column-heading rows under a label

# Tables the port needs, with the BASIC label they get and what they are.
WANTED = [
    ('obstruction_patterns', 'ObstructionPatterns', '21 patterns of 8 column heights; &00 clear, &FF solid'),
    ('obstruction_pattern_low_addresses_table', 'ObstructionPatternOffsets', 'pattern set (low nibble of the y-offset table) and flips -> offset into the patterns'),
    ('tiles_obstruction_y_offsets_table', 'TileObstructionYOffsets', 'per tile type: high nibble unflipped, low nibble flipped, &10 fractions'),
    ('tiles_y_offset_and_pattern_table', 'TileYOffsetAndPattern', 'per tile type: high nibble y offset in &10 fractions, low nibble pattern set'),
    ('tiles_sprite_and_y_flip_table', 'TileSprites', 'per tile type: sprite (low 7 bits) and vertical flip (bit 7)'),
    ('tiles_palette_table', 'TilePalettes', 'per tile type: 0-6 a palette function, otherwise the palette byte'),
    ('feature_tiles_table', 'FeatureTiles', 'tile used when a placeholder type 0-8 has no tertiary object'),
    ('strata_palette_table', 'StrataPalettes', 'stone every 16 rows (7 entries), then earth every 32 rows'),
    ('bushes_palette_table', 'BushPalettes', 'four schemes chosen by position and flip'),
    ('particle_types_data', 'ParticleTypes', '11 types x 11 bytes: ttl, ttl rnd, speed, speed rnd, colour+flags, its rnd, flags, x rnd, y rnd, vx rnd, vy rnd'),
    ('npc_walking_types_maximum_angle_table', 'WalkMaxAngle', 'per walking type: steepest slope, &20 = 45 degrees'),
    ('npc_walking_types_maximum_acceleration_table', 'WalkMaxAccel', 'per walking type'),
    ('npc_walking_types_weight_table', 'WalkWeightShift', 'per walking type: speed reduced by 2 to this power'),
    ('npc_walking_types_turn_probability_table', 'WalkTurnProb', 'per walking type, out of 256'),
    ('npc_walking_types_jump_probability_table', 'WalkJumpProb', 'per walking type, out of 256'),
    ('object_types_sprite_table', 'ObjectSprites', 'per object type: default sprite'),
    ('object_types_palette_and_pickup_table', 'ObjectPalettes', 'per object type: palette (low 7 bits), bit 7 = can be picked up'),
    ('object_types_flags_table', 'ObjectFlags', 'per object type: bit 7 no collisions, bits 4-6 demotion policy, bit 3 from nest, bits 0-2 weight'),
    ('waterline_x_ranges_y_fraction', 'WaterYFrac', 'per water range: the fraction of the row the water starts at'),
    ('update_routine_addresses_high_table', 'UpdateRoutineFlags', 'per tile type (first 20) the high nibble says when its routine runs: &80 plotting, &40 obstruction, &20 collision, &10 events; the rest is code address'),
    ('object_type_ranges_table', 'ObjectRanges', 'first type of each of the ten ranges'),
    ('object_type_ranges_energy_table', 'ObjectRangeEnergy', 'maximum energy per range'),
    ('sprites_width_and_horizontal_flip_table', 'SpriteWidths', 'per sprite: (width - 1) << 4, bit 0 = drawn flipped horizontally'),
    ('sprites_height_and_vertical_flip_table', 'SpriteHeights', 'per sprite: (height - 1) << 3, bit 0 = drawn flipped vertically'),
    ('waterline_x_ranges_x_table', 'WaterRangeX', 'first column of each of the four waterline ranges'),
    ('waterline_x_ranges_y', 'WaterY', 'initial waterline row per range'),
    ('waterline_x_ranges_desired_y', 'WaterDesiredY', 'the row each waterline is moving toward'),
    ('water_velocities_table', 'WaterVelocities', 'per weight'),
    ('tile_tertiary_object_ranges_table', 'TertiaryRanges', 'first tertiary object of each tile type 0-8, and one past the last'),
    ('tertiary_objects_data_offset', 'TertiaryDataOffset', 'per tile type: where its objects data bytes start'),
    ('tertiary_objects_type_offset', 'TertiaryTypeOffset', 'per tile type: where its objects type bytes start'),
    ('tertiary_objects_x', 'TertiaryX', 'per tertiary object: the column it is keyed on'),
    ('tertiary_objects_tile_and_flip', 'TertiaryTile', 'per tertiary object: the tile it shows, with flips'),
    ('tertiary_objects_data', 'TertiaryData', 'live state: doors, switches, nests'),
    ('tertiary_objects_type', 'TertiaryType', 'the object type a nest, pipe or placeholder produces'),
    ('secondary_objects_x', 'SecondaryX', 'initial secondary list: column'),
    ('secondary_objects_y', 'SecondaryY', 'initial secondary list: row'),
    ('secondary_objects_type', 'SecondaryType', 'initial secondary list: object type'),
    ('secondary_objects_energy_and_x_y_fractions', 'SecondaryEnergyFrac', 'initial secondary list: energy nibble and position fractions'),
    ('objects_type', 'PrimaryType', 'initial primary list: object type'),
    ('objects_x', 'PrimaryX', 'initial primary list: column'),
    ('objects_y', 'PrimaryY', 'initial primary list: row'),
    ('distances_to_remove_objects_table', 'DemoteDistances', 'squares off screen before an object is demoted'),
    ('player_weights_when_holding_objects_table', 'PlayerWeights', 'player weight by the weight of what is held'),
    ('weapons_energy_cost', 'WeaponEnergyCost', 'jetpack, pistol, icer, blaster, plasma gun, protection suit'),
    ('player_weapons_energy_high', 'WeaponEnergyStart', 'initial energy of each'),
    ('transporter_destinations_x_table', 'TransporterDestX', 'per destination: column'),
    ('transporter_destinations_y_table', 'TransporterDestY', 'per destination: row'),
    ('transporter_beams_palette_table', 'TransporterBeamPalettes', 'palette per beam colour'),
    ('angle_calculation_half_quadrants_table', 'AngleHalfQuadrants', 'for calculate_angle_from_vector'),
    ('envelopes_table', 'SoundEnvelopes', 'stage and loop bytes for every sound'),
    ('frequency_ranges_limit_table', 'SoundFreqLimits', 'the four ranges of the frequency value'),
    ('frequency_ranges_base_table', 'SoundFreqBases', 'what each range subtracts before shifting'),
]


def read_tables(path):
    """Every '; name' label followed by data lines -> name: (address, bytes)."""
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    tables = {}
    i = 0
    while i < len(lines):
        m = LABEL.match(lines[i])
        if m:
            name = m.group(1)
            j = i + 1
            addr = None
            data = []
            while j < len(lines):
                d = DATA.match(lines[j])
                if d:
                    if addr is None:
                        addr = int(d.group(1), 16)
                    data += [int(b, 16) for b in d.group(2).split()]
                    j += 1
                    continue
                if FILLER.match(lines[j]):
                    j += 1
                    continue
                break
            if addr is not None and data and name not in tables:
                tables[name] = (addr, data)
        i += 1
    return tables


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, 'out')
    if '--out' in args:
        out_dir = args[args.index('--out') + 1]
    os.makedirs(out_dir, exist_ok=True)
    tables = read_tables(args[0])
    with open(os.path.join(out_dir, 'tables.json'), 'w') as f:
        json.dump({k: {'address': a, 'bytes': d} for k, (a, d) in tables.items()}, f)
    missing = []
    with open(os.path.join(out_dir, 'tables.bas'), 'w', newline='\n') as f:
        f.write("' tables.bas - Exile's tables, generated by gen_tables.py from the level7 listing.\n")
        f.write("' Do not edit: every table is read from the listing under its own label.\n")
        f.write("' Each block is a label for RESTORE followed by DATA; the comment gives the\n")
        f.write("' listing name, its address and the number of bytes.\n\n")
        for name, label, what in WANTED:
            if name not in tables:
                missing.append(name)
                continue
            addr, data = tables[name]
            f.write("' %s: %s at &%04X, %d bytes\n" % (label, name, addr, len(data)))
            f.write("' %s\n" % what)
            f.write("%s:\n" % label)
            for k in range(0, len(data), 16):
                f.write("Data " + ",".join(str(b) for b in data[k:k + 16]) + "\n")
            f.write("\n")
    print("%d tables in the listing, %d written to tables.bas" % (len(tables), len(WANTED) - len(missing)))
    for name in missing:
        print("  not found:", name)
    return 0


if __name__ == '__main__':
    sys.exit(main())
