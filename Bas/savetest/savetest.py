"""Characterisation test for SaveProgramToFlash.

SaveProgramToFlash writes a tokenised program to flash in three passes.  Pass 1
walks the source and tokenises it.  Passes 2 and 3 then scan back over what
pass 1 wrote - not the source - looking for CSUB and DefineFont blocks: pass 2
measures each blob so its size word can be back-filled, pass 3 rewinds the
flash pointer and writes them again with the sizes known.  Both scan bases, and
a bounds check inside the hex reader, are hardwired to flash_progmemory /
PROGSTART.  Parameterising those by region is what a LIBRARY LOAD command would
need, and it is a change to a function that SAVE, LOAD and the editor all
depend on.

So this records exactly what the function writes today, before anything is
touched.  For each route into program memory it captures:

  * the functional answers - ordinary BASIC, the font's metrics, and a CSUB
    whose result is wrong if its binary was mis-sized or mis-placed
  * the length of the tokenised program text
  * every CSUB/font blob that follows it, with the size word that was
    back-filled into each
  * a hash of all MAX_PROG_SIZE bytes of the region

Run it before the change and again after.  Every figure must match.

  python savetest.py                  run and print the signature
  python savetest.py --baseline       run and write baseline.txt
  python savetest.py --check          run and diff against baseline.txt

Set PC3_PORT to choose the board.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "elite_tools")))
import pc3

BASELINE = os.path.join(HERE, "baseline.txt")


def free_slot(b):
    """A flash slot that is not already in use.

    The snapshot needs a whole slot, and a board on a bench usually has
    something in one of them.  Read FLASH LIST and take the first that is
    free rather than assuming slot 1, which is how a test quietly destroys
    somebody's work.
    """
    out = b.cmd("FLASH LIST", 30)
    for n in (1, 2, 3):
        if re.search(r"Slot %d available" % n, out):
            return n
    raise SystemExit("no free flash slot for the snapshot:" + chr(10) + out)


def field(out, name):
    m = re.search(r"^%s\s+(.*)$" % re.escape(name), out, re.M)
    return " ".join(m.group(1).split()) if m else None


def snapshot(b, label, load, slot):
    """Put the fixture into program memory by one route, then measure it."""
    lines = ["[%s]" % label]

    load()
    out = b.cmd("RUN", 120)
    if "rror" in out:
        raise SystemExit("%s: fixture failed to run:\n%s" % (label, out))
    for k in ("basic", "fontw", "fonth", "csub1", "csub2"):
        lines.append("%-9s%s" % (k, field(out, k)))

    # A program cannot checksum the memory it is running from, so copy the
    # whole region into a flash slot and read that instead.
    b.cmd("FLASH ERASE %d" % slot, 60)
    b.cmd("FLASH SAVE %d" % slot, 60)
    sig = open(os.path.join(HERE, "sig.bas"), encoding="ascii").read()
    sig = sig.replace("FLASH ADDRESS 1", "FLASH ADDRESS %d" % slot)
    b.xmodem_send("A:/sig.bas", sig.encode("ascii"))
    b.cmd('LOAD "A:/sig.bas"', 120)
    out = b.cmd("RUN", 300)
    if "rror" in out:
        raise SystemExit("%s: signature failed:\n%s" % (label, out))
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("blob "):
            lines.append(" ".join(ln.split()))
    for k in ("head", "binbase", "blobs", "hash1", "hash2"):
        lines.append("%-9s%s" % (k, field(out, k)))
    b.cmd("FLASH ERASE %d" % slot, 60)
    return lines


def main():
    args = sys.argv[1:]
    fixture = open(os.path.join(HERE, "fixture.bas"), "rb").read()
    report = []
    b = pc3.PC3()
    try:
        b.attention()
        report.append("device   " + " ".join(b.cmd("PRINT MM.DEVICE$, MM.VER", 15).split()))
        b.cmd("LIBRARY DELETE", 60)
        slot = free_slot(b)
        print("using flash slot %d for the snapshot" % slot)

        # Route 1: LOAD from a file.  FileIO's loader -> SaveProgramToFlash.
        def by_load():
            b.xmodem_send("A:/fixture.bas", fixture)
            out = b.cmd('LOAD "A:/fixture.bas"', 180)
            if "rror" in out:
                raise SystemExit("LOAD failed: " + " ".join(out.split()))
        report += snapshot(b, "LOAD from file", by_load, slot)

        # Route 2: AUTOSAVE, which tokenises from the console instead.
        def by_autosave():
            b.upload(fixture.decode("ascii"))
        report += snapshot(b, "AUTOSAVE from console", by_autosave, slot)
    finally:
        b.close()

    text = "\n".join(report) + "\n"
    print(text)
    if "--baseline" in args:
        open(BASELINE, "w", newline="\n").write(text)
        print("wrote " + BASELINE)
    elif "--check" in args:
        if not os.path.exists(BASELINE):
            raise SystemExit("no baseline.txt - run with --baseline first")
        want = open(BASELINE, newline="").read().replace("\r\n", "\n")
        if want == text:
            print("IDENTICAL to baseline")
        else:
            import difflib
            print("DIFFERS from baseline:")
            for ln in difflib.unified_diff(want.splitlines(), text.splitlines(),
                                           "baseline", "now", lineterm=""):
                print("  " + ln)
            sys.exit(1)


if __name__ == "__main__":
    main()
