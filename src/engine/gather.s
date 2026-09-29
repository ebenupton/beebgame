; ---------------------------------------------------------------- the gather, in bank 5
; A tile row's ids, straight from the map (ptr, the row's first tile; rc_nt+1 of them),
; into GATHERL/GATHERH in low RAM, which the row loop in bank 6 reads: low RAM's
; mapstrip pages this bank in around it.  The Master's gather is a table (LV_PAGE0);
; the Model B's is arithmetic, on the level's half shape (zero page) and mirror shape
; (below), both the loader's.
        .segment "MAP5CODE"
gather5:
        ldy rc_nt
@gl:
  .if .not BHW
        ; the Master: the map row read in place (this is bank 5), then the table --
        ; LV_PAGE0 in main RAM, the level's (the loader's) -- gives the pair the Model
        ; B's gather below computes
        lda (ptr),y
        tax
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
  .else
        ; the tiles are contiguous from TILES (page aligned, 64 bytes each), so the
        ; address is arithmetic: no table beside them.  Id 0 (the level's solid) and
        ; the ids from FLAT0 are fills, flagged by a high byte with bit 7 clear: 0 for
        ; the solid, $40 for a flat tile -- two bytes alternating down every char, the
        ; low byte indexing the pair in FLATTAB (the loader's; the two solids are its
        ; last two entries, for a level's other solid).
        ; Between the full tiles and the flats are the HALF tiles (ids from half0,
        ; the loader's): one 32-byte char row stored at halfhi:00 + k*32, the other
        ; either a fill (its pair in HALFPAIR) or the same row again.  Their low byte
        ; carries the flags: bit 2 = a half, bit 0 = the top row is the fill, bit 1 the
        ; bottom (neither: both rows are the stored one).
        lda (ptr),y
        beq @gsol                   ; id 0: the solid, a zero high byte (GATHERL unread)
        cmp #FLAT0
        bcs @gflat
        cmp half0
        bcs @ghalf
        adc #TOFF                   ; (C = 0) its slot: the first tile is TOFF+1 slots up
        tax                         ; from TILES, past the code (assets.inc)
        lsr
        lsr
        clc
        adc #>TILES
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
@gsol:  sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone
@gflat: sbc #FLAT0                  ; (C is set)
        asl
        sta GATHERL,y
        lda #$40                    ; a fill (the row loop's bpl), not the solid (0)
        sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone
@ghalf:
  .if TILEMIRROR
        cmp mir0
        bcs @gmir
  .endif
        tax                         ; X = the id, for the range tests
        sbc halfsub                 ; k, the slot from the halves' page: C is clear after
                                    ; the mirror test (halfsub = half0 - HALFOFF - 1), set
                                    ; without it (the loader's halfsub = half0 - HALFOFF)
        sta tmp
        lsr
        lsr
        lsr
        clc
        adc halfhi5
        sta GATHERH,y
        lda tmp
        asl
        asl
        asl
        asl
        asl                         ; (k & 7) << 5: the shifts drop the rest
        cpx half1                   ; a half: bit 2, the fill row's flag by range:
        adc #5                      ; below half1 4|1 (top fills), else 4|2 (C from cpx)
        cpx half2
        bcc @gh2                    ; below half2: done
        eor #2                      ; from half2 (so from half1): 6 -> 4, both stored
@gh2:   sta GATHERL,y
        dey
        bpl @gl
        bmi @gdone
  .if TILEMIRROR
@gmir:  sbc mir0                    ; a mirrored tile: its source's slot (C is set),
        tax                         ; addressed as a full tile's, kind 3
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
        .segment "MAP5BSS"          ; the level's mirror shape (the loader's), for the
  .if BHW                           ; Model B's arithmetic gather (the half shape,
   .if TILEMIRROR                   ; half0-halfsub, is in zero page)
mir0:      .res 1                   ; the first mirrored tile's id (the loader's)
MIRTAB:    .res MAXMIR              ; per mirrored id: the slot of the tile it mirrors
   .endif
  .endif
  .if BHW
        .assert * = B5_CODE_END, error, "bank 5's code must end where its sprites start: set B5_CODE_END in the game's assets.inc"
  .else
        .assert * <= B5_CODE_END, error, "bank 5's code runs into its sprites: B5_CODE_END in the game's assets.inc"
  .endif
