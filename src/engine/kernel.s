; ============================================================================
; engine/kernel.s -- the kernel: the rupture chain, the interrupt, keys and sound
;
; The kernel is the resident part of bank 7: the top of the bank on both machines,
; there whichever image (the game's or the menus') is swapped in below it, so the menus
; build their frame with it too.  The interrupt's own work -- the handler body,
; scan_keys, sound_tick, sndwrite -- is placed with PLACEH: in the kernel (KRNCODE) on
; the Model B, whose low-RAM stub (low.s) pages bank 7 in around it, and in main RAM
; (CODE) on the Master, whose handler sits at IRQ1V itself.
;
; The display is a rupture: each frame is several CRTC frames ("sections": the bar,
; the composed row, the playfield, the bottom partial, the blanking), reprogrammed
; from a chain of VIA T1 interrupts and re-phased at every vsync.  docs/DESIGN.md
; ("The chain", "Load mode") has the whole story; the timing notes are here.
;
;   build_sections  fill the current buffer's SECTAB entries from ringS and wfine
;   menu_sections   build_sections, with section 0 moved off the bar (the menus)
;   load_begin      park the CRTC in a standard frame before a disc load
;   calc_ring       ringS and barq (and the Model B's wcxm, mrow) from wcx, wcy
;   isr_body        the interrupt: a chain step (T1) or the vsync (CA1)
;                   (irq_handler on the Master)
;   scan_keys       the keyboard into keys
;   sound_tick      step the sound effect; raise the tune's step (not with GAMESOUND)
;   sndwrite        write A to the SN76489
;   music_stop      stop the tune and silence all four channels
;   set_palette     the MODE 1 palette: logical 0..3 = black, cyan, magenta, yellow
;   blank_palette   every palette entry black
;   ringaddr7       the screen address of a ring character, from bank 7
;
; Segments: KRNCODE, and PLACEH "CODE", "KRNCODE" for the interrupt's work.
; ============================================================================

; ============================================================================
; build_sections: fill SECTAB for the current buffer from ringS and wfine
;   In:   curbuf, ringS, wfine;  barq (Model B)
;   Out:  the buffer's SECTAB entries (48 bytes from SECTAB + curbuf*48), and its
;         BUF_SEC0/BUF_SEC0T1 (the bar's address and length, at curbuf*2);
;         crtcb (and the Model B's crtcbm) = the buffer's CRTC base
;   Clobbers A, X, Y, w16, tmp2, tmp3, tmp4.
;
; An entry is 8 bytes:
;   +0 R12, +1 R13   the NEXT section's start address (high byte first)
;   +2 R4, +3 R9, +4 R6, +5 R7    this section's shape
;   +6 T1lo, +7 T1hi the NEXT section's duration, as a T1 latch value
; The shape is section i's; the address and duration are section i+1's, because
; R12/R13 latch at the next restart and the T1 latch takes effect one interrupt later.
;
; The sections, top to bottom:
;   T   bar          2 rows, fixed home
;   A   composed row 8-f lines, the fine scroll                (only when f > 0)
;   P   playfield    VISROWS rows from the window's slot; the Model B's software
;                    ring splits it at the ring's end (P1, then M from the mirror
;                    below the ring base), the Master's CRTC folds its ring itself
;   P2  bottom       f lines                                   (only when f > 0)
;   Q   blanking     QROWS rows, vsync at row QVSYNC
; Section 0 (T) takes its address and length from BUF_SEC0/BUF_SEC0T1, which the
; vsync programs; the chain stops at Q (the interrupt, below).
;
; The Master's step timing (all 0 on the Model B), in us (T1 ticks):
;   BARLEAD   10  the T1 that ends the bar fires this much early, beyond the lead every
;                 step has, so the step after the bar's can switch ACCCON D in the
;                 blanking of the bar's last line.  The section after the bar (entry
;                 0's duration) runs BARLEAD longer to end where it should.
;   BARLATE   13  the bar's step fires this much later than when its hold carried it
;                 (26 cycles): it has no hold now.
;   STEPLATE  20  so does every step after the one that switches D (39 cycles: the D
;                 write and the hold).
; VS2T, the bar's length and entry 0's duration carry them.
; ============================================================================
  .if BHW
BARLEAD = 0
BARLATE = 0
STEPLATE = 0
  .else
BARLATE = 13
STEPLATE = 20
BARLEAD = 23
QLEAD = 6                           ; Q's step: D lands in the blanking before Q (crtctime)
P2EARLY = 12                        ; a bottom partial's step: early enough behind a 2-line one
  .endif
        .segment "KRNCODE"          ; the kernel: the menus build their frame with it too
build_sections:
        ; ---- the buffer's CRTC base, and the Model B's mirror redirect (the same less
        ;      the ring)
        ldx curbuf
        lda @cbl,x
        sta crtcb
        lda @cbh,x
        sta crtcb+1
  .if BHW
        lda @cml,x
        sta crtcbm
        lda @cmh,x
        sta crtcbm+1
  .endif
        ; ---- section 0 is the bar: a fixed address and length, in BUF_SEC0/BUF_SEC0T1
        txa                         ; X = curbuf still (ldx curbuf above)
        asl
        tax
        lda #>BARCRTC
        sta BUF_SEC0,x
        lda #<BARCRTC
        sta BUF_SEC0+1,x
        lda #<(BARROWS*8*LINE-2-BARLEAD-BARLATE)
        sta BUF_SEC0T1,x
        lda #>(BARROWS*8*LINE-2-BARLEAD-BARLATE)
        sta BUF_SEC0T1+1,x
        ; ---- X = entry 0 of the buffer (0 or 48); the bar's shape
        txa                         ; Z from X = curbuf*2
        beq :+
        ldx #48
:       lda #BARROWS-1
        sta SECTAB+2,x              ; R4
        lda #7
        sta SECTAB+3,x              ; R9
        lda #BARROWS
        sta SECTAB+4,x              ; R6
        lda #30
        sta SECTAB+5,x              ; R7
        lda wfine
        beq @coarse

        ; ---- f > 0: T -> A (the composed row) -> P.. -> P2 -> Q
        ;      A is the 80 chars above the window: w16 = ringS - 80, folded into the ring
        lda ringS
        sec
        sbc #<ROWCHARS
        sta w16
        lda ringS+1
        sbc #0
        bpl :+
        lda w16                     ; negative: C = 0 (the borrow), A = $FF
        adc #<RINGCHARS             ; + RINGCHARS
        sta w16
        lda #>(RINGCHARS-$100)      ; $FF + >RINGCHARS + C
        adc #0
:       sta w16+1
        jsr @addr                   ; A's address, into entry 0
        lda wfine
        eor #7                      ; 7 - f: A's R9
        sta SECTAB+8+3,x
        clc
        adc #1                      ; 8-f lines of it
        jsr @dur                    ; A's duration into entry 0; X = A's entry
        stz SECTAB+2,x              ; R4 = 0: one row
        lda #2
        sta SECTAB+4,x              ; R6
        lda #30
        sta SECTAB+5,x              ; R7
        ;      the run starts one row into the window (C = 0: @dur's adc #8)
        lda ringS
        adc #<ROWCHARS
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
  .if BHW
        ldy barq                    ; the ring row the run starts on: barq+1,
        iny                         ; folded
        cpy #RINGROWS
        bcc :+
        ldy #0
:       sty tmp3
  .endif
        lda #VISROWS-1
        sta tmp4                    ; rows in the run
        bne @run                    ; always: A = VISROWS-1

        ; ---- f = 0: T -> P.. -> Q
@coarse:
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

        ; ---- the playfield run.  w16 = its ring offset, tmp4 = its rows, X = the entry
        ;      before it (tmp3 = the ring row it starts on, Model B)
@run:
  .if BHW
        ; Model B: the rows of the run that end before the ring end.  With
        ; r = ringS mod 80 non-zero the last ring row straddles the end, so the rows
        ; that fit are RINGROWS-1 - tmp3; with r = 0, RINGROWS - tmp3.
        ldy barq
        lda ringS
        sec
        sbc mulrowlo,y              ; r
        cmp #1                      ; C = 1 iff r > 0
        lda #RINGROWS-1
        bcs :+
        adc #1                      ; r == 0 (C = 0 here): the whole last row fits too
:       sec
        sbc tmp3
        cmp tmp4
        bcs @one                    ; the whole run fits
        tay                         ; Z from A (Y is dead: @emit's @addr reloads it)
        beq @one                    ; starts in the straddling row: all of it folds
        sta tmp2
        jsr @emit                   ; P1: up to the ring end
        lda tmp2
        jsr @advance
        lda tmp4                    ; the rest, M, from the mirror
        sec
        sbc tmp2
        sta tmp4
  .endif
@one:   lda tmp4
        sta tmp2
        jsr @emit
        lda tmp4
        jsr @advance                ; now the row below the playfield
        jsr @addr                   ; ... P2's start, or Q's
        lda wfine
        beq @sq2

        ; ---- P2: the top f lines of that row
        jsr @dur                    ; A = f lines; X = P2's entry
        stz SECTAB+2,x              ; R4 = 0 (A dead: reloaded next)
        lda wfine
        sbc #0                      ; C = 0 from @dur's adc #8: f - 1
        sta SECTAB+3,x              ; R9
        lda #VISROWS
        sta SECTAB+4,x              ; R6
        lda #30
        sta SECTAB+5,x              ; R7

        ; ---- Q: blanking and the vsync; it hands the chain back to the bar.  Its
        ; start (entry X's next address) is a black line whatever the fine scroll:
        ; a 6845 shows a frame's first scanline whatever R6 says, so Q's line 0 is
        ; one line more under the picture -- as the next map row it would be junk
        ; at the map's bottom, and a repeat of P2's first line under a fine scroll.
        ; (QBLANK: defs.s -- the Master's 640 zeroed bytes below the bar; the Model
        ; B's own bar, until its palette can blank that scanline.)
@sq2:   lda #>(QBLANK / 8)
        sta SECTAB,x
        lda #<(QBLANK / 8)
        sta SECTAB+1,x
        txa                         ; X = Q's entry
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
        sta SECTAB+2,x              ; R4
        lda #7
        sta SECTAB+3,x              ; R9
        lda #0
        sta SECTAB+4,x              ; R6 = 0: display off
        lda #QVSYNC
        sta SECTAB+5,x              ; R7: the only entry whose R7 is this
  .if .not BHW
        ; ---- the Master: Q's step puts D back to 0 before Q's first scanline (QBLANK is
        ;      main RAM: under $3000, D = 1 would read HAZEL/ANDY), so like the D step
        ;      it fires early, by QLEAD: the section before Q -- whose duration the entry
        ;      before that carries -- runs STEPLATE + QLEAD shorter.  The vsync takes
        ;      this buffer's Q entry from BUF_QS into QSECT.
        txa
        ldy curbuf
        beq @q0
        ldy #2
@q0:    sta BUF_QS,y
        lda SECTAB-16+6,x
        sec
        sbc #STEPLATE+QLEAD
        sta SECTAB-16+6,x
        bcs @q1
        dec SECTAB-16+7,x
@q1:    lda wfine                   ; and a bottom partial's step fires P2EARLY early
        beq @q3                     ; (its writes still follow its restart), so the
        lda SECTAB-24+6,x           ; step before Q's is done in time behind a two-line
        sec                         ; one: P ends P2EARLY sooner, P2 runs it longer
        sbc #P2EARLY
        sta SECTAB-24+6,x
        bcs @q2
        dec SECTAB-24+7,x
@q2:    lda SECTAB-16+6,x
        clc
        adc #P2EARLY
        sta SECTAB-16+6,x
        bcc @q3
        inc SECTAB-16+7,x
@q3:    clc                         ; (the BARLEAD block's adc wants C = 0)
  .endif
  .if BARLEAD
        ; ---- the Master: the T1 that ends the bar fired BARLEAD early, so the section
        ;      after the bar -- whose duration entry 0 carries -- runs BARLEAD longer to
        ;      end where it should; and the steps after the D step's fire STEPLATE later
        ldx curbuf
        beq @e0
        ldx #48
@e0:    lda SECTAB+6,x
        adc #BARLEAD+STEPLATE       ; C = 0 (@q1's clc)
        sta SECTAB+6,x
        bcc @e1
        inc SECTAB+7,x
@e1:
  .endif
        rts

        ; ---- the buffers' CRTC bases, and the Model B's mirror redirects
@cbl:   .byte <CRTCB_A, <CRTCB_B
@cbh:   .byte >CRTCB_A, >CRTCB_B
  .if BHW
@cml:   .byte <(CRTCB_A-RINGCHARS), <(CRTCB_B-RINGCHARS)
@cmh:   .byte >(CRTCB_A-RINGCHARS), >(CRTCB_B-RINGCHARS)
  .endif

; ---- @emit: a run of tmp2 rows starting at ring offset w16, following entry X
;   Out:  its address and duration in entry X; X = the run's entry, its shape filled
@emit:  jsr @addr
        lda tmp2
        jsr @lines                  ; X = the run's entry
        lda tmp2
        sbc #0                      ; C = 0 out of the adc: tmp2 - 1
        sta SECTAB+2,x              ; R4
        lda #7
        sta SECTAB+3,x              ; R9
        lda #30
        sta SECTAB+4,x              ; R6
        sta SECTAB+5,x              ; R7
        rts

; ---- @addr: SECTAB+0/1,x = the CRTC address of the row at ring offset w16
;   Out:  C = 0 (from the add, which cannot carry out);  Y = w16+1
; On the Model B a row starting past RINGCHARS-80 straddles the ring end and is read
; from the mirror below the base, which is exactly the address w16 - RINGCHARS names.
@addr:  lda w16
        ldy w16+1
  .if BHW
        cpy #>(RINGCHARS-ROWCHARS+1)
        bcc :++
        bne :+
        cmp #<(RINGCHARS-ROWCHARS+1)
        bcc :++
:       clc                         ; straddles: from the mirror
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

        ; ---- @lines: A = rows -> entry X's T1 = that many rows of lines (as @dur)
@lines: asl
        asl
        asl
        jmp @dur

        ; ---- @advance: A = rows: advance w16 by that many rows, folding into
        ;      0..RINGCHARS (@wrap: the fold alone)
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

        ; ---- @dur: A = lines, X = an entry -> its T1lo/T1hi (SECTAB+6/7,x) = the T1
        ;      count that lasts that long (tmp3 = the high byte); then X = the next
        ;      entry (C = 0).  A line is 64 T1 ticks; the count is lines*64 - 2.
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

; ----------------------------------------------------------------------------
; menu_sections: the menus' frame
;   Out:  as build_sections, then buffer 0's section 0 moved to MENUBAR
; build_sections, then buffer 0's first section (the bar's, in play) shows two ring
; rows below the window instead: the menus never draw there and clear_ring has made
; them black, so the menus look as they did but the bar is neither shown nor touched
; while they run -- it is laid once and left in place.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
MENUBAR  = (RING0 + VISROWS*ROWBYTES) / 8
        .assert VISROWS + BARROWS <= RINGROWS, error, "the menus' bar rows must be in the ring"
menu_sections:
        jsr build_sections
        lda #>MENUBAR
        sta BUF_SEC0
        lda #<MENUBAR
        sta BUF_SEC0+1
        rts

; ============================================================================
; The load mode
;
; A disc load stops the chain: the loader runs with interrupts off (disc.s).  Stopped
; mid-chain the CRTC repeats whatever section it was in -- a few lines over and over,
; no vsync -- and monitors and capture cards drop out of sync and take seconds to come
; back, so a level's first moments are missed.  So a load first asks the chain to stop
; at a frame boundary: the next bar step programs a standard 39-row frame instead of
; the bar, with the vsync on the row the chain puts it, so the sync never moves, and
; turns the T1 interrupt off.  The palette is black throughout, so what the frame
; shows does not matter.
;
; LOADREQ: 0 running, 1 stop asked (load_begin), 2 stopped (the bar step, @ldsw),
; 3 resume asked (the load's end, ldprog.s ld_resume).  At 3 the next vsync re-arms
; the chain: its re-phase writes R4 = curR7 + QROWS-1-QVSYNC, which with curR7 = LDR7
; is the standard frame's own total, and the bar step at that frame's end takes the
; display back as if it had never stopped.
;
; On both machines the switch is the interrupt's bar step (@ldsw), so it happens at
; the frame boundary however long the handler's other work runs.  (Polling for the
; bar's T1 with interrupts off does not: when the vsync's own work runs past that T1,
; the switch lands one section late and makes a short frame.)
; ============================================================================
LDR4 = BARROWS + VISROWS + QROWS - 1      ; 38: a standard 312-line frame
LDR7 = BARROWS + VISROWS + QVSYNC         ; the row the chain's vsync is on

; ----------------------------------------------------------------------------
; load_begin: ask the chain to stop at the next frame boundary, and wait until it has
;   Out:  LOADREQ = 2;  A = 2
; Interrupts must be on: the interrupt makes the switch.
; ----------------------------------------------------------------------------
load_begin:
        lda #1
        sta LOADREQ                 ; stop asked
:       lda LOADREQ
        cmp #2                      ; stopped?
        bne :-
        rts

; ============================================================================
; calc_ring: the window's place in the ring
;   In:   wcx (16 bits), wcy
;   Out:  ringS = ((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS
;         barq  = ringS / 80, the window's slot
;         Model B: wcxm = ringS mod 80, where the window starts in its slot;
;                  mrow = the map row shown by the window row in the last slot
;   Clobbers A, X, Y.
; ============================================================================
        .segment "KRNCODE"          ; the kernel, with the row multiples
calc_ring:
        ; ---- ringS
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
        cmp #>RINGCHARS             ; fold into 0..RINGCHARS
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
        ; ---- q = S / 80, by repeated subtraction.  The loop's own bcs keeps C = 1 all
        ;      the way round, so the only entries needing a sec are the first and the
        ;      one after a borrow.
:       lda ringS                   ; the running value: low in A, high in Y
        ldy ringS+1
        ldx #$FF                    ; the quotient, pre-decremented
        sec
@div:   inx
        sbc #ROWCHARS
        bcs @div                    ; no borrow: high byte unchanged, value >= 0
        sec                         ; (dey does not touch the carry)
        dey
        bpl @div                    ; the borrow absorbed by the high byte
@dd:    stx barq                    ; high byte went negative: X is the quotient
  .if BHW
        adc #ROWCHARS-1             ; C = 1 (the sec before dey): A + 80,
        sta wcxm                    ;  the remainder: the window's start in its slot
        lda #RINGROWS-1             ; the window row in the last slot ...
        sbc barq                    ;  (C = 1: the adc carried)
        clc
        adc wcy
        sta mrow                    ; ... and the map row it shows
  .endif
        rts

; ============================================================================
; The interrupt: the rupture chain's steps (T1) and the vsync (CA1)
;
; One body, placed with its state (PLACEH): on the Master the handler itself
; (irq_handler, at IRQ1V, in main RAM); on the Model B isr_body, in bank 7, which the
; low-RAM stub (low.s irq_handler) jumps to after saving X and Y and paging bank 7 in.
;   In:   A saved in $FC (the MOS);  Model B: X, Y saved and ROMSEL stacked by the stub
;   Out:  Master: X, Y, A restored, rti.  Model B: back to the stub -- a step by
;         irq_ret, the vsync by irq_vret (which steps the title tune first)
;
; A step reprograms the next section from SECTAB (build_sections has the layout) and
; walks SECIDX on; the vsync restarts T1, re-phases the frame, takes a pending flip,
; programs section 0 from the buffer about to be shown, then scans the keys and runs
; the sound.  LOADREQ (the load mode, above) diverts both.
;
; ---- A step's timing
; Each step is a CRTC restart: the next section's address was armed during the
; previous one and is latched at the boundary.  What the new section needs quickly is
; its shape.  R9 and R4 together decide where the section ENDS: the CRTC latches
; end-of-frame at the start of the scanline where row = R4 and line = R9, so for a
; 2-line section (a partial with R9 = 1) both must be in place before the start of
; scanline 1 -- 128 cycles after the restart.  R6 is compared from scanline 1 on, so
; Q's R6 = 0 has the same deadline.  Everything else has a row or more to spare.
;
; The chain is phased (VS2T) so the step fires ~50 cycles BEFORE the restart; the hold
; (the Master's; the Model B's stub takes as long) carries the first write past it,
; and the three deadline registers then land about 40, 60 and 80 cycles in, with the
; rest behind them.  So the order is R9, R4, R6, R7: writing R4 third put it at ~140
; for a 2-line P2 -- that section never ended, Q's R6 hit never came, and both borders
; lit up on every scroll frame.
;
; R12/R13 go LAST, after the T1 reload and the index bookkeeping, so they land on
; scanline 1 (measured: ~140-175 cycles in).  Written straight after R7 they fell at
; ~105-125, across the end of scanline 0 -- and on a partial (R4 = 0, written on row 0
; = its last row) some 6845s end the frame at once, the VL6845 among them (Tom
; Seddon's r4-3), and reload the start address as that scanline ends: a Master with
; such a chip lost the R12 write and showed the playfield from A's high byte with P's
; low byte, 256 chars adrift, a 16-char tear down every row whenever the fine scroll
; was not 0.  Two-line sections still have 80 cycles in hand before the next restart.
;
; ACCCON D (the Master) is different again: it is the memory map, sampled by every
; fetch, so it must be in place BEFORE the boundary -- the bar's T1 fires a further
; BARLEAD us early so D lands in the horizontal blanking of the bar's last line.
; ============================================================================
        PLACEH "CODE", "KRNCODE"
  .if BHW
isr_body:
  .else
irq_handler:
        ; Q's step puts D back to 0 before Q's first scanline (the 6845 shows it
        ; whatever R6 says, from QBLANK, main RAM), first thing: behind a two-line P2's
        ; own step there is no time for more.  The chain rests on Q till the vsync, so
        ; any interrupt with SECIDX at QSECT is Q's step, or a vsync that wants D = 0.
        lda SECIDX
        cmp QSECT
        bne @nq
        lda ACCCON
        and #$FE
        sta ACCCON
@nq:    stx irq_x
        sty irq_y
  .endif
        bit VIA_IFR
        bvs @t1arm                  ; T1.  The arm grew past bvc's reach:
        jmp @notT1                  ;  one cycle more each way

        ; ---- the chain step
@t1arm: lda LOADREQ
        beq @chain
        jmp @ldcheck                ; a load asked for, under way or ending
@chain: ldx SECIDX                  ; X = this section's entry
  .if .not BHW
        ; The Master: the step after the bar's (DSECT) switches D to the displayed
        ; buffer's -- before the boundary -- then holds (26 cycles) so its first CRTC
        ; write follows the restart.  Every other step needs neither (D is 0 for the bar
        ; from the vsync, and already right after it): it fires later instead, by
        ; STEPLATE (the bar's by BARLATE), and spends nothing waiting.
        cpx DSECT
        bne @noD
        lda ACCCON
        and #$FE
        ora dispD
        sta ACCCON
        ldy #5
@hold:  dey
        bne @hold
@noD:
        ; Q's step (QSECT): D is 0 already (irq_handler's first act); it holds as the D
        ; step does, so its CRTC writes follow Q's restart
        cpx QSECT
        bne @noQ
        ldy #5
@qhold: dey
        bne @qhold
@noQ:
  .endif
        ; ---- the shape: R9, R4, R6, R7, in that order (the header)
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
        ; ---- the next section's duration, into the T1 latch
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear T1's flag
        ; ---- the next entry.  The chain stops at Q, the only entry whose R7 is the
        ;      vsync row: a late vsync must not walk the chain off the end of SECTAB.
        ;      Every other section's R7 is 30, so C = 1 on the way past, as the adc needs.
        lda curR7                   ; R7, just written
        cmp #QVSYNC
        beq :+
        txa
        adc #7                      ; C is set (30 >= QVSYNC): this adds 8
        sta SECIDX                  ; (X still indexes this entry for R12/R13)
        ; ---- the next section's address, last: see the header
:       lda #12
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

        ; ---- T1 with LOADREQ non-zero (A = LOADREQ)
@ldcheck:
        cmp #1
        bne @ldt1
        ldx SECIDX                  ; stop asked: only the bar step, a frame
        cpx DISPSECT                ;  boundary, makes the switch
        beq @ldsw
        jmp @chain
        ; ---- the switch: this restart is a standard frame, not the bar (load_begin).
        ;      R9 = 7 and R6 = BARROWS are the vsync's pre-arm already, and R12/R13
        ;      hold the bar.  The bar's step fires BARLATE later: no hold.
@ldsw:  lda #4
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
        sta LOADREQ                 ; stopped
        bne @xit                    ; (Z = 0: lda #2)
        ; ---- the vsync while stopped: the standard frame free-runs; count the vsync
        ;      and keep the keys and the sound alive
@ldvsync:
        inc vsyncs
        jmp @sk
        ; ---- stopped or ending: T1 runs on with its interrupt off, so its flag is
        ;      stale: was this the vsync?
@ldt1:  lda VIA_T1CL
        bit irq_x                   ; (a 3-cycle pad for the jmp it replaces)

        ; ---- not T1: the vsync?
@notT1:
        lda VIA_IFR
        and #$02                    ; CA1
        bne :+
        beq @xit                    ; (Z = 1: the bne fell through)

        ; ---- the vsync.  Restart T1 first (constant latency): counter = vsync->T.
        ;      The latch (how long section 0 lasts) is programmed further down, after
        ;      the flip: section 0 belongs to the buffer that is about to be displayed.
:       lda #<VS2T                  ; (an immediate: VS2T allows for its timing)
        sta VIA_T1LL
        lda #>VS2T
        sta VIA_T1CH                ; loads the counter: T1 restarts
        lda #$02
        sta VIA_IFR                 ; clear CA1's flag
        lda LOADREQ                 ; (after the restart: it sets the chain's phase)
        cmp #2
        beq @ldvsync                ; stopped: T1 runs on with its interrupt off
        cmp #3
        bne :+
        stz LOADREQ                 ; resume: T1's interrupt on again, below
:       lda #$C0
        sta VIA_IER                 ; T1's interrupt on
        ; ---- re-phase: the vsync fired at row curR7, so end this frame at row
        ;      curR7 + QROWS-1-QVSYNC with 8-line rows -> T starts exactly
        ;      QROWS-QVSYNC rows after the vsync even if the CRTC row counter had run
        ;      past its vertical total (which otherwise never recovers)
        lda #9
        sta CRTC_IDX
        lda #7
        sta CRTC_DAT                ; R9 = 7
        ;      pre-arm the bar's R6 now, in Q, where the display is already off and a
        ;      new R6 cannot show: the step at the bar's start is too close to the
        ;      second scanline to be trusted with it
        lda #6
        sta CRTC_IDX
        lda #BARROWS
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda curR7
        clc
        adc #QROWS-1-QVSYNC
        and #$7F
        sta CRTC_DAT                ; R4
        ; ---- the flip, if one is asked and two vsyncs have passed since the last
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
        ; the Master: the flip is the section chain moving to the other buffer's rows;
        ; D follows it, but only from the first playfield section -- the bar needs D = 0
        lda NEXTBUF
        sta dispD
  .endif
        stz flipreq
@noflip:
        ; ---- section 0: everything it needs comes from the buffer that is about to
        ;      be displayed -- its start address (menu_sections moves it) and its length
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
        sta VIA_IFR                 ; clear T1's flag
        sty SECIDX                  ; the chain starts at the bar's entry
  .if .not BHW
        tya                         ; DSECT: the step after the bar's (the
        clc                         ;  D step)
        adc #8
        sta DSECT
        lda BUF_QS,x                ; and Q's, the step that puts D back to 0
        sta QSECT
        lda #1                      ; the bar is below $3000: it is only main
        trb ACCCON                  ;  RAM to the CRTC while D = 0
  .endif
        ; ---- the keys and the sound
@sk:    jsr scan_keys
  .if GAMESOUND
        ; the game's player (resident); the tune's step is raised here, as the engine's
        ; sound_tick does
        jsr hook_sound
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
        ; ---- the Master: step the menus' tune, as the Model B's interrupt stub does
        ;      (low.s)
        lda MUSTICK
        beq @exit
        dec MUSTICK
        lda ROMSEL_CPY
        pha
        ldpbank lda, BANK_LVL       ; (in main RAM, loaded unpatched: PBANK)
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

; ----------------------------------------------------------------------------
; VS2T: the T1 count from the vsync to the bar's step
; CA1 fires at the end of the 2-line vsync pulse (the -2*LINE).  Then:
;   -35       would put each step ~5 us INTO its section;
;   -36       the further lead puts it ~30 us before the restart, so that the shape
;             registers land early in the first scanline (the interrupt's header);
;   -8        the step's load-flag test;
;   +2        (ticks) the vsync loads it as immediates, 4 cycles sooner than from memory;
;   -STUBLAT  the Model B's stub pages bank 7 in (pagelogic inlined: no write bank, the
;             interrupt stores into none) before the body, which makes both the
;             vsync's T1 restart and every step later -- STUBLAT ticks in all -- where
;             the Master's handler holds instead.  On the Master it is -BARLATE: the
;             bar's step fires later, with no hold in it.
; STUBLAT (Model B): 22 is the stub's pagelogic inlined, jmp for jsr; 4 is its write
; bank gone, twice.
; ----------------------------------------------------------------------------
  .if BHW
STUBLAT = 18 - 22 - 4
  .else
STUBLAT = -BARLATE
  .endif
VS2T = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36 - STUBLAT - 8 + 2

; ----------------------------------------------------------------------------
; scan_keys: the keyboard into keys
;   Out:  keys = the K_ bits of the keys held (keymap.inc);  A, X clobbered
; Called from the vsync.  keys is built in place: the interrupt is atomic to its
; readers.  Placed with the interrupt's own work: bank 7 with the Model B's handler,
; main RAM with the Master's.
; ----------------------------------------------------------------------------
        PLACEH "CODE", "KRNCODE"
scan_keys:
        lda #$7F
        sta VIA_DDRA                ; PA0-6 out (the key number), PA7 in
        lda #3
        sta VIA_ORB                 ; disable keyboard autoscan
        stz keys
        ldx #KEYN-1
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+                      ; PA7 clear: not pressed
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

; ============================================================================
; The sound
; ============================================================================
  .if .not GAMESOUND                ; (GAMESOUND: the game's hook_sound instead)
; ----------------------------------------------------------------------------
; sound_tick: step the sound effect, and raise the tune's step
;   In:   SFXREQ = an sfx to start (1-based, into sfxtab) or 0;  SFXPTR, SFXDUR
;   Out:  MUSTICK = MUSON;  A, X, Y clobbered
; Called from the vsync.  An sfx is steps of (b0, b1, b2, frames): three bytes written
; to the SN76489, then the frames to hold them; $FF ends it.  SFXPTR+1 = 0: none
; playing.
; ----------------------------------------------------------------------------
sound_tick:
        lda SFXREQ
        beq @play
        ; ---- start a new sfx
        asl
        tax
        stz SFXREQ                  ; (Model B: A = 0 -- the index is in X)
        lda sfxtab-2,x
        sta SFXPTR
        lda sfxtab-1,x
        sta SFXPTR+1
        bne @go                     ; an sfx is never in page 0: to its first step
        ; ---- one playing: its next step when this one's frames are up
@play:  lda SFXPTR+1
        beq @music
        dec SFXDUR
        bne @music
@go:    ldaz SFXPTR                 ; (zp): the first byte needs no index
        cmp #$FF
        beq @end
        jsr sndwrite                ; (C = 0 from the cmp: sndwrite keeps it)
        ldy #1
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        sta SFXDUR
        lda SFXPTR                  ; the next step (C = 0 still)
        adc #4
        sta SFXPTR
        bcc @music
        inc SFXPTR+1
        bne @music                  ; SFXPTR+1 <> 0 after the inc
@end:   jsr sndwrite                ; A = $FF (the end mark): noise off
        lda #$DF                    ; channel 2 off
        jsr sndwrite
        stz SFXPTR+1                ; none playing
        ; ---- the tune is stepped at the interrupt's tail (the Model B's stub in
        ;      low.s, the Master's handler): its player is in the menus' image.  Only
        ;      raised here, at the vsync: the T1 steps share that tail.
@music:
        lda MUSON
        sta MUSTICK
        rts
  .ifdef DBGSND
@dbgsil: .byte $9F, $BF, $FF, 0
  .endif
  .endif

; ----------------------------------------------------------------------------
; sndwrite: write a byte to the SN76489
;   In:   A = the byte
;   Out:  A = $7F;  X, Y and the carry kept
; Through the slow data bus: port A drives the byte, latch bit 0 is the chip's write
; enable (low for the 8 nops, 16 cycles), and the port goes back to the keyboard's
; shape (PA7 in) after.  Placed with the interrupt's work (the PLACEH above).
; ----------------------------------------------------------------------------
sndwrite:
        pha
        lda #$FF
        sta VIA_DDRA                ; port A all out
        lda #$0B
        sta VIA_ORB                 ; keyboard autoscan on so the keyboard does not pull PA7
        pla
        sta VIA_ORANH
        lda #0
        sta VIA_ORB                 ; write enable low
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        lda #8
        sta VIA_ORB                 ; write enable high
        lda #$7F
        sta VIA_DDRA                ; PA7 in again
        rts

; ----------------------------------------------------------------------------
; music_stop: stop the tune and silence all four channels
;   Out:  MUSON = 0;  A clobbered
; In the kernel because the kernel stops it: the menus' image (the tune's player) may
; be gone.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
music_stop:
  .if BHW
        lsr MUSON                   ; MUSON is 0 or 1: 6 cycles, as lda #0 / sta
  .else
        stz MUSON
  .endif
        lda #$9F                    ; tone 0 off
        jsr sndwrite
        lda #$BF                    ; tone 1 off
        jsr sndwrite
        lda #$DF                    ; tone 2 off
        jsr sndwrite
        lda #$FF                    ; noise off
        jmp sndwrite

; ----------------------------------------------------------------------------
; set_palette: the MODE 1 palette, logical 0..3 = black, cyan, magenta, yellow
;   Out:  A, X, Y clobbered
; A screen pixel's two bits land in bits 3 and 1 of the palette index; the other two
; bits are don't-cares, so all 16 entries are written.  In the kernel: the menus call
; it too.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
set_palette:
        ldx #15                     ; X = the palette index
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
        sta ULA_PAL                 ; (index << 4) | (physical ^ 7)
        dex
        bpl :-
        rts
@cmyk:  .byte 0^7, 6^7, 5^7, 3^7    ; physical black, cyan, magenta, yellow (inverted)

; ----------------------------------------------------------------------------
; blank_palette: every palette entry black
;   Out:  A clobbered, C = 0
; ----------------------------------------------------------------------------
blank_palette:
        lda #$F7                    ; (i << 4) | 7, i = 15 down to 0
        sec
:       sta ULA_PAL
        sbc #$10
        bcs :-
        rts

; ----------------------------------------------------------------------------
; ringaddr7: the kernel's ringaddr -- the screen address of a ring character
;   In:   A = the char row;  w16 = the char column (16 bits);  C = 0
;   Out:  sp = the character's screen address (the Model B: in the back buffer,
;         by ringbhi);  A = sp+1;
;         X = the ring slot
; For the sprite prologue, copy_partial and the menus.  The ring modulus
; is by subtraction (no table this side), the row multiple from the kernel's
; mulrowlo/hi, and on the Model B the buffer's base from select_backbuf (both bases
; are xx80: ringbhi is the page).  C = 0 in: the Master's modulus (and #31) leaves the
; caller's carry for the add, where the Model B's leaves it clear.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
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
        ringup sp                   ; fold back into the ring
        sta sp+1
        rts
