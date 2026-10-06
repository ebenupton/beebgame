"""Check that the two machines' builds lay their data out alike.

Every segment both builds have must start at the same address, and every label in a segment
that is not code must sit at the same address in both -- the Master's shorter 65C02 code is
pinned out to the Model B's layout (pincfg.py), so nothing after it may move.  Exempt: labels
in the code segments (a CMOS instruction is shorter), the start-up pieces that run once and
are overwritten (STARTUP), and the segments one machine alone has after the shared data (OWN:
LOWHW, KRNHW, and MRAMBSS, the Master's handler state in main RAM).  Zero page has no
exemption: every zero-page label must exist on both machines, at one address.

Reads each build directory's game.dbg (cleo.dbg is accepted as an older name).  Prints every
difference (the moved labels capped at 40) and a summary line; exits 1 on any difference.

Usage:
    python3 tools/layoutcheck.py [modelb_dir=build/modelb] [master_dir=build/master]
"""
import os, re, sys


def dbgfile(d):
    """The build directory's ld65 debug file: game.dbg, or cleo.dbg where that is the name."""
    g = os.path.join(d, 'game.dbg')
    return g if os.path.exists(g) else os.path.join(d, 'cleo.dbg')

CODE = {'MRAMCODE', 'TILCODE', 'GAMECODE', 'SPR4CODE', 'SPR5CODE', 'MAP5CODE',
        'TIL6ENT', 'MNUCODE', 'LOWCODE', 'LOWCODE2', 'GAME6CODE', 'D8271C', 'D1770C', 'D8271N', 'D1770N', 'KRNCODE', 'ENGCODE', 'MUSCODE'}
# run once at start-up, then overwritten
STARTUP = {'BOOT', 'BOOTHDR', 'BANKFIX', 'WRFIX'}
# one machine's own, placed after the shared data
OWN = {'LOWHW', 'KRNHW', 'MRAMBSS'}


def load(d):
    """The build's layout from its debug file: ({segment: (start, size)} for the non-empty
    segments, {label: (segment, address)} for every plain label, no linker '__' symbols, no
    cheap '@' labels, no equates)."""
    dbg = open(dbgfile(d)).read()
    segs = {}
    for m in re.finditer(r'^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+),size=0x([0-9A-F]+)', dbg, re.M):
        segs[m.group(1)] = (m.group(2), int(m.group(3), 16), int(m.group(4), 16))
    syms = {}
    for m in re.finditer(r'^sym\tid=\d+,name="([\w@]+)",([^\n]*)', dbg, re.M):
        name, rest = m.groups()
        if name.startswith('__') or name.startswith('@') or 'type=lab' not in rest:
            continue
        seg = re.search(r'seg=(\d+)', rest)
        val = re.search(r'val=0x([0-9A-F]+)', rest)
        if seg and val and seg.group(1) in segs:
            syms[name] = (segs[seg.group(1)][0], int(val.group(1), 16))
    return {n: (s, z) for n, s, z in segs.values() if z}, syms


bd = sys.argv[1] if len(sys.argv) > 1 else 'build/modelb'
md = sys.argv[2] if len(sys.argv) > 2 else 'build/master'
bseg, bsym = load(bd)
mseg, msym = load(md)
bad = 0
for n in sorted(set(bseg) & set(mseg)):
    if n in STARTUP:
        continue
    if bseg[n][0] != mseg[n][0]:
        bad += 1
        print('segment %-9s Model B $%04X, Master $%04X' % (n, bseg[n][0], mseg[n][0]))
moved = []
for n in sorted(set(bsym) & set(msym)):
    (sb, ab), (sm, am) = bsym[n], msym[n]
    if sb in CODE or {sb, sm} & (STARTUP | OWN):
        continue
    if ab != am:
        moved.append((sb, ab, n, am))
for sb, ab, n, am in sorted(moved):
    bad += 1
    if bad <= 40:
        print('%-9s %-14s Model B $%04X, Master $%04X' % (sb, n, ab, am))
ZPSEGS = lambda s: s.startswith(('ZP', 'ZEROPAGE'))
zb = {n: a for n, (s, a) in bsym.items() if ZPSEGS(s)}
zm = {n: a for n, (s, a) in msym.items() if ZPSEGS(s)}
for n in sorted(set(zb) ^ set(zm)):
    bad += 1
    print('zero page: %s only on the %s' % (n, 'Model B' if n in zb else 'Master'))
for n in sorted(set(zb) & set(zm)):
    if zb[n] != zm[n]:
        bad += 1
        print('zero page: %s Model B $%02X, Master $%02X' % (n, zb[n], zm[n]))
print('layout: %s' % ('the data sits alike on both machines' if not bad else '%d differences' % bad))
sys.exit(1 if bad else 0)
