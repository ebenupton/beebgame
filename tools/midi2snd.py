#!/usr/bin/env python3
"""Convert a MIDI file into the engine's three-voice tune stream (engine/menus.s music_tick).

The stream is stepped once a vsync (50 Hz).  The game puts it in its menus' image at
music_addr; menus.s reads the period table there and the sequence after it.

Usage:
    python3 beebgame/tools/midi2snd.py <in.mid> <out> [<voices>]
    python3 beebgame/tools/midi2snd.py --fx <in.mid> <out> [MEL [BASS [CHORD [SPLIT]]]]   (TUNEFX)

<voices> says where each of the three voices takes its note from, a frame at a time:
"CHANNELS:RANK" three times, joined by "/", CHANNELS a comma-separated list of MIDI
channels and RANK one of max, min, max2 (the second highest) or min2 (the second lowest)
of the notes sounding on those channels.  The default, Cleo's tune, is "1:max/0:min/0:min2":
voice 0 the highest note of channel 1 (the melody), voices 1 and 2 the two lowest of
channel 0 (the backing).

Output: the period table, 72 x 2 bytes (little-endian) for MIDI notes 24..95, the
SN76489's 10-bit period 125000 / f (notes below 47 are transposed up by octaves until their
period fits); then the sequence, 4-byte records (frames, note0, note1, note2: 0 a rest, else
the MIDI note, which the player turns into a table index), run-length merged; then a record
of four zeros, which the player loops at.  A run is capped at 255 frames.  Only the first
tempo meta event is honoured; running status and the common channel messages are decoded,
note-on with velocity 0 counts as note-off.

--fx: the stream for TUNEFX's player (menus.s): a melody, a bass and a chord, each note
struck (an envelope's attack) where the MIDI starts it.  MEL is "CHANNELS:RANK" (default
1:max), BASS likewise (0:min) among the notes below SPLIT (a MIDI note, 55 by default: G3),
CHORD the channels whose notes from SPLIT up -- the highest first, three at most -- make the
chord (0); the bass and the chord ring on through their rests, their envelopes falling to
silence, as plucked strings do.  The split keeps an oom-pah's bass and chord apart: between the bass's notes the
chord's lowest would otherwise be taken for the bass.  The melody plays on
tone 0 with a delayed vibrato, the chord on tone 1 as an arpeggio, the bass on the noise
channel as periodic noise clocked by tone 2 (silent), at the note's own pitch: 15 times
below tone 2's.  Output: the period table as above; the bass table, MUS_NNOTES bytes: tone
2's period for each note's bass, 125000 / (15 f); FXHDR (FX_HDR_LEN bytes): each voice's
envelope -- the melody's, the bass's, the chord's: the level a strike starts at, its fall
a vsync and the level it rests at (0..255, the chip's attenuation its top nibble) -- then
the vibrato (the vsyncs before it, the period's shift for its depth, the vsyncs a step) and
the arpeggio's vsyncs a note; then the records: frames (0: the end, looped), a mask (bit 0
the melody, 1 the bass, 2-4 the chord's notes), and a byte for each bit set: the note
(MUS_NOTE0..), bit 7 set where it is struck, 0 none.
"""
import struct, os, sys

FX = '--fx' in sys.argv
ARGS = [a for a in sys.argv[1:] if a != '--fx']
SRC, OUT = ARGS[0], ARGS[1]
VOICES = []
if FX:
    mel, bass, chord, split = (ARGS[2:] + ['1:max', '0:min', '0', '55'][len(ARGS) - 2:])[:4]
    FXSPLIT = int(split)
    FXMEL = ([int(c) for c in mel.split(':')[0].split(',')], mel.split(':')[1])
    FXBASS = ([int(c) for c in bass.split(':')[0].split(',')], bass.split(':')[1])
    FXCHORD = [int(c) for c in chord.split(',')]
for v in ('1:max/0:min/0:min2' if FX else (ARGS[2] if len(ARGS) > 2 else '1:max/0:min/0:min2')).split('/'):
    chs, rank = v.split(':')
    assert rank in ('max', 'min', 'max2', 'min2'), rank
    VOICES.append(([int(c) for c in chs.split(',')], rank))
assert len(VOICES) == 3, 'three voices'
def pick(notes, rank):
    """The note of the given rank among those sounding (a set of MIDI notes), or 0 when the
    set has too few notes for the rank."""
    ns = sorted(notes)
    k = {'max': -1, 'min': 0, 'max2': -2, 'min2': 1}[rank]
    return ns[k] if len(ns) > (k if k >= 0 else -k - 1) else 0

d = open(SRC, 'rb').read()

def rd_var(d, p):
    """A MIDI variable-length quantity at d[p]: (value, the position after it)."""
    v = 0
    while True:
        b = d[p]; p += 1; v = (v << 7) | (b & 0x7f)
        if not b & 0x80:
            return v, p

# the header chunk: its length, format, track count and ticks a quarter note
hl = struct.unpack('>I', d[4:8])[0]
fmt, ntrk, div = struct.unpack('>HHH', d[8:14])
p = 8 + hl
tempo = 500000
# every note on and off, as (tick, channel, note, on), from all the tracks
events = []
for t in range(ntrk):
    ln = struct.unpack('>I', d[p + 4:p + 8])[0]; q = p + 8; end = q + ln
    tm = 0; status = 0
    while q < end:
        dt, q = rd_var(d, q); tm += dt
        b = d[q]
        if b & 0x80:
            status = b; q += 1
        if status == 0xFF:
            # a meta event: only the tempo ($51, microseconds a quarter note) is used
            typ = d[q]; l, q = rd_var(d, q + 1); data = d[q:q + l]; q += l
            if typ == 0x51:
                tempo = int.from_bytes(data, 'big')
        elif status in (0xF0, 0xF7):
            # a sysex: skipped
            l, q = rd_var(d, q); q += l
        else:
            # a channel message: two data bytes except program change and channel pressure
            hi = status & 0xF0; ch = status & 0xF
            if hi in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                a, b2 = d[q], d[q + 1]; q += 2
            else:
                a = d[q]; q += 1; b2 = None
            if hi == 0x90 and b2 > 0:
                events.append((tm, ch, a, True))
            elif hi == 0x80 or (hi == 0x90 and b2 == 0):
                events.append((tm, ch, a, False))
    p = end

# ticks in one 20 ms frame; note-offs sort before note-ons at the same tick
ticks_per_frame = 1e6 / 50 / (tempo / div)
events.sort(key=lambda e: (e[0], e[3]))
last_tick = max(e[0] for e in events)
nframes = int(last_tick / ticks_per_frame) + 1
# frame by frame, the notes sounding on each channel, and each voice's pick from them
active = {ch: set() for ch in range(16)}
frames = []
ei = 0
for f in range(nframes):
    tick_end = (f + 1) * ticks_per_frame
    while ei < len(events) and events[ei][0] < tick_end:
        tm, ch, note, on = events[ei]; ei += 1
        if on:
            active[ch].add(note)
        else:
            active[ch].discard(note)
    frames.append(tuple(pick(set().union(*(active[c] for c in chs)), rank) for chs, rank in VOICES))

if FX:
    # the frame's struck notes: a note-on in it, by channel
    struck = []
    ei = 0
    for f in range(nframes):
        tick_end = (f + 1) * ticks_per_frame
        s_ = {ch: set() for ch in range(16)}
        while ei < len(events) and events[ei][0] < tick_end:
            tm, ch, note, on = events[ei]; ei += 1
            if on:
                s_[ch].add(note)
        struck.append(s_)
    # the frames again: each voice's note and whether it is struck there
    active = {ch: set() for ch in range(16)}
    ei = 0
    fxf = []
    for f in range(nframes):
        tick_end = (f + 1) * ticks_per_frame
        while ei < len(events) and events[ei][0] < tick_end:
            tm, ch, note, on = events[ei]; ei += 1
            if on:
                active[ch].add(note)
            else:
                active[ch].discard(note)
        def one(spec, below=256):
            chs, rank = spec
            n = pick(set(x for x in set().union(*(active[c] for c in chs)) if x < below), rank)
            st = any(n in struck[f][c] for c in chs)
            return n | (0x80 if n and st else 0)
        m, b = one(FXMEL), one(FXBASS, FXSPLIT)
        ch_notes = sorted((x for x in set().union(*(active[c] for c in FXCHORD)) if x >= FXSPLIT), reverse=True)[:3]
        cst = any(n in struck[f][c] for c in FXCHORD for n in ch_notes)
        cs = [n | (0x80 if cst else 0) for n in ch_notes] + [0] * (3 - len(ch_notes))
        # the bass and the chord ring on through their rests (their envelopes fall to
        # silence), as a plucked string does: a rest takes the last notes, not struck
        if not b and fxf:
            b = fxf[-1][1] & 0x7F
        if not ch_notes and fxf:
            cs = [x & 0x7F for x in fxf[-1][2:]]
        fxf.append([m, b] + cs)
    out = bytearray()
    for n in range(24, 96):
        nn = n
        while nn < 47:
            nn += 12
        per = min(int(round(125000.0 / (440.0 * 2 ** ((nn - 69) / 12.0)))), 1023)
        out += bytes([per & 255, per >> 8])
    # the bass: tone 2's period for periodic noise at the note's pitch (1/15 of tone 2's)
    for n in range(24, 96):
        out.append(max(1, min(255, int(round(125000.0 / (15 * 440.0 * 2 ** ((n - 69) / 12.0)))))))
    # FXHDR: the envelopes (melody, bass, chord: start, fall a vsync, rest), the vibrato
    # (delay, depth shift, vsyncs a step), the arpeggio's vsyncs a note
    out += bytes([240, 3, 176,   254, 10, 0,   210, 9, 0,   12, 7, 2,   2])
    prev = [0] * 5
    recs = 0
    run = 0
    cur = None
    def emit(run, fr):
        global recs
        mask = 0; body = bytearray()
        for v in range(5):
            if fr[v] != prev[v] or fr[v] & 0x80:
                mask |= 1 << v; body.append(fr[v])
        out.append(run); out.append(mask); out.extend(body)
        prev[:] = [x & 0x7F for x in fr]
        recs += 1
    # a record starts where anything changes or is struck; held frames lengthen it
    for fr in fxf:
        held = [x & 0x7F for x in fr]
        if cur is not None and not any(x & 0x80 for x in fr) and held == [x & 0x7F for x in cur] and run < 255:
            run += 1
        else:
            if cur is not None:
                emit(run, cur)
            cur = fr; run = 1
    emit(run, cur)
    out += bytes([0])
    open(OUT, 'wb').write(out)
    print('music: %d frames, %d records, %d bytes (TUNEFX)' % (nframes, recs, len(out)))
    sys.exit(0)
# equal consecutive frames merge into one record, 255 frames at most
records = []
cur = None; run = 0
for fr in frames:
    if fr == cur and run < 255:
        run += 1
    else:
        if cur is not None:
            records.append((run, cur))
        cur = fr; run = 1
records.append((run, cur))
out = bytearray()
# the period table: 125000 / f (the chip's 4 MHz clock over 32), clamped to 10 bits; notes
# below 47 are raised by octaves first
for n in range(24, 96):
    nn = n
    while nn < 47:
        nn += 12
    f = 440.0 * 2 ** ((nn - 69) / 12.0)
    per = int(round(125000.0 / f))
    per = min(per, 1023)
    out += bytes([per & 255, per >> 8])
for run, (a, b, c) in records:
    out += bytes([run, a, b, c])
out += bytes([0, 0, 0, 0])
open(OUT, 'wb').write(out)
print('music: %d frames, %d records, %d bytes' % (nframes, len(records), len(out)))
