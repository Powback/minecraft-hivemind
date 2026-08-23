/**
 * Every fixture here is a state the fleet was ACTUALLY in today, not one I invented.
 *
 * That matters more than the usual reason for realistic fixtures. A detector for a contradiction I
 * imagined would prove nothing -- the whole point is that these particular lies were believable
 * enough to cost hours each, so the test is whether the detector catches the exact shape that
 * fooled a person looking straight at it.
 */

import { describe, it, expect } from 'vitest';
import { detect, Ledger, type Observation } from '../src/agent/sentinel.js';

const base = (o: Partial<Observation> = {}): Observation => ({
  at: 1_000_000,
  modules: [],
  drones: [],
  tasks: [],
  reads: [],
  ...o,
});

describe('sentinel detectors', () => {
  it('catches a module that resolves but answers nothing (MapServer, for hours)', () => {
    const found = detect(
      base({ modules: [{ name: 'MapServer', probeSaysUp: true, directCallWorked: false }] }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).toContain('resolves-but-silent');
    expect(found[0]!.severity).toBe('wedge');
  });

  it('catches the monitoring lying the other way (hive.nodes said 0 of 7 while queries worked)', () => {
    const found = detect(
      base({ modules: [{ name: 'TaskMan', probeSaysUp: false, directCallWorked: true }] }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).toContain('probe-lies');
  });

  it('says nothing when the probe and the work agree', () => {
    const found = detect(
      base({
        modules: [
          { name: 'TaskMan', probeSaysUp: true, directCallWorked: true },
          { name: 'DroneMan', probeSaysUp: false, directCallWorked: false },
        ],
      }),
      new Map(),
    );
    expect(found).toHaveLength(0);
  });

  it('catches drones reporting idle while holding unfinished work (D21, D7, D17, D14, D8, D2)', () => {
    const held = ['D21', 'D7', 'D17', 'D14', 'D8', 'D2'];
    const found = detect(
      base({
        drones: held.map((name) => ({ name, role: 'scout', status: 'idle' })),
        tasks: held.map((d, i) => ({ id: 17 + i, assigned: d, progress: 0 })),
      }),
      new Map(),
    );
    expect(found.filter((f) => f.kind === 'idle-but-committed')).toHaveLength(6);
  });

  it('does not fire when a drone holding work is actually working', () => {
    const found = detect(
      base({
        drones: [{ name: 'D13', status: 'working' }],
        tasks: [{ id: 123, assigned: 'D13', progress: 0 }],
      }),
      new Map(),
    );
    expect(found.filter((f) => f.kind === 'idle-but-committed')).toHaveLength(0);
  });

  it('catches finished work that was never reported (D13 stood on D3 at -83,67,-72 with the task at 0%)', () => {
    const found = detect(
      base({
        drones: [{ name: 'D13', role: 'miner', status: 'idle', pos: { x: -83, y: 67, z: -72 } }],
        tasks: [{ id: 123, assigned: 'D13', progress: 0, pos: { x: -83, y: 67, z: -72 } }],
      }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).toContain('work-done-not-reported');
  });

  it('does not call it done when the drone is nowhere near the target', () => {
    const found = detect(
      base({
        drones: [{ name: 'D13', status: 'idle', pos: { x: 0, y: 64, z: 0 } }],
        tasks: [{ id: 123, assigned: 'D13', progress: 0, pos: { x: -83, y: 67, z: -72 } }],
      }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).not.toContain('work-done-not-reported');
  });

  it('catches a truncated read reporting success (blocks went 120,000 -> 16,000 and was cached)', () => {
    const best = new Map<string, number>();
    detect(base({ reads: [{ name: 'blocks', count: 120_000 }] }), best);
    const found = detect(base({ reads: [{ name: 'blocks', count: 16_000 }] }), best);
    expect(found.map((f) => f.kind)).toContain('partial-read-as-complete');
  });

  it('treats honest growth as growth, not as a fault', () => {
    const best = new Map<string, number>();
    detect(base({ reads: [{ name: 'voxels', count: 294_713 }] }), best);
    const found = detect(base({ reads: [{ name: 'voxels', count: 375_732 }] }), best);
    expect(found).toHaveLength(0);
    expect(best.get('voxels')).toBe(375_732);
  });

  it('catches a starved queue (114 live, 10 assigned, 11 idle)', () => {
    const found = detect(
      base({
        liveTasks: 114,
        assignedTasks: 4,
        drones: Array.from({ length: 11 }, (_, i) => ({ name: `D${i}`, status: 'idle' })),
      }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).toContain('queue-starvation');
  });

  it('does not call a healthy backlog starvation', () => {
    const found = detect(
      base({
        liveTasks: 114,
        assignedTasks: 22,
        drones: Array.from({ length: 11 }, (_, i) => ({ name: `D${i}`, status: 'idle' })),
      }),
      new Map(),
    );
    expect(found.map((f) => f.kind)).not.toContain('queue-starvation');
  });
});

describe('ledger', () => {
  const tmp = () => `/tmp/hive-sentinel-test-${Math.round(performance.now() * 1000)}`;

  it('opens an incident once and closes it once', async () => {
    const l = new Ledger(tmp());
    const d = [{ key: 'silent:MapServer', kind: 'resolves-but-silent', severity: 'wedge' as const, detail: 'x' }];

    expect((await l.reconcile(d, 1000)).length).toBe(1);
    expect((await l.reconcile(d, 2000)).length).toBe(0);   // still true: not a new incident
    expect(l.counts()).toEqual({ open: 1, closed: 0 });

    await l.reconcile([], 3000);                            // gone: closed
    expect(l.counts()).toEqual({ open: 0, closed: 1 });
  });

  it('scores a manual power-cycle as NOT self-resolved', async () => {
    const l = new Ledger(tmp());
    const d = [{ key: 'silent:MapServer', kind: 'resolves-but-silent', severity: 'wedge' as const, detail: 'x' }];
    await l.reconcile(d, 1000);
    await l.markOutOfBand('silent:MapServer', 'rcon power cycle');
    await l.reconcile([], 2000);

    const m = l.metrics(3000);
    expect(m.resolved).toBe(1);
    expect(m.outOfBand).toBe(1);
    expect(m.selfResolvedPct).toBe(0);        // the number the project exists to move
  });

  it('scores an incident that healed by itself as self-resolved', async () => {
    const l = new Ledger(tmp());
    await l.reconcile([{ key: 'idleheld:D7', kind: 'idle-but-committed', severity: 'stall', detail: 'x' }], 1000);
    await l.reconcile([], 2000);
    expect(l.metrics(3000).selfResolvedPct).toBe(100);
  });

  it('measures time between incidents opening, not between fixes', async () => {
    const l = new Ledger(tmp());
    await l.reconcile([{ key: 'a', kind: 'k', severity: 'stall', detail: '' }], 0);
    await l.reconcile([{ key: 'a', kind: 'k', severity: 'stall', detail: '' },
                       { key: 'b', kind: 'k', severity: 'stall', detail: '' }], 60_000);
    await l.reconcile([{ key: 'a', kind: 'k', severity: 'stall', detail: '' },
                       { key: 'b', kind: 'k', severity: 'stall', detail: '' },
                       { key: 'c', kind: 'k', severity: 'stall', detail: '' }], 180_000);
    expect(l.metrics(200_000).mtbiMs).toBe(90_000);   // (60k + 120k) / 2
  });

  it('survives a restart, because uptime that resets with the observer measures the observer', async () => {
    const dir = tmp();
    const a = new Ledger(dir);
    await a.reconcile([{ key: 'silent:MapServer', kind: 'resolves-but-silent', severity: 'wedge', detail: 'x' }], 1000);

    const b = new Ledger(dir);
    await b.load();
    expect(b.counts().open).toBe(1);
    expect(b.openIncidents()[0]!.key).toBe('silent:MapServer');
  });
});
