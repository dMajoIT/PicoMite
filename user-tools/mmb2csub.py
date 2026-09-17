#!/usr/bin/env python3
"""mmb2csub.py - turn one MMBasic SUB into a PicoMite CSUB, in one command.

    python mmb2csub.py prog.bas --sub PlotJulia [-o out.txt] [--keep-c]

It drives the Fuzix MMBasic->C transpiler (mmb2c.py) to get C for the chosen
routine, wraps it in a CSUB entry shim, and runs armcfgen.py to produce the
`CSUB name ... End CSUB` block.

Why it is this small
--------------------
Two things do most of the work, and neither is in this file:

  * mmb2c already emits a SUB as `void f_name(MMFLOAT *p_a, MMINTEGER *p_b)` -
    one pointer per by-reference parameter, which IS the CSUB calling
    convention.  The shim below only has to cast the interpreter's void*.

  * mmcsub.h defines every runtime helper the generator may name (mm_*) and
    every arithmetic helper the compiler may emit (__aeabi_*), each forwarding
    to a firmware CallTable vector.  So anything unsupported is a COMPILE
    ERROR that names itself, and the scope check needs no hand-maintained list
    of supported statements.  A clean compile is the proof.

Scope (phase 1)
---------------
SUBs and numeric FUNCTIONs whose parameters are numeric scalars or numeric
arrays.  Everything else is refused here with a reason; everything subtly
unsupported is refused by the compiler.  Both refusals are better than a wrong
CSUB, which on a board is a hard fault with no line number.

FUNCTIONs need no special machinery, because MMBasic passes every argument by
reference: the CSUB takes the result as an extra leading out-parameter, the
generated C function is used exactly as mmb2c emitted it, and a three-line
BASIC wrapper keeps the original name so call sites do not change.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIRMWARE = os.path.dirname(HERE)          # PicoCFunctions.h lives one up
ARMCFGEN = os.path.join(HERE, "armcfgen.py")

# Where mmb2c.py may be found, in order.  Keeping the FUZIX tree canonical
# rather than vendoring a copy: this is a driver, not a fork.
MMB2C_CANDIDATES = [
    os.environ.get("MMB2C_PATH"),
    os.path.join(HERE, "mmb2c.py"),
    r"\\wsl.localhost\Ubuntu\home\peter\src\FUZIX\Applications\mmb2c\mmb2c.py",
    "/home/peter/src/FUZIX/Applications/mmb2c/mmb2c.py",
]


def load_mmb2c(explicit=None):
    """Import mmb2c.py from wherever it is and return the module."""
    import importlib.util
    for cand in ([explicit] if explicit else []) + MMB2C_CANDIDATES:
        if cand and os.path.exists(cand):
            spec = importlib.util.spec_from_file_location("mmb2c", cand)
            mod = importlib.util.module_from_spec(spec)
            sys.modules["mmb2c"] = mod
            spec.loader.exec_module(mod)
            mod.__mmb2csub_path = cand
            return mod
    sys.exit("error: cannot find mmb2c.py - pass --mmb2c PATH or set MMB2C_PATH\n"
             "  looked in: " + ", ".join(c for c in MMB2C_CANDIDATES if c))


# ---------------------------------------------------------------- convert

def convert_program(mmb2c, path):
    """Run mmb2c's pipeline over the whole program and return the Conv.

    The WHOLE program, not just the chosen SUB, so that CONSTs, DIMs and the
    types of globals resolve exactly as they do for the real interpreter.
    lenient=True means trouble elsewhere in the program is commented out and
    recorded rather than stopping us - only the chosen routine has to be clean.
    """
    lines = []
    with open(path, "r") as f:
        for ln in f:
            if "\0" in ln:
                ln = ln.split("\0", 1)[0]
                if ln:
                    lines.append(ln)
                break
            lines.append(ln)

    conv = mmb2c.Conv(lines, path)
    conv.lenient = True
    conv.pass_fonts()
    conv.pass_routine_names()
    conv.pass_types()
    conv.pass_declarations()
    conv.walk("scan")
    consts = {}
    for nm in conv.globals:
        if conv.globals[nm].is_const:
            consts[nm] = conv.globals[nm].acc
    for nm in consts:
        conv.globals[nm].acc = mmb2c.cconst(nm)
    mmb2c._heap_fixup(conv)
    mmb2c._local_heap_fixup(conv)
    # A program that uses ON ERROR anywhere makes mmb2c wrap EVERY routine in
    # __mm_e[] checks, so a SUB gets error-trapping code it has nothing to do
    # with. None of it can work in a CSUB - the interpreter's error machinery
    # is not reachable from inside one - so it is suppressed here, and any
    # routine that uses ON ERROR itself is refused by check_scope instead.
    # Setting the flag is not enough: do_on_error sets it again as it emits
    # each ON ERROR statement, so every routine after the first one would be
    # wrapped anyway. Pin it false for the emit pass instead. (A data
    # descriptor on the class beats the instance attribute, and Conv has no
    # __slots__, so this is the least invasive way to say "not for this run".)
    # Three flags, not one: uses_onerror gates the routine entry/exit guards,
    # while checks_on() - which gates the "evaluate to a temporary, store only
    # if nothing raised" form and the checked mm_fdiv - reads onerror_global
    # and err_window instead.
    _off = property(lambda s: False, lambda s, v: None)
    _zero = property(lambda s: 0, lambda s, v: None)
    conv.__class__ = type("ConvNoOnError", (conv.__class__,),
                          {"uses_onerror": _off, "onerror_global": _off,
                           "err_window": _zero})
    conv.tmpn = 0
    conv.out_main = []
    conv.out_body = []
    conv.walk("emit")
    for nm in consts:
        conv.globals[nm].acc = consts[nm]
    return conv


def slice_function(conv, cname):
    """Pull one function's text out of conv.out_body, brace-balanced."""
    body = conv.out_body
    start = None
    for i, ln in enumerate(body):
        if re.match(r"^[A-Za-z_].*\b" + re.escape(cname) + r"\s*\(", ln) and ln.rstrip().endswith("{"):
            start = i
            break
    if start is None:
        return None
    depth = 0
    for i in range(start, len(body)):
        depth += body[i].count("{") - body[i].count("}")
        if depth == 0:
            return "\n".join(body[start:i + 1])
    return None


# ---------------------------------------------------------------- checks

def uses_on_error(conv, routine):
    """Does this routine's own source use ON ERROR?

    convert_program suppresses the program-wide error-trapping code, which is
    right when the routine merely lives in a program that traps elsewhere and
    wrong if the routine traps itself - so that case is refused rather than
    silently given different semantics.
    """
    depth = 0
    for ln in conv.lines[max(routine.line - 1, 0):]:
        u = ln.upper()
        if "ON ERROR" in u:
            return True
        if "SUB " in u or "FUNCTION " in u:
            depth += 1
        if "END SUB" in u or "END FUNCTION" in u:
            depth -= 1
            if depth <= 0:
                break
    return False


def check_scope(conv, routine, name):
    """Refuse what phase 1 knowingly cannot do.  The compiler catches the rest."""
    bad = []
    if uses_on_error(conv, routine):
        bad.append("%s uses ON ERROR; a CSUB cannot reach the interpreter's "
                   "error handling" % name)
    if routine.is_func and routine.ty == "s":
        bad.append("%s is a string FUNCTION; strings are phase 2" % name)
    for p in routine.params:
        if p.stype is not None:
            bad.append("parameter '%s' is a user TYPE; not supported yet" % p.name)
        elif getattr(p, "ty", None) == "s":
            bad.append("parameter '%s' is a string; strings are phase 2" % p.name)
        elif not p.is_array and not p.byref:
            # mmb2c marks a by-value parameter; the interpreter always passes a
            # pointer, so a by-value one would read the pointer as the value.
            bad.append("parameter '%s' is passed by value; a CSUB receives a "
                       "pointer for every argument" % p.name)
    n = len(routine.params) + sum(1 for p in routine.params if p.is_array)
    if n > 16:
        bad.append("%d arguments needed (params plus array bounds); the limit is "
                   "MAX_CSUB_ARGS (16 on RP2350, 10 on RP2040)" % n)
    return bad


# ---------------------------------------------------------------- emit

# MMBasic type suffixes: the generated wrapper is real BASIC and must declare
# its own types, whatever OPTION DEFAULT is where it gets pasted.
SFX = {"f": lambda nm, arr: nm + "!" + ("()" if arr else ""),
       "i": lambda nm, arr: nm + "%" + ("()" if arr else ""),
       "s": lambda nm, arr: nm + "$" + ("()" if arr else "")}


def globals_touched(conv, routine):
    """The globals this routine reaches, in a stable order.

    mmb2c records these itself while scanning (Routine.gtouch, which is what
    its report's "Globals reached from inside a SUB" section is built from),
    so this is reading its answer rather than parsing the generated C.
    CONSTs are excluded - they become #defines and need nothing passed.
    """
    out = []
    for nm in sorted(routine.gtouch):
        s = conv.globals.get(nm)
        if s is None or s.is_const:
            continue
        out.append((nm, s))
    return out


def inject_params(cbody, extra):
    """Add parameters to the generated function's signature.

    The body is mmb2c's output untouched; only its first line changes. A
    routine that takes nothing is emitted as `f_name(void)`, so the `void`
    has to give way rather than be appended to.
    """
    if not extra:
        return cbody
    head, rest = cbody.split("\n", 1)
    i = head.rindex(")")
    inner = head[head.index("(") + 1:i].strip()
    if inner == "void" or inner == "":
        new = ", ".join(extra)
    else:
        new = inner + ", " + ", ".join(extra)
    return head[:head.index("(") + 1] + new + head[i:] + "\n" + rest


def bounds_used(cbody, p):
    """Does the routine actually read this array parameter's bounds?

    mmb2c always gives an array parameter a companion __b_ argument because
    BOUND() inside the routine would need it.  Most kernels never call BOUND(),
    and every argument we do not pass is one more the caller can spend - which
    matters, because MAX_CSUB_ARGS is 10 on the RP2040.  So pass NULL when the
    generated code never mentions it.
    """
    # skip the first line: that is the signature, which always names it
    body = cbody.split("\n", 1)[1] if "\n" in cbody else ""
    return ("__b_" + p.name.replace(".", "__")) in body


def entry_shim(conv, routine, cname, entry, cbody):
    """The CSUB entry: cast the interpreter's void* and call the real function.

    Argument order is the parameter order, with an array's bound argument
    following it when the routine reads bounds, matching mmb2c's signature().
    """
    CT = {"f": "MMFLOAT", "i": "MMINTEGER", "s": "char"}
    args, decl, slot = [], [], 0
    sfx = lambda nm, arr, ty: nm + {"f": "!", "i": "%", "s": "$"}[ty] + ("()" if arr else "")
    passed = []          # what the BASIC caller must supply, in order
    # A FUNCTION becomes a CSUB whose FIRST argument receives the result.
    # MMBasic passes every argument by reference, so an out-parameter is the
    # same mechanism a return value would have used - the generated C function
    # is untouched, the shim just stores what it returned.
    retslot = None
    if routine.is_func:
        retslot = CT[routine.ty]
        decl.append("void *a0")
        passed.append(sfx("__r", False, routine.ty))
        slot = 1
    for p in routine.params:
        ct = CT[p.ty]
        args.append("(%s *)a%d" % (ct, slot))
        decl.append("void *a%d" % slot)
        passed.append(sfx(p.name, p.is_array, p.ty))
        slot += 1
        if p.is_array:
            if bounds_used(cbody, p):
                args.append("(const MMINTEGER *)a%d" % slot)
                decl.append("void *a%d" % slot)
                passed.append("Bound(%s,1)" % sfx(p.name, True, p.ty))
                slot += 1
            else:
                args.append("0")      # never read

    # Globals, by the same mechanism as everything else: MMBasic passes by
    # reference, so a global becomes one more pointer argument and the CSUB
    # writes straight back into the interpreter's own variable.
    gl = globals_touched(conv, routine)
    extra, members, ginit = [], [], []
    for nm, s in gl:
        ct = CT[s.ty]
        if s.acc.startswith("H->"):
            # an array global: mmb2c reaches it as H->v_name, so give the body
            # an H of our own whose members are pointers to the real arrays
            members.append("    %s *%s;" % (ct, s.acc[3:]))
            ginit.append("(%s *)a%d" % (ct, slot))
        else:
            # a scalar global: v_name is redefined as *__gp_name (see the
            # #defines emitted around the function), so it stays an lvalue
            extra.append("%s *__gp_%s" % (ct, nm))
            args.append("(%s *)a%d" % (ct, slot))
        decl.append("void *a%d" % slot)
        # mmb2c keeps arrays AND strings in one heap block reached as H->v_name,
        # so where it chose to put a global says nothing about how the BASIC
        # caller writes it. s.is_array is what decides name() versus name.
        passed.append(sfx(nm, s.is_array, s.ty))
        slot += 1
    if members:
        extra.append("struct __gv *__gh")
        args.append("&__g")

    lines = []
    lines.append("/* CSUB entry - the interpreter hands us one pointer per argument. */")
    lines.append("long long %s(%s)" % (entry, ", ".join(decl) if decl else "void"))
    lines.append("{")
    if members:
        lines.append("    struct __gv __g = { %s };" % ", ".join(ginit))
    if retslot:
        lines.append("    *(%s *)a0 = %s(%s);" % (retslot, cname, ", ".join(args)))
    else:
        lines.append("    %s(%s);" % (cname, ", ".join(args)))
    lines.append("    return 0;")
    lines.append("}")
    return "\n".join(lines), slot, passed, gl, extra, members


def type_list(routine, cbody, gl):
    """The `CSUB name INTEGER, FLOAT, ...` type list, matching entry_shim.

    It has to cover the globals too: a routine with no parameters can still
    take five arguments, and without a list CallCFunction takes the untyped
    path and the interpreter stops checking them.
    """
    T = {"f": "FLOAT", "i": "INTEGER", "s": "STRING"}
    out = []
    if routine.is_func:
        out.append(T[routine.ty])
    for p in routine.params:
        out.append(T[p.ty])
        if p.is_array and bounds_used(cbody, p):
            out.append("INTEGER")      # the bound
    for nm, sym in gl:
        out.append(T[sym.ty])
    return ", ".join(out)


def adapter_sub(name, routine, entry, passed):
    """A thin MMBasic SUB with the ORIGINAL name, so call sites do not change.

    It exists to supply what the CSUB ABI cannot carry - here, each array's
    BOUND(), which the interpreter does not pass.  With no arrays it is pure
    overhead, so it is only emitted when it has something to do.
    """
    ps = [SFX[p.ty](p.name, p.is_array) for p in routine.params]
    if routine.is_func:
        # A FUNCTION keeps its name and its call sites: the wrapper declares a
        # local for the result, hands it to the CSUB by reference, and returns
        # it.  MMBasic passes everything by reference anyway, so the CSUB's
        # out-parameter is the same mechanism the return value would have used.
        fn = SFX[routine.ty](name, False)      # the FUNCTION keeps its own type
        rn = SFX[routine.ty]("__r", False)     # and so must the local it returns
        return ("Function %s(%s)\n  Local %s\n  %s %s\n  %s = %s\nEnd Function\n"
                % (fn, ", ".join(ps), rn, entry, ", ".join(passed), fn, rn))
    if list(ps) == list(passed):
        return None            # the CSUB takes exactly the SUB's arguments,
                               # so it can carry the original name itself
    call = passed
    return ("Sub %s %s\n  %s %s\nEnd Sub\n"
            % (name, ", ".join(ps), entry, ", ".join(call)))


def write_c(cpath, source, subname, cbody, shim, gl, extra, members):
    """Write the translation unit: globals plumbing, the body, then the shim.

    The body between them is mmb2c's output character for character - only the
    signature gains parameters, and the names it uses for globals are
    redirected by #defines that are undone straight after.
    """
    with open(cpath, "w") as f:
        f.write("/* Generated by mmb2csub.py from %s, %s.\n"
                " * Do not edit - regenerate instead. */\n" % (source, subname))
        f.write('#include "mmcsub.h"\n\n')
        if gl:
            f.write("/* Globals this routine reaches. A CSUB has no writable static\n"
                    "   data, so each one arrives as a pointer and the names the\n"
                    "   generated body uses are pointed at it. */\n")
        if members:
            f.write("struct __gv {\n" + "\n".join(members) + "\n};\n")
            f.write("#define H __gh\n")
        for nm, sym in gl:
            if not sym.acc.startswith("H->"):
                f.write("#define %s (*__gp_%s)\n" % (sym.acc, nm))
        f.write("\n")
        f.write("static " + inject_params(cbody, extra) + "\n\n")
        for nm, sym in gl:
            if not sym.acc.startswith("H->"):
                f.write("#undef %s\n" % sym.acc)
        if members:
            f.write("#undef H\n")
        if gl:
            f.write("\n")
        f.write(shim + "\n")


# ---------------------------------------------------------------- main

def find_routine_text(conv, routine):
    """The source lines of the routine, as [start, end] indices into conv.lines.

    MMBasic routines cannot nest, so the first END SUB / END FUNCTION after the
    definition line is the end of this one.
    """
    start = routine.line - 1
    while start < len(conv.lines) and not re.match(
            r"\s*(sub|function)\b", conv.lines[start], re.I):
        start += 1
    if start >= len(conv.lines):
        return None
    for j in range(start + 1, len(conv.lines)):
        if re.match(r"\s*end\s*(sub|function)\b", conv.lines[j], re.I):
            return [start, j]
    return None


def calls_other_routines(routine, cbody):
    """Names of other BASIC routines this one calls.

    For now a converted routine has to be self-contained: only its own function
    goes into the blob, so a call to another one would be an undefined symbol at
    link time.  Catching it here says so in the user's terms instead.
    """
    seen = re.findall(r"\bf_([A-Za-z_][A-Za-z_0-9]*)\s*\(", cbody)
    return sorted(set(m for m in seen if ("f_" + m) != routine.cname))


MARKER = "' --- mmb2csub: "


def rewrite_source(path, conv, routine, subname, wrapper, block, ctext,
                   include_c, backup):
    """Comment the original routine out and append the CSUB (and its C)."""
    span = find_routine_text(conv, routine)
    if span is None:
        sys.exit("error: could not locate '%s' in the source text" % subname)
    lines = [ln if ln.endswith("\n") else ln + "\n" for ln in conv.lines]
    if any(MARKER in ln for ln in lines):
        sys.exit("error: %s already holds a mmb2csub conversion. Restore it from "
                 "the .bak before converting again." % path)

    if backup:
        with open(path + ".bak", "w") as f:
            f.writelines(lines)

    # MMBasic's block comment; the interpreter wants /* and */ on lines of
    # their own, which is also what makes the original easy to restore by hand
    original = lines[span[0]:span[1] + 1]
    lines[span[0]:span[1] + 1] = (
        ["/*\n", MARKER + "%s replaced by a CSUB; original follows\n" % subname]
        + original + ["*/\n"])

    out = ["\n", MARKER + "generated code for %s\n" % subname]
    if wrapper:
        out.append("' The wrapper keeps the original name, so call sites are unchanged.\n")
        out.append(wrapper if wrapper.endswith("\n") else wrapper + "\n")
        out.append("\n")
    out.append(block.rstrip("\n") + "\n")
    if include_c:
        out.append("\n' The C this was compiled from, for reference. Regenerate with:\n")
        out.append("'     python mmb2csub.py %s %s\n'\n"
                   % (os.path.basename(path), subname))
        # one apostrophe per line rather than /* */, because the C carries its
        # own /* */ comments and MMBasic's block comment does not nest
        for ln in ctext.splitlines():
            out.append("'" + ln + "\n")

    with open(path, "w") as f:
        f.writelines(lines)
        f.writelines(out)


def main():
    ap = argparse.ArgumentParser(
        description="Convert one MMBasic SUB or FUNCTION into a CSUB, in place.")
    ap.add_argument("source", help="the .bas program")
    ap.add_argument("sub", help="the SUB or FUNCTION to convert")
    ap.add_argument("--name", help="CSUB name (default <sub>K)")
    ap.add_argument("-O", "--opt", default="s", help="armcfgen -O level (default s)")
    ap.add_argument("--mmb2c", help="path to mmb2c.py")
    ap.add_argument("--keep-c", action="store_true",
                    help="also leave the generated .c on disk")
    ap.add_argument("--no-c", action="store_true",
                    help="do not embed the generated C as comments (it costs "
                         "program memory on the board)")
    ap.add_argument("--no-backup", action="store_true",
                    help="do not write <source>.bak")
    ap.add_argument("--dry-run", action="store_true",
                    help="build and report, but leave the source alone")
    args = ap.parse_args()

    mmb2c = load_mmb2c(args.mmb2c)
    conv = convert_program(mmb2c, args.source)

    canon = args.sub.upper()
    routine = None
    for k, r in conv.routines.items():
        if k.upper() == canon:
            routine = r
            break
    if routine is None:
        sys.exit("error: no SUB or FUNCTION named '%s' in %s\n  found: %s"
                 % (args.sub, args.source, ", ".join(sorted(conv.routines))))

    problems = check_scope(conv, routine, args.sub)
    if problems:
        print("error: %s cannot be a CSUB yet:" % args.sub)
        for p in problems:
            print("  - " + p)
        sys.exit(1)

    cbody = slice_function(conv, routine.cname)
    if cbody is None:
        sys.exit("error: could not find '%s' in the generated C. The routine may "
                 "have failed to translate - run mmb2c.py on the file to see why."
                 % routine.cname)

    others = calls_other_routines(routine, cbody)
    if others:
        sys.exit("error: %s calls %s. For now a converted routine has to be "
                 "self-contained - only its own code goes into the blob."
                 % (args.sub, ", ".join(others)))

    # Name it first, because the name depends on whether a wrapper is needed.
    # When the CSUB takes exactly the routine's own arguments there is nothing
    # for a wrapper to add, so the CSUB takes the ORIGINAL name and the call
    # sites go straight to it - MMBasic calls a CSUB exactly like a SUB. Only
    # when a wrapper has to sit in front (a FUNCTION's result, an array bound,
    # globals) does the CSUB need a name of its own for the wrapper to call.
    _, _, probe, _, _, _ = entry_shim(conv, routine, routine.cname, "probe", cbody)
    needs_wrapper = adapter_sub(args.sub, routine, "probe", probe) is not None
    entry = args.name or ((args.sub + "K") if needs_wrapper else args.sub)
    shim, nargs, passed, gl, extra, members = entry_shim(
        conv, routine, routine.cname, entry, cbody)

    stem = os.path.splitext(os.path.basename(args.source))[0]
    srcdir = os.path.dirname(os.path.abspath(args.source))
    cpath = os.path.join(srcdir, "%s_%s.c" % (stem, args.sub.lower()))
    write_c(cpath, args.source, args.sub, cbody, shim, gl, extra, members)

    out = os.path.join(srcdir, "%s_%s.txt" % (stem, args.sub.lower()))
    cmd = [sys.executable, ARMCFGEN, cpath, "--compile",
           "-n", entry, "-e", entry, "-O", args.opt,
           "-I", FIRMWARE, "-I", HERE, "-o", out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit("\nerror: the CSUB did not compile. 'undefined reference to "
                 "mm_xxx' means that MMBasic feature has no CSUB runtime yet;\n"
                 "'undefined reference to __aeabi_xxx' means an arithmetic helper is "
                 "missing from mmcsub.h. Either way the tool is telling you the\n"
                 "truth - do not work around it.")

    block = open(out).read()
    block = block.replace("CSUB " + entry.upper(),
                          "CSUB %s %s" % (entry, type_list(routine, cbody, gl)), 1)
    open(out, "w").write(block)
    ctext = open(cpath).read()

    wrapper = adapter_sub(args.sub, routine, entry, passed)
    nwords = sum(len(l.split()) for l in block.splitlines()
                 if l.startswith("\t") and not l.lstrip().startswith("'"))

    print("%s: %s %s -> CSUB %s"
          % (os.path.basename(args.source),
             "FUNCTION" if routine.is_func else "SUB", args.sub, entry))
    if gl:
        print("  globals passed by reference: " + ", ".join(nm for nm, _ in gl))
    print("  %d argument%s: %s"
          % (nargs, "" if nargs == 1 else "s", ", ".join(passed)))
    print("  blob: %d bytes of code" % (nwords * 4))

    if args.dry_run:
        print("\n(dry run - %s not modified)" % args.source)
        if wrapper:
            print("\nwrapper:\n" + wrapper)
        return

    rewrite_source(args.source, conv, routine, args.sub, wrapper, block, ctext,
                   not args.no_c, not args.no_backup)
    os.unlink(out)
    if not args.keep_c:
        os.unlink(cpath)
    print("  original commented out; CSUB%s appended"
          % (" and wrapper" if wrapper else ""))
    if not args.no_backup:
        print("  previous version saved as %s.bak" % os.path.basename(args.source))


if __name__ == "__main__":
    main()
