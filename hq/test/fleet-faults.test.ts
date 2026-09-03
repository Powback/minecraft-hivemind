import { describe, it, expect } from 'vitest';
import { fleetFaults } from '../src/tools/core.js';

/**
 * FLEET-LEVEL FAULTS ARE NOT THE SUM OF THE DRONE ONES.
 *
 * Every condition here was live on the night the settlement died, and every one was reported only
 * as a few ordinary per-drone lines that read like a busy afternoon. These are unit-tested against
 * constructed fleets rather than grepped out of the source, because the whole point is the
 * THRESHOLD behaviour -- when it fires and, just as importantly, when it stays quiet.
 */
const drone = (fuel: number, status = 'working', reported: string | null = null, order: unknown = null) =>
  ({ fuel, status, order, reported });

describe('fleet faults', () => {
  it('says nothing about a healthy fleet', () => {
    expect(fleetFaults([drone(2000), drone(1500), drone(900)], 3)).toEqual([]);
  });

  it('never reports on an empty fleet', () => {
    expect(fleetFaults([], 5)).toEqual([]);   // `every` on [] is true -- would fire on a fresh install
  });

  /** The unrecoverable state: nothing can mine, fell or smelt, and all three need a fuelled drone. */
  it('names the fuel trap when every drone is dry', () => {
    const f = fleetFaults([drone(0), drone(0), drone(0)], 0);
    expect(f[0]).toMatch(/FUEL TRAP: all 3 drones/);
    expect(f[0]).toMatch(/cannot recover on its own/);
    expect(f[0]).toMatch(/storage chest/);          // and how to get out of it
  });

  /**
   * The APPROACH is the part worth catching -- the trap is reached gradually and every step looks
   * like an ordinary bad day. Measured: three dry, then five, then seven, inside about an hour.
   */
  it('warns on the spiral before it becomes the trap', () => {
    const f = fleetFaults([drone(0), drone(0), drone(0), drone(500), drone(500), drone(500)], 0);
    expect(f[0]).toMatch(/FUEL SPIRAL: 3 of 6 drones are dry/);
    expect(f[0]).not.toMatch(/FUEL TRAP/);
  });

  it('does not cry spiral over one dry drone', () => {
    const f = fleetFaults([drone(0), drone(900), drone(900), drone(900), drone(900), drone(900)], 0);
    expect(f.join(' ')).not.toMatch(/FUEL SPIRAL/);
  });

  /**
   * Rescuing costs fuel and returns none. Measured at the bottom: nine Relieve jobs to one Gather,
   * and 192 hand-fed coal converted into rescue miles inside fifteen minutes.
   */
  it('names the rescue treadmill', () => {
    const f = fleetFaults([drone(900, 'hauling', 'relieve for D37'),
                           drone(900, 'working', 'relieve for D35'),
                           drone(900, 'working', 'gather coal_ore')], 0);
    expect(f.join(' ')).toMatch(/RESCUE TREADMILL: 2 of 3 working drones/);
  });

  it('stays quiet when one drone is on relief and the rest are earning', () => {
    const f = fleetFaults([drone(900, 'working', 'relieve for D37'),
                           drone(900, 'working', 'gather coal_ore'),
                           drone(900, 'working', 'lumber'),
                           drone(900, 'working', 'build')], 0);
    expect(f.join(' ')).not.toMatch(/TREADMILL/);
  });

  /** A scheduler wedge looks exactly like a quiet afternoon; nothing refuses the work out loud. */
  it('reports fuelled drones sitting idle while work waits', () => {
    const f = fleetFaults([drone(900, 'idle'), drone(900, 'idle'), drone(900, 'working')], 4);
    expect(f.join(' ')).toMatch(/IDLE WITH WORK QUEUED: 2 fuelled drones are idle while 4 order/);
  });

  it('does not report idleness when there is genuinely nothing to do', () => {
    const f = fleetFaults([drone(900, 'idle'), drone(900, 'idle')], 0);
    expect(f.join(' ')).not.toMatch(/IDLE WITH WORK/);
  });

  /** A dry drone is not "idle with work" -- it has a different, louder problem. */
  it('does not count dry drones as idle-with-work', () => {
    const f = fleetFaults([drone(0, 'idle'), drone(0, 'idle'), drone(900, 'working')], 4);
    expect(f.join(' ')).not.toMatch(/IDLE WITH WORK/);
  });
});

import { droneFault } from '../src/tools/core.js';

/**
 * A FAULT LINE MUST NOT FLIP WHILE NOTHING CHANGES.
 *
 * The per-drone report branched on `status` first, so a drone at zero fuel alternated between
 * "is STUCK -- low fuel" and "is low on fuel (0)" depending on what DroneMan called it that second.
 * Both true, both the same fault -- but a watcher diffing the list sees one clear and another
 * appear and reports a change that did not happen. The first thing the new monitor emitted was
 * eight lines of exactly that churn, describing nothing.
 *
 * A monitor that cries wolf is the failure this surface exists to prevent, so the fault is chosen
 * by what is WRONG, not by what the drone is currently labelled.
 */
const d = (o: Partial<Parameters<typeof droneFault>[0]>) => droneFault({
  name: 'D4', id: 47, fuel: 1000, status: 'working',
  stuck: null, silentMs: 0, healthy: true, unhealthyWhy: null, ...o,
});

describe('per-drone fault is stable', () => {
  it('reports the same line for a dry drone whatever its status says', () => {
    const lines = ['working', 'idle', 'stranded', 'hauling'].map((status) =>
      d({ fuel: 0, status, stuck: status === 'stranded' ? 'low fuel' : null }));
    expect(new Set(lines).size).toBe(1);              // one fault, one line, no churn
    expect(lines[0]).toMatch(/OUT OF FUEL/);
  });

  it('keeps saying nothing about a healthy drone', () => {
    expect(d({})).toBeNull();
  });

  it('still distinguishes a real obstruction from a fuel symptom', () => {
    expect(d({ fuel: 900, status: 'stranded', stuck: 'movement refused' })).toMatch(/STUCK — movement refused/);
  });

  it('still reports lost, low fuel and looks-busy-achieves-nothing', () => {
    expect(d({ fuel: 900, status: 'lost' })).toMatch(/is LOST/);
    expect(d({ fuel: 50 })).toMatch(/low on fuel \(50\)/);
    expect(d({ healthy: false, unhealthyWhy: 'has not moved in 20m' })).toMatch(/has not moved in 20m/);
  });
});
