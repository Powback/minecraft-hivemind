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
    const storage = at('await maintenancePhases(');
    expect(storage).toBeLessThan(at('await materialPhases('));
  });

  // THE FUEL GATE IS A PHASE-ORDER RULE TOO, AND IT WAS THE ONE THAT GOT THIS WRONG.
  //
  // fuelCritical was computed at the BOTTOM of the tick, below replanShortfalls and topUpQueue.
  // On a settlement with one failing wood gather the replan returned early every single pass --
  // six identical notes in six minutes -- so the fuel check was never reached at all. Coal sat at
  // zero throughout while the loop re-planned oak logs. The protection read as present and was
  // unreachable, which is worse than absent.
  it('decides the fuel emergency before any phase that can return early', () => {
    expect(at('fuelRunway(')).toBeLessThan(at('await materialPhases('));
  });

  // materialPhases exists to keep the tick's branch count down, NOT to give these two phases a
  // second way in. If either is ever called directly again the ordering guarantees above stop
  // meaning anything, because the source-order check would not see it.
  it('only reaches the material phases through the gated helper', () => {
    const helper = src.slice(src.indexOf('async function materialPhases'));
    const body = helper.slice(0, helper.indexOf('\n}\n'));
    expect(body).toContain('replanShortfalls(');
    expect(body).toContain('topUpQueue(');
    const calls = (n: string) => (src.match(new RegExp(`await ${n}\\(`, 'g')) ?? []).length;
    expect(calls('replanShortfalls')).toBe(1);
    expect(calls('topUpQueue')).toBe(1);
  });

  it('checks storage before dispatching any rule', () => {
    expect(at('await maintenancePhases(')).toBeLessThan(at('for (const rule of supply.rules)'));
  });

  it('reads the queue before any phase that can add to it', () => {
    // Every phase below can queue work, so every one needs to know what is already outstanding.
    // Reading it halfway down is why the storage rule had to guard itself with a timer instead of
    // a fact -- and a timer expires while the previous build is still running.
    expect(at('await buildQueuedSet(')).toBeLessThan(at('await maintenancePhases('));
    expect(at('await buildQueuedSet(')).toBeLessThan(at('await materialPhases('));
  });

  it('will not queue a second storage expansion while one is outstanding', () => {
    // Guarded on the FACT of an outstanding build, not on elapsed time. Cooldown-only produced
    // build-chest-row-storage-03, -05, -06, -07 and -08 for the same shortage.
    //
    // The check now lives in mayQueue, shared with the field-cache collector, because two copies of
    // one rule is how they drift. Pin the CALLER passes its prefix, and separately that mayQueue
    // still asks about outstanding tasks BEFORE the cooldown -- that order is the whole lesson.
    const fn = src.slice(src.indexOf('async function expandStorageIfFull'));
    const body = fn.slice(0, fn.indexOf('\n}\n'));
    expect(body).toMatch(/mayQueue\(queued, 'build-chest-row', '__storage'\)/);

    const guard = src.slice(src.indexOf('function mayQueue('));
    const guardBody = guard.slice(0, guard.indexOf('\n}\n'));
    expect(guardBody, 'an outstanding task must veto before the cooldown is consulted')
      .toMatch(/startsWith\(prefix\)[\s\S]*cooldowns\[cooldownKey\]/);
  });

  it('collects field caches, or caching loses the material it saves', () => {
    // A lumber sweep reported done with oak_log still 0: the wood was in a cache 81 blocks out and
    // nothing ever went back for it. Planks gate chests and chests gate every blueprint, so the
    // whole build chain stalled on material already cut.
    expect(src).toMatch(/async function collectFieldCaches\(/);
    const fn = src.slice(src.indexOf('async function collectFieldCaches'));
    const body = fn.slice(0, fn.indexOf('\n}\n'));
    // A cache is a deposit point with no peripheral -- that absence is what identifies it.
    expect(body, 'a field cache is identified by having NO peripheral').toMatch(/!\w+\.peripheral/);
    expect(body, 'must queue work TaskMan can dispatch').toMatch(/work: \{ haul:/);
    // And the tick must act on it rather than discarding the result.
    expect(src).toMatch(/await collectFieldCaches\(live, queued\)/);
  });

  it('acts on the storage result rather than discarding it', () => {
    // A phase whose result is ignored is the same as one that never ran.
    const after = tick.slice(at('await maintenancePhases('), at('await materialPhases('));
    expect(after).toMatch(/if \(maintained\) return maintained;/);
  });
});
