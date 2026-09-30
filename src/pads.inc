; The Master's padding in the sprite banks: its 65C02 code is shorter than the Model
; B's, and the room it leaves (the pinned layout's: tools/pincfg.py) is spent before
; the hot blitters so that their branches cross no page boundary -- the Model B's are
; placed by the order of its code alone.  Found by the build (tools/pagecheck.py over
; the profile's hot branches); each is at most the Master's slack in its bank.
PADM_FN4 = 26                       ; bank 4: before the unmirrored mask blitter
PADM_FM4 = 0                        ;         before the mirrored one
PADM_FN5 = 3                        ; bank 5: before the mask blitter
PADM_FC5 = 28                       ;         before the copy blitter
; Bank 7's engine code (ENGCODE) ends at the kernel on the Model B, so a pad there
; places the code before it; the Master's runs on from the Model B's start, so a pad
; places the code after it.  Found together over the profile's bank 7 branches and
; reads (Cleo's test/cycprof.mjs PHASEDUMP, then test/padopt.py): they move with the
; kernel's start (disc.s: the driver slot's size sets it), so re-find them when it moves.
; So is the order of ENGCODE's blocks in engine/frame.s (Cleo's test/blockopt.py, first).
PADB_MS = 0                         ; before match_sprites
PADM_MS = 4
PADB_SP = 10                         ; before draw_sprites
PADM_SP = 0
PADB_EO = 5                         ; before erase_old
PADM_EO = 0
PADB_DS = 0                         ; before drawsprite
PADM_DS = 8
PADB_CP = 0                         ; before copy_partial
PADM_CP = 9
PADB_M6 = 29                        ; bank 6, the Model B: before drawrect's solid fills,
                                    ; @m31..@m7, so the four share a page (tiles.s asserts)
PADB_BB = 0                         ; the Model B: after blank_below
