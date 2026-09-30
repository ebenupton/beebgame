#!/bin/sh
# beebgame's build: a game's sources with the engine's, both machines, one disc.  The
# game's build.sh sets the variables below and runs this from its own directory, where
# build/ is made.  The sources are assembled twice against one sector table: BHW=1 for
# the Model B's hardware into build/modelb/, BHW=0 for the Master's into build/master/
# -- the same structure, each level gathered into the banks by the engine's loader.
# The boot loader picks the machine's bank images (BANKSB, BANKSM); each machine's
# LDPROG and bank 7 images (IMG7: MENU, GAME) are its own; everything else, the levels
# included, is on the disc once.
#
#   GAME_MAIN    the game's root source (it includes the engine's: see README.md)
#   GAME_SRC     the game's include directory
#   GAME_ASSETS  run once per machine (TARGET, BD set): writes build/$TARGET's assets
#                -- assets.inc, the level files, SPRC, SPRX, BAR, imgtab.bin and what
#                the game's own sources .incbin -- and build/TILES0-2
#   GAME_MUSIC   run once first (may be empty)
#   DISC_TITLE   the disc's title; DISC_OUT the disc image (build/game.ssd); GAME_NAME
#                the game's name, for the boot loader's messages (DISC_TITLE)
#   SKIP_ASSETS=1 skips GAME_MUSIC and GAME_ASSETS; TILEMIRROR=1 builds the tile
#   blitter's mirrored tiles (cpu.inc; off by default), which move the tiles up a page
#   MASTERONLY=1 builds the Master alone: no Model B assembly, link or files, the
#                Master linked unpinned, its own layout the level files' (a game too big
#                for the Model B; the boot loader says so on one)
#   GAMEHAZEL=1  the game's own code in HAZEL (segments HAZCODE, HAZDATA, HAZBSS), a
#                piece of BANKS the boot loader copies once; the Master only, and SPRX
#                is then read at every level load (no copy is kept in HAZEL/ANDY)
#   GAMESOUND=1  the vsync calls the game's hook_sound instead of the engine's sound
#                effects (the game's player, resident: its code in HAZEL, say)
#   TALLMAP=1    maps up to 256 tiles tall (the window's char row keeps its high bits
#                for drawrect's map row); the Master alone
#   DRAWFLAGS=1  the sprite list carries draw flags in the high bits of its x (bit 7:
#                mirror the image), so one image is drawn either way round
#   TIGHTBSS=1   the engine's bank 7 variables packed: the sprite records 9 bytes (the
#                rectangle's column high bits in the height's byte) and ENGBSS not
#                page aligned (after GAMEBSS as it falls)
#   MAXSPR=n     the sprite slots (the most sprites on screen at once), in place of
#                the game's assets.inc MAXSPRDEF; 28 when neither sets it
BG=$(cd "$(dirname "$0")/.." && pwd)
: "${GAME_MAIN:?}" "${GAME_SRC:?}" "${GAME_ASSETS:?}" "${DISC_TITLE:?}"
DISC_OUT=${DISC_OUT:-build/game.ssd}
GAME_NAME=${GAME_NAME:-$DISC_TITLE}
set -e
mkdir -p build
# (TILEMIRROR: the game's converter and packer follow it too; the linker areas here)
if [ "$TILEMIRROR" = 1 ]; then MIRDEF="-D TILEMIRROR=1"; else TILEMIRROR=0; MIRDEF=""; fi
export TILEMIRROR
# the options, as the assembler's flags (cpu.inc defaults each to 0)
for o in MASTERONLY GAMEHAZEL GAMESOUND DRAWFLAGS TALLMAP TIGHTBSS; do
    eval "v=\$$o"
    if [ "$v" = 1 ]; then MIRDEF="$MIRDEF -D $o=1"; else eval "$o=0"; fi
    export $o
done
[ -z "$MAXSPR" ] || MIRDEF="$MIRDEF -D MAXSPRDEF=$MAXSPR"
[ "$GAMEHAZEL" = 0 ] || [ "$MASTERONLY" = 1 ] || { echo "GAMEHAZEL=1 needs MASTERONLY=1: the Model B has no HAZEL"; exit 1; }
if [ "$MASTERONLY" = 1 ]; then TARGETS=master; else TARGETS="modelb master"; fi
settarget() {                       # $1: modelb or master
    TARGET=$1
    if [ "$TARGET" = master ]; then
        BD=build/master; CPU=65C02; DEFS="-D BHW=0 $MIRDEF"; CFG=$BG/cfg/master.cfg; BARADDR='$2B00'
    else
        BD=build/modelb; CPU=6502; DEFS="$MIRDEF"; CFG=$BG/cfg/modelb.cfg; BARADDR='$0300'
    fi
    export BD TARGET
}
[ -n "$SKIP_ASSETS" ] || [ -z "$GAME_MUSIC" ] || sh -c "$GAME_MUSIC"
for t in $TARGETS; do
    settarget $t
    mkdir -p $BD
    [ -n "$SKIP_ASSETS" ] || sh -c "$GAME_ASSETS"
    sed "s#\"build/#\"$BD/#g" $CFG > $BD/game.cfg
    [ "$TIGHTBSS" = 1 ] && sed -i.bak '/^ *ENGBSS:/s#, align = \$100##' $BD/game.cfg   # (ENGBSS where GAMEBSS ends)
    [ "$TILEMIRROR" = 1 ] && sed -i.bak 's#start = \$8000, size = \$0700#start = $8000, size = $0800#' $BD/game.cfg
    for f in BANKS MENU GAME IMG7 LDPROG; do [ -f $BD/$f ] || : > $BD/$f; done
    python3 $BG/tools/levelfile.py inc > $BD/levelfmt.inc     # (the loader's: one definition)
done
# what both machines read goes on the disc once (the Model B's copy): the packs agree
# (the files the engine's loader reads, by these names: ldprog.s)
B=build/modelb M=build/master
if [ "$MASTERONLY" = 1 ]; then REF=$M; else REF=$B
for f in SPRX SPRC BAR L0 L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 L14 L15; do
    cmp -s build/modelb/$f build/master/$f || { echo "build/modelb/$f and build/master/$f differ: the level layout is not one"; exit 1; }
done
fi
python3 $BG/tools/levelfile.py check $REF/assets.inc $(for l in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo $REF/L$l; done)

# the disc's file list, in disc order: the boot files, each machine's pieces, the
# shared files together, the levels after them.  A game's start reads LDPROG, the
# game's image (IMG7) and BAR in turn, so they are neighbours: the Model B's in that
# order, the Master's around them
if [ "$MASTERONLY" = 1 ]; then
DISC="!BOOT:build/BOOT LOADER:build/LOADER BANKSM:$M/BANKS"
DISC="$DISC IMG7M:$M/IMG7 LDPROGM:$M/LDPROG BAR:$REF/BAR"
else
DISC="!BOOT:build/BOOT LOADER:build/LOADER BANKSB:$B/BANKS BANKSM:$M/BANKS"
DISC="$DISC IMG7M:$M/IMG7 LDPROGM:$M/LDPROG LDPROGB:$B/LDPROG IMG7B:$B/IMG7 BAR:$REF/BAR"
fi
DISC="$DISC SPRX:$REF/SPRX SPRC:$REF/SPRC TILES0:build/TILES0 TILES1:build/TILES1"
for l in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do DISC="$DISC L$l:$REF/L$l"; done
DISC="$DISC TILES2:build/TILES2"
[ -f build/LOADER ] || : > build/LOADER
printf '*RUN LOADER\r' > build/BOOT

# Passes: the sector table (files.inc) needs the files' sizes, and bank 7 and LDPROG
# carry entries from it.  No size depends on a sector number, so the second pass is
# stable (the third checks that).
for pass in 1 2 3; do
    [ $pass = 3 ] && cp $REF/files.inc $REF/files.prev
    python3 $BG/tools/mkdfs.py table $REF/files.inc $DISC
    [ "$MASTERONLY" = 1 ] || cp $B/files.inc $M/files.inc
    [ $pass = 3 ] && { cmp -s $REF/files.inc $REF/files.prev || { echo "files.inc did not settle"; exit 1; }; break; }
    for t in $TARGETS; do
        settarget $t
        ca65 -g --cpu $CPU $DEFS -I $BD -I $GAME_SRC -I $BG/src --bin-include-dir $BD \
             -o $BD/main.o $GAME_MAIN -l $BD/main.lst
        # the top of bank 7, down from KRNHW at $BF00: the driver slot, as big as the
        # larger driver (disc.s: the boot loader copies in the machine's one), the
        # kernel below it, its tables kept inside a page; then the game's image, ending
        # at the kernel: the game's data and code, then the engine's.  From the Model B's
        # sizes (od65: the object's segments, before any link); the Master's, pinned to
        # the Model B's, fall short (MASTERONLY: the Master's own, there is no Model B)
        if [ $TARGET = modelb ] || [ "$MASTERONLY" = 1 ]; then
            SZ=$(od65 --dump-segsize $BD/main.o)
            seg() { echo "$SZ" | awk -v p="^ +($1):" '$0 ~ p {s += $2} END {print s + 0}'; }
            D1=$(seg 'D8271H|D8271N|D8271C'); D2=$(seg 'D1770H|D1770N|D1770C')
            DRVN=$(( D1 > D2 ? D1 : D2 )); DRVS=$(( 0xBF00 - DRVN ))
            KD=$(seg KRNDATA)
            KRNS=$(( DRVS - $(seg 'KRNDATA|KRNCODE|KRNBSS') ))
            [ $(( (KRNS & 255) + KD )) -gt 256 ] && KRNS=$(( (KRNS & 0xFF00) + 256 - KD ))
            B7N=$(seg 'GAMEDATA|GAMECODE|ENGCODE')
            B7S=$(printf '%04X' $(( KRNS - B7N ))); B7N=$(printf '%04X' $B7N)
            MSZ=$(printf '%04X' $(( KRNS - 0x8000 ))); KSZ=$(printf '%04X' $(( DRVS - KRNS )))
            KRNS=$(printf '%04X' $KRNS); DRVS=$(printf '%04X' $DRVS); DRVN=$(printf '%04X' $DRVN)
        fi
        sed -i.b7 -e "s#^\( *B7: *start = [$]\)[0-9A-F]*, size = [$][0-9A-F]*#\1$B7S, size = \$$B7N#" \
                  -e "s#^\( *B7M: *start = [$]8000, size = [$]\)[0-9A-F]*#\1$MSZ#" \
                  -e "s#^\( *B7K: *start = [$]\)[0-9A-F]*, size = [$][0-9A-F]*#\1$KRNS, size = \$$KSZ#" \
                  -e "s#^\( *DRV[0-9]*: *start = [$]\)[0-9A-F]*, size = [$][0-9A-F]*#\1$DRVS, size = \$$DRVN#" $BD/game.cfg
        # the Master's segments at the Model B's addresses (linked just before): its
        # shorter 65C02 code leaves gaps, and the data lies alike on both
        LCFG=$BD/game.cfg
        [ $TARGET = master ] && [ "$MASTERONLY" = 0 ] && { python3 $BG/tools/pincfg.py $BD/game.cfg $B/game.dbg > $BD/pinned.cfg; LCFG=$BD/pinned.cfg; }
        ld65 -C $LCFG -o $BD/unused.bin $BD/main.o -m $BD/map.txt -Ln $BD/labels.txt --dbgfile $BD/game.dbg
        # what the loaders need from the game: its addresses
        python3 - <<'EOF'
import re
want = ['boot','dsk_type','dsk_drv','read_sectors','ld_sec','ld_n','ld_dst',
        'LV_HDR','LV_OBJS','LV_ATTR0','LV_ALTCLS','TILES','SPR_TABLE','mapshr','MAPSTRIDE','FLATTAB',
        'half0','half1','half2','halfhi','halfhi5','halfsub','mir0','MIRTAB','sprc_ok','sprx_ok','HPAIR0','HPAIR1',
        'MAP5','LDZP','BARADDR','STAGE','STAGE_LVL','LDPROG','PBANK','PBOARD','dsk_banks','dsk_board',
        'ld_img','ld_open','LOADREQ','game_in']
addr = {}
import os
BD = os.environ['BD']
for l in open(BD + '/labels.txt'):
    p = l.split()
    if len(p) >= 3 and p[0] == 'al':
        addr[p[2].lstrip('.')] = int(p[1], 16)
# drawrect's @s0f (a cheap label: in the debug info, not labels.txt): the solid's
# lda #fill, whose operand the loader patches
dbg = open(BD + '/game.dbg').read()
did = re.search(r'^sym\tid=(\d+),name="drawrect",', dbg, re.M).group(1)
s0f = re.search(r'^sym\tid=\d+,name="@s0f",[^\n]*parent=%s,[^\n]*val=0x([0-9A-F]+)' % did, dbg, re.M)
addr['SOLIDF'] = int(s0f.group(1), 16) + 1
want.append('SOLIDF')
# the game's hooks (README.md): equates, so in the debug info and not labels.txt --
# the load-time program goes on to them after an image load (ldprog.s ld_entry)
for h in ('hook_title', 'hook_image', 'hook_over'):
    addr[h] = int(re.search(r'^sym\tid=\d+,name="%s",[^\n]*val=0x([0-9A-F]+)' % h, dbg, re.M).group(1), 16)
    want.append(h)
# bank 7's images (ldprog.s image_load): the game's, the linker's b7.bin (its code,
# from GAMEDATA; its variables are not in the file), and the menus', MENU
# (one file on the disc, IMG7: the menus' image to a whole sector, then the game's,
# which ldprog.s reads as two)
import shutil
shutil.copy(BD + '/b7.bin', BD + '/GAME')
menu = open(BD + '/MENU', 'rb').read()
open(BD + '/IMG7', 'wb').write(menu + bytes(-len(menu) % 256) + open(BD + '/GAME', 'rb').read())
img = {'GAME': (addr['__B7_START__'], os.path.getsize(BD + '/GAME')),       # (the files start
       'MENU': (addr['__B7M_START__'], os.path.getsize(BD + '/MENU'))}      #  where their areas do)
assert img['MENU'][0] + img['MENU'][1] <= addr['__KRNDATA_RUN__'] and img['GAME'][0] + img['GAME'][1] <= addr['__KRNDATA_RUN__']
with open(BD + '/defs_ld.inc', 'w') as f:
    f.write('; generated by build.sh from build/labels.txt\n')
    for n in want:
        if n in addr:
            f.write('%s = $%04X\n' % (n, addr[n]))
        else:
            f.write('; %s: not in labels.txt (a constant?)\n' % n)
    for k, (a, n) in img.items():
        f.write('%s_ADDR = $%04X\n%s_LEN = %d\n' % (k, a, k, n))
    # the image's variables (GAMEBSS then ENGBSS, page aligned), zeroed as it comes in:
    # below its code
    bss, bssn = addr['__GAMEBSS_RUN__'], addr['__ENGBSS_RUN__'] + addr['__ENGBSS_SIZE__'] - addr['__GAMEBSS_RUN__']
    assert bss & 255 == 0 and bss + ((bssn + 255) & ~255) <= addr['__B7_START__'], 'the game image\'s variables run into its code'
    f.write('GAME_BSS = $%04X\nGAME_BSS_PAGES = %d\n' % (bss, (bssn + 255) // 256))
# each image's own patch lists (bank 7 entries of the linker's, cpu.inc BANKREF and
# wrsel, that fall in it): image_load applies them after every read, as the boot
# loader does BANKS's
fix, wr = open(BD + '/bankfix.bin', 'rb').read(), open(BD + '/wrfix.bin', 'rb').read()
fixe = [(fix[i], fix[i + 1] | fix[i + 2] << 8) for i in range(0, len(fix), 3)]
wre = [(wr[i], wr[i + 1] | wr[i + 2] << 8, wr[i + 3]) for i in range(0, len(wr), 4)]
# The two images share their addresses, so a list entry (bank, address) cannot say
# which it is in: the menus' carry none (they read PBANK: cpu.inc ldpbank), and the
# debug info's site labels (@bf_, @wr_) are checked for it.  Every bank 7 entry below
# the kernel is the game's.
for mm in re.finditer(r'^sym\tid=\d+,name="@(bf|wr)_\w+",[^\n]*seg=(\d+)', dbg, re.M):
    sg = re.search(r'^seg\tid=%s,name="(\w+)"' % mm.group(2), dbg, re.M).group(1)
    assert not sg.startswith('MNU'), 'a bank-number or write-bank site in the menus\' image (%s): use ldpbank' % sg
def inimg(k, bank, a):
    return k == 'GAME' and bank == 7 and img[k][0] <= a < img[k][0] + img[k][1]
with open(BD + '/img7fix.inc', 'w') as f:
    f.write('; generated by build.sh: bank 7 images\' bank numbers and write-bank stores\n')
    for k, lab in (('GAME', 'game'), ('MENU', 'menu')):
        bf = [a for b, a in fixe if inimg(k, b, a)]
        ws = [(a, kd) for b, a, kd in wre if inimg(k, b, a)]
        f.write('bf_%s: %s.byte 0, 0\n' % (lab, ''.join('.word $%04X\n        ' % a for a in bf)))
        f.write('wr_%s: %s.byte 0, 0\n' % (lab, ''.join('.word $%04X\n        .byte $%02X\n        ' % (a, kd) for a, kd in ws)))
EOF
        # the constants ld65 does not list: assembled with the game's own flags, so the
        # hardware conditionals in defs.inc resolve as they do in the game (ldconst.s)
        ca65 --cpu $CPU $DEFS -I $BD -I $BG/src -o /dev/null $BG/src/ldconst.s > $BD/ldconst.out
        grep ' = ' $BD/ldconst.out >> $BD/defs_ld.inc
        echo "BARADDR = $BARADDR" >> $BD/defs_ld.inc
        ca65 --cpu 6502 $DEFS -I $BD -I $BG/src --bin-include-dir $BD -o $BD/ldprog.o $BG/src/ldprog.s -l $BD/ldprog.lst
        ld65 -C $BG/cfg/ldprog.cfg -o $BD/LDPROG $BD/ldprog.o
        # BANKS: the fixed pieces with their table, then the bank-number patch list (every
        # byte of the pieces that holds a bank number, cpu.inc BANKREF) ending in $FF: the
        # boot loader rewrites those bytes to the banks it found RAM in.  Each entry is
        # checked against the pieces here: a wrong bank on a bankimm would land outside
        # them or on a byte that is no bank number.  Then the write-bank store list (cpu.inc
        # wrsel: bank, address, kind; every entry must sit on a `sta $FE30`), ending in $FF.
        python3 - <<'EOF'
import os
BD = os.environ['BD']
lab = {}
for l in open(BD + '/labels.txt'):
    p = l.split()
    if len(p) >= 3 and p[0] == 'al':
        lab[p[2].lstrip('.')] = int(p[1], 16)
pieces = [(4, 0x8000, 'b4x.bin'), (4, 0xBC00, 'b4t.bin'),
          (5, 0x8000, 'b5x.bin'), (5, 0xBC00, 'b5t.bin'),
          (6, 0x8000, 'b6x.bin'),                                 # (B6X in the cfg)
          (7, 0x7000, 'boot.bin'),        # main RAM (BOOTRAM): start-up and the low-RAM image
          (7, lab['__KRNDATA_RUN__'], 'b7k.bin'),   # the kernel: resident, the top of bank 7
          (7 | 0x80, lab['__DRV8271_START__'], 'drv8271.bin'),   # the driver slot: the 8271's (bit 7: an
          (7 | 0x40, lab['__DRV1770_START__'], 'drv1770.bin')]   # 8271 only) or the 1770's (bit 6): loader.s
if os.environ.get('TARGET') == 'master':
    pieces.append((7, 0x0600, 'mcode.bin'))         # main RAM: the Master's handler, chain, keys, sound
if os.environ.get('GAMEHAZEL') == '1':
    pieces.append((1, 0xC000, 'hazel.bin'))         # HAZEL (bank "1" to the loader: ACCCON Y), last
tab, body, img = bytearray([len(pieces)]), bytearray(), {}
for bank, addr, fn in pieces:
    d = open(os.path.join(BD, fn), 'rb').read()
    tab += bytes([bank, addr & 255, addr >> 8, len(d) & 255, len(d) >> 8])
    body += d
    img[(bank, addr)] = d
def piece_bytes(bank, addr, n):             # (no patch in a driver: it is one of two)
    hit = [d[addr - a:addr - a + n] for (b, a), d in img.items() if b == bank and a <= addr and addr + n <= a + len(d)]
    assert len(hit) == 1, 'patch %d:$%04X is in no piece' % (bank, addr)
    return hit[0]
# bank 7's images are not BANKS's: ldprog.s image_load patches them (img7fix.inc)
imgs = [(lab['__B7_START__'], os.path.getsize(BD + '/GAME')), (lab['__B7M_START__'], os.path.getsize(BD + '/MENU'))]
ingame = lambda bank, a: bank == 7 and any(b <= a < b + n for b, n in imgs)
fix0 = open(BD + '/bankfix.bin', 'rb').read()
assert len(fix0) % 3 == 0, 'bankfix.bin is not whole entries'
fix = b''.join(fix0[i:i + 3] for i in range(0, len(fix0), 3) if not ingame(fix0[i], fix0[i + 1] | fix0[i + 2] << 8))
# (HAZEL's code reads its banks from PBANK -- cpu.inc ldpbank -- as the menus' does: a
# bankimm there would be a patch in no piece, below)
for i in range(0, len(fix), 3):
    bank, addr = fix[i], fix[i + 1] | (fix[i + 2] << 8)
    v = piece_bytes(bank, addr, 1)[0]
    assert 4 <= (v & 15) <= 7, 'bank patch %d:$%04X names byte $%02X, no bank number' % (bank, addr, v)
wr0 = open(BD + '/wrfix.bin', 'rb').read()
assert len(wr0) % 4 == 0, 'wrfix.bin is not whole entries'
wr = b''.join(wr0[i:i + 4] for i in range(0, len(wr0), 4) if not ingame(wr0[i], wr0[i + 1] | wr0[i + 2] << 8))
for i in range(0, len(wr), 4):
    bank, addr, kind = wr[i], wr[i + 1] | (wr[i + 2] << 8), wr[i + 3]
    assert piece_bytes(bank, addr, 3) in (b'\x8d\x30\xfe', b'\x8d\x30\xff'), 'write-bank store %d:$%04X is not sta $FE30 (or wrback\'s sta $FF30)' % (bank, addr)
    assert kind in (4, 5, 6, 7, 0xFE), 'write-bank store %d:$%04X: kind $%02X' % (bank, addr, kind)
banks = tab + body + fix + b'\xff' + wr + b'\xff'
assert 0x2000 + len(banks) <= 0x7000, 'BANKS (read to $2000) would run into the start-up piece at $7000'
open(BD + '/BANKS', 'wb').write(banks)
print('BANKS: %d pieces, %d bytes, %d bank patches, %d write-bank stores' % (len(pieces), len(tab) + len(body), len(fix) // 3, len(wr) // 4))
EOF
    done
    # the boot loader, one for both machines: the start-up header it writes and the
    # entry it jumps to are at the same addresses on both (init.s)
    [ "$MASTERONLY" = 1 ] || for n in boot dsk_type dsk_drv dsk_banks dsk_board; do
        [ "$(grep "^$n = " $B/defs_ld.inc)" = "$(grep "^$n = " $M/defs_ld.inc)" ] || { echo "$n differs between the machines"; exit 1; }
    done
    printf '          .byte "%s"\n' "$GAME_NAME" > build/gamename.inc
    ca65 --cpu 6502 -D MASTERONLY=$MASTERONLY -D GAMEHAZEL=$GAMEHAZEL -I $REF -I build -I $BG/src -o build/loader.o $BG/src/loader.s
    ld65 -C $BG/cfg/loader.cfg -o build/LOADER build/loader.o
done
python3 $BG/tools/mkdfs.py build $DISC_OUT "$DISC_TITLE" \
    "!BOOT:build/BOOT:0000:FFFF" "LOADER:build/LOADER:1900:1900" \
    $(echo $DISC | tr ' ' '\n' | grep -v '^!BOOT\|^LOADER' | tr '\n' ' ')
if [ "$MASTERONLY" = 1 ]; then
ls -l $M/BANKS $DISC_OUT
else
cmp -s $B/assets.inc $M/assets.inc || { echo "the machines' assets.inc differ"; exit 1; }
python3 $BG/tools/layoutcheck.py $B $M
ls -l $B/BANKS $M/BANKS $DISC_OUT
fi
