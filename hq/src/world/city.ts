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

const STATE_DIR = process.env.STATE_DIR ?? '/state';
const FILE = join(STATE_DIR, 'city.json');

/**
 * The base, and the region drones may operate in.
 *
 * These mirror MapServer's DATA["bounds"] and the force-loaded chunks. They are duplicated rather
 * than fetched because a plot must not be allocated outside the loaded world even when the bridge
 * is down -- and because getting this wrong is how a drone walks out of the world and freezes.
 */
const ORIGIN = { x: -85, y: 81, z: -44 };
const BOUNDS = { min: { x: -155, y: 0, z: -105 }, max: { x: -25, y: 200, z: 15 } };

function load(): Registry {
  try {
    const raw = JSON.parse(readFileSync(FILE, 'utf8'));
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
    writeFileSync(FILE, JSON.stringify(city, null, 2));
  } catch (err) {
    // Report rather than throw: failing to persist should not fail the allocation the operator
    // just made. It should, however, be loud -- a registry that silently stops saving looks fine
    // until the restart that loses the city.
    console.error(`[city] could not persist ${FILE}: ${(err as Error).message}`);
  }
}
