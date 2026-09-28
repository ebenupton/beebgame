; ============================================================================
; The disc, from the game's side: bank 7.  The MOS is gone, so this is its own
; driver -- for the Model B's 8271 or Acorn 1770 board, and the Master's 1770 --
; and the loader that gathers a level into the banks runs in main RAM, where it can
; page banks freely (ldprog.s).  The controllers raise NMI for every byte, so the
; transfer routine sits in main RAM at NMIPAGE, right whatever bank is paged (on the
; Model B that is display RAM, free while the palette is black).  The boot loader
; (loader.s) says which controller and which drive (drv_type, drv_unit).
; ============================================================================
        .include "files.inc"        ; the disc's sector table (one disc, both machines)
  .if BHW                           ; this machine's load-time program
F_LDPROG_SEC = F_LDPROGB_SEC
F_LDPROG_N   = F_LDPROGB_N
  .else
F_LDPROG_SEC = F_LDPROGM_SEC
F_LDPROG_N   = F_LDPROGM_N
  .endif
        .segment "KRNBSS"
drv_type: .res 1                    ; 0 = 8271, 1 = 1770 (loader.s decides at boot: init.s
drv_unit: .res 1                    ; copies them here) and the drive DFS had current
ld_sec:   .res 2                    ; read_sectors: first sector, count, destination
ld_n:     .res 1
ld_dst:   .res 2
ld_trk:   .res 1
ld_sc:    .res 1
ld_cnt:   .res 1
ld_level: .res 1
ld_img:   .res 1                    ; load_image's image (the test harness reads it too)
ld_arg:   .res 1                    ; go_menu's A across it
ld_open:  .res 1                    ; the disc is still open: go_game's load goes on into
                                    ; the level's (ld_resume clears it: every load ends so)

; ---------------------------------------------------------------- the drivers
; Each controller's driver -- its NMI stub, its track read, its helpers -- is assembled
; for the same place at the top of the kernel, the slot (the cfgs' DRV8271 and DRV1770,
; overlapping: build.sh sets where), and the boot loader copies in only the one the
; machine has (BANKS flags each piece by its controller: loader.s), so the kernel pays
; for one driver, the larger, not both.  A driver in the slot:
;   +0  jmp to its track read: ld_cnt sectors of track ld_trk from sector ld_sc to
;       ld_dst; C = 1 to try the run again
;   +3  the length of its NMI stub, +4 the stub, which disc_boot copies to NMIPAGE (the
;       NMI lands at $0D00, so the stub starts there: no jump in front of it)
; The stub's state beside the kernel's is at the top of the NMI page, the same for both.
        .import __DRV8271_START__: absolute, __DRV1770_START__: absolute
DRVSLOT    = __DRV8271_START__
        .assert __DRV1770_START__ = DRVSLOT, error, "the two drivers must share the slot"
DRV_TRACK  = DRVSLOT
DRV_NMILEN = DRVSLOT + 3
DRV_NMI    = DRVSLOT + 4
LD_RES     = NMIPAGE + $FD            ; the 8271's result
LD_DONE    = NMIPAGE + $FE            ; the command is over
LD_SECS    = NMIPAGE + $FF            ; the 1770's sectors to go

; ---- the 8271
        .segment "D8271H"
        jmp r8271
        .byte n8271_end - n8271
        .segment "D8271N"           ; (runs at NMIPAGE)
n8271:                              ; status bit 2 = a byte is ready, otherwise the
        pha                         ; command has ended
        lda FDC8271_CMD
        and #$04
        beq n8271_x
        lda FDC8271_DAT
n8271_sta:
        sta $FFFF
        inc n8271_sta+1
        bne :+
        inc n8271_sta+2
:       pla
        rti
n8271_x: lda FDC8271_PAR             ; the result (reading it clears the interrupt)
        sta LD_RES
        inc LD_DONE
        pla
        rti
n8271_end:
        .assert n8271_end - n8271 <= $FD, error, "the 8271's stub runs into the page's state"
        .segment "D8271C"
; read data, multi-record, 256-byte sectors -- after two commands DFS also sends.  The
; drive control output (special register $23): select + load head is the motor, which
; the 8271 stops after a few idle index pulses (DFS's specify), and a read on a stopped
; drive is "not ready" ($10) at once, without starting it.  And the 8271 LATCHES not
; ready: only a read drive status clears it, so the retry would fail for ever without
; one (the title's idle stops the motor).
r8271:  lda ld_dst                  ; the transfer address, into the stub
        sta n8271_sta+1
        lda ld_dst+1
        sta n8271_sta+2
        jsr i_idle
        lda #$40                    ; bits 7,6 select the drive: $40 = 0, $80 = 1
        ldx drv_unit
        beq :+
        asl
:       tax                         ; (the helpers keep X)
        ora #$3A                    ; write special register
        sta FDC8271_CMD
        lda #$23
        jsr i_param
        txa
        ora #$08                    ; select + load head
        jsr i_param
        jsr i_idle
        txa
        ora #$2C                    ; read drive status: an immediate command, no
        sta FDC8271_CMD             ; interrupt -- its result (the status) is read to
        jsr i_idle                  ; clear it
        lda FDC8271_PAR
        lda #0
        sta LD_DONE                 ; (and the stub's flag, should a controller interrupt after all)
        txa
        ora #$13                    ; read data
        sta FDC8271_CMD
        lda ld_trk
        jsr i_param
        lda ld_sc
        jsr i_param
        lda ld_cnt
        ora #$20
        jsr i_param
:       lda LD_DONE                 ; the stub's completion flag
        beq :-
        lda LD_RES
        and #$1E
        cmp #1                      ; C = 1: not ready, or a soft error -- the run again
        rts
i_idle: lda FDC8271_CMD             ; the 8271 takes a command when not busy
        bmi i_idle
        rts
i_param:                            ; and a parameter when the register is free
        pha
:       lda FDC8271_CMD
        and #$20
        bne :-
        pla
        sta FDC8271_PAR
        rts

; ---- the 1770
        .segment "D1770H"
        jmp r1770
        .byte n1770_end - n1770
        .segment "D1770N"           ; (runs at NMIPAGE)
n1770:                              ; DRQ with busy = a byte, else the command has
        pha                         ; ended (busy dropped)
        lda FDC1770_CMD
        and #3
        cmp #3
        bne n1770_x
        lda FDC1770_DAT
n1770_sta:
        sta $FFFF
        inc n1770_sta+1
        bne :+
        inc n1770_sta+2
        dec LD_SECS                 ; a whole sector done
        bne :+
        lda #$D0                    ; force interrupt: stop the multi-sector read
        sta FDC1770_CMD
        inc LD_DONE
:       pla
        rti
n1770_x: and #1
        bne :+
        inc LD_DONE
:       pla
        rti
n1770_end:
        .assert n1770_end - n1770 <= $FD, error, "the 1770's stub runs into the page's state"
        .segment "D1770C"
; seek if the head is elsewhere, then read multiple
r1770:  lda ld_dst                  ; the transfer address, into the stub
        sta n1770_sta+1
        lda ld_dst+1
        sta n1770_sta+2
        lda #0
        sta LD_DONE
        lda ld_trk
        cmp w_trk
        beq @rd
        sta w_trk
        sta FDC1770_DAT
        lda #$10                    ; seek, no verify
        sta FDC1770_CMD
        jsr w_wait
@rd:    lda ld_sc
        sta FDC1770_SEC
        lda ld_cnt
        sta LD_SECS
        lda #$94                    ; read multiple with head settle: the stub stops it
        sta FDC1770_CMD
        ldx #20
:       dex
        bne :-
:       lda LD_DONE
        bne w_wait                  ; (the abort takes a moment to clear busy)
        lda FDC1770_CMD             ; fallback: the command ended without a completion NMI
        lsr                         ; busy (bit 0) into C
        bcs :-
w_wait: ldx #20                     ; (and start-up's: init.s disc_init)
:       dex
        bne :-
:       lda FDC1770_CMD
        lsr                         ; busy (bit 0) into C: C = 0 when it returns
        bcs :-
        rts

        .segment "KRNCODE"
; ---------------------------------------------------------------- reading
; ld_sec (16 bit), ld_n sectors -> ld_dst in main RAM.  The disc is 80 tracks of 10
; 256-byte sectors: the division is by repeated subtraction; each track's run is the
; driver's (the slot's DRV_TRACK).
read_sectors:
        ldx #$FF                    ; X = track, Y = high byte + 1: ld_sec / 10
        lda ld_sec
        ldy ld_sec+1
        iny
@d10:   inx
        sec
        sbc #10
        bcs @d10
        dey
        bne @d10
        adc #10                     ; (C clear) the remainder
        stx ld_trk
        sta ld_sc
@track: lda #10                     ; sectors to read on this track: min(n, 10 - s)
        sec
        sbc ld_sc
        cmp ld_n
        bcc :+
        lda ld_n
:       sta ld_cnt
        jsr DRV_TRACK
        bcs @track                  ; (the 8271: the run again)
        lda ld_dst+1
        clc
        adc ld_cnt
        sta ld_dst+1
        lda ld_n
        sec
        sbc ld_cnt
        sta ld_n
        beq @done
        lda #0
        sta ld_sc
        inc ld_trk
        jmp @track
@done:  rts

        .segment "KRNBSS"
w_trk:    .res 1                    ; the 1770's head, as far as its driver knows

; a 1770 is reset and its head found once, at start-up (init.s, main RAM): the 8271
; keeps DFS's state and needs nothing
        .segment "BOOT"
disc_init:
        lda drv_type
        beq @done
        lda #FDC_RESET              ; the latch: reset held
        sta FDC1770_CTL
        ldx drv_unit                ; then the drive (and side), FM, reset released
        lda @drvsel,x
        sta FDC1770_CTL
        nop
        lda #$00                    ; restore: track 0
        sta FDC1770_CMD
        jsr w_wait
        stx w_trk                   ; X = 0: w_wait's delay loop ends there
@done:  rts
@drvsel: .byte FDC_DRV0, FDC_DRV1, FDC_DRV0|FDC_SIDE1, FDC_DRV1|FDC_SIDE1
        .segment "KRNCODE"

; ---------------------------------------------------------------- the loader
; The driver's NMI stub goes to its page and the load-time program to LDPROG, then it runs:
; it comes back with bank 7 paged and the display RAM it used as scratch.
disc_boot:
        ldx DRV_NMILEN              ; the driver's NMI stub to its page (its labels are
:       lda DRV_NMI-1,x             ; its run addresses there)
        sta NMIPAGE-1,x
        dex
        bne :-
        lda #<F_LDPROG_SEC
        sta ld_sec
        lda #F_LDPROG_N
        sta ld_n
        lda #>LDPROG
        sta ld_dst+1
        lda #0                      ; >F_LDPROG_SEC and <LDPROG: both zero
        sta ld_sec+1
        sta ld_dst
        .assert >F_LDPROG_SEC = 0 && <LDPROG = 0, error, "disc_boot: a zero assumed"
        jmp read_sectors

; X = level index 0..15: everything the level needs into the banks (the palette is
; black; the game's load_level goes on from the header afterwards)
load_level_b:
        stx ld_level
        lda ld_open                 ; straight on from go_game's image load: the chain is
        bne @on                     ; parked, LDPROG in place
        jsr music_stop
        jsr load_begin              ; the chain parks the CRTC in a standard frame first
        sei                         ; (engine.s load_begin)
        jsr disc_boot
@on:    ldx ld_level
        jsr LDPROG                  ; lv_load
        jmp ld_resume

; ---------------------------------------------------------------- the images
; Bank 7 below the kernel holds one of two images: the game's (GAME: the logic, the
; renderer's bank 7 half, the game loop) or the menus' (MENU: the menus, the tune,
; the font, the title pieces).  Either comes off the disc over the other, and control
; goes to its entry with the stack as boot left it: nothing the other image called
; is returned to.
go_title:                           ; start-up's way in (init.s): the menus' image
        ldx #IMG_MENU
        jsr load_image
        jsr ld_resume
        jmp hook_title              ; (the game's: README.md)
go_game:                            ; the menus' way out: the game's image (and the bar's
        ldx #IMG_GAME               ; template: ldprog.s), then its level loop, whose level
        jsr load_image              ; load goes straight on (interrupts off till it ends)
        ldx #$3F                    ; (init.s: the stack is 64 bytes)
        txs
        inc ld_open                 ; (0 -> 1: the last load's ld_resume)
        jsr hook_image              ; (the game's: README.md -- Cleo's resets its HUD's cache)
game_in:                            ; (a label for the test harness: the game's image in,
        jmp hook_play               ;  its entry not yet run)
go_menu:                            ; the game's way out, A = 0 lost, 1 won: the menus'
        sta ld_arg                  ; image, then its win/lose screen
        ldx #IMG_MENU
        jsr load_image
        jsr ld_resume
        ldx #$3F
        txs
        lda ld_arg
        jmp hook_over
load_image:                         ; X = IMG_GAME or IMG_MENU
        stx ld_img
        jsr music_stop              ; (the tune's player is the menus')
        jsr load_begin
        sei
        jsr disc_boot
        ldx ld_img
        jmp LDPROG+3                ; image_load (ldprog.s)
ld_resume:                          ; (interrupts still off: a flag raised during the load
        lda #0                      ;  is stale, and load_end clears it before the cli)
        sta ld_open
        jsr load_end
        cli
        rts
