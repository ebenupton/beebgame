; ============================================================================
; ringaddr: screen address of map char (w16 = cx 16 bit, A = cy) -> sp
; ============================================================================
        .segment "TILCODE"          ; bank 6 (the sprite prologue has its own: ringaddr7)
ringaddr:
        ringmod
        tax
        lda w16+1
        sta sp+1
        lda w16
        asl
        rol sp+1
        asl
        rol sp+1
        asl
        rol sp+1                    ; sp+1:A = cx*8; C = 0 (cx < 8192)
        adc RINGLO,x
        sta sp
        lda sp+1
@rh:    adc RINGHI,x                ; (Model B: the buffer's table, select_backbuf's)
        ringup sp
        sta sp+1
        rts
  .if .not BHW                      ; the Master's rows, one table for both buffers:
RINGLO:                             ; main and shadow share the addresses
  .repeat RINGROWS, r
        .byte <(RINGBASE + r*ROWBYTES)
  .endrepeat
RINGHI:
  .repeat RINGROWS, r
        .byte >(RINGBASE + r*ROWBYTES)
  .endrepeat
  .endif
  .if BHW
RINGHIOP := @rh + 1                 ; (after the rts: := ends the @ scope)
; the ring rows' addresses, assembled: both bases are xx80, so the low bytes are the
; two rings' alike and only the high bytes are per buffer
RINGLO:
  .repeat RINGROWS, r
        .byte <(RING_A + r*ROWBYTES)
  .endrepeat
RINGHI:                             ; ring A's, and the operand's value at start
  .repeat RINGROWS, r
        .byte >(RING_A + r*ROWBYTES)
  .endrepeat
RINGHI_B:
  .repeat RINGROWS, r
        .byte >(RING_B + r*ROWBYTES)
  .endrepeat
  .endif

; ============================================================================
; drawrect: draw map tiles into the current back buffer.
;   rc_x (map chars, 16 bit), rc_y (map char rows), rc_w (chars 1..80), rc_h (rows)
; ============================================================================
        .segment "TILCODE"          ; bank 6, with the tiles
drawrect:
        lda rc_h
        bne :+
        rts
:
  .if BHW                           ; a write window, to @done: the runs patch their
        bankimm lda, BANK_TILES, BANK_TILES, 3   ; dispatch jumps (cpu.inc; A = bank 6's,
        wrsel BANK_TILES, BANK_TILES, 3          ; paged already: harmless on a plain one)
  .endif
  .if BHW
        lda mrow                    ; the map row the mirror follows (calc_ring): a rect
        sec                         ; that touches it says which window columns it wrote
        sbc rc_y
        cmp rc_h
        bcs @nomir
        lda rc_x
        sec
        sbc wcx                     ; the window column (rects are window clipped)
        pha
        clc
        adc rc_w
        tax
        dex                         ; ..the last one
        pla
        jsr mirdirty6
@nomir:
  .endif
        ; ---- per-rect invariants: tx0 = rc_x >> 2 ; tiles-1 = ((rc_x + rc_w - 1) >> 2) - tx0
        lda rc_x+1
        sta w16+1                   ; the ring address's copy, from this load too
        lsr                         ; C = bit 0, A = bit 1 (rc_x+1 <= 3)
        tax
        lda rc_x
        ror
        cpx #1                      ; C = bit 1
        ror                         ; A = tx0 (map width <= 256 tiles)
        sta rc_tx0
        lda rc_x                    ; tiles-1 = tx1 - tx0 = ((rc_x & 3) + rc_w - 1) >> 2,
        sta w16                     ; the copy the ring address needs, from the same load
        and #3                      ; so tx1 never needs building: max 3 + 80 - 1 = 82,
        sta rc_sc0                  ; one byte, no 16-bit shift, no w16
        asl
        asl
        asl                         ; C = 0 (rc_sc0 < 4): the adc's clc
        sta rc_ro0
        lda rc_sc0
        adc rc_w
        sbc #0                      ; C = 0 (<= 83, no carry): the -1
        lsr
        lsr
        sta rc_nt
        lda #4                      ; the first run's limit, once a rect (each row's first
        sec                         ; run takes it, @drawrow; the later runs 4, @runnext)
        sbc rc_sc0
        sta rc_sc0
        lda rc_y
        jsr ringaddr
        sta rc_sp+1                 ; ringaddr returns A = sp+1 (its last store)
        lda sp
        sta rc_sp
        ; ---- map row pointer: built once here (arithmetic, in low RAM: maprow6) and
        ; stepped on by the stride per tile row (@nextrow)
  .if TALLMAP                       ; (char rows are kept a byte, the ring's modulus needs
        lda rc_y                    ;  no more; the map row does: the rect's full row is
        sec                         ;  the window's, wcyh:wcy, plus its offset from it)
        sbc wcy                     ; the offset, -128..127 (A keeps it: ldy, cmp and
        ldy #0                      ;  dey leave it be)
        cmp #$80
        bcc :+
        dey                         ; (its sign)
:       clc
        adc wcy                     ; (= rc_y: only the carry is wanted)
        tya
        adc wcyh
        lsr                         ; C = bit 8 of the full row
        lda rc_y
        ror                         ; the tile row: the full row >> 1
  .else
        lda rc_y
        lsr
  .endif
        jsr maprow6
        lda rc_y                    ; only a rect's first tile row can start on an odd
        and #1                      ; char row -- after it @nextrow always lands even, so
        beq @rowy                   ; the test is here, once, not in the loop
        jsr mapstrip                ; (odd: the first tile row's gather, then its second
                                    ;  char row)
        jmp @second
@rowy:
        jsr mapstrip                ; the row's gather, run in bank 5 beside the map
                                    ; (gather5, below): GATHERL/H in low RAM.  The write
                                    ; bank stays drawrect's window's, 6: the gather
                                    ; stores into no bank, nor does an interrupt
        ; ---- draw this char row, and (without re-gathering) the odd row of the same tile row
        stz rc_sub
        lda rc_ro0
        sta rowoff
        lda #1                      ; the char row, as a half tile's flag bit
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@second:
        lda #32
        sta rc_sub
        ora rc_ro0
        sta rowoff
        lda #2
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@nextrow:                           ; one map row on
        lda ptr
        clc
        adc MAPSTRIDE
        sta ptr
        lda ptr+1
        adc MAPSTRIDE+1
        sta ptr+1
        jmp @rowy
@done:  wrback BANK_TILES, 4        ; (the window's end)
        rts
        ; ---- @run's rarer ways, here behind @drawrow in its branches' reach: a fill
        ; other than the solid (to @solid), a half tile
@fx:    jmp @solid                  ; (C is clear: clear at every entry to @run)
@half:  and rowbit                  ; a half tile: is this row its fill?  (A mirror's 3
        beq @hcopy                  ; is: @hfill tells them apart)
        jmp @hfill
@hcopy: lda GATHERL,x               ; no: the stored row -- (k&7)<<5 with this run's
        eor rowoff                  ; char offset less the row's 32: rowoff's bits
        and #$E0                    ; outside $E0 through the two eors
        eor rowoff
        jmp @tpsta
@drawrow:                           ; (rc_y is the rect's first row still: only
                                    ;  drawrect's entry reads it, and every caller sets it)
        ; ---- screen base (per-rect ringaddr, +640 per row)
        lda rc_sp
        sta sp
        lda rc_sp+1
        sta sp+1
        ; (a row may straddle the ring end, a run never does: a ring row is 80 chars
        ; and the ring a whole number of them, so the end falls on a map column that
        ; is a multiple of 80 -- a tile boundary, where a run starts.  A run can end
        ; exactly there, which @advc folds.)
        lda #0
        sta rc_gi
        lda rc_sc0
        sta rc_lim
        lda rc_w
        sta cnt
        clc                         ; C is clear at every entry to @run (@advsp's sp step
        ; leaves it clear on the loop back): @hfill's sbc halfhi and the mirror's borrow one
@run:
        ldx rc_gi
        lda GATHERH,x               ; bit 7 set: a tile page ($80-$BF), copied; clear, a
        bmi @tile                   ; fill: 0 the level's solid, on through (the commonest
        SAMEPAGE *, @tile
        bne @fx                     ; run), $40 up a flat tile or the other solid
        ; ---- id 0, the level's solid, the commonest run: one byte, the loader's
        ; (SOLIDF), stored down every line of it
@sol0:  lda rc_lim                  ; chars in this run, as @tpset
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        RUNX                        ; X, tmp = 8*rc_n
@sdisp:
  .if BHW
        lda @mtl-1,x                ; the entry's low byte into the jmp below (the
        sta @sj+1                   ; blocks share a page: asserted)
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
@sj:    jmp @m31
  .else
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
        jmpx @mt-2
  .endif
@tile:  sta tp+1                    ; the tile pointer's high byte
        lda GATHERL,x               ; every tile is in bank 6, selected once per tile row
        and #7                      ; the kind: 0 a full tile, 4..6 a half, 3 a mirror
        bne @half
@full:  lda GATHERL,x
        ora rowoff                  ; (a full tile's lo byte is (id&3)<<6: bits 0-5 clear)
@tpsta: sta tp
@tpset:
        ; chars in this run: min(rc_lim, cnt) -> rc_n, X, tmp = 8*rc_n
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        RUNX
@tdisp:
  .if BHW
        lda @jtl-1,x                ; the entry's low byte into the jmp (the blocks
        sta @tj+1                   ; share a page: asserted)
@tj:    jmp @b31
  .else
        jmpx @jt-2
@jt:    .word @b7, @b15, @b23, @b31
  .endif
        ; unrolled copy, one block per char in descending char order so that entry at
        ; char n-1 copies chars n-1..0.
.macro CPYN                         ; next line: A = (tp),y -> (sp),y ; y++
        lda (tp),y
        sta (sp),y
        iny
.endmacro
.macro CHARCPY c
.if c = 0
  .if ::BHW
        ldy #0                      ; line 0 (staz would reload the same 0 into Y)
        lda (tp),y
        sta (sp),y
        iny
  .else
        ldaz tp                     ; line 0 non-indexed
        staz sp
        ldy #1
  .endif
.else
        ldy #8*c
        lda (tp),y
        sta (sp),y
        iny
.endif
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        lda (tp),y                  ; line 7
        sta (sp),y
.endmacro
@b31:   CHARCPY 3
@b23:   CHARCPY 2
@b15:   CHARCPY 1
@b7:    CHARCPY 0
@advsp: lda cnt                     ; the chars left: C is clear at every entry to @advsp,
        sbc rc_n                    ; so cnt - rc_n - 1, -1 at the row's last run -- whose sp
        bmi @rowdone                ; step is skipped: sp is dead after it (@rowdone steps
        adc #0                      ; rc_sp); else C = 1: +1 back, and C = 0
        sta cnt
        lda sp
        adc tmp
        sta sp
        bcs @advc                   ; (the carry out of line, after @rowdone)
@runnext:                           ; (C = 0: the loop back's)
        lda #4                      ; later tiles in the row: whole
        sta rc_lim
        lda rc_sub
        sta rowoff                  ; later tiles in the row start at column 0
        inc rc_gi
        jmp @run
@rowdone:
        lda rc_sp                   ; next char row: +640 with ring wrap
        adc #<ROWBYTES              ; C = 0: @advsp's sbc borrowed
        sta rc_sp
        lda rc_sp+1
        adc #>ROWBYTES
        ringtest @rfold             ; (the fold out of line)
        sta rc_sp+1
        rts
@rfold: ringfold rc_sp
        sta rc_sp+1
        rts
@advc:  pagestep sp, @runnext        ; a page on: the ring's end only if the run ended
        jmp @runnext                ; exactly there (never inside one: drawrect); C = 0
  .if TILEMIRROR                    ; (cpu.inc: off by default -- no level needs a mirror)
        ; ---- a mirrored full tile: its source's chars right to left, each byte's two
        ; game pixels swapped -- ((b & $33) << 2) | ((b & $CC) >> 2); the dither is per
        ; game pixel, so a game pixel's dots move as one.  A char at a time through spnext,
        ; which folds at the ring end: rare tiles (the packer mirrors only what the
        ; bank cannot hold, the least used first), so no unrolled copy.
@mir:   lda GATHERL,x
        and #$C0
        ora rc_sub                  ; the char row
        sta tp
        lda rc_lim                  ; the first char drawn is the source's rc_lim - 1 (C = 0:
        sbc #0                      ;  clear at every entry to @run)
        asl
        asl
        asl
        ora tp
        sta tp
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        sta tmp2
@mc:    ldy #7
:       lda (tp),y
        and #$33
        asl
        asl
        sta tmp
        lda (tp),y
        and #$CC
        lsr
        lsr
        ora tmp
        sta (sp),y
        dey
        bpl :-
        lda tp                      ; the source's char to the left (a run stays in its
        sec                         ; tile's char row: no borrow before the last char,
        sbc #8                      ; and after it tp is dead)
        sta tp
        spnext
        dec tmp2
        bne @mc
        lda cnt                     ; @advsp's count, its sp step done here (spnext)
        clc
        sbc rc_n
        bmi @mdone
        adc #0
        sta cnt
        jmp @runnext
@mdone: jmp @rowdone
  .endif
        ; ---- fills: a half tile's fill row, a flat tile, the other solid -- no source
        ; bytes: a pair, even lines tp, odd tp+1, down every char
@hfill:
  .if TILEMIRROR
        lda GATHERL,x               ; the kind: bit 2 clear is a mirror (3), set a half
        and #4
        beq @mir
  .endif
        lda GATHERH,x               ; the half's pair: k back out of its address
        sbc halfhi                  ; (C is clear at every entry to @run: halfhi is less 1)
        asl
        asl
        asl
        asl
        sta tmp                     ; (k >> 3) << 4
        lda GATHERL,x
        lsr
        lsr
        lsr
        lsr                         ; (k & 7) << 1: a half's GATHERL has bits 4 and 3 clear
        ora tmp
        tay
@hp0:   lda $FFFF,y                 ; lda HALFPAIR,y: the pair, from where the loader
        sta tp                      ; put the table (it patches both operands: HPAIR0,
@hp1:   lda $FFFF,y                 ; HPAIR1, defined after the row loop)
        sta tp+1
        jmp @fillgo                 ; (the rarer: @solid falls through)
@solid: ldy GATHERL,x               ; the flat pair: even lines from tp, odd from tp+1
        lda FLATTAB,y               ; (tp is otherwise unused on this path)
        sta tp
        lda FLATTAB+1,y
        sta tp+1
@fillgo:
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        RUNX
@fdisp:
  .if BHW
        lda @ftl-1,x                ; the entry's low byte into the jmp (A is dead:
        sta @fj+1                   ; every entry loads tp); the blocks share a page
@fj:    jmp @f31
  .else
        jmpx @ft-2
@ft:    .word @f7, @f15, @f23, @f31
  .endif
; the pair: even lines tp, odd lines tp+1 -- each byte loaded once a char and stored
; four times, every store setting its own Y (70 cycles a char, where alternating the
; loads down a dey chain was 88)
.macro PCHAR c
        lda tp
        ldy #8*c+6
        sta (sp),y
        ldy #8*c+4
        sta (sp),y
        ldy #8*c+2
        sta (sp),y
        ldy #8*c
        sta (sp),y
        lda tp+1
        ldy #8*c+7
        sta (sp),y
        ldy #8*c+5
        sta (sp),y
        ldy #8*c+3
        sta (sp),y
        ldy #8*c+1
        sta (sp),y
.endmacro
@f31:   PCHAR 3
@f23:   PCHAR 2
@f15:   PCHAR 1
@f7:    PCHAR 0
        jmp @advsp

  .if .not BHW
@mt:    .word @m7, @m15, @m23, @m31
  .endif
.macro MFIL k
        ldy #k
        sta (sp),y
        .repeat 7
        dey
        sta (sp),y
        .endrepeat
.endmacro
        PAD ::PADB_M6, 0            ; (@m31..@m7 in one page: pads.inc)
@m31:   MFIL 31
@m23:   MFIL 23
@m15:   MFIL 15
@m7:    ldy #7
        .repeat 6
        sta (sp),y
        dey
        .endrepeat
        sta (sp),y
        staz sp                     ; line 0 non-indexed
        jmp @advsp
  .if BHW                           ; the Model B's dispatch: each group's entries by
@jtl:   .byte <@b7, <@b15, <@b23, <@b31   ; chars (1..4), low bytes only -- the jmp's
@mtl:   .byte <@m7, <@m15, <@m23, <@m31   ; high byte is its group's page
@ftl:   .byte <@f7, <@f15, <@f23, <@f31
        .assert >@b7 = >@b31 && >@m7 = >@m31 && >@f7 = >@f31, error, "a dispatch group straddles a page: pads.inc PADB_M6 (or move it)"
  .endif

; @hfill's two loads of a half tile's pair: the table sits above the halves, wherever
; the level's tiles ended, and the loader patches the operands.  (Defined here, after
; the row loop: a label would end its @ scope, and := puts them in labels.txt.)
        .assert @hp1 = @hp0 + 5, error, "HPAIR1 must be 5 bytes past HPAIR0"
HPAIR0  := @hp0 + 1                 ; (the first := ends the @ scope: HPAIR1 goes by it)
HPAIR1  := HPAIR0 + 5
; (@s0f's operand, the solid's fill byte, is SOLIDF to the loader: build.sh finds the
; label in game.dbg, which lists cheap labels -- a symbol here would end the scope)

; ============================================================================
; scroll_validate: make the current buffer hold the window (wcx, wcy), ROWCHARS x
; BUFROWS, drawing only the strips it lacks
        .segment "TILCODE"          ; bank 6, with the row loop
scroll_validate:
        ldx curbuf                  ; (an invalid buffer holds BUF_CX = $80xx, which the
                                    ;  |dx| >= 80 test below sends to @full)
        ; dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; dx = wcx - BUF_CX
        lda wcx
        sec
        sbc BUF_CX,x
        sta w16
        lda wcx+1
        sbc BUF_CXH,x
        sta w16+1
        ; |dx| >= 80 -> full  (A still holds w16+1, flags still from the sbc)
        beq @dxpos
        cmp #$FF
        bne @full
        lda w16
        cmp #<-79
        bcc @full
        ; dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+BUFROWS-1
        eor #$FF                    ; (A still holds w16)
        adc #0                      ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bcc @docols                 ; C = 0 from the adc
@full:  ; (here, between two unconditional exits, in reach of every branch to it)
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        bne @dorows                 ; BUFROWS <> 0
@dxpos: lda w16
        beq @dyc
        cmp #ROWCHARS
        bcs @full                   ; not taken: C = 0 for the adc
        ; dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
        sta rc_w
        eor #$FF                    ; A = 255 - rc_w, C still 0 from the cmp above
        adc #ROWCHARS               ; A = ROWCHARS-1-rc_w, C = 1 (rc_w <= 79)
        adc wcx                     ; + wcx + 1 -> wcx + ROWCHARS - rc_w
        sta rc_x
        lda wcx+1
        adc #0
        sta rc_x+1
@docols:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        jsr drawrect
@dyc:   lda w16b
        beq @done
        bpl @dypos
        cmp #<-30
        bcc @full
        eor #$FF
        adc #0                      ; C = 1 from the cmp: A = -w16b, and C = 0
        sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                 ; C = 0 from the adc
@dypos: cmp #BUFROWS
        bcs @full                   ; not taken: C = 0 for the adc
        sta rc_h
        eor #$FF                    ; A = 255 - rc_h, C still 0 from the cmp above
        adc #BUFROWS                ; A = BUFROWS-1-rc_h, C = 1 (rc_h <= BUFROWS-1)
        adc wcy                     ; + wcy + 1 -> wcy + BUFROWS - rc_h
        sta rc_y
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #ROWCHARS
        sta rc_w
        jsr drawrect                ; (falls into @done)
@done:
        ldx curbuf
        stz BUF_BOTOK,x             ; the window moved: the slot below is stale again
        lda wcy
        sta BUF_CY,x
        lda wcx
        sta BUF_CX,x
        lda wcx+1
        sta BUF_CXH,x
        rts

; ============================================================================
; Frame control
; ============================================================================
; select_backbuf: point the blitters at the current back buffer -- on the Master CPU
; access to its RAM (ACCCON X), on the Model B its ring's constants -- and the
; sprite records at its half
        .segment "TILCODE"          ; bank 6 (it patches ringaddr's operand)
select_backbuf:
  .if BHW
        ldx curbuf                  ; the buffer's ring: its base and end, the two
        lda @bhi,x                  ; derived constants the blitters' wrap tests use,
        sta ringbhi                 ; and its row table for ringaddr
        lda @ehi,x
        sta ringehi
        sec
        sbc #3
        sta ringe3
  .else
        php                         ; the ISR writes ACCCON's D bit; this read-modify-
        sei                         ; write of the X bit must not straddle one
        lda ACCCON
        and #$FB
        ldx curbuf
        beq :+
        ora #$04
:       sta ACCCON
        plp
  .endif
  .if TIGHTBSS
        lda @rb,x                   ; X = curbuf (0/1): its first sprite record
        sta recb
  .else
        lda @rlo,x                  ; X = curbuf (0/1): its sprite record base
        sta recp
        lda @rhi,x
        sta recp+1
  .endif
  .if BHW
        lda @thl,x                  ; ringaddr's high bytes: this buffer's table
        sta RINGHIOP
        lda @thh,x
        sta RINGHIOP+1
        rts
@thl:   .byte <RINGHI, <RINGHI_B
@thh:   .byte >RINGHI, >RINGHI_B
@bhi:   .byte >RING_A, >RING_B
@ehi:   .byte >RINGEND_A, >RINGEND_B
  .else
        rts
  .endif
  .if TIGHTBSS
@rb:    .byte 0, MAXREC
  .else
@rlo:   .byte <SPRREC, <(SPRREC+MAXREC*RECSZ)
@rhi:   .byte >SPRREC, >(SPRREC+MAXREC*RECSZ)
  .endif


        .segment "TIL6ENT"         ; the start of bank 6
; ============================================================================
; callbank's way into this bank (BANKENTRY): the write bank first -- A is the bank, as
; callbank left it -- then drawrect_clip
bank6_entry:
        .assert * = BANKENTRY, error, "bank6_entry must start bank 6"
                                    ; (no write bank: drawrect_clip stores into no bank,
                                    ;  and drawrect opens and closes its own window)
; drawrect_clip: drawrect, with the rect clipped to the current window
; (rows wcy..wcy+BUFROWS-1, cols wcx..wcx+ROWCHARS-1)
drawrect_clip:
        ; rows
        lda rc_y
        sec
        sbc wcy                     ; rel row start (may be negative), kept in A
        bpl :+
        ; start above window: shrink
        clc
        adc rc_h
        beq @none
        bmi @none
        sta rc_h
        lda wcy
        sta rc_y
        lda #0                      ; clipped to the top: rel is now 0
:       sta tmp                     ; stored here, so the common path never reloads it
        clc
        adc rc_h                    ; rel end+1
        cmp #BUFROWS+1
        bcc :+
        lda #BUFROWS                ; bcc not taken: C = 1 already, for the sbc
        sbc tmp
        beq @none
        bmi @none
        sta rc_h
:       ; cols: rel = rc_x - wcx (16 bit signed)
        lda rc_x
        sec
        sbc wcx
        tay                         ; rel lo, kept in Y
        lda rc_x+1
        sbc wcx+1
        tax                         ; rel hi, kept in X (N,Z as the sbc left them)
        bpl @right
        ; rel < 0: the visible width is w + rel, and rel is already two's complement,
        ; so add rather than negate-and-subtract.  Only a result whose high byte comes
        ; out exactly 0 survives: anything else is the whole rect off the left edge.
        tya
        clc
        adc rc_w                    ; the low sum: the width, if it survives
        beq @none
        inx                         ; hi + C = 0 only for hi = $FF with a carry out
        bne @none
        bcc @none                   ; (inx and branches leave C alone)
        ldx wcx                     ; rel is now exactly 0, so the right clip is just
        stx rc_x                    ; min(width, ROWCHARS): the width is still in A
        ldx wcx+1
        stx rc_x+1
        cmp #ROWCHARS+1
        bcc :+
        lda #ROWCHARS
:       sta rc_w
        jmp drawrect
@right: bne @none                   ; Z from the tax: rel >= 256 -> off right
        tya
        cmp #ROWCHARS
        bcs @none                   ; not taken: C = 0 for the adc
        adc rc_w
        cmp #ROWCHARS+1
        bcc :+                      ; not taken: C = 1 for the sbc
        sbc #ROWCHARS               ; the excess e = lo + w - ROWCHARS (C stays 1)
        eor #$FF
        adc rc_w                    ; w - e = ROWCHARS - lo
        sta rc_w
:       jmp drawrect
@none:  rts

