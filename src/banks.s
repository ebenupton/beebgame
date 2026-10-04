; ============================================================================
; banks.s -- the engine's static tables, its bank-resident data and two small routines
;
; The level's own tables (attributes, alt classes, the header, the sprite
; directory) are storage here, filled by the level loader (ldprog.s); the tables
; assembled into the image are the kernel's row multiples and the sprite banks'
; expansion tables.  The game's tables are its own (Cleo's gamedata.s).  Both
; machines; the one `.if BHW` is the Model B's mirror routine.
;
; Segments: ENGLVL and ENGBSS (bank 7's level tables and the directory), ENGCODE
; (bank 7: mir_dirty, lv_reset), KRNDATA (bank 7's kernel: mul_rowlo/hi), SPR4TAB and
; SPR5TAB (the end of each sprite bank: L0TAB, L1TAB, NMASK, SWAPTAB).
; Entry points: lv_reset (the game's level start, game.s), mir_dirty (Model B:
; frame.s copy_partial and draw_sprite).
; ============================================================================

; ---------------------------------------------------------------- bank 7: the level
        .segment "ENGLVL"          ; the level's tables, loaded by ldprog.s (its
LV_ATTR0:   .res 256               ;  objects go to main RAM: LV_OBJS, defs.inc)
LV_ALTCLS:  .res 256               ; the alt class by tile id (the game's logic)
LV_HDR:     .res HDR_LEN           ; the header: lw, lh, nobj, the tile set's shape,
                                   ;  the game's fields (tools/levelfile.py); the
                                   ;  game's header tail follows, in its own memory
        .segment "ENGBSS"          ; the engine's: the sprite directory
; The directory's level part, by sprite id: the images' addresses, the low bytes then
; the high bytes -- 0 when the id is not in this level, bit 7 of the high byte clear
; for bank 5 (set: bank 4).  The geometry is the game's (sprg_*), the boxes' too.
; draw_sprite (frame.s) reads it; ldprog.s fills it (2*(BOXID0+BOXN) bytes).
DIR_TABLE:  .res 2*(BOXID0+BOXN)
DIRL      = DIR_TABLE
DIRH      = DIR_TABLE+BOXID0+BOXN

; ---------------------------------------------------------------- the sprite banks
; The expansion tables and SWAPTAB end both sprite banks at the same addresses
; (defs.inc), so the blitters' one source (sprloops.s) names them for either bank.
; SWAP_TABLE: the four MODE 1 pixels of a byte in the other order -- pixel n is bits
; 7-n and 3-n, so bits 7<->4, 6<->5, 3<->0, 2<->1 (the mirrored blitter's).
.macro SWAP_TABLE
        .assert * = SWAPTAB, error, "SWAPTAB must be at SWAPTAB"
.repeat 256, xx
        .byte ((xx & $88) >> 3) | ((xx & $44) >> 1) | ((xx & $22) << 1) | ((xx & $11) << 3)
.endrepeat
.endmacro
; NIB_TABLES: the game's expansion tables (its palette: nibtab.bin, L0TAB, L1TAB and
; NMASK, NIBTAB_LEN bytes, from its asset step) and SWAPTAB after them
.macro NIB_TABLES
        .assert * = L0TAB, error, "the expansion tables must be at L0TAB"
        .incbin "nibtab.bin", 0, NIBTAB_LEN
        SWAP_TABLE
.endmacro

; ----------------------------------------------------------------------------
; mir_dirty: note a range of the mirror's row written (Model B)
;   In:    A = the first window column written of the row the mirror follows, X =
;          the last (0..79);  wcxm (calc_ring);  cur_buf
;   Out:   MIRDTY[cur_buf] = 1 and MIRLO/MIRHI[cur_buf] widened to the slot-row
;          chars written, wcxm + column, cut at 79 -- nothing when the first lands
;          past 79 (those chars wrapped to slot row 0, which the mirror never reads)
;   Uses:  A X Y, one stack byte
;   Pre:   bank 7 paged
; One body, MIRDIRTY_BODY (engine/macros.s), used twice: in line in bank 6's
; draw_rect head, and as this routine for bank 7's callers (copy_partial,
; draw_sprite).  mirror_copy (mirror.s) makes the copy from the notes.
; ----------------------------------------------------------------------------
  .if BHW                          ; hardware (the ring): the Model B's mirror row
        .segment "ENGCODE"
mir_dirty:
        MIRDIRTY_BODY
  .endif

; ----------------------------------------------------------------------------
; lv_reset: a level's start -- both buffers invalid, no records, no dirty tiles
;   In:    none
;   Out:   BUF_CXH[0..1] = BUF_INVALID (scroll_validate redraws each buffer whole,
;          match_sprites keeps nothing and drops its records); RECCNT[0..1] = 0;
;          DIRTYCNT[0..1] = 0;  A = 0 (load_level stores it: nspr)
;   Uses:  A
;   Keeps: X Y
;   Pre:   bank 7 paged
; load_level's call (game.s); boot leaves this state to it (init.s).
; ----------------------------------------------------------------------------
        .segment "ENGCODE"
lv_reset:
        lda #BUF_INVALID
        sta BUF_CXH                ; a window x a buffer can never hold
        sta BUF_CXH+1
        lda #0                     ; (the caller stores this A: it must be 0)
        sta RECCNT
        sta RECCNT+1
        sta DIRTYCNT
        sta DIRTYCNT+1
        rts

; ---------------------------------------------------------------- the small tables
; The row multiples, i * ROWCHARS for i < MAXRINGROWS, in the kernel's bank 7 data
; (build_sections and ring_addr7 read them, kernel.s).  Sized MAXRINGROWS (32,
; the Master's ring) on both machines so bank 7's data lies alike (layoutcheck); the
; Model B's RINGROWS is 23 of them.
        .segment "KRNDATA"
        .assert RINGROWS <= MAXRINGROWS, error, "the row multiples are sized for MAXRINGROWS"
mul_rowlo:
.repeat MAXRINGROWS, i
        .byte <(i*ROWCHARS)
.endrepeat
mul_rowhi:
.repeat MAXRINGROWS, i
        .byte >(i*ROWCHARS)
.endrepeat

; ---------------------------------------------------------------- the sprite tables
        .segment "SPR4TAB"
        NIB_TABLES
        .segment "SPR5TAB"
        NIB_TABLES
