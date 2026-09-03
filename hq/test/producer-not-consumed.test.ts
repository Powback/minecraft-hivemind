import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const taskman = readFileSync(join(__dirname, '../../lua/TaskMan.lua'), 'utf8');

/**
 * WORK THAT CONSUMES A MATERIAL MUST NOT TAKE THE DRONE THAT PRODUCES IT.
 *
 * This settlement has exactly one crafter. `anyoneForBuild` is the fallback that lets a build run on
 * a non-miner when no miner is free -- correct, since placing a block needs no special hardware --
 * and it tried "crafter" FIRST. So the crafter was the first drone taken for building.
 *
 * Measured on the ground floor, with the tower unable to rise for hours:
 *
 *   295 tower patches, every one asking for minecraft:stone_bricks
 *   storage: 0 stone_bricks, 77 cobblestone
 *   drone:   JOB Build THREW ran out of minecraft:stone_bricks partway through
 *   drone:   fetch: storage holds none of it -- not flying 11 chest(s) to confirm that
 *   TaskMan: craft-stone_bricks could not be placed: no free crafter, on every pass
 *
 * The crafter was laying blocks for the patches that were short of the bricks it was the only drone
 * able to make. The tower could not advance BECAUSE it was being built.
 *
 * This is the third time this shape has appeared here -- the fuel emergency filter banning
 * `gather:oak_log`, and fuel relief preempting the coal gather that would have ended the shortage
 * are the other two. Hence a check rather than only a fix.
 */
describe('a build never consumes the drone the build depends on', () => {
  const fn = (() => {
    const i = taskman.indexOf('local function anyoneForBuild');
    if (i < 0) throw new Error('anyoneForBuild is gone -- move this assertion, do not delete it');
    return taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
  })();

  it('offers the crafter last, not first', () => {
    expect(fn).toMatch(/\{"loader", "scout", "crafter"\}/);
    // CODE ONLY -- the comment above quotes the banned order to record what it cost.
    const code = fn.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
    expect(code).not.toMatch(/\{"crafter", "loader", "scout"\}/);
  });

  it('does not offer the crafter at all while crafting is waiting', () => {
    expect(fn).toMatch(/alt ~= "crafter" or not craftIsWaiting\(\)/);
  });

  /**
   * The predicate must mean "queued and nobody is on it". Counting assigned craft work would keep
   * the crafter off building for as long as it was crafting, which is the opposite of the point.
   */
  it('counts only craft work nobody has picked up', () => {
    const i = taskman.indexOf('local function craftIsWaiting');
    if (i < 0) throw new Error('craftIsWaiting is gone -- move this assertion, do not delete it');
    const pred = taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
    expect(pred).toMatch(/t\.work\.craft/);
    expect(pred).toMatch(/t\.assignedTo == nil/);
    expect(pred).toMatch(/taskLive\(t\)/);       // finished and disabled tasks are not waiting
  });
});
