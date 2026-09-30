; ============================================================================
; beebgame: the display engine
;
; One engine for two machines, assembled twice from these sources: BHW=1 for the
; Model B (6502, 64K of sideways RAM), BHW=0 for the Master 128 (65C02, shadow RAM).
; The two differ only in the CPU's spellings, the hardware and three placements on the
; Master (docs/DESIGN.md, "One structure, two machines"); `.if BHW` marks the Model
; B's side of every difference.
;
; ---------------------------------------------------------------- the machine
; The code lives in four 16K sideways RAM banks, each beside the data its inner loop
; reads (the numbers are the code's; the loader patches in the real sockets):
;
;   bank 4   the sprite row loop and blitters (with the mirrored one); sprites
;   bank 5   the same again (with the copy blitter); the map, and the tile row's
;            gather that reads it in place; sprites
;   bank 6   the tile blitter and the ring work around it; the level's tiles
;   bank 7   the kernel at the top (resident: the display chain, the interrupt's
;            work on the Model B, sound, the palette, the disc); below it the game's
;            image -- the game's logic and the engine's frame and sprite code -- or,
;            in the menus, the menus' image
;
; Low RAM ($0140-$02FF) holds what every bank must see: the crossings between banks,
; the map access and (Model B) the interrupt stub.  The rest of main RAM is display.
;
; ---------------------------------------------------------------- a frame
; The game's loop calls render_frame (frame.s) once a frame, which waits for the last
; flip, then render_core draws the back buffer:
;
;   selbb            pick the back buffer (tiles.s select_backbuf, through low RAM)
;   calc_ring        where the window sits in its ring (kernel.s)
;   match_sprites    which of last frame's sprites are unchanged (frame.s)
;   erase_old        redraw the tiles under the ones that moved (frame.s, tiles.s)
;   validate         scroll: draw the strips the window has moved onto (tiles.s)
;   draw_dirty       redraw the map tiles the logic changed (frame.s, tiles.s)
;   draw_sprites     the sprites, through the row loops in banks 4/5 (frame.s,
;                    sprloops.s)
;   copy_partial     the composed row for the fine scroll (frame.s)
;   (mirror_copy)    Model B: the row that straddles the ring's end (mirror.s)
;
; and asks for the flip, which the interrupt makes at the next frame.  The display is a
; chain of CRTC sections rebuilt each frame (kernel.s build_sections) and stepped by
; the interrupt: the status bar, the playfield from the ring, and the blanking with the
; vsync (docs/DESIGN.md, "The display").
;
; ---------------------------------------------------------------- the files
; One per bank or role, in the order they are assembled.  Within a file the code is in
; its segment's order, which is layout, not reading order: bank 7's routines are
; placed to keep hot branches off page boundaries (the pads, src/pads.inc).  Moving
; code between or within these files moves it in the binary.
;
;   engine/defs.s      constants: hardware, banks, screen shape, records, keys
;   engine/vars.s      zero page and every table, by where it lives
;   engine/macros.s    the ring-wrapping macros, RUNX
;   engine/tiles.s     bank 6: drawrect, scroll_validate, select_backbuf,
;                      the bank's entry (drawrect_clip)
;   engine/gather.s    bank 5: gather5, a tile row's ids into GATHERL/H
;   engine/sprloops.s  banks 4 and 5: the sprite row loops and blitters
;   engine/frame.s     bank 7: render_frame and what it calls
;   engine/kernel.s    the kernel: the CRTC chain, the interrupt, keyboard, sound,
;                      load mode, ringaddr7
;   engine/menus.s     the menus' image: the tune's player
;   engine/boot.s      start-up: the interrupt's takeover, the CRTC's first frame
;   engine/lowram.s    low RAM: the map access, pagelogic
;
; Beside them: cpu.inc (the two CPUs' spellings, bank patching, the write-bank rule),
; defs.inc (addresses shared with the loader), low.s (the crossings, the Model B's
; interrupt stub), mirror.s (the Model B's mirror row), banks.s (the static tables),
; init.s (start-up), disc.s (the disc driver and image swap).
;
; ---------------------------------------------------------------- editing
; - Labels: a normal label ends ca65's cheap-local (@) scope, so one added inside a
;   routine breaks its @ references; an anonymous `:` label added or removed
;   retargets every :+/:- that crosses it.  Some ring macros contain them
;   (macros.s gives each one's count).
; - Page crossings: SAMEPAGE asserts a hot branch at link time; PAD (pads.inc) moves
;   code off a boundary.  A size change in a bank moves what follows it: re-find
;   bank 7's pads with the Cleo repo's test/padopt.py.
; - The write bank (Watford, Solidisk boards) is bank 7's except in a window, opened
;   with wrsel and closed with wrback (cpu.inc).
; - To check a comment-only edit: tools/codecmp.py old.s new.s compares the code alone.
; ============================================================================
        .include "engine/defs.s"
        .include "engine/vars.s"
        .include "engine/macros.s"
        .include "engine/tiles.s"
        .include "engine/gather.s"
        .include "engine/sprloops.s"
        .include "engine/frame.s"
        .include "engine/kernel.s"
        .include "engine/menus.s"
        .include "engine/boot.s"
        .include "engine/lowram.s"
