import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const supply = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');

/**
 * THE SETTLEMENT MUST NOT WAIT TO BE TOLD.
 *
 * Two things only ever happened because a human ran a tool:
 *
 *  - factory.create files a line as `planned`; only factory.attach makes it `running`. Nobody ever
 *    ran the second step, so planks-01 and charcoal-01 -- the lines that make the planks everything
 *    is built from and the charcoal everything is fuelled with -- sat `planned` indefinitely while
 *    the fleet hand-crafted planks and ran out of fuel doing it.
 *  - nothing queued tower work. A human ran order.tower, the patches drained, and the fleet went
 *    idle in front of an empty queue.
 *
 * Both now live in the supply loop, which already runs on a timer.
 */
describe('the supply loop runs the settlement without a human', () => {
  it('brings planned factories online and keeps the tower ordered', () => {
    const fn = supply.slice(supply.indexOf('async function maintenancePhases'));
    const body = fn.slice(0, fn.indexOf('\n}\n') + 3);
    expect(body).toMatch(/bringFactoriesOnline\(\)/);
    expect(body).toMatch(/runFactories\(queued\)/);
    expect(body).toMatch(/keepTowerOrdered\(live, queued\)/);
  });

  /**
   * A FACTORY THAT PRODUCES NOTHING IS A LABEL, NOT A FACTORY.
   *
   * `running` was set by attaching chests and nothing ever walked a running line to move material
   * through it -- factory.route returned {}, links were empty, and planks and charcoal were in fact
   * made by ordinary craft tasks and StorageMan's furnaces, entirely outside the subsystem meant to
   * own them. Reporting those factories "live" on the strength of the status field was exactly the
   * success-without-effect defect this repo keeps hitting.
   */
  it('a running factory actually drives production', () => {
    const i = supply.indexOf('async function runFactories');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/status === 'running'/);
    expect(fn).toMatch(/plan\.execute/);          // reuse the recipe graph, do not re-implement it
    expect(fn).toMatch(/FACTORY_TARGET/);
  });

  /**
   * Maintenance must sit ABOVE the gather rules. Those return early almost every tick on a busy
   * fleet -- the storage-expansion rule was buried under two of them and effectively never ran,
   * with storage at 0 free slots and ten drones idle.
   */
  it('runs maintenance before the rules that return early', () => {
    const tick = supply.slice(supply.indexOf('export async function runSupplyTick'));
    const maint = tick.indexOf('maintenancePhases(live, queued)');
    const idleBail = tick.indexOf("'no idle miner, scout or crafter'");
    expect(maint).toBeGreaterThan(-1);
    expect(maint).toBeLessThan(idleBail);
  });

  /**
   * Ordering on a TIMER is what a monitor did earlier: it re-queued the whole floor every three
   * minutes, churning the queue and cancelling work already in flight. Order only when the queue
   * has nothing of this floor left -- a fact, not a guess.
   */
  /**
   * A FLOOR IS FINISHED WHEN ITS OWN WORK IS DONE -- NOT WHEN THE FLEET STOPS BEING ABLE TO WORK.
   *
   * This previously asserted the opposite: that completion must be judged WITHOUT an empty queue,
   * because order.tower queues patches for squares already laid and the queue therefore never
   * drains. The first half was right and the conclusion was wrong. No-op patches do drain -- the
   * drone refuses the block and the task completes -- and the queue that "never emptied" was held
   * open by the level-blindness bug in tower-level-scope.test.ts, not by no-ops. Measured at level
   * 0: 131 patches, 67 of them already completed.
   *
   * What "the batch placed nothing" cannot distinguish is the case that actually happened, twice in
   * one night: the counter walked 0 -> 1 -> 2 with placedTotal stuck at 1 -- three drones at zero
   * fuel, the only crafter dry, not one block laid anywhere -- and every step was recorded as a
   * finished floor. A fleet that cannot work places nothing, exactly like a floor that is complete,
   * and NOTHING EVER REVISITS A LEVEL. The cost of guessing wrong is not symmetric: a stalled tower
   * is visible and fixes itself when the fuel arrives; a skipped floor is a permanent hole.
   */
  it('advances only when the floor\'s own patches have drained', () => {
    const i = supply.indexOf('async function keepTowerOrdered');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/floorIsFinished\(level, bricks\) && unfinished === 0/);
    expect(fn).toMatch(/if \(stillQueued\) return null/);   // ordering still waits for an empty queue
    expect(fn).toMatch(/advanceFloor\(level,/);

    // ...and it says so when it declines to advance, rather than stalling in silence
    expect(fn).toMatch(/waiting rather than advancing past a floor the fleet has /);
  });

  /**
   * The count must come from TaskMan, not from the queue snapshot. GetTasks returns at most 40
   * tasks; an undercount here either orders a 295-patch floor twice or skips it permanently.
   */
  it('counts outstanding patches where they are, not in a 40-task window', () => {
    const i = supply.indexOf('async function outstandingFor');
    if (i < 0) throw new Error('outstandingFor is gone -- move this assertion, do not delete it');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/task\.countNamed/);
    // an uncountable queue is an unknown, and an unknown must not read as "nothing outstanding"
    expect(fn).toMatch(/return null/);
    const tower = supply.slice(supply.indexOf('async function keepTowerOrdered'));
    expect(tower.slice(0, tower.indexOf('\n}\n') + 3))
      .toMatch(/counted === null/);
  });

  /**
   * "Consumed nothing" and "has not started yet" are the same reading from a material count, so a
   * fresh batch would otherwise be declared a finished floor the instant it was queued.
   */
  it('gives a batch time to consume before judging it finished', () => {
    const i = supply.indexOf('function batchHasHadLongEnough');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/if \(at === undefined\) return false/);  // no timestamp: cannot judge
    expect(fn).toMatch(/BATCH_GRACE_MS/);
  });

  /**
   * ADVANCING PAST A FLOOR IS IRREVERSIBLE -- NOTHING EVER REVISITS A LEVEL ONCE THE COUNTER PASSES
   * IT. So it may only happen on a real answer, never on a failure or an unknown.
   *
   * Both traps were live in the first version: `order.tower` was called with `.catch(() => null)`,
   * so any failure -- MapServer slow, storage unreadable -- read as "no tasks" and skipped the floor
   * PERMANENTLY; and the material comparison would have treated an unreadable stock as "consumed
   * nothing" and advanced on a storage hiccup.
   */
  it('never advances a floor on a failure or an unknown', () => {
    const i = supply.indexOf('function batchPlacedNothing');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    // an unreadable stock is an UNKNOWN, and must not read as "nothing was consumed"
    expect(fn).toMatch(/p_Held === null \|\| last\.held === null/);
    expect(fn).not.toMatch(/\?\?\s*0/);                     // no coercing the null back to a number

    // The ordering tail lives in orderAndRecord since keepTowerOrdered went over the complexity
    // limit. Both are checked: the swallow must not reappear in EITHER, and the loud report has to
    // exist wherever the ordering actually happens.
    const bodyOf = (name: string) => {
      const i = supply.indexOf(`function ${name}`);
      if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
      return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    };
    // CODE ONLY. The comment above these functions quotes the very pattern being banned, to record
    // what it cost -- asserting against the raw text matches the prose and fails on a correct file.
    // Exactly the trap that made an earlier guard match `turtle.placeDown()` inside its own comment.
    for (const name of ['keepTowerOrdered', 'orderAndRecord']) {
      const code = bodyOf(name).split('\n')
        .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');
      expect(code).not.toMatch(/\.catch\(\(\)\s*=>\s*null\)/); // the swallow that skipped a floor
    }
    expect(bodyOf('orderAndRecord')).toMatch(/level NOT advanced/);   // says so, loudly, on failure
  });
});
