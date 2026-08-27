/**
 * The tower generator was written, exported, and imported by NOTHING.
 *
 * A complete cellar/floors/bays design -- "raw material enters at the bottom and each floor refines
 * what the floor below produced" -- with no tool able to ask for a floor. That is why the settlement
 * had no cellar and no ground floor: not a bug in the builder, an absence of any way to request one.
 *
 * These pin the two facts order.tower depends on, both of which decide whether a drone strands
 * itself mid-floor: what a floor COSTS, and that it is overwhelmingly the one material the fleet
 * already drowns in.
 */
import { describe, it, expect } from 'vitest';
import { PALETTES, towerFloor, floorCost, specForLevel } from '../src/world/tower.js';

describe('tower floor, cobble palette', () => {
  const spec = specForLevel(-1);
  const blocks = towerFloor(spec, -1, PALETTES.cobble!);
  const cost = floorCost(blocks);

  it('is built almost entirely of cobblestone', () => {
    // The point of tier 0: mining spoil IS the building material. 78% of storage is cobblestone,
    // and a floor spends 2,310 of it.
    const cobble = cost['minecraft:cobblestone'] ?? 0;
    expect(cobble / blocks.length).toBeGreaterThan(0.95);
  });

  it('is far too big for one drone, which is why order.tower chunks it', () => {
    // A turtle holds 16 stacks = 1,024 items. A single build task for a whole floor could never
    // finish; it would fail with "ran out of minecraft:cobblestone partway through".
    expect(blocks.length).toBeGreaterThan(1024);
  });

  it('needs nothing the fleet cannot already dig', () => {
    // Glass is the one exception and it is twelve blocks; order.tower drops what is unaffordable
    // rather than stranding a drone mid-floor. Everything else falls out of a shaft.
    const undiggable = Object.keys(cost).filter((i) => !/cobblestone|glass|barrel/.test(i));
    expect(undiggable).toEqual([]);
  });

  it('leaves the atrium floor open apart from the spine', () => {
    // The atrium is the drone shaft: open bedrock-to-roof so drones can fly it. The exceptions are
    // deliberate and both are load-bearing -- the central column at dx0/dz0 is the ITEM SPINE that
    // carries goods between floors, and the ring at r=4 is the gallery railing. Anything else on
    // the atrium floor would be a block a drone flies into.
    const floor = blocks.filter((b) => b.dy === 0
      && Math.sqrt(b.dx ** 2 + b.dz ** 2) <= spec.atriumRadius);
    expect(floor.map((b) => `${b.dx},${b.dz}`)).toEqual(['0,0']);
  });

  it('keeps the spine clear of the railing ring', () => {
    // They occupy the same radius band on different cells; overlapping them would wall the spine in.
    const ring = blocks.filter((b) => b.item.endsWith('cobblestone_wall'));
    expect(ring.some((b) => b.dx === 0 && b.dz === 0)).toBe(false);
  });
});
