; ---- inner blocks.  ptr = source column (already offset), sp = screen char,
;      tmp = ra0', tmp2 = ra1'.  Full-res: source byte per line.
.macro SPRLINE k, mirror, copy, solid, blank
        .local done, skip, opaque, masked
.if k = 0
        ldaz ptr                    ; line 0: Y is not needed here
.else
        ldy #k
        lda (ptr),y
.endif
.if copy
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
  .if k = 0
    .if ::BHW
        sta (sp),y                  ; box sprite: Y = 0 still, from ldaz's ldy #0
    .else
        staz sp                     ; box sprite: every byte opaque, plain copy
    .endif
  .else
        sta (sp),y
  .endif
.else
  .if k = 0
        beq done                    ; 0: both game pixels transparent, no store
        bpl masked                  ; (N from the load: cmp would set it from the subtraction)
        cmp #$C0
        bcc opaque                  ; bit7 alone: single opaque byte
        jmp solid                   ; bit 7+6: this and the next 7 bytes all opaque
masked: cmp #$41                    ; and the mirror image of that: this and the next 7
        beq blank                   ; all transparent, so the cell is left alone
  .else
        bmi opaque                  ; bit 7: both game pixels opaque (see encode_sprite).  Tested
        beq done                    ; before the transparent case because the sprite data is
                                    ; 45.7% opaque against 24.1% transparent, and both read
                                    ; the same load's flags -- $00 is never negative
        cmp #$41                    ; a blank-run tag reached below line 0 (the packer marks
        bne :+                      ; every line a run covers): the rest of this cell is all
        jmp blank                   ; transparent, so skip it -- $41 else draws a stray game pixel
:
  .endif
        tax
  .if mirror
        lda MASKTAB+$80,x           ; mask of the mirrored byte (MASKTAB[SWAPTAB[x]])
  .else
        lda MASKTAB,x
  .endif
  .if k = 0
        andz sp
  .else
        and (sp),y
  .endif
  .if mirror
        ora IDENT+$80,x             ; the mirrored byte's OR value (IDENT[SWAPTAB[x]])
  .else
        ora IDENT,x
  .endif
  .if mirror
        jmp skip                    ; only the mirrored form has anything at 'opaque' to
  .endif                            ; jump over; unmirrored, this branched to the next
opaque:                             ; instruction, 3 cycles on every masked byte
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
skip:
  .if k = 0
        staz sp
  .else
        sta (sp),y
  .endif
done:
.endif
.endmacro

.macro SOLID1 k
        ldy #k
        lda (ptr),y
        sta (sp),y
.endmacro
.macro SOLIDM k                     ; mirrored: nibble swap through the table
.if k > 0
        ldy #k
        lda (ptr),y
.endif
        tax
        lda SWAPTAB,x
.if k = 0
        staz sp
.else
        sta (sp),y
.endif
.endmacro

.macro SPRFULL name, mirror, copy
        .local partial, et, l0, l1, l2, l3, l4, l5, l6, l7, pl, ps, po, pd, solid, blank
.if .not copy
solid:  ; byte 0 carried the RUN flag: the whole cell is opaque, straight copy
.if mirror
        SOLIDM 0
        SOLIDM 1
        SOLIDM 2
        SOLIDM 3
        SOLIDM 4
        SOLIDM 5
        SOLIDM 6
        SOLIDM 7
        jmp sprretM
.else
        staz sp                     ; A = byte 0
        ldy #1
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        jmp sprretP
.endif
.endif
name:
        lda tmp2
        cmp #7
  .if copy
        bne partial                 ; in reach: the copy form's lines are short
  .else
        bne @np
  .endif
        lda tmp
        beq l0                      ; the whole cell: the overwhelmingly common case, and
        asl                         ; it needs no table at all (the table's dispatch is
        tax                         ; 21 cycles to reach the same place)
  .if ::BHW
        lda et-2,x                  ; jmpx without its pha/pla: A is dead at l1..l7
        sta jv
        lda et-1,x
        sta jv+1
        jmp (jv)
  .else
        jmpx et-2                   ; X = 2..14: l0 is reached by the beq, not the table
  .endif
  .if .not copy
@np:    jmp partial
  .endif
et:     .word l1,l2,l3,l4,l5,l6,l7
.if .not copy
blank:  ; byte 0 was $41: the whole cell is transparent, so there is nothing to do
.if mirror
        jmp sprretM
.else
        jmp sprretP
.endif
.endif
l0:     SPRLINE 0, mirror, copy, solid, blank
l1:     SPRLINE 1, mirror, copy, solid, blank
l2:     SPRLINE 2, mirror, copy, solid, blank
l3:     SPRLINE 3, mirror, copy, solid, blank
l4:     SPRLINE 4, mirror, copy, solid, blank
l5:     SPRLINE 5, mirror, copy, solid, blank
l6:     SPRLINE 6, mirror, copy, solid, blank
l7:     SPRLINE 7, mirror, copy, solid, blank
pd:                                 ; l7's exit, and the partial loop's
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
partial:
        ldy tmp
.if copy
pl:     lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.else
pl:     lda (ptr),y
        bmi po                      ; bit 7: both game pixels opaque.  Tested before the
        beq ps                      ; transparent case for the same reason SPRLINE does
                                    ; it -- 45.7% opaque against 24.1% transparent, and
                                    ; both read this load's flags ($00 is never negative)
        cmp #$41
        beq pd
        tax
.if mirror
        lda MASKTAB+$80,x
        and (sp),y
        ora IDENT+$80,x
.else
        lda MASKTAB,x
        and (sp),y
        ora IDENT,x
.endif
        sta (sp),y
        jmp ps
po:
.if mirror
        tax
        lda SWAPTAB,x
.endif
        sta (sp),y
.endif
ps:     cpy tmp2
        beq pd
        iny                         ; Y < tmp2 <= 6: never wraps to 0
        bne pl
.endmacro

; ---- MODE 1 masked blitter.  A col entry has no spare bit, so the mask is a plane of
; its own: one bit per game pixel, a data byte's two game pixels as a 2-bit pair, four
; horizontally adjacent columns packed into one byte (column 4g+j in bits 7-2j, 6-2j),
; column-group-major: for group g, one byte per game-pixel row -- the shape of the data, so
; mptr walks like ptr.  MASKTAB0..3 turn a whole mask byte into the AND mask for the
; column of that phase, no shifting: $FF (both transparent) $CC $33 $00 (both opaque).
; The two scanlines of a game-pixel row share a mask, so lines go in pairs, and a sprite's
; first line in a cell is always even (refy is a multiple of 4 game px).  The data has
; 0 in transparent game pixels, so screen = (screen AND mask) OR data.  Mirrored: the pair's
; mask is SWAPTAB of the table's answer ($33 <-> $CC), and the data byte is swapped.
.macro MLINE mirror                 ; masked store of line Y
  .if mirror
        lda (ptr),y
        tax
        lda SWAPTAB,x
        sta sp_ext                  ; dead during the blit
        lda (sp),y
        and sp_msk
        ora sp_ext
  .else
        lda (sp),y
        and sp_msk
        ora (ptr),y
  .endif
        sta (sp),y
.endmacro
.macro CLINE mirror                 ; plain store of line Y
        lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.endmacro
.macro MPAIR k, mirror              ; lines k, k+1 of the cell
        .local opq, done
  .if k = 0
        ldaz mptr                   ; (Master: lda (mptr); the tay reloads Y)
  .else
        ldy #k/2
        lda (mptr),y
  .endif
        tay
        lda (mtab),y
        beq opq                     ; $00: both game pixels opaque, plain stores
        cmp #$FF
        beq done                    ; both transparent
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy #k
        MLINE mirror
        iny
        MLINE mirror
        bcc done                    ; C = 0: the cmp #$FF above was not equal
opq:    ldy #k
        CLINE mirror
        iny
        CLINE mirror
done:
.endmacro
.macro SPRMSK name, mirror
        .local partial, et, p0, p1, p2, p3, p2j, pl, pop, pnext
partial:                            ; lines tmp..tmp2: tmp even, tmp2 odd (above name, so
        lda tmp                     ; name's bne reaches it)
        sta sp_lim
pl:     lsr                         ; A = sp_lim on both ways in
        tay
        lda (mptr),y
        tay
        lda (mtab),y
        beq pop
        cmp #$FF
        beq pnext
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy sp_lim
        MLINE mirror
        iny
        MLINE mirror
        bcc pnext                   ; C = 0: the cmp #$FF above was not equal
pop:    ldy sp_lim
        CLINE mirror
        iny
        CLINE mirror
pnext:
        lda sp_lim
        clc                         ; (the carry is dead: the cmp follows)
        adc #2
        sta sp_lim
        cmp tmp2
        bcc pl
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
name:
        lda tmp2
        cmp #7
        bne partial
        lda tmp                     ; even: 0,2,4,6 -> entry p0..p3
        beq p0
        cmp #4
        bcc p1
  .if mirror
        beq p2j
        jmp p3
p2j:    jmp p2
  .else
        beq p2
        jmp p3
  .endif
p0:     MPAIR 0, mirror
p1:     MPAIR 2, mirror
p2:     MPAIR 4, mirror
p3:     MPAIR 6, mirror
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
.endmacro
; The row loop and the inner blocks, assembled once into EACH sprite data bank (the
; loop reads image bytes, so it must be resident with them) and reached through
; callbank from the prologue, which lives with the directory in bank 7.
.macro SPRITE_LOOPS withmirror, withcopy, bank   ; withmirror = 0: no mirrored blitter
                                    ; (the bank has no SWAPTAB); withcopy = 0: none drawn
                                    ; by the copy blitter (no sprFC); bank: this copy's
ds_entry:                           ; BANKENTRY: the dispatch jump is patched here,
        wrsel bank, bank            ; in the bank that owns it: a write window (A = the
        ldx sp_disp                 ; bank), closed by the wrback below
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
        wrback bank                 ; (the window's end: the write bank back to 7's)
ds_rowloop:
        lda sp_rb
        sta sp
        lda sp_rb+1
        sta sp+1
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
        lda sp_mrp
        sta mptr
        lda sp_mrp+1
        sta mptr+1
        lda sp_mpg0
        sta mtab+1
        ; ra range for this row
        stz tmp                     ; ra0' = 0 unless this is the first row
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
        stx tmp
:       ldx #7
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite
  .if withmirror
sprretMk:                           ; mask blitter, mirrored: the image column descends,
        dec mtab+1                  ; so the phase (= page & 3) does too; below phase 0
        lda mtab+1                  ; it is the previous group's phase 3
        cmp #>(MASKTAB0-$100)       ; (mtab+1 stays in MASKTAB0..3: only below 0 wraps)
        bne @mk
        lda #>MASKTAB3
        sta mtab+1
        lda mptr                    ; C = 1 from the cmp (equal)
        sbc sp_mh
        sta mptr
        bcs @mk
        dec mptr+1
@mk:
sprretM:                            ; next column, mirrored: source pointer - lines
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcs sprnext
        dec ptr+1
        bcc sprnext                 ; C = 0: the bcs was not taken
  .endif
sprretPk:                           ; mask blitter: next phase is the next page; past
        inc mtab+1                  ; phase 3 it is the next group's phase 0
        lda mtab+1
        and #3
        bne @pk
        lda #>MASKTAB0              ; past MASKTAB3: back to MASKTAB0
        sta mtab+1
        lda mptr
        clc
        adc sp_mh
        sta mptr
        bcs sprmpc                  ; (out of line, after ds_done)
@pk:
sprretP:                            ; next column: source pointer + lines
        lda ptr
        clc
        adc sp_lines
        sta ptr
        bcs sprpinc                 ; (the carries out of line, after ds_done: the
sprnext:                            ;  common case falls through)
        spnext sprscold
sprsback:
        dec sp_cnt
        bpl ds_colloop
        SAMEPAGE *, ds_colloop
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        lda sp_rp                   ; C = 0: sp_row < sp_r1 (the rows count up to it)
        adc sp_rinc
        sta sp_rp
        bcc :+
        inc sp_rp+1
        clc
:
        lda sp_mrp
        adc #4                      ; C is clear
        sta sp_mrp
        bcc @mrnc
        inc sp_mrp+1
        clc
@mrnc:
        lda sp_rb
        adc #<ROWBYTES
        sta sp_rb
        lda sp_rb+1
        adc #>ROWBYTES
        ringup sp_rb
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts
        ; the pointers' carries are here; the page fold (1 column in 32) is a way out, in
        ; its branch's reach, with the fold itself and the dispatch table after the
        ; blitters, so that the hot blitters sit where their branches cross no page
        ; boundary (tools/pagecheck.py)
sprpinc: inc ptr+1
        jmp sprnext
sprmpc: inc mptr+1
        jmp sprretP
sprscold: jmp sprscold2
  .if bank = ::BANK_SPR
        PAD 0, ::PADM_FN4
  .else
        PAD 0, ::PADM_FN5
  .endif
        SPRMSK sprFN, 0
  .if withmirror
        PAD 0, ::PADM_FM4
        SPRMSK sprFM, 1
  .endif
sprscold2:
        spcold sprsback
  .if withmirror
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM
  .else
sprdisp_tab: .word sprFN, sprFN, sprFN, sprFN
  .endif
  .if withcopy
        .word sprFC
  .else
        .word sprFN
  .endif
.endmacro
; ---- 4-bit sprites (NIBSPR).  A stored column is a byte a game-pixel row: its two
; game pixels, 4 bits each, of one palette the game chooses (nibble 0 transparent).
; The two scanlines of the row come out of L0TAB and L1TAB (the game's), and NMASK
; is the AND mask for the byte's transparent game pixels: $00 both opaque (plain
; stores), $CC or $33 for one; a byte of 0 is both transparent and draws nothing.  So
; screen = (screen AND NMASK[b]) OR Ln[b].  Mirrored, the dots of every result are
; reversed through SWAPTAB, the mask's too.  The directory's lines byte is the rows
; stored (flag bit 1 clear: the prologue's half-res arithmetic, two scanlines a
; byte), and a sprite's first line in a char is always even (lb0 = 2*sy + wfine).
; Every bank that holds sprites has the tables and both blitters (banks.s): no box,
; a box (flag bit 3) is its screen bytes, every scanline, drawn by the copy blitter
; (NIBCOPY: its flag's dispatch entry), so a box's backdrop keeps any dither exactly.
.macro NPAIR k, mirror              ; lines k, k+1 of the cell: source byte k/2
        .local opq, done
  .if k = 0
        ldaz ptr
  .else
        ldy #k/2
        lda (ptr),y
  .endif
        beq done                    ; both transparent
        tax
        lda NMASK,x
        beq opq                     ; both opaque: plain stores
  .if mirror
        tay
        lda SWAPTAB,y
  .endif
        sta sp_msk
        ldy #k
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L0TAB,x                 ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy #k
  .else
        ora L0TAB,x
  .endif
        sta (sp),y
        iny
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L1TAB,x
        ora SWAPTAB,y
        ldy #k+1
  .else
        ora L1TAB,x
  .endif
        sta (sp),y
        jmp done
opq:
  .if mirror
        ldy L0TAB,x
        lda SWAPTAB,y
        ldy #k
        sta (sp),y
        ldy L1TAB,x
        lda SWAPTAB,y
        ldy #k+1
        sta (sp),y
  .else
        ldy #k
        lda L0TAB,x
        sta (sp),y
        iny
        lda L1TAB,x
        sta (sp),y
  .endif
done:
.endmacro
.macro NIBBLIT name, mirror, ret
        .local partial, et, p0, p1, p2, p3, pl, pop, pnext
partial:                            ; lines tmp..tmp2: tmp even, tmp2 odd (above name, so
        lda tmp                     ; name's bne reaches it)
        sta sp_lim
pl:     lsr                         ; A = sp_lim on both ways in
        tay
        lda (ptr),y
        beq pnext
        tax
        lda NMASK,x
        beq pop
  .if mirror
        tay
        lda SWAPTAB,y
  .endif
        sta sp_msk
        ldy sp_lim
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L0TAB,x
        ora SWAPTAB,y
        ldy sp_lim
  .else
        ora L0TAB,x
  .endif
        sta (sp),y
        iny
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L1TAB,x
        ora SWAPTAB,y
        ldy sp_lim
        iny
  .else
        ora L1TAB,x
  .endif
        sta (sp),y
        jmp pnext
pop:
  .if mirror
        ldy L0TAB,x
        lda SWAPTAB,y
        ldy sp_lim
        sta (sp),y
        ldy L1TAB,x
        lda SWAPTAB,y
        ldy sp_lim
        iny
        sta (sp),y
  .else
        ldy sp_lim
        lda L0TAB,x
        sta (sp),y
        iny
        lda L1TAB,x
        sta (sp),y
  .endif
pnext:  lda sp_lim
        clc
        adc #2
        sta sp_lim
        cmp tmp2
        bcc pl
        jmp ret
name:
        lda tmp2
        cmp #7
        bne partial
        lda tmp                     ; even: 0, 2, 4, 6 -> p0..p3
        beq p0
        tax
        jmpx et
et:     .word p0, p1, p2, p3
p0:     NPAIR 0, mirror
p1:     NPAIR 2, mirror
p2:     NPAIR 4, mirror
p3:     NPAIR 6, mirror
        jmp ret
.endmacro
.macro NIBCOPY name, ret            ; a box (flag bit 3): every scanline stored, screen bytes,
        .local part, pl             ; opaque -- a straight copy, lines tmp..tmp2 of the cell
name:   lda tmp2                    ; (any first line: a box's rows need not pair)
        cmp #7
        bne part
        lda tmp
        bne part
  .repeat 8, k                      ; a whole cell: 13 cycles a byte against the 4-bit
        ldy #k                      ; blitter's 21
        lda (ptr),y
        sta (sp),y
  .endrepeat
        jmp ret
part:   ldy tmp
pl:     lda (ptr),y
        sta (sp),y
        cpy tmp2                    ; C = 1 at the last line (iny keeps C)
        iny
        bcc pl
        jmp ret
.endmacro
.macro NIB_LOOPS bank               ; the row loop and all three blitters, in each sprite bank
ds_entry:                           ; BANKENTRY: the dispatch jump is patched here, in
        wrsel bank, bank            ; the bank that owns it: a write window (A = the bank)
        ldx sp_disp
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
        wrback bank                 ; (the window's end: the write bank back to 7's)
ds_rowloop:
        lda sp_rb
        sta sp
        lda sp_rb+1
        sta sp+1
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
        stz tmp                     ; ra0' = 0 unless this is the first row
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
        stx tmp
:       ldx #7
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite
sprretM:                            ; next column, mirrored: source pointer - rows
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcs sprnext
        dec ptr+1
        bcc sprnext                 ; C = 0: the bcs was not taken
sprretP:                            ; next column: source pointer + rows
        lda ptr
        clc
        adc sp_lines
        sta ptr
        bcs sprpinc                 ; (the carry out of line: the common case falls through)
sprnext:
        spnext sprscold
sprsback:
        dec sp_cnt
        bpl ds_colloop
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        lda sp_rp                   ; C = 0: sp_row < sp_r1
        adc sp_rinc
        sta sp_rp
        bcc :+
        inc sp_rp+1
        clc
:       lda sp_rb
        adc #<ROWBYTES
        sta sp_rb
        lda sp_rb+1
        adc #>ROWBYTES
        ringup sp_rb
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts
sprpinc: inc ptr+1
        jmp sprnext
sprscold: jmp sprscold2
        NIBBLIT sprFN, 0, sprretP
        NIBBLIT sprFM, 1, sprretM
        NIBCOPY sprFC, sprretP
sprscold2:
        spcold sprsback
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM, sprFC
.endmacro
        .segment "SPR4CODE"
        .scope spr4
  .if ::NIBSPR
        NIB_LOOPS ::BANK_SPR
  .else
        SPRITE_LOOPS 1, ::SPR4_COPY, ::BANK_SPR   ; (assets.inc: the packer puts the box stars in one
        .if ::SPR4_COPY             ;  bank and no mirrored image in the other)
        SPRFULL sprFC, 0, 1
        .endif
  .endif
        .endscope
        .assert spr4::ds_entry = BANKENTRY, error, "bank 4's row loop must start the bank"
  .if BHW                           ; (the Master's is shorter: its gap is the price of
        .assert * = B4_CODE_END, error, "bank 4's code must end where its sprites start: set B4_CODE_END in the game's assets.inc"
  .else                             ;  level files both machines read)
        .assert * <= B4_CODE_END, error, "bank 4's code runs into its sprites: B4_CODE_END in the game's assets.inc"
  .endif
        .segment "SPR5CODE"
        .scope spr5
  .if ::NIBSPR
        NIB_LOOPS ::BANK_TIL1
  .else
        SPRITE_LOOPS ::SPR5_MIRROR, 1, ::BANK_TIL1
        PAD 0, ::PADM_FC5
        SPRFULL sprFC, 0, 1
  .endif
        .endscope
        .assert spr5::ds_entry = BANKENTRY, error, "bank 5's row loop must start the bank"
        .segment "TILCODE"     

; Every image is full-res, so entries 0/1 of sprdisp_tab (the half-res flag clear)
; alias the full blitters: the flag bit is vestigial.



