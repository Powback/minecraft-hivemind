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
import { bayCells } from './tower.js';

const CHEST = 'minecraft:chest';
const MODEM = 'computercraft:wired_modem_full';
const FURNACE = 'minecraft:furnace';

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
const CHEST_DY = 1;
const MODEM_DY = 2;

/**
 * A basement bay as sorted storage: one single-item chest on every footprint cell, each capped with
 * a modem. Capacity is the cell count; StorageMan assigns one item class per chest as items arrive.
 */
export function storageBayInterior(spec: TowerSpec, sector: number): BayInterior {
  const floor = bayCells(spec, sector);
  const blocks: BlueprintBlock[] = [];
  const chests: Cell[] = [];
  const modems: Cell[] = [];
  for (const c of floor) {
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
    else machines.push({ dx: c.dx, dy: CHEST_DY, dz: c.dz });
  });
  return { blocks, chests, machines, modems };
}
