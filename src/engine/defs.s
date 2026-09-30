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
;   hardware        the CRTC, the video ULA, ROMSEL, ACCCON, the system VIA, IRQ1V
;   banks           what is in banks 4-7
;   screen shape    rings, mirrors, the bar and the composed row, machine by machine
;   sprites         the slot count and the sprite record (SPRREC) layout
;   misc            DIRTYMAX, the key bits
;   frame shape     BARROWS, QROWS, QVSYNC: the 312-line frame
; ============================================================================
        .include "assets.inc"
        .include "pads.inc"

; ---------------------------------------------------------------- hardware
CRTC_IDX  = $FE00                 ; 6845: register number
CRTC_DAT  = $FE01                 ; 6845: register data
ULA_CTRL  = $FE20                 ; video ULA control
ULA_PAL   = $FE21                 ; video ULA palette
ROMSEL    = $FE30                 ; the paged (sideways) bank
ACCCON    = $FE34                 ; Master: bit D picks the RAM the CRTC displays
VIA_ORB   = $FE40                 ; the system VIA
VIA_ORA   = $FE41
VIA_DDRB  = $FE42
VIA_DDRA  = $FE43
VIA_T1CL  = $FE44                 ; T1: the rupture chain's step timer
VIA_T1CH  = $FE45
VIA_T1LL  = $FE46
VIA_T1LH  = $FE47
VIA_ACR   = $FE4B
VIA_PCR   = $FE4C
VIA_IFR   = $FE4D
VIA_IER   = $FE4E
VIA_ORANH = $FE4F                 ; port A without handshake
UVIA_IER  = $FE6E                 ; the user VIA's

IRQ1V     = $0204                 ; the MOS's IRQ vector
ROMSEL_CPY= $F4                   ; the MOS's copy of ROMSEL: the interrupt restores it

; ---------------------------------------------------------------- banks
; The same numbers on both machines (the sockets are patched at boot):
;   4  the sprite row loop (with the mirrored blitter), sprites, SWAPTAB, MASKTAB0-3
;   5  the sprite row loop (with the copy blitter), gather5, sprites, the map at
;      $9C00, MASKTAB0-3
;   6  bank6_entry/drawrect_clip, the tile blitter and the ring work, the level's
;      tiles from $8600
;   7  the kernel at the top (resident); below it the game's image -- the level's
;      tables, then the logic, the game loop and the rest of the renderer -- or,
;      during the menus, the menus' image
BANK_SPR  = 4
BANK_TIL1 = 5                     ; the second sprite bank
BANK_TILES= 6                     ; every level's tile data fits one bank
BANK_LVL  = 7
BANK_MAP  = 5                     ; the map, and the gather that reads it in place

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
;   $4400-$467F  mirror B    1 row                          MIRR_B
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
VISROWS   = 21                    ; 168 lines = 84 game px
  .else
; ---- Master: one 32-row ring, main and shadow
; VISROWS: 240 lines = 120 game px (the original is 108: a 128-line phone screen less
; a 20-line HUD).  30 fills the ring exactly: 31 held + the composed row.
RINGROWS  = 32                    ; the whole 20K: the hardware fold IS the ring wrap
VISROWS   = 30                    ; visible char rows
  .endif
BUFROWS   = VISROWS + 1           ; rows held: the visible ones plus the bottom partial's
; The camera follows the player one for one (Cleo's), so her fall speed is also how
; far the window moves in a frame.  A char row is four game pixels: a play decision.
MAXDWY    = 8
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
RING0     = RING_A                ; buffer 0's ring (the menus' too)
CLEAR0    = MIRR_A                ; the menus' clear: mirrors and rings, to $8000
MIRR_A    = RING_A - ROWBYTES     ; ring A's mirror: the row just under its base
MIRR_B    = RING_B - ROWBYTES     ; ring B's mirror
RINGEND_A = RING_A + RINGBYTES
RINGEND_B = RING_B + RINGBYTES
.assert RINGEND_B = $8000 && (RINGEND_A & $FF) = 0, error, "the ring ends must be page aligned"
.assert (<RING_A) = $80 && (<RING_B) = $80, error, "ringup's low-byte fold assumes bases at xx80"
BARADDR   = $0300
.assert MIRR_A = BARADDR + BARROWS*ROWBYTES, error, "mirror A must follow the bar"
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
RING0     = RINGBASE              ; buffer 0's ring (the menus' too)
CLEAR0    = RINGBASE              ; the menus' clear: buffer 0's ring, to $8000
RINGEND   = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything
; below $3000 is only main RAM to the CRTC (the bar gets away with it by being single
; buffered and scanned with D = 0).  It lives in the one ring row the window does not
; hold: the row ABOVE it, ring chars [ringS + BUFROWS*80, ringS + RINGCHARS) =
; [ringS - 80, ringS).  The window start is char granular (ringS = wcy*80 + wcx), so
; that row is not a slot in the row tables: its column c is ring char
; (ringS + c + RINGCHARS - 80) mod RINGCHARS, a constant offset from its source, which
; makes it a ring row like any other.  It is window aligned, not slot aligned -- a
; row-aligned slot (barq + 31) would overlap the window's last row by ringS mod 80
; chars with BUFROWS at 31 -- so its copy may fold at $8000 mid-run (copy_partial).
;
; The bar is BELOW the screen in memory, in main RAM, and there is only one of it.
; The CRTC's start address is just RAM/8, so it can scan from anywhere under $8000 --
; but with shadow selected for display (ACCCON D = 1) everything under $3000 reads
; HAZEL/ANDY instead of main RAM, so the bar's section runs with D = 0 and the
; playfield's with D = the buffer being shown.  Single-buffered: it is drawn where it
; is displayed, inside the 40 lines between vsync and the first scanned bar line.
BARADDR   = $2B00
CRTCBASE  = RINGBASE / 8          ; the CRTC counts characters, so the ring starts here
CRTCB_A   = CRTCBASE              ; each buffer's ring base, as the CRTC counts: one
CRTCB_B   = CRTCBASE              ;  ring, main and shadow (ACCCON D picks)
  .endif
WINPX     = ROWCHARS*2            ; window width in game pixels
VISLINES  = VISROWS*8

; ---------------------------------------------------------------- sprites
; MAXSPRDEF, the sprite slots: the build's MAXSPR (build.sh), or the game's assets.inc
; (Cleo sizes it from its levels), else 28.
  .ifndef MAXSPRDEF
MAXSPRDEF = 28
  .endif
MAXREC    = MAXSPRDEF
MAXSPR    = MAXSPRDEF

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
REC_CX    = SPRREC+10*MAXREC        ; the column's low byte
REC_CY    = SPRREC+12*MAXREC
REC_W     = SPRREC+14*MAXREC
REC_H     = SPRREC+16*MAXREC        ; height | column high << 5 | clipped << 7
recb      = recp                    ; the buffer's first record
rq        = rp                      ; the current record
        .assert BUFROWS < 32, error, "TIGHTBSS: a record's height is 5 bits"
        .assert 2*MAXREC <= 256, error, "TIGHTBSS: the records are indexed by a register"
  .else
RECSZ     = 10
REC_CX    = 5                       ; (2 bytes)
REC_CY    = 7
REC_W     = 8
REC_H     = 9                       ; height | clipped << 7
  .endif

; ---------------------------------------------------------------- misc
; DIRTYMAX: the dirty tiles a buffer can queue.  A switch marks 2 x its height at
; once, 18 for the tallest (level 7's main map); past this the buffer is redrawn
; whole (mark_dirty).
DIRTYMAX = 20

; key bits (keys)
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16

; ---------------------------------------------------------------- frame shape
; A 312-line frame of 39 char rows: the bar, the playfield, then QROWS blank rows (Q)
; with the vsync in them.
BARROWS = 2                        ; the status bar
QROWS  = 39 - VISROWS - BARROWS    ; blank rows after the display: 312 lines in all
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
