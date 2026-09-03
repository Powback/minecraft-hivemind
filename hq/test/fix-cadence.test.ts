import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const pgps = readFileSync(join(__dirname, '../../lua/pgps.lua'), 'utf8');

/**
 * DRIFT IS BOUNDED BY HOW OFTEN WE ASK, AND ASKING IS FREE.
 *
 * Dead reckoning between GPS fixes is only as good as the heading, and a heading that is wrong by a
 * quarter turn -- which happens whenever a reboot restores a stale pose -- turns every move into
 * error. At sixteen moves per fix that is up to sixteen blocks of it. Measured live on D40 while it
 * carried bricks to a build:
 *
 *   cached: -462,69,65  (positionVerified = false)
 *   gps.locate: -467,65,78, returned in 0.0s
 *
 * Thirteen blocks out in z with a free fix available. Everything downstream failed on that number:
 * travel could not reach squares that were plainly air, pickups called empty columns blocked, and
 * builds skipped two thirds of their blocks rather than place on a position they could not trust.
 */
describe('position fixes are frequent enough to bound drift', () => {
  it('re-fixes every few moves, not every sixteen', () => {
    const n = Number(pgps.match(/local MOVES_PER_FIX\s*=\s*(\d+)/)?.[1] ?? 0);
    expect(n).toBeGreaterThan(0);
    expect(n).toBeLessThanOrEqual(4);
  });

  /** The reasoning is measured, not assumed -- keep it attached to the constant. */
  it('records why, so nobody raises it back on the old assumption', () => {
    const i = pgps.indexOf('local MOVES_PER_FIX');
    const note = pgps.slice(Math.max(0, i - 1400), i);
    expect(note).toMatch(/0\.0s|nought seconds/);
  });
});
