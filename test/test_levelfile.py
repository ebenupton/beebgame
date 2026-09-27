"""tools/levelfile.py: the level file's writer against its reader, the run length code,
and the loader's use of its constants.   python3 -m unittest discover beebgame/test"""
import os, random, re, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import levelfile as lf


def level(**kw):
    lw, lh = kw.pop('lw', 5), kw.pop('lh', 4)
    rnd = random.Random(1)
    d = dict(lw=lw, lh=lh, shape=lf.Shape(ntiles=40, mapshr=8 - lw, nhalf=2, half0=30, half1=31,
                                          half2=32, halfpage=0x90, halfoff=3, solidfill=0x0F),
             objects=bytes(rnd.randrange(256) for _ in range(6 * 7)),
             tile_tables=(bytes(range(256)), bytes(255 - i for i in range(256))),
             tiles=b'\x01\x02\x03', placement=lf.placement([(1, 4, 0x9000, 0x9100), (7, 5, 0x8400, 0)]),
             map=bytes(rnd.choice((0, 0, 0, 1, 2, 3)) for _ in range(1 << (lw + lh))),
             flat=b'\x0f\x0f', halves=b'\x05\x01\x06\x03', hpair=b'\x33\x33', mir=b'',
             page0=bytes(range(256)) * 2, game_header={2: 9, 3: 8, 7: 1})
    ents = [None] * lf.DIR_N
    ents[1] = (0x9000, 4, bytes([3, 12, 0, 0, 2, 24]))
    ents[7] = (0x8400, 5, bytes([2, 8, 0, 0, 2 | 8, 16]))
    d['directory'], d['masks'] = lf.directory(ents, [0x9100 if i == 1 else 0 for i in range(lf.MASK_N)])
    d.update(kw)
    return lf.Level(**d)


class RLE(unittest.TestCase):
    def test_round_trip(self):
        rnd = random.Random(2)
        cases = [b'', b'\x00', b'\x00' * 129, b'\x00' * 130, b'\x00' * 400, bytes(range(256)) * 3,
                 bytes(rnd.randrange(4) for _ in range(5000)), b'\x01\x02\x02\x03\x03\x03']
        for c in cases:
            self.assertEqual(lf.unrle(lf.rle(c)), c)

    def test_codes_in_range(self):
        # a run is 2..129 (c = 128..255), a literal 1..128 (c = 0..127)
        e = lf.rle(b'\x07' * 1000 + bytes(range(200)))
        i = 0
        while i < len(e):
            c = e[i]
            i += (2 if c >= 128 else c + 2)
        self.assertEqual(i, len(e))


class File(unittest.TestCase):
    def test_encode_decode(self):
        lv = level()
        data = lf.encode(lv)
        sec = lf.check(data)
        self.assertEqual(sec['map'], lv.map)
        self.assertEqual(sec['objs'], lv.objects)
        self.assertEqual(sec['dir'], lv.directory)
        self.assertEqual(sec['smask'], lv.masks)
        self.assertEqual(sec['page0'], lv.page0)
        f = sec['fields']
        self.assertEqual((f['lw'], f['lh'], f['nobj'], f['nhalf'], f['solidfill']), (5, 4, 7, 2, 0x0F))
        self.assertEqual(sec['hdr'][2:4], bytes([9, 8]))

    def test_page0_last_and_aligned(self):
        data = lf.encode(level())
        off = data[26] | data[27] << 8
        self.assertEqual(off % 256, 0)
        self.assertEqual(len(data) - off, lf.PAGE0_LEN)

    def test_directory_bank5_flag(self):
        sec = lf.decode(lf.encode(level()))
        self.assertTrue(sec['dir'][7 * 8 + 6] & lf.DIR_BANK5)
        self.assertFalse(sec['dir'][1 * 8 + 6] & lf.DIR_BANK5)

    def test_engine_header_fields_are_protected(self):
        for o in (0, 1, 6, 20, 31):
            with self.assertRaises(AssertionError):
                lf.encode(level(game_header={o: 1}))

    def test_limits(self):
        with self.assertRaises(AssertionError):
            lf.encode(level(objects=bytes(6 * (lf.OBJ_MAX + 1))))
        with self.assertRaises(AssertionError):
            lf.encode(level(map=b'\x00'))


class Loader(unittest.TestCase):
    def test_loader_uses_only_defined_constants(self):
        with open(os.path.join(HERE, '..', 'src', 'ldprog.s')) as f:
            src = f.read()
        defined = set(re.findall(r'^(\w+) =', lf.inc(), re.M))
        used = set(re.findall(r'\b((?:SEC|HDR)_\w+)\b', src))
        self.assertTrue(used, 'the loader names no section')
        self.assertLessEqual(used, defined)
        self.assertNotRegex(src, r'lda #\d+\s*(;[^\n]*)?\n\s*jsr section', 'a section by number')


if __name__ == '__main__':
    unittest.main()
