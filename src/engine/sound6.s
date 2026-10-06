; ============================================================================
; engine/sound6.s -- the sound effects player (SOUND6), in bank 6
;
; The game's effects (its GAME_SFX file, packed by tools/sfx.py into sfxdata.inc:
; the format is there) played on the SN76489's four channels, a voice each: the
; vsync calls sfx_tick with bank 6 paged, after the tune's step (low.s irq_vret on
; the Model B, the Master's handler in kernel.s), so the player is there under
; either image of bank 7 and costs bank 7 nothing.  It reads only bank 6, zero page
; and low RAM, and what it keeps is in low RAM (the interrupt stores into no bank:
; vars.s); it writes the chip through snd_write, in low RAM with it (LOWCODE2).
; The game asks for an effect with sfx_request (kernel, resident) and silences
; them all with sound_reset.  (After Elite's Master engine and Exile's: linear
; period sweeps, 2 dB volume steps.)
;
;   sfx_request   ask for an effect (the kernel)
;   sound_reset   every voice idle and silent (the kernel)
;   sfx_tick      the vsync's step: the effects asked for started, every voice
;                 stepped (bank 6)
; ============================================================================

; ---------------------------------------------------------------- what the player keeps
; In low RAM, visible whatever bank is paged: sfx_request writes SFXBITS from bank 7's
; code (or the menus'), the player all of it from bank 6's.  A voice's fields are arrays
; of four, one a field (X = the voice), in FIELDS' order from SV_F (sfx.py).
        .segment "LOWBSS"
SFXBITS:  .res 3                    ; the effects asked for, a bit each (sfx_request)
SV_DUR:    .res 4                    ; the vsyncs left of the segment held; 0 idle
SV_PTR:    .res 4                    ; the next segment, its offset in sfx_scr (0: the end)
SV_PRI:    .res 4                    ; its effect's priority << 4; 0 idle
SV_F:                                 ; the segment's fields, SV_F + 4 x the field
SV_PLO:    .res 4                    ; the period (tone: 10 bits; noise: the control nibble)
SV_PHI:    .res 4
SV_LVL:    .res 4                    ; the level, 0..255 (the chip's 2 dB steps are its top nibble)
SV_DLV:    .res 4                    ; the level's step a vsync, signed
SV_STP:    .res 4                    ; the period's step a vsync, signed
SV_JIT:    .res 4                    ; the period's low bits made random
        .assert SV_PHI = SV_PLO+4 && SV_LVL = SV_PLO+8 && SV_DLV = SV_PLO+12 && SV_STP = SV_PLO+16 && SV_JIT = SV_PLO+20, error, "sound.s: SV_F's fields in sfx.py's FIELDS order"
sfx_rnd:   .res 1                    ; the jitter's generator
sfx_n:     .res 1                    ; the request loop's effect

; ---------------------------------------------------------------- the main code's (the kernel:
; resident, so the menus' image and the game's both call them)
        .segment "KRNCODE"
; sfx_request: ask for an effect, to start at the next vsync
;   In:    A = its id (SFX_*: sfxdata.inc)
;   Out:   A = Y; C = bit 2 of the id; N, Z from X; V kept
;   Keeps: X, Y
; Any number in one frame: each is a bit of SFXBITS (an effect asked twice starts once).
sfx_request:
        stx mtmp                    ; X in cpu.inc's scratch (main code only: the interrupt never uses mtmp)
        tax                         ; the id
        tya
        pha                         ; Y on the stack
        txa                         ; the id again
        lsr
        lsr
        lsr
        tay
        txa
        and #7
        tax
        lda sfxbit,x
        php
        sei
        ora SFXBITS,y
        sta SFXBITS,y
        plp
        pla
        tay
        ldx mtmp                    ; last: N,Z from X, as the 65C02's plx left them
        rts
sfxbit: .byte 1, 2, 4, 8, 16, 32, 64, 128

; sound_reset: every voice idle and silent, no request, the generator seeded
;   Out:   Y = $FF; A clobbered; X kept
sound_reset:
        lda #1
        sta sfx_rnd
        ldy #3
@v:     lda #0
        sta SV_DUR,y
        sta SV_PRI,y
        sta SFXBITS,y               ; Y = 3..0: SFXBITS+2..0 (and SV_DUR, cleared anyway, at 3)
        .assert SV_DUR = SFXBITS+3, error, "sound_reset: SV_DUR right after SFXBITS"
        tya
        lsr                         ; Y is 0..3: lsr, ror x3 is Y<<5 in four bytes
        ror
        ror
        ror
        ora #$9F
        jsr snd_write               ; the channel off
        dey
        bpl @v
        rts

; ---------------------------------------------------------------- the player, bank 6
        .segment "SND6CODE"
; sfx_tick: the vsync's sound step (bank 6 paged, after the tune: low.s irq_vret on the
; Model B, the Master's handler; X and Y saved)
;   Out:   the effects asked for started; every voice stepped; A X Y clobbered
sfx_tick:
        ldx #2
@rq:    lda SFXBITS,x
        beq @rn
        txa                         ; (SFXBITS,x itself is the shift register: the loop
        asl                         ;  ends with it 0)
        asl
        asl
        sta sfx_n                    ; the effect
@bit:   lsr SFXBITS,x
        bcc @nx
        txa                         ; X kept on the stack over the effect's start
        pha
        ldy sfx_n
        ldx sfx_fxtab,y                 ; X -> its header
        lda sfx_fxhdr,x                 ; priority << 4 | the voices' mask
        sta isr_t1
        and #$F0
        sta isr_t2                  ; the priority, as SV_PRI keeps it
        ldy #0                      ; Y = the voice
@vv:    lsr isr_t1                  ; C = the voice's bit (four of them: the priority's
        bcc @nv                     ;  bits shift down behind them unread)
        inx                         ; X -> its script (taken or not)
        lda isr_t2                  ; (an idle voice has SV_PRI = 0: sound_reset and
        cmp SV_PRI,y                 ;  sfx_voff clear it, so the cmp takes it)
        bcc @nv                     ; a lower priority: dropped
        sta SV_PRI,y
        lda sfx_fxhdr,x
        sta SV_PTR,y
        lda #1
        sta SV_DUR,y                 ; its first segment loads on this tick
        lsr                         ; A = 0: what a script's first segment does not set
        sta SV_PHI,y                 ;  is the period's high byte, the step, the jitter
        sta SV_STP,y
        sta SV_JIT,y
@nv:    iny
        cpy #4
        bcc @vv
        pla
        tax
@nx:    inc sfx_n
        lda SFXBITS,x               ; (X is the byte's index again on both paths)
        bne @bit
@rn:    dex
        bpl @rq
        ldx #3
@vl:    jsr sfx_voice
        dex
        bpl @vl
        rts

; sfx_voice: X = the voice
sfx_voice:
        lda SV_DUR,x
        beq @rts                    ; idle
        dec SV_DUR,x
        bne @run
        ; the next segment: its head, shape << 4 | the frames' index
        ldy SV_PTR,x
        lda sfx_scr,y
        bne @skip
        jmp sfx_voff               ; 0: the end (A = 0)
@skip:  iny
        stx isr_t2                  ; X for the tables, the voice back from isr_t2
        pha
        and #15
        tax
        lda sfx_frtab,x
        ldx isr_t2
        sta SV_DUR,x
        pla
        lsr
        lsr
        lsr
        lsr
        tax
        lda sfx_mtab,x                  ; bit 7 the last segment, bits 6..1 the fields present
        ldx isr_t2
        asl                         ; C = the last
        php
        sta isr_t1
@f:     asl isr_t1                  ; C = the next field present
        bcc @n
        lda sfx_scr,y
        iny
        sta SV_F,x
@n:     inx                         ; X on to the next field (SV_F + 4 x the field)
        inx
        inx
        inx
        lda isr_t1
        bne @f                      ; until no field is left
        ldx isr_t2
        tya
        plp
        bcc @skip2
        lda #0                      ; the last: the end (sfx_scr+0) next
@skip2: sta SV_PTR,x
        jsr sfx_wper
        jmp sfx_wvol
@rts:   rts
@run:   ldy #0                      ; Y = the step's sign byte
        lda SV_STP,x
        beq @nostep
        bpl @up
        dey                         ; a negative step: $FF
@up:    clc                         ; period += step, held to 10 bits (no wrap:
        adc SV_PLO,x                 ; a sweep stops at the chip's lowest or highest)
        sta SV_PLO,x
        tya                         ; the sign byte (C from the low add is kept)
        adc SV_PHI,x                 ; hi + sign + carry: -1..4
        cmp #4                      ; 0..3 in range; 4 (past 1023) and $FF (below 0) are both >= 4
        bcc @sethi
        asl                         ; C = 1 below 0 (A = $FF), 0 past 1023 (A = 4)
        lda #0
        sbc #0                      ; the low byte: $FF past 1023 (0-0-1), 0 below 0
        sta SV_PLO,x
        and #3                      ; the high byte: 3 past 1023, 0 below 0 (then @sethi stores it)
@sethi: sta SV_PHI,x
        lda SV_JIT,x
        beq @wp                     ; no jitter: write the stepped period as it is
                                    ; (else on through @nostep: its reload of SV_JIT is not 0 either)
@nostep:
        lda SV_JIT,x
        beq @lvl
        lda sfx_rnd                  ; random bits into the period's low byte
        asl
        bcc @skip3
        eor #$1D
@skip3: sta sfx_rnd
        eor SV_PLO,x                 ; per ^ ((per ^ rnd) & jit): rnd where jit is set
        and SV_JIT,x
        eor SV_PLO,x
        sta SV_PLO,x
@wp:    jsr sfx_wper
@lvl:   lda SV_DLV,x
        beq @rts                    ; (the volume stands: no write)
        lda SV_LVL,x                 ; level + the signed step, saturating at 0 and 255: with the
        eor #$80                    ; level biased to signed (-128..127) it is a signed add and
        clc                         ; V flags exactly the saturating cases
        adc SV_DLV,x
        eor #$80                    ; (unbias: eor keeps V and C)
        bvc @setl
        lda #$FF                    ; V: C = 0 past 255 (both addends >= 0): $FF; C = 1 below 0
        adc #0                      ; (both < 0): $FF + 1 = 0
@setl:  sta SV_LVL,x
sfx_wvol:
        lda SV_LVL,x
        lsr
        lsr
        lsr
        lsr
        eor #$9F                    ; ~vol in the low nibble, $90 = latch + volume
        ora sfx_chbits,x
        jmp snd_write

sfx_wper:
        cpx #3
        beq @noise
        lda SV_PLO,x
        and #15
        ora sfx_chbits,x
        ora #$80
        jsr snd_write
        lda SV_PLO,x
        lsr
        lsr
        lsr
        lsr
        ldy SV_PHI,x                 ; the period's high bits, 0..3
        ora @hi4,y                  ; (per >> 4) & 63
        jmp snd_write
@noise: lda SV_PLO,x
        and #7
        ora #$E0
        jmp snd_write
@hi4:   .byte 0, 16, 32, 48

sfx_voff:                          ; A = 0 (sfx_voice: the end)
        sta SV_PRI,x                 ; (SV_DUR is 0 already: the dec)
        lda sfx_chbits,x
        ora #$9F
        jmp snd_write

sfx_chbits: .byte $00, $20, $40, $60    ; a voice's channel, as the chip's latch byte has it
        .include "sfxdata.inc"      ; tools/sfx.py: SFX_* and NSFX, then sfx_fxtab, sfx_fxhdr, sfx_mtab, sfx_frtab, sfx_scr
