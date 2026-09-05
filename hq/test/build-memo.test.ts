import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * THE RESUME MEMO RECORDS COORDINATES CONFIRMED BUILT, NOT COORDINATES VISITED.
 *
 * It used to be marked on arrival, one line after the travel succeeded. Since builds abort
 * routinely, that permanently retired the coordinates of every block nobody ever placed -- and a
 * memo hit increments neither counter, so the job then reported the tell-tale
 * `built 0 of 48 blocks (0 skipped)` while the floor stayed empty.
 */
describe('the build memo only remembers blocks that were placed', () => {
  const loop = drone.slice(drone.indexOf('local s_Placed, s_Skipped = 0, 0'),
                           drone.indexOf('Deposit()          -- leftovers'));

  it('marks exactly where a block went down, and nowhere else', () => {
    const marks = loop.split('\n').filter((l) => l.includes('s_BuildDone.mark('));
    expect(marks.length).toBe(3);   // place-on-air, already-correct, replace-wrong-block
    for (const after of loop.split('s_BuildDone.mark(s_BK)').slice(1)) {
      expect(after.slice(0, 120)).toMatch(/s_Placed = s_Placed \+ 1/);
    }
  });
});
