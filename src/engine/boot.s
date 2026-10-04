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
;         VIA's CA1 (vsync) and T1;  T1 free running, latched at 40 lines;  flip_req = 0;
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
        lda #<~VIA_ISET            ; clear bits 0-6: every source
        sta VIA_IER
        sta UVIA_IER
        ; ---- T1 continuous, its first period IDLE_LINES lines
        lda VIA_ACR
        and #<~VIA_ACR_T1
        ora #VIA_ACR_T1CONT        ; T1 continuous
        sta VIA_ACR
        lda #<(IDLE_LINES*LINE)
        sta VIA_T1LL
        .assert <(IDLE_LINES*LINE) = 0, error, "take_over clears flip_req with the latch's low byte"
        sta flip_req               ; A = 0: no flip pending
        lda #>(IDLE_LINES*LINE)
        sta VIA_T1CH               ; (starts T1)
        ; ---- CA1 and T1 on, their flags cleared
        lda #VIA_ISET|VIA_IT1|VIA_ICA1   ; enable CA1 (vsync) + T1
        sta VIA_IER
        sta VIA_IFR                ; and clear both flags (the only sources ever enabled)
        cli
        rts

; ============================================================================
; crtc_init: every CRTC register, for the frame a load parks in
;   Out:  R0-R13 written;  cur_r7 = LDR7;  A, X clobbered, Y kept
;
; The frame a load parks in (load_begin): a standard 312-line frame with the vsync on
; the chain's row, cur_r7 = LDR7 -- the first vsync re-phases from it and the chain
; takes over, as after a load.  Every register in order, R0 up to R13, so R12/R13
; (the bar's address) are written last.  R8 = 0: no interlace -- the MOS's MODE 1 leaves
; interlace sync on, which puts every other field's vsync half a scanline later.
; R10 = R10_CUROFF: the cursor off.
; ============================================================================
        .segment "BOOT"
crtc_init:
        ldx #R_HTOT
@w:     stx CRTC_IDX               ; X is the register number
        lda @val,x
        sta CRTC_DAT
        inx
        cpx #CRTC_NREGS
        bne @w
        lda #LDR7
        sta cur_r7
        rts
; the values, R0 first: MODE 1's horizontal shape, the load frame's rows (LDR4, no
; adjust lines, VISROWS shown, the vsync on LDR7), no interlace, 8-line rows, the cursor
; off, the bar's address
@val:   .byte MODE1_R0, ROWCHARS, MODE1_R2, MODE1_R3, LDR4, 0, VISROWS, LDR7, 0
        .byte CHARLINES-1, R10_CUROFF, MODE1_R11, >BARCRTC, <BARCRTC
        .assert * - @val = CRTC_NREGS, error, "crtc_init: a value a register, R0 to R13"
