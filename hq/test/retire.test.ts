/**
 * fleet.retire RETURNED ok:true AND RETIRED NOTHING.
 *
 * It called DroneMan.RetireDrone, which correctly deleted the drone from the in-world registry --
 * and HQ keeps its OWN Map of drones, which had upsertDrone and no way to remove anything. So the
 * drone stayed in fleet.status for ever and every consumer went on planning around it.
 *
 * Live: five drones destroyed in the world (absent from `computercraft dump` while their chunks
 * were force-loaded). fleet.retire reported five successes; all five were still on the roster
 * afterwards, still generating rescues aimed at their last known positions -- and rescues preempt
 * real work, so a handful of casualties occupied the drones that still functioned.
 *
 * CLAUDE.md had already recorded this exact trap -- "fleet.retire (HQ still listed the drone)" --
 * and it was left as a note instead of a fix, which is how it cost the fleet a second time.
 */
import { describe, it, expect } from 'vitest';
import { HiveState } from '../src/world/state.js';

describe('a retired drone leaves HQ state', () => {
  it('removes the drone from the roster', () => {
    const s = new HiveState();
    s.upsertDrone({ id: 49, name: 'D6' });
    s.upsertDrone({ id: 52, name: 'D9' });
    expect(s.listDrones().map((d) => d.id).sort()).toEqual([49, 52]);
    expect(s.retireDrone(49)).toBe(true);
    expect(s.listDrones().map((d) => d.id)).toEqual([52]);
  });

  it('reports whether anything was actually removed, so ok is not a lie', () => {
    const s = new HiveState();
    s.upsertDrone({ id: 49, name: 'D6' });
    expect(s.retireDrone(49)).toBe(true);
    expect(s.retireDrone(49)).toBe(false);   // already gone
    expect(s.retireDrone(999)).toBe(false);  // never existed
  });

  /**
   * The drone must not quietly come back. It re-registers only on a genuine heartbeat, which is
   * the documented behaviour: "if it ever heartbeats again it re-registers from scratch".
   */
  it('stays gone until it speaks for itself', () => {
    const s = new HiveState();
    s.upsertDrone({ id: 49, name: 'D6', fuel: 15993 });
    s.retireDrone(49);
    expect(s.listDrones()).toEqual([]);
    s.upsertDrone({ id: 49, name: 'D6' });          // a real heartbeat arrives
    expect(s.listDrones().map((d) => d.id)).toEqual([49]);
    expect(s.listDrones()[0].fuel).toBe(0);              // from scratch, not the stale 15,993
  });
});
