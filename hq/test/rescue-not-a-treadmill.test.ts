import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const taskman = readFileSync(join(__dirname, '../../lua/TaskMan.lua'), 'utf8');

/**
 * RESCUING COSTS FUEL AND RETURNS NONE, SO THE CAPS CANNOT BE CONSTANTS.
 *
 * Two miner rescues plus three others is five concurrent rescues on a seven-drone fleet. With fuel
 * to spare that is a good trade. With fuel scarce it is a treadmill, and the settlement rode it
 * into the ground -- measured from the drone logs at the bottom:
 *
 *     JOB Relieve x9,  JOB Gather x1
 *
 * Nine tenths of the fleet's labour spent rescuing itself, every run thrashing through the bay (a
 * quarter of every drone log is "no progress toward"), rescuers stranding themselves, and each
 * newly stranded drone queueing another rescue. 192 coal -- fifteen thousand fuel, hand-fed into
 * storage -- was converted into rescue miles inside fifteen minutes, and the fleet came out flat
 * again with nothing mined and nothing felled. No income can outrun that.
 *
 * While fuel is short the budget goes to income instead. One miner rescue is still allowed, because
 * freeing a miner adds a drone that can mine and fell; freeing anything else does not.
 */
describe('rescue capacity yields to income when fuel is short', () => {
  // The decision moved into rescueBudget when rescueNeeded went over the complexity gate. Following
  // it rather than deleting it: a guard that stops covering its subject is this repo's oldest bug.
  const slice = (name: string) => {
    const i = taskman.indexOf(`local function ${name}`);
    if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
    return taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
  };
  const fn = slice('rescueBudget') + slice('rescueNeeded');
  /** CODE ONLY -- the comment quotes the old constants to record what they cost. */
  const code = fn.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');

  it('scales the caps on the fuel the settlement actually holds', () => {
    expect(code).toMatch(/storageFuelCount\(\) or 0\) < FUEL_COMFORTABLE/);
    expect(code).toMatch(/return 1, 0/);            // fuel short: income first
  });

  it('keeps one miner rescue, because a freed miner earns fuel back', () => {
    const m = /return 1, (\d)/.exec(code);
    expect(m).toBeTruthy();
    expect(Number(m![1])).toBe(0);       // a freed scout does not mine
  });

  it('no longer compares against hardcoded caps', () => {
    expect(code).toMatch(/s_LiveMiner >= s_CapMiner/);
    expect(code).toMatch(/s_LiveOther >= s_CapOther/);
    expect(code).not.toMatch(/s_LiveMiner >= 2\b/);
    expect(code).not.toMatch(/s_LiveOther >= 3\b/);
  });

  /** The parked drones must still be told why -- silence here is what made this invisible. */
  it('parked drones are still reported', () => {
    expect(taskman).toMatch(/is dry but storage has no fuel to bring it/);
  });
});
