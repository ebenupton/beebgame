; ============================================================================
; engine/vars.s -- the engine's variables: zero page and the tables
;
; Included by engine.s after defs.s, on both machines.  Storage only (.res), with
; the asserts that bind it.  Where a variable lives is decided by who reads and
; writes it:
;
;   ZEROPAGE  $00-    the shared zero page: the engine's first (this file), then
;                     the game's (ZPGAME); scratch, the window, draw_rect's and the
;                     sprite draw's arguments, the ring, the level's geometry, the
;                     interrupt's counts
;   ZPTOP     $FD-    zero page's last three bytes: ROMSEL_CPY, crtcb ($FC is the
;                     MOS's: it keeps the interrupt's A there)
;   TILBSS    bank 6  the tile blitter's own (FLATTAB)
;   ENGBSS    bank 7  the renderer's: dirty lists, records, the sprite list
;   LOWBSS    $0140-  low RAM, visible whatever bank is paged in: the buffers'
;                     state, which banks 6 and 7 both touch, and the bank table
;   MRAMBSS   $0C00   the Master's chain tables, in main RAM with its handler
;   KRNHW     bank 7  the Model B's chain tables, at the top, with its handler body
;
; Zero page is laid out alike on both machines, every variable at one address
; (tools/layoutcheck.py fails the build otherwise): what one machine alone uses is
; reserved on the other too.  Order is address: a .res moved in this file moves every
; zero-page variable after it, on both machines.
;
; The write-bank rule (cpu.inc): the write bank is bank 7's but for short windows,
; and the interrupt stores into no bank.  So what the interrupt WRITES is in zero
; page or low RAM (or, on the Master, MRAMBSS in main RAM), never in a sideways
; bank; the Model B's chain tables in bank 7 are only READ by it.
; ============================================================================

; ============================================================================
; Zero page
; ============================================================================
        .zeropage

; ---------------------------------------------------------------- shared with the game
; Written by the game, read by the engine, or the other way (cpu.inc's mtmp too).
nspr:      .res 1                  ; the sprite list's length: add_sprite counts it
                                   ;  up; render_frame and the game's level start
                                   ;  zero it; draw_sprites, erase_old,
                                   ;  match_sprites read it
bar_dirty: .res 1                  ; the bar's digits want redrawing: the game sets
                                   ;  it (1); render_frame calls hook_hud and clears it
  .if .not SOUND6                  ; (the built-in player's: SOUND6's is sound6.s's)
sfx_req:   .res 1                  ; a sound effect to start, 1-based into sfx_tab:
                                   ;  the game sets it; sound_tick takes and clears it
  .endif
mtmp:      .res 1                  ; cpu.inc bitimm's scratch (the Model B's expansion)
ringbhi:   .res 1                  ; (Model B) the buffer being drawn, select_backbuf's:
ringehi:   .res 1                  ;  its ring's base page, its end page (the fold test
ringe3:    .res 1                  ;  of ringup, ringtest, pagestep), and its end page
                                   ;  - 3, the last slot's (mirror.s).  Read by
                                   ;  draw_rect, the row loop, ring_addr7, copy_partial
mrow:      .res 1                  ; (Model B) the map char row in the ring's last
                                   ;  slot: calc_ring writes it; draw_rect, draw_sprite
                                   ;  and mirror_copy read it (the mirror's row)
wcxm:      .res 1                  ; (Model B) ring_s mod 80: the window's start in its
                                   ;  slot, the mirror's first useful char.  calc_ring
                                   ;  writes it; MIRDIRTY_BODY and mirror_copy read it
sp_disp:   .res 1                  ; the sprite's blitter: its first entry in
                                   ;  sprrow_tab.  draw_sprite writes it; ds_rowloop
                                   ;  (sprloops.s) reads it
sp_g:      .res 1                  ; the sprite's shape, sprg_ix[id]: draw_sprite
                                   ;  stores it (nothing reads it back: Y holds it)
cur_r7:    .res 1                  ; the chain's R7, the row the vsync is on: a step
                                   ;  and the load switch write it, the vsync re-phases
                                   ;  from it; crtc_init sets LDR7 (kernel.s)
sec_idx:   .res 1                  ; the chain's step: the entry the next T1 programs
                                   ;  (SECTAB's offset).  The interrupt's alone

; ---------------------------------------------------------------- each machine's own
jv:        .res 2                  ; (Model B) a jmp (abs,x) dispatch's vector: the
                                   ;  6502 has no such form (the game's process_object)
crtcbm:    .res 2                  ; (Model B) the buffer being built: its mirror
                                   ;  redirect, crtcb - RINGCHARS (build_sections
                                   ;  writes and reads it: a straddling row's address)
qsect:     .res 1                  ; Q's step, SECTAB's offset: the vsync takes it
                                   ;  from BUF_QS; the Model B's blacks the palette
                                   ;  for Q's first scanline there, the Master's puts
                                   ;  D back to 0 (kernel.s)
ksect:     .res 1                  ; (Model B) or, behind a two-line P2, P2's step does
                                   ;  the kill (from BUF_KS; SECT_NONE: neither)
palon:     .res 1                  ; (Model B) the palette is lit: set_palette sets
                                   ;  it, blank_palette clears it; the vsync puts Q's
                                   ;  blacked colours back only while it is set

; ---------------------------------------------------------------- scratch
; Every bank's: the renderer's, the kernel's, the game's and the menus'.  Each caller
; owns what it uses only within a call; nothing survives a render step.
ptr:       .res 2                  ; a pointer: the row loop's source column,
                                   ;  draw_rect's map row, copy_partial's
                                   ;  destination, the game's
tp:        .res 2                  ; draw_rect's tile source, map_col's neighbours
                                   ;  (free outside a render), the game's
sp:        .res 2                  ; a screen pointer: draw_rect's run, the row loop's
                                   ;  char, ring_addr7's result
tmp:       .res 1                  ; the sprite draw's (frame.s, sprloops.s: the
tmp2:      .res 1                  ;  cell's first and last line), mark_dirty's,
                                   ;  build_sections' (tmp2: a run's rows), the
                                   ;  loaders', the menus'
; The flip and the interrupt's hottest (Cleo's test/hotvars.mjs profiles them).  The
; frame hands over its chain (next_sect, 0 or SECBYTES: SECTAB's offset) and the
; vsync makes it the displayed one (disp_sect); the interrupt reads load_req at
; every step.  Zero page is main RAM, so the interrupt still stores into no bank.
disp_sect: .res 1                  ; the displayed buffer's chain: the vsync's flip
                                   ;  writes it; the vsync and the load switch read it
next_sect: .res 1                  ; the chain the next flip shows: render_frame and
                                   ;  the menus write it; the vsync's flip reads it
load_req:  .res 1                  ; the load mode's state, LDR_RUN / LDR_STOP /
                                   ;  LDR_STOPPED / LDR_RESUME (defs.inc):
                                   ;  load_begin asks, the bar step stops, ldprog.s
                                   ;  asks the resume, the vsync runs again
  .if .not SOUND6
sfx_dur:   .res 1                  ; the sound effect's frames left in its step
                                   ;  (sound_tick's alone)
  .endif
tmp3:      .res 1                  ; build_sections' (a run's first ring row, @dur's
tmp4:      .res 1                  ;  high byte; the rows in a run), match_sprites'
                                   ;  and draw_sprite's, mirror_copy's, the game's
cnt:       .res 1                  ; draw_rect's chars left in the row (runn);
                                   ;  match_sprites' records to compare; the loader's
w16:       .res 2                  ; a scratch word: build_sections' ring offset, the
                                   ;  sprite's column, copy_partial's, scroll_validate's
w16b:      .res 2                  ;  dx, mirror_copy's pointers, the menus'

; ---------------------------------------------------------------- the window
; The window (map coordinates) for the frame being rendered, and the buffer it is
; rendered into.  The game sets wx, wy (clamp_window) and cur_buf's first value;
; render_frame derives wcx, wcy, wfine from them each frame and flips cur_buf.
wx:        .res 2                  ; window x in game pixels, map coordinates (even)
wy:        .res 2                  ; window y in game pixels, map coordinates
wcx:       .res 2                  ; window x in map chars: wx / 2
wcy:       .res 1                  ; window y in map char rows: wy / 4
  .if TALLMAP
wcyh:      .res 1                  ; wcy's high bits (TALLMAP: a map past 256 char rows)
  .endif
wfine:     .res 1                  ; the fine scroll, scanlines 0, 2, 4, 6: (wy & 3) * 2
cur_buf:   .res 1                  ; the buffer being drawn: 0 = ring A / main RAM,
                                   ;  1 = ring B / shadow RAM
recp:      .res 2                  ; the buffer's first sprite record (select_backbuf)
rp:        .res 2                  ; the current record (frame.s)

; ---------------------------------------------------------------- draw_rect's arguments
; The tile blitter's (bank 6, tiles.s): the callers set rc_x, rc_y, rc_w, rc_h
; (erase_old, draw_dirty through draw_rect_clip; scroll_validate), draw_rect the rest.
rc_x:      .res 2                  ; the rect: first map char column (16 bits),
rc_y:      .res 1                  ;  first map char row,
rc_w:      .res 1                  ;  chars wide (1..80),
rc_h:      .res 1                  ;  char rows (counted down as rows are drawn)
rc_sub:    .res 1                  ; the char row's offset in its tile: 0 or HALFBYTES
rc_gi:     .res 1                  ; the run's index into GATHERL/GATHERH
rc_lim:    .res 1                  ; the chars this run may take: rc_sc0 for a row's
                                   ;  first, TILECHARS after
row_off:   .res 1                  ; the run's byte offset into its tile: rc_sub |
                                   ;  (TILECHARS - rc_lim) * CHARBYTES
; the per-rect invariants, built once at draw_rect's head
rc_tx0:    .res 1                  ; the first tile column, rc_x / 4
rc_nt:     .res 1                  ; tiles - 1 in a row (gather5 reads it)
rc_sc0:    .res 1                  ; 4 - (rc_x & 3): the first run's chars
rc_ro0:    .res 1                  ; (rc_x & 3) << 3: the first run's byte offset
rc_sp:     .res 2                  ; the current char row's first char on screen

; ---------------------------------------------------------------- the interrupt's
irq_x:     .res 1                  ; the handler's X and Y saves (the stub's on the
irq_y:     .res 1                  ;  Model B, irq_handler's on the Master); not
                                   ;  reentrant

; ---------------------------------------------------------------- the sprite draw
; The sprite prologue (bank 7, frame.s draw_sprite) sets these up; the row loop
; (banks 4 and 5, sprloops.s) runs on them.
spx:       .res 2                  ; the sprite's reference point in game pixels, map
spy:       .res 2                  ;  coordinates: add_sprite's In (the game sets
                                   ;  them), and draw_sprites' for the prologue
; LDZP: the loader's zero page, 17 bytes from here (ldprog.s): the prologue's scratch
; below is dead while a load runs.
LDZP:
sp_ptr:    .res 2                  ; the image's address (the directory's)
sp_w:      .res 1                  ; its width in columns (sprg_w)
sp_lines:  .res 1                  ; its stored rows (sprg_ln): bytes a column
sp_ext:    .res 1                  ; its height in scanlines: sp_lines, doubled for a
                                   ;  half-res sprite (no SPF_FULLRES)
sp_flags:  .res 1                  ; its SPF_ flags
sp_msk:    .res 1                  ; the row loop's: the pair's transparency mask
                                   ;  (NMASK[b]), kept for the pair's second line
sp_dbank:  .res 1                  ; the bank the image is in, from the directory:
                                   ;  call_bank's A at the prologue's end
sp_c0:     .res 1                  ; the first and last window columns drawn, 0..79
sp_c1:     .res 1
sp_lb0:    .res 2                  ; the sprite's first scanline below the window's
                                   ;  top, 2*sy + wfine (16 bits, signed)
sp_r0:     .res 1                  ; the first and last window char rows drawn,
sp_r1:     .res 1
sp_ra0:    .res 1                  ;  and the scanlines within them, 0..7, where the
sp_ra1:    .res 1                  ;  sprite starts in the first and ends in the last
sp_rb:     .res 2                  ; the current row's first char on screen
sp_rp:     .res 2                  ; the current row's source: the image's column
                                   ;  base plus the row's offset
sp_rinc:   .res 1                  ; source bytes a char row: 8 (full res) or 4 (half)
sp_ncol:   .res 1                  ; columns - 1
sp_row:    .res 1                  ; the current char row, sp_r0..sp_r1
sp_c:      .res 1                  ; the image's first drawn column: -c0 when cut at
                                   ;  the left, else 0; mirrored, W - 1 - that
sp_lim:    .res 1                  ; NIBPART's: the pair's line (sprloops.s)
sp_cnt:    .res 1                  ; the row loop's column countdown
        .assert sp_rp - LDZP >= 17, error, "the loader's zero page runs past the prologue's scratch"
spi:       .res 1                  ; draw_sprites: the sprite's number (X in its loop,
                                   ;  reloaded after draw_sprite)
  .if DRAWFLAGS
sp_dfl:    .res 1                  ; draw_sprites' flags for the sprite: 1 = mirror it
  .endif
lcnt:      .res 1                  ; erase_old, draw_dirty: records or tiles to look at
lidx:      .res 1                  ; erase_old, draw_dirty: the record or list index

; ---------------------------------------------------------------- the ring
; calc_ring's (kernel.s), for the frame being rendered
ring_s:    .res 2                  ; the window's start char in the ring, 0..RINGCHARS-1
barq:      .res 1                  ; its slot, ring_s / 80

; ---------------------------------------------------------------- level geometry
; The game's (its level start, from the level header); the engine reads mapw, maph
; through maxwx, maxwy only in the game's clamp.
maplw:     .res 1                  ; log2 of the map's width in tiles
row_lim:   .res 1                  ; draw_sprite's line limit this frame: render_frame's
                                   ;  min(BUFROWS, 256 - wcy) rows, in lines
mapw:      .res 2                  ; the map's width in game pixels
maph:      .res 2                  ;  and height
maxwx:     .res 2                  ; mapw - WINPX: the window's largest x
maxwy:     .res 2                  ; maph - VISLINES/2: and y

; ---------------------------------------------------------------- misc
vsyncs:    .res 1                  ; counted by the vsync interrupt; the game loop
                                   ;  and the menus pace themselves by it
flip_req:  .res 1                  ; 1 = a flip is pending: render_frame and the menus
                                   ;  set it, the vsync clears it when it flips
flipvs:    .res 1                  ; vsyncs at the last flip: the next waits FLIPWAIT
keys:      .res 1                  ; the K_ bits held, scan_keys' (the vsync); the
                                   ;  game and the menus read it
map_ptr:   .res 2                  ; a map row's address in bank 5: map_row's (and the
                                   ;  game's own row table), for map_byte, map_put,
                                   ;  map_col and draw_rect
  .if .not SOUND6
sfx_ptr:   .res 2                  ; the sound effect's next step; +1 = 0: none playing
  .endif
mus_ptr:   .res 2                  ; the tune's next record (music_tick, menus.s)

; ---------------------------------------------------------------- the Model B's gather
; The arithmetic gather's shape (gather.s gather5): the Model B's hottest scalars,
; the loader's per level (the Master's gather is its table, LV_PAGE0).  The level's
; half tiles: the first id, the halves' page, and half0 less the first half's slot in
; it (their low bits are a table: gather.s HLOW).
half0:     .res 1                  ; (Model B) the first half tile's id
halfhi5:   .res 1                  ; (Model B) the halves' page, less GH_TILE
half_sub:  .res 1                  ; (Model B) half0 - HALFOFF: id - this = the
                                   ;  half's slot

; ---------------------------------------------------------------- appended later
; The hot scalars moved into zero page since the layout above settled, in the order
; they arrived: each took the next free byte, so they are not grouped with their
; owners above.
map_stride: .res 2                 ; bytes a map row, 1 << lw: the loader's;
                                   ;  draw_rect's row step and map_col's neighbours
map_shr:   .res 1                  ; 8 - lw: the loader's; map_row's shift count
mus_tick:  .res 1                  ; the tune's step is due: sound_tick raises it from
                                   ;  mus_on at the vsync (Model B); the stub (low.s)
                                   ;  takes it.  The Master's handler steps the tune
                                   ;  from mus_on directly
disp_d:    .res 1                  ; (Master) ACCCON D for the displayed buffer's
                                   ;  playfield: the vsync's flip writes it, the D step
                                   ;  reads it
dsect:     .res 1                  ; (Master) the step after the bar's, SECTAB's
                                   ;  offset: the one that switches D (the vsync
                                   ;  sets it)
next_buf:  .res 1                  ; (Master) the buffer the next flip shows:
                                   ;  render_frame and the menus write it; the vsync's
                                   ;  flip copies it to disp_d
row_bit:   .res 1                  ; draw_rect: the char row being drawn as a half
                                   ;  tile's fill bit, GL_FILLTOP or GL_FILLBOT
dpass:     .res 1                  ; draw_sprites' pass: 1 the boxes, then 0 the rest;
                                   ;  0 between calls
sp_clip:   .res 1                  ; draw_sprite: counted up at every window edge the
                                   ;  sprite is cut against (0: whole)
mus_on:    .res 1                  ; the tune plays (1): music_start sets it,
                                   ;  music_stop clears it; the vsync steps the tune
                                   ;  while it is set, the menus read it
; $FD-$FF ($FC: the MOS keeps the interrupt's A there)
        .segment "ZPTOP": zeropage
romsel_cpy: .res 1                 ; ROMSEL_CPY (defs.s): the code uses the equate;
                                   ;  the label is for the tests, which read labels.txt
        .assert romsel_cpy = ROMSEL_CPY, error, "ROMSEL_CPY: zero page's $FD"
crtcb:     .res 2                  ; the buffer being built: its CRTC base, as the
                                   ;  CRTC counts (build_sections writes and reads it)
        .zeropage

; ============================================================================
; Tables (uninitialised)
;
; Each table lives in the bank of the code that reads it, and only what more than one
; bank touches is in low RAM.  The expansion tables and SWAPTAB are static data at a
; fixed address in both sprite banks (defs.inc); the row multiples and the row tables
; are static too (banks.s, tiles.s).
; ============================================================================

; ---------------------------------------------------------------- TILBSS: bank 6
; The tile blitter's (the gather's arrays are low RAM's: low.s); boot zeroes it.
        .segment "TILBSS"
        .assert FLAT0 + NFLAT + 2 = 256, error, "the fills are the ids from FLAT0 to 255: NFLAT flat tiles, then the two solids (assets.inc)"
; FLATTAB: the level's flat tiles, a pair (even line, odd line) for each id - FLAT0;
; the solids are the last two.  The loader writes it (ldprog.s), draw_rect reads it.
FLATTAB:   .res FLATTAB_LEN

; ---------------------------------------------------------------- ENGBSS: bank 7
; The renderer's: mark_dirty, draw_dirty, the sprite prologue and the records are in
; bank 7.
        .segment "ENGBSS"
; each buffer's dirty tiles as (x, y) pairs, DIRTYMAX of buffer 0's then buffer 1's
; (mark_dirty writes both lists; draw_dirty reads the back buffer's)
DIRTYLIST: .res 2*2*DIRTYMAX
  .if TIGHTBSS
; TIGHTBSS: as two arrays, x then y, the buffers' entries interleaved: buffer b's
; entry n at 2n + b (mark_dirty, draw_dirty).
DIRTYX     = DIRTYLIST
DIRTYY     = DIRTYLIST+2*DIRTYMAX
  .endif
; the sprite prologue's records (the layout: defs.s, RECSZ)
SPRREC:    .res 2*MAXREC*RECSZ     ; buffer 0's records, then buffer 1's (draw_sprites)
RECCNT:    .res 2                  ; records a buffer holds: draw_sprites sets it,
                                   ;  match_sprites drops an invalid buffer's, lv_reset
                                   ;  zeroes both; erase_old reads it
KEEP:      .res MAXREC             ; match_sprites' verdict a sprite (KEEP_SAME,
                                   ;  KEEP_BOX, 0); erase_old and draw_sprites read it
DIRTYCNT:  .res 2                  ; each buffer's dirty tiles queued: mark_dirty
                                   ;  counts, draw_dirty and lv_reset zero
  .if UDATA5
lv_udata:  .res 2                  ; UDATA5: the level's own bytes in bank 5, their start
                                   ;  (they end at LV_MAP): the loader's (ldprog.s lv_load)
  .endif
; The sprite draw list, one array per field (index = the sprite's number, so no
; stride to multiply by): id, x lo/hi, y lo/hi in game pixels (map coordinates).
; add_sprite writes it; draw_sprites and match_sprites read it.  SPRLIST names the
; whole (docs/DESIGN.md).
SPRLIST:
SPR_ID:    .res MAXSPR
SPR_XL:    .res MAXSPR
SPR_XH:    .res MAXSPR
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
        .assert >SPR_ID = >(SPR_YH+MAXSPR-1), warning, "the sprite list crosses a page: its indexed reads +1"

; ---------------------------------------------------------------- LOWBSS: the buffers
; Main RAM, $0140 on: the buffers' state, which bank 6 writes (scroll_validate) and
; banks 6 and 7 read; and the bank table (low.s holds the rest of LOWBSS).
        .segment "LOWBSS"
BUF_CY:    .res 2                  ; each buffer's window, by cur_buf, as it last
BUF_CXL:   .res 2                  ;  drew it: char row, char column low and high bytes.
BUF_CXH:   .res 2                  ;  BUF_INVALID in the high byte (lv_reset,
                                   ;  mark_dirty): redraw the buffer whole
; PBANK: the physical bank of each of banks 4..7 (what the loader cannot patch reads
; it: ldprog.s, cpu.inc ldpbank).  pboard: the board, BOARD_STD / BOARD_WATFORD /
; BOARD_SOLIDISK (defs.inc), right after PBANK: boot copies the five together.
PBANK:     .res 4
pboard:    .res 1
  .if RINGARITH                     ; (both machines: their LOWBSS lie alike)
wrow:      .res 1                  ; wcy mod RINGROWS (TALLMAP: wcyh:wcy's): the window's
  .endif                           ;  top row's slot (calc_ring, the Model B's)

; ---------------------------------------------------------------- the rupture chain
; The chain's tables sit with the interrupt that reads them (cpu.inc PLACEH): the
; Master's MRAMBSS, main RAM, with its handler; the Model B's KRNHW, bank 7, with
; isr_body, after the shared.  build_sections and the vsync write them from bank 7's
; code; the interrupt's steps only read them.
        PLACEH "MRAMBSS", "KRNHW"
BUF_SEC0:  .res 4                  ; each buffer's section 0 (the bar): CRTC address
BUF_SEC0T1: .res 4                 ;  (build_sections; menu_sections moves buffer 0's),
                                   ;  and its T1 count, by 2 x the buffer
SECTAB:    .res 2*SECBYTES         ; each buffer's chain (build_sections)
BUF_QS:    .res 2+1                ; each buffer's Q entry (-> qsect), at 2 x the buffer
  .if BHW                          ; hardware: the Model B's palette kill
BUF_KS:    .res 2+1                ;  and its two-line P2's (-> ksect), SECT_NONE
                                   ;  for none
  .endif
