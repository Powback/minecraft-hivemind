import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const gps = readFileSync(join(__dirname, '../../lua/PowGPSServer.lua'), 'utf8');

/**
 * THE WORLD MAP HAD NO WORKING WAY TO FORGET, AND THAT IS WHAT KILLED THE SETTLEMENT.
 *
 * `mergeCachedWorldDetail` only ever ADDS keys, and the scanner reports only NON-AIR blocks -- so a
 * cell that once held a block keeps it for ever. The single mechanism meant to counter that is
 * `ClearAged`, which iterates `aged`; and the only code that ever inserts into `aged` sat behind
 * two bugs on consecutive lines:
 *
 *     if(type(v[2]) == table) then                                -- `table` is the LIBRARY.
 *         if(v[2].name == "...Advanced" or "...Turtle") then      -- `(a == x) or "y"` -- truthy.
 *
 * The outer test compares a string to a table and is false for every value, so the branch never
 * ran, `aged` was permanently empty, and ClearAged permanently cleared nothing.
 *
 * The consequence compounds with use: every tree the fleet fells stays indexed at full height, so
 * the share of the map that is fiction RISES with every harvest. The lumber picker takes the
 * densest cluster, which is therefore a grove cut down hours ago -- verified against the world, the
 * chosen site -530,69,55 had three logs recorded and none present. Sweeps flew to ghosts, felled
 * nothing, reported success; wood went to zero, charcoal starved, and the fleet burned down to a
 * fuel trap it could not leave, with every job completing normally the whole way.
 */
describe('the map can record that something is gone', () => {
  const fn = (() => {
    const i = gps.indexOf('local function mergeCachedWorldDetail');
    if (i < 0) throw new Error('mergeCachedWorldDetail is gone -- move this assertion, do not delete it');
    return gps.slice(i, gps.indexOf('\nend\n', i) + 5);
  })();
  /** CODE ONLY -- the comment quotes both bugs verbatim to record what they cost. */
  const code = fn.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');

  it('compares against the type NAME, not the table library', () => {
    expect(code).toMatch(/type\(v\[2\]\) == "table"/);
    expect(code).not.toMatch(/type\(v\[2\]\) == table\b/);
  });

  it('compares the name against each option, not `x or "y"`', () => {
    expect(code).toMatch(/n == "ComputerCraft:CC-TurtleAdvanced" or n == "ComputerCraft:CC-Turtle"/);
    expect(code).not.toMatch(/\.name == "[^"]*" or "[^"]*"/);
  });

  /** The insert is the only feed for the only removal path; if it goes, nothing forgets at all. */
  it('still feeds the one mechanism that removes records', () => {
    expect(code).toMatch(/table\.insert\(aged,/);
    expect(gps).toMatch(/function ClearAged\(\)/);
    expect(gps).toMatch(/cachedWorld\[k\] = nil/);
  });
});

/**
 * A CLEAR AND AN ADD ARE NOT THE SAME RISK.
 *
 * THIS IS THE ROOT CAUSE OF THE SETTLEMENT'S DEATH BY FUEL.
 *
 * `noteObservation` refused to file anything while the drone's position was unverified. That is
 * right for ADDING -- a solid block filed at a fictional coordinate is a wall the pathfinder routes
 * around for as long as the map survives on disk, and nothing ever contradicts it.
 *
 * Removing is the opposite in every respect. `solid == 0` is the ONLY way a cell is ever taken out
 * of the map: IndexOccupancy turns it into `ObserveBlock(key, nil)`, the single removal path in the
 * system. And a wrong removal is self-healing -- the block is still there, so the next drone past
 * re-observes it. A suppressed removal is permanent, because nothing re-observes air.
 *
 *   wrong ADD, suppressed     -> costs a re-scan
 *   wrong CLEAR, allowed      -> costs a re-scan
 *   correct CLEAR, suppressed -> the stale block is in the map FOR EVER
 *
 * Losing a fix while working is normal, and felling a tree is exactly when a drone is doing it. So
 * every tree the fleet cut stayed indexed at full height; the share of the map that was fiction rose
 * with every harvest; the lumber picker chose the densest cluster of trees that no longer existed.
 * Verified against the world: the chosen site -530,69,55 had three logs recorded and none present.
 * Sweeps flew to ghosts, felled nothing and reported success -- wood to zero, charcoal starved, the
 * fleet burned its last fuel with every job completing normally the whole way down.
 */
describe('a drone may always report that a cell is empty', () => {
  // pgps.lua is the DRONE-side library; PowGPSServer.lua is the server's. noteObservation is the
  // drone's gate, and pointing this at the wrong file is how a guard silently covers nothing.
  const pgps = readFileSync(join(__dirname, '../../lua/pgps.lua'), 'utf8');
  const fn = (() => {
    const i = pgps.indexOf('function noteObservation');
    if (i < 0) throw new Error('noteObservation is gone -- move this assertion, do not delete it');
    return pgps.slice(i, pgps.indexOf('\nend\n', i) + 5);
  })();

  it('gates adds on a verified position, but never clears', () => {
    expect(fn).toMatch(/if not positionVerified\(\) and solid ~= 0 then/);
  });

  it('still suppresses -- and counts -- an unverified add', () => {
    expect(fn).toMatch(/m_Suppressed = m_Suppressed \+ 1/);
    expect(fn).toMatch(/return false/);
  });

  /** The clear path this unblocks is the only removal path there is; if it goes, ghosts return. */
  it('the removal path it feeds still exists end to end', () => {
    const drone = pgps;
    expect(drone).toMatch(/cachedWorld\[idx\] = 0/);          // noteCleared marks it air locally
    expect(drone).toMatch(/noteObservation\(idx, 0\)/);       // ...and reports it
    const map = readFileSync(join(__dirname, '../../lua/MapServer.lua'), 'utf8');
    expect(map).toMatch(/if v == 0 and m_BlockAt and m_BlockAt\[key\] then/);
    expect(map).toMatch(/ObserveBlock\(key, nil\)/);          // ...which removes it from the index
  });
});
