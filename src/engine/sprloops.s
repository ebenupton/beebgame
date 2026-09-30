; ============================================================================
; engine/sprloops.s -- the sprite row loops and blitters, in each sprite bank
;
; The row loop reads the image bytes, so it must be resident with them: it is
; assembled once into EACH sprite data bank, bank 4 (SPR4CODE) and bank 5 (SPR5CODE),
; each copy starting its bank at BANKENTRY ($8000).  Both machines.  The prologue,
; drawsprite (frame.s, bank 7, with the directory), clips the sprite and sets up the
; zero page, then enters the copy in the bank the image is in through low RAM's
; callbank (low.s), which returns to bank 7 after it.
;
; Which format: the build's NIBSPR (cpu.inc).  NIBSPR = 1 assembles NIB_LOOPS, the
; 4-bit sprites (a byte a game-pixel row, turned into screen bytes by tables).
; NIBSPR = 0 assembles SPRITE_LOOPS, the MODE 1 masked sprites (screen bytes and a
; separate mask plane), with SPRFULL's copy blitter for boxes.  Each section below
; says how its format is laid out.
;
; The shape, the same in both:
;   ds_entry     patches ds_dispatch's jmp with the sprite's blitter: sprdisp_tab
;                indexed by sp_disp (the prologue's, from the directory's flags).  The
;                jmp is in this bank, so the store is a write window (cpu.inc: wrsel
;                ... wrback; empty on the Master).
;   ds_rowloop   a character row, sp_r0..sp_r1: sp = the row's first char (sp_rb),
;                ptr = its source (sp_rp); tmp..tmp2 = the lines of the cell to draw,
;                0..7 but sp_ra0 on the first row and sp_ra1 on the last.
;   ds_colloop   a column, sp_ncol+1 of them: jmp to the blitter (ds_dispatch), which
;                draws lines tmp..tmp2 of the char at sp and jumps back to a column
;                step -- sprretP (ptr + sp_lines) or sprretM (mirrored: ptr - sp_lines),
;                with the masked format's mask walk before them (sprretPk, sprretMk)
;                -- then sp to the next char (spnext, its page step out of line).
;   ds_rowdone   the next row: sp_rp + sp_rinc, sp_rb + ROWBYTES folded at the ring's
;                end; rts at ds_done.
;
; Macros:
;   SPRLINE, SOLID1, SOLIDM, SPRFULL   the full-res blitter; only its copy form (sprFC,
;                                      the masked build's box blitter) is assembled
;   MLINE, CLINE, MPAIR, SPRMSK        the masked blitter (sprFN, sprFM)
;   SPRITE_LOOPS                       the masked build's row loop and blitters
;   NPAIR, NIBBLIT, NIBCOPY            the 4-bit blitter (sprFN, sprFM) and the copy
;                                      blitter (sprFC)
;   NIB_LOOPS                          the 4-bit build's row loop and blitters
; Then the two copies: SPR4CODE (bank 4) and SPR5CODE (bank 5).
; ============================================================================

; ============================================================================
; The full-res blitter (SPRFULL), and its blocks
;
; In this tree only the copy form is instantiated (SPRFULL sprFC, 0, 1: the masked
; build's box blitter, a straight copy of the cell's lines).  The masked form
; (copy = 0) reads a tagged format -- a source byte per line, its tags below -- and
; needs MASKTAB and IDENT, which nothing here defines.
;
; Common to the blocks: ptr = the source column (already offset), sp = the screen
; char, tmp = ra0' (the first line to draw), tmp2 = ra1' (the last).
; ============================================================================

; ----------------------------------------------------------------------------
; SPRLINE k, mirror, copy, solid, blank: line k of the cell
;   k      0..7;  mirror  1 = through SWAPTAB;  copy  1 = a plain copy
;   solid, blank  the tagged form's exits for a line-0 run tag (SPRFULL's labels)
;   Out:   A, Y clobbered (and X, masked or mirrored);  falls out at its end
; The tagged form's byte, tested in this order:
;   bit 7 set      both game pixels opaque (see encode_sprite): stored as it is.
;                  Tested before the transparent case because the sprite data is
;                  45.7% opaque against 24.1% transparent, and both read the same
;                  load's flags -- $00 is never negative
;   $00            both transparent: no store
;   $41            a blank-run tag: the rest of the cell is transparent (the packer
;                  marks every line a run covers); drawn, $41 would be a stray pixel
;   else           masked: (screen AND MASKTAB[b]) OR IDENT[b]
; Line 0 alone: bits 7 and 6 set is a solid run (this and the next 7 bytes all opaque:
; `solid`), and $41 blanks the whole cell (`blank`).
; ----------------------------------------------------------------------------
.macro SPRLINE k, mirror, copy, solid, blank
        .local done, skip, opaque, masked
.if k = 0
        ldaz ptr                    ; line 0: Y is not needed here
.else
        ldy #k
        lda (ptr),y
.endif

; ---- copy form: store the byte (mirrored through SWAPTAB)
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

; ---- tagged form
.else
  .if k = 0
        beq done                    ; 0: both game pixels transparent, no store
        bpl masked                  ; N from the load (a cmp's N is the subtraction's)
        cmp #$C0
        bcc opaque                  ; bit 7 alone: a single opaque byte
        jmp solid                   ; bits 7+6: this and the next 7 bytes all opaque
masked: cmp #$41                    ; the mirror image of that: this and the next 7 all
        beq blank                   ; transparent, so the cell is left alone
  .else
        bmi opaque                  ; bit 7: both game pixels opaque (see above)
        beq done                    ; $00: both transparent ($00 is never negative)
        cmp #$41                    ; a blank-run tag reached below line 0:
        bne :+
        jmp blank                   ; the rest of this cell is transparent: skip it
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
  ; Only the mirrored form has anything at 'opaque' to jump over; unmirrored, this
  ; jmp branched to the next instruction, 3 cycles on every masked byte.
  .if mirror
        jmp skip
  .endif
opaque:
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

; ----------------------------------------------------------------------------
; SOLID1 k: line k copied as it is (not used)
; SOLIDM k: line k copied, mirrored: nibble swap through the table (the solid run's
;           lines).  k = 0 takes the byte in A.
;   Out:   A, X, Y clobbered
; ----------------------------------------------------------------------------
.macro SOLID1 k
        ldy #k
        lda (ptr),y
        sta (sp),y
.endmacro
.macro SOLIDM k
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

; ----------------------------------------------------------------------------
; SPRFULL name, mirror, copy: the full-res blitter for one column of a char row
;   name   the entry label (sprFC);  mirror  1 = through SWAPTAB;  copy  1 = plain copy
;   In:    ptr, sp, lines tmp..tmp2 of the cell (any first line)
;   Out:   A, X, Y clobbered.  Returns to sprretP (sprretM mirrored)
; A whole cell (tmp2 = 7) goes into the unrolled lines l0..l7 at line tmp; anything
; else runs the partial loop.  The tagged form also has the whole-cell exits: solid
; (a run tag in byte 0: the cell copied) and blank (nothing to do).
; ----------------------------------------------------------------------------
.macro SPRFULL name, mirror, copy
        .local partial, et, l0, l1, l2, l3, l4, l5, l6, l7, pl, ps, po, pd, solid, blank

; ---- solid (tagged form): byte 0 carried the RUN flag, so the whole cell is opaque:
; a straight copy
.if .not copy
solid:
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

; ---- the entry: the whole cell from line tmp, or part of one
name:
        lda tmp2
        cmp #7
  .if copy
        bne partial                 ; in reach: the copy form's lines are short
  .else
        bne @np
  .endif
        lda tmp
        beq l0                      ; the whole cell: the overwhelmingly common case
        ; Otherwise into l1..l7 by the table.  The whole cell needs no table at all
        ; (the table's dispatch is 21 cycles to reach the same place).
        asl
        tax
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

; ---- blank (tagged form): byte 0 was $41, the whole cell transparent: nothing to do
.if .not copy
blank:
.if mirror
        jmp sprretM
.else
        jmp sprretP
.endif
.endif

; ---- the whole cell, from line tmp
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

; ---- part of a cell: lines tmp..tmp2 (tmp2 <= 6)
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
; The tagged form: the tests in SPRLINE's order, for the same reason -- 45.7% opaque
; against 24.1% transparent, and both read this load's flags ($00 is never negative).
pl:     lda (ptr),y
        bmi po                      ; bit 7: both game pixels opaque
        beq ps                      ; $00: both transparent
        cmp #$41
        beq pd                      ; blank-run tag: the rest of the cell is transparent
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
; ============================================================================
; The MODE 1 masked sprites (NIBSPR = 0)
;
; A column entry (a data byte) has no spare bit, so the mask is a plane of its own:
;   - one bit per game pixel, a data byte's two game pixels as a 2-bit pair;
;   - four horizontally adjacent columns packed into one byte (column 4g+j in bits
;     7-2j, 6-2j);
;   - column-group-major: for group g, one byte per game-pixel row -- the shape of the
;     data, so mptr walks like ptr.
; MASKTAB0..3 turn a whole mask byte into the AND mask for the column of that phase,
; no shifting: $FF (both transparent), $CC, $33, $00 (both opaque).  mtab is the
; phase's page (low byte 0), indexed by the mask byte.
;
; The two scanlines of a game-pixel row share a mask, so lines go in pairs, and a
; sprite's first line in a cell is always even (refy is a multiple of 4 game px).  The
; data has 0 in transparent game pixels, so
;   screen = (screen AND mask) OR data
; Mirrored: the pair's mask is SWAPTAB of the table's answer ($33 <-> $CC), and the
; data byte is swapped.
; ============================================================================

; ----------------------------------------------------------------------------
; MLINE mirror: the masked store of line Y
;   In:   Y = the line, ptr, sp, sp_msk = the pair's AND mask
;   Out:  A clobbered (and X, and sp_ext, mirrored);  Y kept
; ----------------------------------------------------------------------------
.macro MLINE mirror
  .if mirror
        lda (ptr),y
        tax
        lda SWAPTAB,x
        sta sp_ext                  ; sp_ext is dead during the blit
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

; ----------------------------------------------------------------------------
; CLINE mirror: the plain store of line Y (both game pixels opaque)
;   In:   Y = the line, ptr, sp
;   Out:  A clobbered (and X, mirrored);  Y kept
; ----------------------------------------------------------------------------
.macro CLINE mirror
        lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.endmacro

; ----------------------------------------------------------------------------
; MPAIR k, mirror: lines k and k+1 of the cell, under mask byte k/2
;   k     0, 2, 4, 6;  mirror  1 = through SWAPTAB
;   In:   ptr, sp, mptr = the column group's mask bytes, mtab = the phase's MASKTAB
;   Out:  A, Y clobbered (and X, mirrored);  sp_msk written
; Falls out at its end: the unrolled cell is four of these in a row.
; ----------------------------------------------------------------------------
.macro MPAIR k, mirror
        .local opq, done
  .if k = 0
        ldaz mptr                   ; (Master: lda (mptr); the tay reloads Y)
  .else
        ldy #k/2
        lda (mptr),y
  .endif
        tay
        lda (mtab),y                ; the AND mask for this column's phase
        beq opq                     ; $00: both game pixels opaque, plain stores
        cmp #$FF
        beq done                    ; $FF: both transparent
  .if mirror
        tax
        lda SWAPTAB,x               ; the mask, mirrored
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

; ----------------------------------------------------------------------------
; SPRMSK name, mirror: the masked blitter for one column of a char row
;   name  the entry label (sprFN, sprFM);  mirror  1 = through SWAPTAB
;   In:   ptr, sp, mptr, mtab as MPAIR;  lines tmp..tmp2 of the cell (tmp even,
;         tmp2 odd)
;   Out:  A, X, Y clobbered;  sp_msk, sp_lim written.  Returns to sprretPk
;         (sprretMk mirrored)
; A whole cell (tmp2 = 7) goes into the unrolled pairs p0..p3 at the pair tmp names;
; anything else runs the partial loop, a pair at a time, with sp_lim the pair's line.
; ----------------------------------------------------------------------------
.macro SPRMSK name, mirror
        .local partial, et, p0, p1, p2, p3, p2j, pl, pop, pnext

; ---- part of a cell: lines tmp..tmp2 (above name, so name's bne reaches it)
partial:
        lda tmp
        sta sp_lim
pl:     lsr                         ; A = sp_lim on both ways in: the pair's mask byte
        tay
        lda (mptr),y
        tay
        lda (mtab),y
        beq pop                     ; $00: both opaque
        cmp #$FF
        beq pnext                   ; $FF: both transparent
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
pnext:                              ; the next pair, until past tmp2
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

; ---- the entry: a whole cell, or part of one
name:
        lda tmp2
        cmp #7
        bne partial
        lda tmp                     ; even: 0,2,4,6 -> entry p0..p3
        beq p0
        cmp #4
        bcc p1
  .if mirror                        ; (p2 by a jmp)
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
; ============================================================================
; SPRITE_LOOPS withmirror, withcopy, bank: the masked build's row loop and blitters
;   withmirror  0: no mirrored blitter (the bank has no SWAPTAB)
;   withcopy    0: no sprite in the bank is drawn by the copy blitter (no sprFC)
;   bank        this copy's bank (BANK_SPR or BANK_TIL1): the write window's
; Emits ds_entry (which must be BANKENTRY), the row and column loops, the column
; steps (sprretPk / sprretMk for the mask walk, falling into sprretP / sprretM), and
; the masked blitters sprFN and sprFM (SPRMSK), then sprdisp_tab.  The copy blitter
; sprFC is SPRFULL's, assembled after this where the bank has one.  The shape: see the
; file header.
; ============================================================================
.macro SPRITE_LOOPS withmirror, withcopy, bank

; ---- ds_entry: patch the dispatch jump for this sprite (X = sp_disp)
; The jump is in this bank, so the store is a write window (cpu.inc): wrsel opens it
; (A = the bank, from callbank), wrback closes it, the write bank back to 7's.
; Master: both empty.
ds_entry:                           ; BANKENTRY
        wrsel bank, bank
        ldx sp_disp
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
        wrback bank

; ---- a character row: sp = its first char, ptr = its source bytes, mptr its mask
; bytes, mtab+1 the first column's MASKTAB page, tmp..tmp2 its lines
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
        ; the line range for this row
        stz tmp                     ; ra0' = 0 unless this is the first row
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
        stx tmp
:       ldx #7                      ; ra1' = 7 unless this is the last row
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)

; ---- a column: the blitter, which returns to one of the steps below
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite (ds_entry)

; ---- the column steps: the mask walk, ptr to the next image column, sp to the next char
  .if withmirror
; Mask blitter, mirrored: the image column descends, so the phase (= page & 3) does
; too; below phase 0 it is the previous group's phase 3.  mtab+1 stays in MASKTAB0..3:
; only below 0 wraps.
sprretMk:
        dec mtab+1
        lda mtab+1
        cmp #>(MASKTAB0-$100)
        bne @mk
        lda #>MASKTAB3              ; below phase 0: phase 3 ...
        sta mtab+1
        lda mptr                    ; ... of the previous group.  C = 1 from the cmp (equal)
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
; Mask blitter: the next phase is the next page; past phase 3 it is the next group's
; phase 0.
sprretPk:
        inc mtab+1
        lda mtab+1
        and #3
        bne @pk
        lda #>MASKTAB0              ; past MASKTAB3: back to MASKTAB0 ...
        sta mtab+1
        lda mptr                    ; ... of the next group
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
        bcs sprpinc                 ; the carry is out of line, after ds_done
sprnext:                            ; (the common case falls through)
        spnext sprscold
sprsback:
        dec sp_cnt
        bpl ds_colloop
        SAMEPAGE *, ds_colloop

; ---- the row's end: the next row's source (+ sp_rinc), mask (+ 4 game-pixel rows)
; and screen (+ ROWBYTES)
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
        ringup sp_rb                ; folded at the ring's end
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts

; ---- out of line.  The pointers' carries are here; the page fold (1 column in 32) is
; a way out, in its branch's reach, with the fold itself and the dispatch table after
; the blitters, so that the hot blitters sit where their branches cross no page
; boundary (tools/pagecheck.py).
sprpinc: inc ptr+1
        jmp sprnext
sprmpc: inc mptr+1
        jmp sprretP
sprscold: jmp sprscold2

; ---- the blitters, each padded (Master only: PAD's first argument, the Model B's, is
; 0) off a page boundary
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

; ---- the dispatch table, by sp_disp (the prologue's): (flags & 3) * 2, or 8 for a box
; Every image is full-res, so entries 0/1 of sprdisp_tab (the half-res flag clear)
; alias the full blitters: the flag bit is vestigial.  Without a mirrored blitter the
; mirrored entries are sprFN; without a copy blitter the box entry is.
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
; ============================================================================
; The 4-bit sprites (NIBSPR)
;
; A stored column is one byte a game-pixel row: its two game pixels, 4 bits each, of
; one palette the game chooses (nibble 0 transparent).  Three tables, the game's
; (nibtab.bin), turn the byte b into screen bytes:
;   L0TAB[b], L1TAB[b]  the row's two scanlines
;   NMASK[b]            the AND mask for its transparent game pixels: $00 both opaque
;                       (plain stores), $CC or $33 for one
; A byte of 0 is both transparent and draws nothing.  Otherwise
;   screen = (screen AND NMASK[b]) OR Ln[b]
; Mirrored, the dots of every result are reversed through SWAPTAB, the mask's too.
;
; The directory's lines byte is the rows stored (flag bit 1 clear: the prologue's
; half-res arithmetic, two scanlines a byte), and a sprite's first line in a char is
; always even (lb0 = 2*sy + wfine), so a cell's lines go in pairs, one source byte a
; pair.  Every bank that holds sprites has the tables (banks.s) and all three
; blitters.  A box (flag bit 3) is not 4-bit: it is its screen bytes, every scanline,
; drawn by the copy blitter (NIBCOPY: its flag's dispatch entry), so a box's backdrop
; keeps any dither exactly.
; ============================================================================

; ----------------------------------------------------------------------------
; NPAIR k, mirror: lines k and k+1 of the cell, from source byte k/2
;   k       0, 2, 4, 6;  mirror  1 = through SWAPTAB
;   In:     ptr = the column's source, sp = the char
;   Out:    A, X (= the byte), Y clobbered;  sp_msk written
; Falls out at its end: the unrolled cell is four of these in a row.
; ----------------------------------------------------------------------------
.macro NPAIR k, mirror
        .local opq, done
  .if k = 0
        ldaz ptr
  .else
        ldy #k/2
        lda (ptr),y
  .endif
        beq done                    ; 0: both transparent
        tax                         ; X = the byte, for the three tables
        lda NMASK,x
        beq opq                     ; both opaque: plain stores

; ---- masked: screen = (screen AND mask) OR line
  .if mirror
        tay
        lda SWAPTAB,y               ; the mask, mirrored
  .endif
        sta sp_msk
        ldy #k
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L0TAB,x                 ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy #k                      ; Y back for the store
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

; ---- opaque: the two lines stored as they are
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

; ----------------------------------------------------------------------------
; NIBBLIT name, mirror, ret: the 4-bit blitter for one column of a char row
;   name    the entry label (sprFN, sprFM);  mirror  1 = through SWAPTAB
;   ret     where it returns (sprretP, sprretM)
;   In:     ptr = the column's source, sp = the char, lines tmp..tmp2 of the cell
;           (tmp even, tmp2 odd)
;   Out:    A, X, Y clobbered;  sp_msk, sp_lim written
; A whole cell (tmp2 = 7) goes into the unrolled pairs p0..p3 at the pair tmp names;
; anything else runs the partial loop, a pair at a time, with sp_lim the pair's line.
; ----------------------------------------------------------------------------
.macro NIBBLIT name, mirror, ret
        .local partial, et, p0, p1, p2, p3, pl, pop, pnext

; ---- part of a cell: lines tmp..tmp2 (above name, so name's bne reaches it)
partial:
        lda tmp
        sta sp_lim
pl:     lsr                         ; A = sp_lim on both ways in: the pair's source byte
        tay
        lda (ptr),y
        beq pnext                   ; 0: both transparent
        tax                         ; X = the byte, for the three tables
        lda NMASK,x
        beq pop                     ; both opaque: plain stores
  .if mirror
        tay
        lda SWAPTAB,y               ; the mask, mirrored
  .endif
        sta sp_msk
        ldy sp_lim
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L0TAB,x                 ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy sp_lim                  ; Y back for the store
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
pop:                                ; opaque: the two lines stored as they are
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
pnext:  lda sp_lim                  ; the next pair, until past tmp2
        clc
        adc #2
        sta sp_lim
        cmp tmp2
        bcc pl
        jmp ret

; ---- the entry: a whole cell, or part of one
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
; ----------------------------------------------------------------------------
; NIBCOPY name, ret: the copy blitter for a box (flag bit 3)
;   name  the entry label (sprFC);  ret  where it returns (sprretP)
;   In:   ptr = the column's source, sp = the char, lines tmp..tmp2 of the cell
;   Out:  A, Y clobbered;  X kept
; A box is its screen bytes, every scanline stored, opaque: a straight copy.  Any
; first line will do (a box's rows need not pair).  A whole cell is unrolled: 13
; cycles a byte against the 4-bit blitter's 21.
; ----------------------------------------------------------------------------
.macro NIBCOPY name, ret
        .local part, pl
name:   lda tmp2
        cmp #7
        bne part
        lda tmp
        bne part

; ---- a whole cell, lines 0-7
  .repeat 8, k
        ldy #k
        lda (ptr),y
        sta (sp),y
  .endrepeat
        jmp ret

; ---- part of a cell, lines tmp..tmp2
part:   ldy tmp
pl:     lda (ptr),y
        sta (sp),y
        cpy tmp2                    ; C = 1 at the last line (iny keeps C)
        iny
        bcc pl
        jmp ret
.endmacro
; ============================================================================
; NIB_LOOPS bank: the 4-bit build's row loop and all three blitters, for one bank
;   bank  this copy's bank (BANK_SPR or BANK_TIL1): the write window's
; Emits ds_entry (which must be BANKENTRY), the row and column loops, the column
; steps sprretP / sprretM, and the blitters sprFN (NIBBLIT), sprFM (NIBBLIT,
; mirrored) and sprFC (NIBCOPY), then sprdisp_tab.  The same shape as SPRITE_LOOPS
; without the mask walk: see the file header.
; ============================================================================
.macro NIB_LOOPS bank

; ---- ds_entry: patch the dispatch jump for this sprite (X = sp_disp)
; The jump is in this bank, so the store is a write window (cpu.inc): wrsel opens it
; (A = the bank, from callbank), wrback closes it, the write bank back to 7's.
; Master: both empty.
ds_entry:                           ; BANKENTRY
        wrsel bank, bank
        ldx sp_disp
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
        wrback bank

; ---- a character row: sp = its first char, ptr = its source bytes, tmp..tmp2 its lines
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
:       ldx #7                      ; ra1' = 7 unless this is the last row
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)

; ---- a column: the blitter, which returns to sprretP or sprretM
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite (ds_entry)

; ---- the column steps: ptr to the next image column, then sp to the next char
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
        bcs sprpinc                 ; carry out of line: the common case falls through
sprnext:
        spnext sprscold
sprsback:
        dec sp_cnt
        bpl ds_colloop

; ---- the row's end: the next row's source (+ sp_rinc) and screen (+ ROWBYTES)
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
        ringup sp_rb                ; folded at the ring's end
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts

; ---- out of line: the source pointer's carry and the screen's page step
sprpinc: inc ptr+1
        jmp sprnext
sprscold: jmp sprscold2

; ---- the blitters
        NIBBLIT sprFN, 0, sprretP
        NIBBLIT sprFM, 1, sprretM
        NIBCOPY sprFC, sprretP
sprscold2:
        spcold sprsback

; ---- the dispatch table, by sp_disp (the prologue's): (flags & 3) * 2, or 8 for a box
; Flag bit 0 is the mirror; bit 1 only sets the prologue's row arithmetic, so entries
; 2/3 alias 0/1.
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM, sprFC
.endmacro
; ============================================================================
; The two copies: bank 4 (SPR4CODE) and bank 5 (SPR5CODE)
;
; Each in a scope of its own (spr4, spr5), so the two copies' labels do not clash.
; Both must start their bank: ds_entry is BANKENTRY, where callbank enters.
; ============================================================================
        .segment "SPR4CODE"
        .scope spr4
  .if ::NIBSPR                      ; 4-bit sprites
        NIB_LOOPS ::BANK_SPR
  .else                             ; masked sprites.  assets.inc's SPR4_COPY: the packer
                                    ; puts the box stars in one bank and no mirrored image
                                    ; in the other
        SPRITE_LOOPS 1, ::SPR4_COPY, ::BANK_SPR
        .if ::SPR4_COPY
        SPRFULL sprFC, 0, 1
        .endif
  .endif
        .endscope
        .assert spr4::ds_entry = BANKENTRY, error, "bank 4's row loop must start the bank"

; Bank 4's code must end where its sprites start (B4_CODE_END).  The Master's code is
; shorter: its gap is the price of level files both machines read.
  .if BHW                           ; Model B: exactly
        .assert * = B4_CODE_END, error, "bank 4's code must end where its sprites start: set B4_CODE_END in the game's assets.inc"
  .else                             ; Master: at most
        .assert * <= B4_CODE_END, error, "bank 4's code runs into its sprites: B4_CODE_END in the game's assets.inc"
  .endif

        .segment "SPR5CODE"
        .scope spr5
  .if ::NIBSPR                      ; 4-bit sprites
        NIB_LOOPS ::BANK_TIL1
  .else                             ; masked sprites: bank 5 always has the copy blitter
        SPRITE_LOOPS ::SPR5_MIRROR, 1, ::BANK_TIL1
        PAD 0, ::PADM_FC5
        SPRFULL sprFC, 0, 1
  .endif
        .endscope
        .assert spr5::ds_entry = BANKENTRY, error, "bank 5's row loop must start the bank"

        .segment "TILCODE"
