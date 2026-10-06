# Writing a game on beebgame

This guide takes you from an empty directory to a game that boots from one disc on a BBC
Model B (with 64K of sideways RAM) and a BBC Master 128.  It follows the steps in the
order you will take them, and shows each with the code of Cleo, the game beebgame was
built for (github.com/ebenupton/cleo, `beeb/`).  It is the contract between the engine and
a game -- the hooks, the segments, the files the build gives you and the files you give
it, the limits.  `README.md` is the overview; `DESIGN.md` is how the engine works inside.

What the engine does for you: the display (a scrolling MODE 1 playfield, double buffered,
with a status bar outside it), the tile and sprite blitters, redrawing only what changed,
the keyboard, sound effects and a tune, the disc, gathering each level into sideways RAM,
and swapping between your menus and your game.  What you write: the game's logic, its
menus, its HUD, and a tool that turns your art and levels into the files the engine loads.

Every symbol named here is in the sources; where a number is given in brackets it is the
value in Cleo's build on the day of writing, for orientation, and the symbol is what to
read.

## Before you start

You need:

- **cc65** (`ca65`, `ld65`, `od65`) and **Python 3**.  The engine's own tools need no
  other package; Cleo's asset converter wants Pillow and numpy.
- **Node** and **jsbeeb**, for the tests.  The harness (`test/lib/harness.mjs`
  `findJsbeeb`) looks for jsbeeb in npm's npx cache, `~/.npm/_npx/*/node_modules/jsbeeb`.

Three facts about the machines shape everything you write:

1. **Two CPUs.**  The Model B has a 6502, the Master a 65C02, and your code is assembled
   once for each (`BHW` is 1 for the Model B's hardware, 0 for the Master's: `cpu.inc`).
   Write 6502, or the 65C02 idioms `cpu.inc` spells for both -- `stz`, `zero`, `sta0`,
   `stzx`, `stz01`, `inca`/`deca`/`incax`, `ldaz`/`cmpz`/`ldaz0`/`staz0`/`ldazx`, `ldy1`,
   `bitimm`, `bra` -- each with a stated contract (which registers and flags its Model B
   expansion destroys: the header of `cpu.inc`).  Inside `.if .not BHW` write native
   65C02; inside `.if BHW` plain 6502.  In game code `.if BHW` is rarely needed.
2. **Two window sizes.**  The playfield is `WINPX` game pixels wide on both (160) but
   `VISROWS` character rows tall: 21 on the Model B (84 game pixels), 30 on the Master
   (120) -- `engine/defs.s` `VISROWS`, `VISLINES`.  Your camera, your menus and your level
   design must work in both.
3. **Banked code, two images.**  Your game's code lives in bank 7 of sideways RAM, beside
   the engine's renderer, below a resident kernel.  Your menus are a *second image* of the
   same memory, which the engine loads from disc over your game and your game over it
   (`disc.s` `go_game`, `go_menu`), so the two can never call each other; both call the
   kernel.

## The concepts

The engine works in several units at once, and most mistakes in a new game are mixing two
of them.  In this guide, as in the engine's sources, "pixel" never stands alone.

### Screen pixels, game pixels, scanlines

A **screen pixel** is MODE 1's: 320 across a scanline, one of four colours (two bits).  A
**scanline** is one line of the display.  A **game pixel** is the game's square pixel, 2
screen pixels wide and 2 scanlines tall; everything the game sees -- positions, speeds,
sizes, the map -- is in game pixels.  A game pixel's colour is a 2x2 dither of its four
screen pixels (Cleo's `tools/convert.py` chooses the dither), so the art shows more than
the four colours the palette has: `set_palette` lays black, cyan, magenta and yellow as
logical 0..3 (`kernel.s`).

### Bytes, characters, character rows

MODE 1 packs 4 screen pixels into a byte: 2 game pixels across, one scanline down.  A
**character** is 8 bytes stacked, a byte a scanline: 2 game pixels wide, 4 tall.  A
**character row** is `ROWCHARS` (80) characters: `ROWBYTES` (640) bytes, the full width.
A tile is `TILECHARS` (4) characters across and `TILEROWS` (2) character rows down:
`TILEBYTES` (64) bytes, 8 x 8 game pixels (`defs.inc`).

| Unit | Screen pixels across | Scanlines down | Game pixels | Bytes |
|---|---|---|---|---|
| game pixel | 2 | 2 | 1 x 1 | half a byte on each of 2 scanlines |
| byte | 4 | 1 | 2 x half | 1 |
| character | 4 | 8 | 2 x 4 | 8 |
| tile | 16 | 16 | 8 x 8 | `TILEBYTES` |
| character row | 320 | 8 | 160 x 4 | `ROWBYTES` |

### Where things are: the coordinates

- **Map coordinates** are game pixels from the map's top left: the window's position
  (`wx`, `wy`) and every sprite's reference point (`spx`, `spy`).
- **Tile coordinates** are map coordinates divided by `TILEPX` (8): the map is a grid of
  `1 << lw` by `1 << lh` tiles (the level header's `HDR_LW`, `HDR_LH`), a tile id a byte.
- **Character coordinates** are what the display scrolls by.  `render_frame` derives them:
  `wcx` = `wx` / 2, `wcy` = `wy` / 4, `wfine` = (`wy` & 3) * 2 scanlines (`frame.s`).

What can move by how much: the window moves 2 game pixels across (a character: `wx` is
even -- Cleo's `clamp_window` clears its low bit) and 1 game pixel down (two scanlines,
through `wfine`); a sprite moves 2 game pixels across (`draw_sprite` takes its column as
(`spx` - `sprg_rx` - `wx`) >> 1) and 1 down; a tile sits on the map's 8-pixel grid.

### A tile

A tile is `TILEBYTES` bytes in the screen's own order: the top character row's four
characters (8 bytes each, a scanline a byte), then the bottom row's.  Tiles are opaque.
The level's tile ids are not all tiles (`convert.py` `pack_tiles`'s comment block, and
`gather.s`):

| Id | What | Bank 6 cost |
|---|---|---|
| 0 | the level's **solid**: a one-byte fill (the header's `HDR_SOLIDFILL`, which the loader patches into the row loop at `SOLIDF`) | none |
| 1 .. `HDR_NTILES`-ish | **full tiles**: id k is stored at slot k + `TOFF` from `TILES` | `TILEBYTES` |
| `HDR_HALF0` .. +`HDR_NHALF`-1 | **half tiles**: one character row stored (`HALFBYTES`, 32) from the page `HDR_HALFPAGE`, the other row a fill or the same row again, in three runs: top row filled (to `HDR_HALF1`), bottom row filled (to `HDR_HALF2`), both rows the stored one | `HALFBYTES` |
| `FLAT0` .. 253 | **flat tiles**, `NFLAT` of them: two bytes alternating down the scanlines (`FLATTAB`'s pairs) | 2 bytes of `FLATTAB` |
| 254, 255 | the two **solids** of the tile set, `FLATTAB`'s last two pairs | as a flat |

`vars.s` asserts `FLAT0 + NFLAT + 2 = 256`.  `FLAT0` and `NFLAT` are the game's, in
`assets.inc`; `NFLAT` is Cleo's packer knob (`NFLAT=n sh build.sh`, default 4), not an
engine option.  Where a level has more flat tiles than `NFLAT`, Cleo's packer stores the
surplus as full tiles.

### A sprite's image

A sprite is `W` bytes wide on the screen (2W game pixels) and some game pixels tall.  Its
image is **4-bit game pixels**: a byte for each game-pixel row of each byte column, the
left pixel in the high nibble, each nibble an index into one palette of fifteen 2x2
patterns, 0 transparent (`convert.py` `NIB_PATTERNS`, `NIBTAB`).  The image is stored
**column by column**: all the rows of column 0, then column 1.  The blitters expand a
stored byte through three 256-byte tables the game supplies in `nibtab.bin` and the
engine assembles into both sprite banks at `L0TAB`, `L1TAB`, `NMASK` (`banks.s`
`NIB_TABLES`, `defs.inc`): the byte's two game pixels on their first scanline, on their
second, and the AND mask for its transparent pixels.  `SWAPTAB`, the dot reversal that
mirrors a byte, follows them in both banks.  Every image is drawn either way round.

A **box** (`SPF_COPY`) is the other kind: opaque screen bytes, every scanline stored
(`SPF_FULLRES`), copied without a mask -- for a sprite that always sits on a known
backdrop.  Cleo's box stars are boxes; the engine draws boxes first so they never paint
over a sprite (`draw_sprites`, `frame.s`).

### Sprite ids, boxes and the directory

Sprite ids are bytes.  Ids `0` .. `BOXID0`-1 are images, `BOXID0` .. `BOXID0`+`BOXN`-1 are
boxes, and ids from `BOXID0`+`BOXN` are the boxes' **still aliases**: id `BOXID0`+`BOXN`+k
draws box `BOXID0`+k, with the promise that nothing can have disturbed it, so the engine
keeps it on screen without redrawing when it is the same frame in the same place
(`draw_sprites`).  `BOXID0` and `BOXN` are the game's (`assets.inc`), and
`BOXID0 + 2*BOXN <= 256` for the aliases to be ids (Cleo's `assets.py` asserts it).

The **directory** that turns an id into an image is split:

- the **level's part**, `DIR_TABLE` (`banks.s`, in `ENGBSS`): for each of the
  `BOXID0`+`BOXN` ids the image's address in its sprite bank, low bytes then high bytes;
  a high byte of 0 means "not in this level", bit 7 clear means bank 5 (bank 4's are
  `$8000`-up as written).  The level file carries it (`levelfile.directory()`), the
  loader copies it in.  With `DIRSPLIT` (Step 11) the ids below your `RES_N` --
  every level's alike -- have their part in a sprite bank instead (`RESDIR`, the same
  form, `RES_N` entries), loaded once with your resident sprites, and `DIR_TABLE` and
  the level file hold the ids from `RES_N` alone;
- the **game's part**, the geometry by shape, `sprgeom.inc`: `sprg_ix` (shape index by
  id), then by shape `sprg_w` (bytes wide), `sprg_rx`, `sprg_ry` (the reference point's
  offset from the image's top left, signed: `draw_sprite` subtracts them from `spx`,
  `spy`), `sprg_ln` (stored rows: scanlines for a box, game-pixel rows otherwise) and,
  when `assets.inc` defines `SPRGFL`, `sprg_fl` (`SPF_MIRROR` 1, `SPF_FULLRES` 2,
  `SPF_COPY` 8: `engine/defs.s`).  Cleo includes it in `GAMEDATA` (`gamedata.s`); it must
  be somewhere in the game's image, where `draw_sprite` runs.  The game may read it too:
  a frame's drawn box is `[-sprg_rx, 2*sprg_w - sprg_rx)` across and `[-sprg_ry, sprg_ln -
  sprg_ry)` down about its reference point (`sprg_ln` in game pixels for a shape without
  `SPF_FULLRES`), which is how Cleo's `body_hit` tests two bodies.

### The two images of bank 7

Bank 7 holds, at its top, the disc driver's slot, the **kernel** (`KRNCODE`, `KRNDATA`,
`KRNBSS`) and `KRNHW`/`GAMEHI`, ending at $BFFF with no hole: resident, never swapped.  Below it is one of two
files read from the disc: the **game's image** (`GAMEDATA`, `GAMECODE`, `ENGCODE`: your
logic and the engine's renderer) or the **menus' image** (`MUSCODE`, `MNUCODE`,
`MNUDATA`, `MNUBSS`: your menus and the engine's tune player).  Below both, not in either
file, lie the level's tables (`ENGLVL`, `GAMELVL`) and the game image's variables
(`GAMEBSS`, `GAMEROWH`, `GAMEOBJ`, `ENGBSS`), which the loader zeroes as the game's image
comes in (`ldprog.s` `image_load`, `GAME_BSS` in `defs_ld.inc`).  `cfg/banks.cfg` is the
one map; its header says how `build.sh` sizes the areas.

## Step 1: make the project

Make a repository with beebgame as a submodule and lay it out as Cleo does:

```text
mygame/
  beebgame/        the engine (git submodule)
  build.sh         your build: sets the driver's variables and runs it
  src/             your sources: main.s (the root), keymap.inc, the rest
  tools/           your asset pipeline (Cleo: assets.py, convert.py)
  test/            your tests, on beebgame's harness (Cleo: harness.mjs, sweep.sh ...)
  assets/          your source art, levels and music
  build/           generated: build/modelb, build/master, the disc
```

Cleo's `src/` is `main.s` (the root and the hooks), `logic.s` (the logic and the HUD),
`game.s` (the level and frame loops), `menu.s` (the menus),
`gamedata.s` (its tables) and `keymap.inc`.

## Step 2: the build script

Your `build.sh` exports a few variables and runs the engine's driver,
`beebgame/tools/build.sh`, from your directory, where `build/` is made.  Cleo's, whole
(`beeb/build.sh`):

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"
[ -f beebgame/tools/build.sh ] || { echo "beebgame is missing: git submodule update --init"; exit 1; }
export GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd GAME_NAME=Cleo
export GAME_MUSIC="python3 beebgame/tools/midi2snd.py assets/v500/thm.mid build/MUSIC"
export GAME_ASSETS="python3 tools/assets.py"
sh beebgame/tools/build.sh
[ -n "$ALLLEVELS" ] || cp build/cleo.ssd ../cleo.ssd
```

The driver's environment (its header):

| Variable | Meaning |
|---|---|
| `GAME_MAIN` | the root source; it includes the engine's (Step 3).  Required. |
| `GAME_SRC` | your include directory (`-I`).  Required. |
| `GAME_ASSETS` | a command run once per machine with `TARGET` (`modelb` or `master`) and `BD` (`build/$TARGET`) set: it writes that directory's assets and `build/TILES0-2` (Step 8).  Required. |
| `GAME_MUSIC` | a command run once, first (may be empty).  Cleo's turns its MIDI into `build/MUSIC`. |
| `DISC_TITLE` | the disc's title.  Required. |
| `DISC_OUT` | the disc image; `build/game.ssd` by default. |
| `GAME_NAME` | the game's name in the boot loader's messages (`gamename.inc`); `DISC_TITLE` by default. |
| `SKIP_ASSETS=1` | skips `GAME_MUSIC` and `GAME_ASSETS`. |

The options -- `GAMESOUND`, `SOUND6`, `DRAWFLAGS`, `TALLMAP`, `TIGHTBSS`,
`DIRSPLIT`, `ALLLEVELS`, `MAXSPR=n` -- are Step 11's; the driver passes each as a `-D` and `cpu.inc`
defaults it to 0.  `NFLAT` is not the driver's: Cleo's `convert.py` reads it from the
environment.

The driver assembles your root twice -- `--cpu 6502` for `build/modelb`, `--cpu 65C02 -D
BHW=0` for `build/master` -- with `-I $BD -I $GAME_SRC -I beebgame/src` and
`--bin-include-dir $BD`, so `.include` finds the generated includes in `$BD`, your own in
`GAME_SRC` and the engine's, and `.incbin` reads from `$BD` alone: everything your sources
`.incbin` must be written there by `GAME_ASSETS`.

## Step 3: the root source and the hooks

Your root includes the engine's sources in this order, with yours between, and defines
the hooks.  Cleo's `src/main.s`, whole but for its header:

```ca65
        .include "cpu.inc"          ; (-D BHW=0: the Master)
        .include "defs.inc"
        .include "engine.s"
        .include "logic.s"
        .include "game.s"
        .include "menu.s"
        .include "low.s"
        .include "disc.s"
  .if BHW                          ; (the Master's CRTC folds its ring itself)
        .include "mirror.s"
  .endif
        .include "banks.s"          ; (the engine's tables, then the game's)
        .include "gamedata.s"
        .include "init.s"

hook_title = game_main             ; start-up, the menus' image in (menu.s)
hook_play  = level_loop            ; a game starts, the game's image in (game.s)
hook_over  = menu_over             ; a game has ended, the menus' image in; A = 0 lost,
                                    ; 1 won (menu.s)
hook_image = bar_bg                ; the game's image has come in: the bar's template
                                    ; with it, so the HUD's digit cache is stale (logic.s)
hook_hud   = redraw_hud            ; render_frame, bar_dirty set: the bar's digits (logic.s)
```

The engine calls six things in your game.  Three of them (`hook_title`, `hook_image`,
`hook_over`) are reached from the load-time program in main RAM, which takes their
addresses from `defs_ld.inc` (`build.sh` reads them from the debug file); the others are
assembled into the engine's own code.

| Hook | Called from | When | In | Out |
|---|---|---|---|---|
| `hook_title` | `ldprog.s` `ld_image` (`@title`), after `ld_resume` | start-up (`init.s` -> `go_title`), and never again: `go_menu` goes to `hook_over` | the menus' image is in bank 7; the chain resumes at the next vsync (`ld_resume`); the palette is black (`init.s` `boot` blanked it); the stack is reset to `STACKTOP`; interrupts on | never returns: it ends in `go_game` |
| `hook_over` | `ldprog.s` `ld_image`, after `ld_resume` | the game's image called `go_menu` | A = `go_menu`'s A (Cleo: 0 lost, 1 won); the menus' image is in; the chain is running; the stack reset | never returns: it ends in `go_game` |
| `hook_image` | `ldprog.s` `ld_image` (`jsr`) | the menus' image called `go_game`: the game's image has been read in, its bank numbers and write-bank stores patched, `GAME_BSS` zeroed and the bar's template (`BAR`) read to `BARADDR` | the game's image is in; **interrupts are off and the chain parked** (the load has not ended: `ld_open` = 1); A is undefined; the stack reset | returns; A, X, Y free |
| `hook_play` | `disc.s` `game_in` (`jmp`), straight after `hook_image` | the same | as `hook_image` left it | never returns: it ends in `go_menu`.  Its first act must be a level load (`load_level_b`), which with `ld_open` set goes straight on and ends in `ld_resume`: only then do the vsyncs count and the flips land |
| `hook_hud` | `frame.s` `render_frame` (`jsr`), after its wait for the last flip | once a rendered frame when `bar_dirty` is non-zero; `render_frame` then clears it (`stz01`: set it to 1 and no other value) | bank 7 paged (the game's image); the bar at `BARADDR` is on display and single buffered: the digits must be finished before the CRTC reaches it, (`QROWS`-`QVSYNC`)*8 scanlines after the vsync | returns; A, X, Y free |
| `hook_sound` | `kernel.s`, the vsync's step of the interrupt, after `scan_keys` -- only with `GAMESOUND=1`, in place of the engine's `sound_tick` | every vsync, whichever image is in bank 7 | the interrupt's: A, X, Y saved by the handler (`irq_x`, `irq_y`, `MOS_IRQA`); the engine still copies `mus_on` to `mus_tick` after it | returns; it must store into no sideways bank (the interrupt's rule, `vars.s`: what it keeps goes in zero page or `LOWBSS`) and so must live outside both images: the kernel's segments, or bank 6 as `SOUND6`'s player does |
| `ld_game` (only with `GAMELDINIT=1`) | `ldprog.s` `ld_entry` (`jsr`), after `lv_load` | every level load, before the load ends | the level in the banks, `LV_HDR` and `LV_OBJS` in place; bank 7 paged and write-selected; interrupts off; your `ldgame.s`, assembled into LDPROG (Step 11) | returns with bank 7 paged and write-selected; A, X, Y free; then `ld_resume` and `load_level_b`'s return |

Two facts about the image hooks: the stack is reset to `STACKTOP` before each, so
"nothing the other image called is returned to" (`disc.s`), and `hook_image` and
`hook_play` run with the display parked and interrupts off -- no `vsyncs`, no flip --
until the level load that `hook_play` must begin with.  `game_in` is also the label the
test harness runs to (Step 10).

The game's **three ways out** are the kernel's (`disc.s`): `go_game` (from the menus:
the game's image, `hook_image`, `hook_play`), `go_menu` (from the game: A = whatever
`hook_over` wants, the menus' image, `hook_over`) and `load_level_b` (from the game: X =
the level 0..15; returns).  Each stops the tune, parks the chain at a frame boundary
(`load_begin`), reads the load-time program and runs it.  **The engine does not blank the
palette for a load**: the loader uses the screen as its staging area (`ldprog.s`), so call
`blank_palette` before any of the three and `set_palette` when your first frames are
built, as Cleo does in `level_loop`, `new_game` and `game_over`.

## Step 4: where your code and variables go

`cfg/banks.cfg` names the segments; yours are the `GAME*`, `MNU*`, `ZPGAME` and (Step 11)
`HAZ*` ones.  Every segment you use must exist there; the loader's zeroing and the
build's sizing depend on them.

| Segment | Where | What goes in it |
|---|---|---|
| `ZPGAME` | zero page, after the engine's `ZEROPAGE`, up to `$FC` (`ZP` is `$00`-`$FB`; `$FC` is the ROM's interrupt entry's, `$FD` `ROMSEL_CPY`, `$FE`-`$FF` the engine's `ZPTOP`) | your hot variables, and **everything the menus set for the game** (Cleo: `level`, `lives`, `health`, `seed`, `max_level`): zero page survives the image swap; `GAMEBSS` does not |
| `GAMELVL` | bank 7, after `ENGLVL` (`LV_ATTR0`, `LV_ALTCLS`, `LV_HDR`) in the room before `$8300` (224 bytes) | tables filled at a level's start.  The level file's **header tail** lands at `LV_HDR + HDR_LEN`, so a variable there receives it (Cleo's `RNGTAB`, asserted at that address; then `MROWL`).  Not zeroed by an image load |
| `GAMEBSS` | bank 7 from `$8300`, page aligned | your small variables (keep it under 128 bytes so `GAMEROWH`'s half page follows in the same page: the cfg's comment).  **Zeroed as the game's image comes in** |
| `GAMEROWH` | after `GAMEBSS`, aligned to a half page | a half-page table (Cleo's `MROWH`).  Zeroed |
| `GAMEOBJ` | after it, page aligned | your page-aligned arrays (Cleo's object state, `LV_OBJST` ..).  Zeroed |
| `ENGBSS` | after `GAMEOBJ`, page aligned (`TIGHTBSS`: unaligned) | the engine's: records, lists, `DIR_TABLE`.  Zeroed |
| `GAMEDATA`, `GAMECODE` | the game's image, before the engine's `ENGCODE`; the file `GAME` | your tables and code.  Only this image can call the engine's `ENGCODE` (`render_frame`, `add_sprite`, `mark_dirty`, `lv_reset`) |
| `MNUCODE`, `MNUDATA`, `MNUBSS` | the menus' image from `$8000`, after the engine's `MUSCODE`; the file `MENU` | your menus, their tables (the tune's stream at `music_addr`, Step 7), their variables |
| `GAMEHI` | the last bytes of bank 7 (`B7H`), after the kernel's `KRNHW`, ending at $BFFF | resident bytes that must survive both swaps and the zeroing: Cleo's `score` and `hi_score`, which the menus show and the game keeps |
| `KRNCODE`, `KRNDATA`, `KRNBSS` | the kernel | the engine's; a game may add resident code (the build sizes the kernel from the object's segment totals) |

Three rules follow from the swap.  **The two images never call each other**: the menus
reach the kernel (`KRNCODE`: `set_palette`, `blank_palette`, `calc_ring`,
`build_sections`, `menu_sections`, `ring_addr7`, `music_stop`, `go_game`), low RAM
(`selbb`, `map_*`) and their own `MUSCODE` (`music_start`), never `render_frame`.  **The
menus' image carries no bank-number or write-bank sites**: `bankimm`, `setbank`, `wrsel`
are patched by the loader for the game's image only, and the build fails on a `@bf_`/
`@wr_` site in an `MNU*` segment ("use ldpbank": `cpu.inc` `ldpbank` reads the physical
bank from `PBANK`).  **What the menus hand the game lives in zero page or low RAM
(`LOWBSS`)** (or `GAMEHI`), and code both images call is in the kernel or assembled into
each: `tools/imagecheck.py` fails the build if code in one image uses a symbol of the other.

Each machine's own zero page variables are reserved on the other too (`vars.s`), and
`tools/layoutcheck.py` fails the build if any shared variable or segment differs between
the two links: your data lies at one address on both machines by construction, and the
Master's shorter code is pinned to the Model B's starts (`tools/pincfg.py`).

## Step 5: the menus

A menu draws into ring buffer 0 and shows it through the kernel.  Cleo's three helpers
(`menu.s`) are the pattern:

```ca65
; menu_begin: window at (0,0), buffer 0 as work buffer, cleared; screen blanked until
; menu_show has flipped the finished page in
menu_begin:
        jsr blank_palette
:       lda flip_req               ; the game may still have a flip pending
        bne :-
        sta wx                     ; A = 0: flip_req was
        sta wx+1
        sta wy
        sta wy+1
        sta wcx
        sta wcx+1
        sta wcy
        sta wfine
        sta cur_buf
        jsr selbb                  ; (bank 6's select_backbuf, through low RAM)
        jsr calc_ring
        jmp clear_ring

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stz cur_buf                ; (A is dead: build_sections loads it)
    .if BHW
        sta next_sect              ; A = 0 (the stz).  Before the build: the vsync reads
    .else                          ;  it only for a flip, and flip_req is 0 until below
        stz next_buf               ; (the Master: its handler's flip reads it)
        stz next_sect
    .endif
        jsr menu_sections          ; the kernel's (engine.s)
        inc flip_req               ; 0 -> 1: every way in has waited for it to clear
:       lda flip_req
        bne :-
        inc cur_buf                ; 0 -> 1: next game frame renders into the other buffer
        jmp set_palette            ; page is on display: colours back

; wait one vsync and return new key edges in A (keys pressed now but not last time)
menu_keys:
        lda vsyncs
:       cmp vsyncs
        beq :-
        lda keys
        tax
        eor last_keys
        and keys
        stx last_keys
        rts
```

`clear_ring` is Cleo's: it zeroes from `CLEAR0` to `$8000` (both machines' buffer 0,
and the Model B's mirrors and second ring).  `menu_sections` (`kernel.s`) is
`build_sections` with the bar's section pointed at two black ring rows below the window
(`MENUBAR`), so the bar is neither shown nor touched while the menus run.  To put bytes
on the page, `ring_addr7` (A = the character row, `w16` = the column, C = 0) gives the
screen address of a ring character in `sp`; Cleo's `draw_glyph_rows` and `blit` use it.

The tune: `music_start` (the engine's, in `MUSCODE`, the menus' image) starts the stream
at `music_addr`, which your `MNUDATA` provides (Step 7); `music_stop` is the kernel's and
every load calls it.  Cleo plays the tune on the title and stops it for the win/lose
screen.

The way out is `go_game`: Cleo's `new_game` sets `score`, `lives`, `health`, `level` (in
zero page and `GAMEHI`), calls `blank_palette`, and jumps.

## Step 6: the game

The game's image comes in at `hook_play`.  Cleo's `level_loop` (`game.s`), as it is:

```ca65
level_loop:
        jsr blank_palette          ; hide the loading and the first-frame build-up
        ldx level
        ; the level: X = level index 0..15 (even = main, odd = bonus)
        jsr load_level_b           ; the disc: everything into the banks (disc.s)
        lda #TILEPX                ; mapw = TILEPX << lw ; maph = TILEPX << lh
        sta mapw
        sta maph
        zero mapw+1, maph+1
        ldx LV_HDR+HDR_LW
        stx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        ldx LV_HDR+HDR_LH
:       asl maph
        rol maph+1
        dex
        bne :-
        lda mapw                   ; C = 0: the last rol shifted out maph's bit 15
        sbc #WINPX-1
        sta maxwx
        lda mapw+1
        sbc #0
        sta maxwx+1
        lda maph                   ; C = 1: mapw >= WINPX
        sbc #VISLINES/2
        sta maxwy
        lda maph+1
        sbc #0
        sta maxwy+1
        jsr lv_reset               ; the records (bank 7) and the buffers' state (main RAM)
        sta nspr                   ; A = 0: lv_reset ends with a stz
        jsr level_init
        sty bar_dirty              ; Y = 1 (level_init's exit): the digits on the first
                                    ; render (the bar's template is in place already: bar_bg)
        ; initial camera; render both buffers before the palette comes back
        jsr game_frame
        jsr render_frame

        jsr game_frame
        jsr render_frame
        jsr set_palette
```

In order: blank, load (`load_level_b`, X = the level), read the header's `HDR_LW`/`HDR_LH`
into the map's size and the window's limits (`maplw`, `mapw`, `maph`, `maxwx`,
`maxwy` are zero page the engine declares for the game: `vars.s`), `lv_reset` (both
buffers invalid, the records and dirty lists empty; it leaves A = 0 for `nspr`), your own
`level_init`, two frames rendered dark so both buffers hold the scene, then `set_palette`.
On the Model B the level's objects are read to `LV_OBJS` in display RAM (`defs.inc`):
read them before the first `render_frame`, as Cleo's `level_init` does.

What the loader has set when `load_level_b` returns (`ldprog.s` `lv_load`): `LV_HDR`
(the 32-byte header and your tail after it), `LV_OBJS` (`HDR_NOBJ` objects of
`OBJ_BYTES`), `LV_ATTR0` and `LV_ALTCLS` (your two 256-byte tables by tile id),
`map_shr` and `map_stride`, the map in bank 5, the tiles in bank 6, the sprites in banks
4 and 5, `DIR_TABLE`, `FLATTAB`, and the chain running again.

The frame loop (`game.s`): Cleo renders every `VSPEG` (3) vsyncs and drops time lost to
a long frame rather than catching up.  `frame_top` is reached exactly once a rendered
frame, before the logic reads `keys`; the harness breaks there (Step 10).

```ca65
frame_loop:
        lda vsyncs
        sec
        sbc logicvs
        cmp #VSPEG
        bcc fl_wait
        lda vsyncs
        sta logicvs
frame_top:                         ; exactly once per rendered frame, before the two
                                    ; logic steps read 'keys': the test harness breaks
                                    ; here so every wait and every input it applies is
                                    ; quantised to a frame boundary (test/harness.mjs)
        jsr game_frame             ; (nspr is 0 here: render_frame and load_level clear it)
        lda exiting
        bne fl_over
        jsr render_frame
        jmp frame_loop
```

What a frame's logic does with the engine (`frame.s`, `lowram.s`):

| Call | In | Out |
|---|---|---|
| `add_sprite` | A = id; `spx`, `spy` = its reference point in game pixels (map coordinates); with `DRAWFLAGS`, bit 7 of `spx+1` mirrors it | the list grows by one, or the sprite is dropped when `nspr` = `MAXSPR`; A, X clobbered, Y kept |
| `mark_dirty` | A = the tile's map column, X = its row | queued in both buffers' dirty lists; a full list (`DIRTYMAX`, 20) marks the buffer to be redrawn whole |
| `map_row` | A = the tile row | `map_ptr` = the row's address in the map (bank 5); Y = 0; X kept |
| `map_byte` | `map_ptr`, Y = the column | A = the tile id; X, Y kept |
| `map_col` | `map_ptr`, Y | A = the tile, `tp` = the tile above, `tp+1` below; X clobbered |
| `map_put` | A = the id, `map_ptr`, Y | the map written (a write window, closed again); A, X, Y kept.  Then `mark_dirty` |
| `render_frame` | `wx` (even), `wy`; the sprite list; `bar_dirty` | draws the back buffer, requests the flip, `nspr` = 0, `cur_buf` flips.  It does not wait: the next logic step overlaps the pending flip |
| `bar_dirty` | set to 1 when the HUD changed | `render_frame` calls `hook_hud` and clears it |

Window limits are yours to keep: the engine draws what `wx`, `wy` say (Cleo's
`clamp_window`).  Both machines render the same `wx`, `wy`; only `VISROWS` differs, so a
camera that places the player `CAM_Y` from the top shows more below on the Master.

The way out is `go_menu` with A set for `hook_over` (Cleo: `game_over`, after the
hi-score compare and `blank_palette`).

## Step 7: keys, sound effects, music

**Keys.**  `kernel.s` `scan_keys` includes your `keymap.inc` right after itself (so it
lands in the interrupt's segment: `PLACEH "MRAMCODE", "KRNCODE"`) and reads three things
from it: `KEYN`, `key_tab` (`KEYN` internal key numbers, written to the keyboard through
the system VIA) and `key_bits` (the `K_` bit each sets).  The vsync builds `keys` from
them; the `K_LEFT` .. `K_FIRE` bits are `engine/defs.s`'s.  Cleo's (`src/keymap.inc`):

```ca65
KEYN = 10
key_tab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
key_bits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE
```

**Sound effects.**  Set `sfx_req` (zero page) to a 1-based index and the vsync's
`sound_tick` plays entry `sfx_req` of your `sfx_tab`, a table of words.  An effect is
steps of `SFXSTEP_LEN` (4) bytes -- three bytes written to the SN76489 in turn, then the
frames to hold them -- ending in `SFX_END` (`$FF`, which written to the chip is also the
noise channel's silence); the end also silences tone channel 2.  `sfx_tab` and the
effects must be where `sound_tick` is: a game puts them under `PLACEH
"MRAMCODE", "KRNCODE"` (bank 7 on the Model B, main RAM on the Master) and builds each
step with a macro (Cleo's, before it moved to `SOUND6`):

```ca65
.macro SFX ch, lo4, hi, att, dur
  .if ch = SN_NOISE                ; a data byte replaces the noise control: repeat it
        .byte SN_LATCH | (ch << SN_CHSHIFT) | lo4, lo4
  .else
        .byte SN_LATCH | (ch << SN_CHSHIFT) | lo4, hi
  .endif
        .byte SN_LATCH | SN_VOL | (ch << SN_CHSHIFT) | att, dur
.endmacro
SFX_CH = 2
sfx_tab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump:  SFX SFX_CH, 8, 12, 0, 2
           SFX SFX_CH, 4, 9, 2, 2
           SFX SFX_CH, 0, 7, 4, 2
           SFX SFX_CH, 8, 5, 6, 3
           .byte SFX_END
```

An effect must not sit in page 0 (`sound_tick` tests its address's high byte for "one
playing").  With `GAMESOUND=1` none of this is assembled and the vsync calls your
`hook_sound` instead (Step 3).

**Sound effects, the bank 6 player (`SOUND6=1`).**  A richer player, in bank 6 where it
costs bank 7 nothing: four voices (the three tones and the noise), each playing a script of
segments that hold a period and a level for some frames while sweeping them, with an
effect's priority deciding which voice it may take.  Write your effects in a Python file
and name it `GAME_SFX`; `tools/sfx.py` (its docstring has the format) packs them into
each machine's `sfxdata.inc`, which defines `SFX_<NAME>` for each:

```python
EFFECTS = [
    # a short pew falling an octave, on voice 1
    ('blob', 3, [(1, [S(6, 120, 200, -32, 20, 0)])]),
    # a ding, F up to C: two segments
    ('mission', 6, [(0, [S(4, 179, 240, -10, 0, 0), S(10, 119, 240, -22, 0, 0)])]),
]
```

Ask for one with `lda #SFX_BLOB / jsr sfx_request` (any number in a frame; X and Y kept;
C = bit 2 of the id, which a caller may branch on), silence everything with `sound_reset`:
both are in the kernel, so the menus' image calls them as the game's does.  The player is
not stepped through a disc load, and every load starts with `sound_reset` (disc.s `ld_go`):
an effect that should be heard to its end before a load -- Cleo's exit fanfare -- needs the
game to wait for it first.  An idle vsync (no request, no voice playing) costs the player a
seven-byte test.  Cleo's effects (`src/sfx.py`) are a second example, with the bank 6 room
they need found by `TILEMIRROR` and `LDBIG` (Step 11).
`tools/sfx.py check GAME_SFX [stream.json]` plays a fixed
schedule through a model of the player, and `tools/soundtest.mjs disc out.json` records
the real player's chip writes for the same schedule: two builds with the same effects give
the same stream.

**The tune.**  Your `MNUDATA` provides `music_addr`: `MUS_TAB_LEN` (144) bytes of
periods for MIDI notes `MUS_NOTE0` .. +`MUS_NNOTES`-1 (24..95), then 4-byte records --
frames, then a note for each of the three voices (0 a rest) -- with frames = 0 to loop
(`engine/menus.s`).  `tools/midi2snd.py <in.mid> <out> [<voices>]` writes exactly that
from a MIDI file; the voices argument picks each voice's note from the MIDI channels
(`CHANNELS:RANK` x 3, joined by `/`; Cleo's default `1:max/0:min/0:min2`).  Cleo's
`GAME_MUSIC` runs it to `build/MUSIC`, its asset step copies that to `music.bin`, and
`gamedata.s` incbins it at `music_addr`.  The player (`music_tick`) is stepped from the
interrupt only while `mus_on` is set, which `music_start` sets and `music_stop` clears;
it lives in the menus' image, so the tune plays in the menus and stops at every load.

## Step 8: the assets

`GAME_ASSETS` runs once per machine with `TARGET` and `BD` set, and must write the same
shared files on both runs: the build compares `SPRX`, `SPRC`, `BAR` and `L0`-`L15`
between `build/modelb` and `build/master` and stops if they differ, and `assets.inc` too.
Into `$BD` it writes:

| File | Read by | What |
|---|---|---|
| `assets.inc` | the engine, the loaders' constant pass (`ldconst.s`) and your sources | the constants below |
| `L0` .. `L15` | the loader (`ldprog.s` `lv_load`) | the sixteen level files, `tools/levelfile.py`'s format |
| `SPRC` | the loader, once | the resident sprites: `SPRC_LEN` bytes to bank 4 at `SPRC_BASE`, then `SPRC5_LEN` to bank 5 at `SPRC5_BASE` |
| `SPRX` | the loader, every level | every other image and box, from which each level copies its own (the Master keeps it in HAZEL/ANDY after the first read) |
| `img_tab.bin` | `ldprog.s` (`.incbin`) | an entry per item of `IMGTAB_LEN` (5) bytes: the file (the loader's file numbers: 0 is `SPRX`), offset, length -- items up to `BAKEITEM0` |
| `nibtab.bin` | `banks.s` (`.incbin`, `NIBTAB_LEN` = 768) | the sprites' expansion tables `L0TAB`, `L1TAB`, `NMASK` |
| `sprgeom.inc` | your `GAMEDATA` (`.include`) | `sprg_ix`, `sprg_w`, `sprg_rx`, `sprg_ry`, `sprg_ln`, `sprg_fl` |
| `BAR` | the loader, with the game's image | the status bar's template, `BARROWS` * `ROWBYTES` (1280) bytes, read to `BARADDR` |
| `bake_kind.bin`, `bake_geom.bin` | `ldprog.s`, only when `assets.inc` defines `BAKEITEM0` | Cleo's baked boxes: by slot its kind; by kind `BG_LEN` (8) bytes (`BG_WC`, `BG_LINES`, `BG_DX`, `BG_DTY`, `BG_OV`, `BG_SKIP`) |
| whatever your sources `.incbin` | you | Cleo: `alt.bin`, `digits.bin`, `digtab.bin`, `font.bin`, `music.bin`, `title.bin` and `title.inc` |

and into `build/`: `TILES0`, `TILES1`, `TILES2`, the tile set, each at most `TILE_CHUNK`
(256) tiles of `TILEBYTES` -- 16K, what either machine stages at a time (`convert.py`).
The loader's file table names exactly these (`ldprog.s` `ftab`: three tile files, `tfi`).

**assets.inc.**  The engine reads these (the rest of Cleo's -- `HDR_STARTX`.., `RQ_*`,
`OT_*`, `SPR_*`, `BINMAXDEF`, `TP_*`, `TBUF_LEN`, `HUD_*`, `GLYPHW`.. -- are its own, and
you may add yours the same way):

| Constant | Meaning | Reader |
|---|---|---|
| `FLAT0`, `NFLAT` | the fill ids: `NFLAT` flats from `FLAT0`, then the two solids (`FLAT0 + NFLAT + 2 = 256`) | `gather.s`, `vars.s`, `ldprog.s` |
| `BOXID0`, `BOXN` | the first box id and the box count | `frame.s`, `banks.s`, `ldprog.s` |
| `SPRGFL` | define it (= 1) when `sprgeom.inc` carries `sprg_fl`; leave it out and the only flag is `DRAWFLAGS`'s mirror | `frame.s` |
| `RES_N`, `RESDIR`, `RESDIR_BANK` | `DIRSPLIT` only: the resident ids (`0` .. `RES_N`-1, images all), and their directory's address in sprite bank `RESDIR_BANK` (4 or 5), inside `SPRC` | `banks.s`, `lowram.s`, `ldprog.s` (through `ldconst.s`), `levelfile.py check` |
| `PALKILL` | optional: the Model B's palette kill's order, the logical colours (1 cyan, 2 magenta, 3 yellow) in bits 1-0, 3-2, 5-4 -- the order they first show along Q's line 0, which runs through your `BAR` from char `QBLANK_CHAR` (45) of row 0 on into row 1, line 0 of each char; yellow, magenta, cyan without it.  Derive it from your bar's bytes in the packer that writes `BAR` (Commando's `assets.py`), and mind what your HUD draws there | `kernel.s` (`palkill`) |
| `MAXSPRDEF` | the sprite list's size, when the build's `MAXSPR` is not given; 28 without either | `engine/defs.s` |
| `TOFF` | tile id k is at slot k + `TOFF` from `TILES`; bank 6's code must end before slot `TOFF`+1 (`init.s` asserts it) | `defs.inc`, `gather.s`, `ldprog.s`, `init.s` |
| `TILES` | bank 6's tile origin, page aligned (Cleo's `$8600`) | `defs.inc`, `gather.s`, `ldprog.s` |
| `MAP5` | the map in bank 5: a fixed 8K below `B4_DATA_END` | `defs.inc` (`LV_MAP`), `ldprog.s` |
| `B4_DATA_END` | where the expansion tables start in banks 4 and 5 (`L0TAB`) | `defs.inc` |
| `B4_CODE_END`, `B5_CODE_END` | where the engine's code ends in the sprite banks: your sprites start there.  Asserted equal on the Model B and not passed on the Master (`sprloops.s`, `gather.s`), and `build.sh` sizes the link's areas to them, so a wrong value stops the build | `sprloops.s`, `gather.s`, `build.sh` |
| `SPRC_BASE`, `SPRC_LEN`, `SPRC5_BASE`, `SPRC5_LEN`, `SPRX_LEN` | the resident and staged sprite files | `ldprog.s` |
| `IMGTAB_LEN` | `img_tab.bin`'s entry (5) | `ldprog.s` |
| `BAKEITEM0`, `BG_*` | the first baked item and the geometry record (optional: the loader bakes nothing without `BAKEITEM0`) | `ldprog.s` |

`B4_CODE_END` and `B5_CODE_END` are the engine's numbers, not yours: Cleo's `assets.py`
sets them by hand because the packer runs before the assembler.

**A level file** is one call to `levelfile.encode()` (`beebgame/tools/levelfile.py`, the
one definition: `python3 levelfile.py inc` writes the `levelfmt.inc` the loader and
`defs.inc` include, so the two cannot drift).  The file is a table of thirteen section
offsets (`SECTIONS`: `hdr objs attr altcls tiles place map flat halves hpair mir dir
page0`), then the sections:

| Section | Content |
|---|---|
| `hdr` | `HDR_LEN` (32) bytes: `HDR_LW`, `HDR_LH` (log2 of the map in tiles), `HDR_NOBJ`, the game's fields at `HDR_GAME` (offsets 2-5 and 7-19), and the tile set's `Shape` at `HDR_SHAPE` (20): `ntiles`, `map_shr` (8 - lw), `nhalf`, `half0..2`, `halfpage` (high byte), `halfoff`, `mir0` (`half0 + nhalf`), `nmir` (0 without `TILEMIRROR`), `solidfill`.  Then your **header tail** (`Level.header_tail`), under a page in all: the loader copies the whole section to `LV_HDR` |
| `objs` | `OBJ_BYTES` (6) a record, `OBJ_MAX` (149) at most: yours, copied to `LV_OBJS` |
| `attr`, `altcls` | two 256-byte tables by tile id: yours (`LV_ATTR0`, `LV_ALTCLS`) |
| `tiles` | the tile list: the files this level uses (count, then each file's number and its full tiles), then each full tile's index in its file (`convert.py` `_tilelist`) |
| `place` | `levelfile.placement()`: `PLACE_LEN` (6) bytes an entry -- item, bank (4 or 5), image address, extra (0, or the tile `x | y << 8` of an item the loader bakes) -- ending in `PL_END` |
| `map` | `1 << (lw + lh)` tile ids, row major, run-length coded (`rle`: c < 128 is c+1 literals, else the next byte c-126 times) |
| `flat` | `FLATTAB`'s pairs, `FLATTAB_LEN` = 2*(`NFLAT`+2) |
| `halves` | two bytes a half tile: its index in its file, and its stored row with the file's place in the level's list << 1 |
| `hpair` | the halves' fill palette, `HPAIR_LEN` (16: 8 first bytes, 8 second), then each half's low bits (fill row and colour) |
| `mir` | `TILEMIRROR`: `MIRTAB`, `nmir` bytes -- for each mirrored id `mir0 + i`, the id (1..`ntiles`) of the full tile it draws reversed; else empty |
| `dir` | `levelfile.directory()`: `2*(BOXID0+BOXN)` bytes (above); `DIRSPLIT`: the ids from `RES_N`, `2*(BOXID0+BOXN-RES_N)` bytes (`Level(res_n=RES_N)`) |
| `page0` | `PAGE0_LEN` (512): the Master's gather table, a pair per id, 256 low then 256 high, in whole sectors at the end -- the Model B's loader reads the file short of them |

`encode()` asserts the sizes and the two stage limits (`STAGE_LVL_B`: 9K less `page0` on
the Model B; `STAGE_M`: 20K on the Master), and the build runs `levelfile.py check` on
every level.  Cleo's call, from `tools/assets.py` `pack_level`:

```python
data = lf.encode(lf.Level(lw=L['lw'], lh=L['lh'], game_header=ghdr, shape=lf.Shape(**T['B']['shape']),
                          objects=bytes(objs), tile_tables=(bytes(attr), bytes(acls)),
                          tiles=T['B']['tiles'], placement=placement, map=mapb, flat=T['flat'],
                          halves=T['halves'], hpair=T['hpair'], mir=T['B']['mir'],
                          directory=directory, page0=T['B']['page0'], header_tail=RNGTAB,
                          boxid0=BOXID0, boxn=BOXN))
```

`ghdr` is `{HDR_STARTX: .., HDR_STARTY: .., HDR_EXITX: .., HDR_EXITY: .., 7: 1}` plus the
twelve special tile ids from `HDR_SPECIAL`; `RNGTAB` is Cleo's collision table, which
`logic.s` keeps in `GAMELVL` at `LV_HDR + HDR_LEN`.

**The tiles.**  The engine has no tile packer: Cleo's `convert.py` `pack_tiles` builds a
level's ids, lists and `Shape` from the tile set and is where to start.  What it must
produce is above (*A tile*); the limits are the ids (`FLAT0` - 1 below the flats) and
bank 6's room, `$C000` - (`TILES` + (`TOFF`+1)*`TILEBYTES`) bytes [14,656: 229 slots], a
half tile taking half a slot.  Id 0 must be a one-byte fill: the same byte on every
scanline.

**The sprites.**  Likewise Cleo's `assets.py`: it decides the resident set
(`RESIDENT_IDS`), places each level's images in the two banks (`place_sprites`), orders
them against page crossings with the engine's `tools/sprpack.py` (`settle_level`), writes
`SPRC`, `SPRX`, `img_tab.bin`, the placement and directory, and sizes `MAXSPRDEF` from the
most sprites a window can hold.  The room is bank 4 from `B4_CODE_END` to `B4_DATA_END`
[14,452 bytes] and bank 5 from `B5_CODE_END` to `MAP5` [6,117], shared between the
resident sprites and one level's own.  `SPRX` is at most 16K (the stage) and, to stay
resident on the Master, `SPRX_PAGES <= $30` (12K: `ldprog.s`).  Any image or box may go
in either bank: both have every blitter and the tables.

## Step 9: build and run

```sh
git submodule update --init
sh build.sh
```

The driver's passes (`beebgame/tools/build.sh`): the music step, then per machine the
asset step, a copy of `banks.cfg` with the bank areas sized from `assets.inc`, and
`levelfmt.inc`; the shared-file comparison and `levelfile.py check`; then three passes
in which the disc's sector table (`files.inc`) is made, the game assembled and linked
(the Master's pinned to the Model B's addresses), `defs_ld.inc`, `IMG7`, `img7fix.inc`,
`LDPROG` and `BANKS` written with their asserts, and the pass repeated until `files.inc`
settles.  Then the boot loader, the disc, `layoutcheck.py` and an `ls -l` of the banks
and the disc.  It prints, among other lines, `BANKS: n pieces, n bytes, n bank patches, n
write-bank stores` per machine and `levelfile: 16 level files check`.

What the build gives your sources, in `$BD`:

| Include | Written by | Contains |
|---|---|---|
| `assets.inc` | your asset step | Step 8's constants |
| `levelfmt.inc` | `tools/levelfile.py inc` | `SEC_*`, `HDR_*`, `HDR_LEN`, `OBJ_BYTES`, `OBJ_MAX`, `PLACE_LEN`, `PL_*`, `RLE_*`, `LV_PAGE0_SECS` (included by `defs.inc`) |
| `files.inc` | `tools/mkdfs.py table` | `F_<file>_SEC` and `F_<file>_N` for every disc file (included by `disc.s`) |
| `sprgeom.inc` | your asset step | the geometry by shape |
| `defs_ld.inc` | `build.sh`, from `labels.txt` and `game.dbg` | for the loaders and the tests: the addresses in its `want` list (`boot`, `read_sectors`, `LV_HDR`, `DIR_TABLE`, `map_shr`, `PBANK`, `ld_open`, `game_in`, `hook_title`, `hook_image`, `hook_over` ...), `SOLIDF`, `GAME_ADDR`/`GAME_LEN`, `MENU_ADDR`/`MENU_LEN`, `GAME_BSS`/`GAME_BSS_PAGES`/`GAME_BSS_REM`, then every constant `ldconst.s` prints (the memory map's and the screen's shape).  Not for your game's sources: your game is linked, the loaders are not |
| `img7fix.inc` | `build.sh` | each image's bank-number and write-bank patch lists, for `ldprog.s` |
| `build/gamename.inc` | `build.sh` | `GAME_NAME`, for the boot loader |

The disc, in order (`build.sh` `DISC`): `!BOOT` (`*RUN LOADER`), `LOADER`, `BANKSB`,
`BANKSM`, `IMG7M`, `LDPROGM`, `LDPROGB`, `IMG7B`, `BAR`, `SPRX`, `SPRC`, `TILES0`,
`TILES1`, `L0` .. `L15`, `TILES2` -- the two machines' pieces around the shared files, the
levels after them.  Boot it in jsbeeb or BeebEm as a Model B with sideways RAM or a
Master 128; the boot loader finds the banks, says which machine it is on, and reads that
machine's `BANKS`.

## Step 10: test

The engine's harness, `test/lib/harness.mjs`, drives a build under jsbeeb frame by
frame.  Its contract with your game is one label: **`frame_top`**, reached exactly once
a rendered frame before the logic reads `keys`.  Every wait is `runTo(A.frame_top)` and
every input is written while stopped there, so nothing in a test can observe a cycle
count -- and so nothing in it can observe code size (the header says why).

What it exports:

- `findJsbeeb()`, `loadLabels(file)` (the linker's `labels.txt` plus the constants of the
  `defs_ld.inc` beside it), `dbgPath(labels)` and `loadBanks(dbg)`: the bank and image of
  every label from its segment's name -- `SPR4*` bank 4, `SPR5*`/`MAP5*` 5, `TIL*` 6,
  `GAME*`/`ENG*`/`MNU*`/`KRN*` 7, with `GAME*`/`ENG*` in the game's image and `MNU*` in
  the menus' -- so a break at a bank 7 address waits for that bank and that image
  (`ld_img`).  Name your segments to fit, or extend `SEGBANK`;
- `class Harness(s, A, banks)`: `rd`/`wr`/`rd16`/`wr16`, `cyc()`, `runTo(pc, budget)`,
  `inBank(name, f)`, `installMeter()` (the render window from `render_frame`'s fall
  through its flip spin to `render_done`, the interrupt's share separated, instructions
  counted; the logic from `frame_top` to `render_frame`), and `fingerprint()`: a hash of
  every input to the renderer's cost (the window, the buffers' state, `nspr` and the
  sprite list, the records, the dirty lists) plus your `gameScene()`.  A cycle comparison
  is valid only where fingerprints match;
- `boards.mjs` `boardEmu(cpu, "watford" | "solidisk")`: a write-select board on a jsbeeb
  Model B, counting in `cpu.boardMismatch` every store into a bank other than the one
  paged -- what a missing write-bank store does.

Cleo's `test/harness.mjs` is the pattern for a game's own: `CleoHarness.gameScene()`
names the player, the frame, the level and the score, and `open({disc, labels, level})`
boots through the real title, patches `title_loop` to start a game, runs to `game_in`,
patches `level_loop`'s `ldx level` to the level wanted, runs to `level_init`, patches
`scan_keys` to `rts` (inputs come from the harness), runs to `frame_top` and installs the
meter.  `test/bopen.mjs` does the same on a Model B (`BMODEL`, `BBOARD`, `BSWRAM`).  On
them Cleo builds its gate, `test/sweep.sh REF` (the current build against a snapshot made
by `test/snapshot.sh DIR`: every level's window and scene on both machines, with seeded
keys, the menus, the frame period through a load, the boards).  The engine's own unit
test is `python3 -m unittest discover -s beebgame/test` (the level file format).

## Step 11: a game for the Master alone, and the other build options

Each option is an environment variable of the driver, passed to the assembler as `-D`
and defaulted to 0 in `cpu.inc` (`build.sh`'s header).  With none set a game builds for
both machines.

| Option | What it does | Where |
|---|---|---|
| `GAMESOUND=1` | the vsync calls your `hook_sound` in place of `sound_tick`; the tune's step is still raised | `kernel.s` |
| `SOUND6=1` | the engine's sound effects player (`engine/sound6.s`) in place of `sound_tick`, playing your `GAME_SFX` effects (packed by `tools/sfx.py`): in bank 6, segment `SND6CODE` after the tile blitter (your `TOFF` clears it), the vsync paging it in after the tune (the Model B from `low.s` `irq_vret`, the Master's handler around it), so it is there under either image of bank 7 and costs bank 7 nothing; `sfx_request` and `sound_reset` in the kernel; its state in `LOWBSS`; `snd_write` moves to low RAM (`LOWCODE2`) for it, and `GATHERL` into `LOWBSS`.  Not with `GAMESOUND`.  (A game with code of its own in `LOWCODE2` -- low RAM, visible with any bank in -- sets `GAMELOWCODE = 1` before `cpu.inc`, so boot copies it down without `SOUND6` too) | `sound6.s`, `kernel.s`, `low.s`, `init.s`, `banks.cfg`, `build.sh`, `tools/sfx.py` |
| `TALLMAP=1` | maps up to 256 tiles tall: the window's character row keeps its high bits (`wcyh`) for the tile blitter's map row.  On the Model B it needs `RINGARITH` (`cpu.inc` errors without): its 23-row ring does not divide 256, so `calc_ring` takes the window's slot from the full row (`wcyh:wcy` mod 23, as `wcy + 3*wcyh`) and `RINGARITH` puts every other row relative to it | `cpu.inc`, `vars.s`, `frame.s`, `kernel.s` |
| `TILEMIRROR=1` | mirrored full tiles: an id drawn as a stored full tile reversed (chars right to left, each byte's two game pixels swapped; `tiles.s` `@mir`).  Your packer gives them the ids from `mir0`, after the halves (before the flats), and the level file's `mir` section (`MIRTAB`) each one's source's id; `LV_PAGE0` gives them kind `GL_MIRROR` (3) in the low byte.  The Model B's gather reads `MIRTAB` (bank 5, `MAXMIR` bytes from your `assets.inc`; 32 bytes of code more), the baker draws them, and the blitter costs 7 cycles more a full-tile run | `gather.s`, `tiles.s`, `ldprog.s`, `levelfile.py` |
| `LDBIG=1` | the Model B's load-time program (`LDPROG`, from $0E00) up to 2.75K, not 2.5K: `STAGE`, the shared files' stage, starts at $1900, so a shared file is 15.75K at most -- your packer must hold its files to it.  Cleo needs it for `TILEMIRROR`'s baker | `defs.inc`, `ldprog.s` |
| `DRAWFLAGS=1` | the sprite list's x high byte carries draw flags: bit 7 mirrors the image, so one image is drawn either way round from the list | `frame.s` `draw_sprites`, `draw_sprite` |
| `TIGHTBSS=1` | the engine's bank 7 variables packed: 9-byte sprite records as arrays (`RECSZ`), `ENGBSS` not page aligned (the driver edits the cfg) | `engine/defs.s`, `build.sh` |
| `DIRSPLIT=1` | the directory's resident part out of bank 7: your packer numbers the ids every level draws alike first (`0` .. `RES_N`-1), writes their entries (`levelfile.directory()` of them: `RES_N` low bytes, `RES_N` high) into `SPRC` at `RESDIR` in bank `RESDIR_BANK`, and the level files' `dir` and `DIR_TABLE` keep the ids from `RES_N` (2 bytes each).  `draw_sprite` reads a resident id's entry through low RAM's `dir_res`, which pages the bank in and bank 7 back: 28 cycles a resident sprite, 5 a level one, for `2*RES_N` bytes of bank 7 | `banks.s`, `frame.s`, `lowram.s`, `ldprog.s`, `levelfile.py` |
| `MAXSPR=n` | the sprite slots, over your `MAXSPRDEF`; 28 when neither sets it | `engine/defs.s` |
| `GAMELDINIT=1` | your level start in the load-time program, out of bank 7: your `ldgame.s` (in `GAME_SRC`), whose entry `ld_game` the loader calls at the end of every level load, after `lv_load` and before the load ends (`ld_resume`).  It is assembled into `LDPROG` (segment `LDGAME`, after the loader's code: `cfg/ldprog.cfg`) for the 6502, inside the scope `ldg` with `gamesyms.inc` -- every global label and constant of your link, from its debug file (`build.sh`) -- so it names your variables and the engine's as your game does, and the loader's own (`src`, `dst`, `cnt`, `bcopy`, `pgbank`, `PB_MAP` ...) with `::`.  It runs with interrupts off, bank 7 paged and write-selected (a Model B's board included), the Master's ACCCON X and Y clear, the level in place (`LV_HDR`, `LV_OBJS`, the map); it may write your zero page, low RAM and bank 7 variables, page another bank only through the loader's `bcopy`/`pgbank` (which leave bank 7 paged and write-selected again), call code of your image's (bank 7 is paged), and must return with bank 7 paged and write-selected.  Your game then goes on from `load_level_b`'s return.  `LDPROG`'s room is shared with it (`$0A00` bytes on the Model B, `$0E00` on the Master) | `ldprog.s` `ld_game`, `cfg/ldprog.cfg`, `build.sh` |
| `UDATA5=1` | your level's own bytes in bank 5, up against the map: the level file's objects section holds them (`levelfile.Level(udata=...)`, any length up to `UDATA_MAX` = 894, no objects: `HDR_NOBJ` 0), and the loader copies them to `LV_OBJS` as ever and on to bank 5 to end at `LV_MAP`, their start there in the engine's `lv_udata` (2 bytes, `ENGBSS`).  Read them in play from bank 5 (`map_byte`, or with bank 5 paged); your level start (`ld_game`) can read the `LV_OBJS` copy and turn an address in it into bank 5's by adding `lv_udata - LV_OBJS`.  Records whose position you fix from the top (the last bytes) sit at constant addresses whatever the level's data before them.  Your packer ends the level's bank 5 sprites by `levelfile.udata_start(udata, MAP5)`: the room the data leaves is the level's, not reserved at the largest level's size | `ldprog.s` `lv_load`, `engine/vars.s`, `tools/levelfile.py` |
| `ALLLEVELS=1` | a test build: the engine passes the flag and your game acts on it (Cleo: every main level on the chooser, every bonus level taken; its `build.sh` then skips the copy to `../cleo.ssd`) | `cpu.inc`, Cleo's `menu.s`, `game.s` |

Commando (github.com/ebenupton/commando) is the second game on the engine, for both
machines, built with `SOUND6`, `DRAWFLAGS`, `TALLMAP`, `TIGHTBSS`, `GAMELDINIT`
(its `ldgame.s`: the map's shape, `lv_reset`, the state cleared, the objects built, the
missions' texts found, the player placed -- 725 bytes out of bank 7) and `UDATA5` (its
missions, their texts and its objects' records, below each level's map).

## Limits to design within

Every budget is in the build's output; read it there (`build/modelb/labels.txt`'s
`__SEG_RUN__`/`__SEG_SIZE__`, `assets.inc`, `ls -l build/*`).  The brackets are Cleo's
values on the day of writing.

| Budget | How to read it | Cleo today |
|---|---|---|
| the game's image: your `GAMEDATA` + `GAMECODE` + the engine's `ENGCODE`, ending at the kernel | free room = `__B7_START__` - (`__ENGBSS_RUN__` + `__ENGBSS_SIZE__`) | 39 bytes |
| the menus' image: `MUSCODE` + `MNUCODE` + `MNUDATA` + `MNUBSS`, from `$8000` to the kernel | `__KRNDATA_RUN__` - (`__MNUBSS_RUN__` + `__MNUBSS_SIZE__`) | 2,249 bytes |
| the game image's variables, `GAMEBSS` .. `ENGBSS`, zeroed at each image load | `__GAMEBSS_RUN__` to `__ENGBSS_RUN__` + `__ENGBSS_SIZE__`; `ENGBSS` = `DIRTYLIST` 4*`DIRTYMAX` + `SPRREC` 2*`MAXREC`*`RECSZ` + `RECCNT` 2 + `KEEP` `MAXREC` + `DIRTYCNT` 2 + `SPRLIST` 5*`MAXSPR` + `DIR_TABLE` 2*(`BOXID0`+`BOXN`) (`DIRSPLIT`: less 2*`RES_N`) (`vars.s`, `banks.s`) | `ENGBSS` 1,064 bytes with `MAXSPR` 24 |
| zero page for the game | `ZP` ends at `$FC`: `ZPGAME` has what the engine's `ZEROPAGE` leaves (`__ZPGAME_RUN__`, `__ZPGAME_SIZE__`) | 113 bytes from `$8B`, all used |
| `GAMELVL` | the room between `ENGLVL`'s end and `$8300`: 224 bytes, your header tail first | 216 used |
| `GAMEHI` | after `KRNHW`, to $BFFF: with `KRNHW`, `KRNBSS` and `KRNDATA` in one page (the build checks) | 6 of 146 used |
| the level file | `STAGE_LVL_B` (9K, less `page0`'s 512) on the Model B; `STAGE_M` (20K) on the Master; `OBJ_MAX` 149 objects; the header tail under 224 bytes | 2,560 to 7,936 bytes |
| the map | a fixed 8K at `MAP5`: `lw + lh <= 13` | 256x32, 128x64, 64x128, 32x32 |
| bank 6 | `$C000` - (`TILES` + (`TOFF`+1)*`TILEBYTES`) bytes of tiles, half tiles half a slot; the fills (`FLAT0`..255 and 0) cost none | 14,656 bytes: 229 slots |
| banks 4 and 5 | `B4_DATA_END` - `B4_CODE_END` and `MAP5` - `B5_CODE_END`, for the resident sprites and the level's own | 14,452 and 6,117 bytes |
| `SPRX` | 16K (the stage); 12K to stay resident on the Master (`SPRX_PAGES <= $30`) | 8,483 bytes |
| sprites a frame | `MAXSPR` (the list); `DIRTYMAX` (20) dirty tiles a buffer before it is redrawn whole | `MAXSPRDEF` 24 |
| the load-time program | `LDPROG`'s area is `$0A00` bytes on the Model B (to `STAGE`: `ldprog.s` asserts it), `$0E00` on the Master (`banks.cfg` `LDP`); it grows with `img_tab.bin`, the bake tables and `GAMELDINIT`'s `ldgame.s` (the link fails past it) | 2,538 / 2,678 bytes |
| the disc | 80 tracks of 10 sectors (`NTRACKS`, `SECTRK`); used to the last file's `F_<name>_SEC` + `_N` | 708 of 800 sectors |
| the window | `WINPX` 160 by `VISLINES`/2 game pixels: 84 (Model B) or 120 (Master) | -- |
