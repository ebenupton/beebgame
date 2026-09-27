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

**To write a game on it, start with `docs/GUIDE.md`**: the steps from an empty
directory to a disc, with Cleo's code as the examples.  `docs/DESIGN.md` is the
detail: the memory maps, the display chain, the blitters, the loader, the level file
format.

## Layout

| Path | What |
|---|---|
| `src/` | the engine: `cpu.inc` (the 6502/65C02 macros, bank-number and write-board patch records), `defs.inc` (the memory map), `engine.s` (display, blitters, records, interrupt, sound, kernel), `low.s` (low RAM: the bank crossings, the Model B's interrupt stub), `disc.s` (the driver, the image swap), `mirror.s` (the Model B's mirror row), `banks.s` (the engine's tables), `init.s` (start-up), `ldprog.s` (the load-time program), `loader.s` (the boot loader), `ldconst.s`, `pads.inc` |
| `cfg/` | the linker maps: `modelb.cfg`, `master.cfg` (with the game's segments in them), `ldprog.cfg`, `loader.cfg` |
| `tools/` | `build.sh` (the build driver), `mkdfs.py` (DFS images and the sector table), `pincfg.py` (the Master's link pinned to the Model B's addresses), `layoutcheck.py` (fails the build if the machines' data do not lie alike), `pagecheck.py` (branches that cross a page), `sprpack.py` (sprite placement against page crossings), `levelfile.py` (the level file format: the writer, a reader and checker, and the loader's constants), `midi2snd.py` (MIDI to the music player's stream) |
| `test/lib/` | `harness.mjs` (a frame-exact jsbeeb driver: breaks at `frame_top`, bank- and image-aware, render-work meter, scene fingerprints), `boards.mjs` (write-select boards emulated on jsbeeb) |
| `test/` | `test_levelfile.py` (`python3 -m unittest discover test`) |

## Status

Extracted from Cleo on 27 September 2026 (Cleo commit 8483965), with the game's side
of every coupling moved behind hooks (`docs/GUIDE.md`); Cleo builds against it and its test
sweep is identical before and after.  The level file format is the engine's
(`tools/levelfile.py`); what fills it -- choosing and packing the tiles, placing the
sprites -- is still the game's packer (Cleo's `tools/assets.py` and `convert.py`
`pack_tiles`), the next thing to split.  No licence has been chosen yet.
