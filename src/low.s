; ============================================================================
; Low RAM, $0140-$02FF, both machines: what has to be visible whatever bank is paged
; in.  The crossings between the banks, the Model B's interrupt stub (its body is in
; bank 7: engine.s isr_body) and the tile blitter's map row; engine.s's map_row, map_byte,
; map_put and page_logic land here too, and its LOWBSS (the buffers' state, the sprite
; list).  boot copies the code down from the BOOT piece.
; ============================================================================
        .segment "LOWCODE"

; ---------------------------------------------------------------- the crossings
; A bank cannot page another over itself, so every crossing is here: fixed thunks for
; what bank 7 calls in the others (call_bank, selbb, validate) and for the tile
; blitter's gather (map_strip).  No table, no dispatch in any bank.  ROMSEL_CPY is
; written before ROMSEL every time, so an interrupt in between puts back the bank
; being entered: the handler restores ROMSEL from it.

; ---------------------------------------------------------------- interrupts
; The Model B's: the chain step and the vsync work are in bank 7 with their tables,
; and this pages it in around them: page_logic inlined and a jmp each way, because
; every cycle before the step's first CRTC write is lead the chain's timing (VS2T's
; STUBLAT) has to allow for, in place of the hold loop the Master's handler has.  The
; body comes back to irq_ret from a step, to irq_vret from the vsync, which steps the
; title tune: its player is in the menus' image of bank 7, mus_on is set only while that
; image is in, and the vsync's sound_tick raises mus_tick.
  .if BHW                          ; (the Master's handler is in main RAM with its
irq_handler:                       ;  chain: engine.s)
        cld                        ; the NMOS 6502 keeps D through an interrupt: the
                                    ;  body's adc/sbc must not see the game's sed (BCD
                                    ;  score; the 65C02 clears D itself).  RTI puts it back
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        bankimm lda, BANK_LVL, 0   ; bank 7, for reading (page_logic's, inline: the
        sta ROMSEL_CPY             ; interrupt stores into no bank, so the write bank
        sta ROMSEL                 ; is left as it was -- cpu.inc)
        jmp isr_body
irq_vret:                          ; the vsync's way back: the tune's step, while it plays
        lda mus_tick
        beq irq_ret
        dec mus_tick               ; (1 -> 0: mus_on's value, which is 0 or 1)
        jsr music_tick             ; (bank 7: paged above)
irq_ret:                           ; a step's way back
        pla
        sta ROMSEL_CPY
        sta ROMSEL
        ldy irq_y
        ldx irq_x
        lda $FC
        rti
  .endif

; ---------------------------------------------------------------- the tile blitter's map
; draw_rect's row loop runs in bank 6 and reads the map in bank 5: the row pointer is arithmetic
; (a map is 32, 64, 128 or 256 tiles wide: row * 2^lw is row * 256 shifted right by
; map_shr = 8 - lw, which the loader sets from the header) and the strip copy is the
; one bank switch a tile row costs.
map_strip:                         ; (ptr) = the row's first tile: its gather, run in
        bankimm lda, BANK_MAP, 0   ; bank 5 beside the map (engine.s gather5), into
        sta ROMSEL_CPY             ; GATHERL/GATHERH here; bank 6 back (read only: no
        sta ROMSEL                 ; write bank: draw_rect's window, 6's, stays open)
        jsr gather5
page6:  bankimm lda, BANK_TILES, 0 ; (selbb and validate: page6 first; selbb the write
        sta ROMSEL_CPY             ; bank for what it stores in bank 6)
        sta ROMSEL
        rts

; bank 7's two calls a frame into bank 6 that are not the blitter's entry:
; select_backbuf (it patches draw_rect's ring operand) and scroll_validate (it draws the
; new strips with draw_rect itself)
selbb:  jsr page6
        wrsel BANK_TILES, 0        ; a write window: select_backbuf patches draw_rect
        jsr select_backbuf
        wrback 0, 1                ; (closed)
        jmp page_logic
validate:
        jsr page6                  ; (no write bank: scroll_validate stores into no
        jsr scroll_validate        ;  bank, and draw_rect opens and closes its own window)
        jmp page_logic

; ---------------------------------------------------------------- the direct switch
; Once a sprite and once a rect: page the bank, call its entry -- BANKENTRY, the start
; of banks 4, 5 and 6: the sprite row loop in 4 and 5, bank6_entry + draw_rect_clip in 6
; (each sets its own write bank) -- and page bank 7 back (page_logic).
call_bank:                         ; A = the bank (the write bank is set by the
        sta ROMSEL_CPY             ; entry itself where it stores: ds_entry -- A still
        sta ROMSEL                 ; holds the bank there; draw_rect_clip stores nothing)
        jsr BANKENTRY
        jmp page_logic

        .segment "LOWBSS"
GATHERH:  .res 21                  ; a tile row's gather (gather5): 21 tiles at most
clip_mask: .res 1                  ; $80 when the window has moved since the back buffer
                                    ;  last drew (select_backbuf; match_sprites)
krlo:     .res 1                   ; select_backbuf: the rows and columns the back buffer's
krhi2:    .res 1                   ;  last window and this one share (relative to this one;
kclo:     .res 1                   ;  the high bounds + 2), for match_sprites' moved records
kchi2:    .res 1
        .segment "LOWBSS2"          ; the rest of low RAM, above the code
GATHERL:  .res 21
        .segment "LOWBSS"
; the Model B's mirror bookkeeping (mirror.s): the tile blitter (bank 6), the sprite
; prologue and copy_partial (bank 7) note what they wrote to the ring's last slot row,
; mirror_copy (bank 7) reads it
  .if BHW
        .segment "LOWHW"            ; (after the shared)
MIRDTY:   .res 2                   ; per buffer: the row has been written since the copy
MIRLO:    .res 2                   ; and which chars of it (in slot chars, 0..79)
MIRHI:    .res 2
MIRWCX:   .res 2                   ; the wcxm the copy was made for
MIRMR:    .res 2                   ; and the mrow
        .segment "LOWBSS"
  .endif
; (the level's shape, map_shr and map_stride, and the tune's mus_on and mus_tick are
; zero page's: engine.s)
sprc_ok:  .res 1                   ; the resident sprites (SPRC) are in bank 4, and (the
sprx_ok:  .res 1                   ;  Master) SPRX in HAZEL/ANDY: ldprog.s
; What the interrupt stores, in main RAM so that it stores into no bank and needs no
; write bank of its own (cpu.inc: the write bank is 7's but for short windows) -- last
; in low RAM, so that nothing else moved for it
mus_dur:    .res 1                 ; the tune's player (music_tick, the menus' image;
MUSNOTE:   .res 3                  ;  mus_on is in zero page): the note's steps to go,
isr_t1:     .res 1                 ;  each channel's note, and its scratch
isr_t2:     .res 1
