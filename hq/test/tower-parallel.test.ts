/**
 * THE TOWER WAS NEVER BUILT BECAUSE ITS TASKS WERE CHAINED.
 *
 * order.tower splits a floor into drone-load-sized patches. Those patches used to carry
 * `dependsOn: prev` -- "so the floor is laid in order rather than by whoever happens to be free".
 *
 * A flat floor laid out of order is indistinguishable from one laid in order. The chain bought
 * invisible tidiness at the price of the whole build. Observed live with SIX drones idle:
 *
 *   tower-L0-p01  running
 *   tower-L0-p02  running
 *   tower-L0-p03  blocked  waiting on tower-L0-p02
 *   ...           all eleven remaining blocked, each on the one before
 *
 * Two tasks can run regardless of how many drones are free, and when the head stalls -- dry drone,
 * rescue, lost link, all routine here -- everything behind it waits for ever. Cobblestone sat at
 * 10,864 and did not fall by one block in three minutes, which jams storage, which strands more
 * drones, which is the spiral this settlement has been in all along.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';

const src = readFileSync(new URL('../src/tools/core.ts', import.meta.url), 'utf8');
const towerRaw = (() => {
  const i = src.indexOf("name: 'order.tower'");
  return src.slice(i, src.indexOf("name: 'order.build'", i));
})();
/**
 * Comments stripped before matching. The fix's own comment QUOTES `dependsOn: prev` while
 * explaining why it was removed, so a naive search finds the string it is asserting the absence
 * of -- the test failed on the prose describing the fix rather than on any code. A guard that
 * cannot tell code from a comment about code is not a guard.
 */
const tower = towerRaw
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

describe('tower patches are independent', () => {
  it('does not chain patches of the same floor', () => {
    expect(tower).not.toMatch(/dependsOn:\s*prev/);
  });

  it('does not carry the `prev` cursor that only existed to chain them', () => {
    expect(tower).not.toMatch(/let\s+prev\b/);
  });

  /**
   * Guard the REASON, not just the symptom. Someone re-adding ordering "so it looks tidy" is
   * exactly how this comes back, so the explanation has to survive alongside the fix.
   */
  it('keeps the explanation next to the code', () => {
    expect(towerRaw).toMatch(/NOT CHAINED/);
    expect(towerRaw).toMatch(/independent/i);
  });

  /**
   * PRIORITY 2, AND THIS ASSERTION USED TO SAY 1.
   *
   * I wrote it expecting 1, because order.tower's comment argued the base should be built before
   * the fleet speculatively gathers ore. That is right about ORE and wrong about COAL, and the
   * queue cannot tell them apart -- 13 tower patches at priority 1 against one gather:coal_ore at
   * priority 1 means the tower takes every drone and the settlement stops mining the fuel the
   * tower burns.
   *
   * Measured directly, same fleet and conditions, back to back:
   *   tower OFF, 12 min: coal 489 -> 642, energy +14,476, rising at every sample
   *   tower ON,  12 min: coal frozen at 642, energy -5,442, cobblestone unmoved
   *
   * Work that CONSUMES fuel must never outrank the work that PRODUCES it -- the same inversion as
   * fuel relief preempting the coal gather it depended on.
   */
  /*
   * The blanket "no priority: 1 anywhere in this tool" above was the right lesson enforced in the
   * wrong place. order.tower now queues the CRAFT that feeds the patches as well as the patches
   * themselves, and that craft must sit one above the build it supplies -- otherwise the two
   * compete, the builds win, and drones are dispatched to place bricks that nothing is making.
   * Grepping the whole tool could not tell the two apart, so it failed on the fix.
   *
   * Assert the thing that actually matters: the tower PATCH is the task that must not outrank fuel.
   */
  it('queues the patches BELOW fuel work, at priority 2', () => {
    const patch = tower.slice(tower.indexOf('`tower-L${a.level}-p$'));
    expect(patch.slice(0, 300)).toMatch(/priority:\s*2/);
    expect(patch.slice(0, 300)).not.toMatch(/priority:\s*1\s*,/);
  });
});
