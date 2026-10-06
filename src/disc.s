; ============================================================================
; disc.s -- the disc from the game's side.  The MOS is gone, so bank 7's kernel
; reads sectors with a driver of its own: the Model B's 8271 or Acorn 1770
; board, the Master's 1770 (the controllers' addresses are defs.inc's FDC*; the
; commands and status bits hw.inc's).  Both machines.
;
; Segments: KRNBSS (a read's parameters), KRNCODE (read_sectors and the loads'
; entries), BOOT (disc_init, start-up only) and the driver slot's six --
; D8271H/N/C and D1770H/N/C -- the two drivers assembled for the same place at
; the top of the kernel (the cfgs' DRV8271 and DRV1770 overlap; build.sh sets
; where), of which the boot loader copies in the machine's alone (BANKS flags
; each by its controller: loader.s), so the kernel pays for one driver, the
; larger.
;
; The controllers raise an NMI for every byte, so each driver's transfer stub
; runs in main RAM at NMIPAGE ($0D00), reached whatever bank is paged.  On the
; Model B that page is display RAM, free because every load runs with the
; palette black (game.s level_loop and menu.s blank it before load_level_b and
; go_game).  The loads themselves are LDPROG's (ldprog.s), which ld_go reads to
; LDPROG and runs.
;
; Exports: load_level_b (X = a level), go_title, go_game, go_menu (A for the
; menus), the game's and start-up's ways to a load; read_sectors (LDPROG's too);
; disc_init (init.s); game_in (a label for the test harness); drv_type,
; drv_unit, ld_sec, ld_n, ld_dst (init.s boot fills the first five bytes from
; the loader's header), ld_img and ld_open (ldprog.s; the headless harness reads
; ld_img).
; ============================================================================
        .include "files.inc"       ; the disc's sector table (one disc, both machines)
  .if BHW                          ; hardware and the Master's placements: each
F_LDPROG_SEC = F_LDPROGB_SEC       ;  machine has its own load-time program
F_LDPROG_N   = F_LDPROGB_N
  .else
F_LDPROG_SEC = F_LDPROGM_SEC
F_LDPROG_N   = F_LDPROGM_N
  .endif

        .segment "KRNBSS"
drv_type: .res 1                   ; 0 = an 8271, 1 = a 1770 (the boot loader's finding,
drv_unit: .res 1                   ;  copied here by init.s) and the drive, 0 or 1
ld_sec:   .res 2                   ; read_sectors: the first sector, how many, where to
ld_n:     .res 1
ld_dst:   .res 2
ld_trk:   .res 1                   ; the current track's run: track, first sector, count
ld_sc:    .res 1
ld_cnt:   .res 1
ld_img:   .res 1                   ; the image in bank 7, IMG_GAME or IMG_MENU (ldprog.s
                                   ;  ld_image writes it; test/hbeebem reads it)
ld_open:  .res 1                   ; the disc is still open after go_game's image load:
                                   ;  the first level's load goes straight in (ld_on);
                                   ;  ldprog.s ld_resume clears it at every load's end
w_trk:    .res 1                   ; the 1770's head, as far as its driver knows

; ---------------------------------------------------------------- the driver slot
; A driver in the slot:
;   +0  jmp to its track read: ld_cnt sectors of track ld_trk from sector ld_sc
;       to ld_dst; C = 1 asks for the run again
;   +3  the length of its NMI stub
;   +4  the stub, which ld_go copies to NMIPAGE (the NMI lands at $0D00 itself,
;       so the stub starts there: nothing in front of it)
; The stub's state sits in the NMI page's last three bytes, the same for both.
        .import __DRV8271_START__: absolute, __DRV1770_START__: absolute
        .import __NMI8271_SIZE__: absolute, __NMI1770_SIZE__: absolute
DRVSLOT    = __DRV8271_START__
DRV_TRACK  = DRVSLOT
DRV_NMILEN = DRVSLOT + 3
DRV_NMI    = DRVSLOT + 4
NMISTUB_MAX = $FD                  ; a stub's room: the page less its three state bytes
LD_RES     = NMIPAGE + NMISTUB_MAX ; the 8271's result
LD_DONE    = LD_RES + 1            ; the command is over (both stubs count it up)
LD_SECS    = LD_RES + 2            ; the 1770's sectors to go

; ----------------------------------------------------------------------------
; read_sectors: ld_n sectors from sector ld_sec (16 bits) to ld_dst, in main RAM
;   In:    ld_sec, ld_n (1..255), ld_dst (a page: its low byte is 0, ld_go's,
;          and nothing writes it)
;   Out:   ld_dst past the data; ld_n = 0; ld_trk, ld_sc, ld_cnt the last run's
;   Uses:  A X Y
;   Pre:   interrupts off, the driver's stub at NMIPAGE (ld_go); bank 7 paged
; The disc is NTRACKS tracks of SECTRK sectors of 256 bytes.  Sector / SECTRK by
; repeated subtraction over the 16-bit number: Y holds the high byte + 1 and
; comes down at each borrow, so the loop ends on the borrow below zero; X counts
; the subtractions, less that last one, which is the track; the final adc puts
; the SECTRK back for the remainder.  Each track's run is the driver's
; (DRV_TRACK), min(ld_n, SECTRK - sector) sectors.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
read_sectors:
        ldx #<-1                   ; X = -1: the first inx makes it track 0
        lda ld_sec
        ldy ld_sec+1
        iny
@div:   inx
        sec
        sbc #SECTRK
        bcs @div
        dey
        bne @div
        adc #SECTRK                ; C = 0: the remainder (and C = 1 out: the add
        stx ld_trk                 ;  wraps), the first sector
        sta ld_sc
@track: lda #SECTRK                ; this track's run: min(ld_n, SECTRK - sector)
        sbc ld_sc                  ; (C = 1: the adc above, a retry's bcs, or the
        cmp ld_n                   ;  sbc ld_cnt below)
        bcc @run
        lda ld_n
@run:   sta ld_cnt
        jsr DRV_TRACK
        bcs @track                 ; the 8271 asks for the run again
        lda ld_dst+1               ; (C = 0) whole sectors on: a page each
        adc ld_cnt
        sta ld_dst+1
        lda ld_n
        sec
        sbc ld_cnt
        sta ld_n
        beq @done
        lda #0                     ; the next track, from its first sector
        sta ld_sc
        inc ld_trk
        bne @track                 ; (always: a track below NTRACKS, plus one)
@done:  rts

; ---------------------------------------------------------------- the 8271
; The header: the track read, then the stub's length
        .segment "D8271H"
        jmp r8271
        .byte n8271_end - n8271

; ----------------------------------------------------------------------------
; n8271: the 8271's NMI -- a byte to the transfer address, or the command's end
;   In:    FDC8271_CMD (the status) bit 2, I8271_ST_IRQ: a byte waits in
;          FDC8271_DAT; clear: the command has ended, its result in FDC8271_PAR
;   Out:   the byte stored and n8271_sta's operand stepped; or LD_RES = the
;          result (reading it clears the interrupt) and LD_DONE stepped, for
;          r8271
;   Uses:  none (A through the stack)
; Runs at NMIPAGE: the labels are run addresses there.  r8271 patches the store.
; ----------------------------------------------------------------------------
        .segment "D8271N"
n8271:  pha
        lda FDC8271_CMD
        and #I8271_ST_IRQ
        beq n8271_x
        lda FDC8271_DAT
n8271_sta:
        sta $FFFF                  ; (the operand: r8271's)
        inc n8271_sta+1
        bne @skip
        inc n8271_sta+2
@skip:  pla
        rti
n8271_x: lda FDC8271_PAR
        sta LD_RES
        inc LD_DONE
        pla
        rti
n8271_end:
        .assert n8271_end - n8271 <= NMISTUB_MAX, error, "the 8271's stub runs into its state bytes"

; ----------------------------------------------------------------------------
; r8271: the 8271's track read -- ld_cnt sectors of track ld_trk from sector
; ld_sc
;   In:    ld_trk, ld_sc, ld_cnt, ld_dst; drv_unit (0 or 1)
;   Out:   C = 1 if the result was not 0: read_sectors runs the track again
;   Uses:  A X Y, LD_DONE, LD_RES
;   Pre:   the stub at NMIPAGE; interrupts off
; Before every run the drive is selected and its head loaded through special
; register $23 (the drive control output), then a read drive status is done and
; its result thrown away.  Both are for a drive whose motor has stopped since
; the last read: its read fails at once as "not ready", and the chip keeps
; reporting that until a read drive status; the failed run is asked for again (C
; = 1), by then with the motor up.  Read data: 256-byte sectors, several in one
; command.
; ----------------------------------------------------------------------------
        .segment "D8271C"
r8271:  lda ld_dst                 ; the transfer address, into the stub
        sta n8271_sta+1
        lda ld_dst+1
        sta n8271_sta+2
        jsr i_idle
        lda #I8271_DRV0            ; bits 7, 6 select the drive: $40 drive 0, $80
        ldx drv_unit               ;  drive 1
        beq @drv0
        asl
@drv0:  tax                        ; X = the drive's bits (the helpers keep X)
        ora #I8271_CMD_WRSPEC      ; write special register
        sta FDC8271_CMD
        lda #I8271_SR_DCOR
        jsr i_param
        txa
        ora #I8271_LOADHEAD        ; select + load head
        jsr i_param
        jsr i_idle
        txa
        ora #I8271_CMD_RDSTAT      ; read drive status: immediate, no interrupt --
        sta FDC8271_CMD            ;  its result is read to clear it
        jsr i_idle
        lda FDC8271_PAR
        lda #0
        sta LD_DONE                ; (the stub's flag, down before the command)
        txa
        ora #I8271_CMD_READ        ; read data: track, sector, count | sector size
        sta FDC8271_CMD
        lda ld_trk
        jsr i_param
        lda ld_sc
        jsr i_param
        lda ld_cnt
        ora #I8271_SEC256
        jsr i_param
@loop:  lda LD_DONE                ; the stub's completion
        beq @loop
        lda LD_RES
        and #I8271_RES_MASK        ; the completion code: C = 1 unless 0
        cmp #1
        rts

; ----------------------------------------------------------------------------
; i_idle: wait until the 8271 takes a command
;   In:    FDC8271_CMD bit 7, I8271_ST_BUSY
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
i_idle: lda FDC8271_CMD
        bmi i_idle
        rts

; ----------------------------------------------------------------------------
; i_param: give the 8271 a parameter once its register is free
;   In:    A = the parameter
;   Uses:  A Y (Y = the parameter: no caller needs it)
;   Keeps: X
; ----------------------------------------------------------------------------
i_param:
        tay
@loop:  lda FDC8271_CMD
        and #I8271_ST_PARFULL
        bne @loop
        sty FDC8271_PAR
        rts

; ---------------------------------------------------------------- the 1770
        .segment "D1770H"
        jmp r1770
        .byte n1770_end - n1770

; ----------------------------------------------------------------------------
; n1770: the 1770's NMI -- a byte to the transfer address, or the command's end
;   In:    FDC1770_CMD (the status): DRQ with busy, a byte waits in FDC1770_DAT;
;          busy clear, the command has ended; busy alone, nothing (ignored)
;   Out:   the byte stored, n1770_sta's operand stepped; at a sector's end
;          LD_SECS down, and at the last one a force interrupt stops the
;          multi-sector read and LD_DONE is stepped; LD_DONE stepped too when
;          busy has dropped
;   Uses:  none (A through the stack)
; Runs at NMIPAGE: the labels are run addresses there.  r1770 patches the store.
; ----------------------------------------------------------------------------
        .segment "D1770N"
n1770:  pha
        lda FDC1770_CMD
        and #WD_ST_DRQ|WD_ST_BUSY
        cmp #WD_ST_DRQ|WD_ST_BUSY
        bne n1770_x
        lda FDC1770_DAT
n1770_sta:
        sta $FFFF                  ; (the operand: r1770's)
        inc n1770_sta+1
        bne @skip
        inc n1770_sta+2            ; a page on: a whole sector done
        dec LD_SECS
        bne @skip
        lda #WD_CMD_FORCEINT       ; the last: stop the read
        sta FDC1770_CMD
        inc LD_DONE
@skip:  pla
        rti
n1770_x: and #WD_ST_BUSY
        bne @skip
        inc LD_DONE
@skip:  pla
        rti
n1770_end:
        .assert n1770_end - n1770 <= NMISTUB_MAX, error, "the 1770's stub runs into its state bytes"

; ----------------------------------------------------------------------------
; r1770: the 1770's track read -- ld_cnt sectors of track ld_trk from sector
; ld_sc
;   In:    ld_trk, ld_sc, ld_cnt, ld_dst; w_trk = where the head is
;   Out:   C = 0 always (w_wait's exit): no retry
;   Uses:  A X, LD_DONE, LD_SECS; w_trk = ld_trk
;   Pre:   the stub at NMIPAGE; interrupts off; the drive selected (disc_init)
; A seek first if the head is elsewhere, then read multiple with a head settle;
; the stub ends the read at the last sector.  A command's busy takes a moment to
; show, so each wait starts with WD_SETTLE turns of a delay loop.
; ----------------------------------------------------------------------------
        .segment "D1770C"
r1770:  lda ld_dst                 ; the transfer address, into the stub
        sta n1770_sta+1
        lda ld_dst+1
        sta n1770_sta+2
        lda #0
        sta LD_DONE
        lda ld_trk
        cmp w_trk
        beq @read
        sta w_trk
        sta FDC1770_DAT
        lda #WD_CMD_SEEK           ; seek, no verify
        sta FDC1770_CMD
        jsr w_wait
@read:  lda ld_sc
        sta FDC1770_SEC
        lda ld_cnt
        sta LD_SECS
        lda #WD_CMD_READM          ; read multiple with a head settle
        sta FDC1770_CMD
        ldx #WD_SETTLE
@loop:  dex
        bne @loop
@loop2: lda LD_DONE
        bne w_wait                 ; done: the force interrupt's busy drops shortly
        lda FDC1770_CMD            ; or the command ended with no completion NMI:
        lsr                        ;  busy (bit 0) into C
        bcs @loop2

; ----------------------------------------------------------------------------
; w_wait: WD_SETTLE turns of a delay, then wait until the 1770 is not busy
;   Out:   C = 0 (busy, bit 0, shifted into C), X = 0
;   Uses:  A X
;   Keeps: Y
; ----------------------------------------------------------------------------
w_wait: ldx #WD_SETTLE
@loop:  dex
        bne @loop
@loop2: lda FDC1770_CMD
        lsr
        .assert WD_ST_BUSY = 1, error, "w_wait shifts the busy bit into C"
        bcs @loop2
        rts

; ----------------------------------------------------------------------------
; disc_init: a 1770 reset and its head found, once, at start-up (init.s boot)
;   In:    drv_type, drv_unit
;   Out:   w_trk = 0 (the head on track 0); the drive selected in the control
;          latch
;   Uses:  A X
; An 8271 needs nothing: DFS left it set up.  The latch is written twice: reset
; held, then the drive (and side) with the reset released, FM; the nop keeps the
; two apart.
; ----------------------------------------------------------------------------
        .segment "BOOT"
disc_init:
        lda drv_type
        beq @done
        lda #FDC_RESET
        sta FDC1770_CTL
        ldx drv_unit
        lda @drvsel,x
        sta FDC1770_CTL
        nop
        lda #WD_CMD_RESTORE        ; restore: the head to track 0
        sta FDC1770_CMD
        jsr w_wait
        stx w_trk                  ; (X = 0: w_wait's)
@done:  rts
@drvsel: .byte FDC_DRV0, FDC_DRV1, FDC_DRV0|FDC_SIDE1, FDC_DRV1|FDC_SIDE1

; ----------------------------------------------------------------------------
; load_level_b, go_title, go_game, go_menu: a load through LDPROG, the load-time
; program (ldprog.s) -- a level into the banks, or an image into bank 7
;   In:    load_level_b: X = the level, 0..15; go_menu: A for hook_over (0 lost,
;          1 won); go_title, go_game: nothing
;   Out:   load_level_b returns with the level in the banks and the chain
;          resumed (ldprog.s ld_resume).  The others do not return: LDPROG goes
;          on to the image's hook with the stack reset -- go_title to
;          hook_title, go_game to hook_image then hook_play (through game_in,
;          with ld_open set: its first level load goes straight in), go_menu to
;          hook_over
;   Uses:  A X Y, the ld_* parameters; A and X reach LDPROG as given
;   Pre:   bank 7 paged; the palette black; interrupts on, unless ld_open (then
;          the chain is parked already and nothing here runs but ld_on)
;   Post:  interrupts off into LDPROG (ld_resume turns them on again)
; ld_go: the tune off, the chain parked in a standard frame (kernel.s
; load_begin: the interrupt does it at a frame boundary, so interrupts must be
; on), the driver's NMI stub to its page, LDPROG to LDPROG, then into it.  Each
; entry's ldx is skipped by the entry before through a `bit abs` (OP_BIT_ABS)
; whose operand bytes are that ldx: a read of sideways memory ($80A2..$83A2), no
; side effect.
; ----------------------------------------------------------------------------
        .segment "KRNCODE"
load_level_b:
        ldy ld_open
        bne ld_on                  ; straight on from go_game's image load
        .byte OP_BIT_ABS           ; (bit abs: the ldx skipped, X kept: the level)
go_title:
        ldx #LDOP_TITLE
        .byte OP_BIT_ABS
go_game:
        ldx #LDOP_GAME
        .byte OP_BIT_ABS
go_menu:
        ldx #LDOP_OVER
ld_go:  pha                        ; A and X across the load, on the stack
        txa
        pha
        jsr music_stop
        jsr load_begin
        sei
        ldx DRV_NMILEN             ; the driver's NMI stub to its page
@loop:  lda DRV_NMI-1,x
        sta NMIPAGE-1,x
        dex
        bne @loop
        lda #<F_LDPROG_SEC         ; and LDPROG to its place
        sta ld_sec
        lda #F_LDPROG_N
        sta ld_n
        lda #>LDPROG
        sta ld_dst+1
        stx ld_sec+1               ; (X = 0: >F_LDPROG_SEC and <LDPROG)
        stx ld_dst
        .assert >F_LDPROG_SEC = 0 && <LDPROG = 0, error, "ld_go: a zero assumed"
        jsr read_sectors
        pla
        tax
        pla
ld_on:  jmp LDPROG                 ; ld_entry: a level returns, an image goes on

; ----------------------------------------------------------------------------
; game_in: LDPROG's way to hook_play -- a label for the test harness: the game's
; image is in, its entry not yet run
; ----------------------------------------------------------------------------
game_in:
        jmp hook_play

; ---- the layout: one slot for both drivers; the stubs' state at the page's end
        .assert __DRV1770_START__ = DRVSLOT, error, "the drivers share one slot"
        .assert NMISTUB_MAX = __NMI8271_SIZE__ && NMISTUB_MAX = __NMI1770_SIZE__, error, "NMI8271/NMI1770 end at the state bytes"
