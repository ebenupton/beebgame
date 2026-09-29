; ---------------------------------------------------------------- zero page
  .if BHW
        .segment "ZPHW": zeropage   ; (one machine's own zero page, after the shared)
jv:       .res 2                  ; jmp (abs,x) has no 6502 form: it goes through here
  .endif
        .zeropage
ptr:      .res 2                  ; general pointer
tp:       .res 2                  ; tile/source pointer
sp:       .res 2                  ; screen pointer
tmp:      .res 1
tmp2:     .res 1
tmp3:     .res 1
tmp4:     .res 1
cnt:      .res 1
w16:      .res 2                  ; scratch words
w16b:     .res 2

; window (map coords) for the frame being rendered
wx:       .res 2                  ; window x in game pixels, map coordinates (even)
wy:       .res 2                  ; window y in game pixels, map coordinates
wcx:      .res 2                  ; window x in map chars (wx/2)
wcy:      .res 1                  ; window y in map char rows (wy/4)
  .if TALLMAP
wcyh:     .res 1                  ; and its high bits (TALLMAP: a map past 256 char rows)
  .endif
wfine:    .res 1                  ; fine scanline offset 0,2,4,6
curbuf:   .res 1                  ; buffer being drawn: 0 = main, 1 = shadow
recp:     .res 2                  ; current buffer's sprite record base
rp:       .res 2                  ; current record

; drawrect args
rc_x:     .res 2
rc_y:     .res 1
rc_w:     .res 1
rc_h:     .res 1
rc_sub:   .res 1
rc_gi:    .res 1
rc_lim:   .res 1                  ; the chars this run may take: 4 - its first char in the tile
rowoff:   .res 1                  ; rc_sub | (4 - rc_lim)*8 : byte offset into the tile for this run
rc_n:     .res 1
rc_tx0:   .res 1                  ; per-rect invariants: first tile column,
rc_nt:    .res 1                  ;   tiles-1 per row,
rc_sc0:   .res 1                  ;   4 - (rc_x & 3): the first tile's chars (rc_lim's first),
rc_ro0:   .res 1                  ;   (rc_x & 3) << 3,
rc_sp:    .res 2                  ;   screen address of the current char row's first char
irq_x:    .res 1                  ; IRQ handler register save (not reentrant)
irq_y:    .res 1

; sprite draw
spx:      .res 2
spy:      .res 2
LDZP:                             ; (the loader's zero page, 17 bytes: ldprog.s -- the
sp_ptr:   .res 2                  ;  prologue's scratch below is dead while a load runs)
sp_w:     .res 1
sp_lines: .res 1
sp_ext:   .res 1                  ; height in scanlines (2*lines for half-res)
sp_flags: .res 1
tmp4c8:   .res 1                  ; copy_partial: the column's byte offset within a row
sp_dbank: .res 1                  ; the bank the sprite's DATA is in: selected once the
                                  ;   prologue has finished reading the directory
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_rb:    .res 2                  ; screen address of the current row's first char
sp_rp:    .res 2                  ; source pointer for the current row (col base + row offset)
sp_rinc:  .res 1                  ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                  ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                  ; sprite column countdown
        .assert sp_rp - LDZP >= 17, error, "the loader's zero page runs past the prologue's scratch"
                                  ; the mask walk aliases zp the blit no longer needs;
                                  ; the rest of it is defs.inc's (sp_mh, sp_mrp...)
mptr    = w16                    ; this column group's mask bytes, one per game-pixel row
mtab    = tmp3                    ; MASKTAB page for this column's phase (tmp3 = 0, tmp4 = page)
sp_msk  = tmp4c8                  ; the AND mask of the pair being drawn
sp_id   = sp_ext                  ; the sprite id, until sp_ext is set a few lines later
spi:      .res 1
  .if DRAWFLAGS
sp_dfl:   .res 1                  ; draw_sprites' flags for the sprite: 1 = mirror it
  .endif
lcnt:     .res 1
lidx:     .res 1
ringS:    .res 2                  ; window start char S (0..RINGCHARS-1)
barq:     .res 1                  ; row slot q = S/80

; level geometry
maplw:    .res 1                  ; log2 map width in tiles
maplh:    .res 1
mapw:     .res 2                  ; map width in game pixels
maph:     .res 2
maxwx:    .res 2                  ; mapw - WINPX
maxwy:    .res 2                  ; maph - VISLINES/2

; misc
vsyncs:   .res 1                  ; counted by the vsync interrupt
flipreq:  .res 1                  ; 1 = flip pending
flipvs:   .res 1
keys:     .res 1                  ; current key bits
mapptr:   .res 2                  ; maprow's: a map row's address (bank 5)
SFXPTR:   .res 2
MUSPTR:   .res 2
  .if BHW                           ; the arithmetic gather's shape (gather5; the loader's,
        .segment "ZPHW": zeropage
half0:     .res 1                   ; per level): the Model B's hottest scalars (the Master's
half1:     .res 1                   ; gather is its table, LV_PAGE0).  The level's half
half2:     .res 1                   ; tiles: first id, the two range boundaries (bottom
halfhi5:   .res 1                   ; fills from half1, rowpairs from half2), the halves'
halfsub:   .res 1                   ; page, and half0 less the first half's slot in it
        .zeropage
  .endif

; ---------------------------------------------------------------- the MOS's zero page
; $F0-$FF is the MOS's, but once the game has the machine only $F4 (ROMSEL's copy, which
; the interrupt restores) and $FC (where the MOS's interrupt entry keeps A) are touched.
; The rest holds the hottest scalars that were absolute (the game's hot-variable count -- Cleo's test/hotvars.mjs: a cycle and
; a byte an access); start-up zeroes it (init.s).  Defined here, ahead of their uses,
; so every access is assembled as zero page.
        .segment "ZPF0": zeropage   ; $F0-$F3
MAPSTRIDE: .res 2                   ; bytes per map row (1 << lw): drawrect's row step
mapshr:    .res 1                   ; 8 - lw (maprow, maprow6): both the loader's
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

; ---------------------------------------------------------------- tables (uninitialised)
; Each table lives in the bank of the code that reads it, and only what more than one
; bank touches is in low RAM.  The mask tables are static data at a fixed address in
; both sprite banks (MASKTAB0, SWAPTAB in src/defs.inc); sprmul5 and the row tables
; are static too.
        .segment "TILBSS"           ; bank 6: the tile blitter's and the ring work's (the
                                    ; gather's arrays are low RAM's); boot zeroes it
        .assert FLAT0 + NFLAT + 2 = 256, error, "the fills are the ids from FLAT0 to 255: NFLAT flat tiles, then the two solids (assets.inc)"
FLATTAB:   .res 2*(NFLAT+2)         ; the level's flat tiles: (even line, odd line) by
                                    ; id - FLAT0, the loader's; the solids are the last two
        .segment "ENGBSS"           ; bank 7: mark_dirty and draw_dirty are there
DIRTYLIST: .res 2*2*DIRTYMAX
  .if TIGHTBSS                      ; (as two arrays, x then y: buffer 0's DIRTYMAX, then 1's)
DIRTX     = DIRTYLIST
DIRTY_    = DIRTYLIST+2*DIRTYMAX
  .endif
        .segment "LOWBSS"           ; main RAM: the buffers' state bank 7 reads too
BUF_CY:    .res 2                   ; each buffer's window char row, by curbuf
BUF_CX:    .res 2                   ; each buffer's window x by curbuf: low bytes,
BUF_CXH:   .res 2                   ; high bytes (bank 7 invalidates a buffer: $80)
BUF_BOTOK: .res 2                   ; the slot below the playfield is black: scroll_validate
                                    ; (bank 6) clears it, blank_below (bank 7) sets it
DIRTYCNT:  .res 2                   ; (the game loop)
PBANK:     .res 4                   ; the physical bank of each of banks 4..7 (the loader's:
                                    ; cpu.inc -- read by what the loader cannot patch)
PBOARD:    .res 1                   ; and the board: BOARD_STD / WATFORD / SOLIDISK (defs.inc),
                                    ; right after PBANK (boot copies the five together)
        .segment "ENGBSS"           ; bank 7: the sprite prologue's records
SPRREC:    .res 2*MAXREC*RECSZ
RECCNT:    .res 2
KEEP:      .res MAXREC
    .if BHW
        .segment "KRNHW"            ; (after the shared: on the Master these are TABLES')
BUF_SEC0:  .res 4
BUF_SEC0T1: .res 4
SECTAB:    .res 2*48
    .else
        .segment "TABLES"           ; the Master: the interrupt handler and its chain
BUF_SEC0:  .res 4                   ; are in main RAM, and so is what they keep
BUF_SEC0T1: .res 4
SECTAB:    .res 2*48
dispD:     .res 1
DSECT:     .res 1                   ; the step after the bar's: the one that switches D
NEXTBUF:   .res 1
    .endif
        .segment "LOWBSS"           ; main RAM: what more than one bank touches
SPRLIST:                          ; (a label, not an equate: the tools read labels.txt)
SPR_ID:    .res MAXSPR            ; the sprite draw list, one array per field (index =
SPR_XL:    .res MAXSPR            ;  the sprite's number, so no stride to multiply by):
SPR_XH:    .res MAXSPR            ;  id, x lo/hi, y lo/hi in game pixels (map coordinates)
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
DISPSECT:  .res 1
NEXTSECT:  .res 1

