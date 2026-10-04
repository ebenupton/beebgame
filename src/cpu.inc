; ============================================================================
; cpu.inc -- the two machines in one source: the hardware flag, the build options,
; the bank patching and the write bank, the 6502 spellings of the 65C02's forms
;
; Included first, by the game's main assembly and by ldconst.s.  The Master is a
; 65C02; the Model B is a 6502.  Every 65C02 spelling the engine and the logic use
; in shared code goes through a macro here, so one source assembles for both: on the
; Master each is its one instruction, on the Model B an expansion whose side effects
; (a register loaded, the flags) every site is audited for.  Inside .if .not BHW
; (Master-only code) the instruction is written natively.  The set (each macro's
; own header, at the end of this file, gives the two expansions and the flags):
;
;   stz m        A is DEAD at the site (the 6502 form is lda #0 / sta)
;   zero m, ...  stz of each of up to eight addresses, one lda #0 on the 6502
;   sta0 m, ...  the same where A is ALREADY 0 (the 6502 stores it, no lda #0)
;   stzx m       A is live and X dead (ldx #0 / stx)
;   stz01 m      m is a 0/1 flag that is 1 here (dec m)
;   inca, deca   A +/- 1; the CARRY is DESTROYED on the 6502 (clc / adc, sec / sbc)
;   incax        A + 1 with X dead; the carry survives on both (tax / inx / txa)
;   ldaz, cmpz   lda / cmp (zp) with no index: Y is DESTROYED (ldy #0)
;   ldaz0, staz0 lda / sta (zp) where Y is ALREADY 0 (the ,y form)
;   ldazx zp     lda (zp) where Y is live and X dead (ldx #0 / lda (zp,x))
;   ldy1         Y = 1 where Y is 0 (iny)
;   bitimm v     bit #imm: Z from A & v, A and X kept, through mtmp
;   bra t        the 6502's jmp (the Master's own instruction: no macro there)
;
; mtmp is zero page scratch bitimm owns; nothing that runs in the interrupt uses
; bitimm (its two sites are the sprite prologue's, frame.s).
;
; Sections:
;   the hardware flag and the build options
;   PLACEH            a segment by hardware: the interrupt's work
;   bank numbers      BANKREF, bankimm, setbank, ldpbank: the boot loader's patching
;   the write bank    WRREC, wrsel, wrback: the Solidisk and Watford boards
;   placement         SAMEPAGE, PAD
;   the spellings     the macros above, one definition a CPU
; ============================================================================

; ---------------------------------------------------------------- the hardware flag
; One structure, two machines (docs/DESIGN.md): code in the sideways banks with the
; data it reads, the level gathered into the banks at load.  BHW is the Model B's
; HARDWARE: a 6502, one screen of main RAM (two software rings with mirror rows), the
; 8271 or Acorn 1770, the write-select boards.  BHW=0 is the Master's: 65C02, the
; hardware-wrapped ring in main and shadow RAM, its interrupt handler in main RAM,
; its 1770.  tools/build.sh builds both (-D BHW=0 for the Master).
  .ifndef BHW
BHW = 1
  .endif
; The build's options (tools/build.sh says what each does), 0 unless it sets them.
  .ifndef MASTERONLY
MASTERONLY = 0                     ; the Master alone: no Model B build
  .endif
  .ifndef GAMEHAZEL
GAMEHAZEL = 0                      ; the game's code in HAZEL too (the Master alone)
  .endif
  .ifndef GAMESOUND
GAMESOUND = 0                      ; the game's own sound player (hook_sound)
  .endif
  .ifndef TALLMAP
TALLMAP = 0                        ; maps taller than 128 tiles (the Master alone)
  .endif
  .if TALLMAP && BHW
        .error "TALLMAP needs the Master's 32-row ring (the Model B's ring is 23 rows)"
  .endif
  .ifndef DRAWFLAGS
DRAWFLAGS = 0                      ; draw flags in the sprite list's x high byte
  .endif
  .ifndef TIGHTBSS
TIGHTBSS = 0                       ; 9-byte sprite records, ENGBSS not page aligned
  .endif
  .ifndef ALLLEVELS
ALLLEVELS = 0                      ; a test build: every level on the chooser, every
  .endif                           ;  bonus level taken (the game's)
  .if GAMEHAZEL && (BHW <> 0 || MASTERONLY = 0)
        .error "GAMEHAZEL is the Master's alone: build with MASTERONLY=1"
  .endif

; ---------------------------------------------------------------- PLACEH
; PLACEH mseg, bseg: the segment by hardware for the interrupt handler's own work
; and state -- bank 7 with the Model B's handler body (bseg), main RAM with the
; Master's (mseg).  The first of the Master's three blessed placements (DESIGN.md).
.macro PLACEH mseg, bseg
  .if ::BHW                        ; blessed placement: the handler and its state
        .segment bseg
  .else
        .segment mseg
  .endif
.endmacro

; ---------------------------------------------------------------- bank numbers
; The four banks are whichever sockets the boot loader finds RAM in (loader.s), on
; either machine.  The code is assembled for banks 4..7 (BANK_SPR, BANK_TILES,
; BANK_MAP, BANK_LVL) and every byte of it that holds a bank number is recorded here,
; with the bank whose image holds the byte, for the loader to patch before the game
; starts (the BANKFIX table, appended to BANKS).  Bank 7's game image comes off the
; disc later and is patched as it comes in (ldprog.s image_load, from its own lists);
; other code that comes off the disc -- the level loader, the menus' image -- is not
; patched: it reads the physical bank from PBANK (low BSS, four bytes indexed by
; bank - 4).
;   bankimm op, n, b   op #n, the operand a bank number: in bank b's image (0 = the
;                      low-RAM image, in the BOOT piece); a fourth argument tells two
;                      alike sites in one routine apart
;   setbank n, b       page bank n in, from code in bank b (A destroyed); likewise
;   ldpbank op, n      op #n from code the loader cannot patch: PBANK's byte instead
;                      (no site today; tools/build.sh refuses a bankimm in the menus'
;                      image and names this)
;   BANKREF name, b    the byte just emitted is a bank number
; The site is marked with a cheap label, @bf_<name>, because any other kind of symbol
; would end the enclosing routine's @ scope; so two sites in one routine need
; different names (bankimm's is the operation and the bank -- a clash is a duplicate
; symbol at assembly, not a silent miss).
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute
.macro BANKREF name, b
        .ident(.concat("@bf_", name)):
        .pushseg
        .segment "BANKFIX"
  .if b = 0                        ; low RAM: its image, in the BOOT piece (main RAM,
        .byte BANK_LVL             ;  filed under bank 7 in BANKS).  The operand is
                                   ;  the byte before the label: op #n is 2 bytes
        .word .ident(.concat("@bf_", name)) - 1 - __LOWCODE_RUN__ + __LOWCODE_LOAD__
  .else
        .byte b
        .word .ident(.concat("@bf_", name)) - 1
  .endif
        .popseg
.endmacro
.macro bankimm op, n, b, tag
  .if .blank(b)
        .error "bankimm: the Model B needs the bank the code is in"
  .endif
        op #n
  .if .blank(tag)
        BANKREF .sprintf("%s_%d", .string(op), n), b
  .else
        BANKREF .sprintf("%s_%d_%d", .string(op), n, tag), b
  .endif
.endmacro
.macro setbank n, b, tag           ; ROMSEL_CPY first: ROMSEL's copy, which the
        bankimm lda, n, b, tag     ;  interrupt restores from (the read bank alone:
        sta ROMSEL_CPY             ;  the write bank stays 7's -- below)
        sta ROMSEL
.endmacro
.macro ldpbank op, n
        op ::PBANK + (n - ::BANK_SPR)
.endmacro

; ---------------------------------------------------------------- the write bank
; Solidisk and Watford boards choose the bank a STORE goes to with a register of
; their own -- Solidisk: user VIA port B bits 0-3 (UVIA_DDRB = SOLIDISK_BITS, then
; WRSEL_SOLIDISK = bank); Watford: a store to WRSEL_WATFORD + bank -- and read through
; ROMSEL like everyone else.  So every switch that a store into sideways RAM may
; follow carries a companion store, assembled as a second `sta ROMSEL` (harmless: A
; holds the bank) and listed in the WRFIX segment for the boot loader to rewrite by
; board: Watford `sta $FF3n` (n the socket), Solidisk `sta $FE60`.  (wrback's is
; `sta WRSEL_WATFORD` as assembled: a store into the MOS's ROM, nothing on a plain
; machine, where a second sta ROMSEL would page bank 7 in under the code running.)
; On the Master the macros are empty: it has no board.
; The rule: the write bank is bank 7's, always, but in a WINDOW -- a store into
; another bank, between a wrsel to it and a wrback that puts 7's back (the sprite
; banks' entry, map_put, selbb, boot, draw_rect).  Nothing else moves it: a switch
; that only reads (every other crossing, page_logic, setbank) leaves it be, and the
; interrupt stores into no bank (what it keeps is in main RAM), so it neither needs
; a write bank nor sets one -- an interrupt inside a window finds the window's and
; leaves it.
;   wrsel n, b [, tag]   after a switch to the constant bank n (A = n), in bank b's
;                        image (0 = the low-RAM image, as BANKREF)
;   wrback b [, tag]     a window's end: the write bank back to 7's (A lost)
;   WRREC kind, b, name  the record: the image's bank, the store's address, the kind
;                        -- 4..7 a constant bank, or WR_INX, the bank in X (`sta
;                        $FF30,x` on a Watford board: no emitter today; ldprog.s and
;                        build.sh still know the kind)
; Every .if BHW here is hardware: the boards.
WR_INX = $FE                       ; a record's kind for "the bank in X"
WRBACK_TAG = 99                    ; wrback's own site tag: no caller's reaches it
.macro WRREC kind, b, name
  .if ::BHW
        .ident(.concat("@wr_", name)):
        .pushseg
        .segment "WRFIX"
    .if b = 0                      ; (the label is past the 3-byte sta abs)
        .byte BANK_LVL
        .word .ident(.concat("@wr_", name)) - 3 - __LOWCODE_RUN__ + __LOWCODE_LOAD__
    .else
        .byte b
        .word .ident(.concat("@wr_", name)) - 3
    .endif
        .byte kind
        .popseg
  .endif
.endmacro
.macro wrsel n, b, tag
  .if ::BHW
        sta ROMSEL
    .if .blank(tag)
        WRREC n, b, .sprintf("s_%d", n)
    .else
        WRREC n, b, .sprintf("s_%d_%d", n, tag)
    .endif
  .endif
.endmacro
.macro wrback b, tag               ; A = bank 7's (Solidisk's store writes A), then a
  .if ::BHW                        ;  store the boot loader makes the board's
    .if .blank(tag)
        bankimm lda, ::BANK_LVL, b, ::WRBACK_TAG
        sta ::WRSEL_WATFORD
        WRREC ::BANK_LVL, b, .sprintf("s_7_%d", ::WRBACK_TAG)
    .else
        bankimm lda, ::BANK_LVL, b, tag
        sta ::WRSEL_WATFORD
        WRREC ::BANK_LVL, b, .sprintf("s_7_%d", tag)
    .endif
  .endif
.endmacro

; ---------------------------------------------------------------- placement
; SAMEPAGE from, to: after a hot branch, assert it and its target share a page
; (checked at link time; a PAD before it fixes it).  PAD b, m: bytes of padding, the
; Model B's and the Master's (pads.inc), to move the code after it off a page
; boundary: the code differs in length between the machines, so the pads do, while
; the data after lies alike whatever they are (tools/pincfg.py pins it).
.macro SAMEPAGE from, to
        .assert >(from) = >(to), warning, "a hot branch crosses a page (+1 cycle when taken)"
.endmacro
.macro PAD b, m
  .if ::BHW                        ; CPU spelling: the code lengths differ
        .res b
  .else
        .res m
  .endif
.endmacro

; ---------------------------------------------------------------- the spellings
; Each macro: what it is for, the Master's expansion, the Model B's, and the flags.
; "kept" means the expansion leaves the flag as it found it.  The Master's
; definitions are one instruction each, so the notes sit with the Model B's.
; Every .if here is CPU spelling.
  .if .not ::BHW
        .setcpu "65C02"
  .else
        .setcpu "6502"
  .endif

; stz m [,x]: m = 0, A DEAD at the site.
;   Master   stz m  / stz m,x        N, Z, C kept
;   Model B  lda #0 / sta m[,x]      N = 0, Z = 1; C kept; A = 0
  .if ::BHW
.macro stz arg, ix
        lda #0
  .if .paramcount = 2
        sta arg,ix
  .else
        sta arg
  .endif
.endmacro
  .endif

; sta0 m, ...: up to eight addresses = 0 where A is ALREADY 0 (the site's own lda #0
; or a stz's expansion precedes it with nothing touching A between).  Not indexed.
;   Master   stz each                N, Z, C kept
;   Model B  sta each                flags kept
; zero m, ...: the same with A DEAD: the Model B loads the zero once.
;   Master   stz each                N, Z, C kept
;   Model B  lda #0 / sta each       N = 0, Z = 1; C kept; A = 0
  .if ::BHW
.macro sta0 a1, a2, a3, a4, a5, a6, a7, a8
        sta a1
  .ifnblank a2
        sta0 a2, a3, a4, a5, a6, a7, a8
  .endif
.endmacro
.macro zero a1, a2, a3, a4, a5, a6, a7, a8
        lda #0
        sta0 a1, a2, a3, a4, a5, a6, a7, a8
.endmacro
  .else
.macro sta0 a1, a2, a3, a4, a5, a6, a7, a8
        stz a1
  .ifnblank a2
        sta0 a2, a3, a4, a5, a6, a7, a8
  .endif
.endmacro
.macro zero a1, a2, a3, a4, a5, a6, a7, a8
        sta0 a1, a2, a3, a4, a5, a6, a7, a8
.endmacro
  .endif

; stzx m: m = 0 with A live and X DEAD.
;   Master   stz m                   N, Z, C kept
;   Model B  ldx #0 / stx m          N = 0, Z = 1; C kept; X = 0
  .if ::BHW
.macro stzx m
        ldx #0
        stx m
.endmacro
  .else
.macro stzx m
        stz m
.endmacro
  .endif

; stz01 m: a 0/1 flag that is 1 here -> 0.  A site that branches on Z after it must
; hold Z = 1 on the way in (the Master's stz keeps the flags; the Model B's dec sets
; them from the 0).
;   Master   stz m                   N, Z, C kept
;   Model B  dec m                   N = 0, Z = 1; C kept
  .if ::BHW
.macro stz01 m
        dec m
.endmacro
  .else
.macro stz01 m
        stz m
.endmacro
  .endif

; inca, deca: A + 1, A - 1.  The CARRY IS DESTROYED on the Model B: only for a site
; where the next use of C is a write.
;   Master   inc a / dec a           N, Z from A; C, V kept
;   Model B  clc / adc #1            N, Z, V from A; C = 1 only if A was $FF
;            sec / sbc #1            N, Z, V from A; C = 0 only if A was 0
; incax: A + 1 with X DEAD; the carry survives on both.
;   Master   inc a                   N, Z from A; C, V kept
;   Model B  tax / inx / txa         N, Z from A; C, V kept; X = A
  .if ::BHW
.macro inca
        clc
        adc #1
.endmacro
.macro deca
        sec
        sbc #1
.endmacro
.macro incax
        tax
        inx
        txa
.endmacro
  .else
.macro inca
        inc a
.endmacro
.macro deca
        dec a
.endmacro
.macro incax
        inc a
.endmacro
  .endif

; ldaz zp, cmpz zp: lda / cmp (zp) with no index.  Y is DESTROYED on the Model B (and
; is 0 after: ldaz0, staz0 and ldy1 build on that).
;   Master   lda (zp) / cmp (zp)     N, Z (cmp: C too) from the result; Y kept
;   Model B  ldy #0 / lda (zp),y     the same flags (ldy's are overwritten); Y = 0
;            ldy #0 / cmp (zp),y
; ldaz0 zp, staz0 zp: lda / sta (zp) where Y is ALREADY 0.
;   Master   lda (zp) / sta (zp)     lda: N, Z from A;  sta: flags kept
;   Model B  lda (zp),y / sta (zp),y the same
; ldazx zp: lda (zp) where Y is live and X DEAD.
;   Master   lda (zp)                N, Z from A
;   Model B  ldx #0 / lda (zp,x)     N, Z from A; X = 0
; ldy1: Y = 1 where Y is 0.
;   Master   ldy #1                  N = 0, Z = 0
;   Model B  iny                     N = 0, Z = 0
  .if ::BHW
.macro ldaz zp
        ldy #0
        lda (zp),y
.endmacro
.macro cmpz zp
        ldy #0
        cmp (zp),y
.endmacro
.macro ldaz0 zp
        lda (zp),y
.endmacro
.macro staz0 zp
        sta (zp),y
.endmacro
.macro ldazx zp
        ldx #0
        lda (zp,x)
.endmacro
.macro ldy1
        iny
.endmacro
  .else
.macro ldaz zp
        lda (zp)
.endmacro
.macro cmpz zp
        cmp (zp)
.endmacro
.macro ldaz0 zp
        lda (zp)
.endmacro
.macro staz0 zp
        sta (zp)
.endmacro
.macro ldazx zp
        lda (zp)
.endmacro
.macro ldy1
        ldy #1
.endmacro
  .endif

; bitimm v: bit #v -- Z = (A & v) = 0, A and X kept.  Through mtmp on the Model B, so
; not for the interrupt (its sites are the sprite prologue's, frame.s).
;   Master   bit #v                  Z from A & v; N, V kept (the immediate form sets
;                                    Z only); A kept
;   Model B  sta mtmp / and #v / php / lda mtmp / plp
;                                    Z from A & v, N from it too; C, V kept; A kept
  .if ::BHW
.macro bitimm v
        sta mtmp
        and #v
        php
        lda mtmp
        plp
.endmacro
  .else
.macro bitimm v
        bit #v
.endmacro
  .endif

; bra t: an unconditional branch.  The Master's instruction (2 bytes, 3 cycles); the
; Model B has none, so its jmp (3 bytes, 3 cycles).  No flags on either.
  .if ::BHW
.macro bra t
        jmp t
.endmacro
  .endif
