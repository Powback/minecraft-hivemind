import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const drone = readFileSync(join(__dirname, '../../lua/DroneLogic.lua'), 'utf8');

/**
 * A ONE-BLOCK STEP MUST NOT QUEUE BEHIND A PATHFINDER.
 *
 * moveTo and digTo are the same A* request to MapServer; the difference is only whether digging is
 * allowed. So every leg -- including a two-block hop between consecutive blocks of a build patch --
 * queued behind a search over 200k+ cells shared by the whole fleet. When that search is starved the
 * leg fails and OnBuild counts the block SKIPPED.
 *
 * Measured with the build instrumentation:
 *   build:  8/32 blocks (4 placed,  4 skipped) in  89s
 *   build: 16/32 blocks (5 placed, 11 skipped) in 232s
 *
 * Two thirds skipped, on squares verified by rcon (against a known-good control) to be plain AIR.
 * Nothing was in the way -- the drone never got a route.
 */
describe('adjacent moves bypass the pathfinder', () => {
  it('tries a direct step before any A* call', () => {
    const fn = drone.slice(drone.indexOf('function TravelTo(p_X, p_Y, p_Z, p_Ceiling)'));
    const body = fn.slice(0, fn.indexOf('\nend\n') + 5);
    const direct = body.indexOf('stepStraightTo(p_X, p_Y, p_Z)');
    const astar = body.indexOf('pgps.digTo(p_X, p_Y, p_Z)');
    expect(direct).toBeGreaterThan(-1);
    expect(direct).toBeLessThan(astar);      // order is the whole point
  });

  it('walks the axes and gives up, rather than climbing over obstacles like the old flyTo', () => {
    const i = drone.indexOf('local function stepStraightTo');
    const fn = drone.slice(i, drone.indexOf('\nend\n', i) + 5);
    expect(fn).toMatch(/for _ = 1, 12 do/);   // bounded: it is not a search
    expect(fn).toMatch(/return false/);
    expect(fn).not.toMatch(/moveTo|digTo/);   // no network call on this path
  });

  it('only applies to genuinely adjacent targets', () => {
    expect(drone).toMatch(/local STRAIGHT_HOP = [1-5]\b/);
    expect(drone).toMatch(/s_D <= STRAIGHT_HOP and stepStraightTo/);
  });
});
