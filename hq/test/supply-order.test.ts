/**
 * STORAGE IS CHECKED BEFORE ANYTHING ELSE IN THE TICK.
 *
 * Not a style rule -- a correctness one, and it was broken. expandStorageIfFull was added after
 * replanShortfalls and topUpQueue, both of which RETURN EARLY the moment they do anything. With ten
 * idle drones the top-up queues a gather almost every tick, so the one rule that could unjam the
 * settlement sat permanently preempted: storage held at 0 free slots, ten drones idle, and the
 * sentinel correctly reporting "nothing is generating the next job".
 *
 * The ordering is also correct on its own terms. Every other rule ends in something being carried
 * home, so topping up the gather queue while there is nowhere to put anything is worse than doing
 * nothing -- it sends more drones to fetch material that cannot be unloaded, and each then fails in
 * a way that looks like its own fault rather than this one.
 *
 * Checked as source order because the phases are early-returning: there is no way to observe "would
 * have run" from the outside, which is exactly what made the bug invisible.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const src = readFileSync(path.join(__dirname, '../src/agent/supply.ts'), 'utf8');
const tick = src.slice(src.indexOf('export async function runSupplyTick'));
const at = (call: string) => {
  const i = tick.indexOf(call);
  expect(i, `${call} not found in runSupplyTick`).toBeGreaterThan(-1);
  return i;
};

describe('supply tick ordering', () => {
  it('checks storage before any phase that can return early', () => {
    const storage = at('await expandStorageIfFull(');
    expect(storage).toBeLessThan(at('await replanShortfalls('));
    expect(storage).toBeLessThan(at('await topUpQueue('));
  });

  it('checks storage before dispatching any rule', () => {
    expect(at('await expandStorageIfFull(')).toBeLessThan(at('for (const rule of supply.rules)'));
  });

  it('reads the queue before any phase that can add to it', () => {
    // Every phase below can queue work, so every one needs to know what is already outstanding.
    // Reading it halfway down is why the storage rule had to guard itself with a timer instead of
    // a fact -- and a timer expires while the previous build is still running.
    expect(at('await buildQueuedSet(')).toBeLessThan(at('await expandStorageIfFull('));
    expect(at('await buildQueuedSet(')).toBeLessThan(at('await topUpQueue('));
  });

  it('will not queue a second storage expansion while one is outstanding', () => {
    // Guarded on the FACT of an outstanding build, not on elapsed time. Cooldown-only produced
    // build-chest-row-storage-03, -05, -06, -07 and -08 for the same shortage.
    const fn = src.slice(src.indexOf('async function expandStorageIfFull'));
    const body = fn.slice(0, fn.indexOf('\n}\n'));
    expect(body).toMatch(/queued\].some\(\(n\) => n\.startsWith\('build-chest-row'\)\)/);
  });

  it('acts on the storage result rather than discarding it', () => {
    // A phase whose result is ignored is the same as one that never ran.
    const after = tick.slice(at('await expandStorageIfFull('), at('await replanShortfalls('));
    expect(after).toMatch(/if \(expanded\) return expanded;/);
  });
});
