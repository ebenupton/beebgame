# beebgame

A game engine for the BBC Micro, in 6502 assembler, for one disc that runs on a
**Model B with 64K of sideways RAM** and on a **Master 128**.  It was written for the
BBC port of *Cleo* (the reference game, and the one that uses it today), and pulled
out of it so the engine can be versioned and tested on its own.

What it gives a game:

- A MODE 1 playfield in a hardware-wrapped ring of character rows (software rings with
  mirror rows on the Model B), scrolled a character column or two scanlines at a time,
  double buffered, with a fixed status bar outside the ring -- driven by a "rupture"
  chain of CRTC sections from the VIA timer, so the sync never breaks.
- Tile and sprite blitters in sideways RAM: 8x16 tiles gathered from the map a row at a
  time (full, half and flat tiles), masked, mirrored and opaque sprites with per-level
  placement tuned against page crossings, dirty-rectangle redraw and sprite records.
- Its own disc driver (8271 and 1770) and loader: each level is gathered from shared
  files into the banks by a load-time program in main RAM, with the display parked in
  a standard frame throughout.
- Bank 7 as a resident kernel plus two swappable images, the game's and its menus',
  each loaded over the other.
- Sideways RAM in any sockets, found and patched at boot, and the Watford and Solidisk
  write-select boards.
- A keyboard scan, SN76489 sound effects and a three-voice music player, all from the
  interrupt.

`docs/DESIGN.md` is the detail: the memory maps, the display chain, the blitters, the
loader, the level file format.

## Layout

| Path | What |
|---|---|
| `src/` | the engine: `cpu.inc` (the 6502/65C02 macros, bank-number and write-board patch records), `defs.inc` (the memory map), `engine.s` (display, blitters, records, interrupt, sound, kernel), `low.s` (low RAM: the bank crossings, the Model B's interrupt stub), `disc.s` (the driver, the image swap), `mirror.s` (the Model B's mirror row), `banks.s` (the engine's tables), `init.s` (start-up), `ldprog.s` (the load-time program), `loader.s` (the boot loader), `ldconst.s`, `pads.inc` |
| `cfg/` | the linker maps: `modelb.cfg`, `master.cfg` (with the game's segments in them), `ldprog.cfg`, `loader.cfg` |
| `tools/` | `build.sh` (the build driver), `mkdfs.py` (DFS images and the sector table), `pincfg.py` (the Master's link pinned to the Model B's addresses), `layoutcheck.py` (fails the build if the machines' data do not lie alike), `pagecheck.py` (branches that cross a page), `sprpack.py` (sprite placement against page crossings), `midi2snd.py` (MIDI to the music player's stream) |
| `test/lib/` | `harness.mjs` (a frame-exact jsbeeb driver: breaks at `frame_top`, bank- and image-aware, render-work meter, scene fingerprints), `boards.mjs` (write-select boards emulated on jsbeeb) |

## A game on beebgame

A game is one ca65 assembly: its root source includes the engine's, in this order,
and its own around them (Cleo's `src/main.s` is the example):

    .include "cpu.inc"
    .include "defs.inc"
    .include "engine.s"
    ...the game's code...
    .include "low.s"
    .include "disc.s"
    .if BHW
    .include "mirror.s"
    .endif
    .include "banks.s"
    ...the game's tables...
    .include "init.s"

### Hooks: what the engine calls

| Symbol | When |
|---|---|
| `hook_title` | start-up: the menus' image is in (jumped to, stack reset) |
| `hook_play` | `go_game` has loaded the game's image (jumped to, stack reset; interrupts off, the disc still open for the first level load) |
| `hook_over` | `go_menu` has loaded the menus' image; A is `go_menu`'s A (jumped to, stack reset) |
| `hook_image` | called just after the game's image is loaded, before `hook_play` |
| `hook_hud` | called by `render_frame` while BARDIRTY is set: draw the bar |

### Data and constants the game provides

- `keymap.inc` (on the include path): `KEYN`, and `keytab`/`keybits`, a key number and
  the `K_` bit it sets for each of KEYN keys.
- `sfxtab`: the sound effects, a word per effect (SFXREQ = its number, from 1), each
  steps of (latch, data, volume, frames) ending $FF, placed resident with
  `PLACEH "CODE", "KRNCODE"`.
- `MUSIC_ADDR`: the tune (`tools/midi2snd.py`'s output) in the menus' image.
- `assets.inc` (generated into the build directory by the game's asset step): TOFF,
  FLAT0, NFLAT, MAXMIR, BOXID0, BOXN, MAXSPRDEF, BINMAXDEF, SPRC_BASE, SPRC_LEN,
  SPRC5_BASE, SPRC5_LEN, SPRX_LEN, SPR5_MIRROR, SPR4_COPY, MAP5, B4_CODE_END,
  B5_CODE_END; and `imgtab.bin` (the sprite items' places in the shared files).
- The disc files the loader reads, by these names: BAR (the bar template), SPRC (the
  sprites every level draws), SPRX (the rest), TILES0-2 (the tile set), L0-L15 (the
  levels): `docs/DESIGN.md`, *The level files*.

### Segments the game fills

| Segment | Where |
|---|---|
| ZPGAME | zero page, after the engine's |
| LGCDATA, LGCCODE, LGCBSS | bank 7, the game's image (below the engine's code and variables) |
| MNUCODE, MNUDATA, MNUBSS | bank 7, the menus' image (after the engine's music player) |
| LOWBSS | low RAM, shared with the engine: a few bytes |

The engine's API is its labels: `go_game`, `go_menu` (A passes to `hook_over`),
`load_level_b`, `render_frame`, `addsprite`, `mark_dirty`, `calc_ring`,
`menu_sections`, `ringaddr7`, `set_palette`, `blank_palette`, `music_start`,
`music_stop`, `div10_16`, `selbb`, the map access `maprow`/`mapbyte`/`mapput`, and the
variables in `defs.inc` and at the top of `engine.s` (window, keys, vsyncs, NSPR,
BARDIRTY, SFXREQ...).

## Building

`tools/build.sh` is run from the game's directory, which gets `build/`:

    GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd \
    GAME_ASSETS="python3 tools/assets.py" \
    GAME_MUSIC="python3 beebgame/tools/midi2snd.py tune.mid build/MUSIC" \
    sh beebgame/tools/build.sh

`GAME_ASSETS` runs once per machine (TARGET, BD set). The driver assembles the game
twice, for the Model B (BHW=1, 6502) and the Master (BHW=0, 65C02), links the Master
pinned to the Model B's addresses, builds the load-time program, the boot loader and
each machine's bank pieces, patches and bank 7 images, settles the sector table and
writes one disc.  Needs cc65 (`ca65`, `ld65`, `od65`) and Python 3.

## Status

Extracted from Cleo on 27 September 2026 (Cleo commit 8483965), with the game's side
of every coupling moved behind the hooks above; Cleo builds against it and its test
sweep is identical before and after.  The level packer is still Cleo's
(`tools/assets.py` there): it writes the engine's level format but from Cleo's data
model, and is the next thing to split.  No licence has been chosen yet.
