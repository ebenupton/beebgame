; ============================================================================
; The load-time program: read into LDPROG ($0E00) by disc.s at every level load and
; every swap of bank 7's image, and run there, in main RAM, where it can page any bank
; in.  One per machine (LDPROGB, LDPROGM).  The display is black and the screen is
; its scratch (defs.inc STAGE, STAGE_LVL: $1C00-$7FFF on the Model B; $3000-$7FFF of
; main and shadow RAM on the Master).  A level is gathered from the shared files --
; the tile set's, SPRC, SPRX, the level's own -- by the lists the packer
; (Cleo's tools/assets.py) put in the level file: which tiles, and where every image goes.
; Bank 7 is paged on entry and after each part; read_sectors (disc.s) is its kernel's,
; which no image covers, and reads into main RAM.
;
;   LDPROG+0  ld_entry    X = a level 0..15, or an image load (defs.inc LDOP_):
;                         the load, the chain's restart, and an image's hook
; ============================================================================
        .ifndef BHW                 ; (cpu.inc's flag: the Model B's hardware unless the
BHW = 1                             ;  build says -D BHW=0, the Master's)
        .endif
        .ifndef TILEMIRROR          ; (cpu.inc's flag: tile mirroring, off by default)
TILEMIRROR = 0
        .endif
        .ifndef GAMEHAZEL           ; (cpu.inc's: the game's code in HAZEL -- then SPRX is
GAMEHAZEL = 0                       ;  staged from the disc every time, as the Model B's)
        .endif
        .ifndef SPRGEOM             ; (cpu.inc's: the split directory, 2 bytes a sprite id)
SPRGEOM = 0
        .endif
SPRXKEEP = (BHW = 0) && (GAMEHAZEL = 0)   ; the Master keeps SPRX in HAZEL and ANDY
        .include "defs_ld.inc"      ; the addresses the game exports (build.sh)
        .include "files.inc"        ; the disc's sector table (mkdfs.py table)
        .include "levelfmt.inc"     ; the level file's sections and header (tools/levelfile.py)
ROMSEL     = $FE30
ROMSEL_CPY = $F4
VIA_IFR    = $FE4D                  ; (the system VIA's: ld_resume)
ACCCON     = $FE34                  ; (the Master: bit 2, X, puts the CPU's
                                    ;  $3000-$7FFF in shadow RAM -- where STAGE is)
; The banks are whichever sockets the boot loader found RAM in: it left their numbers
; in PBANK (low BSS, one byte per bank 4..7).  This program comes off the disc at
; every load, so the loader cannot patch it as it does the banks' code: every switch
; here reads the physical bank from PBANK, and the placement lists' bank bytes
; (4 or 5, the packer's) go through it too.
BANK_MAP   = 5                      ; (the placement lists' number for bank 5)
PB_SPR     = PBANK
PB_TILES   = PBANK + 2
PB_MAP     = PBANK + 1
PB_LVL     = PBANK + 3
; A Solidisk or Watford board takes the bank a store goes to from a register of its own
; (defs.inc BOARD_*): the game's code was patched for it at boot, this program reads
; PBOARD and does it by hand -- pgbank pages the bank in A (X, Y kept), wrx sets the
; write bank to the socket in X.  Not hot: a load makes a few dozen switches.
; zero page: the engine's LDZP, 17 bytes of the sprite prologue's scratch, which
; nothing needs across a load (engine.s)
src   = LDZP                        ; 2
dst   = LDZP + 2                    ; 2
cnt   = LDZP + 4                    ; 2
tmp   = LDZP + 6
tmp2  = LDZP + 7
ent   = LDZP + 8                    ; 2: the directory entry / placement entry
lp    = LDZP + 10                   ; 2: list pointer
item  = LDZP + 12
fnum  = LDZP + 13                   ; the shared file being walked
tbase = LDZP + 14                   ; 2: the level file's section table
nt    = LDZP + 16

        .segment "CODE"
; ---------------------------------------------------------------- the entry
; (disc.s ld_go, the chain parked and interrupts off.)  X = a level (load_level_b:
; its caller is returned to) or LDOP_TITLE, LDOP_GAME, LDOP_OVER (go_title, go_game,
; go_menu: the image, then the game's hook; A = go_menu's for hook_over)
ld_entry:
        cpx #$80
        bcs ld_image
        jsr lv_load
ld_resume:                          ; every load ends here (interrupts still off: a flag
        lda #0                      ; raised during the load is stale)
        sta ld_open
        lda #3                      ; load_end: resume asked -- the next real vsync arms
        sta LOADREQ                 ; T1, turns its interrupt on and clears this (curR7
        lda #$42                    ; holds LDR7 from the switch); until then a T1 flag is
        sta VIA_IFR                 ; stale.  A vsync flag raised meanwhile is stale too
        cli                         ; (engine.s load_begin)
        rts
ld_image: sta ldarg
        stx ldop
        txa
        and #1                      ; the image (defs.inc LDOP_)
        sta ld_img                  ; (the kernel's: the test harness reads it)
        tax
        jsr image_load
        lda ldop
        cmp #LDOP_TITLE
        beq @title                  ; (start-up's stack, as boot left it)
        ldx #$3F                    ; (init.s: the stack is 64 bytes)
        txs
        cmp #LDOP_GAME
        bne @over
        inc ld_open                 ; (0 -> 1: the level loop's first load goes straight
        jsr hook_image              ;  on; the game's: Cleo's resets its HUD's cache)
        jmp game_in                 ; hook_play
@over:  jsr ld_resume
        lda ldarg
        jmp hook_over
@title: jsr ld_resume
        jmp hook_title
ldop:   .res 1
ldarg:  .res 1

; ---------------------------------------------------------------- the file table
; index -> sector lo, hi, sectors (from files.inc: the disc's own order)
.macro FILE name
        .byte <.ident(.concat("F_", name, "_SEC")), >.ident(.concat("F_", name, "_SEC")), .ident(.concat("F_", name, "_N"))
.endmacro
; bank 7's images are one file a machine (IMG7B, IMG7M): the menus' to a whole
; sector, then the game's
MENU_SECS = (MENU_LEN + 255) / 256
  .if BHW
F_IMG7_SEC = F_IMG7B_SEC
F_IMG7_N   = F_IMG7B_N
  .else
F_IMG7_SEC = F_IMG7M_SEC
F_IMG7_N   = F_IMG7M_N
  .endif
.macro IMG7 name                    ; (the & $FF: build.sh's first pass has no sizes yet)
  .if .xmatch(name, "MENU")
        .byte <F_IMG7_SEC, >F_IMG7_SEC, MENU_SECS
  .else
        .byte <(F_IMG7_SEC + MENU_SECS), >(F_IMG7_SEC + MENU_SECS), (F_IMG7_N - MENU_SECS) & $FF
  .endif
.endmacro
; a level file ends with the Master's LV_PAGE0 table, in sectors of its own (the packer's):
; the Model B, whose gather is arithmetic, stops before them
.macro LFILE name
  .if BHW
        .byte <.ident(.concat("F_", name, "_SEC")), >.ident(.concat("F_", name, "_SEC")), .ident(.concat("F_", name, "_N")) - PAGE0_SECS
  .else
        FILE name
  .endif
.endmacro
PAGE0_SECS = LV_PAGE0_SECS          ; (512 bytes: 256 lo, 256 hi)
ftab:   FILE "SPRX"                 ; 0: the sprites placed per level (imgtab's file 0)
        FILE "SPRC"                 ; 1: the sprites every level draws: banks 4 and 5
        FILE "SPRC"                 ; 2: (unused)
        FILE "TILES0"               ; 3, 4: the tile set's outdoor and shared files
        FILE "TILES1"
        IMG7 "MENU"                 ; 5, 6: this machine's images of bank 7, the
        IMG7 "GAME"                 ; menus' and the game's (one file: build.sh)
        FILE "BAR"                  ; 7
        LFILE "L0"                   ; 8..23: the levels
        LFILE "L1"
        LFILE "L2"
        LFILE "L3"
        LFILE "L4"
        LFILE "L5"
        LFILE "L6"
        LFILE "L7"
        LFILE "L8"
        LFILE "L9"
        LFILE "L10"
        LFILE "L11"
        LFILE "L12"
        LFILE "L13"
        LFILE "L14"
        LFILE "L15"
        FILE "TILES2"               ; 24: and its indoor file
tfi:    .byte 3, 4, 24              ; the tile set's files by number
FI_SPRX = 0
FI_SPRC = 1
FI_MENU = 5
FI_GAME = 6
FI_BAR = 7
FI_L0 = 8

; read file A to dst (main RAM)
readfile:                           ; file A -> dst (page-aligned: its low byte is not read)
        ldx dst+1
readpage:                           ; file A -> page X (main RAM)
        stx ld_dst+1
        sta tmp
        asl
        adc tmp                     ; * 3
        tax
        lda ftab,x
        sta ld_sec
        lda ftab+1,x
        sta ld_sec+1
        lda ftab+2,x
        sta ld_n                    ; (ld_dst's low byte: 0 from disc.s ld_go, and never
        .assert <LDPROG = 0, error, "ld_dst's low byte is 0"
        jmp read_sectors            ;  changed -- every destination is a page)

; copy cnt bytes from src (main RAM) to dst in the bank the placement entry (lp) names
; -- the packer's number, 4 or 5, for the socket that is that bank here
plcopy: ldy #1
        lda (lp),y
        tay
        ldx PBANK-4,y               ; (Y: bcopy reloads it)
  .if .not BHW
        jmp scopy                   ; (a placed image comes from the stage)
; the Master stages the shared files in shadow RAM: a copy out of the stage
; reads with ACCCON X set (X and Y kept, as bcopy leaves them)
scopy:  lda ACCCON
        ora #4
        sta ACCCON
        jsr bcopy
        lda ACCCON
        and #$FB
        sta ACCCON
        rts
  .endif
; copy cnt bytes from src (main RAM) to dst in bank X (a socket); bank 7 back afterwards
bcopy:  stx ROMSEL_CPY
        stx ROMSEL
        jsr wrx                     ; the write bank too (A is free here)
        ldy #0
        ldx cnt+1
        beq @tail
@page:  lda (src),y
        sta (dst),y
        iny
        bne @page
        inc src+1
        inc dst+1
        dex
        bne @page
@tail:  ldx cnt
        beq @done
:       lda (src),y
        sta (dst),y
        iny
        dex
        bne :-
@done:  lda PB_LVL
        jsr pgbank
        rts

pgbank: sta ROMSEL_CPY              ; A = the socket to page (and to write to)
        sta ROMSEL
        pha
        txa
        pha
        tsx
        lda $0102,x                 ; the socket again
        tax
        jsr wrx
        pla
        tax
        pla
        rts
wrx:    lda PBOARD                  ; X = the socket a store should reach
        beq @r
        lsr                         ; 1 (Watford) -> C set, 2 (Solidisk) -> C clear
        bcc @s
        sta WRSEL_WATFORD,x         ; Watford: the address is the bank, the value nothing
@r:     rts
@s:     stx WRSEL_SOLIDISK          ; Solidisk: the bank on port B (the loader set DDRB)
        rts

; ---------------------------------------------------------------- a level
lv_load:
  .if .not BHW
        jsr mainram                 ; (X here is whatever buffer the game drew last)
  .endif
        txa
        clc
        adc #FI_L0
        ldx #<STAGE_LVL
        stx dst
        ldx #>STAGE_LVL
        stx dst+1
        jsr readfile
        ; ---- the tables: the section table's offsets are from the file's start
        lda #SEC_HDR
        jsr section                 ; the header
        lda #32
        sta cnt
        sty cnt+1                   ; Y = 0: section 0's index
        .assert <LV_HDR = 0, error, "dst's low byte is Y's 0"
        sty dst
        lda #>LV_HDR
        sta dst+1
        ldx PB_LVL
        jsr bcopy
        lda #SEC_OBJS
        jsr section                 ; the objects: 6 a piece, nobj of them
        lda #0                      ; (cnt+1 is 0 still: the header's copy set it)
        ldx LV_HDR+HDR_NOBJ
        beq @objdone
:       clc
        adc #6
        bcc :+
        inc cnt+1
:       dex
        bne :--
@objdone:
        sta cnt
        .assert <LV_OBJS = 0, error, "dst's low byte is 0 still"
        lda #>LV_OBJS               ; main RAM (level_init reads them once, before
        sta dst+1                   ; the first render)
        ldx PB_LVL
        jsr bcopy
        lda #SEC_ATTR
        jsr section
        .assert <LV_ATTR0 = 0, error, "dst's low byte is 0 still"
        lda #>LV_ATTR0
        sta dst+1
        jsr copy256
                                    ; (src: the copy left it at section 3, which
                                    ;  follows the 256-byte attr in the file)
        .assert LV_ALTCLS = LV_ATTR0 + $100, error, "copy256 leaves dst at LV_ALTCLS"
        jsr copy256
        ; ---- the shape: maprow's shift, the row stride
        lda LV_HDR+HDR_MAPSHR
        sta mapshr
        stx MAPSTRIDE+1             ; X = 0: copy256 ends in bcopy
        ldx LV_HDR                  ; lw: stride = 1 << lw
        lda #1
:       asl
        rol MAPSTRIDE+1
        dex
        bne :-
        sta MAPSTRIDE
        ; ---- the map, run-length coded, into bank 5: exactly its 1 << (lw + lh) bytes
        ; (the stream is not terminated: what follows it in the file is the next section)
        lda LV_HDR                  ; lw + lh - 8 (at least 2: a map is at least 1K)
        clc
        adc LV_HDR+HDR_LH
        sbc #7                      ; (C = 0: - 8)
        tax
        lda #1
:       asl
        dex
        bne :-
        adc #>MAP5                  ; (C = 0: at most 8K) the page after the map
        sta mapend
        lda #SEC_MAP
        jsr section
        .assert <MAP5 = 0, error, "dst's low byte is 0 still"
        lda #>MAP5
        sta dst+1
        jsr unrle
        ; ---- the tiles (the packer's lists): each of the level's files of the tile
        ; set staged in turn and its tiles copied to their slots in bank 6 -- the full
        ; tiles by the tile list (the files: each one's number and its full tiles; then
        ; each tile's index in its file), the half tiles by the half list (index,
        ; row | the file's place in the list << 1)
        lda #SEC_TILES
        jsr section
        ldy #0
        lda (src),y
        sta nfiles
        asl                         ; the first index: past the files (C = 0: n < 128)
        sec
        adc src
        sta lp
        lda src+1
        adc #0
        sta lp+1
        .assert <TILES = 0, error, "TILES page-aligned"
        lda #<(TILES + (TOFF+1)*64) ; the next full slot: id 1's (id 0 is the solid,
        sta tbase                   ; filled, never stored)
        lda #>(TILES + (TOFF+1)*64)
        sta tbase+1
        sty fnum
@file:  lda #SEC_TILES
        jsr section
        lda fnum
        asl
        tay
        iny
        lda (src),y                 ; the set's file
        tay
        lda tfi,y
        jsr stage
        lda #SEC_TILES
        jsr section
        lda fnum
        asl
        tay
        iny
        iny
        lda (src),y                 ; this file's full tiles
        sta nt
@tile:  lda nt
        beq @halves
        lda tbase
        sta dst
        lda tbase+1
        sta dst+1
        ldy #0
        lda (lp),y
        clc                         ; (the whole tile)
        ldx #64
        jsr tcopy
        lda tbase
        clc
        adc #64
        sta tbase
        bcc :+
        inc tbase+1
:       inc lp
        bne :+
        inc lp+1
:       dec nt
        jmp @tile
@halves:                            ; this file's half tiles, to their slots: HALFOFF
        lda LV_HDR+HDR_HALFOFF               ; slots into the halves' page
        asl
        asl
        asl
        asl
        asl
        sta hdst
        lda LV_HDR+HDR_HALFPAGE
        sta hdst+1
        lda #0
        sta item
@half:  lda item
        cmp LV_HDR+HDR_NHALF
        beq @nextfile
        lda #SEC_HALVES
        jsr section
        lda item
        asl
        tay
        iny
        lda (src),y                 ; the row | the file << 1
        lsr
        cmp fnum
        bne @hnext
        lda (src),y
        lsr                         ; C = the row
        dey
        lda (src),y                 ; the index
        ldx hdst
        stx dst
        ldx hdst+1
        stx dst+1
        ldx #32
        jsr tcopy
@hnext: lda hdst
        clc
        adc #32
        sta hdst
        bcc :+
        inc hdst+1
:       inc item
        jmp @half
@nextfile:
        inc fnum
        lda fnum
        cmp nfiles
        beq :+
        jmp @file
:
        ; ---- the halves' fill pairs, where the halves end (hdst): the fill indexes
        ; them by the slot from the halves' page, so its operands sit 2*HALFOFF below
        lda #SEC_HPAIR
        jsr section
        lda hdst
        sta dst
        lda hdst+1
        sta dst+1
        lda LV_HDR+HDR_NHALF               ; two bytes a half
        asl
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
        jsr bcopy                   ; (bank 7 back after it)
        lda LV_HDR+HDR_HALFOFF
        asl
        eor #$FF
        sec
        adc hdst                    ; hdst - 2*HALFOFF: low in X, high in Y
        tax
        lda hdst+1
        sbc #0
        tay
        ; ---- the tile shape, into banks 5 and 6 (read here, with bank 7 in)
        lda LV_HDR+HDR_HALFPAGE
        sta sv_halfhi
        lda LV_HDR+HDR_SOLIDFILL               ; the solid's fill byte (id 0)
        sta sv_solid
  .ifdef BAKEITEM0                  ; (the baker's: the halves' slot offset and pairs)
        lda LV_HDR+HDR_HALFOFF
        sta sv_halfoff
        stx sv_hpl
        sty sv_hph
  .endif
  .if BHW || .defined(BAKEITEM0)    ; the arithmetic gather's (bank 5): the Master's
        lda LV_HDR+HDR_HALF0               ; gather is its table, LV_PAGE0 (the baker
        sta sv_half0                       ; decodes a tile as the Model B's gather does)
   .if TILEMIRROR
        clc                         ; half0 - HALFOFF - 1: the gather's borrow (C clear
   .else                            ; after its mirror test)
        sec                         ; half0 - HALFOFF (C set: no mirror test)
   .endif
        sbc LV_HDR+HDR_HALFOFF
        sta sv_halfsub
        lda LV_HDR+HDR_HALF1
        sta sv_half1
        lda LV_HDR+HDR_HALF2
        sta sv_half2
   .if TILEMIRROR
        lda LV_HDR+HDR_MIR0
        sta sv_mir0
   .endif
  .endif
        lda PB_TILES
        jsr pgbank                  ; (X, Y kept)
        stx HPAIR0
        sty HPAIR0+1
        inx
        stx HPAIR1
        bne :+
        iny
:       sty HPAIR1+1
        ldx sv_halfhi               ; (X, Y free: HPAIR's done)
        dex
        stx halfhi                  ; (bank 6's: the row loop's @hfill, less 1 -- its sbc
                                    ;  borrows: C clear at every entry to @run)
        lda sv_solid
        sta SOLIDF                  ; the row loop's lda #fill for id 0
  .if BHW
        lda PB_MAP                  ; the gather's shape: bank 5, beside it (gather5)
        jsr pgbank
        lda sv_half0
        sta half0
        lda sv_half1
        sta half1
        lda sv_half2
        sta half2
        lda sv_halfhi
        sta halfhi5
        lda sv_halfsub
        sta halfsub
   .if TILEMIRROR
        lda sv_mir0
        sta mir0
   .endif
  .endif
        lda PB_LVL
        jsr pgbank
  .if BHW && TILEMIRROR
        ; ---- MIRTAB: each mirrored tile's source slot
        lda #SEC_MIR
        jsr section
        lda #<MIRTAB
        sta dst
        lda #>MIRTAB
        sta dst+1
        lda LV_HDR+HDR_NMIR
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_MAP
        jsr bcopy
  .endif
        ; ---- the sprites.  The resident block (SPRC: Cleo's player, the boomerang, the stars,
        ; the trampoline) goes to its fixed places in banks 4 and 5 once, and stays (the
        ; menus keep to bank 7); the rest (SPRX) is staged and the level's subset copied
        ; out by its placement list
        lda sprc_ok
        bne @sprx
        lda #FI_SPRC
        jsr stage
        lda #<STAGE
        sta src
        lda #>STAGE
        sta src+1
        lda #<SPRC_BASE
        sta dst
        lda #>SPRC_BASE
        sta dst+1
        lda #<SPRC_LEN
        sta cnt
        lda #>SPRC_LEN
        sta cnt+1
        ldx PB_SPR
        jsr sccopy                  ; bank 4's part: the mirrored ones, and what fits
        lda #<(STAGE + SPRC_LEN)
        sta src
        lda #>(STAGE + SPRC_LEN)
        sta src+1
        lda #<SPRC5_BASE
        sta dst
        lda #>SPRC5_BASE
        sta dst+1
        lda #<SPRC5_LEN
        sta cnt
        lda #>SPRC5_LEN
        sta cnt+1
        ldx PB_MAP
        jsr sccopy                  ; the rest: bank 5, from its code's end
        inc sprc_ok
@sprx:  lda #FI_SPRX
        sta fnum
  .if .not SPRXKEEP
        jsr stage
  .else
        ; the Master reads SPRX once and keeps it in HAZEL (8K) and ANDY (4K); after,
        ; the stage is refilled from them, no disc read
        ldx sprx_ok
        bne @unkeep
        jsr stage
        jsr keep
        inc sprx_ok
        bne @sfile                  ; (always)
@unkeep:
        jsr unkeep
  .endif
@sfile: jsr placewalk
@plend:
        ; ---- the directory and SPRMASK, as the packer finished them
        lda #SEC_DIR
        jsr section
        lda #<SPR_TABLE             ; bank 7, beside the prologue that reads it
        sta dst
        lda #>SPR_TABLE
        sta dst+1
  .if SPRGEOM
DIRLEN = 2*(BOXID0+BOXN)            ; (the split directory: the addresses alone)
  .else
DIRLEN = (BOXID0+BOXN)*8
  .endif
        lda #<DIRLEN                ; (the directory: an entry a sprite id)
        sta cnt
        lda #>DIRLEN
        sta cnt+1
        ldx PB_LVL
        jsr bcopy
        ; ---- the flat tiles' pairs, into bank 6 with the blitter's fill
        lda #SEC_FLAT
        jsr section
        lda #<FLATTAB
        sta dst
        lda #>FLATTAB
        sta dst+1
        lda #2*(NFLAT+2)
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
  .if BHW
        jmp bcopy                   ; (the Model B's gather is arithmetic: no table)
  .else
        jsr bcopy
        ; ---- the Master: the gather's table, to main RAM, and the screens
        ; (main and shadow) cleared of what the load staged there -- a ring row the
        ; window has not reached yet must not show it
        lda #SEC_PAGE0
        jsr section
        lda #<LV_PAGE0
        sta dst
        lda #>LV_PAGE0
        sta dst+1
        lda #0
        sta cnt
        lda #2
        sta cnt+1
        ldx PB_LVL
        jsr bcopy
        lda ACCCON
        ora #4
        jsr @clr                    ; shadow
        lda ACCCON
        and #$FB
@clr:   sta ACCCON                  ; (and main, falling in: X clear on the way out)
        lda #0
        sta dst
        tay
        ldx #$30
@cp:    stx dst+1
@cb:    sta (dst),y
        iny
        bne @cb
        inx
        bpl @cp                     ; to $7FFF
        rts
  .endif

; ---- helpers
sccopy:                             ; a copy out of the stage, on either machine
  .if BHW
        jmp bcopy
  .else
        jmp scopy
  .endif
  .if .not BHW
; the Master: every load starts with the CPU on main RAM -- the game leaves
; ACCCON X on the buffer it drew last, and the level's file is main RAM's
mainram:
        pha
        lda ACCCON
  .if GAMEHAZEL
        and #$FB                    ; X clear (Y stays: the game's code is in HAZEL)
  .else
        and #$F3                    ; X and Y clear
  .endif
        sta ACCCON
        pla
        rts
; SPRX's residency on the Master: the stage (shadow RAM, $3000) to HAZEL
; ($C000, ACCCON Y) and ANDY ($8000, ROMSEL bit 7) -- keep -- and back -- unkeep.  Only
; under a load: interrupts are off, and the game's code is in bank 7 (ANDY would hide
; its bottom 4K).  (HAZEL itself does not hide the interrupt's path: GAMEHAZEL games
; run with Y set throughout.)
  .endif
  .if SPRXKEEP
SPRX_PAGES = (SPRX_LEN + 255) / 256
        .assert SPRX_PAGES <= $30, error, "SPRX outgrows HAZEL and ANDY (12K)"
keep:   sec
        .byte $24                   ; (bit zp: skips the clc)
unkeep: clc
        php
        lda ACCCON
        ora #$0C                    ; X (the stage) and Y (HAZEL)
        sta ACCCON
        ldx #$20                    ; HAZEL: the stage's first 8K
        lda #>STAGE
        ldy #$C0
        jsr kpart
        lda #$80                    ; ANDY: the next 4K
        sta ROMSEL
        ldx #$10
        lda #>STAGE + $20
        ldy #$80
        jsr kpart
        lda PB_LVL                  ; (bank 7 back, ANDY out)
        jsr pgbank
        plp
        lda ACCCON
        and #$F3
        sta ACCCON
        rts
kpart:  stx cnt                     ; X pages between the stage's page A and page Y:
        tsx                         ; from the stage (keep: the C its caller pushed is
        pha                         ; set) or to it
        lda $0103,x                 ; (the P keep/unkeep pushed, under this call's return)
        lsr
        pla
        bcc :+
        sta src+1
        sty dst+1
        bcs :++
:       sty src+1
        sta dst+1
:       lda #0
        sta src
        sta dst
        tay
@pg:    lda (src),y
        sta (dst),y
        iny
        bne @pg
        inc src+1
        inc dst+1
        dec cnt
        bne @pg
        rts
  .endif
tcopy:                              ; tile A of the staged file, its row C (or all of it:
        stx cnt                     ; C = 0, X = 64), X bytes to dst in bank 6
        ldx #0
        stx cnt+1
        tax
        lda #0
        ror
        lsr
        lsr                         ; the row: 0 or 32
        sta src
        txa
        and #3
        lsr
        ror
        ror                         ; (t & 3) << 6
        ora src
        sta src
        txa
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        ldx PB_TILES
  .if BHW
        jmp bcopy
  .else
        jmp scopy
  .endif
nfiles: .res 1                      ; (lv_load's: the set's file count,
hdst:   .res 2                      ;  the next half's slot,
sv_halfhi:  .res 1                  ;  the tile shape on its way to banks 5 and 6)
sv_solid:   .res 1
sv_halfoff: .res 1                  ; (the baker's)
  .ifdef BAKEITEM0
bk_col:     .res 1                  ; (the baker's: columns to go, lines, X0 across,
bk_lines:   .res 1                  ;  the first tile row, the destination's socket,
bk_x:       .res 2                  ;  the map's width shift, the column's byte and tile,
bk_ty0:     .res 1                  ;  the tile row, the line, the tile, its modes, the
bk_sock:    .res 1                  ;  fill pair and where it is, a half's slot, the
bk_lw:      .res 1                  ;  flats, the backdrop's column and the overlay's)
bk_bx:      .res 1
bk_tx:      .res 1
bk_ty:      .res 1
bk_line:    .res 1
bk_t:       .res 1
bk_mt:      .res 1
bk_mb:      .res 1
bk_step:    .res 1
bk_pa:      .res 1
bk_pb:      .res 1
bk_k:       .res 1
bk_fp:      .res 2
bk_bg:      .res 32
  .endif
sv_hpl:     .res 1
sv_hph:     .res 1
mapend:     .res 1                  ; the page after the level's map (unrle)
  .if BHW || .defined(BAKEITEM0)
sv_half0:   .res 1
sv_half1:   .res 1
sv_half2:   .res 1
sv_halfsub: .res 1
   .if TILEMIRROR
sv_mir0:    .res 1
   .endif
  .endif
placewalk:                          ; the placement list's items from file fnum, staged
        lda #SEC_PLACE
        jsr section
        lda src
        sta lp
        lda src+1
        sta lp+1
@pl:    ldy #0
        lda (lp),y
        cmp #$FF
        beq @pwdone
        sta item
  .ifdef BAKEITEM0
        cmp #BAKEITEM0              ; a baked box: made here, from SPRX's overlays
        bcc :+                      ; (bake, below)
        lda fnum
        cmp #FI_SPRX
        bne @plnext
        jsr bake
        jmp @plnext
:
  .endif
        jsr imgent                  ; ent -> imgtab's entry for the item

        lda (ent),y
        cmp fnum
        bne @mask
        ldy #1                      ; the image: src = STAGE + offset, cnt = length
        jsr srccnt
        ldy #2
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        jsr plcopy                  ; to the placement's bank
@mask:  ldy #5
        lda (ent),y
        cmp fnum
        bne @plnext
        ldy #8
        lda (ent),y
        iny
        ora (ent),y
        beq @plnext                 ; no mask
        ldy #6
        jsr srccnt
        ldy #4
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        jsr plcopy                  ; to the placement's bank
@plnext:
        lda lp
        clc
        adc #6
        sta lp
        bcc @pl
        inc lp+1
        bne @pl                     ; (lp+1 is never 0)
@pwdone:
        rts

  .ifdef BAKEITEM0
; ---------------------------------------------------------------- a baked box
; An item from BAKEITEM0 on (the game's: Cleo's trampolines at rest and its costliest
; stars) is not copied but made here: the level's own tiles where the object stands,
; the game's overlay over them -- (backdrop AND mask) OR pixels -- from SPRX, staged:
; a column's pixels (lines bytes) then its mask.  The placement entry carries the
; object's tile (x, y) where an image carries its mask address; bakekind gives the
; slot's kind and bakegeom the kind's shape: bytes wide, lines (every scanline), the
; backdrop's origin from (8x, 8y) -- game pixels across (16 bit), whole tile rows down
; -- and the overlay's offset in SPRX.  A tile is decoded as the Model B's gather
; does (engine.s gather5): 0 the solid, from FLAT0 the flats, from half0 the halves
; (one char row stored, the other a fill pair or the same row), below it full tiles.
        .assert .not TILEMIRROR, error, "bake: no mirrored tiles (the gather's @gmir)"
bake:   lda #SEC_FLAT               ; the flats' pairs, in the level's file (main RAM)
        jsr section
        lda src
        sta bk_fp
        lda src+1
        sta bk_fp+1
        lda item
        sec
        sbc #BAKEITEM0
        tax
        lda bakekind,x
        asl
        asl
        asl
        tax                         ; the kind's shape: bakegeom + kind * 8
        lda bakegeom,x
        sta bk_col
        lda bakegeom+1,x
        sta bk_lines
        ldy #4                      ; X0 = 8x + dx
        lda (lp),y
        sta bk_x
        lda #0
        sta bk_x+1
        asl bk_x
        rol bk_x+1
        asl bk_x
        rol bk_x+1
        asl bk_x
        rol bk_x+1
        lda bk_x
        clc
        adc bakegeom+2,x
        sta bk_x
        lda bk_x+1
        adc bakegeom+3,x
        sta bk_x+1
        iny                         ; the first tile row: y + dty
        lda (lp),y
        clc
        adc bakegeom+4,x
        sta bk_ty0
        lda bakegeom+5,x            ; the overlay: STAGE + its offset
        clc
        adc #<STAGE
        sta src
        lda bakegeom+6,x
        adc #>STAGE
        sta src+1
        ldy #1                      ; where it goes: the bank (4 or 5) and the address
        lda (lp),y
        tay
        lda PBANK-4,y
        sta bk_sock
        ldy #2
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        lda LV_HDR+HDR_LW           ; (bank 7 is paged here)
        sta bk_lw
@col:   lda bk_x                    ; ---- a column: its byte in the tile, its tile
        lsr
        and #3
        asl
        asl
        asl
        sta bk_bx                   ; ((X >> 1) & 3) * 8
        lda bk_x+1
        sta tmp
        lda bk_x
        lsr tmp
        ror
        lsr tmp
        ror
        lsr tmp
        ror
        sta bk_tx                   ; X >> 3
        lda bk_ty0
        sta bk_ty
        ldx #0                      ; X: the line, in bk_bg
@seg:   jsr bk_tile                 ; a tile row's lines (to bk_lines)
        inc bk_ty
        cpx bk_lines
        bcc @seg
        lda src                     ; ---- the column, made, to its bank: the overlay's
        clc                         ; pixels at src, its mask (cnt) after them
        adc bk_lines
        sta cnt
        lda src+1
        adc #0
        sta cnt+1
        lda bk_sock
        jsr pgbank
  .if .not BHW
        lda ACCCON                  ; (the Master: SPRX is in shadow RAM; the backdrop's
        ora #4                      ; column below it, the bank above)
        sta ACCCON
  .endif
        ldy #0
:       lda bk_bg,y
        and (cnt),y
        ora (src),y
        sta (dst),y
        iny
        cpy bk_lines
        bcc :-
  .if .not BHW
        lda ACCCON
        and #$FB
        sta ACCCON
  .endif
        lda PB_LVL
        jsr pgbank
        lda dst                     ; ---- the next: dst + lines, the overlay + 2 lines, X + 2
        clc
        adc bk_lines
        sta dst
        bcc :+
        inc dst+1
:       lda bk_lines
        asl
        adc src                     ; (C = 0: lines <= 32)
        sta src
        bcc :+
        inc src+1
:       lda bk_x
        clc
        adc #2
        sta bk_x
        bcc :+
        inc bk_x+1
:       dec bk_col
        beq :+
        jmp @col
:       rts

; the tile at (bk_tx, bk_ty), its column bk_bx, into bk_bg from line X: sixteen lines,
; or to bk_lines (X out)
bk_tile:
        lda bk_ty                   ; the map: MAP5 + (ty << lw) + tx, in bank 5
        sta ent
        lda #0
        sta ent+1
        ldy bk_lw
        beq :++
:       asl ent
        rol ent+1
        dey
        bne :-
:       lda ent
        clc
        adc bk_tx
        sta ent
        lda ent+1
        adc #>MAP5
        sta ent+1
        .assert <MAP5 = 0, error, "bk_tile: MAP5's low byte"
        stx bk_line
        lda PB_MAP
        jsr pgbank
        ldy #0
        lda (ent),y
        sta bk_t
        lda PB_TILES                ; the tiles: bank 6
        jsr pgbank
        lda #1                      ; the modes: 1 = the fill pair (bk_pa, bk_pb), 0 = the
        sta bk_mt                   ; stored row at (ent), for the top char row and the
        sta bk_mb                   ; bottom; bk_step, the bottom row's offset from the top's
        lda #0
        sta bk_step
        lda bk_t
        bne :+
        lda sv_solid                ; ---- 0: the solid
        sta bk_pa
        sta bk_pb
        jmp @emit
:       cmp #FLAT0
        bcc :+
        sbc #FLAT0                  ; ---- a flat: its pair (C set), in the level's file
        asl
        adc bk_fp                   ; (C = 0)
        sta cnt
        lda bk_fp+1
        adc #0
        sta cnt+1
        jsr @pair
        jmp @emit
:       cmp sv_half0
        bcs @half
        clc                         ; ---- a full tile: TILES + (id + TOFF) * 64 + byte * 8
        adc #TOFF
        sta ent
        lda #0
        sta ent+1
        ldy #6
:       asl ent
        rol ent+1
        dey
        bne :-
        lda ent
        ora bk_bx
        sta ent
        lda ent+1
        clc
        adc #>TILES
        sta ent+1
        .assert <TILES = 0, error, "bk_tile: TILES's low byte"
        lda #0
        sta bk_mt
        sta bk_mb
        lda #32                     ; the bottom char row, 32 on
        sta bk_step
        jmp @emit
@half:  sec                         ; ---- a half: k = id - half0 + HALFOFF; its row at the
        sbc sv_half0                ; halves' page + k * 32 (+ byte * 8), its pair at the
        clc                         ; pairs' base + 2k
        adc sv_halfoff
        sta bk_k
        lsr
        lsr
        lsr
        clc
        adc sv_halfhi
        sta ent+1
        lda bk_k
        asl
        asl
        asl
        asl
        asl
        ora bk_bx
        sta ent
        lda bk_k
        asl
        sta tmp2                    ; 2k (low); the high bit into the carry
        lda #0
        rol
        sta tmp
        lda sv_hpl
        clc
        adc tmp2
        sta cnt
        lda sv_hph
        adc tmp
        sta cnt+1
        jsr @pair
        lda bk_t                    ; below half1 the top row fills, below half2 the
        cmp sv_half1                ; bottom, from it neither (the row twice)
        bcs :+
        lda #0
        sta bk_mb
        beq @emit                   ; (top: the pair, bottom: the row)
:       cmp sv_half2
        bcs :+
        lda #0
        sta bk_mt
        beq @emit                   ; (top: the row, bottom: the pair)
:       lda #0
        sta bk_mt
        sta bk_mb
        beq @emit                   ; (always)
@pair:  ldy #0                      ; the fill pair at (cnt)
        lda (cnt),y
        sta bk_pa
        iny
        lda (cnt),y
        sta bk_pb
        rts
@emit:  ldx bk_line                 ; ---- the two char rows
        lda bk_mt
        jsr bk_row
        bcs @done
        lda ent                     ; the bottom row's bytes
        clc
        adc bk_step
        sta ent
        bcc :+
        inc ent+1
:       lda bk_mb
        jsr bk_row
@done:  lda PB_LVL
        jmp pgbank                  ; (X kept)
; eight lines of a char row into bk_bg from X: A = 0 the row at (ent), 1 the pair;
; C = 1 when bk_lines is reached
bk_row: ldy #0
        cmp #0
        bne @pair
@r:     lda (ent),y
        sta bk_bg,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #8
        bcc @r
        clc
@out:   rts
@pair:  lda bk_pa
        sta bk_bg,x
        inx
        cpx bk_lines
        bcs @out
        lda bk_pb
        sta bk_bg,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #4
        bcc @pair
        clc
        rts
  .endif

section:                            ; A = a section (SEC_) -> src = its start in the staged file
        asl                         ; (C = 0: A < 128)
        tay
        lda STAGE_LVL,y
        sta src
        lda STAGE_LVL+1,y
        adc #>STAGE_LVL
        sta src+1
        rts
        .assert <STAGE_LVL = 0, error, "section: STAGE_LVL page-aligned"
copy256:                            ; src -> dst (bank 7), 256 bytes
        stx cnt                     ; (X = 0: bcopy's exit, both callers)
        inx
        stx cnt+1
        ldx PB_LVL
        jmp bcopy
stage:                              ; file A -> STAGE
        ldx #<STAGE
        stx dst
        ldx #>STAGE
        stx dst+1
  .if BHW
        jmp readfile
  .else
        pha                         ; the Master: into shadow RAM
        lda ACCCON
        ora #4
        sta ACCCON
        pla
        jsr readfile
        lda ACCCON
        and #$FB
        sta ACCCON
        rts
  .endif
imgent:                             ; item -> ent = imgtab + item*10
        lda #0
        sta ent+1
        lda item
        asl
        rol ent+1
        asl
        rol ent+1                   ; * 4 (C = 0)
        adc item                    ; * 5
        bcc :+
        inc ent+1
:       asl
        rol ent+1                   ; * 10 (C = 0)
        adc #<imgtab
        sta ent
        lda ent+1
        adc #>imgtab
        sta ent+1
        rts
srccnt:                             ; (ent),Y = offset lo, hi, length lo, hi -> src, cnt
        lda (ent),y
        sta src                     ; (<STAGE = 0)
        iny
        lda (ent),y
        clc
        adc #>STAGE
        sta src+1
        .assert <STAGE = 0, error, "srccnt: STAGE's low byte"
        iny
        lda (ent),y
        sta cnt
        iny
        lda (ent),y
        sta cnt+1
        rts
unrle:                              ; src (packed) -> dst in bank 5: c < 128 = c+1
        lda PB_MAP
        jsr pgbank
@c:     lda dst+1
        cmp mapend                  ; the map's end: stop there (the stream runs on into
        bcs @end                    ; the next section)
        ldy #0
        lda (src),y
        jsr @next                   ; (A untouched)
        tax                         ; X = the count, N = the control byte's sign
        bmi @run
        inx                         ; c+1 literals
@lit:   lda (src),y
        jsr @next
        sta (dst),y
        jsr @dnext
        dex
        bne @lit
        beq @c
@run:   sbc #125                    ; (C = 0 from the bcs) c - 126
        tax
        lda (src),y
        jsr @next
@r:     sta (dst),y
        jsr @dnext
        dex
        bne @r
        beq @c
@next:  inc src                     ; (A untouched)
        bne :+
        inc src+1
:       rts
@dnext: inc dst
        bne :+
        inc dst+1
:       rts
@end:   lda PB_LVL
        jmp pgbank

; ---------------------------------------------------------------- bank 7's images
; X = IMG_GAME or IMG_MENU: the image staged and copied to its place below the kernel,
; and its bank numbers and write-bank stores made what the boot loader makes them in
; BANKS (loader.s), from the image's own lists (img7fix.inc, build.sh).  The game's
; variables are zeroed (the menus' image was there: its start is the same every time),
; and the game's image brings the bar's template, straight into place (the menus never
; touch the bar and a level does not either: engine.s menu_sections)
image_load:
  .if .not BHW
        jsr mainram
  .endif
        stx item
        lda imgfile,x
        jsr stage
        lda #0                      ; <STAGE = 0
        sta src
        lda #>STAGE
        sta src+1
        ldx item
        lda imgalo,x
        sta dst
        lda imgahi,x
        sta dst+1
        lda imgnlo,x
        sta cnt
        lda imgnhi,x
        sta cnt+1
        ldx PB_LVL
  .if BHW
        jsr bcopy                   ; (bank 7 paged after, and its write bank)
  .else
        jsr scopy
  .endif
        ldx item
        lda bflo,x                  ; ---- the bank numbers: each byte, 4..7, becomes
        sta lp                      ; that bank's socket
        lda bfhi,x
        sta lp+1
@bf:    ldy #1
        lda (lp),y
        beq @bfd                    ; (a high byte of 0: the list's end)
        sta dst+1
        dey
        lda (lp),y
        sta dst
        lda (dst),y
        tax
        lda PBANK-4,x
        sta (dst),y
        lda lp
        clc
        adc #2
        sta lp
        bcc @bf
        inc lp+1
        bne @bf                     ; (always)
@bfd:   lda PBOARD                  ; ---- the write-bank stores, on a board: each a
        beq @wdone                  ; `sta $FE30` as assembled, a harmless second write
        ldx item                    ; of the bank on a plain machine
        lda wrlo,x
        sta lp
        lda wrhi,x
        sta lp+1
@wr:    ldy #1
        lda (lp),y
        beq @wdone
        sta dst+1
        dey
        lda (lp),y
        sta dst
        ldy #2
        lda (lp),y                  ; the kind: 4..7 a constant bank, $FE the bank in X
        tax
        lda PBOARD
        cmp #BOARD_SOLIDISK
        beq @wsol
        cpx #$FE
        beq @wdyn
        lda PBANK-4,x               ; Watford, a constant bank: sta $FF30 + its socket
        ora #<WRSEL_WATFORD
        ldy #1
        bne @whi                    ; (always)
@wdyn:  lda #$9D                    ; Watford, the bank in X: sta $FF30,x
        ldy #0
        sta (dst),y
        lda #<WRSEL_WATFORD
        iny
@whi:   sta (dst),y
        lda #>WRSEL_WATFORD
        bne @wst                    ; (always)
@wsol:  lda #<WRSEL_SOLIDISK        ; Solidisk: sta $FE60, the bank being in A
        ldy #1
        sta (dst),y
        lda #>WRSEL_SOLIDISK
@wst:   iny
        sta (dst),y
        lda lp
        clc
        adc #3
        sta lp
        bcc @wr
        inc lp+1
        bne @wr                     ; (always)
@wdone: lda item                    ; ---- the game's: its variables, the bar's template
        .assert IMG_GAME = 0, error, "image_load: the game's image is 0"
        bne @done
        tay                         ; (A = 0)
        sta dst
        lda #>GAME_BSS
        sta dst+1
        ldx #GAME_BSS_PAGES
        tya
@z:     sta (dst),y                 ; (bank 7 paged, and its write bank: bcopy's pgbank)
        iny
        bne @z
        inc dst+1
        dex
        bne @z
        sta dst                     ; (A = 0; <BARADDR = 0)
        lda #>BARADDR
        sta dst+1
        lda #FI_BAR
        jmp readfile
@done:  rts
        .assert <BARADDR = 0 && <STAGE = 0 && <GAME_BSS = 0, error, "image_load: page-aligned"
imgfile: .byte FI_GAME, FI_MENU
imgalo: .byte <GAME_ADDR, <MENU_ADDR
imgahi: .byte >GAME_ADDR, >MENU_ADDR
imgnlo: .byte <GAME_LEN, <MENU_LEN
imgnhi: .byte >GAME_LEN, >MENU_LEN
bflo:   .byte <bf_game, <bf_menu
bfhi:   .byte >bf_game, >bf_menu
wrlo:   .byte <wr_game, <wr_menu
wrhi:   .byte >wr_game, >wr_menu
        .include "img7fix.inc"      ; bf_game, bf_menu, wr_game, wr_menu (build.sh)
        .assert IMG_MENU = 1, error, "image_load's tables: the game's, then the menus'"

; ---------------------------------------------------------------- the packer's tables
  .ifdef BAKEITEM0
bakekind: .incbin "bakekind.bin"   ; by baked slot: its kind (the game's)
bakegeom: .incbin "bakegeom.bin"   ; by kind: bytes, lines, dx (16 bit), dty, overlay offset (16 bit), 0
  .endif
imgtab: .incbin "imgtab.bin"  ; per item: file, offset, length, mask file, offset, length
