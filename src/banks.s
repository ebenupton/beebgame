; ============================================================================
; The engine's static tables and bank data, and the few routines that exist only
; here.  Everything a level brings -- tiles, map, sprites, directory, its tables --
; is loaded into the banks by ldprog.s.  The game's tables are its own (Cleo's
; gamedata.s).
; ============================================================================

; ---------------------------------------------------------------- the small tables
; Assembled, each in the bank of the code that indexes it: the row multiples are
; bank 7's (calc_ring, ringaddr7, the chain), the ring modulus bank 6's (ringaddr).
        .segment "KRNDATA"          ; (the kernel's: calc_ring and ringaddr7 are there)
        .assert RINGROWS <= 32, error, "the row multiples are sized for 32"
mulrowlo:                           ; (32 rows on both machines, the Master's ring, so
.repeat 32, i                       ; bank 7's data lies alike: the Model B reads 23)
        .byte <(i*ROWCHARS)
.endrepeat
mulrowhi:
.repeat 32, i
        .byte >(i*ROWCHARS)
.endrepeat

; ---------------------------------------------------------------- the sprite banks
; The expansion tables and SWAPTAB (the dot reversal) end both sprite banks, at the
; same addresses (defs.inc), so the prologue in bank 7 can name them for either.
.macro SWAP_TABLE
        .assert * = SWAPTAB, error, "SWAPTAB must be at SWAPTAB"
.repeat 256, xx                     ; four-dot reversal: bits 7<->4, 6<->5, 3<->0, 2<->1
        .byte ((xx & $88) >> 3) | ((xx & $44) >> 1) | ((xx & $22) << 1) | ((xx & $11) << 3)
.endrepeat
.endmacro
; 4-bit sprites: the game's expansion tables (its palette: nibtab.bin, L0TAB, L1TAB and
; NMASK, 768 bytes, from its asset step) and the dot reversal, in both sprite banks
.macro NIB_TABLES
        .assert * = L0TAB, error, "the expansion tables must be at L0TAB"
        .incbin "nibtab.bin", 0, 768
        SWAP_TABLE
.endmacro
        .segment "SPR4TAB"
        NIB_TABLES
        .segment "SPR5TAB"
        NIB_TABLES

; ---------------------------------------------------------------- the mirror's notes
; the mirror's range: A = the first window column written of the row the mirror
; follows, X = the last (0..79).  Those chars sit in the last slot row at wcxm on;
; only the ones up to char 79 are in it (the rest wrapped to slot row 0), and only
; those from wcxm are ever read (mirror.s).  Called by the tile blitter's head
; (bank 6: drawrect's head, in line) and the sprite prologue and copy_partial (bank 7:
; mirdirty): one body, twice (MIRDIRTY_BODY, engine/macros.s).
        .segment "TILBSS"
  .if BHW                           ; (the Master has no mirror: the hardware folds)
        .segment "ENGCODE"
mirdirty:
        MIRDIRTY_BODY
  .endif

        .segment "ENGCODE"          ; (the engine's per-level clear: load_level's)
lvreset:
        lda #$80                    ; both buffers invalid: an unreachable window x
        sta BUF_CXH                 ; (scroll_validate redraws them whole)
        sta BUF_CXH+1
        lda #0                      ; (the caller stores this A: it must be 0)
        sta RECCNT
        sta RECCNT+1
        sta DIRTYCNT
        sta DIRTYCNT+1
        rts

; ---------------------------------------------------------------- bank 7: the level
        .segment "ENGLVL"           ; the level's tables, loaded by ldprog.s (the
LV_ATTR0:   .res 256                ; objects go to main RAM: LV_OBJS, defs.inc)
LV_ALTCLS:  .res 256                ; alt class by tile id
LV_HDR:     .res 32                 ; header: lw, lh, nobj, the tile set's shape, and
                                    ; the game's own fields (tools/levelfile.py)
        .segment "ENGBSS"           ; the engine's: the sprite directory
; The directory's level part, by sprite id: the images' addresses, low bytes then high
; bytes -- 0 not in this level, bit 7 clear in bank 5.  The geometry is the game's
; (SPRG_*), the boxes' too.
SPR_TABLE:  .res 2*(BOXID0+BOXN)
DIR_LO      = SPR_TABLE
DIR_HI      = SPR_TABLE+BOXID0+BOXN
