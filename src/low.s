; ============================================================================
; low.s -- low RAM, $0140-$02FF, both machines: what has to be visible whatever
; bank is paged in
;
; The crossings between the banks and the Model B's interrupt stub (its body is in
; bank 7: kernel.s isr_body); engine/lowram.s's map access and page_logic land in the
; same segment, and the LOWBSS variables that more than one bank touches (the rest of
; them are vars.s's).  init.s boot copies the code down from the BOOT piece.  ROMSEL_CPY
; is written before ROMSEL at every switch, so an interrupt between the two puts back
; the bank being entered: the handler restores ROMSEL from it.
;
;   irq_handler  (Model B) the interrupt stub: bank 7 in, to isr_body; irq_vret and
;                irq_ret the ways back
;   map_strip    the tile row's gather, in bank 5, then bank 6 back
;   page6        bank 6 in
;   selbb        select_backbuf in bank 6, with a write window
;   validate     scroll_validate in bank 6
;   call_bank    a bank's entry (BANKENTRY), A = the bank, then bank 7 back
;
; Segments: LOWCODE (the code, copied down), LOWBSS, LOWBSS2 (GATHERL, above the
; code; SOUND6: in LOWBSS, and LOWCODE2, kernel.s snd_write, after it), LOWHW (the Model B's mirror notes, after the shared).  The .if BHW blocks
; are the first blessed placement (the Master's handler is at IRQ1V itself) and
; hardware (the mirror).
; ============================================================================

; ---------------------------------------------------------------- the variables
        .segment "LOWBSS"
GATHERH:   .res GATHERN            ; a tile row's gather (gather5 writes it from bank
                                   ;  5, draw_rect reads it from bank 6): each tile's
                                   ;  page or kind, GATHERN of them at most
clip_mask: .res 1                  ; REC_CLIP when the window has moved since the back
                                   ;  buffer last drew, else 0 (select_backbuf writes
                                   ;  it; match_sprites reads it)
krlo:      .res 1                  ; select_backbuf's, for match_sprites' moved
krhi2:     .res 1                  ;  records: the rows and columns the back buffer's
kclo:      .res 1                  ;  last window and this one share, relative to this
kchi2:     .res 1                  ;  one -- krlo .. krhi2-2, kclo .. kchi2-2; krlo
                                   ;  or kclo $FF for none (then the other pair is
                                   ;  not read)
sprc_ok:   .res 1                  ; the resident sprites (SPRC) are in bank 4, and
sprx_ok:   .res 1                  ;  (the Master) SPRX in HAZEL/ANDY: ldprog.s's
                                   ;  alone, across loads
; What the interrupt stores, in main RAM so that it stores into no bank and needs no
; write bank of its own (cpu.inc: the write bank is 7's but for short windows)
mus_dur:   .res 1                  ; the tune's player (menus.s music_tick, from the
  .if TUNEFX                       ;  interrupt's tail; music_start): the record's
MUSNOTE:   .res 5                  ;  frames to go, each voice's note (TUNEFX: the
  .else                            ;  melody, the bass, the chord's three), and two
MUSNOTE:   .res 3                  ;  bytes of scratch
  .endif
isr_t1:    .res 1
isr_t2:    .res 1
  .if TUNEFX                       ; (TUNEFX: menus.s's player)
MFX_L:     .res 3                  ; each envelope's level: the melody's, the bass's,
                                   ;  the chord's (0..255)
MFX_A:     .res 4                  ; what each channel was last given: the attenuation,
MFX_PL:    .res 3                  ;  and the tones' periods (the player writes only
MFX_PH:    .res 3                  ;  what changes)
mfx_age:   .res 1                  ; the melody's note's vsyncs (its vibrato's clock)
mfx_ai:    .res 1                  ; the chord's arpeggio: its note, and the vsyncs to
mfx_ac:    .res 1                  ;  the next
mfx_d:     .res 2                  ; the vibrato's depth
  .endif
  .if .not SOUND6
        .segment "LOWBSS2"         ; the rest of low RAM, above the code
  .endif                           ; (SOUND6: here, low RAM's code has snd_write's call)
GATHERL:   .res GATHERN            ; the gather's low bytes (GATHERH's pair)
  .if BHW                          ; hardware: the mirror (mirror.s)
        .segment "LOWHW"           ; (after the shared)
; The mirror's bookkeeping, per buffer: the tile blitter (bank 6), the sprite
; prologue and copy_partial (bank 7) note what they wrote to the ring's last slot row
; (MIRDIRTY_BODY); mirror_copy (bank 7) reads and resets it.
MIRDTY:    .res 2                  ; 1: the row has been written since the copy
MIRLO:     .res 2                  ; and which chars of it, in slot chars 0..79 (MIRLO
MIRHI:     .res 2                  ;  $FF: none)
MIRWCX:    .res 2                  ; the wcxm the copy was made for
MIRMR:     .res 2                  ; and the mrow
  .endif

; ---------------------------------------------------------------- the code
        .segment "LOWCODE"
  .if BHW                          ; blessed placement: the Master's is in main RAM
; ----------------------------------------------------------------------------
; irq_handler: the Model B's interrupt stub (IRQ1V)
;   In:    A saved at MOS_IRQA by the MOS's entry
;   Out:   to isr_body (kernel.s) with bank 7 paged in for reading, X and Y saved in
;          irq_x, irq_y, the interrupted ROMSEL_CPY pushed; D clear
; The chain step and the vsync work are in bank 7 with their tables, and this pages
; it in around them: page_logic in line and a jmp each way, because every cycle
; before the step's first CRTC write is lead the chain's timing has to allow for
; (kernel.s VS2T, STUBLAT), in place of the hold loop the Master's handler has.  The
; write bank is left as it was: the interrupt stores into no bank (cpu.inc).
; ----------------------------------------------------------------------------
irq_handler:
        cld                        ; the NMOS 6502 keeps D through an interrupt: the
                                   ;  body's adc/sbc must not see the game's sed (the
                                   ;  BCD score); rti puts it back.  The 65C02 clears
                                   ;  D itself
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        bankimm lda, BANK_LVL, 0   ; bank 7, for reading (page_logic's, in line)
        sta ROMSEL_CPY
        sta ROMSEL
        jmp isr_body

; ----------------------------------------------------------------------------
; irq_vret: the vsync's way back: step the title tune, (SOUND6) the effects in bank 6
; (sound6.s sfx_tick), then irq_ret
;   In:    mus_tick = mus_on, raised by the vsync's sound_tick; bank 7 paged in
;   Out:   mus_tick = 0; the tune stepped (menus.s music_tick) if it was set; SOUND6:
;          sfx_tick run with bank 6 paged
; The player is in the menus' image of bank 7, and mus_on is set only while that
; image is in (music_stop clears it before any load).
; ----------------------------------------------------------------------------
irq_vret:
        lda mus_tick
  .if SOUND6
        beq @snd
  .else
        beq irq_ret
  .endif
        dec mus_tick               ; 1 -> 0: mus_on's value, which is 0 or 1
        jsr music_tick             ; (bank 7: paged above)
  .if SOUND6                       ; the effects, in bank 6 (sound6.s; irq_ret pages
@snd:   jsr page6                  ;  the interrupted bank back)
        jsr sfx_tick
  .endif
; ----------------------------------------------------------------------------
; irq_ret: a step's way back
;   In:    the interrupted ROMSEL_CPY on the stack (irq_handler's pha)
;   Out:   that bank paged in again; X, Y, A restored; rti
; ----------------------------------------------------------------------------
irq_ret:
        pla
        sta ROMSEL_CPY
        sta ROMSEL
        ldy irq_y
        ldx irq_x
        lda MOS_IRQA
        rti
  .endif

; ----------------------------------------------------------------------------
; map_strip: a tile row's gather, run in bank 5 beside the map, then bank 6 back
;   In:    ptr = the row's first tile in the map, rc_nt (gather5's)
;   Out:   GATHERL/GATHERH filled; A = bank 6's number (N = 0: it is 4..7 after
;          patching), X, Y clobbered
;   Pre:   called from bank 6 (draw_rect's row loop)
;   Post:  bank 6 paged again, for reading; the write bank untouched (draw_rect's
;          window, bank 6, stays open: gather5 stores into no bank)
; The one bank switch a tile row costs.
; ----------------------------------------------------------------------------
map_strip:
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        jsr gather5
; ----------------------------------------------------------------------------
; page6: page bank 6 in, for reading
;   Out:   A = bank 6's number (as wrsel wants it)
;   Keeps: X Y
; map_strip falls into it; selbb, validate and init.s boot call it.
; ----------------------------------------------------------------------------
page6:
        bankimm lda, BANK_TILES, 0
        sta ROMSEL_CPY
        sta ROMSEL
        rts

; ----------------------------------------------------------------------------
; selbb: select_backbuf (tiles.s), from bank 7
;   In:    cur_buf; the window (select_backbuf's)
;   Out:   select_backbuf's: the blitters pointed at the back buffer, recp,
;          clip_mask, the shared rows and columns; A, X clobbered, Y kept
;   Post:  bank 7 paged again
; With a write window: select_backbuf patches draw_rect's ring operand in bank 6.
; Called by render_frame and the menus.
; ----------------------------------------------------------------------------
selbb:
        jsr page6
        wrsel BANK_TILES, 0        ; the window opens
        jsr select_backbuf
        wrback 0, 1                ; and closes
        jmp page_logic

; ----------------------------------------------------------------------------
; validate: scroll_validate (tiles.s), from bank 7
;   In:    cur_buf, the window, the buffer's BUF_CY/CXL/CXH
;   Out:   the strips the window moved onto drawn; A, X, Y clobbered
;   Post:  bank 7 paged again
; No write window: scroll_validate stores into no bank, and draw_rect opens and
; closes its own.  Called by render_frame.
; ----------------------------------------------------------------------------
validate:
        jsr page6
        jsr scroll_validate
        jmp page_logic

; ----------------------------------------------------------------------------
; call_bank: page a bank in and call its entry, then bank 7 back
;   In:    A = the bank (4, 5 or 6), its entry at BANKENTRY: the sprite row loop's
;          ds_entry (banks 4 and 5), bank6_entry + draw_rect_clip (6)
;   Out:   the entry's; X, Y as it leaves them
;   Post:  bank 7 paged again (page_logic)
; Once a sprite and once a rect (draw_sprite, erase_old, draw_dirty).  The write
; bank is the entry's business where it stores: ds_entry opens its window with A
; still the bank; draw_rect_clip stores nothing and draw_rect has its own.
; ----------------------------------------------------------------------------
call_bank:
        sta ROMSEL_CPY
        sta ROMSEL
        jsr BANKENTRY
        jmp page_logic
