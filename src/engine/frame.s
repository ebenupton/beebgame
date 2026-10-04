; ============================================================================
; engine/frame.s -- the renderer, in bank 7: a frame's sprites, dirty tiles and flip
;
; render_frame is the game's call once a frame.  It waits for the previous flip,
; lets the game redraw the status bar's changing parts (hook_hud) before the CRTC
; reaches them, derives the char window from (wx, wy), and draws the back buffer
; (cur_buf) in this order: select it (bank 6's select_backbuf), place it in its ring
; (calc_ring), mark the sprites it already shows right (match_sprites), redraw the
; tiles under the rest of its old sprites (erase_old), draw the strips the scroll has
; uncovered (bank 6's scroll_validate), redraw the map tiles the logic changed
; (draw_dirty), draw this frame's sprites (draw_sprites, each through draw_sprite
; and a sprite bank's row loop), compose the fine-scroll row above the window
; (copy_partial) and, on the Model B, the mirror row (mirror_copy); then it builds
; the buffer's section chain and asks the vsync interrupt to flip to it.  Each buffer
; keeps a record of every sprite it drew (SPRREC, defs.s: id, x, y and the screen
; rectangle), so the erase two frames later is exact.  The records are RECSZ-byte
; records walked through rp (the shipped layout); with TIGHTBSS they are arrays
; indexed by rq, from recb.
;
; Entry points, all in bank 7 and called with it paged:
;   render_frame   the game's: render the back buffer and request the flip
;   add_sprite     the game's: a sprite onto this frame's list
;   mark_dirty     the game's: a changed map tile onto both buffers' dirty lists
;   wait_flip      render_frame's spin, a label the test harness watches
;   render_done    the flip request made, a label the test harness watches
; The rest (draw_sprites, erase_old, match_sprites, copy_partial, draw_sprite,
; draw_dirty) are render_frame's.  The row loop is sprloops.s's, in banks 4 and 5;
; the rects are bank 6's draw_rect_clip: both are reached through low RAM's
; call_bank, which pages bank 7 back.
;
; Segment: ENGCODE (bank 7's game image; on the Model B it ends at the kernel), one
; `.segment` block a routine.  Placement: profile-bound, see pads.inc -- the blocks'
; order and the PAD lines before them are the layout Cleo's test/blockopt.py and
; test/padopt.py found over the frame profile, re-found whenever the kernel's start
; moves.  Do not reorder the blocks: the order is not reading order.
; Both machines.  The differences are the ring (the Model B's software ring with its
; mirror row, the Master's hardware-wrapped one), the CPU spellings (cpu.inc's
; macros, and two explicit `.if BHW`) and the Master's display buffer flag (next_buf).
; Cost: 14.8% of a frame on the Model B, 14.0% on the Master (measured 4 Oct 2026,
; Cleo's test/linecyc.mjs, levels 0, 4, 8, 10, 60 frames); the routines' costs
; below are from the same run and leave out what they call in other files.
; ============================================================================

; ----------------------------------------------------------------------------
; recfirst: rp = recp, the back buffer's first record (select_backbuf's)
;   Uses:  A
; recnext: rp on to the next record, rp += RECSZ
;   Uses:  A;  C clobbered;  one anonymous label
; erase_old and match_sprites walk the records with these; draw_sprites has its own
; step (its carry is known at every arrival).
; ----------------------------------------------------------------------------
.macro recfirst
        lda recp
        sta rp
        lda recp+1
        sta rp+1
.endmacro
.macro recnext
        lda rp
        clc
        adc #RECSZ
        sta rp
        bcc :+
        inc rp+1
:
.endmacro

; ----------------------------------------------------------------------------
; draw_sprites: draw this frame's sprite list into the back buffer, writing its records
;   In:    SPR_ID/XL/XH/YL/YH[i], i < nspr; KEEP[i] (match_sprites); cur_buf; recp =
;          the buffer's first record (select_backbuf); dpass = 0 (see below)
;   Out:   record i = sprite i's id, x, y and rectangle (draw_sprite's), except a
;          still box skipped, whose record stands; RECCNT[cur_buf] = nspr; dpass = 0
;   Uses:  A X Y, rp, spi, spx, spy, and draw_sprite's
;   Pre:   bank 7 paged (draw_sprite pages a sprite bank and comes back)
;   Cost:  1330 cycles a frame on the Model B, 1506 on the Master, without
;          draw_sprite's (measured)
; Two passes.  A box star is an opaque rectangle with its backdrop baked in, so it
; must go down before anything that overlaps it: drawn in list order it would paint
; its backdrop over whatever was already there.  Pass 1 (dpass = 1) draws the boxes
; alone (ids >= BOXID0), pass 0 everything else.  dpass is 0 between calls: boot
; zeroes zero page (init.s) and @endpass leaves it 0.
; A still box (an alias id >= BOXID0+BOXN: the logic says nothing can disturb it) is
; skipped when it is the same frame in the same place as its record (KEEP_SAME) and
; that record was not cut at a window edge: nothing has been painted under it and
; all of it is on screen, so its pixels are still right.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
        PAD ::PADB_SP, ::PADM_SP
draw_sprites:
        inc dpass                  ; dpass = 1: the boxes' pass first
  .if TIGHTBSS
        ; ---- TIGHTBSS: the records are arrays, indexed by rq
@pass:  stz spi
        lda recb                   ; the buffer's first record, stepped with spi
        sta rq
@l:     ldx spi                    ; X = the sprite's number: every field is ,x
        cpx nspr
        bcs @endpass
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
        ldy SPR_ID,x               ; Y = the id, for both compares
        cpy #BOXID0                ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                 ; not a still alias: draw it
        lda KEEP,x
        cmp #KEEP_SAME
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
        sta REC_XH,y               ; the record keeps the flags: a flip is a change
        asl                        ; bit 7, the mirror, into C
        lda #0
        rol
        sta sp_dfl
        lda SPR_XH,x
        and #$7F                   ; the flag bit off
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
        ; Clipped and empty until draw_sprite says otherwise: a sprite wholly off the
        ; window writes no rectangle, and must not pass the next frame's keep test as
        ; drawn and intact.
        lda #0
        sta REC_W,y                ; nothing drawn
        lda #REC_CLIP
        sta REC_H,y                ; clipped
        lda SPR_ID,x
        sta REC_ID,y
        jsr draw_sprite            ; (it writes the rectangle, REC_CX.. at rq)
@next:  inc rq
        inc spi
        bne @l                     ; always: spi <= nspr < 256
@endpass:
        lsr dpass                  ; 1 -> 0 with C = 1: pass 0 next; 0 -> 0 with
        bcs @pass                  ;  C = 0: done, and dpass is 0 for the next call
        ldx cur_buf
        lda nspr
        sta RECCNT,x
        rts
  .else
        ; ---- the RECSZ-byte records, walked through rp
@pass:  recfirst
        ldx #0                     ; X = spi = 0, tested at @chk
        beq @chk                   ; always (Z from the ldx)
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
@l:     ldy SPR_ID,x               ; Y = the id, for both compares (X = spi)
        cpy #BOXID0                ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next                  ; (C = 1 whenever A is 0 here: the sum was 256)
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                 ; not a still alias: draw it
        lda KEEP,x
        cmp #KEEP_SAME
        bne @write                 ; not the same frame in the same place
        ldy #REC_H
        lda (rp),y
        bpl @next                  ; not clipped: all of it on screen and intact
                                   ;  (C = 1 from the cmp)
        ; ---- write the record's id and position, and set up spx/spy
@write: ldy #1                     ; offset 1, x low (0, the id, is written last)
        lda SPR_XL,x
        sta spx
        sta (rp),y
        iny
        lda SPR_XH,x
    .if DRAWFLAGS
        sta (rp),y                 ; the record keeps the flags: a flip is a change
        asl                        ; bit 7, the mirror, into C
        lda #0
        rol
        sta sp_dfl
        lda SPR_XH,x
        and #$7F                   ; the flag bit off
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
        ; Clipped and empty until draw_sprite says otherwise: a sprite wholly off the
        ; window writes no rectangle, and must not pass the next frame's keep test as
        ; drawn and intact.
        ldy #REC_H
        lda #REC_CLIP
        sta (rp),y                 ; clipped
        dey                        ; REC_W
        asl                        ; A = 0: REC_CLIP is bit 7 alone
        .assert REC_CLIP = $80, error, "draw_sprites: REC_CLIP shifted out is 0"
        sta (rp),y                 ; nothing drawn
    .if BHW                        ; CPU spelling: the id's offset 0 needs an index
        tay                        ; Y = 0, from the A the asl left
        lda SPR_ID,x
        sta (rp),y
    .else
        lda SPR_ID,x
        sta (rp)                   ; offset 0: no index
    .endif
        jsr draw_sprite
        ldx spi                    ; X = the sprite's number again (the skips kept it)
        sec                        ; C = 1, as at the skips' arrivals
        ; ---- next record: rp += RECSZ (C = 1 at every arrival)
@next:  lda rp
        adc #RECSZ-1
        sta rp
        bcs @rpc                   ; the carry, out of line (after the rts)
@rpb:   inx
@chk:   stx spi
        cpx nspr
        bcc @l
@endpass:
        lsr dpass                  ; 1 -> 0 with C = 1: pass 0 next; 0 -> 0 with
        bcs @pass                  ;  C = 0: done, and dpass is 0 for the next call
        ldx cur_buf
        lda nspr
        sta RECCNT,x
        rts
@rpc:   inc rp+1
        bcs @rpb                   ; always: C = 1 brought it here
  .endif

; ----------------------------------------------------------------------------
; erase_old: redraw the tiles under the buffer's old sprites that are not kept
;   In:    RECCNT[cur_buf] records at recp: what this buffer drew two frames ago;
;          KEEP[i] for i < nspr (match_sprites)
;   Out:   every record not kept, of width > 0, has its rectangle redrawn as tiles
;          (bank 6's draw_rect_clip, through call_bank); the records stand
;   Uses:  A X Y, rp, lcnt, lidx, rc_x, rc_y, rc_w, rc_h, and draw_rect_clip's
;   Pre:   bank 7 paged;  before draw_sprites, which overwrites the records
;   Post:  bank 7 paged again
;   Cost:  468 cycles a frame on the Model B, 526 on the Master, without the rects
;          (measured)
; A record past the new list's end (i >= nspr) is never kept; one of width 0 drew
; nothing.  It sits after draw_sprites in the file only for where the two loops fall
; (pads.inc).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
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
        and #REC_HMASK             ; bits 0-4: the height
        sta rc_h
        lda REC_H,y                ; bits 5-6: the column's high bits
.repeat REC_CXSHIFT
        lsr
.endrepeat
        and #3                     ; (the two bits)
        sta rc_x+1
        lda REC_CX,y
        sta rc_x
        lda REC_CY,y
        sta rc_y
  .else
        ; ---- the RECSZ-byte records, walked through rp
        ldx #0                     ; X = the record's index, to lcnt
        recfirst
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
        and #<~REC_CLIP            ; the height, without the clipped bit
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
        stx lidx                   ; X is lost across the call
  .endif
        ; ---- redraw the rect's tiles (bank 6's BANKENTRY is draw_rect_clip), then
        ; the next record
        bankimm lda, BANK_TILES, BANK_LVL
        jsr call_bank
  .if TIGHTBSS
@next:  inc rq
        inc lidx
        dec lcnt
        bne @l
  .else
        ldx lidx
@next:  recnext
        inx
        cpx lcnt                   ; X = RECCNT: done
        bne @l
  .endif
@done:  rts

; ----------------------------------------------------------------------------
; match_sprites: which of this frame's sprites does the back buffer already show?
;   In:    SPR_ID/XL/XH/YL/YH[i], i < nspr; cur_buf; RECCNT[cur_buf] records at recp;
;          BUF_CXH[cur_buf]; wcx, wcy; clip_mask, krlo, krhi2, kclo, kchi2
;          (select_backbuf)
;   Out:   KEEP[i] for i < nspr: KEEP_SAME = sprite i is record i (same id, same
;          place: its pixels are already right), KEEP_BOX = a box star where a box
;          star of another frame was, 0 = neither;  RECCNT[cur_buf] = 0 when the
;          buffer is invalid
;   Uses:  A X Y, rp, cnt, tmp3
;   Pre:   bank 7 paged
;   Cost:  808 cycles a frame on the Model B, 900 on the Master (measured)
; Record i is compared only while i < min(RECCNT, nspr) (cnt); past that nothing is
; kept.  Two box frames at one place are taken to be two frames of one object (the
; game's star frames share a shape) and every box pixel is opaque, so the new frame
; covers the old without an erase: KEEP_BOX.
; Once the window has moved since this buffer last drew (clip_mask = REC_CLIP,
; select_backbuf), a record is kept only if it was not cut at the window's edge --
; the strip that brought more of it into view was drawn as tiles since -- and its
; rectangle lies in the rows and columns the old window and the new both hold:
; krlo <= row and row + height + 1 < krhi2, and the columns alike with kclo, kchi2
; (all relative to this window).  The rest of the buffer is this frame's strips, or
; ring slots reused while they were out of view.  (TIGHTBSS has the id and place
; tests, and the clip test, alone.)
; An invalid buffer (BUF_CXH = BUF_INVALID: a level start, or a dirty list that
; overflowed) is about to be redrawn whole: nothing in it is kept and nothing needs
; erasing, so its records go (RECCNT = 0).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
        PAD ::PADB_MS, ::PADM_MS
match_sprites:
        ; ---- an invalid buffer drops its records
        ldx cur_buf
        lda BUF_CXH,x
        bpl @valid
  .if BHW                          ; CPU spelling: the 6502 has no stz, but A =
        asl                        ;  BUF_INVALID = $80 shifts to the 0 it wants
        .assert BUF_INVALID = $80, error, "match_sprites: BUF_INVALID shifted out is 0"
        sta RECCNT,x
  .else
        stz RECCNT,x
  .endif
        ; ---- cnt = the records to compare, min(RECCNT, nspr)
@valid: lda RECCNT,x
        cmp nspr
        bcc :+
        lda nspr
:       sta cnt
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
        lda #KEEP_BOX              ; a different frame of the same thing
        bne @pos                   ; always
@same:  lda #KEEP_SAME             ; identical: its pixels are already right
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
        and clip_mask              ;  window has moved since (select_backbuf): its
        bne @next                  ;  new part is the scroll's tiles
        lda tmp3
        sta KEEP,x                 ; the same pixels in the same place
@next:  iny
        inx
        bne @l                     ; always: i + 1 <= MAXSPR < 256
@done:  rts
  .else
        ; ---- the RECSZ-byte records, walked through rp; X = i throughout
        ldx #0
        recfirst
@l:     cpx nspr
        bcs @done
        cpx cnt
        bcs @zero                  ; no record i: not kept
        lda SPR_ID,x
        cmpz rp                    ; the record's id (offset 0: no index)
        beq @same
        cmp #BOXID0                ; different ids: are both box stars?
        bcc @zero
        ldaz0 rp                   ; (Y = 0 from the cmpz)
        cmp #BOXID0
        bcc @zero
        lda #KEEP_BOX              ; a different frame of the same thing
        bne @pos                   ; always
@same:  lda #KEEP_SAME             ; identical: its pixels are already right
        ; ---- kept if the same place too: the record's x and y, offsets 1-4
@pos:   sta KEEP,x                 ; (undone at @zero if the place differs)
        ldy1                       ; Y = 1 (Y = 0 on both ways in: cmpz, ldaz0)
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
        lda clip_mask              ; the same pixels in the same place: kept if the
        beq @next                  ;  window has not moved since the buffer drew
        jmp @moved                 ;  (select_backbuf), else if it fits both windows
@zero:  stz KEEP,x                 ; not kept
@next:  recnext
        inx
        bne @l                     ; always: i + 1 <= MAXSPR < 256
@done:  rts
        ; ---- the window has moved: kept only if not cut at the window's edge and
        ; inside the rows and columns both windows hold (the rest of the buffer is
        ; the scroll's tiles, or slots reused since)
@moved: ldy #REC_H
        lda (rp),y
        bmi @zero2                 ; cut at an edge
        sta tmp3                   ; its height
        dey
        dey                        ; REC_CY
        .assert REC_H - 2 = REC_CY && REC_CY - 2 = REC_CX, error, "match_sprites: the fields' order"
        lda (rp),y
        sec
        sbc wcy                    ; its row in this window
        cmp krlo
        bcc @zero2                 ; above the shared rows
        adc tmp3                   ; C = 1: row + height + 1
        bcs @zero2                 ; (past 255)
        cmp krhi2
        bcs @zero2                 ; below them
        dey
        dey                        ; REC_CX
        lda (rp),y
        sec
        sbc wcx
        sta tmp3                   ; its column in this window, low byte
        iny
        lda (rp),y
        sbc wcx+1
        bne @zero2                 ; not 0..255: outside
        lda tmp3
        cmp kclo
        bcc @zero2                 ; left of the shared columns
        ldy #REC_W
        adc (rp),y                 ; C = 1: column + width + 1
        bcs @zero2                 ; (past 255)
        cmp kchi2
        bcs @zero2                 ; right of them
        jmp @next
@zero2: jmp @zero
  .endif

; ----------------------------------------------------------------------------
; add_sprite: a sprite onto this frame's draw list
;   In:    A = its id;  spx, spy = its reference point in game pixels (map
;          coordinates);  nspr
;   Out:   SPR_ID/XL/XH/YL/YH[nspr] = the sprite, nspr + 1 -- or nothing when the
;          list is full (nspr = MAXSPR): the sprite is dropped
;   Uses:  A X
;   Keeps: Y
;   Cost:  386 cycles a frame on the Model B, 448 on the Master (measured)
; The game's call, once a sprite a frame.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
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

; ----------------------------------------------------------------------------
; copy_partial: compose the ring row above the window from the fine-scrolled row
;   In:    wfine, wcx, wcy (render_frame); ring_s (calc_ring);  Model B: barq
;          (calc_ring), ringbhi (select_backbuf), wcxm (mir_dirty's)
;   Out:   lines 0..7-wfine of every char of the row above the window = lines
;          wfine..7 of ring row wcy at the same column, all ROWCHARS columns;
;          nothing when wfine = 0.  Model B: the mirror's notes when the row above
;          is the ring's last slot (mir_dirty)
;   Uses:  A X Y, sp, ptr, w16;  Model B: mir_dirty's
;   Pre:   bank 7 paged
;   Cost:  5254 cycles a frame on the Model B (6.9%), 4017 on the Master (5.4%),
;          measured: 80 chars x (8 - wfine) lines whenever the window is fine
;          scrolled
; The row above the window -- ring chars (ring_s + col - 80) mod RINGCHARS, the slot
; before the window's first (defs.s) -- is what the display shows first when the
; window is fine scrolled, so its top lines are composed here from the window's
; first row.  The copy is unrolled by line pairs and entered at this wfine's pair
; through a patched branch (@ftab); it copies the whole row every frame.  Older
; measurements, not repeated: tracking the columns written since the last copy
; would save under 0.3% of a frame; a loop in place of the unrolling cost ~1%.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
        PAD ::PADB_CP, ::PADM_CP
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
  .if .not BHW                     ; hardware (the ring): ring_addr7's Master modulus
        clc                        ;  keeps the caller's C; the Model B's clears it
  .endif
  .if BHW                          ; hardware (the ring): the Model B's mirror row
        ; ---- the composed row is the ring's last slot when the window starts at
        ; slot 0 -- then the mirror follows it, so note the columns written
        ; (mir_dirty: A = first, X = last: the whole row)
        lda barq
        bne @nomir
        ldx #ROWCHARS-1
        lda #0
        jsr mir_dirty              ; (bank 7's copy; it clobbers C: ring_addr7's
@nomir:                            ;  ringmod7 clears it again)
  .endif
        ; ---- source: sp = row wcy at column wcx, wfine lines into the char
        lda wcy
        jsr ring_addr7             ; sp = the source char (row wcy, column wcx)
        ; Offsetting sp by wfine (under 8; a char is 8-aligned) keeps its page
        ; crossings on the real char boundaries, so the +8 steps below carry out of
        ; the low byte at the same chars as they would unoffset.
        lda sp
        clc
        adc wfine
        sta sp
        ; ---- dest: ptr = the same column of the row above the window, ring char
        ; (ring_s + col - 80) mod RINGCHARS, as a real address in the ring.
        ; ring_s - 80 for column 0: the low byte of -80 is the first addend
        lda #<(-ROWCHARS)          ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc ring_s
  .if BHW                          ; hardware (the ring): the Model B's ring is not
                                   ;  whole pages, and its base is the buffer's
        ; the char's low byte in A and its high byte in ptr+1, so the base's low byte
        ; ($80) adds straight to A at the end
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
        ; clear: the ring is RINGBYTES = $3980 bytes, under $4000.
@pnf:   asl
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        adc #<RING_A               ; both bases are xx80; which xx is the buffer's
        sta ptr
        lda ptr+1
        adc ringbhi
  .else
        sta ptr
        lda ring_s+1
        adc #$FF
        bcs @pnf                   ; C = 1: >= 0, already in the ring
        adc #>RINGCHARS            ; (<RINGCHARS = 0: defs.s asserts it)
        ; char -> byte address (A:ptr), + RINGBASE (page aligned).  The rols leave
        ; C clear: the ring is RINGBYTES = $5000 bytes.
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
        ldx #ROWCHARS              ; the char counter in X: dex/beq, no compare
        bcc @back                  ; in at the patched entry (C = 0: ptr+1's adc
                                   ;  above cannot carry, the sum is under $80)
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
        ; ---- next char, both pointers with the ring fold on a page crossing: the
        ; composed row can straddle the ring's end like any row (the page steps are
        ; out of line)
        lda sp                     ; spnext without its clc: C = 0 at every arrival
        adc #CHARBYTES             ;  (the copy is entered by a taken bcc, and
        sta sp                     ;  lda/sta/ldy/dey keep C)
        bcs @sfold
@sback: dex
        beq @done
        lda ptr                    ; C = 0: the bcs not taken, or spcold's clc
        adc #CHARBYTES
        sta ptr
@back:  bcc @g4                    ; patched (@ftab); C = 1 falls into the page step
        SAMEPAGE *, @g4
        SAMEPAGE *, @g0
        pagestep ptr, @back        ; ptr's page step (needs no C in)
        bcc @back                  ; (C = 0: pagestep's)
@done:  rts
        ; ---- sp's page step, out of line
@sfold: spcold @sback

; ----------------------------------------------------------------------------
; draw_sprite: the sprite prologue -- clip one sprite, write its record, draw it
;   In:    A = its id;  spx, spy = its reference point in game pixels (map
;          coordinates);  rp = its record, with id, x, y, W = 0 and H = REC_CLIP
;          already written (draw_sprites; TIGHTBSS: rq);  X dead;  (DRAWFLAGS)
;          sp_dfl = the list's mirror flag;  wcx, wcy, wx, wy, wfine;  DIRL/DIRH
;          (the level's), sprg_* (the game's)
;   Out:   when the image is in this level and any of the sprite is in the window:
;          the record's rectangle (REC_CX, REC_CY, REC_W, REC_H, bit 7 set when
;          clipped) and the sprite drawn by the row loop in its data's bank.  Else
;          the record stands as draw_sprites left it.  sp_ncol = columns - 1
;   Uses:  A X Y, sp_ptr, sp_w, sp_lines, sp_ext, sp_flags, sp_dbank, sp_g, sp_c0,
;          sp_c1, sp_c, sp_lb0, sp_r0, sp_r1, sp_ra0, sp_ra1, sp_rb, sp_rp, sp_rinc,
;          sp_row, sp_disp, sp_clip, tmp, tmp3, w16, sp, mtmp (bitimm), and the row
;          loop's;  Model B: mir_dirty's
;   Pre:   bank 7 paged
;   Post:  bank 7 paged again (call_bank's page_logic)
;   Cost:  2809 cycles a frame on the Model B, 2945 on the Master, without the row
;          loop (measured)
; The directory is split.  The level's part is DIRL/DIRH in bank 7 (banks.s, filled
; by ldprog.s): the image's address by id, 0 when the id is not in this level, bit 7
; of the high byte clear for an image in bank 5 (set: bank 4).  The game's part is
; the geometry by shape (sprg_ix by id; sprg_w, sprg_rx, sprg_ry, sprg_ln and, with
; SPRGFL, sprg_fl by shape).  The flags are defs.s's: SPF_MIRROR, SPF_FULLRES (every
; scanline stored: a box), SPF_COPY (the copy blitter).
; The steps: the address and the geometry; clip horizontally (window columns
; sp_c0..sp_c1, first image column sp_c) and vertically (lines lstart..lend of the
; buffer, char rows sp_r0..sp_r1); write the record; (Model B) note the mirror's
; columns; choose the blitter (sp_disp); the screen and image pointers for the first
; row; and away to the row loop (NIB_LOOPS, sprloops.s) in the data's bank through
; call_bank.  sp_clip counts the window edges the sprite was cut against.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
        PAD ::PADB_DS, ::PADM_DS
draw_sprite:
        stzx sp_clip               ; (A is live, X dead)
        ; ---- the address from the level's DIRL/DIRH, the geometry from the game's
        ; sprg_* tables by shape
  .if BOXN
        ; a still alias draws the same picture as the id BOXN below it
        cmp #BOXID0+BOXN
        bcc :+
        sbc #BOXN                  ; (C = 1: the bcc not taken)
:
  .endif
        tax                        ; X = the id
        ; ---- the image's address and bank
        bankimm ldy, BANK_SPR, BANK_LVL
        lda DIRH,x
        bne :+
        rts                        ; not in this level (@out0 is out of reach here)
:       bmi :+                     ; bit 7 set: bank 4, the address as it is
        ora #$80                   ; bank 5: the address's bit 7 put back
        bankimm ldy, BANK_TIL1, BANK_LVL
:       sty sp_dbank
        sta sp_ptr+1
        lda DIRL,x
        sta sp_ptr
        ; ---- the shape's flags, width and lines.  With SPRGFL (the packer emits
        ; it) the flags are the game's, by shape; without it the list's mirror flag
        ; (DRAWFLAGS) is the only flag, or there are none.
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
        lsr
        lsr                        ; C = SPF_FULLRES (every scanline stored), kept
        .assert SPF_FULLRES = 2, error, "draw_sprite: two shifts put SPF_FULLRES in C"
        lda sprg_w,y               ;  through the loads and stores
        sta sp_w
        lda sprg_ln,y
        sta sp_lines
        ; sp_ext = the height in scanlines: the lines stored when every scanline is
        ; (a box), else twice (two scanlines a stored row)
        bcs :+
        asl
:       sta sp_ext
        ; ---- horizontal: sx = spx - refx - wx; c0 = sx >> 1, the first window
        ; column (16 bit, signed).  X = the high byte of spx - refx: + 1 for a
        ; negative refx (its $FF sign extension taken off), - 1 on the low byte's
        ; borrow.  Y = sp_g stays for @vert.
        ldx spx+1
        lda sprg_rx,y
        bpl @sxp
        inx                        ; refx < 0
@sxp:   eor #$FF
        sec
        adc spx                    ; the low byte of spx - refx; C = no borrow
        bcs @sxb
        dex
@sxb:   sec
        sbc wx
        sta w16
        txa
        sbc wx+1
        cmp #$80                   ; C = the sign
        ror                        ; the high byte >> 1 arithmetic: its bit 0 to C
        beq @cpos                  ; c0 in 0..255 (C kept for the low byte's ror)
        ror w16                    ; c0's low byte
        cmp #$FF
        bne @out0                  ; c0 < -128 or >= 256: off the window
        ; ---- c0 negative (-128..-1): cut at the left.  sp_c0 = 0; visible if
        ; c0 + W > 0, and then sp_c1 = c0 + W - 1, sp_c = -c0
        lda w16
        sbc #2                     ; C = 1 (the cmp's): w16 >= $80, so it stays 1
        adc sp_w                   ; w16 - 2 + W + 1 = c0 + W - 1 (C = 1 iff >= 0)
        bmi @out0
        inc sp_clip
        sta sp_c1
        lda #0                     ; sp_c0 = 0, and the 0 kept for the negate
        sta sp_c0
        sbc w16                    ; C = 1 (the bmi fell through): -c0, 1..128
        sta sp_c                   ; the first visible image column
        bne @vert                  ; always: -c0 is never 0
@out0:  rts                        ; between the arms: in reach of every branch to it
        ; ---- c0 >= 0: off the window at 80 on; else sp_c0 = c0, sp_c = 0,
        ; sp_c1 = c0 + W - 1 cut at 79 (the right edge)
@cpos:  sta sp_c                   ; A = 0 (the beq): the first image column is 0
        lda w16
        ror                        ; c0 = the low byte >> 1, C from the high byte's
        cmp #ROWCHARS
        bcs @out0                  ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        sbc #0                     ; C = 0 still (c0 + W < 256): c0 + W - 1
        cmp #ROWCHARS
        bcc :+
        inc sp_clip                ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
        ; falls into @vert
        ; ---- vertical: sy = spy - refy - wy; lb0 = 2*sy + wfine, the sprite's
        ; first scanline below the window's top (16 bit, signed)
@vert:
        lda sprg_ry,y
        and #$80                   ; tmp3 = refy's sign extension
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
        asl                        ; 2*sy: the low byte's bit 7 into the high byte
        rol sp_lb0+1
        clc
        adc wfine
        sta sp_lb0
        bcc @nc
        inc sp_lb0+1
        clc                        ; only this arm arrives with C set
@nc:
        ; ---- lb1 = lb0 + ext - 1, the last scanline, in X:Y (C = 0 here)
        lda sp_ext                 ; C = 0 makes the sbc ext - 2, and its C = 1 out
        sbc #1                     ;  puts the 1 back in the adc.  ext >= 2: half res
        adc sp_lb0                 ;  doubles sp_lines, and Cleo's full-res shapes
                                   ;  (the boxes) are 16 lines and more -- with
                                   ;  ext = 1 the borrow would make lb1 = lb0 + 255
        tay                        ; Y = lb1 low (Y dead: the ldy below reloads it)
        lda sp_lb0+1
        adc #0
        tax                        ; X = lb1 high (X dead until the tax below)
        ; ---- clip: lstart = max(lb0, 0) in tmp; lend = min(lb1, the window's last
        ; line) in X
        lda sp_lb0+1
        bpl @pos
        txa                        ; lb0 < 0: cut at the top, if lb1 >= 0
        bmi @out0                  ; lb1 < 0: above the window
        inc sp_clip                ; cut at the top
        bne @st                    ; always: sp_clip is 1..2 now; A = lb1 high = 0
@pos:   bne @out0                  ; lb0 >= 256: below the window
        lda sp_lb0
        cmp row_lim
        bcs @out0                  ; below the window (or past map row 255)
@st:    sta tmp                    ; lstart
        txa
        bne @clampend              ; lb1 >= 256
        tya
        cmp row_lim
        bcc :+
@clampend:
        inc sp_clip                ; cut at the bottom
        ldx row_lim                ; the last line: row_lim - 1
        dex
        txa
:       tax                        ; lend
        cmp tmp
        bcc @out0                  ; lend < lstart: nothing left
        ; ---- the char rows sp_r0..sp_r1, and the lines within them sp_ra0, sp_ra1
        and #CHARLINES-1
        sta sp_ra1
        txa
        lsr
        lsr
        lsr
        sta sp_r1
        lda tmp
        and #CHARLINES-1
        sta sp_ra0
        lda tmp
        lsr
        lsr
        lsr
        sta sp_r0
        ; ---- write the record's rectangle: map char column wcx + c0 (w16 too, kept
        ; for @rows), char row wcy + r0, width c1 + 1 - c0, height r1 + 1 - r0 with
        ; bit 7 set when clipped (it may show more next frame, so it must be
        ; redrawn)
  .if TIGHTBSS
        ; TIGHTBSS: at rq, draw_sprites's; the column's high bits go in REC_H
        ldy rq
        lda wcx
        clc
        adc sp_c0
        sta w16                    ; @rows needs this sum: kept, not rebuilt
        sta REC_CX,y
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy                    ; C = 0: wcx+1 < 4, so the adc #0 cannot carry
        adc sp_r0
        sta REC_CY,y
        lda sp_c1
        sec
        sbc sp_c0
        incax                      ; width = c1 + 1 - c0 (X dead: ldx sp_clip below)
        sta REC_W,y
        lda sp_r1
        sbc sp_r0                  ; C = 1 still (sp_c1 >= sp_c0; incax keeps C)
        adc #0                     ; and C = 1 from this one (sp_r1 >= sp_r0): + 1
        sta tmp3                   ; (free here)
        ; the column's high bits (< 4: a map is 1024 chars wide at most) to bits 5-6
        lda w16+1
.repeat REC_CXSHIFT
        asl
.endrepeat
        ora tmp3
        ldx sp_clip
        beq :+
        ora #REC_CLIP              ; clipped
:       sta REC_H,y
  .else
        ; the RECSZ-byte record at rp
        ldy #REC_CX
        lda wcx
        clc
        adc sp_c0
        sta w16                    ; @rows needs this sum: kept, not rebuilt
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta w16+1
        sta (rp),y
        iny                        ; REC_CY
        lda wcy                    ; C = 0: wcx+1 < 4, so the adc #0 cannot carry
        adc sp_r0
        sta (rp),y
        iny                        ; REC_W
        lda sp_c1                  ; columns - 1 = c1 - c0: the row loop's sp_ncol
        sec
        sbc sp_c0
        sta sp_ncol
        incax                      ; width = c1 + 1 - c0 (X dead: ldx sp_clip below)
        sta (rp),y
        iny                        ; REC_H
        lda sp_r1
        sbc sp_r0                  ; C = 1 still (sp_c1 >= sp_c0; incax keeps C)
        adc #0                     ; and C = 1 from this one (sp_r1 >= sp_r0): + 1
        ldx sp_clip
        beq :+
        ora #REC_CLIP              ; clipped
:       sta (rp),y
  .endif
  .if BHW                          ; hardware (the ring): the Model B's mirror row
        ; ---- the mirror's row (mrow), relative to the window: if the sprite covers
        ; it, note the columns written (mir_dirty: A = first, X = last)
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
        ; ---- the first image column, sp_c.  Mirrored, image column W - 1 - c is
        ; drawn at window column c (the row loop then steps the source backwards)
        lda sp_flags
        bitimm SPF_MIRROR
        beq @nomirror
        clc
        lda sp_w
        sbc sp_c                   ; C = 0 takes the extra 1: W - sp_c - 1
        sta sp_c
        lda sp_flags               ; (only this arm clobbers A)
@nomirror:
        ; ---- the blitter, once a sprite: sp_disp = its first entry in the row
        ; loop's sprrow_tab (sprloops.s) -- SPRDISP_FC the copy blitter (SPF_COPY),
        ; SPRDISP_FM the mirrored 4-bit (SPF_MIRROR), SPRDISP_FN the 4-bit.  Each
        ; row patches its column jump from there.
        ldx #SPRDISP_FC
        bitimm SPF_COPY
        bne @setdisp
        ldx #SPRDISP_FN
        lsr                        ; A is still sp_flags (bitimm keeps it): bit 0,
        .assert SPF_MIRROR = 1, error, "draw_sprite: one shift puts SPF_MIRROR in C"
        bcc @setdisp               ;  SPF_MIRROR, to C
        ldx #SPRDISP_FM
@setdisp:
        stx sp_disp
        ; ---- the screen address of the first row, sp_rb = (wcx + c0, wcy + r0):
        ; one ring_addr7 (w16 = wcx + sp_c0 is built with the record); the row loop
        ; adds a row's bytes a row
@rows:
        lda sp_r0
        sta sp_row
        clc
        adc wcy
        jsr ring_addr7             ; (this bank's own copy: no crossing)
        sta sp_rb+1                ; A = sp+1, ring_addr7's last store
        lda sp
        sta sp_rb
        ; ---- the source row offset w16 = r0*8 - lb0 (>> 1 when two scanlines a
        ; stored row), and the step a row sp_rinc = a char row's stored bytes, 8 or
        ; 4.  tmp is still lstart and sp_r0 = lstart >> 3, so r0*8 is lstart & $F8:
        ; no reload, no shifts.
        lda tmp
        and #<-CHARLINES
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        ldx #CHARLINES
        lda sp_flags
        and #SPF_FULLRES
        bne :+                     ; every scanline stored: 8 bytes a row
        lda w16+1                  ; w16 is -8 < w16 < 256, so its high byte is 0 or
        lsr                        ;  $FF and stays so after >> 1: only the bit the
        ror w16                    ;  lsr shifts into the low byte is needed
        ldx #CHARLINES/2
:       stx sp_rinc
        ; ---- the source row pointer sp_rp = sp_ptr + w16 + sp_c * sp_lines (the
        ; column base needs no copy of its own)
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
        sta sp_ncol                ; columns - 1
  .endif
        ; The row loop and the blitters are assembled into each sprite data bank
        ; (NIB_LOOPS, sprloops.s): call the copy in the bank the directory named,
        ; through low RAM's direct switch (both banks enter at BANKENTRY), which pages
        ; this bank back.
        lda sp_dbank
        jmp call_bank

; ----------------------------------------------------------------------------
; mark_dirty: queue a changed map tile for redrawing, in both buffers' lists
;   In:    A = tx, X = ty (the tile's map column and row)
;   Out:   (tx, ty) appended to each buffer's list, DIRTYCNT[b] + 1; a full list
;          (DIRTYMAX) marks its buffer to be redrawn whole instead (BUF_CXH[b] =
;          BUF_INVALID: match_sprites drops its records, scroll_validate redraws it)
;   Uses:  A X Y, tmp, tmp2
;   Cost:  cold (the game's call when a tile changes)
; Each buffer's list is DIRTYLIST's (x, y) pairs: buffer 0's DIRTYMAX pairs, then
; buffer 1's (TIGHTBSS: DIRTYX and DIRTYY, DIRTYMAX bytes each a buffer).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
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
@over:  lda #BUF_INVALID
        sta BUF_CXH,x              ; a window x it can never hold
        bne @next                  ; always

; ----------------------------------------------------------------------------
; draw_dirty: redraw the back buffer's queued dirty tiles, and empty its list
;   In:    cur_buf; DIRTYCNT[cur_buf] and the buffer's list (mark_dirty)
;   Out:   each queued tile redrawn (bank 6's draw_rect_clip, through call_bank);
;          DIRTYCNT[cur_buf] = 0
;   Uses:  A X Y, lcnt, lidx, rc_x, rc_y, rc_w, rc_h, and draw_rect_clip's
;   Pre:   bank 7 paged
;   Post:  bank 7 paged again
;   Cost:  16 cycles a frame on both machines when the list is empty (measured)
; A tile (tx, ty) is the rect of TILECHARS chars by TILEROWS char rows at
; (tx * TILECHARS, ty * TILEROWS).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
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
        ; ---- rc_x = tx * 4 (16 bit)
@l:     stz rc_x+1                 ; (A is dead: loaded just below)
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
        .assert TILECHARS = 4, error, "draw_dirty: two shifts make a tile's column"
        ; ---- rc_y = ty * 2
  .if TIGHTBSS
        lda DIRTYY,y
        iny                        ; Y is dead from here: the index stepped in it
  .else
        lda DIRTYLIST+1,y
        iny                        ; Y is dead from here: the index stepped in it
        iny
  .endif
        sty lidx
        asl
        sta rc_y
        .assert TILEROWS = 2, error, "draw_dirty: one shift makes a tile's row"
        ; ---- TILECHARS x TILEROWS chars, and draw (bank 6's BANKENTRY is
        ; draw_rect_clip)
        lda #TILECHARS
        sta rc_w
        lsr                        ; TILECHARS >> 1 = TILEROWS
        .assert TILECHARS/2 = TILEROWS, error, "draw_dirty: a tile's rows are half its chars"
        sta rc_h
        bankimm lda, BANK_TILES, BANK_LVL
        jsr call_bank
        dec lcnt
        bne @l
        ldx cur_buf
        stz DIRTYCNT,x             ; (A is dead)
@done:  rts

        ; the Model B's ENGCODE ends at the kernel: this pad places what is above it
        ; (pads.inc; the Master has no pad here)
        PAD ::PADB_BB, 0

; ----------------------------------------------------------------------------
; render_frame: render everything queued for the back buffer and request the flip
;   In:    cur_buf = the back buffer; wx, wy (the window, game pixels); the sprite
;          list (nspr, SPR_*); bar_dirty; the dirty lists
;   Out:   the back buffer drawn; wcx, wcy, wfine; the flip requested (flip_req = 1,
;          next_sect = the buffer's chain; Master: next_buf = the buffer); cur_buf =
;          the other buffer; nspr = 0; bar_dirty = 0
;   Uses:  A X Y, and everything the steps use
;   Pre:   bank 7 paged;  called once a rendered frame
;   Post:  bank 7 paged
;   Cost:  145 cycles a frame on the Model B, 139 on the Master, of its own
;          (measured; the spin at wait_flip is idle, not counted)
; The game's call.  It does not wait for the flip it asks for: the next logic step
; runs while the flip is pending, and the next render_frame waits for it before
; touching the buffer.
; wait_flip and render_done are labels the test harness watches (Cleo's test/*.mjs,
; blockopt.py and padopt.py: the spin is idle time, not work).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
render_frame:
        ; ---- the previous frame's flip must land before this buffer is touched
wait_flip:
        lda flip_req               ; spin until the vsync ISR has taken the pending
        bne wait_flip              ;  flip; A = 0 out
        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: the bar's section
        ; starts QROWS - QVSYNC char rows after the vsync wait_flip has just seen
        ; (4 rows = 32 lines on the Master, 8 = 64 on the Model B: defs.s).  Only
        ; what changes is drawn: the template comes with the game's image (the BAR
        ; file) and nothing erases it; the menus keep to the ring (menu_sections).
        lda bar_dirty
        beq :+
        jsr hook_hud               ; the game's (docs/GUIDE.md)
        stz01 bar_dirty            ; only ever set to 1: 1 -> 0
:
        ; ---- the char window: wcx = wx >> 1, wfine = (wy & 3) * 2, wcy = wy >> 2
        lda wx+1
        lsr
        sta wcx+1
        lda wx
        ror
        sta wcx
        lda wy
        and #CHARLINES/2-1         ; (a char row is 4 game pixel rows)
        asl
        sta wfine
        ; wcy = wy >> 2, a full 16-bit shift: a tall map's wy goes past 512, where
        ; shifting the high byte once alone loses 128 rows
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
        ; ---- row_lim: the lines draw_sprite may draw.  The buffer's BUFROWS rows,
        ; but none past map row 255: rows are bytes, and a sprite row of 256 would
        ; wrap to 0 -- on the Model B its ring slot (0 mod RINGROWS) is a visible
        ; row's.  Only a 256-row map's bottom reaches it (Cleo falling off it).
  .if .not TALLMAP
        eor #$FF                   ; 255 - wcy
        cmp #BUFROWS
        bcc :+                     ; 255 - wcy < BUFROWS: rows = 256 - wcy
        lda #BUFROWS-1
:       asl                        ; (rows - 1) * CHARLINES: at most 240, C = 0
        asl
        asl
        adc #CHARLINES             ; rows * CHARLINES
  .else                            ; (TALLMAP: rows go on past 255 legitimately)
        lda #BUFROWS*CHARLINES
  .endif
        sta row_lim
        ; ---- draw the back buffer, the steps in order, and build its section
        ; chain.  Bank 7 drives the frame and keeps the records; bank 6 gets two
        ; fixed calls a frame (low RAM's selbb and validate) and the rects through
        ; call_bank.
        jsr selbb                  ; select_backbuf (bank 6: it patches draw_rect)
        jsr calc_ring              ; ring_s, barq (Model B: wcxm, mrow)
        jsr match_sprites
        jsr erase_old
        jsr validate               ; scroll_validate (bank 6: it draws the new strips)
        jsr draw_dirty             ; (bank 7 from here: the rects through call_bank)
        jsr draw_sprites
        jsr copy_partial
  .if BHW                          ; hardware (the ring): the Model B's mirror row
        jsr mirror_copy            ; the straddling row's copy (mirror.s)
  .endif
        stz nspr                   ; (A is dead: build_sections starts with a load)
        jsr build_sections
        ; ---- hand over to the ISR: next_sect = the buffer's chain, 0 or SECBYTES
        lda cur_buf
  .if .not BHW                     ; hardware (the ring): the Master's shadow-RAM
        sta next_buf               ;  display flag for the flip (-> disp_d)
  .endif
        beq :+
        lda #SECBYTES
:       sta next_sect
        lda #1
        sta flip_req
render_done:
        ; no wait here: the next logic step runs while the flip is pending, and the
        ; next render_frame waits for it before touching the buffer
        eor cur_buf                ; A = 1: cur_buf ^ 1
        sta cur_buf
        rts
