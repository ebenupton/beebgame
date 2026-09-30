; ============================================================================
; Low RAM, $0140-$02FF, both machines: what has to be visible whatever bank is paged
; in.  The crossings between the banks, the Model B's interrupt stub (its body is in
; bank 7: engine.s isr_body) and the tile blitter's map row; engine.s's maprow, mapbyte,
; mapput and pagelogic land here too, and its LOWBSS (the buffers' state, the sprite
; list).  boot copies the code down from the BOOT piece.
; ============================================================================
        .segment "LOWCODE"

; ---------------------------------------------------------------- the crossings
; A bank cannot page another over itself, so every crossing is here: fixed thunks for
; what bank 7 calls in the others (callbank, selbb, validate) and for the tile
; blitter's gather (mapstrip).  No table, no dispatch in any bank.  ROMSEL_CPY is
; written before ROMSEL every time, so an interrupt in between puts back the bank
; being entered: the handler restores from $F4, which is the MOS's own rule.

; ---------------------------------------------------------------- interrupts
; The Model B's: the chain step and the vsync work are in bank 7 with their tables,
; and this pages it in around them: pagelogic inlined and a jmp each way, because
; every cycle before the step's first CRTC write is lead the chain's timing (VS2T's
; STUBLAT) has to allow for, in place of the hold loop the Master's handler has.  The
; body comes back to irq_ret from a step, to irq_vret from the vsync, which steps the
; title tune: its player is in the menus' image of bank 7, MUSON is set only while that
; image is in, and the vsync's sound_tick raises MUSTICK.
  .if BHW                           ; (the Master's handler is in main RAM with its
irq_handler:                        ;  chain: engine.s)
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        bankimm lda, BANK_LVL, 0    ; bank 7, for reading (pagelogic's, inline: the
        sta ROMSEL_CPY              ; interrupt stores into no bank, so the write bank
        sta ROMSEL                  ; is left as it was -- cpu.inc)
        jmp isr_body
irq_vret:                           ; the vsync's way back: the tune's step, while it plays
        lda MUSTICK
        beq irq_ret
        dec MUSTICK                 ; (1 -> 0: MUSON's value, which is 0 or 1)
        jsr music_tick              ; (bank 7: paged above)
irq_ret:                            ; a step's way back
        pla
        sta ROMSEL_CPY
        sta ROMSEL
        ldy irq_y
        ldx irq_x
        lda $FC
        rti
  .endif

; ---------------------------------------------------------------- the tile blitter's map
; drawrect's row loop runs in bank 6 and reads the map in bank 5: the row pointer is arithmetic
; (a map is 32, 64, 128 or 256 tiles wide: row * 2^lw is row * 256 shifted right by
; mapshr = 8 - lw, which the loader sets from the header) and the strip copy is the
; one bank switch a tile row costs.
mapstrip:                           ; (ptr) = the row's first tile: its gather, run in
        bankimm lda, BANK_MAP, 0    ; bank 5 beside the map (engine.s gather5), into
        sta ROMSEL_CPY              ; GATHERL/GATHERH here; bank 6 back (read only: no
        sta ROMSEL                  ; write bank: drawrect's window, 6's, stays open)
        jsr gather5
page6:  bankimm lda, BANK_TILES, 0  ; (selbb and validate: page6 first; selbb the write
        sta ROMSEL_CPY              ; bank for what it stores in bank 6)
        sta ROMSEL
        rts

; bank 7's two calls a frame into bank 6 that are not the blitter's entry:
; select_backbuf (it patches drawrect's ring operand) and scroll_validate (it draws the
; new strips with drawrect itself)
selbb:  jsr page6
        wrsel BANK_TILES, 0         ; a write window: select_backbuf patches drawrect
        jsr select_backbuf
        wrback 0, 1                 ; (closed)
        jmp pagelogic
validate:
        jsr page6                   ; (no write bank: scroll_validate stores into no
        jsr scroll_validate         ;  bank, and drawrect opens and closes its own window)
        jmp pagelogic

; ---------------------------------------------------------------- the direct switch
; Once a sprite and once a rect: page the bank, call its entry -- BANKENTRY, the start
; of banks 4, 5 and 6: the sprite row loop in 4 and 5, bank6_entry + drawrect_clip in 6
; (each sets its own write bank) -- and page bank 7 back (pagelogic).
callbank:                           ; A = the bank (the write bank is set by the
        sta ROMSEL_CPY              ; entry itself where it stores: ds_entry -- A still
        sta ROMSEL                  ; holds the bank there; drawrect_clip stores nothing)
        jsr BANKENTRY
        jmp pagelogic

        .segment "LOWBSS"
GATHERH:  .res 21                   ; a tile row's gather (gather5): 21 tiles at most
        .segment "LOWBSS2"          ; the rest of low RAM, above the code
GATHERL:  .res 21
        .segment "LOWBSS"
; the Model B's mirror bookkeeping (mirror.s): the tile blitter (bank 6), the sprite
; prologue and copy_partial (bank 7) note what they wrote to the ring's last slot row,
; mirror_copy (bank 7) reads it
  .if BHW
        .segment "LOWHW"            ; (after the shared)
mirdty:   .res 2                    ; per buffer: the row has been written since the copy
mirlo:    .res 2                    ; and which chars of it (in slot chars, 0..79)
mirhi:    .res 2
mirwcx:   .res 2                    ; the wcxm the copy was made for
        .segment "LOWBSS"
  .endif
; (the level's shape, mapshr and MAPSTRIDE, and the tune's MUSON and MUSTICK are
; zero page's: engine.s)
sprc_ok:  .res 1                    ; the resident sprites (SPRC) are in bank 4, and (the
sprx_ok:  .res 1                    ;  Master) SPRX in HAZEL/ANDY: ldprog.s
; What the interrupt stores, in main RAM so that it stores into no bank and needs no
; write bank of its own (cpu.inc: the write bank is 7's but for short windows) -- last
; in low RAM, so that nothing else moved for it
MUSDUR:    .res 1                   ; the tune's player (music_tick, the menus' image;
MUSNOTE:   .res 3                   ;  MUSON is in zero page): the note's steps to go,
ISRT1:     .res 1                   ;  each channel's note, and its scratch
ISRT2:     .res 1
