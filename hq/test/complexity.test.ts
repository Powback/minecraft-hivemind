import { describe, it, expect } from 'vitest';
// @ts-expect-error -- plain ESM script, no types, deliberately runnable standalone
import { scan, readBaseline, compare, MAX_COMPLEXITY } from '../scripts/complexity.mjs';

/**
 * CYCLOMATIC COMPLEXITY, RATCHETED.
 *
 * Complexity is a proxy here, not an aesthetic. Every serious outage in this repo has happened
 * inside the largest functions in it, and for the same reason each time: a branch that nobody --
 * including the person who wrote it -- had the whole of in their head.
 *
 *   rescueNeeded          CC 83   sent healthy drones to rescue each other; D14 tunnelled 36
 *                                 minutes toward a D9 that was working fine.
 *   DepositNow            CC 59   looped "depositing before parking" for four hours holding 515
 *                                 items and never once logged why, because the one branch that
 *                                 mattered was wrapped in a pcall that discarded the reason.
 *   OnStartTask           CC 50   dispatched ten duplicate `gather oak logs` tasks with no region.
 *   moveLeg / moveTo      CC 37   the pathfinding that walked drones into each other.
 *   supply.ts:275         CC 169  the planner.
 *
 * So the rule is CC 15 for anything new, and the existing debt is recorded in
 * complexity-baseline.json, which MAY ONLY SHRINK. Three things fail:
 *
 *   1. a file gaining a function over the threshold
 *   2. an existing over-threshold function getting worse
 *   3. the baseline claiming debt that has since been paid  <- this is the ratchet
 *
 * (3) is the part that matters. Without it, paying down one function quietly frees budget for the
 * next regression and the number never actually falls. Fixing something means `node
 * scripts/complexity.mjs --update` to record the REDUCTION -- never to record a rise.
 *
 * Splitting a function to satisfy this is only worth doing when the pieces are separately
 * meaningful. Shredding one long procedure into eight one-caller helpers moves the branches around
 * without making anything easier to hold, and it is a REFACTOR OF LIVE FLEET CODE -- which has its
 * own cost: deleting `moveTo` during exactly such a cleanup crashed every drone in the settlement.
 */
describe(`cyclomatic complexity (max ${MAX_COMPLEXITY})`, () => {
  const found = scan();
  const baseline = readBaseline();
  const { violations, stale } = compare(found, baseline);

  it('no file exceeds its recorded complexity debt', () => {
    const report = violations.map(
      (v: any) =>
        `${v.file}: ${v.message}\n` +
        v.worst.map((w: any) => `    CC ${w.cc}  ${w.file}:${w.line} ${w.name}`).join('\n'),
    );
    expect(report).toEqual([]);
  });

  it('the baseline records no debt that has already been paid', () => {
    const report = stale.map(
      (s: any) =>
        `${s.file}: baseline allows ${s.was} excess branches, only ${s.now} remain. ` +
        `Run \`node scripts/complexity.mjs --update\` to bank the win.`,
    );
    expect(report).toEqual([]);
  });

  it('reports the current total so the number is visible, not just enforced', () => {
    const excess = (ccs: number[]) =>
      ccs.reduce((n, cc) => n + Math.max(0, cc - MAX_COMPLEXITY), 0);
    const allowed = Object.values(baseline).reduce((n, f: any) => n + excess(f.cc), 0 as number);
    const actual = excess(found.map((f: any) => f.cc));
    expect(actual).toBeLessThanOrEqual(allowed as number);
  });
});
