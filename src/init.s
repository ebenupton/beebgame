; ============================================================================
; init.s -- start-up, both machines, in main RAM
;
; The BOOT piece at BOOTRAM ($7000, display RAM nothing has drawn in yet) with the
; low-RAM image behind it.  The boot loader (loader.s) jumps to boot with bank 7
; paged and its findings in the header below.  Code in main RAM pages any bank it
; likes and carries on, so none of this needs a place in a bank: once play starts
; the display overwrites it.  It runs once.
;
;   boot   zero the memory, copy the low RAM down, build the first chains, start
;          the interrupt, the disc, the menus' image (disc.s go_title)
;
; Segment: BOOTHDR -- the header and boot itself, so the entry is BOOTHDR_LEN bytes
; into BOOTRAM, where the loader jumps; engine/boot.s's take_over and crtc_init
; follow in BOOT.  The .if .not BHW block is the first blessed placement (the
; Master's handler state) and hardware (QBLANK).
; ============================================================================

; ---------------------------------------------------------------- the header
; The boot loader's findings, at fixed addresses on both machines (one loader serves
; both): the controller, the drive, the physical bank of each of banks 4..7, the
; board.  boot copies them where the game reads them (drv_type.., PBANK, pboard).
        .segment "BOOTHDR"
dsk_type:  .res 1                  ; 0 = 8271, 1 = 1770 -> drv_type (disc.s)
dsk_drv:   .res 1                  ; the drive DFS had current -> drv_unit
DSK_BANKS: .res 4                  ; the sockets -> PBANK
dsk_board: .res 1                  ; BOARD_* (defs.inc) -> pboard
BOOTHDR_LEN = 7                    ; the entry follows the header (the loader's jmp)
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute, __LOWCODE_SIZE__: absolute
        .import __TILBSS_RUN__: absolute, __TILBSS_SIZE__: absolute
        .import __BOOTRAM_START__: absolute
; the first clearing loop: X counts ZC_N down to 1, and the two stores reach zero
; page $00..ZC_N-1 (a zp,x base of $FF wraps: $FF + X = X - 1) and low RAM
; $0114..$0203 (IRQ1V - ZC_N - 1 = $0113, + X)
ZC_N       = $F0
ZPX_WRAP   = $FF

; ---------------------------------------------------------------- the macros
; CLEAR8 tab, n: zero n (< 256) bytes from tab, with X and A = 0 out
.macro CLEAR8 tab, n
        .local l
        ldx #<(n)
        lda #0
l:      dex
        sta tab,x
        bne l
.endmacro

; ----------------------------------------------------------------------------
; boot: the game's start-up
;   In:    the header above (the loader's); bank 7 paged
;   Out:   does not return: to go_title (disc.s), the menus' image loaded and
;          hook_title entered
; In order: the stack; zero page and low RAM zeroed (interrupts are off until
; take_over); the low-RAM image copied down; the header's findings copied to the
; game's variables; the palette black; (Master) the handler's state and QBLANK
; zeroed; the CRTC's load frame; both buffers' chains, for a blank window at the
; origin; bank 6's variables zeroed; the interrupt; the disc.
; ----------------------------------------------------------------------------
boot:
        .assert dsk_type = __BOOTRAM_START__ && boot = dsk_type + BOOTHDR_LEN, error, "the loader's header: the start of BOOTRAM, the entry BOOTHDR_LEN bytes on"
        sei
        ldx #STACKTOP              ; the stack is 64 bytes, $0100-$013F
        txs
        lda #0
        ldx #ZC_N
@zero:  sta ZPX_WRAP,x             ; zero page $00-$EF (zp,x wraps)
        sta IRQ1V-ZC_N-1,x         ; low RAM $0114-$0203, up to IRQ1V (take_over's):
        dex                        ;  the low BSS and the stack above $0113 (nothing
        bne @zero                  ;  is on it yet)
        .assert __TILBSS_RUN__ + __TILBSS_SIZE__ <= TILES + (TOFF+1)*TILEBYTES, error, "bank 6's code and variables run into the first tile: raise TOFF (the game's packer)"
        ldy #$FF-ZC_N              ; (A = 0) and zero page $F0-$FF
:       sta ZC_N,y
        dey
        bpl :-
        .assert __LOWCODE_SIZE__ < 256, error, "the low-RAM image is copied a byte at a time"
@lc:    lda __LOWCODE_LOAD__,x     ; (X = 0) the low-RAM image, exactly its length
        sta __LOWCODE_RUN__,x
        inx
        cpx #<__LOWCODE_SIZE__
        bne @lc
        bankimm lda, BANK_LVL, BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_LVL, BANK_LVL
        .assert dsk_board = DSK_BANKS + 4 && pboard = PBANK + 4, error, "the board byte follows the banks"
        .assert dsk_drv = dsk_type + 1 && DSK_BANKS = dsk_type + 2 && drv_unit = drv_type + 1 && ld_sec = drv_type + 2 && ld_n = drv_type + 4, error, "boot copies the driver's bytes beside the banks"
        ldx #pboard-PBANK          ; the physical banks and the board, from where the
@pb:    lda DSK_BANKS,x            ;  loader put them (the loop above has just zeroed
        sta PBANK,x                ;  the low BSS); and the disc driver's own copies
        lda dsk_type,x             ;  (this piece is screen memory once play starts):
        sta drv_type,x             ;  drv_type, drv_unit, then three bytes of ld_sec
        dex                        ;  and ld_n, which every read writes before it
        bpl @pb                    ;  reads them
        ; (the records and the buffers' state: the game's level start calls lv_reset;
        ; mus_on and sfx_req are the zeros above, both zero page)
        jsr blank_palette          ; nothing on the screen is a picture until the title
  .if .not BHW                     ; blessed placement: handler state; hardware: QBLANK
        .import __MRAMBSS_RUN__: absolute, __MRAMBSS_SIZE__: absolute
        .assert __MRAMBSS_SIZE__ < 256, error, "boot zeroes MRAMBSS with an 8-bit index"
        ; the chain tables (vars.s)
        CLEAR8 __MRAMBSS_RUN__, __MRAMBSS_SIZE__
        ; Q's black row (defs.s QBLANK): ROWBYTES zeros, three overlapping pages
        ldx #0                     ; (already 0 out of CLEAR8; A = 0 too)
        .assert ROWBYTES > 512 && ROWBYTES <= 768, error, "QBLANK's zeroing: three overlapping pages"
@qz:    sta QBLANK,x
        sta QBLANK+256,x
        sta QBLANK+ROWBYTES-256,x  ; (over the second's end: ROWBYTES in all)
        inx
        bne @qz
  .endif
        jsr crtc_init
        ; both buffers' chains, for a blank window at the origin (ring_s, barq, wfine
        ; are the zeros above), before the interrupt can walk one
        jsr build_sections
        inc cur_buf
        jsr build_sections
        dec cur_buf                ; 1 -> 0 (build_sections only reads it)
        ; bank 6's variables (TILBSS: the tile blitter's) zeroed
        jsr page6                  ; (low RAM's: A = bank 6 after, as wrsel wants)
        wrsel BANK_TILES, BANK_LVL
        .assert __TILBSS_SIZE__ < 256, error, "boot zeroes TILBSS with an 8-bit index"
        CLEAR8 __TILBSS_RUN__, __TILBSS_SIZE__
        wrback BANK_LVL            ; the window's end: the write bank is 7's
        jsr take_over              ; the interrupt (bank 6 still paged, as it was)
        jsr page_logic             ; bank 7 (low RAM's: the image copied above)
        jsr disc_init              ; a 1770: reset, and the head found
        jmp go_title               ; the menus' image, and the title (disc.s)
