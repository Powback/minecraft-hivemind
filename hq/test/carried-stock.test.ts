/**
 * STOCK INSIDE A DRONE IS STILL STOCK THE FLEET HAS.
 *
 * `held` counted chests only, so everything in transit was invisible to every decision the supply
 * loop makes. Measured live: the fleet was carrying 3,567 items -- including 421 COAL, roughly
 * 33,680 fuel -- while storage reported 61 coal, the monitor alerted COAL LOW, and the loop
 * dispatched find-coal_ore to go and mine more of it.
 *
 * It is not a rare state either. Storage sits at 0 free slots, so a drone that finishes a job
 * cannot deposit and keeps its load. The fuller the warehouse, the more stock is invisible and the
 * more phantom shortages get invented -- the blindness is worst exactly when it costs most.
 */
import { describe, it, expect } from 'vitest';
import { carriedStock } from '../src/agent/supply.js';

describe('carried stock counts toward what the fleet has', () => {
  it('sums one item across several drones', () => {
    expect(carriedStock([
      { carrying: { 'minecraft:coal': 200 } },
      { carrying: { 'minecraft:coal': 221 } },
    ])['minecraft:coal']).toBe(421);
  });

  it('keeps kinds separate', () => {
    const got = carriedStock([
      { carrying: { 'minecraft:coal': 10, 'minecraft:cobblestone': 300 } },
      { carrying: { 'minecraft:cobblestone': 2173 } },
    ]);
    expect(got).toEqual({ 'minecraft:coal': 10, 'minecraft:cobblestone': 2473 });
  });

  it('survives drones with no cargo, null cargo, or junk cargo', () => {
    expect(carriedStock([{}, { carrying: null }, { carrying: 'nope' }, { carrying: {} }])).toEqual({});
  });

  it('survives being handed nothing at all', () => {
    expect(carriedStock([])).toEqual({});
    expect(carriedStock(null as any)).toEqual({});
  });

  it('ignores zero and negative counts rather than recording them', () => {
    expect(carriedStock([{ carrying: { 'minecraft:dirt': 0, 'minecraft:sand': -5 } }])).toEqual({});
  });

  /**
   * THE ONE THAT MATTERS. The caller passes `live`, which excludes lost and offline drones -- and
   * it must keep doing so. Material inside an unreachable drone cannot be handed over, so counting
   * it as supply is the same class of bug as counting a lost drone's FUEL as available, which
   * produced 41,234 phantom fuel while every reachable drone sat at zero and the fleet stopped.
   *
   * This asserts the arithmetic a caller gets when it correctly filters first.
   */
  it('a filtered-out drone contributes nothing', () => {
    const fleet = [
      { carrying: { 'minecraft:coal': 40 }, status: 'idle' },
      { carrying: { 'minecraft:coal': 15993 }, status: 'lost' },
    ];
    const live = fleet.filter((d) => d.status !== 'lost' && d.status !== 'offline');
    expect(carriedStock(live)['minecraft:coal']).toBe(40);
    expect(carriedStock(fleet)['minecraft:coal']).toBe(16033);   // what NOT filtering would claim
  });
});
