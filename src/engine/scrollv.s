; ============================================================================
; engine/scrollv.s -- scroll_validate (bank 6, TILCODE): included by tiles.s, after
; draw_rect, or before it with B6PACK (where it fills the room draw_rect's pad holds)
; ============================================================================
; ----------------------------------------------------------------------------
; scroll_validate: make the back buffer hold the window, drawing only the
; strips it lacks
;   In:    cur_buf; wcx (16 bit), wcy = the window;
;          BUF_CXL/BUF_CXH/BUF_CY[cur_buf] = the window the buffer holds
;          (BUF_CXH = BUF_INVALID: it holds nothing usable -- lv_reset,
;          mark_dirty)
;   Out:   BUF_CXL/BUF_CXH/BUF_CY[cur_buf] = the window;  the buffer holds it
;   Uses:  A X Y, w16, w16b, and draw_rect's (its rc_ arguments and work)
;   Pre:   bank 6 paged (low RAM's validate: no write bank -- this stores into
;          no bank, and draw_rect opens its own window)
; dx = wcx - BUF_CXL (16 bit): |dx| < ROWCHARS draws the new columns, a strip
; of |dx| columns and BUFROWS rows (at wcx for a move left, at wcx + ROWCHARS -
; dx for one right).  dy = wcy - BUF_CY: |dy| < BUFROWS draws the new rows, a
; strip of |dy| rows the window's full width (at wcy for a move up, at wcy +
; BUFROWS - dy for one down).  Anything bigger -- or an invalid buffer, whose
; BUF_CXH makes dx's high byte neither 0 nor $FF -- redraws the whole window
; (@full).  dx = 0 and dy = 0 draws nothing and leaves the buffer's record of
; the window as it is (@same: it is the window).  The dy < 0 block is written
; twice (@dx0, and after the columns) so that neither path pays a jmp.
; ----------------------------------------------------------------------------
scroll_validate:
        ldx cur_buf
        ; ---- dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; ---- dx = wcx - BUF_CXL
        lda wcx
        sec
        sbc BUF_CXL,x
        sta w16
        lda wcx+1
        sbc BUF_CXH,x
        sta w16+1
        ; ---- |dx| >= ROWCHARS: the whole window (A = w16+1, flags the sbc's)
        beq @dxpos
        cmp #$FF
        bne @full
        lda w16
        cmp #<(1-ROWCHARS)
        bcc @full
        ; ---- dx < 0, a move left: columns wcx .. wcx-dx-1, all BUFROWS rows
        eor #$FF                   ; (A = w16 still)
        adc #0                     ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bcc @docols                ; (always: C = 0 from the adc)
        ; ---- the whole window: the dy < 0 tail with rc_h = BUFROWS and rc_y =
        ; wcy.  Here, between two unconditional exits, in reach of every branch
        ; to it.
@full:
        clc
        lda #BUFROWS
        bcc @fullt                 ; (always: C = 0 from the clc)
        ; ---- dx = 0: the dy tests, X still cur_buf
@dx0:   lda w16b
        beq @same                  ; dx = 0 and dy = 0: nothing to draw
        bpl @dypos
        cmp #<-(BUFROWS-1)         ; -dy >= BUFROWS: the whole window (as dy > 0 does)
        bcc @full
        eor #$FF
        adc #0                     ; C = 1 from the cmp: A = -w16b, and C = 0
@fullt: sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                ; (always: C = 0 from the adc, or @full's clc)
@dxpos: lda w16
        beq @dx0                   ; dx = 0
        cmp #ROWCHARS
        bcs @full                  ; not taken: C = 0 for the adc
        ; ---- dx > 0, a move right: dx columns from wcx + ROWCHARS - dx
        sta rc_w
        eor #$FF                   ; A = 255 - rc_w, C = 0 still
        adc #ROWCHARS              ; A = ROWCHARS-1-rc_w, C = 1 (rc_w <= 79)
        adc wcx                    ; + wcx + 1: wcx + ROWCHARS - rc_w
        sta rc_x
        lda wcx+1
        adc #0
        sta rc_x+1
@docols:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        jsr draw_rect
        ; ---- then dy, as at @dx0
        lda w16b
        beq @done
        bpl @dypos
        ; ---- dy < 0, a move up: rows wcy .. wcy-dy-1
        cmp #<-(BUFROWS-1)         ; -dy >= BUFROWS: the whole window (as dy > 0 does)
        bcc @full
        eor #$FF
        adc #0                     ; C = 1 from the cmp: A = -w16b, and C = 0
        sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                ; (always: C = 0 from the adc)
        ; ---- dy > 0, a move down: dy rows from wcy + BUFROWS - dy
@dypos: cmp #BUFROWS
        bcs @full                  ; not taken: C = 0 for the adc
        sta rc_h
        eor #$FF                   ; A = 255 - rc_h, C = 0 still
        adc #BUFROWS               ; A = BUFROWS-1-rc_h, C = 1 (rc_h <= BUFROWS-1)
        adc wcy                    ; + wcy + 1: wcy + BUFROWS - rc_h
  .if .not TALLMAP
        ; Rows are bytes.  A map 256 rows tall (128 tiles) has the window's
        ; last buffer row at 256 when the window sits on the bottom (wcy = 256 -
        ; VISROWS); asked for here (dy = 1) that row wraps to 0, and draw_rect's
        ; head puts a rect's FIRST row by its byte -- slot 0 on the Model B,
        ; which is row 253's (253 mod 23 = 0), a visible row.  (A rect that only
        ; runs into row 256 is safe: @rowdone steps to the next slot.)  Row 256
        ; is never shown -- there is no fine scroll on the bottom -- so the
        ; strip is dropped.
        bcs @done                  ; wcy + BUFROWS - rc_h >= 256: nothing to draw
  .endif
        sta rc_y
        ; ---- rows rc_y .., rc_h of them, the window's full width
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #ROWCHARS
        sta rc_w
        jsr draw_rect              ; (falls into @done)
        ; ---- the buffer now holds the window
@done:
        ldx cur_buf
        lda wcy
        sta BUF_CY,x
        lda wcx
        sta BUF_CXL,x
        lda wcx+1
        sta BUF_CXH,x
@same:  rts                        ; (dx = 0 and dy = 0: the buffer's record is right)

