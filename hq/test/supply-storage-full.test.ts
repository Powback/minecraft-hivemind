/**
 * DO NOT MINE INTO A WAREHOUSE WITH NO ROOM IN IT.
 *
 * Storage sat at 0 free slots across 7 chests and 13,856 items, and the supply loop kept
 * dispatching gathers anyway -- including for DIRT, which has a rule of its own. The drones did
 * exactly as told: filled up, flew home, failed to deposit because there was no slot, retried, and
 * ran dry holding the load.
 *
 * Measured over one window: 221 coal burned, ZERO items deposited.
 *
 * The cost was not just wasted trips. Two drones were found stranded at 0 fuel carrying 170 and 274
 * items of dirt, gravel and cobblestone -- and one of them was the fleet's ONLY crafter, the drone
 * that builds the chests that would have made room. The loop was starving the cure to feed the
 * disease.
 */
import { describe, it, expect } from 'vitest';
import { ruleSkipReason, type SupplyRule } from '../src/agent/supply.js';

const gate = (over: Partial<Parameters<typeof ruleSkipReason>[1]>) => ({
  fuelCritical: false, have: 0, cooldownUntil: 0, now: 1_000_000, ...over,
});
const skip = (match: string, over: any) =>
  ruleSkipReason({ match, min: 32, action: 'gather' } as SupplyRule, gate(over));

describe('a full warehouse stops the digging', () => {
  it('skips dirt when there is no free slot', () => {
    expect(skip('dirt', { storageFull: true })?.kind).toBe('full');
  });

  it('skips ore too -- raw copper needs a slot just like dirt does', () => {
    expect(skip('copper_ore', { storageFull: true })?.kind).toBe('full');
  });

  /**
   * Coal is BURNED, not shelved. It is also what a drone needs to reach a chest at all, so a full
   * warehouse is no reason to stop fetching it -- and stopping would strand the fleet exactly when
   * it needs to be able to move to fix the problem.
   */
  it('never stops the chain that makes more shelf: logs, planks, chests', () => {
    expect(skip('oak_log', { storageFull: true })).toBeNull();
    expect(skip('minecraft:oak_planks', { storageFull: true })).toBeNull();
    expect(skip('minecraft:chest', { storageFull: true })).toBeNull();
    expect(skip('minecraft:stone_bricks', { storageFull: true })?.kind).toBe('full');
  });

  it('never stops fetching fuel, however full the warehouse', () => {
    expect(skip('coal_ore', { storageFull: true })).toBe(null);
    expect(skip('charcoal', { storageFull: true })).toBe(null);
  });

  it('says why, so a quiet fleet is not mistaken for a broken one', () => {
    expect(skip('dirt', { storageFull: true })?.message).toMatch(/no free slot/);
  });

  it('does nothing when there is room', () => {
    expect(skip('dirt', { storageFull: false })).toBe(null);
  });

  /**
   * An UNKNOWN is not a FULL. If StorageMan cannot be asked, the honest reading is "I do not know",
   * and halting the fleet on a failed status call would turn one unreachable module into a total
   * work stoppage -- the same class of bug as counting lost drones' fuel as available.
   */
  it('treats an unreadable storage as unknown, not as full', () => {
    expect(skip('dirt', { storageFull: undefined })).toBe(null);
  });

  it('fuel priority still wins when both apply', () => {
    expect(skip('dirt', { storageFull: true, fuelCritical: true })?.kind).toBe('fuel');
  });
});
