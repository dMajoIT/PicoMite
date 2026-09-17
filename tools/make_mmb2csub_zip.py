#!/usr/bin/env python3
"""
Build the mmb2csub distribution zip, and prove it is complete before writing it.

    python tools/make_mmb2csub_zip.py [--mmb2c PATH] [-o OUT.zip]

The proof is the point. The package is staged somewhere unrelated to the
firmware tree and mmb2csub is run from there - a full `--list`, which compiles
and links every routine in a program, so mmcsub.h, armcfgen.py and mmb2c.py
all have to be found - and then a real conversion. The staged files are also
scanned for any absolute path leading back to this tree, because that is how a
package passes its own test and still fails on somebody else's machine.

The compiler is deliberately NOT included: arm-none-eabi-gcc is a large
third-party download that most people building PicoMite firmware already have.
"""

import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(HERE)
TOOLS = os.path.join(FW, "user-tools")
NAME = "mmb2csub"

# mmb2c.py is a tool in its own right and is kept in one place rather than
# copied into every project that uses it, so it is looked for the same way
# mmb2csub.py looks for it.
MMB2C_CANDIDATES = [
    os.environ.get("MMB2C_PATH"),
    os.path.join(TOOLS, "mmb2c.py"),
    r"\\wsl.localhost\Ubuntu\home\peter\src\FUZIX\Applications\mmb2c\mmb2c.py",
    "/home/peter/src/FUZIX/Applications/mmb2c/mmb2c.py",
]

README = """mmb2csub - turn an MMBasic SUB or FUNCTION into a CSUB
=====================================================

Read docs/mmb2csub.pdf (or the same thing as docs/mmb2csub.md). Section 2 is
the setup; everything below is only the short version of it.

WHAT IS IN HERE
  user-tools/mmb2csub.py    the converter - this is what you run
  user-tools/mmcsub.h       the runtime the generated CSUB compiles against
  user-tools/armcfgen.py    turns the compiled object into a CSUB hex block
  user-tools/mmb2c.py       the MMBasic-to-C translator that does the
                            MMBasic-to-C half of the job
  user-tools/xsend.py       optional: sends a program to the board by XMODEM
  PicoCFunctions.h          the firmware's CSUB header
  docs/                     this tool's manual, and the one for writing a
                            CSUB by hand
  examples/                 two programs to try it on

WHAT IS NOT, AND YOU MUST INSTALL
  1. Python 3.6 or later.
  2. The Arm GNU toolchain - arm-none-eabi-gcc - on your PATH. This is the
     only large download, and if you have ever built the firmware you have it
     already.
  3. pyelftools:   pip install pyelftools
  4. pyserial, ONLY if you want xsend.py:   pip install pyserial

KEEP THE LAYOUT
  mmb2csub.py finds PicoCFunctions.h and mmcsub.h relative to its own
  location, so there is nothing to configure - but it does mean you should
  unpack the whole folder and leave user-tools/ where it is.

CHECK IT WORKS
  cd user-tools
  python mmb2csub.py ../examples/julia.bas --list

  That changes nothing. It compiles and links every routine in the program
  and reports what can be converted and what each would cost. A listing means
  the whole chain works.

THE BOARD NEEDS FIRMWARE 6.03.02b9 OR LATER
  Check with:  ? MM.VER     which must read 6.030209 or higher.

  Nothing on your PC can check this for you. A CSUB is built without knowing
  what it will run on, so on older firmware it does not fail to build - it
  calls a CallTable entry that does not exist yet, and the board crashes with
  no message. If a CSUB that built cleanly misbehaves from its very first
  call, check this first.
"""


def find_mmb2c(explicit):
    for c in ([explicit] if explicit else []) + MMB2C_CANDIDATES:
        if c and os.path.exists(c):
            return c
    sys.exit("error: cannot find mmb2c.py - pass --mmb2c PATH or set MMB2C_PATH")


def version():
    """The firmware version, so the archive is named after what it needs."""
    try:
        t = io.open(os.path.join(FW, "Version.h"), encoding="utf-8",
                    errors="ignore").read()
        return t.split('#define VERSION "')[1].split('"')[0]
    except Exception:
        return "unknown"


def stage(root, mmb2c):
    files = {
        "PicoCFunctions.h":       os.path.join(FW, "PicoCFunctions.h"),
        "user-tools/mmb2csub.py": os.path.join(TOOLS, "mmb2csub.py"),
        "user-tools/mmcsub.h":    os.path.join(TOOLS, "mmcsub.h"),
        "user-tools/armcfgen.py": os.path.join(TOOLS, "armcfgen.py"),
        "user-tools/xsend.py":    os.path.join(TOOLS, "xsend.py"),
        "user-tools/mmb2c.py":    mmb2c,
        "docs/mmb2csub.md":       os.path.join(FW, "docs", "mmb2csub.md"),
        "docs/mmb2csub.pdf":      os.path.join(FW, "PDF", "mmb2csub.pdf"),
        "docs/armcfgen.md":       os.path.join(FW, "docs", "armcfgen.md"),
        "docs/armcfgen.pdf":      os.path.join(FW, "PDF", "armcfgen.pdf"),
        "examples/julia.bas":     os.path.join(FW, "Bas", "julia.bas"),
        "examples/strtest.bas":   os.path.join(FW, "Bas", "strtest.bas"),
    }
    for rel, src in sorted(files.items()):
        if not os.path.exists(src):
            if rel.endswith(".pdf"):
                print("  note: %s not built - run docs/generate_%s_pdf.py"
                      % (os.path.basename(src),
                         os.path.basename(src)[:-4]))
                continue
            sys.exit("missing: " + src)
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    with open(os.path.join(root, "README.txt"), "w", newline="\r\n") as f:
        f.write(README)


def verify(root):
    tools = os.path.join(root, "user-tools")

    home = os.path.normcase(FW)
    for base, _, names in os.walk(root):
        for n in names:
            if n.endswith((".py", ".h", ".txt", ".md")):
                t = os.path.normcase(io.open(os.path.join(base, n), encoding="utf-8",
                                             errors="ignore").read())
                if home in t or home.replace(os.sep, "/") in t:
                    print("  FAIL: %s has an absolute path back to this tree" % n)
                    return False
    print("  no file refers back to the firmware tree")

    ex = os.path.join(root, "examples", "julia.bas")
    r = subprocess.run([sys.executable, os.path.join(tools, "mmb2csub.py"), ex, "--list"],
                       capture_output=True, text=True, cwd=tools)
    if "Convertible" not in r.stdout:
        print((r.stdout + r.stderr)[-1500:])
        return False
    print("  --list compiles and links every routine")

    probe = os.path.join(root, "probe.bas")
    shutil.copy2(ex, probe)
    r = subprocess.run([sys.executable, os.path.join(tools, "mmb2csub.py"),
                        probe, "plotjulia", "--lean"],
                       capture_output=True, text=True, cwd=tools)
    body = io.open(probe, encoding="utf-8", errors="ignore").read()
    ok = "CSUB" in body and "End CSUB" in body
    print("  a real conversion works" if ok else (r.stdout + r.stderr)[-1500:])
    for junk in (probe, probe + ".bak"):
        if os.path.exists(junk):
            os.remove(junk)
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--mmb2c", help="path to mmb2c.py")
    ap.add_argument("-o", "--out", help="output zip (default: alongside the tree)")
    args = ap.parse_args()

    mmb2c = find_mmb2c(args.mmb2c)
    out = args.out or os.path.join(FW, "%s-%s.zip" % (NAME, version()))

    tmp = tempfile.mkdtemp(prefix="mmb2csub-pkg-")
    try:
        root = os.path.join(tmp, NAME)
        stage(root, mmb2c)
        print("staged into a temporary tree; mmb2c.py from %s" % mmb2c)
        if not verify(root):
            sys.exit("\nthe staged package did not run - zip NOT written")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for base, dirs, names in os.walk(tmp):
                dirs[:] = [x for x in dirs if x != "__pycache__"]  # running it made one
                for n in sorted(names):
                    if n.endswith(".pyc"):
                        continue
                    full = os.path.join(base, n)
                    z.write(full, os.path.relpath(full, tmp).replace(os.sep, "/"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\nwrote %s (%d bytes)" % (out, os.path.getsize(out)))
    with zipfile.ZipFile(out) as z:
        for i in z.infolist():
            print("  %8d  %s" % (i.file_size, i.filename))


if __name__ == "__main__":
    main()
