import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * A BUILD WRITES THE WORLD AT A COORDINATE, SO IT MUST KNOW WHERE IT IS.
 *
 * turtle.placeDown() succeeds wherever the drone happens to be. If its position is wrong the brick
 * lands somewhere arbitrary while noteObservation records it at the coordinate we MEANT, so the
 * fleet's map fills with structure that does not exist and the material is gone.
 *
 * Measured, and this is the whole bug in two numbers: of seven coordinates the fleet had recorded
 * as built, ZERO had a block on them -- while a blind grid scan found bricks at four points nobody
 * had ever recorded. Hundreds of bricks left storage, every build reported success, and no floor
 * ever appeared. The unreachable pickups and the "blocked" squares that were plainly air were the
 * same wrong position seen from other angles.
 */
describe('a build refuses to place on a guessed position', () => {
  const fn = (() => {
    const i = drone.indexOf('function sureWhereWeAre');
    return drone.slice(i, drone.indexOf('\nend\n', i) + 5);
  })();

  /**
   * positionVerified() answers "how old is the last fix" and nothing else, so a drone that fixed
   * twenty seconds ago and has since flown ten blocks on a wrong heading still answers true. The
   * first version of this guard only re-fixed when that returned false -- so it never re-fixed,
   * logged zero refusals, and blocks kept landing in the wrong places.
   */
  it('takes a FRESH fix every time, never trusting a recent one', () => {
    expect(fn).toMatch(/pgps\.verifyPosition\(true\)/);
    // must not short-circuit on a merely-recent fix before forcing one
    expect(fn).not.toMatch(/if pgps\.positionVerified\(\) then return true end/);
  });

  it('returns false rather than placing blind', () => {
    expect(fn).toMatch(/return false/);
    expect(fn).toMatch(/no fresh gps fix/);
  });

  it('the placement loop skips the block instead of placing it', () => {
    const loop = drone.slice(drone.indexOf('local s_Placed, s_Skipped = 0, 0'),
                             drone.indexOf('Deposit()          -- leftovers'));
    const guard = loop.indexOf('if not sureWhereWeAre(');
    // the CALL, not the prose -- the comment above the guard quotes turtle.placeDown() too
    const place = loop.indexOf('and turtle.placeDown() then');
    expect(guard).toBeGreaterThan(-1);
    expect(guard).toBeLessThan(place);          // must gate the placement, not follow it
    expect(loop.slice(guard, guard + 200)).toMatch(/s_Skipped = s_Skipped \+ 1/);
  });
});
