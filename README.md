# beebgame

A scrolling-platformer display engine for the BBC Model B (with 64K of sideways RAM) and
the BBC Master 128, in ca65 assembly.  One set of sources is assembled twice -- `BHW=1` for
the Model B's hardware, `BHW=0` for the Master's -- and a game built on it ships as one disc
that boots on either machine.

## What it gives a game

- A hardware-scrolled display: a 160 x 84 (Model B) or 160 x 120 (Master) game-pixel window
  over a tile map, scrolling by one character horizontally and one game pixel vertically,
  with a fixed two-row status bar above it.  The frame is a chain of CRTC sections driven
  from VIA timer interrupts (`src/engine/kernel.s`), double buffered: two software rings on
  the Model B, main and shadow RAM on the Master.
- A tile blitter that redraws only what the scroll uncovers, the tiles a game marks dirty,
  and the ground under sprites that moved (`src/engine/tiles.s`, `frame.s`), with 8 x 8
  game-pixel tiles in three kinds: full, half (one char row stored, one filled) and flat.
- Masked 4-bit sprites with mirroring, opaque "box" sprites, and per-buffer records so an
  unchanged sprite costs nothing (`src/engine/sprloops.s`, `frame.s`).
- A disc driver of its own (Intel 8271, Acorn 1770, the Master's 1770) and a load-time
  program that gathers a level into the four sideways banks from shared files
  (`src/disc.s`, `src/ldprog.s`); the level file format with its writer, checker and the
  loader's constants in one Python module (`tools/levelfile.py`).
- A boot loader that finds four banks of writable sideways RAM in any sockets, detects
  Watford and Solidisk write-select boards, the machine, the drive and the controller, and
  patches the code for what it found (`src/loader.s`, `src/cpu.inc`).
- Sound effects stepped from the vsync and a three-voice tune player, with a MIDI
  converter (`src/engine/kernel.s`, `src/engine/menus.s`, `tools/midi2snd.py`); or
  (`SOUND6`) a four-voice effects player in bank 6 with sweeps, jitter and priorities,
  the game's effects packed from a Python file (`src/engine/sound6.s`, `tools/sfx.py`).
- A keyboard scan from a game-supplied key table, the MODE 1 palette, and the swap of bank
  7 between the game's image and the menus'.
- A build driver that assembles both machines, lays out bank 7 from the object sizes, pins
  the Master's layout to the Model B's and checks that every table lies at one address on
  both (`tools/build.sh`, `tools/pincfg.py`, `tools/layoutcheck.py`).
- A frame-exact jsbeeb harness for measuring and comparing builds (`test/lib/harness.mjs`).

The game supplies its logic, menus, tables and assets, and five entry points the engine
calls: `hook_title`, `hook_play`, `hook_over`, `hook_image`, `hook_hud` (and `hook_sound`
with `GAMESOUND`); see `docs/GUIDE.md`.

## Building a game

Start with `docs/GUIDE.md`.  The game's own `build.sh` sets `GAME_MAIN`, `GAME_SRC`,
`GAME_ASSETS`, `GAME_MUSIC`, `DISC_TITLE`, `DISC_OUT` and `GAME_NAME` and runs
`sh beebgame/tools/build.sh`, which writes `build/modelb/`, `build/master/` and the disc.
Options, as environment variables: `GAMESOUND SOUND6 DRAWFLAGS TALLMAP
TIGHTBSS ALLLEVELS` (each `=1`) and `MAXSPR=n`; `SKIP_ASSETS=1` skips the asset steps.
`tools/build.sh`'s header says what each does.  Requirements: cc65 (`ca65`, `ld65`,
`od65`) and Python 3; the tests need Node and jsbeeb in the npx cache.

## Layout

| path | what |
|------|------|
| `cfg/banks.cfg` | the one linker map, both machines: zero page, low RAM, the four banks, the boot piece |
| `cfg/ldprog.cfg` | the load-time program's map (`LDPROG`, $0E00) |
| `cfg/loader.cfg` | the boot loader's ($1900) |
| `src/cpu.inc` | the two CPUs' spellings as macros, the options, bank patching (`bankimm`, `BANKREF`), the write-bank rule (`wrsel`, `wrback`), `PLACEH`, `SAMEPAGE`, `PAD` |
| `src/hw.inc` | the chips' registers and bits and the MOS's fixed addresses, for every program on the disc |
| `src/defs.inc` | the addresses shared with the loaders: images, load ops, the sprite banks' tables, the stages, the disc controllers |
| `src/engine.s` | the engine's root: includes `engine/*.s` in layout order; the editing notes |
| `src/engine/defs.s` | constants: hardware, banks, the screen's shape on each machine, the sprite record, keys, the frame |
| `src/engine/vars.s` | zero page and every table, by where it lives |
| `src/engine/macros.s` | the ring-wrapping macros, `runn`, `MIRDIRTY_BODY` |
| `src/engine/tiles.s` | bank 6: `draw_rect`, `scroll_validate`, `select_backbuf`, `bank6_entry`/`draw_rect_clip` |
| `src/engine/gather.s` | bank 5: `gather5`, a tile row's ids into `GATHERL`/`GATHERH` |
| `src/engine/sprloops.s` | banks 4 and 5: the sprite row loop and its three blitters |
| `src/engine/frame.s` | bank 7: `render_frame`, the sprite prologue, the records, the dirty tiles |
| `src/engine/kernel.s` | the kernel: the CRTC chain, the interrupt, load mode, keys, sound, the palette |
| `src/engine/sound6.s` | (`SOUND6`) bank 6: the sound effects player; the kernel's `sfx_request`, `sound_reset` |
| `src/engine/menus.s` | the menus' image: the tune's player |
| `src/engine/boot.s` | start-up: the interrupt's takeover, the CRTC's first frame |
| `src/engine/lowram.s` | low RAM: the map access, `page_logic` |
| `src/low.s` | low RAM: the crossings between banks, the Model B's interrupt stub, `LOWBSS` |
| `src/mirror.s` | the Model B's mirror row (`mirror_copy`) |
| `src/banks.s` | the static tables (row multiples, the expansion tables), `lv_reset`, the level's tables, the directory |
| `src/init.s` | start-up: the loader's header at $7000 and `boot` |
| `src/disc.s` | the disc driver (8271, 1770), `read_sectors`, the image swaps (`go_title`, `go_game`, `go_menu`) |
| `src/ldconst.s` | the constants the loaders and tests need that the linker does not list (printed into `defs_ld.inc`) |
| `src/ldprog.s` | the load-time program: a level into the banks, an image into bank 7, baking |
| `src/loader.s` | the boot loader, under the MOS: the RAM probe, the boards, BANKS |
| `src/pads.inc` | the padding bytes that keep hot branches off page boundaries |
| `tools/build.sh` | the build driver |
| `tools/mkdfs.py` | a DFS `.ssd` from a file list, or the sector table (`files.inc`) |
| `tools/pincfg.py` | the Master's linker config pinned to the Model B's segment starts |
| `tools/layoutcheck.py` | fail if the two machines' segments or data labels differ |
| `tools/imagecheck.py` | fail if code in one bank 7 image (the game's, the menus') uses a symbol of the other |
| `tools/pagecheck.py` | every taken branch that crosses a page, by segment, with its source line |
| `tools/sprpack.py` | sprite placement within a bank against page crossings (imported by the game's packer) |
| `tools/levelfile.py` | the level file format: writer, reader/checker, `levelfmt.inc` |
| `tools/midi2snd.py` | MIDI to the three-voice 50 Hz note stream |
| `tools/sfx.py` | (`SOUND6`) a game's sound effects packed for `sound6.s`; `check` models the player |
| `tools/soundtest.mjs` | (`SOUND6`) the player's chip writes for a fixed schedule, in jsbeeb |
| `tools/codecmp.py` | compare two sources' code ignoring comments and layout |
| `test/test_levelfile.py` | the level file writer against its reader (`python3 -m unittest discover -s test`) |
| `test/lib/harness.mjs` | the frame-exact jsbeeb driver: `frame_top` breaks, bank- and image-aware, scene fingerprint, render meter |
| `test/lib/boards.mjs` | Watford/Solidisk write-select boards emulated on a jsbeeb Model B |
| `docs/DESIGN.md` | what the engine is and why |
| `docs/GUIDE.md` | how to build a game on it |

## Status

The engine was split out of Cleo on 27 September 2026 (the first commit), and Cleo
(`github.com/ebenupton/cleo`, where this repository is the submodule `beeb/beebgame`) is the
reference game: the documents' examples are its.  The level file format is the engine's;
the asset packer that writes it is each game's own, on `tools/levelfile.py` and
`tools/sprpack.py`.

## Related

beeb-port-kit (`github.com/kieranhj/beeb-port-kit`, MIT), a kit for porting C64 games to the BBC
Micro with a coding agent, runs `tools/dataflow` on Baron and beebasm builds (vendored at a pinned
commit and hash-checked) and carries `test/lib/boards.mjs` for its own harnesses.  Its
`docs/related-beebgame.md` lists what it takes from this repository and what it has sent back.

## Licence

MIT: see `LICENSE`.  It covers the whole repository -- the engine, its tools, tests and
documents.
