#!/usr/bin/env python3
"""Reject ca65 anonymous labels: no `:` label, no `:+` / `:-` reference, in any source.

An anonymous reference counts labels across the whole assembly unit -- macro expansions and
conditional arms included -- so a `:` added or removed anywhere retargets branches far away,
and a cold path escapes every test.  Name every label: a cheap one (@name) in code; in a
macro a cheap one with a fixed name prefixed with the macro's, or one the caller passes in
(a .local name is a normal symbol and would end the caller's @ scope).  Prints each
offender and exits 1 on any.

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

bad = 0
for f in files(sys.argv[1:]):
    for n, line in enumerate(open(f, encoding='latin-1'), 1):
        code = line.split(';', 1)[0]
        if DEF.match(code) or REF.search(code):
            print(f'{f}:{n}: an anonymous label: {line.rstrip()}')
            bad += 1
if bad:
    print(f'{bad} anonymous label(s): name them (tools/noanon.py says how)')
sys.exit(1 if bad else 0)
