/**
 * Work targets must be inside the circle the fleet can call home from.
 *
 * The block index still holds positions surveyed when the region was a square, and the square's
 * corners are half again as far out as its edges -- past modem range. Seeding a job straight from
 * the index therefore dispatches drones to places they cannot be heard from: D3 was recovered from
 * -496,53,126, sixty-four blocks out, sent there by an ordinary gather. Two other drones were lost
 * to the same geometry before this existed.
 */
import { describe, it, expect } from 'vitest';
import { settlement, withinReach, bounds } from '../src/world/settlement.js';

describe('work targets vs the operating circle', () => {
  const { base, reach } = settlement;

  it('accepts the base itself', () => {
    expect(withinReach(base)).toBe(true);
  });

  it('accepts a point just inside the radius on each axis', () => {
    expect(withinReach({ x: base.x + reach - 1, z: base.z })).toBe(true);
    expect(withinReach({ x: base.x, z: base.z + reach - 1 })).toBe(true);
  });

  it('rejects the box CORNERS, which is the whole point', () => {
    const b = bounds();
    expect(withinReach({ x: b.minx, z: b.minz })).toBe(false);
    expect(withinReach({ x: b.maxx, z: b.maxz })).toBe(false);
  });

  it('rejects where D3 was actually found', () => {
    expect(withinReach({ x: -496, z: 126 })).toBe(false);
  });

  it('rejects where D1 and D2 were lost', () => {
    expect(withinReach({ x: -417, z: 176 })).toBe(false);   // D1
    expect(withinReach({ x: -534, z: 26 })).toBe(false);    // D2, a square corner
  });
});
