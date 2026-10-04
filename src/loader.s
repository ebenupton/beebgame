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
        .include "defs_ld.inc"      ; boot, dsk_type, dsk_drv, DSK_BANKS, dsk_board,
                                    ; BOARD_*, WRSEL_* (build.sh)
OSFILE  = $FFDD
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
ROMSEL  = $FE30
ROMSELC = $F4
ROMTYPE = $02A1                    ; the MOS's ROM table: the type byte of every ROM
                                    ; it recognised at BREAK, 0 for the other sockets
BUF     = $2000
zsrc    = $70
zdst    = $72
ztab    = $74
ztmp    = $76

        .segment "CODE"
start:
        ; ---- the machine: one disc, each machine its own bank images (BANKSB, BANKSM).
        ; OSBYTE 0 with X = 1 gives the MOS version in X: 3 and up are a Master's
        lda #0
        ldx #1
        jsr OSBYTE
        cpx #3
        bcc :+
        lda #'M'
        sta fname+5
  .if MASTERONLY
        bne :++                    ; (a Master: on)
:       jmp no_master              ; a game built for the Master alone (build.sh MASTERONLY)
:
  .else
:
  .endif
        lda ROMSELC
        sta old_bank
        jsr find_ram               ; the four banks, into BANKMAP -- or fewer, and C set
        bcc :+
        jmp no_ram                 ; say so and go back to the MOS
:
        ; ---- the drive: whichever DFS has current (OSGBPB 6: its name is the digit)
        lda #6
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

        lda #$81
        ldx #$DE                   ; W (negative INKEY code)
        ldy #$FF
        jsr OSBYTE
        inx                        ; X = $FF: W held
        bne :+
        inc fdc                    ; 0 (above) -> 1, Z clear
        bne @fdcdone
:       ldx #$DA                   ; I (A = $81 still: OSBYTE keeps A)
        dey                        ; Y = $FF (0 from OSBYTE: W not held)
        jsr OSBYTE
        inx                        ; X = $FF: I held
        beq @fdcdone               ; 8271, as set
        ldx #15
@rom:   lda ROMTYPE,x              ; the MOS's ROM type table: service ROMs only
        bpl @nextrom
        stx ROMSELC
        stx ROMSEL
        ldy #0
:       lda $8009,y                ; the title
        beq :+
        iny
        bne :-
:       lda $800A,y                ; the version follows its terminator
        cmp #'2'
        bne @nextrom
        lda $8009                  ; only a DFS: the title starts "DFS" (Acorn's)
        cmp #'D'
        bne @nextrom
        lda $800A
        cmp #'F'
        bne @nextrom
        inc fdc                    ; 0 -> 1
        ldx #0
@nextrom:
        dex
        bpl @rom
        lda old_bank
        sta ROMSELC
        sta ROMSEL
@fdcdone:
        lda #22                    ; MODE 1 first: the OS sets the ULA and the screen size
        jsr OSWRCH                 ; latch, the game reprograms only the CRTC -- and the
        lda #1                     ; main-RAM pieces below land in what is now screen
        jsr OSWRCH                 ; memory, so the palette goes black before they do
        lda #$F7                   ; logical colour 15 down to 0, each to black
        sec
:       sta $FE21
        sbc #$10
        bcs :-                     ; ($07 - $10 borrows: the last one written)
        ; ---- the pieces: BANKS is a count, then (bank, address, length) x count, then
        ; the pieces in that order, then the bank patches.  A disc driver's bank has a
        ; controller flag (bit 7 the 8271, bit 6 the 1770) and only the machine's is copied.  A main-RAM piece is filed
        ; under bank 7 (build.sh), which pages harmlessly; bank 0 would page nothing.
        ; The whole file is loaded at once (OSFILE: a byte at a time through
        ; OSGBPB took the 1770 DFS twenty seconds) into what is now screen memory, and
        ; the pieces copied out.  From here on nothing calls the MOS again and the banks
        ; may hold ROMs it knows (find_ram's last resort), so interrupts stay off: a
        ; stray one would have it offer service calls to a ROM half overwritten.
        lda #$FF                   ; OSFILE 255: load, address from the block
        ldx #<block
        ldy #>block
        jsr OSFILE
        sei
        lda BUF
        sta npieces
        asl                        ; the first piece follows the table: BUF + 1 + 5n
        asl
        adc npieces
        adc #<(BUF+1)              ; (+1: C clear, 5n < 256)
        sta zsrc
        .assert >BUF = >(BUF+1), error, "the table starts in BUF's page"
        lda #>BUF                  ; (the table's page too; the stores keep the carry)
        sta ztab+1
        adc #0
        sta zsrc+1
        lda #<(BUF+1)              ; the table
        sta ztab
@piece: ldy #4                     ; backwards: A ends as the bank, Y as 0
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
        cmp #$40                   ; the socket it goes to is BANKMAP's (main RAM: no paging)
        bcc @sel
        cmp #$80                   ; a driver (disc.s): bit 7 the 8271's, bit 6 the 1770's,
        lda #0                     ; both for the same place -- only this machine's is
        rol                        ; copied
        eor fdc                    ; (1 = the 8271's piece; fdc 0 = an 8271)
        bne @mine
        lda zsrc                   ; not this machine's: copied onto itself, so only
        sta zdst                   ; passed over (Y = 0)
        lda zsrc+1
        sta zdst+1
        bne @cp                    ; (BUF is not in page 0)
@mine:  lda (ztab),y
        and #$3F
@sel:
  .if GAMEHAZEL
        php                        ; (the flags stand for the beq below)
        cmp #1                     ; 1, HAZEL: ACCCON Y, and it stays set for the game
        bne :+
        plp
        lda $FE34
        ora #$08
        sta $FE34
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
        adc #5
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
        tya                        ; past the entry: Y = 2, and the carry makes it 3
        sec
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
        ; Each is a `sta $FE30` in the code, a harmless second write of the bank on a
        ; plain machine and left alone there.  Watford: `sta $FF30+socket` for a constant
        ; bank (kind 4..7 says which), `sta $FF30,x` (opcode $9D) where the code has the
        ; bank in X (kind $FE); Solidisk: `sta $FE60` either way.
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
        cpx #$FE
        beq @wdyn
        lda BANKMAP-4,x            ; Watford, a constant bank: sta $FF30 + its socket
        ora #<WRSEL_WATFORD
@wwat:  ldx #>WRSEL_WATFORD
        bne @wadr                  ; (always: $FF)
@wdyn:  lda #$9D                   ; Watford, the bank in X: sta $FF30,x
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
        adc #4
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
        ldx #3
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
selwr:  stx ROMSELC
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
:       lda #$0F                   ; Solidisk: port B bits 0-3 as outputs
        sta $FE62
        inc board                  ; BOARD_SOLIDISK
        jsr @count
        cmp best
        beq :+
        bcs @classify              ; Solidisk found the most: board and port B stay
:       lda bestb
        sta board
        inx                        ; not a Solidisk: give the user port back (X = 0:
        stx $FE62                  ; @count leaves X = $FF)
@classify:
        ldx #15
@b:     lda #$FF                   ; not RAM until proven
        sta SOCKCLASS,x
        jsr @selflip
        bne @bnext
        lda ROMTYPE,x              ; a ROM the MOS is using
        beq :+
        lda #2
        bne @bsc
@cstr:  .byte 0, "(C)"              ; (after the bne above: never executed)
:       stx ztmp                   ; a ROM image: 0 "(C)" at the copyright offset
        ldy $8007
        ldx #$FC                   ; -4 up to 0, through the four bytes
@cchk:  lda $8000,y
        cmp @cstr-$FC,x
        bne @bfree
        iny                        ; (wraps in the page, as the unrolled reads did)
        inx
        bne @cchk
        lda #1
        .byte $2C                  ; (bit abs: skips the lda #0)
@bfree: lda #0
        ldx ztmp                   ; the socket again, for the store
@bsc:   sta SOCKCLASS,x
@bnext: dex
        bpl @b
        ; the signatures: 15 down, each RAM bank's $8007 SAVED and its number written
        ldx #15
@sig:   lda SOCKCLASS,x
        bmi @snext
        jsr selwr
        lda $8007
        sta SAVED,x
        txa
        ora #$C0
        sta $8007
@snext: dex
        bpl @sig
        ldx #15
@chk:   lda SOCKCLASS,x
        bmi @cnext
        stx ROMSELC
        stx ROMSEL
        txa
        ora #$C0
        cmp $8007
        beq @cnext
        sta SOCKCLASS,x            ; another number reached this RAM after us and keeps
                                    ; it (A = X+$C0: bit 7 set, still to be restored: not $FF)
@cnext: dex
        bpl @chk
        inx                        ; X = 0 (from $FF): restored in the reverse order of
@res:   ldy SOCKCLASS,x            ; the saving, so a chain of aliases unwinds to its
        iny                        ; first byte ($FF: not RAM)
        beq @rnext
        jsr selwr
        lda SAVED,x
        sta $8007
@rnext: inx
        cpx #16
        bne @res
        lda old_bank
        sta ROMSELC
        sta ROMSEL
        cli
        ; the choice: the lowest sockets of class 0, then of class 1, then of class 2
        ldy #0
        sty want
@cls:   ldx #0
@pick:  lda SOCKCLASS,x
        cmp want
        bne @pnext
        txa
        sta BANKMAP,y
        iny
        cpy #4
        beq @found
@pnext: inx
        cpx #16
        bne @pick
        inc want
        lda want
        cmp #3
        bne @cls
        rts                        ; fewer than four (C = 1: A = 3)
        ; --- A = how many of the 16 banks take a write, the board being as set (the
        ; bank is left paged: interrupts are off until find_ram restores old_bank)
@count: lda #0
        sta want                   ; (want is free until the choice below)
        ldx #15
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
@flip:  lda $8006
        tay
        eor #1
        sta $8006
        cmp $8006
        sty $8006                  ; (a store leaves the flags)
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
        cpx #16
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
pbank:    .byte 0
plen:     .word 0
fdc:      .byte 0
drive:    .byte 0
want:     .byte 0
board:    .byte 0                  ; BOARD_STD / BOARD_WATFORD / BOARD_SOLIDISK
best:     .byte 0                  ; find_ram: the most banks any way found, and which
bestb:    .byte 0
BANKMAP:      .res 4               ; the socket of each of banks 4..7
SOCKCLASS:    .res 16              ; per socket: 0..2 as above, $FE an alias, $FF not RAM
SAVED:    .res 16
fname:    .byte "BANKSB", 13          ; (the B patched to M on a Master: start)
gbpb:     .byte 0                  ; OSGBPB 6: the data address is all it reads
          .word DRVNAME, $FFFF
          .res 8
DRVNAME:  .res 8                   ; <len> "<drive>" <len> <boot option>
block:    .word fname
          .dword $FFFF0000 | BUF   ; load address: the $FFFF names the I/O
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
