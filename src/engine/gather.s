; ============================================================================
; engine/gather.s -- bank 5: the tile gather, beside the map
;
; draw_rect's row loop (tiles.s, bank 6) draws a tile row from a list of pairs,
; one a tile.  The gather makes that list: it reads the row's ids straight from
; the map, in place in bank 5, and turns each into GATHERL/GATHERH in low RAM,
; where bank 6 can read them.  low.s's map_strip pages bank 5 in around it and
; bank 6 back after.
;
;   gather5   a tile row's ids -> GATHERL/GATHERH
;
; The Master's gather is a table lookup: LV_PAGE0 in main RAM, the level's,
; which the loader reads from the level file (blessed placement 2: it has the
; main RAM for it).  The Model B's is arithmetic on the level's tile shape, the
; loader's too (ldprog.s): the half tiles' shape in zero page (vars.s half0,
; half_sub, halfhi5) and each half's low bits here (HLOW).
;
; Segments: MAP5CODE, MAP5BSS (bank 5).  The bank's code ends at B5_CODE_END
; (the game's assets.inc), where its sprites start -- exactly there on the Model
; B, at most there on the Master (the asserts at the end).
; ============================================================================

HLOW_LEN = 64                      ; the halves' slots a level may have: k = 0..63,
                                   ;  8 pages of 8 rows (convert.py asserts it)

        .segment "MAP5CODE"
; ----------------------------------------------------------------------------
; gather5: a tile row's ids -> GATHERL/GATHERH
;   In:    ptr = the address of the row's first tile in the map (bank 5); rc_nt
;          = the tile count less 1 (rc_nt+1 tiles, GATHERN at most); the Master:
;          LV_PAGE0; the Model B: half0, half_sub, halfhi5, HLOW
;   Out:   GATHERL,y / GATHERH,y for y = 0..rc_nt (the Model B leaves GATHERL
;          of a solid tile as it was: the row loop never reads it)
;   Uses:  A X Y
;   Pre:   bank 5 paged (map_strip, low.s)
; Last tile first (Y counts down).  What a pair means to the row loop (the
; names are defs.inc's GH_*, GL_*; the Master's table holds the same):
;   GATHERH = 0             id 0, the level's solid (GATHERL unread)
;   GATHERH = GH_FLAT       a flat tile, or the other solid: GATHERL indexes
;                           its pair in FLATTAB (2 x (id - FLAT0))
;   GATHERH bit 7 set       a full tile: GATHERH:GATHERL its address in bank 6,
;                           the low byte's bits 0-5 clear
;   GATHERH else            a half tile: its row's page less GH_TILE (bit 7
;                           clear, not 0, below GH_FLAT: draw_rect sends it the
;                           rare way), GATHERL the row's offset in the page
;                           (GL_ROWMASK, bits 5-7), which of its char rows is
;                           the fill (GL_FILLTOP, GL_FILLBOT; neither: both rows
;                           stored) and the fill's colour in the level's palette
;                           (GL_COLMASK, bits 0-2)
; So a fill is flagged by bit 7 of the high byte clear: the row loop's bmi/bne.
;
; The Model B's tile kinds, by id range (convert.py lays the ids out this way):
;   0                 the level's solid: a fill
;   1 .. half0-1      full tiles, contiguous from TILES (page aligned, TILEBYTES
;                     each, id k in slot k + TOFF), so the address is arithmetic
;   half0 .. FLAT0-1  the half tiles: one char row of HALFBYTES stored at the
;                     halves' page + k*32, k the slot counted from that page
;                     (half_sub = half0 - HALFOFF, so id - half_sub is k); the
;                     other row a fill (a pair from the level's palette,
;                     HPAIR0/HPAIR1) or the same row again.  Their fill row and
;                     colour are HLOW's, by k
;   FLAT0 .. 255      flat tiles: a pair alternating down every char, in
;                     FLATTAB (the two solids are its last two entries, for a
;                     level's other solid)
; ----------------------------------------------------------------------------
gather5:
        ldy rc_nt
@tile:
  .if .not BHW                     ; blessed placement: LV_PAGE0 in main RAM
        ; ---- the Master: the id, read in place, indexes the table -- which
        ; holds the pair the Model B's gather below computes
        lda (ptr),y
        tax
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @tile
  .else
        ; ---- the Model B: sort the id by range
        lda (ptr),y
        beq @solid                 ; id 0: the solid
        cmp #FLAT0
        bcs @flat
        cmp half0
        bcs @half
        ; ---- a full tile: slot id + TOFF, counted from TILES's page.  A = the
        ; slot + 4 x (TILES's page less $80): under $100 while the tile is below
        ; $C000
        adc #TOFF+TILES_PER_PAGE*(>TILES-GH_TILE)   ; (C = 0 from the cmp)
        tax
        and #TILES_PER_PAGE-1
        lsr
        ror
        ror                        ; (slot & 3) << 6: the low byte
        sta GATHERL,y
        txa
        lsr
        sec                        ; bit 7 in: ora #GH_TILE a byte shorter (slot >> 2
        ror                        ;  is below $80), so slot >> 2 + >TILES, 4 a page
        .assert >TILES >= GH_TILE && <TILES = 0 && TILES_PER_PAGE = 4, error, "gather5: TILES page aligned, 4 slots a page"
        ; on into the solid's store: a full tile's high byte goes last, so the
        ; two share the store
        ; ---- the solid: a zero high byte (GATHERL unread)
@solid: sta GATHERH,y
        dey
        bpl @tile
        rts
        ; ---- a flat tile: its pair's index in FLATTAB
@flat:  sbc #FLAT0                 ; C = 1 from the cmp
        asl
        sta GATHERL,y
        lda #GH_FLAT               ; a fill (the row loop's bne), not the solid (0)
        sta GATHERH,y
        dey
        bpl @tile
        rts
        ; ---- a half tile: k = its slot from the halves' page
@half:  sbc half_sub               ; C = 1 from the cmp: id - (half0 - HALFOFF)
        tax
        lsr
        lsr
        lsr
        clc
        adc halfhi5                ; + (k >> 3): 8 half rows a page (halfhi5 is the
        sta GATHERH,y              ;  page less GH_TILE, the loader's: a half's mark)
        txa
        asl
        asl
        asl
        asl
        asl                        ; (k & 7) << 5: the shifts drop the rest
        ora HLOW,x                 ; its fill row and colour
        sta GATHERL,y
        dey
        bpl @tile
        rts
  .endif
  .if .not BHW                     ; (each Model B path ends in its own rts)
        rts
  .endif

; ---------------------------------------------------------------- halves' bits
; HLOW: the level's half tiles' GATHERL low bits -- fill row
; (GL_FILLTOP/GL_FILLBOT) and colour (GL_COLMASK) -- by k, the slot from the
; halves' page; the loader fills entries HALFOFF .. HALFOFF+NHALF-1 (ldprog.s).
; The rest of the shape (half0, half_sub, halfhi5) is zero page's: vars.s.
        .segment "MAP5BSS"
  .if BHW                          ; blessed placement: the Master's shape is LV_PAGE0
HLOW:     .res HLOW_LEN
  .endif

; ---- bank 5's code (with MAP5BSS, its last) against where its sprites start
  .if BHW                          ; (the Model B pins it: the Master's code is shorter)
        .assert * = B5_CODE_END, error, "bank 5's code must end at B5_CODE_END (assets.inc)"
  .else
        .assert * <= B5_CODE_END, error, "bank 5's code runs past B5_CODE_END (assets.inc)"
  .endif
