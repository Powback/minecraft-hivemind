/**
 * THE CAVE INDEX OUTLIVED THE REGION IT WAS BUILT IN.
 *
 * `world.caves` reads the block index, which still holds pockets found when the operating area was
 * a larger square. `surveyCaves` queued a survey for every one of them and sent the scout to
 * `cave.min` -- without ever asking whether that point is inside the circle the fleet may work in.
 *
 * Six such tasks were found live, targeting points 75-78 blocks out against a reach of 56. Each was
 * permanently "could not reach the survey start", re-dispatched for ever, spending a scout and its
 * fuel on a trip that could not finish. Two had been retrying since task #2919, and new ones were
 * still being created -- so this was not old debris, it was an open tap.
 *
 * settlement.ts states the rule and place.ts obeys it. This path simply never asked.
 */
import { describe, it, expect } from 'vitest';
import { withinReach, settlement } from '../src/world/settlement.js';

describe('cave surveys stay inside the operating circle', () => {
  const base = settlement.base;

  it('rejects the exact points that were stuck in the queue', () => {
    // Names taken verbatim from the live queue: cave--530,10,4 and cave--525,-1,4.
    expect(withinReach({ x: -530, z: 4 })).toBe(false);
    expect(withinReach({ x: -525, z: 4 })).toBe(false);
  });

  it('accepts a cave next to base', () => {
    expect(withinReach({ x: base.x + 4, z: base.z + 4 })).toBe(true);
  });

  /**
   * The circle, not the box. The box's corners sit half again as far out as its edges, which is how
   * two drones were permanently lost in them.
   */
  it('measures a circle, so the corner of the bounding box is out', () => {
    const r = settlement.reach;
    expect(withinReach({ x: base.x + r, z: base.z })).toBe(true);          // on the edge
    expect(withinReach({ x: base.x + r, z: base.z + r })).toBe(false);     // the corner
  });

  it('the guard is actually applied where caves are queued', async () => {
    const src = await import('node:fs').then((fs) =>
      fs.readFileSync(new URL('../src/agent/supply.ts', import.meta.url), 'utf8'));
    const fn = src.slice(src.indexOf('async function surveyCaves'));
    const body = fn.slice(0, fn.indexOf('\n}\n'));
    // It must consult the guard BEFORE it adds the task -- checking afterwards costs the dispatch.
    const guardAt = body.indexOf('withinReach');
    const addAt = body.indexOf("'Add'");
    expect(guardAt, 'surveyCaves does not call withinReach at all').toBeGreaterThan(-1);
    expect(guardAt).toBeLessThan(addAt);
  });
});
