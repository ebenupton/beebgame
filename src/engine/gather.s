; ============================================================================
; engine/gather.s -- the tile gather, in bank 5 beside the map
;
; drawrect's row loop (tiles.s, bank 6) draws a tile row from a list of tile addresses.
; The gather makes that list: it reads the row's ids straight from the map, in place
; in bank 5, and turns each into GATHERL/GATHERH in low RAM, where bank 6 can read it.
; low.s's mapstrip pages bank 5 in around it and bank 6 back after.
;
;   gather5   a tile row's ids -> GATHERL/GATHERH
;
; The Master's gather is a table (LV_PAGE0, the loader's).  The Model B's is
; arithmetic on the level's shape, the loader's too: the half shape in zero page
; (vars.s) and the mirror shape here (MAP5BSS, below).
;
; Segments: MAP5CODE, MAP5BSS (bank 5).  The bank's code ends at B5_CODE_END (the
; game's assets.inc), where its sprites start -- exactly there on the Model B, at
; most there on the Master (the asserts at the end).
; ============================================================================
        .segment "MAP5CODE"

; ============================================================================
; gather5: a tile row's ids -> GATHERL/GATHERH
;   In:   ptr = the address of the row's first tile in the map;  rc_nt = the tile
;         count less 1 (rc_nt+1 tiles)
;   Out:  GATHERL,y / GATHERH,y for y = 0..rc_nt;  A, X, Y clobbered (tmp too, on
;         the Model B)
;   Runs in bank 5 (called by mapstrip, low.s), last tile first.
;
; What a pair means to the row loop (the Model B's; the Master's table holds the same):
;   GATHERH = 0             id 0, the level's solid (GATHERL unread)
;   GATHERH = $40           a flat tile: GATHERL indexes its pair in FLATTAB
;   GATHERH bit 7 set       a stored tile: GATHERH:GATHERL is its address in bank 6;
;                           a full tile's GATHERL has its low bits clear, a half's the
;                           flags (bit 2 = a half), a mirror's is kind 3
; A fill is flagged by bit 7 of the high byte clear -- the row loop's bpl.
;
; Model B, the tile kinds by id range:
;   0              the level's solid: a fill
;   1 .. half0-1   full tiles: contiguous from TILES (page aligned, 64 bytes each), so
;                  the address is arithmetic, with no table beside them
;   half0 .. ..    the HALF tiles (half0, half1, half2: the loader's): one 32-byte
;                  char row stored at halfhi:00 + k*32; the other a fill (its pair in
;                  HALFPAIR) or the same row again.  Their low byte carries the flags:
;                  bit 2 = a half, bit 0 = the top row is the fill, bit 1 the bottom
;                  (neither: both rows are the stored one)
;   mir0 .. ..     mirrored tiles (TILEMIRROR builds only): their source's slot
;   FLAT0 ..       flat tiles: a fill of two bytes alternating down every char, the low
;                  byte indexing the pair in FLATTAB (the loader's; the two solids are
;                  its last two entries, for a level's other solid)
; ============================================================================
gather5:
        ldy rc_nt
@gl:
  .if .not BHW
        ; ---- the Master: the map row read in place (this is bank 5), then the table
        ; -- LV_PAGE0 in main RAM, the level's (the loader's) -- gives the pair the
        ; Model B's gather below computes
        lda (ptr),y
        tax
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
  .else
        ; ---- the Model B: sort the id by range
        lda (ptr),y
        beq @gsol                   ; id 0: the solid
        cmp #FLAT0
        bcs @gflat
        cmp half0
        bcs @ghalf

        ; ---- a full tile: slot id + TOFF, so the first tile (id 1) is TOFF+1 slots
        ; up from TILES, past the code (assets.inc)
        adc #TOFF                   ; C = 0 from the cmp
        tax
        lsr
        lsr
        clc
        adc #>TILES                 ; slot >> 2: 4 slots a page
        sta GATHERH,y
        txa
        and #3
        lsr
        ror
        ror                         ; (id & 3) << 6
        sta GATHERL,y
        dey
        bpl @gl
        bmi @gdone

        ; ---- the solid: a zero high byte (GATHERL unread)
@gsol:  sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone

        ; ---- a flat tile: its pair's index in FLATTAB
@gflat: sbc #FLAT0                  ; C is set, from the cmp
        asl
        sta GATHERL,y
        lda #$40                    ; a fill (the row loop's bpl), not the solid (0)
        sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone

        ; ---- a half tile (or, with TILEMIRROR, a mirrored one)
        ; k = its slot from the halves' page.  C is clear after the mirror test, so the
        ; loader's halfsub is half0 - HALFOFF - 1 with it, half0 - HALFOFF without.
@ghalf:
  .if TILEMIRROR
        cmp mir0
        bcs @gmir
  .endif
        tax                         ; X = the id, for the range tests
        sbc halfsub                 ; k
        sta tmp
        lsr
        lsr
        lsr
        clc
        adc halfhi5                 ; + (k >> 3): 8 half rows a page
        sta GATHERH,y
        lda tmp
        asl
        asl
        asl
        asl
        asl                         ; (k & 7) << 5: the shifts drop the rest
        ; The flags, by range: bit 2 (a half) and the fill row's bit -- below half1
        ; 4|1 (the top fills), from it 4|2 (the bottom; C from the cpx adds the 1),
        ; and from half2 (so from half1) 6 -> 4, both rows stored.
        cpx half1
        adc #5
        cpx half2
        bcc @gh2                    ; below half2: done
        eor #2                      ; from half2: 6 -> 4
@gh2:   sta GATHERL,y
        dey
        bpl @gl
        bmi @gdone
  .if TILEMIRROR
        ; ---- a mirrored tile: its source's slot, addressed as a full tile's, kind 3
@gmir:  sbc mir0                    ; C is set, from the cmp
        tax
        lda MIRTAB,x
        tax
        lsr
        lsr
        clc
        adc #>TILES
        sta GATHERH,y
        txa
        and #3
        lsr
        ror
        ror                         ; (slot & 3) << 6
        ora #3
        bne @gh2                    ; (always)
  .endif
    .endif
@gdone: rts

; ----------------------------------------------------------------------------
; The level's mirror shape (the loader's), for the Model B's arithmetic gather (the
; half shape, half0-halfsub, is in zero page: vars.s)
; ----------------------------------------------------------------------------
        .segment "MAP5BSS"
  .if BHW
   .if TILEMIRROR
mir0:      .res 1                   ; the first mirrored tile's id (the loader's)
MIRTAB:    .res MAXMIR              ; per mirrored id: the slot of the tile it mirrors
   .endif
  .endif

; ---- bank 5's code (with MAP5BSS, its last) against where the sprites start
  .if BHW
        .assert * = B5_CODE_END, error, "bank 5's code must end where its sprites start: set B5_CODE_END in the game's assets.inc"
  .else
        .assert * <= B5_CODE_END, error, "bank 5's code runs into its sprites: B5_CODE_END in the game's assets.inc"
  .endif
