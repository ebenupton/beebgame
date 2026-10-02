; ============================================================================
; Start-up, both machines, in main RAM: the BOOT piece at BOOTRAM ($7000, display RAM
; nothing has drawn in yet) with the low-RAM image behind it.  The loader jumps to
; `boot` with bank 7 paged.  Code in main RAM pages any bank it likes and carries
; on, so none of this needs a place in a bank: once play starts the display
; overwrites it.  It runs once.
; ============================================================================
        .segment "BOOTHDR"          ; (first in BOOTRAM: before the routines the rest of
                                    ;  the sources put in BOOT)
; the boot loader's findings, at fixed addresses on both machines (one loader serves
; both): the controller, the drive, the physical bank of each of banks 4..7, the board
dsk_type:  .res 1
dsk_drv:   .res 1
dsk_banks: .res 4
dsk_board: .res 1
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute, __LOWCODE_SIZE__: absolute
        .import __TILBSS_RUN__: absolute, __TILBSS_SIZE__: absolute
boot:   .assert dsk_type = $7000 && boot = $7007, error, "the loader's header: $7000, the entry $7007"
        sei
        ldx #$3F                    ; the stack is 64 bytes: $0100-$013F
        txs
        lda #0                      ; zero page ($F0-$FF is the MOS's: $F4 is the
        ldx #$F0                    ; bank the loader selected, and the OS IRQ still
:       sta $FF,x                   ; restores from it until take_over): $00-$EF, zp,x
        sta $0113,x                 ; wrapping; and $0114-$0203, the low RAM and the
        dex                         ; stack above $0113 (nothing is on it yet)
        bne :-
        .import __ZPF0_RUN__, __ZPF5_RUN__, __ZPFD_RUN__   ; (ld65 exports them absolute)
        .import __TILBSS_RUN__, __TILBSS_SIZE__
        .assert __TILBSS_RUN__ + __TILBSS_SIZE__ <= TILES + (TOFF+1)*64, error, "bank 6's code and variables run into the first tile: raise TOFF (the game's packer)"
        .assert __ZPF0_RUN__ = $F0 && __ZPF5_RUN__ = $F5 && __ZPFD_RUN__ = $FD, error, "the MOS's zero page: $F0-$F3, $F5-$FB, $FD-$FF"
        ldy #$0F                    ; (A = 0, X = 0) and the MOS's zero page but $F4 and
:       cpy #$04                    ; $FC: the hot scalars engine.s keeps there
        beq :+
        cpy #$0C
        beq :+
        sta $F0,y
:       dey
        bpl :--
        .assert __LOWCODE_SIZE__ < 256, error, "the low-RAM image is copied a byte at a time"
@lc:    lda __LOWCODE_LOAD__,x      ; (X = 0) exactly its length: the bar starts at $0300
        sta __LOWCODE_RUN__,x
        inx
        cpx #<__LOWCODE_SIZE__
        bne @lc
        bankimm lda, BANK_LVL, BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_LVL, BANK_LVL
        .assert dsk_board = dsk_banks + 4 && PBOARD = PBANK + 4, error, "the board byte follows the banks"
        .assert dsk_drv = dsk_type + 1 && dsk_banks = dsk_type + 2 && drv_unit = drv_type + 1 && ld_sec = drv_type + 2 && ld_n = drv_type + 4, error, "boot copies the driver's bytes beside the banks"
        ldx #4                      ; the physical banks and the board, from where the
@pb:    lda dsk_banks,x             ; loader put them (the loop above has just zeroed
        sta PBANK,x                 ; the low BSS); and the disc driver's own copies
        lda dsk_type,x              ; (this piece is screen memory once play starts):
        sta drv_type,x              ; drv_type, drv_unit, then three bytes of ld_sec and
        dex                         ; ld_n, which every read writes before it reads them
        bpl @pb
        ; (the records and the buffers' state: load_level's lvreset, in the game's image)
        ; MUSON and SFXREQ: the zeros above (both zero page)
        jsr blank_palette           ; nothing on the screen is a picture until the title
  .if .not BHW                      ; the Master: its handler's state, in main RAM
        .import __TABLES_RUN__: absolute, __TABLES_SIZE__: absolute
        .assert __TABLES_SIZE__ < 256, error, "boot zeroes TABLES with an 8-bit index"
        ldx #<__TABLES_SIZE__       ; (LOADREQ above all: a load is not under way)
        lda #0
:       dex
        sta __TABLES_RUN__,x
        bne :-
        ldx #0                      ; Q's black row (defs.s QBLANK): 640 zeros (A = 0)
        .assert ROWBYTES > 512 && ROWBYTES <= 768, error, "QBLANK's zeroing: three overlapping pages"
@qz:    sta QBLANK,x
        sta QBLANK+256,x
        sta QBLANK+ROWBYTES-256,x   ; (over the second's end: ROWBYTES in all)
        inx
        bne @qz
  .endif
        jsr crtc_init
        ; both buffers' chains, for a blank window at the origin (ringS, barq, wfine
        ; are the zeros above), before the interrupt can walk one
        jsr build_sections
        inc curbuf
        jsr build_sections
        dec curbuf                  ; (1 -> 0: build_sections only reads it)
        ; bank 6's variables (TILBSS: the ring work's) zeroed
        jsr page6                   ; (low RAM's: A = bank 6 after, as wrsel wants)
        wrsel BANK_TILES, BANK_LVL
        .assert __TILBSS_SIZE__ < 256, error, "boot zeroes TILBSS with an 8-bit index"
        ldx #<__TILBSS_SIZE__
        lda #0
:       dex
        sta __TILBSS_RUN__,x
        bne :-
        wrback BANK_LVL             ; (the window's end: the write bank 7's from here on)
        jsr take_over               ; the interrupt: bank 6 still paged, as it was
        jsr pagelogic               ; bank 7 (low RAM's, the image copied above)
        jsr disc_init               ; a 1770: reset, and the head found
        jmp go_title                ; the menus' image, and the title (disc.s)
