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

  /**
   * THIS CALLS THE REAL DECISION, not a re-implementation of it and not a grep over the source.
   * caveCandidates was extracted from surveyCaves precisely so this could import it.
   */
  it('filters the exact caves that were stuck in the queue', async () => {
    const { caveCandidates } = await import('../src/agent/supply.js');
    const near = { min: { x: base.x + 6, y: 40, z: base.z + 6 }, max: { x: base.x + 10, y: 44, z: base.z + 10 } };
    const far  = { min: { x: -530, y: 10, z: 4 }, max: { x: -520, y: 20, z: 14 } };
    const got = caveCandidates([far, near, { min: null, max: null }]);
    expect(got.map((g) => g.cave)).toEqual([near]);
  });

  it('pads the box outward -- a scan centred in a pocket reads air', async () => {
    const { caveCandidates } = await import('../src/agent/supply.js');
    const c = { min: { x: base.x, y: 30, z: base.z }, max: { x: base.x + 2, y: 32, z: base.z + 2 } };
    const [{ box }] = caveCandidates([c]);
    expect(box.min).toEqual({ x: base.x - 4, y: 26, z: base.z - 4 });
    expect(box.max).toEqual({ x: base.x + 6, y: 36, z: base.z + 6 });
  });

  it('never pads y below bedrock', async () => {
    const { caveCandidates } = await import('../src/agent/supply.js');
    const c = { min: { x: base.x, y: 2, z: base.z }, max: { x: base.x + 1, y: 4, z: base.z + 1 } };
    const [{ box }] = caveCandidates([c]);
    expect(box.min.y).toBe(0);
  });

  it('survives a null list rather than throwing inside the supply tick', async () => {
    const { caveCandidates } = await import('../src/agent/supply.js');
    expect(caveCandidates(null as any)).toEqual([]);
  });
});
