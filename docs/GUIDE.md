# Writing a game on beebgame

This guide takes you from an empty directory to a game that boots from one disc on
a BBC Model B (with 64K of sideways RAM) and a BBC Master 128.  It follows the steps
in the order you will take them, and shows each with the code of Cleo, the game
beebgame was built for (github.com/ebenupton/cleo, `beeb/`).  `README.md` is the
reference for the contract between the engine and a game; `DESIGN.md` is the detail
of how the engine works.

What the engine does for you: the display (a scrolling MODE 1 playfield, double
buffered, with a status bar), the tile and sprite blitters, redrawing only what
changed, the keyboard, sound effects and music, the disc, loading each level into
sideways RAM, and swapping between your menus and your game.  What you write: the
game's logic, its menus, its HUD, and a tool that turns your art and levels into the
files the engine loads.

## Before you start

You need:

- **cc65** (`ca65`, `ld65`, `od65`) and **Python 3**.  Your own asset tools will
  probably want Pillow and numpy; the engine's tools need neither.
- **jsbeeb** (`npx jsbeeb` once, so that it is in the npm cache) and **Node**, for
  the tests.  The harness finds jsbeeb there.

Three facts about the machines shape everything you write:

1. **Two CPUs.**  The Model B has a 6502, the Master a 65C02.  Your code is assembled
   for both: write 6502, or use the 65C02 idioms `cpu.inc` spells for both (`stz`,
   `stza`, `phx`/`plx`, `phy`/`ply`, `inca`/`deca`, `ldaz`, `bitimm`, `jmpx`...;
   the contracts are at the end of `DESIGN.md`).  `BHW` is 1 when assembling for the
   Model B, 0 for the Master; use `.if BHW` where the hardware really differs, which
   in game code is almost never.
2. **Two window sizes.**  The playfield is 160 game pixels wide on both, but 84 game
   pixels tall on the Model B (21 character rows) and 120 on the Master (30 rows):
   `WINPX`, `VISROWS`, `VISLINES` in `engine.s`.  Your camera, your menus and your
   level design must work in both.
3. **Banked code.**  Your game's code lives in bank 7 of sideways RAM, beside the
   engine's.  It can call the engine directly; the engine reaches the other banks
   itself.  Your menus are a second image of bank 7 that the engine swaps in over
   your game, so the two can never call each other.

## Step 1: make the project

Make a repository with beebgame as a submodule, and lay it out like Cleo's:

    mygame/
      beebgame/          the engine (git submodule add https://github.com/ebenupton/beebgame beebgame)
      build.sh           your build: sets beebgame's driver going
      src/               your 6502 sources
        main.s           the root: the engine's sources and yours, and the hooks
        keymap.inc       your keys
      tools/             your asset pipeline
      test/              your tests, on beebgame's harness
      build/             generated

Cleo's `src/` has `main.s`, `logic.s` (the game's logic and HUD), `game.s` (the game
loop), `menu.s` (the menus), `gamedata.s` (its tables) and `keymap.inc`.

## Step 2: the build script

Your `build.sh` sets a few variables and runs the engine's driver, which assembles
everything twice (once per machine), builds the loaders and writes the disc.  Cleo's,
whole:

    #!/bin/sh
    set -e
    cd "$(dirname "$0")"
    [ -f beebgame/tools/build.sh ] || { echo "beebgame is missing: git submodule update --init"; exit 1; }
    export GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd GAME_NAME=Cleo
    export GAME_MUSIC="python3 beebgame/tools/midi2snd.py ../v500/thm.mid build/MUSIC"
    export GAME_ASSETS="python3 tools/assets.py"
    exec sh beebgame/tools/build.sh

- `GAME_MAIN`, `GAME_SRC`: your root source and your include directory.
- `GAME_ASSETS`: your asset step, run once per machine with `TARGET` (`modelb` or
  `master`) and `BD` (`build/modelb`, `build/master`) set.  Step 8 says what it must
  write.
- `GAME_MUSIC`: run once before everything (it may be empty).
- `DISC_TITLE`, `DISC_OUT`, `GAME_NAME`: the disc's title and file, and the name the
  boot loader uses when it has to tell someone their machine will not do.

`SKIP_ASSETS=1 sh build.sh` reassembles without rerunning your asset step: the quick
loop while you work on code.

## Step 3: the root source

A game is one ca65 assembly.  Your `main.s` includes the engine's sources in a fixed
order with yours between, then defines the five hooks the engine calls.  Cleo's:

            .include "cpu.inc"          ; (-D BHW=0: the Master)
            .include "defs.inc"
            .include "engine.s"
            .include "logic.s"          ; ---- Cleo's
            .include "game.s"
            .include "menu.s"           ; ----
            .include "low.s"
            .include "disc.s"
      .if BHW                           ; (the Master's CRTC folds its ring itself)
            .include "mirror.s"
      .endif
            .include "banks.s"          ; (the engine's tables, then the game's)
            .include "gamedata.s"       ; Cleo's
            .include "init.s"

    hook_title = game_main              ; start-up, the menus' image in (menu.s)
    hook_play  = level_loop             ; a game starts, the game's image in (game.s)
    hook_over  = menu_over              ; a game has ended, the menus' image in; A = 0 lost,
                                        ; 1 won (menu.s)
    hook_image = bar_bg                 ; the game's image has come in (logic.s)
    hook_hud   = redraw_hud             ; render_frame, BARDIRTY set: the bar's digits (logic.s)

| Hook | Called | What it does |
|---|---|---|
| `hook_title` | once, at start-up, with the menus' image in (jumped to) | your title screen |
| `hook_play` | when `go_game` has loaded your game's image (jumped to, the stack reset, interrupts still off) | your level loop |
| `hook_over` | when `go_menu` has loaded the menus' image (jumped to; A is what you gave `go_menu`) | your game-over screen, then back to the title |
| `hook_image` | just after the game's image is loaded, before `hook_play` | anything the load has made stale (Cleo: the HUD's digit cache) |
| `hook_hud` | from `render_frame` while `BARDIRTY` is set | draw the status bar's changing parts |

The assembler will stop with "symbol undefined" if you leave one out.

## Step 4: where your code and variables go

Put everything in the game's segments; the engine's linker maps place them.

| Segment | What | Where |
|---|---|---|
| `ZPGAME` | your zero page (about 110 bytes) | after the engine's |
| `LGCCODE`, `LGCDATA` | your game's code and tables | bank 7, the game's image |
| `LGCBSS` | your game's variables (zeroed each time the image loads) | bank 7, the game's image |
| `MNUCODE`, `MNUDATA`, `MNUBSS` | your menus, and their art and tune | bank 7, the menus' image |
| `LOWBSS` | a few bytes both images see | low RAM, shared with the engine: keep it small |

Two rules:

- **Define a zero-page variable before its first use.**  ca65 assembles a forward
  reference as absolute (a byte and a cycle more), so put your zero page ahead of
  your code, in the first of your sources `main.s` includes, as Cleo's `logic.s` does:

            .segment "ZPGAME": zeropage
    BINI:     .res 1
    frame:    .res 2
    px:       .res 2                  ; player x, y (px)
    ...

- **The game's image and the menus' image cannot call each other.**  Both are at
  the same addresses in bank 7, one at a time.  Anything both need (Cleo: nothing
  but the engine) goes in the engine or in main RAM.

`build.sh`'s link reports a full bank as a memory area overflow; `python3
beebgame/tools/pagecheck.py build/modelb` lists your branches that cross a page (a
cycle each when taken).

## Step 5: the menus

`hook_title` runs with the menus' image in bank 7.  Draw into buffer 0 of the ring
with the window at the origin, keep the palette black until the page is finished,
then show it.  The engine provides `calc_ring`, `ringaddr7` (a map character's screen
address), `menu_sections` (the display, without the status bar), `set_palette`,
`blank_palette`, `music_start`, `music_stop`, and `vsyncs`, `flipreq` and `keys`.
Cleo's two helpers are a pattern to copy:

    menu_begin:                         ; window at (0,0), buffer 0, cleared, palette black
            jsr blank_palette
    :       lda flipreq                 ; the game may still have a flip pending
            bne :-
            sta wx                      ; A = 0
            sta wx+1
            sta wy
            sta wy+1
            sta wcx
            sta wcx+1
            sta wcy
            sta wfine
            sta curbuf
            jsr selbb                   ; (bank 6's select_backbuf, through low RAM)
            jsr calc_ring
            jmp clear_ring              ; (zero the ring: Cleo's)

    menu_show:                          ; display buffer 0, palette on
            stz curbuf
            jsr menu_sections
        .if .not BHW
            stz NEXTBUF                 ; (the Master: its handler's flip reads it)
        .endif
            stz NEXTSECT
            inc flipreq
    :       lda flipreq
            bne :-
            inc curbuf
            jmp set_palette

For input, wait a vsync and take the keys newly down (`keys` holds `K_LEFT`, `K_RIGHT`,
`K_UP`, `K_DOWN`, `K_FIRE`, set by the interrupt from your key map):

    menu_keys:
            lda vsyncs
    :       cmp vsyncs
            beq :-
            lda keys
            tax
            eor lastkeys
            and keys
            stx lastkeys
            rts

Cleo draws text a glyph at a time through `ringaddr7`, and pictures (its logo, big
Cleo) from run-length streams copied a character row at a time; everything in its
menus is on black, so nothing needs a mask (`menu.s`, *The menus* in its design).

**Music.**  `jsr music_start` plays the tune at `MUSIC_ADDR` from the interrupt,
looping; `jsr music_stop` silences it (every load does too).  Cleo starts it on the
title unless it is already playing.

**Starting a game.**  Set up the game's state in zero page -- it survives the swap --
and `jmp go_game`.  The engine loads the game's image and jumps to `hook_play`:

    new_game:
            stz level
            ...
            lda #3
            sta lives
            sta health
            ...
            jmp go_game

**After a game.**  Your game ends with `lda #n / jmp go_menu`; the engine loads the
menus' image and jumps to `hook_over` with n in A.  Cleo's shows its win or lose
screen and goes back to the title:

    menu_over:
            jsr winlose                 ; A = 0 lost, 1 won
            jmp title_loop

## Step 6: the game

`hook_play` runs with your game's image in, interrupts off and the disc still open.
Cleo's level loop is the pattern: load the level, set it up, render both buffers with
the palette black, then run frames pegged to the vsync.

**Loading a level.**  `load_level_b` (X = the level, 0..15) gathers the level into the
banks.  Call it first in `hook_play`: the engine arrives there with interrupts off and
the disc still open from loading the game's image, and the first level's load goes
straight on and ends by turning them on -- nothing before it may wait on a vsync.  Then take the map's shape from the header and reset the engine's records --
the engine reads `mapw`, `maph`, `maxwx`, `maxwy`, `maplw`, `maplh`, which you set.
Cleo's `load_level`, shortened:

    load_level:
            jsr load_level_b            ; the disc: everything into the banks
            ...                         ; mapw = 8 << lw, maph = 8 << lh (px), from
            ldx LV_HDR+HDR_LW           ;  the header: HDR_ offsets are the engine's
            stx maplw                   ;  (levelfmt.inc)
            ...
            ldx LV_HDR+HDR_LH
            stx maplh
            ...                         ; maxwx = mapw - WINPX, maxwy = maph - VISLINES/2
            jsr lvreset                 ; the records and the buffers' state
            sta NSPR                    ; A = 0: the sprite list empty
            rts

Your own header fields and objects are there too: `LV_HDR` (your bytes: +2..+5,
+7..+19), `LV_OBJS` (6 bytes an object), and the two per-tile tables `LV_ATTR0` and
`LV_ALTCLS`, 256 bytes each, for whatever your logic wants to know about a tile id.

**The level loop:**

    level_loop:
            jsr blank_palette           ; hide the loading and the first frame's build-up
            ldx level
            jsr load_level
            jsr level_init              ; (Cleo's: the objects, the player, the camera)
            lda #1
            sta BARDIRTY                ; the bar on the first render
            jsr game_frame              ; render both buffers before the palette comes back
            jsr render_frame
            jsr game_frame
            jsr render_frame
            jsr set_palette
            lda vsyncs
            sta logicvs
    frame_loop:
            lda vsyncs                  ; a rendered frame every VSPEG vsyncs (3: 16.7 Hz)
            sec
            sbc logicvs
            cmp #VSPEG
            bcc fl_wait
            lda vsyncs
            sta logicvs
    frame_top:                          ; once a rendered frame, before the logic reads
            jsr game_frame              ;  the keys: the test harness breaks here
            ...
            jsr render_frame
            jmp frame_loop

Label `frame_top` exactly as Cleo does: the test harness runs frame to frame by it.

**A frame of logic** does three things the engine reads:

- **The window.**  Set `wx`, `wy` (map pixels; `wx` even) and keep them within
  `0..maxwx`, `0..maxwy` (Cleo's `clamp_window`).  `render_frame` scrolls to them.
- **The sprites.**  Empty the list (`stz NSPR`), then for each sprite set `spx`, `spy`
  (map pixels, the sprite's reference point) and `lda #id / jsr addsprite`.  At most
  `MAXSPR` a frame (your asset step sets it: Step 8).  `render_frame` erases what moved,
  keeps what did not and draws the rest.
- **The map.**  Read and write it through `maprow` (A = a tile row: `mapptr` = the row),
  `mapbyte` and `mapput` (Y = the column); after a change, `lda #tx / ldx #ty / jsr
  mark_dirty` so both buffers redraw that tile.

Then `jsr render_frame`.  It waits for the previous frame's flip, draws, and asks for
the flip; your logic for the next frame runs while it waits.

**Sound.**  `lda #n / sta SFXREQ` plays effect n (from 1) from your `sfxtab`.

**The status bar** is two character rows outside the ring, at `BARADDR`.  Its template
(BAR, your asset) is loaded with the game's image; set `BARDIRTY` when a number
changes and draw it in `hook_hud`.  Cleo's `redraw_hud` draws digits into the bar from
`digits_art`, remembering what each slot shows (`BARCACHE`), which is why its
`hook_image` resets that cache.

**Ending.**  When the game is over, `lda #n / jmp go_menu`.  Between levels, just go
round the level loop again: `load_level_b` keeps the game's image and loads only the
level.

## Step 7: keys, sound effects, music

**Keys:** `src/keymap.inc`, on your include path, gives the key numbers the interrupt
scans and the `K_` bit each sets.  Cleo's:

    ; Z and cursor left K_LEFT, X and cursor right K_RIGHT, : and cursor up K_UP,
    ; RETURN and SPACE K_FIRE, / and cursor down K_DOWN
    KEYN = 10
    keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
    keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE

**Sound effects:** `sfxtab`, a word per effect, each a list of SN76489 steps (the
channel's latch byte, its data byte, its volume byte, and how many frames to hold)
ending `$FF`.  It must be resident, so place it with `PLACEH`:

            PLACEH "CODE", "KRNCODE"    ; bank 7's kernel on the Model B, main RAM on the Master
    sfxtab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
    sfx_jump: .byte $C0|8, 12, $D0, 2,  $C0|4, 9, $D2, 2,  $C0|0, 7, $D4, 2,  $C0|8, 5, $D6, 3, $FF

**Music:** `beebgame/tools/midi2snd.py <in.mid> <out>` turns a MIDI file into the player's
stream (a melody and two voices of backing).  Put it in your menus' image at
`MUSIC_ADDR`:

            .segment "MNUDATA"
    MUSIC_ADDR:
            .incbin "music.bin"

## Step 8: the assets

Your `GAME_ASSETS` step writes, for each machine, into `$BD`:

| File | What |
|---|---|
| `assets.inc` | the constants the engine is built with (below) |
| `L0` .. `L15` | the levels: sixteen files, written with `tools/levelfile.py` |
| `SPRC` | the sprites every level draws, loaded once, to fixed places in banks 4 and 5 |
| `SPRX` | every other sprite image and mask, from which each level takes its own |
| `imgtab.bin` | where each item is in SPRX: 10 bytes each (file, offset, length; the mask's the same) |
| `BAR` | the status bar's template, 1,280 bytes |
| anything your own sources `.incbin` (Cleo: the tune, the font, the title pictures) |

and into `build/`: `TILES0`, `TILES1`, `TILES2`, the tile set, up to 256 tiles (16K)
each.  The files the loader reads must be identical on both machines (the build
checks): build them from the Model B's layout.

**assets.inc** (Cleo's values in brackets):

| Constant | Meaning |
|---|---|
| `TOFF` | tile id k is in slot k + TOFF of bank 6 (2) |
| `FLAT0`, `NFLAT` | the flat tiles' ids (250, 4) |
| `MAXMIR` | mirrored tiles at most (TILEMIRROR only; 0) |
| `BOXID0`, `BOXN` | the first opaque "box" sprite id, and how many (103, 15) |
| `MAXSPRDEF`, `BINMAXDEF` | the sprite list's size, and your logic's bin size (24, 18) |
| `SPRC_BASE`, `SPRC_LEN`, `SPRC5_BASE`, `SPRC5_LEN`, `SPRX_LEN` | where SPRC goes, and the files' lengths |
| `SPR5_MIRROR`, `SPR4_COPY` | 0: nothing mirrored in bank 5, nothing opaque in bank 4 |
| `MAP5` | the map's place in bank 5 ($9C00) |
| `B4_CODE_END`, `B5_CODE_END` | where the engine's sprite-bank code ends: your sprites start there |

`B4_CODE_END` and `B5_CODE_END` are the engine's, not yours: take them from the
engine version you build against (Cleo's `tools/assets.py` has the current ones).  If
they are wrong the build stops with an assertion saying which.

**A level file** is one call to `levelfile.encode()`.  Your packer gathers the level
in the engine's terms: the map as tile ids, the tile set's shape and lists, the
sprites' placements and directory, and your own header fields, objects and tile
tables.  Cleo's, from `tools/assets.py`:

    import levelfile as lf       # (beebgame/tools on sys.path)

    ghdr = {HDR_STARTX: L['start'][0], HDR_STARTY: L['start'][1],
            HDR_EXITX: L['exit'][0], HDR_EXITY: L['exit'][1]}          # Cleo's own fields
    placement = lf.placement([(item, bank, img_addr, mask_addr), ...])  # images this level loads
    directory, smask = lf.directory(entries, masks)                     # 118 entries, 103 masks
    data = lf.encode(lf.Level(lw=L['lw'], lh=L['lh'], game_header=ghdr,
                              shape=lf.Shape(**T['B']['shape']),
                              objects=bytes(objs), tile_tables=(bytes(attr), bytes(acls)),
                              tiles=T['B']['tiles'], placement=placement, map=mapb,
                              flat=T['flat'], halves=T['halves'], hpair=T['hpair'],
                              mir=T['B']['mir'], directory=directory, masks=smask,
                              page0=T['B']['page0']))
    open(os.path.join(OUT, 'L%d' % n), 'wb').write(data)

`encode()` checks the sizes and limits (the objects, the stages, the map, the header's
engine fields); the build runs `levelfile.py check` on every level too.  The format is
in `DESIGN.md`, *The level files*.

**The tiles and the sprites** are the part to be most careful with: their layouts are
the blitters' (`DESIGN.md`, *The tiles* and *The sprites*).  In short:

- A tile is 8x8 game pixels, 64 bytes (4 characters by 2 character rows, MODE 1: four
  pixels a byte).  Id 0 is the level's solid colour; the rest are full tiles, half
  tiles (one row stored, the other a fill), flat tiles (two bytes of dither) and, if
  you need them, mirrored ones.  A level has at most 250 distinct ids.
- A sprite image is column major: each column of `lines` bytes in turn, a byte two
  game pixels wide.  Its mask is a plane of its own, one bit a game pixel.  Its
  directory entry is 6 bytes of geometry -- width in bytes, height, reference point x
  and y, flags (bit 0 mirrored, bit 3 opaque), lines -- which `lf.directory` completes
  with the address and bank.  Mirrored images go in bank 4, opaque ones (the boxes,
  ids from `BOXID0`) in bank 5.

Today the engine has no tile packer or sprite placer of its own beyond `sprpack.py`
(which orders a bank's images to save page crossings).  **Start from Cleo's**:
`tools/convert.py` `pack_tiles` builds a level's tile ids, lists and shape from its
tile art, and `tools/assets.py` places each level's sprites, writes SPRC, SPRX and
imgtab.bin, and sizes MAXSPR from the level's objects.  Copy them and replace what
reads Cleo's data (its JARs, its object types) with your own.

## Step 9: build and run

    git submodule update --init
    sh build.sh

The build prints a line per level from your asset step, the bank pieces, `layout: the
data sits alike on both machines`, and the disc.  Boot it in jsbeeb or BeebEm
(SHIFT+BREAK), as a Master 128 and as a Model B with sideways RAM.

What stops a build, and what to do:

| Message | Meaning |
|---|---|
| `Symbol 'hook_...' is undefined` | a hook is missing from `main.s` (Step 3) |
| ld65's `Memory area overflow` in `B7` or `B7M` | your game's image, or your menus', is full (the limits below) |
| `the game image's variables run into its code` | LGCBSS and the engine's variables have met your code: trim either |
| `bank 4's code must end where its sprites start` | `B4_CODE_END` (or B5) in your assets.inc is not this engine's |
| `a bank-number or write-bank site in the menus' image` | your menus used `bankimm`/`wrsel`: read the bank from PBANK (`ldpbank`) instead |
| `layout: n differences` | a variable sits at different addresses on the two machines: something you put in a shared segment differs by `BHW` |
| `a hot branch crosses a page` (a warning) | a `SAMEPAGE` in the engine is not met: move code, or ask |

## Step 10: test

`test/lib/harness.mjs` drives jsbeeb frame-exactly: every wait is "run to the next
`frame_top`", so a test's inputs land on the same frame whatever the code's timing.
Subclass `Harness` to name your game's state for the scene fingerprint, and write
the way into a level.  Cleo's `test/harness.mjs`:

    import { Harness, loadLabels, loadBanks, dbgPath } from "../beebgame/test/lib/harness.mjs";
    export * from "../beebgame/test/lib/harness.mjs";

    export class CleoHarness extends Harness {
      gameScene() {
        const A = this.A;
        return [["px", A.px, 2], ["py", A.py, 2], ["vx", A.vx, 2], ["vy", A.vy, 2],
                ["frame", A.frame, 2], ["health", A.health, 1], ["hurt", A.hurt, 1],
                ["level", A.level, 1], ["score", A.score, 3]];
      }
    }

Its `open()` boots the disc, patches the title's `jsr title_menu` to start a game,
waits for the engine's `game_in` (the game's image just in) to choose the level, and
runs to the first `frame_top`.  `boards.mjs` emulates the Watford and Solidisk
write-select boards on jsbeeb, which has neither.

Keep a reference build (`build/`'s disc, labels and `game.dbg`) and compare a new
build against it level by level on both machines: Cleo's `test/sweep.sh`,
`wincmp.mjs` and `bwincmp.mjs` are the model, and its `roundtrip.mjs` plays whole
sessions through both images.  `python3 -m unittest discover -s beebgame/test` tests
the engine's level file writer.

## Limits to design within

- **Sixteen levels**, `L0`..`L15`, and three tile files: the loader names them.
- **Sprites:** 118 directory entries, the last 15 opaque boxes; at most MAXSPR on screen
  (your asset step's figure; Cleo's is 24).
- **Objects:** 149 at most, 6 bytes each, yours to define.
- **A level file** must fit the Model B's 8K level stage (Cleo's biggest is 8,448 bytes
  with its 512-byte LV_PAGE0 tail).
- **Bank 7:** the game's image is 14,080 bytes, of which the engine's code, variables
  and level tables take about 4.1K: about 9.9K is yours for code, data and variables
  (Cleo uses 9.5K).  The menus' image is 14,080 bytes less the music player's 157:
  about 13.9K (Cleo uses 11.4K, its title pictures and their unpack buffer most of it).
- **The window** is 84 game pixels tall on the Model B and 120 on the Master.
- **The disc** is one single-sided 80-track DFS disc of 800 sectors (Cleo leaves 22
  free).  Its files are the engine's list (the boot files, each machine's bank pieces,
  loaders and bank 7 images, BAR, SPRX, SPRC, TILES0-2, L0-L15): a game adds none, and
  what it needs goes in those -- the menus' art, for instance, in the menus' image.
