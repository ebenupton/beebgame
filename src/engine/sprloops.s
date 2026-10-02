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
; The format: 4-bit sprites -- a stored byte a game-pixel row, two game pixels of one
; palette each, turned into screen bytes by tables (L0TAB, L1TAB, NMASK: defs.inc) --
; and boxes, screen bytes copied straight (the copy blitter).
;
; The shape:
;   ds_entry     opens a write window into this bank, to ds_done (cpu.inc: wrsel ...
;                wrback; empty on the Master): the row loop patches its column jump.
;   ds_rowloop   a character row, sp_r0..sp_r1: sp = the row's first char (sp_rb),
;                ptr = its source (sp_rp); tmp..tmp2 = the lines of the cell to draw,
;                0..7 but sp_ra0 on the first row and sp_ra1 on the last; and, once a
;                row, the blitter's entry for them into ds_colloop's jmp (sprrow_tab,
;                from sp_disp, the prologue's).
;   ds_colloop   a column, sp_ncol+1 of them: jmp to the entry, which draws the
;                cell's lines and goes on to a column step -- sprretP (ptr +
;                sp_lines; sprFN falls into it) or sprretM (mirrored: ptr - sp_lines)
;                -- then sp to the next char (spnext, its page step out of line), and
;                the countdown, which ends in ds_colloop's jmp itself.
;   ds_rowdone   the next row: sp_rp + sp_rinc, sp_rb + ROWBYTES folded at the ring's
;                end, falling into ds_rowloop; rts at ds_done.
;
; Macros:
;   NPAIR, NIBCELLS, NIBPART   the 4-bit blitter (sprFN, sprFM mirrored)
;   NIBCOPY          the copy blitter, for boxes (sprFC)
;   NIB_LOOPS        the row loop and all three blitters
; Then the two copies: SPR4CODE (bank 4) and SPR5CODE (bank 5).
; ============================================================================

; ============================================================================
; The 4-bit sprites
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
        eor #$FF                    ; the mask, mirrored: NMASK's masks are $CC/$33, swapped
  .endif
        sta sp_msk
  .if (k = 0) .and (.not ::BHW)
        and (sp)                    ; line 0 non-indexed (A is the mask)
    .if mirror
        ldy L0TAB,x                 ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
    .else
        ora L0TAB,x
    .endif
        sta (sp)
        ldy #1
  .else
    .if (k <> 0) .or mirror .or (.not ::BHW)
        ldy #k                      ; (Model B k = 0 unmirrored: Y = 0 from ldaz)
    .endif
        and (sp),y                  ; A is still the mask
    .if mirror
        ldy L0TAB,x                 ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy #k                      ; Y back for the store
    .else
        ora L0TAB,x
    .endif
        sta (sp),y
        iny
  .endif
        lda (sp),y
        and sp_msk
        .local tail
  .if mirror
        ldy L1TAB,x
        ora SWAPTAB,y
  .else
        ora L1TAB,x
  .endif
        bcc tail                    ; always (C = 0 through the cells): opq's store of line k+1

; ---- opaque: the two lines stored as they are
opq:
  .if mirror
        ldy L0TAB,x
        lda SWAPTAB,y
    .if (k = 0) .and (.not ::BHW)
        sta (sp)                    ; line 0 non-indexed
    .else
        ldy #k
        sta (sp),y
    .endif
        ldy L1TAB,x
        lda SWAPTAB,y
tail:   ldy #k+1                    ; (the masked line joins here, its byte in A)
        sta (sp),y
  .else
    .if (k = 0) .and (.not ::BHW)
        lda L0TAB,x                 ; line 0 non-indexed
        sta (sp)
        ldy #1
    .else
      .if (k <> 0) .or (.not ::BHW)
        ldy #k                      ; (Model B k = 0: Y = 0 from ldaz)
      .endif
        lda L0TAB,x
        sta (sp),y
        iny
    .endif
        lda L1TAB,x
tail:   sta (sp),y                  ; (the masked line joins here, its byte in A, Y = k+1)
  .endif
done:
.endmacro

; ----------------------------------------------------------------------------
; The 4-bit blitter for one column of a char row, in two macros so that a bank can
; put its cells where they sit in one page:
;   NIBCELLS name, mirror, ret, fall   the entries name_0 .. name_3: a cell to its
;                      line 7 from pair 0..3 (lines 0, 2, 4, 6 on), the unrolled
;                      pairs entered part way down.  fall given: the last pair falls
;                      into ret, which must follow (the commonest blitter's saving of
;                      a jmp).
;   NIBPART name, mirror, ret          the entry name_pt: anything else -- the last
;                      row, to line tmp2 < 7 -- lines tmp..tmp2 (tmp even, tmp2 odd),
;                      a pair at a time, sp_lim the pair's line
;   name    the entries' prefix (sprFN, sprFM);  mirror  1 = through SWAPTAB
;   ret     where it returns (sprretP, sprretM)
;   In:     ptr = the column's source, sp = the char
;   Out:    A, X, Y clobbered;  sp_msk, sp_lim written
; The row loop chooses the entry once a row (sprrow_tab), not a column.
; ----------------------------------------------------------------------------
.macro NIBPART name, mirror, ret
        .local pl, pop, pnext
.ident(.concat(.string(name), "_pt")):
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
        eor #$FF                    ; the mask, mirrored: NMASK's masks are $CC/$33, swapped
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
        bcc pnext                   ; always: C = 0 from pl's lsr, which nothing here touches
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
pnext:  lda sp_lim                  ; the next pair, until past tmp2 (C = 0: pl's lsr of an even sp_lim)
        adc #2
        sta sp_lim
        cmp tmp2
        bcc pl
  .if .not mirror
        clc                         ; sprretP wants C = 0 (the bcc left it 1)
  .endif
        jmp ret
.endmacro
.macro NIBCELLS name, mirror, ret, fall
  .repeat 4, j
.ident(.sprintf("%s_%d", .string(name), j)):
        NPAIR 2*j, mirror
  .endrepeat
  .ifblank fall
        jmp ret
  .endif
.endmacro
; ----------------------------------------------------------------------------
; NIBCOPY name, ret: the copy blitter for a box (flag bit 3)
;   name  the entries' prefix (sprFC);  ret  where it returns (sprretP)
;   In:   ptr = the column's source, sp = the char
;   Out:  A, Y clobbered;  X kept
; A box is its screen bytes, every scanline stored, opaque: a straight copy, and any
; first line will do (a box's rows need not pair).  The entries, chosen once a row:
;   name_0 .. name_7   a cell to its line 7 from line 0..7: unrolled, each line
;                      setting its own Y, so entered at any (13 cycles a byte; the
;                      Master's line 0 non-indexed, 10)
;   name_pt            lines tmp..tmp2, tmp2 < 7 (the last row), a line at a time
; ----------------------------------------------------------------------------
.macro NIBCOPY name, ret
        .local pl
.ident(.concat(.string(name), "_0")):
  .if ::BHW
        ldy #0                      ; (staz would reload the same 0 into Y)
        lda (ptr),y
        sta (sp),y
  .else
        lda (ptr)                   ; line 0 non-indexed
        sta (sp)
  .endif
  .repeat 7, j
.ident(.sprintf("%s_%d", .string(name), j+1)):
        ldy #j+1
        lda (ptr),y
        sta (sp),y
  .endrepeat
        jmp ret

; ---- part of a cell, lines tmp..tmp2
.ident(.concat(.string(name), "_pt")):
        ldy tmp
pl:     lda (ptr),y
        sta (sp),y
        cpy tmp2                    ; C = 1 at the last line (iny keeps C)
        iny
        bcc pl
        clc                         ; sprretP wants C = 0 (the bcc left it 1)
        bcc .ident(.concat(.string(name), "_pt"))-3   ; always: the unrolled cell's jmp ret, just before this entry
.endmacro
; ============================================================================
; NIB_LOOPS bank: the row loop and all three blitters, for one bank
;   bank  this copy's bank (BANK_SPR or BANK_TIL1): the write window's
; Emits ds_entry (which must be BANKENTRY), the blitter sprFN with the column step
; it falls into (sprretP), the column and row loops, the mirrored step sprretM, the
; blitters sprFM and sprFC, then sprrow_tab: see the file header.
; ============================================================================
.macro NIB_LOOPS bank

; ---- ds_entry: open the write window, to ds_done -- each row patches the column
; loop's jump in this bank (cpu.inc; A = the bank, from callbank).  Master: empty.
ds_entry:                           ; BANKENTRY
        wrsel bank, bank
        jmp ds_rowloop

; ---- the commonest blitter's cells, falling into its column step: first in the bank,
; so in its first page (their branches' targets too)
        NIBCELLS sprFN, 0, sprretP, fall

; ---- the column steps: ptr to the next image column, then sp to the next char
; C = 0 on arrival: every column entry has it (ds_rowloop's adc, the step below,
; spcold), the cells and NIBCOPY's unrolled lines keep it, the partial loops clear it
sprretP:                            ; next column: source pointer + rows
        lda ptr
        adc sp_lines
        sta ptr
        bcs sprpinc                 ; carry out of line: the common case falls through
sprnext:                            ; C = 0: spnext, its clc known
        lda sp
        adc #8
sprssta:
        sta sp
        bcs sprscold
sprsback:
        dec sp_cnt
        bmi ds_rowdone
ds_colloop:
        jmp sprFN_0                 ; operand patched per row (ds_rowloop)

; ---- out of line, in its branches' reach: the source pointer's carry, the screen's
; page step, and the mirrored column step
sprpinc: inc ptr+1
        clc                         ; (the adc's carry)
        bcc sprnext                 ; always
sprscold: jmp sprscold2
sprmdec: dec ptr+1                  ; C = 0 (sprretM's borrow), kept
        bcc sprnext                 ; always: ahead of sprretM, so in sprnext's page
sprretM:                            ; next column, mirrored: source pointer - rows
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcc sprmdec
        lda sp                      ; C = 1: + 7 is + 8
        adc #7
  .if ::BHW
        jmp sprssta
  .else
        bra sprssta
  .endif

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

; ---- a character row: sp = its first char, ptr = its source bytes, and the entry
; its columns take: lines tmp..tmp2 of each cell -- tmp 0 unless the first row
; (sp_ra0), tmp2 7 unless the last (sp_ra1).  To line 7 a cell is the blitter's
; unrolled entry for line tmp, otherwise its partial loop (sprrow_tab, from
; sp_disp: the prologue's, the blitter's first entry).
        sta sp+1                    ; sp = sp_rb: A = sp_rb+1, just stored (from ds_entry
        lda sp_rb                   ;  sp is sp_rb already: the prologue took sp_rb from
        sta sp                      ;  ringaddr7's sp)
ds_rowloop:
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
        ldx #0
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
:       stx tmp                     ; the first line
        ldy #7
        cmp sp_r1
        bne :+
        ldy sp_ra1
:       sty tmp2                    ; the last line
        txa
        cpy #7
        bcs :+                      ; to line 7: the unrolled entry for line tmp
        lda #8                      ; else the partial loop
:       asl                         ; C = 0 (A <= 8)
        adc sp_disp
        tax
        lda sprrow_tab,x
        sta ds_colloop+1
        lda sprrow_tab+1,x
        sta ds_colloop+2
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
        jmp (ds_colloop+1)          ; straight to the row's entry (5, not 3+3)
        .assert <(ds_colloop+1) <> $FF, error, "ds_colloop's operand straddles a page (NMOS jmp (ind))"
ds_done:
        wrback bank                 ; the write window's end
        rts

; ---- the screen's page step, out of line
sprscold2:
        spcold sprsback

; ---- the other blitters: sprFM's cells (291 bytes, more than a page: pads.inc,
; PADB_FM and PADM_FM, place them), the partial loops, the copy blitter.
        PAD ::PADB_FM, ::PADM_FM
        NIBCELLS sprFM, 1, sprretM
        NIBPART sprFN, 0, sprretP
        NIBPART sprFM, 1, sprretM
        NIBCOPY sprFC, sprretP

; ---- the entries a row takes, by sp_disp + 2 x (its first line, or 8 for the partial
; loop): the prologue's sp_disp is 0 (sprFN), 18 (sprFM, mirrored: flag bit 0) or 36
; (sprFC, a box: flag bit 3).  A 4-bit cell's first line is even, so its odd entries
; are never taken (they repeat the even ones).
sprrow_tab:
        .word sprFN_0, sprFN_0, sprFN_1, sprFN_1, sprFN_2, sprFN_2, sprFN_3, sprFN_3, sprFN_pt
        .word sprFM_0, sprFM_0, sprFM_1, sprFM_1, sprFM_2, sprFM_2, sprFM_3, sprFM_3, sprFM_pt
        .word sprFC_0, sprFC_1, sprFC_2, sprFC_3, sprFC_4, sprFC_5, sprFC_6, sprFC_7, sprFC_pt
        .assert >sprrow_tab = >(sprrow_tab+53), warning, "sprrow_tab straddles a page (+1 cycle a row)"
.endmacro
; ============================================================================
; The two copies: bank 4 (SPR4CODE) and bank 5 (SPR5CODE)
;
; Each in a scope of its own (spr4, spr5), so the two copies' labels do not clash.
; Both must start their bank: ds_entry is BANKENTRY, where callbank enters.
; ============================================================================
        .segment "SPR4CODE"
        .scope spr4
        NIB_LOOPS ::BANK_SPR
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
        NIB_LOOPS ::BANK_TIL1
        .endscope
        .assert spr5::ds_entry = BANKENTRY, error, "bank 5's row loop must start the bank"

        .segment "TILCODE"
