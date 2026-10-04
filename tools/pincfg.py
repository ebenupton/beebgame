"""Pin the Master's linker configuration to the Model B's layout.

Every segment in the configuration that the Model B's build also has gets `start = $xxxx`,
the Model B's start address from its ld65 debug file, so the Master's shorter 65C02 code
leaves a gap instead of moving what follows it, and the data lies alike on both machines
(tools/layoutcheck.py checks that).  Left to the linker: the segments in FREE (the start-up
pieces, the Master's own main-RAM code and state, the drivers' NMI stubs), segments the
Model B does not have, and segments the configuration already places with `start` or
`offset`.  A pinned segment loses its `align`: the Model B's start already satisfies it.

Reads the configuration and the debug file; writes the pinned configuration to stdout.

Usage:
    python3 tools/pincfg.py <master cfg> <Model B game.dbg> > <pinned cfg>
"""
import re, sys

FREE = {'BOOT', 'BOOTHDR', 'BANKFIX', 'WRFIX', 'MRAMCODE', 'MRAMBSS', 'D8271N', 'D1770N'}
cfg, dbg = open(sys.argv[1]).read(), open(sys.argv[2]).read()
start = {m.group(1): int(m.group(2), 16)
         for m in re.finditer(r'^seg\tid=\d+,name="(\w+)",start=0x([0-9A-F]+),size=0x([0-9A-F]+)', dbg, re.M)
         if int(m.group(3), 16)}


def pin(m):
    """One SEGMENTS line (indent, name, the rest from `load`) rewritten with the Model B's
    start, or returned as it is when the segment is free, unknown to the Model B, or placed
    already."""
    lead, name, rest = m.groups()
    if name in FREE or name not in start or re.search(r"\b(start|offset)\s*=", rest):
        return m.group(0)
    rest = re.sub(r',\s*align\s*=\s*\$?\w+', '', rest)
    return '%s%s: start = $%04X, %s' % (lead, name, start[name], rest)


seg = cfg.index('SEGMENTS')
sys.stdout.write(cfg[:seg] + re.sub(r'^(\s*)(\w+):\s*(load\b[^\n]*)', pin, cfg[seg:], flags=re.M))
