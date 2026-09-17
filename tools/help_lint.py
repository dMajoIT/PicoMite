"""Check a help.txt against what cmd_help() will actually do with it.

The reader here is a transcription of cmd_help() in core/Commands.c and
pattern_matching() in third_party_mod/ff.c, so "the linter found it" means the
firmware would trip over it too.

    python tools/help_lint.py docs/help.txt
    python tools/help_lint.py docs/help.txt --lookup "MATH*"

Checks:
  * every topic header is reachable by typing its own name at HELP
  * CRLF endings (the seek-back in cmd_help() assumes them)
  * no line >= 256 bytes (the reader's buffer, which it does not bound-check)
  * 7-bit ASCII only (tokenise() masks the input line with & 0x7f)
  * no trailing whitespace on a header, which would make it unmatchable
  * no '~' starting a body line, which would truncate the entry
  * no empty topics, no duplicate topic names
  * cross-reference stubs point at a topic that exists
"""
import argparse
import re
import sys

STRINGSIZE = 256


# --------------------------------------------------------------------------
# pattern_matching(), third_party_mod/ff.c:3182 - whole-string, case-folded
# --------------------------------------------------------------------------
def _up(c):
    return c.upper() if "a" <= c <= "z" else c


def pattern_matching(pat, nam, skip=0, inf=0):
    if skip:
        if len(nam) < skip:
            return 0
        nam = nam[skip:]
    if pat == "" and inf:
        return 1
    while True:
        pp, np = 0, 0
        nc = ""
        while True:
            if pp < len(pat) and pat[pp] in "?*":
                nm = nx = 0
                while pp < len(pat) and pat[pp] in "?*":
                    if pat[pp] == "?":
                        nm += 1
                    else:
                        nx = 1
                    pp += 1
                if pattern_matching(pat[pp:], nam[np:], nm, nx):
                    return 1
                nc = nam[np] if np < len(nam) else ""
                break
            pc = _up(pat[pp]) if pp < len(pat) else ""
            nc2 = _up(nam[np]) if np < len(nam) else ""
            pp += 1
            np += 1
            if pc != nc2:
                nc = nc2
                break
            if pc == "":
                return 1
        nam = nam[1:]
        if not (inf and nc):
            return 0


# --------------------------------------------------------------------------
# cmd_help(), core/Commands.c:3054
# --------------------------------------------------------------------------
def tokenise_help_arg(line):
    """What tokenise() hands cmd_help(): everything after 'HELP ', unquoted."""
    m = re.match(r"(?i)^\s*HELP\s(.*)$", line)
    if not m:
        return None
    arg = m.group(1)
    return arg.strip().strip('"')


def lookup(text, pattern):
    """Topics cmd_help() would print for this pattern, in file order."""
    hits = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].rstrip("\r")
        if line.startswith("~") and pattern_matching(pattern.lstrip(), line[1:]):
            body = []
            j = i + 1
            while j < len(lines):
                nxt = lines[j].rstrip("\r")
                if nxt.startswith("~"):
                    break
                body.append(nxt)
                j += 1
            hits.append((line[1:], body))
        i += 1
    return hits


# --------------------------------------------------------------------------
def lint(path):
    raw = open(path, "rb").read()
    problems = []
    warnings = []

    crlf = raw.count(b"\r\n")
    lf = raw.count(b"\n")
    if crlf != lf:
        problems.append(
            "%d of %d line endings are bare LF - cmd_help()'s seek-back "
            "assumes CRLF" % (lf - crlf, lf))

    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as e:
        problems.append("non-ASCII byte at offset %d (tokenise() masks with "
                        "& 0x7f)" % e.start)
        text = raw.decode("ascii", "replace")

    lines = text.split("\n")
    headers = []
    for n, line in enumerate(lines, 1):
        line = line.rstrip("\r")
        if len(line) >= STRINGSIZE:
            problems.append("line %d is %d bytes - the reader's buffer is %d "
                            "and is not bounds checked" % (n, len(line), STRINGSIZE))
        if line.startswith("~"):
            name = line[1:]
            if name != name.rstrip():
                problems.append("line %d: header '%s' has trailing whitespace, "
                                "so nothing will ever match it" % (n, name))
            if not name.strip():
                problems.append("line %d: empty header" % n)
            headers.append((n, name))

    seen = {}
    for n, name in headers:
        key = name.upper()
        if key in seen:
            warnings.append("topic '%s' appears twice (lines %d and %d)"
                            % (name, seen[key], n))
        else:
            seen[key] = n

    # every topic must be reachable by its own name, and must have a body
    unreachable, empty = [], []
    for n, name in headers:
        hits = lookup(text, name)
        if not any(h[0] == name for h in hits):
            unreachable.append(name)
        body = hits[0][1] if hits else []
        if not [b for b in body if b.strip()]:
            empty.append(name)
    for name in unreachable:
        problems.append("topic '%s' is not reachable by typing HELP %s" % (name, name))
    for name in empty[:20]:
        warnings.append("topic '%s' has an empty body" % name)

    # stubs must point somewhere real
    names = {h[1].upper() for h in headers}
    for n, name in headers:
        body = lookup(text, name)[0][1] if lookup(text, name) else []
        for b in body:
            m = re.match(r"^Described with the rest of its family:\s+HELP (.+)$", b)
            if m and m.group(1).strip().upper() not in names:
                warnings.append("topic '%s' points at HELP %s, which does not "
                                "exist" % (name, m.group(1).strip()))

    return headers, problems, warnings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", default="docs/help.txt")
    ap.add_argument("--lookup", help="show what HELP <this> would print")
    args = ap.parse_args()

    if args.lookup:
        text = open(args.file, "rb").read().decode("ascii", "replace")
        pat = tokenise_help_arg("HELP " + args.lookup) or args.lookup
        hits = lookup(text, pat)
        print("HELP %s  ->  %d topic(s)\n" % (args.lookup, len(hits)))
        for name, body in hits:
            print("~" + name)
            for b in body:
                print(b)
        return 0

    headers, problems, warnings = lint(args.file)
    print("%s: %d topics" % (args.file, len(headers)))
    for w in warnings[:40]:
        print("  warning: " + w)
    if len(warnings) > 40:
        print("  ... and %d more warnings" % (len(warnings) - 40))
    for p in problems[:40]:
        print("  ERROR  : " + p)
    if len(problems) > 40:
        print("  ... and %d more errors" % (len(problems) - 40))
    print("%d error(s), %d warning(s)" % (len(problems), len(warnings)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
