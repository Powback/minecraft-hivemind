import { describe, it, expect } from 'vitest';
import { settlement, withinReach, withinRadio } from '../src/world/settlement.js';

describe('the radio horizon is three-dimensional', () => {
  it('accepts ore under the base and refuses a seam deep at the edge of the reach circle', () => {
    const { base, reach } = settlement;
    expect(withinRadio({ x: base.x + 20, y: base.y - 50, z: base.z })).toBe(true);
    const edge = { x: base.x - reach, y: base.y - 35, z: base.z };   // west: the basement repeater sits east
    expect(withinReach(edge)).toBe(true);
    expect(withinRadio(edge)).toBe(false);
  });
});
