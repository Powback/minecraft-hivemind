/**
 * The operating region is a square; modem range is a sphere. Its corners were a trap.
 *
 * Two drones were lost in them: legal to walk into, too far from the mast to reach StorageMan, so
 * they could not ask where to refuel and starved where they stood. D2's log is just
 * "refuel: storage would not give a point" every twenty seconds at -534,69,26.
 */
import { describe, it, expect } from 'vitest';
import { settlement, bounds } from '../src/world/settlement.js';

/**
 * The radio the drones must stay in range of. The modules sit on the ground-floor wall ring of the
 * tower, two blocks above its base, so the tower centre stands in for all of them -- derived from the
 * settlement, never a literal, or this test pins the fleet to whichever world it was written in.
 */
const MAST = { x: settlement.base.x, y: settlement.base.y + 2, z: settlement.base.z };
const MODEM_RANGE = 64;

const distToMast = (x: number, y: number, z: number) =>
  Math.hypot(x - MAST.x, y - MAST.y, z - MAST.z);

describe('operating region vs radio range', () => {
  it('the SQUARE corner is out of modem range -- the bug', () => {
    const b = bounds();
    expect(distToMast(b.minx, 64, b.minz)).toBeGreaterThan(MODEM_RANGE);
  });

  it('every point inside the reach CIRCLE is within modem range of the mast', () => {
    const { base, reach } = settlement;
    let worst = 0;
    for (let a = 0; a < 360; a += 5) {
      const x = base.x + reach * Math.cos((a * Math.PI) / 180);
      const z = base.z + reach * Math.sin((a * Math.PI) / 180);
      worst = Math.max(worst, distToMast(x, 63, z));   // ground level, the worst case
    }
    expect(worst).toBeLessThanOrEqual(MODEM_RANGE);
  });

  it('the circle is fully inside the force-loaded box, so the box still bounds chunks', () => {
    const b = bounds();
    const { base, reach } = settlement;
    expect(base.x - reach).toBeGreaterThanOrEqual(b.minx);
    expect(base.x + reach).toBeLessThanOrEqual(b.maxx);
    expect(base.z - reach).toBeGreaterThanOrEqual(b.minz);
    expect(base.z + reach).toBeLessThanOrEqual(b.maxz);
  });
});
