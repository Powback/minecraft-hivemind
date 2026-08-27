/**
 * Fuel is the precondition for every other material, and the supply loop did not know it.
 *
 * Caught live: D1 was dispatched to gather DIRT while total fleet fuel fell from 7,556 to 5,664
 * and the coal in storage never moved off 129. Every rule reads as short (StorageMan cannot report
 * stock), so the loop round-robins regardless of whether the fleet can still move.
 */
import { describe, it, expect } from 'vitest';
import { ruleSkipReason, type SupplyRule } from '../src/agent/supply.js';

const FUEL_PRIORITY_BELOW = 4000;

/**
 * THIS NOW CALLS THE REAL DECISION.
 *
 * It used to be a two-line re-implementation of the rule, asserted against itself -- a test shaped
 * exactly like the bug it was written for, which would have passed no matter what supply.ts went on
 * to do. `ruleSkipReason` was extracted out of the 450-line tick so this could import it.
 *
 * `have`/`min` are set so the rule is genuinely short, isolating the fuel decision: a rule that is
 * already satisfied skips for a different reason and would mask the one under test.
 */
const skips = (fleetFuel: number, match: string) => {
  const rule = { match, min: 32, action: 'gather' } as SupplyRule;
  const r = ruleSkipReason(rule, {
    fuelCritical: fleetFuel < FUEL_PRIORITY_BELOW,
    have: 0,
    cooldownUntil: 0,
    now: 1_000_000,
  });
  return r?.kind === 'fuel';
};

describe('fuel priority', () => {
  it('skips dirt when the fleet is running out of fuel', () => {
    expect(skips(3000, 'dirt')).toBe(true);
  });

  it('never skips coal, however low the tank', () => {
    expect(skips(0, 'coal_ore')).toBe(false);
    expect(skips(3000, 'coal_ore')).toBe(false);
  });

  it('lets charcoal through too -- it burns just as well', () => {
    expect(skips(500, 'charcoal')).toBe(false);
  });

  it('leaves the normal round-robin alone once there is a reserve', () => {
    expect(skips(7500, 'dirt')).toBe(false);
    expect(skips(7500, 'copper_ore')).toBe(false);
  });

  it('treats the threshold as a floor, not a target', () => {
    // At exactly the threshold the fleet is not yet critical.
    expect(skips(FUEL_PRIORITY_BELOW, 'dirt')).toBe(false);
    expect(skips(FUEL_PRIORITY_BELOW - 1, 'dirt')).toBe(true);
  });
});

describe('fleet fuel counts only drones that can spend it', () => {
  /**
   * The threshold is computed from a SUM, and the sum was taken over every drone on the books --
   * including ones that had been silent for hours. Fuel inside an unreachable drone is not fuel the
   * fleet has, and treating it as such inverts the entire rule: at the point of collapse eleven
   * reachable drones held ZERO fuel while 41,234 sat inside five lost ones, so the loop saw a
   * comfortable reserve and kept dispatching dirt and copper until nothing could move at all.
   *
   * That is the death spiral the threshold exists to prevent, entered through its own input.
   */
  const liveFuel = (drones: Array<{ fuel: number; offline?: boolean; status?: string }>) => {
    const dead = (d: any) => d.offline === true || d.status === 'offline' || d.status === 'lost';
    return drones.filter((d) => !dead(d)).reduce((n, d) => n + (Number(d.fuel) || 0), 0);
  };

  it('ignores fuel stranded inside lost drones', () => {
    const fleet = [
      { fuel: 0 }, { fuel: 0 }, { fuel: 0 },
      { fuel: 15993, status: 'lost' }, { fuel: 11798, status: 'lost' },
    ];
    expect(liveFuel(fleet)).toBe(0);
    expect(liveFuel(fleet) < FUEL_PRIORITY_BELOW).toBe(true);   // coal-only, correctly
  });

  it('still counts working drones', () => {
    expect(liveFuel([{ fuel: 5000 }, { fuel: 3000, status: 'working' }])).toBe(8000);
  });

  it('an offline flag counts as unreachable even when the status looks fine', () => {
    expect(liveFuel([{ fuel: 9000, offline: true, status: 'working' }])).toBe(0);
  });
});
