#!/usr/bin/env python3
"""Pre-flight checks for a PicoMite release.

Run from anywhere:  python tools/release_preflight.py
Exits non-zero on the first failure, so it can gate the publish:

    python tools/release_preflight.py && gh release create ...

NEVER gate binary freshness on source-file mtimes in this repo: Dropbox
rewrites mtimes on sync without a byte changing, which condemns good
binaries.  Freshness is measured against COMMIT times (a sync cannot forge
one), with a separate porcelain check to catch sources edited but not yet
committed - which a commit-time check alone would miss.
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

VARIANTS = [
    "PicoMiteRP2040", "PicoMiteRP2040MIN", "PicoMiteRP2040USB",
    "PicoMiteRP2040VGA", "PicoMiteRP2040VGAUSB",
    "PicoMiteRP2350", "PicoMiteRP2350USB",
    "PicoMiteRP2350VGA", "PicoMiteRP2350VGAUSB",
    "PicoMiteRP2350BT", "PicoMiteRP2350BTH",
    "PicoMiteHDMI", "PicoMiteHDMIUSB", "PicoMiteHDMIWEB",
    "WebMiteRP2040", "WebMiteRP2350",
]

# Everything a firmware binary is built from.  Bas/, Testfiles/, docs/ and
# PDF/ are deliberately absent: changing a BASIC demo or the manual does not
# invalidate a uf2.
FIRMWARE_PATHS = [
    "*.c", "*.h", "core", "graphics", "input", "io", "misc", "net", "video",
    "bluetooth", "usb_host_files", "third_party_mod", "fonts", "cmake",
    "linker_overrides", "CMakeLists.txt", "buildpicomite.bat",
]

fails = []
def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + (" - " + detail if detail else ""))
    if not ok:
        fails.append(name)

def git(*args):
    return subprocess.run(["git"] + list(args), cwd=REPO, capture_output=True,
                          text=True).stdout.strip()

def commit_time(paths):
    out = git("log", "-1", "--format=%ct", "--", *paths)
    return int(out) if out else 0

# 1. the version the firmware actually declares
src = open(os.path.join(REPO, "Version.h"), encoding="utf-8", errors="replace").read()
m = re.search(r'#define\s+VERSION\s+"([^"]+)"', src)
if not m:
    sys.exit("Version.h has no #define VERSION")
version = m.group(1)
print("Version.h declares V%s\n" % version)
if len(sys.argv) > 1:
    check("requested version matches Version.h", sys.argv[1].lstrip("Vv") == version,
          "asked for %s" % sys.argv[1])

# 2. all 16 uf2 present, correctly named, and no leftovers from another version
uf2dir = os.path.join(REPO, "uf2")
present = sorted(f for f in os.listdir(uf2dir) if f.endswith(".uf2"))
wanted = sorted("%sV%s.uf2" % (v, version) for v in VARIANTS)
missing = [f for f in wanted if f not in present]
stale = [f for f in present if f not in wanted]
check("all 16 uf2 present for V%s" % version, not missing, "missing " + ", ".join(missing))
check("no uf2 left over from another version", not stale, "stale " + ", ".join(stale))

uf2_times = {f: os.path.getmtime(os.path.join(uf2dir, f)) for f in wanted
             if os.path.exists(os.path.join(uf2dir, f))}

# 3. every binary newer than the last change to the fit limits
t_cfg = commit_time(["configuration.h"])
older = [f for f, t in uf2_times.items() if t < t_cfg]
check("every uf2 newer than the last configuration.h commit", not older,
      ", ".join(older))

# 4. every binary newer than the last firmware-affecting commit.  Version.h
#    is excluded: the version bump is committed AFTER the build by
#    definition, and the uf2 FILENAMES already prove which VERSION string
#    was compiled in - buildpicomite.bat reads it from Version.h.
fw_paths = FIRMWARE_PATHS + [":(exclude)Version.h"]
t_fw = commit_time(fw_paths)
older = [f for f, t in uf2_times.items() if t < t_fw]
check("every uf2 newer than the last firmware commit (%s)" % git("log", "-1",
      "--format=%h", "--", *fw_paths), not older, ", ".join(older))

# 5. no firmware source edited but not committed (mtimes cannot see this)
dirty = git("status", "--porcelain", "--", *FIRMWARE_PATHS)
check("no uncommitted firmware source", not dirty, dirty.replace("\n", "; "))

# 6. the release manual exists and is the master, byte for byte
master = os.path.join(REPO, "PDF", "PicoMite_User_Manual.pdf")
copy = os.path.join(REPO, "PDF", "PicoMite_User_ManualV%s.pdf" % version)
if not os.path.exists(copy):
    check("versioned manual PDF present", False, os.path.basename(copy))
else:
    a, b = open(master, "rb").read(), open(copy, "rb").read()
    check("versioned manual PDF present", True)
    check("versioned manual PDF identical to the master", a == b,
          "%d vs %d bytes" % (len(a), len(b)))

# 7. the manual PDF is not older than the docx it is made from - by commit
#    time, again, not mtime
t_docx = commit_time(["docs/PicoMite_User_Manual.docx"])
t_pdf = commit_time(["PDF/PicoMite_User_Manual.pdf"])
docx_dirty = git("status", "--porcelain", "--", "docs/PicoMite_User_Manual.docx",
                 "PDF/PicoMite_User_Manual.pdf")
check("manual PDF regenerated since the docx last changed",
      t_pdf >= t_docx or bool(docx_dirty),
      "docx committed after the PDF")

# 8. everything the release ships is committed and pushed.  Work in progress
#    under Bas/ and Testfiles/ is NOT a release blocker - a half-finished
#    BASIC program does not reach a uf2 - and gh release --target main tags
#    the REMOTE head, so anything unpushed is simply excluded.  An unpushed
#    COMMIT is a blocker, because it would be excluded silently.
release_dirty = git("status", "--porcelain", "--",
                    ":(exclude)Bas", ":(exclude)Testfiles")
check("everything the release ships is committed", not release_dirty,
      release_dirty.replace(chr(10), "; "))
ahead = git("rev-list", "--count", "origin/main..HEAD")
check("HEAD pushed to origin/main", ahead == "0", "%s commit(s) unpushed" % ahead)

other = git("status", "--porcelain", "--", "Bas", "Testfiles")
if other:
    print("")
    print("  note: work in progress left out of the release:")
    for line in other.splitlines():
        print("        " + line.strip())

print()
if fails:
    print("PRE-FLIGHT FAILED: " + ", ".join(fails))
    sys.exit(1)
print("PRE-FLIGHT PASSED for V%s - 17 assets ready (16 uf2 + the manual PDF)" % version)
