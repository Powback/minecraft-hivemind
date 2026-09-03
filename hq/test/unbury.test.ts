import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * A DRONE THAT OWNS A PICKAXE MUST TRY IT BEFORE CALLING FOR HELP.
 *
 * The self-unbury loop only ever called pgps.up(), which moves through air and does nothing about
 * stone. Under the floor the first move fails, the loop breaks on its first pass, and the drone
 * reports "climbed 0 block(s) toward the surface" and raises a distress -- while holding the tool
 * that would free it. D35 spent an hour on this at y=1 and D57 an hour at y=50; the probe that
 * settled it was one line:
 *
 *   fleet.probe #57 turtle.digUp()  ->  dig=true
 *
 * The existing note blamed the pickaxe ("having a pickaxe is not the same as getting out"). The
 * cause was that nothing had ever asked the pickaxe to do anything.
 */
describe('the buried-drone climb cuts its way out', () => {
  const fn = (() => {
    const i = drone.indexOf('local function riseOneDigging()');
    return drone.slice(i, drone.indexOf('\nend\n', i) + 5);
  })();

  it('digs upward when the way up is solid', () => {
    expect(fn).toMatch(/if pgps\.up\(\) then return true end/);
    expect(fn).toMatch(/turtle\.digUp\(\)/);
  });

  it('still refuses to mine the settlement', () => {
    // IsProtected is the fleet's single list of things no drone may ever dig. A second copy of
    // that list would be wrong the first time somebody added a machine to one and not the other.
    expect(fn).toMatch(/IsProtected\(/);
    expect(fn).toMatch(/if not CanDig\(\) then return false end/);
  });

  it('is used by the climb loop instead of a bare move', () => {
    const loop = drone.slice(drone.indexOf('while s_Rose < CLIMB_MAX do'));
    expect(loop.slice(0, 400)).toMatch(/if not riseOneDigging\(\) then break end/);
  });
});
