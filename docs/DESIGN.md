# beebgame -- design

What the engine is and why it is shaped as it is.  Written against beebgame `867cc88` and
Cleo `ce2d7e2`, from the sources, the linker map (`cfg/banks.cfg`) and one build of Cleo
(`build/{modelb,master}/labels.txt`, `assets.inc`, `files.inc`, `defs_ld.inc`, the build's
printed lines).  Every address or size quoted "as built today" is Cleo's and comes from that
build; the symbol that names it is the thing to read, the number is for orientation.

Terminology.  A *screen pixel* is a MODE 1 pixel; a *game pixel* is 2 x 2 of them (a byte of
MODE 1 holds four screen pixels, so two game pixels across).  A *scanline* is one of the 312
lines of a PAL frame; a *character* (char) is 8 bytes, one a scanline; a *character row* is 8
scanlines.  A *tile* is 8 x 8 game pixels: 4 chars across, 2 char rows down, 64 bytes.  The
*ring* is a buffer of RINGROWS char rows the window slides round; a *slot* is one of its rows.
The display is a *rupture*: a *chain* of CRTC *sections* that together make one frame.  Bank 7
below its *kernel* holds one of two *images*, the game's or the menus'.  Sprites are *resident*
(the SPRC file, loaded once) or *staged* (SPRX, placed per level); a *box* is an opaque
copied sprite; a *baked* box is one the loader makes from the level's own tiles.

Contents

 1. One structure, two machines
 2. Main RAM
 3. The banks
 4. The crossings and the write bank
 5. The display
 6. The frame
 7. The tiles
 8. The sprites
 9. The disc and the loader
10. Sound
11. The build
12. Testing, the 6502 spellings and the ca65 traps


## 1. One structure, two machines

The engine is one set of sources assembled twice.  `BHW=1` is the BBC Model B's hardware:
a 6502, 32K of main RAM of which all but 768 bytes is display, two software rings with
mirror rows, an 8271 or Acorn 1770 disc controller, and the write-select sideways RAM boards
(Watford, Solidisk).  `BHW=0` is the Master 128's: a 65C02, a hardware-wrapped ring in main
and shadow RAM, its interrupt handler in main RAM, its own 1770.  `cpu.inc` defaults `BHW`
to 1; `tools/build.sh settarget` passes `--cpu 65C02 -D BHW=0` for the Master and writes the
two builds to `build/modelb` and `build/master`.  Both machines want four 16K banks of
sideways RAM (the Master has them); the boot loader finds them in whatever sockets they are
(section 4).

One linker map serves both: `cfg/banks.cfg`.  The Master's own areas (`MRAM`, `MRAMB`,
`HAZ`) and segments (`MRAMCODE`, `MRAMBSS`, `HAZ*`) are empty in the Model B's link, and an
empty area with a file writes an empty file the build does not read.  The two separately
assembled programs have their own maps: `cfg/ldprog.cfg` (the load-time program at
`LDPROG`) and `cfg/loader.cfg` (the boot loader at `$1900`).

### The convergence rule

The two builds differ only in (`src/engine.s` header, `cpu.inc`):

- the CPU's spellings (section 12): shared code uses `cpu.inc`'s macros, Master-only code
  under `.if .not BHW` is written in native 65C02;
- the hardware: the ring (section 5), the CRTC phasing constants, ACCCON, the disc
  controller's addresses, the boards;
- three placements the Master is allowed, because it has main RAM to spare:
  1. the interrupt handler and its state in main RAM -- `cpu.inc PLACEH mseg, bseg` puts
     the interrupt's own work in `MRAMCODE` (area `MRAM`, $0600) and its tables in
     `MRAMBSS` (area `MRAMB`, $0C00) on the Master, and in `KRNCODE`/`KRNHW` (bank 7) on the
     Model B (`kernel.s`, `vars.s`);
  2. the tile gather as a table, `LV_PAGE0` ($0400, `defs.inc`, Master only), where the
     Model B computes the same pairs arithmetically (`gather.s`, section 7);
  3. the staged sprites kept across loads in HAZEL and ANDY (`ldprog.s SPRXKEEP`,
     section 9);
- and the bigger view: `engine/defs.s` `VISROWS` is 30 char rows on the Master and 21 on the
  Model B, `RINGROWS` 32 and 23.

Everything else -- every table, every variable, every level file -- lies at the same address
on both.  Two tools enforce it in the build:

- `tools/pincfg.py` rewrites the Master's linker config so that every segment the Model B
  also has starts where the Model B's did (read from the Model B's `game.dbg`), stripping
  any `align`; the Master's shorter 65C02 code then leaves a gap rather than moving what
  follows it.  The segments it leaves free are `BOOT`, `BOOTHDR`, `BANKFIX`, `WRFIX`,
  `MRAMCODE`, `MRAMBSS`, `D8271N`, `D1770N` (its `FREE` set).  `build.sh` links the Master
  with the pinned config unless `MASTERONLY`.
- `tools/layoutcheck.py` compares the two `game.dbg`s at the end of the build: every segment
  both have must start at one address (start-up segments excepted), every data label in a
  non-code segment must sit at one address, and zero page has no exception at all.  Exit 1
  on any difference.  Its `CODE`, `STARTUP` and `OWN` sets say which labels may differ.

The level files are shared because of this: `build.sh` compares `SPRX SPRC BAR L0..L15` and
`assets.inc` between the two builds and fails if they differ.

### Page crossings placed on purpose

A taken 6502 branch costs a cycle more when its target is in another page, and so does an
indexed read that crosses one.  The engine takes two measures:

- `SAMEPAGE from, to` (`cpu.inc`) is a link-time assert that a hot branch and its target
  share a page; the ring macros and `tiles.s` use it.
- `PAD b, m` (`cpu.inc`) emits `b` bytes of padding on the Model B and `m` on the Master.
  The values live in `src/pads.inc` (`PADB_FM`/`PADM_FM` before the mirrored sprite cells,
  `PAD*_MS/_SP/_EO/_DS/_CP` before bank 7's hot routines, `PAD*_T6` before `draw_rect`,
  `PADB_BB` before `render_frame`).  Bank 7's pads move with the kernel's start (the driver
  slot sets it: section 3), and `pads.inc` says they are re-found with Cleo's
  `test/cycprof.mjs` (PHASEDUMP) and `test/padopt.py`, and the order of `ENGCODE`'s blocks
  in `engine/frame.s` with `test/blockopt.py`.  `frame.s`'s header: "THE ORDER OF THE
  BLOCKS IS THE LAYOUT'S".

`tools/pagecheck.py <build dir>` lists every branch in a build's code segments that crosses
a page when taken, with its source line, from `game.dbg` and the segment images.


## 2. Main RAM

### Zero page

Zero page is laid out alike on both machines (`vars.s`; `layoutcheck.py` fails the build
otherwise): what one machine alone uses is reserved on the other.  The map (`banks.cfg`
MEMORY `ZP`, `ZPEND`):

| range   | segment    | contents |
|---------|------------|----------|
| $00-    | `ZEROPAGE` | the engine's: `defs.inc`'s first thirteen, then `vars.s`'s |
| ..-$FB  | `ZPGAME`   | the game's (`__ZPGAME_RUN__`, `__ZPGAME_SIZE__`: $8B, 113 bytes today) |
| $FC     | --         | the MOS ROM's interrupt entry keeps A here (`hw.inc MOS_IRQA`) |
| $FD-$FF | `ZPTOP`    | `romsel_cpy` (= `ROMSEL_CPY`, asserted) then `crtcb` (2) |

There is no MOS zero page in use and no machine-dependent block.  `defs.inc` defines the
first thirteen bytes, used before `engine.s` is included so every access assembles as zero
page: `nspr bar_dirty sfx_req mtmp ringbhi ringehi ringe3 mrow wcxm sp_disp sp_g cur_r7
sec_idx`.  `vars.s` lays the rest of the engine's part out by owner: each machine's own
(`jv`, `crtcbm`, `qsect`, `ksect`, `palon`), scratch (`ptr tp sp tmp tmp2`, the flip's
`disp_sect next_sect load_req sfx_dur`, `tmp3 tmp4 cnt w16 w16b`), the window (`wx wy wcx
wcy [wcyh] wfine cur_buf recp rp`), `draw_rect`'s arguments and per-rect invariants (`rc_*`,
`row_off`), the interrupt's `irq_x irq_y`, the sprite prologue's (`spx spy`, then from
`LDZP` seventeen bytes the loader borrows: `sp_ptr` .. `sp_cnt`, asserted), `spi [sp_dfl]
lcnt lidx`, the ring (`ring_s barq`), the level's geometry (`maplw mapw maph maxwx
maxwy`), the sprite clip's `row_lim`, `vsyncs flip_req flipvs keys map_ptr sfx_ptr mus_ptr`, the Model B's gather shape
(`half0 halfhi5 half_sub`) and the hot scalars (`map_stride map_shr mus_tick disp_d dsect
next_buf row_bit dpass sp_clip mus_on`).

`init.s boot` zeroes $00-$EF and $F0-$FF (and low RAM up to `IRQ1V`) before anything runs.

### Low RAM

| range       | what | where defined |
|-------------|------|---------------|
| $0100-$013F | the stack, 64 bytes (`STACKTOP = $3F`) | `defs.inc`; `init.s`, `ldprog.s` set it |
| $0140-$0203 | `LOWBSS`, then `LOWHW` (one machine's own, last) | `banks.cfg` `LOWBS` |
| $0204       | `IRQ1V` | `hw.inc` |
| $0206-$02FF | `LOWCODE` (run address), then `LOWBSS2` | `banks.cfg` `LOWRAM` |

`LOWBSS` holds what every bank must see and what the interrupt writes: `BUF_CY BUF_CXL
BUF_CXH` (each buffer's window), `PBANK` (4: the physical socket of banks 4..7) and `pboard`
(`vars.s`); `GATHERH` (21), `clip_mask`, `krlo krhi2 kclo kchi2`, `sprc_ok sprx_ok`, and the
tune's `mus_dur MUSNOTE isr_t1 isr_t2` (`low.s`); on the Model B `LOWHW` adds the mirror's
`MIRDTY MIRLO MIRHI MIRWCX MIRMR`.  `LOWBSS2` is `GATHERL` (21), above the code.  The sprite
list and the dirty lists are not here: they are bank 7's `ENGBSS` (section 6).

`LOWCODE` (`low.s`, `engine/lowram.s`) is assembled into the BOOT piece at `$7000` and copied
down by `boot`, a byte at a time (asserted under 256 bytes).

### The Model B's main RAM

Everything from $0300 to $8000 is display (`engine/defs.s`, screen shape):

| address     | what | symbol |
|-------------|------|--------|
| $0300-$07FF | the status bar, 2 rows, one for both buffers | `BARADDR` |
| $0800-$0A7F | mirror A, 1 row | `MIRR_A` (= `CLEAR0`) |
| $0A80-$43FF | ring A, 23 rows: buffer 0 | `RING_A` (= `RING0`) |
| $4400-$467F | mirror B | `RING_B - ROWBYTES` |
| $4680-$7FFF | ring B, 23 rows: buffer 1 | `RING_B` |

The asserts there: both ring ends are page aligned (so the fold test is a high-byte compare,
`ringup`), both bases are at xx80 (so the low byte folds by $80), and `MIRR_A` follows the
bar.  `QBLANK` on the Model B is `BARADDR + 45*8`: the bar's own bytes (section 5).

While a level loads, the display is the loader's scratch, black: the driver's NMI stub runs
at `NMIPAGE = $0D00` and the load-time program at `LDPROG = $0E00` (both machines), `STAGE
= $1C00` holds a shared file (16K at most), `STAGE_LVL = $5C00` the level's own file (8K at
most without its last two sectors), and the level's objects go to `LV_OBJS = $7C00`
(`defs.inc`).

### The Master's main RAM

| address     | what | symbol |
|-------------|------|--------|
| $0400-$05FF | the level's tile table: 256 low bytes, 256 high | `LV_PAGE0` (`defs.inc`) |
| $0600-$0BFF | the interrupt handler, keys, sound | `MRAM` / `MRAMCODE` |
| $0C00-$0CFF | its state: the chain tables | `MRAMB` / `MRAMBSS` |
| $0D00       | the disc driver's NMI stub, during a load | `NMIPAGE` |
| $0E00-$1BFF | the load-time program | `LDPROG` |
| $1C00-      | the level's objects, `OBJ_BYTES` x `OBJ_MAX` | `LV_OBJS` |
| $2880-$2AFF | Q's black line: 640 zeros | `QBLANK = BARADDR - ROWBYTES` |
| $2B00-$2FFF | the bar, main RAM only, single buffered | `BARADDR` |
| $3000-$7FFF | the ring, 32 rows: main RAM = buffer 0, shadow = buffer 1 | `RINGBASE` |

`defs.s` asserts `LV_OBJS + OBJ_BYTES*OBJ_MAX <= QBLANK`.  The loader's `STAGE` and
`STAGE_LVL` are both $3000: a shared file is staged in shadow RAM (ACCCON X set while it is
read or copied), the level's own file in main RAM.  `NMIPAGE` and `LDPROG` are the same on
both machines (asserted against the cfg's `NMI8271`/`NMI1770`/`LDP` areas).

### The staged sprites on the Master

With `SPRXKEEP` (`BHW = 0` and not `GAMEHAZEL`) the Master reads the SPRX file once and keeps
it in HAZEL ($C000, 8K, ACCCON Y) and ANDY ($8000 with ROMSEL bit 7, 4K); every later load
refills the stage from them with no disc read (`ldprog.s unkeep`, `kpart`).  `SPRX_PAGES <=
HAZEL_PAGES + ANDY_PAGES` is asserted (12K).  `low.s sprx_ok` says the copy exists.

### Start-up

The boot loader (`loader.s`, under the MOS) ends by writing what it found into a header at
`$7000` and jumping to `boot` at `$7007`: `dsk_type` (0 = 8271, 1 = 1770), `dsk_drv`,
`DSK_BANKS` (4), `dsk_board` -- segment `BOOTHDR`, first in area `BOOTRAM` (`init.s`,
asserted; `build.sh` checks the five addresses are equal across the machines so one loader
serves both).  `boot` then, in order (`init.s`): interrupts off, the stack, zero page and
low RAM zeroed, the low-RAM image copied down, bank 7 paged (and made the write bank),
`PBANK`/`pboard` and the driver's `drv_type`/`drv_unit` copied from the header,
`blank_palette`, (Master) `MRAMBSS` zeroed and `QBLANK`'s 640 zeros written, `crtc_init`,
both buffers' chains built for a blank window at the origin, `TILBSS` zeroed through a write
window into bank 6, `take_over` (the interrupt), `page_logic`, `disc_init` (a 1770 is reset
and its head found), `jmp go_title`.  The BOOT piece is display RAM once play starts.


## 3. The banks

Bank numbers are the code's: `BANK_SPR = 4`, `BANK_TIL1 = 5` (= `BANK_MAP`), `BANK_TILES =
6`, `BANK_LVL = 7` (`engine/defs.s`).  The loader patches the physical sockets in
(section 4).  Each bank holds code beside the data its inner loop reads:

```
        bank 4                 bank 5                 bank 6                 bank 7
$C000 +---------------+     +---------------+     +---------------+     +---------------+
      | L0TAB L1TAB   |     | L0TAB L1TAB   |     |               |     | KRNHW, GAMEHI | B7H $BF00
$BC00 | NMASK SWAPTAB |     | NMASK SWAPTAB |     |               |     | driver slot   |
      |               |     |               |     |               |     | kernel (B7K)  |
      |   sprites     |     |  the map 8K   |     |   the level's |     |---------------|
      |   (SPRC, then |     |---------------| MAP5|   tiles, from |     | game image B7 |
      |    SPRX's)    |     |   sprites     |     |   TILES       |     |  ENGCODE      |
      |               |     |               |     |               |     |  GAMECODE     |
      |               |     |---------------| B5_ |---------------|     |  GAMEDATA     |
      |---------------| B4_ | gather5, HLOW | CODE| FLATTAB TILBSS|     |---------------|
      | row loop +    | CODE| row loop +    | _END| draw_rect ... |     | ENGBSS        |
      | blitters      | _END| blitters      |     | TILCODE       |     | GAMEOBJ ...   |
$8000 | ds_entry      |     | ds_entry      |     | bank6_entry   |     | ENGLVL GAMELVL|
      +---------------+     +---------------+     +---------------+     +---------------+
                                                                        (or, in the menus,
                                                                         B7M from $8000)
```

### Banks 4 and 5

The sprite row loop and its three blitters are assembled once into each (`sprloops.s`
`NIB_LOOPS`, segments `SPR4CODE` and `SPR5CODE`), each copy starting its bank at
`BANKENTRY = $8000` with `ds_entry` (asserted).  Bank 5 also holds the gather (`MAP5CODE`,
`gather5`) and on the Model B its `HLOW` table (`MAP5BSS`).  The code must end exactly at
the game's `B4_CODE_END`/`B5_CODE_END` on the Model B and at most there on the Master
(`sprloops.s`, `gather.s` asserts): the packer lays the sprites out from those addresses,
and `build.sh` sizes the cfg's `B4X`/`B5X` areas to them so an overflow fails the link.
The top 1K of each (`B4T`/`B5T` at `B4_DATA_END`) is the expansion tables `L0TAB`, `L1TAB`,
`NMASK` (`nibtab.bin`, `NIBTAB_LEN` = 768) and `SWAPTAB` (the dot reversal), the same in
both so bank 7's prologue can name them for either (`defs.inc`, `banks.s NIB_TABLES`).  The
map is `LV_MAP = MAP5` (`assets.inc`: $9C00), a fixed 8K below the tables.

### Bank 6

`TIL6ENT` is its own segment so that `bank6_entry` is the bank's first byte -- `BANKENTRY`,
where `call_bank` enters -- and falls into `draw_rect_clip` (`tiles.s`, asserted).  Then
`TILCODE` (`draw_rect`, `scroll_validate`, `select_backbuf`, the row tables) and `TILBSS`
(`FLATTAB`, `2*(NFLAT+2)` bytes).  The level's tiles start at `TILES` (`assets.inc`, $8600):
id k is in slot k + `TOFF`, so the first stored tile (id 1; id 0 is a fill) is `TOFF+1`
slots up, and `init.s` asserts `TILBSS` ends below that slot.  `build.sh` sizes `B6X` to
`TILES + (TOFF+1)*64`.

### Bank 7

The top is the kernel, resident whichever image is below it; below it one of two images,
swapped by a disc load.  From the top down (`banks.cfg`, `build.sh`, `vars.s`):

| segment / area | what |
|----------------|------|
| `KRNHW` (area `B7H`, $BF00) | the Model B's chain tables (empty on the Master: `PLACEH`) |
| `GAMEHI` | the game's resident bytes, after `KRNHW`: they survive the image swaps |
| `DRV8271` / `DRV1770` | the driver slot: one of two drivers, copied in at boot (section 9) |
| `KRNDATA`, `KRNCODE`, `KRNBSS` (area `B7K`) | the kernel |
| `GAMEDATA`, `GAMECODE`, `ENGCODE` (area `B7`, file `GAME`) | the game's image, ending at the kernel |
| `ENGBSS` (area `B7B`, page aligned) | the engine's variables |
| `GAMEOBJ`, `GAMEROWH`, `GAMEBSS` (area `B7B`, from $8300) | the game's variables |
| `GAMELVL` (area `B7D`) | the game's page-bound tables, filled at a level's start |
| `ENGLVL` ($8000) | the level's tables the loader fills |
| `MUSCODE`, `MNUCODE`, `MNUDATA`, `MNUBSS` (area `B7M`, file `MENU`) | the menus' image, from $8000 |

In detail: `KRNHW` is `BUF_SEC0` (4), `BUF_SEC0T1` (4), `SECTAB` (2 x `SECBYTES`), `BUF_QS`
(3), `BUF_KS` (3) -- on the Master these are `MRAMBSS`'s.  `GAMEHI` holds Cleo's `score` and
`hi_score`.  The kernel is `mul_rowlo/hi` (`KRNDATA`), the chain's builders, the palette, the
disc reads, `music_stop`, and on the Model B the interrupt body, keys and sound.  The game's
image is its data and code, then the engine's `frame.s` half.  `ENGBSS` is the dirty lists,
the records, `KEEP`, `SPRLIST` and `DIR_TABLE`.  The game's variables are small ones page
aligned at $8300 (`GAMEBSS`), a half-page-aligned table (`GAMEROWH`) and page-aligned arrays
(`GAMEOBJ`).  `GAMELVL` sits in the 224 bytes between `ENGLVL`'s end and $8300
(`__GAMELVL_SIZE__`: Cleo uses 216 today).  `ENGLVL` is `LV_ATTR0` (256), `LV_ALTCLS` (256)
and `LV_HDR` (`HDR_LEN`, with the game's header tail after it).  The menus' image is the
tune's player first (`MUSCODE`), then the game's menus.

`build.sh` fixes the sizes before each link, because ld65 fills an area from its start and
these must end at fixed places.  From `od65 --dump-segsize` of the Model B's object: the
slot is as big as the larger driver (`DRVN`) and ends at `B7H`; the kernel ends at the slot,
moved down a little if `KRNDATA` would straddle a page; the game image ends at the kernel
(`B7` start = kernel start - the three segments' sizes); the menus' image runs from $8000
to the kernel.  The Master's are pinned to the Model B's.  As built today: `__KRNDATA_RUN__`
$B733, `__DRV8271_START__` $BE64 (size $9C), `__B7_START__` $944F, `__ENGBSS_RUN__` $9000
(size $428).  The free room in the game's image is `__B7_START__ - (__ENGBSS_RUN__ +
__ENGBSS_SIZE__)` -- 39 bytes today; in the menus' image `__KRNDATA_RUN__ - (__MNUBSS_RUN__
+ __MNUBSS_SIZE__)` -- 2,249.  The game image's variables (`GAMEBSS` to the end of `ENGBSS`)
are zeroed as the image comes in, to their exact end (`defs_ld.inc` `GAME_BSS`,
`GAME_BSS_PAGES`, `GAME_BSS_REM`; `ldprog.s image_load`).

Why game-first in the image: the engine's `ENGCODE` ends against the kernel on the Model B,
so its hot blocks sit at known distances from the kernel's start and the pads can be found
once for both machines (`pads.inc`); the game's code and data go below it.

The two images are one disc file a machine, `IMG7`: the menus' image padded to a sector,
then the game's (`build.sh`; `ldprog.s MENU_SECS`).


## 4. The crossings and the write bank

A bank cannot page another over itself, so every crossing is in low RAM (`low.s`,
`engine/lowram.s`), with no table and no dispatch in any bank:

| routine | what |
|---------|------|
| `call_bank` | A = a bank: page it, `jsr BANKENTRY`, page bank 7 back.  Once a sprite (banks 4/5) and once a rect (bank 6) |
| `selbb` | page bank 6, open a write window, `select_backbuf`, close it, bank 7 back |
| `validate` | page bank 6, `scroll_validate`, bank 7 back (no window: it stores into no bank itself) |
| `map_strip` | page bank 5, `gather5`, page bank 6 back (`page6`): once a tile row |
| `map_row`, `map_col`, `map_byte`, `map_put` | the logic's map access: page bank 5, read (or write, in a window), bank 7 back |
| `page_logic` | bank 7 back, every register and the carry kept: the way home from every crossing |

`ROMSEL_CPY` is written before `ROMSEL` every time, so an interrupt between the two puts
back the bank being entered: the handler restores from the copy.

### The write bank

Watford and Solidisk boards choose the bank a *store* reaches with a register of their own
(`hw.inc`: Watford a store to `WRSEL_WATFORD + bank`, $FF30; Solidisk the user VIA's port B
bits 0-3, `WRSEL_SOLIDISK` $FE60 after `UVIA_DDRB = SOLIDISK_BITS`) and read through ROMSEL
like everyone else.  The rule (`cpu.inc`): the write bank is bank 7's, always, except in a
*window* -- a store into another bank between a `wrsel` to it and a `wrback` that puts 7's
back.  The windows are the sprite row loop (`ds_entry` to `ds_done`), `draw_rect` (to
`@done`), `map_put`, `selbb` and `boot`.  Nothing else moves it: a switch that only reads
leaves it be, and the interrupt stores into no bank (what it keeps is in zero page, low RAM
or `MRAMBSS`), so an interrupt inside a window finds the window's bank and leaves it.

The macros: `wrsel n, b` after a switch to the constant bank `n` from code in bank `b`'s
image; `wrselx b` where the bank is in A and X; `wrback b` at a window's end.  Each is
assembled as a second `sta ROMSEL` (harmless: A holds the bank) -- `wrback`'s as `sta
WRSEL_WATFORD`, a store into the MOS ROM on a plain machine, so that it does not page bank 7
in under whatever runs there -- and recorded in the `WRFIX` segment (`WRREC`: bank, address,
kind 4..7 or `WR_INX`).  On the Master the macros are empty.  The boot loader rewrites each
site by board (`loader.s @wfix`): Watford `sta $FF3n` or `sta $FF30,x` (`OP_STA_ABSX`),
Solidisk `sta $FE60`.  `build.sh` asserts every entry sits on a `sta $FE30` (or `sta $FF30`)
and has a legal kind.  As built today the Model B has 13 write-bank stores, the Master 0
(the build's `BANKS:` line).

### Bank numbers and sockets

Every byte of code that holds a bank number is recorded: `bankimm op, n, b` emits `op #n`
and a `BANKREF` into the `BANKFIX` segment (bank `b`'s image, the address); `setbank n, b`
is `bankimm lda` plus the two stores.  The site is marked with a cheap label `@bf_<name>`
because any other kind of symbol would end the enclosing routine's `@` scope, so two sites
in one routine need different tags (a clash is a duplicate-symbol error, not a silent
miss).  `build.sh` appends `bankfix.bin` and `wrfix.bin` to BANKS after the pieces, checking
each entry lands on a byte whose low nibble is 4..7.  Bank 7's images come off the disc
later, so their entries go to `img7fix.inc` instead and `ldprog.s image_load` applies them
after each read; the menus' image may carry none (`build.sh` asserts on the `@bf_`/`@wr_`
site labels: use `ldpbank`).  Code the loader cannot patch -- the load-time program, the
menus' image -- reads the physical bank from `PBANK` (`ldpbank op, n` = `op PBANK + (n-4)`).

### The boot loader's RAM probe

`loader.s find_ram`: for each of the 16 sockets, page it (through `$F4` and `ROMSEL`), flip
bit 0 of the ROM type byte at `$8006`, see whether it stuck, put it back.  The test is run
three ways -- writing through ROMSEL alone, the Watford way, the Solidisk way -- and the board
is the way that finds the most banks, plain winning a tie.  Each writable socket is then
classed: 0 RAM with no ROM image, 1 RAM with an image the MOS is not running (no entry in
its table at `MOS_ROMTAB` $02A1), 2 RAM holding a ROM the MOS recognised, taken only when
nothing else is left.  Two socket numbers reaching one RAM are found by a signature written
to each (`SIG_TAG | socket` at the copyright offset) and read back, and the extras dropped.
The four banks are the lowest-numbered of the best class; fewer than four prints a message
naming the game, how writes were tried and what was found (`no_ram`), and returns to the
MOS.  Machine: OSBYTE 0 (X >= `MOS_MASTER` = 3 is a Master, which picks `BANKSM`).  Drive:
OSGBPB 6.  Controller: the DFS ROM's version string (a title starting "DFS" with version
'2' is a 1770; else 8271), or W / I held at boot.  BANKS is loaded whole with OSFILE to
`BANKSBUF` $2000 (asserted to end below `BOOTRAM`) and the pieces copied out with
interrupts off from there on.


## 5. The display

### Units and the window

The window is `WINPX = 160` game pixels wide (80 chars) and `VISLINES = VISROWS*8` scanlines
tall (168 = 84 game pixels on the Model B, 240 = 120 on the Master).  Horizontal scroll is
by character (2 game pixels), vertical by two scanlines (one game pixel) through the
rupture.  `render_frame` derives from the game's `wx, wy` (map game pixels): `wcx = wx >> 1`,
`wcy = wy >> 2` (a full 16-bit shift: tall maps pass wy = 512), `wfine = (wy & 3) * 2`
(`frame.s`).  `calc_ring` (`kernel.s`) then gives the window's place in its ring: `ring_s =
((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS`, `barq = ring_s / 80` (the slot), and on the
Model B `wcxm = ring_s mod 80` and `mrow`, the map row shown by the window row in the last
slot.  Each buffer holds `BUFROWS = VISROWS + 1` rows: the visible ones and the bottom
partial's.

### The ring

```
   slot 0  +------------------------------+  <- RING0 / RINGBASE
           |                              |
           :                              :
   slot q  |###### window row 0 ##########|  <- ring_s = q*80 + wcxm (char granular)
           |##############################|
           :   BUFROWS rows held          :
           |##############################|
           |###### bottom partial's row ##|
           |                              |
  last     |......... Model B: straddles  |  <- the row that wraps: read from the
  slot     +------------------------------+     mirror below the base (Model B)
           |  composed row (Master): the  |     or folded by the CRTC (Master)
           :  ring row above the window   :
```

Each buffer is a ring of `RINGROWS` 80-char rows and the window slides round it: a row
that would fall off the end comes back at the start.  On the Master the ring is the whole
20K the CRTC wraps ($3000-$7FFF), so the hardware fold is the ring wrap; `RINGROWS` is 32
because that is the size of the region the hardware wraps, not a choice (`defs.s`).  On the
Model B the ring is 23 rows of main RAM and the fold is software: the *mirror*, a copy of
the ring's last slot row immediately below the ring base, so that the one displayed row
that straddles the end can be read by the CRTC as a single run (`mirror.s`).  Only the
chars that row takes from the mirror, `wcxm..79`, need to be right.  Its writers note the
range they wrote -- `draw_rect`'s head in line, the sprite prologue and `copy_partial`
through `mir_dirty` (`MIRDIRTY_BODY`, `macros.s`) -- into `MIRDTY MIRLO MIRHI` per buffer,
and `mirror_copy` (the frame's last step) copies that range.  It redoes the whole row when
`mrow` changed (the window crossed a slot boundary) or on a move left past the last copy's
`wcxm` (`MIRMR`, `MIRWCX`): chars left of the old `wcxm` were the row above's then and were
never noted.

### The composed row

With `wfine` non-zero the top of the window is the bottom `8 - wfine` lines of ring row
`wcy`, so the chain shows an extra one-row section (A) whose source is a row *composed* each
frame: `copy_partial` (`frame.s`) copies lines `wfine..7` of row `wcy` to lines
`0..7-wfine` of the ring row above the window, all 80 columns, every frame the fine scroll
is on.  That row is the one ring row the window does not hold: ring chars `[ring_s - 80,
ring_s)`, window aligned rather than slot aligned, so its copy may fold at the ring's end
mid-run.  This is why `VISROWS` is 30 on the Master: 31 held plus the composed row fill the
32-row ring exactly (`defs.s`).

### The sections

The frame is a rupture: several CRTC frames ("sections") in one 312-line field,
reprogrammed from a chain of VIA T1 interrupts and re-phased at every vsync (`kernel.s`).
Top to bottom:

```
   +-----------------------------+
   | T   the bar       2 rows    |  BARROWS, fixed home (BARADDR)
   +-----------------------------+
   | A   composed row  8-f lines |  only when wfine = f > 0
   +-----------------------------+
   | P   playfield     VISROWS   |  from the window's slot; Model B: split into
   |     rows                    |  P1 (to the ring end) and M (from the mirror)
   +-----------------------------+
   | P2  bottom        f lines   |  only when f > 0
   +-----------------------------+
   | Q   blanking      QROWS     |  display off; the vsync on row QVSYNC; starts
   |     rows                    |  at QBLANK
   +-----------------------------+
```

`FRAMEROWS = 39` char rows; `QROWS = 39 - VISROWS - BARROWS`: 16 on the Model B (vsync at
row `QVSYNC = 8`), 7 on the Master (`QVSYNC = 3`).  The bar is scanned `(QROWS - QVSYNC) * 8`
lines after the vsync -- 64 on the Model B, 32 on the Master -- which is the time the game
has to draw it (section 6).

`build_sections` (`kernel.s`) fills the buffer's chain, `NSECT = 6` entries of `SECENT = 8`
bytes in `SECTAB` (buffer 1's at `SECBYTES = 48`):

| offset | field | meaning |
|--------|-------|---------|
| +0, +1 | `SE_R12`, `SE_R13` | the *next* section's start address (high byte first) |
| +2     | `SE_R4` | this section's rows - 1 |
| +3     | `SE_R9` | its scanlines a row - 1 |
| +4     | `SE_R6` | rows displayed (more than it has: display on; 0: off) |
| +5     | `SE_R7` | the vsync row: `R7_NEVER` (30) everywhere but Q, whose is `QVSYNC` |
| +6, +7 | `SE_T1L`, `SE_T1H` | the *next* section's duration as a T1 latch value: lines x `LINE` (64) - `T1_RELOAD` (2) |

The shape is section i's and the address and duration are section i+1's because R12/R13
latch at the next restart and the T1 latch takes effect one interrupt later.  Section 0
(T) takes its address and length from `BUF_SEC0`/`BUF_SEC0T1`, which the vsync programs
from the buffer about to be shown.  The chain stops at Q: the step's walk `sec_idx` on only
while R7 is `R7_NEVER`, so a late vsync cannot run it off the table.

Q's start is a black line whatever the fine scroll, because a 6845 shows a frame's first
scanline whatever R6 says: as the next map row it would be junk or a repeat of P2's first
line.  The Master's `QBLANK` is 640 zeros below the bar in main RAM, written by `boot`; Q's
step puts ACCCON D back to 0 before it (under $3000, D = 1 would read HAZEL/ANDY).  The
Model B has no spare black line, so Q starts at the bar's 45th char (`QBLANK = BARADDR +
45*8`) and Q's step blacks the palette for it -- 12 writes (`killpal`), yellow and magenta
then cyan, in the order `defs.s` says the colours first appear on that line -- and the vsync
puts the colours back unless `palon` is clear (`blank_palette` clears it, `set_palette`
sets it).  Behind a two-line P2 (f = 2) there is no time for Q's own step, so P2's step does
the kill at its end (`@kend`, `KENDWAIT`) and writes Q's shape itself; `build_sections`
records which entry is responsible in `BUF_QS` (-> `qsect`) and, on the Model B, `BUF_KS`
(-> `ksect`), `SECT_NONE` for neither.

The menus use the same chain with section 0 moved off the bar: `menu_sections` points it at
two black ring rows below the window (`MENUBAR`; `VISROWS + BARROWS <= RINGROWS` asserted),
so the bar is neither shown nor touched while the menus run.

### The step

The interrupt (`isr_body` on the Model B, `irq_handler` on the Master; `kernel.s`) tests
`VIA_IFR` for T1.  A step reprograms the next section from `SECTAB[sec_idx]`.  Deadlines
(`kernel.s`'s notes, measured with Cleo's `test/crtctime.mjs`): R9 and R4 together decide
where the section ends, latched at the start of the scanline where row = R4 and line = R9,
so for a 2-line section both must be in place before scanline 1 -- 128 cycles after the
restart -- and R6 is compared from scanline 1 on.  So the order is **R9, R4, R6, R7**, then
the T1 latch and `sec_idx`, then **R12/R13 last** so they land on scanline 1.  Written
straight after R7 they fell across the end of scanline 0, and on a partial (R4 = 0 written
on its last row) some 6845s -- the VL6845, Tom Seddon's "r4-3" -- end the frame at once and
reload the start address as that scanline ends: a Master with such a chip lost the R12
write and showed a 16-char tear whenever the fine scroll was not 0.

The chain is phased so a step fires about 50 cycles before its restart (`VS2T`).  On the
Master the step after the bar's (`dsect`) switches ACCCON D to the displayed buffer's and
then holds (`DHOLD` = 5 loops of dey) so its first CRTC write follows the restart; D is the
memory map, sampled by every fetch, so it must be in place before the boundary, and the
bar's T1 fires `BARLEAD` early for it.  Every other Master step fires later instead, by
`STEPLATE` (the bar's by `BARLATE`), and spends nothing waiting.  Q's step fires `QLEAD`
early; behind a 2-line P2 that P2's step fires `P2EARLY` early.  The constants (`kernel.s`):
Model B `BARLEAD = BARLATE = STEPLATE = P2EARLY = 0`, `QLEAD = 40`, `KENDWAIT = 4`; Master
`BARLATE = 13`, `STEPLATE = 20`, `BARLEAD = 23`, `QLEAD = 6`, `P2EARLY = 12`, `DHOLD = 5`.
`STUBLAT` is the Model B's stub cost (`18 - 22 - 4 + 2`) or the Master's `-BARLATE`, and
`VS2T = (QROWS-QVSYNC)*CHARLINES*LINE - 2*LINE - 35 - 36 - STUBLAT - 8 + 2` is the T1 count
from the vsync to the bar's step; the comment at `VS2T` accounts for each term.

### The vsync

The other interrupt source is CA1.  The vsync handler, in order: restart T1 with `VS2T`
first (constant latency), clear CA1, handle `load_req` (below), T1's interrupt on, **re-phase**
-- R9 = 7, the bar's R6 pre-armed now in Q where a new R6 cannot show, R4 = `cur_r7 + QROWS -
1 - QVSYNC` so that T starts exactly `QROWS - QVSYNC` rows after the vsync even if the row
counter had run past its total -- then `inc vsyncs`, the **flip** if `flip_req` is set and
`FLIPWAIT` (2) vsyncs have passed since the last (`flipvs`): `disp_sect = next_sect`,
(Master) `disp_d = next_buf`, `flip_req = 0`; then section 0 from the displayed buffer's
`BUF_SEC0`/`BUF_SEC0T1`, `sec_idx` set to its entry, (Master) `dsect` and `qsect` set and D
cleared for the bar, (Model B) `qsect`/`ksect` set and the palette restored if `palon`;
then `scan_keys` and the sound (section 10).  The `FLIPWAIT` of two means a flip at most
every other vsync, 25 Hz.

### Double buffering

Model B: two rings, `RING_A` and `RING_B`; `select_backbuf` (bank 6) sets `ringbhi`,
`ringehi`, `ringe3` for the blitters' folds and patches `draw_rect`'s ring high-byte table
operand (`RINGHIOP`) to the buffer's.  Master: one address range in main and shadow RAM;
`select_backbuf` sets ACCCON X (the CPU's view, `tsb`/`trb` so it cannot straddle the
interrupt's D writes) and the chain's D switch picks the displayed one.  `crtcb` is the
buffer's CRTC base; on the Model B `crtcbm` is the same less the ring, the mirror redirect
`@addr` uses for a straddling row.

### Load mode

A disc load runs with interrupts off.  Stopped mid-chain the CRTC would repeat a few lines
for ever and monitors lose sync, so `load_begin` asks the chain to stop at a frame
boundary: `load_req = LDR_STOP` (1); the next *bar step* (`@ldsw`, the frame boundary
however long the vsync's work ran) programs a standard 39-row frame -- `LDR4 = 38`, the
vsync on `LDR7 = BARROWS + VISROWS + QVSYNC` (31 on the Model B, 35 on the Master: the MOS's
own row) -- turns T1's interrupt off and sets `LDR_STOPPED` (2).  While stopped the vsync
only counts and keeps keys and sound alive.  The load's end sets `LDR_RESUME` (3) and clears
stale T1/CA1 flags (`ldprog.s ld_resume`); the next vsync re-arms T1 and re-phases from
`cur_r7 = LDR7`, which with `QROWS - 1 - QVSYNC` is the standard frame's own total, and the
bar step at that frame's end takes the display back.  `crtc_init` (`boot.s`) starts the
machine in this same frame, R0..R13 in order so R12/R13 are written last, R8 = 0 (no
interlace sync: the MOS's MODE 1 leaves it on, which puts every other field's vsync half a
line later), R10 = cursor off.


## 6. The frame

`render_frame` (`frame.s`) is the game's one call a rendered frame.  In order:

1. `wait_flip` -- inline, its one caller: spin while `flip_req` is set.  The previous frame's
   flip must land before this buffer is touched; it does not wait for the flip it will ask
   for, so the next logic step runs while that is pending.
2. The bar first: if `bar_dirty`, `jsr hook_hud` (the game's) and clear it.  The bar is
   single buffered and drawn where it is displayed, inside the `QROWS - QVSYNC` rows between
   the vsync just returned from and its first scanned line (section 5).  The template comes
   with the game's image (the BAR file) and nothing erases it.
3. Derive `wcx`, `wfine`, `wcy` from `wx`, `wy`.
4. `selbb` -> `select_backbuf` (bank 6): the back buffer's constants, `clip_mask` and the
   `krlo..kchi2` bounds (below), the record base `recp`/`recb`.
5. `calc_ring`: `ring_s`, `barq` (Model B: `wcxm`, `mrow`).
6. `match_sprites`: `KEEP[i]` for every listed sprite (below).
7. `erase_old`: redraw the tiles under this buffer's old records that are not kept -- each
   rectangle to bank 6's `draw_rect_clip` through `call_bank`.
8. `validate` -> `scroll_validate` (bank 6): draw the strips the window has moved onto.
9. `draw_dirty`: the tiles the game changed, queued by `mark_dirty`.
10. `draw_sprites`: the list, in two passes (below).
11. `copy_partial`: the composed row (section 5).
12. (Model B) `mirror_copy`.
13. `nspr = 0`; `build_sections` for this buffer.
14. Hand over: `next_sect` = this buffer's chain (0 or `SECBYTES`), (Master) `next_buf`,
    `flip_req = 1`; `render_done` (a label the harness measures to); `cur_buf ^= 1`.

There is no `render_core` routine: the list above is inlined in `render_frame`.

### The records and the keep rule

Each buffer keeps a record of every sprite it drew: `SPRREC` in `ENGBSS`, `MAXREC = MAXSPR`
records a buffer, `RECSZ` bytes each (`engine/defs.s`):

| offset | field | contents |
|--------|-------|----------|
| 0 | id | the sprite id |
| 1-2 | x | map game pixels |
| 3-4 | y | |
| 5-6 | `REC_CX` | the rectangle drawn: map char column |
| 7 | `REC_CY` | char row |
| 8 | `REC_W` | width in chars (0: nothing drawn) |
| 9 | `REC_H` | height in char rows, bit 7 (`REC_CLIP`) set when cut at a window edge |

With `TIGHTBSS` the records are 9 bytes stored as arrays (one byte of each field per
record, buffer 0's then buffer 1's), the column's two high bits packed into `REC_H` bits
5-6.  `RECCNT` (2) is each buffer's count; `KEEP` (`MAXREC`) the verdicts; `DIRTYCNT` (2)
and `DIRTYLIST` (2 x 2 x `DIRTYMAX`) the dirty tiles; `SPRLIST` the draw list as five arrays
`SPR_ID SPR_XL SPR_XH SPR_YL SPR_YH` of `MAXSPR` (`vars.s`).  `MAXSPR` is the build's
`-D MAXSPR`, else the game's `MAXSPRDEF` (`assets.inc`), else 28.

`match_sprites` compares sprite i with record i: `KEEP_SAME` (2) for the same id in the
same place -- its screen pixels are already right, so no erase and (for a still box) no
draw -- and `KEEP_BOX` (1) for a box where a box was (two box frames at one place overwrite
each other exactly, so a frame change needs no erase).  Once the window has moved since the
buffer last drew (`clip_mask` = `REC_CLIP`, set by `select_backbuf`), a record is kept only
if it was not cut at the window's edge *and* lies in the rows and columns the old window
and the new both hold (`krlo..krhi2-2`, `kclo..kchi2-2`, relative to the new window: the
rest of the buffer is this frame's strips, or ring slots reused while out of view).  An
invalid buffer (`BUF_CXH = BUF_INVALID`, $80: a level start or an overflowed dirty list) is
about to be redrawn whole, so it drops its records.

### Scrolling and dirty tiles

`scroll_validate` (`tiles.s`): `dx = wcx - BUF_CXL`, `dy = wcy - BUF_CY`.  |dx| < 80 draws
the new columns, all `BUFROWS` high; a small dy draws the new rows at full width; anything
bigger, or an invalid buffer, redraws the whole window.  Without `TALLMAP` rows are bytes,
and a strip whose first row would be 256 (the bottom of a 64 x 128-tile map) is dropped:
that row is never shown, and drawn it would land in row 0's slot.  `mark_dirty` (the
game's call, A = tile x, X = tile y) queues a tile in both buffers' lists; a list past
`DIRTYMAX` (20) marks that buffer invalid instead.  `draw_dirty` draws the back buffer's
list as 4 x 2-char rects through `draw_rect_clip`.

### draw_sprites

Two passes: `dpass = 1` draws only the boxes (ids >= `BOXID0`), then `dpass = 0` the rest.
A box is an opaque rectangle with its background baked in, so it has to go down before
anything that shares its space.  A *still alias* (id >= `BOXID0 + BOXN`: a box the logic says
nothing can disturb) kept `KEEP_SAME` and not clipped is skipped: nothing has been
repainted under it.  Each drawn sprite writes its record's id and position, marks it
clipped with nothing drawn, and calls `draw_sprite`, which fills in the rectangle when any
of it is in the window.  Its vertical clip stops at `row_lim` lines, which `render_frame`
sets each frame to `min(BUFROWS, 256 - wcy)` rows: without `TALLMAP` a sprite row past map
row 255 would wrap to row 0, whose Model B ring slot is a visible row's (a sprite falling
off a 64 x 128-tile map).  `add_sprite` (A = id, `spx`/`spy` the reference point) is the game's
call; a full list drops the sprite.  With `DRAWFLAGS`, bit 7 of `SPR_XH` is a mirror flag.


## 7. The tiles

### Ids and kinds

Within a level (`gather.s`, `convert.py`'s `pack_tiles` in Cleo lays them out):

| id | kind |
|----|------|
| 0 | the level's solid: a fill of one byte, `SOLIDF`, patched by the loader |
| 1 .. half0-1 | full tiles, contiguous from `TILES` in bank 6, slot id + `TOFF` |
| half0 .. | half tiles: one char row stored, the other a fill or the same row again (below) |
| `FLAT0` .. 253 | flat tiles: a two-byte pair alternating down every char, from `FLATTAB` |
| 254, 255 | the two solids, `FLATTAB`'s last two pairs (a level's other solid) |

A half tile's stored row is 32 bytes at the halves' page + k*32 (k from `HALFOFF`); its
other char row is a fill from the level's palette of 8 pairs (`HPAIR0`/`HPAIR1`) or the
same row again.  The halves come in three runs, `half0 half1 half2`: top row filled, bottom
row filled, both stored.  `vars.s` asserts `FLAT0 + NFLAT + 2 = 256`.  `NFLAT` and `FLAT0`
are the game's (`assets.inc`; Cleo's `NFLAT=n sh build.sh` knob).

### The gather

Once a tile row, `draw_rect` calls `map_strip` (low RAM), which pages bank 5 in, runs
`gather5` over the row's ids in place, and pages bank 6 back.  The result is a pair a tile
in low RAM, `GATHERL`/`GATHERH` (`GATHERN` = 21: a window's 20 tiles and the one more a run
starting mid-tile takes), read last tile first:

| `GATHERH` | `GATHERL` | kind |
|-----------|-----------|------|
| 0 | unread | the solid |
| `GH_FLAT` ($40) | the pair's index in `FLATTAB` | a flat (or the other solid) |
| bit 7 set (`GH_TILE`) | `(id & 3) << 6` | a full tile: the pair is its address |
| $06-$3F | the row's offset, fill row and colour (below) | a half: its page less $80 |

A half's `GATHERL`: bits 5-7 the stored row's offset in its page (`GL_ROWMASK`), bit 3 or 4
which char row is the fill (`GL_FILLTOP`, `GL_FILLBOT`; neither: both rows stored), bits
0-2 the fill's colour in the level's palette (`GL_COLMASK`).  A fill is flagged by bit 7 of
`GATHERH` clear (the row loop's `bpl`).  The Model B computes the pair from
the level's shape -- `half0`, `halfhi5`, `half_sub` in zero page and `HLOW` (64 bytes, bank
5) for the halves' low bits, all the loader's -- by sorting the id into its range; the
Master reads it from `LV_PAGE0` (256 low bytes then 256 high), which the packer wrote and the
loader copied to $0400.  The two agree byte for byte: `ldprog.s bake` decodes a tile as the
Model B's gather does on either machine.

### draw_rect

`draw_rect` (bank 6, `tiles.s`) draws `rc_w` chars by `rc_h` char rows of map from `(rc_x,
rc_y)` into the back buffer; `draw_rect_clip` (the bank's entry) clips the rect to the
window first.  Per rect, once: the first row's screen address (ring slot from `ringmod`,
`ringlo`/`ringhi` tables), `rc_tx0`, `rc_nt` (tiles - 1), the first run's limit `rc_sc0`
and char offset `rc_ro0`, the map row pointer (`map_row`), and on the Model B the write
window and the mirror's note.  Per tile row: one `map_strip`, then one or two char rows
(`@drawrow`), the second without re-gathering.  Per char row: runs -- a run is the chars of
one tile in this row, at most four -- dispatched by kind from `GATHERH` and entered into an
unrolled block by length.  The solid, the commonest run, is one byte stored down 8n lines
through a chain of 32 `sta (sp),y / iny` entered at the right store; a full tile is
`CHARCPY` blocks in descending char order; a fill (flat, half's fill row, the other solid)
is `PCHAR` blocks.  The Model B enters each group by a patched branch (`runn` leaves X = n
and C = 0; `@jto/@fto/@mto` hold the offsets; the blocks are asserted to follow the branch
in one page, so it costs a `jmp`'s 3 cycles), the Master by `jmp (abs,x)` with X = 2n
(`RUNXS`).  The invariants an editor must keep are listed at the head of `draw_rect`; the
central one: a run never crosses the ring end, because a ring is a whole number of 80-char
rows and the end therefore falls on a tile boundary, so the runs have no wrap test and only
`@advsp`'s page step (`pagestep`) folds.

The loader patches three operands in the row loop: `SOLIDF` (`@s0f`'s `lda #`, a cheap
label `build.sh` finds in `game.dbg` because any other symbol would end `draw_rect`'s `@`
scope), and `HPAIR0`/`HPAIR1` (the two indexed loads of the halves' fill palette, defined
after the row loop with `:=`).

### The tile set files

Cleo's packer cuts the tile set into three files, `TILES0` (outdoor), `TILES1` (shared),
`TILES2` (indoor); the loader's `ftab` numbers them 3, 4 and 24 (`tfi`), and a level's tile
list says which files it uses and which full tiles of each (`levelfile.Level.tiles`,
section 9).  Sizes as built today: 14,272 / 3,904 / 6,720 bytes (`ls -l build/TILES*`).


## 8. The sprites

### The 4-bit format

A stored column is one byte a game-pixel row: two game pixels, 4 bits each, of one palette
the game chooses, nibble 0 transparent (`sprloops.s`).  Three 256-byte tables, the game's
`nibtab.bin`, turn a byte b into screen bytes: `L0TAB[b]` and `L1TAB[b]` the row's two
scanlines, `NMASK[b]` the AND mask for its transparent pixels ($00 both opaque, $CC or $33
one).  A byte of 0 draws nothing; otherwise `screen = (screen AND NMASK[b]) OR Ln[b]`.
Mirrored, every result and the mask go through `SWAPTAB` (the four-dot reversal).  Rows are
stored one in two scanlines and a sprite's first line in a char is always even (`lb0 = 2*sy +
wfine`), so a cell's lines go in pairs.  A *box* (flag `SPF_COPY`, bit 3) is its screen
bytes, every scanline (`SPF_FULLRES`, bit 2), copied straight: a box's backdrop keeps any
dither exactly.  `SPF_MIRROR` is bit 0.

### The directory

Split in two.  The level's part, `DIR_TABLE` in `ENGBSS` (`banks.s`): `DIRL` then `DIRH`,
`BOXID0 + BOXN` bytes each, the image's address by id -- 0 not in this level, bit 7 of the
high byte clear for bank 5 (every image is at $8000-$BFFF so bit 7 is otherwise always set;
`levelfile.directory()` writes it and asserts a bank 5 image is never at $80xx).  The
game's part is the geometry by shape, `sprg_ix` by id then `sprg_w sprg_rx sprg_ry sprg_ln`
and (with `SPRGFL` in `assets.inc`) `sprg_fl` by shape -- Cleo's `sprgeom.inc`, written by
its packer, included by its `gamedata.s`.  Ids from `BOXID0` are boxes; from `BOXID0 +
BOXN` *still aliases* that draw the box `BOXN` below (`draw_sprite`'s first compare).

`DIRSPLIT` splits the level's part again: the ids below the game's `RES_N` are resident
(placed alike in every level), and their `RES_N` low and `RES_N` high bytes are the game's,
at `RESDIR` in sprite bank `RESDIR_BANK`, inside `SPRC` (loaded once).  `DIR_TABLE` keeps
`2*(BOXID0+BOXN-RES_N)` bytes, and `DIRL`/`DIRH` are its two tables less `RES_N`, so an id
indexes them as before; the level file's `dir` section is the same ids'.  The prologue
sends an id below `RES_N` to low RAM's `dir_res` (`lowram.s`), which pages `RESDIR_BANK` in
(with `ROMSEL_CPY`), reads the entry, pages bank 7 back and jumps to the prologue's
`ds_dirback` with the address and bank set (or returns for an entry of none): 28 cycles
more a resident sprite, 5 a level one.  The game's own readers of the directory (Commando's
`glyph`, in HAZEL) page the bank themselves.

### draw_sprite

The prologue in bank 7 (`frame.s`): the address and bank from `DIRH/DIRL` (0: return), the
shape's flags, width and lines; horizontal clip to `sp_c0..sp_c1` with `sp_c` the first
image column; vertical clip from `lb0` to char rows `sp_r0..sp_r1` and lines `sp_ra0`,
`sp_ra1`; the record's rectangle; (Model B) the mirror's columns; the blitter chosen once
(`sp_disp` = `SPRDISP_FN`, `_FM` or `_FC`: its first entry in `sprrow_tab`); the screen
base from `ring_addr7` and the source row pointer; then `call_bank` to the row loop in the
data's bank.  `sp_clip` counts the window edges it was cut against.

### The row loop

`NIB_LOOPS bank` (`sprloops.s`) emits, for each sprite bank: `ds_entry` (at `BANKENTRY`,
opens the write window), `spr_fn`'s cells first so they sit in the bank's first page, the
column step `spr_retp` (ptr + `sp_lines`) which `spr_fn` falls into, the column loop
`ds_colloop` whose `jmp` operand is **patched once a row** with the entry for that row's
lines (`sprrow_tab[sp_disp + 2 * (first line, or SPRTAB_N-1 for the partial loop)]`), the row
step `ds_rowdone` (source + `sp_rinc`, screen + 640 folded by `ringup`), the mirrored step
`spr_retm`, then after `PAD PADB_FM, PADM_FM` the mirrored cells `spr_fm`, the two partial
loops, the copy blitter `spr_fc` and `sprrow_tab` (`SPRTAB_N` = 9 entries a blitter: a cell
from each first line, and the partial loop).

### Placement

`tools/sprpack.py` places a bank's images: the cost is the column pointer's page crossings
over the eight line phases (`CARRY` 9 cycles, the mirrored walk's `BORROW` 7) plus the
`(zp),Y` reads that cross a page inside an image (`READ` 3.5 a boundary), weighted by draws
a frame; a deterministic search over order and padding, cached in `build/sprpack.cache`.
The weights are the game's (Cleo's `tools/drawfreq.json`, from its `test/drawfreq.mjs`).

### Resident and staged; baking

`SPRC` is read once (`sprc_ok`) to `SPRC_BASE` in bank 4 (and `SPRC5_BASE` in bank 5 when
`SPRC5_LEN` is non-zero; 0 today) and stays; `SPRX` is staged every load (or refilled from
HAZEL/ANDY on the Master) and the level's placement list copies its items out
(`place_walk`): each entry item, bank, address, extra (`levelfile.placement`, `PL_*`),
`img_tab` (5 bytes an item: file, offset, length) saying where the item is in the stage.
An item from `BAKEITEM0` on is not copied but *baked* (`ldprog.s bake`): the level's own
tiles where the object stands, decoded as the gather does, with the game's overlay from SPRX
(a column's pixels then its mask) ANDed and ORed over them, column by column into the bank.
The object's tile rides in the entry's extra (`x | y << 8`); `bake_kind.bin` gives the
slot's kind and `bake_geom.bin` the kind's shape (`BG_WC BG_LINES BG_DX BG_DTY BG_OV BG_SKIP`,
`BG_LEN` = 8).  Nothing baked is on the disc.


## 9. The disc and the loader

### The files

Thirty files, in disc order (`build.sh` DISC; `files.inc` gives each one's `F_<name>_SEC` and
`_N`): `!BOOT LOADER BANKSB BANKSM IMG7M LDPROGM LDPROGB IMG7B BAR SPRX SPRC TILES0 TILES1
L0..L15 TILES2`.  A game's start reads LDPROG, IMG7 and BAR in turn, so they are neighbours:
the Model B's in that order, the Master's around them.  `mkdfs.py` lays files out from
sector 2 (a DFS catalogue holds 31).  `!BOOT` is `*RUN LOADER`; LOADER runs at $1900
(`loader.cfg`).  As built today the last file ends at sector 681 + 27 = 708 of 800.

### The driver slot

The MOS is gone once the game runs, so the game has its own driver (`disc.s`): the Model B's
8271 or Acorn 1770, the Master's 1770.  Both are assembled for the same place at the top of
the kernel (`DRV8271`/`DRV1770`, asserted equal) and BANKS carries both, each piece flagged
by controller (`PIECE_8271` bit 7, `PIECE_1770` bit 6); the boot loader copies in only the
machine's, so the kernel pays for the larger, not both.  A driver: +0 `jmp` to its track
read (`DRV_TRACK`: `ld_cnt` sectors of track `ld_trk` from sector `ld_sc` to `ld_dst`, C = 1
to try again), +3 its NMI stub's length, +4 the stub, which `ld_go` copies to `NMIPAGE`
($0D00: the NMI lands there, so the stub starts there).  The page's last three bytes are the
stub's state: `LD_RES`, `LD_DONE`, `LD_SECS`.  Neither driver may hold a bank patch
(`build.sh piece_bytes`).  The 8271's read: load the head through the drive control
special register (the 8271 latches "not ready" and only a read-drive-status clears it, so
one is sent first), then read data; the 1770's: seek if the head is elsewhere, read
multiple with the stub counting sectors and forcing an interrupt at the last.
`read_sectors` divides `ld_sec` by `SECTRK` (10) and reads a track's run at a time.

### The loads

Every load is the load-time program's: the kernel's `ld_go` stops the tune, `load_begin`
(section 5), `sei`, copies the NMI stub down, reads LDPROG to $0E00 and jumps to it.
`load_level_b` (X = level 0..15) returns to its caller; `go_title` (`LDOP_TITLE`), `go_game`
(`LDOP_GAME`) and `go_menu` (`LDOP_OVER`, A = 0 lost / 1 won) go on to the game's hook with
the stack reset (`ldprog.s ld_image`): `hook_title`, or `hook_image` then `game_in` ->
`hook_play`, or `hook_over`.  `ld_open` is set after the game's image load so the level
loop's first `load_level_b` goes straight on without re-parking (the chain is parked and
LDPROG in place); `ld_resume` clears it at every load's end.  `ld_img` records which image
is in (the harness reads it).

### A level load, step by step (`ldprog.s lv_load`)

1. (Master) `main_ram`: ACCCON X and Y clear.
2. Read the level file to `STAGE_LVL` (the Model B stops short of its last `LV_PAGE0_SECS`).
3. The sections, by the file's own offset table: `hdr` (and the game's tail) to `LV_HDR`;
   `objs` to `LV_OBJS`; `attr` to `LV_ATTR0`, `altcls` to `LV_ALTCLS`.
4. The shape: `map_shr` from the header, `map_stride = 1 << lw`.
5. The map, run-length coded, unpacked into bank 5 at `MAP5` -- exactly its `1 << (lw+lh)`
   bytes (`unrle`).
6. The tiles: each file of the set the level uses is staged in turn; its full tiles go to
   consecutive slots from `TILES + (TOFF+1)*64`, its half tiles' rows to the halves' page at
   `HALFOFF` slots of 32; then the halves' fill palette (`HPAIR_LEN` = 16) where the halves
   end, and on the Model B each half's low bits to `HLOW`.
7. The shape into the blitters: `SOLIDF`, `HPAIR0`, `HPAIR1` patched in bank 6; on the Model
   B `half0`, `halfhi5` (the page less `GH_TILE`), `half_sub` in zero page.
8. The sprites: SPRC once; SPRX staged (or kept); `place_walk` over the placement list,
   baking the items from `BAKEITEM0`.
9. The directory's level part to `DIR_TABLE` (`DIRSPLIT`: the ids from `RES_N`, the
   rest came with SPRC); `FLATTAB` to bank 6.
10. (Master) `LV_PAGE0` to $0400, and both screens cleared of what the load staged there.
11. `ld_resume`: `ld_open = 0`, `load_req = LDR_RESUME`, stale flags cleared, `cli`.

An image load (`image_load`): stage the image file, copy it to `GAME_ADDR`/`MENU_ADDR`,
apply its bank-number and write-bank lists (`img7fix.inc`), and for the game's image zero
`GAME_BSS` to its exact end and read BAR straight to `BARADDR`.

### The level file format

`tools/levelfile.py` is the one definition: `python3 levelfile.py inc` writes `levelfmt.inc`,
which `defs.inc` and `ldprog.s` include, so writer and reader cannot drift.  A file is a
table of 13 two-byte section offsets then the sections in order (`SECTIONS`): `hdr objs
attr altcls tiles place map flat halves hpair mir dir page0`.  The header is `HDR_LEN` = 32
bytes: `HDR_LW`, `HDR_LH` (log2 of the map in tiles), `HDR_NOBJ` at 6, the tile set's
`Shape` at `HDR_SHAPE` = 20 (`ntiles map_shr nhalf half0 half1 half2 halfpage halfoff mir0
nmir solidfill`), and the game's own fields at 2..5 and 7..19 (`HDR_GAME`; the writer
rejects a game field anywhere else).  A *header tail* of the game's bytes may follow the 32
(the whole section stays under a page): the loader copies the section whole, so the tail
lands at `LV_HDR + HDR_LEN`, where the game keeps memory for it (Cleo's `RNGTAB` in
`GAMELVL`).  Objects are `OBJ_BYTES` = 6 each, `OBJ_MAX` = 149.  The map's RLE: a control
byte c < 128 means c+1 literals follow, c >= 128 the next byte c-126 times.  A placement
entry is `PLACE_LEN` = 6 bytes (item, bank, address, extra) ending in `PL_END` ($FF).
Section `mir` is `MIRTAB` under `TILEMIRROR` (`nmir` bytes: for each mirrored id, `mir0 + i`,
the id of the full tile it draws reversed; `mir0 = half0 + nhalf`), else empty.  `page0` is `PAGE0_LEN` =
512 bytes, sector aligned and last, so the Model B's loader reads the file short of it.
Limits: without `page0` a file must fit the Model B's stage (`STAGE_LVL_B`, 8K) unless
`MASTERONLY`, and whole the Master's (`STAGE_M`, 20K).  `levelfile.py check <assets.inc>
<level>...` verifies every invariant the loader relies on; `build.sh` runs it on all 16.


## 10. Sound

Both players write the SN76489 through the system VIA's slow bus (`snd_write`: port A out,
the sound write-enable latch low for 8 nops, port A back to the keyboard's shape; it keeps
X, Y and the carry).

### Effects

The game sets `sfx_req` (zero page) to a 1-based index; the vsync's `sound_tick` starts it
from `sfx_tab` (the game's table of word pointers; `sfx_tab-2,x` with X = 2 x index).  An
effect is steps of `SFXSTEP_LEN` = 4 bytes -- three bytes written to the chip, then the
frames to hold them -- ending in `SFX_END` ($FF), which written to the chip is the noise
channel's silence (asserted); the end also silences channel 2.  On the noise channel (3) the
second byte, a data byte, replaces the noise control (`hw.inc`: bit 2 `SN_WHITE`, bits 0-1
the rate) just as the latch's low bits set it, so an effect there repeats the control in it.  `sfx_ptr`, `sfx_dur` are the
player's state; `sfx_ptr+1 = 0` means none playing.  `sound_tick` is a step of the vsync
handler on both machines (inlined; the effects themselves sit with it under `PLACEH`).  With
`GAMESOUND` the vsync calls the game's `hook_sound` instead.

### The tune

The game's `music_addr` (in its menus' image) is a period table of `MUS_NNOTES` = 72 x 2
bytes for MIDI notes `MUS_NOTE0` = 24 .. 95, then 4-byte records: frames, a note a voice
(0 a rest), frames = 0 looping to the top (`engine/menus.s`; `tools/midi2snd.py` writes it,
voices chosen by "CHANNELS:RANK" triples, Cleo's default `1:max/0:min/0:min2`).  The player
`music_tick` lives in `MUSCODE`, first in the menus' image, beside its data: it runs only
while that image is in bank 7.  `music_start` sets `mus_on`; the vsync copies `mus_on` to
`mus_tick`; the interrupt's tail steps the tune when `mus_tick` is set, with bank 7 paged
(the Model B's stub `irq_vret`, the Master's handler through `page_logic`).  `music_stop` is
in the kernel because the kernel stops it: every load calls it (`ld_go`) and the menus'
image may be gone.  `mus_vol` is 3, 8, 8 (melody louder).


## 11. The build

`tools/build.sh` is run from the game's directory by the game's own `build.sh`, which
exports `GAME_MAIN` (the root source, which includes the engine's), `GAME_SRC`, `GAME_ASSETS`
(run once per machine with `TARGET` and `BD` set), `GAME_MUSIC` (once, first), `DISC_TITLE`,
`DISC_OUT`, `GAME_NAME`.  Cleo's is nineteen lines (`beeb/build.sh`).  Options, each a `-D`
flag (`cpu.inc` defaults them to 0; the header of `build.sh` says what each does):
`MASTERONLY GAMEHAZEL GAMESOUND DRAWFLAGS TALLMAP TIGHTBSS DIRSPLIT TILEMIRROR ALLLEVELS`, and
`MAXSPR=n`.
`GAMEHAZEL` needs `MASTERONLY`; `TALLMAP` on the Model B needs `RINGARITH` (`cpu.inc` errors).
`SKIP_ASSETS=1` skips the music and asset steps.

The passes, in order:

1. The tune (`GAME_MUSIC`).
2. Per machine: the assets (`GAME_ASSETS`); `game.cfg` from `banks.cfg` with the build dir
   substituted, `B4X/B5X/B6X` sized from `assets.inc`, `ENGBSS`'s align dropped under
   `TIGHTBSS`; `levelfmt.inc`.
3. The shared files compared across machines (`cmp`), `levelfile.py check` on every level.
4. The disc list; `!BOOT`.
5. Three passes until the sector table settles: `mkdfs.py table` -> `files.inc` (copied to
   the Master); per machine `ca65` of the game, bank 7's sizes from `od65`, the Master's cfg
   pinned, `ld65` with `-Ln labels.txt --dbgfile game.dbg`; `defs_ld.inc` from `labels.txt`
   and `game.dbg` (the `want` list, `SOLIDF`, the hooks, the images' addresses and lengths,
   `GAME_BSS*`); `IMG7`; `img7fix.inc`; `ldconst.s` assembled for its printed constants;
   LDPROG; BANKS with its asserts and printed line; then the header equality check,
   `gamename.inc`, LOADER.
6. `mkdfs.py build` -> the disc; `assets.inc` compared; `layoutcheck.py`; `ls -l`.

What stops a build: a shared file differing between machines; a level file failing
`check`; `files.inc` not settling; a bank patch outside the pieces or on a non-bank byte; a
write-bank entry not on `sta $FE30`; a patch site in the menus' image; the game image's
variables running into its code; BANKS running into BOOTRAM; the header addresses differing
between machines; `assets.inc` differing; any layout difference; and every `.assert` in the
sources (the bank code ends, `BANKENTRY`, the stub sizes, the page-sharing of dispatch
groups, ...).  The build prints `BANKS: n pieces, n bytes, n bank patches, n write-bank
stores` per machine -- today 9 pieces / 16 / 13 for the Model B and 10 / 8 / 0 for the Master
-- and `layout: the data sits alike on both machines`.

Generated includes: `levelfmt.inc` (the format), `defs_ld.inc` (addresses for the loaders
and tests), `img7fix.inc` (the images' patch lists), `files.inc` (sectors), `gamename.inc`
(the loader's message).  Requirements: cc65's `ca65 ld65 od65`, Python 3; the tests need
Node and jsbeeb in the npx cache (`harness.mjs findJsbeeb`).


## 12. Testing, the 6502 spellings and the ca65 traps

### The harness

`test/lib/harness.mjs` drives a game under jsbeeb frame-exactly.  The contract: every wait
is "run to the next `frame_top`", a label the game places at the one point reached exactly
once a rendered frame, before its logic reads `keys` (Cleo's `game.s`); inputs are written
while stopped there, so nothing in the protocol can observe a cycle count.  Breaks are
bank- and image-aware: `loadBanks` reads `game.dbg` for each label's segment (`SEGBANK`,
`SEGIMG`), `at()` waits for that bank in `romsel_cpy` and that image in `ld_img`.
`fingerprint()` hashes every input to the renderer's cost (the window, the buffers' state,
the sprite list, the records, the dirty lists, and the game's `gameScene()`), so a cycle
comparison is valid only where fingerprints match.  `installMeter()` measures render work
from the instruction after `render_frame`'s inlined spin (found by disassembling `lda
flip_req / bne render_frame`) to `render_done`, the interrupt's time inside it separately,
and the logic from `frame_top` to `render_frame`.  `test/lib/boards.mjs boardEmu` emulates a
Watford or Solidisk board on a jsbeeb Model B and counts every store into a bank other than
the one paged for reading.

The engine's own unit test is `test/test_levelfile.py` (`python3 -m unittest discover -s
beebgame/test`, 11 tests): the writer against the reader, the RLE, the directory's split
and bank-5 flag, the header tail, the limits, and that `ldprog.s` names sections and header
fields only by the constants `levelfile.py` defines.  The game's behavioural gate is its
own: Cleo's `test/sweep.sh` runs 89 checks (16 levels x 5 window comparisons, the boards,
the menus, the load sync, the board stores) against a snapshot.

The tools: `tools/layoutcheck.py` and `tools/pincfg.py` (section 1), `tools/pagecheck.py`
(page-crossing branches), `tools/codecmp.py old.s new.s` (two sources' code compared with
comments and layout stripped: the check for a comment-only edit).

### The 6502 spellings

`cpu.inc` gives one source for both CPUs.  On the Master each macro is its one 65C02
instruction; on the Model B an expansion whose side effects are stated in each header and
audited at every site:

| macro | Master | Model B | note |
|-------|--------|---------|------|
| `stz m` | `stz` | `lda #0 / sta` | A dead at the site |
| `zero m,...` / `sta0 m,...` | `stz` each | one `lda #0` / `sta` each | `sta0`: A already 0 |
| `stzx m` | `stz` | `ldx #0 / stx` | X dead |
| `stz01 m` | `stz` | `dec m` | a 0/1 flag that is 1 |
| `inca` / `deca` | `inc a` / `dec a` | `clc / adc #1`, `sec / sbc #1` | the carry is destroyed |
| `incax` | `inc a` | `tax / inx / txa` | the carry survives |
| `ldaz zp` / `cmpz zp` | `lda (zp)` / `cmp (zp)` | `ldy #0 / lda (zp),y` | Y destroyed, 0 after |
| `ldaz0` / `staz0` | `lda (zp)` / `sta (zp)` | the `,y` form | Y already 0 |
| `ldazx zp` | `lda (zp)` | `ldx #0 / lda (zp,x)` | X dead |
| `ldy1` | `ldy #1` | `iny` | Y is 0 |
| `bitimm v` | `bit #v` | `sta mtmp / and #v / php / lda mtmp / plp` | through `mtmp`; not in the interrupt |
| `bra t` | the instruction | `jmp t` | |

Inside `.if .not BHW` the Master's code is written natively (`stz`, `inc a`, `lda (zp)`,
`tsb`, `trb`); the macros are for shared code.  The bank and board macros (`bankimm`,
`setbank`, `BANKREF`, `wrsel`, `wrselx`, `wrback`, `WRREC`, `ldpbank`, `PLACEH`, `SAMEPAGE`,
`PAD`) are section 4's.

### The ca65 traps

- A normal label ends ca65's cheap-local (`@`) scope, so one added inside a routine breaks
  its `@` references.  So does an equate: `tiles.s` relies on `RINGHIOP := * + 1` ending a
  scope at `draw_rect`'s head and on the first `:=` after the row loop ending it again
  (`HPAIR0`, `HPAIR1`), and `build.sh` looks `@s0f` up in `game.dbg` under `draw_rect` *or*
  `RINGHIOP` for that reason.  Hence the `@bf_`/`@wr_` site labels of section 4.
- A line starting with `:` is an anonymous label; adding or removing one retargets every
  `:+`/`:-` that crosses it.  The ring macros contain some (`macros.s` gives each one's
  count; `ringmod7` has two on the Model B and none on the Master, so nothing may branch
  over it with `:+`), and a few sources keep unreferenced `:` lines to hold a count
  (`ldprog.s`, `tiles.s`, `kernel.s`).
- `.segment` blocks are layout: the order of `ENGCODE`'s blocks in `frame.s` and the pads
  before them are the measured placement (section 1).
