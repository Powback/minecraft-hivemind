/**
 * An idle drone is a fault, not a rest state.
 *
 * The fleet is supposed to expand without being told to. A drone with nothing to do means either
 * the queue is empty -- nothing is generating the next job, so the settlement has quietly stopped
 * growing -- or work exists and the scheduler could not place it. Neither surfaces as an error
 * anywhere: the fleet sits there reporting itself healthy, which is how an afternoon passed with
 * five drones parked and the build chain untouched.
 */
import { describe, it, expect } from 'vitest';
import { detect, type Anchor } from '../src/agent/sentinel.js';

const IDLE_TICKS = 5;

const run = (n: number, drones: any[], tasks: any[] = []) => {
  const anchors = new Map<string, Anchor>();
  const idle = new Map<string, number>();
  const fired: any[] = [];
  for (let i = 0; i < n; i++) {
    for (const d of detect({ at: 0, modules: [], drones, tasks, reads: [] } as any,
                           new Map(), anchors, idle)) {
      // NOT startsWith('idle-'): idle-but-committed is a different, pre-existing detector and it
      // fires legitimately here. Matching loosely made this test assert the opposite of the truth.
      if (d.kind === 'idle-nothing-to-do' || d.kind === 'idle-while-work-waits') fired.push(d);
    }
  }
  return fired;
};

const idleMiner = [{ name: 'D5', role: 'miner', status: 'idle', pos: { x: 0, y: 0, z: 0 } }];

describe('idle drones', () => {
  it('says the settlement has stopped expanding when nothing is queued', () => {
    const f = run(IDLE_TICKS + 3, idleMiner);
    expect(f).toHaveLength(1);                       // once per streak, not every tick
    expect(f[0].kind).toBe('idle-nothing-to-do');
    expect(f[0].detail).toContain('not expanding');
  });

  it('distinguishes work-exists-and-you-are-not-doing-it', () => {
    const waiting = [{ id: 42, role: 'miner', progress: 0, assigned: null }];
    const f = run(IDLE_TICKS + 1, idleMiner, waiting);
    expect(f).toHaveLength(1);
    expect(f[0].kind).toBe('idle-while-work-waits');
    expect(f[0].detail).toContain('42');
  });

  it('only counts work its OWN role could take', () => {
    const crafterWork = [{ id: 7, role: 'crafter', progress: 0, assigned: null }];
    const f = run(IDLE_TICKS + 1, idleMiner, crafterWork);
    expect(f[0].kind).toBe('idle-nothing-to-do');    // a miner cannot craft
  });

  it('stays quiet for a drone briefly between jobs', () => {
    expect(run(IDLE_TICKS - 1, idleMiner)).toEqual([]);
  });

  it('stays quiet for a working drone', () => {
    const busy = [{ name: 'D7', role: 'miner', status: 'working', pos: { x: 0, y: 0, z: 0 } }];
    expect(run(20, busy)).toEqual([]);
  });

  it('resets the streak when a drone picks work up again', () => {
    const anchors = new Map<string, Anchor>();
    const idle = new Map<string, number>();
    const tick = (status: string) =>
      detect({ at: 0, modules: [], drones: [{ name: 'D5', role: 'miner', status, pos: { x: 0, y: 0, z: 0 } }],
               tasks: [], reads: [] } as any, new Map(), anchors, idle)
        .filter((d) => d.kind === 'idle-nothing-to-do' || d.kind === 'idle-while-work-waits');
    for (let i = 0; i < IDLE_TICKS - 1; i++) tick('idle');
    tick('working');                                  // back to work: streak forgotten
    for (let i = 0; i < IDLE_TICKS - 1; i++) expect(tick('idle')).toEqual([]);
  });

  it('does not double-report a drone that is idle while HOLDING a task', () => {
    // That is idle-but-committed, a different fault with a different fix.
    const holding = [{ id: 9, role: 'miner', progress: 0, assigned: 'D5' }];
    expect(run(IDLE_TICKS + 2, idleMiner, holding)).toEqual([]);
  });
});
