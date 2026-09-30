; ============================================================================
; engine/lowram.s -- the engine's map access, in low RAM
;
; Low RAM ($0140-$02FF) is visible whichever sideways bank is paged in, so code that
; switches banks under itself lives here.  The game's logic runs in bank 7 but the map
; is in bank 5: these routines page the map in, touch it, and page bank 7 back, so the
; logic can simply call them.  (low.s holds the rest of low RAM: the crossings into
; the other banks and the Model B's interrupt stub.)
;
;   maprow     A = tile row -> mapptr = the row's address in the map
;   mapcol     a map byte and the two beside it in its column, one bank switch
;   mapbyte    A = the map byte at (mapptr),Y
;   mapput     store A at (mapptr),Y
;   pagelogic  page bank 7 back in: the way home from every crossing
;
; Segment: LOWCODE (copied down from the boot piece at start-up).
; ============================================================================
        .segment "LOWCODE"

; ----------------------------------------------------------------------------
; maprow: the address of a map row
;   In:   A = tile row
;   Out:  mapptr = LV_MAP + (row << lw), the map being 2^lw tiles wide;  Y = 0
;   Keeps X (the logic calls this with X live).
; row << lw is worked out as (row << 8) >> (8 - lw): mapshr = 8 - lw is the loader's,
; so no table has to be paged in.
; ----------------------------------------------------------------------------
maprow:
        ldy #0
        sty mapptr                  ; row << 8 has no low byte
        ldy mapshr                  ; then 8 - lw shifts right
        beq :++
:       lsr
        ror mapptr
        dey
        bne :-
:       clc
        adc #>LV_MAP
        sta mapptr+1
        rts

; ----------------------------------------------------------------------------
; mapbyte: read the map
;   In:   mapptr, Y
;   Out:  A = (mapptr),Y;  X, Y kept
; ----------------------------------------------------------------------------
mapbyte:
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (mapptr),y
        jmp pagelogic

; ----------------------------------------------------------------------------
; mapcol: a map byte and its column's neighbours, in one visit to bank 5
;   In:   mapptr = a row, Y = the column
;   Out:  A = (mapptr),Y;  X = the byte a map row above it, Y = the one below
;         (MAPSTRIDE apart);  tp clobbered (the blitter's: free outside a render)
; Past the map's top or bottom row a neighbour is whatever lies there -- the map is
; 8K at $9C00, so $9B00-$BCFF, bank 5's sprites and tables, never I/O -- for the
; caller to ignore.
; ----------------------------------------------------------------------------
mapcol: lda mapptr                  ; tp = the row above
        sec
        sbc MAPSTRIDE
        sta tp
        lda mapptr+1
        sbc MAPSTRIDE+1
        sta tp+1
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (tp),y
        tax                         ; above
        lda (mapptr),y
        sta mtmp                    ; this row's
        lda mapptr                  ; tp = the row below
        clc
        adc MAPSTRIDE
        sta tp
        lda mapptr+1
        adc MAPSTRIDE+1
        sta tp+1
        lda (tp),y
        tay                         ; below
        lda mtmp
        jmp pagelogic

; ----------------------------------------------------------------------------
; mapput: write the map
;   In:   A = the byte, mapptr, Y
;   Out:  A, X, Y kept
; The store is a write window (cpu.inc): the write bank is 5 for it, and 7 again
; before bank 7 is paged back in.  Falls into pagelogic.
; ----------------------------------------------------------------------------
mapput: pha
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_MAP, 0           ; open the write window
        pla
        sta (mapptr),y
        pha
        wrback 0, 2                 ; close it
        pla
        .assert * = pagelogic, error, "mapput falls into pagelogic"

; ----------------------------------------------------------------------------
; pagelogic: page bank 7 back in, for reading
;   Out:  A, X, Y and the carry all kept -- these sit in the middle of calls that
;         return values in them
; The return path of every crossing from bank 7: map access, callbank, the thunks.
; The write bank is 7's already (cpu.inc), so only the read bank changes.
; ----------------------------------------------------------------------------
        .segment "LOWCODE"
pagelogic:
        pha
        bankimm lda, BANK_LVL, 0
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        rts
