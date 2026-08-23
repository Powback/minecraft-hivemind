/**
 * The plot registry: what the city is made of, and the rule that stops it eating itself.
 *
 * Until now nothing in the system knew where anything BELONGED. Orders carried raw coordinates and
 * drones executed them faithfully. That is not a hypothetical risk -- it is how a monitor wall got
 * built on top of D1 and destroyed it, and how a dig order excavated the base because the region
 * happened to contain a turtle. Every farm, smelter and factory that gets added is one careless
 * coordinate away from the same outcome, and no amount of care at the call site fixes it, because
 * the call site is exactly where the mistake is made.
 *
 * Two rules carry the whole idea:
 *
 *   1. Every build or dig order must name a plot, and is rejected if its bounds leave that plot or
 *      enter another. Collisions become impossible by CONSTRUCTION rather than by care.
 *   2. Plots are allocated by HQ from a growth grid -- a street pattern sized per purpose. That is
 *      what makes the settlement procedural: expansion is "allocate the next plot of type X", not
 *      a human choosing coordinates.
 *
 * Allocation lives here (HQ can see the whole city and has no memory ceiling). ENFORCEMENT has to
 * be mirrored in-world in TaskMan, because an order must still be refused when HQ is down -- a
 * settlement that loses its safety rules because a Docker container restarted is not autonomous.
 */

export type Purpose =
  | 'docks' | 'storage' | 'smelting' | 'crafting'
  | 'farm' | 'forestry' | 'mine_head' | 'power' | 'reserved';

export interface Vec3 { x: number; y: number; z: number }

export interface Plot {
  name: string;
  purpose: Purpose;
  /** Inclusive bounds. */
  min: Vec3;
  max: Vec3;
  /** Working surface. Builds sit on it; digs go below it. */
  ground: number;
  status: 'planned' | 'clearing' | 'active';
  /** Task or module responsible, when something has claimed it. */
  owner?: string;
}

/**
 * Footprint and siting per purpose.
 *
 * Sizes are deliberate rather than uniform: a tree farm needs sky and spacing, a smelter is a
 * bench, and a mine head is a shaft entrance. Making them all the same square would waste the
 * desert and, worse, make "allocate a plot" a decision nobody could reason about.
 */
export const SPEC: Record<Purpose, { w: number; l: number; h: number }> = {
  docks:     { w: 8,  l: 8,  h: 4 },
  storage:   { w: 6,  l: 6,  h: 4 },
  smelting:  { w: 6,  l: 4,  h: 4 },
  crafting:  { w: 4,  l: 4,  h: 4 },
  farm:      { w: 9,  l: 9,  h: 6 },
  forestry:  { w: 11, l: 11, h: 16 },   // trees need headroom, and leaves spread
  mine_head: { w: 5,  l: 5,  h: 4 },
  power:     { w: 6,  l: 6,  h: 6 },
  reserved:  { w: 8,  l: 8,  h: 4 },
};

/**
 * The street grid.
 *
 * A one-block gap between plots is not decoration -- it is what lets a drone walk BETWEEN two
 * active plots without entering either, which is the difference between haulers being routable and
 * every trip being a boundary violation.
 */
export const STREET = 1;
const CELL = 12;                        // grid pitch; larger than the biggest common footprint

export interface Registry {
  origin: Vec3;                          // the base; the city grows around it
  plots: Plot[];
  bounds: { min: Vec3; max: Vec3 };      // the operating region; nothing may be sited outside it
}

export function overlaps(a: { min: Vec3; max: Vec3 }, b: { min: Vec3; max: Vec3 }): boolean {
  return a.min.x <= b.max.x && a.max.x >= b.min.x
      && a.min.y <= b.max.y && a.max.y >= b.min.y
      && a.min.z <= b.max.z && a.max.z >= b.min.z;
}

/** Is `inner` wholly inside `outer`? This is the containment half of the enforcement rule. */
export function contains(outer: { min: Vec3; max: Vec3 }, inner: { min: Vec3; max: Vec3 }): boolean {
  return inner.min.x >= outer.min.x && inner.max.x <= outer.max.x
      && inner.min.y >= outer.min.y && inner.max.y <= outer.max.y
      && inner.min.z >= outer.min.z && inner.max.z <= outer.max.z;
}

/**
 * Rule 1, in one function. Every destructive order should pass through this.
 *
 * Returns null when the order is allowed, or the reason it is not. A reason rather than a boolean
 * because "rejected" with no explanation is the kind of thing an operator works around instead of
 * fixing -- and working around this rule is precisely how drones get destroyed.
 */
export function checkOrder(reg: Registry, plotName: string, region: { min: Vec3; max: Vec3 }): string | null {
  const plot = reg.plots.find((p) => p.name === plotName);
  if (!plot) return `no plot named "${plotName}"`;
  if (!contains(plot, region)) return `region leaves plot ${plot.name}`;
  const hit = reg.plots.find((p) => p.name !== plot.name && overlaps(p, region));
  if (hit) return `region enters plot ${hit.name} (${hit.purpose})`;
  return null;
}

/**
 * Allocate the next free plot of a purpose, spiralling outward from the base.
 *
 * Outward from the origin rather than filling a row: it keeps the settlement compact, which keeps
 * hauler trips short. A city that grows in a line is a city whose logistics cost rises linearly
 * with everything you add to it.
 */
export function allocate(reg: Registry, purpose: Purpose, name?: string): Plot | { error: string } {
  const spec = SPEC[purpose];
  const ground = reg.origin.y;

  for (const cell of spiral(200)) {
    const min: Vec3 = {
      x: reg.origin.x + cell.x * CELL,
      y: ground,
      z: reg.origin.z + cell.z * CELL,
    };
    const max: Vec3 = {
      x: min.x + spec.w - 1,
      y: ground + spec.h - 1,
      z: min.z + spec.l - 1,
    };
    // A plot must sit wholly inside the operating region, or the drones sent to work it will walk
    // out of the loaded world -- which is exactly how D3 was lost.
    if (!contains(reg.bounds, { min, max })) continue;

    // AND IT MUST NOT SIT ON THE TOWER.
    //
    // The spiral starts at the origin, and the origin IS the tower's centre column -- so the first
    // mine head allocated was inside the building, and a miner was dispatched to sink a shaft
    // through its own floor. It could not even reach it: the target was one block beneath the drone
    // and made of the slab it was standing on.
    //
    // The keep-out is the tower's footprint plus margin for the terraces, which step outward as the
    // building rises.
    if (withinKeepOut(cell)) continue;

    const padded = {
      min: { x: min.x - STREET, y: min.y, z: min.z - STREET },
      max: { x: max.x + STREET, y: max.y, z: max.z + STREET },
    };
    if (reg.plots.some((p) => overlaps(p, padded))) continue;

    const plot: Plot = {
      name: name ?? nextName(reg, purpose),
      purpose, min, max, ground, status: 'planned',
    };
    reg.plots.push(plot);
    return plot;
  }
  return { error: `no free ground for a ${purpose} plot inside the operating bounds` };
}

function nextName(reg: Registry, purpose: Purpose): string {
  const n = reg.plots.filter((p) => p.purpose === purpose).length + 1;
  return `${purpose}-${String(n).padStart(2, '0')}`;
}

/**
 * The settlement's own footprint, which nothing may be sited on. Radius 20 for the tower wall plus
 * margin, so plots never collide with the building or the terraces it grows.
 */
const KEEP_OUT_RADIUS = Number(process.env.HIVE_KEEPOUT ?? 26);

function withinKeepOut(cell: { x: number; z: number }): boolean {
  const dx = cell.x * CELL;
  const dz = cell.z * CELL;
  return Math.sqrt(dx * dx + dz * dz) < KEEP_OUT_RADIUS;
}

/** Grid cells ordered by ring distance from the origin: (0,0), then the ring around it, and so on. */
function* spiral(maxRing: number): Generator<{ x: number; z: number }> {
  yield { x: 0, z: 0 };
  for (let r = 1; r <= maxRing; r++) {
    for (let x = -r; x <= r; x++) {
      for (let z = -r; z <= r; z++) {
        if (Math.max(Math.abs(x), Math.abs(z)) === r) yield { x, z };
      }
    }
  }
}

export function newRegistry(origin: Vec3, bounds: Registry['bounds']): Registry {
  return { origin, plots: [], bounds };
}
