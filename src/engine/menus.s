; ============================================================================
; engine/menus.s -- the title tune's player, in the menus' image
;
; The tune is the game's (music_addr, in its menus' image: docs/GUIDE.md), and its
; player sits beside it, so the player needs no copy and plays only while that image
; is in bank 7 (music_stop, in the kernel, silences it: the menus' image may be gone).
; The stream (tools/midi2snd.py makes it):
;   music_addr        the period table, MUS_TAB_LEN bytes: MUS_NNOTES x 2 for MIDI notes
;                     MUS_NOTE0 .. MUS_NOTE0 + MUS_NNOTES - 1
;   music_addr + MUS_TAB_LEN  the sequence, 4-byte records: frames, a note a voice (0 =
;                     a rest, else the MIDI note);  frames = 0 -> loop
;
;   music_tick   one vsync's step of the tune
;   mus_byte      the next byte of the sequence
;   music_start  start the tune from its top
;
; Segment: MUSCODE (bank 7, the menus' image: the cfgs put it first in it).
; ============================================================================
MUS_NOTE0  = 24                    ; the lowest MIDI note the table holds,
MUS_NNOTES = 72                    ;  and how many: C1 to B6
MUS_TAB_LEN = 2*MUS_NNOTES
NVOICE     = 3                     ; the chip's tone channels: a note each a record
music_seq  = music_addr + MUS_TAB_LEN
music_tab  = music_addr            ; the player is in the data's bank: no copy needed
        .segment "MUSCODE"

; ============================================================================
; music_tick: one vsync's step of the tune
;   In:   mus_on (0: nothing);  mus_dur = the record's frames to go;  mus_ptr = the
;         next record;  MUSNOTE = each voice's note, as the chip has it
;   Out:  A, X, Y clobbered;  isr_t1, isr_t2 scratch
; Stepped from the interrupt's tail with bank 7 paged, for reading and writing: the
; Model B's stub has paged it for the body already (low.s irq_vret), the Master's
; handler pages it (kernel.s).  Only a voice whose note changed is written to the
; chip (snd_write, which keeps X and Y).
; ============================================================================
music_tick:
        ; (mus_on is not 0 here: both callers step the tune only on mus_tick, which the
        ; vsync has just copied from mus_on in this same interrupt)
        dec mus_dur
        bne @done
        ; ---- the next record: its frames, or (0) back to the top
@rec:   jsr mus_byte
        bne :+
        lda #<music_seq
        sta mus_ptr
        lda #>music_seq
        sta mus_ptr+1
        bne @rec                   ; (always: the tune is in bank 7; its first record's frames are not 0)
:       sta mus_dur
        ; ---- its three notes, X = the voice
        ldx #0
@v:     txa                        ; ch << SN_CHSHIFT, for both latches (mus_byte keeps X)
        .repeat SN_CHSHIFT
        asl
        .endrepeat
        sta isr_t1
        jsr mus_byte
        cmp MUSNOTE,x
        beq :+                     ; the same note: nothing to write
        sta MUSNOTE,x
        ; set the voice (X is not touched: snd_write keeps it).  Notes are MUS_NOTE0 up,
        ; 0 a rest: the table indexed from 2*MUS_NOTE0, and Z from the doubled note is
        ; the rest
        asl
        tay
        beq @rest
        ; ---- a note: its period, the low 4 bits then the rest, then its volume
        lda music_tab-2*MUS_NOTE0,y
        pha                        ; (the low byte again, for the second write)
        and #SN_DATAMASK
        ora isr_t1
        ora #SN_LATCH              ; the tone latch: %1 cc 0 pppp
        jsr snd_write
        pla                        ; (snd_write's own pha/pla balance)
        lsr
        lsr
        lsr
        lsr
        sta isr_t2
        lda music_tab-2*MUS_NOTE0+1,y
        asl
        asl
        asl
        asl
        ora isr_t2                 ; the period's upper bits
        jsr snd_write
        lda mus_vol,x
        .byte OP_BIT_ABS           ; (bit abs: over the lda #SN_ATT_OFF; V is not used)
@rest:  lda #SN_ATT_OFF            ; rest: attenuation 15
        ora isr_t1
        ora #SN_LATCH|SN_VOL       ; the volume latch: %1 cc 1 aaaa
        jsr snd_write
:       inx
        cpx #NVOICE
        bne @v
@done:  rts

; ----------------------------------------------------------------------------
; mus_byte: the next byte of the sequence
;   Out:  A = Y = the byte;  Z from it;  mus_ptr += 1;  X kept
; ----------------------------------------------------------------------------
mus_byte:
        ldaz mus_ptr
        inc mus_ptr
        bne :+
        inc mus_ptr+1
:       tay
        rts

; each voice's attenuation while it plays (0 the loudest): the melody (voice 0) over
; the two accompanying
mus_vol: .byte 3, 8, 8
        .assert * - mus_vol = NVOICE, error, "mus_vol: an attenuation a voice"

; ----------------------------------------------------------------------------
; music_start: start the tune from its top
;   Out:  mus_ptr = the sequence;  mus_dur = 1 (the first record read at the next
;         vsync);  MUSNOTE = rests;  mus_on = 1;  A clobbered, X, Y kept
; ----------------------------------------------------------------------------
music_start:
        lda #<music_seq
        sta mus_ptr
        lda #>music_seq
        sta mus_ptr+1
        lda #1
        sta mus_dur
  .if BHW
        lsr                        ; A = 0
        sta MUSNOTE
        sta MUSNOTE+1
        sta MUSNOTE+2
        inc mus_on                 ; 0 -> 1: the only caller calls while it is 0
  .else
        stz MUSNOTE
        stz MUSNOTE+1
        stz MUSNOTE+2
        sta mus_on
  .endif
        rts
