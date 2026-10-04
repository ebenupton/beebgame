; ============================================================================
; engine/frame.s -- the renderer: a frame's sprites, dirty tiles and flip, in bank 7
;
; render_frame draws one frame into the back buffer (cur_buf) and asks the vsync
; interrupt to flip to it.  The work is render_core's list: erase the sprites of two
; frames ago that have moved (each buffer keeps a record of every sprite it drew),
; let bank 6 draw the strips the scroll has uncovered, redraw the map tiles that
; changed, draw the new sprite list, and compose the partial row above the window.
; Bank 7 drives it all and keeps the records; bank 6 draws the tiles (the rects go to
; draw_rect_clip through low RAM's call_bank), banks 4 and 5 draw the sprites (the row
; loop, NIB_LOOPS, is assembled into each: draw_sprite hands over through call_bank).
;
;   draw_sprites   draw the sprite list into the back buffer, writing its records
;   erase_old      redraw the tiles under the buffer's records that are not kept
;   match_sprites  KEEP[i]: is sprite i what record i already shows?
;   add_sprite      add a sprite to the draw list (the game's call)
;   copy_partial   compose the ring row above the window from the fine-scrolled row
;   draw_sprite     the sprite prologue: clip, record, set up and call the row loop
;   render_core    the frame's steps, in order
;   mark_dirty     queue a changed map tile for both buffers (the game's call)
;   draw_dirty     redraw the back buffer's queued dirty tiles
;   render_frame   the game's call: render the back buffer and request the flip
;   wait_flip      spin until the pending flip has been taken
;
; Segment: ENGCODE (bank 7; on the Model B it ends at the kernel).  Each routine is
; its own `.segment "ENGCODE"` block, and THE ORDER OF THE BLOCKS IS THE LAYOUT'S:
; chosen over a profile to keep the hot loops' branches and reads off page crossings,
; with the PAD lines (pads.inc) before some blocks and before render_frame.  Keep the
; blocks where they are; the order and the pads are found by Cleo's test/blockopt.py
; and then test/padopt.py (in /Users/ebenupton/cleo/beeb/test), and re-found whenever
; the kernel's start moves.
;
; The record layout is defs.s's: with TIGHTBSS the records are arrays indexed by a
; register (rq, recb), otherwise 10-byte records walked through (rp).
; ============================================================================

; ============================================================================
; draw_sprites: draw every listed sprite into the back buffer
;   In:   the sprite list (SPR_*, nspr); KEEP[] from match_sprites; cur_buf;
;         recb / recp = the buffer's first record
;   Out:  record i written for sprite i (a skipped still box keeps its own);
;         RECCNT[cur_buf] = nspr;  A, X, Y clobbered
; Two passes.  A box star is an opaque rectangle with its background baked in, so it
; has to go down before anything that shares its space -- drawn in list order it
; would paint that background over whatever was standing there.  Pass 1 (dpass = 1)
; draws only the boxes (ids >= BOXID0), pass 0 only the rest.
; A box star the logic says nothing can disturb (a "still" alias, id >= BOXID0+BOXN)
; is skipped when it is the same frame already in the same place (KEEP = 2) and its
; record was not cut off at a window edge: nothing has been repainted under it, and
; all of it is on screen, so its screen pixels are still right.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the prologue and the records
        PAD ::PADB_SP, ::PADM_SP
draw_sprites:
        inc dpass                  ; dpass = 1: it is 0 between calls (start-up zeroes
                                    ;  it, and the passes' end leaves it 0)

  .if TIGHTBSS
        ; ---- TIGHTBSS: the records are arrays, indexed by rq
@pass:  stz spi
        lda recb                   ; the buffer's first record, stepped with spi
        sta rq
@l:     ldx spi                    ; X = the sprite's number: every field is ,x
        cpx nspr
        bcs @endpass
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
        ldy SPR_ID,x               ; Y = id for both compares
        cpy #BOXID0                ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                 ; not a still alias: draw it
        lda KEEP,x
        cmp #2
        bne @write                 ; not the same frame in the same place
        ldy rq
        lda REC_H,y
        bpl @next                  ; not clipped: all of it on screen and intact
        ; ---- write the record's id and position, and set up spx/spy
@write: ldy rq
        lda SPR_XL,x
        sta spx
        sta REC_XL,y
        lda SPR_XH,x
    .if DRAWFLAGS
        sta REC_XH,y               ; (the record keeps the flags: a flip is a change)
        asl                        ; bit 7, mirror, into C
        lda #0
        rol
        sta sp_dfl
        lda SPR_XH,x
        and #$7F
        sta spx+1
    .else
        sta spx+1
        sta REC_XH,y
    .endif
        lda SPR_YL,x
        sta spy
        sta REC_YL,y
        lda SPR_YH,x
        sta spy+1
        sta REC_YH,y
        ; Clipped until the prologue says otherwise: a sprite wholly off the window
        ; writes no rectangle, and must not look drawn and intact to the next keep test.
        lda #0
        sta REC_W,y                ; nothing drawn
        lda #$80
        sta REC_H,y                ; clipped
        lda SPR_ID,x
        sta REC_ID,y
        jsr draw_sprite            ; (it writes the rectangle: REC_CX.. at rq)
@next:  inc rq
        inc spi
        bne @l                     ; spi <= nspr: never wraps to 0
@endpass:
        lsr dpass                  ; 1 -> 0, C = 1: pass 0; 0 -> 0, C = 0: done,
        bcs @pass                  ;  and dpass is 0 again for the next call
        ldx cur_buf
        lda nspr
        sta RECCNT,x
        rts

  .else
        ; ---- the 10-byte records, walked through (rp)
@pass:  lda recp
        sta rp
        lda recp+1
        sta rp+1
        ldx #0                     ; X = spi = 0, tested at @chk
        beq @chk                   ; always
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
@l:     ldy SPR_ID,x               ; Y = id for both compares (X = spi: every field is ,x)
        cpy #BOXID0                ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next                  ; (C = 1, X = spi)
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                 ; not a still alias: draw it
        lda KEEP,x
        cmp #2
        bne @write                 ; not the same frame in the same place
        ldy #REC_H
        lda (rp),y
        bpl @next                  ; not clipped: all of it on screen and intact (C = 1 from the cmp)
        ; ---- write the record's id and position, and set up spx/spy
@write: ldy #1
        lda SPR_XL,x
        sta spx
        sta (rp),y
        iny
        lda SPR_XH,x
  .if DRAWFLAGS
        sta (rp),y                 ; (the record keeps the flags: a flip is a change)
        asl                        ; bit 7, mirror, into C
        lda #0
        rol
        sta sp_dfl
        lda SPR_XH,x
        and #$7F
        sta spx+1
  .else
        sta spx+1
        sta (rp),y
  .endif
        iny
        lda SPR_YL,x
        sta spy
        sta (rp),y
        iny
        lda SPR_YH,x
        sta spy+1
        sta (rp),y
        ; Clipped until the prologue says otherwise: a sprite wholly off the window
        ; writes no rectangle, and must not look drawn and intact to the next keep test.
        ldy #REC_H
        lda #$80
        sta (rp),y                 ; clipped
        dey                        ; REC_W
        asl                        ; A = 0
        sta (rp),y                 ; nothing drawn
  .if BHW
        tay                        ; Y = 0: the id's offset
        lda SPR_ID,x
        sta (rp),y
  .else
        lda SPR_ID,x
        sta (rp)                   ; offset 0 needs no index
  .endif
        jsr draw_sprite
        ldx spi                    ; X = the sprite's number again (the skips kept it)
        sec                        ; C = 1, as at the skips' arrivals
        ; ---- next record: rp += RECSZ (C = 1 at every arrival)
@next:  lda rp
        adc #RECSZ-1
        sta rp
        bcs @rpc                   ; (the carry out of line, after the rts)
@rpb:   inx
@chk:   stx spi
        cpx nspr
        bcc @l
@endpass:
        lsr dpass                  ; 1 -> 0, C = 1: pass 0; 0 -> 0, C = 0: done,
        bcs @pass                  ;  and dpass is 0 again for the next call
        ldx cur_buf
        lda nspr
        sta RECCNT,x
        rts
@rpc:   inc rp+1
        bcs @rpb                   ; always: C = 1, the bcs that came here
  .endif

; ============================================================================
; erase_old: redraw the tiles under the buffer's old records that are not kept
;   In:   RECCNT[cur_buf] records at recb / recp (what this buffer last drew);
;         KEEP[] from match_sprites, for the first nspr of them
;   Out:  A, X, Y clobbered
; A record past the new list's end (i >= nspr) is never kept; one of width 0 drew
; nothing.  Each rect goes to bank 6's draw_rect_clip through call_bank.  It runs
; before draw_sprites overwrites the records; it sits after it in the file only for
; where the two loops fall (pads.inc).
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_EO, ::PADM_EO
erase_old:
        ldx cur_buf
        lda RECCNT,x
        beq @done
        sta lcnt                   ; records to look at

  .if TIGHTBSS
        ; ---- TIGHTBSS: the records are arrays, indexed by rq
        stz lidx
        lda recb                   ; the buffer's first record, stepped with lidx
        sta rq
@l:     ldx lidx
        cpx nspr
        bcs @erase                 ; past the new list: never kept
        lda KEEP,x
        bne @next                  ; kept: leave it
@erase: ldy rq
        lda REC_W,y
        beq @next                  ; width 0: nothing was drawn
        sta rc_w
        lda REC_H,y
        and #$1F                   ; bits 0-4: the height
        sta rc_h
        lda REC_H,y                ; bits 5-6: the column's high bits
        lsr
        lsr
        lsr
        lsr
        lsr
        and #3
        sta rc_x+1
        lda REC_CX,y
        sta rc_x
        lda REC_CY,y
        sta rc_y
  .else
        ; ---- the 10-byte records, walked through (rp)
        ldx #0                     ; X = the record index (lcnt = RECCNT: the end)
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     cpx nspr
        bcs @erase                 ; past the new list: never kept
        lda KEEP,x
        bne @next                  ; kept: leave it
@erase: ldy #REC_W
        lda (rp),y
        beq @next                  ; width 0: nothing was drawn
        sta rc_w
        iny                        ; REC_H
        lda (rp),y
        and #$7F                   ; the height, without the clipped bit
        sta rc_h
        ldy #REC_CX
        lda (rp),y
        sta rc_x
        iny
        lda (rp),y
        sta rc_x+1
        iny                        ; REC_CY
        lda (rp),y
        sta rc_y
        stx lidx                   ; (call_bank clobbers X)
  .endif

        ; ---- redraw the rect's tiles, then the next record
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is draw_rect_clip
        jsr call_bank
  .if TIGHTBSS
@next:  inc rq
        inc lidx
        dec lcnt
        bne @l
  .else
        ldx lidx
@next:  lda rp
        clc
        adc #RECSZ
        sta rp
        bcc :+
        inc rp+1
:       inx
        cpx lcnt                   ; X = RECCNT: done
        bne @l
  .endif
@done:  rts

; ============================================================================
; match_sprites: the persistent sprite records -- which new sprites are already drawn?
;   In:   the sprite list (SPR_*, nspr); the buffer's records (RECCNT[cur_buf] of
;         them, at recb / recp); BUF_CXH[cur_buf]
;   Out:  KEEP[i] for every i < nspr: 2 = sprite i is record i (same id, same place:
;         its screen pixels are already right), 1 = a box star where a box star was
;         (a different frame of the same thing, same place), 0 = neither;
;         A, X, Y clobbered
; Once the window has moved since the buffer last drew (clip_mask, select_backbuf's), a
; record is kept only if it was not cut at the window's edge -- the strip that brought
; more of it into view was drawn as tiles -- and lies in the rows and columns the old
; window and the new both hold (krlo..., select_backbuf's): the rest of the buffer is
; this frame's strips, or ring slots reused while it was out of view (the composed row
; above the window) -- a record kept on through a move need not fit the window it was
; kept in.  (TIGHTBSS has only the first test.)
; Two box-star frames at the same place overwrite each other exactly -- every game
; pixel opaque, and each box covers the art of the frame before it -- so a frame
; change there needs no erase either: hence KEEP = 1.
; An invalid buffer (BUF_CXL high byte $80: a level start, or a dirty list that
; overflowed) is about to be redrawn whole, so nothing in it is kept and there is
; nothing to erase: its records go (RECCNT = 0).
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_MS, ::PADM_MS   ; (each machine's code off page crossings: pads.inc)
match_sprites:
        ; ---- an invalid buffer drops its records
        ldx cur_buf
        lda BUF_CXH,x
        bpl @valid
  .if BHW
        asl                        ; A = $80, an invalid buffer's (exactly): 0
        sta RECCNT,x
  .else
        stz RECCNT,x
  .endif
        ; ---- cnt = the records to compare, min(RECCNT, nspr)
@valid: lda RECCNT,x
        cmp nspr
        bcc :+
        lda nspr
:       sta cnt                    ; n = min(RECCNT, nspr)

  .if TIGHTBSS
        ; ---- TIGHTBSS: Y = the record, X = the sprite
        ldy recb
        ldx #0
@l:     cpx nspr
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next                  ; no record i: not kept
        lda SPR_ID,x
        cmp REC_ID,y
        beq @same
        cmp #BOXID0                ; different ids: are both box stars?
        bcc @next
        lda REC_ID,y
        cmp #BOXID0
        bcc @next
        lda #1                     ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                     ; 2 = identical, so its screen pixels are already right
        ; ---- and the same place
@pos:   sta tmp3
        lda SPR_XL,x
        cmp REC_XL,y
        bne @next
        lda SPR_XH,x
        cmp REC_XH,y
        bne @next
        lda SPR_YL,x
        cmp REC_YL,y
        bne @next
        lda SPR_YH,x
        cmp REC_YH,y
        bne @next
        lda REC_H,y                ; not if it was cut at the window's edge and the
        and clip_mask              ;  window has moved since (select_backbuf): its new
        bne @next                  ;  part is the scroll's tiles
        lda tmp3
        sta KEEP,x                 ; same screen pixels in the same place: skip the erase
@next:  iny
        inx
        bne @l                     ; always: i+1 <= MAXSPR
@done:  rts

  .else
        ; ---- the 10-byte records, walked through (rp); X = i throughout
        ldx #0
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     cpx nspr
        bcs @done
        cpx cnt
        bcs @zero                  ; no record i: not kept
        lda SPR_ID,x
        cmpz rp                    ; (zp): offset 0 needs no index register
        beq @same
        cmp #BOXID0                ; different ids: are both box stars?
        bcc @zero
        ldaz0 rp                   ; Y = 0 from the cmpz above
        cmp #BOXID0
        bcc @zero
        lda #1                     ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                     ; 2 = identical, so its screen pixels are already right
        ; ---- kept if the same place too: record bytes 1-4
@pos:   sta KEEP,x                 ; (undone at @zero if the place differs)
        ldy1                       ; Y = 0 on both ways in (cmpz, ldaz)
        lda SPR_XL,x
        cmp (rp),y
        bne @zero
        iny
        lda SPR_XH,x
        cmp (rp),y
        bne @zero
        iny
        lda SPR_YL,x
        cmp (rp),y
        bne @zero
        iny
        lda SPR_YH,x
        cmp (rp),y
        bne @zero
        lda clip_mask              ; same screen pixels in the same place: skip the erase
        beq @next                  ;  -- if the window has not moved since (select_backbuf)
        jmp @moved                 ;  or else if it fits both windows (out of line)
@zero:  stz KEEP,x                 ; not kept
@next:  lda rp
        clc
        adc #RECSZ
        sta rp
        bcc :+
        inc rp+1
:       inx
        bne @l                     ; always: i+1 <= MAXSPR
@done:  rts
        ; ---- the window has moved: kept only if not cut at the window's edge and
        ; inside the rows and columns both windows hold (the rest of the buffer is the
        ; scroll's tiles, or slots reused since)
@moved: ldy #REC_H
        lda (rp),y
        bmi @zero2
        sta tmp3                   ; its height
        dey
        dey                        ; REC_CY
        .assert REC_H - 2 = REC_CY && REC_CY - 2 = REC_CX, error, "match_sprites: the fields' order"
        lda (rp),y
        sec
        sbc wcy                    ; its row in this window
        cmp krlo
        bcc @zero2
        adc tmp3                   ; C = 1: row + height + 1
        bcs @zero2
        cmp krhi2
        bcs @zero2
        dey
        dey                        ; REC_CX
        lda (rp),y
        sec
        sbc wcx
        sta tmp3                   ; its column in this window
        iny
        lda (rp),y
        sbc wcx+1
        bne @zero2
        lda tmp3
        cmp kclo
        bcc @zero2
        ldy #REC_W
        adc (rp),y                 ; C = 1: column + width + 1
        bcs @zero2
        cmp kchi2
        bcs @zero2
        jmp @next
@zero2: jmp @zero
  .endif

; ----------------------------------------------------------------------------
; add_sprite: add a sprite to the draw list
;   In:   A = id;  spx, spy = its reference point in game pixels (map coordinates)
;   Out:  nspr + 1, unless the list is full (MAXSPR): then the sprite is dropped;
;         A, X clobbered, Y kept
; The game's call, a sprite at a time, each frame.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
add_sprite:
        ldx nspr
        cpx #MAXSPR
        bcs @full                  ; full: dropped
        sta SPR_ID,x
        lda spx
        sta SPR_XL,x
        lda spx+1
        sta SPR_XH,x
        lda spy
        sta SPR_YL,x
        lda spy+1
        sta SPR_YH,x
        inc nspr
@full:  rts

; ============================================================================
; copy_partial: compose the ring row above the window (the "A" section's source)
;   In:   wfine, wcx, wcy, ring_s; (Model B) barq, RING_A, ringbhi
;   Out:  lines 0..(7-wfine) of the row above the window = lines wfine..7 of ring
;         row wcy, all 80 columns;  A, X, Y, sp, ptr, w16 clobbered
; Does nothing when the fine scroll is 0.  Otherwise it copies the whole row, every
; frame: tracking the columns drawn since the last copy saves under 0.3% of a frame
; (measured).
; The copy is unrolled by line pairs and entered at the pair for this wfine through a
; patched branch (@ftab).  A loop here is 40 bytes smaller and ~1% of a frame slower:
; every frame with vertical movement recomposes all 80 columns.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, beside render_core
        PAD ::PADB_CP, ::PADM_CP   ; (each machine's code off page crossings: pads.inc)
copy_partial:
        lda wfine
        bne :+
        rts                        ; fine scroll 0: nothing to compose
:
        ; ---- the run: all ROWCHARS columns from column 0; w16 = its map column, wcx
        lda wcx
        sta w16
        lda wcx+1
        sta w16+1
  .if .not BHW
        clc                        ; C = 0 for ring_addr7 (the Master's ringmod keeps C)
  .endif

  .if BHW
        ; ---- Model B: the composed row is the ring row above the window, the last
        ; slot when the window starts at slot 0 -- then the mirror follows it, so
        ; note the columns (mir_dirty: A = first, X = last).  No C needed: mir_dirty
        ; clears it, and ring_addr7's ringmod7 leaves by its bcc with C = 0.
        lda barq
        bne @nomir
        ldx #ROWCHARS-1            ; the whole row: columns 0..79
        lda #0
        jsr mir_dirty              ; (bank 7's copy)
@nomir:
  .endif

        ; ---- source: sp = row wcy at column wcx, wfine lines into the char
        lda wcy
        jsr ring_addr7             ; sp = source start (row wcy, column wcx)
        ; Offsetting sp by wfine (under 8, and a char is 8-aligned) keeps its page
        ; crossings on the real char boundaries, so spnext's fold still lands where it
        ; should.
        lda sp
        clc
        adc wfine
        sta sp

        ; ---- dest: ptr = the same column of the composed row, the row above the
        ; window: ring char (ring_s + col - 80) mod RINGCHARS, as a real address in
        ; the ring
        ; ring_s - 80 for column 0: the low byte of -80 is the first addend
        lda #<(-ROWCHARS)          ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc ring_s
  .if BHW
        ; Model B: the char's low byte in A and its high byte in ptr+1, so the
        ; base's low byte ($80) adds straight to A at the end
        tax
        lda ring_s+1
        adc #$FF
        sta ptr+1
        txa
        bcs @pnf                   ; C = 1: >= 0, already in the ring
        ; < 0: + RINGCHARS, 16 bit (23 rows is not whole pages)
        adc #<RINGCHARS
        tax
        lda ptr+1
        adc #>RINGCHARS
        sta ptr+1
        txa
        ; char -> byte address (ptr+1:A), + the buffer's base.  The rols leave C
        ; clear: the offset is under $4000.
@pnf:   asl
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        adc #<RING_A               ; the base is xx80, and which xx is the buffer's
        sta ptr
        lda ptr+1
        adc ringbhi
  .else
        sta ptr
        lda ring_s+1
        adc #$FF
        bcs @pnf                   ; C = 1: >= 0, already in the ring
        adc #>RINGCHARS
        ; char -> byte address (A:ptr), + RINGBASE.  The rols leave C clear: the
        ; offset is under $5000.
@pnf:   asl ptr
        rol
        asl ptr
        rol
        asl ptr
        rol
        adc #>RINGBASE
  .endif
        sta ptr+1

        ; ---- the copy.  Y is the dest line, 0..7-wfine, and the source line is
        ; Y + wfine through the offset sp: enter the unrolled copy at the pair for
        ; this wfine by patching the loop's back branch.
        ldx wfine
        lda @ftab-2,x              ; this wfine's entry, as a branch offset
        sta @back+1                ; patched into the loop's back branch
        ldx #ROWCHARS              ; char counter in X: dex/beq is 3 cycles cheaper
        bcc @back                  ; in at the patched entry (C = 0: ptr+1's adc cannot carry)
        ; the entries by wfine: 2 -> six lines (@g4), 4 -> four (@g2), 6 -> two (@g0)
@ftab:  .byte <(@g4-(@back+2)), 0, <(@g2-(@back+2)), 0, <(@g0-(@back+2))
@g4:    ldy #5
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
@g2:    ldy #3
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
@g0:    ldy #1
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
        ; ---- next char, both with the ring fold on the page crossing: the composed
        ; row can straddle the ring end like any other row (the page steps out of line)
        lda sp                     ; spnext @sfold without its clc: C = 0 at every
        adc #8                     ; arrival (the copy is entered by a taken bcc and
        sta sp                     ; lda/sta/ldy/dey keep C)
        bcs @sfold
@sback: dex
        beq @done
        lda ptr                    ; C = 0: spnext's bcs not taken, or spcold's clc
        adc #8
        sta ptr
@back:  bcc @g4                    ; patched (@ftab): C = 1 falls into the page step
        SAMEPAGE *, @g4
        SAMEPAGE *, @g0
        pagestep ptr, @back        ; ptr's page step (needs no C in)
        bcc @back                  ; (C = 0: pagestep's)
@done:  rts
        ; ---- the page step, out of line
@sfold: spcold @sback

; ============================================================================
; draw_sprite: the sprite prologue -- draw one sprite
;   In:   A = id;  spx, spy = its reference point in game pixels (map coordinates);
;         (DRAWFLAGS) sp_dfl = the list's mirror;  X dead;
;         the record in hand: rq (TIGHTBSS) or rp, set up by draw_sprites
;   Out:  the record's rectangle (REC_CX, REC_CY, REC_W, REC_H) written when any of
;         the sprite is in the window; then the row loop has drawn it.  Returns
;         without either when it is wholly off the window or not in this level.
;         A, X, Y and the prologue's zero page clobbered.
; The directory is split.  The level's part, in bank 7 (banks.s, ldprog.s): DIRL and
; DIRH, the image's address by id, 0 if not in this level, bit 7 of the high byte
; clear for bank 5.  The game's part: the geometry by shape (sprg_ix by id; sprg_w,
; sprg_rx, sprg_ry, sprg_ln and, with SPRGFL, sprg_fl by shape).  Flags: bit 0
; mirrored, bit 1 every scanline stored (a box), bit 3 the copy blitter.
; The steps: fetch the geometry; clip horizontally (sp_c0..sp_c1, first image column
; sp_c) and vertically (lines lstart..lend, char rows sp_r0..sp_r1); write the
; record; (Model B) note the mirror's columns; pick the blitter; work out the screen,
; and image pointers; and jump to the row loop (NIB_LOOPS, sprloops.s) in the data's bank
; through call_bank.  sp_clip counts the window edges it was cut against.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_DS, ::PADM_DS
draw_sprite:
        stzx sp_clip               ; set at every window edge the sprite is cut against
                                    ;  (A is live, X dead on entry)

        ; ==== the address from the level's DIRL/HI, the geometry from the game's
        ; SPRG_* tables by shape
    .if BOXN
        ; a "nothing can disturb it" alias draws the same picture as the id BOXN below
        cmp #BOXID0+BOXN
        bcc :+
        sbc #BOXN                  ; (C = 1: the bcc not taken)
:
    .endif
        tax                        ; X = id
        ; ---- the image's address and bank
        bankimm ldy, BANK_SPR, BANK_LVL
        lda DIRH,x
        bne :+
        rts                        ; not in this level (@out0 is out of reach)
:       bmi :+                     ; bit 7 set: bank 4
        ora #$80                   ; bank 5: the address's bit 7 put back
        bankimm ldy, BANK_TIL1, BANK_LVL
:       sty sp_dbank
        sta sp_ptr+1
        lda DIRL,x
        sta sp_ptr
        ; ---- the shape's flags, width and lines.  With SPRGFL (assets.inc says so)
        ; the flags are the game's, by shape: a game that mirrors by id rather than
        ; by the list.  Without it the list's mirror is the only flag: every
        ; scanline stored is clear (every image's).
        ldy sprg_ix,x
        sty sp_g
    .ifdef SPRGFL
        lda sprg_fl,y
      .if DRAWFLAGS
        eor sp_dfl
      .endif
    .elseif DRAWFLAGS
        lda sp_dfl
    .else
        lda #0
    .endif
        sta sp_flags
        lsr a
        lsr a                      ; C = flags bit 1 (every scanline stored), kept past the lda/sta
        lda sprg_w,y
        sta sp_w
        lda sprg_ln,y
        sta sp_lines
        ; every scanline stored (a box's screen bytes): the lines are scanlines;
        ; else two scanlines a stored row
        bcs :+
        asl a
:       sta sp_ext
        ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        ; X = the high byte of spx - refx: + 1 for a negative refx, - 1 on the low's
        ; borrow (Y = sp_g kept for @vert)
        ldx spx+1
        lda sprg_rx,y
        bpl @sxp
        inx                        ; refx < 0: its sign extension $FF taken off
@sxp:   eor #$FF
        sec
        adc spx                    ; low of spx - refx, C = no borrow, as an sbc
        bcs @sxb
        dex
        ; ---- (both) finish sx = spx - refx - wx, and c0 = sx >> 1 in w16
@sxb:   sec
        sbc wx
        sta w16
        txa
        sbc wx+1
        cmp #$80
        ror a                      ; sign into bit 7, old bit 0 out to C; N,Z of the high byte
        beq @cpos                  ; (C kept for the low byte's ror at @cpos)
        ror w16                    ; arithmetic shift right 1 -> c0 (16 bit)
        cmp #$FF
        bne @out0                  ; c0 < -128 or >= 256: off the window

        ; ---- c0 negative (-128..-1): cut at the left.  sp_c0 = 0;
        ; visible if c0 + W > 0, and then sp_c1 = c0 + W - 1, sp_c = -c0
        lda w16
        sbc #2                     ; C = 1 from the cmp #$FF: w16 >= $80, so C stays 1
        adc sp_w                   ; w16 - 2 + W + 1 = c0 + W - 1
        bmi @out0
        inc sp_clip
        sta sp_c1
        lda #0                     ; stz sp_c0, with the zero kept for the negate
        sta sp_c0
        sbc w16                    ; C = 1 (bmi fall-through): A = -c0, 1..128
        sta sp_c                   ; starting image column: the first visible, -c0
        bne @vert                  ; always: -c0 is never 0
@out0:  rts                        ; between the arms: in reach of every branch to it

        ; ---- c0 >= 0: off the window at 80 on; else sp_c0 = c0, sp_c = 0,
        ; sp_c1 = c0 + W - 1 cut at 79 (the right edge)
@cpos:
  .if BHW
        sta sp_c                   ; A = 0 (the beq): sp_c = 0, early (dead if @out0)
  .endif
        lda w16
        ror a                      ; c0 = the low byte >> 1, C from the high byte's ror
        cmp #ROWCHARS
        bcs @out0                  ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        sbc #0                     ; C = 0 still (c0 + W < 256): A - 1, as deca
        cmp #ROWCHARS
        bcc :+
        inc sp_clip                ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
  .if .not BHW
        stz sp_c                   ; A is dead at @vert
  .endif
        ; on into @vert

        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine, the sprite's
        ; first scanline below the window's top (16 bit signed)
@vert:
        lda sprg_ry,y
        and #$80                   ; tmp3 = refy's sign
        beq @rpos
        lda #$FF
@rpos:  sta tmp3
        lda spy
        sec
        sbc sprg_ry,y
        tax
        lda spy+1
        sbc tmp3
        tay
        txa
        sec
        sbc wy
        tax
        tya
        sbc wy+1
        sta sp_lb0+1
        txa
        asl                        ; C = old bit 7, exactly what 'asl w16' left
        rol sp_lb0+1
        clc
        adc wfine
        sta sp_lb0
        bcc @nc
        inc sp_lb0+1               ; lb0 (16 bit signed)
        clc                        ; only this arm arrives with C set
@nc:
        ; ---- w16 = lb1, the last scanline: lb0 + ext - 1 (C = 0 here)
  .if BHW
        lda sp_ext                 ; C = 0: ext - 2, and C = 1 (ext >= 2) adds the 1 back
        sbc #1
  .else
        lda sp_ext
        dec a
  .endif
        adc sp_lb0
        tay                        ; Y = lb1 low (Y dead: ldy rq / #REC_CX below)
        lda sp_lb0+1
        adc #0
        tax                        ; X = lb1 high (X dead until the tax below)

        ; ---- clip: lstart = max(lb0, 0) in tmp ; lend = min(lb1, BUFROWS*8-1) in X
        lda sp_lb0+1
        bpl @pos
        txa                        ; lb0 < 0: cut at the top, if lb1 >= 0
        bmi @out0                  ; lb1 < 0
        inc sp_clip                ; cut off at the top
        bne @st                    ; always: sp_clip is 1..2 now; A = lb1 high = 0
@pos:   bne @out0                  ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0                  ; below the window
@st:    sta tmp                    ; lstart
        txa
        bne @clampend
        tya
        cmp #BUFROWS*8
        bcc :+
@clampend:
        inc sp_clip                ; and at the bottom
        lda #BUFROWS*8-1
        ; lend in X (tmp2 is not read again before the row loop sets it)
:       tax
        cmp tmp
        bcc @out0                  ; lend < lstart: nothing left

        ; ---- the char rows sp_r0..sp_r1, and the lines within them sp_ra0, sp_ra1
        and #7
        sta sp_ra1
        txa
        lsr
        lsr
        lsr
        sta sp_r1
        lda tmp
        and #7
        sta sp_ra0
        lda tmp
        lsr
        lsr
        lsr
        sta sp_r0

        ; ---- write the record's rectangle: map char column wcx + c0, char row
        ; wcy + r0, width c1 + 1 - c0, height r1 + 1 - r0, bit 7 set when clipped (so
        ; it may be visible next time and it has to be redrawn).  w16 = the column,
        ; kept for @rows.
  .if TIGHTBSS
        ; TIGHTBSS: at rq, draw_sprites's; the column's high bits go in REC_H
        ldy rq
        lda wcx
        clc
        adc sp_c0
        sta w16                    ; @rows needs this same sum: keep it, don't rebuild it
        sta REC_CX,y
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy                    ; C = 0: wcx+1 <= $7F, so the adc #0 above cannot carry
        adc sp_r0
        sta REC_CY,y
    .if BHW
        ldx sp_c1                  ; width = c1 + 1 - c0 (X dead: ldx sp_clip below)
        inx
        txa
        sec
        sbc sp_c0
    .else
        lda sp_c1
        sec
        sbc sp_c0
        inc a
    .endif
        sta REC_W,y
        lda sp_r1
        sbc sp_r0                  ; C still set by the width sbc above (sp_c1 >= sp_c0)
        adc #0                     ; and set by this one (sp_r1 >= sp_r0): + 1
        sta tmp3                   ; (free here)
        ; the column's high bits (< 4: a map is 1024 chars wide at most) to bits 5-6
        lda w16+1
        asl
        asl
        asl
        asl
        asl
        ora tmp3
        ldx sp_clip
        beq :+
        ora #$80                   ; clipped
:       sta REC_H,y
  .else
        ; the 10-byte record at rp
        ldy #REC_CX
        lda wcx
        clc
        adc sp_c0
        sta w16                    ; @rows needs this same sum: keep it, don't rebuild it
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta w16+1
        sta (rp),y
        iny                        ; REC_CY
        lda wcy                    ; C = 0: wcx+1 <= $7F, so the adc #0 above cannot carry
        adc sp_r0
        sta (rp),y
        iny
        lda sp_c1                  ; columns-1 = c1 - c0: the row loop's sp_ncol, set here
        sec
        sbc sp_c0
        sta sp_ncol
        incax                      ; width = c1 + 1 - c0 (X dead: ldx sp_clip below)
        sta (rp),y
        iny                        ; REC_H
        lda sp_r1
        sbc sp_r0                  ; C still set by the width sbc above (sp_c1 >= sp_c0)
        adc #0                     ; and set by this one (sp_r1 >= sp_r0): + 1
        ldx sp_clip
        beq :+
        ora #$80                   ; clipped
:       sta (rp),y
  .endif

  .if BHW
        ; ---- Model B: the mirror's row (mrow), relative to the window: if the
        ; sprite covers it, note the columns (see draw_rect)
        lda mrow
        sec
        sbc wcy
        cmp sp_r0
        bcc @nomir                 ; above the sprite
        cmp sp_r1
        beq @mir
        bcs @nomir                 ; below it
@mir:   lda sp_c0
        ldx sp_c1
        jsr mir_dirty
@nomir:
  .endif

        ; ---- column base pointer & step.  Mirrored: image column = W-1-c (the
        ; column loop then steps backwards)
        lda sp_flags
        bitimm 1
        beq @nomirror
        clc
        lda sp_w
        sbc sp_c                   ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags               ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the blitter once per sprite: sp_disp = its first entry in the
        ; row loop's sprrow_tab (sprloops.s) -- 36 the copy blitter (flags bit 3), 18
        ; the mirrored 4-bit (bit 0), 0 the 4-bit.  Each row patches its column jump.
        ldx #36
        bitimm 8                   ; bit 3: the copy blitter
        bne :++
        ldx #0
        lsr                        ; A is still sp_flags (bit #imm keeps A): bit 0
        bcc :+
        ldx #18
:
:       stx sp_disp

        ; ---- screen base sp_rb for (wcx + c0, wcy + r0): one ring_addr7, then +80
        ; chars per row (w16 = wcx + sp_c0 was already built when the record rect
        ; was written)
@rows:
        lda sp_r0
        sta sp_row
        clc
        adc wcy
        jsr ring_addr7             ; this bank's own copy (no crossing)
        sta sp_rb+1                ; A = sp+1: ring_addr7's last store
        lda sp
        sta sp_rb

        ; ---- source row offset w16 = r0*8 - lb0 (>> 1 for half res), and the step
        ; per row sp_rinc = 8 (4)
        ; tmp is still lstart, and sp_r0 = lstart >> 3, so r0*8 is lstart & $F8:
        ; no reload and no shifts
        lda tmp
        and #$F8
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        ldx #8
        lda sp_flags
        and #2
        bne :+                     ; every scanline stored: 8
        lda w16+1
        lsr                        ; w16+1 is 0 or $FF: its bit 0 is the sign, and
        ror w16                    ;  >> 1 leaves it as it is
        ldx #4
:       stx sp_rinc

        ; ---- source row pointer sp_rp = sp_ptr + w16 + sp_c * lines (the column
        ; base needs no copy of its own)
        lda sp_ptr
        clc
        adc w16
        tay
        lda sp_ptr+1
        adc w16+1
        sta sp_rp+1
        tya
        ldx sp_c
        beq @mdone
        clc
@mul:   adc sp_lines
        bcc :+
        inc sp_rp+1
        clc
:       dex
        bne @mul
@mdone: sta sp_rp


        ; ---- the columns (sp_ncol, set with the record's width), and away to the
        ; row loop
  .if TIGHTBSS
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                ; columns-1
  .endif
        ; The row loop and the inner blocks are assembled into each sprite data bank
        ; (NIB_LOOPS, sprloops.s): call the copy in the bank the directory named,
        ; through low RAM's direct switch (both banks enter at BANKENTRY) and back to
        ; this bank.
        lda sp_dbank
        jmp call_bank

; ============================================================================
; mark_dirty: queue a changed map tile for redrawing, in both buffers' lists
;   In:   A = tx, X = ty (the tile's map column and row)
;   Out:  A, X, Y, tmp, tmp2 clobbered
; Each buffer keeps its own list (DIRTYCNT, and DIRTYX/DIRTYY with TIGHTBSS, else
; DIRTYLIST's x,y pairs: buffer 0's DIRTYMAX, then buffer 1's).  A full list marks
; that buffer to be redrawn whole instead (BUF_CXH = $80: an unreachable window x;
; match_sprites drops its records, scroll_validate redraws it).  The game's call.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
mark_dirty:
        sta tmp
        stx tmp2
        ldx #1                     ; buffer 1, then 0
@b:     lda DIRTYCNT,x
        cmp #DIRTYMAX
        bcs @over
  .if TIGHTBSS
        cpx #1                     ; (C = 0: cnt < DIRTYMAX)
        bcc @b0                    ; buffer 0: its list is at 0
        adc #DIRTYMAX-1            ; buffer 1: C = 1, so this adds DIRTYMAX
@b0:    tay
        lda tmp
        sta DIRTYX,y
        lda tmp2
        sta DIRTYY,y
  .else
        asl                        ; cnt*2, C = 0 (cnt < DIRTYMAX)
        cpx #1
        bcc @b0                    ; buffer 0: its list is at 0
        adc #2*DIRTYMAX-1          ; buffer 1: C = 1, so this adds 2*DIRTYMAX
@b0:    tay
        lda tmp
        sta DIRTYLIST,y
        lda tmp2
        sta DIRTYLIST+1,y
  .endif
        inc DIRTYCNT,x
@next:  dex
        bpl @b
        rts
        ; ---- the list is full: that buffer is redrawn whole instead
@over:  lda #$80
        sta BUF_CXH,x              ; an unreachable window x
        bne @next                  ; (always)

; ============================================================================
; draw_dirty: redraw the back buffer's queued dirty tiles, and empty its list
;   In:   cur_buf; DIRTYCNT[cur_buf] and the buffer's list (mark_dirty)
;   Out:  DIRTYCNT[cur_buf] = 0;  A, X, Y clobbered
; A tile (tx, ty) is the rect of 4 chars by 2 char rows at (tx*4, ty*2), redrawn by
; bank 6's draw_rect_clip through call_bank.
; ============================================================================
        .segment "ENGCODE"          ; bank 7 (draw_rect_clip through call_bank)
draw_dirty:
        ldx cur_buf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
        ; ---- lidx = the buffer's list
  .if TIGHTBSS
        lda #0                     ; the buffer's list: 0, or DIRTYMAX for buffer 1
        cpx #1
        bcc @d0
        lda #DIRTYMAX
  .else
        lda #0                     ; the buffer's list: 0, or 2*DIRTYMAX for buffer 1
        cpx #1
        bcc @d0
        lda #2*DIRTYMAX
  .endif
@d0:    sta lidx
        ; ---- rc_x = tx*4 (16 bit)
@l:     stz rc_x+1                 ; A is dead here: loaded just below
        ldy lidx
  .if TIGHTBSS
        lda DIRTYX,y
  .else
        lda DIRTYLIST,y
  .endif
        asl
        rol rc_x+1
        asl
        rol rc_x+1
        sta rc_x
        ; ---- rc_y = ty*2
  .if TIGHTBSS
        lda DIRTYY,y
        iny                        ; Y is dead from here: advance the index in it
  .else
        lda DIRTYLIST+1,y
        iny                        ; Y is dead from here: advance the index in it
        iny
  .endif
        sty lidx
        asl
        sta rc_y
        ; ---- 4 x 2 chars, and draw
        lda #4
        sta rc_w
        lsr                        ; 4 >> 1 = 2
        sta rc_h
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is draw_rect_clip
        jsr call_bank
        dec lcnt
        bne @l
        ldx cur_buf
        stz DIRTYCNT,x             ; A is dead: render_core's next call reloads it
@done:  rts

        ; the Model B's bank 7 code ends at the kernel: this pad places what is above
        ; it (pads.inc)
        PAD ::PADB_BB, 0


; ============================================================================
; render_frame: render everything queued for the back buffer and request the flip
;   In:   cur_buf = the back buffer; the window (wx, wy); the sprite list (nspr);
;         bar_dirty
;   Out:  the flip requested (flip_req = 1, next_sect = the buffer's chain);
;         cur_buf = the other buffer; nspr = 0; A, X, Y clobbered
; The game's call, once a rendered frame.  It does not wait for the flip it asks for:
; the next logic step runs while the flip is pending, and the next render_frame waits
; for it before touching the buffer.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the game loop
render_frame:
        ; the previous frame's flip must land before this buffer is touched
wait_flip:                         ; (inline, its one caller) spin until any pending
        lda flip_req               ; flip has been taken by the vsync ISR: A = 0 out
        bne wait_flip

        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: T starts QROWS-QVSYNC
        ; rows after the vsync wait_flip just returned from (32 lines on the Master,
        ; 64 on the Model B).  Only digits: the template comes with the game's image
        ; (the BAR file) and nothing erases it -- the menus keep to the ring
        ; (menu_sections).
        lda bar_dirty
        beq :+
        jsr hook_hud               ; (the game's: README.md)
        stz01 bar_dirty            ; only ever set to 1: 1 -> 0
:
        ; ---- derive the char window: wcx = wx >> 1, wfine = (wy & 3) * 2,
        ; wcy = wy >> 2
        lda wx+1
        lsr
        sta wcx+1
        lda wx
        ror
        sta wcx
        lda wy
        and #3
        asl
        sta wfine
        ; wcy = wy >> 2, a full 16-bit shift: the tall maps go past wy = 512, where
        ; shifting the high byte once only loses 128 rows
        lda wy+1
        lsr
        sta wcy
        lda wy
        ror
        lsr wcy
  .if TALLMAP
        ldx wcy                    ; (the high bits: draw_rect's map row)
        stx wcyh
  .endif
        ror
        sta wcy

        ; ---- draw (the frame's steps, in order, into the back buffer: render_core,
        ; inlined at its one caller), and build this buffer's section chain.  Bank 7
        ; drives the frame and keeps the records; bank 6 gets two fixed calls a frame
        ; (low RAM's selbb and validate) and the rects through call_bank.
        jsr selbb                  ; select_backbuf (bank 6: it patches draw_rect)
        jsr calc_ring              ; ring_s, barq (Model B: wcxm, mrow)
        jsr match_sprites
        jsr erase_old
        jsr validate               ; scroll_validate (bank 6: it draws the new strips)
        jsr draw_dirty             ; (bank 7 from here: the rects through call_bank)
        jsr draw_sprites
        jsr copy_partial
    .if BHW
        jsr mirror_copy            ; the straddling row's copy (mirror.s)
    .endif
        stz nspr                   ; A dead: build_sections starts ldx/lda
        jsr build_sections

        ; ---- hand over to the ISR: next_sect = the buffer's chain, 0 or 48
        lda cur_buf
  .if .not BHW
        sta next_buf
  .endif
        beq :+
        lda #48
:       sta next_sect
        lda #1
        sta flip_req
render_done:                       ; (label for the phase timer harness)
        ; no wait here: the next logic step runs while the flip is pending and
        ; the next render_frame waits for it before touching the buffer
        eor cur_buf                ; A = 1: cur_buf ^ 1
        sta cur_buf
        rts
