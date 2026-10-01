# beebgame: the design

beebgame is one engine for two machines: a BBC Model B with 64K of sideways RAM and a
BBC Master 128, one disc for both.  This document is the detail behind the README.
Addresses are from a build's linker maps (`build/modelb/map.txt`,
`build/master/map.txt`) and the sources they come from; where the two machines
differ, both are given.  The figures are one game's build (the reference game's, Cleo):
where a figure depends on the game -- its code's size, its sprites, its levels -- it
is marked as the game's.  The game's code and tables are the game's segments (GAME*,
MNU*, ZPGAME); everything else is the engine's.

## One structure, two machines

A game's sources and the engine's in `src/` (the game's root includes them) are assembled twice by `tools/build.sh`:
`BHW=1` for the Model B's hardware (6502, `cfg/modelb.cfg`, output in `build/modelb/`)
and `BHW=0` for the Master's (65C02, `cfg/master.cfg`, `build/master/`).  `BHW` is only
the hardware.  The structure is the same on both: the code lives in four 16K sideways
RAM banks, each beside the data its inner loop reads, and the game's own loader gathers
every level from the disc into those banks.

| Bank | Code | Data |
|---|---|---|
| 4 | the sprite row loop and its blitters | most sprite images; the expansion tables and SWAPTAB |
| 5 | the sprite row loop and its blitters; the tile row's gather | the rest of the sprites; the level's map; the expansion tables and SWAPTAB |
| 6 | the tile blitter and the ring work that calls it | the level's tiles |
| 7 | at the top the kernel, resident: the display chain's builders, the palette, the disc driver, the image swap (on the Model B the interrupt's work too); below it the game's image -- the game's code, the engine's sprite prologue and records -- or the menus' image | the level's tables, the sprite directory and records, the game's variables; or the menus' code and data |

What `BHW` changes is the hardware underneath:

- **The Model B**: a 6502; 32K of main RAM that is almost all display, holding two
  software rings of 23 character rows, each with a mirror row; the rupture chain's
  interrupt work in bank 7 behind a stub in low RAM; an 8271 or an Acorn 1770 disc
  controller; Watford and Solidisk write-select boards; the tile gather computed.
- **The Master**: a 65C02; one hardware-wrapped ring of 32 rows at $3000, in main RAM
  for buffer 0 and shadow RAM for buffer 1; the status bar at $2B00; its interrupt
  handler and chain step in main RAM ($0600); its own 1770; the tile gather through a
  per-level table in main RAM (LV_PAGE0).

Nothing else differs.  The rule: the two builds may differ only where the CPU does
(a 65C02 instruction for a 6502 sequence, the same algorithm and data), where the
hardware does (the display memory, shadow RAM and ACCCON, the disc controllers, the
write-select boards), and in three placements on the Master -- its interrupt handler
and state in main RAM, its tile gather's table in main RAM, and its HAZEL/ANDY copy
of SPRX.  Where a 6502 spelling costs the Master no cycle it is used on both.  One of
everything else: one fill path, one `build_sections`, one `crtc_init`, one interrupt
body (`engine/kernel.s`; the Model B's stub pages it in, the Master's handler is it).

The data lies alike too.  `tools/build.sh` links the Model B first and then the Master with
every shared segment pinned at the Model B's address (`tools/pincfg.py`): the
Master's shorter code leaves gaps, and every table and variable -- zero page, low RAM,
each bank -- is at the same address on both.  What one machine alone has goes in
segments after the shared ones (ZPHW, LOWHW, KRNHW: the Model B's `jmp (abs,x)`
vector, its gather's shape, its mirror bookkeeping, its handler's state).
`tools/layoutcheck.py` compares the two builds' debug info and fails the build on any
difference; only code labels (a CMOS instruction is shorter) and the start-up pieces
may differ.

Page crossings are placed, not left to chance.  In banks 4-6 the Model B's code is
ordered so that its hot branches stay in their page (the sprite loops' rarer paths and
dispatch table sit after the blitters); the Master spends its shorter code's room on
pads (`src/pads.inc`, the `PAD` macro) before the blitters, found with
`tools/pagecheck.py`, which lists every branch that crosses a page.  In bank 7 the
engine's code ends at the kernel on the Model B, so a pad places what is before it;
the Master's runs on from the Model B's start, so a pad places what is after it.  The
bank 7 pads (PADB_xx and PADM_xx, at each of ENGCODE's routines that loop hot) were
chosen over a profile of every bank 7 branch taken and indexed read (Cleo's
`test/cycprof.mjs` with PHASEDUMP set, then `test/padopt.py`), for all the pads together: all of bank 7's
code moves with the kernel's start, so they are chosen again when that moves.  GAMEBSS and ENGBSS are page aligned, so the crossings of
their tables' indexed reads do not move with anything in front of them.  `SAMEPAGE`
asserts the hot loops' branches at link time.

The level files, the sprites, the tile set and the bar template are on the disc once
and read by both.  Each machine has its own bank images (BANKSB, BANKSM), load-time
program (LDPROGB, LDPROGM) and bank 7 images (IMG7B, IMG7M).  Because
the level files carry the sprites' placed addresses, the level layout is the Model B's
on both machines: `engine/sprloops.s` and `engine/gather.s` assert that each sprite bank's code ends exactly at
`B4_CODE_END`/`B5_CODE_END` on the Model B and at most there on the Master, whose
shorter code leaves a gap.  `build.sh` checks that the two builds' shared files are
byte-identical.

`TILEMIRROR=1 sh build.sh` also builds mirrored tiles into the tile blitter (below).
It is off by default: no level needs it.

## Main RAM

### Zero page (both machines)

| Range | Use |
|---|---|
| $00-$72 | the engine's (ZEROPAGE): defs.inc's (NSPR, BARDIRTY, SFXREQ, mtmp -- cpu.inc's scratch --, the ring and mirror state, the sprite prologue's hand-over, curR7, SECIDX), then engine/vars.s's (`mapptr`, maprow's result, among them); LDPROG's 17 bytes (LDZP) are the sprite prologue's scratch, dead during a load |
| $73-$79 | the Model B's own, the engine's (ZPHW: `jv`, the gather's shape); a gap on the Master |
| $7A-$EF | the game's (ZPGAME; Cleo's to $E7) |
| $F0-$FF | the MOS's zero page, but $F4 and $FC: the engine's hottest scalars |

Once the game has the machine only two of the MOS's zero-page bytes are still touched:
$F4, the MOS's copy of ROMSEL, which the interrupt restores from, and $FC, where the
MOS's interrupt entry keeps A (every handler returns with `lda $FC / rti`).  The rest,
in segments ZPF0 ($F0-$F3), ZPF5 ($F5-$FB) and ZPFD ($FD-$FF), holds scalars that were
absolute and are among the most accessed: MAPSTRIDE, mapshr, MUSTICK, rowbit, dpass,
spclip, MUSON and crtcb ($F8-$FB free).  `boot` zeroes them.  On the Model B the arithmetic gather's shape
(half0, halfhi5, halfsub) and `jv`, the vector the 6502's `jmp (abs,x)` goes
through, are in its own segment, ZPHW.

### Low RAM (both machines)

| Range | Model B | Master | Use |
|---|---|---|---|
| $0100-$013F | | | the stack, 64 bytes |
| LOWBSS | $0140-$01F8 | $0140-$01F0 | what more than one bank reads: the sprite list (SPRLIST), the buffers' state (BUF_CX, DIRTYCNT), PBANK/PBOARD, DISPSECT/NEXTSECT, GATHERH, the mirror's notes (Model B), sprc_ok, sprx_ok; and the game's few bytes |
| $0204-$0205 | | | IRQ1V, which the game points at its handler |
| LOWCODE | $0206-$02E4 | $0206-$02A4 | the crossings, the map helpers, pagelogic; the Model B's interrupt stub |
| LOWBSS2 | $02E5-$02F9 | $02A5-$02B9 | GATHERL |

LOWCODE is linked to run here and loaded behind the start-up code; `boot` copies it
down byte by byte (it is asserted under 256 bytes).

### The Model B

| Range | Use |
|---|---|
| $0300-$07FF | the status bar, 2 rows |
| $0800-$0A7F | mirror A: a copy of ring A's last slot row |
| $0A80-$43FF | ring A: 23 slots of 640 bytes |
| $4400-$467F | mirror B |
| $4680-$7FFF | ring B |

Everything from $0300 up is display; nothing else lives in main RAM during play.  23 x
640 is not a whole number of pages, so a pointer's fold at the ring end is 16 bits
wide, but both ring ends are page aligned (asserted: RINGEND_B = $8000, RINGEND_A a
page boundary), so `ringup`'s test is a byte compare against the buffer's `ringehi`,
and both bases are at xx80 (asserted), so the low byte folds by a constant.

A row of the tile blitter (`drawrect`) can straddle the ring end but a run -- the
chars of one tile, at most four -- never does: a ring row is 80 chars and the ring a
whole number of rows (on either machine), so the end falls on a map column that is a
multiple of 80, a tile boundary.  A run can only end exactly at the end, which carries
into a new page: `@advc`, on that carry, folds the pointer back to the base.  So the
runs have no wrap test and no char-at-a-time path.

During a load the display is black and is the loader's: the NMI routine at $0D00
(NMIPAGE), the load-time program at $0E00 (LDPROG, at most $0E00 bytes), a shared file
staged at $1C00-$5BFF (STAGE, 16K), the level's own file at $5C00-$7BFF (STAGE_LVL, 8K;
`tools/levelfile.py` asserts every level file fits), and the level's objects at $7C00
(LV_OBJS: 6 bytes each, which the game reads before its first render).  The file
is staged below the objects because they are copied out while it is still being read.

### The Master

| Range | Use |
|---|---|
| $0400-$05FF | LV_PAGE0: the level's tile gather table, 256 low bytes and 256 high |
| $0600-$08CA | CODE: the interrupt handler and chain step, the keyboard, the sound effects |
| $0C00-$0C6D | TABLES: the handler's state (BUF_SEC0, BUF_SEC0T1, SECTAB, BUF_QS, OLDIRQ); `boot` zeroes it |
| $1C00- | LV_OBJS, the level's objects (below the display; LDPROG ends by $1BFF) |
| $2880-$2AFF | QBLANK: 640 zeros (`boot`'s), Q's start -- the line a 6845 shows under the picture |
| $2B00-$2FFF | the status bar, 2 rows, main RAM, single-buffered |
| $3000-$7FFF | the ring: buffer 0 in main RAM, buffer 1 in shadow RAM at the same addresses |

The ring is the whole region the hardware wraps: an address that runs past $8000 comes
back to $3000, so a displayed row may straddle the end and needs no mirror.  That is
why RINGROWS is 32: it is the size of the wrap, not a choice.  The bar is below $3000
and there is only one of it; with shadow selected for display (ACCCON D = 1) the CRTC
does not see main RAM there, so the bar's section is scanned with D = 0 and the
playfield's with D = the buffer shown.

After its first read SPRX (at most 12K) is kept in HAZEL ($C000-$DFFF, 8K) and ANDY
($8000-$8FFF, 4K), and later loads rebuild the stage from there instead of the disc
-- unless the game has HAZEL for its code (GAMEHAZEL, *The build options*), when SPRX
is read from the disc at every load as on the Model B.
During a load the shared files are staged in shadow RAM at $3000 (ACCCON X set around
every read and every copy out) and the level's file in main RAM at $3000; the load
ends by clearing both screens, because a ring row the window has not reached yet must
not show what was staged there.  Every load starts by putting the CPU on main RAM
(ACCCON X and Y clear; with GAMEHAZEL, X alone): the game leaves X on the buffer it
drew last.

### Start-up (both machines)

The BOOT piece is loaded at $7000, display RAM that nothing has drawn in yet, with the
low-RAM image behind it.  Its header is the boot loader's findings at fixed addresses
on both machines: `dsk_type` $7000 (the controller), `dsk_drv` $7001, `dsk_banks`
$7002-$7005 (the socket of each of banks 4-7), `dsk_board` $7006; `boot` is at $7007
(all asserted in `init.s` and checked equal across the builds by `build.sh`).  `boot`
sets a 64-byte stack, zeroes zero page and low RAM (the MOS's zero page but $F4 and
$FC), copies the low code down, pages bank 7, copies the banks and the board to PBANK
and PBOARD and the controller and drive to the disc driver, blanks the palette, sets
up the CRTC and both buffers' chains, zeroes bank 6's variables, takes over the
interrupt and starts the game.  The screen overwrites it once play starts.

## The banks

The code for banks 4, 5 and 6 starts at $8000 and the data runs from the code's end
upward, so the data can be any size.  Each of these banks is entered at BANKENTRY =
$8000.

### Bank 4: sprites

| Range | Model B | Master |
|---|---|---|
| the row loop (SPR4CODE: `ds_entry`, the 4-bit blitter and its mirrored twin, the copy blitter) | $8000-$83CA | $8000-$83A7 |
| the resident sprites' bank-4 part (SPRC_BASE, SPRC_LEN: the game's) | from B4_CODE_END | same |
| the level's staged sprites | to $BBFF | same |
| L0TAB, L1TAB, NMASK (the expansion tables: `nibtab.bin`, the game's) | $BC00-$BEFF | same |
| SWAPTAB (the reversal of a byte's four screen pixels) | $BF00-$BFFF | same |

### Bank 5: sprites and the map

| Range | Model B | Master |
|---|---|---|
| the row loop (SPR5CODE: the same as bank 4's) | $8000-$83CA | $8000-$83A7 |
| MAP5CODE: `gather5` | $83E5-$844B | $83E5-$83F9 |
| the resident sprites' bank-5 part (SPRC5_BASE, SPRC5_LEN: the game's) | from B5_CODE_END | same |
| the level's staged sprites | to $9BFF | same |
| the map (MAP5 = LV_MAP), a fixed 8K | $9C00-$BBFF | same |
| L0TAB, L1TAB, NMASK | $BC00-$BEFF | same |
| SWAPTAB | $BF00-$BFFF | same |

Both sprite banks end with the same four pages (banks.s `NIB_TABLES`, segments SPR4TAB
and SPR5TAB in the cfgs' B4T and B5T), so the prologue in bank 7 can name them for
either, and either bank can draw any image, mirrored or not.  The cfgs give each
bank's code (B4X, B5X) $600.

The menus keep to bank 7, so the resident sprites stay from the first level on
(`sprc_ok`).

### Bank 6: tiles

| Range | Model B | Master |
|---|---|---|
| TIL6ENT: `bank6_entry`, `drawrect_clip` | $8000-$806F | same (padded) |
| TILCODE: `drawrect` and its row loop, its fills (the solid's one-byte cascade too), its ring row tables, `select_backbuf`, `scroll_validate` and the ring modulus table (Model B) | $8070-$8691 | $8070-$8559, padded |
| TILBSS: BUF_CY, FLATTAB | $8692-$869F | same |
| the level's tiles, 64 bytes a slot from TILES = $8600: id k in slot k + TOFF (2), so id 1 is at $86C0, the first 64 bytes clear of the code | $86C0-$BFFF | same |

### Bank 7: the kernel and two images

Bank 7 is a resident kernel at its top and, below it, one of two images, each read
from the disc over the other (`disc.s` `go_game`, `go_menu`; start-up reads the menus'
with `go_title`).  The two share their addresses, so nothing in either may be called
while the other is in: what both need is the kernel's.

| Range | Model B | Master |
|---|---|---|
| **the game's image** (GAME): the game's first, the engine's up against the kernel | | |
| ENGLVL: LV_ATTR0, LV_ALTCLS (256 each), LV_HDR (32), loaded | $8000-$821F | same |
| GAMEBSS, page aligned: the game's variables | from $8300 (the game's size) | same |
| ENGBSS, page aligned: the engine's variables | after GAMEBSS | same |
| free | | |
| GAMEDATA, GAMECODE: the game's tables and code (the file GAME starts here) | (the game's size) | |
| ENGCODE: the engine's bank 7 code, ending at the kernel | $B12A-$B806 | $B12A-$B704 |
| **or the menus' image** (MENU) | | |
| MUSCODE: the engine's music player | $8000-$809C | $8000-$8098 |
| MNUCODE, MNUDATA, MNUBSS: the game's menus | from $809D | same |
| **the kernel**, resident | | |
| KRNDATA: the row multiples (kept inside a page) | $B807-$B846 | same |
| KRNCODE | $B847-$BE55 | $B847-$BB51 |
| KRNBSS: the disc driver's and the swap's variables | $BE56-$BE62 | same |
| the driver slot: the 8271's driver or the 1770's, as the boot loader found | $BE63-$BEFF | same |
| KRNHW (the Model B): SECTAB, BUF_SEC0, BUF_SEC0T1, LOADREQ, page aligned | $BF00-$BF6B | -- |

The game's image is laid out for the engine to come apart from the game: the game's
variables, then the engine's; the game's code and data, then the engine's code,
which ends at the kernel -- `build.sh` sets the file's start from the Model B's
segment sizes (`od65`, before any link), so the engine's code sits where its own
size puts it, whatever the game's is (the Master's, pinned to the Model B's start,
runs on from there and falls short).  ENGCODE is `render_frame`
and `render_core`, the sprite prologue (`drawsprite`), `draw_sprites`,
`match_sprites`, `erase_old`, `copy_partial`, `mark_dirty`,
`draw_dirty`, `lvreset`, and on the Model B `mirror_copy` -- in whatever order keeps
their hot loops in a page (below: the pads).  ENGBSS is SPR_TABLE (the level's
part of the sprite directory: 2 bytes for each of the game's BOXID0 + BOXN sprite ids), the sprite records (SPRREC, RECCNT, KEEP) and the dirty
lists.  KRNCODE is `build_sections`, `menu_sections`, `calc_ring`, `ringaddr7`,
`load_begin`, the palette, `music_stop`, `read_sectors` and the loads' way in (`ld_go`), and
on the Model B the interrupt's work (`isr_body`, `scan_keys`, `sound_tick`: the
Master's handler has them in main RAM).  A game may place its own resident code and
data in KRNCODE with `PLACEH "CODE", "KRNCODE"` (its sound effects must be there:
the interrupt plays them).

The small tables are assembled, not built at start-up, each in the bank of the code
that indexes it: the row multiples (`mulrowlo/hi`) in bank 7's kernel for the
prologue, the records, the chain and the menus; the ring modulus (`ringmodtab`, RINGROWS x 5 entries, which
`ringmod` reaches with two subtractions) in bank 6 for `drawrect` on the Model B, where
the Master's ring needs only `and #31`.  Bank 7 has its own `ringaddr7` (the modulus by
subtraction, the base from `ringbhi`) so a sprite's screen address never crosses a bank.

## The crossings

A bank cannot page another in over itself, so every crossing is a fixed thunk in low
RAM (`low.s`).  There is no table and no dispatch in any bank.

- `callbank` (A = the bank): pages it, calls BANKENTRY, pages bank 7 back through
  `pagelogic`.  Once a sprite (the row loop in bank 4 or 5) and once a tile rectangle
  (`drawrect_clip` in bank 6, from `erase_old` and `draw_dirty`).
- `selbb` and `validate`: bank 7's two other calls a frame into bank 6,
  `select_backbuf` (which patches `drawrect`'s row-table operand on the Model B) and
  `scroll_validate` (which draws the newly exposed strips with `drawrect`).
- `mapstrip`: from bank 6's `drawrect`, once a tile row: pages bank 5, runs `gather5`
  over the map in place, pages bank 6 back through `page6`.
- `maprow`, `mapbyte`, `mapput`: the game's reads and writes of the map in bank 5.

Every switch writes ROMSEL_CPY ($F4) before ROMSEL, so an interrupt landing between the
two restores the bank being entered.  A switch that a store into sideways RAM may
follow also sets the write bank (below); `pagelogic` does, so everything that returns to
bank 7 has it right.

The tile gather runs in bank 5 beside the map because reading the map from bank 6
would take a bank switch per read; `gather5` reads a tile row's ids once into
GATHERL/GATHERH in low RAM, and the row loop draws both char rows of the tile row from
them without touching the map again.  The game's own sprite directory is in bank 7
beside the prologue, which reads it in place: in bank 5 it cost about 1,250 cycles a
frame.

## Bank numbers, sockets and write-select boards

The code is assembled for banks 4-7, but the four banks are whichever sockets the boot
loader finds RAM in (it runs the same probe on both machines).  Every byte of code that
holds a bank number is recorded at assembly (`cpu.inc`: `bankimm`, `setbank`, `BANKREF`) into the BANKFIX
segment, which `build.sh` appends to BANKS and checks against the pieces (each entry
must land on a byte whose low nibble is 4-7).  The boot loader rewrites each byte's low
nibble to the socket found and keeps the high nibble.  So the hot paths pay nothing.
Bank 7's game image comes off the disc after boot and is patched as it comes in: its
entries of both lists are taken out of BANKS's and assembled into LDPROG (`img7fix.inc`),
and `image_load` does what the boot loader does with them.  The two images share their
addresses, so an entry cannot say which it is in: the menus' image carries none (`build.sh`
checks the site labels), and reads a socket from PBANK like the rest of what comes off
the disc -- LDPROG -- does (four bytes, indexed by bank - 4; the `ldpbank` macro).

Solidisk and Watford boards read through ROMSEL like any machine but choose the bank a
store reaches with a register of their own: Solidisk, user VIA port B bits 0-3
($FE62 = $0F, then $FE60 = the bank); Watford, a store to $FF30 + the bank.  Every
switch that a store into sideways RAM may follow carries a companion store, assembled
as a second `sta ROMSEL` (harmless: A holds the bank) and recorded in the WRFIX segment
(`cpu.inc` `wrsel` for a constant bank, `wrselx` where the bank is in X as well).
`build.sh` appends the list after BANKFIX and asserts that every entry sits on
`sta $FE30`.  The boot loader rewrites each by board -- Watford `sta $FF3n` or
`sta $FF30,x`, Solidisk `sta $FE60` -- and leaves them alone on a plain machine.  The
write bank is bank 7's always, but in a *window*: a store into another bank sits between
a `wrsel` to it and a `wrback` that puts 7's back (cpu.inc) -- the sprite banks'
`ds_entry` (the dispatch patch), `drawrect` (its dispatch patches), `mapput`, `selbb`
and start-up.  Every other switch only reads and leaves the write bank be, and the
interrupt stores into no bank (what it keeps is in low RAM), so it neither needs a
write bank nor sets one.  `wrback`'s store is assembled as `sta $FF30`, a store into
the MOS's ROM on a plain machine (a second `sta ROMSEL` there would page bank 7 in
under the code), and build.sh accepts it beside `sta $FE30`.  LDPROG reads PBOARD and
does it by hand.  On the Master the macros are empty.

**Why bank 6's entry is a segment of its own (TIL6ENT) and banks 4's and 5's are
not.**  Every bank `callbank` enters must have its entry at $8000.  In banks 4 and 5
the code is one macro (`NIB_LOOPS`),
assembled into SPR4CODE and SPR5CODE with `ds_entry` its first line, so the entry is
at $8000 because nothing comes before it.
Bank 6's code, TILCODE, is `engine/tiles.s` -- the tile blitter,
`scroll_validate`, `select_backbuf` -- in source order, and `drawrect_clip`, where
`callbank` must land, is not first in it; so `bank6_entry` (falling into
`drawrect_clip`) is a segment of its own, placed first in the bank.  Bank 6 is also
the one entered other ways -- `selbb` and `validate` from low RAM call routines inside
it (`selbb` in a write window), and `mapstrip` returns into it -- which is why its entry
is a label of its own and not the start of a routine that is called from inside the
bank too.

The boot loader (`loader.s`) finds the RAM with the test Stuart McConnachie's sideways
RAM Elite loader used: page each of the 16 banks through $F4 and ROMSEL, flip bit 0 of
the ROM type byte at $8006, see whether it stuck, put it back.  A floating bus fails
it, and so does write-protected RAM.  The test runs three ways -- through ROMSEL alone,
the Watford way, the Solidisk way -- and the way that finds the most banks is the board
(a board's write latch rests on some bank, so the plain test finds that one bank on a
board machine too; plain wins a tie).  Each RAM bank is then classed: empty; holding a
ROM image the MOS is not running (no entry in its table at $02A1); holding a ROM the MOS
recognised.  Two socket numbers that reach the same RAM are found by a signature written
to each and read back (comparing the banks' bytes would call four blank banks one).
The four lowest sockets of the best class win; a bank holding a live ROM is fair game
as a last resort because nothing calls the MOS once the pieces are down and interrupts
stay off until the game's own handler is in.  With fewer than four the loader says
what it found, and how it wrote, and returns to the MOS.  A machine with RAM of two
kinds gets the kind with more; two boards at once are not handled.

## The display

Two units, always named (`docs/GUIDE.md`, *The concepts*): a **screen
pixel** is MODE 1's, 320 to a line, two bits, four to a byte; a **game pixel** is the
game's square pixel, 2 screen pixels wide and 2 scanlines tall.  MODE 1, 80 characters
(160 game pixels) wide.  The palette is logical 0-3 = black, cyan, magenta, yellow;
the colours come from a dither per game pixel, which the game's asset pipeline chooses:
a game pixel is four screen pixels, so it can show any combination of four of the
colours.  The engine needs only that the dither be the same for every game pixel of a
colour, whatever its position: then a tile or sprite reversed left to right with each
byte's two game pixels swapped is exact, which is how it mirrors them.

Horizontal scrolling is by whole characters (two game pixels) through the CRTC start
address.  Vertical scrolling is by a game pixel, two scanlines (`wfine` = 0, 2, 4 or 6
lines into the character row), through a *rupture*: the frame is several CRTC frames, each
section reprogrammed from a chain of VIA T1 interrupts and the whole re-phased at every
vsync.  The window is `wx`, `wy` in game pixels (map coordinates); `wcx` = wx/2 and `wcy` = wy/4 in
characters and character rows; the ring offset of the window's top-left character is
`ringS` and its slot `barq` (`calc_ring`).  `wcy` is a byte, and so is every character
row the renderer passes around (`rc_y`, the records' rows, BUF_CY): a map is at most
256 character rows, 128 tiles, tall.  With TALLMAP (the Master only) the rows stay
bytes -- the ring's modulus needs only their low five bits, and the rest of their uses
are offsets from the window -- and `render_frame` keeps `wcy`'s high bits in `wcyh`,
from which `drawrect` rebuilds the full row it reads the map at: 256 tiles.

Both buffers are rings of characters, 80 to a row, and the playfield is drawn in map
space: map character (cx, cy) lives at ring character ((cy mod RINGROWS) x 80 + cx) mod
RINGCHARS (`drawrect`).  So a scroll only draws the newly exposed strips
(`scroll_validate`), a displayed row may start anywhere in a slot and straddle the
ring's end, the bar has a fixed home outside the ring, and only the playfield's
sections walk the ring.

### The sections

| Section | Model B | Master |
|---|---|---|
| T, the bar | 2 rows at $0300 | 2 rows at $2B00, D = 0 |
| A, the composed row (when `wfine` > 0) | 8 - f lines | 8 - f lines |
| P, the playfield | P1 to the ring's end, then M from the mirror | one section: the CRTC folds it |
| P2, the bottom partial (when `wfine` > 0) | f lines | f lines |
| Q, blanking | 16 rows, vsync at row 8 | 7 rows, vsync at row 3 |
| visible rows | 21 (84 game px) | 30 (120 game px) |

All sections total 39 rows, 312 lines.  The bar is scanned (QROWS - QVSYNC) x 8 lines
after the vsync starts: 32 on the Master, where the Master MOS's own MODE 1 frame puts
the picture; 64 on the Model B, 4 lines below where a MODE 1 screen sits.

The **composed row** A shows lines f..7 of the window's top row at the top of the
picture.  It is the ring row just above the window, ring characters [ringS - 80,
ringS): a row at a constant offset from its source, so a horizontal scroll leaves it
valid.  `copy_partial` recomposes all 80 columns every frame that `wfine` is not 0
(tracking the columns drawn since the last copy saved under 0.3% of a frame; the
unrolled copy is about 1% of a frame faster than a loop).  On the Master the ring holds
the 31 rows of the window and its bottom partial plus this one, which is why VISROWS is
30.  On the Model B the 23 slots are the 21 visible rows, the composed row and the
bottom straddle.

The **mirror** (Model B): a displayed row that starts within the ring's last 80
characters straddles the ring end.  The CRTC cannot fold a 23-row ring, so a copy of
the ring's last slot row sits immediately below the ring base, where the address
`c - RINGCHARS` names the straddling row, and every row after it follows on
contiguously: the chain reads P1 up to the ring's end and M from the mirror
(`build_sections`, `mirror.s`).  Only the characters that row takes from the mirror --
`wcxm`..79, where `wcxm` is ringS mod 80 -- need to be right, and when the window is
slot aligned no row straddles at all.  The blitters note the columns they write to the
row the mirror follows (`mirdirty`, and `drawrect`'s own copy in line, the sprite prologue
and `copy_partial`), and `mirror_copy`, the last step of `render_core`, copies only
those.  It redoes the whole row when a move left uncovers characters the last copy
never reached, or when the map row in the last slot (`mrow`) has changed since it: a
move right across a slot boundary wraps `wcxm` through 0, and the characters now from
`wcxm` on were written while they were the row above's, left of the old `wcxm`, so no
blitter noted them.  (Missing that second case showed stale mirror characters in the
straddling row, a strip of the tile that was there before.)

**Q's first scanline.**  A 6845 always displays the first scanline of a frame whatever
R6 says, so Q's row 0 line 0 is one more line under the picture.  As the ring row
after the playfield it would be the next map line, a repeat of P2's first line under
a fine scroll, or junk at the map's bottom; so Q always starts at QBLANK (defs.s), a
line that is always the same.  The Master's is 640 zeros below the bar, in main RAM,
which Q's step reads with D = 0 (below).  The Model B has no spare 640 bytes, so its
QBLANK is the bar's own first line, until its palette can blank that scanline.

### The chain

`build_sections` fills SECTAB (8 bytes an entry: R12, R13, R4, R9, R6, R7, T1 low, T1
high; 48 bytes a buffer) from `ringS` and `wfine`.  An entry holds section i's shape
and section i+1's address and duration, because R12/R13 latch at the next restart and
a T1 latch takes effect one interrupt later.  Section 0, the bar, takes its address and
length from BUF_SEC0/BUF_SEC0T1 of the buffer about to be shown.

Each T1 interrupt is a CRTC restart.  R12/R13 were armed during the section before.
R9 and R4 together decide where the new section ends: the CRTC latches end-of-frame at
the start of the scanline where row = R4 and line = R9, so for a two-line section both
must be in place before scanline 1, 128 cycles after the restart; R6 is compared from
scanline 1 on, so Q's R6 = 0 has the same deadline.  The chain is phased (VS2T) so the
step's first CRTC write lands just after the restart.  Every cycle before that write is
lead the phasing allows for, so none is spent waiting where it can be avoided: the
Model B's stub pages bank 7 in inline and jumps to the body and back (`STUBLAT`);
on the Master only the step after the bar's -- the one that switches ACCCON D to the
displayed buffer, which must happen before its boundary -- writes D and holds about
26 cycles, and the others fire later instead (BARLATE for the bar's, STEPLATE for the
rest: VS2T, the bar's length and entry 0's duration carry them).  Then it writes R9, R4, R6, R7
in that order (with R4 third it landed at about 140 cycles for a two-line P2, the
section never ended, and both borders lit on every scroll frame).  R12/R13 go last,
after the T1 reload and the index bookkeeping, so they land on scanline 1: written
straight after R7 they fell across the end of scanline 0, and some 6845s -- the VL6845
among them (Tom Seddon's r4-3 test) -- end a partial (R4 = 0 on row 0) at once and
reload the start address as that scanline ends.  A Master with such a chip lost the
R12 write and showed the playfield 256 characters adrift, a 16-character tear down
every row whenever the fine scroll was not 0.

The chain stops at Q, the only section whose R7 is the vsync row, so a late vsync
cannot walk it off the end of SECTAB.  The vsync interrupt (CA1, at the end of the
2-line pulse) restarts T1 first, for a constant latency, then re-phases: R9 = 7 and
R4 = curR7 + QROWS - 1 - QVSYNC, so this frame ends a fixed number of rows after the
vsync whatever the row counter did (a counter that has run past its vertical total
otherwise never recovers).  It pre-arms the bar's R6 there, in Q, where a new R6
cannot show.  A pending flip is taken only at a vsync at least two after the last
one; the vsync then programs section 0 from the buffer about to be shown, scans the
keyboard and runs the sound.

`crtc_init` writes R8 = 0 on both machines: the MOS's MODE 1 leaves interlace sync on,
which puts every other field's vsync half a scanline later (on BeebEm's Model B it
showed as a band across the picture).

VS2T (`engine/kernel.s`) is the vsync-to-bar time less the pulse, less the lead that
puts each step ahead of its restart (-35 -36), less the step's own entry costs:
STUBLAT -- on the Model B 18 - 22 - 4 ticks, its stub paging bank 7 in (pagelogic
inlined, a jmp each way, no write bank); on the Master -BARLATE -- and -8 for the
LOADREQ test.  +2 ticks on both: the vsync loads it as an immediate.

**The Master's ACCCON D.**  D is the memory map the CRTC fetches from, sampled on every
fetch, so it must change before a section's boundary, not after.  The bar's T1 fires
BARLEAD = 23 us earlier than every other step's lead, so D can be switched in the
horizontal blanking of the bar's last line; the section after the bar runs BARLEAD
longer to end where it should.  The handler sets D from `dispD` for every section but
the bar (which starts with D = 0, cleared at the vsync); the flip moves `dispD` to the
new buffer with the section chain.  Q's step (QSECT, the vsync's copy of the buffer's
BUF_QS) puts D back to 0 before Q's first scanline, so QBLANK is main RAM for both
buffers: it fires QLEAD early (the section before Q runs STEPLATE + QLEAD shorter), and
its D write is the handler's first act -- behind a two-line P2's own step there is no
time for more -- keyed on SECIDX = QSECT (the chain rests on Q till the vsync).  A
bottom partial's step fires P2EARLY early too, so it is done in time.  crtctime.mjs
logs every ACCCON write: D lands at characters 98-114 of the line before its boundary.  `select_backbuf`'s read-modify-write of ACCCON's X
bit runs with interrupts off, since the handler writes D.

### Load mode

A disc load stops the chain (interrupts are off while the disc is read).  Stopped
mid-chain the CRTC would repeat whatever section it was in with no vsync, and monitors
and capture cards take seconds to regain sync.  So `load_begin` asks the chain to stop
at a frame boundary (LOADREQ: 0 running, 1 stop asked, 2 stopped, 3 resume asked): the
next bar step programs a standard 39-row frame instead (R4 = LDR4 = 38, R7 = LDR7 = the
row the chain's vsync is on) and turns T1's interrupt off, so the sync never moves.
The switch is made in the interrupt handler's bar step, so it happens at the frame
boundary however long the handler's other work runs (a version that waited for a
vsync and polled for the bar's T1 switched one section late when the vsync's work ran
past that T1, and made a short frame).  While stopped the vsync still counts, scans
the keys and plays the sound.  LDPROG's `ld_resume` sets 3 at the load's end; the next vsync turns T1's interrupt
on again and its re-phase, with curR7 = LDR7, is exactly the standard frame's total,
so the bar step at that frame's end takes the display back as if it had never stopped.
The palette is black throughout.

### Double buffering and the flip

`curbuf` is the buffer being drawn.  `render_frame` waits for the previous flip, draws
the HUD digits if BARDIRTY (the bar is single-buffered and drawn where it is shown, so
this comes first, before the CRTC reaches it), derives the character window, runs
`render_core`, builds the chain for this buffer and requests the flip.  `render_core`:
`selbb`, `calc_ring`, `match_sprites`, `erase_old`, `validate`, `draw_dirty`,
`draw_sprites`, `copy_partial`, and on the Model B `mirror_copy`.

The bar's template (the BAR file, 1,280 bytes) is read into place with the game's
image and never redrawn by the engine; the game draws what changes, in `hook_hud`,
while BARDIRTY is set.  The bar lives outside the ring because in the ring it moved
with every vertical scroll and re-copying its 1,280 bytes cost 13,310 cycles a frame.  The menus never show or touch
it: `menu_sections` points section 0 at two black ring rows below the window instead.

## The tiles

A map tile is 8x8 game pixels: 4 characters by 2 character rows, 64 bytes.  A map byte
is a level tile id:

| Ids | Kind |
|---|---|
| 0 | the level's solid: one colour's fill (the header's +31), one byte down every line |
| 1 .. half0-1 | full tiles, stored at TILES + 64 x (id + TOFF) |
| half0 .. half1-1 | half tiles whose top row is a fill |
| half1 .. half2-1 | half tiles whose bottom row is a fill |
| half2 .. mir0-1 | half tiles whose two rows are the same |
| mir0 .. (TILEMIRROR only) | full tiles drawn mirrored from another's slot |
| FLAT0 .. 253 | NFLAT flat tiles: one colour's dither, two bytes alternating down every character |
| 254, 255 | two more flat tiles: FLATTAB's last pairs, the level's like the rest (Cleo's two solids, cyan and black) |

How many flat tiles a level may have is the game's parameter, NFLAT (assets.inc; FLAT0
= 254 - NFLAT, asserted).  So NFLAT + 3 ids are fills, costing no bank 6 room beyond
FLATTAB's two bytes each; the more there are, the fewer ids are left for the tiles.
(Cleo's is 4.)

These ranges are the Model B's arithmetic gather's.  The Master's gather is only its
table, LV_PAGE0, so on a Master-only build (MASTERONLY) any id below FLAT0 may be any
stored slot, kind 0 (as stored) or 3 (mirrored, TILEMIRROR), in any order: Commando's
packer stores each image and its mirror once and gives every drawn (image,
collision) pair an id, the full ids and the mirrored ones interleaved.

The packer may give tiles that look the same the same id, or not: the game's two
per-tile tables (LV_ATTR0, LV_ALTCLS) are read by id, so tiles the game treats
differently need ids of their own.  A flat tile is not stored: its two bytes are in
FLATTAB (bank 6), the solids last.  A half tile stores its one distinct character row,
32 bytes, from HALFPAGE + HALFOFF x 32 (the page after the full tiles), with its fill's
pair in a table after the halves; the row loop's two loads of that pair are patched by
the loader (HPAIR0, HPAIR1).  The solid's fill byte is the header's +31; the loader
patches it into the row loop's `lda #` (SOLIDF: a cheap label, which `build.sh` reads
from `game.dbg`, because any symbol defined there would end the loop's `@` scope).  A
level's ids and the lists that gather its tiles are laid out for the Model B's bank,
the smaller: the tiles from the first slot clear of the code to the end of bank 6, on
both machines.
The slots count from the page TILES ($8600), so the address stays arithmetic: the
Model B's gather adds TOFF to an id (the packer's constant, in assets.inc; init.s
asserts the code ends below slot TOFF+1).

`gather5` turns a tile row's ids into (GATHERL, GATHERH) pairs, which `drawrect`'s row
loop reads:

- a full tile: GATHERH = its page (bit 7 set), GATHERL = (id & 3) << 6 (bits 0-5
  clear), so the full-tile path is the load, one `bmi` and the address -- no kind test;
- the level's solid (id 0): GATHERH = 0, the row loop's fall-through: the patched byte
  (SOLIDF) stored down every line;
- a flat tile or the other solid: GATHERH = $40, GATHERL indexing its pair in FLATTAB;
- a half tile: GATHERH = its stored row's page less $80 ($06-$3F: bit 7 clear marks
  it), GATHERL = its offset | bit 2 | which row fills (bit 0 the top, bit 1 the bottom,
  neither: both rows are the stored one); the row loop tests against `rowbit` (1 for
  the top character row, 2 for the bottom).

The row loop's load of GATHERH then sorts a run with two branches: `bmi` to the full
tiles, `bne` to the rarer ways (flats at $40, halves below it: one `cmp`), and on
through to the solid.  The flats and the halves' fill rows go down the one pair
cascade (PCHAR).

On the Model B `gather5` computes the pair from the id with the level's shape (half0,
halfhi5 -- the halves' page less $80, the loader's --, halfsub, in zero page), since
main RAM has no room for a table; only a half's low bits are one, HLOW in bank 5 beside
the gather.  A half's GATHERL is its row's offset (bits 5-7), which char row is the fill
(bit 3 the top, bit 4 the bottom -- `rowbit` is 8 or 16 -- neither when both rows are
stored) and the fill's colour (bits 0-2): an index into the level's palette of 8 pairs
(Cleo's levels use 5 at most), so `@hfill` is an `and #7` and two patched loads.
On the Master it is two indexed loads from LV_PAGE0 in main RAM, a table the packer
builds per level; unused ids in it are a black fill ($40, 0), because the rows past a
map's end are read too.  The Model B's gather tests for id 0 first (`beq`, 2 cycles a
tile): a solid costs it one store.

`drawrect` (bank 6) draws a rectangle of map characters into the back buffer: per-rect
invariants once, the first row's screen address (in line: every routine `drawrect`
alone calls is written into it), then per tile row one `mapstrip` and
one or two character rows.  A row may straddle the ring's end but a run -- the
characters of one tile, at most four -- never does (below), so every run is drawn by
an unrolled block entered by its length.  The blocks are the same code on both
machines; only the entry differs.  The Model B patches a branch right before the
blocks (each group's entries in the branch's page, asserted, so it costs a jmp's 3
cycles; `drawrect` is a write window for it); the Master goes through `jmp (abs,x)`.
X holds the run's dispatch index from RUNN (`min`, then `tax`: n on the Model B, 2n
on the Master) to `@advsp`, which steps `sp` by a table of 8n -- every block keeps X.  A fill
of a pair stores each byte four times a character, every store setting its own Y (70
cycles a character; alternating loads down a `dey` chain was 88).  The solid is one
chain of 32 `sta (sp),y` with an `iny` between each after its branch, entered at a
store with Y = 0 (the Model B's branch offsets a table beside the dispatch's); on
the Model B ringmodtab and PADB_T6 before `drawrect` put its two hot stretches each
in a page, on the Master PADM_T6 the row loop's `bmi`.  Each character row starts with `sp` already set, by `drawrect`'s head for
the first and `@rowdone` for the rest.

**Mirrored tiles** (TILEMIRROR=1): another stored tile reversed left to right, drawn a
character at a time right to left with `((b & $33) << 2) | ((b & $CC) >> 2)`.  The
packer mirrors only what the bank cannot hold, the least used first; on the Model B
MIRTAB (each mirrored id's source slot) is in bank 5 beside the gather, on the Master
LV_PAGE0 names the source's slot.  No level needs it, and the code and tables it
takes are the room: building it raises TOFF to 4.

**The tile set.**  Every distinct tile any level uses, in three files, TILES0-2, of at
most 256 tiles each (16K, STAGE's size).  How the tiles are cut between the files is
the game's choice: a level's tile list says which of the files it stages and which
tiles it takes from each, so a tile the levels share can be in one file that all of
them stage, and a file only some levels use is never staged by the others.

**Dirty tiles.**  A tile the game changes is queued for both buffers (`mark_dirty`,
DIRTYMAX = 20 each).  Past that the buffer is marked invalid (BUF_CX high byte $80)
and redrawn whole: correct, but a whole window's redraw.

## The sprites

**Where they sit.**  A row of a sprite walks the column pointer across the image a
column (`lines` bytes) at a time, and each page it crosses costs the carry path (9
cycles; the mirrored walk's borrow, 7).  So where each image lies in its bank
matters, and the packer places them for it (`tools/sprpack.py`): each level's images,
as separate items, are ordered and padded within their bank's run by a local search that
minimises the expected carries (over the eight line phases a sprite can have), plus
the reads that cross a page, weighted by how often the level draws each sprite forward
and mirrored (the game measures that; its packer passes the weights).  The resident
sprites are placed the same way, weighted over all the levels, and may pad into the
room the fullest level leaves.  The placement list tells the loader every item's
address, so this needs nothing of the loader.  The search is deterministic
and cached (`build/sprpack.cache`).  An image of a few hundred bytes crosses a page
once a row whatever the placement: that is the floor.

The sprite list (SPRLIST in low RAM: one array per field -- id, x and y in game pixels,
map coordinates) is built by the game each frame, at most MAXSPR (the game's figure,
from assets.inc).  Each buffer keeps a record per sprite drawn (10 bytes: id, position,
the screen rectangle, whether it was clipped).  `match_sprites` marks a sprite KEEP 2
when it is the same id in the same place as the buffer's record, and 1 when it is a box
where a box was (below: it covers the old one, so neither needs erasing); `erase_old`
redraws the tiles under every record not kept; `draw_sprites` draws in two passes, the
boxes first (a box is an opaque rectangle, and drawn later it would paint over what
stands in front of it), and skips a "still" box that is kept identical and was not
clipped at a window edge.

**Boxes.**  Sprite ids from BOXID0 to BOXID0 + BOXN - 1 are boxes: opaque rectangles
with their background baked into the art, stored as screen bytes and drawn by the
copy blitter (either bank).
Two rules come with them.  A box drawn at the same place as the box before it must
cover it completely (the engine does not erase it: frames of one animation, the same
size).  And ids from BOXID0 + BOXN are "still" aliases, each drawing as the box BOXN
below it: a game uses one when it knows nothing will move over the box, so that
`draw_sprites` may skip it altogether while it is unchanged.

**The directory** is in two parts.  The level's, SPR_TABLE in bank 7 (banks.s; the
level file's section 11, which `ldprog.s` copies whole, `DIRLEN`), is the images'
addresses by id: `DIR_LO` then `DIR_HI`, BOXID0 + BOXN bytes each, the high byte 0
when the id is not in this level and with bit 7 clear when the image is in bank 5 (an
image is at $8000-$BFFF, so bit 7 is otherwise always set).  The game's, the same in
every level, is the geometry (`sprgeom.inc` in the game's GAMEDATA, or HAZEL, where
the prologue reads it with bank 7 paged): `SPRG_IX`, a byte by id, the sprite's shape,
and by shape `SPRG_W` (the width in bytes), `SPRG_RX` and `SPRG_RY` (the reference
point, signed game pixels) and `SPRG_LN` (the rows stored), and with `SPRGFL` (the
game's assets.inc) `SPRG_FL`, the flags: bit 0 mirrored, bit 1 every scanline stored,
bit 3 the copy blitter.  Without SPRGFL the flags are DRAWFLAGS's `sp_dfl`, or 0.  The
directory covers the boxes (BOXID0 + BOXN ids), and the prologue folds a "still"
alias onto its box first.

`drawsprite` (bank 7) takes the id in X: the address from DIR_LO/DIR_HI (high byte 0:
return; bit 7 clear: bank 5, the bit put back), the shape from `SPRG_IX` into `sp_g`,
and the flags, W, lines, refx and, at `@vert`, refy by shape; `sp_ext` is the lines,
doubled unless flag bit 1 is set.  It clips the sprite to the
window, writes the record, notes the mirror's columns (Model B), computes the source
and screen pointers and the blitter index, and hands over through `callbank` to the
row loop in the bank the image is in.  The row loop (`NIB_LOOPS`, `engine/sprloops.s`)
is assembled into both sprite banks, since it reads the image bytes; `ds_entry` opens
a write window into its bank for the whole row loop (as `drawrect` does), because
each row patches the column loop's `jmp`.  The lines a row draws in every cell are the
same all along it -- 0-7, but from `sp_ra0` on the first row and to `sp_ra1` on the
last -- so the row loop, not the column, chooses the blitter's entry for them
(`sprrow_tab`, from `sp_disp`, the prologue's: the blitter's first entry): to line 7
the unrolled cell entered at its first line, otherwise the partial loop.  The
commonest blitter, `sprFN`, falls into its column step, and the column countdown ends
in the patched `jmp` itself.

The 4-bit blitter (`NIBCELLS` and `NIBPART`: `sprFN`, and `sprFM` mirrored): an image is stored
column by column, a byte a game-pixel row, the byte's two game pixels 4 bits each (the
left in the high nibble), indices into one palette the game chooses, nibble 0
transparent.  Three tables, the game's (`nibtab.bin`), turn a stored byte into screen
bytes: L0TAB and L1TAB the row's two scanlines, NMASK the AND mask for its transparent
game pixels ($00 both opaque, $CC or $33 for one).  A byte of 0 draws nothing, one
whose NMASK is 0 is two plain stores, and any other is (screen AND NMASK) OR the line.
The mirrored blitter passes every result, the mask's too, through SWAPTAB.  The
shape's `lines` is the rows stored, with flag bit 1 clear, so the prologue takes
two scanlines a stored byte (`sp_rinc` 4); a sprite's first line in a character is
always even (lb0 = 2 x sy + wfine), so a cell's lines go in pairs, a source byte a
pair.  A sprite's screen position is in whole bytes across (`drawsprite`'s c0 = sx >>
1: 2 game pixels, 4 screen pixels) and game pixels down (2 scanlines).  A box (flag
bit 3) is not 4-bit: it is its screen bytes, every scanline stored (flag bit 1, lines
= 2h), drawn by the copy blitter (`NIBCOPY`, `sprFC`: 13 cycles a byte, unrolled to line
7 from any first line -- each line sets its own Y -- and the Master's line 0
non-indexed), so a box's backdrop keeps any dither exactly.  Every blitter is in both
banks.

**Resident and staged sprites.**  Which sprites are loaded once and which each level
loads is the game's choice, given to the engine as parameters:

- The **resident** sprites are one file, SPRC, loaded at the first level load and
  never again (`sprc_ok`): SPRC_LEN bytes to bank 4 at SPRC_BASE (= B4_CODE_END), then
  SPRC5_LEN bytes to bank 5 at SPRC5_BASE (= B5_CODE_END).  Their places are fixed, so
  every level's directory can name them without a placement.
- The **staged** sprites are the other file, SPRX (SPRX_LEN bytes: at most 16K,
  STAGE's size, and at most 12K for the Master to keep it in HAZEL and ANDY).  At each
  level load it is staged whole and the level's own subset copied out, image by
  image, to the addresses its placement list gives; `imgtab.bin` says where in
  SPRX each item is.
- The rest of each sprite bank -- from the resident part's end to $BBFF in bank 4, to
  $9BFF (the map) in bank 5 -- is the level's.  So the split trades load time and disc
  reads (a resident sprite is never staged again) against the room every level has
  for its own.

The banks add no constraint of their own: both have every blitter and the tables, so
any image, mirrored or not, and any box may be in either.

## The disc

One single-sided 80-track disc (the game's DISC_OUT) with 30 files (the DFS catalogue
holds 31), in this order:

| File | What |
|---|---|
| !BOOT | `*RUN LOADER` |
| LOADER | the boot loader, both machines, at $1900 |
| BANKSB, BANKSM | each machine's fixed pieces, bank-number patch list and write-bank store list |
| IMG7M, LDPROGM, LDPROGB, IMG7B | each machine's bank 7 images (the menus' to a whole sector, then the game's: LDPROG reads them as two) and load-time program; a game's start reads LDPROG, IMG7 and BAR in turn, so the Model B's are in that order |
| BAR | the bar template |
| SPRX, SPRC | the sprites: the level-placed ones, the resident block |
| TILES0, TILES1 | two of the tile set's files |
| L0-L15 | the levels |
| TILES2 | the tile set's third file |

Sector numbers are baked into the game and LDPROG from `files.inc`, which `mkdfs.py
table` writes from the files' sizes; `build.sh` assembles twice so they settle and a
third time to check they have.

### Boot

LOADER runs under the MOS.  It asks the MOS its version (OSBYTE 0: 3 and up is a
Master) and chooses BANKSB or BANKSM, finds the RAM, finds the drive DFS has current
(OSGBPB 6), and the controller from the DFS ROM's version string (0.x and 1.x are
Acorn's 8271 DFSs, 2.x the 1770 one; holding W or I at boot says so instead).  It
selects MODE 1 and blacks out the palette (the ULA and the screen-size latch stay as
the MOS set them; the game reprograms only the CRTC), loads BANKS whole to $2000 with
OSFILE (through OSGBPB a byte at a time took the 1770 DFS twenty seconds), turns
interrupts off, copies the pieces to their banks and main RAM, applies the bank patches
and the write-bank stores, writes its findings to $7000-$7006 and jumps to `boot` at
$7007.  `build.sh` asserts BANKS ends below $7000.

### The game's own disc driver

After boot the MOS is abandoned: `disc.s` (bank 7's kernel) drives the 8271 or the 1770
directly.  `read_sectors` reads a run of 256-byte sectors (10 a track) into main RAM;
each track's part of the run is the driver's.  The two drivers are linked for the same
place, the driver slot at the top of the kernel (the cfgs' DRV8271 and DRV1770
overlap), and BANKS carries both, flagged by controller in the piece table's bank byte
(bit 7 the 8271's, bit 6 the 1770's): the boot loader copies in only the one the
machine has, so the kernel pays for the larger driver, not both.  `build.sh` sizes the
slot from the two (od65) and sets the kernel's start below it.  A driver in the slot
is a `jmp` to its track read (`DRV_TRACK`: C = 1 asks for the run again), its NMI
stub's length and the stub.  Both controllers raise NMI for every byte, so the stub is
copied to $0D00, where the NMI lands, for each load; it writes through a self-modified
address and keeps its state in that page ($0DFD-$0DFF), so it works whatever bank is
paged.  Neither driver may hold a bank patch or a write-bank store (`build.sh` checks:
a patch in a piece that may not be copied would be lost).

- **8271**: DFS's step rate is kept, but not its motor: after an idle spell (the title)
  the head has unloaded, and a read on a stopped drive reports "not ready" at once,
  which the 8271 latches until a read-drive-status.  So each run loads the head
  (special register $23: select + load head) and reads the drive status first, as DFS
  does, and retries a run that fails.
- **1770** (the Acorn board on the Model B at $FE80/$FE84, the Master's at
  $FE24/$FE28): reset and restored to track 0 once at start-up; a seek when the head
  is elsewhere, then read-multiple, which the stub ends with a force-interrupt after
  the run's last sector.

### A level load

The game calls `load_level_b` (X = the level): the kernel's `ld_go` does
`music_stop`, `load_begin`, interrupts off, the driver's NMI stub to $0D00, and LDPROG
read to $0E00 and run (`ld_entry`, X = the level).  Everything after that is
LDPROG's: the kernel holds only what must run before LDPROG is in place.  LDPROG runs in main RAM, where it can page any bank; it reads the socket
of every bank from PBANK and sets the write bank by PBOARD by hand.

1. The level file to STAGE_LVL.  It ends with the Master's LV_PAGE0 in two whole
   sectors; the Model B's file table reads it short of them (`LFILE`, PAGE0_SECS).
2. The header, attr and altcls to bank 7; the objects to LV_OBJS; `mapshr` = 8 - lw
   and MAPSTRIDE = 1 << lw from the header.
3. The map, run-length coded, unpacked into bank 5 at $9C00: exactly 1 << (lw + lh)
   bytes (the stream is not terminated).
4. Each of the level's tile-set files staged in turn, its full tiles copied to
   consecutive slots from TILES and its half tiles' stored rows to their slots; then
   the halves' fill palette after them (16 bytes), HPAIR0/HPAIR1 patched, and on the
   Model B the gather's shape and each half's low bits (HLOW, bank 5).
5. The sprites: SPRC to its fixed places if it is not already there; then SPRX staged (the
   Master: from the disc the first time, then kept in HAZEL and ANDY and restored from
   there), and every image the placement list names copied to its bank and address
   (or, from BAKEITEM0, baked: *The build options*).
6. The directory's level part to SPR_TABLE, bank 7, as the packer finished it:
   no table is built at load.
7. FLATTAB to bank 6.  On the Master, LV_PAGE0 to $0400 and both screens cleared.

Then LDPROG's `ld_resume` (the chain's restart asked for, interrupts on) returns to the
game, which goes on from the header (the
map's size and the window's limits, which it sets for the engine; `lvreset`).

### Bank 7's images

`go_title`, `go_game` and `go_menu` go through the same `ld_go` with X an image load
(defs.inc LDOP_), and LDPROG's `image_load` is the same machinery as a level's: the
image staged and copied to its place, then its bank numbers and write-bank stores
patched as the boot loader patches BANKS.  The game's image brings more: its variables
(GAMEBSS) are zeroed, so a game starts the same whatever the menus left there, and the
bar template is read to its place.  Then LDPROG goes on to the game's hook (their
addresses come from the game's debug info: `build.sh`).  For `go_game` (the menus'
way out) it calls `hook_image` and jumps to `hook_play` (through the kernel's
`game_in`, a label for the test harness) with the stack reset and the disc still open
(`ld_open`): the first level's load goes straight on without parking the chain and
reading LDPROG again.  For `go_menu` (the game's way out, with A for the menus) it
resumes the chain and jumps to `hook_over`; for `go_title` (start-up), `hook_title`.

## The level files

The format has one definition, `tools/levelfile.py`.  A game's packer builds a
`levelfile.Level` in the engine's terms and `encode()` writes it; `ldprog.s` reads it, taking the section numbers (SEC_) and the
header's offsets (HDR_) from `levelfmt.inc`, which the build writes from
`levelfile.py inc`, so the writer and the reader cannot drift apart.  The build also
runs `levelfile.py check` over every level file (the table, the sections in order,
the header's counts against the sections, the stages' sizes), and
`test/test_levelfile.py` tests the writer against its reader
(`python3 -m unittest discover test`).

A level file starts with a table of 13 section offsets:

| # | Section |
|---|---|
| 0 | the header, 32 bytes (below) |
| 1 | the objects, 6 bytes each (at most 149, LV_OBJS's room): the game's, copied to LV_OBJS |
| 2, 3 | two tables by tile id, 256 each: the game's, copied to LV_ATTR0 and LV_ALTCLS |
| 4 | the tile list: the files, each with its full-tile count, then each full tile's index in its file |
| 5 | the sprite placement list, 6 bytes an item: item, bank (4 or 5), image address, and 0 or, for an item the loader bakes, its tile (x \| y << 8); $FF |
| 6 | the map, RLE: c < 128, c+1 literals; c >= 128, the next byte c-126 times |
| 7 | FLATTAB's pairs |
| 8 | the half tiles: index in file, row, file |
| 9 | the halves' fill palette (8 first bytes, 8 second), then each half's low bits (fill row: 8 top, 16 bottom; colour: 0-7) |
| 10 | MIRTAB (TILEMIRROR) |
| 11 | the sprite directory's level part, 2 x (BOXID0 + BOXN): the images' addresses by id, low bytes then high (0: not in this level; bit 7 clear: bank 5) |
| 12 | LV_PAGE0, 512 bytes, sector aligned at the end |

The header (LV_HDR): the engine's fields are lw and lh (+0, +1: log2 of the map's
size in tiles), the objects' count (+6) and the tile set's shape (+20..+31,
`levelfile.Shape`: +21 the tile count, +22 mapshr = 8 - lw, +23 the half count,
+24-26 half0-2, +27 the halves' page, +28 HALFOFF, +29 mir0, +30 the mirror count,
+31 the solid's fill byte); +2..+5 and +7..+19 are the game's.  `encode()` refuses a
game field in the engine's bytes.  `levelfile.check` takes the game's BOXID0 and BOXN
(the build passes its assets.inc).

The file must fit the Model B's STAGE_LVL (8K, without LV_PAGE0) and the Master's
stage (20K); a Master-only build (MASTERONLY: `levelfile.py` reads it from the
environment) needs only the second.

## The build options

`tools/build.sh` takes its options from the environment (the game's `build.sh`
exports them), passes each to the assembler (`-D`; `cpu.inc` makes the rest 0) and
to its tools.  With none set a game builds for both machines.  What each changes:

- **MASTERONLY.**  build.sh's targets are `master` alone: no Model B assembly, and
  the Master is linked unpinned (no `pincfg.py`), its bank 7 image sized from its own
  `od65` segment sizes; the shared files come from `build/master`; the disc has no
  BANKSB, LDPROGB or IMG7B; no layout check.  The boot loader, assembled with it,
  answers a Model B with "<game> needs a BBC Master 128".  The engine's asserts that
  held the Master to the Model B's code ends (`* <= B4_CODE_END`) still hold, so a
  game sets B4_CODE_END and B5_CODE_END to its own ends.
- **BAKEITEM0** (the game's assets.inc): items from it on are baked by the loader
  (`ldprog.s bake`), not copied: the level's own tiles where the object stands, decoded
  as the Model B's gather does (the solid, the flats, the halves, full tiles: no
  mirrored ones), with the game's overlay laid over them -- (backdrop AND mask) OR
  pixels, a column's pixels then its mask, staged in SPRX.  The placement entry's last
  two bytes carry the object's tile (x | y << 8; an image's are 0); `bakekind.bin` gives each baked slot its kind
  and `bakegeom.bin` each kind's shape (bytes, lines, the offset from (8x, y) in game
  pixels across and tile rows down, the overlay's offset in SPRX).  imgtab stops at
  BAKEITEM0.  Cleo bakes every trampoline's rest state and its costliest stars: 309
  items over the 16 levels, 0.2-0.34 s of the Model B's CPU a load, nothing on the disc.
- **GAMEHAZEL.**  master.cfg's HAZ area ($C000-$DFFF) takes HAZCODE, HAZDATA and
  HAZBSS into `hazel.bin`, a BANKS piece with bank byte 1, which the loader copies
  with ACCCON Y set and leaves set for good.  `ldprog.s`'s `mainram` keeps Y, and
  SPRX is staged from the disc every load (no keep/unkeep).  With Y set throughout,
  the interrupt path (the hardware vector, the MOS's entry, IRQ1V) works on the
  Master (MOS 3.20, on jsbeeb: the MOS's entry code is not under HAZEL, whatever
  ldprog.s's comment on keep/unkeep says).
- **GAMESOUND.**  The vsync's `jsr sound_tick` becomes `jsr hook_sound`, followed by
  sound_tick's last act (`MUSON` to `MUSTICK`, the tune's step); `sound_tick` and the
  game's `sfxtab` are not assembled.
- **DRAWFLAGS.**  `draw_sprites` stores SPR_XH in the record as it is (so a flip is a
  change to `match_sprites`), takes bit 7 into `sp_dfl` (a zero-page byte) and gives
  the prologue x without it; `drawsprite` takes `sp_dfl` as the flags, XORed into
  `SPRG_FL`'s with SPRGFL.
- **TALLMAP.**  `wcyh` (zero page) and `drawrect`'s full map row: *The display*.
- **TIGHTBSS.**  The sprite records are nine arrays of 2 x MAXREC bytes (engine/defs.s:
  `REC_ID`, `REC_XL`, `REC_XH`, `REC_YL`, `REC_YH`, `REC_CX` the column's low byte,
  `REC_CY`, `REC_W`, `REC_H` = height | column high bits << 5 | clipped << 7; BUFROWS
  < 32 asserted), buffer 0's records then buffer 1's, indexed by register: `recb`
  (recp's byte) is the current buffer's first, `rq` (rp's) the record in hand, which
  `draw_sprites` steps and the prologue writes the rectangle at (`tmp3` its scratch); `match_sprites` walks Y with X, `erase_old` steps `rq`.  The
  dirty list likewise: `DIRTX` then `DIRTY_`, DIRTYMAX a buffer.  build.sh drops
  ENGBSS's `align = $100` from the linked cfg.
- **MAXSPR.**  build.sh passes `-D MAXSPRDEF=n`; engine/defs.s defaults MAXSPRDEF to 28
  when neither the build nor assets.inc sets it.
- **TILEMIRROR** (the oldest): the tile blitter's mirrored tiles, *The tiles*.

## Timing

A standard 312-line frame is 39,936 cycles at 2 MHz.  How often the game renders is
the game's: it waits on `vsyncs` (the interrupt counts them) and calls `render_frame`,
which waits for the previous frame's flip; a flip is taken at a vsync at least two
after the last.  `frame_top`, the game's label, is reached exactly once per rendered
frame, before the game's logic reads the keys: the test harness breaks there.

Per frame, bank 7 crosses once a sprite and once a tile rectangle through `callbank`,
twice into bank 6 (`selbb`, `validate`), and `drawrect` once a tile row through
`mapstrip`.

## The 6502 spellings

The engine (and a game, if it likes) is written once, with 65C02 idioms spelt as macros
(`cpu.inc`) that expand for the 6502.  Their contracts:

- `stz`: A is dead at the site (the 6502 form is `lda #0 / sta`); where A must
  survive, `stza`.
- `inca`/`deca`: the carry is preserved (through `mtmp`), because the sprite prologue
  relies on it.
- `ldaz`/`staz`/`andz`/`cmpz`, (zp) with no index: Y is destroyed; the site with Y
  live spells `ldazy`.
- `bitimm`: Z from A & v, A and X kept, through `mtmp`.
- `jmpx`: `jmp (abs,x)` through the zero-page vector `jv`.
- Nothing the interrupt runs may use `inca`, `deca`, `bitimm` or `ldazy` (they share
  `mtmp`).

**Anonymous labels.**  The sources use ca65's `:`/`:+`/`:-` labels heavily, and several
bare `:` lines are kept, unreferenced, only to hold the count: deleting a line that
starts with `:` retargets every `:+`/`:++` that jumps across it, and on a cold path no
test will notice.

## Testing

`test/lib/harness.mjs` drives jsbeeb frame-exactly: every wait is "run to the next
`frame_top`" (a label the game places where it is reached once a rendered frame,
before its logic reads the keys), never a poll of cycles, which would let key timing
drift with code size.  A break waits for the label's bank and, in bank 7, its image
(the kernel's `ld_img`); `fingerprint()` hashes every input to `render_frame`'s cost
(the engine's state and the game's, `gameScene`), so frame costs are only compared
between like scenes.  `test/lib/boards.mjs` emulates the Watford and Solidisk
write-select boards on jsbeeb, counting every store into sideways RAM that reaches a
bank other than the one paged.  `tools/pagecheck.py` lists every branch that crosses
a page; `tools/layoutcheck.py` fails the build if the two machines' data do not lie
alike.  A game's own tests compare a build with a reference, level by level, on both
machines.
