import { describe, it, expect } from 'vitest';
import { BLUEPRINTS, blueprint, materials, placementOrder, footprint } from './blueprints.js';
import { expand } from './recipes.js';

describe('blueprints', () => {
  it('places bottom-up, because a turtle cannot place a block in mid-air', () => {
    const bp = blueprint('field-cache')!;
    const order = placementOrder(bp);
    const chestAt = order.findIndex((b) => b.item === 'minecraft:chest');
    // Every floor block comes before the chest that sits on it.
    expect(order.slice(0, chestAt).every((b) => b.dy === 0)).toBe(true);
    expect(order[chestAt].dy).toBe(1);
  });

  it('costs a structure before anything is dispatched', () => {
    const m = materials(blueprint('field-cache')!);
    expect(m['minecraft:oak_planks']).toBe(9);
    expect(m['minecraft:chest']).toBe(1);
  });

  it('reports the ground it will occupy, so the plot check has something to test', () => {
    const f = footprint(blueprint('field-cache')!, { x: 10, y: 64, z: -20 });
    expect(f.min).toEqual({ x: 9, y: 64, z: -21 });
    expect(f.max).toEqual({ x: 11, y: 65, z: -19 });
  });

  it('only calls for materials the fleet can actually obtain', () => {
    // The failure this prevents: a build that queues, consumes drones and stalls halfway because
    // one of its blocks has no recipe and no source. Cheaper to catch here than in world.
    for (const bp of BLUEPRINTS) {
      for (const item of Object.keys(materials(bp))) {
        const plan = expand(item, 1, () => 0);
        expect(plan.missing, `${bp.name} needs ${item}`).toEqual([]);
      }
    }
  });

  it('the cheapest blueprint is buildable from logs alone', () => {
    const m = materials(blueprint('claim-post')!);
    const plan = expand('minecraft:oak_planks', m['minecraft:oak_planks'], () => 0);
    expect(plan.missing).toEqual([]);
    expect(plan.steps.some((s) => s.action === 'lumber' || s.item === 'minecraft:oak_log')).toBe(true);
  });
});
