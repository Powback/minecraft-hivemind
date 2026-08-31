/**
 * THE RESERVE MUST NOT OUTLAW THE WORK THAT REFILLS IT.
 *
 * FUEL_RESERVE is a flat 900 on top of a distance term, and it buys exactly one thing: certainty
 * that the drone can reach storage AND REFUEL THERE. When storage is empty that purchase is void --
 * arriving changes nothing -- and the only remaining effect of the 900 is to forbid work.
 *
 * Which is a deadlock rather than an inefficiency, because the forbidden work is what ends the
 * shortage. Measured: D15 holding 829 fuel, ~20 blocks from base, a verified oak tree 33 blocks
 * away, round trip under 150. It logged "DISTRESS: low fuel level 829, nothing to refuel with at
 * the dock", refused the lumber job, flew to an empty chest, found nothing, and repeated -- while
 * the settlement's entire fuel income depended on that one gather. Charcoal comes from logs; logs
 * come from a drone; the drone would not go, because it was saving fuel to visit a chest that could
 * not help it.
 *
 * Static guards: there is no Lua runtime in this suite, so these assert the SHAPE of the decision
 * -- that the dry branch exists, is reached from FuelFloorNow, and does not re-add the flat
 * reserve it exists to drop.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const SRC = readFileSync(path.resolve(__dirname, '../../lua/DroneLogic.lua'), 'utf8');
const CODE = SRC.replace(/--.*$/gm, '');

/** FuelFloorNow's body, without comments. */
function floorBody(): string {
  const m = /function FuelFloorNow\(\)([\s\S]*?)\nend/.exec(CODE);
  expect(m, 'FuelFloorNow must exist').toBeTruthy();
  return m![1];
}

describe('fuel floor', () => {
  it('collapses to the trip home when storage is known dry', () => {
    const body = floorBody();

    // The whole fix: the floor asks whether there is anything to reserve FOR.
    expect(body, 'FuelFloorNow must consult StorageKnownDry').toMatch(/StorageKnownDry\(/);

    const dry = body.split('\n').find((l) => l.includes('StorageKnownDry('));
    expect(dry).toBeTruthy();

    // The dry branch must return, and must NOT re-add the flat reserve -- adding it back is the
    // bug wearing the fix's clothes, and would read as guarded while changing nothing.
    expect(dry!, 'the dry branch must return a floor').toMatch(/return/);
    expect(dry!, 'the dry branch must not re-add FUEL_RESERVE').not.toMatch(/FUEL_RESERVE/);
  });

  it('still charges the full reserve when storage has fuel', () => {
    const body = floorBody();
    // The last return is the normal path and must keep the protection that the 900 was added for:
    // a drone far from home, with a stocked larder, should still break off in time to reach it.
    const returns = body.split('\n').filter((l) => /return/.test(l));
    expect(returns.at(-1), 'the normal path keeps the flat reserve').toMatch(/FUEL_RESERVE/);
  });

  it('keeps StorageKnownDry declared above FuelFloorNow', () => {
    // A `local`/function used above its declaration is a nil global in Lua, silently -- the single
    // most expensive mistake in this codebase. Here it would make the dry branch simply never fire,
    // restoring the deadlock with the fix still visibly present in the source.
    const declared = CODE.indexOf('function StorageKnownDry(');
    const used = CODE.indexOf('function FuelFloorNow(');
    expect(declared).toBeGreaterThan(-1);
    expect(declared).toBeLessThan(used);
  });
});

/**
 * NOBODY FLIES TO A FIXED ALTITUDE TO GET SOMEWHERE.
 *
 * The survey path used to answer "cannot reach" by flying to CRUISE_Y = 110, crossing above the
 * terrain and dropping down. That is what you do with no map. This settlement has one: MapServer
 * holds ~262,000 named blocks and runs A* over them, so the climb was never buying a route -- it
 * was buying a way to ignore the router, at ~90 fuel per round trip, plus the GPS fix lost on the
 * way up and a dead-reckoned descent.
 *
 * D15 left base with 634 fuel for a tree NINETEEN blocks away, logged "boxed in -- climbing to 110
 * to cross", and was found at y=102 with 322 fuel and no logs. The trip costs under 150 at ground
 * level.
 *
 * climbForFix is deliberately exempt: it gains height for a reason height actually solves -- a GPS
 * fix needs four audible hosts and rock does not carry radio -- and it is bounded by
 * SKY_FIX_CEILING and refuses when the fuel will not pay for the return.
 */
describe('no fixed-altitude flyovers', () => {
  it('has no CRUISE_Y constant to fly to', () => {
    expect(CODE, 'CRUISE_Y was removed on purpose; A* is the router').not.toMatch(/CRUISE_Y\s*=/);
  });

  // There was a second check here that scanned flyTo's arguments for a hardcoded altitude. It is
  // gone, and the reason is worth keeping: it fired immediately on `flyTo(p_X, cy, p_Z, 256)`,
  // whose 256 is a step budget. Guessing at call shapes with a pattern produces a guard that cries
  // wolf, and a guard that cries wolf gets deleted by whoever it blocks -- taking the real check
  // above with it. Deleting the constant is what prevents the flyover; this file only has to make
  // sure nobody declares it again.
});
