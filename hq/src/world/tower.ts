/**
 * THE TOWER.
 *
 * Everything the settlement makes eventually happens inside one building, and the building has a
 * shape that means something: raw material enters at the bottom, and each floor above refines what
 * the floor below produced. Storage is underground, ingest is at ground level, and the higher a
 * process sits the more advanced it is. Walk up the stairs and you walk up the tech tree.
 *
 * WHY A CYLINDER, AND NOT BECAUSE IT LOOKS NICE.
 *
 * Every bay is the same distance from the centre, so the run from the item spine to a bay is
 * identical for all of them -- which means ONE bay blueprint fits every slot on every floor. A
 * square building makes corner bays a different shape from edge bays, and then every module needs a
 * corner variant and an edge variant, forever.
 *
 * WHY THIS IS GENERATED AND NOT WRITTEN OUT.
 *
 * A blueprint used to be a hand-typed list of blocks, which is right for a five-block field cache
 * and impossible here: one floor of this tower is about 1,150 blocks and twelve floors is fourteen
 * thousand. Radius, sector count and floor height are inputs, so the tower can be built small now
 * and the same code builds it large later.
 */

import type { BlueprintBlock } from './blueprints.js';

export type Heading = 'north' | 'west' | 'south' | 'east';

export interface TowerSpec {
  /** Outer wall radius. The wall itself sits on this ring. */
  radius: number;
  /** Module bays per floor. Also the number of wall window slits. */
  sectors: number;
  /** Total rise per floor: floor slab, clear headroom, ceiling. */
  floorHeight: number;
  /** r <= atriumRadius is the open drone shaft: air circulation, bedrock to roof. */
  atriumRadius: number;
  /** atriumRadius < r <= walkRadius is the gallery: walkway and staircase, overlooking the atrium. */
  walkRadius: number;
  /** The outer skin is a cavity `serviceDepth` thick, carrying chutes and power shafts vertically. */
  serviceDepth: number;
}

/**
 * THREE CIRCULATION SYSTEMS, ONE PER ZONE.
 *
 * The centre is air, the gallery is foot, the wall is gravity. Each kind of traffic gets its own
 * space and they never cross, which is why the building works rather than merely looking like a
 * building.
 *
 *   r 0-4    atrium      open shaft, bedrock to roof. Drones fly it; docks line it at every floor.
 *   r 5-6    gallery     two lanes: stair on the inner, walking on the outer. Balconied over the
 *                        atrium. A one-lane gallery does not work -- the staircase occupies the
 *                        inner ring, so with a single lane the stairs ARE the walkway and nobody
 *                        can get past them to a bay.
 *   r 7-11   bays        8 module bays per floor, ~9 wide x 5 deep.
 *   r 13-14  service     double skin with a cavity: item chutes and power shafts run up inside it.
 *
 * PUTTING THE DRONES DOWN THE MIDDLE IS WHAT MAKES THIS BUILDABLE NOW.
 *
 * A central chute column would have needed an encased fan to lift anything, a fan needs rotational
 * power, and power needs andesite alloy the fleet has not made yet -- so the tower could not have
 * moved a single item upward until several other things existed first. Drones already fly and
 * already carry. They become the vertical transport, the chutes in the walls handle the short
 * gravity-fed hops between a bay and its floor buffer, and the powered spine becomes an upgrade
 * rather than a precondition.
 *
 * It also solves a problem the fleet has right now: drones climb to y=110 to cross terrain because
 * they cannot path through it. An open shaft down the middle of the building is a protected highway
 * to every floor.
 */
export const TOWER: TowerSpec = {
  radius: 14,
  sectors: 8,
  floorHeight: 6,
  atriumRadius: 4,
  walkRadius: 6,
  serviceDepth: 2,
};

/**
 * What each level is FOR.
 *
 * The order is the whole point: a floor may only host a process whose inputs the floors below it
 * already produce. That is what makes the building legible from outside -- you can tell what the
 * settlement can do by counting its floors.
 *
 * Level -3 is a mine head rather than more storage. The fleet has surveyed 375,000 cells and found
 * zero redstone, zero gold, zero diamond and zero quartz, because the lowest point it has ever
 * reached is y=-2 and all four of those spawn below y=16. Everything from level 5 upward is
 * unreachable until something digs down, so the shaft is not a basement feature, it is the
 * precondition for the top half of the building.
 */
export interface Level {
  index: number;
  name: string;
  purpose: string;
  /** Items whose production unlocks this level. Empty means "buildable now". */
  gatedOn: string[];
}

export const LEVELS: Level[] = [
  { index: -3, name: 'shaft',    purpose: 'Mine head. A shaft to y=-50, where redstone, gold and diamond actually are.', gatedOn: [] },
  { index: -2, name: 'bulk',     purpose: 'Bulk storage: vaults for ore and stone awaiting processing.',                 gatedOn: [] },
  { index: -1, name: 'buffer',   purpose: 'Sorted storage, one item class per bay, feeding the spine upward.',           gatedOn: [] },
  { index:  0, name: 'ingest',   purpose: 'Drone docks, unload, and sorting into the spine. Ground level, the door.',    gatedOn: [] },
  { index:  1, name: 'wash',     purpose: 'Crushing and washing: ore to nuggets, gravel to flint.',                      gatedOn: ['andesite_alloy'] },
  { index:  2, name: 'smelt',    purpose: 'Furnace bank, later blast furnaces. Ore and dust to ingots.',                 gatedOn: [] },
  { index:  3, name: 'alloy',    purpose: 'Mixing and alloying: brass from copper and zinc, andesite alloy.',            gatedOn: ['andesite_alloy'] },
  { index:  4, name: 'press',    purpose: 'Pressing and shaping: sheets and rods.',                                      gatedOn: ['brass_ingot'] },
  { index:  5, name: 'assemble', purpose: 'Mechanical crafters. Where components become machines.',                      gatedOn: ['brass_ingot'] },
  { index:  6, name: 'logic',    purpose: 'AE2: digital storage and autocrafting. The top of the tree, so the top floor.', gatedOn: ['redstone', 'certus_quartz'] },
];

const dist = (dx: number, dz: number) => Math.sqrt(dx * dx + dz * dz);

/** Cells whose distance from the centre rounds to exactly r: a one-block-thick circle. */
export function ringCells(r: number): Array<{ dx: number; dz: number }> {
  const out: Array<{ dx: number; dz: number }> = [];
  for (let dx = -r; dx <= r; dx++) {
    for (let dz = -r; dz <= r; dz++) {
      if (Math.round(dist(dx, dz)) === r) out.push({ dx, dz });
    }
  }
  return out;
}

/** Every cell strictly inside radius r. */
export function discCells(r: number): Array<{ dx: number; dz: number }> {
  const out: Array<{ dx: number; dz: number }> = [];
  for (let dx = -r; dx <= r; dx++) {
    for (let dz = -r; dz <= r; dz++) {
      if (dist(dx, dz) <= r) out.push({ dx, dz });
    }
  }
  return out;
}

/**
 * Which bay a cell belongs to, 0..sectors-1, counting anticlockwise from due north.
 *
 * This is the tower's address system. A module is not sited "somewhere on a plot", it is assigned
 * to (level, sector) -- which is what makes allocation a lookup instead of a search, and what lets
 * the spine know where to tap.
 */
export function sectorOf(dx: number, dz: number, sectors: number): number {
  const a = Math.atan2(dx, -dz);                 // 0 = north, growing clockwise
  const norm = (a + Math.PI * 2) % (Math.PI * 2);
  return Math.floor((norm / (Math.PI * 2)) * sectors) % sectors;
}

/** The cells a given bay owns on a floor: the annulus between the walkway and the wall. */
export function bayCells(spec: TowerSpec, sector: number): Array<{ dx: number; dz: number }> {
  return discCells(spec.radius - spec.serviceDepth - 1)
    .filter((c) => dist(c.dx, c.dz) > spec.walkRadius)
    .filter((c) => sectorOf(c.dx, c.dz, spec.sectors) === sector);
}

/**
 * The staircase.
 *
 * One block of rise per step, spiralling around the spine at the inner edge of the walkway. A
 * fourteen-radius tower has about nineteen cells on that ring, so six steps -- one floor -- is
 * roughly a third of a turn, and twelve floors is about four full turns. That is a real staircase a
 * person can walk up, which is the point: the building has to make sense to stand in, not just to
 * pathfind through.
 *
 * Stairs are the reason the builder had to learn to turn before placing. A stair block takes its
 * facing from whoever placed it, so without a heading a staircase is a pile of steps facing at
 * random.
 */
export function spiralSteps(
  spec: TowerSpec,
  floorIndex: number,
  item: string,
): BlueprintBlock[] {
  const r = spec.atriumRadius + 1;
  const ring = ringCells(r).sort(
    (a, b) => Math.atan2(a.dx, -a.dz) - Math.atan2(b.dx, -b.dz),
  );
  const out: BlueprintBlock[] = [];
  // Continue where the floor below stopped, so the spiral is unbroken through the whole tower.
  const startAt = (floorIndex * spec.floorHeight) % ring.length;
  for (let step = 0; step < spec.floorHeight; step++) {
    const cell = ring[(startAt + step) % ring.length];
    if (!cell) continue;
    // Face along the direction of travel, so the step rises the way the walker is going.
    const next = ring[(startAt + step + 1) % ring.length] ?? cell;
    out.push({
      dx: cell.dx,
      dy: step,
      dz: cell.dz,
      item,
      heading: headingFrom(cell, next),
    });
  }
  return out;
}

/** The compass direction from one cell toward another, for orienting stairs and machines. */
export function headingFrom(
  from: { dx: number; dz: number },
  to: { dx: number; dz: number },
): Heading {
  const ddx = to.dx - from.dx;
  const ddz = to.dz - from.dz;
  if (Math.abs(ddx) >= Math.abs(ddz)) return ddx >= 0 ? 'east' : 'west';
  return ddz >= 0 ? 'south' : 'north';
}

/**
 * One complete floor: slab, wall, windows, spine shaft and staircase.
 *
 * Deliberately NOT including the bay interiors. A floor is structure; what goes in the bays is
 * decided later by what the settlement is short of, and is dispatched as its own build against the
 * bay address. Building the shell and the modules as one task would mean the whole floor has to be
 * affordable at once, and that a change of plan wastes everything already placed.
 *
 * Emitted bottom-up. A turtle places against an adjacent face, so the order is not cosmetic: the
 * slab has to exist before anything can stand on it.
 */
export function towerFloor(
  spec: TowerSpec,
  floorIndex: number,
  mats: { slab: string; wall: string; stair: string; window: string; shaft: string },
): BlueprintBlock[] {
  const out: BlueprintBlock[] = [];
  const y0 = 0;

  // Slab: everything inside the wall, minus the atrium, which is open all the way up.
  for (const c of discCells(spec.radius - 1)) {
    if (dist(c.dx, c.dz) <= spec.atriumRadius) continue;
    out.push({ dx: c.dx, dy: y0, dz: c.dz, item: mats.slab });
  }

  // Wall, with a window slit per sector at eye height.
  const wall = ringCells(spec.radius);
  const windowCells = new Set<string>();
  for (let sec = 0; sec < spec.sectors; sec++) {
    const mid = ((sec + 0.5) / spec.sectors) * Math.PI * 2;
    const wx = Math.round(Math.sin(mid) * spec.radius);
    const wz = Math.round(-Math.cos(mid) * spec.radius);
    const near = wall.reduce((best, c) =>
      (c.dx - wx) ** 2 + (c.dz - wz) ** 2 < (best.dx - wx) ** 2 + (best.dz - wz) ** 2 ? c : best,
      wall[0]!);
    windowCells.add(`${near.dx}:${near.dz}`);
  }
  for (let dy = y0; dy < spec.floorHeight; dy++) {
    for (const c of wall) {
      // One slit per bay, at eye height, on the cell nearest that sector's mid-angle. Computed
      // against the ring rather than by an angular tolerance: a fixed tolerance produces a
      // different number of windows at every radius, and this produced 81 of them for 8 bays.
      const isWindow = dy === 2 && windowCells.has(`${c.dx}:${c.dz}`);
      out.push({ dx: c.dx, dy, dz: c.dz, item: isWindow ? mats.window : mats.wall });
    }
  }

  // The atrium's parapet: one course at the gallery edge so nothing walks off the balcony, and the
  // shaft above it left open for drones. A wall here would defeat the entire point of the atrium.
  for (const c of ringCells(spec.atriumRadius)) {
    out.push({ dx: c.dx, dy: y0 + 1, dz: c.dz, item: mats.shaft });
  }

  // The inner skin of the service wall. The gap between it and the outer wall at spec.radius is the
  // cavity the chutes and power shafts run up -- left hollow here and fitted out per floor, because
  // what a floor needs piped to it depends on what ends up in its bays.
  for (let dy = y0; dy < spec.floorHeight; dy++) {
    for (const c of ringCells(spec.radius - spec.serviceDepth)) {
      out.push({ dx: c.dx, dy, dz: c.dz, item: mats.wall });
    }
  }

  out.push(...spiralSteps(spec, floorIndex, mats.stair));
  return out;
}

/** What a floor costs, so it can be refused before a drone is sent rather than halfway through. */
export function floorCost(blocks: BlueprintBlock[]): Record<string, number> {
  const need: Record<string, number> = {};
  for (const b of blocks) need[b.item] = (need[b.item] ?? 0) + 1;
  return need;
}

/**
 * An ASCII cross-section, so the geometry can be checked before fourteen thousand blocks are placed.
 *
 * Cheap to run and the only way to see the shape without building it. A design nobody has looked at
 * is a design nobody has checked.
 */
export function plan(spec: TowerSpec = TOWER): string {
  const rows: string[] = [];
  for (let dz = -spec.radius; dz <= spec.radius; dz++) {
    let row = '';
    for (let dx = -spec.radius; dx <= spec.radius; dx++) {
      const d = dist(dx, dz);
      if (Math.round(d) === spec.radius) row += '#';
      else if (d > spec.radius) row += ' ';
      else if (d <= spec.atriumRadius) row += ' ';                       // open shaft
      else if (Math.round(d) === spec.atriumRadius) row += ':';          // parapet
      else if (d <= spec.walkRadius) row += '.';                         // gallery
      else if (d > spec.radius - spec.serviceDepth - 0.5) row += '=';    // service cavity
      else row += String(sectorOf(dx, dz, spec.sectors));
    }
    rows.push(row);
  }
  return rows.join('\n');
}
