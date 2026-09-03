import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * AN INTERRUPTED JOB IS NOT A COMPLETED ONE -- CHECKED ONCE, FOR EVERY VERB.
 *
 * Every job loop in DroneLogic breaks on `not executing`; that is how a stand-down, a reassignment
 * and a task.stop stop work. An aborted body therefore falls out of its loop and returns whatever
 * it accumulated, which reaches RunJobNow looking exactly like success -- so TaskMan marks the task
 * 100% done and never gives it to anybody again.
 *
 * This was found and patched TWICE in one day, in Build and in Lumber, before it was clear they
 * were one defect:
 *
 *   built 0 of 48 blocks (0 skipped)   <- placed + skipped = 0 against a total of 48
 *   JOB Lumber done                    <- logged four lines after "Aborting"
 *
 * Craft, Gather, Dig, Haul and Relieve had the same hole and were never looked at. The guard
 * belongs to the job protocol, not to any verb: put it anywhere else and the next verb reintroduces
 * it. This test exists to stop that.
 */
describe('the job protocol refuses to call an interrupted job done', () => {
  const run = (() => {
    const i = drone.indexOf('local function RunJobNow(');
    return drone.slice(i, drone.indexOf('\n-- The w x l boustrophedon', i));
  })();

  it('checks `executing` before reporting done, at the choke point', () => {
    const guard = run.indexOf('if not executing then');
    const done = run.indexOf('JOB %s done');
    expect(guard).toBeGreaterThan(-1);
    expect(guard).toBeLessThan(done);   // the guard must come FIRST or it cannot stop anything
  });

  it('returns the task to the queue rather than finishing it', () => {
    const g = run.slice(run.indexOf('if not executing then'));
    expect(g.slice(0, 300)).toMatch(/finish\(false,/);
  });

  /**
   * The per-verb patches are deliberately gone. Two copies of one rule is how the fleet ended up
   * with three different answers to "what counts as fuel" -- see CLAUDE.md.
   */
  it('does not re-grow per-verb copies of the same check', () => {
    expect(drone).not.toMatch(/assertFinished|assertDidSomething/);
  });
});
