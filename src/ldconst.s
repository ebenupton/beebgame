; ============================================================================
; ldconst.s -- the constants the loaders and the tests need that the linker does
; not list.  Not a program: build.sh assembles it for its .out lines alone (the
; object goes to /dev/null) and appends them to defs_ld.inc, which loader.s and
; ldprog.s include and test/*.mjs read beside labels.txt.  Assembled with the
; game's own flags (BHW and the rest), so defs.inc's and engine/defs.s's
; hardware conditionals resolve as they do in the game; the game's assets.inc
; and pads.inc come in with engine/defs.s.  Both machines, once each.
;
; OUTC name: prints `name = $XXXX` if the symbol is defined (the baker's
; BAKEITEM0, BG_*, the sprite banks' SPRC5_LEN and the like are a game's to
; define).
; ============================================================================
        .include "cpu.inc"
        .include "defs.inc"
        .include "engine/defs.s"

.macro OUTC name
  .ifdef name
        .out .sprintf("%s = $%04X", .string(name), name)
  .endif
.endmacro

; ---- the load-time program's and the boot loader's (ldprog.s, loader.s)
        OUTC IMG_GAME
        OUTC IMG_MENU
        OUTC LDOP_GAME
        OUTC LDOP_TITLE
        OUTC LDOP_OVER
        OUTC LDOP_IMAGE
        OUTC LDOP_IMGMASK
        OUTC LDR_RESUME
        OUTC ROMSEL_CPY
        OUTC STACKTOP
        OUTC BANKSBUF
        OUTC PIECE_LEN
        OUTC FIX_LEN
        OUTC WR_LEN
        OUTC PIECE_8271
        OUTC PIECE_1770
        OUTC PIECE_BANKMASK
        OUTC PIECE_HAZEL
        OUTC WR_INX
        OUTC TILES
        OUTC IMGTAB_LEN
        OUTC BG_WC
        OUTC BG_LINES
        OUTC BG_DX
        OUTC BG_DTY
        OUTC BG_OV
        OUTC BG_SKIP
        OUTC BG_LEN
        OUTC TILEBYTES
        OUTC HALFBYTES
        OUTC TILECHARS
        OUTC TILEPX_SHIFT
        OUTC TILESHIFT
        OUTC GH_TILE
        OUTC GL_COLMASK
        OUTC HPAIR_LEN
        OUTC FLATTAB_LEN
        OUTC TOFF
        OUTC NFLAT
        OUTC BAKEITEM0
        OUTC FLAT0
        OUTC BOXID0
        OUTC BOXN
        OUTC LDPROG
        OUTC STAGE
        OUTC STAGE_LVL
        OUTC MAP5
        OUTC LV_OBJS
        OUTC LV_PAGE0
        OUTC SPRC_BASE
        OUTC SPRC_LEN
        OUTC SPRC5_BASE
        OUTC SPRC5_LEN
        OUTC SPRX_LEN
        OUTC BOARD_STD
        OUTC BOARD_WATFORD
        OUTC BOARD_SOLIDISK
; ---- the screen's shape, for the tests (engine/defs.s)
        OUTC BARADDR
        OUTC BARROWS
        OUTC ROWCHARS
        OUTC ROWBYTES
        OUTC RINGROWS
        OUTC RINGCHARS
        OUTC RINGBYTES
        OUTC RING_A
        OUTC RING_B
        OUTC RINGBASE
        OUTC MIRR_A
        OUTC CLEAR0
        OUTC VISROWS
        OUTC BUFROWS
        OUTC BUF_INVALID
        OUTC RECSZ
