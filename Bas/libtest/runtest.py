"""Prove that a library plus a program gives twice the code space.

The PicoMite keeps BASIC in two separate flash areas of MAX_PROG_SIZE each:
program memory, and the library.  On this firmware (PicoMiteHDMIWEB)
MAX_PROG_SIZE is HEAP_MEMORY_SIZE, 144 KB, so the ceiling for one program is
144 KB - but a program with a library behind it can run 288 KB of BASIC.

This drives a real board and reports what it finds.  Nothing here is
simulated: every figure is read back off the device.

  python runtest.py             the correctness test
  python runtest.py --bulk      that, then fill both halves to prove the size
  python runtest.py --bulk-only

Set PC3_PORT to choose the board.
"""
import os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "elite_tools")))
import pc3

FAILED = []


def step(title):
    print()
    print("== " + title)


def check(name, got, want):
    ok = (got == want)
    print("   %-28s %-28s %s" % (name, repr(got), "ok" if ok else "WANTED " + repr(want)))
    if not ok:
        FAILED.append(name)
    return ok


def send_file(b, local, dev):
    data = open(local, "rb").read()
    b.xmodem_send(dev, data)
    return len(data)


def memory_report(b):
    """The MEMORY command's program and library lines, as (kb, percent)."""
    out = b.cmd("MEMORY", 20)
    prog = lib = None
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)K \(\s*(\d+)%\) Program", line)
        if m:
            prog = (int(m.group(1)), int(m.group(2)))
        m = re.match(r"\s*(\d+)K \(\s*(\d+)%\) Library", line)
        if m:
            lib = (int(m.group(1)), int(m.group(2)))
    return prog, lib, out


def load_file(b, dev):
    """LOAD, and refuse to carry on quietly if it did not fit.

    Program memory is MAX_PROG_SIZE, and a source file of very nearly that
    size does not fit once it is loaded - LOAD says "Not enough memory" and
    leaves program memory empty.  Left unchecked that turns into a puzzling
    failure several steps later, so it is caught here.
    """
    out = b.cmd('LOAD "%s"' % dev, 180)
    if "rror" in out:
        raise SystemExit("LOAD %s failed: %s" % (dev, " ".join(out.split())))
    return out


def install_library(b, path, dev):
    n = send_file(b, path, dev)
    load_file(b, dev)
    out = b.cmd("LIBRARY SAVE", 180)
    m = re.search(r"Library Saved (\d+) bytes", out)
    if not m:
        raise SystemExit("LIBRARY SAVE did not report a size:\n" + out)
    print("   %s (%d bytes of source) -> library, %s bytes saved" % (os.path.basename(path), n, m.group(1)))
    return int(m.group(1))


def load_and_run(b, path, dev, timeout=120):
    send_file(b, path, dev)
    load_file(b, dev)
    return b.cmd("RUN", timeout)


def field(out, name):
    m = re.search(r"^%s\s+(.*)$" % re.escape(name), out, re.M)
    return m.group(1).strip() if m else None


def correctness(b):
    step("clear anything left over")
    b.cmd("LIBRARY DELETE", 60)
    b.cmd("ON ERROR SKIP 1 : FLASH ERASE 1", 60)
    b.cmd("ON ERROR CLEAR", 10)
    print(b.cmd("FLASH LIST", 20))

    step("install the library")
    libsize = install_library(b, os.path.join(HERE, "lib.bas"), "A:/lib.bas")
    prog, lib, out = memory_report(b)
    print(out)
    check("program memory empty", prog[0] if prog else None, 0)
    if lib is None:
        FAILED.append("library reported by MEMORY")

    step("run the program that uses it")
    out = load_and_run(b, os.path.join(HERE, "main.bas"), "A:/main.bas")
    print(out)
    check("tag", field(out, "tag"), "libtest")
    check("version", field(out, "version"), "103")
    check("ready (library top level ran)", field(out, "ready"), "1")
    check("squares (library DIM + array)", field(out, "squares"), "9 144")
    check("names (library DATA via library)", field(out, "names"), "Cobra Viper Mamba")
    check("add (library FUNCTION)", field(out, "add"), "5")
    check("calls (library global)", field(out, "calls"), "11")
    check("total (RESTORE inside library)", field(out, "total"), "55")
    check("restore (library DATA from program)", field(out, "restore"), "100 200 300")
    check("callback (library calls program SUB)", field(out, "callback"), "hello")
    # 103 + 1 + 144 + 5 + 12 + 55 + 100 + 200 + 300, evaluated left to right
    # (LibAdd bumps libCalls to 12 before libCalls is read)
    check("checksum", field(out, "checksum"), "920")
    first = out

    step("snapshot the program with FLASH SAVE, wipe it, restore it")
    b.cmd("FLASH SAVE 1", 60)
    print(b.cmd("FLASH LIST", 20))
    b.cmd("NEW", 30)
    prog, lib2, out2 = memory_report(b)
    check("program gone after NEW", prog[0] if prog else None, 0)
    check("library survives NEW", lib2, lib)
    b.cmd("FLASH LOAD 1", 60)
    out = b.cmd("RUN", 120)
    print(out)
    check("same output after FLASH LOAD", field(out, "checksum"), field(first, "checksum"))

    step("what the library costs elsewhere")
    out = b.cmd("FLASH LIST", 20)
    print(out)
    check("slot 3 is the library", "Slot 3 in use: Library" in out, True)
    out = b.cmd("FLASH SAVE 3", 30)
    print("   FLASH SAVE 3 ->", " ".join(out.split()) or "(accepted!)")
    check("slot 3 refused while a library exists", "rror" in out, True)


def bulk(b, kb):
    step("fill both halves (%d KB of BASIC each)" % kb)
    import gen_bulk
    biglib = os.path.join(HERE, "biglib.bas")
    bigmain = os.path.join(HERE, "bigmain.bas")
    nsub, ndata = gen_bulk.write_library(biglib, kb * 1024)
    gen_bulk.write_program(bigmain, kb * 1024, nsub, ndata)
    for p in (biglib, bigmain):
        if os.path.getsize(p) > 140 * 1024:
            raise SystemExit("%s is %d bytes: LOAD needs a little more room than the "
                             "file itself, so a source much over 140 KB will not go in"
                             % (os.path.basename(p), os.path.getsize(p)))
    print("   library  %d subs, %d DATA blocks, %d bytes of source" % (nsub, ndata, os.path.getsize(biglib)))
    print("   program  %d bytes of source" % os.path.getsize(bigmain))

    b.cmd("LIBRARY DELETE", 60)
    b.cmd("ON ERROR SKIP 1 : FLASH ERASE 1", 60)
    b.cmd("ON ERROR CLEAR", 10)
    install_library(b, biglib, "A:/biglib.bas")
    out = load_and_run(b, bigmain, "A:/bigmain.bas", 300)
    print(out)
    prog, lib, mem = memory_report(b)
    print(mem)
    if prog and lib:
        print("   program %d K + library %d K = %d K of BASIC in one program"
              % (prog[0], lib[0], prog[0] + lib[0]))
        check("total beats one program's ceiling", prog[0] + lib[0] > 144, True)
    check("bulk checksum", field(out, "checksum"), field(out, "expected"))


def main():
    args = sys.argv[1:]
    b = pc3.PC3()
    try:
        b.attention()
        print(b.cmd("PRINT MM.DEVICE$, MM.VER", 15))
        if "--bulk-only" not in args:
            correctness(b)
        if "--bulk" in args or "--bulk-only" in args:
            kb = 110
            for a in args:
                if a.startswith("--kb="):
                    kb = int(a[5:])
            bulk(b, kb)
    finally:
        b.close()
    print()
    if FAILED:
        print("FAILED: " + ", ".join(FAILED))
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
