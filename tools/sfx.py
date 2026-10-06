"""beebgame's sound effects (SOUND6): a game's effects, packed for the engine's player
(src/engine/sound6.s, bank 6).

    python3 tools/sfx.py EFFECTS.py [out.inc]     # $BD/sfxdata.inc by default (build.sh runs it,
                                                  #  EFFECTS.py being the game's GAME_SFX)
    python3 tools/sfx.py check EFFECTS.py [stream.json]

EFFECTS.py is Python that sets EFFECTS, run with S, KEEP and the noise nibbles below defined:
a list, in id order, of (name, priority 1..15, [(voice, script), ...]) -- or (name, other)
for a second name for another effect.  The packed file defines SFX_<NAME> = id for each,
which the game passes to sfx_request.  The voices are 0-2, the tone channels, and 3, the
noise.  A script is segments, S(frames, period, level, dlevel, step, jitter): for `frames`
vsyncs the voice holds `period` (the SN76489's 10-bit tone period, 125000 / Hz; on the noise
voice the control nibble: NW_*, NP_*) and `level` (0..254; 16 a 2 dB step), stepping the
period by `step` and the level by `dlevel` each vsync after the first (the period held to
0..1023, the level to 0..255), and with `jitter` set, random bits into the period's low byte
where it has ones.  KEEP for the period or the level carries on from the segment before.  A
voice takes a script when idle or when the effect's priority is at least its current one;
effects asked for in one vsync start in the order 16-23, 8-15, 0-7 (SFXBITS' bytes from the
last, each byte's bits from bit 0).

The packed form (sfxdata.inc, assembled into sound6.s):
  sfx_fxtab  an effect's header, by id: its offset in sfx_fxhdr
  sfx_fxhdr  a header: priority << 4 | the voices' mask (bit n voice n), then each voice's
             script, lowest voice first, as an offset in sfx_scr
  sfx_scr    the scripts, at most 256 bytes (a voice's place is one byte); sfx_scr+0 is 0,
             the end a voice goes to after its last segment.  A segment: its head, shape
             << 4 | the frames' index (never 0), then the fields its shape has, in the
             order FIELDS -- each one only where it changes what the voice holds, which
             starting an effect leaves as period high 0, step 0, jitter 0, the rest unknown
  sfx_mtab   a shape: bit 7 the script's last segment, bits 6..1 FIELDS present (16 at most)
  sfx_frtab  the frames, by index (16 at most)
`check` runs soundtest.mjs's schedule through a model of the player on the definitions and
one on the packed bytes and compares what the chip is given; with a stream recorded by
soundtest.mjs, that too.  At most 24 effects (SFXBITS: three bytes).
"""
import json, os, sys

KEEP = None
NW_HI, NW_MID, NW_LO, NW_T2 = 4, 5, 6, 7   # white noise: fixed rates; clocked by tone 2
NP_HI, NP_LO, NP_T2 = 0, 2, 3              # periodic (buzzing) noise


def S(frames, period, level, dlevel, step, jitter):
    assert 0 < frames < 256 and (period is KEEP or 0 <= period < 1024)
    assert level is KEEP or 0 <= level < 255
    return dict(fr=frames, per=period, lvl=level, dl=dlevel & 255, stp=step & 255, jit=jitter)


EFFECTS = []


def load(path):
    """The game's EFFECTS, from its file."""
    g = dict(S=S, KEEP=KEEP, NW_HI=NW_HI, NW_MID=NW_MID, NW_LO=NW_LO, NW_T2=NW_T2,
             NP_HI=NP_HI, NP_LO=NP_LO, NP_T2=NP_T2, __file__=path)
    exec(compile(open(path).read(), path, 'exec'), g)
    EFFECTS[:] = g['EFFECTS']
    assert 0 < len(EFFECTS) <= 24, 'sfx: 1 to 24 effects (SFXBITS is three bytes)'


FIELDS = ('plo', 'phi', 'lvl', 'dl', 'stp', 'jit')   # sound6.s SV_F's order; sfx_mtab bits 6..1
CH = (0x00, 0x20, 0x40, 0x60)


def effects():
    """[(name, prio, [(voice, segments)])] by id, an alias resolved to its effect's."""
    by = {e[0]: e for e in EFFECTS if len(e) == 3}
    return [by[e[1]] if len(e) == 2 else e for e in EFFECTS]


def wants(s):
    """What a segment sets: {field: value}."""
    w = dict(dl=s['dl'], stp=s['stp'], jit=s['jit'])
    if s['per'] is not KEEP:
        w['plo'], w['phi'] = s['per'] & 255, s['per'] >> 8
    if s['lvl'] is not KEEP:
        w['lvl'] = s['lvl']
    return w


def plan(segs):
    """A script's segments as [emit, avail, frames, last]: the fields that change what the
    voice holds, and every field whose value at the load is known (for padding a shape)."""
    known = dict(plo=None, phi=0, lvl=None, dl=None, stp=0, jit=0)
    out = []
    for i, s in enumerate(segs):
        w = wants(s)
        avail = {k: v for k, v in known.items() if v is not None}
        avail.update(w)
        out.append([{k: v for k, v in w.items() if known[k] != v}, avail, s['fr'], i == len(segs) - 1])
        known.update(w)
        if s['stp']:
            known['plo'] = known['phi'] = None      # swept (and held to 0..1023)
        if s['jit']:
            known['plo'] = None
        if s['dl']:
            known['lvl'] = None
    return out


def pack():
    """The packed tables: dict of name -> bytes, and the sizes."""
    effs = effects()
    scripts = {}                                    # (name, voice) -> plan
    for name, prio, voices in effs:
        for v, segs in voices:
            scripts.setdefault((name, v), plan(segs))
    segs = [p for sc in scripts.values() for p in sc]
    key = lambda p: (frozenset(p[0]), p[3])
    # shapes: at most 16 -- the rarest padded into a superset (fields whose values are known)
    while True:
        shapes = {}
        for p in segs:
            shapes.setdefault(key(p), []).append(p)
        if len(shapes) <= 16:
            break
        best = None
        for a, pa in shapes.items():
            for b in shapes:
                if a != b and a[1] == b[1] and a[0] < b[0] and all(b[0] <= set(p[1]) for p in pa):
                    cost = len(pa) * len(b[0] - a[0])
                    if best is None or cost < best[0]:
                        best = (cost, a, b)
        assert best, 'sfx: more than 16 segment shapes, and none can be padded into another'
        for p in shapes[best[1]]:
            p[0] = {k: p[1][k] for k in best[2][0]}
    frames = sorted({p[2] for p in segs})
    assert len(frames) <= 16, 'sfx: more than 16 distinct frame counts'
    order = sorted(shapes, key=lambda k: (-len(shapes[k]), sorted(k[0]), k[1]))
    # no head may be 0 (the end): shape 0 must not meet frames index 0
    for i in range(len(order)):
        if all(p[2] != frames[0] for p in shapes[order[i]]):
            order.insert(0, order.pop(i))
            break
    else:
        raise AssertionError('sfx: every shape has a segment of %d frames' % frames[0])
    si = {k: i for i, k in enumerate(order)}
    mtab = bytes((0x80 if k[1] else 0) | sum(2 << (5 - FIELDS.index(f)) for f in k[0]) for k in order)
    scr = bytearray([0])
    off = {}
    for sk, sc in scripts.items():
        off[sk] = len(scr)
        for p in sc:
            scr.append(si[key(p)] << 4 | frames.index(p[2]))
            scr.extend(p[0][f] for f in FIELDS if f in p[0])
    assert len(scr) <= 256, 'sfx: the scripts are %d bytes, over 256 (SCR is indexed by Y)' % len(scr)
    hdr, fxtab, at = bytearray(), [], {}
    for name, prio, voices in effs:
        if name not in at:
            assert 0 < prio < 16 and len({v for v, _ in voices}) == len(voices)
            at[name] = len(hdr)
            hdr.append(prio << 4 | sum(1 << v for v, _ in voices))
            hdr.extend(off[(name, v)] for v in sorted(v for v, _ in voices))
        fxtab.append(at[name])
    assert len(hdr) <= 256
    return dict(FXTAB=bytes(fxtab), FXHDR=bytes(hdr), SCR=bytes(scr), MTAB=mtab, FRTAB=bytes(frames))


# ---------------------------------------------------------------- the player's models
class Player:
    """sound6.s's player, step for step: requests (SFXBITS, its order), voices, the chip's
    writes.  packed: read the scripts from the tables (the bank 6 player), else from the
    definitions (the player before it)."""

    def __init__(self, packed=None):
        self.t = packed
        self.writes = []
        self.reset()

    def w(self, v):
        self.writes.append((self.tick, v))

    def reset(self):
        self.tick = -1
        self.bits = [0, 0, 0]
        self.dur, self.pri, self.ptr = [0] * 4, [0] * 4, [None] * 4
        self.f = {k: [0] * 4 for k in FIELDS}
        self.rnd = 1
        for v in (3, 2, 1, 0):
            self.w(CH[v] | 0x9F)

    def request(self, e):
        self.bits[e >> 3] |= 1 << (e & 7)

    def start(self, e):
        name, prio, voices = effects()[e]
        if self.t:
            hx = self.t['FXTAB'][e]
            hb = self.t['FXHDR'][hx]
            prio, n = hb >> 4, 0
            for v in range(4):
                if hb >> v & 1:
                    n += 1
                    if prio >= self.pri[v]:
                        self.pri[v], self.ptr[v], self.dur[v] = prio, self.t['FXHDR'][hx + n], 1
                        self.f['phi'][v] = self.f['stp'][v] = self.f['jit'][v] = 0
        else:
            for v, segs in voices:
                if prio >= self.pri[v]:
                    self.pri[v], self.ptr[v], self.dur[v] = prio, (segs, 0), 1

    def vsync(self):
        for x in (2, 1, 0):
            n = x * 8
            while self.bits[x]:
                b = self.bits[x] & 1
                self.bits[x] >>= 1
                if b:
                    self.start(n)
                n += 1
        for v in (3, 2, 1, 0):
            self.voice(v)

    def load(self, v):
        """The next segment into voice v: False at the script's end."""
        f = self.f
        if self.t:
            p = self.ptr[v]
            h = self.t['SCR'][p]
            if h == 0:
                return False
            m = self.t['MTAB'][h >> 4]
            self.dur[v] = self.t['FRTAB'][h & 15]
            p += 1
            for i, k in enumerate(FIELDS):
                if m & (2 << (5 - i)):
                    f[k][v] = self.t['SCR'][p]
                    p += 1
            self.ptr[v] = 0 if m & 0x80 else p
        else:
            segs, i = self.ptr[v]
            if i == len(segs):
                return False
            s = segs[i]
            self.dur[v] = s['fr']
            for k, x in wants(s).items():
                f[k][v] = x
            self.ptr[v] = (segs, i + 1)
        return True

    def voice(self, v):
        f = self.f
        if not self.dur[v]:
            return
        self.dur[v] -= 1
        if not self.dur[v]:
            if not self.load(v):
                self.pri[v] = 0
                self.w(CH[v] | 0x9F)
                return
            self.period(v)
            self.volume(v)
            return
        if f['stp'][v]:
            st = f['stp'][v] - (256 if f['stp'][v] & 128 else 0)
            per = min(1023, max(0, (f['phi'][v] << 8 | f['plo'][v]) + st))
            f['plo'][v], f['phi'][v] = per & 255, per >> 8
            if f['jit'][v]:
                self.jitter(v)
            self.period(v)
        elif f['jit'][v]:
            self.jitter(v)
            self.period(v)
        if f['dl'][v]:
            d = f['dl'][v] - (256 if f['dl'][v] & 128 else 0)
            f['lvl'][v] = min(255, max(0, f['lvl'][v] + d))
            self.volume(v)

    def jitter(self, v):
        r = self.rnd << 1
        if r > 255:
            r = (r & 255) ^ 0x1D
        self.rnd = r
        p, j = self.f['plo'][v], self.f['jit'][v]
        self.f['plo'][v] = p ^ ((p ^ r) & j)

    def period(self, v):
        lo, hi = self.f['plo'][v], self.f['phi'][v]
        if v == 3:
            self.w(lo & 7 | 0xE0)
        else:
            self.w(lo & 15 | CH[v] | 0x80)
            self.w(lo >> 4 | hi << 4)

    def volume(self, v):
        self.w((self.f['lvl'][v] >> 4) ^ 0x9F | CH[v])


def schedule():
    """tools/soundtest.mjs's: every effect alone, then overlapping triples, then a run."""
    n, at, t = len(EFFECTS), {}, 1
    for e in range(n):
        at.setdefault(t, []).append(e); t += 40
    for e in range(n):
        for d, x in ((0, e), (2, (e + 7) % n), (3, (e + 13) % n)):
            at.setdefault(t + d, []).append(x)
        t += 25
    for e in range(60):
        at.setdefault(t, []).append(e * 5 % n); t += 3
    return at, t + 200


def run(player):
    at, end = schedule()
    for tick in range(end):
        player.tick = tick
        for e in at.get(tick, ()):
            player.request(e)
        player.vsync()
    return player.writes


def inc(t):
    """sfxdata.inc: the ids, and the tables."""
    out = ['; generated by beebgame/tools/sfx.py: the game\'s sound effects, packed for sound6.s']
    for i, e in enumerate(EFFECTS):
        out.append('SFX_%s = %d' % (e[0].upper(), i))
    out.append('NSFX = %d' % len(EFFECTS))
    for k in ('FXTAB', 'FXHDR', 'MTAB', 'FRTAB', 'SCR'):
        b = t[k]
        out.append('sfx_%s:' % k.lower())
        for i in range(0, len(b), 16):
            out.append('        .byte ' + ', '.join('$%02X' % x for x in b[i:i + 16]))
    out.append('        .assert sfx_fxhdr = sfx_fxtab + NSFX, error, "sfxdata.inc: soundtest.mjs counts the effects by it"')
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    chk = sys.argv[1:2] == ['check']
    args = sys.argv[2:] if chk else sys.argv[1:]
    load(args[0])
    t = pack()
    if chk:
        a, b = run(Player()), run(Player(t))
        assert a == b, 'sfx: the packed scripts play differently (first at %s)' % (next(
            (i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b))))
        print('sfx: the packed player matches the definitions: %d writes' % len(a))
        if len(args) > 1:
            ref = [tuple(x) for x in json.load(open(args[1]))['writes']]
            assert a == ref, 'sfx: the model differs from the recorded stream (%d vs %d writes; first at %s)' % (
                len(a), len(ref), next((i for i, (x, y) in enumerate(zip(a, ref)) if x != y), None))
            print('sfx: and the recorded stream (%s)' % args[1])
        print('sizes: ' + ', '.join('%s %d' % (k, len(v)) for k, v in t.items()) + ', total %d' % sum(map(len, t.values())))
        sys.exit(0)
    out = args[1] if len(args) > 1 else os.path.join(os.environ.get('BD', 'build'), 'sfxdata.inc')
    open(out, 'w').write(inc(t))
