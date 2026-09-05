import { describe, it, expect } from 'vitest';
import { storageBayInterior, factoryBayInterior } from '../src/world/bay.js';
import { specForLevel, bayCells } from '../src/world/tower.js';

const CHEST = 'minecraft:chest';
const MODEM = 'computercraft:wired_modem_full';
const FURNACE = 'minecraft:furnace';

// A storage basement (level -1, plinth band) sector that the flight notch does not pass through.
const storageSpec = specForLevel(-1);
const factorySpec = specForLevel(2);

describe('bay interiors are generated from the bay geometry', () => {
  it('a storage bay is one single-item chest per footprint cell, each capped with a modem', () => {
    const sector = 3;                                   // away from the notch at bearing 0
    const cells = bayCells(storageSpec, sector);
    expect(cells.length).toBeGreaterThan(0);
    const bay = storageBayInterior(storageSpec, sector);

    // One chest per footprint cell -- capacity is the cell count, one item class each.
    expect(bay.chests.length).toBe(cells.length);
    // No two chests share a cell: each is a distinct single-item slot.
    const keys = new Set(bay.chests.map((c) => `${c.dx},${c.dz}`));
    expect(keys.size).toBe(bay.chests.length);
    // Every chest has a modem directly above it -- that is what puts it on the network.
    for (const ch of bay.chests) {
      const capped = bay.modems.some((m) => m.dx === ch.dx && m.dz === ch.dz && m.dy === ch.dy + 1);
      expect(capped).toBe(true);
    }
    // The block list is chests + modems and nothing else.
    expect(bay.blocks.filter((b) => b.item === CHEST).length).toBe(cells.length);
    expect(bay.blocks.filter((b) => b.item === MODEM).length).toBe(cells.length);
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
    // Every placed thing is on the network: a modem per cell.
    expect(bay.modems.length).toBe(cells.length);
    // The two chests are the two ends of the arc, not adjacent middle cells.
    const angle = (c: { dx: number; dz: number }) => Math.atan2(c.dz, c.dx);
    const sorted = [...cells].sort((a, b) => angle(a) - angle(b));
    const ends = new Set([`${sorted[0]!.dx},${sorted[0]!.dz}`, `${sorted[sorted.length - 1]!.dx},${sorted[sorted.length - 1]!.dz}`]);
    for (const ch of bay.chests) expect(ends.has(`${ch.dx},${ch.dz}`)).toBe(true);
  });
});
