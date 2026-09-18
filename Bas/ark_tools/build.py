"""Build Picanoid and lay out a package that can be copied anywhere.

The generated CONSTs execute, so they have to come before the main flow; DATA
is not executable and can sit anywhere.  Order is therefore:

    out/ark_data.bas     CONSTs and DATA blocks
    ArkBlankMap          the 13 x 16 map TILEMAP CREATE starts from
    <phase>_src.bas      the program

The program finds its own assets with MM.INFO(PATH), so the whole directory
can live anywhere on any drive - A:/picanoid, B:/games/picanoid, wherever.

Usage:
    python build.py                 package phase8 into Bas/picanoid/
    python build.py phase3          package an earlier phase instead
    python build.py phase8 out.bas  just write the .bas, no package
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
PKG = os.path.abspath(os.path.join(HERE, "..", "picanoid"))

ASSETS = ["pic_art.bmp"]

README = """Picanoid for the PicoMite
=========================

A bat-and-ball brick game for the PicoMite, in the style of the 1980s
originals.  The title screen and all of the sound are original work.

Copy this whole directory to the board, keeping the files together, and

    RUN "picanoid.bas"

The program finds pic_art.bmp beside itself with MM.INFO(PATH), so the
directory can sit anywhere on any drive.  That one image holds the bricks,
every sprite and the title screen, and it needs one image slot.

On a board with PSRAM (the PicoComputer 3 has it) running 6.03.02b11 or
later it goes into RAM slot 1 - image slot 4 - at every start, which takes
a few tens of milliseconds and leaves all three flash slots alone.  Without
PSRAM it is written into flash slot 1 the first time the game runs and
checked, not rewritten, after that; flash slots 2 and 3 are left alone
either way, so a LIBRARY and this game can live together.

Needs an RP2350 (the brick field is a TILEMAP), MODE 2, firmware 6.03.02b8
or later, and a mouse.

Player's guide: docs/Picanoid_Player_Guide.md in the PicoMite repository.
"""


def build_bas(phase):
    data = open(os.path.join(OUT, "ark_data.bas"), encoding="utf-8").read()
    src = open(os.path.join(HERE, phase + "_src.bas"), encoding="utf-8").read()
    vals = ["0"] * 208
    blank = ["ArkBlankMap:"] + ["DATA " + ",".join(vals[i:i + 16]) for i in range(0, 208, 16)]
    return data + "\n" + "\n".join(blank) + "\n\n" + src


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "phase8"
    text = build_bas(phase)

    if len(sys.argv) > 2:                       # plain .bas, no package
        dst = os.path.abspath(sys.argv[2])
        with open(dst, "w", encoding="utf-8", newline="\r\n") as f:
            f.write(text)
        print("%s -> %s  (%d lines)" % (phase, dst, text.count("\n") + 1))
        return

    os.makedirs(PKG, exist_ok=True)
    bas = os.path.join(PKG, "picanoid.bas")
    with open(bas, "w", encoding="utf-8", newline="\r\n") as f:
        f.write(text)
    with open(os.path.join(PKG, "README.txt"), "w", encoding="utf-8", newline="\r\n") as f:
        f.write(README)
    for a in ASSETS:
        shutil.copy(os.path.join(OUT, a), os.path.join(PKG, a))

    # prune anything left over from an earlier layout, so what is in the
    # directory is exactly what the game needs
    keep = set(ASSETS) | {"picanoid.bas", "README.txt"}
    for n in os.listdir(PKG):
        if n not in keep:
            os.remove(os.path.join(PKG, n))
            print("  removed stale %s" % n)

    print("package: %s" % PKG)
    total = 0
    for n in sorted(os.listdir(PKG)):
        sz = os.path.getsize(os.path.join(PKG, n))
        total += sz
        print("  %-18s %7d" % (n, sz))
    print("  %-18s %7d" % ("total", total))


if __name__ == "__main__":
    main()
