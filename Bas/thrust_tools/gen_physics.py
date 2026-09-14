"""The numbers the flight model is made of.

Two 32-entry tables, six gravity constants and six starting positions.  The
tables are the part that must be copied rather than recomputed: they are
deliberately elliptical, about 2.5 in Y against 1.25 in X, to compensate for
MODE 1's non-square pixels.  Substitute SIN and COS and the compensation is
thrown away and the ship stops feeling like Thrust.

  python gen_physics.py          emit the DATA fragment
  python gen_physics.py --show   print the tables as an ellipse, to check
"""
import sys

import thrustdata as td

# ship_input_thrust_calculate_force is tick-gated: gravity, thrust and drag
# run only on these six of every sixteen ticks.
ACTIVE_TICKS = [0x00, 0x03, 0x05, 0x08, 0x0B, 0x0D]
# and the tether torque skips two more of them
NO_TORQUE_TICKS = [0x03, 0x0B]


def q78(int_tbl, frac_tbl):
    """Q7.8 signed: the integer byte is signed, the fraction is not."""
    return [td.signed(i) + f / 256.0 for i, f in zip(int_tbl, frac_tbl)]


def angle_tables():
    y = q78(td.label('lookup_angle_to_y_INT'),
            td.label('lookup_angle_to_y_FRAC'))
    x = q78(td.label('lookup_angle_to_x_INT'),
            td.label('lookup_angle_to_x_FRAC'))
    if len(x) != 32 or len(y) != 32:
        raise SystemExit('angle tables are %d and %d entries, not 32'
                         % (len(x), len(y)))
    return x, y


def starts():
    """Checkpoint 0 of each level: where the ship and the camera begin.

    The reset tables are column-major - all the midpoint-Y high bytes, then
    all the low bytes, and so on - because the code steps between fields by
    adding the checkpoint count.  Field order is midpoint Y high, midpoint Y
    low, window X, window Y high, window Y low, midpoint X.
    """
    sizes = td.label('level_reset_data_sizes')
    out = []
    for lvl in range(td.NUM_LEVELS):
        d = td.label('level_%d_reset_data' % lvl)
        n = sizes[lvl]
        if len(d) != n * 6:
            raise SystemExit('level %d reset data is %d bytes, expected %d'
                             % (lvl, len(d), n * 6))
        f = [d[i * n] for i in range(6)]           # checkpoint 0 of each field
        # The original's positions are sprite plot origins; PLAYER_CENTRE_X
        # and _Y say the ship's middle is 4 columns and 5 scanlines further
        # on, which is also where this port's shipX,shipY sits.  Apply it
        # here and the ship starts exactly above the first fuel cell, which
        # is the whole reason a game begins with an empty tank.
        out.append({'midY': f[0] * 256 + f[1] + 5, 'winX': f[2],
                    'winY': f[3] * 256 + f[4], 'midX': f[5] + 4,
                    'checkpoints': n})
    return out


def data_lines():
    x, y = angle_tables()
    grav = td.label('level_gravity_FRAC_table')
    st = starts()
    out = td.bar('Flight model')
    out[2:2] = [
        "'  The 32 angle-to-force entries, as Q7.8 in the original: the X",
        "'  component reaches 1.25 and the Y component 2.5, an ellipse rather",
        "'  than a circle, because MODE 1's pixels are not square.  Copy them",
        "'  rather than computing SIN and COS, or that compensation is lost.",
        "'  Angle 0 points up, 8 right, 16 down, 24 left.",
        "'  Then per level: gravity per active tick, the ship's starting",
        "'  position and the camera's, in world units."]
    out.append('angdata:')
    for name, tbl in (('x', x), ('y', y)):
        out.append("' angle to %s" % name)
        for i in range(0, 32, 8):
            out.append('DATA ' + ', '.join('%8.5f' % v for v in tbl[i:i + 8]))
    out.append("' per level: gravity, ship x, ship y, camera x, camera y")
    out.append('lvldata:')
    for lvl in range(td.NUM_LEVELS):
        s = st[lvl]
        out.append('DATA %9.7f, %3d, %4d, %3d, %4d   '
                   % (grav[lvl] / 256.0, s['midX'], s['midY'], s['winX'],
                      s['winY'])
                   + "' level %d, %d checkpoint%s"
                   % (lvl, s['checkpoints'], '' if s['checkpoints'] == 1
                      else 's'))
    out += ["",
            "' The six ticks in sixteen on which gravity, thrust and drag run.",
            'tickdata:',
            'DATA ' + ', '.join(str(t) for t in ACTIVE_TICKS)]
    return out


def show():
    x, y = angle_tables()
    print('ang      x        y     |x|,|y| against 1.25, 2.5')
    for i in range(32):
        bar = ' ' * int(20 + x[i] * 12) + '*'
        print('%3d %8.4f %8.4f  %s' % (i, x[i], y[i], bar))
    print()
    print('X range %.3f to %.3f, Y range %.3f to %.3f'
          % (min(x), max(x), min(y), max(y)))
    print()
    for lvl, s in enumerate(starts()):
        print('level %d: ship at %d,%d  camera at %d,%d  %d checkpoints'
              % (lvl, s['midX'], s['midY'], s['winX'], s['winY'],
                 s['checkpoints']))


if __name__ == '__main__':
    if '--show' in sys.argv:
        show()
    else:
        td.emit(data_lines(), 'physics.bas')
        print('\n'.join(data_lines()))
