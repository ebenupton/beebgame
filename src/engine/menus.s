; ============================================================================
; engine/menus.s -- the title tune's player, in the menus' image
;
; The tune is the game's (MUSIC_ADDR, in its menus' image: docs/GUIDE.md), and its
; player sits beside it, so the player needs no copy and plays only while that image
; is in bank 7 (music_stop, in the kernel, silences it: the menus' image may be gone).
; The stream (tools/midi2snd.py makes it):
;   MUSIC_ADDR        the period table, 144 bytes: 72 x 2 for MIDI notes 24..95
;   MUSIC_ADDR + 144  the sequence, 4-byte records: frames, note0..2 (0 = a rest, else
;                     the MIDI note);  frames = 0 -> loop
;
;   music_tick   one vsync's step of the tune
;   musbyte      the next byte of the sequence
;   music_start  start the tune from its top
;
; Segment: MUSCODE (bank 7, the menus' image: the cfgs put it first in it).
; ============================================================================
MUSIC_SEQ  = MUSIC_ADDR + 144
MUSIC_TAB  = MUSIC_ADDR             ; the player is in the data's bank: no copy needed
        .segment "MUSCODE"

; ============================================================================
; music_tick: one vsync's step of the tune
;   In:   MUSON (0: nothing);  MUSDUR = the record's frames to go;  MUSPTR = the
;         next record;  MUSNOTE = each voice's note, as the chip has it
;   Out:  A, X, Y clobbered;  ISRT1, ISRT2 scratch
; Stepped from the interrupt's tail with bank 7 paged, for reading and writing: the
; Model B's stub has paged it for the body already (low.s irq_vret), the Master's
; handler pages it (kernel.s).  Only a voice whose note changed is written to the
; chip (sndwrite, which keeps X and Y).
; ============================================================================
music_tick:
        lda MUSON
        beq @done
        dec MUSDUR
        bne @done
        ; ---- the next record: its frames, or (0) back to the top
        jsr musbyte
        bne :+
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        jsr musbyte
:       sta MUSDUR
        ; ---- its three notes, X = the voice
        ldx #0
@v:     jsr musbyte
        cmp MUSNOTE,x
        beq :+                      ; the same note: nothing to write
        sta MUSNOTE,x
        ; set the voice: Y = the note (0 = rest), X = the voice (X is not touched:
        ; sndwrite keeps it)
        tay
        txa
        asl
        asl
        asl
        asl
        asl
        sta ISRT1                   ; ch << 5
        cpy #0
        bne @note
        ora #$0F                    ; rest: A is still ch<<5; attenuation 15
        bne @vol                    ; (always)
        ; ---- a note: its period, the low 4 bits then the rest, then its volume
@note:  tya
        asl                         ; notes are 24..95: the table indexed from 2*24
        tay
        lda MUSIC_TAB-48,y
        and #15
        ora ISRT1
        ora #$80                    ; the tone latch: %1 cc 0 pppp
        jsr sndwrite
        lda MUSIC_TAB-48,y
        lsr
        lsr
        lsr
        lsr
        sta ISRT2
        lda MUSIC_TAB-47,y
        asl
        asl
        asl
        asl
        ora ISRT2                   ; the period's upper bits
        jsr sndwrite
        lda musvol,x
        ora ISRT1
@vol:   ora #$90                    ; the volume latch: %1 cc 1 aaaa
        jsr sndwrite
:       inx
        cpx #3
        bne @v
@done:  rts

; ----------------------------------------------------------------------------
; musbyte: the next byte of the sequence
;   Out:  A = Y = the byte;  Z from it;  MUSPTR += 1;  X kept
; ----------------------------------------------------------------------------
musbyte:
        ldaz MUSPTR
        inc MUSPTR
        bne :+
        inc MUSPTR+1
:       tay
        rts

; each voice's attenuation while it plays: the melody (voice 0) the loudest
musvol: .byte 3, 8, 8

; ----------------------------------------------------------------------------
; music_start: start the tune from its top
;   Out:  MUSPTR = the sequence;  MUSDUR = 1 (the first record read at the next
;         vsync);  MUSNOTE = rests;  MUSON = 1;  A = 1, X, Y kept
; ----------------------------------------------------------------------------
music_start:
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        lda #1
        sta MUSDUR
  .if BHW
        lsr                         ; A = 0, C = 1
        sta MUSNOTE
        sta MUSNOTE+1
        sta MUSNOTE+2
        rol                         ; A = 1
  .else
        stz MUSNOTE
        stz MUSNOTE+1
        stz MUSNOTE+2
  .endif
        sta MUSON
        rts
