import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const supply = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');
const core = readFileSync(join(__dirname, '../src/tools/core.ts'), 'utf8');
const stock = readFileSync(join(__dirname, '../src/world/stock.ts'), 'utf8');

/**
 * A FLOOR IS FINISHED WHEN WORKING IT STOPS CHANGING THE WORLD.
 *
 * The first attempt decided this by asking the world map what was still missing, and it could not
 * be made to work -- not because the code was wrong but because the question was. The map remembers
 * blocks that were mined, does not know the atrium is meant to stay open, and has no idea the
 * settlement's own module row sits inside the tower footprint at z=76 where no floor block can ever
 * go. Every fix was another exception for another legitimately-unbuildable square, and the map
 * lookups themselves timed out under load and silently returned "not built", which made the tool
 * queue MORE work than before the filter existed (235 patches, up from 185).
 *
 * The second attempt read storage and treated a drop in floor material as blocks placed. Also
 * wrong, and for the same class of reason -- it measured something CORRELATED with placing rather
 * than placing itself. Measured: 79 units gone from the shelves with 66 of them sitting in drone
 * inventories, carried out to squares that were already occupied and carried straight back.
 *
 * The drones have always known the true figure: OnBuild returns `placed`, the drone sends it in
 * `result`, and TaskMan stored it on the task and threw it away when the task was purged. It now
 * keeps a running total, and this is the only number that answers "has anything been built".
 * That is the effect, and CLAUDE.md has one rule about effects.
 */
describe('the tower advances on effect, not on the map', () => {
  /**
   * ASSERTIONS FOLLOW THE CODE THEY GUARD.
   *
   * These used to read keepTowerOrdered's source and look for the whole decision inside it. The
   * decision was later split into batchPlacedNothing and advanceFloor -- a good change -- and the
   * assertions silently stopped covering anything, because a source-text match against the wrong
   * function just fails to find its needle. Scoped per named function so a future split fails
   * loudly at the assertion instead of quietly at the thing it was protecting.
   */
  const slice = (name: string) => {
    const i = supply.indexOf(`function ${name}`);
    if (i < 0) throw new Error(`${name} no longer exists -- move this assertion, do not delete it`);
    return supply.slice(i, supply.indexOf('\n}\n', i) + 3);
  };
  const fn = slice('keepTowerOrdered');
  const batch = slice('batchPlacedNothing');
  const advance = slice('advanceFloor');
  /** The ordering tail moved out of keepTowerOrdered when it went over the complexity limit; the
   *  batch is recorded there now. slice() throws if it moves again. */
  const order = slice('orderAndRecord');

  /**
   * BLOCKS PLACED, NOT MATERIAL THAT LEFT THE SHELVES.
   *
   * This used to read storage and treat a drop as "blocks were placed". It is not the same thing,
   * and the difference stalled the tower: 79 units gone from storage with 66 of them sitting in
   * drone inventories, carried out to squares that were already occupied and carried back. Material
   * moves for crafting, hauling and carrying; only placing puts it in the world.
   */
  it('measures blocks actually placed, before and after a batch', () => {
    expect(fn).toMatch(/blocksPlacedTotal\(\)/);
    expect(fn).not.toMatch(/floorMaterialHeld\(\)/);
    // `at` too: "consumed nothing" and "has not started" are the same reading from a material
    // count alone, so the batch carries when it was queued and is only judged after a grace period.
    expect(order).toMatch(/supply\.towerBatch = \{ level, held: bricks, at: Date\.now\(\) \}/);
  });

  it('advances the level when a batch consumed nothing', () => {
    // placed counts only rise, so progress is now-minus-then
    expect(batch).toMatch(/p_Held - last\.held < FLOOR_PROGRESS_MIN/);
    expect(advance).toMatch(/supply\.towerLevel = p_Level \+ 1/);
  });

  /**
   * An unreadable stock is not zero progress -- it is an unknown, and must not advance the floor.
   *
   * The null guard moved into world/stock.ts when the six copies of the stock read were folded into
   * one. This follows it rather than being deleted: a check that stops covering the thing it was
   * written for is the failure this repo keeps having, so it now asserts the guard at its new home
   * AND that floorMaterialHeld does not quietly coerce the null back to a number on the way out.
   */
  it('never advances on a reading it could not take', () => {
    expect(batch).toMatch(/p_Held === null \|\| last\.held === null/);
    expect(stock).toMatch(/if \(!detail\) return null/);
    // slice() throws if the function is gone -- indexOf(-1) would silently assert on the whole
    // file and pass, which is the disarmed-guard failure this suite is here to prevent.
    const placed = slice('blocksPlacedTotal');
    expect(placed).toMatch(/return null/);                  // unreadable is an unknown...
    expect(placed).not.toMatch(/\?\?\s*0|\|\|\s*0/);        // ...never quietly a zero
  });

  /** order.tower stays a dumb, fast queueing tool -- the judgement lives in one place. */
  it('order.tower does not try to second-guess the world', () => {
    expect(core).not.toMatch(/const alreadyThere =/);
    expect(core).not.toMatch(/const laidAt = new Set/);
  });
});
