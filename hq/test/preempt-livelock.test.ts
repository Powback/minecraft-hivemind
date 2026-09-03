import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const tm = readFileSync(join(__dirname, '../../lua/TaskMan.lua'), 'utf8');

/**
 * ONE PREEMPT PER BLOCKER, THEN WAIT FOR IT TO LAND.
 *
 * placeBlockers frees a working drone when a task other work depends on cannot be placed, then
 * returns with "place it on the next tick, once the drone is idle". It kept no record of having
 * done so, so if the blocker still was not placeable next tick -- the freed drone still winding
 * down, or the ordinary placement loop having already taken it -- it preempted somebody else, and
 * again the tick after.
 *
 * That livelock is what stopped the tower. Every in-flight job was collateral: builds died seconds
 * after starting, for hours, and the floor never gained a block, while TaskMan logged nothing worse
 * than a routine-looking interrupt.
 */
describe('blocker preemption cannot storm the fleet', () => {
  it('records who was freed and for which blocker', () => {
    expect(tm).toMatch(/m_PreemptedFor\[tostring\(v\.id\)\] = \{drone = s_Best\.id, at = os\.epoch\("utc"\)\}/);
  });

  it('refuses a second preempt for the same blocker inside the grace window', () => {
    const fn = tm.slice(tm.indexOf('local function preemptedRecently'));
    const body = fn.slice(0, fn.indexOf('\nend\n') + 5);
    expect(body).toMatch(/PREEMPT_GRACE_MS/);
    expect(body).toMatch(/return true/);
  });

  it('gates the interrupt on that check, not on a bare candidate test', () => {
    expect(tm).toMatch(/if mayPreemptFor\(s_Best, v\.id\) then/);
    const before = tm.slice(0, tm.indexOf('interrupting %s on %s'));
    expect(before).toMatch(/local function mayPreemptFor/);   // declared above use: nil-global trap
  });

  /** The grace must outlast a drone shutdown plus one placement pass, or the storm returns. */
  it('uses a grace long enough to matter', () => {
    const ms = Number(tm.match(/PREEMPT_GRACE_MS = (\d+)/)?.[1] ?? 0);
    expect(ms).toBeGreaterThanOrEqual(15000);
  });
});
