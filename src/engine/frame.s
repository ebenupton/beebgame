
; draw all listed sprites into current buffer (skipping unchanged kept ones)
        .segment "ENGCODE"          ; bank 7, with the prologue and the records
        PAD ::PADB_SP, ::PADM_SP
draw_sprites:
        ; Two passes.  A box star is an opaque rectangle with its background baked in,
        ; so it has to go down before anything that shares its space -- drawn in list
        ; order it would paint that background over whatever was standing there.
        lda #1
        sta dpass
  .if TIGHTBSS
@pass:  stz spi
        lda recb                    ; the buffer's first record, stepped with spi
        sta rq
@l:     ldx spi                     ; X = the sprite's number: every field is ,x
        cpx NSPR
        bcs @endpass
        ldy SPR_ID,x                ; Y = id for both compares
        cpy #BOXID0
        lda dpass
        adc #$FF
        beq @next
        cpy #BOXID0+BOXN            ; a box star the logic says nothing can disturb, and
        bcc @write                  ; the same frame already in the same place: if
        lda KEEP,x                  ; nothing has been repainted under it, its screen pixels
                                    ; are still right, so leave it alone
        cmp #2
        bne @write
        ldy rq                      ; and it was not cut off at a window edge, so all
        lda REC_H,y                 ; of it is on screen and still intact
        bpl @next
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
        lda #0
        sta REC_W,y
        lda #$80                    ; clipped until the prologue says otherwise: a sprite
        sta REC_H,y                 ; wholly off the window writes no rectangle, and must
        lda SPR_ID,x                ; not look drawn and intact to the next keep test
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
@pass:  stz spi                     ; A dead: lda recp next
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx spi                     ; X = the sprite's number: every field is ,x
        cpx NSPR
        bcs @endpass
        ldy SPR_ID,x                ; Y = id for both compares
        cpy #BOXID0
        lda dpass
        adc #$FF
        beq @next
        cpy #BOXID0+BOXN            ; a box star the logic says nothing can disturb, and
        bcc @write                  ; the same frame already in the same place: if
        lda KEEP,x                  ; nothing has been repainted under it, its screen pixels
                                    ; are still right, so leave it alone
        cmp #2
        bne @write
        ldy #REC_H                  ; and it was not cut off at a window edge, so all
        lda (rp),y                  ; of it is on screen and still intact
        bpl @next
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
        ldy #REC_W
        lda #0
        sta (rp),y
        iny                         ; REC_H: clipped until the prologue says otherwise --
        lda #$80                    ; a sprite wholly off the window writes no rectangle,
        sta (rp),y                  ; and must not look drawn and intact to the next keep
        lda SPR_ID,x
        staz rp                     ; sta (rp) - offset 0 needs no index
        jsr drawsprite
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

; erase_old: redraw tiles under old records that are not kept (after draw_sprites
; only for where the two loops fall: pads.inc)
        .segment "ENGCODE"          ; bank 7, with the records (the rects it redraws
        PAD ::PADB_EO, ::PADM_EO
erase_old:                          ; go to bank 6's drawrect_clip through callbank)
        ldx curbuf
        lda RECCNT,x
        beq @done
        sta lcnt
  .if TIGHTBSS
        stz lidx
        lda recb                    ; the buffer's first record, stepped with lidx
        sta rq
@l:     ldx lidx
        cpx NSPR
        bcs @erase
        lda KEEP,x
        bne @next
@erase: ldy rq
        lda REC_W,y
        beq @next
        sta rc_w
        lda REC_H,y
        and #$1F
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
        stz lidx
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx lidx
        cpx NSPR
        bcs @erase
        lda KEEP,x
        bne @next
@erase: ldy #REC_W
        lda (rp),y
        beq @next
        sta rc_w
        iny                         ; REC_H
        lda (rp),y
        and #$7F
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
; Persistent sprite records.  match_sprites: KEEP[i] = new sprite i identical to record i
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the records
        PAD ::PADB_MS, ::PADM_MS    ; (each machine's code off page crossings: pads.inc)
match_sprites:
        ldx curbuf                  ; an invalid buffer (BUF_CX high byte $80: a level
                                    ; start, or a dirty list that overflowed) is about to
                                    ; be redrawn whole, so nothing in it is kept and
        lda BUF_CXH,x               ; there is nothing to erase: its records go
        bpl @valid
        stz RECCNT,x
@valid: lda RECCNT,x
        cmp NSPR
        bcc :+
        lda NSPR
:       sta cnt                     ; n = min(RECCNT, NSPR)
  .if TIGHTBSS
        ldy recb                    ; Y = the record, X = the sprite
        ldx #0
@l:     cpx NSPR
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next
        lda SPR_ID,x
        cmp REC_ID,y
        beq @same
        ; two box-star frames at the same place overwrite each other exactly -- every
        ; game pixel opaque, and each box covers the art of the frame before it -- so a
        ; frame change there needs no erase either
        cmp #BOXID0
        bcc @next
        lda REC_ID,y
        cmp #BOXID0
        bcc @next
        lda #1                      ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                      ; 2 = identical, so its screen pixels are already right
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
        stz tmp4                    ; i
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx tmp4
        cpx NSPR
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next
        lda SPR_ID,x
        cmpz rp                     ; (zp): offset 0 needs no index register
        beq @same
        ; two box-star frames at the same place overwrite each other exactly -- every
        ; game pixel opaque, and each box covers the art of the frame before it -- so a
        ; frame change there needs no erase either
        cmp #BOXID0
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

; ============================================================================
; Sprites
; ============================================================================
; add sprite to draw list: A = id, spx/spy = game pixels (map coordinates)
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
addsprite:
        ldx NSPR
        cpx #MAXSPR
        bcs @full
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
; copy_partial: copy lines wfine..7 of ring row wcy into lines 0..(7-wfine) of the
; ring row above the window (the "A" section's source), all 80 columns.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, beside render_core
        PAD ::PADB_CP, ::PADM_CP    ; (each machine's code off page crossings: pads.inc)
copy_partial:                       ; the whole row, every frame the fine scroll is not 0
        lda wfine                   ; (tracking the columns drawn since the last copy
        bne :+                      ;  saves under 0.3% of a frame: measured)
        rts
:
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
        lda barq                    ; the composed row is the ring row above the window,
        bne @nomir                  ; the last slot when the window starts at slot 0
        lda tmp4                    ; C = 0 from the w16+1 adc (wcx < $8000)
        adc cnt
        tax
        dex
        lda tmp4
        jsr mirdirty                ; (bank 7's copy)
@nomir:
  .endif
        lda wcy
        jsr ringaddr7               ; sp = source start (row wcy, column wcx)
        ; source: sp is the char, and the copy starts wfine lines into it.  Offsetting
        ; sp by wfine (under 8, and a char is 8-aligned) keeps its page crossings on
        ; the real char boundaries, so spnext's fold still lands where it should
        lda sp
        clc
        adc wfine
        sta sp
        ; dest: the same column of the composed row, ring char (ringS + col - 80)
        ; mod RINGCHARS -- the row above the window -- as a real address in the ring
        lda tmp4                    ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc #<(-ROWCHARS)           ; ringS + tmp4 - 80: this low add cannot carry (tmp4 <= 79)
        adc ringS
        sta ptr
        lda ringS+1
        adc #$FF                    ; C = 1: >= 0, already in the ring
        bcs @pnf
  .if BHW
        tax                         ; < 0: + RINGCHARS, 16 bit (23 rows is not whole pages)
        lda ptr
        adc #<RINGCHARS
        sta ptr
        txa
  .endif
        adc #>RINGCHARS
@pnf:   asl ptr                     ; char -> byte address (A:ptr), + RINGBASE (the rols
        rol                         ; leave C clear: the offset is under $5000)
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
        ; Y is the dest line, 0..7-wfine, and the source line is Y + wfine through the
        ; offset sp: enter the unrolled copy at the pair for this wfine.  (A loop here
        ; is 40 bytes smaller and ~1% of a frame slower: every frame with vertical
        ; movement recomposes all 80 columns.)
        ldx wfine
        lda @ftab-2,x               ; the loop's back branch, patched to this wfine's entry
        sta @back+1
        ldx cnt                     ; char counter in X: dex/beq is 3 cycles cheaper
        clc
        bcc @back                   ; in at the patched entry (C = 0)
@ftab:  .byte <(@g4-(@back+2)), 0, <(@g2-(@back+2)), 0, <(@g0-(@back+2))   ; wfine 2: six lines, 4: four, 6: two
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
        ; next char, both with the ring fold on the page crossing: the composed row
        ; can straddle the ring end like any other row (the page steps out of line)
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
@sfold: spcold @sback
@pfold: pagestep ptr, @back
        bcc @back                   ; (C = 0: pagestep's)

; draw one sprite: A = id ; spx, spy = game pixels, map coordinates (ref point)
; The directory is the level's, in bank 7 at SPR_TABLE (ldprog.s); the data is in
; bank 4, or bank 5 when the entry's flag bit 4 is set.  (SPRGEOM: the level's
; DIR_LO/DIR_HI, bit 7 of the high byte clear for bank 5, and the game's SPRG_* for
; the geometry, by its shape SPRG_IX.)
        .segment "ENGCODE"          ; bank 7, with the records and SPRMASK
        PAD ::PADB_DS, ::PADM_DS
drawsprite:
  .if BHW
        ldx #0                      ; X is dead on entry
        stx spclip                  ; set at every window edge the sprite is cut against
  .else
        stza spclip                 ; set at every window edge the sprite is cut against
  .endif
  .if SPRGEOM
sp_g    = sp_mh                     ; the sprite's shape (NIBSPR: no mask plane, no sp_mh)
    .if BOXN
        cmp #BOXID0+BOXN            ; the "nothing can disturb it" aliases draw the same
        bcc :+                      ; picture as the ids BOXN below them
        sbc #BOXN
:
    .endif
        tax
        bankimm ldy, BANK_SPR, BANK_LVL
        lda DIR_HI,x
        bne :+
        rts                         ; not in this level (@out0 is out of reach)
:       bmi :+
        ora #$80                    ; bank 5: the address's bit 7 put back
        bankimm ldy, BANK_TIL1, BANK_LVL
:       sty sp_dbank
        sta sp_ptr+1
        lda DIR_LO,x
        sta sp_ptr
        ldy SPRG_IX,x
        sty sp_g
    .ifdef SPRGFL                   ; the game's flags by shape (assets.inc says so): a
        lda SPRG_FL,y               ; game that mirrors by id rather than by the list
      .if DRAWFLAGS
        eor sp_dfl
      .endif
    .elseif DRAWFLAGS
        lda sp_dfl                  ; (the list's mirror is the only flag: every scanline
    .else                           ;  stored is clear, NIBSPR's images)
        lda #0
    .endif
        sta sp_flags
        lda SPRG_W,y
        sta sp_w
        lda SPRG_LN,y
        sta sp_lines
        sta sp_ext
        lda sp_flags
        and #2                      ; every scanline stored (a box's screen bytes): the
        bne :+                      ; lines are scanlines; else two scanlines a stored row
        asl sp_ext
:
        ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        lda SPRG_RX,y
        and #$80
        beq @sxp
        lda #$FF
@sxp:   sta tmp3
        lda spx
        sec
        sbc SPRG_RX,y
  .else
        cmp #BOXID0+BOXN            ; the "nothing can disturb it" aliases draw the same
        bcc :+                      ; picture as the ids BOXN below them
        sbc #BOXN
:
        sta sp_id
  .if BHW
        stx ptr+1                   ; X = 0 still
  .else
        stza ptr+1
  .endif
        asl                         ; id*8 -> offset
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1                   ; C = 0: id < 128
        adc #<SPR_TABLE
        sta ptr
        lda ptr+1
        adc #>SPR_TABLE
        sta ptr+1
        ldy #6
        lda (ptr),y
  .if DRAWFLAGS
        eor sp_dfl                  ; the list's mirror flips the directory's
  .endif
        sta sp_flags
        bankimm ldx, BANK_SPR, BANK_LVL
        and #$10                    ; bit 4: the data is in bank 5
        beq :+
        bankimm ldx, BANK_TIL1, BANK_LVL
:       stx sp_dbank            ; wanted later: the directory is still being read
  .if .not NIBSPR                   ; (4-bit sprites: no mask plane)
        lda sp_id
        asl
        tax
        lda SPRMASK,x
        sta sp_mbase
        lda SPRMASK+1,x
        sta sp_mbase+1
                                    ; (C = 0 still: the asl, sp_id < 128)
  .endif
        ldaz ptr
        sta sp_ptr
        ldy #1
        lda (ptr),y
        sta sp_ptr+1
        iny
        lda (ptr),y
        sta sp_w
        beq @out0
        ldy #7
        lda (ptr),y
        sta sp_lines
        sta sp_ext
        lsr
        sta sp_mh                   ; mask bytes per column group = game-pixel rows
        lda sp_flags
        and #2
        bne :+
        asl sp_ext                  ; half-res: two scanlines per stored row
:       ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        ldy #4
        lda (ptr),y
        and #$80                    ; sext inlined: the jsr/rts was 12 cycles of the 39
        beq @sxp
        lda #$FF
@sxp:   sta tmp3
        lda spx
        sec
        sbc (ptr),y
  .endif
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
        bne @out0
        ; c0 negative (-128..-1): cstart = 0 ; visible if c0 + W > 0
        lda w16
        sbc #2                      ; C = 1 from the cmp #$FF: w16 >= $80, so C stays 1
        adc sp_w                    ; w16 - 2 + W + 1 = c0 + W - 1
        bmi @out0
        inc spclip
        sta sp_c1
        lda #0                      ; stz sp_c0, with the zero kept for the negate
        sta sp_c0
        ; first visible column index = -c0
        sbc w16                     ; C = 1 (bmi fall-through): A = -c0, 1..128
        sta sp_c                    ; starting image column
        bne @vert                   ; always: -c0 is never 0
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
@vert:
        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine
  .if SPRGEOM
        ldy sp_g
        lda SPRG_RY,y
        jsr sext                    ; (Y kept)
        lda spy
        sec
        sbc SPRG_RY,y
  .else
        ldy #5
        lda (ptr),y
        jsr sext
        lda spy
        sec
        sbc (ptr),y
  .endif
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
        ; lend = lb0 + ext - 1
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
        ; clip lstart = max(lb0,0) ; lend = min(lb1, BUFROWS*8-1)
        lda sp_lb0+1
        bmi @top
        bne @out0                   ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0
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
:       tax                         ; lend (X: tmp2 is not read again before the row loop sets it)
        cmp tmp
        bcc @out0
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
        sta sp_r0                   ; sta sets no flags: Z still from the third lsr
@nopart:
  .if TIGHTBSS
        ; ---- record rect in current sprite record (rq: draw_sprites's)
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
        sta tmp3                    ; (free here: mtab is set in @rows)
        lda w16+1                   ; the column's high bits (< 4: a map is 1024 chars wide
        asl                         ;  at most) to bits 5-6
        asl
        asl
        asl
        asl
        ora tmp3
        ldx spclip
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta REC_H,y
  .else
        ; ---- record rect in current sprite record
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
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta (rp),y
  .endif
  .if BHW
        lda mrow                    ; the mirror's row, relative to the window: if the
        sec                         ; sprite covers it, note the columns (see drawrect)
        sbc wcy
        cmp sp_r0
        bcc @nomir
        cmp sp_r1
        beq @mir
        bcs @nomir
@mir:   lda sp_c0
        ldx sp_c1
        jsr mirdirty
@nomir:
  .endif
        ; ---- column base pointer & step
        lda sp_flags
        bitimm 1
        beq @nomirror
        ; mirror: image column = W-1-c (the column loop then steps backwards)
        clc
        lda sp_w
        sbc sp_c                    ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags                ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the inner blitter once per sprite (patched jmp in the column loop)
        bitimm 8                    ; bit3: copy blitter
        beq :+
        ldx #8
        bne :++
:       and #3                      ; A is still sp_flags: bit #imm does not alter A
        asl
        tax
:
        stx sp_disp                 ; the loop copy in the data's bank patches its own jump
  .if .not NIBSPR
        lda sp_c
        and #3                      ; phase of the first column drawn, and its page:
        ora #>MASKTAB0              ; MASKTAB0 is 1K aligned, so phase = page & 3
        sta sp_mpg0
  .endif
@rows:
        lda sp_r0
        sta sp_row
        ; screen base for (wcx + c0, wcy + r0): one ringaddr, then +80 chars per row
        ; (w16 = wcx + sp_c0 was already built when the record rect was written)
        clc
        adc wcy
        jsr ringaddr7               ; this bank's own copy (no crossing)
        sta sp_rb+1                 ; A = sp+1: ringaddr's last store
        lda sp
        sta sp_rb
        ; source row pointer = column base + r0*8 - lb0 (>>1 for half res); +8 (+4) per row
        lda tmp                     ; tmp is still lstart, and sp_r0 = lstart >> 3,
        and #$F8                    ; so r0*8 is lstart & $F8: no reload and no shifts
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        ldx #8
        lda sp_flags
        and #2
        bne :+
        lda w16+1
        asl                         ; C = the sign: an arithmetic >> 1
        ror w16+1
        ror w16
        ldx #4
:       stx sp_rinc
        ; sp_rp = sp_ptr + w16 + sp_c * lines (the column base needs no copy of its own)
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
  .if .not NIBSPR                   ; (4-bit sprites: no mask plane to walk)
        stx mtab                    ; X = 0 here: the MASKTAB pages are indexed by the mask byte
        lda w16+1                   ; the same offset in game-pixel rows (signed >> 1)
        asl                         ; C = the sign
        ror w16+1
        ror w16
        ; mask row pointer = mask plane + (first image column / 4) * game-pixel rows + that offset
        lda sp_c
        lsr
        lsr
        tay                         ; column groups to step over
        lda sp_mbase
        clc
        adc w16
        tax
        lda sp_mbase+1
        adc w16+1
        sta sp_mrp+1
        txa
        cpy #0
        beq @mgdone
        clc
@mgrp:  adc sp_mh
        bcc @mgnc
        inc sp_mrp+1
        clc
@mgnc:  dey
        bne @mgrp
@mgdone: sta sp_mrp
  .endif
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                 ; columns-1
        ; the row loop and the inner blocks are assembled into each sprite data bank
        ; (SPRITE_LOOPS below): call the copy in the bank the directory named, through
        ; low RAM's direct switch (both banks enter at BANKENTRY) and back to this bank
        lda sp_dbank
        jmp callbank
        .segment "ENGCODE"          ; bank 7 drives the frame and keeps the records; bank
render_core:                        ; 6 gets two fixed calls a frame (low RAM's selbb and
        jsr selbb                   ; validate) and the rects through callbank
        jsr calc_ring
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
; dirty tiles: redraw changed map tiles (both buffers keep their own list)
; ============================================================================
        .segment "ENGCODE"          ; bank 7, with the logic that calls it
mark_dirty:                         ; A = tx, X = ty  (adds to both buffers' lists)
        sta tmp
        stx tmp2
        ldx #1
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
@over:  lda #$80                    ; the list is full: that buffer is redrawn whole
        sta BUF_CXH,x               ; instead (an unreachable window x; match_sprites
                                    ; drops its records, scroll_validate redraws it)
        bne @next                   ; (always)

; sign extend A -> tmp3 (0 or $FF)
        .segment "ENGCODE"          ; (its one caller is the sprite prologue: bank 7)
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

        .segment "ENGCODE"          ; bank 7 (drawrect_clip through callbank)
draw_dirty:
        ldx curbuf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
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
        lda #4
        sta rc_w
        lsr                         ; 4 >> 1 = 2
        sta rc_h
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is drawrect_clip
        jsr callbank
        dec lcnt
        bne @l
        ldx curbuf
        stz DIRTYCNT,x              ; A is dead: both callers reload it at once
@done:  rts

; ============================================================================
; blank_below: the 6845 always displays the first scanline of a frame, whatever R6
; says, so the blanking section's row 0 line 0 -- the ring slot below the playfield --
; is one line more under the picture.  Elsewhere it is the next map line; parked on
; the map's bottom row it is whatever that never-drawn slot last held.  So when the
; window sits on the bottom row, blank the slot, once per buffer per arrival.
; ============================================================================
        .segment "ENGCODE"          ; bank 7, beside render_core
blank_below:
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
        bne @no
        inc BUF_BOTOK,x
        lda wcx                     ; the row below the playfield: map char row
        sta w16                     ; wcy + VISROWS at the window's column -- rows
        lda wcx+1                   ; are not slot aligned, so this is a run of 80
        sta w16+1                   ; chars that may straddle the ring end
        lda wcy
        adc #VISROWS-1              ; C = 1 from cmp maxwy+1 (equal)
        jsr ringaddr7               ; sp = its ring address
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
        PAD ::PADB_BB, 0            ; (the Model B's bank 7 code ends at the kernel: this
                                    ;  pad places what is above it -- pads.inc)


; render everything queued for the current back buffer and request flip
        .segment "ENGCODE"          ; bank 7, with the game loop
render_frame:
        jsr wait_flip               ; the previous frame's flip must land before this
                                    ; buffer is touched
        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: T starts QROWS-QVSYNC
        ; rows after the vsync wait_flip just returned from (32 lines on the Master,
        ; 64 on the Model B).  Only digits: the template comes with the game's image (the
        ; BAR file) and nothing erases it -- the menus keep to the ring (menu_sections).
        lda BARDIRTY
        beq :+
        jsr hook_hud                ; (the game's: README.md)
  .if BHW
        dec BARDIRTY                ; only ever set to 1: 1 -> 0
  .else
        stz BARDIRTY
  .endif
:
        ; derive char window
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
        lda wy+1                    ; wcy = wy >> 2, a full 16-bit shift: the tall maps
        lsr                         ; go past wy = 512, where shifting the high byte
        sta wcy                     ; once only loses 128 rows
        lda wy
        ror
        lsr wcy
  .if TALLMAP
        ldx wcy                     ; (the high bits: drawrect's map row)
        stx wcyh
  .endif
        ror
        sta wcy
        jsr render_core
        stz NSPR                    ; A dead: build_sections starts ldx/lda
        jsr build_sections
        ; hand over to ISR
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

; spin until any pending flip has been taken by the vsync ISR
wait_flip:
        lda flipreq
        bne wait_flip
        rts

