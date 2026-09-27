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

## The concepts

The engine works in several units at once, and most mistakes in a new game are
mixing two of them.  This section defines them and then shows how the tiles, the
sprites and their masks are laid out in memory.  Throughout this guide, and the
engine's other documents, the word "pixel" never stands alone: it is always a
**screen pixel** or a **game pixel**.

### Screen pixels, game pixels, scanlines

A **screen pixel** is MODE 1's: 320 across a scanline, one of four colours (two
bits).  A **scanline** is one line of the display.

A **game pixel** is the game's square pixel: **2 screen pixels wide and 2 scanlines
tall**.  Everything the game sees -- positions, speeds, sizes, the map -- is in game
pixels.  The playfield is 160 game pixels wide on both machines (320 screen pixels),
and 84 game pixels tall on the Model B (168 scanlines) or 120 on the Master (240).

A game pixel's colour is not one of the four: it is a 2x2 **dither** of its four
screen pixels, chosen from black, cyan, magenta and yellow to come nearest the colour
the artist meant (Cleo's `tools/convert.py` does this).  So a game pixel can show
many more than four colours, and it is the smallest thing the art can change.

### Bytes, characters, character rows

MODE 1 packs **4 screen pixels into a byte** -- that is 2 game pixels across and 1
scanline down.  Screen pixel i of a byte (0 the leftmost) keeps its colour's high bit
in bit 7-i and its low bit in bit 3-i.

The screen is built from **characters**: a character is 8 bytes stacked, one byte a
scanline -- 4 screen pixels (2 game pixels) wide, 8 scanlines (4 game pixels) tall.
A **character row** is 80 characters side by side: 640 bytes, the full width.

| Unit | Screen pixels across | Scanlines down | Game pixels across x down | Bytes |
|---|---|---|---|---|
| screen pixel | 1 | 1 | half x half | a quarter |
| game pixel | 2 | 2 | 1 x 1 | half a byte on each of 2 scanlines |
| byte | 4 | 1 | 2 x half | 1 |
| character | 4 | 8 | 2 x 4 | 8 |
| tile | 16 | 16 | 8 x 8 | 64 |
| character row | 320 | 8 | 160 x 4 | 640 |

### Where things are: the coordinates

- **Map coordinates** are in game pixels from the map's top left: the window's
  position (`wx`, `wy`) and every sprite's (`spx`, `spy`).
- **Tile coordinates** are map coordinates divided by 8: the map is a grid of
  1 << lw by 1 << lh tiles (its header's lw and lh), one byte (a tile id) each.
- **Character coordinates** are what the display scrolls by: `wcx` = wx / 2
  (character columns, 2 game pixels each) and `wcy` = wy / 4 (character rows, 4 game
  pixels each).

What can move by how much:

| What | Across | Down |
|---|---|---|
| the window (`wx`, `wy`) | 2 game pixels (a character column: `wx` must be even) | 1 game pixel (2 scanlines) |
| a sprite (`spx`, `spy`) | 2 game pixels: the engine drops the low bit of its screen x | 1 game pixel |
| a tile | 8 game pixels (it is on the map's grid) | 8 game pixels |

So a sprite drawn one game pixel further right each frame appears to move every
other frame.  A game that needs smoother movement across must keep a second image
shifted by one game pixel and choose between them itself.

### A tile

A tile is 8 x 8 game pixels: 4 characters across, 2 character rows down, 64 bytes, in
the screen's own order -- the top character row's four characters (8 bytes each, a
scanline a byte), then the bottom row's:

```text
bytes  0-7   8-15  16-23  24-31      scanlines 0-7    (game-pixel rows 0-3)
bytes 32-39 40-47  48-55  56-63      scanlines 8-15   (game-pixel rows 4-7)
      char0 char1  char2  char3      each 2 game pixels (4 screen pixels) wide
```

The two scanlines of a game-pixel row are separate bytes, because the dither puts
different screen pixels on each.  Tiles are opaque: a tile covers its 8 x 8 game
pixels completely, and the level's tile ids say which tile goes where.

### A sprite's image

A sprite is a rectangle `W` bytes wide -- 2W game pixels, 4W screen pixels -- and
`lines` scanlines tall (2 for each game-pixel row: `lines` = 2 x h).  Its image is
stored **column by column**: all `lines` bytes of column 0, top to bottom, then
column 1, and so on.  A 6 x 4 game-pixel sprite is 3 bytes wide and 8 scanlines tall:

```text
image bytes, column-major (W = 3, lines = 8, 24 bytes):
  column 0: bytes  0-7    game pixels 0-1 across, scanlines 0-7
  column 1: bytes  8-15   game pixels 2-3 across
  column 2: bytes 16-23   game pixels 4-5 across
```

A transparent game pixel is stored as 0 (its four screen pixels black).  That alone
cannot say "transparent", because black is a colour; the mask does.

### A sprite's mask

The mask has **one bit per game pixel**: 1 opaque, 0 transparent.  It cannot be finer
(a single screen pixel cannot be transparent on its own) and it need not be, since a
game pixel is the smallest thing the art changes.

- Each image column (2 game pixels) has a 2-bit pair: its left game pixel in the
  pair's high bit.
- Four columns' pairs pack into one mask byte: column 4g+j at bits 7-2j and 6-2j.
- There is one mask byte per game-pixel row, which both of that row's scanlines use.
- The plane is stored by **column group**: all the rows of columns 0-3, then all the
  rows of columns 4-7...  It is a quarter of the image's width in bytes and half its
  height, and the blitter's mask pointer steps through it as its image pointer steps
  through the image.

For the 6 x 4 game-pixel sprite above -- one column group, 4 game-pixel rows:

```text
mask bytes (4):   bits 7 6 | 5 4 | 3 2 | 1 0
                  col 0    | col 1 | col 2 | (col 3: none, 0)
                  L  R     | L  R  | L  R
row 0 (scanlines 0, 1):  one byte
row 1 (scanlines 2, 3):  one byte   ...and so on for rows 2 and 3
```

When the sprite is drawn, each column's pair becomes the AND mask for its screen
byte: 00 keeps the byte ($FF), 01 keeps its left half ($CC, the right game pixel
opaque), 10 keeps its right half ($33), 11 replaces it ($00).  The screen byte becomes
(screen AND mask) OR image.

### Sprite ids, and boxes

A sprite id indexes the level's directory.  Your asset step chooses two numbers,
`BOXID0` and `BOXN`: ids below `BOXID0` are ordinary sprites (masked), and the `BOXN`
ids from `BOXID0` are **boxes**, opaque rectangles with their background baked into
the art, no mask, drawn by a plain copy.  A box is cheaper to draw than a masked
sprite, and suits a thing that sits still on a known background.  Two rules come with
boxes:

- A box drawn at the same place as the box before it must cover it completely -- the
  frames of one animation, the same size.  The engine does not erase the old one.
- Ids from `BOXID0 + BOXN` up (to `BOXID0 + 2 x BOXN - 1`) are **still** aliases: each
  draws as the box `BOXN` below it, and tells the engine nothing will move over it, so
  it may skip redrawing the box while it is unchanged.  Use them for boxes the player
  can never pass in front of.


### A sprite's directory entry

Each sprite id has an 8-byte entry in the level's directory: the image's address
(filled in by the level writer), then six bytes of geometry:

| Byte | Field | Unit |
|---|---|---|
| 2 | W, the width | bytes (2 game pixels each) |
| 3 | h, the height | game pixels |
| 4 | refx, the reference point across (signed) | game pixels |
| 5 | refy, the reference point down (signed) | game pixels |
| 6 | flags: bit 0 drawn mirrored, bit 1 every scanline stored (else one a game-pixel row, drawn twice), bit 3 a box (copied, no mask), bit 4 in bank 5 | |
| 7 | lines, the scanlines stored | scanlines |

The sprite's top left lands at (`spx` - refx, `spy` - refy) in map coordinates, so the
reference point is where the game says the sprite is: a character's feet, say, so
that its frames of different sizes all stand on the same ground.  Its mask's address is in SPRMASK, by id.

## Step 1: make the project

Make a repository with beebgame as a submodule, and lay it out like Cleo's:

```text
mygame/
  beebgame/          the engine (git submodule add https://github.com/ebenupton/beebgame beebgame)
  build.sh           your build: sets beebgame's driver going
  src/               your 6502 sources
    main.s           the root: the engine's sources and yours, and the hooks
    keymap.inc       your keys
  assets/            your source art, levels and music, in the repository: the
                     build reads nothing from outside it
  tools/             your asset pipeline
  test/              your tests, on beebgame's harness
  build/             generated
```

Cleo's `src/` has `main.s`, `logic.s` (the game's logic and HUD), `game.s` (the game
loop), `menu.s` (the menus), `gamedata.s` (its tables) and `keymap.inc`; its
`assets/v500/` is the original J2ME game's data (the tile and sprite sheets, the
levels, the tune), which its `tools/convert.py` reads.

## Step 2: the build script

Your `build.sh` sets a few variables and runs the engine's driver, which assembles
everything twice (once per machine), builds the loaders and writes the disc.  Cleo's,
whole:

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"
[ -f beebgame/tools/build.sh ] || { echo "beebgame is missing: git submodule update --init"; exit 1; }
export GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd GAME_NAME=Cleo
export GAME_MUSIC="python3 beebgame/tools/midi2snd.py assets/v500/thm.mid build/MUSIC"
export GAME_ASSETS="python3 tools/assets.py"
exec sh beebgame/tools/build.sh
```

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

```asm
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
```

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
| `GAMECODE`, `GAMEDATA` | your game's code and tables | bank 7, the game's image |
| `GAMEBSS` | your game's variables (zeroed each time the image loads) | bank 7, the game's image |
| `MNUCODE`, `MNUDATA`, `MNUBSS` | your menus, and their art and tune | bank 7, the menus' image |
| `LOWBSS` | a few bytes both images see | low RAM, shared with the engine: keep it small |

Two rules:

- **Define a zero-page variable before its first use.**  ca65 assembles a forward
  reference as absolute (a byte and a cycle more), so put your zero page ahead of
  your code, in the first of your sources `main.s` includes, as Cleo's `logic.s` does:

  ```asm
          .segment "ZPGAME": zeropage
  BINI:     .res 1
  frame:    .res 2
  px:       .res 2                  ; player x, y (game pixels, map coordinates)
  ...
  ```

- **The game's image and the menus' image cannot call each other.**  Both are at
  the same addresses in bank 7, one at a time.  Anything both need goes in the kernel
  (`PLACEH "CODE", "KRNCODE"`) or in zero page and low RAM.

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

```asm
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
```

For input, wait a vsync and take the keys newly down (`keys` holds `K_LEFT`, `K_RIGHT`,
`K_UP`, `K_DOWN`, `K_FIRE`, set by the interrupt from your key map):

```asm
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
```

Draw text and pictures through `ringaddr7`, a character row at a time.  If your menus
are all on black, a picture needs no mask: Cleo's are run-length streams copied
straight to the screen (its `menu.s`).

**Music.**  `jsr music_start` plays the tune at `MUSIC_ADDR` from the interrupt,
looping; `jsr music_stop` silences it (every load does too).  Cleo starts it on the
title unless it is already playing.

**Starting a game.**  Set up the game's state in zero page -- it survives the swap --
and `jmp go_game`.  The engine loads the game's image and jumps to `hook_play`:

```asm
new_game:
        stz level
        ...
        lda #3
        sta lives
        sta health
        ...
        jmp go_game
```

**After a game.**  Your game ends with `lda #n / jmp go_menu`; the engine loads the
menus' image and jumps to `hook_over` with n in A.  Cleo's shows its win or lose
screen and goes back to the title:

```asm
menu_over:
        jsr winlose                 ; A = 0 lost, 1 won
        jmp title_loop
```

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

```asm
load_level:
        jsr load_level_b            ; the disc: everything into the banks
        ...                         ; mapw = 8 << lw, maph = 8 << lh (game pixels), from
        ldx LV_HDR+HDR_LW           ;  the header: HDR_ offsets are the engine's
        stx maplw                   ;  (levelfmt.inc)
        ...
        ldx LV_HDR+HDR_LH
        stx maplh
        ...                         ; maxwx = mapw - WINPX, maxwy = maph - VISLINES/2
        jsr lvreset                 ; the records and the buffers' state
        sta NSPR                    ; A = 0: the sprite list empty
        rts
```

Your own header fields and objects are there too: `LV_HDR` (your bytes: +2..+5,
+7..+19), `LV_OBJS` (6 bytes an object), and the two per-tile tables `LV_ATTR0` and
`LV_ALTCLS`, 256 bytes each, for whatever your logic wants to know about a tile id.

**The level loop:**

```asm
level_loop:
        jsr blank_palette           ; hide the loading and the first frame's build-up
        ldx level
        jsr load_level
        jsr level_init              ; (the game's: the objects, the player, the camera)
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
```

Label `frame_top` exactly as Cleo does: the test harness runs frame to frame by it.

**A frame of logic** does three things the engine reads:

- **The window.**  Set `wx`, `wy` (game pixels, map coordinates; `wx` even) and keep them within
  `0..maxwx`, `0..maxwy` (Cleo's `clamp_window`).  `render_frame` scrolls to them.
- **The sprites.**  Empty the list (`stz NSPR`), then for each sprite set `spx`, `spy`
  (game pixels, map coordinates: the sprite's reference point; across, the sprite
  lands on the even game pixel at or left of it) and `lda #id / jsr addsprite`.  At most
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

```asm
; Z and cursor left K_LEFT, X and cursor right K_RIGHT, : and cursor up K_UP,
; RETURN and SPACE K_FIRE, / and cursor down K_DOWN
KEYN = 10
keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE
```

**Sound effects:** `sfxtab`, a word per effect, each a list of SN76489 steps (the
channel's latch byte, its data byte, its volume byte, and how many frames to hold)
ending `$FF`.  It must be resident, so place it with `PLACEH`:

```asm
        PLACEH "CODE", "KRNCODE"    ; bank 7's kernel on the Model B, main RAM on the Master
sfxtab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump: .byte $C0|8, 12, $D0, 2,  $C0|4, 9, $D2, 2,  $C0|0, 7, $D4, 2,  $C0|8, 5, $D6, 3, $FF
```

**Music:** `beebgame/tools/midi2snd.py <in.mid> <out>` turns a MIDI file into the player's
stream (a melody and two voices of backing).  Put it in your menus' image at
`MUSIC_ADDR`:

```asm
        .segment "MNUDATA"
MUSIC_ADDR:
        .incbin "music.bin"
```

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

**assets.inc:**

| Constant | Meaning |
|---|---|
| `TOFF` | tile id k is in slot k + TOFF of bank 6 (2, or 4 with TILEMIRROR) |
| `FLAT0`, `NFLAT` | the flat tiles' first id and count (the last two are the solids) |
| `MAXMIR` | mirrored tiles at most (TILEMIRROR only; else 0) |
| `BOXID0`, `BOXN` | the first box id, and how many boxes (*Sprite ids, and boxes*) |
| `MAXSPRDEF` | the sprite list's size: the most sprites on screen at once |
| `SPRC_BASE`, `SPRC_LEN`, `SPRC5_BASE`, `SPRC5_LEN`, `SPRX_LEN` | the resident and staged sprites (below) |
| `SPR5_MIRROR`, `SPR4_COPY` | 0: nothing mirrored in bank 5, nothing opaque in bank 4 |
| `MAP5` | the map's place in bank 5 ($9C00) |
| `B4_CODE_END`, `B5_CODE_END` | where the engine's sprite-bank code ends: your sprites start there |

Your asset step may add your own constants to `assets.inc` for your own sources
(Cleo adds BINMAXDEF, its bin walk's list size, and its title pieces' TP_ and
TBUF_LEN); the engine reads only the ones above.

`B4_CODE_END` and `B5_CODE_END` are the engine's, not yours: take them from the
engine version you build against (Cleo's `tools/assets.py` has the current ones).  If
they are wrong the build stops with an assertion saying which.

**A level file** is one call to `levelfile.encode()`.  Your packer gathers the level
in the engine's terms: the map as tile ids, the tile set's shape and lists, the
sprites' placements and directory, and your own header fields, objects and tile
tables.  Cleo's, from `tools/assets.py`:

```python
import levelfile as lf       # (beebgame/tools on sys.path)

ghdr = {HDR_STARTX: L['start'][0], HDR_STARTY: L['start'][1],
        HDR_EXITX: L['exit'][0], HDR_EXITY: L['exit'][1]}          # Cleo's own fields
placement = lf.placement([(item, bank, img_addr, mask_addr), ...])  # images this level loads
directory, smask = lf.directory(entries, masks)                     # BOXID0 + BOXN entries, BOXID0 masks
data = lf.encode(lf.Level(lw=L['lw'], lh=L['lh'], game_header=ghdr,
                          shape=lf.Shape(**T['B']['shape']),
                          objects=bytes(objs), tile_tables=(bytes(attr), bytes(acls)),
                          tiles=T['B']['tiles'], placement=placement, map=mapb,
                          flat=T['flat'], halves=T['halves'], hpair=T['hpair'],
                          mir=T['B']['mir'], directory=directory, masks=smask,
                          page0=T['B']['page0'], boxid0=BOXID0, boxn=BOXN))
open(os.path.join(OUT, 'L%d' % n), 'wb').write(data)
```

`encode()` checks the sizes and limits (the objects, the stages, the map, the header's
engine fields); the build runs `levelfile.py check` on every level too.  The format is
in `DESIGN.md`, *The level files*.

**The tiles and the sprites** are the part to be most careful with: their layouts are
the blitters' (`DESIGN.md`, *The tiles* and *The sprites*).  In short:

- A tile's 64 bytes and a sprite's image, mask and directory entry are laid out as
  *The concepts* shows.
- Tile id 0 is the level's solid colour; the rest are full tiles (all 64 bytes
  stored), half tiles (one character row of the two stored, the other a fill), flat
  tiles (a colour's dither, two bytes alternating down the scanlines) and, if you need
  them, mirrored ones.  A level has at most 250 distinct ids.
- Mirrored images go in bank 4 (it has the table that reverses a byte's four screen
  pixels), boxes in bank 5 (it has the copy blitter), and an image and its mask in the
  same bank.

**Resident and staged sprites.**  Every sprite image is in one of two files, and which
is your choice:

- **SPRC, the resident sprites**, loaded once, at the first level, to fixed places:
  SPRC_LEN bytes to bank 4 from SPRC_BASE (= B4_CODE_END), then SPRC5_LEN bytes to
  bank 5 from SPRC5_BASE (= B5_CODE_END).  They stay for the whole session, so every
  level's directory names them at those addresses and no level loads them again.
- **SPRX, the staged sprites**, SPRX_LEN bytes: everything else.  Each level load
  stages SPRX whole and copies out just the images and masks that level's placement
  list names, to the addresses the list gives.  `imgtab.bin` has an entry per item
  saying where in SPRX its image and mask are (zeros for a resident item).
- The rest of each sprite bank is the level's: bank 4 from the end of SPRC's part to
  $BAFF, bank 5 from the end of its part to $9BFF.

Make resident what (nearly) every level draws -- the player, what the player throws,
the pickups -- and stage the rest.  A bigger resident set means shorter loads and less
room for each level's own sprites; a smaller one, the reverse.  Limits: SPRX at most
16K (the Model B's stage) and 12K (the Master keeps it in HAZEL and ANDY); the
resident parts and the biggest level's own sprites together must fit each bank.
Cleo declares its split in one place at the top of its packer (`RESIDENT_IDS` in
`tools/assets.py`).

Today the engine has no tile packer or sprite placer of its own beyond `sprpack.py`
(which orders a bank's images to save page crossings).  **Start from Cleo's**:
`tools/convert.py` `pack_tiles` builds a level's tile ids, lists and shape from its
tile art, and `tools/assets.py` places each level's sprites, writes SPRC, SPRX and
imgtab.bin, and sizes MAXSPR from the level's objects.  Copy them and replace what
reads Cleo's data (its `assets/v500` sheets and levels, its object types) with your own.

## Step 9: build and run

```sh
git submodule update --init
sh build.sh
```

The build prints a line per level from your asset step, the bank pieces, `layout: the
data sits alike on both machines`, and the disc.  Boot it in jsbeeb or BeebEm
(SHIFT+BREAK), as a Master 128 and as a Model B with sideways RAM.

What stops a build, and what to do:

| Message | Meaning |
|---|---|
| `Symbol 'hook_...' is undefined` | a hook is missing from `main.s` (Step 3) |
| ld65's `Memory area overflow` in `B7` or `B7M` | your game's image, or your menus', is full (the limits below) |
| `the game image's variables run into its code` | GAMEBSS and the engine's variables have met your code: trim either |
| `bank 4's code must end where its sprites start` | `B4_CODE_END` (or B5) in your assets.inc is not this engine's |
| `a bank-number or write-bank site in the menus' image` | your menus used `bankimm`/`wrsel`: read the bank from PBANK (`ldpbank`) instead |
| `layout: n differences` | a variable sits at different addresses on the two machines: something you put in a shared segment differs by `BHW` |
| `a hot branch crosses a page` (a warning) | a `SAMEPAGE` in the engine is not met: move code, or ask |

## Step 10: test

`test/lib/harness.mjs` drives jsbeeb frame-exactly: every wait is "run to the next
`frame_top`", so a test's inputs land on the same frame whatever the code's timing.
Subclass `Harness` to name your game's state for the scene fingerprint, and write
the way into a level.  Cleo's `test/harness.mjs`:

```js
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
```

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
- **Sprites:** BOXID0 + BOXN sprite ids, and the still aliases after them, all below
  256; at most MAXSPR on screen at once.
- **Objects:** 149 at most, 6 bytes each, yours to define.
- **A level file** must fit the Model B's 8K level stage, not counting its 512-byte
  LV_PAGE0 tail.
- **Sprite files:** SPRX at most 12K; SPRC's parts and each level's own sprites within
  banks 4 and 5.
- **Bank 7:** the game's image is 14,080 bytes, of which the engine's code, variables
  and level tables take about 4.1K: about 9.9K is yours for code, data and variables.
  The menus' image is 14,080 bytes less the music player's 157: about 13.9K.
- **The window** is 84 game pixels tall on the Model B and 120 on the Master.
- **The disc** is one single-sided 80-track DFS disc of 800 sectors.  Its files are the engine's list (the boot files, each machine's bank pieces,
  loaders and bank 7 images, BAR, SPRX, SPRC, TILES0-2, L0-L15): a game adds none, and
  what it needs goes in those -- the menus' art, for instance, in the menus' image.
