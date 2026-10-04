; ============================================================================
; engine/sprloops.s -- the sprite row loop and blitters, assembled into each sprite bank
;
; The row loop reads the image bytes, so it is resident with them: NIB_LOOPS is
; assembled once into EACH sprite data bank, bank 4 (SPR4CODE) and bank 5
; (SPR5CODE), each copy starting its bank at BANKENTRY ($8000) in a scope of its
; own (spr4, spr5).  Both machines.  The prologue, draw_sprite (frame.s, bank 7,
; with the directory), clips the sprite and sets up the zero page, then enters the
; copy in the bank the image is in through low RAM's call_bank (low.s), which
; returns to bank 7 after it.
;
; The format: 4-bit sprites -- a stored byte a game-pixel row of two game pixels,
; turned into screen bytes by the tables beside the code (L0TAB, L1TAB, NMASK:
; defs.inc, banks.s) -- and boxes, their screen bytes copied straight (the copy
; blitter).  The notes on the 4-bit format follow this header.
;
; The shape of one copy:
;   ds_entry     (BANKENTRY) opens a write window into this bank, to ds_done
;                (cpu.inc wrsel ... wrback; nothing on the Master): the row loop
;                patches its column jump.
;   ds_rowloop   a char row, sp_row from sp_r0 to sp_r1: sp = the row's first char
;                (sp_rb), ptr = its source (sp_rp); tmp..tmp2 = the lines of each
;                cell to draw, 0..7 but sp_ra0 on the first row and sp_ra1 on the
;                last; and, once a row, the blitter's entry for those lines into
;                ds_colloop's jmp (sprrow_tab, from the prologue's sp_disp).
;   ds_colloop   a column, sp_ncol + 1 of them: jmp to the entry, which draws the
;                cell's lines and goes on to a column step -- spr_retp (ptr +
;                sp_lines; spr_fn falls into it) or spr_retm (mirrored: ptr -
;                sp_lines) -- then sp to the next char (its page step out of line),
;                and the countdown, which ends at ds_colloop's jmp itself.
;   ds_rowdone   the next row: sp_rp + sp_rinc, sp_rb + ROWBYTES folded at the
;                ring's end, falling into ds_rowloop; rts at ds_done.
;
; Macros:
;   NPAIR, NIBCELLS, NIBPART   the 4-bit blitter (spr_fn; spr_fm mirrored)
;   NIBCOPY                    the copy blitter, for boxes (spr_fc)
;   NIB_LOOPS                  the row loop and all three blitters
; Then the two copies, SPR4CODE and SPR5CODE, and the asserts that pin them.
;
; Placement: the blitters' order inside NIB_LOOPS is layout -- spr_fn's cells
; first, in the bank's first page (180 bytes from $8006 in both builds, 4 Oct 2026),
; the out-of-line steps in their branches' reach, PADB_FM/PADM_FM (pads.inc) before
; spr_fm's cells (252 bytes on the Model B, 245 on the Master, so they straddle a
; page) -- and the Model B's copy must end exactly at the game's B4_CODE_END.  Do
; not move anything in NIB_LOOPS.
; Cost: 23.0% of a frame on the Model B, 25.7% on the Master (measured 4 Oct 2026,
; Cleo's test/linecyc.mjs, levels 0, 4, 8, 10, 60 frames; both copies together):
; NPAIR's cells 9.7% / 11.0%, the copy blitter 4.8% / 5.7%, the column steps
; and loop 4.1% / 4.6%, the row loop 2.4% / 3.0%, the partial loops 0.9% / 0.9%.
; ============================================================================

; ============================================================================
; The 4-bit sprites
;
; A stored column is one byte a game-pixel row: its two game pixels, 4 bits each,
; of one palette the game chose (nibble 0 transparent).  Three tables, the game's
; (nibtab.bin, banks.s), turn the byte b into screen bytes:
;   L0TAB[b], L1TAB[b]  the row's two scanlines
;   NMASK[b]            the AND mask for its transparent game pixels: 0 when both
;                       are opaque (plain stores), else the mask for the one
; A byte of 0 is both pixels transparent and draws nothing.  Otherwise
;   screen = (screen AND NMASK[b]) OR Ln[b]
; Mirrored, each line's byte is reversed through SWAPTAB (the four MODE 1 pixels of
; a byte in the other order) and the mask complemented, which for one transparent
; pixel of two is the same reversal (nibtab.bin's masks are $CC and $33).
;
; The shape's lines (sprg_ln) are the rows stored, two scanlines each unless every
; scanline is stored (SPF_FULLRES: a box), and a sprite's first line in a char is
; always even (the prologue's lb0 = 2*sy + wfine), so a cell's lines go in pairs,
; one source byte a pair.  Every bank that holds sprites has the tables (banks.s)
; and all three blitters.  A box (SPF_COPY) is not 4-bit: it is its screen bytes,
; every scanline, drawn by the copy blitter, so a box's backdrop keeps any dither
; exactly.
; ============================================================================

; ----------------------------------------------------------------------------
; NPAIR k, mirror: lines k and k+1 of the cell, from source byte k/2
;   In:    k = 0, 2, 4 or 6;  mirror = 1: through SWAPTAB
;          ptr = the column's source, sp = the char;  C = 0 (the column steps')
;   Out:   the two lines drawn;  sp_msk written on the masked path
;   Uses:  A X Y (X = the byte, for the three tables)
;   Keeps: C (nothing here touches it: the bcc to tail is the always-branch)
; Falls out at its end: the unrolled cell is four of these in a row.  On the Master
; line 0 is stored through (sp) with no index; the Model B's ldaz leaves Y = 0 for
; it (the (k = 0) .and (.not ::BHW) tests: CPU spelling, kept explicit because the
; two orders differ).  Local labels: opq, done, tail.
; ----------------------------------------------------------------------------
.macro NPAIR k, mirror
        .local opq, done
  .if k = 0
        ldaz ptr
  .else
        ldy #k/2
        lda (ptr),y
  .endif
        beq done                   ; 0: both transparent
        tax                        ; X = the byte, for the three tables
        lda NMASK,x
        beq opq                    ; both opaque: plain stores
        ; ---- masked: screen = (screen AND mask) OR line
  .if mirror
        eor #$FF                   ; the mask reversed (the masks are $CC and $33)
  .endif
        sta sp_msk
  .if (k = 0) .and (.not ::BHW)    ; CPU spelling: the 65C02's line 0 non-indexed
        and (sp)                   ; (A is the mask)
    .if mirror
        ldy L0TAB,x                ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
    .else
        ora L0TAB,x
    .endif
        sta (sp)
        ldy #1
  .else
    .if (k <> 0) .or mirror .or (.not ::BHW)
        ldy #k                     ; (Model B k = 0 unmirrored: Y = 0 from the ldaz)
    .endif
        and (sp),y                 ; A is still the mask
    .if mirror
        ldy L0TAB,x                ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy #k                     ; Y back for the store
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
        bcc tail                   ; always (C = 0): opq's store of line k+1
        ; ---- opaque: the two lines stored as they are
opq:
  .if mirror
        ldy L0TAB,x
        lda SWAPTAB,y
    .if (k = 0) .and (.not ::BHW)  ; CPU spelling: the 65C02's line 0 non-indexed
        sta (sp)
    .else
        ldy #k
        sta (sp),y
    .endif
        ldy L1TAB,x
        lda SWAPTAB,y
tail:   ldy #k+1                   ; (the masked line joins here, its byte in A)
        sta (sp),y
  .else
    .if (k = 0) .and (.not ::BHW)  ; CPU spelling: the 65C02's line 0 non-indexed
        lda L0TAB,x
        sta (sp)
        ldy #1
    .else
      .if (k <> 0) .or (.not ::BHW)
        ldy #k                     ; (Model B k = 0: Y = 0 from the ldaz)
      .endif
        lda L0TAB,x
        sta (sp),y
        iny
    .endif
        lda L1TAB,x
tail:   sta (sp),y                 ; (the masked line joins here, its byte in A,
  .endif                           ;  Y = k+1 on both paths)
done:
.endmacro

; ----------------------------------------------------------------------------
; NIBPART name, mirror, ret: the 4-bit blitter's partial cell -- lines tmp..tmp2
;   In:    name = the entries' prefix (spr_fn, spr_fm);  mirror = 1: through
;          SWAPTAB;  ret = the column step it returns to (spr_retp, spr_retm)
;          ptr = the column's source, sp = the char;  tmp (even)..tmp2 (odd) = the
;          lines to draw, tmp2 < 7
;   Out:   the lines drawn, a pair at a time;  sp_msk, sp_lim written;  jumps to ret
;          with C = 0 when not mirrored (spr_retp's condition; spr_retm sets its own)
;   Uses:  A X Y
; The entry name_pt: the last row of a sprite that ends above line 7 (ds_rowloop
; picks it; sprrow_tab).  sp_lim is the pair's first line; its source byte is
; sp_lim/2, so the lsr at pl leaves C = 0, which nothing in the body touches: the
; bcc after the masked stores is the always-branch, and the adc #2 at pnext needs
; no clc.  Local labels: pl, pop, pnext.
; ----------------------------------------------------------------------------
.macro NIBPART name, mirror, ret
        .local pl, pop, pnext
.ident(.concat(.string(name), "_pt")):
        lda tmp
        sta sp_lim
pl:     lsr                        ; A = sp_lim on both ways in: the pair's source byte
        tay
        lda (ptr),y
        beq pnext                  ; 0: both transparent
        tax                        ; X = the byte, for the three tables
        lda NMASK,x
        beq pop                    ; both opaque: plain stores
  .if mirror
        eor #$FF                   ; the mask reversed (the masks are $CC and $33)
  .endif
        sta sp_msk
        ldy sp_lim
        lda (sp),y
        and sp_msk
  .if mirror
        ldy L0TAB,x                ; the line's byte, straight into SWAPTAB's index
        ora SWAPTAB,y
        ldy sp_lim                 ; Y back for the store
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
        bcc pnext                  ; always: C = 0 from pl's lsr
        ; ---- opaque: the two lines stored as they are
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
        ; ---- the next pair, until past tmp2
pnext:  lda sp_lim
        adc #2                     ; (C = 0: pl's lsr of an even sp_lim)
        sta sp_lim
        cmp tmp2
        bcc pl
  .if .not mirror
        clc                        ; spr_retp wants C = 0 (the bcc left it 1)
  .endif
        jmp ret
.endmacro

; ----------------------------------------------------------------------------
; NIBCELLS name, mirror, ret, fall: the 4-bit blitter's whole cells
;   In:    name = the entries' prefix (spr_fn, spr_fm);  mirror = 1: through
;          SWAPTAB;  ret = the column step (spr_retp, spr_retm);  fall given: the
;          last pair falls into ret, which must follow (saves the commonest
;          blitter a jmp)
;          ptr = the column's source, sp = the char;  C = 0
;   Out:   the entries name_0 .. name_3: a cell to its line 7 from pair 0..3 (line
;          0, 2, 4 or 6 on), the unrolled pairs entered part way down;  C = 0 out
;   Uses:  A X Y, sp_msk
; The row loop chooses the entry once a row (sprrow_tab), not a column.
; ----------------------------------------------------------------------------
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
; NIBCOPY name, ret: the copy blitter, for a box (SPF_COPY)
;   In:    name = the entries' prefix (spr_fc);  ret = the column step (spr_retp)
;          ptr = the column's source, sp = the char;  C = 0;  for name_pt: tmp..tmp2
;          = the lines to draw
;   Out:   the entries name_0 .. name_7: a cell to its line 7 from line 0..7,
;          unrolled, each line setting its own Y, so entered at any; name_pt: lines
;          tmp..tmp2 (the last row, tmp2 < 7), a line at a time;  jumps to ret with
;          C = 0
;   Uses:  A Y
;   Keeps: X
;   Cost:  13 cycles a byte unrolled (ldy #, lda (ptr),y, sta (sp),y); the Master's
;          line 0 non-indexed, 10
; A box is its screen bytes, every scanline stored, opaque: a straight copy, and any
; first line will do (a box's rows need not pair).  Local label: pl.
; ----------------------------------------------------------------------------
.macro NIBCOPY name, ret
        .local pl
.ident(.concat(.string(name), "_0")):
        ldaz ptr                   ; line 0 non-indexed (the Model B: Y = 0 from it)
        staz0 sp
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
        cpy tmp2                   ; C = 1 at the last line (iny keeps C)
        iny
        bcc pl
        clc                        ; spr_retp wants C = 0 (the bcc left it 1)
        ; always: the unrolled cell's jmp ret, the 3 bytes before this entry
        bcc .ident(.concat(.string(name), "_pt"))-3
.endmacro

; ----------------------------------------------------------------------------
; NIB_LOOPS bank: the row loop and all three blitters, one bank's copy
;   In:    bank = this copy's bank (BANK_SPR or BANK_TIL1), for the write window
;          At ds_entry (from call_bank, A = the bank): sp = sp_rb = the first row's
;          first char, sp_rp = its source, sp_row = sp_r0, sp_r1, sp_ra0, sp_ra1,
;          sp_ncol, sp_disp, sp_lines, sp_rinc (the prologue's)
;   Out:   the sprite drawn; rts at ds_done with the write bank 7's again
;   Uses:  A X Y, sp, ptr, tmp, tmp2, sp_row, sp_rp, sp_rb, sp_cnt, sp_lim, sp_msk,
;          and ds_colloop's operand (patched in this bank)
; Emits ds_entry (which must be BANKENTRY), spr_fn's cells falling into the column
; step spr_retp, the column loop, the out-of-line steps, the mirrored step
; spr_retm, the row loop, then spr_fm's cells, the partial loops, the copy blitter
; and sprrow_tab: see the file header.  Anonymous labels: three in the row loop,
; each a skip of one instruction.
; ----------------------------------------------------------------------------
.macro NIB_LOOPS bank
        ; ---- ds_entry: open the write window, to ds_done -- each row patches the
        ; column loop's jump in this bank (cpu.inc).  Master: the jmp alone.
ds_entry:                          ; BANKENTRY
        wrsel bank, bank           ; (A = the bank, call_bank's)
        jmp ds_rowloop
        ; ---- the commonest blitter's cells, falling into its column step: first in
        ; the bank, so in its first page (their branches' targets too)
        NIBCELLS spr_fn, 0, spr_retp, fall
        ; ---- the column steps: ptr to the next image column, then sp to the next
        ; char.  C = 0 on arrival: every column entry has it (ds_rowloop's adc, the
        ; step below, spcold), the cells and NIBCOPY's unrolled lines keep it, the
        ; partial loops clear it
spr_retp:                          ; next column: the source pointer + the rows
        lda ptr
        adc sp_lines
        sta ptr
        bcs spr_pinc               ; the carry, out of line: the common case falls on
spr_next:                          ; C = 0: spnext with its clc known
        lda sp
        adc #CHARBYTES
spr_ssta:
        sta sp
        bcs spr_scold
spr_sback:
        dec sp_cnt
        bmi ds_rowdone
ds_colloop:
        jmp spr_fn_0               ; the operand patched a row (ds_rowloop)
        ; ---- out of line, in their branches' reach: the source pointer's carry, the
        ; screen's page step, the mirrored column step
spr_pinc:
        inc ptr+1
        clc                        ; (the adc's carry)
        bcc spr_next               ; always
spr_scold:
        jmp spr_scold2             ; (out of the bcs's reach)
spr_mdec:
        dec ptr+1                  ; C = 0 (spr_retm's borrow), kept
        bcc spr_next               ; always: ahead of spr_retm, so in reach
spr_retm:                          ; next column, mirrored: the source pointer - rows
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcc spr_mdec
        lda sp                     ; C = 1: + 7 is + CHARBYTES
        adc #CHARBYTES-1
        bra spr_ssta
        ; ---- the row's end: the next row's source (+ sp_rinc) and screen
        ; (+ ROWBYTES, folded at the ring's end)
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        lda sp_rp                  ; C = 0: sp_row < sp_r1
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
        ringup sp_rb               ; folded at the ring's end
        sta sp_rb+1
        ; ---- a char row: sp = its first char, ptr = its source bytes, and the entry
        ; its columns take: lines tmp..tmp2 of each cell -- tmp 0 unless the first
        ; row (sp_ra0), tmp2 7 unless the last (sp_ra1).  To line 7 a cell is the
        ; blitter's unrolled entry for line tmp, otherwise its partial loop
        ; (sprrow_tab, from sp_disp: the prologue's, the blitter's first entry).
        sta sp+1                   ; sp = sp_rb: A = sp_rb+1, just stored (from
        lda sp_rb                  ;  ds_entry sp is sp_rb already: the prologue took
        sta sp                     ;  sp_rb from ring_addr7's sp)
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
:       stx tmp                    ; the first line
        ldy #CHARLINES-1
        cmp sp_r1
        bne :+
        ldy sp_ra1
:       sty tmp2                   ; the last line
        txa
        cpy #CHARLINES-1
        bcs :+                     ; to line 7: the unrolled entry for line tmp
        lda #SPRTAB_N-1            ; else the partial loop, the blitter's last entry
:       asl                        ; C = 0 (A <= 8): the word's index
        adc sp_disp
        tax
        lda sprrow_tab,x
        sta ds_colloop+1
        lda sprrow_tab+1,x
        sta ds_colloop+2
        lda sp_ncol
        sta sp_cnt                 ; columns - 1 (the countdown)
        jmp (ds_colloop+1)         ; straight to the row's entry (5 cycles, not 3+3)
        .assert <(ds_colloop+1) <> $FF, error, "ds_colloop's operand straddles a page (NMOS jmp (ind))"
ds_done:
        wrback bank                ; the write window's end
        rts
        ; ---- the screen's page step, out of line
spr_scold2:
        spcold spr_sback
        ; ---- the other blitters: spr_fm's cells (pads.inc's PADB_FM and PADM_FM
        ; place them: they straddle a page), the partial loops, the copy blitter
        PAD ::PADB_FM, ::PADM_FM
        NIBCELLS spr_fm, 1, spr_retm
        NIBPART spr_fn, 0, spr_retp
        NIBPART spr_fm, 1, spr_retm
        NIBCOPY spr_fc, spr_retp
        ; ---- the entries a row takes, by sp_disp + 2 x (its first line, or
        ; SPRTAB_N-1 for the partial loop): the prologue's sp_disp is SPRDISP_FN
        ; (spr_fn), SPRDISP_FM (spr_fm, mirrored: SPF_MIRROR) or SPRDISP_FC (spr_fc,
        ; a box: SPF_COPY) -- defs.s.  A 4-bit cell's first line is even, so its odd
        ; entries are never taken (they repeat the even ones).
sprrow_tab:
        .word spr_fn_0, spr_fn_0, spr_fn_1, spr_fn_1, spr_fn_2, spr_fn_2, spr_fn_3
        .word spr_fn_3, spr_fn_pt
        .word spr_fm_0, spr_fm_0, spr_fm_1, spr_fm_1, spr_fm_2, spr_fm_2, spr_fm_3
        .word spr_fm_3, spr_fm_pt
        .word spr_fc_0, spr_fc_1, spr_fc_2, spr_fc_3, spr_fc_4, spr_fc_5, spr_fc_6
        .word spr_fc_7, spr_fc_pt
        .assert * - sprrow_tab = 3*2*SPRTAB_N && SPRDISP_FM = 2*SPRTAB_N && SPRDISP_FC = 4*SPRTAB_N, error, "sprrow_tab: SPRTAB_N entries a blitter, in sp_disp's order"
        .assert >sprrow_tab = >(sprrow_tab+3*2*SPRTAB_N-1), warning, "sprrow_tab straddles a page (+1 cycle a row)"
.endmacro

; ============================================================================
; The two copies: bank 4 (SPR4CODE) and bank 5 (SPR5CODE)
;
; Each in a scope of its own (spr4, spr5), so the two copies' labels do not clash.
; Both must start their bank: ds_entry is BANKENTRY, where call_bank enters.
; ============================================================================
        .segment "SPR4CODE"
        .scope spr4
        NIB_LOOPS ::BANK_SPR
        .endscope
        .assert spr4::ds_entry = BANKENTRY, error, "bank 4's row loop must start the bank"
        ; Bank 4's code must end where its sprites start (B4_CODE_END, the game's
        ; assets.inc).  The Model B's copy is the longer, and B4_CODE_END is set to
        ; it exactly; the Master's copy leaves a gap, the price of level files both
        ; machines read.
  .if BHW                          ; hardware (write-select boards): wrsel and wrback
                                   ;  are stores on the Model B, nothing on the Master
        .assert * = B4_CODE_END, error, "bank 4's code must end where its sprites start: set B4_CODE_END in the game's assets.inc"
  .else
        .assert * <= B4_CODE_END, error, "bank 4's code runs into its sprites: B4_CODE_END in the game's assets.inc"
  .endif

        .segment "SPR5CODE"
        .scope spr5
        NIB_LOOPS ::BANK_TIL1
        .endscope
        .assert spr5::ds_entry = BANKENTRY, error, "bank 5's row loop must start the bank"
