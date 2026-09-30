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
;   ds_entry     patches ds_dispatch's jmp with the sprite's blitter: sprdisp_tab
;                indexed by sp_disp (the prologue's, from the directory's flags).  The
;                jmp is in this bank, so the store is a write window (cpu.inc: wrsel
;                ... wrback; empty on the Master).
;   ds_rowloop   a character row, sp_r0..sp_r1: sp = the row's first char (sp_rb),
;                ptr = its source (sp_rp); tmp..tmp2 = the lines of the cell to draw,
;                0..7 but sp_ra0 on the first row and sp_ra1 on the last.
;   ds_colloop   a column, sp_ncol+1 of them: jmp to the blitter (ds_dispatch), which
;                draws lines tmp..tmp2 of the char at sp and jumps back to a column
;                step -- sprretP (ptr + sp_lines) or sprretM (mirrored: ptr - sp_lines)
;                -- then sp to the next char (spnext, its page step out of line).
;   ds_rowdone   the next row: sp_rp + sp_rinc, sp_rb + ROWBYTES folded at the ring's
;                end; rts at ds_done.
;
; Macros:
;   NPAIR, NIBBLIT   the 4-bit blitter (sprFN, sprFM mirrored)
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
; NIB_LOOPS bank: the row loop and all three blitters, for one bank
;   bank  this copy's bank (BANK_SPR or BANK_TIL1): the write window's
; Emits ds_entry (which must be BANKENTRY), the row and column loops, the column
; steps sprretP / sprretM, and the blitters sprFN (NIBBLIT), sprFM (NIBBLIT,
; mirrored) and sprFC (NIBCOPY), then sprdisp_tab: see the file header.
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
