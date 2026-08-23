/**
 * The city: the live plot registry, and its persistence.
 *
 * Kept separate from plots.ts so the RULES stay pure and testable while the STATE has somewhere to
 * live. Plot allocation that cannot be tested without a disk is plot allocation that stops being
 * tested.
 *
 * Persistence is deliberately boring -- a JSON file, written on every change. The registry is tens
 * of records, not thousands, and losing it means losing the map of what the settlement is, which
 * would let the next build order sit on top of something that already exists. That is precisely
 * the failure the registry exists to prevent, so it must survive a container restart.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { newRegistry, type Registry, type Plot } from './plots.js';
import type { Factory } from './factories.js';

const STATE_DIR = process.env.STATE_DIR ?? '/state';
const FILE = join(STATE_DIR, 'city.json');

/**
 * The base, and the region drones may operate in.
 *
 * These mirror MapServer's DATA["bounds"] and the force-loaded chunks. They are duplicated rather
 * than fetched because a plot must not be allocated outside the loaded world even when the bridge
 * is down -- and because getting this wrong is how a drone walks out of the world and freezes.
 */
/**
 * WHERE THE SETTLEMENT IS. It moved, and this did not.
 *
 * These were the previous world's numbers, and nothing complained when the settlement was re-founded
 * 400 blocks away -- a mine order was duly planned at -35, 81, -90, a miner accepted it, and set off
 * for ground in a world that no longer exists. The plan was valid, the dispatch succeeded, the drone
 * reported "working", and the destination was fiction.
 *
 * One definition, environment-overridable, with the bounds derived from it so the two cannot drift.
 * Same fix as the supply loop's BASE, and the second place the same mistake was hiding.
 */
const ORIGIN = {
  x: Number(process.env.HIVE_BASE_X ?? -480),
  y: Number(process.env.HIVE_BASE_Y ?? 63),
  z: Number(process.env.HIVE_BASE_Z ?? 64),
};
/** How far from origin a plot may be sited. Must stay inside the force-loaded chunks. */
const REACH = Number(process.env.HIVE_REACH ?? 96);
const BOUNDS = {
  min: { x: ORIGIN.x - REACH, y: -64, z: ORIGIN.z - REACH },
  max: { x: ORIGIN.x + REACH, y: 200, z: ORIGIN.z + REACH },
};

/** The plant. Persisted beside the plots, because a factory without its plot is meaningless. */
export const factories: Factory[] = [];

function load(): Registry {
  try {
    const raw = JSON.parse(readFileSync(FILE, 'utf8'));

    // STATE THAT OUTLIVES ITS WORLD IS WORSE THAN NO STATE.
    //
    // This registry is persisted in a volume, and the volume survived the world being replaced. So
    // HQ came up in a brand-new world still holding 21KB of plots from the old one, planned a mine
    // at -35, 81, -90, and dispatched a miner to ground that no longer exists. The plan was valid,
    // the dispatch succeeded, the drone reported "working", and the destination was fiction. Nothing
    // anywhere reported a fault, because from every component's point of view nothing had failed.
    //
    // The origin is the settlement's identity. If the persisted one disagrees with the configured
    // one, this is somebody else's city: keep the file for forensics and start clean, rather than
    // silently inheriting coordinates nobody chose.
    const o = raw?.origin;
    const sameWorld = o && o.x === ORIGIN.x && o.y === ORIGIN.y && o.z === ORIGIN.z;
    if (!sameWorld && o) {
      const archived = `${FILE}.${o.x}_${o.y}_${o.z}.bak`;
      try { writeFileSync(archived, JSON.stringify(raw)); } catch { /* forensics are a bonus */ }
      console.log(`[city] persisted registry is for origin ${o.x},${o.y},${o.z} but this settlement `
                + `is at ${ORIGIN.x},${ORIGIN.y},${ORIGIN.z} -- archived to ${archived}, starting clean`);
      return newRegistry(ORIGIN, BOUNDS);
    }

    if (Array.isArray(raw?.factories)) factories.push(...raw.factories);
    if (Array.isArray(raw?.plots)) {
      return { origin: raw.origin ?? ORIGIN, bounds: raw.bounds ?? BOUNDS, plots: raw.plots as Plot[] };
    }
  } catch {
    // First run, or an unreadable file. Starting empty is correct and safe: an empty registry
    // refuses every plot-scoped order rather than permitting them, so a lost file cannot turn into
    // a licence to dig anywhere.
  }
  return newRegistry(ORIGIN, BOUNDS);
}

export const city: Registry = load();

export function saveCity(): void {
  try {
    mkdirSync(dirname(FILE), { recursive: true });
    writeFileSync(FILE, JSON.stringify({ ...city, factories }, null, 2));
  } catch (err) {
    // Report rather than throw: failing to persist should not fail the allocation the operator
    // just made. It should, however, be loud -- a registry that silently stops saving looks fine
    // until the restart that loses the city.
    console.error(`[city] could not persist ${FILE}: ${(err as Error).message}`);
  }
}
