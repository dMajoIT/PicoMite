"""Glue the code and the generated data into Bas/thrust.bas.

Straight to the shipped copy in Bas/ - a build left sitting in this
directory is a build nobody runs.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
OUT = os.path.join(HERE, 'out')
DEST = os.path.abspath(os.path.join(HERE, os.pardir, 'thrust.bas'))

GENERATORS = ['gen_terrain.py', 'gen_objects.py', 'gen_sprites.py',
              'gen_physics.py', 'gen_sound.py']

# appended after the program, in this order; sound.bas is SUBs, the rest DATA
GENERATED = ['terrain.bas', 'objects.bas', 'sprites.bas', 'physics.bas',
             'sound.bas']

# CONST executes where it stands, and everything above is appended after the
# program's END, so generated constants are spliced in at this marker instead.
MARKER = "' <<<GENERATED CONSTANTS>>>"


def run(script):
    r = subprocess.run([PY, os.path.join(HERE, script)],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode:
        sys.exit(script + ' failed:\n' + r.stdout + r.stderr)


def read(path):
    return open(path, encoding='utf-8').read().rstrip('\n')


for s in GENERATORS:
    run(s)

code = read(os.path.join(HERE, 'thrust_code.bas'))
if MARKER not in code:
    sys.exit('thrust_code.bas has lost its ' + MARKER + ' line')
code = code.replace(MARKER, read(os.path.join(OUT, 'consts.bas')), 1)

parts = [code]
for name in GENERATED:
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        sys.exit('missing generated fragment: ' + p)
    parts.append(read(p))

open(DEST, 'w', encoding='utf-8', newline='\n').write('\n\n'.join(parts) + '\n')
n = sum(1 for _ in open(DEST, encoding='utf-8'))
print('%s: %d lines, %d bytes' % (DEST, n, os.path.getsize(DEST)))
