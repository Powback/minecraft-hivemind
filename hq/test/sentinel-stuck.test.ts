/**
 * The contradiction that hid for hours: a drone that is BUSY, COMMITTED, and going nowhere.
 *
 * D1 held the shaft task for the settlement's centre plot all afternoon, reporting "working" and
 * "mining" on every heartbeat while failing to reach the shaft head and being handed the same task
 * straight back. Every other detector looked at it and saw a healthy fleet.
 */
import { describe, it, expect } from 'vitest';
import { detect, type Anchor } from '../src/agent/sentinel.js';

const obs = (pos: { x: number; y: number; z: number }) => ({
  at: 0,
  modules: [],
  drones: [{ name: 'D1', status: 'working', pos }],
  tasks: [{ id: 347, assigned: 'D1', progress: 0 }],
  reads: [],
});

const run = (n: number, pos: (i: number) => { x: number; y: number; z: number }) => {
  const anchors = new Map<string, Anchor>();
  const fired: string[] = [];
  for (let i = 0; i < n; i++) {
    for (const d of detect(obs(pos(i)) as any, new Map(), anchors)) {
      if (d.kind === 'committed-but-not-moving') fired.push(d.detail);
    }
  }
  return fired;
};

describe('committed-but-not-moving', () => {
  it('fires on a busy drone that holds work and never leaves its spot', () => {
    const fired = run(20, () => ({ x: -477, y: 66, z: 77 }));
    expect(fired.length).toBe(1);          // once, not once per tick
    expect(fired[0]).toContain('347');
    expect(fired[0]).toContain('-477,66,77');
  });

  it('stays quiet for a drone that is actually moving', () => {
    expect(run(40, (i) => ({ x: -477, y: 66, z: 77 + i * 4 }))).toEqual([]);
  });

  it('tolerates the small drift of a drone working in place, then still fires', () => {
    // Bobbing within 3 blocks is exactly what D1 did. That is not progress.
    expect(run(20, (i) => ({ x: -477, y: 65 + (i % 2), z: 77 })).length).toBe(1);
  });

  it('does not fire before the threshold', () => {
    expect(run(10, () => ({ x: -477, y: 66, z: 77 }))).toEqual([]);
  });
});
