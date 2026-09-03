import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { TOWER_TOP, BANDS, towerFloor, specForLevel, PALETTES } from '../src/world/tower.js';

const supply = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');
const core = readFileSync(join(__dirname, '../src/tools/core.ts'), 'utf8');

/**
 * WHICH FLOOR IS QUEUED MATTERS -- ONE SUBSTRING WAS THREE BUGS.
 *
 * keepTowerOrdered asked `n.startsWith('tower-')`: is ANY tower work queued. Patches left over from
 * a floor already advanced past therefore counted as work on the current floor, and all three
 * consequences fired at once. Measured live: 39 `tower-L0` patches outstanding with towerLevel at 2.
 *
 *   1. Ordering waits for an empty queue. The leftovers never left it, so levels 1 and 2 were never
 *      ordered at all and the fleet had no tower work to do.
 *   2. startWatchingFloor opened a batch for level 2 on the strength of level 0's leftovers, so a
 *      floor nobody had ordered was being timed for completion.
 *   3. It duly "completed", because a floor that was never ordered places nothing -- and NOTHING
 *      REVISITS A LEVEL. The counter climbed 0 -> 1 -> 2 through floors that do not exist.
 *
 * The queue is the authority on what the fleet is working on; the counter is a pointer into it.
 */
describe('the tower counter cannot outrun the queue', () => {
  /** Scoped per named function, so a future split fails HERE rather than quietly ceasing to cover
   *  anything -- the disarmed-guard failure this repo keeps having. */
  const slice = (name: string) => {
    const i = supply.indexOf(`function ${name}`);
    if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  };
  /** CODE ONLY -- the comments quote the banned substring to record what it cost. */
  const codeOf = (s: string) =>
    s.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');

  it('judges queued work per level, not per prefix', () => {
    const part = codeOf(slice('towerWorkFor'));
    expect(part).toMatch(/at\(n\) === p_Level/);       // "this floor's work"
    expect(part).toMatch(/at\(n\) !== p_Level/);        // "any floor we are not building"
    // the level-blind test must be gone from the decision itself
    expect(codeOf(slice('keepTowerOrdered')))
      .not.toMatch(/stillQueued = \[\.\.\.queued\]\.some\(\(n\) => n\.startsWith\('tower-'\)\)/);
  });

  it('clears leftovers from a floor it has moved past', () => {
    expect(codeOf(slice('keepTowerOrdered'))).toMatch(/stale\.length/);
    expect(codeOf(slice('clearStaleFloors'))).toMatch(/stopTasksNamed\(`tower-L\$\{l\}-`\)/);
  });

  /**
   * taskLevel must actually parse the names order.tower produces. Asserted against the real format
   * rather than a hand-written sample, because a guard that agrees only with its own fixture is the
   * disarmed-check failure this repo keeps having.
   */
  it('parses the level out of the names order.tower actually issues', () => {
    expect(core).toMatch(/tower-L\$\{[^}]*\}-p/);                  // the name template still matches
    const m = /function taskLevel[\s\S]*?exec\(p_Name\)/.exec(supply);
    expect(m).toBeTruthy();
    const re = /\/\^tower-L\(\\d\+\)-\//;
    expect(supply).toMatch(re);
  });
});

/**
 * A DESIGN WITH NO TOP IS A LOOP WITH NO FINISH LINE.
 *
 * bandFor falls back to the topmost band for any level above it, so towerFloor(99) returns a
 * perfectly valid cap floor and nothing in the geometry ever says "finished". The supply loop
 * advances whenever a floor stops producing, so it would have ordered cap floors into the sky for
 * as long as the settlement had bricks.
 */
describe('the tower design has a top', () => {
  it('tops out at the highest band', () => {
    expect(TOWER_TOP).toBe(Math.max(...BANDS.map((b) => b.to)));
  });

  /** The fallback that made the top necessary is still there -- so the guard is still load-bearing. */
  it('still yields blocks above the top, which is why the guard exists', () => {
    const blocks = towerFloor(specForLevel(TOWER_TOP + 5), TOWER_TOP + 5, PALETTES.brick);
    expect(blocks.length).toBeGreaterThan(0);
  });

  it('stops the loop above it', () => {
    const i = supply.indexOf('async function keepTowerOrdered');
    const fn = supply.slice(i, supply.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/level > TOWER_TOP/);
  });

  /** The loop's own state must be readable, or its failures are all silent by construction. */
  it('reports the tower in supply.status', () => {
    const i = core.indexOf("name: 'supply.status'");
    const tool = core.slice(i, core.indexOf('\n});', i));
    expect(tool).toMatch(/level: supply\.towerLevel/);
    expect(tool).toMatch(/top: TOWER_TOP/);
    expect(tool).toMatch(/batch: supply\.towerBatch/);
  });
});

/**
 * THE COUNTER CAN GO DOWN, AND THE CLEANUP HAS TO COPE WITH THAT.
 *
 * The leftover filter tested `taskLevel(n) < level`, on the unexamined assumption that the counter
 * only ever rises. It does not: supply.set accepts a towerLevel precisely so a tower that skipped
 * floors can be told to rebuild them, and advancing is otherwise irreversible.
 *
 * Measured the moment that control was first used. The counter had run away to 3 with nothing
 * built, was reset to 0 to rebuild levels 1 and 2 -- and level 3's 236 patches instantly became work
 * for a floor nobody was building. Ordering waits for an empty tower queue, so they blocked level 0
 * exactly as thoroughly as the below-level leftovers had blocked levels 1 and 2, and the filter
 * written for that very bug could not see them because they sat on the other side of the comparison.
 */
describe('leftovers are cleared in both directions', () => {
  const fn = (() => {
    const i = supply.indexOf('function towerWorkFor');
    if (i < 0) throw new Error('towerWorkFor is gone -- move this assertion, do not delete it');
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  })();
  const code = fn.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');

  it('counts work for any floor that is not the current one as a leftover', () => {
    expect(code).toMatch(/at\(n\) !== p_Level/);
    expect(code).not.toMatch(/at\(n\) < p_Level/);   // one-directional, and it missed half the cases
  });

  /** The operator control that makes downward movement possible, and therefore makes this needed. */
  it('the counter is correctable, which is why both directions matter', () => {
    const i = core.indexOf("name: 'supply.set'");
    const tool = core.slice(i, core.indexOf('\n});', i));
    expect(tool).toMatch(/towerLevel: z\.number\(\)/);
    expect(tool).toMatch(/supply\.towerBatch = undefined/);   // a batch belongs to its own floor
  });
});
