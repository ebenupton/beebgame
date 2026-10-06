; ============================================================================
; engine/menus.s -- the title tune's player, in the menus' image
;
; The tune is the game's (music_addr, in its menus' image: docs/GUIDE.md), and its
; player sits beside it, so the player needs no copy and plays only while that image
; is in bank 7 (music_stop, in the kernel, silences it: the menus' image may be gone).
; The stream (tools/midi2snd.py makes it):
;   music_addr               the period table, MUS_TAB_LEN bytes: a word for each
;                            MIDI note MUS_NOTE0 .. MUS_NOTE0 + MUS_NNOTES - 1
;   music_addr + MUS_TAB_LEN the sequence, records of frames then a note a voice
;                            (0 = a rest, else the MIDI note); frames = 0 ends it
;
;   music_tick    one vsync's step of the tune
;   mus_byte      the next byte of the sequence
;   music_start   start the tune from its top
;
; Segment: MUSCODE (bank 7, the menus' image: cfg/banks.cfg puts it first there).
; Both machines.
; ============================================================================
MUS_NOTE0   = 24                   ; the lowest MIDI note the table holds (C1),
MUS_NNOTES  = 72                   ;  and how many: C1 to B6
MUS_TAB_LEN = 2*MUS_NNOTES
NVOICE      = 3                    ; the chip's tone channels: a note each a record
music_tab   = music_addr           ; the player is in the data's bank: no copy needed
  .if TUNEFX
music_btab  = music_addr + MUS_TAB_LEN   ; the bass's tone 2 periods, a byte a note
MFX_HDR     = music_btab + MUS_NNOTES    ; FXHDR: the envelopes, the vibrato, the arpeggio
FXH_VIBD    = 9                    ; the vibrato: the melody's vsyncs before it,
FXH_VIBS    = 10                   ;  the period's shift for its depth,
FXH_VIBR    = 11                   ;  the shift of the note's age for its step
FXH_ARP     = 12                   ; the arpeggio's vsyncs a note
FX_HDR_LEN  = 13
music_seq   = MFX_HDR + FX_HDR_LEN
NFXV        = 5                    ; a record's voices: the melody, the bass, the chord's three
  .else
music_seq   = music_addr + MUS_TAB_LEN
  .endif
        .segment "MUSCODE"

  .if .not TUNEFX
; ----------------------------------------------------------------------------
; music_tick: one vsync's step of the tune
;   In:    mus_dur = the record's frames to go; mus_ptr = the next record; MUSNOTE =
;          each voice's note, as the chip has it
;   Out:   mus_dur counted down, or the next record read and its notes played;
;          mus_ptr, MUSNOTE moved on
;   Uses:  A X Y, isr_t1, isr_t2
;   Pre:   mus_on = 1 (both callers test it, through mus_tick on the Model B);
;          bank 7 paged in (the stub paged it for the body: low.s irq_vret; the
;          Master's handler pages it: kernel.s)
; Stepped from the interrupt's tail.  Only a voice whose note changed is written to
; the chip (snd_write, which keeps X and Y).
; ----------------------------------------------------------------------------
music_tick:
        dec mus_dur
        bne @done
        ; ---- the next record: its frames, or (0) back to the top
@rec:   jsr mus_byte
        bne @dur
        jsr mus_top                ; (A = 1: Z = 0; the record read next sets mus_dur)
        bne @rec                   ; always
@dur:   sta mus_dur
        ; ---- its three notes, X = the voice
        ldx #0
@voice: txa                        ; isr_t1 = the voice << SN_CHSHIFT, for both latches
        .repeat SN_CHSHIFT
        asl
        .endrepeat
        sta isr_t1
        jsr mus_byte               ; (keeps X)
        cmp MUSNOTE,x
        beq @next                  ; the same note: nothing to write
        sta MUSNOTE,x
        ; Notes are MUS_NOTE0 up, 0 a rest: the table is indexed from 2*MUS_NOTE0,
        ; and Z from the doubled note is the rest
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
        pla
        lsr                        ; the low byte's top 4 bits ...
        lsr
        lsr
        lsr
        sta isr_t2
        lda music_tab-2*MUS_NOTE0+1,y
        asl                        ; ... under the high byte's 2: the period's upper 6
        asl
        asl
        asl
        ora isr_t2
        jsr snd_write
        lda mus_vol,x
        .byte OP_BIT_ABS           ; (bit abs: skips the lda #SN_ATT_OFF; V is not used)
@rest:  lda #SN_ATT_OFF            ; a rest: attenuation 15
        ora isr_t1
        ora #SN_LATCH|SN_VOL       ; the volume latch: %1 cc 1 aaaa
        jsr snd_write
@next:  inx
        cpx #NVOICE
        bne @voice
@done:  rts

  .else
; ----------------------------------------------------------------------------
; music_tick (TUNEFX): one vsync's step of the tune -- a melody on tone 0, a chord
; on tone 1 as an arpeggio, a bass on the noise channel (periodic noise clocked by
; tone 2, which stays silent: the note's own pitch, below the tones' range)
;   In:    mus_dur = the record's frames to go; mus_ptr = the next record; MUSNOTE =
;          the melody's, the bass's and the chord's notes; MFX_* the envelopes, what
;          the chip holds, the vibrato's and the arpeggio's clocks
;   Out:   the next record read when mus_dur runs out (a struck note restarts its
;          envelope); every voice stepped: its level down its envelope, the
;          melody's period with its vibrato, the chord's note on; the chip given
;          only what changed (snd_write keeps X and Y)
;   Uses:  A X Y, isr_t1, isr_t2
;   Pre:   as the plain player's: mus_on = 1, bank 7 paged
; The stream: tools/midi2snd.py --fx.  A record: frames (0: the end, looped), a mask
; (bit 0 the melody, 1 the bass, 2-4 the chord's notes), then a byte for each bit
; set: the note, bit 7 set where it is struck, 0 none.
; ----------------------------------------------------------------------------
music_tick:
        dec mus_dur
        bne @play
@rec:   jsr mus_byte
        bne @dur
        jsr mus_top                ; (A = 1: Z = 0; the record read next sets mus_dur)
        bne @rec                   ; always
@dur:   sta mus_dur
        jsr mus_byte               ; the mask
        sta isr_t1
        ldx #0                     ; X = the voice: 0 the melody, 1 the bass, 2-4 the chord
@mask:  lsr isr_t1
        bcc @mnext
        jsr mus_byte               ; (keeps X) the note, bit 7 struck
        and #$7F
        sta MUSNOTE,x
        tya                        ; (mus_byte: Y = the byte)
        bpl @mnext                 ; held
        ; ---- struck: its envelope from the top (the level's index: 0 the melody,
        ;      1 the bass, 2 the chord), the melody's vibrato from its start, the
        ;      chord's arpeggio from its first note, the bass's noise mode again
        txa
        cmp #2
        bcc @lv
        lda #2
@lv:    sta isr_t2
        asl
        adc isr_t2                 ; x 3: its envelope in FXHDR (C = 0: the asl of 0..2)
        tay
        lda MFX_HDR,y              ; the envelope's start
        ldy isr_t2
        sta MFX_L,y
        lda #0
        cpy #1
        bcc @age                   ; the melody
        bne @arp                   ; the chord
        lda #SN_LATCH|(SN_NOISE << SN_CHSHIFT)|3   ; the bass: periodic noise, clocked by
        jsr snd_write              ;  tone 2 (a sound effect on the noise may have changed
        lda #$FF                   ;  it), and its volume written again
        sta MFX_A+SN_NOISE
        bne @mnext                 ; always
@age:   sta mfx_age
        beq @mnext                 ; always: A = 0
@arp:   lda #$FF                   ; (the arpeggio's first step takes it to 0)
        sta mfx_ai
        lda #1
        sta mfx_ac
@mnext: inx
        cpx #NFXV
        bne @mask
        ; ---- the melody, tone 0
@play:  lda MUSNOTE
        bne @mon
        ldx #0                     ; resting: silent (A = 0)
        jsr mfx_vol
        jmp @chord
@mon:   asl
        tay
        lda music_tab-2*MUS_NOTE0,y
        sta isr_t1
        lda music_tab-2*MUS_NOTE0+1,y
        sta isr_t2
        lda mfx_age                ; the vibrato, once the note has held FXH_VIBD vsyncs:
        cmp MFX_HDR+FXH_VIBD       ;  its step (age >> FXH_VIBR) & 3 is the note, a
        bcc @mper                  ;  depth up, the note, a depth down
        ldy MFX_HDR+FXH_VIBR
@vr:    dey
        bmi @vstep
        lsr
        bpl @vr                    ; always: N = 0 from the lsr
@vstep: lsr                        ; C = bit 0: the note itself (steps 0 and 2)
        bcc @mper
        tay                        ; (Y bit 0: 1 down, 0 up)
        lda isr_t2                 ; the depth: the period >> FXH_VIBS
        sta mfx_d+1
        lda isr_t1
        sta mfx_d
        ldx MFX_HDR+FXH_VIBS
@vs:    lsr mfx_d+1
        ror mfx_d
        dex
        bne @vs
        tya
        lsr
        bcs @vdown
        lda isr_t1                 ; up a depth: the period less it
        sbc mfx_d                  ; (C = 0: - 1 more, a hair deeper)
        sta isr_t1
        lda isr_t2
        sbc mfx_d+1
        sta isr_t2
        jmp @mper
@vdown: lda isr_t1                 ; down a depth: the period plus it (C = 1: + 1)
        adc mfx_d
        sta isr_t1
        lda isr_t2
        adc mfx_d+1
        sta isr_t2
@mper:  ldx #0
        jsr mfx_per
        inc mfx_age
        bne @mlev
        dec mfx_age                ; (held at 255)
@mlev:  ldx #0
        jsr mfx_decay
        ldx #0
        jsr mfx_vol
        ; ---- the chord, tone 1: its notes in turn, FXH_ARP vsyncs each
@chord: lda MUSNOTE+2
        beq @coff
        dec mfx_ac
        bne @cnote
        lda MFX_HDR+FXH_ARP
        sta mfx_ac
        inc mfx_ai
@cnote: ldy mfx_ai
        cpy #NFXV-2
        bcs @cfirst
        lda MUSNOTE+2,y
        bne @cgo
@cfirst:
        lda #0                     ; past its last note: back to the first
        sta mfx_ai
        lda MUSNOTE+2
@cgo:   asl
        tay
        lda music_tab-2*MUS_NOTE0,y
        sta isr_t1
        lda music_tab-2*MUS_NOTE0+1,y
        sta isr_t2
        ldx #1
        jsr mfx_per
        ldx #2
        jsr mfx_decay
        ldx #1
        jsr mfx_vol
        jmp @bass
@coff:  ldx #1                     ; (A = 0: silent)
        jsr mfx_vol
        ; ---- the bass: tone 2's period its clock, the noise channel its volume
@bass:  ldy MUSNOTE+1
        beq @boff
        lda music_btab-MUS_NOTE0,y
        sta isr_t1
        lda #0
        sta isr_t2
        ldx #2
        jsr mfx_per
        ldx #1
        jsr mfx_decay              ; A = the bass's level
        .byte OP_BIT_ABS           ; (skips the lda #0)
@boff:  lda #0                     ; silent
        ldx #SN_NOISE
        ; (on into mfx_vol)
; mfx_vol: channel X's volume from level A (0..255: the attenuation 15 less its top
; nibble), written when it changed.  Keeps X, Y
mfx_vol:
        lsr
        lsr
        lsr
        lsr
        eor #SN_ATT_OFF
        cmp MFX_A,x
        beq mfx_rts
        sta MFX_A,x
        ora mfx_ch,x
        ora #SN_LATCH|SN_VOL
        jmp snd_write
; mfx_per: tone channel X's period from isr_t2:isr_t1, written when it changed.
; Keeps X, Y; isr_t1, isr_t2 clobbered
mfx_per:
        lda isr_t1
        cmp MFX_PL,x
        bne @w
        lda isr_t2
        cmp MFX_PH,x
        beq mfx_rts
@w:     lda isr_t2
        sta MFX_PH,x
        lda isr_t1
        sta MFX_PL,x
        and #SN_DATAMASK           ; the latch: %1 cc 0 pppp, the period's low 4 bits
        ora mfx_ch,x
        ora #SN_LATCH
        jsr snd_write
        lda isr_t2                 ; then its upper 6
        asl
        asl
        asl
        asl
        sta isr_t2
        lda isr_t1
        lsr
        lsr
        lsr
        lsr
        ora isr_t2
        jmp snd_write
; mfx_decay: envelope X's level (0 the melody, 1 the bass, 2 the chord) down its
; fall, not below its rest; A = it.  Keeps X
mfx_decay:
        txa
        sta isr_t2
        asl
        adc isr_t2                 ; x 3 (C = 0)
        tay
        lda MFX_L,x
        sec
        sbc MFX_HDR+1,y            ; its fall
        bcc @rest
        cmp MFX_HDR+2,y            ; not below its rest
        bcs @st
@rest:  lda MFX_HDR+2,y
@st:    sta MFX_L,x
mfx_rts:
        rts
mfx_ch: .byte $00, $20, $40, $60   ; a channel, as the chip's latch byte has it
  .endif
; ----------------------------------------------------------------------------
; mus_byte: the next byte of the sequence
;   Out:   A = Y = the byte, Z from it; mus_ptr += 1
;   Keeps: X
; ----------------------------------------------------------------------------
mus_byte:
        ldaz mus_ptr
        inc mus_ptr
        bne @skip
        inc mus_ptr+1
@skip:  tay
        rts

  .if .not TUNEFX
; each voice's attenuation while it plays (0 the loudest): the melody (voice 0) over
; the two accompanying
mus_vol: .byte 3, 8, 8
        .assert * - mus_vol = NVOICE, error, "mus_vol: an attenuation a voice"
  .endif

; ----------------------------------------------------------------------------
; music_start: start the tune from its top
;   Out:   mus_ptr = the sequence; mus_dur = 1 (the first record is read at the next
;          vsync); MUSNOTE = rests; mus_on = 1
;   Uses:  A
;   Keeps: X Y
;   Pre:   mus_on = 0 (the one caller, the game's title menu, tests it)
; mus_top: music_tick's way back to the top: mus_on is 1 there, and the record it
; reads next sets mus_dur
; ----------------------------------------------------------------------------
music_start:
  .if TUNEFX
        txa                        ; (X kept)
        pha
        lda #0
        ldx #NFXV-1
@z:     sta MUSNOTE,x              ; every voice resting
        dex
        bpl @z
        lda #$FF                   ; what the chip holds unknown: everything written
        ldx #3+3+4-1               ;  (MFX_A, MFX_PL, MFX_PH: ten bytes in a row)
@f:     sta MFX_A,x
        dex
        bpl @f
        .assert MFX_PL = MFX_A+4 && MFX_PH = MFX_PL+3, error, "music_start: MFX_A, MFX_PL, MFX_PH in a row"
        lda #SN_LATCH|SN_VOL|(2 << SN_CHSHIFT)|SN_ATT_OFF   ; tone 2 silent: the bass's
        jsr snd_write                                       ;  clock alone
        pla
        tax
  .else
        zero MUSNOTE, MUSNOTE+1, MUSNOTE+2
  .endif
mus_top:
        lda #<music_seq
        sta mus_ptr
        lda #>music_seq
        sta mus_ptr+1
        lda #1
        sta mus_dur
        sta mus_on                 ; last: the vsync steps the tune from here
        rts
