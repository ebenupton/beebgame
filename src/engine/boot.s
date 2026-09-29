; ---------------------------------------------------------------- interrupt takeover
        .segment "BOOT"             ; start-up's, in main RAM (once only)
take_over:
        sei
        lda #<irq_handler
        sta IRQ1V
        lda #>irq_handler
        sta IRQ1V+1
        lda #$7F
        sta VIA_IER
        sta UVIA_IER
        lda VIA_ACR
        and #$3F
        ora #$40                    ; T1 continuous
        sta VIA_ACR
        lda #<(40*LINE)
        sta VIA_T1LL
        .assert <(40*LINE) = 0, error, "take_over clears flipreq with the latch's low byte"
        sta flipreq                 ; A = 0
        lda #>(40*LINE)
        sta VIA_T1CH
        lda #$C2                    ; enable CA1 (vsync) + T1
        sta VIA_IER
        sta VIA_IFR                 ; $C2: T1 and CA1, the only sources ever enabled
        cli
        rts

; ============================================================================
; CRTC / palette setup
; ============================================================================
        .segment "BOOT"             ; start-up's, in main RAM
; The frame a load parks in (load_begin): a standard 312-line frame with the vsync on
; the chain's row, curR7 = LDR7 -- the first vsync re-phases from it and the chain
; takes over, as after a load.  Every register, from the end of the tables: R8 = 0
; (no interlace: the MOS's MODE 1 leaves interlace sync on, which puts every other
; field's vsync half a scanline later), R10 = $20 (cursor off), R12/R13 last.
crtc_init:
        ldx #13
@w:     lda @reg,x
        sta CRTC_IDX
        lda @val,x
        sta CRTC_DAT
        dex
        bpl @w
        lda #LDR7
        sta curR7
        rts
@reg:   .byte 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
@val:   .byte <BARCRTC, >BARCRTC, 8, $20, 7, 0, LDR7, VISROWS, 0, LDR4, $28, 98, ROWCHARS, 127

