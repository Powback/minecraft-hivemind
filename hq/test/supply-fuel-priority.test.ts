/**
 * Fuel is the precondition for every other material, and the supply loop did not know it.
 *
 * Caught live: D1 was dispatched to gather DIRT while total fleet fuel fell from 7,556 to 5,664
 * and the coal in storage never moved off 129. Every rule reads as short (StorageMan cannot report
 * stock), so the loop round-robins regardless of whether the fleet can still move.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { ruleSkipReason, fuelRunway, producesFuel, type SupplyRule } from '../src/agent/supply.js';

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

/**
 * THE GATE HAS NOW MEASURED THE WRONG NUMBER THREE TIMES.
 *
 * First it summed fuel inside drones nobody could reach: 41,234 phantom fuel in five silent drones
 * while eleven reachable ones sat at zero. Then it trusted stock that could not be read. Then it
 * counted only what was already in the tanks and ignored the warehouse that refills them -- 7,078
 * fuel onboard against 50 coal in storage read as comfortable, and the queue held eleven
 * tower-building tasks against a single coal gather while the settlement starved.
 *
 * The failure is always the same shape and never the same input, so the check is on the QUANTITY:
 * what the fleet can still burn, tanks plus warehouse.
 */
describe('fuel runway counts the warehouse, not just the tanks', () => {
  const carried = {} as Record<string, number>;

  it('declares an emergency when the tanks look fine but there is no coal to refill from', () => {
    // The exact numbers measured at the collapse.
    const r = fuelRunway([{ name: 'minecraft:coal', count: 50 }], carried, 7078);
    expect(r.coalReserve).toBe(50);
    expect(r.runway).toBe(7078 + 50 * 80);
    expect(r.critical).toBe(true);
  });

  it('stays calm when the warehouse is genuinely stocked', () => {
    const r = fuelRunway([{ name: 'minecraft:coal', count: 704 }], carried, 12_000);
    expect(r.critical).toBe(false);
  });

  it('still fires on empty tanks even with coal in the chest -- the drone has to reach it', () => {
    const r = fuelRunway([{ name: 'minecraft:coal', count: 704 }], carried, 100);
    expect(r.critical).toBe(true);
  });

  it('counts charcoal as fuel', () => {
    const r = fuelRunway([{ name: 'minecraft:charcoal', count: 300 }], carried, 1000);
    expect(r.coalReserve).toBe(300);
  });

  it('does NOT count coal_ore -- substring matching is what made this wrong before', () => {
    const r = fuelRunway([{ name: 'minecraft:coal_ore', count: 900 }], carried, 5000);
    expect(r.coalReserve).toBe(0);
    expect(r.critical).toBe(true);
  });

  it('counts fuel held in drones, which is stock the warehouse cannot see', () => {
    const r = fuelRunway([], { 'minecraft:coal': 256 }, 5000);
    expect(r.coalReserve).toBe(256);
  });
});

/**
 * A FUEL EMERGENCY MUST NOT FORBID THE ONLY FUEL THE FLEET CAN REACH.
 *
 * The gate tested `/coal/`, which assumes reachable coal. This settlement's coal is all mapped
 * between y=27 and y=58 -- inside the operating circle, but ten to forty blocks underground where
 * there is no GPS. Three drones stranded trying to get to it. The 1,069 oak_log at y=64-70 are on
 * the surface and burn, via charcoal, just as well.
 */
describe('a fuel emergency permits everything that burns, not just coal', () => {
  it('permits coal and charcoal', () => {
    expect(producesFuel('coal_ore')).toBe(true);
    expect(producesFuel('minecraft:charcoal')).toBe(true);
  });

  it('permits wood, which is the reachable half of the fuel supply', () => {
    expect(producesFuel('oak_log')).toBe(true);
  });

  it('still refuses ore the fleet cannot burn', () => {
    for (const m of ['iron_ore', 'copper_ore', 'zinc_ore', 'redstone_ore', 'gold_ore', 'dirt']) {
      expect(producesFuel(m), m).toBe(false);
    }
  });
});

/**
 * THE TWO DISPATCHERS THAT NEVER ASKED.
 *
 * `fuelCritical` gates materialPhases and, through ruleSkipReason, every rule in the tick's loop.
 * surveyCaves and scoutForMiners are called after that loop and consulted neither -- so during a
 * declared fuel emergency the settlement refused to gather dirt and then sent a scout on a cave
 * survey at the edge of its range instead.
 *
 * That is worse than an ungated tick, because the emergency note prints once a minute and reads as
 * if the fleet is being protected. It was found with storage on ZERO coal and the only fuelled
 * mobile drone flying a survey while burning the 32 coal it was carrying home to the furnaces.
 *
 * Asserted at the call site rather than through the tick: runSupplyTick needs a live bridge, and a
 * guard that only exists when a mock is wired up is a guard that stops guarding the day the mock
 * changes.
 */
describe('exploration during a fuel emergency', () => {
  const SRC = readFileSync(path.resolve(__dirname, '../src/agent/supply.ts'), 'utf8');
  const lines = SRC.split('\n');

  for (const call of ['await surveyCaves(', 'await scoutForMiners(']) {
    it(`${call.trim()}…) is guarded by fuelCritical`, () => {
      const at = lines.findIndex((l) => l.includes(call));
      expect(at, `${call} must still exist`).toBeGreaterThan(-1);

      // Only one call site each: a second, ungated one is exactly how this regressed the first time.
      expect(lines.filter((l) => l.includes(call)).length, 'one call site only').toBe(1);

      // The guard has to be immediately above the call, not merely somewhere in the function.
      expect(lines.slice(Math.max(0, at - 6), at).join('\n')).toMatch(/fuelCritical/);
    });
  }
});
