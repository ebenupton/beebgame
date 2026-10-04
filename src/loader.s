; ============================================================================
; LOADER -- runs at $1900 from !BOOT under the MOS, one for both machines.  It asks
; the MOS which machine this is and loads that one's bank images (BANKSB, BANKSM).
; First the sideways RAM: the game wants four 16K banks it can write through ROMSEL
; and takes them from whatever sockets they are in (find_ram), then patches every bank
; number in the code it is about to put there -- the code is assembled for banks
; 4..7, and the list at the end of BANKS names every byte that holds one (cpu.inc
; BANKREF), then every write-bank store (cpu.inc wrsel).  Then the fixed pieces of the
; four banks from BANKS (DFS will not load into a sideways bank, so the file is read
; to $2000 and the pieces copied), which drive and which disc controller the game's
; own driver is to use, and the game.  Everything else -- bank 7's images (the
; menus', the game's), every level -- the game loads itself (disc.s, ldprog.s),
; reading the physical banks from PBANK, which `boot` fills from the bytes this
; leaves in the start-up piece's header (init.s, $7000).
; ============================================================================
        .setcpu "6502"
        .include "hw.inc"           ; the chips: ROMSEL, ACCCON, the user VIA, the boards'
                                    ;  write-bank registers; the MOS's ROM table, a ROM's header
        .include "defs_ld.inc"      ; boot, dsk_type, dsk_drv, DSK_BANKS, dsk_board,
                                    ; BOARD_*, BANKSBUF, PIECE_*, FIX_LEN, WR_LEN, WR_INX (build.sh)
OSFILE  = $FFDD                    ; the MOS's entries, and what this asks of them
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
OSB_MOSVER = 0                     ; OSBYTE 0, X = 1: the MOS version in X
OSB_INKEY  = $81                   ; OSBYTE $81, X = a negative INKEY code: is the key down?
INKEY_W = $DE                      ;  W and I, as INKEY codes
INKEY_I = $DA
VDU_MODE = 22                      ; VDU 22, n: MODE n
SCREEN_MODE = 1                    ; MODE 1 (the game's)
OSF_LOAD = $FF                     ; OSFILE $FF: load a file, the address from its block
OSGBPB_DRIVE = 6                   ; OSGBPB 6: the current drive's name
NSOCK   = 16                       ; sideways sockets
zsrc    = $70
zdst    = $72
ztab    = $74
ztmp    = $76

        .segment "CODE"
start:
        ; ---- the machine: one disc, each machine its own bank images (BANKSB, BANKSM).
        ; OSBYTE 0 with X = 1 gives the MOS version in X: 3 and up are a Master's
        lda #OSB_MOSVER
        ldx #1
        jsr OSBYTE
        cpx #MOS_MASTER
        bcc :+
        lda #'M'
        sta fname_m
  .if MASTERONLY
        bne :++                    ; (a Master: on)
:       jmp no_master              ; a game built for the Master alone (build.sh MASTERONLY)
:
  .else
:
  .endif
        lda MOS_ROMSEL
        sta old_bank
        jsr find_ram               ; the four banks, into BANKMAP -- or fewer, and C set
        bcc :+
        jmp no_ram                 ; say so and go back to the MOS
:
        ; ---- the drive: whichever DFS has current (OSGBPB 6: its name is the digit)
        lda #OSGBPB_DRIVE
        ldx #<gbpb
        ldy #>gbpb
        jsr OSGBPB
        ldx DRVNAME
        lda DRVNAME,x
        and #1
        sta drive
        ; ---- the controller: the DFS ROM's version string.  Acorn's 8271 DFSs are
        ; 0.90 and 1.20 (whose title is "DFS,NET" with no version at all); the 1770
        ; DFSs are 2.xx.  Hold W or I at boot to say so instead.

        lda #OSB_INKEY
        ldx #INKEY_W               ; W (negative INKEY code)
        ldy #$FF
        jsr OSBYTE
        inx                        ; X = $FF: W held
        bne :+
        inc fdc                    ; 0 (above) -> 1, Z clear
        bne @fdcdone
:       ldx #INKEY_I               ; I (A = OSB_INKEY still: OSBYTE keeps A)
        dey                        ; Y = $FF (0 from OSBYTE: W not held)
        jsr OSBYTE
        inx                        ; X = $FF: I held
        beq @fdcdone               ; 8271, as set
        ldx #NSOCK-1
@rom:   lda MOS_ROMTAB,x           ; the MOS's ROM type table: service ROMs only
        bpl @nextrom
        stx MOS_ROMSEL
        stx ROMSEL
        ldy #0
:       lda ROMHDR_TITLE,y         ; the title
        beq :+
        iny
        bne :-
:       lda ROMHDR_TITLE+1,y       ; the version follows its terminator
        cmp #'2'
        bne @nextrom
        lda ROMHDR_TITLE           ; only a DFS: the title starts "DFS" (Acorn's)
        cmp #'D'
        bne @nextrom
        lda ROMHDR_TITLE+1
        cmp #'F'
        bne @nextrom
        inc fdc                    ; 0 -> 1
        ldx #0
@nextrom:
        dex
        bpl @rom
        lda old_bank
        sta MOS_ROMSEL
        sta ROMSEL
@fdcdone:
        lda #VDU_MODE              ; MODE 1 first: the OS sets the ULA and the screen size
        jsr OSWRCH                 ; latch, the game reprograms only the CRTC -- and the
        lda #SCREEN_MODE           ; main-RAM pieces below land in what is now screen
        jsr OSWRCH                 ; memory, so the palette goes black before they do
        lda #((PAL_N-1) << PAL_SHIFT) | (PCOL_BLACK ^ PAL_INV)   ; logical colour 15 down to 0, each to black
        sec
:       sta ULA_PAL
        sbc #1 << PAL_SHIFT
        bcs :-                     ; ($07 - $10 borrows: the last one written)
        ; ---- the pieces: BANKS is a count, then (bank, address, length) x count, then
        ; the pieces in that order, then the bank patches (defs.inc PIECE_*).  A disc
        ; driver's bank has a controller flag (PIECE_8271, PIECE_1770) and only the
        ; machine's is copied.  A main-RAM piece is filed under bank 7 (build.sh),
        ; which pages harmlessly; bank 0 would page nothing.
        ; The whole file is loaded at once (OSFILE: a byte at a time through
        ; OSGBPB took the 1770 DFS twenty seconds) into what is now screen memory, and
        ; the pieces copied out.  From here on nothing calls the MOS again and the banks
        ; may hold ROMs it knows (find_ram's last resort), so interrupts stay off: a
        ; stray one would have it offer service calls to a ROM half overwritten.
        lda #OSF_LOAD              ; OSFILE 255: load, address from the block
        ldx #<block
        ldy #>block
        jsr OSFILE
        sei
        lda BANKSBUF
        sta npieces
        asl                        ; the first piece follows the table: BANKSBUF + 1 + 5n
        asl
        adc npieces
        .assert PIECE_LEN = 5, error, "the table's size is 4n + n"
        adc #<(BANKSBUF+1)         ; (+1: C clear, 5n < 256)
        sta zsrc
        .assert >BANKSBUF = >(BANKSBUF+1), error, "the table starts in BANKSBUF's page"
        lda #>BANKSBUF             ; (the table's page too; the stores keep the carry)
        sta ztab+1
        adc #0
        sta zsrc+1
        lda #<(BANKSBUF+1)         ; the table
        sta ztab
@piece: ldy #PIECE_LEN-1           ; backwards: A ends as the bank, Y as 0
        lda (ztab),y
        sta plen+1
        dey
        lda (ztab),y
        sta plen
        dey
        lda (ztab),y
        sta zdst+1
        dey
        lda (ztab),y
        sta zdst
        dey
        lda (ztab),y               ; the piece's bank is the code's number (4..7):
        cmp #PIECE_1770            ; the socket it goes to is BANKMAP's (main RAM: no paging)
        bcc @sel
        cmp #PIECE_8271            ; a driver (disc.s): bit 7 the 8271's, bit 6 the 1770's,
        lda #0                     ; both for the same place -- only this machine's is
        rol                        ; copied
        eor fdc                    ; (1 = the 8271's piece; fdc 0 = an 8271)
        bne @mine
        lda zsrc                   ; not this machine's: copied onto itself, so only
        sta zdst                   ; passed over (Y = 0)
        lda zsrc+1
        sta zdst+1
        bne @cp                    ; (BANKSBUF is not in page 0)
@mine:  lda (ztab),y
        and #PIECE_BANKMASK
@sel:
  .if GAMEHAZEL
        php                        ; (the flags stand for the beq below)
        cmp #PIECE_HAZEL           ; HAZEL: ACCCON Y, and it stays set for the game
        bne :+
        plp
        lda ACCCON
        ora #ACC_Y
        sta ACCCON
        bne :++                    ; (always)
:       plp
  .endif
        beq :+
        jsr sel_bank               ; and the write bank, on a board that has one
:                                  ; (Y = 0: the table read ends there)
@cp:    lda plen                   ; the length, counted down first
        bne :+
        lda plen+1
        beq @cpdone
        dec plen+1
:       dec plen
        lda (zsrc),y
        sta (zdst),y
        inc zsrc
        bne :+
        inc zsrc+1
:       inc zdst
        bne @cp
        inc zdst+1
        bne @cp                    ; (zdst never wraps)
@cpdone:
        lda ztab
        clc
        adc #PIECE_LEN
        sta ztab
        dec npieces
        bne @piece
        ; ---- the bank patches: (bank, address) x n, $FF -- zsrc is on them, the pieces
        ; being done.  The byte is a bank number, 4..7.
@fix:   lda (zsrc),y               ; (Y = 0 here: the copy loop and this loop leave it so)
        bmi @fixdone               ; the $FF (a bank is 4..7)
        jsr sel_bank
        iny
        lda (zsrc),y
        sta zdst
        iny
        lda (zsrc),y
        sta zdst+1
        tya                        ; past the entry: Y = 2, and the carry makes it FIX_LEN
        sec
        .assert FIX_LEN = 3, error, "an entry is passed as Y = 2 + C"
        adc zsrc
        sta zsrc
        bcc @fixp
        inc zsrc+1
@fixp:  ldy #0
        lda (zdst),y
        tax
        lda BANKMAP-4,x
        sta (zdst),y
        bpl @fix                   ; (always: a socket is 0..15)
@fixdone:
        ; ---- the write-bank stores: (bank, address, kind) x n, $FF, after the $FF above.
        ; Each is a `sta ROMSEL` in the code, a harmless second write of the bank on a
        ; plain machine and left alone there.  Watford: `sta WRSEL_WATFORD+socket` for
        ; a constant bank (kind 4..7 says which), `sta WRSEL_WATFORD,x` (OP_STA_ABSX)
        ; where the code has the bank in X (kind WR_INX); Solidisk: `sta WRSEL_SOLIDISK`
        ; either way.
@wfix:  ldy #1                     ; zsrc is on the byte before each entry (first the $FF)
        lda (zsrc),y
        bmi @wfixdone              ; the $FF (a bank is 4..7)
        ldx board
        beq @wnext                 ; plain: as assembled
        jsr sel_bank
        iny
        lda (zsrc),y
        sta zdst
        iny
        lda (zsrc),y
        sta zdst+1
        iny
        lda (zsrc),y               ; the kind
        tax
        bcc @wsol                  ; Solidisk: sel_bank's wrx left C = the board's bit 0 (1 Watford)
        .assert <WRSEL_WATFORD <> 0 && >WRSEL_WATFORD <> 0, error, "the Watford branches below are always taken"
        cpx #WR_INX
        beq @wdyn
        lda BANKMAP-4,x            ; Watford, a constant bank: sta $FF30 + its socket
        ora #<WRSEL_WATFORD
@wwat:  ldx #>WRSEL_WATFORD
        bne @wadr                  ; (always: $FF)
@wdyn:  lda #OP_STA_ABSX           ; Watford, the bank in X: sta $FF30,x
        ldy #0
        sta (zdst),y
        lda #<WRSEL_WATFORD
        bne @wwat                  ; (always: $30)
@wsol:  lda #<WRSEL_SOLIDISK       ; Solidisk: sta $FE60, the bank being in A
        ldx #>WRSEL_SOLIDISK
@wadr:  ldy #1                     ; the store's address: A its low byte, X its high
        sta (zdst),y
        txa
        iny
        sta (zdst),y
@wnext: lda zsrc
        clc
        adc #WR_LEN
        sta zsrc
        bcc @wfix
        inc zsrc+1
        bne @wfix                  ; (zsrc never wraps)
@wfixdone:
        ; ---- the driver's configuration, the banks themselves and the board, into the
        ; start-up piece's header ($7000 on both machines, init.s; bank 7's socket stays
        ; the one stores reach, as the start-up expects)
        ldx BANKMAP+3
        jsr selwr
        .assert drive = fdc + 1 && dsk_drv = dsk_type + 1, error, "the controller and drive copied as a pair"
        ldx #1
@hdr:   lda fdc,x                  ; fdc, drive: dsk_type, dsk_drv
        sta dsk_type,x
        dex
        bpl @hdr
        ldx #NBANKS-1
:       lda BANKMAP,x
        sta DSK_BANKS,x
        dex
        bpl :-
        lda board
        sta dsk_board
        jmp boot                   ; the game's start-up, in main RAM (init.s)

; ---------------------------------------------------------------- the write bank
; A = a bank's code number (4..7): page its socket for reading and writing.
; X = the socket, A destroyed.
sel_bank:
        tax
        lda BANKMAP-4,x
        tax                        ; and into selwr
; X = a socket: page it for reading, and writing (into wrx)
selwr:  stx MOS_ROMSEL
        stx ROMSEL
; X = a socket: make it the one a store reaches, on a board that chooses that apart
; from ROMSEL.  A is destroyed.
wrx:    lda board
        .assert BOARD_STD = 0 && BOARD_WATFORD = 1 && BOARD_SOLIDISK = 2, error, "wrx tells the boards by bit 0"
        lsr                        ; plain: 0, C = 0; Watford: 0, C = 1; Solidisk: 1, C = 0
        bcc @s
        sta WRSEL_WATFORD,x        ; Watford: the address says which, the value nothing
@s:     beq @r                     ; Z = 1: plain, or Watford (a store leaves the flags)
        stx WRSEL_SOLIDISK         ; Solidisk: port B bits 0-3 (DDRB was set by find_ram)
@r:     rts

; ---------------------------------------------------------------- the sideways RAM
; Which sockets hold RAM, and which four the game gets.  The test is the one Stuart
; McConnachie's sideways RAM Elite loader used (1988; Mark Moxon's commentary): page
; the bank through $F4 and ROMSEL, flip bit 0 of the ROM type byte at $8006 and see
; whether it stuck, put it back.  A floating bus fails it (both reads see the same
; value), a write-protected board fails it too -- it looks like ROM, and the message
; says so.  First the board: the test is run over the 16 banks writing through ROMSEL
; alone, then again selecting the write bank the Watford way ($FF30 + bank), then the
; Solidisk way (user VIA port B, bits 0-3 made outputs); the board is the way that
; finds the MOST banks (a board's write latch rests on some bank, usually 0, so the
; plain test "finds" that one bank on a board machine too), plain winning a tie; and
; every write below goes through wrx.  A machine with RAM of two kinds gets the kind
; with more.  Every bank then gets a class: 0, RAM with no ROM image in it; 1, RAM with
; an image the MOS is not running (no entry in its table at $02A1: left there by an
; earlier load); 2, RAM holding a ROM the MOS recognised -- taken only when nothing
; else is left, which is safe here because nothing calls the MOS once the pieces go
; down.  Two socket numbers that reach the same RAM (a board answering two numbers)
; are found by a signature written to each and read back -- not Elite's byte-for-byte
; comparison of the banks, which would call four blank banks one -- and the extra
; numbers dropped.  The four are the lowest-numbered of the best class.
CSTR_LEN = 4                       ; the copyright string tested: 0, "(C)"
SIG_TAG  = $C0                     ; the signature: the socket's number, tagged
CLASS_FREE = 0                     ; a socket's class (SOCKCLASS): RAM with no ROM image,
CLASS_IMAGE = 1                    ;  RAM with an image the MOS is not running, RAM
CLASS_ROM  = 2                     ;  holding a ROM the MOS recognised
NBANKS   = 4                       ; the banks the game wants
find_ram:
        sei
        lda #BOARD_STD
        sta board
        sta bestb                  ; (plain wins a tie)
        jsr @count
        sta best
        .assert BOARD_WATFORD = BOARD_STD + 1 && BOARD_SOLIDISK = BOARD_WATFORD + 1, error, "find_ram steps board up"
        inc board                  ; BOARD_WATFORD
        jsr @count
        cmp best
        bcc :+
        beq :+
        sta best
        inc bestb                  ; BOARD_WATFORD
:       lda #SOLIDISK_BITS         ; Solidisk: port B bits 0-3 as outputs
        sta UVIA_DDRB
        inc board                  ; BOARD_SOLIDISK
        jsr @count
        cmp best
        beq :+
        bcs @classify              ; Solidisk found the most: board and port B stay
:       lda bestb
        sta board
        inx                        ; not a Solidisk: give the user port back (X = 0:
        stx UVIA_DDRB              ; @count leaves X = $FF)
@classify:
        ldx #NSOCK-1
@b:     lda #$FF                   ; not RAM until proven
        sta SOCKCLASS,x
        jsr @selflip
        bne @bnext
        lda MOS_ROMTAB,x           ; a ROM the MOS is using
        beq :+
        lda #CLASS_ROM
        bne @bsc
@cstr:  .byte 0, "(C)"              ; (after the bne above: never executed)
        .assert * - @cstr = CSTR_LEN, error, "the copyright string's length"
:       stx ztmp                   ; a ROM image: 0 "(C)" at the copyright offset
        ldy ROMHDR_COPY
        ldx #<-CSTR_LEN            ; -4 up to 0, through the four bytes
@cchk:  lda ROMBASE,y
        cmp @cstr+CSTR_LEN-256,x
        bne @bfree
        iny                        ; (wraps in the page, as the unrolled reads did)
        inx
        bne @cchk
        lda #CLASS_IMAGE
        .byte OP_BIT_ABS           ; (bit abs: skips the lda)
@bfree: lda #CLASS_FREE
        ldx ztmp                   ; the socket again, for the store
@bsc:   sta SOCKCLASS,x
@bnext: dex
        bpl @b
        ; the signatures: 15 down, each RAM bank's ROMHDR_COPY byte SAVED and its
        ; number written there, tagged
        ldx #NSOCK-1
@sig:   lda SOCKCLASS,x
        bmi @snext
        jsr selwr
        lda ROMHDR_COPY
        sta SAVED,x
        txa
        ora #SIG_TAG
        sta ROMHDR_COPY
@snext: dex
        bpl @sig
        ldx #NSOCK-1
@chk:   lda SOCKCLASS,x
        bmi @cnext
        stx MOS_ROMSEL
        stx ROMSEL
        txa
        ora #SIG_TAG
        cmp ROMHDR_COPY
        beq @cnext
        sta SOCKCLASS,x            ; another number reached this RAM after us and keeps
                                    ; it (A = X+SIG_TAG: bit 7 set, still to be restored: not $FF)
@cnext: dex
        bpl @chk
        inx                        ; X = 0 (from $FF): restored in the reverse order of
@res:   ldy SOCKCLASS,x            ; the saving, so a chain of aliases unwinds to its
        iny                        ; first byte ($FF: not RAM)
        beq @rnext
        jsr selwr
        lda SAVED,x
        sta ROMHDR_COPY
@rnext: inx
        cpx #NSOCK
        bne @res
        lda old_bank
        sta MOS_ROMSEL
        sta ROMSEL
        cli
        ; the choice: the lowest sockets of class 0, then of class 1, then of class 2
        ldy #CLASS_FREE
        sty want
@cls:   ldx #0
@pick:  lda SOCKCLASS,x
        cmp want
        bne @pnext
        txa
        sta BANKMAP,y
        iny
        cpy #NBANKS
        beq @found
@pnext: inx
        cpx #NSOCK
        bne @pick
        inc want
        lda want
        cmp #CLASS_ROM+1
        bne @cls
        rts                        ; fewer than four (C = 1: A = CLASS_ROM+1)
        ; --- A = how many of the 16 banks take a write, the board being as set (the
        ; bank is left paged: interrupts are off until find_ram restores old_bank)
@count: lda #0
        sta want                   ; (want is free until the choice below)
        ldx #NSOCK-1
:       jsr @selflip
        bne :+
        inc want
:       dex
        bpl :--
        lda want
        rts
        ; --- Z = 1 if bank X, paged and selected for writing, takes a write: flip bit 0
        ; of the ROM type byte, look, put it back
@selflip:
        jsr selwr
@flip:  lda ROMHDR_TYPE
        tay
        eor #1
        sta ROMHDR_TYPE
        cmp ROMHDR_TYPE
        sty ROMHDR_TYPE            ; (a store leaves the flags)
@found: clc                        ; (the choice's exit: C = 0; Z is @flip's)
        rts

; not enough: say what was found and return to the MOS (MODE 7 still: this runs
; before the mode change)
no_ram:                            ; X = 16 (find_ram's fewer-than-four exit)
:       lda msg1-16,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       ldx board                  ; how the writes were tried: the board found
        lda board_msg,x
        tax
:       lda msgs,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       ldx #0
:       lda msg1b,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       ldx #0
@d:     lda SOCKCLASS,x            ; the writable banks, as hex digits
        bmi @dnext
        txa
        cmp #10
        bcc :+
        adc #6                     ; (the carry is set: 10 -> 'A')
:       adc #'0'
        jsr OSWRCH
        lda #' '
        jsr OSWRCH
@dnext: inx
        cpx #NSOCK
        bne @d
:       lda msg2-16,x              ; X = 16 from the loop above
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       rts

  .if MASTERONLY
no_master:                         ; a game built for the Master alone, on a Model B
        ldx #0
:       lda msg1,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       ldx #0
:       lda msgm,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       rts
msgm:     .byte " needs a BBC Master 128", 13, 10, 0
  .endif

old_bank:  .byte 0
npieces:  .byte 0
plen:     .word 0
fdc:      .byte 0
drive:    .byte 0
want:     .byte 0
board:    .byte 0                  ; BOARD_STD / BOARD_WATFORD / BOARD_SOLIDISK
best:     .byte 0                  ; find_ram: the most banks any way found, and which
bestb:    .byte 0
BANKMAP:      .res NBANKS          ; the socket of each of banks 4..7
SOCKCLASS:    .res NSOCK           ; per socket: CLASS_* as above, $FE an alias, $FF not RAM
SAVED:    .res NSOCK
fname:    .byte "BANKS"
fname_m:  .byte "B", 13            ; (patched to M on a Master: start)
gbpb:     .byte 0                  ; OSGBPB 6: the data address is all it reads
          .word DRVNAME, $FFFF
          .res 8
DRVNAME:  .res 8                   ; <len> "<drive>" <len> <boot option>
block:    .word fname
          .dword $FFFF0000 | BANKSBUF   ; load address: the $FFFF names the I/O
                                    ; processor, and DFS wants it even with no tube
          .dword $00000000         ; exec address: 0 here means "use the one above"
          .dword $00000000
          .dword $00000000
msg1:     .byte 13, 10
          .include "gamename.inc"   ; (the build's: the game's name)
  .if MASTERONLY
          .byte 0                  ; (no_master goes on with its own words; find_ram never
                                    ;  fails on a Master, which has four banks of its own)
  .endif
          .byte " needs 64K of sideways RAM: four", 13, 10
          .byte "16K banks in any sockets, writable", 13, 10, 0
board_msg: .byte msg_std-msgs, msg_wat-msgs, msg_sol-msgs
msgs:
msg_std:  .byte "through &FE30", 0
msg_wat:  .byte "the Watford way (&FF3x)", 0
msg_sol:  .byte "the Solidisk way (&FE60)", 0
msg1b:    .byte ".  Found:", 13, 10, 0
msg2:     .byte 13, 10, 13, 10
          .byte "Write-protected RAM reads as ROM: turn", 13, 10
          .byte "it off and press SHIFT-BREAK.", 13, 10, 0
