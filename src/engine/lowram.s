        .segment "LOWCODE"          ; low RAM
; ============================================================================
; Map access for the logic, which lives in bank 7 and so cannot select bank 5
; itself.  Each of these leaves bank 7 selected, so the logic calls them directly.
; ============================================================================
; A = tile row -> mapptr = address of that map row
maprow:                             ; row * 2^lw = (row << 8) >> (8 - lw): mapshr is
        ldy #0                      ; the loader's; no table to page in.  X
        sty mapptr                  ; is kept (the logic calls this with it live);
        ldy mapshr                  ; Y comes back 0
        beq :++
:       lsr
        ror mapptr
        dey
        bne :-
:       clc
        adc #>LV_MAP
        sta mapptr+1
        rts

; A = (mapptr),y ; Y preserved
mapbyte:
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (mapptr),y
        jmp pagelogic

; store A at (mapptr),y ; Y preserved
mapput: pha
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_MAP, 0           ; a write window: the store
        pla
        sta (mapptr),y
        pha
        wrback 0, 2                 ; (closed)
        pla
        .assert * = pagelogic, error, "mapput falls into pagelogic"




; ============================================================================
; pagelogic: bank 7 back, for reading -- the return path of every crossing from bank 7
; (map access, callbank, the thunks); the write bank is 7's already (cpu.inc)
; ============================================================================
        .segment "LOWCODE"
pagelogic:                          ; A, X, Y and the carry all come through intact:
        pha                         ; these sit in the middle of calls that return values
        bankimm lda, BANK_LVL, 0
        sta ROMSEL_CPY
        sta ROMSEL                  ; (no write bank: it is 7's already -- cpu.inc)
        pla
        rts
