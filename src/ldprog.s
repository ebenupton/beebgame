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
        .ifndef BHW                ; (cpu.inc's flag: the Model B's hardware unless the
BHW = 1                            ;  build says -D BHW=0, the Master's)
        .endif
        .ifndef GAMEHAZEL          ; (cpu.inc's: the game's code in HAZEL -- then SPRX is
GAMEHAZEL = 0                      ;  staged from the disc every time, as the Model B's)
        .endif
SPRXKEEP = (BHW = 0) && (GAMEHAZEL = 0)   ; the Master keeps SPRX in HAZEL and ANDY
        .include "hw.inc"           ; the chips: ROMSEL, ACCCON (the Master: X puts the
                                    ;  CPU's $3000-$7FFF in shadow RAM, where STAGE is),
                                    ;  VIA_IFR (ld_resume)
        .include "defs_ld.inc"      ; the addresses the game exports (build.sh)
        .include "files.inc"        ; the disc's sector table (mkdfs.py table)
        .include "levelfmt.inc"     ; the level file's sections and header (tools/levelfile.py)
        .import __LD_START__: absolute
        .assert LDPROG = __LD_START__, error, "LDPROG (defs.inc) is where ldprog.cfg links this program"
; The banks are whichever sockets the boot loader found RAM in: it left their numbers
; in PBANK (low BSS, one byte per bank 4..7).  This program comes off the disc at
; every load, so the loader cannot patch it as it does the banks' code: every switch
; here reads the physical bank from PBANK, and the placement lists' bank bytes
; (4 or 5, the packer's) go through it too.
PB_SPR     = PBANK
PB_TILES   = PBANK + 2
PB_MAP     = PBANK + 1
PB_LVL     = PBANK + 3
; A Solidisk or Watford board takes the bank a store goes to from a register of its own
; (defs.inc BOARD_*): the game's code was patched for it at boot, this program reads
; pboard and does it by hand -- pgbank pages the bank in A (X, Y kept), wrx sets the
; write bank to the socket in X.  Not hot: a load makes a few dozen switches.
; zero page: the engine's LDZP, 17 bytes of the sprite prologue's scratch, which
; nothing needs across a load (engine.s)
src   = LDZP                       ; 2
dst   = LDZP + 2                   ; 2
cnt   = LDZP + 4                   ; 2
tmp   = LDZP + 6
tmp2  = LDZP + 7
ent   = LDZP + 8                   ; 2: the directory entry / placement entry
lp    = LDZP + 10                  ; 2: list pointer
item  = LDZP + 12
fnum  = LDZP + 13                  ; the shared file being walked
tbase = LDZP + 14                  ; 2: the level file's section table
nt    = LDZP + 16

        .segment "CODE"
; ---------------------------------------------------------------- the entry
; (disc.s ld_go, the chain parked and interrupts off.)  X = a level (load_level_b:
; its caller is returned to) or LDOP_TITLE, LDOP_GAME, LDOP_OVER (go_title, go_game,
; go_menu: the image, then the game's hook; A = go_menu's for hook_over)
ld_entry:
        cpx #LDOP_IMAGE
        bcs ld_image
        jsr lv_load
ld_resume:                         ; every load ends here (interrupts still off: a flag
        lda #0                     ; raised during the load is stale)
        sta ld_open
        lda #LDR_RESUME            ; load_end: resume asked -- the next real vsync arms
        sta load_req               ; T1, turns its interrupt on and clears this (cur_r7
        lda #VIA_IT1|VIA_ICA1      ; holds LDR7 from the switch); until then a T1 flag is
        sta VIA_IFR                ; stale.  A vsync flag raised meanwhile is stale too
        cli                        ; (engine.s load_begin)
        rts
ld_image: pha                      ; go_menu's A, then the op: on the stack across
        txa                        ;  the image's load
        pha
        and #LDOP_IMGMASK          ; the image (defs.inc LDOP_)
        sta ld_img                 ; (the kernel's: the test harness reads it)
        tax
        jsr image_load
        .assert (LDOP_GAME & LDOP_IMGMASK) = IMG_GAME && (LDOP_TITLE & LDOP_IMGMASK) = IMG_MENU && (LDOP_OVER & LDOP_IMGMASK) = IMG_MENU && IMG_MENU = 1, error, "ld_image: bit 0 of the op is the menus' image"
        .assert (LDOP_TITLE >> 1) < (LDOP_OVER >> 1), error, "ld_image: go_menu's op above go_title's"
        pla                        ; the op: C set for the menus' image
        lsr
        tay
        pla                        ; (A: go_menu's, for hook_over)
        ldx #STACKTOP              ; (init.s: the stack is 64 bytes; start-up's is this
        txs                        ;  already -- init.s jumps to go_title at STACKTOP)
        bcs @menu
        inc ld_open                ; (0 -> 1: the level loop's first load goes straight
        jsr hook_image             ;  on; the game's: Cleo's resets its HUD's cache)
        jmp game_in                ; hook_play
@menu:  cpy #(LDOP_OVER >> 1)      ; C: go_menu's, clear for go_title's
        tay                        ; (ld_resume keeps Y and C)
        jsr ld_resume
        tya
        bcc @title
        jmp hook_over
@title: jmp hook_title

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
.macro IMG7 name                   ; (the & $FF: build.sh's first pass has no sizes yet)
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
PAGE0_SECS = LV_PAGE0_SECS         ; (512 bytes: 256 lo, 256 hi)
ftab:   FILE "SPRX"                 ; 0: the sprites placed per level (img_tab's file 0)
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
tfi:    .byte 3, 4, 24             ; the tile set's files by number
FI_SPRX = 0
FI_SPRC = 1
FI_MENU = 5
FI_GAME = 6
FI_BAR = 7
FI_L0 = 8

; read file A to dst (main RAM)
read_file:                         ; file A -> dst (page-aligned: its low byte is not read)
        ldx dst+1
read_page:                         ; file A -> page X (main RAM)
        stx ld_dst+1
        sta tmp
        asl
        adc tmp                    ; * 3
        tax
        ldy #<-3                   ; the entry's 3 bytes to ld_sec, ld_sec+1, ld_n
@f:     lda ftab,x
        sta ld_sec+3-$100,y
        inx
        iny
        bne @f
        .assert ld_n = ld_sec + 2, error, "ld_sec and ld_n are 3 bytes in a row"
        .assert <LDPROG = 0, error, "ld_dst's low byte is 0"
        jmp read_sectors           ; (ld_dst's low byte: 0 from disc.s ld_go, and never
                                    ;  changed -- every destination is a page)

; copy cnt bytes from src (main RAM) to dst in the bank the placement entry (lp) names
; -- the packer's number, 4 or 5, for the socket that is that bank here
plcopy: ldy #PL_BANK
        lda (lp),y
        tay
        ldx PBANK-4,y              ; (Y: bcopy reloads it)
  .if .not BHW
                                    ; (a placed image comes from the stage: on into scopy)
; the Master stages the shared files in shadow RAM: a copy out of the stage
; reads with ACCCON X set (X and Y kept, as bcopy leaves them)
        .pc02                      ; (this program is assembled as the 6502's: the Master's tsb, trb)
scopy:  lda #ACC_X
        tsb ACCCON
        jsr bcopy
        lda #ACC_X
        trb ACCCON
        rts
        .p02
  .endif
; copy cnt bytes from src (main RAM) to dst in bank X (a socket); bank 7 back afterwards
bcopy:  txa                        ; the socket, to read and write (X, Y kept)
        jsr pgbank
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
@done:  lda PB_LVL                 ; bank 7 back (falling into pgbank)
pgbank: sta ROMSEL_CPY             ; A = the socket to page (and to write to)
        sta ROMSEL
        pha
        stx tmp2                   ; (X kept: tmp2 is pgbank's alone)
        tax
        lda pboard                 ; the write bank: X = the socket a store should reach
        beq @r
        lsr                        ; 1 (Watford) -> C set, 2 (Solidisk) -> C clear
        bcc @s
        sta WRSEL_WATFORD,x        ; Watford: the address is the bank, the value nothing
        bcs @r                     ; (always: C set)
@s:     stx WRSEL_SOLIDISK         ; Solidisk: the bank on port B (the loader set DDRB)
@r:     ldx tmp2
        pla
        rts

; section A of the level's file, whole (to the next section's start: levelfile.py
; lays them end to end), to page X of bank 7.  dst's low byte is 0 throughout: lv_load
; sets it to STAGE_LVL's and bcopy moves only the high bytes
lvsec:  stx dst+1
        jsr section                ; (Y = 2 * the section)
        lda STAGE_LVL+2,y
        sec
        sbc STAGE_LVL,y
        sta cnt
        lda STAGE_LVL+3,y
        sbc STAGE_LVL+1,y
        sta cnt+1
        ldx PB_LVL
        jmp bcopy                  ; (X = 0 after it)

; ---------------------------------------------------------------- a level
lv_load:
  .if .not BHW
        jsr main_ram               ; (X here is whatever buffer the game drew last)
  .endif
        txa
        clc
        adc #FI_L0
        ldx #<STAGE_LVL
        stx dst
        ldx #>STAGE_LVL
        stx dst+1
        jsr read_file
        ; ---- the tables: the section table's offsets are from the file's start
        .assert <STAGE_LVL = 0 && <LV_HDR = 0 && <LV_OBJS = 0 && <LV_ATTR0 = 0, error, "lvsec: dst's low byte is 0"
        lda #SEC_HDR               ; the header, and the game's tail after it (under
        ldx #>LV_HDR               ;  a page: levelfile.py)
        jsr lvsec
        lda #SEC_OBJS              ; the objects, OBJ_BYTES a piece, to main RAM (level_init
        ldx #>LV_OBJS              ;  reads them once, before the first render)
        jsr lvsec
:                                  ; (two anonymous labels, unreferenced: the
:                                  ;  file's count of them kept)
        lda #SEC_ATTR
        ldx #>LV_ATTR0
        jsr lvsec                  ; (src: the copy left it at section 3, which
                                    ;  follows the 256-byte attr in the file; X = 0)
        .assert LV_ALTCLS = LV_ATTR0 + $100, error, "lvsec's copy leaves dst at LV_ALTCLS"
        jsr copy256
        ; ---- the shape: map_row's shift, the row stride
        lda LV_HDR+HDR_MAP_SHR
        sta map_shr
        stx map_stride+1           ; X = 0: copy256 ends in bcopy
        ldx LV_HDR                 ; lw: stride = 1 << lw
        lda #1
:       asl
        rol map_stride+1
        dex
        bne :-
        sta map_stride
        ; ---- the map, run-length coded, into bank 5: exactly its 1 << (lw + lh) bytes
        ; (the stream is not terminated: what follows it in the file is the next section)
        lda LV_HDR                 ; lw + lh - 8, the map's pages' shift (at least 2: a
                                    ;  map is at least 1K; C = 0: the stride's last rol
        adc LV_HDR+HDR_LH          ;  shifted out a 0)
        sbc #8-1                   ; (C = 0: - 8)
        stx fnum                   ; (X = 0 from the stride's loop: the tiles' first file)
        tax
        lda #1
:       asl
        dex
        bne :-
        adc #>MAP5                 ; (C = 0: at most 8K) the page after the map
        sta map_end
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
        .assert <TILES = 0, error, "TILES page-aligned"
        lda #<(TILES + (TOFF+1)*TILEBYTES)   ; the next full slot: id 1's (id 0 is the solid,
        sta tbase                  ; filled, never stored)
        lda #>(TILES + (TOFF+1)*TILEBYTES)
        sta tbase+1
@file:  lda #SEC_TILES
        jsr section
        lda fnum
        bne @fn                    ; (the first file: the list's head, once)
        tay
        lda (src),y
        sta nfiles
        asl                        ; the first index: past the files (C = 0: n < 128)
        sec
        adc src
        sta lp
        lda src+1
        adc #0
        sta lp+1
        tya                        ; (fnum's 0)
@fn:
        asl
        tay
        iny
        lda (src),y                ; the set's file
        tax
        iny
        lda (src),y                ; this file's full tiles (before the stage, which
        sta nt                     ;  keeps zero page but for dst and tmp)
        lda tfi,x
        jsr stage
@tile:  lda nt
        beq @halves
        lda tbase
        sta dst
        lda tbase+1
        sta dst+1
        ldy #0
        lda (lp),y
        clc                        ; (the whole tile)
        ldx #TILEBYTES
        jsr tcopy
        lda tbase
        clc
        adc #TILEBYTES
        sta tbase
        bcc :+
        inc tbase+1
:       inc lp
        bne :+
        inc lp+1
:       dec nt
        jmp @tile
@halves:                           ; this file's half tiles, to their slots: HALFOFF
        lda LV_HDR+HDR_HALFOFF     ; slots of HALFBYTES (32) into the halves' page
        asl
        asl
        asl
        asl
        asl
        sta dst                    ; (the next half's slot is dst itself: section and
        lda LV_HDR+HDR_HALFPAGE    ;  tcopy leave it alone, a half's copy is under a page)
        sta dst+1
        lda #0
        sta item
@half:  lda #SEC_HALVES
        jsr section                ; (on the way out too: harmless, src is remade after)
        lda item
        cmp LV_HDR+HDR_NHALF
        beq @nextfile
        asl
        tay
        iny
        lda (src),y                ; the row | the file << 1
        lsr
        eor fnum                   ; (eor, not cmp: C keeps the row from the lsr)
        bne @hnext
        dey
        lda (src),y                ; the index
        ldx #HALFBYTES
        jsr tcopy
@hnext: lda dst
        clc
        adc #HALFBYTES
        sta dst
        bcc :+
        inc dst+1
:       inc item
        bne @half                  ; (always: item <= NHALF <= 255 after the inc)
@nextfile:
        inc fnum
        lda fnum
        cmp nfiles
        beq :+
        jmp @file
:
        ; ---- the halves' fill palette (8 first bytes, then 8 second), where the
        ; halves end (dst, kept in hdst): @hfill's two loads index it by a half's colour
        lda #SEC_HPAIR
        jsr section                ; src = the palette, then each half's low bits
  .ifdef BAKEITEM0
        lda src                    ; (the baker's: it reads both from the staged file)
        sta sv_hplo
        lda src+1
        sta sv_hphi
  .endif
        lda dst                    ; (dst is the halves' end already: the last file's walk)
        sta hdst
        lda dst+1
        sta hdst+1
        lda #HPAIR_LEN
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
        jsr bcopy                  ; (bank 7 back after it; src unmoved: under a page)
  .if BHW
        ; ---- each half's low bits (its fill row and colour), by k, into bank 5's HLOW
        ; for the gather: from HALFOFF on (k counts from the halves' page)
        lda src
        clc
        adc #HPAIR_LEN
        sta src
        bcc :+
        inc src+1
:       lda #<HLOW
        clc
        adc LV_HDR+HDR_HALFOFF
        sta dst
        lda #>HLOW
        adc #0
        sta dst+1
        lda LV_HDR+HDR_NHALF
        sta cnt                    ; (cnt+1 is 0 still)
        ldx PB_MAP
        jsr bcopy
  .endif
        ; ---- the tile shape, into banks 5 and 6 (read here, with bank 7 in)
        lda LV_HDR+HDR_HALFPAGE
        sta sv_halfhi
        ldx LV_HDR+HDR_SOLIDFILL   ; the solid's fill byte (id 0): X to bank 6
        stx sv_solid
  .ifdef BAKEITEM0                 ; (the baker's: the halves' slot offset and pairs)
        lda LV_HDR+HDR_HALFOFF
        sta sv_halfoff
  .endif
  .if BHW || .defined(BAKEITEM0)   ; the arithmetic gather's (bank 5): the Master's
        lda LV_HDR+HDR_HALF0       ; gather is its table, LV_PAGE0 (the baker
        sta sv_half0               ; decodes a tile as the Model B's gather does)
        sec                        ; half0 - HALFOFF (gather5 subtracts it with C set)
        sbc LV_HDR+HDR_HALFOFF
        sta sv_halfsub
        lda LV_HDR+HDR_HALF1
        sta sv_half1
        lda LV_HDR+HDR_HALF2
        sta sv_half2
  .endif
        lda PB_TILES
        jsr pgbank                 ; (X, Y kept)
        stx SOLIDF                 ; the row loop's lda #fill for id 0
        lda hdst                   ; the palette (where the halves end): its first
        sta HPAIR0                 ; bytes, then its second, 8 on (hdst's low byte is
        ora #HPAIR_LEN/2           ; a multiple of HALFBYTES: no carry)
        sta HPAIR1
        lda hdst+1
        sta HPAIR0+1
        sta HPAIR1+1
  .if BHW
        lda PB_MAP                 ; the gather's shape: bank 5, beside it (gather5)
        jsr pgbank
        lda sv_half0
        sta half0
        lda sv_halfhi
        and #<~GH_TILE             ; (a half's mark: its page less $80, gather5)
        sta halfhi5
        lda sv_halfsub
        sta half_sub
  .endif
        lda PB_LVL
        jsr pgbank
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
        jsr sccopy                 ; bank 4's part: the mirrored ones, and what fits
  .if SPRC5_LEN                    ; (the packer's: none when bank 4 holds all of SPRC)
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
        jsr sccopy                 ; the rest: bank 5, from its code's end
  .endif
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
        inc sprx_ok
        sec                        ; keep: C set
        .byte OP_BIT_ZP            ; (bit zp: skips the clc)
@unkeep:
        clc                        ; unkeep: C clear
        jsr unkeep
  .endif
@sfile: jsr place_walk
@plend:
        ; ---- the directory's level part, as the packer finished it
        lda #SEC_DIR
        jsr section
        lda #<DIR_TABLE            ; bank 7, beside the prologue that reads it
        sta dst
        lda #>DIR_TABLE
        sta dst+1
DIRLEN = 2*(BOXID0+BOXN)           ; (the split directory: the addresses alone)
        lda #<DIRLEN               ; (the directory: an entry a sprite id)
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
        lda #FLATTAB_LEN
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
  .if BHW
        jmp bcopy                  ; (the Model B's gather is arithmetic: no table)
  .else
        jsr bcopy
        ; ---- the Master: the gather's table, to main RAM, and the screens
        ; (main and shadow) cleared of what the load staged there -- a ring row the
        ; window has not reached yet must not show it
        lda #SEC_PAGE0
        jsr section
        stx dst                    ; (X = 0: bcopy's exit; <LV_PAGE0 = 0)
        .assert <LV_PAGE0 = 0, error, "LV_PAGE0 page-aligned"
        lda #>LV_PAGE0
        sta dst+1
        stx cnt
        lda #LV_PAGE0_SECS
        sta cnt+1
        ldx PB_LVL
        jsr bcopy
        .setcpu "65C02"
        lda #ACC_X
        tsb ACCCON
        jsr @clr                   ; shadow
        lda #ACC_X
        trb ACCCON                 ; (and main, falling in: X clear on the way out)
        .setcpu "6502"
@clr:   lda #0
        sta dst
        tay
        ldx #>STAGE                ; the screen, from the stage's page ($3000) to $7FFF
@cp:    stx dst+1
@cb:    sta (dst),y
        iny
        bne @cb
        inx
        bpl @cp                    ; to $7FFF
        rts
  .endif

; ---- helpers
  .if BHW
sccopy = bcopy                     ; a copy out of the stage, on either machine
  .else
sccopy = scopy
  .endif
  .if .not BHW
; the Master: every load starts with the CPU on main RAM -- the game leaves
; ACCCON X on the buffer it drew last, and the level's file is main RAM's
  .if GAMEHAZEL
main_ram:                          ; (A and N, Z not kept: neither caller needs them)
        lda ACCCON
        and #<~ACC_X               ; X clear (Y stays: the game's code is in HAZEL)
        sta ACCCON
        rts
  .endif                           ; (else main_ram is unkeep's tail, below: X and Y clear)
; SPRX's residency on the Master: the stage (shadow RAM, $3000) to HAZEL
; ($C000, ACCCON Y) and ANDY ($8000, ROMSEL bit 7), or back: unkeep, by C.  Only
; under a load: interrupts are off, and the game's code is in bank 7 (ANDY would hide
; its bottom 4K).  (HAZEL itself does not hide the interrupt's path: GAMEHAZEL games
; run with Y set throughout.)
  .endif
  .if SPRXKEEP
SPRX_PAGES = (SPRX_LEN + 255) / 256
        .assert SPRX_PAGES <= HAZEL_PAGES + ANDY_PAGES, error, "SPRX outgrows HAZEL and ANDY (12K)"
unkeep: php                        ; C = 1: the stage to HAZEL and ANDY (keep); 0: back
        .setcpu "65C02"
        lda #ACC_X|ACC_Y           ; X (the stage) and Y (HAZEL)
        tsb ACCCON
        .setcpu "6502"
        ldx #HAZEL_PAGES           ; HAZEL: the stage's first 8K
        lda #>STAGE
        ldy #>HAZEL
        jsr kpart
        lda #ROMSEL_ANDY           ; ANDY: the next 4K
        sta ROMSEL
        ldx #ANDY_PAGES
        lda #>STAGE + HAZEL_PAGES
        ldy #>ANDY
        jsr kpart
        lda PB_LVL                 ; (bank 7 back, ANDY out)
        jsr pgbank
        plp
main_ram:                          ; (every load's start too: SPRXKEEP is GAMEHAZEL = 0)
        lda ACCCON
        and #<~(ACC_X|ACC_Y)
        sta ACCCON
        rts
kpart:  stx cnt+1                  ; X pages between the stage's page A and page Y:
        tsx                        ; from the stage (keep: the C in the P unkeep
        pha                        ; pushed is set) or to it
        lda $0103,x                ; (that P, under this call's return)
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
        sta cnt                    ; (whole pages: no tail)
        ldx #ROMSEL_ANDY           ; bcopy's page loop, with ANDY in (HAZEL's part
        jmp bcopy                  ;  touches no $8000-$BFFF); bank 7 back after
  .endif
tcopy:                             ; tile A of the staged file, its row C (or all of it:
        stx cnt                    ; C = 0, X = TILEBYTES), X bytes to dst in bank 6
        ldx #0
        stx cnt+1
        tax
        ror
        ror
        ror                        ; (C:A rotated: t1 t0 row in bits 7-5)
        and #<-HALFBYTES           ; (t & 3) << 6 | the row's 0 or HALFBYTES
        sta src
        txa
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        ldx PB_TILES
        jmp sccopy                 ; (out of the stage: bcopy, or the Master's scopy)
nfiles: .res 1                     ; (lv_load's: the set's file count,
hdst:   .res 2                     ;  the next half's slot,
sv_halfhi:  .res 1                 ;  the tile shape on its way to banks 5 and 6)
sv_solid:   .res 1
sv_halfoff: .res 1                 ; (the baker's)
  .ifdef BAKEITEM0
bk_col:     .res 1                 ; (the baker's: columns to go, lines, X0 across,
bk_lines:   .res 1                 ;  the first tile row, the destination's socket,
bk_x:       .res 2                 ;  the map's width shift, the column's byte and tile,
bk_ty0:     .res 1                 ;  the tile row, the line, the tile, its modes, the
bk_skip0:   .res 1                 ;  (the kind's: start the first tile row at its
bk_skip:    .res 1                 ;   bottom char row; the column's copy)
bk_sock:    .res 1                 ;  fill pair and where it is, a half's slot, the
bk_lw:      .res 1                 ;  flats, the backdrop's column and the overlay's)
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
bk_fp:      .res 2
BK_LINES_MAX = 32                  ; a baked column's lines at most (assets.py asserts it)
BK_BG:      .res BK_LINES_MAX
  .endif
sv_hplo:     .res 1
sv_hphi:     .res 1
map_end:     .res 1                ; the page after the level's map (unrle)
  .if BHW || .defined(BAKEITEM0)
sv_half0:   .res 1
sv_half1:   .res 1
sv_half2:   .res 1
sv_halfsub: .res 1
  .endif
place_walk:                        ; the placement list's items from file fnum, staged
        lda #SEC_PLACE
        jsr section
        lda src
        sta lp
        lda src+1
        sta lp+1
@pl:    ldy #PL_ITEM
        lda (lp),y
        cmp #PL_END
        beq @pwdone
        sta item
  .ifdef BAKEITEM0
        cmp #BAKEITEM0             ; a baked box: made here, from SPRX's overlays
        bcc :+                     ; (bake, below)
        lda fnum                   ; (FI_SPRX = 0)
        bne @plnext
        .assert FI_SPRX = 0, error, "place_walk: FI_SPRX"
        jsr bake
        jmp @plnext
:
  .endif
        jsr img_ent                ; ent -> img_tab's entry for the item

        lda (ent),y
        cmp fnum
        bne @plnext                ; (in another file)
        ldy #1                     ; the image: src = STAGE + offset, cnt = length
        jsr src_cnt
        ldy #PL_ADDR
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        jsr plcopy                 ; to the placement's bank
@plnext:
        lda lp
        clc
        adc #PLACE_LEN
        sta lp
        bcc @pl
        inc lp+1
        bne @pl                    ; (lp+1 is never 0)
@pwdone:
        rts

  .ifdef BAKEITEM0
; ---------------------------------------------------------------- a baked box
; An item from BAKEITEM0 on (the game's: Cleo's trampolines at rest and its costliest
; stars) is not copied but made here: the level's own tiles where the object stands,
; the game's overlay over them -- (backdrop AND mask) OR pixels -- from SPRX, staged:
; a column's pixels (lines bytes) then its mask.  The placement entry carries the
; object's tile (x, y) where an image carries 0; bake_kind gives the
; slot's kind and bake_geom the kind's shape: bytes wide, lines (every scanline), the
; backdrop's origin from (8x, 8y) -- game pixels across (16 bit), whole tile rows down
; -- the overlay's offset in SPRX, and whether the first tile row starts at its bottom
; char row (4 game pixels down: Cleo's health powerup, whose art does).  A tile is decoded as the Model B's gather
; does (engine.s gather5): 0 the solid, from FLAT0 the flats, from half0 the halves
; (one char row stored, the other a fill pair or the same row), below it full tiles.
bake:   lda #SEC_FLAT              ; the flats' pairs, in the level's file (main RAM)
        jsr section
        lda src
        sta bk_fp
        lda src+1
        sta bk_fp+1
        ldx item                   ; the slot: item - BAKEITEM0
        lda bake_kind-BAKEITEM0,x
        asl
        asl
        asl
        .assert BG_LEN = 8, error, "bake: three shifts index bake_geom by kind"
        tax                        ; the kind's shape: bake_geom + kind * BG_LEN
        lda bake_geom+BG_WC,x
        sta bk_col
        lda bake_geom+BG_LINES,x
        sta bk_lines
        ldy #PL_EXTRA              ; X0 = 8x + dx: 8x's high byte x >> 5,
        lda (lp),y                 ; its low byte x << 3
        lsr
        lsr
        lsr
        lsr
        lsr
        pha
        lda (lp),y
        asl
        asl
        asl
        clc
        adc bake_geom+BG_DX,x
        sta bk_x
        pla                        ; (C kept: the low byte's carry)
        adc bake_geom+BG_DX+1,x
        sta bk_x+1
        iny                        ; the first tile row: y + dty
        lda (lp),y
        clc
        adc bake_geom+BG_DTY,x
        sta bk_ty0
        lda bake_geom+BG_SKIP,x    ; the first tile row: from its bottom char row?
        sta bk_skip0
        lda bake_geom+BG_OV,x      ; the overlay: STAGE + its offset
        sta src                    ; (<STAGE = 0)
        clc
        .assert <STAGE = 0, error, "bake: STAGE's low byte"
        lda bake_geom+BG_OV+1,x
        adc #>STAGE
        sta src+1
        ldy #PL_ADDR+1             ; where it goes: the address and the bank (4 or 5)
        lda (lp),y
        sta dst+1
        dey
        lda (lp),y
        sta dst
        dey                        ; PL_BANK
        lda (lp),y
        tay
        lda PBANK-4,y
        sta bk_sock
        lda LV_HDR+HDR_LW          ; (bank 7 is paged here)
        sta bk_lw
@col:   lda bk_x                   ; ---- a column: its byte in the tile, its tile
        tax
        asl
        asl
        and #(TILECHARS-1)*CHARBYTES
        sta bk_bx                  ; ((X >> 1) & 3) * 8, as (X << 2) & $18
        lda bk_x+1
        sta tmp
        txa
        ldy #TILEPX_SHIFT
@tx:    lsr tmp
        ror
        dey
        bne @tx
        sta bk_tx                  ; X >> 3: the tile
        lda bk_ty0
        sta bk_ty
        lda bk_skip0
        sta bk_skip
        ldx #0                     ; X: the line, in BK_BG
@seg:   jsr bk_tile                ; a tile row's lines (to bk_lines)
        inc bk_ty
        cpx bk_lines
        bcc @seg
        txa                        ; ---- the column, made, to its bank: the overlay's
        clc                        ; pixels at src, its mask (cnt) after them (X = lines)
        adc src
        sta cnt
        lda src+1
        adc #0
        sta cnt+1
        lda bk_sock
        jsr pgbank
  .if .not BHW
        .setcpu "65C02"
        lda #ACC_X                 ; (the Master: SPRX is in shadow RAM; the backdrop's
        tsb ACCCON                 ; column below it, the bank above)
        .setcpu "6502"
  .endif
        ldy #0
:       lda BK_BG,y
        and (cnt),y
        ora (src),y
        sta (dst),y
        iny
        dex                        ; (X = lines, from @seg: pgbank keeps it)
        bne :-
  .if .not BHW
        lda ACCCON
        and #<~ACC_X
        sta ACCCON
  .endif
        tya                        ; ---- the next: dst + lines (Y: the copy ends on it),
        clc                        ; the overlay + 2 lines, X + 2
        adc dst
        sta dst
        bcc :+
        inc dst+1
:       tya
        asl
        adc src                    ; (C = 0: lines <= 32)
        sta src
        bcc :+
        inc src+1
:       inc bk_x                   ; X + 2 (X even: 8x + an even dx)
        inc bk_x
        bne :+
        inc bk_x+1
:       dec bk_col
        beq :+
        jmp @col
:       lda PB_LVL                 ; bank 7 back, once: until here nothing reads it (bk_tile
        jmp pgbank                 ; pages its own banks and leaves bank 7 paged)

; the tile at (bk_tx, bk_ty), its column bk_bx, into BK_BG from line X: sixteen lines,
; or to bk_lines (X out)
bk_tile:
        lda #0                     ; the map: MAP5 + (ty << lw) + tx, in bank 5
        sta ent+1
        lda bk_ty                  ; (the low byte shifted in A)
        ldy bk_lw
        beq :++
:       asl
        rol ent+1
        dey
        bne :-
:       clc
        adc bk_tx
        sta ent
        lda ent+1
        adc #>MAP5
        sta ent+1
        .assert <MAP5 = 0, error, "bk_tile: MAP5's low byte"
        stx bk_line
        lda PB_MAP
        jsr pgbank
        lda (ent),y                ; (Y = 0: the map's shift loop, pgbank keeps it)
        sta bk_t
        lda PB_TILES               ; the tiles: bank 6
        jsr pgbank
        lda #1                     ; the modes: 1 = the fill pair (bk_pa, bk_pb), 0 = the
        sta bk_mt                  ; stored row at (ent), for the top char row and the
        sta bk_mb                  ; bottom; bk_step, the bottom row's offset from the top's
        sty bk_step                ; (Y = 0)
        lda sv_solid               ; ---- 0: the solid (its pair set for every tile: a flat
        sta bk_pa                  ; or a half writes its own over it, a full tile reads
        sta bk_pb                  ; neither)
        lda bk_t
        beq @go
:       cmp #FLAT0
        bcc :+
        sbc #FLAT0                 ; ---- a flat: its pair (C set), in the level's file
        asl
        adc bk_fp                  ; (C = 0)
        sta cnt
        lda bk_fp+1
        adc #0
        sta cnt+1
        jsr @pair
@go:    jmp @emit
:       cmp sv_half0
        bcs @half
        clc                        ; ---- a full tile: TILES + (id + TOFF) * TILEBYTES + byte * 8
        adc #TOFF
        sta ent
        lda #0
        sta ent+1
        ldy #TILESHIFT
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
        sty bk_mt                  ; (Y = 0)
        sty bk_mb
        lda #HALFBYTES             ; the bottom char row, HALFBYTES on
        sta bk_step
        bne @emit                  ; (always)
@half:  sbc sv_half0               ; ---- a half (C = 1: the bcs): k = id - half0 + HALFOFF; its row at
        pha                        ; the halves' page + k * HALFBYTES (+ byte * 8), its pair
        clc                        ; the palette's by its colour (i = id - half0, kept)
        adc sv_halfoff
        tax                        ; (X: k; @emit reloads X)
        lsr
        lsr
        lsr
        clc
        adc sv_halfhi
        sta ent+1
        txa
        asl
        asl
        asl
        asl
        asl
        ora bk_bx
        sta ent
        pla                        ; i: its low bits are the section's HPAIR_LEN + i
        clc                        ; (the staged file's: after the palette)
        adc #HPAIR_LEN
        tay
        lda sv_hplo
        sta cnt
        lda sv_hphi
        sta cnt+1
        lda (cnt),y
        and #GL_COLMASK            ; the colour
        tay
        lda (cnt),y                ; the palette's first byte
        sta bk_pa
        tya
        ora #HPAIR_LEN/2           ; (the colour < 8: its second byte)
        tay
        lda (cnt),y                ; and its second
        sta bk_pb
        lda bk_t                   ; below half1 the top row fills, below half2 the
        cmp sv_half1               ; bottom, from it neither (the row twice)
        bcs :+
        lda #0
        sta bk_mb
        beq @emit                  ; (top: the pair, bottom: the row)
:       cmp sv_half2
        bcs :+
        lda #0
        sta bk_mt
        beq @emit                  ; (top: the row, bottom: the pair)
:       lda #0
        sta bk_mt
        sta bk_mb
        beq @emit                  ; (always)
@pair:  ldy #0                     ; the fill pair at (cnt)
        lda (cnt),y
        sta bk_pa
        iny
        lda (cnt),y
        sta bk_pb
        rts
@emit:  ldx bk_line                ; ---- the two char rows
        lda bk_skip                ; (a kind that starts at the first tile row's
        beq @top                   ;  bottom char row: just that, once a column)
        lda #0
        sta bk_skip
        beq @bot
@top:   lda bk_mt
        jsr bk_row
        bcs @done
@bot:   lda ent                    ; the bottom row's bytes
        clc
        adc bk_step
        sta ent
        bcc :+
        inc ent+1
:       lda bk_mb
        jsr bk_row
@done:  lda PB_LVL
        jmp pgbank                 ; (X kept)
; eight lines of a char row into BK_BG from X: A = 0 the row at (ent), 1 the pair;
; C = 1 when bk_lines is reached
bk_row: tay                        ; (A is 0 or 1: Y = 0 for the row, 1 for the pair,
        bne @pair                  ;  which counts its four pairs from 1)
@r:     lda (ent),y
        sta BK_BG,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #CHARLINES
        bcc @r
        clc
@out:   rts
@pair:  lda bk_pa
        sta BK_BG,x
        inx
        cpx bk_lines
        bcs @out
        lda bk_pb
        sta BK_BG,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #1+CHARLINES/2
        bcc @pair
        clc
        rts
  .endif

section:                           ; A = a section (SEC_) -> src = its start in the staged file
        asl                        ; (C = 0: A < 128)
        tay
        lda STAGE_LVL,y
        sta src
        lda STAGE_LVL+1,y
        adc #>STAGE_LVL
        sta src+1
        rts
        .assert <STAGE_LVL = 0, error, "section: STAGE_LVL page-aligned"
copy256:                           ; src -> dst (bank 7), 256 bytes
        stx cnt                    ; (X = 0: bcopy's exit, both callers)
        inx
        stx cnt+1
        ldx PB_LVL
        jmp bcopy
stage:                             ; file A -> STAGE
        ldx #>STAGE                ; (to its page: every caller sets dst before it reads it)
  .if BHW
        jmp read_page
  .else
        pha                        ; the Master: into shadow RAM
        lda ACCCON
        ora #ACC_X
        sta ACCCON
        pla
        jsr read_page
        lda ACCCON
        and #<~ACC_X
        sta ACCCON
        rts
  .endif
img_ent:                           ; item -> ent = img_tab + item*IMGTAB_LEN
        .assert IMGTAB_LEN = 5, error, "img_ent: item * 4 + item"
        sty ent+1                  ; (Y = 0 and A = item: place_walk's @pl, the one caller)
        asl
        rol ent+1
        asl
        rol ent+1                  ; * 4 (C = 0)
        adc item                   ; * 5
        bcc :+
        inc ent+1
        clc
:       adc #<img_tab
        sta ent
        lda ent+1
        adc #>img_tab
        sta ent+1
        rts
src_cnt:                           ; (ent),Y = offset lo, hi, length lo, hi -> src, cnt
        lda (ent),y
        sta src                    ; (<STAGE = 0)
        iny
        lda (ent),y
        clc
        adc #>STAGE
        sta src+1
        .assert <STAGE = 0, error, "src_cnt: STAGE's low byte"
        iny
        lda (ent),y
        sta cnt
        iny
        lda (ent),y
        sta cnt+1
        rts
unrle:                             ; src (packed) -> dst in bank 5: c < RLE_LIT_MAX = c+1
        lda PB_MAP                 ;  literals, else c - RLE_RUNBASE copies (levelfile.py)
        jsr pgbank
@c:     lda dst+1
        cmp map_end                ; the map's end: stop there (the stream runs on into
        bcs @end                   ; the next section)
        ldy #0
        jsr @next                  ; A = the control byte
        tax                        ; X = c: c+1 literals, the loop running X+1 times
        .assert RLE_LIT_MAX = $80, error, "unrle: a run is a control byte with bit 7 set"
        bpl @rd                    ; (C = 0 from the bcs: literals)
        sbc #RLE_RUNBASE           ; c - 127: c - 126 copies of one byte (C = 1: a run)
        tax
@rd:    jsr @next
@st:    jsr @dnext
        dex
        bmi @c                     ; (X at most 128: N only at the packet's end)
        bcs @st                    ; a run: the same byte again
        bcc @rd                    ; literals: the next byte
@next:  lda (src),y                ; (Y = 0) A = the next byte
        inc src
        bne :+
        inc src+1
:       rts
@dnext: sta (dst),y
        inc dst
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
        jsr main_ram
  .endif
        stx item
        lda img_file,x
        jsr stage
        lda #0                     ; <STAGE = 0
        sta src
        lda #>STAGE
        sta src+1
        ldx item
        lda img_alo,x
        sta dst
        lda img_ahi,x
        sta dst+1
        lda img_nlo,x
        sta cnt
        lda img_nhi,x
        sta cnt+1
        ldx PB_LVL
        jsr sccopy                 ; (bank 7 paged after, and its write bank; the
                                    ;  Master's scopy: out of shadow RAM)
        ldx item
        lda bflo,x                 ; ---- the bank numbers: each byte, 4..7, becomes
        sta lp                     ; that bank's socket
        lda bfhi,x
        sta lp+1
        bne @bf                    ; (always: A = the list's high byte, not page 0)
@bfl:   sta dst+1
        lda (dst),y                ; (Y = 0 from @rd)
        tax
        lda PBANK-4,x
        sta (dst),y
@bf:    jsr @rd
        sta dst
        jsr @rd
        bne @bfl                   ; (a high byte of 0: the list's end)
@bfd:   lda pboard                 ; ---- the write-bank stores, on a board: each a
        beq @wdone                 ; `sta $FE30` as assembled, a harmless second write
        ldx item                   ; of the bank on a plain machine
        lda wrlo,x
        sta lp
        lda wrhi,x
        sta lp+1
@wr:    jsr @rd
        sta dst
        jsr @rd
        beq @wdone
        sta dst+1
        jsr @rd                    ; the kind: 4..7 a constant bank, WR_INX the bank in X
        lda pboard
        cmp #BOARD_SOLIDISK
        beq @wsol
        cpx #WR_INX
        beq @wdyn
        lda PBANK-4,x              ; Watford, a constant bank: sta $FF30 + its socket
        ora #<WRSEL_WATFORD
        iny                        ; (Y = 0 from @rd: 1)
        bne @whi                   ; (always)
@wdyn:  lda #OP_STA_ABSX           ; Watford, the bank in X: sta $FF30,x
        sta (dst),y                ; (Y = 0 from @rd)
        lda #<WRSEL_WATFORD
        iny
@whi:   sta (dst),y
        lda #>WRSEL_WATFORD
        bne @wst                   ; (always)
@wsol:  lda #<WRSEL_SOLIDISK       ; Solidisk: sta $FE60, the bank being in A
        iny                        ; (Y = 0 from @rd: 1)
        sta (dst),y
        lda #>WRSEL_SOLIDISK
@wst:   iny
        sta (dst),y
        bne @wr                    ; (always: Y = 2)
@rd:    ldy #0                     ; the list's next byte -> A and X (flags on it), Y = 0
        lda (lp),y
        inc lp
        bne @rd1
        inc lp+1
@rd1:   tax
        rts
@wdone: ldy item                   ; ---- the game's: its variables, the bar's template
        .assert IMG_GAME = 0, error, "image_load: the game's image is 0"
        bne @done
        sty dst                    ; (Y = 0)
        lda #>GAME_BSS
        sta dst+1
        ldx #GAME_BSS_PAGES        ; the whole pages (at least one: build.sh)
        tya
@z:     sta (dst),y                ; (bank 7 paged, and its write bank: bcopy's pgbank)
        iny
        bne @z
        inc dst+1
        dex
        bne @z
  .if GAME_BSS_REM
        ldy #GAME_BSS_REM          ; then the last page's bytes, and no further: the
@zr:    dey                        ;  image's code may start in that page
        sta (dst),y
        bne @zr
  .endif
        ldx #>BARADDR              ; the bar's template: read_page takes the page in X
        lda #FI_BAR
        jmp read_page
@done:  rts
        .assert <BARADDR = 0 && <STAGE = 0 && <GAME_BSS = 0, error, "image_load: page-aligned"
img_file: .byte FI_GAME, FI_MENU
img_alo: .byte <GAME_ADDR, <MENU_ADDR
img_ahi: .byte >GAME_ADDR, >MENU_ADDR
img_nlo: .byte <GAME_LEN, <MENU_LEN
img_nhi: .byte >GAME_LEN, >MENU_LEN
bflo:   .byte <bf_game, <bf_menu
bfhi:   .byte >bf_game, >bf_menu
wrlo:   .byte <wr_game, <wr_menu
wrhi:   .byte >wr_game, >wr_menu
        .include "img7fix.inc"      ; bf_game, bf_menu, wr_game, wr_menu (build.sh)
        .assert IMG_MENU = 1, error, "image_load's tables: the game's, then the menus'"

; ---------------------------------------------------------------- the packer's tables
  .ifdef BAKEITEM0
bake_kind: .incbin "bake_kind.bin"   ; by baked slot: its kind (the game's)
bake_geom: .incbin "bake_geom.bin"   ; by kind, BG_LEN bytes: bytes, lines, dx (16 bit), dty, overlay offset (16 bit), skip
  .endif
img_tab: .incbin "img_tab.bin"  ; per item: its file, offset and length (IMGTAB_LEN bytes)
