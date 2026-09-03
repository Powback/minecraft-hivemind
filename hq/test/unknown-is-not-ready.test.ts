import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const taskman = readFileSync(join(__dirname, '../../lua/TaskMan.lua'), 'utf8');

/**
 * A MISSING READING IS NOT A HEALTHY ONE.
 *
 * hasFuel returned true for any drone whose fuel field was absent, so that an older DroneMan record
 * could not bench the fleet. The reasoning was sound and the test was not: the drones whose fuel is
 * missing are overwhelmingly the ones whose HEARTBEAT is missing, and a drone that has stopped
 * reporting is exactly the one that has run dry, left radio range, or wedged. So work went
 * preferentially to the drones least able to do it, sat unstarted, and was reclaimed a minute later
 * -- which from outside looks like a scheduler that refuses to dispatch.
 *
 * CLAUDE.md records the same trap one layer up for the same data: fuel and position are replayed
 * from the last heartbeat a drone managed to get home, so the numbers are freshest exactly when
 * they matter least.
 */
describe('unknown fuel is not treated as a full tank', () => {
  const fn = (() => {
    const i = taskman.indexOf('local function hasFuel(d)');
    return taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
  })();

  it('a known reading is compared against the floor', () => {
    // The floor is now the one the DRONE reports -- a constant here drifted from the drone's own
    // figure twice, most recently opening a band where a drone was refused work for being too low
    // and refused fuel for being too high. See fuel-floor-agrees.test.ts.
    expect(fn).toMatch(/if f ~= nil then return f >= fuelFloorOf\(d\) end/);
  });

  it('an unknown reading is only trusted while the record is fresh', () => {
    expect(fn).toMatch(/lastSeen/);
    expect(fn).toMatch(/FUEL_UNKNOWN_GRACE_MS/);
  });

  /** No record of ever being seen is the least trustworthy state of all. */
  it('never trusts a record that was never seen', () => {
    expect(fn).toMatch(/if s_Seen == nil then return false end/);
  });
});
