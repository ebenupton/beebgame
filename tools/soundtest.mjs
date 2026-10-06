// The engine's sound effects player (SOUND6: engine/sound6.s) driven directly: node
// beebgame/tools/soundtest.mjs disc out.json.  Boots the disc on a Master to the title, then
// with interrupts masked calls the routines as the vsync and the logic would: sound_reset
// once, then for each tick the scheduled sfx_request calls (in the kernel: low RAM's
// page_logic first) and one sfx_tick (in bank 6: page6 first, as the vsync does),
// recording every value the sound chip is given.
// Timing plays no part, so two builds with the same player and effects give the same stream,
// and tools/sfx.py check compares its model of the player with it.  The labels are the
// disc's directory's master/labels.txt (build.sh's).
import { readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const disc = path.resolve(process.argv[2]), outf = process.argv[3];
const A = {}; for (const m of readFileSync(path.join(path.dirname(disc), "master", "labels.txt"), "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(disc);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(40_000_000);                              // the title
const cpu = s._machine.processor;
const rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
const writes = []; let tick = -1;
const poke0 = s._soundChip.poke.bind(s._soundChip);
s._soundChip.poke = (v) => { writes.push([tick, v]); return poke0(v); };
const TRAP = 0x0E00;                                      // (LDPROG's room: unused at the title)
let halted = false;
cpu.debugInstruction.add((pc) => { if (pc === TRAP) { halted = true; return true; } return false; });
async function call(addr, a = 0, x = 0, y = 0) {
    const ret = TRAP - 1;                                 // jsr's return address, less one
    wr(0x100 + cpu.s, ret >> 8); cpu.s = (cpu.s - 1) & 255;
    wr(0x100 + cpu.s, ret & 255); cpu.s = (cpu.s - 1) & 255;
    cpu.a = a; cpu.x = x; cpu.y = y; cpu.p.i = true; cpu.pc = addr;
    halted = false;
    for (let n = 0; !halted && n < 50; n++) await s.runFor(20_000);
    if (!halted) throw new Error("call to " + addr.toString(16) + " did not return");
}
// the schedule (tools/sfx.py schedule()): every effect alone, then triples and runs that
// overlap on the channels
const NSFX = A.sfx_fxhdr - A.sfx_fxtab;                // (sfxdata.inc asserts it)
const sched = {};
const at = (t, e) => (sched[t] = sched[t] || []).push(e);
let t = 1;
for (let e = 0; e < NSFX; e++) { at(t, e); t += 40; }
for (let e = 0; e < NSFX; e++) { at(t, e); at(t + 2, (e + 7) % NSFX); at(t + 3, (e + 13) % NSFX); t += 25; }
for (let e = 0; e < 60; e++) { at(t, (e * 5) % NSFX); t += 3; }
const END = t + 200;
const saveS = cpu.s, saveP = cpu.p.asByte ? cpu.p.asByte() : null;
cpu.p.i = true;
await call(A.page_logic);                                // (the kernel's routines: bank 7, as their callers have it)
await call(A.sound_reset);
for (tick = 0; tick < END; tick++) {
    await call(A.page_logic);
    for (const e of sched[tick] || []) await call(A.sfx_request, e);
    await call(A.page6);
    await call(A.sfx_tick);
}
writeFileSync(outf, JSON.stringify({ ticks: END, writes }));
console.log("ticks", END, "writes", writes.length);
