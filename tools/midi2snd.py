#!/usr/bin/env python3
"""Convert a MIDI file into a 50Hz 3-voice note stream for the engine's SN76489 music
player (engine.s music_tick: the game puts the stream at music_addr).

   python3 beebgame/tools/midi2snd.py <in.mid> <out> [<voices>]

<voices> says where each of the three voices takes its note from, a frame at a time:
"CHANNELS:RANK" three times, comma-separated channels, joined by "/"; RANK is max, min,
max2 (the second highest) or min2 (the second lowest) of the notes sounding on those
MIDI channels.  The default, Cleo's tune, is "1:max/0:min/0:min2" (the melody the
highest note of channel 1, the backing the two lowest of channel 0).

Output: the period table, 72 x 2 bytes for MIDI notes 24..95; then
records of 4 bytes: frames, note0, note1, note2 (0 = rest, else the MIDI note, which
indexes the period table); terminated by frames=0.  Voice 0 = melody, voices 1/2 =
backing (lowest two notes of any chord).
"""
import struct, os, sys

SRC, OUT = sys.argv[1], sys.argv[2]
VOICES = []
for v in (sys.argv[3] if len(sys.argv) > 3 else '1:max/0:min/0:min2').split('/'):
    chs, rank = v.split(':')
    assert rank in ('max', 'min', 'max2', 'min2'), rank
    VOICES.append(([int(c) for c in chs.split(',')], rank))
assert len(VOICES) == 3, 'three voices'
def pick(notes, rank):
    ns = sorted(notes)
    k = {'max': -1, 'min': 0, 'max2': -2, 'min2': 1}[rank]
    return ns[k] if len(ns) > (k if k >= 0 else -k - 1) else 0

d = open(SRC, 'rb').read()

def rd_var(d, p):
    v = 0
    while True:
        b = d[p]; p += 1; v = (v << 7) | (b & 0x7f)
        if not b & 0x80:
            return v, p

hl = struct.unpack('>I', d[4:8])[0]
fmt, ntrk, div = struct.unpack('>HHH', d[8:14])
p = 8 + hl
tempo = 500000
events = []   # (tick, channel, note, on)
for t in range(ntrk):
    ln = struct.unpack('>I', d[p + 4:p + 8])[0]; q = p + 8; end = q + ln
    tm = 0; status = 0
    while q < end:
        dt, q = rd_var(d, q); tm += dt
        b = d[q]
        if b & 0x80:
            status = b; q += 1
        if status == 0xFF:
            typ = d[q]; l, q = rd_var(d, q + 1); data = d[q:q + l]; q += l
            if typ == 0x51:
                tempo = int.from_bytes(data, 'big')
        elif status in (0xF0, 0xF7):
            l, q = rd_var(d, q); q += l
        else:
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

ticks_per_frame = 1e6 / 50 / (tempo / div)     # ticks per 20ms
events.sort(key=lambda e: (e[0], e[3]))
last_tick = max(e[0] for e in events)
nframes = int(last_tick / ticks_per_frame) + 1
# per frame active notes per channel
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

# run-length encode
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
# period table for MIDI notes 24..95 (notes below 47 transposed up an octave to fit 10 bits)
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
