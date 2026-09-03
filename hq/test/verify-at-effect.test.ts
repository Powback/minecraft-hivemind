import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { scan } from '../scripts/verify-at-effect.mjs';

const SRC = join(__dirname, '../src/tools/core.ts');
const baseline = JSON.parse(readFileSync(join(__dirname, '../verify-baseline.json'), 'utf8'));

/**
 * THE #1 RECURRING DEFECT IN THIS PROJECT: SUCCESS REPORTED BY SOMETHING OTHER THAN THE EFFECT.
 *
 * One shape, ten instances in a single evening:
 *   redeploy.sh          said "redeploy ok" and shipped to no drone (17 of 20 ran stale code)
 *   OnBuild / OnLumber   returned a result table after being aborted; TaskMan marked them 100% done
 *   the resume memo      was written on ARRIVAL, so aborts retired blocks nobody placed
 *   noteObservation      filed bricks at coordinates that had none
 *   task.stop            returned ok:true for 25 tasks that kept running
 *   positionVerified()   answers "is the fix recent", not "is the position right"
 *
 * The individual bugs were cheap. What was expensive is that a false success CORRUPTS THE
 * DIAGNOSIS: you measure the proxy, believe it, and spend hours fixing something that was never
 * broken. CLAUDE.md has said "verify at the effect, never at the call" for a long time; saying it
 * did not stop it coming back, so this counts it instead.
 *
 * A mutating tool is verified when it carries a `// verify-at-effect:` note saying what it re-reads
 * after acting. The note is the mechanism -- it forces the author to answer the question.
 */
describe('mutating tools verify at the effect', () => {
  const found = scan(SRC);

  it('no NEW mutating tool ships without confirming its own effect', () => {
    const known = new Set(baseline.unverified);
    const fresh = found.unverified.filter((n: string) => !known.has(n));
    expect(fresh, `these mutating tools report success without re-reading anything.
Add a "// verify-at-effect: <what it re-reads>" note, or confirm the effect and say so.`).toEqual([]);
  });

  /** May fall, may not rise -- the same ratchet the complexity budget uses. */
  it('the debt only shrinks', () => {
    expect(found.unverified.length).toBeLessThanOrEqual(baseline.unverified.length);
  });

  it('reports the count so the number is visible, not just enforced', () => {
    console.log(`verify-at-effect: ${found.verified.length} verified, ${found.unverified.length} not`);
    expect(found.verified.length + found.unverified.length).toBeGreaterThan(0);
  });
});
