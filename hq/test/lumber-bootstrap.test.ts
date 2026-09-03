import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { standingTrees, chooseSweep } from '../src/world/lumber.js';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * THE RENEWABLE RESOURCE MAY NEVER BE GATED BEHIND A MANUFACTURED GOOD.
 *
 * EnsureCacheChest fetched a chest with a minimum of one before a lumber job could run. Chests are
 * crafted from planks, planks from logs, and logs come from the lumber job being blocked -- so once
 * the settlement ran out of spare chests, wood became permanently unobtainable, and with it
 * charcoal and therefore all fuel. Nothing inside the game can break that cycle; it emptied the
 * larder and stranded drones at zero fuel.
 *
 *   kit: 85 blocks from the nearest deposit point -- taking a chest for a cache
 *   chest: nothing matching is in there
 *   fetch: storage holds none of it -- not flying 8 chest(s) to confirm that
 *   Aborting (was executing: true)
 *
 * The cache is a convenience: without it the drone carries its load home, which is slower and not
 * impossible. Slower is always acceptable; deadlocked never is.
 */
describe('gathering wood cannot depend on having a chest', () => {
  const fn = (() => {
    const i = drone.indexOf('local function fetchCacheChestOptional()');
    return drone.slice(i, drone.indexOf('\nend\n', i) + 5);
  })();

  it('the cache-chest fetch is wrapped so it cannot fail the job', () => {
    expect(fn).toMatch(/pcall\(FetchItems/);
    // no path returns failure to a caller -- the "optional" is structural, not a comment
    expect(fn).not.toMatch(/return\s+(false|nil)\b/);
  });

  it('EnsureCacheChest calls only the optional form', () => {
    const i = drone.indexOf('function EnsureCacheChest(p_Job)');
    const body = drone.slice(i, drone.indexOf('\nend\n', i) + 5);
    expect(body).toMatch(/fetchCacheChestOptional\(\)/);
    // a bare FetchItems here would reinstate the hard requirement
    expect(body).not.toMatch(/[^l]FetchItems\(/);
  });
});

/**
 * A SITE SCORE MUST COUNT THE GROUND THE DRONE ACTUALLY WALKS.
 *
 * densestStart counted every trunk within +/-SWEEP of a candidate -- a 17x17 box, 289 cells. The
 * sweep is `Serpentine(SWEEP, SWEEP)`: an 8x8 block, 64 cells, anchored where the drone lands and
 * oriented by whatever heading it has. So the score was taken over four and a half times the ground
 * the drone covers, and only one quadrant of that could ever be visited.
 *
 * Measured: `oak_log: 8/128 -> lumber sweep at -495,65,19 (32 trunks in range)` produced
 * `felled 1 tree(s), 9 log(s)`. Nothing failed. The drone walked its 64 cells and met one tree,
 * exactly as instructed -- the picker had scored a neighbourhood and sent it to a corner of it.
 *
 * This matters more than a bad number: wood is the settlement's only renewable fuel, and a sweep
 * that returns nine logs does not pay for the fuel it burned getting there.
 */
describe('the lumber site score matches the sweep', () => {
  const src = readFileSync(join(__dirname, '../src/world/lumber.ts'), 'utf8');
  // The window moved into columnsNear when the score changed from counting blocks to counting
  // columns. Following it rather than deleting it: a guard that stops covering its subject is this
  // repo's most persistent failure.
  const fn = (() => {
    const i = src.indexOf('function columnsNear');
    if (i < 0) throw new Error('columnsNear is gone -- move this assertion, do not delete it');
    return src.slice(i, src.indexOf('\n}\n', i) + 3);
  })();

  it('scores a window that fits inside the walked block', () => {
    expect(fn).toMatch(/HALF_SWEEP/);
    // CODE ONLY -- the comment above quotes the old bound to record what it cost.
    const code = fn.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');
    expect(code).not.toMatch(/<= SWEEP &&/);
  });

  /** The window must be derived from SWEEP, not a second number that can drift from it. */
  it('derives the window from the sweep size', () => {
    expect(src).toMatch(/const HALF_SWEEP = Math\.floor\(SWEEP \/ 2\)/);
  });
});

/**
 * A TREE IS A COLUMN, AND THE MAP RECORDS EVERY BLOCK IN IT.
 *
 * The site score counted map hits, so one oak eight blocks tall scored eight. Verified against the
 * world rather than assumed: of five recorded oak_log positions, four were really there (so the map
 * was NOT stale) and two of them -- `-477,67,11` and `-477,70,11` -- were the same tree.
 *
 * That is how a site advertised as "32 trunks in range" returns `felled 1 tree(s), 9 log(s)` with
 * nothing having failed: nine logs IS that tree. And the count picks the site, so one tall tree
 * outscored a stand of short ones and the drone was sent to the least productive ground available --
 * burning a round trip for one tree, for the settlement's only renewable fuel.
 */
describe('the lumber site counts trees, not log blocks', () => {
  const src = readFileSync(join(__dirname, '../src/world/lumber.ts'), 'utf8');

  it('scores distinct trunk columns', () => {
    const i = src.indexOf('function columnsNear');
    if (i < 0) throw new Error('columnsNear is gone -- move this assertion, do not delete it');
    const fn = src.slice(i, src.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/new Set<string>\(\)/);
    expect(fn).toMatch(/seen\.add\(`\$\{o\.x\},\$\{o\.z\}`\)/);   // x,z only -- y is the same tree
  });

  it('the picker uses it', () => {
    const i = src.indexOf('function densestStart');
    const fn = src.slice(i, src.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/columnsNear\(p_All, h\)/);
    // the raw block count is what inflated the score
    const code = fn.split('\n').filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*')).join('\n');
    expect(code).not.toMatch(/\)\.length;/);
  });
});

/**
 * THE SWEEP MUST WALK AT TRUNK HEIGHT.
 *
 * The map records every log in a column, so the best-scoring record is as likely to be a canopy log
 * as a trunk one -- and the sweep walks at the altitude it is handed. RunJobNow arrives at
 * `pos.y + 1`, so a start taken from a log at y=71 puts the drone at y=72, above the canopy, where
 * `turtle.inspect()` looks forward into open air for all sixty-four cells.
 *
 * That is the failure CLAUDE.md already records for gathers -- "approaching vertically wrote off the
 * entire forest" -- and it explains a sweep that walks its whole grid over trunks VERIFIED present
 * in the world (four of five spot-checked against rcon) and reports `felled 0 tree(s), 0 log(s)`
 * with nothing having failed.
 */
describe('the lumber sweep starts at the foot of the tree', () => {
  const src = readFileSync(join(__dirname, '../src/world/lumber.ts'), 'utf8');

  // Lowest foot in the WINDOW, not just the chosen column: the sweep looks forward and up, so a
  // trunk whose base sits below the plane is passed over through its canopy. Measured: the densest
  // column's foot was 67, the next column's base was at 65 and read as "felled 0".
  it('picks the plane that intersects the most standing columns in the window', () => {
    const w = src.indexOf('function columnsInWindow');
    if (w < 0) throw new Error('columnsInWindow is gone -- move this assertion, do not delete it');
    const win = src.slice(w, src.indexOf('\n}\n', w) + 3);
    expect(win).toMatch(/Math\.abs\(o\.x - p_At\.x\) > HALF_SWEEP \|\| Math\.abs\(o\.z - p_At\.z\) > HALF_SWEEP/);
    const i = src.indexOf('function lowestFootNear');
    if (i < 0) throw new Error('lowestFootNear is gone -- move this assertion, do not delete it');
    const fn = src.slice(i, src.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/columnsInWindow\(p_All, p_At\)/);
    // forward sees y, overhead sees y+1: a column counts if its logs include either
    expect(fn).toMatch(/c\.lo <= y \+ 1 && c\.hi >= y/);
    expect(fn).toMatch(/if \(n > bestN\)/);                          // most columns wins; ties to the lowest
  });

  it('the start it returns uses that height', () => {
    const i = src.indexOf('function densestStart');
    const fn = src.slice(i, src.indexOf('\n}\n', i) + 3);
    expect(fn).toMatch(/y: lowestFootNear\(p_All, best\)/);
  });
});

/**
 * A LOG IS NOT A TREE, AND THE INDEX FILLS UP WITH THE DIFFERENCE.
 *
 * THIS IS THE ROOT CAUSE OF THE FUEL DEATH. Felling leaves the canopy behind and the map keeps every
 * log it has ever seen, so each harvest ADDS single floating logs with nothing beneath them. Nothing
 * removes them, so the share of un-fellable targets rises with every tree cut: the better the fleet
 * works, the worse its next target gets.
 *
 * Measured on the settlement that died of it -- 200 recorded oak logs, 101 distinct columns:
 * 63 columns one log tall, 11 two, and only 27 with three or more. And the last sweep before the
 * fuel ran out was sent to `-505,71,30`, verified against the world as a single log with six blocks
 * of air under it. The drone arrives at `pos.y + 1`, so it swept open sky and honestly reported
 * `felled 0 tree(s), 0 log(s)`.
 *
 * Wood income went to zero while every sweep completed successfully, the charcoal line starved, and
 * the fleet burned its reserve to nothing. Spot-checking the index against the world earlier said it
 * was "80% accurate" -- those blocks ARE there. Being present and being a tree are different
 * questions, and checking the first is what made this look healthy.
 */
describe('lumber targets standing trees, not leftover canopy', () => {
  const src = readFileSync(join(__dirname, '../src/world/lumber.ts'), 'utf8');

  // A forest the picker can be handed: five columns of one leftover log each (felled trees whose
  // canopy stayed), and optionally one real trunk of four.
  const canopy = [-500, -496, -492, -488, -484].map((x) => ({ x, y: 70, z: 60, name: 'minecraft:oak_log' }));
  const trunk  = [64, 65, 66, 67].map((y) => ({ x: -490, y, z: 64, name: 'minecraft:oak_log' }));

  it('keeps only columns tall enough to be a tree', () => {
    expect(standingTrees(canopy)).toEqual([]);
    expect(standingTrees([...canopy, ...trunk])).toHaveLength(4);
  });

  it('the sweep is chosen from standing trees when any exist', () => {
    const pick = chooseSweep([...canopy, ...trunk], true);
    if ('reason' in pick) throw new Error(pick.reason);
    expect(pick.leftovers).toBe(false);
    expect(pick.targets).toEqual([{ x: -490, y: 64, z: 64 }]);
  });

  it('says why rather than dispatching a doomed sweep', () => {
    const pick = chooseSweep(canopy);
    expect('reason' in pick && pick.reason).toMatch(/no standing trees known -- 5 recorded log\(s\) are all leftover/);
  });

  /**
   * The fuel emergency of 2026-09-04: no standing tree inside the circle, 88 leftover logs in it,
   * shelf at zero. Leftovers are wood. The picker takes them when told the fleet is out of fuel,
   * and only then.
   */
  it('harvests leftover canopy when the fleet is out of fuel, and says so', () => {
    const pick = chooseSweep(canopy, true);
    if ('reason' in pick) throw new Error(pick.reason);
    expect(pick.leftovers).toBe(true);
    expect(pick.targets.length).toBeGreaterThanOrEqual(2);     // several leftovers per trip, not one
    for (const t of pick.targets) expect(t.y).toBe(70);
  });

  it('the threshold separates the measured populations', () => {
    const measured = { 1: 63, 2: 11, 3: 9, 4: 10, 5: 2, 6: 4, 7: 2 };
    const kept = Object.entries(measured).filter(([h]) => Number(h) >= 3)
      .reduce((n, [, c]) => n + c, 0);
    const dropped = Object.entries(measured).filter(([h]) => Number(h) < 3)
      .reduce((n, [, c]) => n + c, 0);
    expect(dropped).toBe(74);   // the leftovers that were poisoning every pick
    expect(kept).toBe(27);      // real trees still available to the fleet
  });
});
