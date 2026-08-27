/**
 * KARMA: is a drone actually achieving anything, or only saying so?
 *
 * Every expensive failure in this system has been a drone whose self-report was sincere and wrong.
 * One walked 121 blocks in the WRONG direction while logging that it was closing the gap on home.
 * Four sat "assigned" to tasks they were not performing, wedging both the task and the drone. One
 * reported idle for five hours and twelve minutes from outside the loaded region, holding 475
 * items. Reading `status` could not distinguish any of them from real progress.
 *
 * Movement and deliveries are OBSERVATIONS -- HiveState records them by diffing successive reports,
 * so they cannot be faked by a drone that is confused about itself.
 */
import { describe, it, expect } from 'vitest';
import { HiveState, type Drone } from '../src/world/state.js';

const NOW = 1_800_000_000_000;
const MIN = 60_000;
const drone = (over: Partial<Drone>): Drone => ({
  id: 1, name: 'D1', role: 'miner', fuel: 1000, status: 'working', ...over,
});

describe('karma', () => {
  it('a working drone that moved recently is healthy', () => {
    expect(HiveState.karma(drone({ lastMovedAt: NOW - MIN }), NOW).healthy).toBe(true);
  });

  it('a working drone that has neither moved nor delivered for ten minutes is not', () => {
    const k = HiveState.karma(drone({ lastMovedAt: NOW - 10 * MIN }), NOW);
    expect(k.healthy).toBe(false);
    expect(k.why).toMatch(/has not moved or delivered/);
  });

  it('delivering counts even when standing still', () => {
    // A crafter parked on a chest is the intended case: it never moves and is doing the single
    // most valuable thing in the settlement.
    const k = HiveState.karma(
      drone({ lastMovedAt: NOW - 30 * MIN, lastDeliveredAt: NOW - MIN }), NOW);
    expect(k.healthy).toBe(true);
  });

  it('an idle drone that is not moving is honest, not unhealthy', () => {
    // Idle and still is a correct, self-consistent state. Flagging it would bury the drones that
    // are genuinely lying under a dozen behaving exactly as intended.
    expect(HiveState.karma(drone({ status: 'idle', lastMovedAt: NOW - 60 * MIN }), NOW).healthy)
      .toBe(true);
  });

  it('a drone never observed doing anything is not accused', () => {
    // Nothing to judge on yet. 'lost' already covers a drone that has never spoken, and accusing
    // one that simply has no history yet would fire on every drone at boot.
    expect(HiveState.karma(drone({}), NOW).healthy).toBe(true);
  });

  it('hauling and docking are claims too, so they are held to the same test', () => {
    for (const status of ['hauling', 'docking'] as const) {
      expect(HiveState.karma(drone({ status, lastMovedAt: NOW - 20 * MIN }), NOW).healthy)
        .toBe(false);
    }
  });

  it('the threshold is a floor, not a target', () => {
    const at = NOW - HiveState.KARMA_STALL_MS;
    expect(HiveState.karma(drone({ lastMovedAt: at }), NOW).healthy).toBe(true);
    expect(HiveState.karma(drone({ lastMovedAt: at - 1 }), NOW).healthy).toBe(false);
  });
});
