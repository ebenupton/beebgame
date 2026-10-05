; ============================================================================
; hw.inc -- the machine's fixed facts, one definition for every program on the disc
;
; Included by the game's assembly (defs.inc, first thing), the boot loader
; (loader.s) and the load-time program (ldprog.s): three separate assemblies, so
; this is where the chips' registers and their bits, the MOS's fixed addresses the
; code relies on, and the opcode bytes the code writes as data are spelt out, once.
; No storage, no code.  What is the game's own layout -- the banks, the screen, the
; loader's addresses -- is defs.inc's and engine/defs.s's.
;
; Sections:
;   the 6845 CRTC         its registers and their numbers, the MODE 1 values
;                         start-up loads, the character cell
;   the video ULA         the palette register and how a colour is written
;   paging                ROMSEL, ACCCON and its bits; the Master's HAZEL and ANDY
;   the system VIA        its registers, the interrupt bits, the ACR, the latch
;   the user VIA          what the Solidisk board test touches
;   sideways RAM boards   the Watford and Solidisk write-select registers
;   the SN76489           the latch byte
;   the disc controllers  the 8271's and the WD1770's commands and status bits
;                         (their addresses differ by machine: defs.inc)
;   the MOS               IRQ1V, the interrupt entry's A, ROMSEL's copy, the ROM
;                         table and a sideways ROM's header
;   opcodes               bytes written as data: patched stores, bit-skips
; ============================================================================

; ---------------------------------------------------------------- the 6845 CRTC
CRTC_IDX   = $FE00                 ; the register number
CRTC_DAT   = $FE01                 ; and its data
R_HTOT     = 0                     ; characters a scanline - 1
R_HDISP    = 1                     ; characters displayed
R_HSYNC    = 2                     ; the horizontal sync's position
R_SYNCW    = 3                     ; the sync widths: vertical << 4 | horizontal
R_VTOT     = 4                     ; character rows a frame - 1
R_VADJ     = 5                     ; and the scanlines added to them
R_VDISP    = 6                     ; character rows displayed
R_VSYNC    = 7                     ; the row the vsync is on
R_ILACE    = 8                     ; interlace and display delay
R_MAXRAST  = 9                     ; scanlines a character row - 1
R_CURS     = 10                    ; the cursor's start line (bit 5: off)
R_CURE     = 11                    ; and its end line
R_ADDRH    = 12                    ; the screen's start, in characters: high byte
R_ADDRL    = 13                    ;  and low
CRTC_NREGS = 14                    ; R0-R13: what start-up programs (R14-R17 are the
                                   ;  cursor and light pen, unused)
MODE1_R0   = 127                   ; MODE 1's horizontal total - 1: 128 character clocks
MODE1_R2   = 98                    ; its horizontal sync position
MODE1_R3   = $28                   ; its sync widths: 2 scanlines, 8 characters
R10_CUROFF = $20                   ; R10 bit 5: the cursor off
MODE1_R11  = 8                     ; the MOS's cursor end line (unseen: cursor off)
; the character cell, MODE 1: a character is 8 scanlines, a byte each, 4 pixels of
; two bits across (pixel 0 in bits 7 and 3, pixel 3 in bits 4 and 0); a game pixel is
; two of them
CHARLINES  = 8                     ; scanlines a character row (R9 = CHARLINES - 1)
CHARBYTES  = 8                     ; bytes a character: one a scanline
MODE1_DOTS_L = $CC                 ; a byte's left game pixel: its two screen
                                   ;  pixels' bits
MODE1_DOTS_R = $33                 ; and its right one's

; ---------------------------------------------------------------- the video ULA
; A palette entry is written as (index << PAL_SHIFT) | (physical colour ^ PAL_INV):
; the ULA takes the colour inverted.  In MODE 1 a screen pixel's two bits are the
; index's bits 3 and 1 (bits 2 and 0 are don't-cares), so a logical colour is four
; entries.
ULA_PAL    = $FE21                 ; the palette register
PAL_SHIFT  = 4                     ; the index's place in the byte
PAL_INV    = 7                     ; the physical colour's bits, all written inverted
PAL_N      = 16                    ; the palette's entries
PCOL_BLACK = 0                     ; the physical colours: bit 0 red, 1 green, 2 blue
PCOL_YELLOW = 3
PCOL_MAGENTA = 5
PCOL_CYAN  = 6
LCOL_IDX_B1 = 8                    ; a MODE 1 logical colour's bit 1 is the index's
LCOL_IDX_B0 = 2                    ;  bit 3, its bit 0 the index's bit 1

; ---------------------------------------------------------------- paging
ROMSEL     = $FE30                 ; the paged (sideways) bank, bits 0-3
ROMSEL_ANDY = $80                  ; Master: bit 7 pages ANDY, 4K of RAM, over $8000
ACCCON     = $FE34                 ; Master: shadow RAM and HAZEL
ACC_D      = $01                   ; D: the CRTC displays shadow RAM
ACC_X      = $04                   ; X: the CPU's $3000-$7FFF is shadow RAM
ACC_Y      = $08                   ; Y: HAZEL, 8K of RAM, over $C000-$DFFF
HAZEL      = $C000                 ; Master: HAZEL, and its size in pages (8K)
HAZEL_PAGES = $20
ANDY       = $8000                 ; ANDY, and its size in pages (4K)
ANDY_PAGES = $10

; ---------------------------------------------------------------- the system VIA
VIA_ORB    = $FE40                 ; port B: the addressable latch
VIA_DDRA   = $FE43                 ; port A's direction
VIA_T1CL   = $FE44                 ; T1: the rupture chain's step timer -- the counter
VIA_T1CH   = $FE45                 ;  (a read of T1CL clears T1's flag)
VIA_T1LL   = $FE46                 ;  and the latch
VIA_T1LH   = $FE47
VIA_ACR    = $FE4B                 ; the auxiliary control register
VIA_IFR    = $FE4D                 ; the interrupt flags
VIA_IER    = $FE4E                 ;  and enables
VIA_ORANH  = $FE4F                 ; port A without handshake
VIA_ISET   = $80                   ; IER: bit 7 set means set (else clear) the bits
                                   ;  named; IFR: any enabled source is up
VIA_IT1    = $40                   ; IER/IFR: timer 1
VIA_ICA1   = $02                   ; IER/IFR: CA1, the vsync
VIA_ACR_T1 = $C0                   ; ACR bits 7-6: T1's mode --
VIA_ACR_T1CONT = $40               ;  continuous interrupts, PB7 untouched
; the addressable latch (ORB bits 0-2 the address, bit 3 the value)
SL_SND     = 0                     ; the SN76489's write enable (low writes)
SL_KBD     = 3                     ; the keyboard's autoscan (1 on)
SL_SET     = 8                     ; the value bit
DDRA_KEYS  = $7F                   ; port A: PA0-6 out (the key number), PA7 in
DDRA_OUT   = $FF                   ;  all out (a byte to the sound chip)

; ---------------------------------------------------------------- the user VIA
UVIA_DDRB  = $FE62                 ; port B's direction (a Solidisk board's write-bank
UVIA_IER   = $FE6E                 ;  register is its bits 0-3); the interrupt enables

; ---------------------------------------------------------------- sideways RAM boards
; Which bank a STORE goes to, on a board that chooses it apart from ROMSEL (defs.inc
; BOARD_*): Watford, a store to $FF30 + bank; Solidisk, the bank on the user VIA's
; port B, bits 0-3 (UVIA_DDRB = SOLIDISK_BITS first)
WRSEL_WATFORD  = $FF30
WRSEL_SOLIDISK = $FE60
SOLIDISK_BITS  = $0F

; ---------------------------------------------------------------- the SN76489
; A latch byte: %1 cc t dddd -- channel cc, t = 1 the volume (attenuation dddd, 15
; silent), 0 a tone's low 4 bits (its high 6 follow as a data byte, bit 7 clear).
; Channel 3 is the noise: its 3 data bits are the control, written by a latch or a
; data byte alike (a data byte replaces them all): bit 2 white (else periodic),
; bits 0-1 the shift rate.
SN_LATCH   = $80
SN_VOL     = $10
SN_CHSHIFT = 5                     ; the channel's place
SN_DATAMASK = $0F                  ; the 4 data bits
SN_ATT_OFF = $0F                   ; attenuation 15: silent
SN_NOISE   = 3
SN_WHITE   = $04                  ; the noise control's white-noise bit

; ---------------------------------------------------------------- the disc controllers
; the Intel 8271 (the Model B's)
I8271_ST_BUSY    = $80             ; status: a command is running
I8271_ST_PARFULL = $20             ;  the parameter register is full
I8271_ST_IRQ     = $04             ;  a byte is ready (non-DMA data request); clear on
                                   ;  an interrupt, the command has ended (disc.s)
I8271_RES_MASK   = $1E             ; result: the completion code (0 good)
I8271_DRV0       = $40             ; command bits 7-6: drive 0 ($40), drive 1 ($80)
I8271_CMD_WRSPEC = $3A             ; write special register
I8271_CMD_RDSTAT = $2C             ; read drive status
I8271_CMD_READ   = $13             ; read data, several sectors
I8271_SR_DCOR    = $23             ; special register: the drive control output
I8271_LOADHEAD   = $08             ;  its bit 3: select + load head (the motor)
I8271_SEC256     = $20             ; the count byte's sector size: 256 bytes
; the Western Digital 1770 (the Acorn board's and the Master's)
WD_CMD_RESTORE   = $00             ; seek track 0
WD_CMD_SEEK      = $10             ; seek the track in the data register, no verify
WD_CMD_READM     = $94             ; read sectors (multiple) with a head settle
WD_CMD_FORCEINT  = $D0             ; force interrupt: stop the command
WD_ST_BUSY       = $01             ; status: a command is running
WD_ST_DRQ        = $02             ;  a byte is ready
WD_SETTLE        = 20              ; a delay loop's count after a command (its busy
                                   ;  takes a moment to show)

; ---------------------------------------------------------------- the MOS
IRQ1V      = $0204                 ; the ROM's interrupt entry jumps through it
MOS_IRQA   = $FC                   ;  having saved A here
MOS_ROMSEL = $F4                   ; the MOS's own copy of ROMSEL (the boot loader
                                   ;  keeps it true)
MOS_ROMTAB = $02A1                 ; its ROM table: the type byte of each socket's ROM
                                   ;  it recognised at BREAK, 0 for the other sockets
ROMBASE    = $8000                 ; sideways memory, and a ROM's header there:
ROMHDR_TYPE = ROMBASE + 6          ;  the type byte,
ROMHDR_COPY = ROMBASE + 7          ;  the copyright string's offset (0, "(C)" there),
ROMHDR_TITLE = ROMBASE + 9         ;  the title, 0-terminated, then the version string
MOS_MASTER = 3                     ; OSBYTE 0's MOS version: 3 and up are a Master's

; ---------------------------------------------------------------- opcodes
OP_BIT_ABS = $2C                   ; bit abs: as data, skips the two bytes after it
OP_BIT_ZP  = $24                   ; bit zp: skips one
OP_STA_ABSX = $9D                  ; sta abs,x: the boot loader writes it over a
                                   ;  write-bank store whose bank is in X (cpu.inc
                                   ;  WR_INX; ldprog.s)
