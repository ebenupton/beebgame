; ============================================================================
; engine/boot.s -- start-up's display and interrupt set-up
;
; Run once, by init.s boot, when the game takes the machine: crtc_init sets the CRTC
; up in the frame a load parks in, then (the section chains built) take_over installs
; the engine's interrupt.  Both machines.
;
;   take_over   the interrupt: IRQ1V, the VIAs' enables, T1 free running
;   crtc_init   every CRTC register, for the load frame
;
; Segment: BOOT (start-up's, in main RAM, run once only).  init.s calls crtc_init
; first; the order here is the file's, not the call's.
; ============================================================================
        .segment "BOOT"

; ----------------------------------------------------------------------------
; take_over: install the engine's interrupt
;   Out:   IRQ1V = irq_handler; every source on both VIAs disabled but the system
;          VIA's CA1 (the vsync) and T1; T1 free running, its first period
;          IDLE_LINES lines; flip_req = 0; interrupts enabled
;   Uses:  A
;   Keeps: X Y
; The VIAs' other sources go off for good: nothing of the MOS runs again.  The CA1
; edge is the MOS's setting (PCR untouched).
; ----------------------------------------------------------------------------
take_over:
        sei
        lda #<irq_handler
        sta IRQ1V
        lda #>irq_handler
        sta IRQ1V+1
        ; ---- every source off, on both VIAs
        lda #<~VIA_ISET            ; bit 7 clear: clear the bits named; 0-6: all
        sta VIA_IER
        sta UVIA_IER
        ; ---- T1 continuous, its first period IDLE_LINES lines
        lda VIA_ACR
        and #<~VIA_ACR_T1
        ora #VIA_ACR_T1CONT
        sta VIA_ACR
        lda #<(IDLE_LINES*LINE)
        sta VIA_T1LL
        .assert <(IDLE_LINES*LINE) = 0, error, "take_over clears flip_req with the latch's low byte"
        sta flip_req               ; A = 0: no flip pending
        lda #>(IDLE_LINES*LINE)
        sta VIA_T1CH               ; (starts T1)
        ; ---- CA1 and T1 on, their flags cleared
        lda #VIA_ISET|VIA_IT1|VIA_ICA1
        sta VIA_IER
        sta VIA_IFR                ; the same bits: clears both flags (bit 7 is ignored)
        cli
        rts

; ----------------------------------------------------------------------------
; crtc_init: every CRTC register, for the frame a load parks in
;   Out:   R0-R13 written; cur_r7 = LDR7
;   Uses:  A X
;   Keeps: Y
; The frame a load parks in (kernel.s load_begin): a standard 312-line frame, LDR4
; rows, with the vsync on the chain's row LDR7 -- the first vsync re-phases from
; cur_r7 and the chain takes over, as after a load.  Every register in order, R0 up
; to R13, so R12/R13 (the bar's address) are written last.  R8 = 0: no interlace --
; the MOS's MODE 1 leaves interlace sync on, which puts every other field's vsync
; half a scanline later.  R10 = R10_CUROFF: the cursor off.
; ----------------------------------------------------------------------------
crtc_init:
        ldx #R_HTOT
@reg:   stx CRTC_IDX               ; X = the register number
        lda @val,x
        sta CRTC_DAT
        inx
        cpx #CRTC_NREGS
        bne @reg
        lda #LDR7
        sta cur_r7
        rts
; the values, R0 first: MODE 1's horizontal shape, the load frame's rows (LDR4, no
; adjust lines, VISROWS shown, the vsync on LDR7), no interlace, 8-line rows, the
; cursor off, the bar's address
@val:   .byte MODE1_R0, ROWCHARS, MODE1_R2, MODE1_R3, LDR4, 0, VISROWS, LDR7, 0
        .byte CHARLINES-1, R10_CUROFF, MODE1_R11, >BARCRTC, <BARCRTC
        .assert * - @val = CRTC_NREGS, error, "crtc_init: a value a register, R0 to R13"
