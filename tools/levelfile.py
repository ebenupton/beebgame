"""beebgame's level files: the format the load-time program (src/ldprog.s lv_load) reads.

A game's packer writes a level in the engine's terms through Level and encode().  This file
is the one definition of the format: the section order, the header's fields and the
constants below are also what the loader assembles against (`python3 levelfile.py inc`
writes levelfmt.inc, which ldprog.s includes), so the two cannot drift apart.

A level file is a table of section offsets (two bytes each, from the file's start), then the
sections in SECTIONS order.  The header may carry a tail of the game's own bytes
(Level.header_tail): the loader copies the whole section to LV_HDR, so the tail lands at
LV_HDR + HDR_LEN, where the game keeps memory for it.  The last section, LV_PAGE0 (the
Master's tile gather table), is PAGE0_LEN bytes at a sector boundary at the end, so the
Model B's loader reads the file short of it.  The whole file is whole sectors.

    import levelfile as lf
    data = lf.encode(lf.Level(lw=5, lh=5, game_header={2: x, ...}, shape=lf.Shape(...),
                              objects=b'...', tile_tables=(attr, altcls), tiles=b'...',
                              placement=lf.placement([(item, bank, img, extra), ...]),
                              map=b'...', flat=b'...', halves=b'...', hpair=b'...', mir=b'',
                              directory=lf.directory([None | (addr, bank), ...]),
                              page0=b'...', boxid0=103, boxn=15))
    lf.decode(data, 103, 15)    # the sections back, the map unpacked: for checks
(DIRSPLIT, the build option: the directory section holds the ids from RES_N alone --
directory(entries[res_n:]), Level(..., res_n=RES_N) -- the resident ids' part being the
game's, loaded once with its resident sprites.)

Usage from the command line:
    python3 levelfile.py inc                             # levelfmt.inc to stdout
    python3 levelfile.py check <assets.inc> <level file>...   # check() each; BOXID0 and BOXN
                                                               # from the game's assets.inc
                                                               # (and RES_N, when DIRSPLIT=1)
"""
from dataclasses import dataclass, field
import os, re, sys

# ---------------------------------------------------------------- the sections
SECTIONS = ('hdr', 'objs', 'attr', 'altcls', 'tiles', 'place', 'map', 'flat', 'halves',
            'hpair', 'mir', 'dir', 'page0')
SEC = {n: i for i, n in enumerate(SECTIONS)}

# ---------------------------------------------------------------- the header, 32 bytes (LV_HDR)
HDR_LEN = 32
# log2 of the map's width and height in tiles
HDR_LW, HDR_LH = 0, 1
# the objects' count (the loader copies OBJ_BYTES each)
HDR_NOBJ = 6
# the tile set's shape, 12 bytes (Shape)
HDR_SHAPE = 20
# the game's own fields
HDR_GAME = tuple(range(2, 6)) + tuple(range(7, 20))
SHAPE_FIELDS = ('zero', 'ntiles', 'map_shr', 'nhalf', 'half0', 'half1', 'half2', 'halfpage',
                'halfoff', 'mir0', 'nmir', 'solidfill')
HDR = {'HDR_' + f.upper(): HDR_SHAPE + i for i, f in enumerate(SHAPE_FIELDS) if f != 'zero'}


@dataclass
class Shape:
    """The tile set as the blitter and the loader take it: the stored tile count, the map's
    row shift (8 - lw), the half tiles (count, the three range boundaries half0..half2, the
    page they are in and HALFOFF), two bytes the format keeps from the removed mirrored tiles
    (mir0: the id the halves end at; nmir: 0), and the solid's fill byte (id 0).  encode()
    gives the 12 header bytes: a zero, then the fields in SHAPE_FIELDS order."""
    ntiles: int
    map_shr: int
    nhalf: int = 0
    half0: int = 0
    half1: int = 0
    half2: int = 0
    # the page's high byte
    halfpage: int = 0
    halfoff: int = 0
    mir0: int = 0
    nmir: int = 0
    solidfill: int = 0

    def encode(self):
        """The shape's 12 header bytes."""
        return bytes([0] + [getattr(self, f) & 255 for f in SHAPE_FIELDS[1:]])


# ---------------------------------------------------------------- the limits (src/defs.inc)
# LV_OBJS: OBJ_BYTES * OBJ_MAX = 894 bytes of main RAM (levelfmt.inc carries both)
OBJ_BYTES, OBJ_MAX = 6, 149
# the Model B's level stage, LV_OBJS - STAGE_LVL (the file short of LV_PAGE0)
STAGE_LVL_B = 0x7C00 - 0x5C00
# the Master's stage, its STAGE_LVL to the banks (the whole file)
STAGE_M = 0x8000 - 0x3000
# the build's: no Model B, so no limit of its
MASTERONLY = os.environ.get('MASTERONLY') == '1'
PAGE0_LEN = 512


def dir_len(boxid0, boxn, res_n=0):
    """The directory section's length: 2 bytes a sprite id, BOXID0 + BOXN ids (the game's
    counts, from its assets.inc), less the RES_N resident ids under DIRSPLIT (their entries
    are not the level's: the game loads them once, with its resident sprites)."""
    return 2 * (boxid0 + boxn - res_n)


# ---------------------------------------------------------------- the map's run length code
# a code byte c < RLE_LIT_MAX: c+1 literal bytes follow
RLE_LIT_MAX = 128
# else the next byte repeats c - RLE_RUNBASE times (2..129)
RLE_RUNBASE = 126


def rle(data):
    """Run-length encode: runs of 2..129 equal bytes as (RLE_RUNBASE + run, byte); the rest
    as literal blocks of up to RLE_LIT_MAX bytes, each cut short where a run of three
    begins."""
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        j = i
        while j + 1 < n and data[j + 1] == data[i] and j - i < RLE_LIT_MAX:
            j += 1
        run = j - i + 1
        if run >= 2:
            out += bytes([RLE_RUNBASE + run, data[i]]); i += run; continue
        j = i
        while j < n and j - i < RLE_LIT_MAX and not (j + 2 < n and data[j] == data[j + 1] == data[j + 2]):
            j += 1
        out += bytes([j - i - 1]) + data[i:j]; i = j
    return bytes(out)


def unrle(data, n=None):
    """Decode rle()'s output; with n, stop once n bytes are out."""
    out, i = bytearray(), 0
    while i < len(data) and (n is None or len(out) < n):
        c = data[i]; i += 1
        if c < RLE_LIT_MAX:
            out += data[i:i + c + 1]; i += c + 1
        else:
            out += bytes([data[i]]) * (c - RLE_RUNBASE); i += 1
    return bytes(out)


# ---------------------------------------------------------------- the sprites' sections
# a placement entry: item, bank, image address (2), extra (2)
PLACE_LEN = 6
PL_ITEM, PL_BANK, PL_ADDR, PL_EXTRA = 0, 1, 2, 4
# the item byte that ends the list
PL_END = 0xFF


def placement(items):
    """The placement section: (item, bank, image address, extra) for each item the level
    places from the shared files, in the order given, PL_END after them.  extra is 0, or for
    an item the loader bakes (ldprog.s bake) its tile: x | y << 8.  Banks are 4 or 5."""
    out = bytearray()
    for item, bank, img, extra in items:
        assert 0 <= item < PL_END and bank in (4, 5), (item, bank)
        out += bytes([item, bank, img & 255, img >> 8, extra & 255, extra >> 8])
    return bytes(out + bytes([PL_END]))


def directory(entries):
    """The directory section (DIR_TABLE, the directory's level part): for every sprite id,
    None or (address, bank).  The addresses' low bytes, then their high bytes -- 0 for None,
    bit 7 cleared for bank 5 (every image is at $8000..$BFFF, so bit 7 is set in the address
    itself and its absence marks the bank).  A bank-5 image at $80xx would read as none, so
    it is refused.  The geometry is the game's own tables (sprg_*), the same in every
    level."""
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
    """A level as the packer hands it to encode(): the engine's fields, and the game's own
    bytes where the format leaves room for them (game_header, header_tail, objects, the tile
    tables)."""
    lw: int
    lh: int
    shape: Shape
    # OBJ_BYTES each: the game's (copied to LV_OBJS)
    objects: bytes
    # two 256-byte tables by tile id: the game's (LV_ATTR0, LV_ALTCLS)
    tile_tables: tuple
    # the tile list: the files, each with its full tiles' indices
    tiles: bytes
    # placement()
    placement: bytes
    # 1 << (lw + lh) tile ids, row major
    map: bytes
    # FLATTAB's pairs
    flat: bytes
    # the half tiles, two bytes each: the index in its file, then the stored row's bit |
    # (the file's place in the tile list) << 1
    halves: bytes
    # the halves' fill palette (8 first bytes, 8 second), then each half's low bits (fill
    # row, colour)
    hpair: bytes
    # section 10, empty: the format keeps the removed mirrored tiles' slot
    mir: bytes
    # directory()
    directory: bytes
    # LV_PAGE0: the Master's gather table, PAGE0_LEN bytes
    page0: bytes
    # the game's sprite ids: BOXID0 images, then BOXN boxes (its assets.inc)
    boxid0: int = 0
    boxn: int = 0
    # DIRSPLIT: the resident ids (0 .. res_n-1), whose entries the directory leaves out
    res_n: int = 0
    # offset -> byte, HDR_GAME offsets only
    game_header: dict = field(default_factory=dict)
    # the game's bytes after the header: the loader copies them on to LV_HDR + HDR_LEN
    header_tail: bytes = b''


def header(lv):
    """The header section: HDR_LEN bytes (lw, lh, the object count, the game's fields, the
    shape) followed by the game's tail.  The loader copies the section whole, its length
    from the section table's low bytes, so the whole must stay under a page."""
    h = bytearray(HDR_LEN)
    h[HDR_LW], h[HDR_LH] = lv.lw, lv.lh
    assert len(lv.objects) % OBJ_BYTES == 0 and len(lv.objects) // OBJ_BYTES <= OBJ_MAX
    h[HDR_NOBJ] = len(lv.objects) // OBJ_BYTES
    for o, v in lv.game_header.items():
        assert o in HDR_GAME, 'header byte %d is the engine\'s' % o
        h[o] = v
    h[HDR_SHAPE:] = lv.shape.encode()
    assert HDR_LEN + len(lv.header_tail) < 256, 'the header\'s tail is too long'
    return bytes(h) + lv.header_tail


def encode(lv):
    """The level file: the section table, then the sections, the map run-length coded,
    LV_PAGE0 padded to a sector boundary.  Checks the sizes against the map, the directory,
    PAGE0_LEN and the two machines' stages."""
    assert len(lv.map) == 1 << (lv.lw + lv.lh), (len(lv.map), lv.lw, lv.lh)
    assert all(len(t) == 256 for t in lv.tile_tables) and len(lv.tile_tables) == 2
    assert lv.boxid0 > 0 and len(lv.directory) == dir_len(lv.boxid0, lv.boxn, lv.res_n)
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
            # pad to a sector boundary
            data += bytes(-(off + len(data)) % 256)
        o = off + len(data)
        table += bytes([o & 255, o >> 8])
        data += body[name]
    out = bytes(table + data)
    assert len(out) % 256 == 0
    assert len(out) - PAGE0_LEN <= STAGE_LVL_B or MASTERONLY, ('too big for the Model B\'s stage', len(out))
    assert len(out) <= STAGE_M, ('too big for the Master\'s stage', len(out))
    return out


def decode(data, boxid0, boxn, res_n=0):
    """The sections by name, the map unpacked and the header's fields under 'fields' (lw, lh,
    nobj and the shape's).  boxid0 and boxn, the game's (and res_n, DIRSPLIT's), say how long
    the directory is: the padding between it and LV_PAGE0's sector follows as 'pad'."""
    offs = [data[2 * i] | data[2 * i + 1] << 8 for i in range(len(SECTIONS))]
    ends = offs[1:] + [len(data)]
    sec = {n: data[o:e] for n, o, e in zip(SECTIONS, offs, ends)}
    sec['page0'] = sec['page0'][:PAGE0_LEN]
    n = dir_len(boxid0, boxn, res_n)
    sec['pad'] = sec['dir'][n:]
    sec['dir'] = sec['dir'][:n]
    h = sec['hdr']
    sec['map'] = unrle(sec['map'], 1 << (h[HDR_LW] + h[HDR_LH]))
    sec['fields'] = dict(lw=h[HDR_LW], lh=h[HDR_LH], nobj=h[HDR_NOBJ],
                         **{f: h[HDR_SHAPE + i] for i, f in enumerate(SHAPE_FIELDS) if f != 'zero'})
    return sec


# ---------------------------------------------------------------- the loader's constants
def inc():
    """levelfmt.inc: the section numbers (SEC_*), the header's offsets (HDR_*), HDR_LEN,
    the object record, the placement entry's layout, the run-length constants and
    LV_PAGE0's sector count, as ca65 equates."""
    lines = ['; generated by beebgame/tools/levelfile.py: the level file\'s sections and header']
    lines += ['SEC_%s = %d' % (n.upper(), i) for i, n in enumerate(SECTIONS)]
    lines += ['HDR_LW = %d' % HDR_LW, 'HDR_LH = %d' % HDR_LH, 'HDR_NOBJ = %d' % HDR_NOBJ]
    lines += ['%s = %d' % kv for kv in HDR.items()]
    lines += ['HDR_LEN = %d' % HDR_LEN, 'OBJ_BYTES = %d' % OBJ_BYTES, 'OBJ_MAX = %d' % OBJ_MAX]
    lines += ['PLACE_LEN = %d' % PLACE_LEN, 'PL_ITEM = %d' % PL_ITEM, 'PL_BANK = %d' % PL_BANK,
              'PL_ADDR = %d' % PL_ADDR, 'PL_EXTRA = %d' % PL_EXTRA, 'PL_END = $%02X' % PL_END]
    lines += ['RLE_LIT_MAX = %d' % RLE_LIT_MAX, 'RLE_RUNBASE = %d' % RLE_RUNBASE]
    lines += ['LV_PAGE0_SECS = %d' % (PAGE0_LEN // 256)]
    return '\n'.join(lines) + '\n'


def check(data, boxid0, boxn, res_n=0):
    """A level file's invariants, as the loader relies on them: whole sectors; the section
    table in order, starting after itself; LV_PAGE0 last, sector aligned, PAGE0_LEN long;
    the stages' limits; the header's counts against the sections; the map whole and
    map_shr = 8 - lw; the tile tables, halves, mir and directory sizes; zero padding before
    LV_PAGE0; the placements whole, ended by PL_END, their banks 4 or 5.  Returns the
    decoded sections; raises AssertionError with the failing invariant's name."""
    assert len(data) % 256 == 0, 'not whole sectors'
    offs = [data[2 * i] | data[2 * i + 1] << 8 for i in range(len(SECTIONS))]
    assert offs[0] == 2 * len(SECTIONS) and offs == sorted(offs), 'the section table'
    assert offs[SEC['page0']] % 256 == 0 and len(data) - offs[SEC['page0']] == PAGE0_LEN, 'LV_PAGE0'
    assert (len(data) - PAGE0_LEN <= STAGE_LVL_B or MASTERONLY) and len(data) <= STAGE_M, 'too big for a stage'
    sec = decode(data, boxid0, boxn, res_n)
    f = sec['fields']
    assert len(sec['objs']) == OBJ_BYTES * f['nobj'] and f['nobj'] <= OBJ_MAX, 'the objects'
    assert len(sec['map']) == 1 << (f['lw'] + f['lh']), 'the map'
    assert f['map_shr'] == 8 - f['lw'], 'map_shr'
    assert len(sec['attr']) == 256 and len(sec['altcls']) == 256, 'the tile tables'
    assert len(sec['halves']) == 2 * f['nhalf'], 'the half tiles'
    assert len(sec['mir']) == f['nmir'], 'MIRTAB'
    assert len(sec['dir']) == dir_len(boxid0, boxn, res_n), 'the directory'
    assert not any(sec['pad']) and len(sec['pad']) < 256, 'the padding before LV_PAGE0'
    p = sec['place']
    assert len(p) % PLACE_LEN == 1 and p[-1] == PL_END and all(p[i + PL_BANK] in (4, 5) for i in range(0, len(p) - 1, PLACE_LEN)), 'the placements'
    return sec


if __name__ == '__main__':
    if sys.argv[1:] == ['inc']:
        sys.stdout.write(inc())
    elif sys.argv[1:2] == ['check'] and len(sys.argv) > 3:
        consts = dict(re.findall(r'^(\w+) = \$?(\w+)', open(sys.argv[2]).read(), re.M))
        boxid0, boxn = int(consts['BOXID0']), int(consts['BOXN'])
        if os.environ.get('DIRSPLIT') == '1' and 'RES_N' not in consts:
            sys.exit('levelfile: DIRSPLIT=1 needs the game\'s RES_N (assets.inc): its packer numbers the resident ids first')
        res_n = int(consts['RES_N']) if os.environ.get('DIRSPLIT') == '1' else 0
        for fn in sys.argv[3:]:
            try:
                check(open(fn, 'rb').read(), boxid0, boxn, res_n)
            except AssertionError as e:
                sys.exit('%s: %s' % (fn, e))
        print('levelfile: %d level files check' % (len(sys.argv) - 3))
    else:
        sys.exit('usage: levelfile.py inc | check <assets.inc> <level file>...')
