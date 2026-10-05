; ============================================================================
; ldprog.s -- the load-time program: LDPROG, read to LDPROG ($0E00) by disc.s at
; every level load and every swap of bank 7's image, and run there, in main RAM,
; where it can page any bank.  A separate assembly, one per machine (LDPROGB,
; LDPROGM: build.sh), one segment, CODE (cfg/ldprog.cfg).  Its variables are
; .res bytes in the code, where they are: the program's entry is its first byte,
; and their addresses are the layout.  Both machines.
;
; The display is black and the screen is the program's scratch (defs.inc STAGE,
; STAGE_LVL: $1C00-$7FFF on the Model B; on the Master $3000-$7FFF of shadow
; RAM, ACCCON X, for the shared files and of main RAM for the level's).  A level
; is gathered from the shared files -- the tile set's three, SPRC, SPRX, the
; level's own -- by the lists the game's packer put in the level file
; (levelfmt.inc, beebgame/tools/levelfile.py): which tiles, and where every
; image goes.  Bank 7 is paged on entry and again after each part; read_sectors
; (disc.s) is its kernel's, which no image covers, and reads into main RAM.
;
; Entry: LDPROG+0, ld_entry -- X = a level 0..15 (returns to load_level_b's
; caller) or an image load (defs.inc LDOP_: goes on to the game's hook).
; Options: BAKEITEM0 (the game's packer defines it: items made here from the
; level's tiles and an overlay, bake); SPRXKEEP (the Master without GAMEHAZEL
; keeps SPRX in HAZEL and ANDY across loads); GAMEHAZEL (the game's code in
; HAZEL: cpu.inc); TILEMIRROR (mirrored full tiles, cpu.inc: the Model B's
; gather reads MIRTAB, the baker draws them reversed); GAMELDINIT (the game's
; level start, its ldgame.s, called at a level load's end: ld_game, below).
; ============================================================================
  .ifndef BHW                      ; cpu.inc's flags, again: it is the game's (its
BHW = 1                            ;  65C02 spellings and link imports), not this
  .endif                           ;  program's
  .ifndef GAMEHAZEL
GAMEHAZEL = 0
  .endif
  .ifndef TILEMIRROR
TILEMIRROR = 0
  .endif
  .ifndef GAMELDINIT
GAMELDINIT = 0
  .endif
; SPRXKEEP: the Master (without GAMEHAZEL) keeps SPRX in HAZEL and ANDY
SPRXKEEP = (BHW = 0) && (GAMEHAZEL = 0)
        .include "hw.inc"          ; the chips: ROMSEL, ACCCON, VIA_IFR; the opcodes
        .include "defs_ld.inc"     ; the game's addresses and constants (build.sh)
        .include "files.inc"       ; the disc's sector table (mkdfs.py)
        .include "levelfmt.inc"    ; the level file's sections and header (levelfile.py)
        .import __LD_START__: absolute
; The physical banks: the boot loader found RAM in whatever sockets and left
; their numbers in PBANK (low BSS, a byte per bank 4..7).  This program comes
; off the disc at every load, so the loader cannot patch it as it does the
; banks' code: every switch here reads PBANK, and the placement lists' bank
; bytes (4 or 5, the packer's) go through it too.
PB_SPR     = PBANK                 ; bank 4: sprites
PB_MAP     = PBANK + 1             ; bank 5: the map, sprites, the gather's shape
PB_TILES   = PBANK + 2             ; bank 6: the tiles
PB_LVL     = PBANK + 3             ; bank 7: the kernel and the image
; the file table (ftab, below): FTAB_LEN bytes an entry, by file number
FTAB_LEN   = 3
FI_SPRX    = 0
FI_SPRC    = 1
FI_TILES0  = 3                     ; the tile set's outdoor, shared and indoor files
FI_TILES1  = 4
FI_MENU    = 5
FI_GAME    = 6
FI_BAR     = 7
FI_L0      = 8                     ; the levels, 8..23
FI_TILES2  = 24
; MENU_SECS: bank 7's images are one file (IMG7): the menus' to a whole sector,
; then the game's (build.sh)
MENU_SECS  = (MENU_LEN + 255) / 256
PAGE0_SECS = LV_PAGE0_SECS         ; a level file ends with the Master's LV_PAGE0
                                   ;  table (256 lo, 256 hi), in sectors of its own
  .ifdef RES_N                     ; DIRSPLIT (the game's RES_N, through ldconst.s):
DIRLEN     = 2*(BOXID0+BOXN-RES_N) ;  the level file carries the ids from RES_N alone,
  .else                            ;  the resident ids' part being in SPRC (banks.s)
DIRLEN     = 2*(BOXID0+BOXN)       ; the sprite directory's level part: DIR_TABLE's
  .endif                           ;  size (banks.s), an address a sprite id
  .if SPRXKEEP
SPRX_PAGES = (SPRX_LEN + 255) / 256
  .endif
  .ifdef BAKEITEM0
BK_LINES_MAX = 32                  ; a baked column's lines at most (assets.py
  .endif                           ;  asserts it)
  .if BHW                          ; each machine's own bank 7 images (IMG7B, IMG7M)
F_IMG7_SEC = F_IMG7B_SEC
F_IMG7_N   = F_IMG7B_N
  .else
F_IMG7_SEC = F_IMG7M_SEC
F_IMG7_N   = F_IMG7M_N
  .endif
; zero page: the engine's LDZP, 17 bytes of the sprite prologue's scratch, dead
; across a load (vars.s asserts the room)
src   = LDZP                       ; 2: a copy's source (main RAM, or the stage)
dst   = LDZP + 2                   ; 2: its destination
cnt   = LDZP + 4                   ; 2: its length (bake: a mask or pair pointer)
tmp   = LDZP + 6                   ; read_page's, bake's
tmp2  = LDZP + 7                   ; pgbank's
ent   = LDZP + 8                   ; 2: an img_tab entry; bk_tile's map and tile
                                   ;  pointer
lp    = LDZP + 10                  ; 2: a list pointer (the tile list, the placements,
                                   ;  image_load's patch lists)
item  = LDZP + 12                  ; the placement item; the half tile (lv_load);
                                   ;  the image (image_load)
fnum  = LDZP + 13                  ; the shared file being walked
tbase = LDZP + 14                  ; 2: the next full tile's slot in bank 6
nt    = LDZP + 16                  ; this file's full tiles to go

; setw var, value: var = value, 16 bits, from immediates
.macro setw var, value
        lda #<(value)
        sta var
        lda #>(value)
        sta var+1
.endmacro
; FILE name: ftab's entry for the file F_<name>, its first sector (16 bits) and
; its sectors.  LFILE: a level file's, which on the Model B stops before the
; Master's LV_PAGE0 sectors.  IMG7 "MENU" / "GAME": bank 7's two images out of
; the one file (the & $FF: build.sh's passes -- before the sizes settle the
; difference can come out negative).
.macro FILE name
        .byte <.ident(.concat("F_", name, "_SEC"))
        .byte >.ident(.concat("F_", name, "_SEC"))
        .byte .ident(.concat("F_", name, "_N"))
.endmacro
.macro LFILE name
  .if BHW                          ; placement: LV_PAGE0 is the Master's gather table
        .byte <.ident(.concat("F_", name, "_SEC"))
        .byte >.ident(.concat("F_", name, "_SEC"))
        .byte .ident(.concat("F_", name, "_N")) - PAGE0_SECS
  .else
        FILE name
  .endif
.endmacro
.macro IMG7 name
  .if .xmatch(name, "MENU")
        .byte <F_IMG7_SEC, >F_IMG7_SEC, MENU_SECS
  .else
        .byte <(F_IMG7_SEC + MENU_SECS), >(F_IMG7_SEC + MENU_SECS)
        .byte (F_IMG7_N - MENU_SECS) & $FF
  .endif
.endmacro

; ----------------------------------------------------------------------------
; ld_entry: LDPROG+0 -- the load disc.s ld_go asked for
;   In:    X = a level, 0..15 (from load_level_b: its caller is returned to), or
;          LDOP_TITLE, LDOP_GAME, LDOP_OVER (go_title, go_game, go_menu: the
;          image, then the game's hook); A = go_menu's, for hook_over
;   Out:   a level: rts to load_level_b's caller with the level in the banks
;          (GAMELDINIT: and the game's ld_game run), the chain asked to resume
;          and interrupts on (ld_resume).  An image:
;          no return -- the stack reset to STACKTOP, then jmp hook_title or
;          hook_over (after ld_resume), or hook_image then game_in (hook_play;
;          interrupts still off, ld_open = 1: the level loop's first load goes
;          straight in)
;   Uses:  everything
;   Pre:   the chain parked and interrupts off (disc.s ld_go); bank 7 paged
; ----------------------------------------------------------------------------
        .segment "CODE"
ld_entry:
        cpx #LDOP_IMAGE
        bcs ld_image
        jsr lv_load
  .if GAMELDINIT
        jsr ld_game                ; the game's level start (LDGAME, below)
  .endif

; ----------------------------------------------------------------------------
; ld_resume: a load's end -- the disc closed, the chain asked to resume,
; interrupts on (ld_entry falls into it; ld_image's menu loads call it)
;   Out:   ld_open = 0; load_req = LDR_RESUME (the next vsync turns T1's
;          interrupt on again and clears it: kernel.s, the vsync's handler); the
;          T1 and vsync flags cleared (any raised during the load is stale)
;   Uses:  A
;   Keeps: X Y, C (ld_image relies on Y and C)
; ----------------------------------------------------------------------------
ld_resume:
        lda #0
        sta ld_open
        lda #LDR_RESUME
        sta load_req
        lda #VIA_IT1|VIA_ICA1
        sta VIA_IFR
        cli
        rts

; ----------------------------------------------------------------------------
; ld_image: an image load, then its hook
;   In:    X = the op (LDOP_TITLE, LDOP_GAME, LDOP_OVER), A = go_menu's
;   Out:   no return (ld_entry says where); ld_img = the image (test/hbeebem
;          reads it)
;   Uses:  everything; the stack reset
; ----------------------------------------------------------------------------
ld_image:
        pha                        ; go_menu's A, then the op, across the load
        txa
        pha
        and #LDOP_IMGMASK          ; the image: bit 0 of the op
        sta ld_img
        tax
        jsr image_load
        .assert (LDOP_GAME & LDOP_IMGMASK) = IMG_GAME && (LDOP_TITLE & LDOP_IMGMASK) = IMG_MENU && (LDOP_OVER & LDOP_IMGMASK) = IMG_MENU && IMG_MENU = 1, error, "ld_image: bit 0 of the op is the menus' image"
        .assert (LDOP_TITLE >> 1) < (LDOP_OVER >> 1), error, "ld_image: go_menu's op above go_title's"
        pla                        ; the op: C = its bit 0, the menus' image
        lsr
        tay
        pla                        ; (A: go_menu's, for hook_over)
        ldx #STACKTOP              ; the stack reset: nothing of the other image's
        txs                        ;  is returned to (init.s: 64 bytes)
        bcs @menu
        inc ld_open                ; the game's: 0 -> 1, the level loop's first load
        jsr hook_image             ;  goes straight in; the game's hook for what the
        jmp game_in                ;  load made stale; then hook_play
@menu:  cpy #(LDOP_OVER >> 1)      ; C = 1: go_menu's op, 0: go_title's
        tay                        ; (A, go_menu's, kept in Y across ld_resume)
        jsr ld_resume
        tya
        bcc @title
        jmp hook_over
@title: jmp hook_title

; ---------------------------------------------------------------- the file table
; ftab: by file number, FTAB_LEN bytes: the first sector (lo, hi) and the count
; (files.inc: the disc's own order).  The FI_ equates index it; the labels bind
; them (the assert after the table).
ftab:
@sprx:  FILE "SPRX"                ; the sprites placed per level (img_tab's file 0)
@sprc:  FILE "SPRC"                ; the sprites every level draws: banks 4 and 5
        FILE "SPRC"                ; (unused)
@t0:    FILE "TILES0"              ; the tile set's outdoor and shared files
@t1:    FILE "TILES1"
@menu:  IMG7 "MENU"                ; this machine's images of bank 7, the menus' and
@game:  IMG7 "GAME"                ;  the game's (one file: build.sh)
@bar:   FILE "BAR"                 ; the bar's template
@l0:    LFILE "L0"                 ; the 16 levels
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
@t2:    FILE "TILES2"              ; and the set's indoor file
        .assert @sprx = ftab + FTAB_LEN*FI_SPRX && @sprc = ftab + FTAB_LEN*FI_SPRC && @t0 = ftab + FTAB_LEN*FI_TILES0 && @t1 = ftab + FTAB_LEN*FI_TILES1, error, "ftab: the FI_ numbers"
        .assert @menu = ftab + FTAB_LEN*FI_MENU && @game = ftab + FTAB_LEN*FI_GAME && @bar = ftab + FTAB_LEN*FI_BAR && @l0 = ftab + FTAB_LEN*FI_L0 && @t2 = ftab + FTAB_LEN*FI_TILES2, error, "ftab: the FI_ numbers"
; tfi: the tile set's files by number
tfi:    .byte FI_TILES0, FI_TILES1, FI_TILES2

; ----------------------------------------------------------------------------
; read_file: file A to dst, in main RAM
;   In:    A = the file number (ftab); dst+1 = the page (dst's low byte is not
;          read: every destination is a page)
;   Out:   the file read; ld_sec, ld_n, ld_dst the last run's (disc.s)
;   Uses:  A X Y, tmp
; read_page: the same to page X (dst untouched).
; ----------------------------------------------------------------------------
read_file:
        ldx dst+1
read_page:
        stx ld_dst+1
        sta tmp
        asl                        ; * FTAB_LEN: 2A + A (C = 0: A < 128)
        adc tmp
        .assert FTAB_LEN = 3, error, "read_page: the entry's offset is 2A + A"
        tax
        ldy #<-FTAB_LEN            ; the entry's bytes to ld_sec, ld_sec+1, ld_n
@ent:   lda ftab,x
        sta ld_sec+FTAB_LEN-$100,y
        inx
        iny
        bne @ent
        .assert ld_n = ld_sec + 2, error, "ld_sec and ld_n are 3 bytes in a row"
        .assert <LDPROG = 0, error, "ld_dst's low byte is 0"
        jmp read_sectors           ; (ld_dst's low byte: 0 from disc.s ld_go, and
                                   ;  never changed)

; ---------------------------------------------------------------- the copies
  .if BHW                          ; hardware: the Master stages in shadow RAM
sccopy = bcopy                     ; a copy out of the stage, on either machine
  .else
sccopy = scopy
  .endif

; ----------------------------------------------------------------------------
; plcopy: cnt bytes from src (the stage) to dst in the bank the placement entry
; names -- the packer's number, 4 or 5, for the socket that is that bank here
;   In:    lp -> the placement entry (PL_BANK), src, dst, cnt
;   Out:   bcopy's (X = 0, Y = cnt), bank 7 paged
;   Uses:  A X Y, tmp2
; Falls into scopy (the Master) or bcopy.
; ----------------------------------------------------------------------------
plcopy: ldy #PL_BANK
        lda (lp),y
        tay
        ldx PBANK-4,y
  .if .not BHW                     ; hardware: the Master's stage is shadow RAM
; ----------------------------------------------------------------------------
; scopy: bcopy with ACCCON X set for the read -- the Master's copy out of the
; stage ($3000-$7FFF of shadow RAM)
;   In:    X = the socket, src, dst, cnt
;   Out:   bcopy's; ACCCON X clear again
;   Uses:  A X Y, tmp2
; ----------------------------------------------------------------------------
        .setcpu "65C02"
scopy:  lda #ACC_X
        tsb ACCCON
        jsr bcopy
        lda #ACC_X
        trb ACCCON
        rts
        .setcpu "6502"
  .endif

; ----------------------------------------------------------------------------
; bcopy: cnt bytes from src to dst in bank X, then bank 7 back
;   In:    X = the socket to page (read and write), src, dst, cnt (16 bits)
;   Out:   src+1, dst+1 up by the whole pages (the low bytes untouched: the tail
;          is indexed); X = 0; Y = cnt's low byte; bank 7 paged and its write
;          bank
;   Uses:  A X Y, tmp2
; Falls into pgbank with A = bank 7's socket.
; ----------------------------------------------------------------------------
bcopy:  txa
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
@done:  lda PB_LVL

; ----------------------------------------------------------------------------
; pgbank: page a socket for reading, and for writing on a board
;   In:    A = the socket; pboard (the board: BOARD_*)
;   Out:   ROMSEL and ROMSEL_CPY = the socket; the board's write-bank register
;          set (Watford: a store to WRSEL_WATFORD + socket; Solidisk: the socket
;          on the user VIA's port B, whose DDRB the boot loader set)
;   Uses:  A (the socket again on exit), tmp2
;   Keeps: X Y
; ----------------------------------------------------------------------------
pgbank: sta ROMSEL_CPY
        sta ROMSEL
        pha
        stx tmp2
        tax
        lda pboard
        beq @done
        lsr                        ; BOARD_WATFORD -> C = 1, BOARD_SOLIDISK -> C = 0
        .assert BOARD_STD = 0 && BOARD_WATFORD = 1 && BOARD_SOLIDISK = 2, error, "pgbank tells the boards by bit 0"
        bcc @solidisk
        sta WRSEL_WATFORD,x        ; Watford: the address says which, the value
        bcs @done                  ;  nothing (always: a store keeps C)
@solidisk:
        stx WRSEL_SOLIDISK
@done:  ldx tmp2
        pla
        rts

; ----------------------------------------------------------------------------
; lvsec: section A of the level's file, whole, to page X of bank 7
;   In:    A = the section (SEC_), X = the destination page; the file at
;          STAGE_LVL (its table: offsets from the file's start, two bytes a
;          section, the sections end to end -- levelfile.py)
;   Out:   bcopy's: src+1 and dst+1 up by the whole pages (dst's low byte is 0
;          throughout, lv_load's STAGE_LVL's); X = 0
;   Uses:  A X Y, cnt, tmp2
; ----------------------------------------------------------------------------
lvsec:  stx dst+1
        jsr section                ; src = the section; Y = 2 * A
        lda STAGE_LVL+2,y          ; cnt = the next section's offset less this one's
        sec
        sbc STAGE_LVL,y
        sta cnt
        lda STAGE_LVL+3,y
        sbc STAGE_LVL+1,y
        sta cnt+1
        ldx PB_LVL
        jmp bcopy

; ----------------------------------------------------------------------------
; lv_load: a level into the banks and main RAM
;   In:    X = the level, 0..15
;   Out:   the level's file read and its parts placed (below); bank 7 paged and
;          its write bank; the Master: LV_PAGE0 filled, both screens cleared
;   Uses:  everything; the screen as the stage
;   Pre:   interrupts off, the palette black (the stage is the screen)
; The parts, in the file's order of use: the header to LV_HDR (the game's tail
; with it), the objects to LV_OBJS, the two tile tables to LV_ATTR0 and
; LV_ALTCLS; the map's shape (map_shr, map_stride) and the map, run-length
; coded, to MAP5 in bank 5; the tiles -- each of the level's files of the tile
; set staged in turn and its tiles copied to their slots in bank 6: the full
; tiles by the tile list (the files, each one's number and its count of full
; tiles; then each tile's index in its file), the half tiles by the half list
; (index, row | the file's place in the list << 1); the halves' fill palette
; after the halves, and (Model B) each half's low bits to bank 5's HLOW; the
; tile shape to banks 5 and 6 (SOLIDF, HPAIR0/1: the blitter's patch points;
; half0, halfhi5, half_sub: the Model B's gather's); the resident sprites SPRC
; to banks 4 (and 5) once (sprc_ok); SPRX staged and the level's subset placed
; by its list (place_walk, which also bakes); the sprite directory's level part
; to DIR_TABLE; the flat tiles' pairs to FLATTAB; the Master: the gather's table
; to LV_PAGE0.
; ----------------------------------------------------------------------------
lv_load:
  .if .not BHW                     ; hardware: shadow RAM
        jsr main_ram               ; the CPU on main RAM (the game left ACCCON X on
  .endif                           ;  the buffer it drew last)
        txa
        clc
        adc #FI_L0
        ldx #<STAGE_LVL            ; (through X: A is the file)
        stx dst
        ldx #>STAGE_LVL
        stx dst+1
        jsr read_file
        ; ---- the tables: the section table's offsets are from the file's start
        .assert <STAGE_LVL = 0 && <LV_HDR = 0 && <LV_OBJS = 0 && <LV_ATTR0 = 0, error, "lvsec: dst's low byte is 0"
        lda #SEC_HDR               ; the header, and the game's tail after it
        ldx #>LV_HDR               ;  (under a page: levelfile.py)
        jsr lvsec
        lda #SEC_OBJS              ; the objects, OBJ_BYTES each, to main RAM
        ldx #>LV_OBJS              ;  (level_init reads them once, before the
        jsr lvsec                  ;  first render)
        lda #SEC_ATTR              ; the two tile tables, 256 bytes each: the attr
        ldx #>LV_ATTR0             ;  by lvsec, which leaves src on the altcls and
        jsr lvsec                  ;  dst on LV_ALTCLS (X = 0)
        .assert LV_ALTCLS = LV_ATTR0 + $100, error, "lvsec's copy leaves dst at LV_ALTCLS"
        jsr copy256
        ; ---- the shape: map_row's shift, the row stride
        lda LV_HDR+HDR_MAP_SHR
        sta map_shr
        stx map_stride+1           ; (X = 0: copy256 ends in bcopy)
        ldx LV_HDR                 ; lw: stride = 1 << lw
        lda #1
:       asl
        rol map_stride+1
        dex
        bne :-
        sta map_stride
        ; ---- the map, run-length coded, into bank 5: exactly its 1 << (lw +
        ;      lh) bytes (the stream is not terminated: the next section follows
        ;      it)
        lda LV_HDR                 ; lw + lh - 8: the map's pages' shift (at least
        adc LV_HDR+HDR_LH          ;  2: a map is at least 1K.  C = 0: the stride's
        sbc #8-1                   ;  last rol shifted out a 0, so the sbc takes 8)
        stx fnum                   ; (X = 0 from the stride's loop: the tiles'
        tax                        ;  first file)
        lda #1
:       asl
        dex
        bne :-
        adc #>MAP5                 ; (C = 0 from the asl: fewer than 128 pages) the
        sta map_end                ;  page after the map
        lda #SEC_MAP
        jsr section
        .assert <MAP5 = 0, error, "dst's low byte is 0 still"
        lda #>MAP5
        sta dst+1
        jsr unrle
        ; ---- the tiles: each of the level's files of the tile set staged in
        ;      turn (fnum walks the tile list's files) and its tiles copied to
        ;      bank 6.  tbase: the next full slot, id 1's (id 0 is the solid,
        ;      filled, never stored)
        .assert <TILES = 0, error, "TILES page-aligned"
        setw tbase, TILES + (TOFF+1)*TILEBYTES
@file:  lda #SEC_TILES
        jsr section
        lda fnum
        bne @fn                    ; the first file: the list's head, once --
        tay                        ;  (Y = 0) the file count, then lp = the first
        lda (src),y                ;  index, past the count and the (file, count)
        sta nfiles                 ;  pairs: 1 + 2n (the sec)
        asl
        sec
        adc src
        sta lp
        lda src+1
        adc #0
        sta lp+1
        tya                        ; (fnum's 0)
@fn:    asl                        ; the pair: Y = 1 + 2 fnum
        tay
        iny
        lda (src),y                ; the set's file
        tax
        iny
        lda (src),y                ; its full tiles (saved before the stage, which
        sta nt                     ;  keeps zero page but for tmp)
        lda tfi,x
        jsr stage
@tile:  lda nt
        beq @halves
        lda tbase
        sta dst
        lda tbase+1
        sta dst+1
        ldy #0
        lda (lp),y                 ; the tile's index in the file
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
@halves:                           ; this file's half tiles, to their slots
        lda LV_HDR+HDR_HALFOFF     ; HALFOFF slots of HALFBYTES (32) into the halves'
        asl                        ;  page: the first half's slot
        asl
        asl
        asl
        asl
        sta dst                    ; (the next half's slot is dst itself: section
        lda LV_HDR+HDR_HALFPAGE    ;  and tcopy leave it alone, a half's copy is
        sta dst+1                  ;  under a page)
        lda #0
        sta item                   ; item: the half, 0..NHALF-1
@half:  lda #SEC_HALVES
        jsr section                ; (on the way out too: harmless, src is remade
        lda item                   ;  after)
        cmp LV_HDR+HDR_NHALF
        beq @nextfile
        asl
        tay
        iny
        lda (src),y                ; the half's row | its file << 1
        lsr
        eor fnum                   ; (eor, not cmp: C keeps the row from the lsr)
        bne @hnext                 ; another file's
        dey
        lda (src),y                ; its index in the file
        ldx #HALFBYTES
        jsr tcopy
@hnext: lda dst                    ; the next slot
        clc
        adc #HALFBYTES
        sta dst
        bcc :+
        inc dst+1
:       inc item
        bne @half                  ; (always: item < NHALF <= 255 before the inc)
@nextfile:
        inc fnum
        lda fnum
        cmp nfiles
        beq @hpair
        jmp @file
        ; ---- the halves' fill palette (8 first bytes, then 8 second) to bank 6
        ;      right after the halves (dst: the last file's walk left it there;
        ;      kept in hdst for the blitter's patch points)
@hpair: lda #SEC_HPAIR
        jsr section                ; src = the palette, then each half's low bits
  .ifdef BAKEITEM0
        lda src                    ; (the baker reads both from the staged file)
        sta sv_hplo
        lda src+1
        sta sv_hphi
  .endif
        lda dst
        sta hdst
        lda dst+1
        sta hdst+1
        setw cnt, HPAIR_LEN
        ldx PB_TILES
        jsr bcopy                  ; (bank 7 back after it; src unmoved: under a
                                   ;  page)
  .if BHW                          ; placement: the Model B's gather's shape, bank 5
        ; ---- each half's low bits (its fill row and colour), by k, into bank
        ;      5's HLOW for the gather: from HALFOFF on (k counts from the
        ;      halves' page)
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
    .if TILEMIRROR
        ; ---- the mirrored tiles' sources, by id - mir0, into bank 5's MIRTAB
        lda #SEC_MIR
        jsr section
        setw dst, MIRTAB
        lda LV_HDR+HDR_NMIR
        sta cnt                    ; (cnt+1 is 0 still: bcopy's exit)
        ldx PB_MAP
        jsr bcopy
    .endif
  .endif
        ; ---- the tile shape, into banks 5 and 6 (read here, with bank 7 in)
        lda LV_HDR+HDR_HALFPAGE
        sta sv_halfhi
        ldx LV_HDR+HDR_SOLIDFILL   ; the solid's fill byte (id 0): X to bank 6, and
        stx sv_solid               ;  the baker's copy
  .ifdef BAKEITEM0                 ; (the baker's: the halves' slot offset)
        lda LV_HDR+HDR_HALFOFF
        sta sv_halfoff
  .endif
  .if BHW || .defined(BAKEITEM0)   ; placement: the gather's shape (the Master's is
        lda LV_HDR+HDR_HALF0       ;  LV_PAGE0); the baker decodes a tile as the
        sta sv_half0               ;  Model B's gather does
    .if TILEMIRROR
        clc                        ; half0 - HALFOFF - 1 (gather5 subtracts it with
    .else                          ;  C clear, after its mirror test)
        sec                        ; half0 - HALFOFF (gather5 subtracts it with C
    .endif                         ;  set)
        sbc LV_HDR+HDR_HALFOFF
        sta sv_halfsub
    .if TILEMIRROR
        lda LV_HDR+HDR_MIR0        ; the mirrored tiles' first id
        sta sv_mir0
    .endif
        lda LV_HDR+HDR_HALF1
        sta sv_half1
        lda LV_HDR+HDR_HALF2
        sta sv_half2
  .endif
        lda PB_TILES
        jsr pgbank                 ; (X, Y kept)
        stx SOLIDF                 ; the row loop's lda #fill for id 0 (tiles.s)
        lda hdst                   ; the palette's first bytes, then its second, 8 on
        sta HPAIR0                 ;  (hdst's low byte is a multiple of HALFBYTES:
        ora #HPAIR_LEN/2           ;  no carry)
        sta HPAIR1
        lda hdst+1
        sta HPAIR0+1
        sta HPAIR1+1
  .if BHW                          ; placement: the Model B's gather's shape, bank 5
        lda PB_MAP
        jsr pgbank
        lda sv_half0
        sta half0
        lda sv_halfhi
        and #<~GH_TILE             ; a half's page less GH_TILE (gather5's mark)
        sta halfhi5
        lda sv_halfsub
        sta half_sub
    .if TILEMIRROR
        lda sv_mir0                ; the gather's mirror test (its cmp's operand)
        sta MIRCMP                 ;  and MIRTAB's base less mir0 (its lda's)
        lda #<MIRTAB
        sec
        sbc sv_mir0
        sta MIRBASE
        lda #>MIRTAB
        sbc #0
        sta MIRBASE+1
    .endif
  .endif
        lda PB_LVL
        jsr pgbank
        ; ---- the sprites: the resident block SPRC to its fixed places in banks
        ;      4 (and 5) once, and it stays (the menus keep to bank 7); SPRX
        ;      staged and the level's subset placed by its list
        lda sprc_ok
        bne @sprx
        lda #FI_SPRC
        jsr stage
        setw src, STAGE
        setw dst, SPRC_BASE
        setw cnt, SPRC_LEN
        ldx PB_SPR
        jsr sccopy                 ; bank 4's part (the packer's split)
  .if SPRC5_LEN                    ; (the packer's: none when bank 4 holds all of
        setw src, STAGE + SPRC_LEN ;  SPRC)
        setw dst, SPRC5_BASE
        setw cnt, SPRC5_LEN
        ldx PB_MAP
        jsr sccopy                 ; the rest: bank 5
  .endif
        inc sprc_ok
@sprx:  lda #FI_SPRX
        sta fnum
  .if .not SPRXKEEP                ; placement: the Master keeps SPRX in HAZEL/ANDY
        jsr stage
  .else
        ldx sprx_ok                ; read once; after, the stage is refilled from
        bne @unkeep                ;  them, no disc read
        jsr stage
        inc sprx_ok
        sec                        ; keep: C = 1
        .byte OP_BIT_ZP            ; (bit zp: the clc skipped)
@unkeep:
        clc                        ; unkeep: C = 0
        jsr unkeep
  .endif
        jsr place_walk
        ; ---- the sprite directory's level part, as the packer finished it: to
        ;      bank 7, beside the prologue that reads it
        lda #SEC_DIR
        jsr section
        setw dst, DIR_TABLE
        setw cnt, DIRLEN
        ldx PB_LVL
        jsr bcopy
        ; ---- the flat tiles' pairs, into bank 6 with the blitter's fill
        lda #SEC_FLAT
        jsr section
        setw dst, FLATTAB
        setw cnt, FLATTAB_LEN
        ldx PB_TILES
  .if BHW                          ; placement: the gather's table is the Master's
        jmp bcopy
  .else
        jsr bcopy
        ; ---- the Master: the gather's table to main RAM, and both screens
        ;      (main and shadow) cleared of what the load staged there: a ring
        ;      row the window has not reached yet must not show it
        lda #SEC_PAGE0
        jsr section
        stx dst                    ; (X = 0: bcopy's exit; <LV_PAGE0 = 0)
        .assert <LV_PAGE0 = 0, error, "LV_PAGE0 page-aligned"
        lda #>LV_PAGE0
        sta dst+1
        stx cnt
        lda #LV_PAGE0_SECS
        sta cnt+1
        ldx PB_LVL                 ; (main RAM: the bank is moot; bank 7 stays paged)
        jsr bcopy
        .setcpu "65C02"
        lda #ACC_X
        tsb ACCCON
        jsr @clr                   ; shadow
        lda #ACC_X
        trb ACCCON                 ; and main, falling in (ACCCON X clear on the
        .setcpu "6502"             ;  way out)
@clr:   lda #0
        sta dst
        tay
        ldx #>STAGE                ; the screen, from the stage's page ($3000) to
@cp:    stx dst+1                  ;  $7FFF
@cb:    sta (dst),y
        iny
        bne @cb
        inx
        bpl @cp
        rts
  .endif

; ---------------------------------------------------------------- the helpers
  .if .not BHW                     ; hardware: shadow RAM, HAZEL and ANDY
; ----------------------------------------------------------------------------
; main_ram: the CPU on main RAM -- ACCCON X clear (and Y, unless the game's code
; is in HAZEL: GAMEHAZEL games run with Y set throughout)
;   Uses:  A
;   Keeps: X Y
; Every load starts with it (lv_load, image_load): the game leaves ACCCON X on
; the buffer it drew last, and the level's file is read into main RAM.  Without
; GAMEHAZEL it is unkeep's tail, below.
; ----------------------------------------------------------------------------
    .if GAMEHAZEL
main_ram:
        lda ACCCON
        and #<~ACC_X
        sta ACCCON
        rts
    .endif
  .endif
  .if SPRXKEEP                     ; placement: SPRX kept in HAZEL and ANDY
; ----------------------------------------------------------------------------
; unkeep: SPRX's residency on the Master -- the stage (shadow RAM, $3000) to
; HAZEL ($C000, ACCCON Y) and ANDY ($8000, ROMSEL bit 7), or back
;   In:    C = 1 keep (the stage to HAZEL and ANDY), 0 unkeep (back to the
;          stage)
;   Out:   12K copied (HAZEL's 8K, ANDY's 4K: whatever SPRX's length); bank 7
;          paged, ANDY out, ACCCON X and Y clear (main_ram's tail)
;   Uses:  A X Y, src, dst, cnt, tmp2
;   Pre:   under a load: interrupts off, and the game's code in bank 7 (ANDY
;          would hide its bottom 4K; HAZEL does not hide the interrupt's path)
; ----------------------------------------------------------------------------
unkeep: php                        ; C, for kpart
        .setcpu "65C02"
        lda #ACC_X|ACC_Y           ; X (the stage) and Y (HAZEL)
        tsb ACCCON
        .setcpu "6502"
        ldx #HAZEL_PAGES           ; HAZEL: the stage's first 8K
        lda #>STAGE
        ldy #>HAZEL
        jsr kpart
        lda #ROMSEL_ANDY           ; ANDY: the next 4K (bcopy pages it too)
        sta ROMSEL
        ldx #ANDY_PAGES
        lda #>STAGE + HAZEL_PAGES
        ldy #>ANDY
        jsr kpart
        lda PB_LVL                 ; bank 7 back, ANDY out
        jsr pgbank
        plp
; ---- main_ram: the box above (SPRXKEEP: GAMEHAZEL = 0; every load's start)
main_ram:
        lda ACCCON
        and #<~(ACC_X|ACC_Y)
        sta ACCCON
        rts

; ----------------------------------------------------------------------------
; kpart: X whole pages between the stage's page A and page Y, the way unkeep's
; C says (the P it pushed, read off the stack: keep from the stage, else to it)
;   In:    X = pages, A = the stage's page, Y = the other
;   Out:   bcopy's, the copy made with ANDY paged (ROMSEL_ANDY); bank 7 back
;   Uses:  A X Y, src, dst, cnt, tmp2
; ----------------------------------------------------------------------------
kpart:  stx cnt+1
        tsx                        ; X = S: S+1, S+2 the return, S+3 unkeep's P
        pha
        lda $0100+3,x
        lsr                        ; C = its carry
        pla
        bcc @back
        sta src+1                  ; keep: from the stage
        sty dst+1
        bcs @whole
@back:  sty src+1                  ; unkeep: to the stage
        sta dst+1
@whole: lda #0                     ; whole pages: the low bytes 0, no tail
        sta src
        sta dst
        sta cnt
        ldx #ROMSEL_ANDY           ; bcopy's page loop with ANDY in (HAZEL's part
        jmp bcopy                  ;  touches no $8000-$BFFF); bank 7 back after
  .endif

; ----------------------------------------------------------------------------
; tcopy: tile A of the staged tile file -- its char row C, or all of it -- to
; dst in bank 6
;   In:    A = the tile's index in the file; C = the row (0 top, 1 bottom) with
;          X = HALFBYTES, or C = 0 with X = TILEBYTES for the whole tile; dst
;   Out:   bcopy's (sccopy: out of the stage); bank 7 paged
;   Uses:  A X Y, src, cnt, tmp2
; A tile is TILEBYTES (64) in the file, four to a page: src = STAGE + (A >> 2)
; pages + (A & 3) * 64 + the row's 0 or HALFBYTES.
; ----------------------------------------------------------------------------
tcopy:  stx cnt
        ldx #0
        stx cnt+1
        tax
        ror                        ; C:A rotated three times: bits 7-5 = t1 t0 row
        ror
        ror
        and #<-HALFBYTES           ; (A & 3) << 6 | the row's 0 or HALFBYTES
        sta src
        txa
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        ldx PB_TILES
        jmp sccopy

; ---------------------------------------------------------------- the variables
; Here, between the code (the one segment's entry is its first byte); their
; addresses are the layout.
nfiles:     .res 1                 ; lv_load: the tile set's files this level uses
hdst:       .res 2                 ;  the halves' end: the fill palette's place
sv_halfhi:  .res 1                 ;  the tile shape on its way to banks 5 and 6:
sv_solid:   .res 1                 ;  the halves' page, the solid's fill byte,
sv_halfoff: .res 1                 ;  (the baker's) the halves' slot offset
  .ifdef BAKEITEM0
bk_col:     .res 1                 ; bake: columns to go
bk_lines:   .res 1                 ;  the kind's lines
bk_x:       .res 2                 ;  the column's game pixel X (16 bits, even)
bk_ty0:     .res 1                 ;  the first tile row
bk_skip0:   .res 1                 ;  the kind's: start it at its bottom char row
bk_skip:    .res 1                 ;  (the column's copy)
bk_sock:    .res 1                 ;  the destination's socket
bk_lw:      .res 1                 ;  the map's width shift
bk_bx:      .res 1                 ;  the column's byte in the tile (0, 8, 16, 24)
bk_tx:      .res 1                 ;  its tile, and the tile row
bk_ty:      .res 1
bk_line:    .res 1                 ; bk_tile: the line in BK_BG
bk_t:       .res 1                 ;  the tile id
bk_mt:      .res 1                 ;  the top and bottom char rows' modes (1 the
bk_mb:      .res 1                 ;  pair, 0 the stored row)
bk_step:    .res 1                 ;  the bottom row's offset from the top's
bk_pa:      .res 1                 ;  the fill pair
bk_pb:      .res 1
bk_fp:      .res 2                 ;  the flats' pairs, in the level's file
    .if TILEMIRROR
bk_mp:      .res 2                 ;  MIRTAB, in the level's file
bk_cx:      .res 1                 ; bk_tile: the full tile's column (bk_bx, or
bk_md:      .res 1                 ;  a mirror's 24 - bk_bx) and its rows' mode
    .endif
BK_BG:      .res BK_LINES_MAX      ; the column's backdrop, a byte a line
  .endif
sv_hplo:    .res 1                 ; the HPAIR section in the staged file (the
sv_hphi:    .res 1                 ;  baker's)
map_end:    .res 1                 ; the page after the level's map (unrle)
  .if BHW || .defined(BAKEITEM0)   ; placement: the gather's shape (bake's too)
sv_half0:   .res 1                 ; the half tiles' first id, the two range
sv_half1:   .res 1                 ;  boundaries, and half0 - HALFOFF
sv_half2:   .res 1
sv_halfsub: .res 1
    .if TILEMIRROR
sv_mir0:    .res 1                 ; the mirrored tiles' first id
    .endif
  .endif

; ----------------------------------------------------------------------------
; place_walk: the placement list's items that come from the staged file fnum
;   In:    fnum = the file staged (FI_SPRX: 0); the level's file (SEC_PLACE)
;   Out:   each item of file fnum copied to its bank and address (plcopy); with
;          BAKEITEM0, the baked items made (bake) during the SPRX walk; bank 7
;          paged
;   Uses:  everything
; An entry (PLACE_LEN): the item (PL_END ends the list), the bank (4 or 5), the
; address, two extra bytes (a baked item's tile x, y).  An item below BAKEITEM0
; is an image: img_tab's entry gives its file, offset and length.
; ----------------------------------------------------------------------------
place_walk:
        lda #SEC_PLACE
        jsr section
        lda src
        sta lp
        lda src+1
        sta lp+1
@pl:    ldy #PL_ITEM
        lda (lp),y
        cmp #PL_END
        beq @done
        sta item
  .ifdef BAKEITEM0
        cmp #BAKEITEM0             ; a baked box: made here from SPRX's overlays,
        bcc @image                 ;  on the SPRX walk
        lda fnum
        bne @next
        .assert FI_SPRX = 0, error, "place_walk: FI_SPRX"
        jsr bake
        jmp @next
@image:
  .endif
        jsr img_ent                ; ent -> img_tab's entry (A = item, Y = 0)
        lda (ent),y                ; its file
        cmp fnum
        bne @next                  ; another file's
        ldy #1                     ; src = STAGE + offset, cnt = length
        jsr src_cnt
        ldy #PL_ADDR
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        jsr plcopy                 ; to the placement's bank
@next:  lda lp
        clc
        adc #PLACE_LEN
        sta lp
        bcc @pl
        inc lp+1
        bne @pl                    ; (always: lp+1 is never 0)
@done:  rts

  .ifdef BAKEITEM0
; ----------------------------------------------------------------------------
; bake: a baked box -- an item from BAKEITEM0 on is not copied but made here:
; the level's own tiles where the object stands, with the game's overlay over
; them
;   In:    item (BAKEITEM0..), lp -> its placement entry (the bank, the address,
;          and in PL_EXTRA the object's tile x, y); SPRX staged; the level's
;          file; bank 7 paged
;   Out:   the box in its bank: columns of (backdrop AND mask) OR pixels; bank 7
;          paged again
;   Uses:  everything; the bk_* variables, BK_BG
; bake_kind gives the item's kind and bake_geom (BG_LEN bytes a kind:
; tools/assets.py) the kind's shape: byte columns, lines (every scanline), the
; backdrop's origin from (8x, 8y) -- dx in game pixels (16 bits, even), dty in
; whole tile rows -- the overlay's offset in SPRX (a column's pixels, lines
; bytes, then its mask), and whether the first tile row starts at its bottom
; char row (skip: a kind whose art sits a char row down).  A column at a time:
; its backdrop is decoded into BK_BG tile row by tile row as the Model B's
; gather does (bk_tile), then masked, overlaid and stored.
; ----------------------------------------------------------------------------
bake:   lda #SEC_FLAT              ; the flats' pairs, in the level's file (main RAM)
        jsr section
        lda src
        sta bk_fp
        lda src+1
        sta bk_fp+1
    .if TILEMIRROR
        lda #SEC_MIR               ; the mirrored tiles' sources, there too
        jsr section
        lda src
        sta bk_mp
        lda src+1
        sta bk_mp+1
    .endif
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
        ldy #PL_EXTRA              ; X0 = 8x + dx: 8x's high byte is x >> 5, its
        lda (lp),y                 ;  low byte x << 3
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
        pla                        ; (C: the low byte's carry)
        adc bake_geom+BG_DX+1,x
        sta bk_x+1
        iny                        ; the first tile row: y + dty
        lda (lp),y
        clc
        adc bake_geom+BG_DTY,x
        sta bk_ty0
        lda bake_geom+BG_SKIP,x    ; from its bottom char row?
        sta bk_skip0
        lda bake_geom+BG_OV,x      ; the overlay: STAGE + its offset
        sta src
        clc
        .assert <STAGE = 0, error, "bake: STAGE's low byte"
        lda bake_geom+BG_OV+1,x
        adc #>STAGE
        sta src+1
        ldy #PL_ADDR+1             ; where it goes: the address, then the bank (4
        lda (lp),y                 ;  or 5) as a socket
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
        ; ---- a column: its byte in the tile -- ((X >> 1) & 3) * 8, as (X << 2)
        ;      & $18 -- and its tile, X >> 3; then its lines into BK_BG
@col:   lda bk_x
        tax
        asl
        asl
        and #(TILECHARS-1)*CHARBYTES
        sta bk_bx
        lda bk_x+1
        sta tmp
        txa
        ldy #TILEPX_SHIFT
@tx:    lsr tmp
        ror
        dey
        bne @tx
        sta bk_tx
        lda bk_ty0
        sta bk_ty
        lda bk_skip0
        sta bk_skip
        ldx #0                     ; X: the line, in BK_BG
@seg:   jsr bk_tile                ; a tile row's lines (to bk_lines)
        inc bk_ty
        cpx bk_lines
        bcc @seg
        ; ---- the column, made, to its bank: the overlay's pixels at src, its
        ;      mask (cnt) after them (X = lines)
        txa
        clc
        adc src
        sta cnt
        lda src+1
        adc #0
        sta cnt+1
        lda bk_sock
        jsr pgbank
    .if .not BHW                   ; hardware: SPRX is staged in shadow RAM (the
        .setcpu "65C02"            ;  backdrop, BK_BG, is below it and the bank
        lda #ACC_X                 ;  above)
        tsb ACCCON
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
    .if .not BHW                   ; hardware: shadow RAM
        lda ACCCON
        and #<~ACC_X
        sta ACCCON
    .endif
        ; ---- the next column: dst + lines (Y: the copy ends on it), the
        ;      overlay + 2 lines, X + 2
        tya
        clc
        adc dst
        sta dst
        bcc :+
        inc dst+1
:       tya
        asl                        ; (C = 0 from the asl: lines < 128)
        adc src
        sta src
        bcc :+
        inc src+1
:       inc bk_x                   ; X + 2: X is even (8x + an even dx), so the one
        inc bk_x                   ;  test catches the wrap
        bne :+
        inc bk_x+1
:       dec bk_col
        beq :+
        jmp @col
:       lda PB_LVL                 ; bank 7 back, once (bk_tile pages its own banks
        jmp pgbank                 ;  and leaves bank 7 paged; nothing reads it in
                                   ;  between)

; ----------------------------------------------------------------------------
; bk_tile: the tile at (bk_tx, bk_ty), its column bk_bx, into BK_BG from line X
;   In:    X = the line in BK_BG; bk_tx, bk_ty, bk_bx, bk_lines, bk_skip; the
;          shape (sv_*), bk_fp (the flats' pairs); the level's file in main RAM
;   Out:   X = the next line (16 on, or fewer: up to bk_lines); bk_skip cleared
;          once a column; bank 7 paged
;   Uses:  A X Y, ent, cnt, bk_line, bk_t, bk_mt, bk_mb, bk_step, bk_pa, bk_pb
; The map byte: MAP5 + (ty << lw) + tx, read with bank 5 paged.  A tile's two
; char rows are each a stored row (mode 0: eight bytes at (ent), the bottom's
; bk_step on) or a fill pair (mode 1: bk_pa, bk_pb alternating), as the gather
; decides: the solid (id 0), both the pair, sv_solid twice; a flat (from FLAT0),
; its pair from the level's file; a half (from half0), its stored row at the
; halves' page + k * HALFBYTES (k = id - half0 + HALFOFF) and its pair from the
; palette by its colour (the HPAIR section's low bits, HPAIR_LEN + i on), the
; fill row by the id's range -- below half1 the top, below half2 the bottom,
; from half2 neither: the row twice (bk_step = 0); a full tile, both rows from
; its slot in TILES; with TILEMIRROR a mirrored one (from mir0), its source's
; (MIRTAB, in the level's file) column 3 - c with each byte's pixels swapped
; (mode $80).
; ----------------------------------------------------------------------------
bk_tile:
        lda #0                     ; the map: MAP5 + (ty << lw) + tx, in bank 5
        sta ent+1
        lda bk_ty                  ; (the low byte shifted in A)
        ldy bk_lw
        beq @row0
@shift: asl
        rol ent+1
        dey
        bne @shift
@row0:  clc
        adc bk_tx
        sta ent
        lda ent+1
        adc #>MAP5
        sta ent+1
        .assert <MAP5 = 0, error, "bk_tile: MAP5's low byte"
        stx bk_line
        lda PB_MAP
        jsr pgbank
        lda (ent),y                ; (Y = 0: the shift loop's, pgbank keeps it)
        sta bk_t
        lda PB_TILES               ; the tiles: bank 6
        jsr pgbank
        lda #1                     ; the modes: 1 = the fill pair (bk_pa, bk_pb), 0
        sta bk_mt                  ;  = the stored row at (ent), for the top char
        sta bk_mb                  ;  row and the bottom; bk_step the bottom row's
        sty bk_step                ;  offset from the top's (Y = 0)
        lda sv_solid               ; ---- 0: the solid (its pair set for every tile:
        sta bk_pa                  ;  a flat or a half writes its own over it, a
        sta bk_pb                  ;  full tile reads neither)
        lda bk_t
        beq @emitj
        cmp #FLAT0
        bcc @notflat
        sbc #FLAT0                 ; ---- a flat: its pair (C = 1), in the level's
        asl                        ;  file
        adc bk_fp                  ; (C = 0)
        sta cnt
        lda bk_fp+1
        adc #0
        sta cnt+1
        jsr @pair
@emitj: jmp @emit
@notflat:
    .if TILEMIRROR
        ; ---- a mirrored full tile (from mir0): its source's id from MIRTAB,
        ;      drawn as that full tile's column 3 - c, each byte's pixels swapped
        ;      (mode $80)
        ldx bk_bx                  ; (a plain full tile: its own column, its rows
        ldy #0                     ;  stored)
        cmp sv_mir0
        bcc @plain
        sbc sv_mir0                ; (C = 1) the source, MIRTAB[id - mir0]
        clc
        adc bk_mp
        sta cnt
        lda bk_mp+1
        adc #0
        sta cnt+1
        ldy #0
        lda (cnt),y
        pha
        lda bk_bx
        eor #(TILECHARS-1)*CHARBYTES   ; (0, 8, 16, 24: 24 less it)
        tax
        ldy #$80
        pla
@plain: stx bk_cx
        sty bk_md
    .endif
        cmp sv_half0
        bcs @half
        clc                        ; ---- a full tile: TILES + (id + TOFF) *
        adc #TOFF                  ;  TILEBYTES + byte * 8
        sta ent
        lda #0
        sta ent+1
        ldy #TILESHIFT
:       asl ent
        rol ent+1
        dey
        bne :-
        lda ent
    .if TILEMIRROR
        ora bk_cx
    .else
        ora bk_bx
    .endif
        sta ent
        lda ent+1
        clc
        adc #>TILES
        sta ent+1
        .assert <TILES = 0, error, "bk_tile: TILES's low byte"
    .if TILEMIRROR
        lda bk_md                  ; both rows stored: 0, or $80 swapped
        sta bk_mt
        sta bk_mb
    .else
        sty bk_mt                  ; (Y = 0) both rows stored
        sty bk_mb
    .endif
        lda #HALFBYTES             ; the bottom char row, HALFBYTES on
        sta bk_step
        bne @emit                  ; (always)
@half:  sbc sv_half0               ; ---- a half (C = 1: the bcs): k = id - half0 +
        pha                        ;  HALFOFF; its row at the halves' page + k *
        clc                        ;  HALFBYTES (+ byte * 8), its pair the
        adc sv_halfoff             ;  palette's by its colour (i = id - half0, kept)
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
        clc                        ;  (the staged file's: after the palette)
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
        lda (cnt),y
        sta bk_pb
        lda bk_t                   ; below half1 the top row fills, below half2 the
        cmp sv_half1               ;  bottom, from it neither (the row twice)
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
        ; ---- the two char rows
@emit:  ldx bk_line
        lda bk_skip                ; a kind that starts at the first tile row's
        beq @top                   ;  bottom char row: just that, once a column
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

; ----------------------------------------------------------------------------
; bk_row: eight lines of a char row into BK_BG from line X
;   In:    A = 0 the stored row at (ent), 1 the fill pair (bk_pa, bk_pb); X =
;          the line; bk_lines
;   Out:   X = the next line; C = 1 if bk_lines is reached (the column is done)
;   Uses:  A X Y
; ----------------------------------------------------------------------------
bk_row: tay                        ; Y = 0 for the row (its byte), 1 for the pair
    .if TILEMIRROR
        bmi @swap                  ; ($80: the row, each byte's pixels swapped)
    .endif
        bne @pair                  ;  (which counts its four pairs from 1)
@row:   lda (ent),y
        sta BK_BG,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #CHARLINES
        bcc @row
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
    .if TILEMIRROR
@swap:  ldy #0                     ; a mirror's row: each byte's two game pixels
@sw:    lda (ent),y                ;  swapped, ((b & $33) << 2) | ((b & $CC) >> 2),
        lsr                        ;  as a delta swap (tiles.s @mir)
        lsr
        eor (ent),y
        and #$33
        sta tmp
        asl
        asl
        eor tmp
        eor (ent),y
        sta BK_BG,x
        inx
        cpx bk_lines
        bcs @out
        iny
        cpy #CHARLINES
        bcc @sw
        clc
        rts
    .endif
  .endif

; ----------------------------------------------------------------------------
; section: src = the start of section A of the level's file, in the stage
;   In:    A = the section (SEC_, under 128); the file at STAGE_LVL (a page: its
;          table's offsets are from its start, two bytes a section)
;   Out:   src; Y = 2 * A
;   Uses:  A Y
;   Keeps: X
; ----------------------------------------------------------------------------
section:
        asl                        ; (C = 0: A < 128)
        tay
        lda STAGE_LVL,y
        sta src
        lda STAGE_LVL+1,y
        adc #>STAGE_LVL
        sta src+1
        rts

; ----------------------------------------------------------------------------
; copy256: 256 bytes from src to dst, in bank 7
;   In:    X = 0 (bcopy's exit: lv_load's one call follows lvsec); src, dst
;   Out:   bcopy's
;   Uses:  A X Y, cnt, tmp2
; ----------------------------------------------------------------------------
copy256:
        stx cnt
        inx
        stx cnt+1
        ldx PB_LVL
        jmp bcopy

; ----------------------------------------------------------------------------
; stage: file A to STAGE (the Master: into shadow RAM)
;   In:    A = the file number
;   Out:   read_page's; dst untouched (every caller sets it afterwards)
;   Uses:  A X Y, tmp
; ----------------------------------------------------------------------------
stage:  ldx #>STAGE
  .if BHW                          ; hardware: the Master's stage is shadow RAM
        jmp read_page
  .else
        pha
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

; ----------------------------------------------------------------------------
; img_ent: ent = img_tab + item * IMGTAB_LEN
;   In:    A = item, Y = 0 (place_walk's @pl, the one caller)
;   Out:   ent
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
img_ent:
        .assert IMGTAB_LEN = 5, error, "img_ent: item * 4 + item"
        sty ent+1
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

; ----------------------------------------------------------------------------
; src_cnt: an image's place in the stage and its length, from its img_tab entry
;   In:    ent, Y = 1 (the entry's offset lo, hi, length lo, hi follow its file)
;   Out:   src = STAGE + the offset, cnt = the length; Y = 4
;   Uses:  A Y
;   Keeps: X
; ----------------------------------------------------------------------------
src_cnt:
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

; ----------------------------------------------------------------------------
; unrle: the map, run-length coded at src, to dst in bank 5, up to page map_end
;   In:    src (the SEC_MAP section), dst = MAP5, map_end (the stream is not
;          terminated: the next section follows it)
;   Out:   the map unpacked; src past it, dst+1 = map_end; bank 7 paged
;   Uses:  A X Y, src, dst, tmp2
; The code (levelfile.py): a control byte c below RLE_LIT_MAX means c + 1
; literal bytes follow; else the next byte is repeated c - RLE_RUNBASE times
; (2..129).
; ----------------------------------------------------------------------------
unrle:  lda PB_MAP
        jsr pgbank
@c:     lda dst+1
        cmp map_end
        bcs @end
        ldy #0
        jsr @next                  ; A = the control byte
        tax                        ; X = c: c + 1 literals, the loop running X + 1
        .assert RLE_LIT_MAX = $80, error, "unrle: a run is a control byte with bit 7 set"
        bpl @rd                    ;  times (C = 0 from the bcs: literals)
        sbc #RLE_RUNBASE           ; c - 127 (C = 0): c - 126 copies of one byte
        tax                        ;  (C = 1 now: a run)
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
; ----------------------------------------------------------------------------
; image_load: an image of bank 7 -- the game's or the menus' -- staged, copied
; to its place below the kernel, and its bank numbers and write-bank stores
; made what the boot loader makes BANKS's (loader.s), from the image's own
; lists (img7fix.inc: build.sh); the game's variables zeroed and its bar
; template read
;   In:    X = IMG_GAME or IMG_MENU
;   Out:   the image in bank 7, patched; the game's: GAME_BSS zeroed to its last
;          byte and the bar's template at BARADDR; bank 7 paged and its write
;          bank
;   Uses:  everything
; The game's variables (GAME_BSS: GAMEBSS then ENGBSS, from a page) are zeroed
; because the menus' image was there: the game starts the same every time.  The
; bar's template goes straight into place: the bar's rows are outside every
; stage, so the menus and a level load leave them alone.
; ----------------------------------------------------------------------------
image_load:
  .if .not BHW                     ; hardware: shadow RAM
        jsr main_ram
  .endif
        stx item
        lda img_file,x
        jsr stage
        setw src, STAGE
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
        jsr sccopy                 ; (bank 7 paged after, and its write bank)
        ; ---- the bank numbers: each byte on the list, 4..7, becomes that
        ;      bank's socket.  A list: (address lo, hi) pairs, a 0 high byte its
        ;      end
        ldx item
        lda bflo,x
        sta lp
        lda bfhi,x
        sta lp+1
        bne @bf                    ; (always: the list's page is not 0)
@bfl:   sta dst+1
        lda (dst),y                ; (Y = 0 from @rd)
        tax
        lda PBANK-4,x
        sta (dst),y
@bf:    jsr @rd
        sta dst
        jsr @rd
        bne @bfl
        ; ---- the write-bank stores, on a board: each a `sta $FE30` as
        ;      assembled, a harmless second write of the bank on a plain
        ;      machine.  A list: (address lo, hi, kind), a 0 high byte its end;
        ;      the kind 4..7 a constant bank, WR_INX the bank in X (loader.s
        ;      @wfix does the same)
        lda pboard
        beq @wdone
        ldx item
        lda wrlo,x
        sta lp
        lda wrhi,x
        sta lp+1
@wr:    jsr @rd
        sta dst
        jsr @rd
        beq @wdone
        sta dst+1
        jsr @rd                    ; the kind, in A and X
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
@wsol:  lda #<WRSEL_SOLIDISK       ; Solidisk: sta $FE60 (the bank is in A there)
        iny                        ; (Y = 0 from @rd: 1)
        sta (dst),y
        lda #>WRSEL_SOLIDISK
@wst:   iny
        sta (dst),y
        bne @wr                    ; (always: Y = 2)
@rd:    ldy #0                     ; the list's next byte -> A and X (flags on it),
        lda (lp),y                 ;  Y = 0
        inc lp
        bne @rd1
        inc lp+1
@rd1:   tax
        rts
        ; ---- the game's: its variables, the bar's template
@wdone: ldy item
        .assert IMG_GAME = 0, error, "image_load: the game's image is 0"
        bne @done
        sty dst                    ; (Y = 0)
        lda #>GAME_BSS
        sta dst+1
        ldx #GAME_BSS_PAGES        ; the whole pages (at least one: build.sh)
        tya
@z:     sta (dst),y                ; (bank 7 paged, and its write bank: bcopy's
        iny                        ;  pgbank)
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
        ldx #>BARADDR              ; the bar's template: read_page takes the page in
        lda #FI_BAR                ;  X
        jmp read_page
@done:  rts

; ---------------------------------------------------------------- the tables
; image_load's, by image (IMG_GAME, IMG_MENU): the file, where the image goes
; and its length (defs_ld.inc), its two patch lists (img7fix.inc: bf_game,
; bf_menu, wr_game, wr_menu)
img_file:   .byte FI_GAME, FI_MENU
img_alo:    .byte <GAME_ADDR, <MENU_ADDR
img_ahi:    .byte >GAME_ADDR, >MENU_ADDR
img_nlo:    .byte <GAME_LEN, <MENU_LEN
img_nhi:    .byte >GAME_LEN, >MENU_LEN
bflo:       .byte <bf_game, <bf_menu
bfhi:       .byte >bf_game, >bf_menu
wrlo:       .byte <wr_game, <wr_menu
wrhi:       .byte >wr_game, >wr_menu
        .include "img7fix.inc"
; the packer's (tools/assets.py): bake_kind, by baked slot, its kind; bake_geom,
; by kind, BG_LEN bytes -- columns, lines, dx (16 bits), dty, the overlay's
; offset (16 bits), skip; img_tab, by item, its file, offset and length
; (IMGTAB_LEN bytes)
  .ifdef BAKEITEM0
bake_kind:  .incbin "bake_kind.bin"
bake_geom:  .incbin "bake_geom.bin"
  .endif
img_tab:    .incbin "img_tab.bin"

; ---------------------------------------------------------------- the game's part
; ----------------------------------------------------------------------------
; ld_game (GAMELDINIT): the game's own level start, its ldgame.s (the game's
; include directory: build.sh adds it), in segment LDGAME after this program's
; code (ldprog.cfg).  It runs once a level load, after lv_load and before
; ld_resume -- what a game would otherwise do in bank 7 right after
; load_level_b, done here so that the code is not in bank 7.
;   In:    lv_load's Out: the level in the banks -- LV_HDR (and the header's
;          tail) in bank 7, the objects at LV_OBJS (main RAM), the map in bank 5;
;          bank 7 paged and its write bank (stores to bank 7 land on either
;          machine and on a Model B's write-select board); the Master: ACCCON X
;          clear, Y as the game runs (GAMEHAZEL: set, so HAZEL's variables are
;          in reach); the stage is not (the Master cleared it)
;   Out:   bank 7 paged and its write bank, as on entry (bcopy and pgbank leave
;          it so: another bank is paged through them, never by hand)
;   Uses:  A X Y; this program's zero page (LDZP: src dst cnt ...) and its
;          helpers (bcopy, pgbank, the PB_ sockets) as ::src, ::bcopy ...; the
;          game's own zero page and variables -- whatever its level start would
;          write.  Nothing else of the engine's but what the game's code may
;          touch: the game's image is in bank 7, and its code is callable
;   Pre:   interrupts off, the chain parked (a load)
; The game's symbols: build.sh writes gamesyms.inc from the game's link (every
; global label and constant of its debug file), included here inside the scope
; ldg with the game's code, so the game's names (the engine's zero page cnt,
; tmp, ... among them) win over this program's inside it; this program's are
; reached with the global scope's ::.
; ----------------------------------------------------------------------------
  .if GAMELDINIT
        .segment "LDGAME"
        .scope ldg
        .include "gamesyms.inc"    ; the game's names (build.sh)
        .include "ldgame.s"        ; the game's code: ld_game, then what it wants
        .endscope
ld_game = ldg::ld_game
  .endif

; ---- the layout
        .assert LDPROG = __LD_START__, error, "LDPROG (defs.inc) is where ldprog.cfg links this program"
        .assert <STAGE_LVL = 0, error, "section: STAGE_LVL page-aligned"
        .assert <BARADDR = 0 && <STAGE = 0 && <GAME_BSS = 0, error, "image_load: page-aligned"
        .assert IMG_MENU = 1, error, "image_load's tables: the game's, then the menus'"
  .if SPRXKEEP
        .assert SPRX_PAGES <= HAZEL_PAGES + ANDY_PAGES, error, "SPRX outgrows HAZEL and ANDY (12K)"
  .endif
