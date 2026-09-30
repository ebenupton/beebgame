; ============================================================================
; engine/frame.s -- the renderer: a frame's sprites, dirty tiles and flip, in bank 7
;
; render_frame draws one frame into the back buffer (curbuf) and asks the vsync
; interrupt to flip to it.  The work is render_core's list: erase the sprites of two
; frames ago that have moved (each buffer keeps a record of every sprite it drew),
; let bank 6 draw the strips the scroll has uncovered, redraw the map tiles that
; changed, draw the new sprite list, and compose the partial row above the window.
; Bank 7 drives it all and keeps the records; bank 6 draws the tiles (the rects go to
; drawrect_clip through low RAM's callbank), banks 4 and 5 draw the sprites (the row
; loop, SPRITE_LOOPS, is assembled into each: drawsprite hands over through callbank).
;
;   draw_sprites   draw the sprite list into the back buffer, writing its records
;   erase_old      redraw the tiles under the buffer's records that are not kept
;   match_sprites  KEEP[i]: is sprite i what record i already shows?
;   addsprite      add a sprite to the draw list (the game's call)
;   copy_partial   compose the ring row above the window from the fine-scrolled row
;   drawsprite     the sprite prologue: clip, record, set up and call the row loop
;   render_core    the frame's steps, in order
;   mark_dirty     queue a changed map tile for both buffers (the game's call)
;   sext           sign-extend A into tmp3
;   draw_dirty     redraw the back buffer's queued dirty tiles
;   blank_below    black the ring slot below the playfield on the map's bottom row
;   render_frame   the game's call: render the back buffer and request the flip
;   wait_flip      spin until the pending flip has been taken
;
; Segment: ENGCODE (bank 7; on the Model B it ends at the kernel).  Each routine is
; its own `.segment "ENGCODE"` block, and THE ORDER OF THE BLOCKS IS THE LAYOUT'S:
; chosen over a profile to keep the hot loops' branches and reads off page crossings,
; with the PAD lines (pads.inc) before some blocks and after blank_below.  Keep the
; blocks where they are; the order and the pads are found by Cleo's test/blockopt.py
; and then test/padopt.py (in /Users/ebenupton/cleo/beeb/test), and re-found whenever
; the kernel's start moves.
;
; The record layout is defs.s's: with TIGHTBSS the records are arrays indexed by a
; register (rq, recb), otherwise 10-byte records walked through (rp).
; ============================================================================

; ============================================================================
; draw_sprites: draw every listed sprite into the back buffer
;   In:   the sprite list (SPR_*, NSPR); KEEP[] from match_sprites; curbuf;
;         recb / recp = the buffer's first record
;   Out:  record i written for sprite i (a skipped still box keeps its own);
;         RECCNT[curbuf] = NSPR;  A, X, Y clobbered
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
        lda #1
        sta dpass

  .if TIGHTBSS
        ; ---- TIGHTBSS: the records are arrays, indexed by rq
@pass:  stz spi
        lda recb                    ; the buffer's first record, stepped with spi
        sta rq
@l:     ldx spi                     ; X = the sprite's number: every field is ,x
        cpx NSPR
        bcs @endpass
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
        ldy SPR_ID,x                ; Y = id for both compares
        cpy #BOXID0                 ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                  ; not a still alias: draw it
        lda KEEP,x
        cmp #2
        bne @write                  ; not the same frame in the same place
        ldy rq
        lda REC_H,y
        bpl @next                   ; not clipped: all of it on screen and intact
        ; ---- write the record's id and position, and set up spx/spy
@write: ldy rq
        lda SPR_XL,x
        sta spx
        sta REC_XL,y
        lda SPR_XH,x
    .if DRAWFLAGS
        sta REC_XH,y                ; (the record keeps the flags: a flip is a change)
        asl                         ; bit 7, mirror, into C
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
        sta REC_W,y                 ; nothing drawn
        lda #$80
        sta REC_H,y                 ; clipped
        lda SPR_ID,x
        sta REC_ID,y
        jsr drawsprite              ; (it writes the rectangle: REC_CX.. at rq)
@next:  inc rq
        inc spi
        bne @l                      ; spi <= NSPR: never wraps to 0
@endpass:
        dec dpass
        bpl @pass                   ; (in range on both machines)
        ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

  .else
        ; ---- the 10-byte records, walked through (rp)
@pass:  stz spi                     ; A dead: lda recp next
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx spi                     ; X = the sprite's number: every field is ,x
        cpx NSPR
        bcs @endpass
        ; ---- this pass's kind only: A = dpass + $FF + C is 0 to skip
        ldy SPR_ID,x                ; Y = id for both compares
        cpy #BOXID0                 ; C = 1: a box
        lda dpass
        adc #$FF
        beq @next
        ; ---- a still box, kept identical and not clipped, is left alone
        cpy #BOXID0+BOXN
        bcc @write                  ; not a still alias: draw it
        lda KEEP,x
        cmp #2
        bne @write                  ; not the same frame in the same place
        ldy #REC_H
        lda (rp),y
        bpl @next                   ; not clipped: all of it on screen and intact
        ; ---- write the record's id and position, and set up spx/spy
@write: ldy #1
        lda SPR_XL,x
        sta spx
        sta (rp),y
        iny
        lda SPR_XH,x
  .if DRAWFLAGS
        sta (rp),y                  ; (the record keeps the flags: a flip is a change)
        asl                         ; bit 7, mirror, into C
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
        ldy #REC_W
        lda #0
        sta (rp),y                  ; nothing drawn
        iny                         ; REC_H
        lda #$80
        sta (rp),y                  ; clipped
        lda SPR_ID,x
        staz rp                     ; sta (rp) - offset 0 needs no index
        jsr drawsprite
        ; ---- next record: rp += RECSZ
@next:  lda rp
        clc
        adc #RECSZ
        sta rp
        bcs @rpc                    ; (the carry out of line, after the rts)
@rpb:   inc spi
        bne @l                      ; spi <= NSPR: never wraps to 0
@endpass:
        dec dpass
        bpl @pass                   ; (in range on both machines)
        ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts
@rpc:   inc rp+1
        jmp @rpb
  .endif

; ============================================================================
; erase_old: redraw the tiles under the buffer's old records that are not kept
;   In:   RECCNT[curbuf] records at recb / recp (what this buffer last drew);
;         KEEP[] from match_sprites, for the first NSPR of them
;   Out:  A, X, Y clobbered
; A record past the new list's end (i >= NSPR) is never kept; one of width 0 drew
; nothing.  Each rect goes to bank 6's drawrect_clip through callbank.  It runs
; before draw_sprites overwrites the records; it sits after it in the file only for
; where the two loops fall (pads.inc).
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_EO, ::PADM_EO
erase_old:
        ldx curbuf
        lda RECCNT,x
        beq @done
        sta lcnt                    ; records to look at

  .if TIGHTBSS
        ; ---- TIGHTBSS: the records are arrays, indexed by rq
        stz lidx
        lda recb                    ; the buffer's first record, stepped with lidx
        sta rq
@l:     ldx lidx
        cpx NSPR
        bcs @erase                  ; past the new list: never kept
        lda KEEP,x
        bne @next                   ; kept: leave it
@erase: ldy rq
        lda REC_W,y
        beq @next                   ; width 0: nothing was drawn
        sta rc_w
        lda REC_H,y
        and #$1F                    ; bits 0-4: the height
        sta rc_h
        lda REC_H,y                 ; bits 5-6: the column's high bits
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
        stz lidx
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx lidx
        cpx NSPR
        bcs @erase                  ; past the new list: never kept
        lda KEEP,x
        bne @next                   ; kept: leave it
@erase: ldy #REC_W
        lda (rp),y
        beq @next                   ; width 0: nothing was drawn
        sta rc_w
        iny                         ; REC_H
        lda (rp),y
        and #$7F                    ; the height, without the clipped bit
        sta rc_h
        ldy #REC_CX
        lda (rp),y
        sta rc_x
        iny
        lda (rp),y
        sta rc_x+1
        iny                         ; REC_CY
        lda (rp),y
        sta rc_y
  .endif

        ; ---- redraw the rect's tiles, then the next record
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is drawrect_clip
        jsr callbank
  .if TIGHTBSS
@next:  inc rq
  .else
@next:  lda rp
        clc
        adc #RECSZ
        sta rp
        bcc :+
        inc rp+1
:
  .endif
        inc lidx
        dec lcnt
        bne @l
@done:  rts

; ============================================================================
; match_sprites: the persistent sprite records -- which new sprites are already drawn?
;   In:   the sprite list (SPR_*, NSPR); the buffer's records (RECCNT[curbuf] of
;         them, at recb / recp); BUF_CXH[curbuf]
;   Out:  KEEP[i] for every i < NSPR: 2 = sprite i is record i (same id, same place:
;         its screen pixels are already right), 1 = a box star where a box star was
;         (a different frame of the same thing, same place), 0 = neither;
;         A, X, Y clobbered
; Two box-star frames at the same place overwrite each other exactly -- every game
; pixel opaque, and each box covers the art of the frame before it -- so a frame
; change there needs no erase either: hence KEEP = 1.
; An invalid buffer (BUF_CX high byte $80: a level start, or a dirty list that
; overflowed) is about to be redrawn whole, so nothing in it is kept and there is
; nothing to erase: its records go (RECCNT = 0).
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_MS, ::PADM_MS    ; (each machine's code off page crossings: pads.inc)
match_sprites:
        ; ---- an invalid buffer drops its records
        ldx curbuf
        lda BUF_CXH,x
        bpl @valid
        stz RECCNT,x
        ; ---- cnt = the records to compare, min(RECCNT, NSPR)
@valid: lda RECCNT,x
        cmp NSPR
        bcc :+
        lda NSPR
:       sta cnt                     ; n = min(RECCNT, NSPR)

  .if TIGHTBSS
        ; ---- TIGHTBSS: Y = the record, X = the sprite
        ldy recb
        ldx #0
@l:     cpx NSPR
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next                   ; no record i: not kept
        lda SPR_ID,x
        cmp REC_ID,y
        beq @same
        cmp #BOXID0                 ; different ids: are both box stars?
        bcc @next
        lda REC_ID,y
        cmp #BOXID0
        bcc @next
        lda #1                      ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                      ; 2 = identical, so its screen pixels are already right
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
        lda tmp3
        sta KEEP,x                  ; same screen pixels in the same place: skip the erase
@next:  iny
        inx
        bne @l                      ; always: i+1 <= MAXSPR
@done:  rts

  .else
        ; ---- the 10-byte records, walked through (rp); tmp4 = i
        stz tmp4
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx tmp4
        cpx NSPR
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next                   ; no record i: not kept
        lda SPR_ID,x
        cmpz rp                     ; (zp): offset 0 needs no index register
        beq @same
        cmp #BOXID0                 ; different ids: are both box stars?
        bcc @next
  .if BHW
        lda (rp),y                  ; Y = 0 from the cmpz above
  .else
        ldaz rp
  .endif
        cmp #BOXID0
        bcc @next
        lda #1                      ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                      ; 2 = identical, so its screen pixels are already right
        ; ---- and the same place: record bytes 1-4
@pos:   sta tmp3
  .if BHW
        iny                         ; Y = 0 on both ways in (cmpz, ldaz)
  .else
        ldy #1
  .endif
        lda SPR_XL,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_XH,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_YL,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_YH,x
        cmp (rp),y
        bne @next
        lda tmp3                    ; (X is still the sprite's number)
        sta KEEP,x                  ; same screen pixels in the same place: skip the erase
@next:  lda rp
        clc
        adc #RECSZ
        sta rp
        bcc :+
        inc rp+1
:       inc tmp4
        bne @l                      ; always: i+1 <= MAXSPR
@done:  rts
  .endif

; ----------------------------------------------------------------------------
; addsprite: add a sprite to the draw list
;   In:   A = id;  spx, spy = its reference point in game pixels (map coordinates)
;   Out:  NSPR + 1, unless the list is full (MAXSPR): then the sprite is dropped;
;         A, X clobbered, Y kept
; The game's call, a sprite at a time, each frame.
; ----------------------------------------------------------------------------
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
addsprite:
        ldx NSPR
        cpx #MAXSPR
        bcs @full                   ; full: dropped
        sta SPR_ID,x
        lda spx
        sta SPR_XL,x
        lda spx+1
        sta SPR_XH,x
        lda spy
        sta SPR_YL,x
        lda spy+1
        sta SPR_YH,x
        inc NSPR
@full:  rts

; ============================================================================
; copy_partial: compose the ring row above the window (the "A" section's source)
;   In:   wfine, wcx, wcy, ringS; (Model B) barq, RING_A, ringbhi
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
        PAD ::PADB_CP, ::PADM_CP    ; (each machine's code off page crossings: pads.inc)
copy_partial:
        lda wfine
        bne :+
        rts                         ; fine scroll 0: nothing to compose
:
        ; ---- the run: cnt columns from column tmp4; w16 = its map column
        lda #ROWCHARS
        sta cnt
        lda #0
        sta tmp4                    ; first column to copy
        clc
        adc wcx
        sta w16
        lda wcx+1
        adc #0
        sta w16+1

  .if BHW
        ; ---- Model B: the composed row is the ring row above the window, the last
        ; slot when the window starts at slot 0 -- then the mirror follows it, so
        ; note the columns (mirdirty: A = first, X = last)
        lda barq
        bne @nomir
        lda tmp4                    ; C = 0 from the w16+1 adc (wcx < $8000)
        adc cnt
        tax
        dex
        lda tmp4
        jsr mirdirty                ; (bank 7's copy)
@nomir:
  .endif

        ; ---- source: sp = row wcy at column wcx, wfine lines into the char
        lda wcy
        jsr ringaddr7               ; sp = source start (row wcy, column wcx)
        ; Offsetting sp by wfine (under 8, and a char is 8-aligned) keeps its page
        ; crossings on the real char boundaries, so spnext's fold still lands where it
        ; should.
        lda sp
        clc
        adc wfine
        sta sp

        ; ---- dest: ptr = the same column of the composed row, the row above the
        ; window: ring char (ringS + col - 80) mod RINGCHARS, as a real address in
        ; the ring
        ; ringS + tmp4 - 80: the low add of -80 cannot carry (tmp4 <= 79)
        lda tmp4                    ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc #<(-ROWCHARS)
        adc ringS
        sta ptr
        lda ringS+1
        adc #$FF
        bcs @pnf                    ; C = 1: >= 0, already in the ring
  .if BHW
        ; < 0: + RINGCHARS, 16 bit (23 rows is not whole pages)
        tax
        lda ptr
        adc #<RINGCHARS
        sta ptr
        txa
  .endif
        adc #>RINGCHARS
        ; char -> byte address (A:ptr), + RINGBASE.  The rols leave C clear: the
        ; offset is under $5000.
@pnf:   asl ptr
        rol
        asl ptr
        rol
        asl ptr
        rol
  .if BHW
        tax
        lda ptr                     ; the base is xx80, and which xx is the buffer's
        adc #<RING_A
        sta ptr
        txa
        adc ringbhi
  .else
        adc #>RINGBASE
  .endif
        sta ptr+1

        ; ---- the copy.  Y is the dest line, 0..7-wfine, and the source line is
        ; Y + wfine through the offset sp: enter the unrolled copy at the pair for
        ; this wfine by patching the loop's back branch.
        ldx wfine
        lda @ftab-2,x               ; this wfine's entry, as a branch offset
        sta @back+1                 ; patched into the loop's back branch
        ldx cnt                     ; char counter in X: dex/beq is 3 cycles cheaper
        clc
        bcc @back                   ; in at the patched entry (C = 0)
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
        spnext @sfold
@sback: dex
        beq @done
        lda ptr
        clc
        adc #8
        sta ptr
        bcs @pfold
@back:  bcc @g4                     ; patched (@ftab): C = 0 at every arrival
        SAMEPAGE *, @g4
        SAMEPAGE *, @g0
@done:  rts
        ; ---- the page steps, out of line
@sfold: spcold @sback
@pfold: pagestep ptr, @back
        bcc @back                   ; (C = 0: pagestep's)

; ============================================================================
; drawsprite: the sprite prologue -- draw one sprite
;   In:   A = id;  spx, spy = its reference point in game pixels (map coordinates);
;         (DRAWFLAGS) sp_dfl = the list's mirror;  X dead;
;         the record in hand: rq (TIGHTBSS) or rp, set up by draw_sprites
;   Out:  the record's rectangle (REC_CX, REC_CY, REC_W, REC_H) written when any of
;         the sprite is in the window; then the row loop has drawn it.  Returns
;         without either when it is wholly off the window or not in this level.
;         A, X, Y and the prologue's zero page clobbered.
; The directory is split.  The level's part, in bank 7 (banks.s, ldprog.s): DIR_LO and
; DIR_HI, the image's address by id, 0 if not in this level, bit 7 of the high byte
; clear for bank 5.  The game's part: the geometry by shape (SPRG_IX by id; SPRG_W,
; SPRG_RX, SPRG_RY, SPRG_LN and, with SPRGFL, SPRG_FL by shape).  Flags: bit 0
; mirrored, bit 1 every scanline stored (a box), bit 3 the copy blitter.
; The steps: fetch the geometry; clip horizontally (sp_c0..sp_c1, first image column
; sp_c) and vertically (lines lstart..lend, char rows sp_r0..sp_r1); write the
; record; (Model B) note the mirror's columns; pick the blitter; work out the screen,
; and image pointers; and jump to the row loop (NIB_LOOPS, sprloops.s) in the data's bank
; through callbank.  spclip counts the window edges it was cut against.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_DS, ::PADM_DS
drawsprite:
  .if BHW
        ldx #0                      ; X is dead on entry
        stx spclip                  ; set at every window edge the sprite is cut against
  .else
        stza spclip                 ; set at every window edge the sprite is cut against
  .endif

        ; ==== the address from the level's DIR_LO/HI, the geometry from the game's
        ; SPRG_* tables by shape
    .if BOXN
        ; a "nothing can disturb it" alias draws the same picture as the id BOXN below
        cmp #BOXID0+BOXN
        bcc :+
        sbc #BOXN                   ; (C = 1: the bcc not taken)
:
    .endif
        tax                         ; X = id
        ; ---- the image's address and bank
        bankimm ldy, BANK_SPR, BANK_LVL
        lda DIR_HI,x
        bne :+
        rts                         ; not in this level (@out0 is out of reach)
:       bmi :+                      ; bit 7 set: bank 4
        ora #$80                    ; bank 5: the address's bit 7 put back
        bankimm ldy, BANK_TIL1, BANK_LVL
:       sty sp_dbank
        sta sp_ptr+1
        lda DIR_LO,x
        sta sp_ptr
        ; ---- the shape's flags, width and lines.  With SPRGFL (assets.inc says so)
        ; the flags are the game's, by shape: a game that mirrors by id rather than
        ; by the list.  Without it the list's mirror is the only flag: every
        ; scanline stored is clear (every image's).
        ldy SPRG_IX,x
        sty sp_g
    .ifdef SPRGFL
        lda SPRG_FL,y
      .if DRAWFLAGS
        eor sp_dfl
      .endif
    .elseif DRAWFLAGS
        lda sp_dfl
    .else
        lda #0
    .endif
        sta sp_flags
        lda SPRG_W,y
        sta sp_w
        lda SPRG_LN,y
        sta sp_lines
        sta sp_ext
        ; every scanline stored (a box's screen bytes): the lines are scanlines;
        ; else two scanlines a stored row
        lda sp_flags
        and #2
        bne :+
        asl sp_ext
:
        ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        lda SPRG_RX,y               ; tmp3 = refx's sign extension (sext inlined)
        and #$80
        beq @sxp
        lda #$FF
@sxp:   sta tmp3
        lda spx
        sec
        sbc SPRG_RX,y


        ; ---- (both) finish sx = spx - refx - wx, and c0 = sx >> 1 in w16
        tax
        lda spx+1
        sbc tmp3
        tay
        txa
        sec
        sbc wx
        sta w16
        tya
        sbc wx+1
        cmp #$80
        ror a                       ; sign into bit 7, old bit 0 out to C
        ror w16                     ; arithmetic shift right 1 -> c0 (16 bit)
        tax                         ; A still holds w16+1: just restore N,Z (X is dead)
        beq @cpos
        cmp #$FF
        bne @out0                   ; c0 < -128 or >= 256: off the window

        ; ---- c0 negative (-128..-1): cut at the left.  sp_c0 = 0;
        ; visible if c0 + W > 0, and then sp_c1 = c0 + W - 1, sp_c = -c0
        lda w16
        sbc #2                      ; C = 1 from the cmp #$FF: w16 >= $80, so C stays 1
        adc sp_w                    ; w16 - 2 + W + 1 = c0 + W - 1
        bmi @out0
        inc spclip
        sta sp_c1
        lda #0                      ; stz sp_c0, with the zero kept for the negate
        sta sp_c0
        sbc w16                     ; C = 1 (bmi fall-through): A = -c0, 1..128
        sta sp_c                    ; starting image column: the first visible, -c0
        bne @vert                   ; always: -c0 is never 0

        ; ---- c0 >= 0: off the window at 80 on; else sp_c0 = c0, sp_c = 0,
        ; sp_c1 = c0 + W - 1 cut at 79 (the right edge)
@cpos:  lda w16
        cmp #ROWCHARS
        bcs @out0                   ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        sbc #0                      ; C = 0 still (c0 + W < 256): A - 1, as deca
        cmp #ROWCHARS
        bcc :+
        inc spclip                  ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
        stz sp_c                    ; A is dead at @vert
        jmp @vert
@out0:  rts

        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine, the sprite's
        ; first scanline below the window's top (16 bit signed)
@vert:
        ldy sp_g
        lda SPRG_RY,y
        jsr sext                    ; tmp3 = refy's sign (Y kept)
        lda spy
        sec
        sbc SPRG_RY,y
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
        asl                         ; C = old bit 7, exactly what 'asl w16' left
        rol sp_lb0+1
        clc
        adc wfine
        sta sp_lb0
        bcc @nc
        inc sp_lb0+1                ; lb0 (16 bit signed)
        clc                         ; only this arm arrives with C set
@nc:
        ; ---- w16 = lb1, the last scanline: lb0 + ext - 1 (C = 0 here)
  .if BHW
        ldx sp_ext                  ; X is dead here: ext - 1, carry kept
        dex
        txa
  .else
        lda sp_ext
        deca
  .endif
        adc sp_lb0
        sta w16
        lda sp_lb0+1
        adc #0
        sta w16+1                   ; w16 = lb1

        ; ---- clip: lstart = max(lb0, 0) in tmp ; lend = min(lb1, BUFROWS*8-1) in X
        lda sp_lb0+1
        bmi @top
        bne @out0                   ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0                   ; below the window
        sta tmp                     ; lstart
        bcc @ck                     ; C = 0: the bcs above was not taken
@top:   lda w16+1
        bmi @out0                   ; lb1 < 0
        inc spclip                  ; cut off at the top
        sta tmp                     ; A = w16+1 = 0 here: lb0 < 0 <= lb1 < 256
@ck:    lda w16+1
        bne @clampend
        lda w16
        cmp #BUFROWS*8
        bcc :+
@clampend:
        inc spclip                  ; and at the bottom
        lda #BUFROWS*8-1
        ; lend in X (tmp2 is not read again before the row loop sets it)
:       tax
        cmp tmp
        bcc @out0                   ; lend < lstart: nothing left

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
        sta w16                     ; @rows needs this same sum: keep it, don't rebuild it
        sta REC_CX,y
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy                     ; C = 0: wcx+1 <= $7F, so the adc #0 above cannot carry
        adc sp_r0
        sta REC_CY,y
    .if BHW
        ldx sp_c1                   ; width = c1 + 1 - c0 (X dead: ldx spclip below)
        inx
        txa
        sec
        sbc sp_c0
    .else
        lda sp_c1
        sec
        sbc sp_c0
        inca
    .endif
        sta REC_W,y
        lda sp_r1
        sbc sp_r0                   ; C still set by the width sbc above (sp_c1 >= sp_c0)
        adc #0                      ; and set by this one (sp_r1 >= sp_r0): + 1
        sta tmp3                    ; (free here)
        ; the column's high bits (< 4: a map is 1024 chars wide at most) to bits 5-6
        lda w16+1
        asl
        asl
        asl
        asl
        asl
        ora tmp3
        ldx spclip
        beq :+
        ora #$80                    ; clipped
:       sta REC_H,y
  .else
        ; the 10-byte record at rp
        ldy #REC_CX
        lda wcx
        clc
        adc sp_c0
        sta w16                     ; @rows needs this same sum: keep it, don't rebuild it
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta w16+1
        sta (rp),y
        iny                         ; REC_CY
        lda wcy                     ; C = 0: wcx+1 <= $7F, so the adc #0 above cannot carry
        adc sp_r0
        sta (rp),y
        iny
  .if BHW
        ldx sp_c1                   ; width = c1 + 1 - c0 (X dead: ldx spclip below)
        inx
        txa
        sec
        sbc sp_c0
  .else
        lda sp_c1
        sec
        sbc sp_c0
        inca
  .endif
        sta (rp),y
        iny                         ; REC_H
        lda sp_r1
        sbc sp_r0                   ; C still set by the width sbc above (sp_c1 >= sp_c0)
        adc #0                      ; and set by this one (sp_r1 >= sp_r0): + 1
        ldx spclip
        beq :+
        ora #$80                    ; clipped
:       sta (rp),y
  .endif

  .if BHW
        ; ---- Model B: the mirror's row (mrow), relative to the window: if the
        ; sprite covers it, note the columns (see drawrect)
        lda mrow
        sec
        sbc wcy
        cmp sp_r0
        bcc @nomir                  ; above the sprite
        cmp sp_r1
        beq @mir
        bcs @nomir                  ; below it
@mir:   lda sp_c0
        ldx sp_c1
        jsr mirdirty
@nomir:
  .endif

        ; ---- column base pointer & step.  Mirrored: image column = W-1-c (the
        ; column loop then steps backwards)
        lda sp_flags
        bitimm 1
        beq @nomirror
        clc
        lda sp_w
        sbc sp_c                    ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags                ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the inner blitter once per sprite: sp_disp = 8 for the copy
        ; blitter (flags bit 3), else (flags & 3) * 2 -- mirrored, every scanline
        ; stored.  The row loop's copy in the data's bank patches its own jump.
        bitimm 8                    ; bit3: copy blitter
        beq :+
        ldx #8
        bne :++
:       and #3                      ; A is still sp_flags: bit #imm does not alter A
        asl
        tax
:
        stx sp_disp                 ; (a patched jmp in the column loop)

        ; ---- screen base sp_rb for (wcx + c0, wcy + r0): one ringaddr, then +80
        ; chars per row (w16 = wcx + sp_c0 was already built when the record rect
        ; was written)
@rows:
        lda sp_r0
        sta sp_row
        clc
        adc wcy
        jsr ringaddr7               ; this bank's own copy (no crossing)
        sta sp_rb+1                 ; A = sp+1: ringaddr's last store
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
        bne :+                      ; every scanline stored: 8
        lda w16+1
        asl                         ; C = the sign: an arithmetic >> 1
        ror w16+1
        ror w16
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


        ; ---- the columns, and away to the row loop
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                 ; columns-1
        ; The row loop and the inner blocks are assembled into each sprite data bank
        ; (SPRITE_LOOPS, sprloops.s): call the copy in the bank the directory named,
        ; through low RAM's direct switch (both banks enter at BANKENTRY) and back to
        ; this bank.
        lda sp_dbank
        jmp callbank

; ============================================================================
; render_core: the frame's steps, in order, into the back buffer
;   In:   curbuf; the window (wcx, wcy, wfine); the sprite list; the dirty lists
;   Out:  the back buffer drawn;  A, X, Y clobbered
; Bank 7 drives the frame and keeps the records; bank 6 gets two fixed calls a frame
; (low RAM's selbb and validate) and the rects through callbank.
; ============================================================================
        .segment "ENGCODE"
render_core:
        jsr selbb                   ; select_backbuf (bank 6: it patches ringaddr)
        jsr calc_ring               ; ringS, barq (Model B: wcxm, mrow)
        jsr match_sprites
        jsr erase_old
        jsr validate                ; scroll_validate (bank 6: it draws the new strips)
        jsr draw_dirty              ; (bank 7 from here: the rects through callbank)
        jsr blank_below
        jsr draw_sprites
        jsr copy_partial
    .if BHW
        jmp mirror_copy             ; the straddling row's copy (mirror.s)
    .else
        rts                         ; (the hardware folds the straddling row)
    .endif

; ============================================================================
; mark_dirty: queue a changed map tile for redrawing, in both buffers' lists
;   In:   A = tx, X = ty (the tile's map column and row)
;   Out:  A, X, Y, tmp, tmp2 clobbered
; Each buffer keeps its own list (DIRTYCNT, and DIRTX/DIRTY_ with TIGHTBSS, else
; DIRTYLIST's x,y pairs: buffer 0's DIRTYMAX, then buffer 1's).  A full list marks
; that buffer to be redrawn whole instead (BUF_CXH = $80: an unreachable window x;
; match_sprites drops its records, scroll_validate redraws it).  The game's call.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
mark_dirty:
        sta tmp
        stx tmp2
        ldx #1                      ; buffer 1, then 0
@b:     lda DIRTYCNT,x
        cmp #DIRTYMAX
        bcs @over
  .if TIGHTBSS
        cpx #1                      ; (C = 0: cnt < DIRTYMAX)
        bcc @b0                     ; buffer 0: its list is at 0
        adc #DIRTYMAX-1             ; buffer 1: C = 1, so this adds DIRTYMAX
@b0:    tay
        lda tmp
        sta DIRTX,y
        lda tmp2
        sta DIRTY_,y
  .else
        asl                         ; cnt*2, C = 0 (cnt < DIRTYMAX)
        cpx #1
        bcc @b0                     ; buffer 0: its list is at 0
        adc #2*DIRTYMAX-1           ; buffer 1: C = 1, so this adds 2*DIRTYMAX
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
        sta BUF_CXH,x               ; an unreachable window x
        bne @next                   ; (always)

; ----------------------------------------------------------------------------
; sext: sign-extend A into tmp3
;   In:   A
;   Out:  tmp3 = 0 or $FF, by A's bit 7;  A = tmp3;  X, Y kept
; ----------------------------------------------------------------------------
        .segment "ENGCODE"          ; (its one caller is the sprite prologue: bank 7)
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ============================================================================
; draw_dirty: redraw the back buffer's queued dirty tiles, and empty its list
;   In:   curbuf; DIRTYCNT[curbuf] and the buffer's list (mark_dirty)
;   Out:  DIRTYCNT[curbuf] = 0;  A, X, Y clobbered
; A tile (tx, ty) is the rect of 4 chars by 2 char rows at (tx*4, ty*2), redrawn by
; bank 6's drawrect_clip through callbank.
; ============================================================================
        .segment "ENGCODE"          ; bank 7 (drawrect_clip through callbank)
draw_dirty:
        ldx curbuf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
        ; ---- lidx = the buffer's list
  .if TIGHTBSS
        lda #0                      ; the buffer's list: 0, or DIRTYMAX for buffer 1
        cpx #1
        bcc @d0
        lda #DIRTYMAX
  .else
        lda #0                      ; the buffer's list: 0, or 2*DIRTYMAX for buffer 1
        cpx #1
        bcc @d0
        lda #2*DIRTYMAX
  .endif
@d0:    sta lidx
        ; ---- rc_x = tx*4 (16 bit)
@l:     stz rc_x+1                  ; A is dead here: loaded just below
        ldy lidx
  .if TIGHTBSS
        lda DIRTX,y
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
        lda DIRTY_,y
        iny                         ; Y is dead from here: advance the index in it
  .else
        lda DIRTYLIST+1,y
        iny                         ; Y is dead from here: advance the index in it
        iny
  .endif
        sty lidx
        asl
        sta rc_y
        ; ---- 4 x 2 chars, and draw
        lda #4
        sta rc_w
        lsr                         ; 4 >> 1 = 2
        sta rc_h
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is drawrect_clip
        jsr callbank
        dec lcnt
        bne @l
        ldx curbuf
        stz DIRTYCNT,x              ; A is dead: render_core's next call reloads it
@done:  rts

; ============================================================================
; blank_below: black the ring slot below the playfield, on the map's bottom row
;   In:   wfine, wy, maxwy, wcx, wcy, curbuf, BUF_BOTOK[curbuf]
;   Out:  A, X, Y, sp, w16 clobbered
; The 6845 always displays the first scanline of a frame, whatever R6 says, so the
; blanking section's row 0 line 0 -- the ring slot below the playfield -- is one line
; more under the picture.  Elsewhere it is the next map line; parked on the map's
; bottom row it is whatever that never-drawn slot last held.  So when the window sits
; on the bottom row, blank the slot, once per buffer per arrival (BUF_BOTOK: set here,
; cleared by scroll_validate when the window moves).
; ============================================================================
        .segment "ENGCODE"          ; bank 7, beside render_core
blank_below:
        ; ---- only on the bottom row (fine scroll 0, wy = maxwy), once
        lda wfine
        bne @no
        lda wy
        cmp maxwy
        bne @no
        lda wy+1
        cmp maxwy+1
        bne @no
        ldx curbuf
        lda BUF_BOTOK,x
        bne @no                     ; already black
        inc BUF_BOTOK,x
        ; ---- the row below the playfield: map char row wcy + VISROWS at the
        ; window's column.  Rows are not slot aligned, so this is a run of 80 chars
        ; that may straddle the ring end.
        lda wcx
        sta w16
        lda wcx+1
        sta w16+1
        lda wcy
        adc #VISROWS-1              ; C = 1 from cmp maxwy+1 (equal)
        jsr ringaddr7               ; sp = its ring address
        ; ---- zero its 80 chars
        ldx #ROWCHARS
@char:  lda #0
        ldy #7
        .repeat 7
        sta (sp),y
        dey
        .endrepeat
        sta (sp),y
        spnext @fold                ; 8 on, folding at the ring end (out of line)
@fback: dex
        bne @char
        SAMEPAGE *, @char
@no:    rts
@fold:  spcold @fback
        ; the Model B's bank 7 code ends at the kernel: this pad places what is above
        ; it (pads.inc)
        PAD ::PADB_BB, 0


; ============================================================================
; render_frame: render everything queued for the back buffer and request the flip
;   In:   curbuf = the back buffer; the window (wx, wy); the sprite list (NSPR);
;         BARDIRTY
;   Out:  the flip requested (flipreq = 1, NEXTSECT = the buffer's chain);
;         curbuf = the other buffer; NSPR = 0; A, X, Y clobbered
; The game's call, once a rendered frame.  It does not wait for the flip it asks for:
; the next logic step runs while the flip is pending, and the next render_frame waits
; for it before touching the buffer.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the game loop
render_frame:
        ; the previous frame's flip must land before this buffer is touched
        jsr wait_flip

        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: T starts QROWS-QVSYNC
        ; rows after the vsync wait_flip just returned from (32 lines on the Master,
        ; 64 on the Model B).  Only digits: the template comes with the game's image
        ; (the BAR file) and nothing erases it -- the menus keep to the ring
        ; (menu_sections).
        lda BARDIRTY
        beq :+
        jsr hook_hud                ; (the game's: README.md)
  .if BHW
        dec BARDIRTY                ; only ever set to 1: 1 -> 0
  .else
        stz BARDIRTY
  .endif
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
        ldx wcy                     ; (the high bits: drawrect's map row)
        stx wcyh
  .endif
        ror
        sta wcy

        ; ---- draw, and build this buffer's section chain
        jsr render_core
        stz NSPR                    ; A dead: build_sections starts ldx/lda
        jsr build_sections

        ; ---- hand over to the ISR: NEXTSECT = the buffer's chain, 0 or 48
        lda curbuf
  .if .not BHW
        sta NEXTBUF
  .endif
        beq :+
        lda #48
:       sta NEXTSECT
        lda #1
        sta flipreq
render_done:                        ; (label for the phase timer harness)
        ; no wait here: the next logic step runs while the flip is pending and
        ; the next render_frame waits for it before touching the buffer
        eor curbuf                  ; A = 1: curbuf ^ 1
        sta curbuf
        rts

; ----------------------------------------------------------------------------
; wait_flip: spin until any pending flip has been taken by the vsync ISR
;   Out:  A = 0 (flipreq);  X, Y kept
; ----------------------------------------------------------------------------
wait_flip:
        lda flipreq
        bne wait_flip
        rts
