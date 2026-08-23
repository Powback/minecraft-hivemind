import { describe, it, expect } from 'vitest';
import { newRegistry, allocate, checkOrder, overlaps, contains, type Plot, type Registry } from './plots.js';

const BOUNDS = { min: { x: -155, y: 0, z: -105 }, max: { x: -25, y: 200, z: 15 } };
const fresh = (): Registry => newRegistry({ x: -85, y: 81, z: -44 }, BOUNDS);

const ok = (p: Plot | { error: string }): Plot => {
  if ('error' in p) throw new Error(p.error);
  return p;
};

describe('allocate', () => {
  it('keeps the first plot OFF the origin, because the origin is the tower', () => {
    // This used to assert the first plot lands exactly on the origin, which was true and became
    // wrong: the origin is the tower's centre column. Allocating there sited a mine head inside the
    // building and dispatched a miner to sink a shaft through its own floor -- which it could not
    // even reach, the target being one block beneath it and made of the slab it stood on.
    const reg = fresh();
    const p = ok(allocate(reg, 'docks'));
    expect(p.name).toBe('docks-01');
    expect(p.status).toBe('planned');

    const dx = p.min.x - (-85);
    const dz = p.min.z - (-44);
    expect(Math.sqrt(dx * dx + dz * dz)).toBeGreaterThanOrEqual(26);
  });

  it('never allocates two plots that touch', () => {
    const reg = fresh();
    const a = ok(allocate(reg, 'forestry'));
    const b = ok(allocate(reg, 'forestry'));
    expect(overlaps(a, b)).toBe(false);
    // And not merely non-overlapping -- separated, so a hauler can walk between them without
    // entering either.
    const touching = { min: { ...b.min, x: b.min.x - 1 }, max: { ...b.max, x: b.max.x + 1 } };
    expect(overlaps(a, touching)).toBe(false);
  });

  it('keeps every plot inside the operating bounds', () => {
    const reg = fresh();
    for (let i = 0; i < 25; i++) allocate(reg, 'farm');
    for (const p of reg.plots) expect(contains(BOUNDS, p)).toBe(true);
  });

  it('sizes plots by purpose rather than uniformly', () => {
    const reg = fresh();
    const forest = ok(allocate(reg, 'forestry'));
    const bench = ok(allocate(reg, 'crafting'));
    expect(forest.max.y - forest.min.y).toBeGreaterThan(bench.max.y - bench.min.y);
  });

  it('reports exhaustion instead of returning an out-of-bounds plot', () => {
    const tiny = newRegistry({ x: 0, y: 64, z: 0 }, { min: { x: 0, y: 64, z: 0 }, max: { x: 3, y: 68, z: 3 } });
    const r = allocate(tiny, 'forestry');
    expect('error' in r).toBe(true);
  });
});

describe('checkOrder', () => {
  it('allows a region wholly inside its own plot', () => {
    const reg = fresh();
    const p = ok(allocate(reg, 'storage'));
    expect(checkOrder(reg, p.name, { min: p.min, max: p.min })).toBeNull();
  });

  it('refuses a region that leaves its plot', () => {
    const reg = fresh();
    const p = ok(allocate(reg, 'storage'));
    const outside = { min: p.min, max: { ...p.max, x: p.max.x + 20 } };
    expect(checkOrder(reg, p.name, outside)).toMatch(/leaves plot/);
  });

  it('refuses a region that spans two plots — the D1 case', () => {
    // A build order sized from the wrong corner is exactly how a monitor wall was raised on top of
    // a drone. The order looks reasonable; only the registry can tell it is not.
    //
    // Containment is what catches this: since allocated plots never overlap, a region big enough
    // to reach plot B has necessarily already left plot A. The message names the first rule
    // broken, and the order is refused either way -- which is the whole point.
    const reg = fresh();
    const a = ok(allocate(reg, 'docks'));
    const b = ok(allocate(reg, 'storage'));
    const greedy = {
      min: { x: Math.min(a.min.x, b.min.x), y: a.min.y, z: Math.min(a.min.z, b.min.z) },
      max: { x: Math.max(a.max.x, b.max.x), y: a.max.y, z: Math.max(a.max.z, b.max.z) },
    };
    expect(checkOrder(reg, a.name, greedy)).not.toBeNull();
    expect(overlaps(b, greedy)).toBe(true);        // it really would have hit the other plot
  });

  it('refuses a region that hits a reservation nested inside its own plot', () => {
    // The other half of the rule, and the reachable one: a sub-area reserved INSIDE a plot -- a
    // furnace bench, a dock pad, anything already built there. The region is legitimately within
    // the plot, so only the overlap check can save it.
    const reg = fresh();
    const yard = ok(allocate(reg, 'farm'));
    reg.plots.push({
      name: 'reserved-bench', purpose: 'reserved',
      min: { x: yard.min.x + 2, y: yard.min.y, z: yard.min.z + 2 },
      max: { x: yard.min.x + 3, y: yard.min.y + 1, z: yard.min.z + 3 },
      ground: yard.ground, status: 'active',
    });
    const sweep = { min: yard.min, max: yard.max };
    expect(checkOrder(reg, yard.name, sweep)).toMatch(/enters plot reserved-bench/);
  });

  it('refuses an unknown plot rather than defaulting to permitted', () => {
    const reg = fresh();
    expect(checkOrder(reg, 'nowhere', { min: reg.origin, max: reg.origin })).toMatch(/no plot/);
  });
});
