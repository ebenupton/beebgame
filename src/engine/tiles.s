; ============================================================================
; engine/tiles.s -- bank 6: the tile blitter, and the frame's two other calls
; into the bank
;
; Bank 6 holds every level's tiles (from TILES, assets.inc) and the code that
; draws them into the current back buffer's ring.  The map is in bank 5: once a
; tile row, draw_rect calls low RAM's map_strip, which pages bank 5 in, runs
; gather5 (gather.s) into GATHERL/GATHERH in low RAM and pages bank 6 back; the
; row loop then draws the tile row's one or two char rows from those pairs.
;
; Entered three ways, each with bank 6 paged by low RAM (low.s): call_bank's
; jsr BANKENTRY lands on bank6_entry, the bank's first byte (erase_old's and
; draw_dirty's rects, frame.s); selbb calls select_backbuf and validate calls
; scroll_validate (render_frame's two fixed calls a frame).
;
; The Model B's code patches itself -- select_backbuf patches draw_rect's ring
; table operand (RINGHIOP), draw_rect's row loop its three dispatch branches --
; so those stores run inside a write window (cpu.inc wrsel/wrback: selbb opens
; one round select_backbuf, draw_rect opens and closes its own).  On the Master
; the window macros are empty and the dispatches are jmp (abs,x).
;
;   bank6_entry      BANKENTRY: falls into draw_rect_clip
;   draw_rect_clip   draw_rect with the rect clipped to the window
;   draw_rect        draw a rectangle of map chars (rc_x, rc_y, rc_w, rc_h)
;   scroll_validate  make the back buffer hold the window, drawing what it lacks
;   select_backbuf   point the blitter and the sprite records at the back buffer
;
; Segments: TIL6ENT (bank 6's first bytes), TILCODE (the rest of its code).
; Machines: both.  The .if BHW blocks are the Model B's software ring (two rings
; of 23 rows, folded in software, each with a mirror row), its self-patching
; dispatch and its write-select boards; the Master's side is its
; hardware-wrapped 32-row ring.
; Placement: profile-bound -- ringlo/ringhi/ringmod_tab and PAD PADB_T6/PADM_T6
; (pads.inc) put draw_rect's hot stretches in their pages, so nothing in TILCODE
; may move.
; ============================================================================

; The solid chain's bytes a line (draw_rect @schain: a sta (sp),y and its iny);
; the dispatch enters the chain this far in for every line it skips
CHAIN_STEP = 3
; krhi2 and kchi2 (low.s) hold the kept range's end (one past its last row or
; column) plus this: match_sprites (frame.s) adds a record's height to its row
; with C = 1 -- row + height + 1 -- and keeps the record while that is below
KHI_BIAS   = 2

; ----------------------------------------------------------------------------
; The blitter's unrolled blocks (draw_rect): CHARCPY copies a stored char,
; PCHAR fills one from a pair.  Each is expanded TILECHARS times in a group, in
; descending char order, so that the dispatch's entry at char n-1 does chars
; n-1..0.
; ----------------------------------------------------------------------------
; CPYN: one line, (tp),y -> (sp),y, then Y + 1.  13 cycles.
.macro CPYN
        lda (tp),y
        sta (sp),y
        iny
.endmacro
; CHARCPY c: char c's CHARBYTES lines, (tp)+8c -> (sp)+8c
;   Uses:  A Y
;   Keeps: X, C
;   Cost:  104 cycles (ldy 2, seven lines of 13, the last line 11); the Master's
;          char 0 101 (lda (tp) / sta (sp) 5 each, and no ldy before them)
; Char 0's first line is non-indexed: the Model B's ldaz is ldy #0 / lda (tp),y
; and its staz0 uses that Y; the Master's lda (tp) / sta (sp) need none; ldy1
; then makes Y = 1 either way (iny / ldy #1).  No read crosses a page: a stored
; char lies inside its TILEBYTES slot (a half's inside its row's page), and the
; slots are aligned.
.macro CHARCPY c
  .if c = 0
        ldaz tp
        staz0 sp
        ldy1
  .else
        ldy #CHARBYTES*c
        lda (tp),y
        sta (sp),y
        iny
  .endif
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        lda (tp),y                 ; line 7: no iny after it
        sta (sp),y
.endmacro
; PCHAR c: char c filled with the pair in tp -- even lines tp, odd lines tp+1
;   Uses:  A Y
;   Keeps: X, C
;   Cost:  70 cycles (two loads of 3, eight stores of 6, seven ldy # of 2 and an
;          iny); the Master's char 0 67 (its line 0 is sta (sp), 5, with no ldy)
; Each byte is loaded once and stored four times, every store with its own Y.
; The alternative, the two loads alternating down a dey chain, is 8 x (3 + 6) +
; 8 x 2 = 88 a char.
.macro PCHAR c
  .if c <> 0 || ::BHW
        lda tp
        ldy #CHARBYTES*c+6
        sta (sp),y
        ldy #CHARBYTES*c+4
        sta (sp),y
        ldy #CHARBYTES*c+2
        sta (sp),y
        ldy #CHARBYTES*c
        sta (sp),y
        lda tp+1
        iny
        sta (sp),y
        ldy #CHARBYTES*c+3
        sta (sp),y
        ldy #CHARBYTES*c+5
        sta (sp),y
        ldy #CHARBYTES*c+7
        sta (sp),y
  .else
        ; the Master's char 0: line 0 non-indexed, the even lines up to 6, then
        ; the odd lines down from 7 (Y ends 1, dead)
        lda tp
        sta (sp)
        ldy #2
        sta (sp),y
        ldy #4
        sta (sp),y
        ldy #6
        sta (sp),y
        lda tp+1
        iny
        sta (sp),y
        ldy #5
        sta (sp),y
        ldy #3
        sta (sp),y
        ldy #1
        sta (sp),y
  .endif
.endmacro

        .segment "TILCODE"
; ---------------------------------------------------------------- ring tables
; Placement: these tables and the PAD after them are what put draw_rect's hot
; stretches in their pages (pads.inc PADB_T6/PADM_T6: the pads were found for
; this layout), so they stay here, before draw_rect.
; ringlo/ringhi: ring slot r's address, RINGBASE + r*ROWBYTES, by slot.
  .if .not BHW                     ; hardware: the ring
; The Master: one table for both buffers -- main and shadow RAM share the
; addresses.
ringlo:
.repeat RINGROWS, r
        .byte <(RINGBASE + r*ROWBYTES)
.endrepeat
ringhi:
.repeat RINGROWS, r
        .byte >(RINGBASE + r*ROWBYTES)
.endrepeat
  .else
; The Model B: both rings' bases are at xx80 (defs.s asserts it), so one table
; of low bytes serves both and only the high bytes are per buffer:
; select_backbuf patches draw_rect's read of them (RINGHIOP) to ringhi or
; ringhi_b.
ringlo:
.repeat RINGROWS, r
        .byte <(RING_A + r*ROWBYTES)
.endrepeat
ringhi:                            ; ring A's: RINGHIOP's operand as assembled
.repeat RINGROWS, r
        .byte >(RING_A + r*ROWBYTES)
.endrepeat
ringhi_b:
.repeat RINGROWS, r
        .byte >(RING_B + r*ROWBYTES)
.endrepeat
; ringmod_tab: a map char row's ring slot, row mod RINGROWS, for ringmod
; (macros.s) and draw_rect's head.  RINGROWS*5 entries: the two subtractions
; before the lookup bring any row (0..255) under that.  (The Master's RINGROWS
; is 32: its ringmod is an and, and it has no table.)
ringmod_tab:
.repeat RINGROWS*5, i
        .byte i .mod RINGROWS
.endrepeat
  .endif
        PAD ::PADB_T6, ::PADM_T6   ; (pads.inc: draw_rect's placement)

; ----------------------------------------------------------------------------
; draw_rect: draw a rectangle of map chars into the current back buffer
;   In:    rc_x = the first map char column (16 bit, < 1024), rc_y = the first
;          map char row, rc_w = chars wide (1..ROWCHARS), rc_h = char rows (0:
;          nothing drawn); the level's map (map_stride, map_shr: lowram.s
;          map_row) and its tiles in this bank; the loader's patches (SOLIDF,
;          HPAIR0/1, FLATTAB, the gather's shape)
;   Out:   rc_h = 0; the rect's chars drawn; rc_sp = sp = the char row after
;          the rect's last
;   Uses:  A X Y, sp, tp, ptr, cnt, rc_sp, rc_tx0, rc_nt, rc_sc0, rc_ro0,
;          rc_sub, rc_gi, rc_lim, row_off, row_bit; GATHERL/GATHERH (through
;          map_strip)
;   Pre:   bank 6 paged (call_bank's or validate's, low.s); rc_x..rc_x+rc_w-1
;          inside the window (the Model B's mirror notes take the column less
;          wcx as a byte)
;   Post:  bank 6 paged again (map_strip pages 5 in and 6 back once a tile row);
;          the Model B: the write bank is 7's again (the window below)
;   Cost:  a stored char 104 cycles (the Master's first of a run 101), a filled
;          char 70 (67), the solid 8 a byte, 64n - 2 a run of n chars; plus a
;          run's dispatch, and a map_strip (two bank switches and the gather) a
;          tile row
;
; Per rect: the invariants once (tx0, tiles-1, the first run's limit and char
; offset), the first row's screen address, the map row pointer.  Per tile row:
; one map_strip (the gather) and one or two char rows (@drawrow).  Per char row:
; runs -- a run is the chars of one tile in this row, TILECHARS at most --
; dispatched by kind from the pair (defs.inc GH_*, GL_*):
;   GATHERH bit 7 set   case T, a stored tile: its page (GATHERL its offset)
;   GATHERH = 0         case S, the level's solid (id 0): one byte, SOLIDF, down
;                       every line
;   GATHERH = GH_FLAT   case X, a flat tile or the other solid: a pair from
;                       FLATTAB
;   GATHERH below it    case X, a half tile: its page less GH_TILE (GATHERL:
;                       its row and kind) -- one char row stored, the other a
;                       pair from the level's palette, or the stored row again
; and entered into an unrolled block by the run's length (1..TILECHARS chars).
; The gather's encoding is gather.s's.
;
; Invariants an editor must keep:
; - A run never crosses the ring end.  A row may straddle it, but a ring row is
;   ROWCHARS chars and the ring a whole number of them, so the end falls on a
;   map column that is a multiple of ROWCHARS -- a tile boundary, where a run
;   starts.  A run can only END exactly there, which carries sp into a new page:
;   @spcarry folds it (pagestep).  So the runs have no wrap test.
; - runn leaves C = 0 on both machines (macros.s); every block keeps X and C,
;   so @advsp's sbc counts on C = 0 and reads the run's length back through X
;   from @run1/@run8 (X = n x RUNXS: 2n on the Master, for its jmp (abs,x)).
;   The blocks are the same code on both machines; only the dispatch into them
;   differs.
; - rc_lim: the chars the current run may take -- TILECHARS - (rc_x & 3) for a
;   row's first run (rc_sc0, set per rect), TILECHARS for the later ones
;   (@runnext).
; - @s0f's operand is SOLIDF and @hp0/@hp1's are HPAIR0/HPAIR1: the loader
;   patches them (ldprog.s).  Their labels must stay: build.sh finds @s0f in
;   game.dbg, and the HPAIR equates below name @hp0.
; - The Model B's dispatch patches a branch's offset into the code, so all of
;   draw_rect to @done is a write window into bank 6.  Each branch sits right
;   before its blocks, which share its page (asserted after the blocks;
;   ringmod_tab and the pad place them), so a taken branch costs what a jmp
;   would, 3 cycles.
; - Case X is in two pieces: its test (@xkind, right after this routine's rts,
;   within reach of @run's bne) and its body (@hfill .. @f7, after case T's).
; ----------------------------------------------------------------------------
draw_rect:
        lda rc_h
        bne :+
        rts
:
        ; ---- the first char row's screen address: rc_sp = sp = rc_x*8 + its
        ; ring slot's, folded at the ring end.  First, before any @ label: the
        ; Model B's RINGHIOP := below ends a cheap-label scope, so here it
        ; splits nothing.  (The sprite prologue has its own copy in bank 7:
        ; kernel.s ring_addr7.)
        lda rc_y
  .if BHW                          ; hardware: the ring
        ; ringmod's body (macros.s) with the slot read straight into X: a row
        ; under RINGROWS*5 takes neither subtraction
        cmp #RINGROWS*5
        bcc @slot
        sbc #RINGROWS*5            ; C = 1 from the cmp
        cmp #RINGROWS*5
        bcc @slot
        sbc #RINGROWS*5
@slot:  tay
        ldx ringmod_tab,y          ; X = the row's ring slot
  .else
        ringmod                    ; the row's ring slot: and #RINGROWS-1
        tax
  .endif
        ; ---- tx0 = rc_x >> 2, a per-rect invariant, worked out in A with the
        ; two high bits brought in by cpy (Y is the scratch: X holds the slot)
        lda rc_x+1
        lsr                        ; C = bit 8 of rc_x, A = bit 9 (rc_x+1 <= 3)
        tay
        lda rc_x
        ror                        ; bit 8 in
        cpy #1                     ; C = bit 9
        ror                        ; A = tx0 (a map is 256 tiles wide at most)
        sta rc_tx0
        ; ---- sp = rc_x*8: its high byte is tx0 >> 3 (rc_x < 1024), its low
        ; byte rc_x << 3
        lsr
        lsr
        lsr
        sta sp+1
        lda rc_x
        asl
        asl
        asl
        clc
        adc ringlo,x               ; + the slot's address
        sta sp
  .if .not BHW                     ; hardware: the ring (the Master's ringup leaves
        sta rc_sp                  ;  sp's low byte; the Model B's fold moves it)
  .endif
        lda sp+1
  .if BHW                          ; hardware: the ring
RINGHIOP := * + 1                  ; the adc's operand: the buffer's high-byte table,
  .endif                           ;  ringhi or ringhi_b (select_backbuf patches it)
        adc ringhi,x
        ringup sp                  ; fold back into the ring (macros.s)
        sta sp+1
        sta rc_sp+1
  .if BHW                          ; hardware: the ring (the fold moved sp's low byte)
        lda sp
        sta rc_sp
  .endif
  .if BHW                          ; hardware: the write-select boards
        ; ---- open the write window, to @done: the runs patch their dispatch
        ; branches (cpu.inc; the tags tell this site from the bank's others).
        ; A = bank 6's number, which is paged already: harmless on a plain
        ; machine.
        bankimm lda, BANK_TILES, BANK_TILES, 3
        wrsel BANK_TILES, BANK_TILES, 3
  .endif
  .if BHW                          ; hardware: the ring's mirror row
        ; ---- the mirror's notes: a rect that touches the map row the mirror
        ; follows (mrow, calc_ring) says which window columns of it it wrote
        ; (MIRDIRTY_BODY, macros.s: A = the first, X = the last)
        lda mrow
        sec
        sbc rc_y
        cmp rc_h                   ; mrow - rc_y < rc_h: the rect holds mrow
        bcs @nomir                 ; (mrow below rc_y wraps to a large value)
        lda rc_x                   ; C = 0 from the bcs: the sbc takes one more --
        sbc wcx                    ;  the window column less one (rc_x - wcx fits a
        tay                        ;  byte: rects are window clipped)
        clc
        adc rc_w
        tax                        ; X = the last window column
        iny
        tya                        ; A = the first
        MIRDIRTY_BODY @nomir
@nomir:
  .endif
        ; ---- the other per-rect invariants.  tiles-1 =
        ; ((rc_x + rc_w - 1) >> 2) - tx0 = ((rc_x & 3) + rc_w - 1) >> 2: at
        ; most 3 + 80 - 1 = 82, one byte, so no 16-bit shift and no tx1.
        lda rc_x
        and #TILECHARS-1
        tax                        ; X = rc_x & 3
        asl
        asl
        asl                        ; C = 0 (X < 4)
        sta rc_ro0                 ; the first run's char offset, (rc_x & 3) << 3
        txa
        eor #TILECHARS-1
        adc #1                     ; (C = 0) TILECHARS - (rc_x & 3): <= 4, C stays 0
        sta rc_sc0                 ; the first run's limit (@drawrow takes it)
        dex                        ; the -1 first: X = (rc_x & 3) - 1 ($FF for 0: the
        txa                        ;  add below wraps, and only the byte is wanted)
        adc rc_w                   ; (C = 0) <= 82
        lsr
        lsr
        sta rc_nt                  ; tiles-1
        ; ---- the map row pointer: built once here (map_row's arithmetic) and
        ; stepped by the stride a tile row (@nextrow)
  .if TALLMAP
        ; Char rows are kept a byte (the ring's modulus needs no more) but the
        ; map row needs more: the rect's full row is the window's, wcyh:wcy,
        ; plus its offset from it.  Only the carry of that add is wanted: its
        ; low byte is rc_y.
        lda rc_y
        sec
        sbc wcy                    ; the offset, -128..127 (ldy, cmp, dey keep A)
        ldy #0
        cmp #$80
        bcc :+
        dey                        ; Y = its sign
:       clc
        adc wcy                    ; (= rc_y: only the carry is wanted)
        tya
        adc wcyh
        lsr                        ; C = bit 8 of the full row
        lda rc_y
        ror                        ; the tile row: the full row >> 1
  .else
        lda rc_y
        lsr                        ; the tile row
  .endif
        jsr map_row                ; (X kept) A = map_ptr+1, C = 0: the map is 8K at
        sta ptr+1                  ;  LV_MAP, so its add never carries
        lda map_ptr
        adc rc_tx0                 ; tx0 < the map's width, and a row is aligned to
        sta ptr                    ;  its width: no carry out of the low byte
        ; ---- only a rect's first tile row can start on an odd char row --
        ; @nextrow always lands even -- so the test is here, once, not in the
        ; loop
        lda rc_y
        lsr                        ; C = bit 0: an odd char row
        bcc @rowy
        jsr map_strip              ; odd: the first tile row's gather, then its second
        bpl @second                ; always: map_strip ends lda #bank, sta
                                   ;  ROMSEL, rts; a bank is 0..15, so N = 0
        ; ---- per tile row: the gather, run in bank 5 beside the map (gather5),
        ; into GATHERL/GATHERH in low RAM.  The write bank stays this window's,
        ; 6: the gather stores into no bank, nor does an interrupt (cpu.inc).
@rowy:
        jsr map_strip
        ; ---- draw this char row, and (without re-gathering) the odd row of the
        ; same tile row
        stz rc_sub                 ; the tile's top char row: offset 0
        lda rc_ro0
        sta row_off
        lda #GL_FILLTOP            ; the char row as a half tile's fill bit (GATHERL
        sta row_bit                ;  bit 3 the top, bit 4 the bottom)
        jsr @drawrow
        dec rc_h
        beq @done
@second:
        lda #HALFBYTES             ; the tile's bottom char row: offset 32
        sta rc_sub
        ora rc_ro0
        sta row_off
        lda #GL_FILLBOT
        sta row_bit
        jsr @drawrow
        dec rc_h
        beq @done
@nextrow:
        ; ---- one map row on
        lda ptr
        clc
        adc map_stride
        sta ptr
        lda ptr+1
        adc map_stride+1
        sta ptr+1
        ; ---- @rowy's body again, in line: the loop closes on a bne to @second,
        ; not a jmp back
        jsr map_strip
        stz rc_sub
        lda rc_ro0
        sta row_off
        lda #GL_FILLTOP
        sta row_bit
        jsr @drawrow
        dec rc_h
        bne @second                ; (0: falls into @done)
@done:  wrback BANK_TILES, 4       ; the write window's end
        rts

        ; ---- case X's test: @run's bne, with A = GATHERH (bit 7 clear, not 0):
        ; GH_FLAT a flat or the other solid (to @flat), below it a half tile
        ; (its page less GH_TILE).  Here, right after draw_rect's rts, because
        ; @run's bne must reach it; the case's body is @hfill .. @f7, after
        ; case T's.
@xkind: cmp #GH_FLAT
        bcc @half                  ; below GH_FLAT: a half (C = 0 on to @hfill)
        jmp @flat
@half:  ora #GH_TILE               ; the half's page
        sta tp+1
        lda GATHERL,x              ; is this char row its fill? (bit 3 the top, bit 4
        bit row_bit                ;  the bottom; A kept: GATHERL,x for @hcopy)
        beq @hcopy
        jmp @hfill
        ; no: the stored row.  tp's low byte is GATHERL's row bits (GL_ROWMASK,
        ; (k & 7) << 5) over row_off's char offset without the row's 32: the two
        ; eors merge them.
@hcopy: eor row_off
        and #GL_ROWMASK
        eor row_off                ; (A & GL_ROWMASK) | (row_off & ~GL_ROWMASK)
        jmp @tpsta

; ----------------------------------------------------------------------------
; @drawrow: one char row of the rect, run by run
;   In:    sp = rc_sp = the row's screen address (draw_rect's head set it for
;          the rect's first row, @rowdone for each after: nothing between
;          touches sp); rc_sub, row_off, row_bit set for the row;
;          GATHERL/GATHERH = the tile row's gather; rc_sc0, rc_w
;   Out:   rc_sp = sp = the next char row's address (+ROWBYTES, folded at the
;          ring end); C undefined
;   Uses:  A X Y, cnt, rc_gi, rc_lim, tp
; ----------------------------------------------------------------------------
@drawrow:
        ; ---- the run state: the first run's limit, all the row's chars left
        lda rc_sc0
        sta rc_lim
        lda rc_w
        sta cnt                    ; chars left in the row
        clc
        ldx #0                     ; the run's index into GATHERL/H, kept in rc_gi
        ; ---- a run: its kind from GATHERH.  Bit 7 set: a stored tile's page.
        ; Clear: a fill -- 0 the level's solid, straight on (the commonest run);
        ; else case X (@xkind, behind draw_rect's rts).
@run:
        stx rc_gi                  ; (zp, 2 bytes: @runnext stores it itself and
        lda GATHERH,x              ;  enters at @run+2)
        bmi @tile
        SAMEPAGE *, @tile
        bne @xkind
        ; ---- case S: id 0, the level's solid, the commonest run.  One byte,
        ; the loader's (SOLIDF), stored down every line of the run's chars.
@srun:  runn                       ; X = the run's chars (x RUNXS), C = 0
@sdisp:
        ; ---- the chain that follows: TILECHARS*CHARLINES stores counting Y up,
        ; an iny between each, entered at a store with Y = 0 so that it stores
        ; lines 0 to 8n-1, skipping the first 32 - 8n stores (CHAIN_STEP bytes
        ; each).  8 cycles a byte (sta (sp),y 6, iny 2), 64n - 2 a run, and one
        ; ldy.  The Model B enters by a patched branch, taken (C = 0 from runn),
        ; its offsets in @sto; the Master by jmp (abs,x) through @st.
        ldy #0
  .if BHW                          ; CPU spelling: the dispatch
        lda @sto-1,x
        sta @sj+1
  .endif
@s0f:   lda #0                     ; SOLIDF: the fill byte (the label is build.sh's)
  .if BHW                          ; CPU spelling: the dispatch
@sj:    bcc @schain
  .else
        jmp (@st-2,x)
  .endif
@schain:
.repeat TILECHARS*CHARLINES-1
        sta (sp),y
        iny
.endrepeat
        sta (sp),y
        jmp @advsp
  .if BHW                          ; CPU spelling: the dispatch
        .assert @sj+2 = @schain, error, "case S: the chain must follow its branch"
        .assert >@schain = >(@schain+(TILECHARS-1)*CHARLINES*CHAIN_STEP), error, "case S: the chain's entries straddle a page"
  .endif

        ; ---- case T: a stored tile.  tp = its address (the tiles are in this
        ; bank, paged for the whole rect); the stored row of a half comes in at
        ; @tpsta.
@tile:  sta tp+1                   ; the tile's page
        lda GATHERL,x
        ora row_off                ; a full tile's low byte is (slot & 3) << 6: its
@tpsta: sta tp                     ;  bits 0-5 are clear for the row and char offset
@trun:  runn                       ; X = the run's chars (x RUNXS), C = 0
@tdisp:
  .if BHW                          ; CPU spelling: the dispatch
        ; the entry's offset into the branch, which is taken (C = 0).  The
        ; blocks follow it in one page (asserted with the tables), so it costs a
        ; jmp's 3.
        lda @tto-1,x
        sta @tj+1
@tj:    bcc @t31
  .else
        jmp (@tt-2,x)
  .endif
        ; ---- the copy blocks (CHARCPY above): @t31 copies chars 3..0, @t23
        ; 2..0, and so on; @t7 falls into @advsp -- the hottest copy pays no jmp
        ; (the other two groups end in jmp @advsp).
@t31:   CHARCPY 3
@t23:   CHARCPY 2
@t15:   CHARCPY 1
@t7:    CHARCPY 0

; ----------------------------------------------------------------------------
; @advsp: after a run -- count its chars off and step sp past them
;   In:    X = n x RUNXS (the run's chars, kept by the blocks); C = 0 (runn's,
;          kept by the blocks); cnt = chars left before this run
;   Out:   cnt -= n and sp += 8n, then the next run at @run+2;  or, at the row's
;          last run, @rowdone
; With C = 0 the sbc gives cnt - n - 1: negative only when this run took the
; rest (n = cnt), so bmi is the row's end, and sp is not stepped (dead: @rowdone
; steps rc_sp).  Otherwise C = 1, and the adc #0 puts the 1 back and leaves
; C = 0.
; ----------------------------------------------------------------------------
@advsp: lda cnt
        sbc @run1-RUNXS,x          ; n, by X
        bmi @rowdone               ; the row's last run
        adc #0                     ; C = 1: +1 back, and C = 0
        sta cnt
        lda sp
        adc @run8-RUNXS,x          ; sp += 8n
        sta sp
        bcs @spcarry               ; a page on: out of line, after @rowdone
        ; ---- the next run: the later tiles of the row are whole and start at
        ; the tile's column 0
@runnext:                          ; C = 0 (the adc's, or pagestep's)
        ldx rc_gi                  ; the row's first run? only it leaves rc_lim and
        bne @later                 ;  row_off to set (a later run's are TILECHARS and
        lda #TILECHARS             ;  rc_sub already)
        sta rc_lim
        lda rc_sub
        sta row_off
@later: inx
        stx rc_gi
        jmp @run+2                 ; past @run's stx rc_gi (zp, 2 bytes): X = rc_gi
        ; ---- the row done: the next char row, +ROWBYTES with the ring fold
@rowdone:
        lda rc_sp
        adc #<ROWBYTES             ; C = 0: @advsp's sbc borrowed
        sta rc_sp
        sta sp                     ; (sp too: the next row starts there)
        lda rc_sp+1
        adc #>ROWBYTES
        ringtest @rfold            ; the fold out of line (macros.s)
        sta rc_sp+1
        sta sp+1
        rts
@rfold:
  .if BHW                          ; hardware: the ring (ringup's fold, in line)
        sbc #>RINGBYTES            ; C = 1 from ringtest's compare
        pha
        lda rc_sp
        sbc #<RINGBYTES            ; the low byte folds too: sp's with rc_sp's
        sta rc_sp
        sta sp
        pla
        sbc #0                     ; the low byte's borrow
  .else
        sbc #>RINGBYTES-1          ; C = 0: the adc #>ROWBYTES cannot carry (< $80)
  .endif
        sta rc_sp+1
        sta sp+1
        rts
        ; ---- sp carried into a new page (every 32 chars): the page step,
        ; folded if the page is the ring's end -- which a run can only reach
        ; exactly (draw_rect's first invariant).  C = 0 out.  The Model B's
        ; pagestep branches to @runnext itself in the common case and falls to
        ; the jmp when it folds; the Master's always falls to it.
@spcarry:
        pagestep sp, @runnext
        jmp @runnext

; ----------------------------------------------------------------------------
; @hfill / @flat: case X's body -- a run filled from a pair, no source bytes
;   In:    X = rc_gi, the run's index into GATHERL/GATHERH; at @hfill also
;          C = 0 (@xkind's bcc @half; the Model B's bcc @frun needs it)
;   Out:   the run's chars filled, then @advsp with X = n x RUNXS and C = 0
;          (runn's; the PCHAR blocks keep both)
;   Uses:  A X Y, tp
; Its test is @xkind, behind draw_rect's rts.  A half tile's fill row, a flat
; tile or the other solid: a pair in tp, even lines tp, odd lines tp+1, down
; every char (tp is otherwise unused on this path).  Two ways in: @hfill, the
; half's pair from the level's palette; @flat, the pair from FLATTAB.  Both
; reach @frun's dispatch -- the Model B's @hfill by a branch (the rarer way:
; @flat falls through), the Master's with its own runn and jmp (abs,x), a jmp
; the less.
; ----------------------------------------------------------------------------
@hfill:
        ; ---- a half's fill: its colour in the level's palette, GATHERL's bits
        ; 0-2.  The loader patches both loads' operands (HPAIR0, HPAIR1: the
        ; palette's first bytes, then its second).
        lda GATHERL,x
        and #GL_COLMASK
        tay
@hp0:   lda $FFFF,y                ; HPAIR0
        sta tp
@hp1:   lda $FFFF,y                ; HPAIR1
        sta tp+1
  .if BHW                          ; CPU spelling: the dispatch
        bcc @frun                  ; C = 0 from @xkind's bcc @half (nothing between
        SAMEPAGE *, @frun          ;  touches it)
  .else
        runn
        jmp (@ft-2,x)
  .endif
        ; ---- a flat tile or the other solid: the pair from FLATTAB, by GATHERL
@flat:  ldy GATHERL,x
        lda FLATTAB,y
        sta tp
        lda FLATTAB+1,y
        sta tp+1
@frun:  runn                       ; X = the run's chars (x RUNXS), C = 0
@fdisp:
  .if BHW                          ; CPU spelling: the dispatch
        ; the entry's offset into the branch, taken as C = 0 (A is dead: every
        ; entry loads tp).  The blocks follow it in one page (asserted with the
        ; tables).
        lda @fto-1,x
        sta @fj+1
@fj:    bcc @f31
  .else
        jmp (@ft-2,x)
  .endif
        ; ---- the fill blocks (PCHAR above): @f31 fills chars 3..0, and so on
@f31:   PCHAR 3
@f23:   PCHAR 2
@f15:   PCHAR 1
@f7:    PCHAR 0
        jmp @advsp                 ; (case T's @t7 falls into it instead)

; ---------------------------------------------------------------- dispatch
; Each group's entries by the run's chars, n = 1..TILECHARS: case S @sto/@st,
; case T @tto/@tt, case X @fto/@ft.  The Model B (the ..to tables): the entry's
; offset from its patched branch, which sits right before its blocks (the
; solid's: the chain's store for line 32 - 8n); each group's entries share a
; page with the branch's next byte, so a taken branch costs a jmp's 3 cycles.
; The Master (..t): jmp (abs,x) with X = 2n, through the entries' addresses.
; @run1 and @run8 hold a run's chars and bytes, n and 8n, for @advsp, indexed by
; X = n x RUNXS: the Master's a byte apart.
  .if BHW                          ; CPU spelling: the dispatch
@tto:   .byte @t7-(@tj+2), @t15-(@tj+2), @t23-(@tj+2), @t31-(@tj+2)
@fto:   .byte @f7-(@fj+2), @f15-(@fj+2), @f23-(@fj+2), @f31-(@fj+2)
        .assert @tj+2 = @t31 && @fj+2 = @f31, error, "a dispatch branch must sit before its blocks"
        .assert @t7-(@tj+2) <= 127 && @f7-(@fj+2) <= 127, error, "a dispatch's blocks run past its reach"
        .assert >@t7 = >@t31 && >@f7 = >@f31, error, "a dispatch group straddles a page"
@sto:   .byte (TILECHARS-1)*CHARLINES*CHAIN_STEP, (TILECHARS-2)*CHARLINES*CHAIN_STEP
        .byte CHARLINES*CHAIN_STEP, 0
@run1:  .byte 1, 2, 3, 4
@run8:  .byte CHARBYTES, 2*CHARBYTES, 3*CHARBYTES, 4*CHARBYTES
  .else
@tt:    .word @t7, @t15, @t23, @t31
@ft:    .word @f7, @f15, @f23, @f31
@st:    .word @schain+(TILECHARS-1)*CHARLINES*CHAIN_STEP
        .word @schain+(TILECHARS-2)*CHARLINES*CHAIN_STEP
        .word @schain+CHARLINES*CHAIN_STEP
        .word @schain
@run1:  .byte 1, 0, 2, 0, 3, 0, 4
@run8:  .byte CHARBYTES, 0, 2*CHARBYTES, 0, 3*CHARBYTES, 0, 4*CHARBYTES
  .endif
        .assert >@run1 = >(@run8+3*RUNXS), error, "@run1/@run8 straddle a page"

; ---------------------------------------------------------------- patch points
; HPAIR0/HPAIR1: @hfill's two loads of a half's fill pair, by its colour.  The
; level's palette (HPAIR_LEN bytes: 8 first bytes, then 8 second) sits above the
; halves, wherever the level's tiles ended, and the loader patches the operands
; (ldprog.s).  Defined here, after the row loop, because := ends the cheap-label
; scope (a label would too): every @ reference of draw_rect is above this line,
; and HPAIR1 goes by HPAIR0 because the first := has already ended it.  :=
; rather than = puts them in labels.txt, where build.sh reads them.  SOLIDF,
; @s0f's operand, has no equate: build.sh finds the cheap label in game.dbg
; (which lists them) -- a symbol for it here would end the scope.
        .assert @hp1 = @hp0 + 5, error, "HPAIR1 must be 5 bytes past HPAIR0"
HPAIR0  := @hp0 + 1
HPAIR1  := HPAIR0 + 5

; ----------------------------------------------------------------------------
; scroll_validate: make the back buffer hold the window, drawing only the
; strips it lacks
;   In:    cur_buf; wcx (16 bit), wcy = the window;
;          BUF_CXL/BUF_CXH/BUF_CY[cur_buf] = the window the buffer holds
;          (BUF_CXH = BUF_INVALID: it holds nothing usable -- lv_reset,
;          mark_dirty)
;   Out:   BUF_CXL/BUF_CXH/BUF_CY[cur_buf] = the window;  the buffer holds it
;   Uses:  A X Y, w16, w16b, and draw_rect's (its rc_ arguments and work)
;   Pre:   bank 6 paged (low RAM's validate: no write bank -- this stores into
;          no bank, and draw_rect opens its own window)
; dx = wcx - BUF_CXL (16 bit): |dx| < ROWCHARS draws the new columns, a strip
; of |dx| columns and BUFROWS rows (at wcx for a move left, at wcx + ROWCHARS -
; dx for one right).  dy = wcy - BUF_CY: |dy| < BUFROWS draws the new rows, a
; strip of |dy| rows the window's full width (at wcy for a move up, at wcy +
; BUFROWS - dy for one down).  Anything bigger -- or an invalid buffer, whose
; BUF_CXH makes dx's high byte neither 0 nor $FF -- redraws the whole window
; (@full).  dx = 0 and dy = 0 draws nothing and leaves the buffer's record of
; the window as it is (@same: it is the window).  The dy < 0 block is written
; twice (@dx0, and after the columns) so that neither path pays a jmp.
; ----------------------------------------------------------------------------
scroll_validate:
        ldx cur_buf
        ; ---- dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; ---- dx = wcx - BUF_CXL
        lda wcx
        sec
        sbc BUF_CXL,x
        sta w16
        lda wcx+1
        sbc BUF_CXH,x
        sta w16+1
        ; ---- |dx| >= ROWCHARS: the whole window (A = w16+1, flags the sbc's)
        beq @dxpos
        cmp #$FF
        bne @full
        lda w16
        cmp #<(1-ROWCHARS)
        bcc @full
        ; ---- dx < 0, a move left: columns wcx .. wcx-dx-1, all BUFROWS rows
        eor #$FF                   ; (A = w16 still)
        adc #0                     ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bcc @docols                ; (always: C = 0 from the adc)
        ; ---- the whole window: the dy < 0 tail with rc_h = BUFROWS and rc_y =
        ; wcy.  Here, between two unconditional exits, in reach of every branch
        ; to it.
@full:
        clc
        lda #BUFROWS
        bcc @fullt                 ; (always: C = 0 from the clc)
        ; ---- dx = 0: the dy tests, X still cur_buf
@dx0:   lda w16b
        beq @same                  ; dx = 0 and dy = 0: nothing to draw
        bpl @dypos
        cmp #<-(BUFROWS-1)         ; -dy >= BUFROWS: the whole window (as dy > 0 does)
        bcc @full
        eor #$FF
        adc #0                     ; C = 1 from the cmp: A = -w16b, and C = 0
@fullt: sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                ; (always: C = 0 from the adc, or @full's clc)
@dxpos: lda w16
        beq @dx0                   ; dx = 0
        cmp #ROWCHARS
        bcs @full                  ; not taken: C = 0 for the adc
        ; ---- dx > 0, a move right: dx columns from wcx + ROWCHARS - dx
        sta rc_w
        eor #$FF                   ; A = 255 - rc_w, C = 0 still
        adc #ROWCHARS              ; A = ROWCHARS-1-rc_w, C = 1 (rc_w <= 79)
        adc wcx                    ; + wcx + 1: wcx + ROWCHARS - rc_w
        sta rc_x
        lda wcx+1
        adc #0
        sta rc_x+1
@docols:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        jsr draw_rect
        ; ---- then dy, as at @dx0
        lda w16b
        beq @done
        bpl @dypos
        ; ---- dy < 0, a move up: rows wcy .. wcy-dy-1
        cmp #<-(BUFROWS-1)         ; -dy >= BUFROWS: the whole window (as dy > 0 does)
        bcc @full
        eor #$FF
        adc #0                     ; C = 1 from the cmp: A = -w16b, and C = 0
        sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                ; (always: C = 0 from the adc)
        ; ---- dy > 0, a move down: dy rows from wcy + BUFROWS - dy
@dypos: cmp #BUFROWS
        bcs @full                  ; not taken: C = 0 for the adc
        sta rc_h
        eor #$FF                   ; A = 255 - rc_h, C = 0 still
        adc #BUFROWS               ; A = BUFROWS-1-rc_h, C = 1 (rc_h <= BUFROWS-1)
        adc wcy                    ; + wcy + 1: wcy + BUFROWS - rc_h
  .if .not TALLMAP
        ; Rows are bytes.  A map 256 rows tall (128 tiles) has the window's
        ; last buffer row at 256 when the window sits on the bottom (wcy = 256 -
        ; VISROWS); asked for here (dy = 1) that row wraps to 0, and draw_rect's
        ; head puts a rect's FIRST row by its byte -- slot 0 on the Model B,
        ; which is row 253's (253 mod 23 = 0), a visible row.  (A rect that only
        ; runs into row 256 is safe: @rowdone steps to the next slot.)  Row 256
        ; is never shown -- there is no fine scroll on the bottom -- so the
        ; strip is dropped.
        bcs @done                  ; wcy + BUFROWS - rc_h >= 256: nothing to draw
  .endif
        sta rc_y
        ; ---- rows rc_y .., rc_h of them, the window's full width
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #ROWCHARS
        sta rc_w
        jsr draw_rect              ; (falls into @done)
        ; ---- the buffer now holds the window
@done:
        ldx cur_buf
        lda wcy
        sta BUF_CY,x
        lda wcx
        sta BUF_CXL,x
        lda wcx+1
        sta BUF_CXH,x
@same:  rts                        ; (dx = 0 and dy = 0: the buffer's record is right)

; ----------------------------------------------------------------------------
; select_backbuf: point the blitter at the current back buffer, and the sprite
; records at its half
;   In:    cur_buf (0/1); wcx, wcy = the window;
;          BUF_CXL/BUF_CXH/BUF_CY[cur_buf] = the window the buffer last drew
;          (scroll_validate updates them later)
;   Out:   the Master: ACCCON's X bit = cur_buf (CPU access to shadow RAM for
;          buffer 1); the Model B: ringbhi, ringehi, ringe3 = the buffer's
;          ring's base page, end page and last slot's page, and RINGHIOP
;          (draw_rect's ring high-byte table) patched to the buffer's; both:
;          clip_mask = REC_CLIP if the window has moved since the buffer last
;          drew, else 0; krlo, krhi2, kclo, kchi2 = the rows and columns the old
;          window and this one both hold; recb (TIGHTBSS) or recp = the buffer's
;          first sprite record
;   Uses:  A X Y (X = cur_buf out)
;   Pre:   bank 6 paged, and on the Model B a write window to it open for the
;          RINGHIOP store (low RAM's selbb, cpu.inc)
; The shared range is for match_sprites (frame.s): once the window has moved, a
; record is kept only inside it -- the rest of the buffer is this frame's
; strips, or slots reused since.  With d = the old window less the new, the rows
; both hold are max(0, d) .. min(BUFROWS, BUFROWS + d) - 1, as krlo .. krhi2 -
; KHI_BIAS (columns kclo .. kchi2 - KHI_BIAS with ROWCHARS); krlo = $FF (or
; kclo) when none.
; ----------------------------------------------------------------------------
select_backbuf:
  .if BHW                          ; hardware: the ring
        ; ---- the buffer's ring: its base and end pages, the constants the
        ; blitters' folds use (ringup, pagestep), and the last slot's page for
        ; the mirror (mirror.s): the end's less 3, the same for both rings
        ; (mirror.s asserts it).  Its row table for draw_rect is patched below.
        ldx cur_buf
        lda @bhi,x
        sta ringbhi
        lda @ehi,x
        sta ringehi
        sec
        sbc #>RINGEND_A - >(RING_A + (RINGROWS-1)*ROWBYTES)
        sta ringe3
  .else
        ; ---- ACCCON's X bit.  The ISR writes ACCCON's D bit: tsb and trb are
        ; each one instruction, so neither can straddle it, and only one of them
        ; changes X.
        ldx cur_buf
        txa
        asl
        asl                        ; A = ACC_X for buffer 1, 0 for buffer 0
        .assert ACC_X = 4, error, "select_backbuf: cur_buf << 2 is ACCCON's X bit"
        tsb ACCCON                 ; buffer 1: X set
        eor #ACC_X
        trb ACCCON                 ; buffer 0: X clear
  .endif
        ; ---- has the window moved since this buffer last drew?  Then a record
        ; cut at its edge is not kept (match_sprites): what more of it the
        ; scroll brought into view is tiles.
        ldy #REC_CLIP              ; clip_mask if it has moved: the record bit tested
        lda wcx
        cmp BUF_CXL,x
        bne @moved
        lda wcx+1
        cmp BUF_CXH,x
        bne @moved
        lda wcy
        cmp BUF_CY,x
        bne @moved
        ldy #0
@moved: sty clip_mask
        ; ---- the rows both windows hold: d = the old window's row less the new
        lda BUF_CY,x
        sec
        sbc wcy                    ; (an invalid buffer keeps no records anyway)
        bmi @rneg
        cmp #BUFROWS
        bcs @rnone
        sta krlo                   ; d >= 0: rows d .. BUFROWS-1
        lda #BUFROWS+KHI_BIAS
        bne @krh                   ; (always)
@rneg:  cmp #<(1-BUFROWS)
        bcc @rnone                 ; d <= -BUFROWS: nothing shared
        adc #BUFROWS+KHI_BIAS-1    ; C = 1: BUFROWS + d + KHI_BIAS
        ldy #0
        sty krlo                   ; rows 0 .. BUFROWS+d-1
@krh:   sta krhi2
        ; ---- the columns: d is 16 bit, low byte in Y
        lda BUF_CXL,x
        sec
        sbc wcx
        tay
        lda BUF_CXH,x
        sbc wcx+1
        beq @cpos
        cmp #$FF
        bne @cnone                 ; (an invalid buffer's BUF_INVALID lands here too)
        tya
        cmp #<(1-ROWCHARS)
        bcc @cnone                 ; d <= -ROWCHARS
        adc #ROWCHARS+KHI_BIAS-1   ; C = 1: ROWCHARS + d + KHI_BIAS
        ldy #0                     ; columns 0 .. ROWCHARS+d-1
        beq @ckh                   ; (always)
@rnone: lda #$FF                   ; no rows shared: match_sprites tests the rows
        sta krlo                   ;  first, so the columns (and krhi2) are not read
@cnone: ldy #$FF
        bne @clo                   ; (always; kchi2 is not read)
@cpos:  cpy #ROWCHARS              ; Y = d
        bcs @cnone
        lda #ROWCHARS+KHI_BIAS     ; columns d .. ROWCHARS-1
@ckh:   sta kchi2
@clo:   sty kclo
        ; ---- the sprite records: X = cur_buf (0/1)
  .if TIGHTBSS
        lda @rb,x                  ; its first sprite record
        sta recb
  .else
        lda @rlo,x                 ; its sprite record base
        sta recp
        lda @rhi,x
        sta recp+1
  .endif
  .if BHW                          ; hardware: the ring
        ; ---- draw_rect's ring high bytes: this buffer's table
        lda @thl,x
        sta RINGHIOP
        rts                        ; (RINGHIOP's high byte needs no patch: both
        .assert >ringhi = >ringhi_b, error, "ringhi and ringhi_b must share a page"
@thl:   .byte <ringhi, <ringhi_b   ;  tables lie in one page, asserted above)
@bhi:   .byte >RING_A, >RING_B
@ehi:   .byte >RINGEND_A, >RINGEND_B
  .else
        rts
  .endif
  .if TIGHTBSS
@rb:    .byte 0, MAXREC
  .else
@rlo:   .byte <SPRREC, <(SPRREC+MAXREC*RECSZ)
@rhi:   .byte >SPRREC, >(SPRREC+MAXREC*RECSZ)
  .endif

; ----------------------------------------------------------------------------
; bank6_entry: call_bank's way into bank 6 (BANKENTRY, the bank's first byte)
;   In:    as draw_rect_clip, which it falls into
;   Out:   as draw_rect_clip
;   Uses:  as draw_rect_clip
;   Pre:   bank 6 paged for reading (call_bank, low.s).  It sets no write bank:
;          draw_rect_clip stores into no bank, and draw_rect opens and closes
;          its own window.
; Segment TIL6ENT: the linker places it first in the bank, before ringlo.
; ----------------------------------------------------------------------------
        .segment "TIL6ENT"
bank6_entry:
        .assert * = BANKENTRY, error, "bank6_entry must start bank 6"

; ----------------------------------------------------------------------------
; draw_rect_clip: draw_rect, with the rect clipped to the window
;   In:    rc_x (16 bit), rc_y, rc_w, rc_h = the rect, unclipped; wcx, wcy =
;          the window (rows wcy .. wcy+BUFROWS-1, columns wcx ..
;          wcx+ROWCHARS-1)
;   Out:   draw_rect's, with the rect clipped (a tail jump); or rts with
;          nothing drawn when none of it is in the window.  rc_x, rc_y, rc_w,
;          rc_h clobbered either way.
;   Uses:  A X Y, and draw_rect's
;   Pre:   bank 6 paged (call_bank); the rect's rows within -128..127 of wcy
;          (the row offset is a signed byte)
; Callers: erase_old and draw_dirty (frame.s), through call_bank -- entered by
; falling from bank6_entry.
; ----------------------------------------------------------------------------
draw_rect_clip:
        ; ---- rows: rel = rc_y - wcy, a signed byte, kept in A
        lda rc_y
        sec
        sbc wcy
        bpl :+
        ; ---- it starts above the window: shrink to what is below the top
        clc
        adc rc_h                   ; rel + h = the rows left
        beq @none
        bmi @none
        sta rc_h
        lda wcy
        sta rc_y
        lda #0                     ; clipped to the top: rel is now 0
:       clc
        adc rc_h                   ; rel + h, the row after its last
        cmp #BUFROWS+1
        bcc :+
        sbc #BUFROWS               ; bcc not taken, C = 1: the excess e = end - BUFROWS
        eor #$FF                   ;  (C stays 1)
        adc rc_h                   ; h - e = BUFROWS - rel
        beq @none
        bmi @none
        sta rc_h
        ; ---- columns: rel = rc_x - wcx (16 bit signed), low byte in Y
:       lda rc_x
        sec
        sbc wcx
        tay
        lda rc_x+1
        sbc wcx+1
        bpl @right                 ; rel's high byte in A: N, Z the sbc's
        ; ---- rel < 0: the visible width is w + rel, and rel is already two's
        ; complement, so add rather than negate and subtract.  Only a result
        ; whose high byte comes out exactly 0 survives: anything else is the
        ; whole rect off the left edge.
        tax                        ; rel's high byte, kept in X (this path's alone)
        tya
        clc
        adc rc_w                   ; the low sum: the width, if it survives
        beq @none
        inx                        ; hi + C = 0 only for hi = $FF with a carry out
        bne @none
        bcc @none                  ; (inx and branches leave C alone)
        ; rel is now exactly 0, so the right clip is just min(width, ROWCHARS):
        ; the width is still in A
        ldx wcx
        stx rc_x
        ldx wcx+1
        stx rc_x+1
        cmp #ROWCHARS+1
        bcc :+
        lda #ROWCHARS
:       sta rc_w
        jmp draw_rect
        ; ---- rel >= 0: off the right, or clip the right edge
@right: bne @none                  ; Z from the sbc: rel >= 256, off the right
        tya
        cmp #ROWCHARS
        bcs @none                  ; not taken: C = 0 for the adc
        adc rc_w                   ; rel + w, the column after its last
        cmp #ROWCHARS+1
        bcc :+                     ; not taken: C = 1 for the sbc
        sbc #ROWCHARS              ; the excess e = rel + w - ROWCHARS (C stays 1)
        eor #$FF
        adc rc_w                   ; w - e = ROWCHARS - rel
        sta rc_w
:       jmp draw_rect
@none:  rts
