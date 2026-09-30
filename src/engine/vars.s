; ============================================================================
; engine/vars.s -- the engine's variables: zero page and the tables
;
; Included by engine.s after defs.s, on both machines.  Storage only (.res), plus the
; equates that alias it.  Where a variable lives is decided by who reads and writes it:
;
;   ZEROPAGE   $00-   the shared zero page: scratch, the window, drawrect's and the
;                     sprite draw's arguments, the level's geometry, the vsync's counts
;   ZPHW       after  one machine's own zero page (the Model B's: jv, the gather's
;                     halves), linked after the shared; the game's ZPGAME follows it
;   ZPF0/F5/FD $F0-   the MOS's zero page, free once the game has the machine
;   TILBSS     bank 6 the tile blitter's own (FLATTAB)
;   ENGBSS     bank 7 the game loop's and the sprite prologue's (dirty lists, records)
;   LOWBSS     $0140- low RAM, visible whatever bank is paged in: what more than one
;                     bank touches, and what the interrupt stores
;   KRNHW      bank 7 the Model B's chain tables, at the top, with its interrupt body
;   TABLES     $0C00  the Master's chain tables, in main RAM with its interrupt handler
;
; The write-bank rule (cpu.inc): the write bank is bank 7's, but for short windows,
; and the interrupt stores into no bank.  So what the interrupt WRITES is in zero page
; or low RAM (or, on the Master, TABLES in main RAM), never in a sideways bank; the
; Model B's chain tables in bank 7 are only READ by it.
; ============================================================================

; ============================================================================
; Zero page
; ============================================================================

; ---------------------------------------------------------------- the Model B's own
; (ZPHW: one machine's own zero page, linked after the shared)
  .if BHW
        .segment "ZPHW": zeropage
jv:       .res 2                  ; jmpx's vector: jmp (abs,x) has no 6502 form (cpu.inc)
MTO:      .res 4                  ; drawrect's solid-chain offsets, by chars (1..4): 72, 48,
                                  ;  24, 0 (boot's) -- in zero page, a byte shorter to read
                                  ;  than a table, which keeps @run's bmi @tile in reach
  .endif

; ---------------------------------------------------------------- scratch
        .zeropage
ptr:      .res 2                  ; general pointer
tp:       .res 2                  ; tile/source pointer
sp:       .res 2                  ; screen pointer
tmp:      .res 1
tmp2:     .res 1
tmp3:     .res 1
tmp4:     .res 1
cnt:      .res 1
w16:      .res 2                  ; scratch word
w16b:     .res 2                  ; scratch word

; ---------------------------------------------------------------- the window
; The window (map coordinates) for the frame being rendered, and the buffer it is
; rendered into.
wx:       .res 2                  ; window x in game pixels, map coordinates (even)
wy:       .res 2                  ; window y in game pixels, map coordinates
wcx:      .res 2                  ; window x in map chars (wx/2)
wcy:      .res 1                  ; window y in map char rows (wy/4)
  .if TALLMAP
wcyh:     .res 1                  ; wcy's high bits (TALLMAP: a map past 256 char rows)
  .endif
wfine:    .res 1                  ; fine scanline offset 0,2,4,6
curbuf:   .res 1                  ; buffer being drawn: 0 = main, 1 = shadow
recp:     .res 2                  ; current buffer's sprite record base
rp:       .res 2                  ; current record

; ---------------------------------------------------------------- drawrect's arguments
; The tile blitter (bank 6, tiles.s).
rc_x:     .res 2
rc_y:     .res 1
rc_w:     .res 1
rc_h:     .res 1
rc_sub:   .res 1
rc_gi:    .res 1
rc_lim:   .res 1                  ; chars this run may take: 4 - its first char in the tile
rowoff:   .res 1                  ; byte offset into the tile for this run:
                                  ;  rc_sub | (4 - rc_lim)*8
rc_n:     .res 1
; per-rect invariants
rc_tx0:   .res 1                  ; first tile column
rc_nt:    .res 1                  ; tiles-1 per row
rc_sc0:   .res 1                  ; 4 - (rc_x & 3): the first tile's chars (rc_lim's first)
rc_ro0:   .res 1                  ; (rc_x & 3) << 3
rc_sp:    .res 2                  ; screen address of the current char row's first char

; ---------------------------------------------------------------- the interrupt's
irq_x:    .res 1                  ; IRQ handler's X save (not reentrant)
irq_y:    .res 1                  ; IRQ handler's Y save

; ---------------------------------------------------------------- the sprite draw
; The sprite prologue (bank 7, frame.s) sets these up; the row loops (banks 4 and 5,
; sprloops.s) run on them.
spx:      .res 2
spy:      .res 2
; LDZP: the loader's zero page, 17 bytes from here (ldprog.s): the prologue's scratch
; below is dead while a load runs.
LDZP:
sp_ptr:   .res 2
sp_w:     .res 1
sp_lines: .res 1
sp_ext:   .res 1                  ; height in scanlines (2*lines for half-res)
sp_flags: .res 1
tmp4c8:   .res 1                  ; copy_partial: the column's byte offset within a row
sp_dbank: .res 1                  ; the bank the sprite's DATA is in: selected once the
                                  ;  prologue has finished reading the directory
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_rb:    .res 2                  ; screen address of the current row's first char
sp_rp:    .res 2                  ; source pointer for the current row:
                                  ;  column base + row offset
sp_rinc:  .res 1                  ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                  ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                  ; sprite column countdown
        .assert sp_rp - LDZP >= 17, error, "the loader's zero page runs past the prologue's scratch"
; Aliases of zero page the blit no longer needs:
sp_msk  = tmp4c8                  ; the AND mask of the pair being drawn
sp_id   = sp_ext                  ; the sprite id, until sp_ext is set a few lines later
spi:      .res 1                  ; draw_sprites: the sprite's number (X in its loop)
  .if DRAWFLAGS
sp_dfl:   .res 1                  ; draw_sprites' flags for the sprite: 1 = mirror it
  .endif
lcnt:     .res 1                  ; frame.s: records to look at
lidx:     .res 1                  ; frame.s: the record index, stepped from recb

; ---------------------------------------------------------------- the ring
ringS:    .res 2                  ; window start char S (0..RINGCHARS-1)
barq:     .res 1                  ; row slot q = S/80

; ---------------------------------------------------------------- level geometry
maplw:    .res 1                  ; log2 map width in tiles
maplh:    .res 1
mapw:     .res 2                  ; map width in game pixels
maph:     .res 2
maxwx:    .res 2                  ; mapw - WINPX
maxwy:    .res 2                  ; maph - VISLINES/2

; ---------------------------------------------------------------- misc
vsyncs:   .res 1                  ; counted by the vsync interrupt
flipreq:  .res 1                  ; 1 = flip pending
flipvs:   .res 1                  ; vsyncs at the last flip: the next waits 2 vsyncs
keys:     .res 1                  ; current key bits
mapptr:   .res 2                  ; maprow's: a map row's address (bank 5)
SFXPTR:   .res 2
MUSPTR:   .res 2

; ---------------------------------------------------------------- the Model B's gather
; The arithmetic gather's shape (gather5; the loader's, per level): the Model B's
; hottest scalars (the Master's gather is its table, LV_PAGE0).  The level's half
; tiles: the first id, the two range boundaries (bottom fills from half1, rowpairs
; from half2), the halves' page, and half0 less the first half's slot in it.
  .if BHW
        .segment "ZPHW": zeropage
half0:     .res 1                   ; the first half tile's id
half1:     .res 1                   ; bottom fills from here
half2:     .res 1                   ; rowpairs from here
halfhi5:   .res 1                   ; the halves' page
halfsub:   .res 1                   ; half0 less the first half's slot in the page
        .zeropage
  .endif

; ---------------------------------------------------------------- the MOS's zero page
; $F0-$FF is the MOS's, but once the game has the machine only $F4 (ROMSEL's copy,
; which the interrupt restores) and $FC (where the MOS's interrupt entry keeps A) are
; touched.  The rest holds the hottest scalars that were absolute (the game's
; hot-variable count -- Cleo's test/hotvars.mjs: a cycle and a byte an access);
; start-up zeroes it (init.s).  Defined here, ahead of their uses, so every access is
; assembled as zero page.
        .segment "ZPF0": zeropage   ; $F0-$F3
MAPSTRIDE: .res 2                   ; bytes per map row (1 << lw): drawrect's row step
mapshr:    .res 1                   ; 8 - lw (maprow): the loader's, as MAPSTRIDE
MUSTICK:   .res 1                   ; a frame's tune step is due: the vsync's sound_tick
        .segment "ZPF5": zeropage   ; $F5-$FB
rowbit:    .res 1                   ; the char row being drawn, as a flag bit (1, 2)
dpass:     .res 1                   ; draw_sprites' pass
spclip:    .res 1                   ; set at every window edge a sprite is cut against
halfhi:    .res 1                   ; the halves' page less 1 (the loader's), for @hfill
        .segment "ZPFD": zeropage   ; $FD-$FF
MUSON:     .res 1                   ; the tune plays: the interrupt stub steps it
crtcb:     .res 2                   ; build_sections: the buffer's CRTC base
        .zeropage

; ============================================================================
; Tables (uninitialised)
;
; Each table lives in the bank of the code that reads it, and only what more than one
; bank touches is in low RAM.  The expansion tables and SWAPTAB are static data at a
; fixed address in both sprite banks (defs.inc); sprmul5 and the row tables are
; static too.
; ============================================================================

; ---------------------------------------------------------------- TILBSS: bank 6
; The tile blitter's and the ring work's (the gather's arrays are low RAM's); boot
; zeroes it.
        .segment "TILBSS"
        .assert FLAT0 + NFLAT + 2 = 256, error, "the fills are the ids from FLAT0 to 255: NFLAT flat tiles, then the two solids (assets.inc)"
; FLATTAB: the level's flat tiles (the loader's), a pair (even line, odd line) for
; each id - FLAT0; the solids are the last two.
FLATTAB:   .res 2*(NFLAT+2)

; ---------------------------------------------------------------- ENGBSS: bank 7
; mark_dirty and draw_dirty are in bank 7.
        .segment "ENGBSS"
DIRTYLIST: .res 2*2*DIRTYMAX        ; each buffer's dirty tiles (x, y)
  .if TIGHTBSS
; TIGHTBSS: as two arrays, x then y, each buffer 0's DIRTYMAX then buffer 1's.
DIRTX     = DIRTYLIST
DIRTY_    = DIRTYLIST+2*DIRTYMAX
  .endif

; ---------------------------------------------------------------- LOWBSS: the buffers
; Main RAM: the buffers' state, which bank 7 reads too.
        .segment "LOWBSS"
BUF_CY:    .res 2                   ; each buffer's window char row, by curbuf
BUF_CX:    .res 2                   ; each buffer's window x, by curbuf: low bytes
BUF_CXH:   .res 2                   ; high bytes (bank 7 invalidates a buffer: $80)
; BUF_BOTOK: the slot below the playfield is black.  scroll_validate (bank 6) clears
; it, blank_below (bank 7) sets it.
BUF_BOTOK: .res 2
DIRTYCNT:  .res 2                   ; each buffer's dirty tiles queued (the game loop)
; PBANK: the physical bank of each of banks 4..7 (the loader's: cpu.inc -- read by
; what the loader cannot patch).  PBOARD: the board, BOARD_STD / WATFORD / SOLIDISK
; (defs.inc), right after PBANK: boot copies the five together.
PBANK:     .res 4
PBOARD:    .res 1

; ---------------------------------------------------------------- ENGBSS: the records
; Bank 7: the sprite prologue's records (the layout: defs.s, RECSZ).
        .segment "ENGBSS"
SPRREC:    .res 2*MAXREC*RECSZ      ; buffer 0's records, then buffer 1's
RECCNT:    .res 2                   ; records per buffer
KEEP:      .res MAXREC              ; match_sprites: is sprite i what record i shows?

; ---------------------------------------------------------------- the rupture chain
; The chain's tables sit with the interrupt that reads them.
    .if BHW
; Model B: KRNHW, bank 7, with isr_body (after the shared; on the Master these are
; TABLES').  build_sections writes them from bank 7; the interrupt only reads them.
        .segment "KRNHW"
BUF_SEC0:  .res 4                   ; each buffer's section 0 (the bar): CRTC address
BUF_SEC0T1: .res 4                  ; and its T1 count
SECTAB:    .res 2*48                ; each buffer's chain (kernel.s build_sections)
    .else
; Master: TABLES, main RAM.  The interrupt handler and its chain are in main RAM, and
; so is what they keep.
        .segment "TABLES"
BUF_SEC0:  .res 4                   ; each buffer's section 0 (the bar): CRTC address
BUF_SEC0T1: .res 4                  ; and its T1 count
SECTAB:    .res 2*48                ; each buffer's chain (kernel.s build_sections)
dispD:     .res 1                   ; ACCCON D for the displayed buffer's playfield
DSECT:     .res 1                   ; the step after the bar's: the one that switches D
NEXTBUF:   .res 1                   ; the buffer the next flip shows (-> dispD)
    .endif

; ---------------------------------------------------------------- LOWBSS: the sprite list
; Main RAM: what more than one bank touches.
        .segment "LOWBSS"
; The sprite draw list, one array per field (index = the sprite's number, so no
; stride to multiply by): id, x lo/hi, y lo/hi in game pixels (map coordinates).
; SPRLIST is a label, not an equate: the tools read labels.txt.
SPRLIST:
SPR_ID:    .res MAXSPR
SPR_XL:    .res MAXSPR
SPR_XH:    .res MAXSPR
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
; The flip: the frame hands over its chain (NEXTSECT, 0 or 48: SECTAB's offset) and the
; vsync makes it the displayed one.  DISPSECT is the interrupt's store, so low RAM.
DISPSECT:  .res 1                   ; the displayed buffer's chain (vsync)
NEXTSECT:  .res 1                   ; the chain the next flip shows (the frame)
