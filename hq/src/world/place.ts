/**
 * PLACING BLOCKS, AND WRITING DOWN THAT WE DID.
 *
 * There is no fleet in a fresh world, so the first structure has to be cheated in over rcon. That is
 * exactly the thing that has been complained about -- 22 GPS hosts placed by command, infrastructure
 * that the settlement never learned to build for itself -- and the fix is not to refuse to cheat. It
 * is to make cheating produce the recipe.
 *
 * Every placement goes through here, and here writes two things: the rcon commands that put the
 * blocks in the world now, and a manifest of the same placements as data. The manifest is what a
 * bootstrap turtle replays later. So the act of building it by hand IS the act of writing down how
 * to build it, and the two cannot drift apart, because there is only one description.
 *
 * The blocks themselves come from the real generator in tower.ts rather than from a hand-written
 * list here. Building the first floor is therefore also the first test of that code, which has so far
 * been verified only by compiling and by drawing pictures of it.
 */

import type { BlueprintBlock } from './blueprints.js';

export interface PlaceStep {
  x: number; y: number; z: number;
  item: string;
  heading?: 'north' | 'west' | 'south' | 'east';
}

export interface Manifest {
  name: string;
  origin: { x: number; y: number; z: number };
  /** Relative to origin, in placement order, exactly as a turtle would walk them. */
  steps: Array<Omit<PlaceStep, 'x' | 'y' | 'z'> & { dx: number; dy: number; dz: number }>;
}

export function toManifest(
  name: string,
  origin: { x: number; y: number; z: number },
  blocks: BlueprintBlock[],
): Manifest {
  return {
    name,
    origin,
    steps: blocks.map((b) => ({ dx: b.dx, dy: b.dy, dz: b.dz, item: b.item, heading: b.heading })),
  };
}

/**
 * Turn placements into as few /fill commands as possible.
 *
 * One /setblock per block is 2,300 rcon round trips for a single floor, which at a third of a second
 * each is a quarter of an hour of waiting to find out whether the geometry was right. A disc is
 * contiguous along x for any fixed y and z, so runs collapse into /fill and the same floor becomes
 * about forty commands.
 *
 * Blocks carrying a heading are NEVER collapsed. /fill cannot express orientation, and quietly
 * dropping it would place a staircase as a pile of steps -- the precise bug the heading work exists
 * to fix. Those go one at a time, with the facing named, and there are only a few dozen of them.
 */
export function toCommands(m: Manifest): string[] {
  const abs = m.steps.map((s) => ({
    x: m.origin.x + s.dx, y: m.origin.y + s.dy, z: m.origin.z + s.dz,
    item: s.item, heading: s.heading,
  }));

  const out: string[] = [];
  const directional = abs.filter((b) => b.heading);
  const plain = abs.filter((b) => !b.heading);

  // Group by (y, z, item), then collapse contiguous x.
  const rows = new Map<string, typeof plain>();
  for (const b of plain) {
    const k = `${b.y}|${b.z}|${b.item}`;
    if (!rows.has(k)) rows.set(k, []);
    rows.get(k)!.push(b);
  }
  for (const [k, cells] of rows) {
    const [y, z, item] = [Number(k.split('|')[0]), Number(k.split('|')[1]), k.split('|').slice(2).join('|')];
    cells.sort((a, b) => a.x - b.x);
    let runStart = cells[0]!.x;
    let prev = runStart;
    for (let i = 1; i <= cells.length; i++) {
      const cur = cells[i]?.x;
      if (cur === prev + 1) { prev = cur; continue; }
      out.push(`fill ${runStart} ${y} ${z} ${prev} ${y} ${z} ${item}`);
      if (cur === undefined) break;
      runStart = cur; prev = cur;
    }
  }

  // Facing is expressed as blockstate. A turtle gets the same result by turning before it places;
  // this is the command-line equivalent of the same instruction, not a different one.
  for (const b of directional) {
    out.push(`setblock ${b.x} ${b.y} ${b.z} ${b.item}[facing=${b.heading}]`);
  }
  return out;
}
