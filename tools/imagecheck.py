"""Check that bank 7's two images keep to themselves.

The game's image (the game's and the engine's bank 7 code, data and variables, and the
level's tables before $8300) and the menus' image (MUSCODE, MNU*) are read from the disc
over each other, so code in one must not reach a symbol in the other: a call or a load
across them runs or reads the other image's bytes.  What both use belongs where both can
reach it -- the kernel (KRN*), GAMEHI, low RAM, zero page, the banks -- or is assembled
into each.  Reads the build's ld65 debug file (assembled with -g: every symbol's
referencing lines, every line's spans, every span's segment); prints each crossing and
exits 1 on any.  HAZEL (GAMEHAZEL) is resident, so it is neither.

Usage:
    python3 tools/imagecheck.py [game.dbg=build/master/game.dbg]
"""
import re, sys

GAME = {'GAMECODE', 'GAMEDATA', 'ENGCODE', 'GAMEBSS', 'ENGBSS', 'GAMEROWH', 'GAMEOBJ',
        'GAMELVL', 'ENGLVL'}
MENU = {'MUSCODE', 'MNUCODE', 'MNUDATA', 'MNUBSS'}

dbg = open(sys.argv[1] if len(sys.argv) > 1 else 'build/master/game.dbg').read()
seg = {m.group(1): m.group(2) for m in re.finditer(r'^seg\tid=(\d+),name="(\w+)"', dbg, re.M)}
span = {m.group(1): seg[m.group(2)] for m in re.finditer(r'^span\tid=(\d+),seg=(\d+)', dbg, re.M)}
files = {m.group(1): m.group(2) for m in re.finditer(r'^file\tid=(\d+),name="([^"]+)"', dbg, re.M)}
lines = {}
for m in re.finditer(r'^line\tid=(\d+),file=(\d+),line=(\d+)(?:,[^\n]*?span=([\d+]+))?', dbg, re.M):
    segs = {span[s] for s in m.group(4).split('+')} if m.group(4) else set()
    lines[m.group(1)] = (files[m.group(2)].split('/')[-1], int(m.group(3)), segs)


def image(segs):
    return 'game' if segs & GAME else 'menus' if segs & MENU else None


bad = []
for m in re.finditer(r'^sym\tid=\d+,name="([^"]+)",([^\n]*)', dbg, re.M):
    name, rest = m.groups()
    s, r = re.search(r'\bseg=(\d+)', rest), re.search(r'\bref=([\d+]+)', rest)
    if not s or not r or 'type=lab' not in rest:
        continue
    own = image({seg[s.group(1)]})
    if not own:
        continue
    for lid in r.group(1).split('+'):
        f, n, segs = lines.get(lid, ('?', 0, set()))
        other = image(segs)
        if other and other != own:
            bad.append('%s:%d (the %s image) uses %s (the %s image\'s, %s)' % (f, n, other, name, own, seg[s.group(1)]))
for b in sorted(set(bad)):
    print(b)
print('imagecheck: %s' % ('%d crossings between the bank 7 images' % len(set(bad)) if bad else 'the bank 7 images keep to themselves'))
sys.exit(1 if bad else 0)
