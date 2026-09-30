; ============================================================================
; engine/boot.s -- start-up's display and interrupt set-up
;
; Run once, by init.s, when the game takes the machine: crtc_init sets the CRTC up
; in the frame a load parks in, then (the section chains built) take_over installs
; the engine's interrupt.
;
;   take_over   the interrupt: IRQ1V, the VIAs' enables, T1 free running
;   crtc_init   every CRTC register, for the load frame
;
; Segment: BOOT (start-up's, in main RAM, run once only).
; ============================================================================

; ----------------------------------------------------------------------------
; take_over: install the engine's interrupt
;   Out:  IRQ1V = irq_handler;  every source on both VIAs disabled except the system
;         VIA's CA1 (vsync) and T1;  T1 free running, latched at 40 lines;  flipreq = 0;
;         interrupts enabled;  A clobbered, X, Y kept
; ----------------------------------------------------------------------------
        .segment "BOOT"
take_over:
        sei
        lda #<irq_handler
        sta IRQ1V
        lda #>irq_handler
        sta IRQ1V+1
        ; ---- every source off, on both VIAs
        lda #$7F
        sta VIA_IER
        sta UVIA_IER
        ; ---- T1 continuous, its first period 40 lines
        lda VIA_ACR
        and #$3F
        ora #$40                    ; T1 continuous
        sta VIA_ACR
        lda #<(40*LINE)
        sta VIA_T1LL
        .assert <(40*LINE) = 0, error, "take_over clears flipreq with the latch's low byte"
        sta flipreq                 ; A = 0: no flip pending
        lda #>(40*LINE)
        sta VIA_T1CH                ; (starts T1)
        ; ---- CA1 and T1 on, their flags cleared
        lda #$C2                    ; enable CA1 (vsync) + T1
        sta VIA_IER
        sta VIA_IFR                 ; $C2: T1 and CA1, the only sources ever enabled
        cli
        rts

; ============================================================================
; crtc_init: every CRTC register, for the frame a load parks in
;   Out:  R0-R13 written;  curR7 = LDR7;  A, X clobbered, Y kept
;
; The frame a load parks in (load_begin): a standard 312-line frame with the vsync on
; the chain's row, curR7 = LDR7 -- the first vsync re-phases from it and the chain
; takes over, as after a load.  Every register, from the end of the tables, so R12/R13
; (the bar's address) are written last.  R8 = 0: no interlace -- the MOS's MODE 1 leaves
; interlace sync on, which puts every other field's vsync half a scanline later.
; R10 = $20: the cursor off.
; ============================================================================
        .segment "BOOT"
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
; the registers and their values, R13 first (written from the end: R0 first)
@reg:   .byte 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
@val:   .byte <BARCRTC, >BARCRTC, 8, $20, 7, 0, LDR7, VISROWS, 0, LDR4, $28, 98, ROWCHARS, 127
