// beebgame's measurement harness: a frame-exact driver for a game under jsbeeb.
//
// WHY THIS EXISTS.  The old benchmark advanced the machine in 20000-cycle polls and
// checked a frame counter afterwards, so every wait overshot by a variable amount and
// every key write landed at an arbitrary point inside a frame.  Whether the logic saw
// a key this frame or the next then depended on sub-frame phase -- which depends on
// absolute timing, which depends on code size.  One frame of drift at the first
// location put the world somewhere else for every location after it (measured: f0 64
// vs 65 at location 1, and by location 10 one build's Cleo had died and restarted the
// level).  The costs being compared were of different scenes.
//
// THE FIX.  jsbeeb's debugInstruction hook stops execution *before* the instruction
// when a handler returns true, so an exact PC break is available at full speed.  Every
// wait here is therefore "run to the next frame_top", a symbol the game places at the
// one point reached exactly once per rendered frame, before its logic reads 'keys'.  Inputs are written while stopped there.  Nothing in the protocol can
// observe a cycle count, so nothing in it can observe code size.
//
// WHAT IS STILL NOT INVARIANT, and why that is honest rather than a bug: moving code
// changes real cycle counts, because a taken 6502 branch costs an extra cycle when its
// target is on another page, and so does an indexed access that crosses one.  No
// harness can remove that -- it is the machine.  So this module does not claim equal
// cycles; it claims the same SCENE, and proves it: fingerprint() hashes every piece of
// state the renderer reads, and a comparison is only valid where the fingerprints
// match.  A cycle difference under a matching fingerprint is genuine; a cycle
// difference under a differing fingerprint is a measurement artifact.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import path from "node:path";

export function findJsbeeb() {
  const npx = path.join(homedir(), ".npm", "_npx");
  for (const d of readdirSync(npx)) {
    const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js");
    if (existsSync(p)) return p;
  }
  throw new Error("jsbeeb not found");
}
// the linker's debug file beside a build's labels (game.dbg; cleo.dbg in builds made
// before the engine was its own project)
export function dbgPath(labels) {
  const d = path.dirname(labels), g = path.join(d, "game.dbg");
  return existsSync(g) ? g : path.join(d, "cleo.dbg");
}
export function loadLabels(file) {
  const A = {};
  for (const m of readFileSync(file, "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
  return A;
}

const CHUNK = 90_000;          // < jsbeeb's MaxCyclesPerIter (100000) so each runFor is
                               // exactly one execute() call -- see runTo for why
const WRAP = 2_000_000;        // cpu.currentCycles wraps at 2e6 (cycleSeconds ticks)

// A banked build (the Model B's layout, on either machine) has code and state in
// sideways RAM, where one address names a different byte in each bank: the linker's
// debug file says which bank each label is in (by its segment), so a PC break waits
// for that bank to be paged ($F4, ROMSEL's copy) and a state read pages it first.
const SEGBANK = [[/^SPR4/, 4], [/^(SPR5|MAP5)/, 5], [/^TIL/, 6],
                 [/^(COMMON7|GAME|ENG|MNU|KRN|LGC|D8271[HC]|D1770[HC])/, 7]];   // (LGC: builds before the rename; D: the driver slot)
// Bank 7 below its kernel holds one of two images, the game's (GAME*, ENG*) or the menus'
// (MNU*), and the kernel's ld_img says which (disc.s load_image): a break in either
// waits for that image as well as the bank.
const SEGIMG = [[/^(GAME|ENG|LGC)/, 0], [/^MNU/, 1]];
export function loadBanks(dbgFile) {
  if (!existsSync(dbgFile)) return null;
  const segBank = new Map(), segImg = new Map(), byName = new Map(), byPc = new Map(), imgByName = new Map(), imgByPc = new Map();
  const t = readFileSync(dbgFile, "utf8");
  const kernel = /name="KRNCODE"/.test(t);        // (before the kernel: the menus were bank 6's overlay)
  for (const m of t.matchAll(/^seg\tid=(\d+),name="(\w+)"/gm)) {
    const e = !kernel && /^MNU/.test(m[2]) ? [null, 6] : SEGBANK.find(([re]) => re.test(m[2]));
    if (e) segBank.set(m[1], e[1]);
    const i = SEGIMG.find(([re]) => re.test(m[2]));
    if (i) segImg.set(m[1], i[1]);
  }
  if (!segBank.size) return null;
  for (const m of t.matchAll(/^sym\tid=\d+,name="(\w+)",[^\n]*?val=0x([0-9A-F]+),seg=(\d+),type=lab/gm)) {
    const b = segBank.get(m[3]);
    if (b === undefined) continue;
    byName.set(m[1], b);
    const a = parseInt(m[2], 16);
    byPc.set(a, byPc.has(a) && byPc.get(a) !== b ? -1 : b);   // (-1: two banks, ambiguous)
    const i = segImg.get(m[3]);
    if (i !== undefined) { imgByName.set(m[1], i); imgByPc.set(a, imgByPc.has(a) && imgByPc.get(a) !== i ? -1 : i); }
  }
  return { byName, byPc, imgByName, imgByPc };
}
// is bank 7's image the one a label at pc is in? (read with bank 7 paged: ld_img is
// the kernel's)
export function imgOk(cpu, A, banks, pc) {
  const i = banks?.imgByPc.get(pc);
  return i === undefined || i < 0 || A.ld_img === undefined || cpu.readmem(A.ld_img) === i;
}

export class Harness {
  constructor(s, A, banks = null) { this.s = s; this.A = A; this.cpu = s._machine.processor; this.banks = banks; }
  // is the CPU at pc, in the bank that label lives in?
  at(pc, p) { if (p !== pc) return false; const b = this.banks?.byPc.get(pc); return (b === undefined || b < 0 || this.cpu.readmem((this.A.romsel_cpy ?? 0xf4)) === b) && imgOk(this.cpu, this.A, this.banks, pc); }
  // is the CPU at address a, in the bank the named label lives in? (an address that is
  // no label -- the instruction after a jsr, say -- takes its bank from a neighbour)
  atIn(a, name, p) { if (p !== a) return false; const b = this.banks?.byName.get(name); return b === undefined || this.cpu.readmem((this.A.romsel_cpy ?? 0xf4)) === b; }
  // f() with the bank a named label lives in paged in (read side only)
  inBank(name, f) {
    const b = this.banks?.byName.get(name);
    if (b === undefined) return f();
    const was = this.cpu.readmem((this.A.romsel_cpy ?? 0xf4)); this.cpu.writemem(0xfe30, b);
    try { return f(); } finally { this.cpu.writemem(0xfe30, was); }
  }

  rd(a) { return this.cpu.readmem(a); }
  wr(a, v) { this.cpu.writemem(a, v); }
  rd16(a) { return this.rd(a) | (this.rd(a + 1) << 8); }
  rds16(a) { const v = this.rd16(a); return v >= 32768 ? v - 65536 : v; }
  wr16(a, v) { this.wr(a, v & 255); this.wr(a + 1, (v >> 8) & 255); }
  cyc() { return this.cpu.currentCycles + this.cpu.cycleSeconds * WRAP; }

  // Run until PC is exactly `pc`.  jsbeeb skips the hook check on the FIRST
  // instruction of each execute() call, so a chunk boundary landing on the target
  // would silently run past it.  Two things make this safe: we chunk ourselves at
  // less than MaxCyclesPerIter (one execute per runFor), and we test cpu.pc after
  // every chunk -- so a chunk that *ended* on the target is detected here rather
  // than resumed past.  Resuming from the target is only ever done deliberately, by
  // the next runTo call, which is exactly the "advance to the next occurrence" we want.
  async runTo(pc, budget = 40_000_000) {
    const t0 = this.cyc();
    const h = this.cpu.debugInstruction.add((p) => this.at(pc, p));
    try {
      while (this.cyc() - t0 < budget) {
        await this.s.runFor(CHUNK);
        if (this.at(pc, this.cpu.pc)) return this.cyc() - t0;
      }
    } finally { h.remove(); }
    throw new Error(`runTo(${pc.toString(16)}) timed out after ${budget} cycles`);
  }

  // ---- render-work measurement, with the interrupt separated out ------------------
  // The window is select_backbuf..render_done (render_frame opens with wait_flip, an
  // idle spin of 6-23k cycles that is not work).  The vsync/timer ISR fires inside
  // that window, and how many times depends on where the CRTC phase happens to sit --
  // so it is accounted separately rather than left to pollute the figure.
  // Also counts instructions retired in the window.  Cycles move when code moves --
  // a taken branch costs an extra cycle across a page -- so for a change of a few
  // hundred cycles the cycle figure cannot tell a real win from a relocation.  The
  // instruction count can: it is exactly what the code did, wherever it sits.
  installMeter() {
    // 'work' is the render window.  'logic' is frame_top..render_frame, the two game
    // steps -- about 18000 cycles a frame, and invisible to the render figure, so a
    // change to the logic measures as nothing at all unless it is timed separately.
    const A = this.A, m = { work: 0, isr: 0, isrCount: 0, frames: 0, instrs: 0, logic: 0, logicI: 0 };
    let t0 = -1, inWin = false, isrAt = -1, exiting = false;
    this.meter = m;
    let n = 0, lt0 = -1, li = 0, inLogic = false;
    this.cpu.debugInstruction.add((pc, op) => {
      if (inWin) n++;
      if (inLogic) li++;
      if (this.at(A.frame_top, pc)) { lt0 = this.cyc(); inLogic = true; li = 0; }
      else if (inLogic && this.at(A.render_frame, pc)) { m.logic = this.cyc() - lt0; m.logicI = li; inLogic = false; }
      // the window opens as render_frame's wait for the flip returns (its first
      // instruction is that jsr): everything the frame does after
      if (!inWin && this.atIn(A.render_frame + 3, "render_frame", pc)) { t0 = this.cyc(); inWin = true; m.isr = 0; m.isrCount = 0; n = 0; }
      else if (inWin && this.at(A.render_done, pc)) { m.work = this.cyc() - t0; m.instrs = n; inWin = false; m.frames++; }
      else if (this.at(A.irq_handler, pc)) { isrAt = this.cyc(); }
      else if (isrAt >= 0 && op === 0x40) { exiting = true; }   // RTI: measure to the
      else if (exiting) {                                       // instruction after it
        if (inWin) { m.isr += this.cyc() - isrAt; m.isrCount++; }
        exiting = false; isrAt = -1;
      }
      return false;
    });
    return m;
  }

  // ---- the scene the renderer sees ------------------------------------------------
  // Every input to render_frame's cost, named by label so it is build-independent: the
  // engine's, then the game's (gameScene, a subclass's: the game state the scene is of).
  gameScene() { return []; }
  sceneRanges() {
    const A = this.A, MAXSPR = 32, MAXREC = 32;
    return [
      ["wcx", A.wcx, 2], ["wcy", A.wcy, 1], ["wfine", A.wfine, 1], ["wy", A.wy, 2],
      ["curbuf", A.curbuf, 1],   // (not BUF_VALID: the Master encodes it in BUF_CX now)
      ["BUF_CX", A.BUF_CX, 4, "bufcx"], ["BUF_CY", A.BUF_CY, 2],
      ["BARDIRTY", A.BARDIRTY, 1],   // (one byte: one bar; not BARBG, gone)
      ["MIRR_R", A.MIRR_R, 2], ["MIRR_LO", A.MIRR_LO, 2],
      ["NSPR", A.NSPR, 1], ["SPRLIST", A.SPRLIST, 5 * MAXSPR, "sprites"],
      ["RECCNT", A.RECCNT, 2], ["SPRREC", A.SPRREC, 2 * MAXREC * 10, "rec"], ["KEEP", A.KEEP, MAXREC, "keep"],
      ["DIRTYCNT", A.DIRTYCNT, 2], ["DIRTYLIST", A.DIRTYLIST, 2 * 2 * 64, "dirty"],
      ...this.gameScene(),
    ].filter(([, a]) => a !== undefined);
  }
  fingerprint() {
    const h = createHash("sha256"), parts = {};
    for (const [name, addr, len, kind] of this.sceneRanges()) {
      const b = Buffer.alloc(len);
      if (typeof kind === "function") {  // a game's own reading (its scene's value, not its bytes)
        kind(this, b);
      } else if (kind === "dirty") {         // each buffer's list up to its count: the capacity
        const cap = (this.A.DIRTYCNT - this.A.DIRTYLIST) / 4;   // (DIRTYMAX) is a build choice
        const n = cap >= 1 && cap <= 64 && Number.isInteger(cap) ? cap : 16;
        for (let bf = 0; bf < 2; bf++) { const c = Math.min(this.rd(this.A.DIRTYCNT + bf), n);
          for (let i = 0; i < 2 * c; i++) b[bf * 128 + i] = this.rd(this.A.DIRTYLIST + bf * 2 * n + i); }
      } else if (kind === "sprites" && this.A.SPR_XL !== undefined) {   // five arrays: as id,xl,xh,yl,yh records
        // (each array to its own length, MAXSPR being a build's choice; the rest zero)
        const n = Math.min(len / 5, this.A.SPR_XL - this.A.SPR_ID), F = [this.A.SPR_ID, this.A.SPR_XL, this.A.SPR_XH, this.A.SPR_YL, this.A.SPR_YH];
        this.inBank("SPR_ID", () => { for (let i = 0; i < n; i++) for (let k = 0; k < 5; k++) b[i * 5 + k] = F[k] < 0x10000 ? this.rd(F[k] + i) : 0; });
      } else if (kind === "bufcx" && this.A.BUF_CXH !== undefined) {   // (split: low, high bytes)
        this.inBank(name, () => { for (let bf = 0; bf < 2; bf++) { b[2 * bf] = this.rd(addr + bf); b[2 * bf + 1] = this.rd(this.A.BUF_CXH + bf); } });
      } else if (kind === "rec" || kind === "keep") {   // per buffer, the records it holds
        // (MAXREC is a build's choice: each buffer's live records, the rest zero)
        const mr = (this.A.RECCNT - this.A.SPRREC) / 20, cap = len / (kind === "rec" ? 20 : 1);
        this.inBank("SPRREC", () => {
          if (kind === "keep") { for (let i = 0; i < Math.min(mr, cap); i++) b[i] = this.rd(addr + i); return; }
          for (let bf = 0; bf < 2; bf++) {
            const c = Math.min(this.rd(this.A.RECCNT + bf), mr, cap);
            for (let i = 0; i < c * 10; i++) b[bf * cap * 10 + i] = this.rd(this.A.SPRREC + bf * mr * 10 + i);
          }
        });
      } else this.inBank(name, () => { for (let i = 0; i < len; i++) b[i] = this.rd(addr + i); });
      h.update(name); h.update(b);
      parts[name] = b.toString("hex");
    }
    return { fp: h.digest("hex").slice(0, 16), parts };
  }
}
