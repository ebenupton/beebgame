; ---------------------------------------------------------------- music
; 144-byte period table then the sequence (4-byte records: frames, note0..2;
; frames = 0 -> loop), in the menus' image beside its player (banks.s MUSIC_ADDR).
; Stepped from the interrupt's tail with bank 7 paged, for reading and writing: the
; Model B's stub has paged it for the body already, the Master's handler pages it.
MUSIC_SEQ  = MUSIC_ADDR + 144
MUSIC_TAB  = MUSIC_ADDR             ; the player is in the data's bank: no copy needed
        .segment "MUSCODE"          ; the menus' image, with the tune (the cfgs: first in it)
music_tick:
        lda MUSON
        beq @done
        dec MUSDUR
        bne @done
        jsr musbyte
        bne :+
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        jsr musbyte
:       sta MUSDUR
        ldx #0
@v:     jsr musbyte
        cmp MUSNOTE,x
        beq :+
        sta MUSNOTE,x
        tay                         ; set the voice: Y = the note (0 = rest), X = the voice
        txa                         ; (X is not touched: sndwrite keeps it)
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
@note:  tya
        asl                         ; notes are 24..95: the table indexed from 2*24
        tay
        lda MUSIC_TAB-48,y
        and #15
        ora ISRT1
        ora #$80
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
        ora ISRT2
        jsr sndwrite
        lda musvol,x
        ora ISRT1
@vol:   ora #$90
        jsr sndwrite
:       inx
        cpx #3
        bne @v
@done:  rts

; A = next music byte; MUSPTR += 1.  Preserves X.  Z reflects A; Y = A.
musbyte:
        ldaz MUSPTR
        inc MUSPTR
        bne :+
        inc MUSPTR+1
:       tay
        rts
musvol: .byte 3, 8, 8

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

