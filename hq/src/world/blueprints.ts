/**
 * What the settlement is made OF.
 *
 * A blueprint is a list of blocks relative to an origin -- nothing more. Keeping it as plain data
 * rather than code is what lets the same structure be costed before it is built, checked against
 * the plot registry before a single block is placed, and rendered on the map as a plan. A builder
 * that computes its own geometry can do none of those things, because nobody else can see what it
 * intends until it has already done it.
 *
 * Every block here must be something the fleet can actually obtain or make. A blueprint calling for
 * a material with no recipe and no source is a build that will queue, consume drones, and stall
 * halfway -- so the planner checks that before dispatching rather than discovering it in world.
 */

export interface BlueprintBlock {
  dx: number; dy: number; dz: number;
  item: string;
}

export interface Blueprint {
  name: string;
  /** Which plot purpose this belongs on. The registry sites it. */
  purpose: 'storage' | 'smelting' | 'crafting' | 'farm' | 'docks' | 'power' | 'mine_head';
  summary: string;
  /** Footprint, for siting and for refusing a plot that is too small. */
  size: { w: number; h: number; l: number };
  blocks: BlueprintBlock[];
}

const P = 'minecraft:oak_planks';
const CHEST = 'minecraft:chest';
const FURNACE = 'minecraft:furnace';

/** A 3x3 platform with a chest in the middle: somewhere for miners to drop off without commuting. */
const fieldCache: Blueprint = {
  name: 'field-cache',
  purpose: 'storage',
  summary: 'A planked pad with a chest, so a miner can unload at the face instead of flying home.',
  size: { w: 3, h: 2, l: 3 },
  blocks: [
    // Floor first. Order matters: a turtle places against an adjacent face, so the ground must
    // exist before anything can sit on it.
    ...[-1, 0, 1].flatMap((dx) => [-1, 0, 1].map((dz) => ({ dx, dy: 0, dz, item: P }))),
    { dx: 0, dy: 1, dz: 0, item: CHEST },
  ],
};

/** Two furnaces and a chest: the smallest thing that turns ore into ingots without a human. */
const smelterBank: Blueprint = {
  name: 'smelter-bank',
  purpose: 'smelting',
  summary: 'Two furnaces flanking a chest, on a planked base. StorageMan drives them once wired.',
  size: { w: 3, h: 2, l: 2 },
  blocks: [
    ...[-1, 0, 1].flatMap((dx) => [0, 1].map((dz) => ({ dx, dy: 0, dz, item: P }))),
    { dx: -1, dy: 1, dz: 0, item: FURNACE },
    { dx:  0, dy: 1, dz: 0, item: CHEST },
    { dx:  1, dy: 1, dz: 0, item: FURNACE },
  ],
};

/** A marker post. Cheap, and the first thing worth building to prove the whole chain works. */
const claimPost: Blueprint = {
  name: 'claim-post',
  purpose: 'docks',
  summary: 'A four-block post. Trivial to build and the cheapest possible end-to-end proof.',
  size: { w: 1, h: 4, l: 1 },
  blocks: [0, 1, 2, 3].map((dy) => ({ dx: 0, dy, dz: 0, item: P })),
};

/**
 * The hatchery: a disk drive holding a bootloader floppy, with a pad to stand a new machine on.
 *
 * A freshly crafted computer is blank -- no PowNet, no bootloader, no label -- and cannot be told
 * anything over rednet because it is running nothing that listens. A drive with a boot floppy is
 * the one mechanism that fixes that from inside the world: the ROM runs `disk/startup`, which
 * installs PowNet and the bootloader and reboots into the fleet.
 *
 * VERIFIED, AND WITH A LIMIT WORTH KNOWING: a COMPUTER placed beside the drive commissions itself.
 * A TURTLE placed beside the same drive does not -- turtles do not mount disk drives at all, only
 * computers do. So this hatches module servers, monitors and storage controllers, and a crafted
 * turtle still needs seeding from outside until a different mechanism is found.
 */
const hatchery: Blueprint = {
  name: 'hatchery',
  purpose: 'crafting',
  summary: 'A disk drive with a boot floppy: commissions a blank COMPUTER into a fleet module.',
  size: { w: 3, h: 2, l: 2 },
  blocks: [
    ...[-1, 0, 1].flatMap((dx) => [0, 1].map((dz) => ({ dx, dy: 0, dz, item: P }))),
    { dx: 0, dy: 1, dz: 0, item: 'computercraft:disk_drive' },
  ],
};

export const BLUEPRINTS: Blueprint[] = [claimPost, fieldCache, smelterBank, hatchery];

export function blueprint(name: string): Blueprint | undefined {
  return BLUEPRINTS.find((b) => b.name === name);
}

/** What it costs, in items. Costed BEFORE anything is dispatched. */
export function materials(bp: Blueprint): Record<string, number> {
  const out: Record<string, number> = {};
  for (const b of bp.blocks) out[b.item] = (out[b.item] ?? 0) + 1;
  return out;
}

/**
 * Bottom-up, and within a layer nearest-first.
 *
 * A turtle places a block against an adjacent face, so anything placed before the thing it rests on
 * simply fails -- and a half-built structure with holes in it is far more annoying to repair than
 * one that was never started. Sorting here rather than in the drone keeps the ordering rule
 * somewhere it can be read and tested.
 */
export function placementOrder(bp: Blueprint): BlueprintBlock[] {
  return [...bp.blocks].sort((a, b) =>
    a.dy - b.dy ||
    (Math.abs(a.dx) + Math.abs(a.dz)) - (Math.abs(b.dx) + Math.abs(b.dz)) ||
    a.dx - b.dx || a.dz - b.dz);
}

/** Bounds the structure will occupy, given an origin. Fed to the plot check. */
export function footprint(bp: Blueprint, origin: { x: number; y: number; z: number }) {
  const xs = bp.blocks.map((b) => origin.x + b.dx);
  const ys = bp.blocks.map((b) => origin.y + b.dy);
  const zs = bp.blocks.map((b) => origin.z + b.dz);
  return {
    min: { x: Math.min(...xs), y: Math.min(...ys), z: Math.min(...zs) },
    max: { x: Math.max(...xs), y: Math.max(...ys), z: Math.max(...zs) },
  };
}
