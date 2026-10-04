; ============================================================================
; The addresses, for both machines (BHW, cpu.inc: the hardware).  The code lives in
; four sideways banks, each with the data its inner loops read:
;   4  the sprite row loop and blitters, most of the sprite images, and the
;      expansion tables (L0TAB, L1TAB, NMASK) and SWAPTAB
;   5  the row loop again, the gather, the rest of the sprites, the map (a fixed
;      8K) and the same tables
;   6  the tile blitter and the ring work, then the level's tiles from TILES
;   7  at the top the kernel, resident: the chain's builders, the palette, the disc
;      driver, and on the Model B the interrupt's work, the keys and the sound.
;      Below it one of two images, swapped by a disc load (disc.s go_game, go_menu):
;      the game's -- the level's tables, the logic, the game loop, the sprite
;      prologue and its records, the HUD, the level's sprite directory -- or the
;      menus' -- the menus, the tune, the font, the title pieces
; Main RAM on the Model B is the display from $0300 -- the bar, two mirrors and two
; 23-slot rings (engine.s, screen shape) -- leaving zero page and $0100-$02FF (the
; stack, low.s).  On the Master the bar is at $2B00 and the ring at $3000 in main and
; shadow RAM; below them its handler, chain and their state, and LV_PAGE0.  Every
; level is gathered from the disc into the banks by the loader (ldprog.s), which runs
; in main RAM while the palette is black.
; ============================================================================
        .include "hw.inc"           ; the chips' registers and bits, the MOS's addresses
IMG_GAME  = 0                      ; bank 7's images (ldprog.s image_load)
IMG_MENU  = 1
LDOP_IMAGE   = $80                 ; a load request's bits (ld_entry's X): bit 7 an image,
LDOP_OVERBIT = $02                 ;  not a level; bit 1 a game over; bit 0 the image
LDOP_IMGMASK = IMG_GAME | IMG_MENU
LDOP_GAME  = LDOP_IMAGE | IMG_GAME ; a load of an image and where it goes on (disc.s
LDOP_TITLE = LDOP_IMAGE | IMG_MENU ; go_game, go_title, go_menu; ldprog.s ld_entry)
LDOP_OVER  = LDOP_IMAGE | LDOP_OVERBIT | IMG_MENU
; load_req (vars.s), the load mode's states (kernel.s): the chain runs, a stop is
; asked, it has stopped, a resume is asked (ldprog.s ld_resume)
LDR_RUN     = 0
LDR_STOP    = 1
LDR_STOPPED = 2
LDR_RESUME  = 3

L0TAB     = B4_DATA_END            ; both sprite banks are the expansion -- a stored
L1TAB     = L0TAB + $100           ; byte's two game pixels to its first scanline, its
NMASK     = L0TAB + $200           ; second, the AND mask for its transparent pixels --
SWAPTAB   = L0TAB + $300           ; and the dot reversal, in both (either can mirror):
                                    ; the top 1K of each, where the packer's sprites end
                                    ; (assets.inc B4_DATA_END; the cfg's B4T and B5T)
NIBTAB_LEN = 3*256                 ; the three expansion tables (the game's nibtab.bin)
BANKENTRY = ROMBASE                ; banks 4, 5 and 6: the routine bank 7 calls once a
                                    ; sprite or rect starts the bank (low.s call_bank):
                                    ; the sprite row loop's ds_entry, bank6_entry
; The equates stay equates (the packer and the loaders' own links need the values,
; and code folds them into immediates), and the linker's map (cfg/banks.cfg) is held
; to them here: every area's start and size reaches the link as __NAME_START__ and
; __NAME_SIZE__.
        .import __B4X_START__: absolute, __B5X_START__: absolute, __B6X_START__: absolute, __B6X_SIZE__: absolute
        .import __B4T_START__: absolute, __B5T_START__: absolute, __B4T_SIZE__: absolute
        .assert BANKENTRY = __B4X_START__ && BANKENTRY = __B5X_START__ && BANKENTRY = __B6X_START__, error, "BANKENTRY: banks 4, 5 and 6 are entered at their first byte (the cfg's B4X, B5X, B6X)"
        .assert L0TAB = __B4T_START__ && L0TAB = __B5T_START__ && SWAPTAB + $100 = L0TAB + __B4T_SIZE__, error, "L0TAB..SWAPTAB: the cfg's B4T and B5T, the top 1K of the sprite banks"
        .assert TILES + (TOFF+1)*TILEBYTES = __B6X_START__ + __B6X_SIZE__, error, "TILES: the cfg's B6X ends at the first tile slot (build.sh sets its size from assets.inc)"
; TILES (assets.inc, the packer's): bank 6's tiles, TILEBYTES a slot from this page
; (draw_rect's gather is arithmetic): id k's slot is k + TOFF (assets.inc), so the
; first tile (id 1; id 0 is the solid, filled) sits at the first slot clear of the code
; and its variables
TILEPX    = 8                      ; a tile is 8 x 8 game pixels:
TILEPX_SHIFT = 3                   ;  (a pixel's tile is its coordinate >> 3)
        .assert (1 << TILEPX_SHIFT) = TILEPX, error, "TILEPX_SHIFT: log2 of TILEPX"
TILECHARS = 4                      ;  4 chars across (2 game pixels a char)
TILEROWS  = 2                      ;  and 2 char rows down (4 game pixels a row)
TILEBYTES = TILECHARS*TILEROWS*CHARBYTES   ; 64: a slot
HALFBYTES = TILEBYTES/TILEROWS     ; 32: one char row of a tile -- a half tile's stored row,
                                    ;  and the bottom char row's offset in a slot
TILESHIFT = 6                      ; id * TILEBYTES is id << TILESHIFT
        .assert (1 << TILESHIFT) = TILEBYTES, error, "TILESHIFT: log2 of TILEBYTES"
TILES_PER_PAGE = 256/TILEBYTES
; The gather's pair for a tile (gather.s gather5, tiles.s draw_rect's row loop; the
; Master's LV_PAGE0 holds the same): GATHERH bit 7 set is a full tile's page (GH_TILE),
; clear a fill -- 0 the level's solid, GH_FLAT a flat tile or the other solid (GATHERL
; its pair in FLATTAB), else a half tile's page less GH_TILE, with GATHERL its row's
; offset (GL_ROWMASK), which char row is its fill (GL_FILLTOP, GL_FILLBOT; neither:
; both stored) and the fill's colour in the level's palette (GL_COLMASK)
GH_TILE    = $80
GH_FLAT    = $40
GL_FILLTOP = 8
GL_FILLBOT = 16
GL_ROWMASK = $E0
GL_COLMASK = 7
HPAIR_LEN  = 16                    ; the halves' fill palette: 8 first bytes, then 8 second
FLATTAB_LEN = 2*(NFLAT+2)          ; the flat tiles' pairs, and the two solids'
LV_MAP    = MAP5                   ; bank 5, $9C00: row major, a fixed 8K below the
                                    ; mask tables; the level's sprites below it
  .if BHW
LV_OBJS   = $7C00                  ; the level's objects, OBJ_BYTES each (OBJ_MAX of them:
                                    ; levelfmt.inc): main RAM (the display, black while
                                    ; they are read: level_init reads them once, before
                                    ; the first render)
  .else                            ; the Master: main RAM below the screen
LV_OBJS   = $1C00                  ; (the loader's program ends by $1BFF)
LV_PAGE0  = $0400                  ; tile id -> the gather's pair: 256 lo, 256 hi (the
                                    ; level's, the loader's), page aligned
  .endif

; ---------------------------------------------------------------- zero page
; The engine's first (ZEROPAGE: these, then engine.s's), then the game's (ZPGAME),
; $00-$FB, alike on both machines; $FC is the ROM's interrupt entry's (it keeps A
; there), $FD ROMSEL_CPY, $FE-$FF the engine's (ZPTOP).  Those used before engine.s
; are here, so every access is assembled as zero page.
        .zeropage
nspr:     .res 1                   ; the sprite list's length (the game's add_sprite)
bar_dirty: .res 1                  ; the bar's digits to redraw (the game sets it)
sfx_req:   .res 1                  ; a sound effect asked for (the game; sound_tick)
mtmp:     .res 1                   ; cpu.inc's scratch (bitimm's, on the Model B)
ringbhi:  .res 1                   ; the buffer being drawn: ring base high byte,
ringehi:  .res 1                   ;   ring end high byte (ringup's fold test),
ringe3:   .res 1                   ;   >RINGEND-3 (mirror.s)
mrow:     .res 1                   ; the map char row in the ring's last slot (calc_ring)
wcxm:     .res 1                   ; ring_s mod 80: the mirror's first useful char
sp_disp:  .res 1                   ; the sprite's blitter: its entries in sprrow_tab (sprloops.s)
sp_g:     .res 1                   ; the sprite's shape (the prologue's: sprg_ix)
cur_r7:    .res 1                  ; two hot scalars (profiled: ~41 and ~35 accesses a
sec_idx:   .res 1                  ;  frame): the chain's R7 and step

        .include "levelfmt.inc"     ; the level file's sections and header fields
                                    ; (tools/levelfile.py, written by the build)

; ---------------------------------------------------------------- display
LINE      = 64                     ; T1 ticks in one scanline
T1_RELOAD = 2                      ; a T1 period of n ticks is latched as n - T1_RELOAD
BARCRTC   = BARADDR / CHARBYTES    ; (the CRTC counts characters)
  .if BHW
CRTCB_A   = RING_A / CHARBYTES     ; each buffer's ring base, as the CRTC counts
CRTCB_B   = RING_B / CHARBYTES
  .endif
STACKTOP  = $3F                    ; the stack is 64 bytes, $0100-$013F (init.s, ldprog.s)

; ---------------------------------------------------------------- sideways RAM boards
; Which register chooses the bank a store goes to (the loader finds out: find_ram).  The
; game's own code is patched for it at boot (cpu.inc wrsel); what comes off the disc
; reads pboard (ldprog.s).  The registers are hw.inc's (WRSEL_*).
BOARD_STD      = 0                 ; through ROMSEL, as reads
BOARD_WATFORD  = 1                 ; a store to WRSEL_WATFORD + bank
BOARD_SOLIDISK = 2                 ; user VIA port B bits 0-3: UVIA_DDRB = SOLIDISK_BITS,
                                    ;  WRSEL_SOLIDISK = bank

; ---------------------------------------------------------------- the boot loader
; BANKS (build.sh; loader.s): a count, then PIECE_LEN bytes a piece (bank, address,
; length), the pieces, then the bank-number patch list (FIX_LEN an entry: bank,
; address; cpu.inc BANKREF) ending in $FF, then the write-bank store list (WR_LEN an
; entry: bank, address, kind; cpu.inc wrsel) ending in $FF.  A piece's bank byte is the
; code's bank number, with a disc driver's flagged by its controller.
BANKSBUF  = $2000                  ; where the loader reads BANKS (below BOOTRAM, $7000)
        .import __BANKSB_START__: absolute, __BANKSB_SIZE__: absolute, __BOOTRAM_START__: absolute
        .assert BANKSBUF = __BANKSB_START__ && BANKSBUF + __BANKSB_SIZE__ = __BOOTRAM_START__, error, "BANKSBUF: the cfg's BANKSB, up to BOOTRAM"
PIECE_LEN = 5
FIX_LEN   = 3
WR_LEN    = 4
PIECE_8271 = $80                   ; the piece is the 8271's driver (the Model B)
PIECE_1770 = $40                   ;  or the 1770's: only the machine's is copied
PIECE_BANKMASK = $3F
PIECE_HAZEL = 1                    ; the piece goes to HAZEL (GAMEHAZEL: ACCCON Y)

; ---------------------------------------------------------------- the loader
NMIPAGE   = $0D00                  ; the disc transfer routine, while a load runs
LDPROG    = $0E00                  ; the load-time program (ldprog.s), read there
        .import __NMI8271_START__: absolute, __NMI1770_START__: absolute, __LDP_START__: absolute
        .assert NMIPAGE = __NMI8271_START__ && NMIPAGE = __NMI1770_START__, error, "NMIPAGE: the cfg's NMI8271 and NMI1770, where the stubs run"
        .assert LDPROG = __LDP_START__, error, "LDPROG: the cfg's LDP (and ldprog.cfg's LD)"
SECTRK    = 10                     ; the disc: 80 tracks of 10 256-byte sectors
NTRACKS   = 80
  .if BHW
STAGE     = $1C00                  ; a shared file staged here, 16K at most ($5BFF)
STAGE_LVL = $5C00                  ; the level's own file, 8K at most (the game's packer
                                    ; asserts it): the objects go to LV_OBJS ($7C00)
                                    ; while it is still being read
  .else                            ; the Master: the screen, both copies of it --
STAGE     = $3000                  ; a shared file in SHADOW RAM (ACCCON X = 1 while it
STAGE_LVL = $3000                  ; is read or copied), the level's in main RAM
  .endif
FDC8271_CMD = $FE80                ; the Model B's 8271: command/status, parameter/result, data
FDC8271_PAR = $FE81
FDC8271_DAT = $FE84
  .if BHW
FDC1770_CTL = $FE80                ; the Acorn 1770 board: the drive control latch,
FDC1770_CMD = $FE84                ; then the WD1770 at $FE84-$FE87
FDC1770_SEC = $FE86
FDC1770_DAT = $FE87
FDC_RESET   = $08                  ; the latch: reset held (bit 5 low), FM
FDC_DRV0    = $29                  ;   reset released, FM, drive 0 / drive 1 (bits 0, 1)
FDC_DRV1    = $2A
FDC_SIDE1   = $04                  ;   side 1 (bit 2)
  .else
FDC1770_CTL = $FE24                ; the Master's: its drive control latch, then the
FDC1770_CMD = $FE28                ; WD1770 at $FE28-$FE2B
FDC1770_SEC = $FE2A
FDC1770_DAT = $FE2B
FDC_RESET   = $20                  ; the latch: reset held (bit 2 low)
FDC_DRV0    = $25                  ;   reset released, FM, drive 0 / drive 1 (bits 0, 1)
FDC_DRV1    = $26
FDC_SIDE1   = $10                  ;   side 1 (bit 4)
  .endif

