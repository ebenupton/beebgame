; ============================================================================
; mirror.s -- the Model B's mirror row (BHW = 1 only: main.s includes it so)
;
; The Model B's rings are software, so the one displayed row that straddles a ring's
; end is read from a copy below the ring's base (defs.s MIRR_A; kernel.s @addr sends
; the chain there); the Master's CRTC folds its ring itself.  The copy is of the
; ring's last slot row: only the chars that row takes from it -- wcxm..79 -- need to
; be right, and when the window is slot aligned (wcxm = 0) no row straddles at all.
; It is made only when its row has been written: the writers note the range
; (draw_rect's head in bank 6, in line; in bank 7 the sprite prologue and
; copy_partial through banks.s mir_dirty -- both MIRDIRTY_BODY, macros.s); the notes
; are low.s's MIRDTY, MIRLO, MIRHI, MIRWCX, MIRMR.
;
;   mirror_copy   render_frame's last drawing step, after copy_partial
;
; Segment: ENGCODE (bank 7).
; ============================================================================
        .segment "ENGCODE"

; ----------------------------------------------------------------------------
; mirror_copy: bring the back buffer's mirror row up to date
;   In:    cur_buf; wcxm, mrow (calc_ring's); the buffer's mirror notes;
;          ringbhi, ringe3 (select_backbuf's)
;   Out:   the mirror holds the last slot row's chars from max(MIRLO, wcxm) to MIRHI;
;          MIRDTY = 0, MIRLO = $FF, MIRHI = 0 (the range empty), MIRWCX = wcxm,
;          MIRMR = mrow -- or nothing, when the row is clean or not read
;   Uses:  A X Y, tmp4, w16, w16b
; The whole row is made again when the last copy was for another mrow (the window
; crossed a slot boundary) or a larger wcxm (a move left uncovers chars left of the
; old wcxm, written while they were the row above's and so never noted).
; ----------------------------------------------------------------------------
mirror_copy:
        ldx cur_buf
        lda mrow
        cmp MIRMR,x
        bne @all
        lda wcxm
        cmp MIRWCX,x
        bcs @chk
@all:   lda #0                     ; the whole row: dirty, chars 0..79
        sta MIRLO,x
        lda #ROWCHARS-1
        sta MIRHI,x
        sta MIRDTY,x               ; (non-zero)
@chk:   lda MIRDTY,x
        bne @skip
        rts                        ; nothing has touched the row since the last copy
@skip:  lda wcxm
        bne @skip2
        rts                        ; slot aligned: no row straddles, so the mirror is
                                   ;  not read -- the flag stays up for when it is
@skip2: lda #0
        sta MIRDTY,x
        ldy MIRHI,x                ; Y = the last written char
        sta MIRHI,x                ; the written range is empty again (MIRLO below)
        lda MIRLO,x                ; the copy starts at the first written char, or at
        cmp wcxm                   ;  wcxm if the writing started left of it
        bcs @skip3
        lda wcxm
@skip3: sta tmp4                   ; tmp4 = the first char to copy
        lda #$FF
        sta MIRLO,x
        lda wcxm
        sta MIRWCX,x
        lda mrow
        sta MIRMR,x
        tya                        ; the chars from the first to the last
        sec
        sbc tmp4
        bcs @skip4
        rts                        ; none of it is at wcxm or beyond
@skip4: adc #0                     ; C = 1 from the bcs: + 1
        tax                        ; X = the chars to copy, 1..80: the loop's count
        ; ---- the source: the last slot row, base + (RINGROWS-1)*ROWBYTES + tmp4*8,
        ; whose page is ringe3 (select_backbuf: >RINGEND - 3); the mirror is one
        ; whole ring below it, two pages below the base's page
        .assert (RINGEND_A >> 8) - 3 = (RING_A >> 8) + (((RINGROWS-1)*ROWBYTES) >> 8) && (RINGEND_B >> 8) - 3 = (RING_B >> 8) + (((RINGROWS-1)*ROWBYTES) >> 8), error, "ringe3 is the last slot's page less the base's"
        .assert <(RING_A + (RINGROWS-1)*ROWBYTES) = $80 && <RING_A = <RING_B, error, "the last slot is at xx80"
        .assert (RING_A & $FF) + (RINGROWS-1)*ROWBYTES - RINGBYTES = -$200, error, "the mirror is 2 pages below the base page"
        lda tmp4                   ; T = tmp4*8: A = its high byte (tmp4 >> 5), C =
        lsr                        ;  bit 7 of its low byte -- the carry the +$80 of
        lsr                        ;  the slot's xx80 base makes below
        lsr
        lsr
        lsr
        tay
        adc ringe3                 ; the source page (C = 0 after: < $80)
        sta w16+1
        tya
        adc ringbhi                ; the base page + T's page (C = 0 in and out)
        sbc #1                     ; C = 0: - 2, the mirror's page
        sta w16b+1
        ; Both pointers are page aligned in the reads' favour: the source's low byte
        ; goes to Y (Y0, a multiple of 8, so the page step still falls between chars)
        ; and w16 keeps the page; the mirror's pointer comes down by Y0 -- its low byte
        ; is then $80 (L - (L ^ $80) = +-$80), a page lower when L < $80.  No read
        ; crosses a page (a store's cycles do not care).
        lda tmp4
        asl
        asl
        asl                        ; L, the char's offset in the row's page
        ; + $80, its carry taken above: Y0
        eor #<(RING_A + (RINGROWS-1)*ROWBYTES)
        tay
        bpl @skip5
        dec w16b+1                 ; L < $80
        .assert <(RING_A << 1) = 0, error, "the base's low byte doubled is 0"
@skip5: lda #<RING_A               ; the base's low byte, $80 (asserted above)
        sta w16b
        asl                        ; $80 << 1 = 0: the source's low byte
        sta w16
@char:  .repeat CHARBYTES
        lda (w16),y
        sta (w16b),y
        iny
        .endrepeat
        beq @page                  ; Y = 0: a page done (out of line: 1 char in 32)
@back:  dex
        bne @char
        rts
@page:  inc w16+1
        inc w16b+1
        jmp @back
