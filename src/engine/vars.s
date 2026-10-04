; ============================================================================
; engine/vars.s -- the engine's variables: zero page and the tables
;
; Included by engine.s after defs.s, on both machines.  Storage only (.res), plus the
; equates that alias it.  Where a variable lives is decided by who reads and writes it:
;
;   ZEROPAGE   $00-   the shared zero page: scratch, the window, draw_rect's and the
;                     sprite draw's arguments, the level's geometry, the vsync's counts
;   ZPTOP      $FD-   zero page's last three bytes: ROMSEL_CPY, crtcb ($FC: the ROM's interrupt entry's)
;   TILBSS     bank 6 the tile blitter's own (FLATTAB)
;   ENGBSS     bank 7 the game loop's and the sprite prologue's (dirty lists, records)
;   LOWBSS     $0140- low RAM, visible whatever bank is paged in: what more than one
;                     bank touches, and what the interrupt stores
;   KRNHW      bank 7 the Model B's chain tables, at the top, with its interrupt body
;   MRAMBSS     $0C00  the Master's chain tables, in main RAM with its interrupt handler
;
; The write-bank rule (cpu.inc): the write bank is bank 7's, but for short windows,
; and the interrupt stores into no bank.  So what the interrupt WRITES is in zero page
; or low RAM (or, on the Master, MRAMBSS in main RAM), never in a sideways bank; the
; Model B's chain tables in bank 7 are only READ by it.
; ============================================================================

; ============================================================================
; Zero page
; ============================================================================

; ---------------------------------------------------------------- each machine's own
; Zero page is laid out alike on both machines (tools/layoutcheck.py fails the build
; otherwise): what only one machine uses is reserved on the other too.
        .zeropage
jv:       .res 2                   ; (Model B) a jmp (abs,x) dispatch's vector: the 6502 has no such form (the game's process_object)
crtcbm:   .res 2                   ; (Model B) the buffer being built: its mirror redirect
                                  ;  (base - RINGCHARS; its CRTC base, crtcb, is zero page's)
qsect:    .res 1                   ; Q's step: the Model B's blacks the palette for its first
                                  ;  scanline (kernel.s, the vsync's from BUF_QS); the
                                  ;  Master's puts D back to 0
ksect:    .res 1                   ; (Model B) or, behind a two-line P2, P2's step does, at its
                                  ;  end (the vsync's from BUF_KS; $FF: neither)
palon:    .res 1                   ; (Model B) the palette is lit (set_palette; blank_palette
                                  ;  clears it): the vsync puts Q's blacked colours back

; ---------------------------------------------------------------- scratch
        .zeropage
ptr:      .res 2                   ; general pointer
tp:       .res 2                   ; tile/source pointer
sp:       .res 2                   ; screen pointer
tmp:      .res 1
tmp2:     .res 1
; The flip and the interrupt's hottest (profiled: test/hotvars.mjs).  The frame hands
; over its chain (next_sect, 0 or 48: SECTAB's offset) and the vsync makes it the
; displayed one (disp_sect); the interrupt reads load_req at every step.  Zero page is
; main RAM, so the interrupt still stores into no bank.
disp_sect: .res 1                  ; the displayed buffer's chain (vsync)
next_sect: .res 1                  ; the chain the next flip shows (the frame)
load_req:  .res 1                  ; 0 running, 1 stop asked, 2 stopped, 3 resume asked (load_begin)
sfx_dur:   .res 1                  ; the sound effect's steps to go (sound_tick)
tmp3:     .res 1
tmp4:     .res 1
cnt:      .res 1
w16:      .res 2                   ; scratch word
w16b:     .res 2                   ; scratch word

; ---------------------------------------------------------------- the window
; The window (map coordinates) for the frame being rendered, and the buffer it is
; rendered into.
wx:       .res 2                   ; window x in game pixels, map coordinates (even)
wy:       .res 2                   ; window y in game pixels, map coordinates
wcx:      .res 2                   ; window x in map chars (wx/2)
wcy:      .res 1                   ; window y in map char rows (wy/4)
  .if TALLMAP
wcyh:     .res 1                   ; wcy's high bits (TALLMAP: a map past 256 char rows)
  .endif
wfine:    .res 1                   ; fine scanline offset 0,2,4,6
cur_buf:   .res 1                  ; buffer being drawn: 0 = main, 1 = shadow
recp:     .res 2                   ; current buffer's sprite record base
rp:       .res 2                   ; current record

; ---------------------------------------------------------------- draw_rect's arguments
; The tile blitter (bank 6, tiles.s).
rc_x:     .res 2
rc_y:     .res 1
rc_w:     .res 1
rc_h:     .res 1
rc_sub:   .res 1
rc_gi:    .res 1
rc_lim:   .res 1                   ; chars this run may take: 4 - its first char in the tile
row_off:   .res 1                  ; byte offset into the tile for this run:
                                  ;  rc_sub | (4 - rc_lim)*8
; per-rect invariants
rc_tx0:   .res 1                   ; first tile column
rc_nt:    .res 1                   ; tiles-1 per row
rc_sc0:   .res 1                   ; 4 - (rc_x & 3): the first tile's chars (rc_lim's first)
rc_ro0:   .res 1                   ; (rc_x & 3) << 3
rc_sp:    .res 2                   ; screen address of the current char row's first char

; ---------------------------------------------------------------- the interrupt's
irq_x:    .res 1                   ; IRQ handler's X save (not reentrant)
irq_y:    .res 1                   ; IRQ handler's Y save

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
sp_ext:   .res 1                   ; height in scanlines (2*lines for half-res)
sp_flags: .res 1
sp_msk:   .res 1                   ; copy_partial: the column's byte offset within a row
sp_dbank: .res 1                   ; the bank the sprite's DATA is in: selected once the
                                  ;  prologue has finished reading the directory
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_rb:    .res 2                   ; screen address of the current row's first char
sp_rp:    .res 2                   ; source pointer for the current row:
                                  ;  column base + row offset
sp_rinc:  .res 1                   ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                   ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                   ; sprite column countdown
        .assert sp_rp - LDZP >= 17, error, "the loader's zero page runs past the prologue's scratch"
spi:      .res 1                   ; draw_sprites: the sprite's number (X in its loop)
  .if DRAWFLAGS
sp_dfl:   .res 1                   ; draw_sprites' flags for the sprite: 1 = mirror it
  .endif
lcnt:     .res 1                   ; frame.s: records to look at
lidx:     .res 1                   ; frame.s: the record index, stepped from recb

; ---------------------------------------------------------------- the ring
ring_s:    .res 2                  ; window start char S (0..RINGCHARS-1)
barq:     .res 1                   ; row slot q = S/80

; ---------------------------------------------------------------- level geometry
maplw:    .res 1                   ; log2 map width in tiles
maplh:    .res 1
mapw:     .res 2                   ; map width in game pixels
maph:     .res 2
maxwx:    .res 2                   ; mapw - WINPX
maxwy:    .res 2                   ; maph - VISLINES/2

; ---------------------------------------------------------------- misc
vsyncs:   .res 1                   ; counted by the vsync interrupt
flip_req:  .res 1                  ; 1 = flip pending
flipvs:   .res 1                   ; vsyncs at the last flip: the next waits 2 vsyncs
keys:     .res 1                   ; current key bits
map_ptr:   .res 2                  ; map_row's: a map row's address (bank 5)
sfx_ptr:   .res 2
mus_ptr:   .res 2

; ---------------------------------------------------------------- the Model B's gather
; The arithmetic gather's shape (gather5; the loader's, per level): the Model B's
; hottest scalars (the Master's gather is its table, LV_PAGE0).  The level's half
; tiles: the first id, the halves' page, and half0 less the first half's slot in it
; (their low bits are a table: gather.s HLOW).
half0:     .res 1                  ; (Model B) the first half tile's id
halfhi5:   .res 1                  ; (Model B) the halves' page
half_sub:   .res 1                 ; (Model B) half0 less the first half's slot in the page

; ---------------------------------------------------------------- the hot scalars
; (defined here, ahead of their uses, so every access is assembled as zero page)
map_stride: .res 2                 ; bytes per map row (1 << lw): draw_rect's row step
map_shr:    .res 1                 ; 8 - lw (map_row): the loader's, as map_stride
mus_tick:   .res 1                 ; a frame's tune step is due: the vsync's sound_tick
disp_d:     .res 1                 ; (Master) ACCCON D for the displayed buffer's playfield
dsect:     .res 1                  ; (Master) the step after the bar's: the one that switches D
next_buf:   .res 1                 ; (Master) the buffer the next flip shows (-> disp_d)
row_bit:    .res 1                 ; the char row being drawn, as a half's fill bit (8, 16)
dpass:     .res 1                  ; draw_sprites' pass
sp_clip:    .res 1                 ; set at every window edge a sprite is cut against
mus_on:     .res 1                 ; the tune plays: the interrupt stub steps it
        .segment "ZPTOP": zeropage  ; $FD-$FF ($FC: the ROM's interrupt entry keeps A there)
romsel_cpy: .res 1                 ; ROMSEL_CPY (defs.s: the code's equate, assembled as
        .assert romsel_cpy = ROMSEL_CPY, error, "ROMSEL_CPY: zero page's $FD"   ;  zero page wherever used; this label is the tools')
crtcb:     .res 2                  ; build_sections: the buffer's CRTC base
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
DIRTYLIST: .res 2*2*DIRTYMAX       ; each buffer's dirty tiles (x, y)
  .if TIGHTBSS
; TIGHTBSS: as two arrays, x then y, each buffer 0's DIRTYMAX then buffer 1's.
DIRTYX     = DIRTYLIST
DIRTYY    = DIRTYLIST+2*DIRTYMAX
  .endif

; ---------------------------------------------------------------- LOWBSS: the buffers
; Main RAM: the buffers' state, which bank 7 reads too.
        .segment "LOWBSS"
BUF_CY:    .res 2                  ; each buffer's window char row, by cur_buf
BUF_CXL:    .res 2                 ; each buffer's window x, by cur_buf: low bytes
BUF_CXH:   .res 2                  ; high bytes (bank 7 invalidates a buffer: $80)
; PBANK: the physical bank of each of banks 4..7 (the loader's: cpu.inc -- read by
; what the loader cannot patch).  pboard: the board, BOARD_STD / WATFORD / SOLIDISK
; (defs.inc), right after PBANK: boot copies the five together.
PBANK:     .res 4
pboard:    .res 1

; ---------------------------------------------------------------- ENGBSS: the records
; Bank 7: the sprite prologue's records (the layout: defs.s, RECSZ).
        .segment "ENGBSS"
SPRREC:    .res 2*MAXREC*RECSZ     ; buffer 0's records, then buffer 1's
RECCNT:    .res 2                  ; records per buffer
KEEP:      .res MAXREC             ; match_sprites: is sprite i what record i shows?
DIRTYCNT:  .res 2                  ; each buffer's dirty tiles queued (the game loop)
; The sprite draw list, one array per field (index = the sprite's number, so no
; stride to multiply by): id, x lo/hi, y lo/hi in game pixels (map coordinates).
; Only bank 7 touches it (add_sprite, the sprite prologue).  SPRLIST is a label, not
; an equate: the tools read labels.txt.
SPRLIST:
SPR_ID:    .res MAXSPR
SPR_XL:    .res MAXSPR
SPR_XH:    .res MAXSPR
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
        .assert >SPR_ID = >(SPR_YH+MAXSPR-1), warning, "the sprite list crosses a page: its indexed reads +1"

; ---------------------------------------------------------------- the rupture chain
; The chain's tables sit with the interrupt that reads them.
; With the interrupt handler that reads them (cpu.inc PLACEH): the Model B's KRNHW,
; bank 7, with isr_body (after the shared); the Master's MRAMBSS, main RAM, with its
; handler.  build_sections writes them from bank 7; the interrupt only reads them.
        PLACEH "MRAMBSS", "KRNHW"
BUF_SEC0:  .res 4                  ; each buffer's section 0 (the bar): CRTC address
BUF_SEC0T1: .res 4                 ; and its T1 count
SECTAB:    .res 2*48               ; each buffer's chain (kernel.s build_sections)
BUF_QS:    .res 3                  ; each buffer's Q entry (-> qsect), by 2 x the buffer
    .if BHW
BUF_KS:    .res 3                  ; and its two-line P2's (-> ksect); $FF for none
    .endif                         ;  (the Model B's palette kill: kernel.s)

