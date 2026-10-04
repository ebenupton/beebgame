; ============================================================================
; engine/defs.s -- the engine's constants
;
; Included first by engine.s (before vars.s), on both machines.  No code and no
; storage: the hardware's registers, the bank numbers, the shape of the screen on each
; machine, the sprite record's layout, the key bits and the shape of the frame.
;
; The display, in short:
;   - double-buffered ring framebuffers: main and shadow RAM, 20K each, on the
;     Master; two rings in main RAM on the Model B
;   - vertical rupture: a fixed status-bar section + a hardware-scrolled playfield,
;     with 2-scanline fine vertical scroll and 1-character horizontal scroll
;   - tiles are 8x8 game pixels = 4 chars x 2 char rows (64 bytes), in sideways RAM
;
; Sections:
;   hardware        the chips and the MOS (hw.inc), ROMSEL's copy, the palette
;   banks           what is in banks 4-7
;   screen shape    rings, mirrors, the bar and the composed row, machine by machine
;   sprites         the slot count, the sprite record (SPRREC) layout, the flags
;   misc            DIRTYMAX, the key bits, the dirty-buffer mark, the sound effects
;   frame shape     BARROWS, QROWS, QVSYNC: the 312-line frame; the section table
; ============================================================================
        .include "assets.inc"
        .include "pads.inc"

; ---------------------------------------------------------------- hardware
; (the chips' registers and bits and the MOS's addresses are hw.inc's: defs.inc
; includes it first, for the loaders' sake)
ROMSEL_CPY= $FD                    ; ROMSEL's copy: the interrupt restores it (zero page's
                                  ;  last but two; $FC is the ROM's interrupt entry's A:
                                  ;  hw.inc MOS_IRQA)
; the MODE 1 palette (set_palette): logical 0..3 = black, cyan, magenta, yellow.  A
; logical colour's four palette indices are PALIDX_x | (0..3 in the don't-care bits 2
; and 0); PALPHYS holds the physical colour of each logical one, a nibble a colour
LCOL_CYAN    = 1
LCOL_MAGENTA = 2
LCOL_YELLOW  = 3
PALIDX_CYAN    = (LCOL_CYAN & 2) / 2 * LCOL_IDX_B1 | (LCOL_CYAN & 1) * LCOL_IDX_B0
PALIDX_MAGENTA = (LCOL_MAGENTA & 2) / 2 * LCOL_IDX_B1 | (LCOL_MAGENTA & 1) * LCOL_IDX_B0
PALIDX_YELLOW  = (LCOL_YELLOW & 2) / 2 * LCOL_IDX_B1 | (LCOL_YELLOW & 1) * LCOL_IDX_B0
PALPHYS = PCOL_BLACK | (PCOL_CYAN << (4*LCOL_CYAN)) | (PCOL_MAGENTA << (4*LCOL_MAGENTA)) | (PCOL_YELLOW << (4*LCOL_YELLOW))

; ---------------------------------------------------------------- banks
; The same numbers on both machines (the sockets are patched at boot):
;   4  the sprite row loop and blitters, sprites, the expansion tables and SWAPTAB
;   5  the same, gather5, sprites, the map at $9C00
;   6  bank6_entry/draw_rect_clip, the tile blitter and the ring work, the level's
;      tiles from $8600
;   7  the kernel at the top (resident); below it the game's image -- the level's
;      tables, then the logic, the game loop and the rest of the renderer -- or,
;      during the menus, the menus' image
BANK_SPR  = 4
BANK_TIL1 = 5                      ; the second sprite bank
BANK_TILES= 6                      ; every level's tile data fits one bank
BANK_LVL  = 7
BANK_MAP  = 5                      ; the map, and the gather that reads it in place
MAXRINGROWS = 32                   ; the Master's ring: bank 7's row tables are sized for
                                    ;  it on both machines, so the data lies alike

; ============================================================================
; Screen shape
;
; Each buffer is a ring of 80-char rows (640 bytes a row), with the 2-row status bar
; displayed above it.  The window (VISROWS rows, plus the bottom partial's row: BUFROWS)
; slides round the ring; the rupture chain (kernel.s build_sections) displays it.
;
; Model B: 32K of main RAM, and all but 768 bytes of it is the display.  Two rings of
; 23 slots, each with a mirror row below it (the rupture chain reads the row that
; straddles the ring end from there: see docs/DESIGN.md), and the 2-row bar.  Nothing
; else lives in main RAM from $0300 to $8000 (the code every bank calls is the low RAM
; below it: low.s).
;
;   $0300-$07FF  bar         2 rows, one for both buffers   BARADDR
;   $0800-$0A7F  mirror A    1 row                          MIRR_A   (CLEAR0 from here)
;   $0A80-$43FF  ring A      23 rows: buffer 0              RING_A = RING0
;   $4400-$467F  mirror B    1 row
;   $4680-$7FFF  ring B      23 rows: buffer 1              RING_B
;
; Master: the ring is the whole 20K the CRTC wraps, in main RAM (buffer 0) and shadow
; RAM (buffer 1) at the same addresses; ACCCON D picks which one is displayed.
;
;   $2B00-$2FFF  bar         2 rows, main RAM only, single-buffered, scanned with D = 0
;   $3000-$7FFF  ring        32 rows: main = buffer 0, shadow = buffer 1  (RINGBASE)
;                            30 visible + the bottom partial's row + the composed row
; ============================================================================
ROWCHARS  = 80
  .if BHW
; ---- Model B: two 23-row rings in main RAM
RINGROWS  = 23
VISROWS   = 21                     ; 168 lines = 84 game px
  .else
; ---- Master: one 32-row ring, main and shadow
; VISROWS: 240 lines = 120 game px (the original is 108: a 128-line phone screen less
; a 20-line HUD).  30 fills the ring exactly: 31 held + the composed row.
RINGROWS  = 32                     ; the whole 20K: the hardware fold IS the ring wrap
VISROWS   = 30                     ; visible char rows
  .endif
BUFROWS   = VISROWS + 1            ; rows held: the visible ones plus the bottom partial's
ROWBYTES  = ROWCHARS*8
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = RINGCHARS*8
  .if BHW
; ---- Model B: the rings, their mirrors, the bar
; 23 x 640 = $3980 is not a whole number of pages, so the fold is 16-bit -- but both
; ring ENDS are page aligned, which keeps the fold TEST a byte compare (ringup), and
; both bases are at xx80, which makes the low byte's fold a subtraction of $80.
RING_A    = $0A80
RING_B    = $4680
RING0     = RING_A                 ; buffer 0's ring (the menus' too)
CLEAR0    = MIRR_A                 ; the menus' clear: mirrors and rings, to $8000
MIRR_A    = RING_A - ROWBYTES      ; ring A's mirror: the row just under its base
RINGEND_A = RING_A + RINGBYTES
RINGEND_B = RING_B + RINGBYTES
.assert RINGEND_B = $8000 && (RINGEND_A & $FF) = 0, error, "the ring ends must be page aligned"
.assert (<RING_A) = $80 && (<RING_B) = $80, error, "ringup's low-byte fold assumes bases at xx80"
BARADDR   = $0300
.assert MIRR_A = BARADDR + BARROWS*ROWBYTES, error, "mirror A must follow the bar"
; Q's start (kernel.s build_sections): the 6845 shows a frame's first scanline whatever
; R6 says, so Q's line 0 shows under the picture.  The Model B has no spare line of
; black, so it is the bar's line 0 from its 45th char (row 0's to 79, row 1's from 0 to
; 44) and Q's step blacks the palette for it (kernel.s): there its colours first show
; late enough for the writes -- yellow and magenta from the 9th char (the score's digits,
; whatever they are), cyan from the 39th (the icon under the lives).
QBLANK    = BARADDR + 45*8
  .else
; ---- Master: the ring, the composed row, the bar
; The bar at $2B00 (below the screen, main RAM, single-buffered), then each buffer's
; ring at $3000-$7FFF, main and shadow.  The ring is the entire screen and the CRTC
; folds it for free: an address that runs off $8000 comes back to $3000, the ring
; base, so a displayed row may straddle the end and no mirror copy is needed.  That is
; the whole reason RINGROWS is 32 -- it is not a choice, it is the size of the region
; the hardware wraps.
BUF0      = $3000
.assert (RINGCHARS & $FF) = 0, error, "the ring folds on a high-byte compare"
RINGBASE  = BUF0
RING0     = RINGBASE               ; buffer 0's ring (the menus' too)
CLEAR0    = RINGBASE               ; the menus' clear: buffer 0's ring, to $8000
RINGEND   = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything
; below $3000 is only main RAM to the CRTC (the bar gets away with it by being single
; buffered and scanned with D = 0).  It lives in the one ring row the window does not
; hold: the row ABOVE it, ring chars [ring_s + BUFROWS*80, ring_s + RINGCHARS) =
; [ring_s - 80, ring_s).  The window start is char granular (ring_s = wcy*80 + wcx), so
; that row is not a slot in the row tables: its column c is ring char
; (ring_s + c + RINGCHARS - 80) mod RINGCHARS, a constant offset from its source, which
; makes it a ring row like any other.  It is window aligned, not slot aligned -- a
; row-aligned slot (barq + 31) would overlap the window's last row by ring_s mod 80
; chars with BUFROWS at 31 -- so its copy may fold at $8000 mid-run (copy_partial).
;
; The bar is BELOW the screen in memory, in main RAM, and there is only one of it.
; The CRTC's start address is just RAM/8, so it can scan from anywhere under $8000 --
; but with shadow selected for display (ACCCON D = 1) everything under $3000 reads
; HAZEL/ANDY instead of main RAM, so the bar's section runs with D = 0 and the
; playfield's with D = the buffer being shown.  Single-buffered: it is drawn where it
; is displayed, inside the 40 lines between vsync and the first scanned bar line.
BARADDR   = $2B00
; Q's start (kernel.s build_sections): the 6845 shows a frame's first scanline whatever
; R6 says, so Q's line 0 shows under the picture -- from here, a row of zeros just below
; the bar (boot's), in main RAM: Q's step puts D back to 0 before that scanline.
QBLANK    = BARADDR - ROWBYTES
.assert LV_OBJS + OBJ_BYTES*OBJ_MAX <= QBLANK, error, "QBLANK: the level's objects run into it"
CRTCBASE  = RINGBASE / 8           ; the CRTC counts characters, so the ring starts here
CRTCB_A   = CRTCBASE               ; each buffer's ring base, as the CRTC counts: one
CRTCB_B   = CRTCBASE               ;  ring, main and shadow (ACCCON D picks)
  .endif
WINPX     = ROWCHARS*2             ; window width in game pixels
VISLINES  = VISROWS*CHARLINES
GATHERN   = ROWCHARS/TILECHARS + 1 ; the tiles a row's gather can hold: a window's, and
                                    ;  the one more a run starting mid-tile takes

; ---------------------------------------------------------------- sprites
; MAXSPR, the sprite slots: the build's (-D MAXSPR=n, build.sh) over the game's
; assets.inc MAXSPRDEF (Cleo sizes it from its levels); 28 when neither sets it.
  .ifndef MAXSPR
    .ifdef MAXSPRDEF
MAXSPR    = MAXSPRDEF
    .else
MAXSPR    = 28
    .endif
  .endif
MAXREC    = MAXSPR

; ---- the sprite record (SPRREC)
; Each buffer keeps a record for each sprite it drew: id, x (2), y (2), then the screen
; rectangle erase_old redraws -- its map char column, char row, width in chars (0:
; nothing drawn) and height in char rows, bit 7 set when it was cut at a window edge.
;
;   TIGHTBSS = 0: 10-byte records, one after another (field = offset in the record)
;     0 id  1-2 x  3-4 y  5-6 column (REC_CX)  7 row  8 width  9 height | clipped << 7
;   TIGHTBSS = 1: 9 bytes, stored as arrays, one byte of each by record: every field
;     is 2*MAXREC bytes, buffer 0's MAXREC then buffer 1's.  recb (recp's byte) is the
;     buffer's first record, rq (rp's) the record's index.  The column's high bits (a
;     map is 1024 chars wide at most: 2 bits) are packed into the height's byte, bits
;     5-6 (the height is BUFROWS at most).
  .if TIGHTBSS
RECSZ     = 9
REC_ID    = SPRREC
REC_XL    = SPRREC+2*MAXREC
REC_XH    = SPRREC+4*MAXREC
REC_YL    = SPRREC+6*MAXREC
REC_YH    = SPRREC+8*MAXREC
REC_CX    = SPRREC+10*MAXREC       ; the column's low byte
REC_CY    = SPRREC+12*MAXREC
REC_W     = SPRREC+14*MAXREC
REC_H     = SPRREC+16*MAXREC       ; height | column high << 5 | clipped << 7
recb      = recp                   ; the buffer's first record
rq        = rp                     ; the current record
        .assert BUFROWS < 32, error, "TIGHTBSS: a record's height is 5 bits"
        .assert 2*MAXREC <= 256, error, "TIGHTBSS: the records are indexed by a register"
  .else
RECSZ     = 10
REC_CX    = 5                      ; (2 bytes)
REC_CY    = 7
REC_W     = 8
REC_H     = 9                      ; height | clipped << 7
  .endif
REC_CLIP  = $80                    ; REC_H bit 7: cut at a window edge
REC_HMASK = $1F                    ; (TIGHTBSS) REC_H bits 0-4: the height,
REC_CXSHIFT = 5                    ;  bits 5-6 the column's high bits
; match_sprites' verdict on a record (KEEP): neither, a box star where one was, the
; same sprite in the same place
KEEP_BOX  = 1
KEEP_SAME = 2
; the sprite flags (the game's sprgeom.inc sprg_fl, by shape; draw_sprite)
SPF_MIRROR  = 1                    ; drawn mirrored
SPF_FULLRES = 2                    ; every scanline stored (a box), not one row in two
SPF_COPY    = 8                    ; the copy blitter: screen bytes, opaque
; the row loop's blitters: each has SPRTAB_N entries in sprrow_tab (sprloops.s), and
; sp_disp (the prologue's) is the sprite's blitter's first
SPRTAB_N   = 9                     ; a cell's 8 first lines, and the partial loop
SPRDISP_FN = 0                     ; the 4-bit blitter
SPRDISP_FM = 2*SPRTAB_N            ; mirrored
SPRDISP_FC = 4*SPRTAB_N            ; the copy blitter

; ---------------------------------------------------------------- misc
; DIRTYMAX: the dirty tiles a buffer can queue.  A switch marks 2 x its height at
; once, 18 for the tallest (level 7's main map); past this the buffer is redrawn
; whole (mark_dirty).
DIRTYMAX = 20
; BUF_CXH's mark for a buffer to be redrawn whole: a window x it can never hold
BUF_INVALID = $80
; a flip waits this many vsyncs after the last (render_frame asks, the vsync takes)
FLIPWAIT = 2

; key bits (keys)
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16

; a sound effect (sfx_tab, the game's): steps of three bytes for the SN76489 and the
; frames to hold them, then SFX_END -- which, written to the chip as the last step's
; first byte, is the noise channel off
SFXSTEP_LEN = 4
SFX_END     = $FF
        .assert SFX_END = SN_LATCH | SN_VOL | (SN_NOISE << SN_CHSHIFT) | SN_ATT_OFF, error, "SFX_END doubles as the noise channel's silence"

; ---------------------------------------------------------------- frame shape
; A 312-line frame of 39 char rows: the bar, the playfield, then QROWS blank rows (Q)
; with the vsync in them.
FRAMEROWS = 312/CHARLINES          ; a PAL frame's char rows
BARROWS = 2                        ; the status bar
QROWS  = FRAMEROWS - VISROWS - BARROWS   ; blank rows after the display: 312 lines in all
  .if BHW
; Model B: 16 Q rows.  The picture starts 64 lines after the vsync, 4 lines below
; where a MODE 1 screen sits.
QVSYNC = 8                         ; vsync at Q row 8 of 16
  .else
; Master: 7 Q rows.  Four rows (32 lines) between the vsync and the bar, which is
; where the bar is drawn, and three below.  Measured against the Master MOS's own
; standard frame (R7 = 35): the picture sits exactly where it does.
QVSYNC = 3                         ; vsync at Q row 3 of 7
  .endif
R7_NEVER = 30                      ; a section's R7 its rows never reach: no vsync in it
                                    ;  (every section's but Q's, whose is QVSYNC)
IDLE_LINES = 40                    ; the T1 period Q's entry carries (and start-up's first):
                                    ;  the chain rests on Q, re-running its step should
                                    ;  that fall due before the vsync restarts T1

; ---------------------------------------------------------------- the section table
; SECTAB (vars.s): each buffer's chain, NSECT entries of SECENT bytes (kernel.s
; build_sections lays them out)
SECENT   = 8                       ; an entry's bytes:
SE_R12   = 0                       ;  the NEXT section's start address (high byte first)
SE_R13   = 1
SE_R4    = 2                       ;  this section's shape
SE_R9    = 3
SE_R6    = 4
SE_R7    = 5
SE_T1L   = 6                       ;  the NEXT section's duration, as a T1 latch value
SE_T1H   = 7
NSECT    = 6                       ; T, A, P1, M, P2, Q at most (the Model B's split run)
SECBYTES = NSECT*SECENT            ; a buffer's chain: buffer 1's starts here
SECT_NONE = $FF                    ; BUF_QS/BUF_KS: no entry
