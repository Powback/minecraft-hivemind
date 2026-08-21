/**
 * The planner is the component whose bugs are least visible in world: a wrong plan does not throw,
 * it quietly orders the wrong work and looks busy. So it is tested here, where a wrong answer is
 * loud and costs nothing.
 */
import { describe, it, expect } from 'vitest';
import { expand, craftable } from './recipes.js';

const nothing = () => 0;
const stock = (s: Record<string, number>) => (i: string) => s[i] ?? 0;

describe('expand', () => {
  it('turns a chest into the whole wood chain, in dependency order', () => {
    const p = expand('minecraft:chest', 1, nothing);
    const order = p.steps.map((s) => s.item);
    expect(order).toEqual([
      'minecraft:oak_log',
      'minecraft:oak_planks',
      'minecraft:chest',
    ]);
    // Inputs must be produced before the thing that consumes them, so the caller can execute the
    // list front to back with no sorting of its own.
    expect(order.indexOf('minecraft:oak_planks')).toBeLessThan(order.indexOf('minecraft:chest'));
    expect(p.missing).toEqual([]);
  });

  it('respects yields instead of ordering one run per unit', () => {
    // 8 planks at 4 per log is TWO logs. Ignoring yields orders eight -- a 4x over-harvest that
    // looks perfectly reasonable in a log line.
    const p = expand('minecraft:chest', 1, nothing);
    const logs = p.steps.find((s) => s.item === 'minecraft:oak_log')!;
    expect(logs.runs).toBe(2);
    const planks = p.steps.find((s) => s.item === 'minecraft:oak_planks')!;
    expect(planks.need).toBe(8);
    expect(planks.runs).toBe(2);
  });

  it('spends existing stock and does not order what it already has', () => {
    const p = expand('minecraft:chest', 1, stock({ 'minecraft:oak_planks': 8 }));
    expect(p.steps.map((s) => s.item)).toEqual(['minecraft:chest']);
    expect(p.satisfied['minecraft:oak_planks']).toBe(8);
  });

  it('never spends the same stack twice across branches', () => {
    // The bug this exists to catch: counting stock per branch lets four chests each claim the same
    // eight planks, producing a plan that cannot possibly run.
    const p = expand('minecraft:chest', 4, stock({ 'minecraft:oak_planks': 8 }));
    expect(p.satisfied['minecraft:oak_planks']).toBe(8);
    const planks = p.steps.find((s) => s.item === 'minecraft:oak_planks');
    // 32 needed, 8 held -> 24 still to make, which is 6 logs.
    expect(planks?.need).toBe(24);
    expect(p.steps.find((s) => s.item === 'minecraft:oak_log')?.runs).toBe(6);
  });

  it('reaches through smelting for glass', () => {
    const p = expand('minecraft:glass', 3, nothing);
    expect(p.steps.map((s) => [s.item, s.action])).toEqual([
      ['minecraft:sand', 'gather'],
      ['minecraft:glass', 'smelt'],
    ]);
  });

  it('names what it cannot obtain rather than emitting an impossible plan', () => {
    const p = expand('minecraft:hopper', 1, nothing);
    // Iron is reachable (raw_iron -> smelt), so the hopper itself is plannable; the point is that
    // anything unreachable would surface in `missing` instead of vanishing.
    expect(p.missing).toEqual([]);
    expect(p.steps.some((s) => s.item === 'minecraft:iron_ingot')).toBe(true);
  });

  it('reports an unknown goal as missing instead of throwing', () => {
    const p = expand('minecraft:beacon', 1, nothing);
    expect(p.steps).toEqual([]);
    expect(p.missing).toEqual(['minecraft:beacon']);
  });

  it('carries the crafting grid, because turtle.craft reads slots, not recipe names', () => {
    const p = expand('minecraft:chest', 1, stock({ 'minecraft:oak_planks': 8 }));
    const chest = p.steps[0];
    expect(chest.grid).toHaveLength(9);
    expect(chest.grid![4]).toBeNull();   // the hole in the middle IS the recipe
  });

  it('lists what can be produced at all', () => {
    expect(craftable()).toContain('minecraft:chest');
    expect(craftable()).toContain('minecraft:iron_ingot');
  });
});
