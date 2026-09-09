import { describe, it, expect } from 'vitest';
import { storageBayInterior, factoryBayInterior, outfitBay, trunkCells, riserBlocks } from '../src/world/bay.js';
import { specForLevel, bayCells } from '../src/world/tower.js';

const CHEST = 'minecraft:chest';
const MODEM = 'computercraft:wired_modem_full';
const FURNACE = 'minecraft:furnace';

// A storage basement (level -1, plinth band) sector that the flight notch does not pass through.
const storageSpec = specForLevel(-1);
const factorySpec = specForLevel(2);

describe('bay interiors are generated from the bay geometry', () => {
  it('a storage bay is a checkerboard of single chests, each on its own modem, nothing on top', () => {
    const sector = 3;                                   // away from the notch at bearing 0
    const cells = bayCells(storageSpec, sector);
    expect(cells.length).toBeGreaterThan(0);
    const bay = storageBayInterior(storageSpec, sector);

    // Every other cell holds a chest: two chests that touch merge into a double chest and stop being
    // one item class each (the user, 2026-09-08).
    const even = cells.filter((c) => (c.dx + c.dz) % 2 === 0);
    expect(bay.chests.length).toBe(even.length);
    for (const a of bay.chests) for (const b of bay.chests) {
      if (a !== b) expect(Math.abs(a.dx - b.dx) + Math.abs(a.dz - b.dz)).toBeGreaterThan(1);
    }
    // Every chest stands on its modem (one below, in the slab layer) and has NOTHING above it: a turtle
    // loads and unloads a chest from above.
    for (const ch of bay.chests) {
      const under = bay.modems.some((m) => m.dx === ch.dx && m.dz === ch.dz && m.dy === ch.dy - 1);
      expect(under).toBe(true);
      const above = bay.blocks.some((b) => b.dx === ch.dx && b.dz === ch.dz && b.dy > ch.dy);
      expect(above).toBe(false);
    }
    // The other cells carry cable in the slab layer, so the modems form one network.
    expect(bay.blocks.filter((b) => b.item === CHEST).length).toBe(even.length);
    expect(bay.blocks.filter((b) => b.item === MODEM).length).toBe(even.length);
    expect(bay.blocks.filter((b) => b.item === 'computercraft:cable').length).toBe(cells.length - even.length);
  });

  it('a factory bay is furnaces between an input and an output chest, all networked', () => {
    const sector = 3;
    const cells = bayCells(factorySpec, sector);
    expect(cells.length).toBeGreaterThanOrEqual(3);
    const bay = factoryBayInterior(factorySpec, sector, FURNACE);

    // Two buffer chests (the ends), the rest furnaces.
    expect(bay.chests.length).toBe(2);
    expect(bay.machines.length).toBe(cells.length - 2);
    expect(bay.blocks.filter((b) => b.item === FURNACE).length).toBe(cells.length - 2);
    // Every placed thing is on the network: a modem per cell, and a second one over every furnace (its input face).
    expect(bay.modems.length).toBe(cells.length + bay.machines.length);
    for (const m of bay.machines) expect(bay.modems.some((x) => x.dx === m.dx && x.dz === m.dz && x.dy === m.dy + 1)).toBe(true);
    // The two chests are the two ends of the arc, not adjacent middle cells.
    const angle = (c: { dx: number; dz: number }) => Math.atan2(c.dz, c.dx);
    const sorted = [...cells].sort((a, b) => angle(a) - angle(b));
    const ends = new Set([`${sorted[0]!.dx},${sorted[0]!.dz}`, `${sorted[sorted.length - 1]!.dx},${sorted[sorted.length - 1]!.dz}`]);
    for (const ch of bay.chests) expect(ends.has(`${ch.dx},${ch.dz}`)).toBe(true);
  });
});

describe('outfitBay decides a bay from the floor it is on', () => {
  const sector = 3;
  it('storage floors get sorted single-item racks', () => {
    for (const lv of [-2, -1, 0]) {
      const plan = outfitBay(specForLevel(lv), lv, sector);
      expect(plan.role).toBe('storage');
      expect(plan.interior.chests.length).toBeGreaterThan(0);
      expect(plan.interior.machines.length).toBe(0);
    }
  });
  it('the smelt floor gets a furnace bank', () => {
    const plan = outfitBay(specForLevel(2), 2, sector);
    expect(plan.role).toBe('factory');
    expect(plan.interior.machines.length).toBeGreaterThan(0);
    expect(plan.interior.chests.length).toBe(2);
  });
  it('the mine head and the cap hold no bays', () => {
    expect(outfitBay(specForLevel(-3), -3, sector).role).toBe('shaft');
    expect(outfitBay(specForLevel(7), 7, sector).role).toBe('cap');
  });
  it('a floor whose machine cannot be placed yet is left a shell, marked pending', () => {
    const plan = outfitBay(specForLevel(3), 3, sector);   // alloy: mixer not placeable yet
    expect(plan.role).toBe('pending');
    expect(plan.interior.blocks.length).toBe(0);
  });
});

describe('the trunk ties every bay of a level into one network', () => {
  const sp = specForLevel(-1);
  const trunk = trunkCells(sp);
  const key = (c: { dx: number; dz: number }) => `${c.dx}:${c.dz}`;
  it('is one 4-connected component (cable does not connect diagonally)', () => {
    const set = new Set(trunk.map(key));
    const seen = new Set<string>(); const stack = [key(trunk[0]!)]; seen.add(stack[0]!);
    while (stack.length) { const [x, z] = stack.pop()!.split(':').map(Number); for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) { const n = `${x + dx}:${z + dz}`; if (set.has(n) && !seen.has(n)) { seen.add(n); stack.push(n); } } }
    expect(seen.size).toBe(trunk.length);
  });
  it('touches every bay of the level and shares no cell with one', () => {
    const set = new Set(trunk.map(key));
    for (let s = 0; s < sp.sectors; s++) {
      const cells = bayCells(sp, s);
      expect(cells.some((c) => set.has(key(c)))).toBe(false);
      expect(cells.some((c) => [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dz]) => set.has(`${c.dx + dx!}:${c.dz + dz!}`)))).toBe(true);
    }
  });
  it('lies in the slab layer', () => expect(trunk.every((c) => c.dy === 0)).toBe(true));
});

describe('a riser joins one level\'s trunk to the next', () => {
  it('stands on a shared trunk cell and fills every cell strictly between the two rings', () => {
    const sp = specForLevel(-2), up = specForLevel(-1);
    const r = riserBlocks(sp, up, -12, -6);
    expect(r.map((b) => b.dy).sort((a, b) => a - b)).toEqual([-11, -10, -9, -8, -7]);
    const key = (c: { dx: number; dz: number }) => `${c.dx}:${c.dz}`;
    expect(new Set(r.map(key)).size).toBe(1);
    expect(trunkCells(sp).map(key)).toContain(key(r[0]!));
    expect(trunkCells(up).map(key)).toContain(key(r[0]!));
    expect(r.every((b) => b.item === 'computercraft:cable')).toBe(true);
  });
});
