#!/usr/bin/env python3
"""Reject ca65 anonymous labels outside macros: no `:` label, no `:+` / `:-` reference in
code.

An anonymous reference counts labels across the whole assembly unit, so a `:` added or
removed retargets branches far away, and a cold path escapes every test: name every label in
code (a cheap one, @name).  A macro's body may keep its anonymous skips -- a named label
there would have to be unique per expansion without ending the caller's @ scope, which ca65
offers no clean way to do -- since the code around a macro's call has none to count across
them.  Prints each offender and exits 1 on any.

Usage:
    python3 tools/noanon.py <dir or file>...     (directories: every .s and .inc in them)
"""
import os, re, sys

DEF = re.compile(r'^\s*:(\s|$)')
REF = re.compile(r'(?<![\w@:.$\'"]):(\++|-+)(?![\w+-])')

def files(args):
    for a in args:
        if os.path.isdir(a):
            for root, _, names in os.walk(a):
                for n in sorted(names):
                    if n.endswith(('.s', '.inc')):
                        yield os.path.join(root, n)
        else:
            yield a

MAC = re.compile(r'^\s*\.mac(ro)?\b', re.I)
ENDM = re.compile(r'^\s*\.endmac(ro)?\b', re.I)
bad = 0
for f in files(sys.argv[1:]):
    inmac = False
    for n, line in enumerate(open(f, encoding='latin-1'), 1):
        code = line.split(';', 1)[0]
        if MAC.match(code):
            inmac = True
        elif ENDM.match(code):
            inmac = False
        elif not inmac and (DEF.match(code) or REF.search(code)):
            print(f'{f}:{n}: an anonymous label: {line.rstrip()}')
            bad += 1
if bad:
    print(f'{bad} anonymous label(s) outside macros: name them (tools/noanon.py says why)')
sys.exit(1 if bad else 0)
