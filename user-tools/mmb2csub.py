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


def cname_of(nm):
    """An MMBasic name as a C identifier: a dot is legal in BASIC, not in C."""
    return nm.replace(".", "__")


def called_routines(cbody, own_cname):
    """The f_ names this body calls, other than itself."""
    seen = re.findall(r"\bf_([A-Za-z_][A-Za-z_0-9]*)\s*\(", cbody)
    return [m for m in seen if ("f_" + m) != own_cname]


def closure(conv, routine):
    """The routine and everything it calls, transitively, in emission order.

    mmb2c emits an inter-routine call as f_other(...), so a blob holding only
    the entry would leave that undefined.  armcfgen's merge mode already packs
    several functions into one blob and resolves the calls between them, so the
    work is picking WHICH functions: the call graph from the entry, with
    recursion and mutual recursion handled by the visited set.
    """
    by_cname = {r.cname: r for r in conv.routines.values()}
    order, seen = [], set()

    def walk(r):
        if r.cname in seen:
            return
        seen.add(r.cname)
        body = slice_function(conv, r.cname)
        if body is None:
            return
        for nm in called_routines(body, r.cname):
            callee = by_cname.get("f_" + nm)
            if callee is not None:
                walk(callee)
        order.append(r)

    walk(routine)
    return order          # callees first, entry last


def local_structs_for(conv, routines):
    """The `struct mm_l_<routine>` definitions the blob needs.

    A routine with LOCAL arrays or strings keeps them in one block per
    invocation, whose struct mmb2c declares at file scope - in a part of its
    output that a slice does not carry.  Only the structs for routines in this
    blob are taken, so an unrelated routine's locals cost nothing.
    """
    want = set("struct mm_l_%s {" % r.cname for r in routines)
    out, keep = [], False
    for ln in conv.local_structs():
        if ln in want:
            keep = True
        if keep:
            out.append(ln)
        if keep and ln == "};":
            keep = False
    return out


def consts_used(conv, mmb2c, text):
    """The CONSTs the emitted text mentions, as (cname, value) pairs.

    mmb2c emits a global CONST as a #define in a section of its output that a
    slice does not carry, so a routine using one would not compile.  Only the
    ones actually named are emitted; a CONST whose value needs the runtime is
    skipped, being a hidden global rather than a #define.
    """
    out = []
    for nm in sorted(conv.globals):
        sym = conv.globals[nm]
        if not sym.is_const or getattr(sym, "const_runtime", False):
            continue
        cn = mmb2c.cconst(nm)
        if re.search(r"\b" + re.escape(cn) + r"\b", text):
            out.append((cn, sym.acc))
    return out


def globals_touched(conv, routines):
    """The globals the whole blob reaches, in a stable order.

    mmb2c records these itself while scanning (Routine.gtouch, which is what
    its report's "Globals reached from inside a SUB" section is built from),
    so this is reading its answer rather than parsing the generated C.  The
    union over the closure, because a callee's globals have to arrive too.
    CONSTs are excluded - they become #defines and need nothing passed.
    """
    names = set()
    for r in routines:
        names |= set(r.gtouch)
    out = []
    for nm in sorted(names):
        s = conv.globals.get(nm)
        if s is None or s.is_const:
            continue
        out.append((nm, s))
    return out


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


def check_scope(conv, routine, name, routines=None):
    """Refuse what this knowingly cannot do.  The compiler catches the rest.

    Checked over the whole closure: a callee that cannot be converted stops the
    entry just as surely, and saying so here names the real routine.
    """
    bad = []
    routines = routines or [routine]
    for r in routines:
        who = r.name if r is not routine else name
        if uses_on_error(conv, r):
            bad.append("%s uses ON ERROR; a CSUB cannot reach the "
                       "interpreter's error handling" % who)
        if r.is_func and r.ty == "s":
            bad.append("%s is a string FUNCTION; strings are phase 2" % who)
        for p in r.params:
            if p.stype is not None:
                bad.append("%s: parameter '%s' is a user TYPE" % (who, p.name))
            elif getattr(p, "ty", None) == "s":
                bad.append("%s: parameter '%s' is a string; strings are phase 2"
                           % (who, p.name))
    n = len(routine.params) + sum(1 for p in routine.params if p.is_array)
    if n > 16:
        bad.append("%d arguments needed; the limit is MAX_CSUB_ARGS "
                   "(16 on RP2350, 10 on RP2040)" % n)
    return bad


# ---------------------------------------------------------------- emit

# MMBasic type suffixes: the generated wrapper is real BASIC and must declare
# its own types, whatever OPTION DEFAULT is where it gets pasted.
SFX = {"f": lambda nm, arr: nm + "!" + ("()" if arr else ""),
       "i": lambda nm, arr: nm + "%" + ("()" if arr else ""),
       "s": lambda nm, arr: nm + "$" + ("()" if arr else "")}

CT = {"f": "MMFLOAT", "i": "MMINTEGER", "s": "char"}


def bind_globals(body, routine, flat, heap):
    """Point this routine's global references at the pointers in CFuncRam.

    Done by rewriting the body rather than with #define, because a macro has no
    scope: a program with a global `i` and a local `i` in some other routine
    gives both the C name v_i, and a file-scope #define would rewrite the
    LOCAL's declaration into a syntax error.

    Substituting per routine is sound precisely because that ambiguity cannot
    arise inside one routine - mmb2c does not record a global as touched by a
    routine that has a local of the same name (note_touch skips it), so within
    a single body v_i means one thing or the other, never both.
    """
    decls = []
    for k, (nm, s) in enumerate(flat):
        if nm not in routine.gtouch:
            continue
        ptr = "__gp_" + cname_of(nm)
        body = re.sub(r"\b" + re.escape(s.acc) + r"\b", "(*%s)" % ptr, body)
        # Read the pointer ONCE into a local rather than substituting the
        # CFuncRam expression at every use: the compiler then keeps it in a
        # register. Inlining it cost about 6% on a globals-heavy inner loop.
        decls.append("    %s *const %s = (%s *)MMCSUB_G[%d];"
                     % (CT[s.ty], ptr, CT[s.ty], len(heap) + k))
    if decls:
        head, rest = body.split("\n", 1)
        body = head + "\n" + "\n".join(decls) + "\n" + rest
    return body


def add_polls(body):
    """Put mm_poll() at the top of every loop body.

    The interpreter tests the break key between statements.  A CSUB is ONE
    statement, so a converted loop that runs for thirty seconds cannot be
    interrupted at all - the board simply stops answering, which is exactly
    what the KnivD benchmark did the first time it was converted.  mm_poll()
    calls CheckAbort once in every 1024 times round, far below the cost of any
    loop worth converting.
    """
    out = []
    for ln in body.split("\n"):
        out.append(ln)
        st = ln.strip()
        if ln.rstrip().endswith("{") and (st.startswith("for (")
                                          or st.startswith("while (")
                                          or st == "do {"):
            out.append(" " * (len(ln) - len(ln.lstrip()) + 4) + "mm_poll();")
    return "\n".join(out)


def heap_member(s):
    """One member of our struct __gv, for a global mmb2c reaches as H->name.

    mmb2c lays every global array out inside one block and indexes it with its
    real shape, so a 2-D array is written H->v_x[i][j].  The interpreter
    allocates each array separately, so the member here is a POINTER to the
    caller's storage - and for more than one dimension that has to be a pointer
    to an array, or the second subscript has nothing to apply to.  mmb2c
    declares the dimensions reversed; the outermost one is what the pointer
    replaces.
    """
    ct = CT[s.ty]
    nm = s.acc[3:]
    dims = getattr(s, "dims", None) or []
    if s.is_array and len(dims) > 1:
        rest = "".join("[%s]" % d for d in reversed(dims[:-1]))
        return "%s (*%s)%s;" % (ct, nm, rest)
    if s.ty == "s" and s.is_array:
        return "char (*%s)[%s];" % (nm, s.slen + 1 if s.slen else "STRINGSIZE")
    return "%s *%s;" % (ct, nm)


def bounds_used(text, p):
    """Does the blob actually read this array parameter's bounds?

    mmb2c always gives an array parameter a companion __b_ argument because
    BOUND() inside the routine would need it.  Most kernels never call BOUND(),
    and every argument not passed is one more the caller can spend - which
    matters, because MAX_CSUB_ARGS is 10 on the RP2040.  So pass NULL when the
    generated code never mentions it.
    """
    # every function's FIRST line is its signature, which always names the
    # __b_ argument - only a mention in a body counts
    bodies_only = "\n".join(
        ln for b in text.split("\n}\n") for ln in b.split("\n")[1:])
    return ("__b_" + p.name.replace(".", "__")) in bodies_only


def entry_shim(conv, routine, entry, bodytext, gl):
    """The CSUB entry: cast the interpreter's void*, publish the globals, call.

    The routine's own parameters go straight through as arguments.  The globals
    go into CFuncRam, where every function in the blob can reach them - a
    callee's signature is fixed by mmb2c and cannot be given them.
    """
    args, decl, passed, slot = [], [], [], 0
    sfx = lambda nm, arr, ty: nm + {"f": "!", "i": "%", "s": "$"}[ty] + ("()" if arr else "")

    retslot = None
    if routine.is_func:
        # MMBasic passes every argument by reference, so a FUNCTION's result is
        # just one more out-parameter and the generated C is used as emitted.
        retslot = CT[routine.ty]
        decl.append("void *a0")
        passed.append(sfx("__r", False, routine.ty))
        slot = 1
    for p in routine.params:
        args.append("(%s *)a%d" % (CT[p.ty], slot))
        decl.append("void *a%d" % slot)
        passed.append(sfx(p.name, p.is_array, p.ty))
        slot += 1
        if p.is_array:
            if bounds_used(bodytext, p):
                args.append("(const MMINTEGER *)a%d" % slot)
                decl.append("void *a%d" % slot)
                passed.append("Bound(%s,1)" % sfx(p.name, True, p.ty))
                slot += 1
            else:
                args.append("0")      # never read

    # globals: the heap-resident ones first, so they lie over struct __gv
    heap = [(nm, s) for nm, s in gl if s.acc.startswith("H->")]
    flat = [(nm, s) for nm, s in gl if not s.acc.startswith("H->")]
    sets = []
    for k, (nm, s) in enumerate(heap):
        sets.append("    H->%s = (%s *)a%d;" % (s.acc[3:], CT[s.ty], slot))
        decl.append("void *a%d" % slot)
        passed.append(sfx(nm, s.is_array, s.ty))
        slot += 1
    for k, (nm, s) in enumerate(flat):
        sets.append("    MMCSUB_G[%d] = a%d;" % (len(heap) + k, slot))
        decl.append("void *a%d" % slot)
        passed.append(sfx(nm, s.is_array, s.ty))
        slot += 1

    lines = ["/* CSUB entry - the interpreter hands us one pointer per argument. */",
             "long long %s(%s)" % (entry, ", ".join(decl) if decl else "void"),
             "{",
             "    mm_scratch_reset();"]
    lines += sets
    call = "%s(%s)" % (routine.cname, ", ".join(args))
    lines.append("    *(%s *)a0 = %s;" % (retslot, call) if retslot
                 else "    %s;" % call)
    lines.append("    return 0;")
    lines.append("}")
    return "\n".join(lines), slot, passed


def type_list(routine, bodytext, gl):
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
        if p.is_array and bounds_used(bodytext, p):
            out.append("INTEGER")      # the bound
    for nm, sym in sorted(gl, key=lambda g: not g[1].acc.startswith("H->")):
        out.append(T[sym.ty])
    return ", ".join(out)


def adapter_sub(name, routine, entry, passed):
    """A thin MMBasic SUB or FUNCTION with the ORIGINAL name.

    It supplies what the CSUB ABI cannot carry - a FUNCTION's result, an
    array's BOUND(), the globals - so that call sites do not change.  When the
    CSUB takes exactly the routine's own arguments there is nothing to add and
    the CSUB carries the original name itself.
    """
    ps = [SFX[p.ty](p.name, p.is_array) for p in routine.params]
    if routine.is_func:
        fn = SFX[routine.ty](name, False)      # the FUNCTION keeps its type
        rn = SFX[routine.ty]("__r", False)     # and so must the local
        return ("Function %s(%s)\n  Local %s\n  %s %s\n  %s = %s\nEnd Function\n"
                % (fn, ", ".join(ps), rn, entry, ", ".join(passed), fn, rn))
    if list(ps) == list(passed):
        return None
    return ("Sub %s%s\n  %s %s\nEnd Sub\n"
            % (name, (" " + ", ".join(ps)) if ps else "",
               entry, ", ".join(passed)))


def write_c(cpath, source, subname, routines, bodies, shim, gl, consts,
            lstructs=()):
    """Write the translation unit: globals, every function in the blob, the shim.

    The bodies are mmb2c's output character for character.  Only names are
    redirected around them, by #defines that stay in force for the whole blob
    because a callee needs them just as much as the entry does.
    """
    heap = [(nm, s) for nm, s in gl if s.acc.startswith("H->")]
    flat = [(nm, s) for nm, s in gl if not s.acc.startswith("H->")]
    with open(cpath, "w") as f:
        f.write("/* Generated by mmb2csub.py from %s, %s.\n"
                " * Do not edit - regenerate instead. */\n" % (source, subname))
        f.write('#include "mmcsub.h"\n\n')
        for cn, val in consts:
            f.write("#define %s %s\n" % (cn, val))
        if consts:
            f.write("\n")
        if gl:
            f.write("/* Globals the blob reaches. A CSUB has no writable static data,\n"
                    "   so each one arrives as a pointer in CFuncRam and the names the\n"
                    "   generated bodies use are pointed at it. */\n")
        if heap:
            f.write("struct __gv {\n")
            for nm, s in heap:
                f.write("    %s\n" % heap_member(s))
            f.write("};\n#define H ((struct __gv *)MMCSUB_G)\n")
        f.write("\n")
        if lstructs:
            f.write("\n".join(lstructs) + "\n\n")
        if len(routines) > 1:
            f.write("/* every function in the blob, so the calls between them resolve */\n")
            for r in routines:
                f.write("static %s;\n" % bodies[r.cname].split("\n", 1)[0].rstrip(" {"))
            f.write("\n")
        for r in routines:
            f.write("static "
                    + add_polls(bind_globals(bodies[r.cname], r, flat, heap))
                    + "\n\n")
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

    # Everything the routine calls comes with it: mmb2c emits an inter-routine
    # call as f_other(...), and armcfgen's merge mode packs them into one blob
    # and resolves the calls between them.
    routines = closure(conv, routine)
    bodies = {}
    for r in routines:
        b = slice_function(conv, r.cname)
        if b is None:
            sys.exit("error: could not find '%s' in the generated C. %s may have "
                     "failed to translate - run mmb2c.py on the file to see why."
                     % (r.cname, r.name))
        bodies[r.cname] = b
    bodytext = "\n".join(bodies[r.cname] for r in routines)

    problems = check_scope(conv, routine, args.sub, routines)
    if problems:
        print("error: %s cannot be a CSUB yet:" % args.sub)
        for p in problems:
            print("  - " + p)
        sys.exit(1)

    gl = globals_touched(conv, routines)
    if len(gl) > 62:
        sys.exit("error: %s and what it calls reach %d globals; CFuncRam holds 62"
                 % (args.sub, len(gl)))

    # Name it first, because the name depends on whether a wrapper is needed.
    # When the CSUB takes exactly the routine's own arguments there is nothing
    # for a wrapper to add, so the CSUB takes the ORIGINAL name and the call
    # sites go straight to it - MMBasic calls a CSUB exactly like a SUB. Only
    # when a wrapper has to sit in front (a FUNCTION's result, an array bound,
    # globals) does the CSUB need a name of its own for the wrapper to call.
    _, _, probe = entry_shim(conv, routine, "probe", bodytext, gl)
    needs_wrapper = adapter_sub(args.sub, routine, "probe", probe) is not None
    entry = args.name or ((args.sub + "K") if needs_wrapper else args.sub)
    shim, nargs, passed = entry_shim(conv, routine, entry, bodytext, gl)

    stem = os.path.splitext(os.path.basename(args.source))[0]
    srcdir = os.path.dirname(os.path.abspath(args.source))
    cpath = os.path.join(srcdir, "%s_%s.c" % (stem, args.sub.lower()))
    write_c(cpath, args.source, args.sub, routines, bodies, shim, gl,
            consts_used(conv, mmb2c, bodytext),
            local_structs_for(conv, routines))

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
                          "CSUB %s %s" % (entry, type_list(routine, bodytext, gl)), 1)
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
    if len(routines) > 1:
        print("  also in the blob: "
              + ", ".join(r.name for r in routines if r is not routine))

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
