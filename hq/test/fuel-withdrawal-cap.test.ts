/**
 * ONE DRONE MAY NOT TAKE THE WHOLE LARDER.
 *
 * CollectFuel asked FetchItems for 64 units on every top-up, whatever the tank actually held, so
 * during a shortage the first drone to reach storage took everything. Measured, with the settlement
 * at 46 charcoal and three miners stranded at zero:
 *
 *   cc#62 (D38, SCOUT)   refuel at storage: +2476 fuel (now 2619, collected 46)
 *   cc#47 (D4, crafter)  JOB Relieve FAILED no fuel to deliver: storage had nothing burnable
 *
 * Seconds apart, and the second line is the consequence of the first. A scout on 206 fuel filled
 * itself to 2,619 -- past any plausible need -- and the relief run for a stranded miner then failed
 * for want of the fuel the scout had just drained.
 *
 * It is worse than unfair. A scout carries a geo_scanner in its second upgrade slot and a crafter a
 * workbench, so canDig() is false for both: neither can fell a tree or mine coal. The settlement's
 * entire fuel supply went to a drone physically incapable of making more, while the three drones
 * that could make more sat at zero and could not move to do it.
 *
 * This is the THIRD time the same shape has cost this project a day: SMELT_RANK put cobblestone
 * last and it still burned 414 charcoal because last-among-available is first when it is the only
 * candidate; the wood reserve did nothing until it had a batch cap; and now this. A preference
 * decides who goes first. Only a limit stops whoever goes first from taking it all.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const DRONE = path.resolve(__dirname, '../../lua/DroneLogic.lua');
const CODE = readFileSync(DRONE, 'utf8');
const BARE = CODE.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n');

describe('a fuel top-up is bounded by need, not by stack size', () => {
  it('CollectFuel asks for what it needs rather than a flat 64', () => {
    const at = BARE.indexOf('local function CollectFuel(');
    expect(at, 'CollectFuel must exist').toBeGreaterThan(-1);
    const body = BARE.slice(at, at + 2600);
    expect(body, [
      'CollectFuel must size its request from the tank deficit (FuelUnitsWanted), not ask for a',
      'flat 64 units. Asking for 64 is what let one scout drain 46 charcoal and strand the relief',
      'run that was carrying fuel to a miner at zero.',
    ].join('\n')).toMatch(/FetchItems\(\{\s*\[s_Name\]\s*=\s*FuelUnitsWanted\(\)/);
  });

  it('the cap is declared before CollectFuel uses it', () => {
    /**
     * The nine-outage trap: a `local` declared below the function that uses it is a silent nil
     * global, the branch is simply dead, and nothing reports it. FuelUnitsWanted is a global
     * function for the same reason RefuelAtStorage is -- it is used ~2,700 lines from where the
     * constants live.
     */
    const decl = BARE.indexOf('function FuelUnitsWanted(');
    const use = BARE.indexOf('FuelUnitsWanted()', BARE.indexOf('local function CollectFuel('));
    expect(decl, 'FuelUnitsWanted must exist').toBeGreaterThan(-1);
    expect(decl, 'FuelUnitsWanted must be declared BEFORE CollectFuel calls it').toBeLessThan(use);
  });

  it('it never returns more than a bounded number of units', () => {
    const at = BARE.indexOf('function FuelUnitsWanted(');
    const body = BARE.slice(at, BARE.indexOf('\nend', at));
    // Both ends matter: the min keeps a walk to storage from returning empty over a rounding
    // decision (FetchItems' own minimum is 8), the max is the actual fix.
    expect(body, 'the request must be clamped, or the deficit alone could still ask for a stack')
      .toMatch(/math\.min\(REFUEL_MAX_UNITS/);
    expect(body, 'keep a floor: FetchItems returns nothing below its minimum of 8')
      .toMatch(/math\.max\(8/);
  });

  it('a non-numeric fuel level does not throw', () => {
    // turtle.getFuelLevel() returns the STRING "unlimited" when fuel is disabled, and arithmetic
    // on it throws -- inside the one function every drone calls to feed itself.
    const at = BARE.indexOf('function FuelUnitsWanted(');
    expect(BARE.slice(at, BARE.indexOf('\nend', at)), 'guard the "unlimited" string')
      .toMatch(/type\(f\)\s*~=\s*"number"/);
  });
});
