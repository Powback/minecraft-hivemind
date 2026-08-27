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

  it('still queues the patches at priority 1', () => {
    expect(tower).toMatch(/priority:\s*1/);
  });
});
