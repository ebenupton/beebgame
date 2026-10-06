; ============================================================================
; pads.inc -- the pads that place the hot code off page boundaries, a machine each
;
; Included by engine/defs.s; used through cpu.inc's PAD b, m (the Model B's bytes,
; the Master's).  The two machines' code differs in length, so each has its own
; pads; the data after them lies alike regardless (tools/pincfg.py).  Found with
; Cleo's test/padopt.py over a profile of bank 7's branches and reads (its
; test/cycprof.mjs with PHASEDUMP) and, for the sprite banks, tools/pagecheck.py;
; the values recorded here are that search's result, not derived.
; ============================================================================

; The sprite banks (both: one row loop, sprloops.s).  spr_fn's cells lie in the
; bank's first page by their place.  spr_fm's cells are nearly a page long
; (labels.txt: 255 bytes on the Model B, 248 on the Master), so one of their branches
; crosses a page's end wherever they lie (a pair's beq done lands on the next pair).
; The Master's pad of 1 is the search's pick (its $8200 falls in spr_fm_2); a Model B
; pad would cost sprite room in both banks (the game's B4/B5_CODE_END), and the
; search found nothing to buy with one.
PADB_FM = 0                        ; before spr_fm's cells
PADM_FM = 1
; Bank 7's engine code (ENGCODE) ends at the kernel on the Model B, so a pad there
; places the code before it; the Master's runs on from the Model B's start, so a pad
; places the code after it.  The bank 7 pads move with the kernel's start (disc.s:
; the driver slot's size sets it), so they are re-found when it moves.  So is the
; order of ENGCODE's blocks in engine/frame.s (Cleo's test/blockopt.py, first).
PADB_MS = 0                        ; before match_sprites
PADB_SP = 26                       ; before draw_sprites
PADB_EO = 15                       ; before erase_old
PADB_DS = 0                        ; before draw_sprite
PADB_CP = 0                        ; before copy_partial
PADM_MS = 15
PADM_SP = 26
PADM_EO = 0
PADM_DS = 64
PADM_CP = 61
  .if RINGARITH                     ; (no ring tables before draw_rect: its own value)
    .ifdef PADB_T6R
PADB_T6 = PADB_T6R
    .else
PADB_T6 = 168                      ; (the first that places draw_rect's chains: 168-204, 212-220)
    .endif
  .else
PADB_T6 = 14                       ; bank 6, the Model B: after ringmod_tab, before
  .endif
                                   ;  draw_rect
PADM_T6 = 228                      ; bank 6, the Master: before draw_rect (tiles.s: its
                                   ;  hot stretches each in a page; SAMEPAGE asserts
                                   ;  @run's bmi @tile)
PADB_BB = 2                        ; the Model B: after draw_dirty, before render_frame
                                   ;  (the Master has no partner: PAD ::PADB_BB, 0)
