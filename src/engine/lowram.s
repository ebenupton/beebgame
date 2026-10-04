; ============================================================================
; engine/lowram.s -- the engine's map access, in low RAM
;
; Low RAM ($0140-$02FF) is visible whichever sideways bank is paged in, so code that
; switches banks under itself lives here.  The game's logic runs in bank 7 but the map
; is in bank 5: these routines page the map in, touch it, and page bank 7 back, so the
; logic can simply call them.  (low.s holds the rest of low RAM: the crossings into
; the other banks and the Model B's interrupt stub.)
;
;   map_row     A = tile row -> map_ptr = the row's address in the map
;   map_col     a map byte and the two beside it in its column, one bank switch
;   map_byte    A = the map byte at (map_ptr),Y
;   map_put     store A at (map_ptr),Y
;   page_logic  page bank 7 back in: the way home from every crossing
;
; Segment: LOWCODE (copied down from the boot piece at start-up).
; ============================================================================
        .segment "LOWCODE"

; ----------------------------------------------------------------------------
; map_row: the address of a map row
;   In:   A = tile row
;   Out:  map_ptr = LV_MAP + (row << lw), the map being 2^lw tiles wide;  Y = 0
;   Keeps X (the logic calls this with X live).
; row << lw is worked out as (row << 8) >> (8 - lw): map_shr = 8 - lw is the loader's,
; so no table has to be paged in.
; ----------------------------------------------------------------------------
map_row:
        ldy map_shr                ; then 8 - lw shifts right; row << 8 has no low byte:
        sty map_ptr                ;  map_shr's own bits there all go out in its shifts
                                    ;  (k >> k = 0), and 0 is 0 (Y = 0 out either way)
        beq :++
:       lsr
        ror map_ptr
        dey
        bne :-
:       clc
        adc #>LV_MAP
        sta map_ptr+1
        rts

; ----------------------------------------------------------------------------
; map_col: a map byte and its column's neighbours, in one visit to bank 5
;   In:   map_ptr = a row, Y = the column
;   Out:  A = (map_ptr),Y;  tp = the byte a map row above it, tp+1 the one below
;         (map_stride apart: tp is the blitter's, free outside a render);  X clobbered,
;         Y kept
; Past the map's top or bottom row a neighbour is whatever lies there -- the map is
; 8K at $9C00, so $9B00-$BCFF, bank 5's sprites and tables, never I/O -- for the
; caller to ignore.
; ----------------------------------------------------------------------------
map_col: lda map_ptr               ; tp = the row above
        sec
        sbc map_stride
        sta tp
        lda map_ptr+1
        sbc map_stride+1
        sta tp+1
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (tp),y
        tax                        ; above
        lda map_ptr                ; tp = the row below
        clc
        adc map_stride
        sta tp
        lda map_ptr+1
        adc map_stride+1
        sta tp+1
        lda (tp),y
        sta tp+1                   ; below
        stx tp                     ; above
        lda (map_ptr),y            ; this row's, last: no staging through mtmp
        bankimm ldx, BANK_LVL, 0   ; bank 7 back (page_logic's, inline), through X: A kept
        stx ROMSEL_CPY
        stx ROMSEL
        rts

; ----------------------------------------------------------------------------
; map_put: write the map
;   In:   A = the byte, map_ptr, Y
;   Out:  A, X, Y kept
; The store is a write window (cpu.inc): the write bank is 5 for it, and 7 again
; before bank 7 is paged back in.  Falls into map_byte, which reads the byte back
; from bank 5 into A, then into page_logic.
; ----------------------------------------------------------------------------
map_put: pha
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_MAP, 0          ; open the write window
        pla
        sta (map_ptr),y
        wrback 0, 2                ; close it (A lost: map_byte reads the byte back)

; ----------------------------------------------------------------------------
; map_byte: read the map
;   In:   map_ptr, Y
;   Out:  A = (map_ptr),Y;  X, Y kept
; Falls into page_logic.
; ----------------------------------------------------------------------------
map_byte:
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (map_ptr),y
        .assert * = page_logic, error, "map_byte falls into page_logic"

; ----------------------------------------------------------------------------
; page_logic: page bank 7 back in, for reading
;   Out:  A, X, Y and the carry all kept -- these sit in the middle of calls that
;         return values in them
; The return path of every crossing from bank 7: map access, call_bank, the thunks.
; The write bank is 7's already (cpu.inc), so only the read bank changes.
; ----------------------------------------------------------------------------
        .segment "LOWCODE"
page_logic:
        pha
        bankimm lda, BANK_LVL, 0
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        rts
