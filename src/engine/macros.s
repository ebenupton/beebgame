; ============================================================================
; engine/macros.s -- the engine's macros: the ring wrap, runn, the mirror's notes
;
; Included by engine.s after defs.s and vars.s; emits nothing by itself.  Each
; buffer's screen is a ring of RINGROWS char rows (defs.s): an address that runs off
; the ring's end must fold back to its start.  On the Master the ring is $3000-$7FFF,
; whole pages, and the CRTC folds it for free, so the end test is the sign bit
; (RINGEND = $8000) and only the high byte moves.  On the Model B a ring is 23 rows
; ($3980 bytes, not whole pages): its END is page aligned, so the test is a compare
; of the high byte with the buffer's ringehi (select_backbuf), but its base is at
; xx80, so the fold also takes $80 from the low byte, with the borrow into the high.
;
;   ringmod        A = a map char row -> its ring slot (bank 6: the table, or an and)
;   ringmod7       the same by subtraction on the Model B (bank 7 has no table)
;   ringtest       a high byte just moved forward: branch out if it ran off the end
;                  (the caller folds it there: tiles.s @rfold)
;   ringup         ringtest and its fold in one, in line
;   pagestep       a pointer's high byte one page on after its low byte carried, folded
;   spnext         sp on one char (CHARBYTES), folding at the ring end
;   spcold         spnext's page step, out of line
;   runn           a run's char count, min(rc_lim, cnt), as X (x RUNXS); C = 0
;   MIRDIRTY_BODY  note a range of the mirror's row written (the Model B)
;
; Labels.  No anonymous (':') labels, here or anywhere: their :+ / :- count across the
; whole assembly, so one added or removed retargets branches far away (tools/build.sh
; rejects them).  A macro's skips are cheap (@) labels -- a normal label, .local ones
; included, would end the enclosing routine's cheap-local scope: a fixed name, prefixed
; with the macro's, where the macro expands at most once in a scope (each header names
; them), else the caller's, passed in (pagestep's done, runn's done).  ringmod and
; ringwin use .local labels: their callers branch across neither.
;
; Every .if BHW here is hardware -- the ring -- but runn's, which is CPU spelling:
; the Master dispatches with jmp (abs,x), the Model B with a patched branch.
; ============================================================================

; ----------------------------------------------------------------------------
; ringmod: a map char row -> its ring slot, row mod RINGROWS
;   In:    A = the row, 0..255
;   Out:   A = the slot, 0..RINGROWS-1
;   Uses:  Master (RINGROWS a power of two): an and; X, C kept
;          Model B: X; C clobbered
;   Labels: the Model B's are .local (normal symbols).
; The Model B's is a table lookup in bank 6 (tiles.s ringmod_tab), RINGMOD_SPAN =
; RINGROWS*5 entries long: two subtractions bring any row under it, 141 bytes short
; of a 256-entry table.  draw_rect's head open-codes the same with the slot into X.
; ----------------------------------------------------------------------------
.macro ringmod
  .if (RINGROWS & (RINGROWS - 1)) = 0
        and #(RINGROWS-1)
  .else
        .local n1, n2
        cmp #RINGMOD_SPAN
        bcc n1
        sbc #RINGMOD_SPAN          ; C = 1 from the cmp
n1:     cmp #RINGMOD_SPAN
        bcc n2
        sbc #RINGMOD_SPAN
n2:     tax
        lda ringmod_tab,x
  .endif
.endmacro

; ----------------------------------------------------------------------------
; ringmod7: ringmod for bank 7 (calc_ring, ring_addr7), which has no copy of the table
;   In:    A = the row
;   Out:   A = the slot
;   Keeps: X.  Model B: C = 0 out (it leaves by its bcc).  Master: C kept
;   Labels: the Model B's @ringmod7_loop and @ringmod7_done (one expansion a scope).
; ----------------------------------------------------------------------------
.macro ringwin
        ; (RINGARITH, the Model B) A = a map char row IN THE WINDOW (wcy .. wcy +
        ; BUFROWS-1, mod 256) -> A = its ring slot, (wrow + row - wcy) mod RINGROWS: one
        ; fold, the sum being under 2*RINGROWS.  C = 0 out; X, Y kept
        .local n1
        .assert BUFROWS <= RINGROWS, error, "ringwin: one fold needs BUFROWS <= RINGROWS"
        sec
        sbc wcy
        clc
        adc wrow
        cmp #RINGROWS
        bcc n1
        sbc #RINGROWS              ; (C = 1 from the cmp)
        clc
n1:
.endmacro
.macro ringmod7
  .if ::BHW                        ; hardware: the ring (Model B: by repeated subtraction)
@ringmod7_loop: cmp #RINGROWS
        bcc @ringmod7_done
        sbc #RINGROWS              ; C = 1 from the cmp, and stays 1
        bcs @ringmod7_loop
@ringmod7_done:
  .else                            ; Master: ringmod's and
        ringmod
  .endif
.endmacro

; ----------------------------------------------------------------------------
; ringtest cold: has a high byte just moved forward run off the ring's end?
;   In:    A = the high byte; Master: N from the adc that made it
;   Out:   fell through: still in the ring, A kept (the common case); Model B C = 0
;          branched to cold: it has run off, for the caller to fold there (ringup's
;          fold, written out at tiles.s @rfold); Model B C = 1
;   Labels: none.
; The ring's end is a page boundary, so the test is on the high byte alone.  On the
; Model B the cmp leaves C = 1 on the way to cold, so the fold there needs no sec of
; its own whatever the caller was holding.
; ----------------------------------------------------------------------------
.macro ringtest cold
  .if ::BHW                        ; hardware: the ring (Model B: the buffer's ring end)
        cmp ringehi
        bcs cold
  .else                            ; Master
        bmi cold                   ; RINGEND = $8000: N from A
  .endif
.endmacro

; ----------------------------------------------------------------------------
; ringup p: fold a high byte just moved forward back into the ring, in line
;   In:    A = the high byte; p = the pointer whose high byte A holds (the Master's
;          fold never touches it); Master: N from A (every caller's adc)
;   Out:   A = the high byte, in the ring (the caller stores it)
;          Model B: p's low byte folded with it; C = 0 if no fold, 1 if folded
;          Master: C kept if no fold, 1 if folded
;   Labels: @ringup_done (one expansion a scope).
; Model B: A >= ringehi (>RINGEND_A = $44) > >RINGBYTES ($39), so the first sbc
; leaves C = 1.  The low byte folds by <RINGBYTES = $80, which borrows from A when
; p's low byte is below $80 (the sbc #0).
; Master: the adc of a positive operand that set N cannot have carried, so C = 0 and
; the sbc takes >RINGBYTES exactly.
; ----------------------------------------------------------------------------
.macro ringup p
  .if ::BHW                        ; hardware: the ring (Model B)
        cmp ringehi                ; the buffer's ring end, high byte (select_backbuf)
        bcc @ringup_done
        sbc #>RINGBYTES            ; C = 1 from the compare, and stays 1
        pha
        lda p
        sbc #<RINGBYTES            ; $80: borrows when p is below it
        sta p
        pla
        sbc #0                     ; the low byte's borrow (C = 1: none)
@ringup_done:
  .else                            ; Master
        bpl @ringup_done           ; RINGEND = $8000: N from A
        sbc #(>RINGBYTES)-1        ; C = 0 (see above): - >RINGBYTES
@ringup_done:
  .endif
.endmacro

; ----------------------------------------------------------------------------
; pagestep p, back: p's high byte one page on, folded at the ring's end
;   In:    p's low byte has just carried out of a step forward of under $80, so it
;          is now below $80
;   Out:   p updated; C = 0; A clobbered (the Master's only when it folds)
;          With back given, the Model B's common case (no fold) branches to back
;          with C = 0.
;   Labels: done, the caller's (a cheap one): the Model B's without back, the
;   Master's always (so the Master falls out at the end even given back: follow it
;   with a branch to back -- tiles.s @advc does, with a jmp).
; Model B: the fold takes a ring less the low byte's borrow from the high byte.  The
; low byte is below <RINGBYTES ($80), so the fold always borrows, and the low byte's
; share is +$80 (an eor).
; Master: RINGEND = $8000, so N from the inc says it ran off, and the page after the
; end is $80 exactly (the step is under a page): the high byte goes back to the
; base, the low byte unchanged (<RINGBYTES = 0).
; ----------------------------------------------------------------------------
.macro pagestep p, back, done
  .if ::BHW                        ; hardware: the ring (Model B)
        inc p+1
        lda p+1
        cmp ringehi
    .ifblank back
        bcc done
    .else
        bcc back
    .endif
        sbc #>RINGBYTES+1          ; C = 1 from the compare: a ring, and the borrow
        sta p+1
        lda p
        eor #<RINGBYTES            ; + $80
        sta p
        clc
        .assert <RINGBYTES = $80, error, "pagestep: the Model B's ring folds its low byte by $80"
    .ifblank back
done:
    .endif
  .else                            ; Master
        inc p+1                    ; N set: ran off the end
        bpl done
        lda #>RINGBASE
        sta p+1
        .assert <RINGBYTES = 0 && RINGEND = $8000, error, "pagestep: the Master's ring"
done:   clc
  .endif
.endmacro

; ----------------------------------------------------------------------------
; spnext cold: sp on one char (CHARBYTES), folding at the ring's end
;   Out:   sp moved on; A clobbered; C = 0 on the fall-through
;   Without cold: the page step (pagestep sp) is in line.  Labels: @spnext_done and
;   pagestep's @spnext_page (one expansion a scope).
;   With cold: a carry out of the low byte branches to cold, which must be in branch
;   reach and hold spcold (the caller's); the common case falls through.  Labels:
;   none.
; ----------------------------------------------------------------------------
.macro spnext cold
        lda sp
        clc
        adc #CHARBYTES
        sta sp
  .if .blank(cold)
        bcc @spnext_done           ; past the fold
        pagestep sp, , @spnext_page
@spnext_done:
  .else
        bcs cold
  .endif
.endmacro

; ----------------------------------------------------------------------------
; spcold back: spnext's page step, out of line
;   Out:   jumps to back with C = 0 (pagestep's)
;   Labels: pagestep's @spcold_page (one expansion a scope).
; ----------------------------------------------------------------------------
.macro spcold back
        pagestep sp, , @spcold_page
        jmp back
.endmacro

; ----------------------------------------------------------------------------
; runn: a run's chars, n = min(rc_lim, cnt), as X, the dispatch index: n x RUNXS
;   In:    rc_lim, cnt (draw_rect's)
;   Out:   X = n x RUNXS: the Model B's n (a table of branch offsets), the Master's
;          2n (jmp (abs,x)) -- the only copy: @advsp reads n and 8n back through X
;          from tables (tiles.s @run1, @run8); A = n (the Master: 2n); C = 0
;   Labels: done, the caller's (a cheap one: runn expands several times a scope).
; C = 0 out is for the Model B's patched branch and for @advsp after the blocks
; (which keep X and C).  rc_lim < cnt, a run with more to follow, falls through the
; bcc with C = 0 already; the row's last run pays the Model B a clc, and the Master's
; asl (n <= 4) clears it.
; ----------------------------------------------------------------------------
  .if BHW                          ; CPU spelling: the dispatch (see the header)
RUNXS = 1
  .else
RUNXS = 2
  .endif
.macro runn done
        lda rc_lim
        cmp cnt
        bcc done
        lda cnt
  .if BHW                          ; CPU spelling
        clc
  .endif
done:
  .if .not BHW                     ; CPU spelling
        asl                        ; n <= 4: C = 0
  .endif
        tax
.endmacro

; ----------------------------------------------------------------------------
; MIRDIRTY_BODY exit: note a range of the mirror's row written (the Model B's
; mirror, mirror.s)
;   In:    A = the first window column written of the row the mirror follows, X =
;          the last (0..79); wcxm; cur_buf
;   Out:   MIRDTY[cur_buf] = 1 and MIRLO/MIRHI[cur_buf] widened to the chars written,
;          in slot chars -- or nothing, when none of the range is in the last slot row
;   Uses:  A X Y
;   Labels: @mirdirty_last, @mirdirty_hi, @mirdirty_done (one expansion a scope).
; Those chars sit in the last slot row at wcxm on; only the ones up to char 79 are in
; it (the rest wrapped to slot row 0), and only those from wcxm are ever read.
; Blank exit: a routine, ending in rts (bank 7's mir_dirty, banks.s); given one, in
; line, leaving there or falling out (draw_rect's head, tiles.s).
; ----------------------------------------------------------------------------
.macro MIRDIRTY_BODY exit
        clc
        adc wcxm
        cmp #ROWCHARS
  .ifblank exit
        bcs @out
  .else
        bcs exit
  .endif
        pha
        txa                        ; C = 0: the bcs not taken
        adc wcxm
        cmp #ROWCHARS
        bcc @mirdirty_last
        lda #ROWCHARS-1
@mirdirty_last: tax
        ldy cur_buf
        lda #1
        sta MIRDTY,y
        pla
        cmp MIRLO,y
        bcs @mirdirty_hi
        sta MIRLO,y
@mirdirty_hi: txa
        cmp MIRHI,y
        bcc @mirdirty_done
        sta MIRHI,y
@mirdirty_done:
  .ifblank exit
@out:   rts
  .endif
.endmacro
