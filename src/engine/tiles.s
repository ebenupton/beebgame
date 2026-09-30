; ============================================================================
; engine/tiles.s -- the tile blitter and its frame calls, in bank 6
;
; Bank 6 holds every level's tile data, and the code that draws it into the back
; buffer's ring lives beside it.  The map is in bank 5: once a tile row, drawrect
; calls low RAM's mapstrip, which pages bank 5 in, runs the gather (gather.s) into
; GATHERL/GATHERH in low RAM, and pages bank 6 back.  The row loop then draws the
; tile row's one or two char rows from those pairs.
;
; On the Model B the code patches itself (select_backbuf ringaddr's operand, the row
; loop its dispatch jumps), so every store into bank 6 is inside a write window
; (cpu.inc: wrsel/wrback); on the Master the window macros are empty.
;
;   ringaddr        w16 = map char column, A = char row -> sp = its screen address
;   RINGLO/RINGHI   the ring rows' addresses (the Model B: a high-byte table a buffer)
;   drawrect        draw a rectangle of map chars (rc_x, rc_y, rc_w, rc_h)
;   scroll_validate make the current buffer hold the window, drawing only what it lacks
;   select_backbuf  point the blitters and sprite records at the current back buffer
;   bank6_entry     callbank's way in (BANKENTRY, segment TIL6ENT: the start of bank 6)
;   drawrect_clip   drawrect with the rect clipped to the window
;
; Segments: TILCODE (bank 6), TIL6ENT (bank 6's first bytes).
; ============================================================================

; ----------------------------------------------------------------------------
; ringaddr: the screen address of a map char in the current back buffer
;   In:   w16 = map char column (16 bit, < 8192), A = map char row
;   Out:  sp = the address, folded into the ring;  A = sp+1;  X = the ring slot
;         Y kept.
; The sprite prologue has its own copy in bank 7 (ringaddr7).  On the Model B the
; high-byte table is the current buffer's: select_backbuf patches @rh's operand
; (RINGHIOP).
; ----------------------------------------------------------------------------
        .segment "TILCODE"
ringaddr:
        ringmod                     ; A = the row's ring slot
        tax
        ; ---- sp+1:A = cx*8
        lda w16+1
        sta sp+1
        lda w16
        asl
        rol sp+1
        asl
        rol sp+1
        asl
        rol sp+1                    ; C = 0 (cx < 8192)
        ; ---- + the slot's address, folded at the ring end
        adc RINGLO,x
        sta sp
        lda sp+1
@rh:    adc RINGHI,x                ; Model B: the buffer's table (select_backbuf's)
        ringup sp
        sta sp+1
        rts

; ---- the ring rows' addresses, RINGROWS of them
  .if .not BHW
; The Master: one table for both buffers -- main and shadow RAM share the addresses.
RINGLO:
  .repeat RINGROWS, r
        .byte <(RINGBASE + r*ROWBYTES)
  .endrepeat
RINGHI:
  .repeat RINGROWS, r
        .byte >(RINGBASE + r*ROWBYTES)
  .endrepeat
  .endif
  .if BHW
; The Model B: both ring bases are xx80, so the two rings' low bytes are alike and
; only the high bytes are per buffer.  RINGHIOP is defined here, after the rts,
; because := ends the @ scope.
RINGHIOP := @rh + 1
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
  .if BHW
; The ring slot of a map char row, row mod RINGROWS, for ringmod (macros.s): five rings
; long, as the macro brings a row under RINGROWS*5 (the Master's ring is 32 rows: its
; ringmod is an and).  It sits here, before drawrect, with a pad after it: together
; they put drawrect's two hot stretches -- @run's bmi to @tile, over the solid chain,
; and @b31..@b7 -- each in a page, with the page boundary on the tile path between.
ringmodtab:
.repeat RINGROWS*5, i
        .byte i .mod RINGROWS
.endrepeat
        PAD ::PADB_T6, 0
  .endif

; ============================================================================
; drawrect: draw map tiles into the current back buffer
;   In:   rc_x = first map char column (16 bit), rc_y = first map char row,
;         rc_w = chars wide (1..80), rc_h = char rows (0 draws nothing)
;   Out:  rc_h = 0.  A, X, Y, sp, tp, ptr, w16, tmp (tmp2 under TILEMIRROR) and
;         the rc_ work bytes clobbered.
;
; Per rect: the invariants once (tx0, tiles-1, the first run's limit and char
; offset), one ringaddr for the first row, the map row pointer.  Per tile row: one
; mapstrip (the gather) and one or two char rows (@drawrow).  Per char row: runs --
; a run is the chars of one tile in this row, at most four -- dispatched by kind:
;   GATHERH bit 7 set   a full tile (its page; GATHERL its offset -- or, under
;                       TILEMIRROR, kind 3 in GATHERL's low bits: a mirror)
;   GATHERH = 0         the level's solid (id 0): one byte, SOLIDF, down every line
;   GATHERH = $40       a flat tile or the other solid: a pair from FLATTAB
;   GATHERH $06-$3F     a half tile: its page less $80 (GATHERL: its row and kind)
; and entered into an unrolled block by the run's length (1..4 chars).  The gather's
; encoding is described in docs/DESIGN.md (The tiles) and gather.s.
;
; Invariants an editor must keep:
; - A run never crosses the ring end.  A row may straddle it, but a ring row is 80
;   chars and the ring a whole number of them, so the end falls on a map column that
;   is a multiple of 80 -- a tile boundary, where a run starts.  A run can only END
;   exactly there, which carries sp into a new page: @advc folds it (pagestep).  So
;   the runs have no wrap test.
; - C is clear at every entry to @run: @drawrow's clc, and @advsp's sp step on the
;   loop back.  @hfill's sbc halfhi and the mirror's sbc #0 each borrow one on it.
;   @drawrow's exit (@rowdone) does NOT leave C clear.
; - rc_lim: the chars the current run may take -- 4 - rc_x&3 for a row's first run
;   (rc_sc0, set per rect), 4 for the later ones (@runnext).
; - @s0f's operand is SOLIDF and @hp0/@hp1's are HPAIR0/HPAIR1: the loader patches
;   them.  Their labels must stay (build.sh finds @s0f in game.dbg).
; - Model B: the dispatch patches a branch's offset, so the whole of drawrect, to
;   @done, is a write window into bank 6.  Each branch sits right before its blocks,
;   which share its page (asserted after the blocks; ringmodtab and PADB_T6 place
;   them), so it costs a jmp's 3 cycles.
; ============================================================================
        .segment "TILCODE"
drawrect:
        lda rc_h
        bne :+
        rts
:
  .if BHW
        ; ---- open the write window, to @done: the runs patch their dispatch jumps
        ; (cpu.inc).  A = bank 6's, which is paged already: harmless on a plain machine.
        bankimm lda, BANK_TILES, BANK_TILES, 3
        wrsel BANK_TILES, BANK_TILES, 3
  .endif
  .if BHW
        ; ---- the mirror's notes: a rect that touches the map row the mirror follows
        ; (mrow, calc_ring) says which window columns it wrote (mirdirty6, banks.s)
        lda mrow
        sec
        sbc rc_y
        cmp rc_h
        bcs @nomir                  ; the rect misses mrow
        lda rc_x
        sec
        sbc wcx                     ; the window column (rects are window clipped)
        pha
        clc
        adc rc_w
        tax
        dex                         ; ..the last one
        pla
        jsr mirdirty6               ; A = first column, X = last
@nomir:
  .endif
        ; ---- per-rect invariants: tx0 = rc_x >> 2, and tiles-1 =
        ; ((rc_x + rc_w - 1) >> 2) - tx0 = ((rc_x & 3) + rc_w - 1) >> 2, so tx1 never
        ; needs building: at most 3 + 80 - 1 = 82, one byte, no 16-bit shift.
        ; Each load of rc_x also leaves the copy ringaddr needs in w16.
        lda rc_x+1
        sta w16+1                   ; ringaddr's copy
        lsr                         ; C = bit 0, A = bit 1 (rc_x+1 <= 3)
        tax
        lda rc_x
        ror
        cpx #1                      ; C = bit 1
        ror                         ; A = tx0 (map width <= 256 tiles)
        sta rc_tx0
        lda rc_x
        sta w16                     ; ringaddr's copy
        and #3
        sta rc_sc0                  ; (rc_x & 3 for now)
        asl
        asl
        asl                         ; C = 0 (rc_sc0 < 4): the adc's clc
        sta rc_ro0                  ; the first run's char offset, (rc_x & 3) << 3
        lda rc_sc0
        adc rc_w
        sbc #0                      ; the -1 (C = 0); <= 83, no carry out
        lsr
        lsr
        sta rc_nt                   ; tiles-1
        ; the first run's limit, once a rect: each row's first run takes it
        ; (@drawrow), the later runs 4 (@runnext)
        lda #4
        sec
        sbc rc_sc0
        sta rc_sc0                  ; 4 - (rc_x & 3)
        ; ---- the first char row's screen address
        lda rc_y
        jsr ringaddr
        sta rc_sp+1                 ; ringaddr returns A = sp+1 (its last store)
        lda sp
        sta rc_sp
        ; ---- map row pointer: built once here (arithmetic, in low RAM: maprow6) and
        ; stepped on by the stride per tile row (@nextrow)
  .if TALLMAP
        ; Char rows are kept a byte (the ring's modulus needs no more) but the map row
        ; needs more: the rect's full row is the window's, wcyh:wcy, plus its offset
        ; from it.  Only the carry of that add is wanted: its low byte is rc_y.
        lda rc_y
        sec
        sbc wcy                     ; the offset, -128..127 (ldy, cmp, dey keep A)
        ldy #0
        cmp #$80
        bcc :+
        dey                         ; Y = its sign
:       clc
        adc wcy                     ; (= rc_y: only the carry is wanted)
        tya
        adc wcyh
        lsr                         ; C = bit 8 of the full row
        lda rc_y
        ror                         ; the tile row: the full row >> 1
  .else
        lda rc_y
        lsr                         ; the tile row
  .endif
        jsr maprow6
        ; ---- only a rect's first tile row can start on an odd char row -- after it
        ; @nextrow always lands even -- so the test is here, once, not in the loop
        lda rc_y
        and #1
        beq @rowy
        jsr mapstrip                ; odd: the first tile row's gather,
        jmp @second                 ; then its second char row
        ; ---- per tile row: the gather, run in bank 5 beside the map (gather5), into
        ; GATHERL/H in low RAM.  The write bank stays drawrect's window's, 6: the
        ; gather stores into no bank, nor does an interrupt.
@rowy:
        jsr mapstrip
        ; ---- draw this char row, and (without re-gathering) the odd row of the
        ; same tile row
        stz rc_sub                  ; the tile's top char row: offset 0
        lda rc_ro0
        sta rowoff
        lda #1                      ; the char row, as a half tile's flag bit
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@second:
        lda #32                     ; the tile's bottom char row: offset 32
        sta rc_sub
        ora rc_ro0
        sta rowoff
        lda #2
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@nextrow:
        ; ---- one map row on
        lda ptr
        clc
        adc MAPSTRIDE
        sta ptr
        lda ptr+1
        adc MAPSTRIDE+1
        sta ptr+1
        jmp @rowy
@done:  wrback BANK_TILES, 4        ; the write window's end
        rts

        ; ---- @run's rarer ways, here behind @drawrow in its branches' reach, A =
        ; GATHERH: a flat ($40, to @solid) or a half tile (its page less $80: $06-$3F)
@fx:    cmp #$40
        bcc @half                   ; below $40: a half (C = 0, which @hfill's sbc needs)
        jmp @solid                  ; a flat, or the other solid
@half:  ora #$80                    ; the half's page
        sta tp+1
        lda GATHERL,x               ; its kind (bits 0-2): is this row its fill?
        and rowbit
        beq @hcopy
        jmp @hfill
        ; no: the stored row -- GATHERL's bits $E0, (k&7)<<5, with rowoff's others,
        ; this run's char offset less the row's 32 (the two eors merge them)
@hcopy: lda GATHERL,x
        eor rowoff
        and #$E0
        eor rowoff
        jmp @tpsta

; ----------------------------------------------------------------------------
; @drawrow: one char row of the rect, run by run
;   In:   sp = rc_sp = the row's screen address; rc_sub, rowoff, rowbit set for it;
;         GATHERL/GATHERH = the tile row's gather
;   Out:  rc_sp and sp stepped one char row on (+640, folded at the ring end); C undefined
; rc_y is the rect's first row still: only drawrect's entry reads it, and every
; caller sets it.
; ----------------------------------------------------------------------------
@drawrow:
        ; (sp is the row's start already: ringaddr's for the rect's first, @rowdone's
        ;  for each after -- nothing between touches it)
        ; ---- the run state: first tile, first run's limit, all the row's chars left
        lda #0
        sta rc_gi                   ; the run's index into GATHERL/H
        lda rc_sc0
        sta rc_lim
        lda rc_w
        sta cnt                     ; chars left in the row
        clc                         ; C = 0 at every entry to @run (see drawrect)

        ; ---- a run: the kind from GATHERH.  Bit 7 set: a tile page ($80-$BF),
        ; copied.  Clear: a fill -- 0 the level's solid, on through (the commonest
        ; run); $40 a flat tile or the other solid (@fx).
@run:
        ldx rc_gi
        lda GATHERH,x
        bmi @tile
        SAMEPAGE *, @tile
        bne @fx
        ; ---- id 0, the level's solid, the commonest run: one byte, the loader's
        ; (SOLIDF), stored down every line of it.  Chars in this run, as @tpset.
@sol0:  lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n                    ; min(rc_lim, cnt)
        RUNX                        ; X, tmp = 8*rc_n
@sdisp:
  .if BHW
        ; ---- the Model B: a patched branch into the chain that follows, taken (C = 0,
        ; RUNX's asl).  The chain is 32 stores counting up, an iny between each, and
        ; is entered at a store with Y = 0, so it stores lines 0 to 8n-1: the branch
        ; skips the first 32 - 8n stores (MTO, zero page: 3 bytes a store, iny's).
        ; 7 cycles a byte, and one ldy for the run.
        ldy #0
        lda MTO-1,x
        sta @sj+1
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
@sj:    bcc @mch
@mch:
    .repeat 31
        sta (sp),y
        iny
    .endrepeat
        sta (sp),y
        jmp @advsp
        .assert @sj+2 = @mch && >@mch = >(@mch+72), error, "the solid chain must follow its branch, its entries in one page"
  .else
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
        jmpx @mt-2
  .endif

        ; ---- a stored tile.  Every tile is in bank 6, selected once per tile row.
@tile:  sta tp+1                    ; the tile pointer's high byte
  .if TILEMIRROR
        lda GATHERL,x
        and #7                      ; the kind: 0 a full tile, 3 a mirror
        beq @full
        jmp @mir
  .endif
@full:  lda GATHERL,x
        ora rowoff                  ; a full tile's lo byte is (id&3)<<6: bits 0-5 clear
@tpsta: sta tp
        ; ---- chars in this run: min(rc_lim, cnt) -> rc_n, X, tmp = 8*rc_n
@tpset:
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        RUNX
@tdisp:
  .if BHW
        ; the entry's offset into the branch, which is taken: C = 0 (RUNX's asl).  The
        ; blocks follow it in one page (asserted), so the branch costs what a jmp would
        lda @jto-1,x
        sta @tj+1
@tj:    bcc @b31
  .else
        jmpx @jt-2
@jt:    .word @b7, @b15, @b23, @b31
  .endif

; ----------------------------------------------------------------------------
; The tile copy: unrolled, one block per char in descending char order, so that
; entry at char n-1 copies chars n-1..0.  (tp),y -> (sp),y, 8 lines a char.
; ----------------------------------------------------------------------------
; CPYN: one line, A = (tp),y -> (sp),y; Y+1
.macro CPYN
        lda (tp),y
        sta (sp),y
        iny
.endmacro
; CHARCPY c: char c's 8 lines, (tp)+8c -> (sp)+8c.  A, Y clobbered; C kept.
.macro CHARCPY c
.if c = 0
  .if ::BHW
        ; line 0 (staz would reload the same 0 into Y)
        ldy #0
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

; ----------------------------------------------------------------------------
; @advsp: after a run -- count its chars off and step sp past them.  C is clear at
; every entry to @advsp, so the sbc gives cnt - rc_n - 1: -1 at the row's last run,
; whose sp step is skipped (sp is dead after it: @rowdone steps rc_sp).  Otherwise
; C = 1, and the adc #0 puts the 1 back and leaves C = 0.
; ----------------------------------------------------------------------------
@advsp: lda cnt
        sbc rc_n
        bmi @rowdone                ; the row's last run
        adc #0                      ; C = 1: +1 back, and C = 0
        sta cnt
        lda sp
        adc tmp                     ; sp += 8*rc_n
        sta sp
        bcs @advc                   ; a page on: the carry out of line, after @rowdone
        ; ---- the next run: later tiles in the row are whole and start at column 0
@runnext:                           ; C = 0 (the loop back's)
        lda #4
        sta rc_lim
        lda rc_sub
        sta rowoff
        inc rc_gi
        jmp @run
        ; ---- the row done: next char row, +640 with the ring wrap
@rowdone:
        lda rc_sp
        adc #<ROWBYTES              ; C = 0: @advsp's sbc borrowed
        sta rc_sp
        sta sp                      ; (sp too: the next row starts there)
        lda rc_sp+1
        adc #>ROWBYTES
        ringtest @rfold             ; the fold out of line
        sta rc_sp+1
        sta sp+1
        rts
@rfold: ringfold rc_sp
        sta rc_sp+1
        sta sp+1
        lda rc_sp                   ; (the Model B's fold moves the low byte too)
        sta sp
        rts
        ; ---- sp's carry into a new page: the ring's end only if the run ended exactly
        ; there (never inside one: drawrect).  C = 0 out.  (Model B: pagestep's common
        ; case branches to @runnext itself; the Master's falls to the jmp.)
@advc:  pagestep sp, @runnext
        jmp @runnext

  .if TILEMIRROR
; ----------------------------------------------------------------------------
; @mir: a mirrored full tile (TILEMIRROR, cpu.inc: off by default -- no level needs
; a mirror).  Its source's chars right to left, each byte's two game pixels swapped:
; ((b & $33) << 2) | ((b & $CC) >> 2).  The dither is per game pixel, so a game
; pixel's dots move as one.  A char at a time through spnext, which folds at the ring
; end: mirrors are rare tiles (the packer mirrors only what the bank cannot hold, the
; least used first), so there is no unrolled copy.
;   In:   X = rc_gi;  tp+1 = the source's page (@tile);  C = 0 (as at @run)
; ----------------------------------------------------------------------------
@mir:   lda GATHERL,x
        and #$C0                    ; the source tile's offset in its page
        ora rc_sub                  ; the char row
        sta tp
        ; the first char drawn is the source's rc_lim - 1 (the sbc #0 is the -1:
        ; C = 0, clear at every entry to @run)
        lda rc_lim
        sbc #0
        asl
        asl
        asl
        ora tp
        sta tp
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n                    ; min(rc_lim, cnt)
        sta tmp2                    ; chars to go
        ; ---- one char: 8 lines, each byte's pixels swapped
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
        ; the source's char to the left: a run stays in its tile's char row, so no
        ; borrow before the last char, and after it tp is dead
        lda tp
        sec
        sbc #8
        sta tp
        spnext
        dec tmp2
        bne @mc
        ; ---- @advsp's count; its sp step is done already (spnext)
        lda cnt
        clc
        sbc rc_n                    ; cnt - rc_n - 1
        bmi @mdone
        adc #0                      ; C = 1: +1 back, and C = 0 for @runnext
        sta cnt
        jmp @runnext
@mdone: jmp @rowdone
  .endif

; ----------------------------------------------------------------------------
; The fills: a half tile's fill row, a flat tile, the other solid -- no source bytes,
; a pair: even lines tp, odd lines tp+1, down every char.  (tp is otherwise unused
; on this path.)
; ----------------------------------------------------------------------------
@hfill:
        ; ---- a half's pair: k back out of its address.  The sbc borrows one (C is
        ; clear from @fx's cmp), and halfhi is the halves' page less 1.  GATHERH is the
        ; page less $80 (a half's mark): the $80 goes out with the asl's.
        lda GATHERH,x
        sbc halfhi
        asl
        asl
        asl
        asl
        sta tmp                     ; (k >> 3) << 4
        lda GATHERL,x
        lsr
        lsr
        lsr
        lsr                         ; (k & 7) << 1: a half's GATHERL has bits 4, 3 clear
        ora tmp
        tay                         ; Y = 2k: the pair's index
        ; lda HALFPAIR,y twice: the pair, from where the loader put the table.  It
        ; patches both operands (HPAIR0, HPAIR1, defined after the row loop).
@hp0:   lda $FFFF,y
        sta tp
@hp1:   lda $FFFF,y
        sta tp+1
        jmp @fillgo                 ; (the rarer: @solid falls through)
        ; ---- a flat tile or the other solid: the pair from FLATTAB
@solid: ldy GATHERL,x
        lda FLATTAB,y
        sta tp
        lda FLATTAB+1,y
        sta tp+1
        ; ---- chars in this run: min(rc_lim, cnt) -> rc_n, X, tmp = 8*rc_n
@fillgo:
        lda rc_lim
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        RUNX
@fdisp:
  .if BHW
        ; the entry's offset into the branch, taken as C = 0 (RUNX's asl); A is dead
        ; (every entry loads tp).  The blocks follow it in one page (asserted)
        lda @fto-1,x
        sta @fj+1
@fj:    bcc @f31
  .else
        jmpx @ft-2
@ft:    .word @f7, @f15, @f23, @f31
  .endif
; PCHAR c: char c filled with the pair -- even lines tp, odd lines tp+1.  Each byte
; is loaded once a char and stored four times, every store setting its own Y (70
; cycles a char, where alternating the loads down a dey chain was 88).  A, Y
; clobbered; C kept.
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
        iny
        sta (sp),y
        ldy #8*c+3
        sta (sp),y
        ldy #8*c+5
        sta (sp),y
        ldy #8*c+7
        sta (sp),y
.endmacro
@f31:   PCHAR 3
@f23:   PCHAR 2
@f15:   PCHAR 1
@f7:    PCHAR 0
        jmp @advsp

; ----------------------------------------------------------------------------
; The solid's blocks: A (SOLIDF) stored down all 8 lines of each char, from @s0f.
; ----------------------------------------------------------------------------
  .if .not BHW                      ; (the Master's: the Model B's is the chain at @sdisp)
@mt:    .word @m7, @m15, @m23, @m31
; MFIL k: A stored at lines k down to k-7 (one char, k = 8c+7).  Y clobbered; A, C kept.
.macro MFIL k
        ldy #k
        sta (sp),y
        .repeat 7
        dey
        sta (sp),y
        .endrepeat
.endmacro
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
  .endif

  .if BHW
; The Model B's dispatch, each group's entries by chars (1..4): a patched branch, the
; entry's offset from it, right before its blocks (the solid's chain: MTO, zero page).
; Each group's entries share a page with the branch's next byte, so a taken branch
; costs a jmp's 3 cycles.
@jto:   .byte @b7-(@tj+2), @b15-(@tj+2), @b23-(@tj+2), @b31-(@tj+2)
@fto:   .byte @f7-(@fj+2), @f15-(@fj+2), @f23-(@fj+2), @f31-(@fj+2)
        .assert @tj+2 = @b31 && @fj+2 = @f31, error, "the branch dispatches must sit right before their blocks"
        .assert @b7-(@tj+2) <= 127 && @f7-(@fj+2) <= 127, error, "a dispatch branch's blocks run past its reach"
        .assert >@b7 = >@b31 && >@f7 = >@f31, error, "a dispatch group straddles a page"
  .endif

; ---- the loader's patch points in the row loop
; HPAIR0/HPAIR1: @hfill's two loads of a half tile's pair.  The table sits above the
; halves, wherever the level's tiles ended, and the loader patches the operands.
; Defined here, after the row loop: a label would end its @ scope, and := puts them
; in labels.txt.  The first := ends the @ scope, so HPAIR1 goes by HPAIR0.
        .assert @hp1 = @hp0 + 5, error, "HPAIR1 must be 5 bytes past HPAIR0"
HPAIR0  := @hp0 + 1
HPAIR1  := HPAIR0 + 5
; SOLIDF: @s0f's operand, the solid's fill byte.  build.sh finds the label in
; game.dbg, which lists cheap labels -- a symbol here would end the scope.

; ============================================================================
; scroll_validate: make the current buffer hold the window (wcx, wcy), ROWCHARS x
; BUFROWS, drawing only the strips it lacks
;   In:   curbuf;  wcx (16 bit), wcy;  the buffer's BUF_CX/BUF_CXH/BUF_CY
;   Out:  the buffer's BUF_CX/BUF_CXH/BUF_CY = the window, BUF_BOTOK = 0.
;         A, X, Y, w16, w16b and drawrect's work clobbered.
; dx = wcx - BUF_CX: |dx| < 80 draws the new columns (a strip of dx columns, all
; BUFROWS high); dy = wcy - BUF_CY: a small one draws the new rows (full width).
; Anything bigger redraws the whole window (@full).  An invalid buffer holds
; BUF_CX = $80xx (lvreset, mark_dirty), which the |dx| >= 80 test sends to @full.
; Called from low RAM's validate, which pages bank 6 in.
; ============================================================================
        .segment "TILCODE"
scroll_validate:
        ldx curbuf
        ; ---- dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; ---- dx = wcx - BUF_CX
        lda wcx
        sec
        sbc BUF_CX,x
        sta w16
        lda wcx+1
        sbc BUF_CXH,x
        sta w16+1
        ; ---- |dx| >= 80 -> full  (A still holds w16+1, flags still from the sbc)
        beq @dxpos
        cmp #$FF
        bne @full
        lda w16
        cmp #<-79
        bcc @full
        ; ---- dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+BUFROWS-1
        eor #$FF                    ; (A still holds w16)
        adc #0                      ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bcc @docols                 ; C = 0 from the adc
        ; ---- the whole window.  Here, between two unconditional exits, in reach of
        ; every branch to it.
@full:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        bne @dorows                 ; BUFROWS <> 0
@dxpos: lda w16
        beq @dyc                    ; dx = 0
        cmp #ROWCHARS
        bcs @full                   ; not taken: C = 0 for the adc
        ; ---- dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
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
        ; ---- dy
@dyc:   lda w16b
        beq @done
        bpl @dypos
        ; ---- dy negative: rows wcy .. wcy+(-dy)-1
        cmp #<-(BUFROWS-1)          ; -dy >= BUFROWS: the whole window (as dy > 0 does)
        bcc @full
        eor #$FF
        adc #0                      ; C = 1 from the cmp: A = -w16b, and C = 0
        sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                 ; C = 0 from the adc
        ; ---- dy positive: the dy rows starting at wcy+BUFROWS-dy
@dypos: cmp #BUFROWS
        bcs @full                   ; not taken: C = 0 for the adc
        sta rc_h
        eor #$FF                    ; A = 255 - rc_h, C still 0 from the cmp above
        adc #BUFROWS                ; A = BUFROWS-1-rc_h, C = 1 (rc_h <= BUFROWS-1)
        adc wcy                     ; + wcy + 1 -> wcy + BUFROWS - rc_h
        sta rc_y
        ; ---- rows rc_y.., rc_h of them, the window's full width
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #ROWCHARS
        sta rc_w
        jsr drawrect                ; (falls into @done)
        ; ---- the buffer now holds the window
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
; ----------------------------------------------------------------------------
; select_backbuf: point the blitters at the current back buffer, and the sprite
; records at its half
;   In:   curbuf (0/1)
;   Out:  the Master: ACCCON's X bit (CPU access to shadow RAM for buffer 1).
;         The Model B: ringbhi, ringehi, ringe3 = the buffer's ring's constants, and
;         ringaddr's high-byte table (RINGHIOP) patched to the buffer's.
;         Both: recb (TIGHTBSS) or recp = the buffer's first sprite record.
;         A, X clobbered;  Y kept.
; It patches ringaddr's operand, so it is in bank 6; low RAM's selbb calls it with
; bank 6 paged and a write window open.
; ----------------------------------------------------------------------------
        .segment "TILCODE"
select_backbuf:
  .if BHW
        ; ---- the buffer's ring: its base and end, the two derived constants the
        ; blitters' wrap tests use (its row table for ringaddr is below)
        ldx curbuf
        lda @bhi,x
        sta ringbhi
        lda @ehi,x
        sta ringehi
        sec
        sbc #3
        sta ringe3                  ; >RINGEND - 3 (mirror.s)
  .else
        ; ---- ACCCON's X bit.  The ISR writes ACCCON's D bit: this read-modify-write
        ; must not straddle one.
        php
        sei
        lda ACCCON
        and #$FB
        ldx curbuf
        beq :+
        ora #$04
:       sta ACCCON
        plp
  .endif
        ; ---- the sprite records: X = curbuf (0/1)
  .if TIGHTBSS
        lda @rb,x                   ; its first sprite record
        sta recb
  .else
        lda @rlo,x                  ; its sprite record base
        sta recp
        lda @rhi,x
        sta recp+1
  .endif
  .if BHW
        ; ---- ringaddr's high bytes: this buffer's table
        lda @thl,x
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

; ============================================================================
; bank6_entry: callbank's way into this bank (BANKENTRY), at the start of bank 6
; (segment TIL6ENT).  It sets no write bank: drawrect_clip stores into no bank, and
; drawrect opens and closes its own window.  It falls straight into drawrect_clip.
; ============================================================================
        .segment "TIL6ENT"
bank6_entry:
        .assert * = BANKENTRY, error, "bank6_entry must start bank 6"

; ----------------------------------------------------------------------------
; drawrect_clip: drawrect, with the rect clipped to the current window
; (rows wcy..wcy+BUFROWS-1, cols wcx..wcx+ROWCHARS-1)
;   In:   rc_x (16 bit), rc_y, rc_w, rc_h: the rect, unclipped
;   Out:  the rect clipped, then drawrect (tail jump);  or nothing drawn if none of
;         it is in the window.  tmp clobbered (and drawrect's work).
; Callers: erase_old and draw_dirty, through callbank.
; ----------------------------------------------------------------------------
drawrect_clip:
        ; ---- rows
        lda rc_y
        sec
        sbc wcy                     ; rel row start (may be negative), kept in A
        bpl :+
        ; ---- start above the window: shrink
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
        ; ---- cols: rel = rc_x - wcx (16 bit signed)
:       lda rc_x
        sec
        sbc wcx
        tay                         ; rel lo, kept in Y
        lda rc_x+1
        sbc wcx+1
        tax                         ; rel hi, kept in X (N,Z as the sbc left them)
        bpl @right
        ; ---- rel < 0: the visible width is w + rel, and rel is already two's
        ; complement, so add rather than negate-and-subtract.  Only a result whose
        ; high byte comes out exactly 0 survives: anything else is the whole rect
        ; off the left edge.
        tya
        clc
        adc rc_w                    ; the low sum: the width, if it survives
        beq @none
        inx                         ; hi + C = 0 only for hi = $FF with a carry out
        bne @none
        bcc @none                   ; (inx and branches leave C alone)
        ; rel is now exactly 0, so the right clip is just min(width, ROWCHARS): the
        ; width is still in A
        ldx wcx
        stx rc_x
        ldx wcx+1
        stx rc_x+1
        cmp #ROWCHARS+1
        bcc :+
        lda #ROWCHARS
:       sta rc_w
        jmp drawrect
        ; ---- rel >= 0: off the right, or clip the right edge
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
