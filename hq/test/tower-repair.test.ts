/**
 * FINISHED FLOORS ARE REPAIRED, NOT FORGOTTEN.
 *
 * Drones on their way somewhere dug through floor 0 of the tower until it was "swiss cheese" (the
 * user's words, 2026-09-04), and nothing ever ordered those squares again: the level counter only
 * moved up. These tests run the repair pass against a fake registry: a finished level with holes
 * gets exactly one order per interval, a level with its own patches queued is left alone, and a
 * patch for a lower level is a repair, not a stale leftover to be cleared.
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { registry } from '../src/tools/registry.js';
import { repairLowerFloors, supply, towerWorkFor } from '../src/agent/supply.js';

afterEach(() => vi.restoreAllMocks());

describe('repairLowerFloors', () => {
  it('re-orders a finished level that has holes and reports how many patches it queued', async () => {
    supply.towerLevel = 2;
    const invoke = vi.spyOn(registry, 'invoke').mockImplementation(async (name, args: any) => {
      expect(name).toBe('order.tower');
      return { ok: true, data: { tasks: args.level === 0 ? [{ id: 1 }, { id: 2 }] : [] } } as any;
    });
    const res = await repairLowerFloors(new Set(['tower-L2-3']));
    expect(res).toEqual({ acted: true, reason: 'repair: level 0 had holes -- 2 patch(es) re-ordered' });
    expect(invoke).toHaveBeenCalledTimes(1);
    expect((invoke.mock.calls[0][1] as any).level).toBe(0);
  });

  it('leaves a level alone while its own patches are still queued, and does not re-check within the interval', async () => {
    supply.towerLevel = 2;
    const invoke = vi.spyOn(registry, 'invoke').mockResolvedValue({ ok: true, data: { tasks: [] } } as any);
    // level 0 was checked by the test above moments ago; level 1 has a repair patch of its own queued
    const res = await repairLowerFloors(new Set(['tower-L1-0', 'tower-L2-3']));
    expect(res).toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });
});

describe('towerWorkFor', () => {
  it('counts a lower level\'s patch as a repair, and only a higher level\'s as stale', () => {
    const queued = new Set(['tower-L0-4', 'tower-L2-1', 'tower-L3-0']);
    const at2 = towerWorkFor(queued, 2);
    expect(at2.stillQueued).toBe(true);
    expect(at2.stale).toEqual(['tower-L3-0']);
  });
});
