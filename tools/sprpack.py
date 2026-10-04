"""Place the sprites' images in a bank: the order and padding that cost the sprite loops least.

The cost is page crossings.  A sprite's row loop (engine/sprloops.s) walks its source pointer
across the image a column (`lines` bytes) at a time, and every page boundary the pointer
crosses takes the out-of-line carry path (spr_pinc: CARRY cycles over falling through; the
mirrored walk's borrow, spr_mdec, BORROW).  Row r's walk starts at base + 8r less the
sprite's line phase (the low three bits of its first line, which is anything), so a
placement's cost is the carries a draw expects averaged over the eight phases, at the base's
offset in its page.  A (zp),Y read whose index runs into the next page costs as well: READ
cycles a draw for each page boundary inside the image.

A bank's run of sprites is a list of items -- each image on its own -- in some order, with
padding before any of them.  optimise() swaps and moves items and moves padding, keeping
every change that does not raise the draws-weighted cost, within the run's room.  The search
is deterministic (seeded from its inputs) and cached (build/sprpack.cache, through
load_cache/save_cache), so the same items in the same room come back the same without the
search.  tools/assets.py is the caller.
"""
import hashlib, json, os, random

# cycles: the carry path over falling through (sprloops.s spr_pinc)
CARRY = 9.0
# the mirrored walk's borrow path (spr_mdec's dec ptr+1)
BORROW = 7.0
# cycles a draw: the (zp),Y reads past a page boundary inside an image
READ = 3.5
# the cache's format: part of every signature, so a change here discards old entries
VERSION = 2
_tables = {}


def _walk(o, cols, step, rstep, rows_of, phases):
    """The page crossings a draw expects, averaged over the phases: for each phase ph, each of
    rows_of(ph) rows walks from o + rstep*r - ph across cols*step bytes."""
    tot = 0
    for ph in range(phases):
        for r in range(rows_of(ph)):
            p = o + rstep * r - ph
            tot += (p + cols * step) // 256 - p // 256
    return tot / phases


def image_table(W, L, mirrored=False):
    """The cost a draw (cycles) of an image W columns by L lines at each of the 256 page
    offsets of its base: the walk from the first column up, or (mirrored) from the last
    column down -- the same span one column lower, at the borrow path's price -- plus the
    reads across each page boundary inside the image.  Memoised."""
    k = ('img', W, L, mirrored)
    if k not in _tables:
        n = W * L
        rows = lambda ph: (L + ph + 7) // 8
        if mirrored:
            walk = [_walk(o - L, W, L, 8, rows, 8) for o in range(256)]
            _tables[k] = [BORROW * walk[o] + READ * ((o + n - 1) // 256 - o // 256) for o in range(256)]
        else:
            _tables[k] = [CARRY * _walk(o, W, L, 8, rows, 8) + READ * ((o + n - 1) // 256 - o // 256)
                          for o in range(256)]
    return _tables[k]


def cost(items, lo, order, pads):
    """The draws-weighted cost of laying the items out from lo in this order, pads[i] bytes
    before the i-th: each item's weight times its table at its base's page offset (an item
    with no table is free)."""
    a, c = lo, 0.0
    for i, idx in enumerate(order):
        a += pads[i]
        it = items[idx]
        if it['table'] is not None:
            c += it['w'] * it['table'][a & 255]
        a += it['size']
    return c


def optimise(items, lo, hi, cache=None, iters=None, pad_penalty=1e-3):
    """Place the items in [lo, hi): items are dicts with key, size, w (draws a frame) and
    table (256 costs by page offset, or None: free).  A random search of swaps, moves and
    padding changes, iters steps (3000 + 600 n by default), accepts every change that does
    not raise cost + pad_penalty * padding; the cache, keyed by a hash of the inputs, short-
    cuts it.  Returns ({key: address}, cost before, cost after, the end address), the costs
    in cycles a frame."""
    n = len(items)
    room = hi - lo - sum(it['size'] for it in items)
    assert room >= 0, ('does not fit', hi - lo, room)
    base_order, base_pads = list(range(n)), [0] * n
    before = cost(items, lo, base_order, base_pads)
    sig = json.dumps([VERSION, lo, hi, [(repr(it['key']), it['size'], round(it['w'], 4),
                                         hashlib.sha1(json.dumps(it['table']).encode()).hexdigest()[:8] if it['table'] else None)
                                        for it in items]])
    h = hashlib.sha1(sig.encode()).hexdigest()
    got = cache.get(h) if cache is not None else None
    if got:
        order, pads = got
    else:
        rnd = random.Random(h)
        order, pads = base_order[:], base_pads[:]
        best = cost(items, lo, order, pads) + pad_penalty * sum(pads)
        steps = iters or (3000 + 600 * n)
        for _ in range(steps):
            o2, p2 = order[:], pads[:]
            mv = rnd.random()
            if mv < 0.3 and n > 1:
                # swap two items
                i, j = rnd.randrange(n), rnd.randrange(n)
                o2[i], o2[j] = o2[j], o2[i]
            elif mv < 0.55 and n > 1:
                # move one item
                i, j = rnd.randrange(n), rnd.randrange(n)
                o2.insert(j, o2.pop(i))
            elif mv < 0.85:
                # more or less padding before one item, within the room
                i = rnd.randrange(n)
                d = rnd.choice((-8, -4, -2, -1, 1, 2, 4, 8, 16, 32))
                v = p2[i] + d
                if v < 0 or sum(p2) - p2[i] + v > room:
                    continue
                p2[i] = v
            else:
                # padding moved from one item to another
                i, j = rnd.randrange(n), rnd.randrange(n)
                d = rnd.randint(1, 32)
                if p2[i] < d:
                    continue
                p2[i] -= d; p2[j] += d
            c = cost(items, lo, o2, p2) + pad_penalty * sum(p2)
            if c <= best:
                best, order, pads = c, o2, p2
        if cache is not None:
            cache[h] = (order, pads)
    addr, a = {}, lo
    for i, idx in enumerate(order):
        a += pads[i]
        addr[items[idx]['key']] = a
        a += items[idx]['size']
    assert a <= hi
    return addr, before, cost(items, lo, order, pads), a


def load_cache(path):
    """The cache from its JSON file, {hash: (order, pads)}; empty if the file is missing or
    unreadable."""
    try:
        with open(path) as f:
            return {k: tuple(v) for k, v in json.load(f).items()}
    except (OSError, ValueError):
        return {}


def save_cache(cache, path):
    """Write the cache as JSON, through a temporary file and a rename."""
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(cache, f)
    os.replace(tmp, path)
