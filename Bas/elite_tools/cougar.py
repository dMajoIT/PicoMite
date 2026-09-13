"""The Cougar: one extra blueprint, taken from the 6502 Second Processor source.

The cassette game has twelve ship designs.  The 6502 Second Processor version
has thirty, and one of them - the Cougar - is the rarest thing in Elite: about
one spawn in nine thousand.  Its blueprint is in the same beebasm format as the
cassette's, so blueprints.py's parser and polygon builder do all the work; this
only picks the one ship out and appends it to data/ships.bas.

Usage:  python cougar.py            (reads cache/6502sp-source.asm)
"""
import os, sys
import blueprints as bp

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, "cache", "6502sp-source.asm")
SHIPS = os.path.normpath(os.path.join(HERE, "..", "elite", "data", "ships.bas"))
NAME, DISP = "COUGAR", "Cougar"

ships = bp.parse_asm(ASM)
sh = bp.build(ships[NAME])
st = sh["stats"]
polys = sh["polys"]
nfv = sum(len(p[0]) for p in polys)

out = ["dat_%s:" % NAME.lower()]
out.append('DATA "%s", %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d' % (
    DISP, len(sh["verts"]), len(polys), nfv, len(sh["faces"]), sh["nv0"], st["canisters"],
    st["area"], st["bounty10"], st["visdist"], st["energy"], st["speed"], st["laser"],
    st["missiles"], st["gun_vertex"], st["explosion"]))
vs = sh["verts"]
for k in range(0, len(vs), 6):
    out.append("DATA " + ", ".join("%g,%g,%g" % tuple(v) for v in vs[k:k + 6]))
out.append("DATA " + ",".join(str(len(p[0])) for p in polys))
out.append("DATA " + ",".join(str(p[1]) for p in polys))
ns = sh["faces"]
for k in range(0, len(ns), 6):
    out.append("DATA " + ", ".join("%d,%d,%d" % tuple(n) for n in ns[k:k + 6]))
for p in polys:
    out.append("DATA " + ",".join(str(i) for i in p[0]))
out.append("")

print("Cougar: %d vertices (%d + %d sliver), %d edges, %d faces, %d polygons, max %d vertices a polygon"
      % (len(sh["verts"]), sh["nv0"], len(sh["verts"]) - sh["nv0"], len(sh["edges"]),
         len(sh["faces"]), len(polys), max(len(p[0]) for p in polys)))
print("stats:", st)
for m in sh["notes"]:
    print("  note:", m)

text = open(SHIPS, encoding="ascii").read()
if "dat_cougar:" in text:
    head = text[:text.index("dat_cougar:")]
else:
    head = text if text.endswith("\n") else text + "\n"
open(SHIPS, "w", newline="\n", encoding="ascii").write(head + "\n".join(out))
print("appended to", SHIPS)
