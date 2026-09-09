/**
 * BAY INTERIORS — the missing half of the generative building.
 *
 * towerFloor() emits the SHELL: slab, wall, atrium, stair, spine. It deliberately leaves the bays
 * empty, because for a long time what went in a bay was decided by hand and cheated in over rcon.
 * This module is the other half: given a bay's geometry and what the floor is FOR, it generates the
 * bay's interior -- chests, machines, and the wired network that joins them -- as ordinary
 * BlueprintBlocks a drone can build, plus the metadata the build's completion hook needs to register
 * what it placed (deposit points, factory input/output chests, dock slots).
 *
 * ONE ITEM PER CHEST IS A CORRECTNESS PROPERTY, NOT TIDINESS.
 *
 * turtle.suck() takes a chest's first occupied slot and cannot choose. A chest holding nineteen kinds
 * hands a drone whatever is in front, so collecting a full load of one thing meant surfacing it past
 * everything ahead of it -- the "911 stone_bricks in storage, pulls 1 per trip" failure that stalled
 * building for a whole session. A chest that holds exactly ONE item class is deterministic: suck it
 * and you get a full load of that item, every time. Sorted storage is what makes the fetch reliable,
 * so the basements are one-item-per-chest by construction.
 *
 * THE MODEM IS WHY A CHEST COUNTS AT ALL.
 *
 * StorageMan finds inventories by NETWORK name, not by adjacency -- pushItems needs both ends on a
 * wired modem joined by cable. A bare chest is invisible to storage. So every chest here is capped
 * with a wired_modem_full and the caps are joined into one run. A drone can PLACE a modem but cannot
 * ACTIVATE it (peripheral=true needs a player/rcon in CC:Tweaked), so a placed bay is inert until a
 * commissioning step toggles the modems -- see commissionBay(). Until the fleet can mine the redstone
 * a modem needs AND commission it itself, that step is a bridge, the way cheated fuel and bricks are.
 */

import type { BlueprintBlock } from './blueprints.js';
import type { TowerSpec } from './tower.js';
import { bayCells, discCells, BAY_DEPTH, LEVELS } from './tower.js';

const CHEST = 'minecraft:chest';
const MODEM = 'computercraft:wired_modem_full';
const FURNACE = 'minecraft:furnace';
// Between the modems the wire is plain networking cable: a full modem is only needed where a
// peripheral attaches (the user, 2026-09-08: "do we need to use modems as wires all the time?").
const CABLE = 'computercraft:cable';

/** A relative cell inside a bay, addressed from the floor origin like every BlueprintBlock. */
export interface Cell { dx: number; dy: number; dz: number; }

export interface BayInterior {
  /** Blocks to build, in no particular order -- placementOrder() sorts them bottom-up before dispatch. */
  blocks: BlueprintBlock[];
  /** Chests that hold ONE item class each. The completion hook registers these as deposit points. */
  chests: Cell[];
  /** Machines placed (furnaces etc.), for the completion hook to wire to StorageMan. */
  machines: Cell[];
  /** Wired modems placed, for commissionBay() to activate. */
  modems: Cell[];
}

/**
 * The slab sits at dy=0 (towerFloor placed it). A chest rests ON the slab at dy=1, and its modem
 * caps it at dy=2. Adjacent modems on the same course touch and so form one network without separate
 * cable; the bay footprint is a contiguous arc, so a solid modem course over a solid chest course is
 * a single connected run. Drones do not suck these -- StorageMan routes through the modems -- so a
 * modem on top does not block anything.
 */
// THE MODEM GOES UNDER THE CHEST, IN THE SLAB LAYER. A turtle loads and unloads a chest from ABOVE
// (suckDown/dropDown), so nothing may sit on top of it -- the first bay was built with modems capping
// the chests and no drone could ever have used it (the user, 2026-09-08: "the chests must be connected
// from their bottom, they can't have stuff on top"). The modem replaces the floor slab cell; full modems
// touching each other form the network, so the wired run travels inside the floor.
const CHEST_DY = 1;
const MODEM_DY = 0;

/**
 * A basement bay as sorted storage: one single-item chest on every footprint cell, each capped with
 * a modem. Capacity is the cell count; StorageMan assigns one item class per chest as items arrive.
 */
export function storageBayInterior(spec: TowerSpec, sector: number): BayInterior {
  // CHECKERBOARD. Two chests that touch merge into one double chest, and a third beside them starts
  // another pair -- so a packed row is not "one item per chest", it is a few 54-slot boxes StorageMan
  // cannot tell apart from the plan ("max 2 next to each other" -- the user, 2026-09-08). Every other
  // cell holds a chest; the cells between stay open floor to stand on. Modems run under all of them.
  const floor = bayCells(spec, sector);
  const blocks: BlueprintBlock[] = [];
  const chests: Cell[] = [];
  const modems: Cell[] = [];
  for (const c of floor) {
    if ((c.dx + c.dz) % 2 !== 0) {
      blocks.push({ dx: c.dx, dy: MODEM_DY, dz: c.dz, item: CABLE });   // wire between the chest modems
      continue;
    }
    const chest: Cell = { dx: c.dx, dy: CHEST_DY, dz: c.dz };
    const modem: Cell = { dx: c.dx, dy: MODEM_DY, dz: c.dz };
    blocks.push({ ...chest, item: CHEST });
    blocks.push({ ...modem, item: MODEM });
    chests.push(chest);
    modems.push(modem);
  }
  return { blocks, chests, machines: [], modems };
}

/**
 * A factory bay: a bank of furnaces down the outer row with an input chest and an output chest, all
 * on the network so StorageMan can feed ore in and pull ingots out once wired. Furnaces face inward
 * (heading toward the atrium) so the drone that places them orients them consistently; StorageMan
 * drives them over the network regardless of facing, but a consistent build reads as a machine.
 *
 * This is the smelter; other station types (crusher, mixer, press) slot in here as the recipe
 * `Station` vocabulary grows -- the shape is the same: machines on the outer row, a buffer chest at
 * each end, capped with modems.
 */
export function factoryBayInterior(spec: TowerSpec, sector: number, machine = FURNACE): BayInterior {
  const floor = bayCells(spec, sector);
  if (floor.length === 0) return { blocks: [], chests: [], machines: [], modems: [] };
  // Sort the footprint by angle so "first" and "last" are the two ends of the arc: input at one end,
  // output at the other, machines between them.
  const row = [...floor].sort((a, b) => Math.atan2(a.dz, a.dx) - Math.atan2(b.dz, b.dx));
  const blocks: BlueprintBlock[] = [];
  const chests: Cell[] = [];
  const machines: Cell[] = [];
  const modems: Cell[] = [];
  row.forEach((c, i) => {
    const isEnd = i === 0 || i === row.length - 1;
    const item = isEnd ? CHEST : machine;
    blocks.push({ dx: c.dx, dy: CHEST_DY, dz: c.dz, item });
    blocks.push({ dx: c.dx, dy: MODEM_DY, dz: c.dz, item: MODEM });
    modems.push({ dx: c.dx, dy: MODEM_DY, dz: c.dz });
    if (isEnd) chests.push({ dx: c.dx, dy: CHEST_DY, dz: c.dz });
    else {
      machines.push({ dx: c.dx, dy: CHEST_DY, dz: c.dz });
      // A FURNACE HAS FACES. Seen from below it exposes fuel and output (size 2); its INPUT face is
      // the top. With only the modem underneath, StorageMan's service loaded coal into 35 furnaces
      // and never a single ore (2026-09-08). Chests keep nothing on top (the user); furnaces get a
      // second modem above, which the service reads as the input face (size 1).
      blocks.push({ dx: c.dx, dy: CHEST_DY + 1, dz: c.dz, item: MODEM });
      modems.push({ dx: c.dx, dy: CHEST_DY + 1, dz: c.dz });
    }
  });
  return { blocks, chests, machines, modems };
}

/**
 * WHAT A BAY IS FOR, DECIDED BY THE FLOOR IT IS ON.
 *
 * This is the generative brain: `LEVELS` already says what each floor does, so the bay's contents
 * follow from its level rather than from a human choosing per bay. The storage floors get sorted
 * single-item racks; the smelt floor gets a furnace bank; the mine head and the cap hold no bays;
 * and the floors whose machines the recipe vocabulary cannot place yet (wash/alloy/press/assemble/
 * logic -- crushers, mixers, presses, mechanical crafters, AE2) are left as shells, honestly marked
 * 'pending', to be outfitted when their Station type and Create placement exist. Nothing here guesses
 * a machine that cannot be built.
 */
export type BayRole = 'storage' | 'factory' | 'shaft' | 'cap' | 'pending';

export interface BayPlan { role: BayRole; interior: BayInterior; }

const EMPTY: BayInterior = { blocks: [], chests: [], machines: [], modems: [] };

export function outfitBay(spec: TowerSpec, level: number, sector: number): BayPlan {
  const name = LEVELS.find((l) => l.index === level)?.name;
  switch (name) {
    case 'bulk':
    case 'buffer':
    case 'ingest':
      // Storage and ingest are racks of single-item chests: bulk holds ore/stone, buffer sorts one
      // class per chest feeding upward, ingest buffers what drones drop before it is sorted down.
      return { role: 'storage', interior: storageBayInterior(spec, sector) };
    case 'smelt':
      return { role: 'factory', interior: factoryBayInterior(spec, sector, FURNACE) };
    case 'shaft':
      return { role: 'shaft', interior: EMPTY };   // the mine head: an open shaft, no bays
    case 'cap':
      return { role: 'cap', interior: EMPTY };      // mast base, no bays
    default:
      // wash / alloy / press / assemble / logic -- machines not yet placeable. Shell only, for now.
      return { role: 'pending', interior: EMPTY };
  }
}

/**
 * THE TRUNK. One ring of cable in the slab layer, just inside the bays' inner edge, so every bay mesh
 * on the level is one network with StorageMan's. It has to be 4-CONNECTED: a discretised circle steps
 * diagonally and cable does not connect across a diagonal -- the ring HQ ordered on 2026-09-08 was 16
 * fragments of 5-7 cells, and sectors 7-9 stayed an island from the wired sector 11 with every cell
 * "laid". Consecutive cells round the ring that only touch at a corner get a bridging cell between them.
 */
export function trunkCells(spec: TowerSpec): Cell[] {
  const outer = spec.radius - spec.serviceDepth - 1;
  const inner = Math.max(spec.walkRadius, outer - BAY_DEPTH);
  const band = discCells(inner).filter((c) => Math.hypot(c.dx, c.dz) > inner - 1);
  band.sort((a, b) => Math.atan2(a.dz, a.dx) - Math.atan2(b.dz, b.dx));
  const seen = new Set(band.map((c) => `${c.dx}:${c.dz}`));
  const out: Cell[] = [];
  for (let i = 0; i < band.length; i++) {
    const a = band[i]!, b = band[(i + 1) % band.length]!;
    out.push({ dx: a.dx, dy: MODEM_DY, dz: a.dz });
    if (Math.abs(a.dx - b.dx) === 1 && Math.abs(a.dz - b.dz) === 1) {
      // a corner step: bridge through the INNER elbow -- the outer one can lie in the bay band
      const e1 = { dx: a.dx, dz: b.dz }, e2 = { dx: b.dx, dz: a.dz };
      const pick = Math.hypot(e1.dx, e1.dz) <= Math.hypot(e2.dx, e2.dz) ? e1 : e2;
      const k = `${pick.dx}:${pick.dz}`;
      if (!seen.has(k)) { seen.add(k); out.push({ dx: pick.dx, dy: MODEM_DY, dz: pick.dz }); }
    }
  }
  return out;
}

/** The trunk as blueprint blocks (cable). */
export function trunkBlocks(spec: TowerSpec): BlueprintBlock[] {
  return trunkCells(spec).map((c) => ({ ...c, item: CABLE }));
}

/**
 * The cable column that joins one level's trunk to the next level's: a wired network is one
 * ring per floor until something climbs between them, and a ring nobody reaches is a bay whose
 * chests StorageMan never sees. The column stands on a cell both rings share (tapers permitting)
 * and fills every cell strictly between the two trunk heights, floor slab included -- cable is
 * infrastructure the shell check tolerates.
 */
export function riserBlocks(a: TowerSpec, b: TowerSpec, dyA: number, dyB: number): BlueprintBlock[] {
  const key = (c: Cell) => `${c.dx}:${c.dz}`;
  const other = new Set(trunkCells(b).map(key));
  const cell = trunkCells(a).find((c) => other.has(key(c)));
  if (!cell) return [];
  const lo = Math.min(dyA, dyB), hi = Math.max(dyA, dyB);
  const out: BlueprintBlock[] = [];
  for (let dy = lo + 1; dy < hi; dy++) out.push({ dx: cell.dx, dy, dz: cell.dz, item: CABLE });
  return out;
}
