; ============================================================================
; ============================================================================
; build_sections: fill SECTAB for the current buffer from ringS and wfine.
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi.  The shape is section i's; the
; address and duration are section i+1's, because R12/R13 latch at the next restart
; and the T1 latch takes effect one interrupt later.
;
;   T   bar          2 rows, fixed home
;   A   composed row 8-f lines, the fine scroll                (only when f > 0)
;   P   playfield    VISROWS rows from the window's slot; the Model B's software
;                    ring splits it at the ring's end (P1, then M from the mirror
;                    below the ring base), the Master's CRTC folds its ring itself
;   P2  bottom       f lines                                   (only when f > 0)
;   Q   blanking     QROWS rows, vsync at row QVSYNC
; ============================================================================
  .if BHW
BARLEAD = 0
BARLATE = 0
STEPLATE = 0
  .else
BARLATE = 13                        ; us the Master's bar step fires later than its hold
STEPLATE = 20                       ;  once carried it (26 cycles), and every step after
                                    ;  the one that switches D (39: the D write and the
                                    ;  hold): VS2T, the bar's length and entry 0's
                                    ;  duration carry them
BARLEAD = 10                        ; us the Master's bar step fires early, beyond the
                                    ; lead every step has, so ACCCON D can be switched in
                                    ; the blanking of the bar's last line (its handler)
  .endif
        .segment "KRNCODE"          ; the kernel: the menus build their frame with it too
build_sections:
        ldx curbuf                  ; the buffer's CRTC base (and the Model B's mirror
        lda @cbl,x                  ; redirect: the same less the ring)
        sta crtcb
        lda @cbh,x
        sta crtcb+1
  .if BHW
        lda @cml,x
        sta crtcbm
        lda @cmh,x
        sta crtcbm+1
  .endif
        txa                         ; X = curbuf still (ldx curbuf above)
        asl
        tax
        lda #>BARCRTC               ; section 0 is the bar: fixed address and length
        sta BUF_SEC0,x
        lda #<BARCRTC
        sta BUF_SEC0+1,x
        lda #<(BARROWS*8*LINE-2-BARLEAD-BARLATE)
        sta BUF_SEC0T1,x
        lda #>(BARROWS*8*LINE-2-BARLEAD-BARLATE)
        sta BUF_SEC0T1+1,x
        txa                         ; Z from X = curbuf*2
        beq :+
        ldx #48
:       lda #BARROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #BARROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda wfine
        beq @coarse
        ; ---- f > 0: T -> A (the composed row) -> P.. -> P2 -> Q
        lda ringS                   ; the composed row is the 80 chars above the window
        sec
        sbc #<ROWCHARS
        sta w16
        lda ringS+1
        sbc #0
        bpl :+                      ; negative: C = 0 (the borrow), A = $FF
        lda w16                     ; + RINGCHARS
        adc #<RINGCHARS
        sta w16
        lda #>(RINGCHARS-$100)      ; $FF + >RINGCHARS + C
        adc #0
:       sta w16+1
        jsr @addr
        lda wfine
        eor #7                      ; 7 - f: A's R9
        sta SECTAB+8+3,x
        clc
        adc #1                      ; 8-f lines of it
        jsr @dur                    ; X = A's entry
        stz SECTAB+2,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda ringS                   ; the run starts one row into the window (C = 0: @dur's adc #8)
        adc #<ROWCHARS
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
  .if BHW
        ldy barq                    ; the ring row the run starts on
        iny
        cpy #RINGROWS
        bcc :+
        ldy #0
:       sty tmp3
  .endif
        lda #VISROWS-1
        sta tmp4                    ; rows in the run
        bne @run                    ; always: A = VISROWS-1
@coarse:                            ; ---- f = 0: T -> P.. -> Q
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        lda #VISROWS
        sta tmp4
  .if BHW
        lda barq
        sta tmp3
  .endif
@run:   ; w16 = the run's ring offset, tmp4 = its rows, X = the entry before it
  .if BHW
        ; rows of the run that end before the ring end: the run starts on
        ; ring row tmp3; r = ringS mod 80 non-zero -> the last ring row straddles
        ldy barq
        lda ringS
        sec
        sbc mulrowlo,y              ; r
        cmp #1                      ; C = 1 iff r > 0
        lda #RINGROWS-1
        bcs :+
        adc #0                      ; r == 0: C is clear here, so this adds 1
        adc #1
:       sec
        sbc tmp3
        cmp tmp4
        bcs @one                    ; the whole run fits
        tay                         ; Z from A (Y is dead: @emit's @addr reloads it)
        beq @one                    ; it starts inside the straddling row: all of it folds
        sta tmp2
        jsr @emit                   ; up to the ring end
        lda tmp2
        jsr @advance
        lda tmp4
        sec
        sbc tmp2
        sta tmp4
  .endif
@one:   lda tmp4
        sta tmp2
        jsr @emit
        lda tmp4
        jsr @advance                ; now the row below the playfield
        jsr @addr                   ; the row below the playfield: P2's start, or Q's
        lda wfine
        beq @sq2
        ; --- P2: the top f lines of that row
        jsr @dur                    ; X = P2's entry
        stz SECTAB+2,x              ; A dead: reloaded next
        lda wfine
        sbc #0                      ; C = 0 from @dur's adc #8: f - 1
        sta SECTAB+3,x
        lda #VISROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda SECTAB-8,x              ; w16 has not moved: the address the P2 @addr left
        sta SECTAB,x                ; in the previous entry is this one's too
        lda SECTAB-8+1,x
        sta SECTAB+1,x
@sq2:   txa
        clc
        adc #8
        tax
        lda #<(40*LINE-2)           ; the previous section's T1 and Q's
        sta SECTAB-8+6,x
        sta SECTAB+6,x
        lda #>(40*LINE-2)
        sta SECTAB-8+7,x
        sta SECTAB+7,x
        lda #>BARCRTC               ; Q hands the chain back to the bar
        sta SECTAB,x
        lda #<BARCRTC
        sta SECTAB+1,x
        lda #QROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #0
        sta SECTAB+4,x
        lda #QVSYNC
        sta SECTAB+5,x
  .if BARLEAD
        ; the bar's step fired BARLEAD early, so the section after the bar -- whose
        ; duration entry 0 carries -- runs BARLEAD longer to end where it should
        ldx curbuf
        beq @e0
        ldx #48
@e0:    lda SECTAB+6,x
        adc #BARLEAD+STEPLATE       ; C = 0: the last carry-writer was @sq2's adc #8 (and
                                    ;  the steps after the D step's fire STEPLATE later)
        sta SECTAB+6,x
        bcc @e1
        inc SECTAB+7,x
@e1:
  .endif
        rts
@cbl:   .byte <CRTCB_A, <CRTCB_B
@cbh:   .byte >CRTCB_A, >CRTCB_B
  .if BHW
@cml:   .byte <(CRTCB_A-RINGCHARS), <(CRTCB_B-RINGCHARS)
@cmh:   .byte >(CRTCB_A-RINGCHARS), >(CRTCB_B-RINGCHARS)
  .endif
; --- emit a run of tmp2 rows starting at ring offset w16, following entry X
@emit:  jsr @addr
        lda tmp2
        jsr @lines                  ; X = the run's entry
        lda tmp2
        sbc #0                      ; C = 0 out of the adc: tmp2 - 1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #30
        sta SECTAB+4,x
        sta SECTAB+5,x
        rts
; --- SECTAB+0/1,x = the CRTC address of the row at ring offset w16.  On the Model B a
; row starting past RINGCHARS-80 straddles the ring end and is read from the mirror
; below the base, which is exactly the address w16 - RINGCHARS names.
@addr:  lda w16
        ldy w16+1
  .if BHW
        cpy #>(RINGCHARS-ROWCHARS+1)
        bcc :++
        bne :+
        cmp #<(RINGCHARS-ROWCHARS+1)
        bcc :++
:       clc
        adc crtcbm
        sta SECTAB+1,x
        tya
        adc crtcbm+1
        sta SECTAB,x
        rts
:                                   ; (C = 0: both ways here are a bcc)
  .else
        clc
  .endif
        adc crtcb
        sta SECTAB+1,x
        tya
        adc crtcb+1
        sta SECTAB,x
        rts
        ; --- A = rows -> A/tmp3 = that many rows of lines, as a T1 count
@lines: asl
        asl
        asl
        jmp @dur
        ; --- A = rows: advance w16 by that many rows, folding into 0..RINGCHARS
@advance:
        tay
        clc
        lda w16
        adc mulrowlo,y
        sta w16
        lda w16+1
        adc mulrowhi,y
        sta w16+1
@wrap:                              ; A = w16+1: both ways in have just stored it
        cmp #>RINGCHARS
        bcc :++
        bne :+
        lda w16
        cmp #<RINGCHARS
        bcc :++
:       lda w16                     ; C = 1: both ways here
        sbc #<RINGCHARS
        sta w16
        lda w16+1
        sbc #>RINGCHARS
        sta w16+1
:       rts
        ; --- A = lines, X = an entry -> its T1lo/T1hi (SECTAB+6/7,x) = the T1 count
        ; that lasts that long (tmp3 = the high byte); then X = the next entry (C = 0)
@dur:   lsr                         ; n*64 == (n*256)>>2
        sta tmp3
        lda #0
        ror
        lsr tmp3
        ror
        sbc #1                      ; C = 0 out of the ror pair: A - 2
        bcs :+
        dec tmp3
:       sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        rts

        .segment "KRNCODE"
; menu_sections: the menus' frame.  build_sections, then buffer 0's first section (the
; bar's, in play) shows two ring rows below the window instead: the menus never draw
; there and clear_ring has made them black, so the menus look as they did but the bar
; is neither shown nor touched while they run -- it is laid once and left in place.
MENUBAR  = (RING0 + VISROWS*ROWBYTES) / 8
        .assert VISROWS + BARROWS <= RINGROWS, error, "the menus' bar rows must be in the ring"
menu_sections:
        jsr build_sections
        lda #>MENUBAR
        sta BUF_SEC0
        lda #<MENUBAR
        sta BUF_SEC0+1
        rts

; ---------------------------------------------------------------- load mode
; A disc load stops the chain: the loader runs with interrupts off (disc.s).  Stopped
; mid-chain the CRTC repeats whatever section
; it was in -- a few lines over and over, no vsync -- and monitors and capture cards
; drop out of sync and take seconds to come back, so a level's first moments are
; missed.  So a load first asks the chain to stop at a frame boundary: the next bar
; step programs a standard 39-row frame instead of the bar, with the vsync on the
; row the chain puts it, so the sync never moves, and turns the T1 interrupt off.
; The palette is black throughout, so what the frame shows does not matter.
; The load's end (ldprog.s ld_resume) lets the next vsync re-arm the chain: its
; re-phase writes R4 = curR7 + QROWS-1-QVSYNC, which with curR7 = LDR7 is the standard frame's own total, and the
; bar step at that frame's end takes the display back as if it had never stopped.
LDR4 = BARROWS + VISROWS + QROWS - 1      ; 38: a standard 312-line frame
LDR7 = BARROWS + VISROWS + QVSYNC         ; the row the chain's vsync is on
; On both machines the switch is the interrupt's bar step (@ldsw), so it happens at the frame boundary however
; long the handler's other work runs.  (Polling for the bar's T1 with interrupts off
; does not: when the vsync's own work runs past that T1, the switch lands one section
; late and makes a short frame.)
load_begin:
        lda #1
        sta LOADREQ
:       lda LOADREQ
        cmp #2
        bne :-
        rts

; ============================================================================
; calc_ring: ringS = ((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS ; barq = ringS / 80
; ============================================================================
        .segment "KRNCODE"          ; the kernel, with the row multiples
calc_ring:
        lda wcy
        ringmod7
        tax
        lda mulrowlo,x
        clc
        adc wcx
        sta ringS
        lda mulrowhi,x
        adc wcx+1
        sta ringS+1
        cmp #>RINGCHARS
        bcc :+
        bne @sub
        lda ringS
        cmp #<RINGCHARS
        bcc :+
@sub:   lda ringS
        sec
        sbc #<RINGCHARS
        sta ringS
        lda ringS+1
        sbc #>RINGCHARS
        sta ringS+1
:       ; q = S / 80
        lda ringS                   ; running value: low in A, high in Y
        ldy ringS+1
        ldx #$FF                    ; quotient, pre-decremented
        sec                         ; the loop's own bcs guarantees C=1 all the way
@div:   inx                         ; round, so the only entries needing a sec are
        sbc #ROWCHARS               ; this one and the one after a borrow
        bcs @div                    ; no borrow: high byte unchanged, value still >= 0
        sec                         ; dey does not touch the carry
        dey
        bpl @div                    ; borrow absorbed by the high byte
@dd:    stx barq                    ; high byte went negative: X is the quotient
  .if BHW
        adc #ROWCHARS-1             ; C = 1 (the sec before dey): A + 80, the remainder,
        sta wcxm                    ; where the window starts in its slot
        lda #RINGROWS-1             ; the window row that lives in the last slot, and
        sbc barq                    ; the map row it shows.  C = 1: the adc carried
        clc
        adc wcy
        sta mrow
  .endif
        rts

; ============================================================================
; The interrupt: the rupture chain's steps (T1) and the vsync.  One body, placed with
; its state (PLACEH): the Master's handler itself, in main RAM (irq_handler, at
; IRQ1V); the Model B's isr_body in bank 7, which the stub in low RAM (low.s
; irq_handler) pages in around it, saving X and Y and stepping the title tune after.
; ============================================================================
        PLACEH "CODE", "KRNCODE"
  .if BHW
isr_body:
  .else
irq_handler:
        stx irq_x
        sty irq_y
  .endif
        bit VIA_IFR
        bvs @t1arm                  ; the T1 arm grew past bvc's reach: one cycle each way
        jmp @notT1
@t1arm: ; ---- rupture chain step.  This is a CRTC restart: the next section's address
        ; was armed during the previous one and is latched at the boundary.  What the
        ; new section needs quickly is its shape.  R9 and R4 together decide where the
        ; section ENDS: the CRTC latches end-of-frame at the start of the scanline
        ; where row = R4 and line = R9, so for a 2-line section (a partial with
        ; R9 = 1) both must be in place before the start of scanline 1 -- 128 cycles
        ; after the restart.  R6 is compared from scanline 1 on, so Q's R6 = 0 has
        ; the same deadline.  Everything else has a row or more to spare.  The chain is
        ; phased (VS2T) so the step fires ~50 cycles BEFORE the restart, the
        ; hold below (the Master's; the Model B's stub takes as long) carries the first
        ; write past it, and the three deadline registers
        ; then land about 40, 60 and 80 cycles in, with the rest behind them.  Writing
        ; R4 third put it at ~140 for a 2-line P2: that section never ended, Q's R6
        ; hit never came, and both borders lit up on every scroll frame.
        ; R12/R13 go LAST, after the T1 reload and the index bookkeeping, so they land
        ; on scanline 1 (measured: ~140-175 cycles in).  Written straight after R7 they
        ; fell at ~105-125, across the end of scanline 0 -- and on a partial (R4 = 0,
        ; written on row 0 = its last row) some 6845s end the frame at once, the VL6845
        ; among them (Tom Seddon's r4-3), and reload the start address as that scanline
        ; ends: a Master with such a chip lost the R12 write and showed the playfield
        ; from A's high byte with P's low byte, 256 chars adrift, a 16-char tear down
        ; every row whenever the fine scroll was not 0.  Two-line sections still have
        ; 80 cycles in hand before the next restart.
        ; ACCCON D is different again: it is the memory map, sampled by every fetch,
        ; so it must be in place BEFORE the boundary -- the bar's T1 fires a further
        ; BARLEAD us early so D lands in the horizontal blanking of the bar's last line.
        lda LOADREQ
        beq @chain
        jmp @ldcheck                ; a load asked for, under way or ending: load_begin
@chain: ldx SECIDX
  .if .not BHW
        cpx DSECT                   ; the step after the bar's switches D to the displayed
        bne @noD                    ; buffer's -- before the boundary -- then holds so its
        lda ACCCON                  ; first CRTC write follows the restart.  Every other
        and #$FE                    ; step needs neither (D is 0 for the bar from the
        ora dispD                   ; vsync, and already right after it): it fires later
        sta ACCCON                  ; instead, by STEPLATE (the bar's by BARLATE), and
        ldy #5                      ; spends nothing waiting
@hold:  dey
        bne @hold
@noD:
  .endif
        lda #9
        sta CRTC_IDX
        lda SECTAB+3,x
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda SECTAB+2,x
        sta CRTC_DAT
        lda #6
        sta CRTC_IDX
        ldy SECTAB+4,x
        sty CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda SECTAB+5,x
        sta CRTC_DAT
        sta curR7                   ; the vsync handler re-phases the frame from this
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear T1 flag
        ; next entry; the chain stops at Q, the only entry whose R7 is the vsync row: a
        ; late vsync must not walk the chain off the end of SECTAB.  Every other
        ; section's R7 is 30, so C = 1 on the way past, as the adc below needs.
        lda curR7                   ; R7, just written
        cmp #QVSYNC
        beq :+
        txa
        adc #7                      ; C is set (30 >= QVSYNC), so this adds 8
        sta SECIDX                  ; (X still indexes this entry for R12/R13 below)
:       lda #12                     ; the next section's address, last: see above
        sta CRTC_IDX
        lda SECTAB,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda SECTAB+1,x
        sta CRTC_DAT
@xit:
  .if BHW
        jmp irq_ret                 ; to the stub (low.s)
  .else
        ldy irq_y                   ; @exit inlined: no jmp on the chain-step path
        ldx irq_x
        lda $FC
        rti
  .endif
@ldcheck:
        cmp #1
        bne @ldt1
        ldx SECIDX                  ; stop asked: only the bar step, a frame boundary,
        cpx DISPSECT                ; makes the switch
        beq @ldsw
        jmp @chain
@ldsw:  ; ---- this restart is a standard frame, not the bar: see load_begin.  R9 = 7
        ; and R6 = BARROWS are the vsync's pre-arm already, and R12/R13 hold the bar.
        lda #4                      ; (the bar's step fires BARLATE later: no hold)
        sta CRTC_IDX
        lda #LDR4
        sta CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda #LDR7
        sta CRTC_DAT
        sta curR7                   ; the resume's first vsync re-phases to LDR4 from this
        lda #$40
        sta VIA_IER                 ; T1 off: the chain is stopped
        lda VIA_T1CL
        lda #2
        sta LOADREQ
        bne @xit                    ; (Z = 0: lda #2)
@ldvsync:                           ; stopped: the standard frame free-runs; count the
        inc vsyncs                  ; vsync and keep the keys and the sound alive
        jmp @sk
@ldt1:  lda VIA_T1CL                ; stopped or ending: T1 runs on with its interrupt
                                    ; off, so its flag is stale: was this the vsync?
        bit irq_x                   ; (a 3-cycle pad for the jmp it replaces)
@notT1:
        lda VIA_IFR
        and #$02
        bne :+
        beq @xit                    ; (Z = 1: the bne fell through)
:       ; ---- vsync: restart T1 first (constant latency), counter = vsync->T.  The
        ; latch (how long section 0 lasts) is programmed further down, after the
        ; flip: section 0 belongs to the buffer that is about to be displayed.
        lda #<VS2T                  ; (an immediate: VS2T allows for its timing)
        sta VIA_T1LL
        lda #>VS2T
        sta VIA_T1CH
        lda #$02
        sta VIA_IFR
        lda LOADREQ                 ; (after the restart: it sets the chain's phase)
        cmp #2
        beq @ldvsync                ; stopped: T1 runs on with its interrupt off
        cmp #3
        bne :+
        stz LOADREQ                 ; resume: T1's interrupt on again, below
:       lda #$C0
        sta VIA_IER
        ; re-phase: the vsync fired at row curR7, so end this frame at row
        ; curR7 + QROWS-1-QVSYNC with 8-line rows -> T starts exactly QROWS-QVSYNC rows
        ; after the vsync even if the CRTC row counter had run past its vertical total
        ; (which otherwise never recovers)
        lda #9
        sta CRTC_IDX
        lda #7
        sta CRTC_DAT
        lda #6                      ; pre-arm the bar's R6 now, in Q, where the display
        sta CRTC_IDX                ; is already off and a new R6 cannot show: the step
        lda #BARROWS                ; at the bar's start is too close to the second
        sta CRTC_DAT                ; scanline to be trusted with it
        lda #4
        sta CRTC_IDX
        lda curR7
        clc
        adc #QROWS-1-QVSYNC
        and #$7F
        sta CRTC_DAT
        inc vsyncs
        lda flipreq
        beq @noflip
        lda vsyncs
        sec
        sbc flipvs
        cmp #2
        bcc @noflip
        lda vsyncs
        sta flipvs
        lda NEXTSECT
        sta DISPSECT
  .if .not BHW
        lda NEXTBUF                 ; the flip is the section chain moving to the other
        sta dispD                   ; buffer's rows; D follows it, but only from the
  .endif                            ; first playfield section -- the bar needs D = 0
        stz flipreq
@noflip:
        ; everything section 0 needs comes from the buffer that is about to be
        ; displayed -- its start address (menu_sections moves it) and its length
        ldx #0
        ldy DISPSECT                ; held in Y: SECIDX wants the same byte below
        beq :+
        ldx #2
:       lda BUF_SEC0T1,x
        sta VIA_T1LL
        lda BUF_SEC0T1+1,x
        sta VIA_T1LH
        lda #12
        sta CRTC_IDX
        lda BUF_SEC0,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda BUF_SEC0+1,x
        sta CRTC_DAT
        lda #$40
        sta VIA_IFR
        sty SECIDX
  .if .not BHW
        tya                         ; the step after the bar's (DSECT: the chain step)
        clc
        adc #8
        sta DSECT
        lda #1                      ; the bar is below $3000: it is only main RAM to the
        trb ACCCON                  ; CRTC while D = 0
  .endif
@sk:    jsr scan_keys
  .if GAMESOUND                     ; the game's player (resident); the tune's step is
        jsr hook_sound              ; raised here, as the engine's sound_tick does
        lda MUSON
        sta MUSTICK
    .if BHW
        jmp irq_vret                ; (the stub steps the tune)
    .endif
  .elseif BHW
        jsr sound_tick
        jmp irq_vret                ; (the stub steps the tune)
  .else
        jsr sound_tick
  .endif
  .if .not BHW
        lda MUSTICK                 ; the menus' image, stepped as the Model B's
        beq @exit                   ; interrupt stub does (low.s)
        dec MUSTICK
        lda ROMSEL_CPY
        pha
        ldpbank lda, BANK_LVL       ; (the handler is in main RAM, loaded unpatched: PBANK)
        sta ROMSEL_CPY
        sta ROMSEL
        jsr music_tick
        pla
        sta ROMSEL_CPY
        sta ROMSEL
@exit:
        ldy irq_y
        ldx irq_x
        lda $FC
        rti
  .endif

; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO its
; section; the further -36 puts it ~30 us before the restart, so that the shape
; registers land early in the first scanline -- see the chain step above.  -8: the
; step's load-flag test; +2 (ticks): the vsync loads it as immediates, 4 cycles sooner
; than from memory.  The Model B's stub pages bank 7 in (pagelogic inlined: no write
; bank, the interrupt stores into none) before the body, which makes both the vsync's
; T1 restart and every step later -- STUBLAT ticks in all -- where the Master's
; handler holds instead.
  .if BHW
STUBLAT = 18 - 22 - 4               ; (22: the stub's pagelogic inlined, jmp for jsr; 4: its write bank gone, twice)
  .else
STUBLAT = -BARLATE                  ; (the bar's step fires later: no hold in it)
  .endif
VS2T = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36 - STUBLAT - 8 + 2

; ---------------------------------------------------------------- keyboard
        PLACEH "CODE", "KRNCODE"    ; the interrupt's own work: bank 7 with the Model B's
scan_keys:                          ; handler, main RAM with the Master's
        lda #$7F
        sta VIA_DDRA
        lda #3
        sta VIA_ORB                 ; disable keyboard autoscan
        stz keys                    ; built in place: the interrupt is atomic to its readers
        ldx #KEYN-1
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+
        lda keybits,x
  .if BHW
        ora keys
        sta keys
  .else
        tsb keys
  .endif
:       dex
        bpl @k
        rts
        .include "keymap.inc"       ; the game's: keytab (KEYN key numbers), keybits
                                    ; (the K_ bits each sets); README.md

; ---------------------------------------------------------------- sound
  .if .not GAMESOUND                ; (GAMESOUND: the game's hook_sound instead)
; sfx format: steps of (b0,b1,b2,frames) written to the SN76489 ; end = $FF
sound_tick:
        lda SFXREQ
        beq @play
        ; start new sfx
        asl
        tax
        stz SFXREQ                  ; (Model B: A = 0 -- the index is in X)
        lda sfxtab-2,x
        sta SFXPTR
        lda sfxtab-1,x
        sta SFXPTR+1
        bne @go                     ; an sfx is never in page 0: straight to its first step
@play:  lda SFXPTR+1
        beq @music
        dec SFXDUR
        bne @music
@go:    ldaz SFXPTR                 ; (zp): the first byte needs no index
        cmp #$FF
        beq @end
        jsr sndwrite
        ldy #1
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        sta SFXDUR
        lda SFXPTR

        adc #4
        sta SFXPTR
        bcc @music
        inc SFXPTR+1
        bne @music                  ; SFXPTR+1 <> 0 after the inc
@end:   jsr sndwrite                ; A = $FF (the end mark): noise off
        lda #$DF                    ; channel 2 off
        jsr sndwrite
        stz SFXPTR+1
@music:
        lda MUSON                   ; the tune is stepped at the interrupt's tail (the
        sta MUSTICK                 ; Model B's stub in low.s, the Master's handler): its
        rts                         ; player is in the menus' image.  Only raised here,
                                    ; at the vsync: the T1 steps share that tail
  .ifdef DBGSND
@dbgsil: .byte $9F, $BF, $FF, 0
  .endif
  .endif

sndwrite:
        pha
        lda #$FF
        sta VIA_DDRA
        lda #$0B
        sta VIA_ORB                 ; keyboard autoscan on so the keyboard does not pull PA7
        pla
        sta VIA_ORANH
        lda #0
        sta VIA_ORB
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        lda #8
        sta VIA_ORB
        lda #$7F
        sta VIA_DDRA
        rts

        .segment "KRNCODE"          ; (the kernel stops it: the menus' image may be gone)
music_stop:
  .if BHW
        lsr MUSON                   ; MUSON is 0 or 1: 6 cycles, as lda #0 / sta
  .else
        stz MUSON
  .endif
        lda #$9F
        jsr sndwrite
        lda #$BF
        jsr sndwrite
        lda #$DF
        jsr sndwrite
        lda #$FF
        jmp sndwrite

        .segment "KRNCODE"          ; the kernel (the menus call it too)
set_palette:
        ; MODE 1: a screen pixel's two bits land in bits 3 and 1 of the palette index, the other
        ; two bits are don't-cares, so all 16 entries are written: logical 0..3 = K C M Y
        ldx #15
:       txa
        lsr
        lsr                         ; C = bit 1
        and #2                      ; bit 3, as bit 1
        adc #0                      ; + bit 1: the logical colour
        tay
        txa
        asl
        asl
        asl
        asl
        ora @cmyk,y
        sta ULA_PAL
        dex
        bpl :-
        rts
@cmyk:  .byte 0^7, 6^7, 5^7, 3^7    ; physical black, cyan, magenta, yellow (inverted)

blank_palette:
        lda #$F7                    ; (i << 4) | 7, i = 15 down to 0
        sec
:       sta ULA_PAL
        sbc #$10
        bcs :-
        rts

        .segment "KRNCODE"
; the kernel's ringaddr, for the sprite prologue, copy_partial, blank_below and the
; menus: the ring modulus by subtraction (no table this side), the row multiple from
; the kernel's mulrowlo/hi, and on the Model B the buffer's base from select_backbuf
; (both bases are xx80: ringbhi is the page).  C = 0 in: the Master's modulus (and
; #31) leaves the caller's carry for the add, where the Model B's leaves it clear
ringaddr7:
        ringmod7
        tax
        lda mulrowlo,x              ; slot * 80 + cx (C = 0: ringmod7 leaves by its bcc)
        adc w16
        sta sp
        lda mulrowhi,x
        adc w16+1
        asl sp                      ; x 8, the high byte kept in A
        rol
        asl sp
        rol
        asl sp
        rol                         ; C = 0: bit 13 of the char (< 8192)
        pha
        lda sp
  .if BHW
        adc #<RING_A
        sta sp
        pla
        adc ringbhi
  .else
        adc #<RINGBASE
        sta sp
        pla
        adc #>RINGBASE
  .endif
        ringup sp
        sta sp+1
        rts
