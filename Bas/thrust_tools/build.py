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

# in the order they are appended; sound.bas is SUBs, the rest is DATA
GENERATED = ['terrain.bas', 'objects.bas', 'sprites.bas', 'sound.bas']


def run(script):
    r = subprocess.run([PY, os.path.join(HERE, script)],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode:
        sys.exit(script + ' failed:\n' + r.stdout + r.stderr)
    return r


for s in ('gen_terrain.py', 'gen_objects.py', 'gen_sprites.py',
          'gen_sound.py'):
    run(s)

parts = [open(os.path.join(HERE, 'thrust_code.bas'),
              encoding='utf-8').read().rstrip('\n')]
for name in GENERATED:
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        sys.exit('missing generated fragment: ' + p)
    parts.append(open(p, encoding='utf-8').read().rstrip('\n'))

open(DEST, 'w', encoding='utf-8', newline='\n').write('\n\n'.join(parts) + '\n')
n = sum(1 for _ in open(DEST, encoding='utf-8'))
print('%s: %d lines, %d bytes' % (DEST, n, os.path.getsize(DEST)))
