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
  radius: 15,
  sectors: 8,
  floorHeight: 6,
  atriumRadius: 4,
  walkRadius: 6,
  serviceDepth: 3,
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
  { index:  7, name: 'cap',      purpose: 'Mast base, wireless hub and GPS. No bays -- height is the point: modem range scales with altitude, and nine drones are out of contact right now.', gatedOn: [] },
];

/**
 * WHAT THE TOWER IS MADE OF, AND WHY IT IS NOT WOOD.
 *
 * The first costing used oak planks for the floor slabs and came to 480 planks PER FLOOR. That is
 * absurd on its own terms -- it is a hundred and twenty logs a floor, from a fleet with no forestry
 * -- and it is worse than absurd in a desert, where there are no trees at all. Planks were never a
 * decision, they were a placeholder that survived into a cost estimate.
 *
 * Cobblestone is the correct answer and it is not a compromise: it is the ONE material the fleet
 * already produces in bulk, as a by-product of every shaft it digs. A tower built of what mining
 * throws away costs nothing but the mining that was happening anyway.
 *
 * The palettes are a tier ladder, and the ladder is the same one the floors encode -- you build the
 * plinth out of what you have, and reface it later out of what the smelters upstairs have started
 * producing. Nothing here needs an item the fleet cannot obtain, which is the rule blueprints are
 * supposed to obey and the plank version quietly broke.
 *
 * pipe is deliberately nullable. A Create chute needs andesite alloy, a hopper needs five iron
 * apiece, and a dropper column needs redstone -- of which the fleet has found exactly none. So at
 * tier 0 there is no pipe: the core column is solid, the drones carry everything both ways, and the
 * chute becomes an upgrade dropped into a shaft that is already the right shape.
 */
export interface Palette {
  name: string;
  slab: string;
  wall: string;
  stair: string;
  window: string;
  shaft: string;
  barrel: string;
  /** null until the fleet can make one. The column is solid in the meantime. */
  pipe: string | null;
  /** Plain-language precondition, checked before this palette is offered. */
  needs: string;
}

const MC = 'minecraft:';

export const PALETTES: Record<string, Palette> = {
  // Tier 0. Everything here falls out of a mining shaft. Glass needs sand, which a desert has more
  // of than anywhere else -- the one way the current site is an advantage.
  cobble: {
    name: 'cobble',
    slab: MC + 'cobblestone',
    wall: MC + 'cobblestone',
    stair: MC + 'cobblestone_stairs',
    window: MC + 'glass',
    shaft: MC + 'cobblestone_wall',
    barrel: MC + 'barrel',
    pipe: null,
    needs: 'nothing -- mining produces all of it',
  },
  // Tier 1. Same shapes, smelted. Cobble -> stone -> stone bricks, so the only new input is furnace
  // time and coal, and the fleet has located 576 coal.
  brick: {
    name: 'brick',
    slab: MC + 'stone_bricks',
    wall: MC + 'stone_bricks',
    stair: MC + 'stone_brick_stairs',
    window: MC + 'glass_pane',
    shaft: MC + 'stone_brick_wall',
    barrel: MC + 'barrel',
    pipe: null,
    needs: 'a furnace bank and coal',
  },
  // Tier 2. Once Create exists the column becomes a real pipe and the facing work starts paying off.
  create: {
    name: 'create',
    slab: MC + 'stone_bricks',
    wall: MC + 'stone_bricks',
    stair: MC + 'stone_brick_stairs',
    window: MC + 'glass_pane',
    shaft: MC + 'stone_brick_wall',
    barrel: MC + 'barrel',
    pipe: 'create:chute',
    needs: 'andesite alloy, for the chute',
  },
};

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

/**
 * The cells a given bay owns: a fixed-depth band hugging the inside of the service wall.
 *
 * BAYS ARE ALWAYS AGAINST THE WALL, AND NOT FOR TIDINESS. The chutes and power shafts run up the
 * wall cavity, so a bay that is not touching it cannot be piped to. Fixed depth is what keeps every
 * bay the same size as the tower tapers -- and one bay being the same as every other is the entire
 * reason this building is round.
 *
 * Whatever is left between the gallery and the bays is open concourse: wide at the base, nothing at
 * the top. That is where the ground floor gets its lobby, and it costs nothing to leave empty.
 */
export const BAY_DEPTH = 5;

export function bayCells(spec: TowerSpec, sector: number): Array<{ dx: number; dz: number }> {
  const outer = spec.radius - spec.serviceDepth - 1;
  const inner = Math.max(spec.walkRadius, outer - BAY_DEPTH);
  return discCells(outer)
    .filter((c) => dist(c.dx, c.dz) > inner)
    .filter((c) => sectorOf(c.dx, c.dz, spec.sectors) === sector);
}

/**
 * THE TAPER.
 *
 * A band is a run of levels sharing one radius. Stepping in as the tower rises is not decoration:
 * throughput falls with height. A tonne of ore arrives at the bottom and a handful of processors
 * leaves at the top, so the bottom needs many bays and the top needs few.
 *
 * Sector count falls WITH the radius, chosen so bay width stays near constant -- circumference over
 * sectors is about 10 blocks in every band. Keeping the count fixed while shrinking the radius would
 * squeeze the bays until modules stopped fitting, which is the failure the cylinder exists to avoid.
 *
 * The atrium, the gallery and the service cavity never taper. Drones need the same shaft at every
 * height, the stair has to stay continuous, and the chutes have to run the full rise.
 *
 * Each step-in leaves a ring of the band below exposed. Those are terraces, and they come free.
 */
export interface TowerBand {
  name: string;
  /** Inclusive level range this band covers. */
  from: number;
  to: number;
  radius: number;
  sectors: number;
}

/**
 * r=15 IS THE FLOOR, AND IT IS ARITHMETIC RATHER THAN TASTE.
 *
 * A bay needs the atrium (4) plus both gallery lanes (2) plus its own depth (5) plus the service
 * cavity (3) plus the wall. That is fifteen. Taper below it and the bays are the first thing
 * squeezed -- a first attempt at r=11 produced 15-cell bays against 41 at the base, which is exactly
 * the "every module needs a variant per band" failure the round plan exists to prevent.
 *
 * The service cavity is THREE deep, not two: two skins with a two-block gap between them, room for a
 * chute AND a power shaft (or a wider item lane) to run the full rise without fouling each other.
 * Widening it stepped every working band out by one to keep bay depth constant.
 *
 * So the working floors step 21 -> 18 -> 15 and stop. The cap above them is genuinely narrow because
 * it holds no bays at all: it is the mast base and an observation deck, and the ring of roof each
 * step-in leaves exposed below it is a terrace.
 */
export const BANDS: TowerBand[] = [
  { name: 'plinth', from: -3, to: -1, radius: 21, sectors: 12 },
  { name: 'base',   from:  0, to:  1, radius: 21, sectors: 12 },
  { name: 'mid',    from:  2, to:  3, radius: 18, sectors: 10 },
  { name: 'upper',  from:  4, to:  6, radius: 15, sectors:  8 },
  { name: 'cap',    from:  7, to:  7, radius: 12, sectors:  0 },
];

export function bandFor(level: number): TowerBand {
  return BANDS.find((b) => level >= b.from && level <= b.to) ?? BANDS[BANDS.length - 1]!;
}

/**
 * The last level the design describes.
 *
 * bandFor falls back to the topmost band for anything above it, so towerFloor(99) cheerfully
 * returns a cap floor's worth of blocks and NOTHING in the geometry says "that is the top". The
 * supply loop advances a level whenever the current one stops producing, so without this it would
 * keep ordering cap floors into the sky for as long as the settlement had bricks -- an autonomous
 * loop needs a finish line as much as it needs a start.
 */
export const TOWER_TOP = Math.max(...BANDS.map((b) => b.to));

/** The spec to build a given level with: the shared shape, resized to that level's band. */
export function specForLevel(level: number, base: TowerSpec = TOWER): TowerSpec {
  const b = bandFor(level);
  return { ...base, radius: b.radius, sectors: b.sectors };
}

/**
 * A vertical cross-section, so the taper can be looked at before it is built.
 *
 * The plan view checks one floor. It cannot show that the stair stays continuous through a step-in,
 * or that a band change does not strand a bay over open air -- which is exactly the kind of mistake
 * that is obvious in a picture and invisible in a list of coordinates.
 */
export function section(base: TowerSpec = TOWER): string {
  const widest = Math.max(...BANDS.map((b) => b.radius));
  const levels = [...BANDS].sort((a, b) => b.to - a.to);
  const rows: string[] = [];
  for (const band of levels) {
    for (let lv = band.to; lv >= band.from; lv--) {
      const spec = specForLevel(lv, base);
      const lvl = LEVELS.find((l) => l.index === lv);
      for (let dy = base.floorHeight - 1; dy >= 0; dy--) {
        let row = '';
        for (let dx = -widest; dx <= widest; dx++) {
          const r = Math.abs(dx);
          if (r > spec.radius) row += ' ';
          else if (r > spec.radius - spec.serviceDepth - 1) row += dy === 0 ? '=' : '=';
          else if (r <= spec.atriumRadius) row += dy === 0 ? ' ' : ' ';
          else if (r <= spec.walkRadius) row += dy === 0 ? '.' : ' ';
          else row += dy === 0 ? '-' : ' ';
        }
        rows.push(row + (dy === 0 ? `  ${lv >= 0 ? '+' : ''}${lv} ${lvl?.name ?? ''}` : ''));
      }
    }
  }
  return rows.join('\n');
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
  mats: Palette,
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
      // The notch is the doorway: no wall across it at any height, on any floor.
      if (inNotch(c.dx, c.dz)) continue;
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
      if (inNotch(c.dx, c.dz)) continue;
      out.push({ dx: c.dx, dy, dz: c.dz, item: mats.wall });
    }
  }

  out.push(...spiralSteps(spec, floorIndex, mats.stair));
  // The one thing standing inside the atrium. Everything else in there stays empty on purpose.
  // Only the ground floor gets the draw point; every other level is unbroken pipe.
  out.push(...coreColumn(spec, { pipe: mats.pipe, barrel: mats.barrel, solid: mats.wall },
                         { drawPoint: floorIndex === 0 }));
  return out;
}

/**
 * THE FLIGHT NOTCH.
 *
 * Drones need to get in at the level they are going to. Entering only at the roof and dropping down
 * the atrium works, but climbing is the expensive direction -- a drone bringing ore to level 2 would
 * burn the fuel to reach y+70 first and then give the height straight back.
 *
 * A separate arch on every floor is the obvious answer and the wrong one. Bays hug the outer wall at
 * a fixed depth, so any opening has to cut clean through the bay ring, and that sector can then hold
 * no module. Twelve arches is twelve lost bays scattered around the building, and at the crown --
 * eight bays -- it is an eighth of the tower's working space gone to doorways.
 *
 * One notch instead: a single vertical channel through the bay ring, the full height of the tower,
 * on one bearing. It costs ONE bay per floor rather than one per floor per opening, it gives every
 * level its own entry, and because it is defined by ANGLE rather than by sector index it stays
 * aligned through bands that have twelve, ten and eight sectors.
 *
 * It also gives the building a front. A plain drum has no orientation and nothing to read at a
 * glance; a recess running the full height tells you which way the tower faces from a distance, and
 * lines the terraces up underneath it.
 */
export const NOTCH_BEARING = 0;              // due north
export const NOTCH_HALF_ARC = Math.PI / 14;  // about 13 degrees each side: two blocks wide at r=14

/** Is this cell inside the flight notch -- open air rather than wall, bay or concourse? */
export function inNotch(dx: number, dz: number): boolean {
  const a = Math.atan2(dx, -dz);
  let d = a - NOTCH_BEARING;
  while (d > Math.PI) d -= Math.PI * 2;
  while (d < -Math.PI) d += Math.PI * 2;
  return Math.abs(d) <= NOTCH_HALF_ARC;
}

/** A bay is unusable if the notch passes through it, so it is never offered to the allocator. */
export function bayIsFlightPath(spec: TowerSpec, sector: number): boolean {
  return bayCells(spec, sector).some((c) => inNotch(c.dx, c.dz));
}

/**
 * The terrace left exposed where the tower steps in.
 *
 * Free geometry -- the roof of the wider band below is already there -- so this is a floor surface
 * and a parapet, nothing more. Where a terrace meets the notch it widens into the landing deck for
 * that band: the one place a drone can set down outside the building, which matters for loads too
 * awkward to hand through an arch, and for a drone that needs to stop without entering.
 */
export function terraceRing(
  lower: TowerSpec,
  upper: TowerSpec,
  mats: { deck: string; parapet: string },
): BlueprintBlock[] {
  const out: BlueprintBlock[] = [];
  if (upper.radius >= lower.radius) return out;
  for (const c of discCells(lower.radius)) {
    const d = Math.sqrt(c.dx * c.dx + c.dz * c.dz);
    if (d <= upper.radius) continue;
    out.push({ dx: c.dx, dy: 0, dz: c.dz, item: mats.deck });
  }
  // Parapet on the outer edge only, and not across the notch -- a rail there would be a fence
  // across the doorway.
  for (const c of ringCells(lower.radius)) {
    if (inNotch(c.dx, c.dz)) continue;
    out.push({ dx: c.dx, dy: 1, dz: c.dz, item: mats.parapet });
  }
  return out;
}

/**
 * THE CORE COLUMN AND ITS FOUR DOCKS.
 *
 * DockingMan already lays docks out in a plus: GetXYZFromSlot puts slot % 4 at pos +/- 1 in x or z,
 * and GetSlotHeading turns each drone to face INWARD at the column. So all four docked drones are
 * face-adjacent to the same block, which is the point of the pattern -- one inventory feeds four
 * drones, and the drone's own refuel routine already reaches it: it tries suckDown, then suckUp,
 * then suck, and the last of those is the column.
 *
 * So the column has to BE an inventory at every dock level, not decoration. A barrel rather than a
 * chest: chests need a free block above to open and this one has a column sitting on it.
 *
 * The column is also the only structure inside the atrium. Everything else in there is deliberately
 * empty so drones can fly, and the plus is what lets docking cost a 3x3 footprint in the middle of a
 * nine-radius open shaft rather than a ring of berths around the edge.
 *
 * Stocking it is a loader's job today -- fly coal to the barrel. "Fuel from the centre column" ends
 * up automatic once the wall chutes exist and can push up into it, which is an upgrade to this, not
 * a change of shape.
 */
export interface DockSlot {
  dx: number; dz: number; dy: number;
  /** Which way the drone faces once docked: inward, at the column. */
  heading: Heading;
}

/** The four arms of the plus at a given height, in DockingMan's slot order. */
export function dockSlots(dy: number): DockSlot[] {
  return [
    { dx: 0, dz: -1, dy, heading: 'south' },   // north arm, looking back at the column
    { dx: -1, dz: 0, dy, heading: 'east' },
    { dx: 0, dz: 1, dy, heading: 'north' },
    { dx: 1, dz: 0, dy, heading: 'west' },
  ];
}

/**
 * The column itself: ONE PIPE, TOP TO BOTTOM, WITH NO STORAGE ON THE WAY DOWN.
 *
 * An earlier version put a barrel at every floor's dock level so each floor had its own buffer.
 * That is ten inventories to keep stocked, ten places for items to sit and be forgotten, and ten
 * things to reason about when something goes missing. A single unbroken chute run does the same job:
 * anything a floor finishes goes into the pipe and lands in storage at the bottom.
 *
 * SO THE PIPE IS THE DOWN LINE AND THE DRONES ARE THE UP LINE.
 *
 * That split falls out of the physics rather than being imposed. Down is gravity and costs nothing
 * and works today. Up needs an encased fan, which needs rotational power, which needs andesite alloy
 * the fleet has not made -- while drones already fly and already carry. When the fan does get built
 * it is an upgrade to this exact column, not a redesign.
 *
 * One draw point, at ground level, rather than one per floor: a drone needing fuel flies down the
 * atrium, which is a few seconds through open air, and the ground floor is where it was going anyway.
 * A barrel rather than a chest -- a chest needs a free block above to open, and this one has a pipe
 * sitting on it.
 *
 * One docking tower is registered per floor, not one tall tower for the building. DockingMan derives
 * a slot's height as floor(slot / 4), so a single tall tower would put docks at every y including
 * those filled by floor slabs. A tower per floor puts all four slots at the one open height.
 */
export function coreColumn(
  spec: TowerSpec,
  mats: { pipe: string | null; barrel: string; solid: string },
  opts: { drawPoint?: boolean; dockDy?: number } = {},
): BlueprintBlock[] {
  const dockDy = opts.dockDy ?? 1;
  const out: BlueprintBlock[] = [];
  for (let dy = 0; dy < spec.floorHeight; dy++) {
    const isDraw = opts.drawPoint === true && dy === dockDy;
    // No pipe yet: a solid column, still the right shape for a chute to be dropped into later.
    out.push({ dx: 0, dy, dz: 0, item: isDraw ? mats.barrel : (mats.pipe ?? mats.solid) });
  }
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
