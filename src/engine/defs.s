; ============================================================================
; engine/defs.s -- the engine's constants
;
; Included first by engine.s, before vars.s, on both machines; ldconst.s includes
; it too, to print the constants the loaders and the tests read into defs_ld.inc.
; No code and no storage: equates, and the asserts that bind them.  The chips'
; registers are hw.inc's and the addresses shared with the loaders defs.inc's (both
; are included before this, by main.s); here are the game's own shape and the
; engine's numbers.
;
; Sections:
;   hardware        ROMSEL's copy, the MODE 1 palette
;   banks           the four banks' numbers and what each holds
;   screen shape    rings, mirrors, the bar, the composed row, machine by machine
;   sprites         the slots, the sprite record (SPRREC), the flags, the blitters
;   misc            DIRTYMAX, BUF_INVALID, FLIPWAIT, the key bits, the sound effects
;   frame shape     the 312-line frame: BARROWS, QROWS, QVSYNC, the idle T1 period
;   section table   SECTAB's entries (SE_*), NSECT, SECT_NONE
; Every .if BHW in this file is hardware: the display memory and the CRTC frame.
; ============================================================================
        .include "assets.inc"      ; the game's packer's: MAXSPRDEF, NFLAT, FLAT0,
                                   ;  TOFF, TILES, MAP5, B4_DATA_END...
        .include "pads.inc"

; ---------------------------------------------------------------- hardware
ROMSEL_CPY = $FD                   ; ROMSEL's copy: every switch writes it first and
                                   ;  the interrupt restores ROMSEL from it (low.s).
                                   ;  Zero page's last but two: $FC is the MOS's
                                   ;  interrupt A (hw.inc MOS_IRQA), $FE-$FF crtcb
                                   ;  (vars.s ZPTOP)
; The MODE 1 palette (kernel.s set_palette): logical colours 0..3 = black, cyan,
; magenta, yellow.  A logical colour c is written to four palette indices, PALIDX_c
; with any of the don't-care bits 2 and 0 (hw.inc LCOL_IDX_B1, LCOL_IDX_B0);
; PALPHYS holds each logical colour's physical one, a nibble a colour.
LCOL_CYAN      = 1
LCOL_MAGENTA   = 2
LCOL_YELLOW    = 3
PALIDX_CYAN    = (LCOL_CYAN & 2) / 2 * LCOL_IDX_B1 | (LCOL_CYAN & 1) * LCOL_IDX_B0
PALIDX_MAGENTA = (LCOL_MAGENTA & 2) / 2 * LCOL_IDX_B1 | (LCOL_MAGENTA & 1) * LCOL_IDX_B0
PALIDX_YELLOW  = (LCOL_YELLOW & 2) / 2 * LCOL_IDX_B1 | (LCOL_YELLOW & 1) * LCOL_IDX_B0
PALPHYS = PCOL_BLACK | (PCOL_CYAN << (4*LCOL_CYAN)) | (PCOL_MAGENTA << (4*LCOL_MAGENTA)) | (PCOL_YELLOW << (4*LCOL_YELLOW))

; ---------------------------------------------------------------- banks
; The code's numbers, 4..7, on both machines: the boot loader patches in the sockets
; it found RAM in (cpu.inc BANKREF).
;   4  the sprite row loop and its three blitters (sprloops.s); sprites; the
;      expansion tables and SWAPTAB (defs.inc L0TAB...)
;   5  the same loop and tables; gather5 (gather.s); sprites; the map at MAP5
;   6  bank6_entry and draw_rect_clip at its start, the tile blitter and the ring
;      work (tiles.s); the level's tiles from TILES (assets.inc)
;   7  the kernel at the top, resident; below it the game's image -- the level's
;      tables, the game's logic and loop, the engine's frame and sprite code -- or,
;      while the menus run, the menus' image (cfg/banks.cfg)
BANK_SPR    = 4
BANK_TIL1   = 5                    ; the second sprite bank
BANK_TILES  = 6
BANK_LVL    = 7
BANK_MAP    = 5                    ; = BANK_TIL1: the map, with gather5 beside it
MAXRINGROWS = 32                   ; the Master's RINGROWS: bank 7's row multiples
                                   ;  (banks.s mul_rowlo/hi) are this long on both
                                   ;  machines, so the kernel's data lies alike

; ============================================================================
; Screen shape
;
; Each buffer is a ring of ROWCHARS-char rows (ROWBYTES = 640 bytes a row), with the
; BARROWS-row status bar displayed above it.  The window (VISROWS rows, plus the
; bottom partial's row: BUFROWS) slides round the ring; the rupture chain (kernel.s
; build_sections) displays it.
;
; Model B: 32K of main RAM, and from $0300 up all of it is the display while play
; runs (a load stages files in it, black: defs.inc STAGE).  Two rings of 23 slots,
; each with a mirror row below it (the chain reads the row that straddles a ring's
; end from there: mirror.s), and the 2-row bar.  Below $0300 are zero page, the
; stack and the low RAM every bank calls (low.s).
;
;   $0300-$07FF  bar         2 rows, one for both buffers    BARADDR
;   $0800-$0A7F  mirror A    1 row                           MIRR_A  (CLEAR0 from here)
;   $0A80-$43FF  ring A      23 rows: buffer 0               RING_A = RING0
;   $4400-$467F  mirror B    1 row                           RING_B - ROWBYTES
;   $4680-$7FFF  ring B      23 rows: buffer 1               RING_B
;
; Master: the ring is the whole 20K the CRTC wraps, in main RAM (buffer 0) and
; shadow RAM (buffer 1) at the same addresses; ACCCON D picks which is displayed.
;
;   $2880-$2AFF  QBLANK      a row of zeros (init.s): Q's first scanline
;   $2B00-$2FFF  bar         2 rows, main RAM only, single-buffered, scanned with D = 0
;   $3000-$7FFF  ring        32 rows: main = buffer 0, shadow = buffer 1    RINGBASE
;                            30 visible + the bottom partial's row + the composed row
; ============================================================================
ROWCHARS   = 80
  .if BHW                          ; hardware: two software rings
RINGROWS   = 23
VISROWS    = 21                    ; 168 lines, 84 game pixel rows
  .else                            ; hardware: the hardware-wrapped ring
RINGROWS   = 32                    ; the whole 20K: the CRTC's fold IS the ring wrap
VISROWS    = 30                    ; 240 lines, 120 game pixel rows.  31 rows held
                                   ;  plus the composed row fill the ring exactly
  .endif
BUFROWS    = VISROWS + 1           ; rows a buffer holds: the visible plus the
                                   ;  bottom partial's
ROWBYTES   = ROWCHARS*CHARBYTES
RINGCHARS  = ROWCHARS*RINGROWS
RINGBYTES  = RINGCHARS*CHARBYTES
  .if BHW                          ; hardware: the Model B's display memory
; ---- Model B: the rings, their mirrors, the bar
; 23 x 640 = $3980 bytes is not whole pages, so the fold is 16-bit -- but both ring
; ENDS are page aligned, which keeps the fold TEST a high-byte compare (macros.s
; ringtest, ringup), and both bases are at xx80, so the low byte's fold is a
; subtraction of $80.
RING_A     = $0A80
RING_B     = $4680
RING0      = RING_A                ; buffer 0's ring: the menus' work buffer
CLEAR0     = MIRR_A                ; the menus' clear runs from here to $8000
MIRR_A     = RING_A - ROWBYTES     ; ring A's mirror, the row under its base
RINGEND_A  = RING_A + RINGBYTES
RINGEND_B  = RING_B + RINGBYTES
        .assert RINGEND_B = $8000 && (RINGEND_A & $FF) = 0, error, "the ring ends must be page aligned"
        .assert (<RING_A) = $80 && (<RING_B) = $80, error, "ringup's low-byte fold assumes bases at xx80"
BARADDR    = $0300
        .assert MIRR_A = BARADDR + BARROWS*ROWBYTES, error, "mirror A must follow the bar"
; Q's start (kernel.s build_sections, @sq2): a 6845 shows a frame's first scanline
; whatever R6 says, so Q's line 0 shows under the picture.  The Model B has no spare
; black line, so Q starts in the bar, at char QBLANK_CHAR: its line 0 is bar row 0's
; line 0 from that char to char 79 and then row 1's from char 0 (the bar is one run
; of memory).  Q's step blacks the palette for it (kernel.s killpal): yellow, then
; magenta, then cyan, each colour's four writes landing before that colour first
; shows along the line (test/crtctime.mjs checks the writes' timing).
QBLANK_CHAR = 45
QBLANK     = BARADDR + QBLANK_CHAR*CHARBYTES
  .else                            ; hardware: the Master's display memory
; ---- Master: the ring, the composed row, the bar
; The bar at $2B00 (below the screen, main RAM, single-buffered), then each buffer's
; ring at $3000-$7FFF, main and shadow.  The ring is the entire screen and the CRTC
; folds it for free: an address that runs off $8000 comes back to $3000, the ring
; base, so a displayed row may straddle the end and no mirror copy is needed.  That
; is the whole reason RINGROWS is 32: it is the size of the region the hardware
; wraps, not a choice.
BUF0       = $3000
        .assert (RINGCHARS & $FF) = 0, error, "the ring folds on a high-byte compare"
RINGBASE   = BUF0
RING0      = RINGBASE              ; buffer 0's ring: the menus' work buffer
CLEAR0     = RINGBASE              ; the menus' clear runs from here to $8000
RINGEND    = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything
; below $3000 is only main RAM to the CRTC (the bar gets away with it by being single
; buffered and scanned with D = 0).  It lives in the one ring row the window does not
; hold: the row ABOVE it, ring chars [ring_s + BUFROWS*80, ring_s + RINGCHARS) =
; [ring_s - 80, ring_s).  The window start is char granular (ring_s = wcy*80 + wcx),
; so that row is not a slot of the row tables: its column c is ring char
; (ring_s + c + RINGCHARS - 80) mod RINGCHARS, a constant offset from its source,
; which makes it a ring row like any other.  It is window aligned, not slot aligned
; -- a row-aligned slot (barq + 31) would overlap the window's last row by
; ring_s mod 80 chars with BUFROWS at 31 -- so its copy may fold at $8000 mid-run
; (frame.s copy_partial).
;
; The bar is BELOW the screen in memory, in main RAM, and there is only one of it.
; The CRTC's start address is just RAM/8, so it can scan from anywhere under $8000
; -- but with shadow selected for display (ACCCON D = 1) everything under $3000 reads
; HAZEL/ANDY instead of main RAM, so the bar's section runs with D = 0 and the
; playfield's with D = the buffer being shown (kernel.s: the vsync and the D step).
; Single-buffered: it is drawn where it is displayed, in the QROWS - QVSYNC rows
; between the vsync and its first scanned line (frame.s render_frame).
BARADDR    = $2B00
; Q's start (kernel.s build_sections, @sq2): a 6845 shows a frame's first scanline
; whatever R6 says, so Q's line 0 shows under the picture -- from here, a row of zeros
; just below the bar (init.s zeroes it), in main RAM: Q's step puts D back to 0 before
; that scanline (kernel.s irq_handler).
QBLANK     = BARADDR - ROWBYTES
        .assert LV_OBJS + OBJ_BYTES*OBJ_MAX <= QBLANK, error, "QBLANK: the level's objects run into it"
CRTCBASE   = RINGBASE / CHARBYTES  ; the CRTC counts characters: the ring starts here
CRTCB_A    = CRTCBASE              ; each buffer's ring base, as the CRTC counts: one
CRTCB_B    = CRTCBASE              ;  ring, main and shadow (ACCCON D picks)
  .endif
WINPX      = ROWCHARS*2            ; the window's width in game pixels
VISLINES   = VISROWS*CHARLINES
; GATHERN: the tiles a row's gather can hold -- a window's, and one more for a run
; starting mid-tile
GATHERN    = ROWCHARS/TILECHARS + 1
RINGMOD_SPAN = RINGROWS*5          ; (Model B) ringmod's table is this long, five
                                   ;  rings: two subtractions bring any row under it
                                   ;  (macros.s ringmod, tiles.s ringmod_tab)

; ---------------------------------------------------------------- sprites
; MAXSPR, the sprite slots: the build's (-D MAXSPR=n, tools/build.sh) over the
; game's assets.inc MAXSPRDEF (the packer sizes it from the levels); 28 when neither
; sets it.
  .ifndef MAXSPR
    .ifdef MAXSPRDEF
MAXSPR     = MAXSPRDEF
    .else
MAXSPR     = 28
    .endif
  .endif
MAXREC     = MAXSPR

; ---- the sprite record (SPRREC, vars.s)
; Each buffer keeps a record for each sprite it drew (frame.s draw_sprites): id,
; x (2), y (2), then the screen rectangle erase_old redraws -- its map char column,
; char row, width in chars (0: nothing drawn) and height in char rows, bit 7 set when
; it was cut at a window edge.
;
;   TIGHTBSS = 0 (the build's default: cpu.inc): 10-byte records, one after another
;     (a field is its offset in the record)
;     0 id  1-2 x  3-4 y  5-6 column (REC_CX)  7 row  8 width  9 height | clipped << 7
;   TIGHTBSS = 1: 9 bytes, stored as arrays, one byte of each by record: every field
;     is 2*MAXREC bytes, buffer 0's MAXREC then buffer 1's.  recb (recp's byte) is the
;     buffer's first record, rq (rp's) the record's index.  The column's high bits
;     (a map is 1024 chars wide at most: 2 bits) are packed into the height's byte,
;     bits 5-6 (the height is BUFROWS at most).
  .if TIGHTBSS
RECSZ      = 9
REC_ID     = SPRREC
REC_XL     = SPRREC+2*MAXREC
REC_XH     = SPRREC+4*MAXREC
REC_YL     = SPRREC+6*MAXREC
REC_YH     = SPRREC+8*MAXREC
REC_CX     = SPRREC+10*MAXREC      ; the column's low byte
REC_CY     = SPRREC+12*MAXREC
REC_W      = SPRREC+14*MAXREC
REC_H      = SPRREC+16*MAXREC      ; height | column high << 5 | clipped << 7
recb       = recp                  ; the buffer's first record
rq         = rp                    ; the current record
        .assert BUFROWS < 32, error, "TIGHTBSS: a record's height is 5 bits"
        .assert 2*MAXREC <= 256, error, "TIGHTBSS: records are indexed by a register"
  .else
RECSZ      = 10
REC_CX     = 5                     ; (2 bytes)
REC_CY     = 7
REC_W      = 8
REC_H      = 9                     ; height | clipped << 7
  .endif
REC_CLIP   = $80                   ; REC_H bit 7: cut at a window edge
REC_HMASK  = $1F                   ; (TIGHTBSS) REC_H bits 0-4: the height,
REC_CXSHIFT = 5                    ;  bits 5-6 the column's high bits
; match_sprites' verdict on a record (KEEP, vars.s): neither, a box star where one
; was, the same sprite in the same place
KEEP_BOX   = 1
KEEP_SAME  = 2
; the sprite flags (frame.s draw_sprite: the game's sprg_fl by shape, with SPRGFL)
SPF_MIRROR  = 1                    ; drawn mirrored
SPF_FULLRES = 2                    ; every scanline stored (a box), not one row in two
SPF_COPY    = 8                    ; the copy blitter: screen bytes, opaque
; the row loop's blitters (sprloops.s): each has SPRTAB_N entries in sprrow_tab, and
; sp_disp (the prologue's) is the sprite's blitter's first
SPRTAB_N   = 9                     ; a cell's 8 first lines, and the partial loop
SPRDISP_FN = 0                     ; the 4-bit blitter
SPRDISP_FM = 2*SPRTAB_N            ; mirrored
SPRDISP_FC = 4*SPRTAB_N            ; the copy blitter

; ---------------------------------------------------------------- misc
; DIRTYMAX: the dirty tiles a buffer can queue (frame.s mark_dirty).  A switch marks
; two tiles for each row of its height at once (the game's ob_switch); past this the
; buffer is redrawn whole instead.
DIRTYMAX   = 20
; BUF_CXH's mark for a buffer to be redrawn whole: a window x it can never hold
BUF_INVALID = $80
; a flip waits this many vsyncs after the last (render_frame asks, the vsync takes)
FLIPWAIT   = 2

; key bits (keys; the game's keymap.inc says which keys set each)
K_LEFT     = 1
K_RIGHT    = 2
K_UP       = 4
K_DOWN     = 8
K_FIRE     = 16

; a sound effect (sfx_tab, the game's; kernel.s sound_tick): steps of three bytes
; for the SN76489 and the frames to hold them, then SFX_END -- which, written to the
; chip as the last step's first byte, is the noise channel off
SFXSTEP_LEN = 4
SFX_END    = $FF
        .assert SFX_END = SN_LATCH | SN_VOL | (SN_NOISE << SN_CHSHIFT) | SN_ATT_OFF, error, "SFX_END doubles as the noise channel's silence"

; ---------------------------------------------------------------- frame shape
; A PAL frame of 312 lines, 39 char rows: the bar, the playfield, then QROWS blank
; rows (Q) with the vsync in them.
PAL_LINES  = 312
FRAMEROWS  = PAL_LINES/CHARLINES   ; 39
BARROWS    = 2                     ; the status bar
; QROWS: the blank rows after the picture
QROWS      = FRAMEROWS - VISROWS - BARROWS
  .if BHW                          ; hardware: the CRTC frame
; Model B: 16 Q rows, the vsync on the 8th: the bar starts 8 rows (64 lines) after it.
QVSYNC     = 8
  .else                            ; hardware: the CRTC frame
; Master: 7 Q rows, the vsync on the 3rd: four rows (32 lines) between the vsync and
; the bar -- the time the bar is drawn in -- and three below.  The Master MOS's own
; MODE 1 frame has R7 = 35 of R4 = 38, four rows too: the picture's top sits where
; the MOS puts it.
QVSYNC     = 3
  .endif
R7_NEVER   = 30                    ; a section's R7 its rows never reach: no vsync in
                                   ;  it (every section's but Q's, whose is QVSYNC)
IDLE_LINES = 40                    ; the T1 period Q's entry carries (and the one
                                   ;  before it, and take_over's first): the chain
                                   ;  rests on Q, re-running Q's step should that
                                   ;  fall due before the vsync restarts T1

; ---------------------------------------------------------------- the section table
; SECTAB (vars.s): each buffer's chain, NSECT entries of SECENT bytes (kernel.s
; build_sections lays them out and says what each field means)
SECENT     = 8                     ; an entry's bytes:
SE_R12     = 0                     ;  the NEXT section's start address (high byte first)
SE_R13     = 1
SE_R4      = 2                     ;  this section's shape
SE_R9      = 3
SE_R6      = 4
SE_R7      = 5
SE_T1L     = 6                     ;  the NEXT section's duration, as a T1 latch value
SE_T1H     = 7
NSECT      = 6                     ; T, A, P1, M, P2, Q at most (the Model B splits
                                   ;  the playfield at the ring's end)
SECBYTES   = NSECT*SECENT          ; a buffer's chain: buffer 1's starts here
SECT_NONE  = $FF                   ; BUF_QS/BUF_KS: no entry
