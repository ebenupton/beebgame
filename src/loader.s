; ============================================================================
; loader.s -- the boot loader: LOADER, run at $1900 (cfg/loader.cfg) by !BOOT
; under the MOS, one program for both machines.  A separate assembly (build.sh),
; one segment, CODE; its own data at the end.
;
; It asks the MOS which machine this is and loads that machine's bank images
; (BANKSB or BANKSM).  First the sideways RAM: the game wants four 16K banks it
; can write through ROMSEL and takes them from whatever sockets hold RAM
; (find_ram), then patches every bank number in the code it is about to put
; there -- the code is assembled for banks 4..7, and BANKS ends with a list of
; every byte that holds one (cpu.inc BANKREF), then of every write-bank store
; (cpu.inc wrsel) for a Watford or Solidisk board.  Then the drive DFS has
; current and the disc controller (the DFS ROM's version, or W / I held at
; boot), MODE 1 with a black palette, the pieces of the four banks out of BANKS
; (DFS will not load into a sideways bank, so the whole file is read to BANKSBUF
; and the pieces copied), and the findings into the start-up piece's header at
; $7000 for init.s `boot`, which is jumped to.  Everything else -- bank 7's
; images, every level -- the game loads itself (disc.s, ldprog.s), reading the
; physical banks from PBANK, which `boot` fills from that header.
;
; Exports: none (start is the load address).  Data the code names: defs_ld.inc's
; (build.sh: dsk_type, dsk_drv, DSK_BANKS, dsk_board, boot, BANKSBUF, PIECE_*,
; FIX_LEN, WR_LEN, WR_INX, BOARD_*), hw.inc's chips and MOS addresses.
; ============================================================================
        .setcpu "6502"
        .include "hw.inc"
        .include "defs_ld.inc"
OSFILE  = $FFDD                    ; the MOS's entries this asks of it
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
OSB_MOSVER = 0                     ; OSBYTE 0 with X = 1: the MOS version in X
OSB_INKEY  = $81                   ; OSBYTE $81, X = a negative INKEY code, Y = $FF:
                                    ;  X = Y = $FF if the key is down, 0 if not
INKEY_W = $DE                      ; W and I as INKEY codes (-34, -38)
INKEY_I = $DA
VDU_MODE = 22                      ; VDU 22, n: MODE n
SCREEN_MODE = 1                    ; MODE 1, the game's
OSF_LOAD = $FF                     ; OSFILE $FF: load a file to the block's address
OSF_IOPROC = $FFFF0000             ; a load address's high word: the I/O processor
OSGBPB_DRIVE = 6                   ; OSGBPB 6: the current drive's and directory's
                                    ;  names
NSOCK   = 16                       ; sideways sockets
NBANKS  = 4                        ; the banks the game wants
CSTR_LEN = 4                       ; a ROM's copyright string, as tested: 0, "(C)"
SIG_TAG = $C0                      ; find_ram's signature: the socket's number, tagged
CLASS_FREE = 0                     ; a socket's class (SOCKCLASS): RAM with no ROM
CLASS_IMAGE = 1                    ;  image; RAM with an image the MOS is not
CLASS_ROM  = 2                     ;  running; RAM holding a ROM the MOS recognised
CLASS_NONE = $FF                   ;  (and bit 7 set: not for the game -- $FF not RAM,
                                    ;  SIG_TAG | n an alias of a lower socket)
zsrc    = $70                      ; zero page: the MOS's user bytes
zdst    = $72
ztab    = $74
ztmp    = $76

; print msg: the 0-terminated text at msg,X to the screen; X ends on the 0. (Two
; anonymous labels.)
.macro print msg
:       lda msg,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:
.endmacro

; ----------------------------------------------------------------------------
; start: the loader's whole run -- the machine, the RAM, the drive, the
; controller, the mode, the pieces and their patches, the header, then `boot`
;   In:    the MOS, from !BOOT: interrupts on, the disc's drive current
;   Out:   does not return: jmp boot (init.s) with bank 7's socket paged and
;          write-selected and interrupts off; or no_ram's message and back to
;          the MOS (rts) if fewer than four banks take a write
;   Uses:  everything
; ----------------------------------------------------------------------------
        .segment "CODE"
start:
        ; ---- the machine: OSBYTE 0 with X = 1 gives the MOS version in X, 3
        ;      and up a Master's -- then the file is BANKSM
        lda #OSB_MOSVER
        ldx #1
        jsr OSBYTE
        cpx #MOS_MASTER
        bcc @modelb
        lda #'M'
        sta fname_m
@modelb:
        lda MOS_ROMSEL
        sta old_bank
        jsr find_ram               ; the four banks into BANKMAP -- or C = 1, fewer
        bcc @ram
        jmp no_ram                 ; say so and go back to the MOS
@ram:
        ; ---- the drive: whichever DFS has current (OSGBPB 6: its name is a
        ;      digit)
        lda #OSGBPB_DRIVE
        ldx #<gbpb
        ldy #>gbpb
        jsr OSGBPB
        ldx DRVNAME                ; the name's length (1), then the digit
        lda DRVNAME,x
        and #1                     ; '0'..'3' -> drive 0 or 1
        sta drive
        ; ---- the controller: W or I held at boot says which (fdc = 1 a 1770, 0
        ;      an 8271, as the zero it starts at); else the DFS ROM's version --
        ;      Acorn's 8271 DFSs are 0.90 and 1.20 (whose title "DFS,NET" has no
        ;      version at all), its 1770 DFSs 2.xx
        lda #OSB_INKEY
        ldx #INKEY_W
        ldy #$FF
        jsr OSBYTE
        inx                        ; X = $FF: W held
        bne @notw
        inc fdc                    ; 0 -> 1 (Z clear)
        bne @fdcdone
@notw:  ldx #INKEY_I               ; (A = OSB_INKEY still: OSBYTE keeps A)
        dey                        ; Y = 0 from OSBYTE (W not held) -> $FF
        jsr OSBYTE
        inx                        ; X = $FF: I held
        beq @fdcdone               ; an 8271, as set
        ldx #NSOCK-1
@rom:   lda MOS_ROMTAB,x           ; the MOS's ROM table: service ROMs (bit 7) only
        bpl @nextrom
        stx MOS_ROMSEL
        stx ROMSEL
        ldy #0
@loop:  lda ROMHDR_TITLE,y         ; the title's terminator
        beq @skip
        iny
        bne @loop
@skip:  lda ROMHDR_TITLE+1,y       ; the version follows it
        cmp #'2'
        bne @nextrom
        lda ROMHDR_TITLE           ; only a DFS (the title's first two letters)
        cmp #'D'
        bne @nextrom
        lda ROMHDR_TITLE+1
        cmp #'F'
        bne @nextrom
        inc fdc                    ; 0 -> 1: a 1770
        ldx #0                     ; (the dex below ends the loop)
@nextrom:
        dex
        bpl @rom
        lda old_bank
        sta MOS_ROMSEL
        sta ROMSEL
@fdcdone:
        ; ---- MODE 1 first: the MOS sets the ULA and the screen size latch, the
        ;      game reprograms only the CRTC.  The main-RAM pieces below land in
        ;      what is now screen memory, so the palette goes black before them
        lda #VDU_MODE
        jsr OSWRCH
        lda #SCREEN_MODE
        jsr OSWRCH
        ; the palette: logical colour 15 down to 0, each to black
        lda #((PAL_N-1) << PAL_SHIFT) | (PCOL_BLACK ^ PAL_INV)
        sec
@loop2: sta ULA_PAL
        sbc #1 << PAL_SHIFT
        bcs @loop2                 ; ($07 - $10 borrows: index 0 was the last)
        ; ---- the pieces (defs.inc PIECE_*): BANKS is a count, then (bank,
        ;      address, length) x count, then the pieces in that order, then the
        ;      patch lists.  A driver's bank byte has a controller flag
        ;      (PIECE_8271, PIECE_1770) and only this machine's is copied.  A
        ;      main-RAM piece is filed under bank 7 (build.sh), which pages
        ;      harmlessly.  The whole file is loaded at once (OSFILE; a byte at
        ;      a time through OSGBPB took the 1770 DFS twenty seconds) into what
        ;      is now screen memory, and the pieces copied out.  From here on
        ;      nothing calls the MOS again and the banks may hold ROMs it knows
        ;      (find_ram's last resort), so interrupts stay off: a stray one
        ;      would offer service calls to a ROM half overwritten.
        lda #OSF_LOAD
        ldx #<block
        ldy #>block
        jsr OSFILE
        sei
        lda BANKSBUF
        sta npieces
        asl                        ; the first piece follows the table: BANKSBUF +
        asl                        ;  1 + 5n (4n + n; C = 0: n < 64, then 5n < 256)
        adc npieces
        .assert PIECE_LEN = 5, error, "the table's size is 4n + n"
        adc #<(BANKSBUF+1)
        sta zsrc
        .assert >BANKSBUF = >(BANKSBUF+1), error, "the table starts in BANKSBUF's page"
        lda #>BANKSBUF             ; (the table's page too; the stores keep the carry)
        sta ztab+1
        adc #0
        sta zsrc+1
        lda #<(BANKSBUF+1)         ; the table
        sta ztab
@piece: ldy #PIECE_LEN-1           ; the entry backwards: A ends as the bank, Y as 0
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
        lda (ztab),y               ; the bank: the code's number, 4..7 (the socket is
        cmp #PIECE_1770            ;  BANKMAP's); a driver's flagged above PIECE_1770
        bcc @sel
        cmp #PIECE_8271            ; C = 1 the 8271's, 0 the 1770's: A = C ^ fdc is
        lda #0                     ;  0 when the piece is the other controller's
        rol
        eor fdc
        bne @mine
        lda zsrc                   ; not this machine's: copied onto itself, so only
        sta zdst                   ;  passed over
        lda zsrc+1
        sta zdst+1
        bne @cp                    ; (always: BANKSBUF is not in page 0)
@mine:  lda (ztab),y
        and #PIECE_BANKMASK
@sel:
        beq @cp                    ; a bank of 0 would page nothing (none is: build.sh
        jsr sel_bank               ;  files every piece under a bank); page it, and
@cp:    lda plen                   ;  its write bank on a board.  (Y = 0 from the
        bne @skip2                 ;  table read.)  The copy: plen counted down first
        lda plen+1
        beq @cpdone
        dec plen+1
@skip2: dec plen
        lda (zsrc),y
        sta (zdst),y
        inc zsrc
        bne @skip3
        inc zsrc+1
@skip3: inc zdst
        bne @cp
        inc zdst+1
        bne @cp                    ; (always: zdst never wraps)
@cpdone:
        lda ztab
        clc
        adc #PIECE_LEN
        sta ztab
        dec npieces
        bne @piece
        ; ---- the bank patches: (bank, address) x n then $FF, right after the
        ;      pieces, where zsrc now points.  The byte at each address is a
        ;      bank number, 4..7: it becomes the socket
@fix:   lda (zsrc),y               ; (Y = 0: the copy left it so, and @fixp sets it)
        bmi @fixdone               ; the $FF
        jsr sel_bank
        iny
        lda (zsrc),y
        sta zdst
        iny
        lda (zsrc),y
        sta zdst+1
        tya                        ; past the entry: Y = 2 and the carry make FIX_LEN
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
        ; ---- the write-bank stores: (bank, address, kind) x n then $FF, after
        ;      the $FF above.  Each is a `sta ROMSEL` in the code -- on a plain
        ;      machine a harmless second write of the bank, left alone.
        ;      Watford: `sta WRSEL_WATFORD+socket` for a constant bank (kind
        ;      4..7 says which), `sta WRSEL_WATFORD,x` (OP_STA_ABSX) where the
        ;      code has the bank in X (kind WR_INX); Solidisk: `sta
        ;      WRSEL_SOLIDISK` either way.
@wfix:  ldy #1                     ; zsrc is on the byte before each entry (the $FF
        lda (zsrc),y               ;  first)
        bmi @wfixdone              ; the $FF
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
        bcc @wsol                  ; C = the board's bit 0 (wrx's lsr): 1 Watford
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
@wsol:  lda #<WRSEL_SOLIDISK       ; Solidisk: sta $FE60 (the bank is in A there)
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
        bne @wfix                  ; (always: zsrc never wraps)
@wfixdone:
        ; ---- the findings into the start-up piece's header (init.s: $7000 on
        ;      both machines), with bank 7's socket paged and write-selected, as
        ;      init.s says `boot` is entered
        ldx BANKMAP+3
        jsr selwr
        .assert drive = fdc + 1 && dsk_drv = dsk_type + 1, error, "the controller and drive copied as a pair"
        ldx #1
@hdr:   lda fdc,x                  ; fdc, drive -> dsk_type, dsk_drv
        sta dsk_type,x
        dex
        bpl @hdr
        ldx #NBANKS-1
@loop3: lda BANKMAP,x
        sta DSK_BANKS,x
        dex
        bpl @loop3
        lda board
        sta dsk_board
        jmp boot                   ; the game's start-up, in main RAM (init.s)

; ----------------------------------------------------------------------------
; sel_bank: page a bank's socket for reading and writing
;   In:    A = the bank's code number, 4..7
;   Out:   X = its socket; C = board bit 0 (wrx)
;   Uses:  A X
;   Keeps: Y
; selwr: the same from X = a socket.  wrx: the write bank alone -- make socket X
; the one a store reaches, on a board that chooses that apart from ROMSEL
; (board: BOARD_*); C = board bit 0, Z = 1 unless Solidisk.  find_ram sets board
; and, for a Solidisk, the user VIA's DDRB first.
; ----------------------------------------------------------------------------
sel_bank:
        tax
        lda BANKMAP-4,x
        tax
selwr:  stx MOS_ROMSEL
        stx ROMSEL
wrx:    lda board
        .assert BOARD_STD = 0 && BOARD_WATFORD = 1 && BOARD_SOLIDISK = 2, error, "wrx tells the boards by bit 0"
        lsr                        ; plain: 0, C = 0; Watford: 0, C = 1; Solidisk:
        bcc @solidisk              ;  1, C = 0
        sta WRSEL_WATFORD,x        ; Watford: the address says which, the value nothing
@solidisk:
        beq @done                  ; Z = 1: plain, or Watford (a store keeps the flags)
        stx WRSEL_SOLIDISK         ; Solidisk: port B bits 0-3
@done:  rts

; ----------------------------------------------------------------------------
; find_ram: which sockets hold RAM, and which four the game gets
;   In:    MOS_ROMTAB (the MOS's ROM table); old_bank = ROMSEL to restore
;   Out:   C = 0: BANKMAP = the four sockets, board = BOARD_*, and the user
;          VIA's DDRB set for a Solidisk; C = 1: fewer than four (X = NSOCK, A =
;          CLASS_ROM + 1).  SOCKCLASS = every socket's class.  Interrupts on
;          again (cli), old_bank paged
;   Uses:  A X Y, ztmp, want, best, bestb, SAVED
; The test of a socket: page it through MOS_ROMSEL and ROMSEL, flip bit 0 of the
; ROM type byte (ROMHDR_TYPE), read it back, put it back (@selflip).  A floating
; bus fails it (both reads alike), and so does write-protected RAM, which the
; message then calls ROM.  First the board: the 16 sockets are counted (@count)
; writing through ROMSEL alone, then selecting the write bank the Watford way (a
; store to WRSEL_WATFORD + socket), then the Solidisk way (user VIA port B bits
; 0-3, made outputs), and the way that finds the MOST wins, plain winning a tie:
; a board's write latch rests on some socket, so the plain count finds that one
; on a board machine too.  Every write after goes through wrx.  Then each
; socket's class: CLASS_ROM, a ROM the MOS recognised (its table) -- taken only
; when nothing else is left, which is safe here because nothing calls the MOS
; once the pieces go down; CLASS_IMAGE, RAM with a ROM image the MOS is not
; running (0 "(C)" at the copyright offset); CLASS_FREE, the rest.  Two socket
; numbers that reach one RAM (a board answering two) are found by a tagged
; signature written to each and read back: the higher number is dropped (not a
; byte-for-byte comparison of the banks, which would call four blank banks one).
; The four are the lowest numbers of the best class.
; ----------------------------------------------------------------------------
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
        bcc @solidisk
        beq @solidisk
        sta best
        inc bestb                  ; BOARD_WATFORD
@solidisk:
        lda #SOLIDISK_BITS         ; Solidisk: port B bits 0-3 as outputs
        sta UVIA_DDRB
        inc board                  ; BOARD_SOLIDISK
        jsr @count
        cmp best
        beq @notsol
        bcs @classify              ; Solidisk found the most: board and port B stay
@notsol:
        lda bestb
        sta board
        inx                        ; not a Solidisk: the user port back (X = 0:
        stx UVIA_DDRB              ;  @count leaves X = $FF)
@classify:
        ldx #NSOCK-1
@sock:  lda #CLASS_NONE            ; not RAM until proven
        sta SOCKCLASS,x
        jsr @selflip
        bne @socknext
        lda MOS_ROMTAB,x           ; a ROM the MOS is using
        beq @image
        lda #CLASS_ROM
        bne @class                 ; (always)
@cstr:  .byte 0, "(C)"             ; (after the bne above: never executed)
        .assert * - @cstr = CSTR_LEN, error, "the copyright string's length"
@image: stx ztmp                   ; a ROM image: 0 "(C)" at the copyright offset
        ldy ROMHDR_COPY
        ldx #<-CSTR_LEN            ; -4 up to 0, through the four bytes
@cchk:  lda ROMBASE,y
        cmp @cstr+CSTR_LEN-256,x
        bne @free
        iny                        ; (wraps in the page)
        inx
        bne @cchk
        lda #CLASS_IMAGE
        .byte OP_BIT_ABS           ; (bit abs: the lda skipped)
@free:  lda #CLASS_FREE
        ldx ztmp                   ; the socket again, for the store
@class: sta SOCKCLASS,x
@socknext:
        dex
        bpl @sock
        ; ---- the signatures: 15 down, each RAM socket's ROMHDR_COPY byte saved
        ;      and its number written there, tagged
        ldx #NSOCK-1
@sig:   lda SOCKCLASS,x
        bmi @signext
        jsr selwr
        lda ROMHDR_COPY
        sta SAVED,x
        txa
        ora #SIG_TAG
        sta ROMHDR_COPY
@signext:
        dex
        bpl @sig
        ldx #NSOCK-1
@chk:   lda SOCKCLASS,x
        bmi @chknext
        stx MOS_ROMSEL
        stx ROMSEL
        txa
        ora #SIG_TAG
        cmp ROMHDR_COPY
        beq @chknext
        sta SOCKCLASS,x            ; a lower number wrote here after us and keeps
                                   ;  the RAM: an alias (SIG_TAG | X: bit 7 set, not
                                   ;  CLASS_NONE -- its byte is still to be restored)
@chknext:
        dex
        bpl @chk
        inx                        ; X = 0 (from $FF): restored in the reverse order
@res:   ldy SOCKCLASS,x            ;  of the saving, so a chain of aliases unwinds
        iny                        ;  to its first byte (CLASS_NONE: not RAM)
        beq @resnext
        jsr selwr
        lda SAVED,x
        sta ROMHDR_COPY
@resnext:
        inx
        cpx #NSOCK
        bne @res
        lda old_bank
        sta MOS_ROMSEL
        sta ROMSEL
        cli
        ; ---- the choice: the lowest sockets of class 0, then of class 1, then
        ;      of class 2
        ldy #CLASS_FREE
        sty want
@cls:   ldx #0
@pick:  lda SOCKCLASS,x
        cmp want
        bne @picknext
        txa
        sta BANKMAP,y
        iny
        cpy #NBANKS
        beq @found
@picknext:
        inx
        cpx #NSOCK
        bne @pick
        inc want
        lda want
        cmp #CLASS_ROM+1
        bne @cls
        rts                        ; fewer than four (C = 1: A = CLASS_ROM+1)
        ; ---- @count: A = how many of the 16 sockets take a write, the board
        ;      being as set.  X = $FF after; the last socket is left paged
        ;      (interrupts are off until find_ram restores old_bank).  want is
        ;      scratch here: the choice above sets it afterwards
@count: lda #0
        sta want
        ldx #NSOCK-1
@cnt:   jsr @selflip
        bne @cntnext
        inc want
@cntnext:
        dex
        bpl @cnt
        lda want
        rts
        ; ---- @selflip: Z = 1 if socket X, paged and selected for writing,
        ;      takes a write: flip bit 0 of the ROM type byte, look, put it
        ;      back.  Ends in @found's clc; rts (C = 0, which no caller reads)
@selflip:
        jsr selwr
        lda ROMHDR_TYPE
        tay
        eor #1
        sta ROMHDR_TYPE
        cmp ROMHDR_TYPE
        sty ROMHDR_TYPE            ; (a store keeps the flags)
@found: clc                        ; the choice's exit: C = 0 (Z is @selflip's there)
        rts

; ----------------------------------------------------------------------------
; no_ram: fewer than four banks -- say what was found and return to the MOS
;   In:    X = NSOCK (find_ram's exit); board, SOCKCLASS
;   Out:   rts to the MOS (MODE 7 still: this runs before the mode change)
;   Uses:  A X
; ----------------------------------------------------------------------------
no_ram:
        print msg1-NSOCK           ; (X = NSOCK) the name, and what the game needs
        ldx board                  ; how the writes were tried: the board found
        lda board_msg,x
        tax
        print msgs
        ldx #0
        print msg1b
        ldx #0
@digit: lda SOCKCLASS,x            ; the writable sockets, as hex digits
        bmi @next
        txa
        cmp #10                    ; ten digits, then the letters
        bcc @skip
        adc #'A'-'0'-10-1          ; (C = 1 from the cmp: + 'A' - '0' - 10 in all)
@skip:  adc #'0'
        jsr OSWRCH
        lda #' '
        jsr OSWRCH
@next:  inx
        cpx #NSOCK
        bne @digit
        print msg2-NSOCK           ; (X = NSOCK from the loop)
        rts


; ---------------------------------------------------------------- the data
old_bank:   .byte 0                ; ROMSEL at entry (the MOS's copy), paged again after
                                   ;  the tests and the DFS ROM scan
npieces:    .byte 0                ; BANKS: pieces to go, and the piece's length,
plen:       .word 0                ;  counted down
fdc:        .byte 0                ; the controller: 0 an 8271, 1 a 1770 -> dsk_type
drive:      .byte 0                ; the drive, 0 or 1 -> dsk_drv (the pair: the assert)
want:       .byte 0                ; find_ram: @count's count, then the class picked
board:      .byte 0                ; BOARD_STD / WATFORD / SOLIDISK -> dsk_board
best:       .byte 0                ; find_ram: the most sockets any way found, and the
bestb:      .byte 0                ;  way (a BOARD_*)
BANKMAP:    .res NBANKS            ; the socket of each of banks 4..7 -> DSK_BANKS
                                   ;  (sel_bank reads BANKMAP-4,x with X = 4..7)
SOCKCLASS:  .res NSOCK             ; per socket: CLASS_FREE / IMAGE / ROM / NONE, or
                                   ;  SIG_TAG | n, an alias
SAVED:      .res NSOCK             ; each RAM socket's ROMHDR_COPY byte while the
                                   ;  signatures are in
fname:      .byte "BANKS"          ; the file: BANKSB, or BANKSM on a Master (start
fname_m:    .byte "B", 13          ;  patches the letter)
gbpb:       .byte 0                ; OSGBPB 6's block: the data address is all it reads
            .word DRVNAME, $FFFF
            .res 8
DRVNAME:    .res 8                 ; <len> <drive digit> <len> <directory>
; OSFILE $FF's block: the name, the load address (its high word OSF_IOPROC: the
; I/O processor, which DFS wants even with no tube), an exec address whose low
; byte of 0 says "load where the block says", the length, the attributes
block:      .word fname
            .dword OSF_IOPROC | BANKSBUF
            .dword 0
            .dword 0
            .dword 0
; the messages: the game's name (gamename.inc, build.sh's) and what it needs;
; no_ram's by board (board_msg indexes msgs), the found list's head and tail
msg1:       .byte 13, 10
            .include "gamename.inc"
            .byte " needs 64K of sideways RAM: four", 13, 10
            .byte "16K banks in any sockets, writable", 13, 10, 0
board_msg:  .byte msg_std-msgs, msg_wat-msgs, msg_sol-msgs
msgs:
msg_std:    .byte "through &FE30", 0
msg_wat:    .byte "the Watford way (&FF3x)", 0
msg_sol:    .byte "the Solidisk way (&FE60)", 0
msg1b:      .byte ".  Found:", 13, 10, 0
msg2:       .byte 13, 10, 13, 10
            .byte "Write-protected RAM reads as ROM: turn", 13, 10
            .byte "it off and press SHIFT-BREAK.", 13, 10, 0
