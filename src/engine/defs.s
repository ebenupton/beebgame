; ============================================================================
; CLEO - BBC Micro port : display engine
;   - double buffered ring framebuffers: main and shadow RAM, 20K each, on the
;     Master; two rings in main RAM on the Model B
;   - vertical rupture: fixed status bar section + hardware scrolled playfield
;     with 2-scanline fine vertical scroll, 1-character horizontal scroll
;   - tiles are 8x8 game pixels = 4 chars x 2 char rows (64 bytes) in SWR
; ============================================================================
        .include "assets.inc"
        .include "pads.inc"

; ---------------------------------------------------------------- hardware
CRTC_IDX  = $FE00
CRTC_DAT  = $FE01
ULA_CTRL  = $FE20
ULA_PAL   = $FE21
ROMSEL    = $FE30
ACCCON    = $FE34
VIA_ORB   = $FE40
VIA_ORA   = $FE41
VIA_DDRB  = $FE42
VIA_DDRA  = $FE43
VIA_T1CL  = $FE44
VIA_T1CH  = $FE45
VIA_T1LL  = $FE46
VIA_T1LH  = $FE47
VIA_ACR   = $FE4B
VIA_PCR   = $FE4C
VIA_IFR   = $FE4D
VIA_IER   = $FE4E
VIA_ORANH = $FE4F
UVIA_IER  = $FE6E

IRQ1V     = $0204
ROMSEL_CPY= $F4

; The banks, the same numbers on both machines (the sockets are patched at boot):
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

; ---------------------------------------------------------------- screen shape
; An 80-char ring per buffer, with the 2-row status bar displayed above it.
ROWCHARS  = 80
  .if BHW
; Model B: 32K of main RAM, and all but 768 bytes of it is the display.  Two rings of
; 23 slots, each with a mirror row below it (the rupture chain reads the row that
; straddles the ring end from there: see docs/DESIGN.md), and the 2-row bar:
;   $0300 bar  $0800 mirror A  $0A80 ring A  $4400 mirror B  $4680 ring B  $8000
RINGROWS  = 23
VISROWS   = 21                    ; 168 lines = 84 game px
  .else
RINGROWS  = 32                    ; the whole 20K: the hardware fold IS the ring wrap
VISROWS   = 30                    ; visible char rows: 240 lines = 120 game px (the
                                  ; original is 108: a 128-line phone screen less a
                                  ; 20-line HUD).  30 fills the ring exactly: 31 held
                                  ; + the composed row.
  .endif
BUFROWS   = VISROWS + 1           ; rows held: the visible ones plus the bottom partial's
; The camera follows the player one for one (Cleo's), so her fall speed is also how far the window
; moves in a frame.  A char row is four game pixels: a play decision.
MAXDWY    = 8
ROWBYTES  = ROWCHARS*8
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = RINGCHARS*8
  .if BHW
; 23 x 640 = $3980 is not a whole number of pages, so the fold is 16 bit -- but both
; ring ENDS are page aligned, which keeps the fold TEST a byte compare (ringup), and
; both bases are at xx80, which makes the low byte's fold a subtraction of $80.
; Main RAM is display from the bar's $0300 to $8000: nothing else lives in it
; (the code every bank calls is the low RAM below it: low.s).
RING_A    = $0A80
RING_B    = $4680
RING0     = RING_A                ; buffer 0's ring (the menus' too)
CLEAR0    = MIRR_A                ; the menus' clear: mirrors and rings, to $8000
MIRR_A    = RING_A - ROWBYTES
MIRR_B    = RING_B - ROWBYTES
RINGEND_A = RING_A + RINGBYTES
RINGEND_B = RING_B + RINGBYTES
.assert RINGEND_B = $8000 && (RINGEND_A & $FF) = 0, error, "the ring ends must be page aligned"
.assert (<RING_A) = $80 && (<RING_B) = $80, error, "ringup's low-byte fold assumes bases at xx80"
BARADDR   = $0300
.assert MIRR_A = BARADDR + BARROWS*ROWBYTES, error, "mirror A must follow the bar"
  .else
BUF0      = $3000
.assert (RINGCHARS & $FF) = 0, error, "the ring folds on a high-byte compare"
; The layout: the bar at $2B00 (below the screen, main RAM, single buffered), then each
; buffer's ring at $3000-$7FFF, main and shadow.  The ring is the entire screen and
; the CRTC folds it for free: an address that runs off $8000 comes back to $3000, the
; ring base, so a displayed row may straddle the end and no mirror copy is needed.
; That is the whole reason RINGROWS is 32 -- it is not a choice, it is the size of the
; region the hardware wraps.
RINGBASE  = BUF0
RING0     = RINGBASE              ; buffer 0's ring (the menus' too)
CLEAR0    = RINGBASE              ; the menus' clear: buffer 0's ring, to $8000
RINGEND   = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything below
; $3000 is only main RAM to the CRTC (the bar gets away with it by being single buffered
; and scanned with D = 0).  It lives in the one ring row the window does not hold: the
; row ABOVE it, ring chars [ringS + BUFROWS*80, ringS + RINGCHARS) = [ringS - 80, ringS).
; The window start is char granular (ringS = wcy*80 + wcx), so that row is not a slot in
; the row tables: its column c is ring char (ringS + c + RINGCHARS - 80) mod RINGCHARS,
; a constant offset from its source, which makes it a ring row like any other.  It is
; window aligned, not slot aligned -- a row-aligned slot (barq + 31) would overlap the
; window's last row by ringS mod 80 chars with BUFROWS at 31 -- so its copy may fold
; at $8000 mid-run (copy_partial).
; The bar is BELOW the screen in memory, in main RAM, and there is only one of it.  The CRTC's
; start address is just RAM/8, so it can scan from anywhere under $8000 -- but with
; shadow selected for display (ACCCON D = 1) everything under $3000 reads HAZEL/ANDY
; instead of main RAM, so the bar's section runs with D = 0 and the playfield's with
; D = the buffer being shown.  Single buffered: it is drawn where it is displayed,
; inside the 40 lines between vsync and the first scanned bar line.
BARADDR   = $2B00
CRTCBASE  = RINGBASE / 8          ; the CRTC counts characters, so the ring starts here
CRTCB_A   = CRTCBASE              ; each buffer's ring base, as the CRTC counts: one ring,
CRTCB_B   = CRTCBASE              ; main and shadow (ACCCON D picks)
  .endif
WINPX     = ROWCHARS*2            ; window width in game pixels
VISLINES  = VISROWS*8
  .ifndef MAXSPRDEF                 ; the sprite slots: the build's MAXSPR (build.sh), or the
MAXSPRDEF = 28                      ;  game's assets.inc (Cleo sizes it from its levels), else 28
  .endif
MAXREC    = MAXSPRDEF
MAXSPR    = MAXSPRDEF
; a sprite record (SPRREC, a buffer's for each sprite it drew): id, x (2), y (2), then
; the screen rectangle erase_old redraws -- its map char column, char row, width in
; chars (0: nothing drawn) and height in char rows, bit 7 set when it was cut at a
; window edge.  TIGHTBSS packs the column's high bits (a map is 1024 chars wide at
; most: 2 bits) into the height's byte, bits 5-6 (the height is BUFROWS at most)
  .if TIGHTBSS                      ; (the records as arrays, a byte of each by record:
RECSZ     = 9                       ;  buffer 0's MAXREC, then buffer 1's; recb, recp's
REC_ID    = SPRREC                  ;  byte, is the buffer's first, rq, rp's, the record's)
REC_XL    = SPRREC+2*MAXREC
REC_XH    = SPRREC+4*MAXREC
REC_YL    = SPRREC+6*MAXREC
REC_YH    = SPRREC+8*MAXREC
REC_CX    = SPRREC+10*MAXREC        ; the column's low byte
REC_CY    = SPRREC+12*MAXREC
REC_W     = SPRREC+14*MAXREC
REC_H     = SPRREC+16*MAXREC        ; height | column high << 5 | clipped << 7
recb      = recp
rq        = rp
        .assert BUFROWS < 32, error, "TIGHTBSS: a record's height is 5 bits"
        .assert 2*MAXREC <= 256, error, "TIGHTBSS: the records are indexed by a register"
  .else
RECSZ     = 10
REC_CX    = 5                       ; (2 bytes)
REC_CY    = 7
REC_W     = 8
REC_H     = 9                       ; height | clipped << 7
  .endif

DIRTYMAX = 20                     ; dirty tiles a buffer can queue: a switch marks 2 x its
                                  ; height at once, 18 for the tallest (level 7's main map);
                                  ; past this the buffer is redrawn whole (mark_dirty)
; key bits
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16

BARROWS = 2                        ; the status bar
QROWS  = 39 - VISROWS - BARROWS    ; blank rows after the display: 312 lines in all
  .if BHW
QVSYNC = 8                         ; vsync at Q row 8 of 16: the picture starts 64 lines after
                                   ; it, 4 lines below where a MODE 1 screen sits
  .else
QVSYNC = 3                         ; vsync at Q row 3 of 7: four rows (32 lines) between the
                                   ; vsync and the bar, which is where the bar is drawn, and
                                   ; three below.  Measured against the Master MOS's own
                                   ; standard frame (R7 = 35): the picture sits exactly
                                   ; where it does.
  .endif
