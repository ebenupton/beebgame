; The sprite banks (both: one row loop, sprloops.s).  spr_fn's cells lie in the bank's
; first page by their place.  spr_fm's are longer than a page, so one of their branches
; crosses a page's end wherever they lie (a pair's beq done lands on the next pair):
; the Master's pad puts it between pairs 1 and 2, where it measured best; the Model B's
; would cost sprite room in both banks (the game's B4/B5_CODE_END) and bought nothing.
PADB_FM = 0                        ; before spr_fm's cells
PADM_FM = 1
; Bank 7's engine code (ENGCODE) ends at the kernel on the Model B, so a pad there
; places the code before it; the Master's runs on from the Model B's start, so a pad
; places the code after it.  Found together over the profile's bank 7 branches and
; reads (Cleo's test/cycprof.mjs PHASEDUMP, then test/padopt.py): they move with the
; kernel's start (disc.s: the driver slot's size sets it), so re-find them when it moves.
; So is the order of ENGCODE's blocks in engine/frame.s (Cleo's test/blockopt.py, first).
PADB_MS = 0                        ; before match_sprites
PADM_MS = 15
PADB_SP = 26                       ; before draw_sprites
PADM_SP = 26
PADB_EO = 15                       ; before erase_old
PADM_EO = 0
PADB_DS = 0                        ; before draw_sprite
PADM_DS = 64
PADB_CP = 0                        ; before copy_partial
PADM_CP = 61
PADB_T6 = 14                       ; bank 6, the Model B: after ringmod_tab, before draw_rect
PADM_T6 = 228                      ; bank 6, the Master: before draw_rect (puts @run's bmi @tile in a page)
                                    ; (tiles.s: its hot stretches each in a page)
PADB_BB = 2                        ; the Model B: before render_frame
