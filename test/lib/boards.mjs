// Write-select sideways RAM boards, emulated on a jsbeeb Model B (jsbeeb has none):
// reads page through ROMSEL as ever, but a store into $8000-$BFFF goes to the bank the
// board's register names -- Watford: the low nibble of the address of the last store to
// $FF30-$FF3F; Solidisk: user VIA port B bits 0-3 (ORB & DDRB, stores to $FE60/$FE62 or
// their $FE70/$FE72 images).  Both start at bank 0, as a fresh machine would, more or
// less.  The store lands only when that socket is RAM (cpu.model.swram).
// cpu.boardMismatch counts, by PC, every store the game makes into a bank other than
// the one paged for reading (cpu.romsel) -- what a missing or wrong write-bank store
// does.  Code in main RAM $0D00-$1FFF (the NMI stub at $0D00, LDPROG from $0E00, the
// boot loader from $1900) is left out: it copies between banks on purpose.  Stores
// into the sideways range still reach a debugWrite hook (cpu._debugWrite is called).
//   boardEmu(cpu, "watford" | "solidisk")   (anything else throws)
export function boardEmu(cpu, kind) {
  if (kind !== "watford" && kind !== "solidisk") throw new Error(`BBOARD: ${kind}?`);
  const orig = cpu.writemem.bind(cpu);
  let wr = 0, orb = 0, ddrb = 0;
  cpu.boardMismatch = new Map();
  cpu.writemem = function (addr, b) {
    addr &= 0xffff;
    if (addr >= 0x8000 && addr < 0xc000) {
      if (cpu._debugWrite) cpu._debugWrite(addr, b);
      const bank = kind === "solidisk" ? (orb & ddrb & 15) : wr;
      const pc = cpu.pc;
      if (bank !== (cpu.romsel & 15) && !(pc >= 0x0D00 && pc < 0x2000))
        cpu.boardMismatch.set(pc, (cpu.boardMismatch.get(pc) ?? 0) + 1);
      if (cpu.model.swram[bank]) cpu.ramRomOs[cpu.romOffset + bank * 16384 + (addr - 0x8000)] = b;
      return;
    }
    if (kind === "watford" && (addr & 0xfff0) === 0xff30) wr = addr & 15;
    if (kind === "solidisk") { if ((addr & 0xffef) === 0xfe60) orb = b; else if ((addr & 0xffef) === 0xfe62) ddrb = b; }
    return orig(addr, b);
  };
}
