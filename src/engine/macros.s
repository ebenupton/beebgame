
; ---------------------------------------------------------------- macros
.macro crtc reg, val
        lda #reg
        sta CRTC_IDX
        lda val
        sta CRTC_DAT
.endmacro

; ---------------------------------------------------------------- ring wrapping
; A screen address that runs off the end of the ring folds back to its start.  On the
; Master the ring runs to $8000 and the test is the sign bit; on the Model B it is a
; compare with the buffer's ring end (ringehi).
; These spell their skip with an anonymous label, so a caller that wants to branch
; over one has to count it: see spnext, which says :++ for that reason.  A named
; label here would end the enclosing routine's cheap-local scope.
.macro ringmod                      ; A = a map char row -> its ring slot
.if (RINGROWS & (RINGROWS - 1)) = 0
        and #(RINGROWS-1)
.else
        .local n1, n2               ; a row is 0..255 and the table RINGROWS*5 long
        cmp #RINGROWS*5             ; (bank 6's): two subtractions bring the row into
        bcc n1                      ; it, 141 bytes short of a 256-entry table
        sbc #RINGROWS*5
n1:     cmp #RINGROWS*5
        bcc n2
        sbc #RINGROWS*5
n2:     tax
        lda ringmodtab,x
.endif
.endmacro
.macro ringmod7                     ; the same, by subtraction: for bank 7 (calc_ring,
  .if ::BHW                        ; ringaddr7), which has no copy of the table
:       cmp #RINGROWS
        bcc :+
        sbc #RINGROWS
        bcs :-
:
  .else
        ringmod
  .endif
.endmacro
; The ring's end is a page boundary, so the fold test is a compare on the high
; byte alone.  A = high byte after moving forward, folded back into the ring.
; The cmp leaves the carry set on the path that reaches the sbc, so the fold needs
; no sec of its own whatever the caller was holding.
.macro ringtest cold                ; A = a high byte just moved forward: to cold if it
  .if ::BHW                        ; has run off the ring's end (ringfold there, out of
        cmp ringehi                 ; line; the common case falls through)
        bcs cold
  .else
        bmi cold                    ; RINGEND = $8000: N from A
  .endif
.endmacro
.macro ringfold p                   ; ringup's fold, for ringtest's cold path: A back into
  .if ::BHW                        ; the ring, p's low byte with it (the Model B)
        sbc #>RINGBYTES             ; C = 1 from ringtest's compare
        pha
        lda p
        sbc #<RINGBYTES
        sta p
        pla
        sbc #0
  .else
        sec
        sbc #>RINGBYTES
  .endif
.endmacro
.macro ringup p                     ; p names the pointer whose high byte A holds;
  .if ::BHW                        ; the Master's fold never needs it
        cmp ringehi                 ; the buffer's ring end, high byte (select_backbuf)
        bcc :+
        sbc #>RINGBYTES             ; C = 1 from the compare, and stays 1: A >= >RINGEND
        pha                         ; > >RINGBYTES.  The low byte folds by $80, which
        lda p                       ; borrows from A when p is below $80 (C still 1)
        sbc #<RINGBYTES
        sta p
        pla
        sbc #0
:
  .else
        bpl :+                      ; RINGEND = $8000: N from A (every caller's adc / inc a)
        sec
        sbc #>RINGBYTES
:
  .endif
.endmacro
.macro pagestep p, back             ; p's low byte has just carried out of a step forward
  .if ::BHW                        ; (under $80: p's low byte is now below it): its high
        inc p+1                     ; byte on one page, folded at the ring end.  C = 0 out
        lda p+1                     ; (and, without back, a single anonymous label, as ringup's).  With
        cmp ringehi                 ; back, the Model B's common case branches there
    .ifblank back
        bcc :+
    .else
        bcc back
    .endif
        sbc #>RINGBYTES+1           ; C = 1 from the compare: back a ring, less the low
        sta p+1                     ; byte's borrow -- it is below <RINGBYTES ($80), so
        lda p                       ; the fold always borrows, and the low byte's is +$80
        eor #<RINGBYTES
        sta p
        clc
        .assert <RINGBYTES = $80, error, "pagestep: the Model B's ring folds its low byte by $80"
    .ifblank back
:
    .endif
  .else
        inc p+1                     ; RINGEND = $8000: N from the inc, and the page after
        bpl :+                      ; the end is $80 exactly (a step under a page), the
        lda #>RINGBASE              ; low byte unchanged (<RINGBYTES = 0)
        sta p+1
        .assert <RINGBYTES = 0 && RINGEND = $8000, error, "pagestep: the Master's ring"
:       clc
  .endif
.endmacro
.macro ringdn                       ; A = high byte after moving back
        cmp #>RINGBASE
        bcs :+
        adc #>RINGBYTES
:
.endmacro

.macro spnext cold                 ; sp on one char (8 bytes), folding at the ring end.
        lda sp                      ; With cold: the page step is out of line there, in
        clc                         ; branch reach (spcold, the caller's), and the
        adc #8                      ; common case falls through
        sta sp
  .if .blank(cold)
        bcc :++                     ; past the fold's own anonymous label
        pagestep sp
:
  .else
        bcs cold
  .endif
.endmacro
.macro spcold back                  ; spnext's page step, out of line: back to `back`
        pagestep sp                 ; (C = 0)
        jmp back
.endmacro

; A = a run's chars (rc_n): X for its dispatch -- the Model B's, n, into a table of
; low bytes; the Master's, 2n, for jmp (abs,x) -- and tmp = its bytes, 8n (C = 0)
.macro RUNX
  .if BHW
        tax
        asl
  .else
        asl
        tax
  .endif
        asl
        asl
        sta tmp
.endmacro
