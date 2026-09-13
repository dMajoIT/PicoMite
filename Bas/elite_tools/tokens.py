"""Extract the disc version's extended token table.

The cassette game's data screen stops at the planet's radius.  The disc version
adds a paragraph - "Lave is most famous for its vast rain forests and the Lave
tree grub" - built by expanding a token from a table of 256, where some tokens
choose at random between five alternatives and the random number generator has
been seeded from the system's own s1 and s2, so a given system always gets the
same description.

The table is TKN1 in the 6502 Second Processor source, and the encoding is
carried by the macros themselves rather than by the bytes they emit, so nothing
here has to decode 6502 data:

    ECHR 'x'        one literal character
    ETWO 'a','b'    a two-letter token - the two letters, literally
    ETOK n          print extended token n
    TOKN n          the same
    ERND n          print one of the five tokens the n'th random group names
    EJMP n          a control code: case, newline, the planet's name, and so on
    EQUB VE         end of this token

What comes out is one string per token with the literals in place and markers
left for the rest, so the PicoMite only has to walk a string:

    [n]     print token n
    [n?]    print a random choice from group n
    {n}     control code n

Usage:  python tokens.py            writes ../elite/data/tokens.bas
"""
import io, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, "cache", "6502sp-source.asm")
OUT = os.path.normpath(os.path.join(HERE, "..", "elite", "data", "tokens.bas"))
TOKLEN = 160   # must match the LENGTH of tk$() in 00_main.bas

# The two words the original spells wrong, and what they are corrected to.
# This is the only place the token table is not reproduced as it stands, and
# it is a deliberate departure: the briefings are there to be read.  Each is
# a plain substring of the assembled token, with the markers around it left
# alone - "EQUIP[196]" is EQUIP followed by token 196, which is "ED ", and
# 196 is used by seven other tokens so the extra P goes in here instead.
TYPOS = [
    (10, "EQUIP[196]", "EQUIPP[196]"),        # EQUIPED -> EQUIPPED
    (222, "INTELLEGENCE", "INTELLIGENCE"),
]
BS = chr(92)
QT = chr(39)


def parse(path):
    src = io.open(path, encoding="latin-1").read().splitlines()
    start = next(i for i, l in enumerate(src) if l.strip() == ".TKN1")
    end = next(i for i, l in enumerate(src)
               if i > start and re.match("^[.][A-Z]", l.strip()) and "TKN1" not in l)
    tokens, cur = [], []
    for line in src[start + 1:end]:
        c = line.split(BS)[0].strip()
        if not c:
            continue
        op = c.split()[0]
        arg = c[len(op):].strip()
        if op == "EQUB" and arg == "VE":
            tokens.append("".join(cur))
            cur = []
        elif op == "ECHR":
            m = re.match(r"^" + chr(39) + r"(.)" + chr(39) + r"$", arg)
            if not m:
                raise SystemExit("odd ECHR: " + c)
            cur.append(m.group(1))
        elif op == "ETWO":
            m = re.match("^" + chr(39) + "(.)" + chr(39) + "[ ]*,[ ]*" + chr(39) + "(.)" + chr(39) + "$", arg)
            if not m:
                raise SystemExit("odd ETWO: " + c)
            cur.append(m.group(1) + m.group(2))
        elif op in ("ETOK", "TOKN"):
            cur.append("[" + arg + "]")
        elif op == "ERND":
            cur.append("[" + arg + "?]")
        elif op == "EJMP":
            cur.append("{" + arg + "}")
        else:
            raise SystemExit("unknown directive: " + c)
    return tokens



# --- the standard token table, for the three tokens the briefings borrow
#
# A mission briefing switches to the standard table for a couple of phrases -
# "{6}[117]{5}" is MILITARY  LASER - and that table is a different one with a
# different encoding.  Rather than carry all 147 of them for three phrases,
# the three are expanded to plain text here and shipped as literals.
#
# Where the source builds different text for different releases, the first
# branch is taken, which is the Second Processor's own.

def standard(path):
    """QQ18, the standard token table, as lists of characters and [n] refs."""
    src = io.open(path, encoding="latin-1").read().splitlines()
    start = next(i for i, l in enumerate(src) if l.strip() == ".QQ18")
    end = next(i for i, l in enumerate(src)
               if i > start and re.match("^[.][A-Z]", l.strip()))
    toks, cur, skip = [], [], 0
    for line in src[start + 1:end]:
        c = line.split(BS)[0].strip()
        if not c:
            continue
        op = c.split()[0]
        if op == "IF":
            skip = 0
            continue
        if op in ("ELIF", "ELSE"):
            skip = 1
            continue
        if op == "ENDIF":
            skip = 0
            continue
        if skip:
            continue
        arg = c[len(op):].strip()
        if op == "EQUB" and arg == "0":
            toks.append(cur)
            cur = []
        elif op == "CHAR":
            cur.append(re.match("^" + QT + "(.)" + QT + "$", arg).group(1))
        elif op == "TWOK":
            m = re.match("^" + QT + "(.)" + QT + r"\s*,\s*" + QT + "(.)" + QT + "$", arg)
            cur.append(m.group(1) + m.group(2))
        elif op == "RTOK":
            cur.append(int(arg))
        elif op in ("CONT", "EQUB"):
            pass                      # a newline, or padding past the last token
        else:
            raise SystemExit("unknown QQ18 directive: " + c)
    return toks


def std_text(toks, n, depth=0):
    if depth > 8:
        return ""
    return "".join(std_text(toks, p, depth + 1) if isinstance(p, int) else p
                   for p in toks[n])


def std_wanted(tokens):
    """Which standard tokens the extended ones ask for, in {6}..{5} regions."""
    pat = re.compile(re.escape("{6}") + "(.*?)" + re.escape("{5}"), re.S)
    want = set()
    for t in tokens:
        for m in pat.finditer(t):
            for r in re.findall(r"\[(\d+)\]", m.group(1)):
                want.add(int(r))
    return sorted(want)


def atoms(t):
    """A token as indivisible pieces: a [n] or {n} marker, or one character."""
    out, i = [], 0
    while i < len(t):
        if t[i] in "[{":
            j = t.index("]" if t[i] == "[" else "}", i)
            out.append(t[i:j + 1])
            i = j + 1
        else:
            out.append(t[i])
            i += 1
    return out


def split_token(t, limit):
    """Break a token into parts of at most limit characters, never inside a
    marker.  The parts are walked one after another, so joining them back up
    gives the token unchanged."""
    parts, cur = [], ""
    for a in atoms(t):
        if len(cur) + len(a) > limit:
            parts.append(cur)
            cur = ""
        cur += a
    parts.append(cur)
    assert "".join(parts) == t
    return parts


def groups(path):
    """MTIN: the base token each of the 38 random groups picks its five from."""
    src = io.open(path, encoding="latin-1").read().splitlines()
    start = next(i for i, l in enumerate(src) if l.strip() == ".MTIN")
    out = []
    for line in src[start + 1:]:
        c = line.split(BS)[0].strip()
        if not c:
            continue
        if not c.startswith("EQUB"):
            break
        out.append(int(c.split()[1]))
    return out


def digrams(path, n=32):
    """The two-letter tokens control code 18 makes its alien words out of.

    It reads from TKN2 + 2, which skips the newline pair at the start, and the
    offset it picks is an even number 0 to 62 - so only the first 32 pairs can
    ever come up, and the QQ16 table the source mentions is never reached."""
    src = io.open(path, encoding="latin-1").read().splitlines()
    i = next(k for k, l in enumerate(src) if l.strip() == ".TKN2")
    out = []
    for l in src[i + 1:i + 120]:
        out += re.findall("EQUS " + chr(34) + "(..)" + chr(34), l)
        if len(out) >= n:
            break
    return out[:n]


def basic_quote(t):
    """MMBasic has no escape for a quote inside a string literal, so a token
    containing one is split and rejoined with CHR$(34)."""
    parts = t.split(chr(34))
    lit = (chr(34) + ' + CHR$(34) + ' + chr(34)).join(parts)
    return chr(34) + lit + chr(34)


def main():
    tokens = parse(ASM)
    for n, wrong, right in TYPOS:
        if wrong not in tokens[n]:
            raise SystemExit("token %d no longer contains %r - has the source "
                             "changed?" % (n, wrong))
        tokens[n] = tokens[n].replace(wrong, right)
        print("  corrected token %d: %s -> %s" % (n, wrong, right))
    mtin = groups(ASM)
    print("%d tokens, %d random groups" % (len(tokens), len(mtin)))
    for n in (5, 16, 53, 96):
        print("  token %3d %s" % (n, repr(tokens[n])))

    out = ["' The disc version's extended token table, generated by",
           "' elite_tools/tokens.py from the 6502 Second Processor source.",
           "' Do not edit: regenerate it.",
           "'",
           "'   [n]   print token n        [n?]  a random one of group n",
           "'   {n}   control code n",
           "'",
           "' Token 5 is the whole of a system description:",
           "'   " + tokens[5],
           "",
           "dat_tokens:"]
    # An MMBasic string array element is whatever LENGTH says, and the ceiling
    # is 255 characters, so the four longest tokens do not fit in one.  All
    # four are mission briefings; each is split into parts below and the
    # expander walks them one after another.  Their entry here is left empty.
    long = [(i, split_token(t, TOKLEN)) for i, t in enumerate(tokens)
            if len(t) > TOKLEN]
    longset = set(i for i, _ in long)
    for i, t in enumerate(tokens):
        out.append("DATA " + basic_quote("" if i in longset else t))
    out.append("")

    out.append("' The tokens too long to hold in one string - the mission")
    out.append("' briefings.  Each is its number, how many parts it is in, and")
    out.append("' then the parts, which join back up into the whole token.")
    out.append("dat_longtok:")
    for i, parts in long:
        out.append("DATA %d,%d" % (i, len(parts)))
        for p in parts:
            out.append("DATA " + basic_quote(p))
    out.append("")

    # The briefings borrow a few phrases from the standard token table, which
    # is a different table with a different encoding.  Three of them are worth
    # carrying; all 147 are not.
    std = standard(ASM)
    wanted = std_wanted(tokens)
    out.append("' The standard tokens the briefings borrow, expanded here")
    out.append("' because the standard table is not otherwise carried.")
    out.append("dat_stdtok:")
    for n in wanted:
        out.append("DATA %d,%s" % (n, basic_quote(std_text(std, n))))
    out.append("")

    print("  long tokens: " + ", ".join("%d in %d parts" % (i, len(p)) for i, p in long))
    print("  00_main.bas needs NLONG >= %d, NLPART >= %d, NSTD = %d"
          % (len(long), sum(len(p) for _, p in long), len(wanted)))
    for n in wanted:
        print("  standard token %3d %r" % (n, std_text(std, n)))
    out.append("' The two-letter tokens control code 18 builds alien words from.")
    out.append("dat_digrams:")
    dg = digrams(ASM)
    for k in range(0, len(dg), 16):
        out.append("DATA " + ",".join(chr(34) + d + chr(34) for d in dg[k:k + 16]))
    out.append("")
    out.append("' MTIN: the base token each random group chooses its five from.")
    out.append("dat_rndgroups:")
    for k in range(0, len(mtin), 16):
        out.append("DATA " + ",".join(str(v) for v in mtin[k:k + 16]))
    out.append("")
    text = chr(10).join(out)
    open(OUT, "w", newline=chr(10), encoding="ascii").write(text)
    print("wrote %s, %d bytes" % (OUT, len(text)))
    print("longest token kept: %d characters (tk$() needs LENGTH %d)"
          % (max(len(t) for t in tokens if len(t) <= TOKLEN), TOKLEN))


if __name__ == "__main__":
    main()
