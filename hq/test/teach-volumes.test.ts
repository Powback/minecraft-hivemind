import { describe, it, expect } from 'vitest';
import { registry } from '../src/tools/registry.js';
import '../src/tools/core.js';

/**
 * Locks the teach-example volumes in place.
 *
 * A teach example is compiled into the priming transcript the agent boots with, so a volume in an
 * example that disagrees with the bounds the example passes is a lesson that is subtly wrong. The
 * model imitates the number, not the formula, and then produces plausible-looking but inconsistent
 * region reports.
 *
 * THIS FILE ALSO IS THE LESSON. It was written as a top-level `node:assert` script at
 * `src/tools/core.test.ts`, which vitest cannot collect -- so `hq/vitest.config.ts` listed it under
 * `exclude`, and running from the repo root reported it as a FAIL ("No test suite found") that was
 * read as pre-existing noise and left alone. Between those two facts the check never ran anywhere,
 * in either place, for its entire life: a guard that cannot fail, which CLAUDE.md names as the
 * failure mode worse than no guard at all. Converted to the runner everything else uses, so it can.
 */
const volumeOf = (min: { x: number; y: number; z: number }, max: { x: number; y: number; z: number }) =>
  (max.x - min.x + 1) * (max.y - min.y + 1) * (max.z - min.z + 1);

/** Teach examples carry bounds two ways: `args.bounds` (order.issue) and top-level
 *  `args.min`/`args.max` (world.query). Resolve both. */
function boundsOf(args: unknown) {
  if (typeof args !== 'object' || args === null) return null;
  const a = args as Record<string, any>;
  if (a.bounds && typeof a.bounds === 'object') return a.bounds as { min: any; max: any };
  if (a.min && a.max) return { min: a.min, max: a.max };
  return null;
}

describe('teach examples state volumes their own bounds imply', () => {
  const tools = registry.list();

  it('registers tools at all', () => {
    expect(tools.length).toBeGreaterThan(0);
  });

  /** Collected rather than asserted inline so one wrong example names itself instead of aborting
   *  the sweep at the first failure. */
  const wrong: string[] = [];
  let checks = 0;
  for (const tool of tools) {
    for (const ex of tool.teach ?? []) {
      const bounds = boundsOf(ex.args);
      const r = ex.result as Record<string, unknown> | null;
      if (!bounds || typeof r !== 'object' || r === null) continue;
      const expected = volumeOf(bounds.min, bounds.max);

      if ('volume' in r) {
        checks++;
        if (r.volume !== expected) wrong.push(`${tool.name}: result.volume ${r.volume}, bounds imply ${expected}`);
      }
      const m = typeof r.error === 'string' ? /Region is (\d+) blocks/.exec(r.error) : null;
      if (m) {
        checks++;
        if (Number(m[1]) !== expected) wrong.push(`${tool.name}: error says ${m[1]}, bounds imply ${expected}`);
      }
    }
  }

  it('has every teach example agree with its bounds', () => {
    expect(wrong).toEqual([]);
  });

  /**
   * THE CANARY. Every assertion above is driven by whatever the registry happens to contain, so if
   * the teach examples were renamed, restructured or dropped the sweep would pass by examining
   * nothing -- the exact way this repo's guards have gone quiet before. This fails if the sweep
   * stops finding work to do.
   */
  it('actually examined some examples', () => {
    expect(checks).toBeGreaterThanOrEqual(3);
  });

  /** The three examples this test exists to lock in, named so a regression is obvious. */
  it('keeps the three worked examples exact', () => {
    expect(volumeOf({ x: 120, y: 64, z: -50 }, { x: 129, y: 68, z: -41 })).toBe(500);        // 10x5x10 pad
    expect(volumeOf({ x: 0, y: 0, z: 0 }, { x: 200, y: 60, z: 200 })).toBe(2464461);         // 201x61x201 quarry
    expect(volumeOf({ x: 100, y: 60, z: -60 }, { x: 130, y: 90, z: -30 })).toBe(29791);      // 31x31x31 region
  });
});
