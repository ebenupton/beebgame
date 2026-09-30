"""beebgame's level files: the format the load-time program (src/ldprog.s lv_load)
reads, written from a game's level in the engine's terms.  One definition of the
format: the section order and the header's fields are here, and the loader takes
them from here too (`python3 levelfile.py inc` writes levelfmt.inc, which ldprog.s
includes), so the two cannot drift apart.

A level file is a table of section offsets (two bytes each, from the file's start),
then the sections in order.  The last, LV_PAGE0 (the Master's tile gather), is two
whole sectors at the end, so the Model B's loader reads the file short of them.

    import levelfile as lf
    data = lf.encode(lf.Level(lw=5, lh=5, game_header={2: x, ...}, shape=lf.Shape(...),
                              objects=b'...', tile_tables=(attr, altcls), tiles=b'...',
                              placement=[(item, bank, img, extra), ...], map=b'...',
                              flat=b'...', halves=b'...', hpair=b'...', mir=b'',
                              directory=lf.directory([None | (addr, bank), ...]),
                              page0=b'...', boxid0=103, boxn=15))
    lf.decode(data, 103, 15)    # the sections back, the map unpacked: for checks
"""
from dataclasses import dataclass, field
import os, re, sys

# ---------------------------------------------------------------- the sections
SECTIONS = ('hdr', 'objs', 'attr', 'altcls', 'tiles', 'place', 'map', 'flat', 'halves',
            'hpair', 'mir', 'dir', 'page0')
SEC = {n: i for i, n in enumerate(SECTIONS)}

# ---------------------------------------------------------------- the header, 32 bytes (LV_HDR)
HDR_LEN = 32
HDR_LW, HDR_LH = 0, 1           # log2 of the map's width and height in tiles
HDR_NOBJ = 6                    # the objects' count (the loader copies 6 bytes each)
HDR_SHAPE = 20                  # the tile set's shape, 12 bytes (Shape)
HDR_GAME = tuple(range(2, 6)) + tuple(range(7, 20))   # the game's own fields
SHAPE_FIELDS = ('zero', 'ntiles', 'mapshr', 'nhalf', 'half0', 'half1', 'half2', 'halfpage',
                'halfoff', 'mir0', 'nmir', 'solidfill')
HDR = {'HDR_' + f.upper(): HDR_SHAPE + i for i, f in enumerate(SHAPE_FIELDS) if f != 'zero'}


@dataclass
class Shape:
    """the tile set as the blitter and the loader take it: the tile count, the map's row
    shift (8 - lw), the half tiles (count, the three range boundaries, the page they
    are in and HALFOFF), the mirrored tiles (the first id, the count: TILEMIRROR), and
    the solid's fill byte (id 0)"""
    ntiles: int
    mapshr: int
    nhalf: int = 0
    half0: int = 0
    half1: int = 0
    half2: int = 0
    halfpage: int = 0           # the page's high byte
    halfoff: int = 0
    mir0: int = 0
    nmir: int = 0
    solidfill: int = 0

    def encode(self):
        return bytes([0] + [getattr(self, f) & 255 for f in SHAPE_FIELDS[1:]])


# ---------------------------------------------------------------- the limits (src/defs.inc)
OBJ_BYTES, OBJ_MAX = 6, 149     # LV_OBJS: 894 bytes, main RAM
                                # SPR_TABLE: 2 bytes a sprite id, BOXID0 + BOXN of them
                                # (the game's numbers, from its assets.inc: Level.boxid0,
                                # boxn)
STAGE_LVL_B = 0x7C00 - 0x5C00   # the Model B's level stage (without LV_PAGE0)
STAGE_M = 0x8000 - 0x3000       # the Master's stage
MASTERONLY = os.environ.get('MASTERONLY') == '1'   # (the build's: no Model B, no limit of its)
PAGE0_LEN = 512


def dir_len(boxid0, boxn):
    """the directory section's length: 2 bytes a sprite id"""
    return 2 * (boxid0 + boxn)


# ---------------------------------------------------------------- the map's run length code
def rle(data):
    """c < 128: c+1 literal bytes follow; c >= 128: the next byte, c-126 times (2..129)"""
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        j = i
        while j + 1 < n and data[j + 1] == data[i] and j - i < 128:
            j += 1
        run = j - i + 1
        if run >= 2:
            out += bytes([126 + run, data[i]]); i += run; continue
        j = i
        while j < n and j - i < 128 and not (j + 2 < n and data[j] == data[j + 1] == data[j + 2]):
            j += 1
        out += bytes([j - i - 1]) + data[i:j]; i = j
    return bytes(out)


def unrle(data, n=None):
    out, i = bytearray(), 0
    while i < len(data) and (n is None or len(out) < n):
        c = data[i]; i += 1
        if c < 128:
            out += data[i:i + c + 1]; i += c + 1
        else:
            out += bytes([data[i]]) * (c - 126); i += 1
    return bytes(out)


# ---------------------------------------------------------------- the sprites' sections
def placement(items):
    """(item, bank, image address, extra) for each image the level places from the
    shared files, in item order; $FF ends it.  extra is 0, or for an item the loader
    bakes (ldprog.s bake) its tile: x | y << 8"""
    out = bytearray()
    for item, bank, img, extra in items:
        assert 0 <= item < 255 and bank in (4, 5), (item, bank)
        out += bytes([item, bank, img & 255, img >> 8, extra & 255, extra >> 8])
    return bytes(out + b'\xff')


def directory(entries):
    """SPR_TABLE, the directory's level part: for every sprite id, None or (address, bank);
    the addresses' low bytes, then their high bytes -- 0 for None, bit 7 clear for bank
    5 (the images are all at $8000..$BFFF: bit 7 is always set in the address itself).
    The geometry is the game's own tables (SPRG_*), the same in every level."""
    lo, hi = bytearray(), bytearray()
    for e in entries:
        if e is None:
            lo.append(0); hi.append(0); continue
        addr, bank = e
        assert 0x8000 <= addr < 0xC000 and bank in (4, 5), (addr, bank)
        lo.append(addr & 255); hi.append(addr >> 8 if bank == 4 else (addr >> 8) & 0x7F)
        assert hi[-1], 'an image at $80xx in bank 5 reads as none'
    return bytes(lo + hi)


# ---------------------------------------------------------------- a level
@dataclass
class Level:
    lw: int
    lh: int
    shape: Shape
    objects: bytes              # OBJ_BYTES each: the game's (copied to LV_OBJS)
    tile_tables: tuple          # two 256-byte tables by tile id: the game's (LV_ATTR0, LV_ALTCLS)
    tiles: bytes                # the tile list: the files, each with its full tiles' indices
    placement: bytes            # placement()
    map: bytes                  # 1 << (lw + lh) tile ids, row major
    flat: bytes                 # FLATTAB's pairs
    halves: bytes               # the half tiles: index in file, row, file
    hpair: bytes                # the halves' fill palette (8 first bytes, 8 second), then
                                # each half's low bits (fill row, colour)
    mir: bytes                  # MIRTAB (TILEMIRROR; else empty)
    directory: bytes            # directory()
    page0: bytes                # LV_PAGE0: the Master's gather table, 512 bytes
    boxid0: int = 0             # the game's sprite ids: BOXID0 images, then BOXN boxes
    boxn: int = 0               #  (assets.inc)
    game_header: dict = field(default_factory=dict)   # offset -> byte, HDR_GAME only


def header(lv):
    h = bytearray(HDR_LEN)
    h[HDR_LW], h[HDR_LH] = lv.lw, lv.lh
    assert len(lv.objects) % OBJ_BYTES == 0 and len(lv.objects) // OBJ_BYTES <= OBJ_MAX
    h[HDR_NOBJ] = len(lv.objects) // OBJ_BYTES
    for o, v in lv.game_header.items():
        assert o in HDR_GAME, 'header byte %d is the engine\'s' % o
        h[o] = v
    h[HDR_SHAPE:] = lv.shape.encode()
    return bytes(h)


def encode(lv):
    assert len(lv.map) == 1 << (lv.lw + lv.lh), (len(lv.map), lv.lw, lv.lh)
    assert all(len(t) == 256 for t in lv.tile_tables) and len(lv.tile_tables) == 2
    assert lv.boxid0 > 0 and len(lv.directory) == dir_len(lv.boxid0, lv.boxn)
    assert len(lv.page0) == PAGE0_LEN
    maprle = rle(lv.map)
    assert unrle(maprle) == lv.map
    body = dict(hdr=header(lv), objs=lv.objects, attr=lv.tile_tables[0], altcls=lv.tile_tables[1],
                tiles=lv.tiles, place=lv.placement, map=maprle, flat=lv.flat, halves=lv.halves,
                hpair=lv.hpair, mir=lv.mir, dir=lv.directory, page0=lv.page0)
    off = 2 * len(SECTIONS)
    table, data = bytearray(), bytearray()
    for name in SECTIONS:
        if name == 'page0':
            data += bytes(-(off + len(data)) % 256)     # to a sector boundary
        o = off + len(data)
        table += bytes([o & 255, o >> 8])
        data += body[name]
    out = bytes(table + data)
    assert len(out) % 256 == 0
    assert len(out) - PAGE0_LEN <= STAGE_LVL_B or MASTERONLY, ('too big for the Model B\'s stage', len(out))
    assert len(out) <= STAGE_M, ('too big for the Master\'s stage', len(out))
    return out


def decode(data, boxid0, boxn):
    """the sections by name (the map unpacked, the header's fields as well); boxid0 and
    boxn, the game's, say how long the directory is: the padding to LV_PAGE0's sector
    follows it, as 'pad'"""
    offs = [data[2 * i] | data[2 * i + 1] << 8 for i in range(len(SECTIONS))]
    ends = offs[1:] + [len(data)]
    sec = {n: data[o:e] for n, o, e in zip(SECTIONS, offs, ends)}
    sec['page0'] = sec['page0'][:PAGE0_LEN]
    n = dir_len(boxid0, boxn)
    sec['pad'] = sec['dir'][n:]                     # (to LV_PAGE0's sector)
    sec['dir'] = sec['dir'][:n]
    h = sec['hdr']
    sec['map'] = unrle(sec['map'], 1 << (h[HDR_LW] + h[HDR_LH]))
    sec['fields'] = dict(lw=h[HDR_LW], lh=h[HDR_LH], nobj=h[HDR_NOBJ],
                         **{f: h[HDR_SHAPE + i] for i, f in enumerate(SHAPE_FIELDS) if f != 'zero'})
    return sec


# ---------------------------------------------------------------- the loader's constants
def inc():
    lines = ['; generated by beebgame/tools/levelfile.py: the level file\'s sections and header']
    lines += ['SEC_%s = %d' % (n.upper(), i) for i, n in enumerate(SECTIONS)]
    lines += ['HDR_LW = %d' % HDR_LW, 'HDR_LH = %d' % HDR_LH, 'HDR_NOBJ = %d' % HDR_NOBJ]
    lines += ['%s = %d' % kv for kv in HDR.items()]
    lines += ['LV_PAGE0_SECS = %d' % (PAGE0_LEN // 256)]
    return '\n'.join(lines) + '\n'


def check(data, boxid0, boxn):
    """a level file's invariants, as the loader relies on them: the table, the sections
    in order, the header's counts against the sections, the map whole, LV_PAGE0 last and
    sector aligned; returns the decoded sections"""
    assert len(data) % 256 == 0, 'not whole sectors'
    offs = [data[2 * i] | data[2 * i + 1] << 8 for i in range(len(SECTIONS))]
    assert offs[0] == 2 * len(SECTIONS) and offs == sorted(offs), 'the section table'
    assert offs[SEC['page0']] % 256 == 0 and len(data) - offs[SEC['page0']] == PAGE0_LEN, 'LV_PAGE0'
    assert (len(data) - PAGE0_LEN <= STAGE_LVL_B or MASTERONLY) and len(data) <= STAGE_M, 'too big for a stage'
    sec = decode(data, boxid0, boxn)
    f = sec['fields']
    assert len(sec['objs']) == OBJ_BYTES * f['nobj'] and f['nobj'] <= OBJ_MAX, 'the objects'
    assert len(sec['map']) == 1 << (f['lw'] + f['lh']), 'the map'
    assert f['mapshr'] == 8 - f['lw'], 'mapshr'
    assert len(sec['attr']) == 256 and len(sec['altcls']) == 256, 'the tile tables'
    assert len(sec['halves']) == 2 * f['nhalf'], 'the half tiles'
    assert len(sec['mir']) == f['nmir'], 'MIRTAB'
    assert len(sec['dir']) == dir_len(boxid0, boxn), 'the directory'
    assert not any(sec['pad']) and len(sec['pad']) < 256, 'the padding before LV_PAGE0'
    p = sec['place']
    assert len(p) % 6 == 1 and p[-1] == 0xFF and all(p[i + 1] in (4, 5) for i in range(0, len(p) - 1, 6)), 'the placements'
    return sec


if __name__ == '__main__':
    if sys.argv[1:] == ['inc']:
        sys.stdout.write(inc())
    elif sys.argv[1:2] == ['check'] and len(sys.argv) > 3:
        consts = dict(re.findall(r'^(\w+) = \$?(\w+)', open(sys.argv[2]).read(), re.M))
        boxid0, boxn = int(consts['BOXID0']), int(consts['BOXN'])
        for fn in sys.argv[3:]:
            try:
                check(open(fn, 'rb').read(), boxid0, boxn)
            except AssertionError as e:
                sys.exit('%s: %s' % (fn, e))
        print('levelfile: %d level files check' % (len(sys.argv) - 3))
    else:
        sys.exit('usage: levelfile.py inc | check <assets.inc> <level file>...')
