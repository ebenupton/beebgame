; ============================================================================
; engine/kernel.s -- the kernel: the rupture chain and its interrupt, the keys,
; the sound, the palette
;
; Both machines.  The resident part of bank 7 (KRNCODE): it stays paged in under
; either image of the bank (the game's or the menus'), so the menus build their
; frames with it as the game does.  The interrupt's own work -- the handler, the
; vsync's sound step, scan_keys with the game's key table (keymap.inc),
; snd_write -- is placed with PLACEH "MRAMCODE", "KRNCODE": in bank 7 on the
; Model B, where low.s's stub pages the bank in around it, and in main RAM on
; the Master, whose handler is IRQ1V's target itself (a blessed placement).  The
; rest is KRNCODE on both.
;
; The display is a rupture: each 312-line frame is a chain of CRTC frames
; ("sections": the bar, the composed row, the playfield, the bottom partial, the
; blanking), each programmed by a VIA T1 interrupt (a "step") and re-phased at
; every vsync (CA1).  build_sections lays a buffer's chain out in SECTAB; the
; interrupt walks it.  docs/DESIGN.md has the design; the timing is here.
;
;   build_sections  the current buffer's chain, for the next flip
;   menu_sections   build_sections with buffer 0's section 0 moved off the bar
;   load_begin      stop the chain at a frame boundary before a disc load
;   calc_ring       ring_s and barq (the Model B: wcxm, mrow too) from wcx, wcy
;   isr_body        the interrupt's body (the Master: irq_handler, the handler)
;   scan_keys       the keyboard into keys
;   snd_write       one byte to the SN76489
;   music_stop      stop the tune, silence all four channels
;   set_palette     the MODE 1 palette
;   blank_palette   every palette entry black
;   ring_addr7      a ring character's screen address, from bank 7
;
; Order: as listed, which is the as-built order on both machines (the
; interrupt's work between the two KRNCODE runs); no code here is under a PAD or
; SAMEPAGE.
; ============================================================================

; ---------------------------------------------------------------- chain timing
; In T1 ticks (us; one tick is two CPU cycles).  Each step fires a lead before
; the restart it programs (VS2T, below, sets the lead); these move single steps
; off it.  The values were tuned against test/crtctime.mjs, which shows where
; each write lands.
;   BARLATE   the bar's step fires this much later: VS2T carries it (as -STUBLAT
;             on the Master) and the bar's own duration (BUF_SEC0T1) is that
;             much shorter, so the steps after it are back in line
;   BARLEAD   the step after the bar's fires this much earlier still: the bar's
;             duration is shorter by it and the section after the bar (entry 0's
;             T1) longer
;   STEPLATE  every step after the D step fires this much later: the section
;             after the bar runs this much longer, and the section before Q this
;             much shorter (Q's step is back on the common lead)
;   QLEAD     Q's step fires this much early: the section before Q runs it
;             shorter
;   P2EARLY   a bottom partial's (P2's) step fires this much early: P runs it
;             shorter and P2 it longer, so the step before Q's is done in time
;             behind a two-line P2
;   DHOLD     the Master's D and Q steps: a dey loop from DHOLD, 26 cycles with
;             the ldy (2 + 4 x 5 + 4), so their first CRTC write follows the
;             restart
;   KENDWAIT  the Model B's two-line P2 step: the same loop before its palette
;             kill
  .if BHW
BARLEAD  = 0
BARLATE  = 0
STEPLATE = 0
QLEAD    = 40                      ; the palette kill starts as the line before
                                   ;  Q goes into its blanking (crtctime)
P2EARLY  = 0                       ; (a two-line P2's own step does Q's kill:
                                   ;  @kend)
  .else
BARLATE  = 13
STEPLATE = 20
BARLEAD  = 23
QLEAD    = 6                       ; D = 0 lands in the blanking before Q
                                   ;  (crtctime)
P2EARLY  = 12
DHOLD    = 5
  .endif
KENDWAIT = 4

; VS2T: the T1 count the vsync restarts the chain with, to the bar's step.  The
; (QROWS-QVSYNC) rows from the vsync's row to the bar, less: 2*LINE, as CA1 is
; taken at the end of the two-line vsync pulse; 35, which would put each step ~5
; us into its section, and 36 more, the lead that puts the shape writes early in
; a section's first scanline; STUBLAT; 8 for the step's load_req test; plus 2,
; as the vsync loads the count as immediates.  These terms are the old
; derivation (not re-derived in this pass); the write positions they give are
; what crtctime measures.
;
; STUBLAT: on the Model B the low-RAM stub runs before the body (cld, the X/Y
; saves, bank 7 paged: 26 cycles), where the Master's handler starts at once and
; holds instead; 18 - 22 - 4 + 2 is the old account (the stub before page_logic
; was inlined, less the inlining, less two write-bank stores, plus the cld).  On
; the Master it is -BARLATE: the bar's step fires later.
  .if BHW
STUBLAT  = 18 - 22 - 4 + 2
  .else
STUBLAT  = -BARLATE
  .endif
VS2T     = (QROWS-QVSYNC)*CHARLINES*LINE - 2*LINE - 35 - 36 - STUBLAT - 8 + 2

; ---------------------------------------------------------------- chain shapes
PARTR6   = 2                       ; a one-row partial's R6: more rows than it
                                   ;  has, so the display stays on to its end
P2SHORT  = 2                       ; the fine scroll whose P2 is two lines
                                   ;  (wfine is even): its own step must black
                                   ;  Q's palette
BUFPAIR  = 2                       ; BUF_SEC0, BUF_SEC0T1, BUF_QS, BUF_KS: bytes
                                   ;  a buffer (each is indexed by 2 x the
                                   ;  buffer)
; MENUBAR: the menus' section 0, the ring rows below the window (menu_sections)
MENUBAR  = (RING0 + VISROWS*ROWBYTES) / CHARBYTES
        .assert VISROWS + BARROWS <= RINGROWS, error, "MENUBAR: not in the ring"

; ---------------------------------------------------------------- load mode
; A disc load runs with interrupts off (disc.s), which stops the chain.  Stopped
; mid-chain the CRTC repeats whatever section it was in -- a few lines over and
; over, no vsync -- and a monitor loses sync.  So load_begin asks the interrupt
; to stop the chain at a frame boundary: the bar's step programs one standard
; 39-row frame (LDR4) with the vsync on the row the chain puts it (LDR7) and
; turns T1's interrupt off; the CRTC free-runs that frame, the vsync where it
; was.  The palette is black through a load (the callers' blank_palette), so
; what that frame shows does not matter.  load_req (defs.inc LDR_*): LDR_RUN,
; LDR_STOP (load_begin), LDR_STOPPED (the bar's step), LDR_RESUME (ldprog.s, at
; a load's end).  At LDR_RESUME the next vsync re-arms T1's interrupt; its
; re-phase from cur_r7 = LDR7 gives R4 = LDR4, the standard frame's own, so the
; next bar step takes the display back on time.
; LDR4: FRAMEROWS - 1, a standard 312-line frame's R4;  LDR7: the vsync's row in
; the chain's frame
LDR4     = BARROWS + VISROWS + QROWS - 1
LDR7     = BARROWS + VISROWS + QVSYNC

; ---------------------------------------------------------------- sound effects
SFXTONE  = 2                       ; the tone channel the sound effects use
                                   ;  (with the noise, which SFX_END silences)

; ---------------------------------------------------------------- local macros
; ----------------------------------------------------------------------------
; crtcw reg, src [,ix]: CRTC register reg = src (lda's operand: #imm, abs or
; abs,ix)
;   Out:   A = the value written;  N, Z from it
; ----------------------------------------------------------------------------
.macro crtcw reg, src, ix
        lda #reg
        sta CRTC_IDX
  .if .paramcount = 3
        lda src,ix
  .else
        lda src
  .endif
        sta CRTC_DAT
.endmacro

; ----------------------------------------------------------------------------
; palfill cy, cm, cc: the palette entries of logical yellow, magenta and cyan,
; in that order, to physical colours cy, cm, cc -- 12 writes, 72 cycles
; (lda # 2, sta 4)
;   Out:   A = the last byte written
; A MODE 1 logical colour is index bits 3 and 1 (PALIDX_*); bits 2 and 0 are
; don't cares, run through as i .mod 2 and (i / 2) * 4.  The order is the one
; the Model B's palette kill needs: the colour that can first show on Q's line 0
; first (defs.s QBLANK).
; ----------------------------------------------------------------------------
.macro palfill cy, cm, cc
        .repeat 4, i
        lda #((PALIDX_YELLOW + i .mod 2 + (i / 2) * 4) << PAL_SHIFT) | (cy ^ PAL_INV)
        sta ULA_PAL
        .endrepeat
        .repeat 4, i
        lda #((PALIDX_MAGENTA + i .mod 2 + (i / 2) * 4) << PAL_SHIFT) | (cm ^ PAL_INV)
        sta ULA_PAL
        .endrepeat
        .repeat 4, i
        lda #((PALIDX_CYAN + i .mod 2 + (i / 2) * 4) << PAL_SHIFT) | (cc ^ PAL_INV)
        sta ULA_PAL
        .endrepeat
.endmacro

; ----------------------------------------------------------------------------
; build_sections: lay out the current buffer's section chain, for the next flip
;   In:    cur_buf (0 or 1);  ring_s, wfine (calc_ring, the frame);  barq
;   Out:   the buffer's SECTAB entries (from SECTAB + cur_buf*SECBYTES); its
;          BUF_SEC0 (the bar's CRTC address, high byte first) and BUF_SEC0T1
;          (the bar's T1 count) and BUF_QS (Q's entry), at 2 x cur_buf (the
;          Model B: BUF_KS too);  crtcb = the buffer's CRTC base (the Model B:
;          crtcbm = that less RINGCHARS)
;   Uses:  A X Y, w16, tmp2, tmp3, tmp4
;   Pre:   bank 7 paged
; Called once a frame (frame.s, after calc_ring), by menu_sections, and at
; start-up (init.s, for each buffer).  An entry is SECENT bytes (defs.s SE_*):
; the section's shape (R4, R9, R6, R7), then the NEXT section's start address
; (R12, R13) and duration (a T1 latch value): R12/R13 latch at the next restart
; and a T1 latch takes effect when the counter next reloads, so each step arms
; the section after the one it shapes.  The chain, top to bottom (f = wfine, 0,
; 2, 4 or 6):
;   T   the bar: BARROWS rows from BARCRTC (entry 0's shape; its address and
;       duration are BUF_SEC0/BUF_SEC0T1, which the vsync programs)
;   A   f > 0 only: 8-f lines of the ring row above the window (the composed
;       row)
;   P   the playfield from the window: VISROWS rows, VISROWS-1 when f > 0.  The
;       Model B's ring does not wrap in hardware: a run that reaches the ring's
;       end is split there, P1, then M, read from the mirror row below the
;       ring's base
;   P2  f > 0 only: the top f lines of the row below
;   Q   QROWS rows of blanking with the vsync on row QVSYNC; the chain stops
;       here
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
build_sections:
        ; ---- the buffer's CRTC base (Model B: and its mirror redirect)
        ldx cur_buf
        lda @cbl,x
        sta crtcb
        lda @cbh,x
        sta crtcb+1
  .if BHW                          ; hardware: the Model B's mirror
        lda @cml,x
        sta crtcbm
        lda @cmh,x
        sta crtcbm+1
  .endif
        ; ---- section 0, the bar: a fixed address and length
        txa
        asl
        tay                        ; Y = 2 x cur_buf;  Z = 1 for buffer 0
        beq @entry0                ; X = entry 0: 0, or SECBYTES for buffer 1
        ldx #SECBYTES
@entry0:
        lda #>BARCRTC
        sta BUF_SEC0,y
        lda #<BARCRTC
        sta BUF_SEC0+1,y
        lda #<(BARROWS*CHARLINES*LINE-T1_RELOAD-BARLEAD-BARLATE)
        sta BUF_SEC0T1,y
        lda #>(BARROWS*CHARLINES*LINE-T1_RELOAD-BARLEAD-BARLATE)
        sta BUF_SEC0T1+1,y
        lda #BARROWS-1
        sta SECTAB+SE_R4,x
        .assert BARROWS = 2, error, "build_sections: the bar's R6 is its R4 doubled"
        asl                        ; R6 = BARROWS
        sta SECTAB+SE_R6,x
        lda #CHARLINES-1
        sta SECTAB+SE_R9,x
        lda #R7_NEVER
        sta SECTAB+SE_R7,x
        lda wfine
        beq @coarse

        ; ---- f > 0: T, A, P, P2, Q.  A is the 80 chars before the window:
        ;      w16 = ring_s - 80, folded into the ring
        lda ring_s
        sec
        sbc #<ROWCHARS
        sta w16
        lda ring_s+1
        sbc #0
        bpl @aplus                 ; no borrow out of the ring's start
  .if .lobyte(RINGCHARS)
        lda w16                    ; C = 0 (the borrow), A = $FF
        adc #<RINGCHARS
        sta w16
        lda #>(RINGCHARS-$100)     ; $FF + >RINGCHARS + C
        adc #0
  .else
        adc #>RINGCHARS            ; C = 0, A = $FF; RINGCHARS's low byte is 0
  .endif
@aplus: sta w16+1
        jsr @addr                  ; A's address, into entry 0
        lda wfine
        eor #CHARLINES-1           ; 7 - f: A's R9
        sta SECTAB+SECENT+SE_R9,x
  .if BHW                          ; hardware: the Model B's @addr may leave
        clc                        ;  C = 1 (its mirror path's add carries)
  .endif
        adc #1                     ; 8 - f lines
        jsr @dur                   ; A's duration, into entry 0;  X = A's entry
        stz SECTAB+SE_R4,x         ; R4 = 0: one row (A dead: reloaded next)
        lda #PARTR6
        sta SECTAB+SE_R6,x
        lda #R7_NEVER
        sta SECTAB+SE_R7,x
        lda ring_s                 ; the run starts one row into the window
        adc #<ROWCHARS             ;  (C = 0 from @dur)
        sta w16
        lda ring_s+1
        adc #0
        sta w16+1
        jsr @wrap
  .if BHW                          ; hardware: the Model B's mirror
        ldy barq                   ; the run's first ring row: barq + 1, folded
        iny
        cpy #RINGROWS
        bcc @rowsf
        ldy #0
@rowsf:
  .endif
        lda #VISROWS-1
        bne @rows                  ; (always)

        ; ---- f = 0: T, P, Q
@coarse:
        lda ring_s
        sta w16
        lda ring_s+1
        sta w16+1
  .if BHW                          ; hardware: the Model B's mirror
        ldy barq
  .endif
        lda #VISROWS
@rows:
  .if BHW                          ; hardware: the Model B's mirror
        sty tmp3                   ; the ring row the run starts on
  .endif
        sta tmp4                   ; the run's rows

        ; ---- the playfield.  w16 = its first row's ring offset, tmp4 = its
        ;      rows, X = the entry before it;  Model B: tmp3 = its first ring
        ;      row
  .if BHW                          ; hardware: the Model B's mirror
        ; The rows that end before the ring's end: with r = ring_s mod 80 > 0
        ; the last ring row straddles the end, so RINGROWS-1 - tmp3; with r = 0,
        ; RINGROWS - tmp3.  If the run is longer, emit P1 to the end, then the
        ; rest (M) from the mirror.
        ldy barq
        lda ring_s
        eor mul_rowlo,y            ; 0 iff r = 0 (ring_s - barq*80 < 80)
        cmp #1                     ; C = 1 iff r > 0
        lda tmp3                   ; RINGROWS - tmp3 - C, as the complement of
        adc #$FF-RINGROWS          ;  tmp3 + C + $FF - RINGROWS
        eor #$FF
        cmp tmp4
        bcs @one                   ; the whole run fits
        tay                        ; Z from A (Y is dead: @addr reloads it)
        beq @one                   ; it starts in the straddling row: all from
                                   ;  the mirror
        sta tmp2
        jsr @emit                  ; P1, up to the ring's end
        lda tmp4                   ; M: the rest
        sec
        sbc tmp2
        sta tmp4
  .endif
@one:   lda tmp4
        sta tmp2
        jsr @emit                  ; w16 = the row below the playfield
        jsr @addr                  ; P2's address, or Q's
        lda wfine
        beq @qentry

        ; ---- P2: the top f lines of that row
        jsr @dur                   ; A = f lines;  X = P2's entry
        stz SECTAB+SE_R4,x         ; R4 = 0 (A dead: reloaded next)
        lda wfine
        sbc #0                     ; f - 1 (C = 0 from @dur)
        sta SECTAB+SE_R9,x
        lda #VISROWS               ; R6: more rows than it has
        sta SECTAB+SE_R6,x
  .if VISROWS <> R7_NEVER
        lda #R7_NEVER
  .endif
        sta SECTAB+SE_R7,x

        ; ---- Q.  Its line 0 shows whatever R6 says (a 6845 displays a frame's
        ;      first scanline), so its address is QBLANK, a line of black
        ;      (defs.s: the Master's zeroed row below the bar; the Model B's bar
        ;      line 0 from char 45, with Q's step blacking the palette).  Entry
        ;      X (the one before Q) arms that address and Q's duration; Q's
        ;      entry arms the bar's address.
@qentry:
        lda #>(QBLANK / CHARBYTES)
        .assert >(QBLANK / CHARBYTES) = >BARCRTC, error, "QBLANK: not BARCRTC's page"
        sta SECTAB+SE_R12,x
        sta SECTAB+SECENT+SE_R12,x
        lda #<(QBLANK / CHARBYTES)
        sta SECTAB+SE_R13,x
        ; Q's duration and the next: the chain rests on Q until the vsync
        lda #<(IDLE_LINES*LINE-T1_RELOAD)
        sta SECTAB+SE_T1L,x
        sta SECTAB+SECENT+SE_T1L,x
        lda #>(IDLE_LINES*LINE-T1_RELOAD)
        sta SECTAB+SE_T1H,x
        sta SECTAB+SECENT+SE_T1H,x
        lda #<BARCRTC
        sta SECTAB+SECENT+SE_R13,x
        lda #QROWS-1
        sta SECTAB+SECENT+SE_R4,x
        lda #CHARLINES-1
        sta SECTAB+SECENT+SE_R9,x
        stz SECTAB+SECENT+SE_R6,x  ; R6 = 0: display off (A dead: reloaded next)
        lda #QVSYNC
        sta SECTAB+SECENT+SE_R7,x  ; the only such R7: the chain stops here

        ; ---- Q's step fires QLEAD early: the section before Q, whose duration
        ;      entry X-SECENT carries, runs STEPLATE + QLEAD shorter.  The vsync
        ;      takes Q's entry from BUF_QS (qsect).
        lda cur_buf
        asl
        tay                        ; Y = 2 x cur_buf (C = 0: cur_buf < $80)
        txa
        adc #SECENT                ; Q's entry (C = 0 out: X < $F8)
        sta BUF_QS,y
  .if BHW                          ; hardware: the Model B's palette kill
        ; Behind a two-line P2 (f = P2SHORT) P2's step kills the palette
        ; (BUF_KS = P2's entry) and Q's step does not (BUF_QS = SECT_NONE, never
        ; an entry); Q's step then fires on time: early, Q's interrupt could be
        ; taken before P2's step had done.  Otherwise Q's step does it (BUF_KS =
        ; SECT_NONE).
        lda wfine
        beq @qkill                 ; (f = 0: Q's step)
        cmp #P2SHORT+1
        bcs @qkill
        txa
        sta BUF_KS,y               ; P2's entry
        lda #SECT_NONE
        sta BUF_QS,y
        bne @barlead               ; (always)
@qkill: lda #SECT_NONE
        sta BUF_KS,y
  .endif
  .if P2EARLY
        ; with a P2: P's duration (entry X-2*SECENT's) P2EARLY shorter, and
        ; P2's (X-SECENT's) STEPLATE+QLEAD-P2EARLY shorter
        lda wfine
        beq @nop2
        lda SECTAB-2*SECENT+SE_T1L,x
        sec
        sbc #P2EARLY
        sta SECTAB-2*SECENT+SE_T1L,x
        bcs @p2dur
        dec SECTAB-2*SECENT+SE_T1H,x
@p2dur: lda SECTAB-SECENT+SE_T1L,x
        sec
        sbc #STEPLATE+QLEAD-P2EARLY
        bra @qlead                 ; (Master-only by P2EARLY's value)
@nop2:
  .endif
        lda SECTAB-SECENT+SE_T1L,x
  .if BHW                          ; hardware: C from the palette-kill block
        sec
        sbc #STEPLATE+QLEAD
  .else
        sbc #STEPLATE+QLEAD-1      ; C = 0 (the adc #SECENT): - (STEPLATE+QLEAD)
  .endif
@qlead: sta SECTAB-SECENT+SE_T1L,x
        bcs @barlead
        dec SECTAB-SECENT+SE_T1H,x
@barlead:
  .if BARLEAD
        ; ---- the section after the bar (entry 0's duration) runs BARLEAD +
        ;      STEPLATE longer: the bar's step ended the bar BARLEAD early, and
        ;      the steps after the D step fire STEPLATE late
        clc
        ldx cur_buf
        beq @e0
        ldx #SECBYTES
@e0:    lda SECTAB+SE_T1L,x
        adc #BARLEAD+STEPLATE      ; (C = 0: the clc)
        sta SECTAB+SE_T1L,x
        bcc @e0done
        inc SECTAB+SE_T1H,x
@e0done:
  .endif
        rts

        ; ---- the buffers' CRTC bases, and the Model B's mirror redirects
@cbl:   .byte <CRTCB_A, <CRTCB_B
@cbh:   .byte >CRTCB_A, >CRTCB_B
  .if BHW                          ; hardware: the Model B's mirror
@cml:   .byte <(CRTCB_A-RINGCHARS), <(CRTCB_B-RINGCHARS)
@cmh:   .byte >(CRTCB_A-RINGCHARS), >(CRTCB_B-RINGCHARS)
  .endif

; ---- @addr: entry X's R12/R13 = the CRTC address of the row at ring offset w16
;   Out:   Y = w16+1;  C = 0, but on the Model B's mirror path C = 1
;   Uses:  A Y
; Model B: a row starting past RINGCHARS-80 straddles the ring's end and is read
; from the mirror below the base, which is the address w16 - RINGCHARS names
; (crtcbm).  The Master's CRTC wraps the ring itself.
@addr:  lda w16
        ldy w16+1
  .if BHW                          ; hardware: the Model B's mirror
        cpy #>(RINGCHARS-ROWCHARS+1)
        bcc @plain
        bne @mirror
        cmp #<(RINGCHARS-ROWCHARS+1)
        bcc @plain
@mirror:
        clc
        adc crtcbm
        sta SECTAB+SE_R13,x
        tya
        adc crtcbm+1               ; (carries: crtcbm < 0 <= the sum)
        sta SECTAB+SE_R12,x
        rts
@plain:                            ; (C = 0: both ways here are a bcc)
  .else
        clc
  .endif
        adc crtcb
        sta SECTAB+SE_R13,x
        tya
        adc crtcb+1
        sta SECTAB+SE_R12,x
        rts

; ---- @emit: entry X arms a run of tmp2 rows (>= 1) from ring offset w16; X =
;      the run's entry, its shape written; on into @advance
;   Out:   X = the run's entry;  w16 = the row after the run, folded
;   Uses:  A Y, tmp3
@emit:  jsr @addr
        lda tmp2
        jsr @lines                 ; X = the run's entry
        lda tmp2
        sbc #0                     ; R4 = tmp2 - 1 (C = 0 from @lines)
        sta SECTAB+SE_R4,x
        lda #CHARLINES-1
        sta SECTAB+SE_R9,x
        lda #R7_NEVER              ; R6 = R7 = R7_NEVER, more rows than the run:
        sta SECTAB+SE_R6,x         ;  the display stays on, no vsync falls in it
        sta SECTAB+SE_R7,x
        lda tmp2

; ---- @advance: w16 += A rows (A <= RINGROWS), folded into 0..RINGCHARS-1
;   Uses:  A Y
@advance:
        tay
        clc
        lda w16
        adc mul_rowlo,y
        sta w16
        lda w16+1
        adc mul_rowhi,y
        sta w16+1

; ---- @wrap: fold w16 (< 2 x RINGCHARS) into 0..RINGCHARS-1
;   In:    A = w16+1 (both ways in have just stored it)
;   Uses:  A
@wrap:  cmp #>RINGCHARS
        bcc @wrapped
        bne @fold
        lda w16
        cmp #<RINGCHARS
        bcc @wrapped
@fold:  lda w16                    ; C = 1: both ways here
        sbc #<RINGCHARS
        sta w16
        lda w16+1
        sbc #>RINGCHARS
        sta w16+1
@wrapped:
        rts

; ---- @lines: entry X's T1 = A rows (< 32) of lines; on into @dur
; ---- @dur: entry X's T1 (SE_T1L/H) = A lines: A*LINE - T1_RELOAD; X += SECENT
;   Out:   X = the next entry;  C = 0;  tmp3 = the T1 high byte
;   Uses:  A, tmp3
; tmp3:A = A*64 as (A*256) >> 2: the two bits shifted out of A land in the low
; byte.
        .assert LINE = 64 && CHARLINES = 8 && T1_RELOAD = 2, error, "@dur's shifts"
@lines: asl
        asl
        asl
@dur:   lsr
        sta tmp3
        lda #0
        ror
        lsr tmp3
        ror                        ; C = 0: A's bit 0 was 0
        sbc #1                     ; - T1_RELOAD
        bcs @durhi
        dec tmp3
@durhi: sta SECTAB+SE_T1L,x
        lda tmp3
        sta SECTAB+SE_T1H,x
        txa
        clc
        adc #SECENT
        tax
        rts

; ----------------------------------------------------------------------------
; menu_sections: build_sections for the menus, without the bar
;   In:    as build_sections, with cur_buf = 0 (menu.s)
;   Out:   as build_sections, then buffer 0's section 0 address = MENUBAR
;   Uses:  A X Y, w16, tmp2, tmp3, tmp4
;   Pre:   bank 7 paged
; Section 0 shows two ring rows below the window instead of the bar: the menus
; never draw there and menu.s clear_ring has made them black, so the bar is
; neither shown nor touched while the menus run.
; ----------------------------------------------------------------------------
menu_sections:
        jsr build_sections
        lda #>MENUBAR
        sta BUF_SEC0
        lda #<MENUBAR
        sta BUF_SEC0+1
        rts

; ----------------------------------------------------------------------------
; load_begin: ask the interrupt to stop the chain at the next frame boundary,
; and wait until it has (the load mode: the equates above)
;   Out:   load_req = LDR_STOPPED;  A = LDR_STOP;  C = 0, Z = 0
;   Uses:  A
;   Pre:   interrupts enabled (the interrupt makes the switch)
; ----------------------------------------------------------------------------
load_begin:
        lda #LDR_STOP
        sta load_req
@wait:  cmp load_req               ; until the bar's step stores LDR_STOPPED
        beq @wait
        rts

; ----------------------------------------------------------------------------
; calc_ring: where the window sits in the ring
;   In:    wcx (16 bits), wcy;  TALLMAP: wcyh (the Model B's slot is the full row's)
;   Out:   ring_s = ((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS;  barq =
;          ring_s / 80, the window's slot;  Model B: wcxm = ring_s mod 80 (where
;          the window starts in its slot) and mrow = wcy + RINGROWS-1 - barq
;          (the map row the window shows in the ring's last slot)
;   Uses:  A X Y
;   Pre:   bank 7 paged;  wcx < RINGCHARS + ROWCHARS (one subtraction folds the
;          sum)
;   Cost:  the division: 7 x barq + 3 x (ring_s's high byte) + 18 cycles,
;          without page crossings (7 a subtraction, 3 more for each borrow from
;          the high byte, and the loop's entry and exit)
; Called once a frame (frame.s) and by the menus.
; ----------------------------------------------------------------------------
calc_ring:
  .if BHW && TALLMAP               ; hardware: the ring.  The Model B's 23 rows do not
        ; divide 256 (the Master's 32 do): the slot is the FULL row's, wcyh:wcy mod
        ; RINGROWS, so a row keeps its slot as the window crosses row 256.  256 =
        ; 11*23 + 3: wcy + 3*wcyh, folded once past 255 by + 3 again
        .assert 256 .mod RINGROWS = 3, error, "calc_ring: 256 mod RINGROWS is 3"
        lda wcyh                   ; (wy >> 10: under 64)
        asl                        ; C = 0
        adc wcyh                   ; 3 x wcyh: at most 189, C = 0
        adc wcy
        bcc :+
        adc #3-1                   ; past 255: 256 = 3 mod RINGROWS (C = 1): at most 191
:
  .else
        lda wcy
  .endif
        ringmod7
  .if BHW && RINGARITH
        sta wrow                   ; the window's top row's slot (ringwin, draw_rect)
  .endif
        tax
        lda mul_rowlo,x
  .if .not BHW                     ; hardware: the Master's ringmod keeps C (the
        clc                        ;  Model B's leaves C = 0)
  .endif
        adc wcx
        sta ring_s
        lda mul_rowhi,x
        adc wcx+1
        sta ring_s+1
        tay
        cmp #>RINGCHARS            ; fold into 0..RINGCHARS-1
        bcc @div0
        bne @sub
        lda ring_s
        cmp #<RINGCHARS
        bcc @div0
@sub:   lda ring_s                 ; C = 1: both ways here
        sbc #<RINGCHARS
        sta ring_s
        tya
        sbc #>RINGCHARS
        sta ring_s+1
        tay
        ; ---- barq = ring_s / 80, by subtraction: the low byte in A, the high
        ;      in Y
@div0:  lda ring_s
        ldx #$FF                   ; the quotient, pre-decremented
        sec
@div:   inx
        sbc #ROWCHARS
        bcs @div                   ; no borrow: C = 1 for the next
        dey                        ; a borrow from the high byte (C = 0)
        bmi @dd                    ; none left: done
        inx                        ; the next subtraction, folded in: C = 0, so
        sbc #ROWCHARS-1            ;  this takes 80; A >= 176, so no borrow
        bcs @div                   ; (always)
@dd:    stx barq
  .if BHW                          ; hardware: the Model B's mirror
        adc #ROWCHARS              ; C = 0 (the bmi): A = the remainder, C = 1
        sta wcxm                   ;  (A was the remainder - 80 + 256)
        lda #RINGROWS-1
        sbc barq                   ; (C = 1)
        clc
        adc wcy
        sta mrow
  .endif
        rts

; ----------------------------------------------------------------------------
; isr_body: the interrupt -- a chain step (T1) or the vsync (CA1).  The Model
; B's body, which low.s's stub (irq_handler) jumps to; on the Master it is the
; handler, irq_handler, at IRQ1V.
;   In:    A saved in MOS_IRQA by the MOS's IRQ entry;  Model B: X and Y saved
;          in irq_x, irq_y, ROMSEL_CPY pushed and bank 7 paged by the stub
;   Out:   a step: the section starting at the next restart shaped (R9, R4, R6,
;          R7, cur_r7), the one after it armed (T1 latch, R12/R13), sec_idx on
;          to the next entry, but never past Q's.  The vsync: T1 restarted with
;          VS2T, the frame re-phased (R9, R6, R4), a due flip taken (disp_sect,
;          flipvs; Master: disp_d), section 0 armed from the displayed buffer,
;          sec_idx = disp_sect, keys scanned, the sound effect stepped, the tune
;          stepped (the Master here; the Model B raises mus_tick for the stub)
;   Uses:  everything, restored: the Master returns by rti with A X Y as they
;          were; the Model B jumps to the stub, irq_ret from a step and irq_vret
;          from the vsync, which restores them
;   Post:  Master: ROMSEL as it was
;   Cost:  where the writes land (crtctime, 4 Oct 2026, level 0, 60 frames): a
;          step's R9 at char 20-78 of its section's first scanline on the
;          Master, 35-59 on the Model B; R4, R6, R7 at 18-char steps behind it
;          (R7 on the Master up to char 4 of scanline 1); R12/R13 on scanline 1.
;          (Q's step behind a two-line P2 lands a scanline later: @kend has
;          written its values already)
; A step's registers have deadlines: the CRTC ends a frame at the start of the
; scanline where row = R4 and line = R9, so for a two-line section both are due
; before scanline 1 -- 128 cycles after the restart -- and R6 is compared from
; scanline 1 on, so Q's R6 = 0 is too.  Hence the order R9, R4, R6, R7.  R12/R13
; (the next section's address) go last, onto scanline 1: on a partial (R4 = 0)
; some 6845s (the VL6845; Tom Seddon's r4-3 test) end the frame at once and
; reload the start address as scanline 0 ends, and an R12 written then was lost
; on a real Master (a 256-char tear, observed 24 Sep 2026).  ACCCON D (Master)
; is sampled by every fetch, so it must change before the restart: the D step,
; which ends the bar, fires BARLEAD early and switches it in the blanking of the
; bar's last line.
; ----------------------------------------------------------------------------
        PLACEH "MRAMCODE", "KRNCODE"
  .if BHW                          ; blessed placement: the Model B's body
isr_body:
  .else                            ;  behind the stub, the Master's handler
irq_handler:
        ; Q's step puts D back to 0 first thing, before Q's line 0 (QBLANK, main
        ; RAM, which D = 1 would read from HAZEL/ANDY): behind a two-line P2's
        ; own step there is no time for more.  The chain rests on Q until the
        ; vsync, so an interrupt with sec_idx = qsect is Q's step, or a vsync,
        ; which wants D = 0 too (the bar).
        lda sec_idx
        cmp qsect
        bne @notq
        lda ACCCON
        and #<~ACC_D
        sta ACCCON
@notq:  stx irq_x
        sty irq_y
  .endif
        bit VIA_IFR                ; V = T1's flag
        .assert VIA_IT1 = $40, error, "the T1 test is bit's V"
        bvs @t1                    ; (a bvc to @nott1 would be out of reach)
        jmp @nott1

        ; ---- the chain step
@t1:    lda load_req
        beq @chain
        jmp @ldcheck               ; a load: asked for, under way or ending
@chain: ldx sec_idx                ; X = this step's entry
  .if .not BHW                     ; hardware: ACCCON D
        ; The D step (dsect, the step after the bar's) switches D to the
        ; displayed buffer's before the restart, then holds so its CRTC writes
        ; follow it.  Other steps fire STEPLATE later instead (the bar's
        ; BARLATE) and do not wait.
        cpx dsect
        bne @notd
        lda ACCCON
        and #<~ACC_D
        ora disp_d
        sta ACCCON
        ldy #DHOLD
@dhold: dey
        bne @dhold
@notd:
        ; Q's step: D is 0 already (above); it holds as the D step does
        cpx qsect
        bne @shape
        ldy #DHOLD
@qhold: dey
        bne @qhold
@shape:
  .else                            ; hardware: the Model B's palette kill
        ; Q's step blacks the palette for Q's line 0 (the bar's line 0 from char
        ; 45: defs.s QBLANK).  It fires as the line before goes into its
        ; blanking; the last writes land with the beam already on the line,
        ; before the colours first show.  Behind a two-line P2 that P2's step
        ; does it (@kend).  The vsync puts the colours back (palon).
        cpx qsect
        bne @shape
        palfill PCOL_BLACK, PCOL_BLACK, PCOL_BLACK
@shape:
  .endif
        ; ---- the shape, deadline order (the header)
        crtcw R_MAXRAST, SECTAB+SE_R9, x
        crtcw R_VTOT, SECTAB+SE_R4, x
        lda #R_VDISP
        sta CRTC_IDX
        ldy SECTAB+SE_R6,x
        sty CRTC_DAT
        crtcw R_VSYNC, SECTAB+SE_R7, x
        sta cur_r7                 ; the vsync re-phases the frame from it
        ; ---- the next section's duration, into the T1 latch
        lda SECTAB+SE_T1L,x
        sta VIA_T1LL
        lda SECTAB+SE_T1H,x
        sta VIA_T1LH
        lda VIA_T1CL               ; clears T1's flag
        ; ---- the next entry, unless this is Q's (the only R7 = QVSYNC): a late
        ;      vsync must not walk sec_idx off the end of SECTAB
        lda cur_r7
        cmp #QVSYNC
        beq @addrw
        txa
        adc #SECENT-1              ; + SECENT: C = 1 (R7_NEVER > QVSYNC)
        sta sec_idx                ; (X still this entry's, for R12/R13)
        ; ---- the next section's address, last (the header)
@addrw: crtcw R_ADDRH, SECTAB+SE_R12, x
        crtcw R_ADDRL, SECTAB+SE_R13, x
  .if BHW                          ; hardware: the Model B's palette kill
        cpx ksect                  ; a two-line P2's step: Q's line 0's kill and
        bne @stepexit              ;  Q's shape too
        jmp @kend
  .endif
@stepexit:
  .if BHW                          ; blessed placement: the stub restores
        jmp irq_ret
  .else
        ldy irq_y
        ldx irq_x
        lda MOS_IRQA
        rti
  .endif

        ; ---- T1 with load_req non-zero (A = load_req)
@ldcheck:
        cmp #LDR_STOP
        bne @ldt1
        ldx sec_idx                ; a stop asked for: only the bar's step, a
        cpx disp_sect              ;  frame boundary, switches
        beq @ldsw
        jmp @chain
        ; ---- the switch: from this restart a standard frame, not the bar.
        ;      R9 = CHARLINES-1 and R6 = BARROWS are the vsync's already,
        ;      R12/R13 the bar's
@ldsw:  crtcw R_VTOT, #LDR4
        crtcw R_VSYNC, #LDR7
        sta cur_r7                 ; the resume's vsync re-phases from it
        lda #VIA_IT1
        sta VIA_IER                ; T1's interrupt off: the chain is stopped
        lda VIA_T1CL               ; (clears T1's flag)
        lda #LDR_STOPPED
        sta load_req
        bne @stepexit              ; (always)
        ; ---- a vsync while stopped (T1 restarted above, its interrupt off):
        ;      count it, and keep the keys and the sound going
@ldvsync:
        inc vsyncs
        jmp @keys
        ; ---- T1 while stopped or resuming: its interrupt is off, so its flag
        ;      is stale.  Clear it and see whether this is the vsync.
@ldt1:  lda VIA_T1CL
        bit irq_x                  ; 3 cycles, flags unused: this path's vsync
                                   ;  restarts T1 as late as when a jmp stood
                                   ;  here

        ; ---- not T1: the vsync?
@nott1: lda VIA_IFR
        and #VIA_ICA1
        bne @vsync
        beq @stepexit              ; neither: (always)

        ; ---- the vsync.  T1 first, at a fixed latency: the counter = VS2T, to
        ;      the bar's step.  Its latch (the bar's duration) is set below,
        ;      after the flip: it is the displayed buffer's.
@vsync: lda #<VS2T                 ; (immediates: VS2T counts on their timing)
        sta VIA_T1LL
        lda #>VS2T
        sta VIA_T1CH               ; loads the counter: T1 restarts
        lda #VIA_ICA1
        sta VIA_IFR                ; clears CA1's flag
        lda load_req
        cmp #LDR_STOPPED
        beq @ldvsync
        cmp #LDR_RESUME
        bne @t1on
        stz load_req               ; LDR_RUN (A dead: reloaded next)
@t1on:  lda #VIA_ISET|VIA_IT1
        sta VIA_IER
        ; ---- the re-phase: the vsync came at row cur_r7, so this frame ends at
        ;      row cur_r7 + QROWS-1-QVSYNC: the bar starts QROWS-QVSYNC rows
        ;      after the vsync even if the row counter had run past R4 (from
        ;      which a 6845 does not recover).  R6 = BARROWS is armed here, in Q
        ;      with the display off, for the bar: its step is too close to the
        ;      bar's scanline 1 for it.
        crtcw R_MAXRAST, #CHARLINES-1
        crtcw R_VDISP, #BARROWS
        lda #R_VTOT
        sta CRTC_IDX
        lda cur_r7
        clc
        adc #QROWS-1-QVSYNC
        and #%01111111             ; R4 is 7 bits
        sta CRTC_DAT
        ; ---- the flip, if one is asked for and FLIPWAIT vsyncs have passed
        ;      since the last
        inc vsyncs
        lda flip_req
        beq @noflip
        lda vsyncs
        sec
        sbc flipvs
        cmp #FLIPWAIT
        bcc @noflip
        lda vsyncs
        sta flipvs
        lda next_sect
        sta disp_sect
  .if .not BHW                     ; hardware: ACCCON D follows the flip, from
        lda next_buf               ;  the D step (the bar is D = 0)
        sta disp_d
  .endif
        stz01 flip_req             ; flip_req is 1 here (the beq above)
@noflip:
        ; ---- section 0, the displayed buffer's bar: its duration (the T1
        ;      latch) and its address (menu_sections moves it)
        ldx #0
        ldy disp_sect              ; (Y: sec_idx's below)
        beq @sec0
        ldx #BUFPAIR
@sec0:  lda BUF_SEC0T1,x
        sta VIA_T1LL
        lda BUF_SEC0T1+1,x
        sta VIA_T1LH
        crtcw R_ADDRH, BUF_SEC0, x
        crtcw R_ADDRL, BUF_SEC0+1, x
        lda #VIA_IT1
        sta VIA_IFR                ; clears T1's flag
        sty sec_idx                ; the chain starts at the bar's entry
  .if .not BHW                     ; hardware: ACCCON D
        tya                        ; dsect: the step after the bar's
        clc
        adc #SECENT
        sta dsect
        lda BUF_QS,x               ; qsect: Q's, which puts D back to 0
        sta qsect
        lda #ACC_D                 ; D = 0 for the bar: below $3000, the CRTC
        trb ACCCON                 ;  reads main RAM only with D = 0
  .else                            ; hardware: the Model B's palette kill
        lda BUF_QS,x               ; the step that blacks the palette: Q's, or
        sta qsect                  ;  behind a two-line P2 that P2's
        lda BUF_KS,x
        sta ksect
        ; the colours Q's step blacked, back (Q's display is off: the bar is the
        ; next thing shown), unless blank_palette has the screen black
        lda palon
        beq @nopal
        palfill PCOL_YELLOW, PCOL_MAGENTA, PCOL_CYAN
@nopal:
  .endif
        ; ---- the keys and the sound
@keys:  jsr scan_keys
  .if GAMESOUND
        jsr hook_sound             ; the game's own sound
  .elseif .not SOUND6              ; (SOUND6: sound6.s sfx_tick, in bank 6, after the tune:
                                   ;  below, and low.s irq_vret)
        ; ---- sound_tick: the sound effect's step, then the tune's.  An sfx is
        ;      steps of SFXSTEP_LEN bytes: three for the chip, then the vsyncs
        ;      to hold them; a first byte of SFX_END ends it.  sfx_req: 1-based
        ;      into sfx_tab (the game's), 0 for none;  sfx_ptr: the next step,
        ;      its high byte 0 for none playing (an sfx is never in page 0);
        ;      sfx_dur: the vsyncs left of the step being held.  The common case
        ;      (none asked, none playing) falls through to @tune.
        lda sfx_req
        bne @sfstart
        lda sfx_ptr+1
        bne @sfplay
  .endif
        ; ---- the tune: its player, music_tick, is in the menus' image of bank
        ;      7 (menus.s), and mus_on is set only while that image is in
@tune:  lda mus_on
  .if BHW .or GAMESOUND .or SOUND6
        sta mus_tick               ; (the Model B's stub reads it: low.s)
  .endif
  .if BHW                          ; blessed placement: the stub steps the tune
        jmp irq_vret
  .else
    .if SOUND6
        tay                        ; (Z: mus_on)
        lda ROMSEL_CPY             ; the interrupted code's bank: back after
        pha
        tya
        beq @snd
        dec mus_tick
        jsr page_logic             ; bank 7, for the menus' image
        jsr music_tick
@snd:   jsr page6                  ; the effects, in bank 6 (sound6.s)
        jsr sfx_tick
    .else
        beq @vexit
      .if GAMESOUND
        dec mus_tick
      .endif
        lda ROMSEL_CPY             ; the interrupted code's bank: back after
        pha
        jsr page_logic             ; bank 7, for the menus' image
        jsr music_tick
    .endif
        pla
        sta ROMSEL_CPY
        sta ROMSEL
@vexit: ldy irq_y
        ldx irq_x
        lda MOS_IRQA
        rti
  .endif
  .if .not (GAMESOUND .or SOUND6)
        ; ---- a new sfx: its first step at once
@sfstart:
        asl
        tax
        stz sfx_req                ; (A dead: reloaded next)
        lda sfx_tab-2,x
        sta sfx_ptr
        lda sfx_tab-1,x
        sta sfx_ptr+1
        bne @sfgo                  ; (always: not page 0)
        ; ---- one playing: its next step when this one's vsyncs are up
@sfplay:
        dec sfx_dur
        bne @tune
@sfgo:  ldaz sfx_ptr
        cmp #SFX_END
        beq @sfend
        jsr snd_write              ; (C = 0 from the cmp: snd_write keeps C, Y)
        ldy1
        lda (sfx_ptr),y
        jsr snd_write
        iny
        lda (sfx_ptr),y
        jsr snd_write
        iny
        lda (sfx_ptr),y
        sta sfx_dur
        lda sfx_ptr                ; the next step (C = 0 still)
        adc #SFXSTEP_LEN
        sta sfx_ptr
        bcc @tune
        inc sfx_ptr+1
        bne @tune                  ; (always: not page 0)
@sfend: jsr snd_write              ; SFX_END, the noise's silence (defs.s)
        lda #SN_LATCH|SN_VOL|(SFXTONE << SN_CHSHIFT)|SN_ATT_OFF
        jsr snd_write
    .if BHW                        ; CPU spelling: Y = 0 from ldaz (snd_write
        sty sfx_ptr+1              ;  keeps it)
    .else
        stz sfx_ptr+1
    .endif
        bne @tune                  ; (always: Z = 0 from snd_write's A)
  .endif

  .if BHW                          ; hardware: the Model B's palette kill
        ; ---- @kend: a two-line P2's step, its own writes done.  Q's interrupt
        ;      cannot be taken until this handler is done, too late for Q's
        ;      palette kill and for Q's R9/R4/R6 (due before Q's scanline 1).
        ;      So this step, on P2's last line, waits for its blanking
        ;      (crtctime: the first write at char 80 or later), kills the
        ;      palette and writes Q's shape; Q's own step writes the same values
        ;      again later.
@kend:  ldy #KENDWAIT
@kwait: dey
        bne @kwait
        palfill PCOL_BLACK, PCOL_BLACK, PCOL_BLACK
        crtcw R_MAXRAST, SECTAB+SECENT+SE_R9, x
        crtcw R_VTOT, SECTAB+SECENT+SE_R4, x
        crtcw R_VDISP, SECTAB+SECENT+SE_R6, x
        crtcw R_VSYNC, SECTAB+SECENT+SE_R7, x
        jmp irq_ret
  .endif

; ----------------------------------------------------------------------------
; scan_keys: the keyboard into keys
;   Out:   keys = the K_ bits (key_bits) of the keys in key_tab held;  A = keys;
;          X = $FF;  Y = key_tab's first byte
;   Uses:  A X Y
;   Post:  the keyboard's autoscan off; port A PA0-6 out, PA7 in
; Called from the vsync; keys is written once, at the end.  Placed with the
; interrupt's work.  test/harness.mjs, test/bopen.mjs and test/hbeebem patch its
; first byte to rts, so their inputs come from the tool alone.
; ----------------------------------------------------------------------------
scan_keys:
        lda #DDRA_KEYS
        sta VIA_DDRA
        lda #SL_KBD                ; latch bit SL_KBD = 0: autoscan off
        sta VIA_ORB
        lda #0
        ldx #KEYN-1
@key:   ldy key_tab,x              ; the key's number on PA0-6
        sty VIA_ORANH
        bit VIA_ORANH              ; N = PA7: held
        bpl @next
        ora key_bits,x
@next:  dex
        bpl @key
        sta keys
        rts
        .include "keymap.inc"      ; the game's: KEYN, key_tab, key_bits

  .if SOUND6                       ; in low RAM: bank 6's player (sound6.s) writes the chip too
        .segment "LOWCODE2"
  .endif
; ----------------------------------------------------------------------------
; snd_write: a byte to the SN76489
;   In:    A = the byte
;   Out:   A = DDRA_KEYS;  N = 0, Z = 0
;   Uses:  A
;   Keeps: X, Y, C
;   Post:  port A PA0-6 out, PA7 in (scan_keys's shape);  the keyboard's
;          autoscan on
; The byte goes out on port A; the addressable latch's SL_SND bit is the chip's
; write enable, held low through 8 nops (16 cycles).  Autoscan is turned on
; first so the keyboard does not drive PA7.  Placed with the interrupt's work;
; SOUND6: in low RAM (LOWCODE2), for bank 6's effects player and bank 7 alike.
; ----------------------------------------------------------------------------
snd_write:
        pha
        lda #DDRA_OUT
        sta VIA_DDRA
        lda #SL_KBD|SL_SET
        sta VIA_ORB
        pla
        sta VIA_ORANH
        lda #SL_SND
        sta VIA_ORB                ; write enable low
        .repeat 8
        nop
        .endrepeat
        lda #SL_SND|SL_SET
        sta VIA_ORB                ; write enable high
        lda #DDRA_KEYS
        sta VIA_DDRA
        rts

; ----------------------------------------------------------------------------
; music_stop: stop the tune and silence all four channels
;   Out:   mus_on = 0;  A = $1F;  C = 1
;   Uses:  A
;   Keeps: X, Y
; In the kernel because its callers (disc.s before a load, menu.s) may have the
; menus' image, which holds the tune's player, swapped out.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
music_stop:
  .if BHW                          ; CPU spelling: mus_on is 0 or 1
        lsr mus_on
  .else
        stz mus_on
  .endif
        ; channels 0, 1, 2 and 3 (the noise): $9F, $BF, $DF, $FF
        lda #SN_LATCH|SN_VOL|SN_ATT_OFF
        clc
@off:   pha
        jsr snd_write              ; (keeps C)
        pla
        adc #1 << SN_CHSHIFT       ; the next channel's; C = 1 past the noise's
        bcc @off
        rts

; ----------------------------------------------------------------------------
; set_palette: the MODE 1 palette: logical 0..3 = black, cyan, magenta, yellow
;   Out:   all PAL_N entries written from @pal;  Model B: palon = 1;  A = @pal's
;          first byte;  X = $FF
;   Uses:  A X
;   Keeps: Y
; In the kernel: the menus call it too.
; ----------------------------------------------------------------------------
set_palette:
  .if BHW                          ; hardware: the Model B's palette kill
        lda #1                     ; the vsync restores what Q's step blacks
        sta palon
  .endif
        ldx #PAL_N-1
@set:   lda @pal,x
        sta ULA_PAL
        dex
        bpl @set
        rts
        ; ---- entry i: index i, and the physical colour (PALPHYS's nibble) of
        ;      the logical colour in its bits 3 and 1 (LCOL_IDX_B1,
        ;      LCOL_IDX_B0), inverted
@pal:
.repeat PAL_N, i
        .byte (i << PAL_SHIFT) | (((PALPHYS >> (4 * ((i & LCOL_IDX_B1) / (LCOL_IDX_B1/2) | (i & LCOL_IDX_B0) / LCOL_IDX_B0))) & 15) ^ PAL_INV)
.endrepeat

; ----------------------------------------------------------------------------
; blank_palette: every palette entry black
;   Out:   Model B: palon = 0;  A = $F7;  C = 0
;   Uses:  A
;   Keeps: X, Y
; ----------------------------------------------------------------------------
blank_palette:
  .if BHW                          ; hardware: the Model B's palette kill
        lsr palon                  ; 1 or 0 -> 0: the vsync must not light the
                                   ;  colours Q's step blacks
  .endif
        lda #((PAL_N-1) << PAL_SHIFT) | (PCOL_BLACK ^ PAL_INV)
        sec
@blank: sta ULA_PAL                ; index 15 down to 0
        sbc #1 << PAL_SHIFT
        bcs @blank
        rts

; ----------------------------------------------------------------------------
; ring_addr7: the screen address of a ring character, from bank 7
;   In:    A = the map char row;  w16 = the char column (16 bits);  C = 0 (the
;          Master adds it in; the Model B's ringmod7 clears it)
;   Out:   sp = the character's address in the ring (Model B: the back buffer's,
;          from ringbhi);  A = sp+1
;   Uses:  A X, sp
;   Keeps: Y
; The kernel's ringaddr (bank 6 has the table form), for the sprite prologue,
; copy_partial and the menus: the slot by ringmod7, the row's offset from
; mul_rowlo/hi, x 8, the ring's base, folded at its end.
; ----------------------------------------------------------------------------
ring_addr7:
  .if BHW && RINGARITH
        ringwin                    ; (the row is in the window: every caller's is)
  .else
        ringmod7
  .endif
        tax
        lda mul_rowlo,x            ; slot * 80 + the column
        adc w16
        sta sp
        lda mul_rowhi,x
        adc w16+1
        asl sp                     ; x 8, the high byte in A
        rol
        asl sp
        rol
        asl sp
        rol                        ; C = 0: the char offset is under 8192
  .if BHW                          ; hardware: the Model B's two rings, at xx80
        tax
        lda sp
        adc #<RING_A
        sta sp
        txa
        adc ringbhi
  .else
        .assert (<RINGBASE) = 0, error, "ring_addr7: the Master's base is page aligned"
        adc #>RINGBASE             ; (C = 0 from the rol)
  .endif
        ringup sp
        sta sp+1
        rts
