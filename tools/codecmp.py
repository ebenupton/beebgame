#!/usr/bin/env python3
"""Compare the code of two ca65 sources, ignoring comments and layout.

Every line has its comment stripped (a ';' outside quotes), its whitespace collapsed, and a
label split from the instruction that shares its line, so moving or rewrapping a comment, or
putting a label on its own line, is no change.  Prints the first difference and exits 1 if
the code differs, 0 if it is the same.

Usage:
    python3 tools/codecmp.py old.s new.s
"""
import sys, re

def strip(line):
    """The line up to its comment: a ';' inside a single- or double-quoted string is kept."""
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in '"\'':
            q = ch; out.append(ch)
        elif ch == ';':
            break
        else:
            out.append(ch)
    return ''.join(out)

def tokens(path):
    """The file's code items as (text, line number): a label (cheap, anonymous or plain) and
    the instruction after it on the same line are two items; a line that is only a comment
    or blank is none.  A line starting ':=' is an equate, not an anonymous label."""
    toks = []
    for n, line in enumerate(open(path), 1):
        s = ' '.join(strip(line).split())
        if not s:
            continue
        m = re.match(r'^((?:[@A-Za-z_][\w@]*|):)\s*(.*)$', s)
        if m and not s.startswith(':='):
            toks.append((m.group(1), n))
            if m.group(2):
                toks.append((m.group(2), n))
        else:
            toks.append((s, n))
    return toks

a, b = tokens(sys.argv[1]), tokens(sys.argv[2])
for i in range(max(len(a), len(b))):
    x = a[i] if i < len(a) else ('<end>', 0)
    y = b[i] if i < len(b) else ('<end>', 0)
    if x[0] != y[0]:
        print('differ: %s:%d %r  vs  %s:%d %r' % (sys.argv[1], x[1], x[0], sys.argv[2], y[1], y[0]))
        sys.exit(1)
print('code identical (%d items)' % len(a))
