/**
 * THE ONE NUMBER THAT SAYS WHETHER THE SETTLEMENT IS ALIVE.
 *
 * Every layer here reports success from its own intent: a sweep says "done", a deposit says
 * "unloaded", a relief says "delivered". For an entire evening all of those were true while the
 * fuel economy ran at a loss and three hand-fed loads of coal vanished. The only measurement that
 * could not lie was a shell loop sampling storage and every drone's tank once a minute -- so that
 * loop now lives here, and the brief reads it.
 *
 * Income is burnable in NETWORKED storage (what the smelter, the fetchers and the factories can
 * see); a cache chest off the network does not count, because nothing deposited there takes part.
 * Burn is the fleet's tanks. Fuel per block is the price of movement -- measured at 1 in open air
 * and 25 while a drone paced -- and it is the number that decides whether any income can ever be
 * positive.
 */
import { readStockWhere } from '../world/stock.js';
import { state } from '../world/state.js';

const BURNABLE = /coal|_log|planks/;
const SAMPLE_MS = 60_000;
const KEEP = 120;                 // two hours

type Sample = { t: number; burnable: number | null; fleetFuel: number; blocks: number; working: number };

const ring: Sample[] = [];
const lastPos = new Map<number, { x: number; y: number; z: number }>();

/** One reading. Exported so a test (or a tick) can drive it without the timer. */
export async function sampleEconomy(): Promise<Sample> {
  const drones = state.listDrones() as any[];
  let fleetFuel = 0, blocks = 0, working = 0;
  for (const d of drones) {
    fleetFuel += Number(d.fuel) || 0;
    if (d.status === 'working') working++;
    const p = d.pos;
    const prev = lastPos.get(d.id);
    if (p && prev) blocks += Math.abs(p.x - prev.x) + Math.abs(p.y - prev.y) + Math.abs(p.z - prev.z);
    if (p) lastPos.set(d.id, { x: p.x, y: p.y, z: p.z });
  }
  const burnable = await readStockWhere((n) => BURNABLE.test(n), () => undefined);
  const s = { t: Date.now(), burnable, fleetFuel, blocks, working };
  // An empty fleet is HQ not knowing yet, not a fleet with no fuel. The first sample after a
  // restart read 0 and made the window report "burn -6732" -- a gain of 6,732 fuel from nowhere.
  if (drones.length > 0) ring.push(s);
  if (ring.length > KEEP) ring.shift();
  return s;
}

/** What the last N minutes say. Nulls where there is not enough history to say anything. */
export function economySummary(p_WindowMin = 20) {
  const now = Date.now();
  const win = ring.filter((s) => now - s.t <= p_WindowMin * 60_000);
  const first = win[0], last = win[win.length - 1];
  if (!first || !last || win.length < 3) {
    return { samples: win.length, windowMin: p_WindowMin, burnable: last?.burnable ?? null,
             fleetFuel: last?.fleetFuel ?? null, income: null, burn: null, fuelPerBlock: null };
  }
  const income = (first.burnable != null && last.burnable != null) ? last.burnable - first.burnable : null;
  const burn = first.fleetFuel - last.fleetFuel;
  const moved = win.slice(1).reduce((n, s) => n + s.blocks, 0);
  // Fuel spent per block moved. Refuels ADD fuel mid-window, so this is a floor on the true price,
  // never an overstatement -- which is the safe direction for a number that decides "is this viable".
  const fuelPerBlock = moved > 0 && burn > 0 ? Math.round((burn / moved) * 10) / 10 : null;
  const working = Math.round(win.reduce((n, s) => n + s.working, 0) / win.length);
  return { samples: win.length, windowMin: p_WindowMin, burnable: last.burnable, fleetFuel: last.fleetFuel,
           income, burn, fuelPerBlock, working };
}

/**
 * The fault the whole evening needed and nobody raised: drones working, tanks falling, nothing
 * arriving. Null when there is not yet enough history to accuse anyone.
 */
export function economyFault(): string | null {
  const e = economySummary(20);
  if (e.income == null || e.samples < 15) return null;
  if ((e.working ?? 0) >= 2 && e.income <= 0 && (e.burn ?? 0) > 0) {
    return `NO INCOME: ${e.working} drones worked for ${e.windowMin} min, tanks fell ${e.burn}, `
         + `burnable in storage moved ${e.income}. Work that earns nothing is the fuel trap in slow `
         + `motion -- find what the jobs actually deliver before adding fuel.`;
  }
  return null;
}

let timer: NodeJS.Timeout | null = null;
export function startEconomySampler(): void {
  if (timer) return;
  // silent: allow (a sample that fails leaves a gap in the ring, and the brief reports how many samples the window holds -- a missing minute is visible, not hidden)
  timer = setInterval(() => { sampleEconomy().catch(() => undefined); }, SAMPLE_MS);
  // silent: allow (same as above -- the first sample is a convenience so the brief is not empty for a minute)
  sampleEconomy().catch(() => undefined);
}
