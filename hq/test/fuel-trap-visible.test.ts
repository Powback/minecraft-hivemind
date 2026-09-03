import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const core = readFileSync(join(__dirname, '../src/tools/core.ts'), 'utf8');

/**
 * THE ONE STATE THE SETTLEMENT CANNOT LEAVE MUST BE SAID OUT LOUD.
 *
 * Mining coal needs a fuelled drone. Felling wood needs a fuelled drone. Smelting charcoal needs
 * fuel. So once every drone is at zero there is no sequence of actions available -- the graph of
 * "what produces fuel" has no node that does not consume it first.
 *
 * buildBrief reported that as seven separate "low on fuel" lines, indistinguishable from a fleet
 * having a bad afternoon. An emergent, terminal condition is not the sum of its per-drone symptoms,
 * and the surface a human reads to ask "what is wrong" said nothing that named it.
 *
 * Reached on 2026-09-03 and confirmed by hand: seven drones at zero, none carrying anything
 * burnable, storage empty. An external monitor spotted it; the settlement's own brief did not.
 */
describe('the brief names the fuel trap', () => {
  const fn = (() => {
    const i = core.indexOf('export function buildBrief');
    if (i < 0) throw new Error('buildBrief is gone -- move this assertion, do not delete it');
    return core.slice(i, core.indexOf('\n}\n', i) + 3);
  })();

  /**
   * The CONDITIONS moved into fleetFaults, where they are unit-tested against constructed fleets in
   * fleet-faults.test.ts -- thresholds deserve real tests, not a source grep. What is left to check
   * here is the WIRING, because a detector nothing calls is the disarmed guard this repo keeps
   * rebuilding.
   */
  it('asks fleetFaults for the whole-fleet conditions', () => {
    expect(fn).toMatch(/fleetFaults\(drones as any, orders\.length\)/);
  });

  /** The list's order is its only emphasis, and a fleet-wide fault outranks any single drone. */
  it('puts them ahead of the per-drone problems', () => {
    expect(fn).toMatch(/problems\.unshift\(\.\.\.fleetFaults\(/);
  });

  /** The per-drone wording moved into droneFault, where it is unit-tested for STABILITY -- see
   *  fleet-faults.test.ts. What matters here is that buildBrief still asks for it. */
  it('still reports the per-drone problems underneath', () => {
    expect(fn).toMatch(/const f = droneFault\(d\)/);
    expect(fn).toMatch(/if \(f\) problems\.push\(f\)/);
  });
});

describe('the brief looks before it reports', () => {
  const server = readFileSync(join(__dirname, '../src/server.ts'), 'utf8');

  it('refreshes the fleet on the /brief route', () => {
    expect(server).toMatch(/pathname === '\/brief'\) \{ await refreshFleet\(\); return send\(200, buildBrief\(\)\); \}/);
  });

  it('the tool path still refreshes too', () => {
    expect(core).toMatch(/await refreshFleet\(\); return buildBrief\(\)/);
  });
});

/**
 * A PAUSE MUST NOT LOOK LIKE A COMPLETION.
 *
 * The fuel-emergency pause stops the current floor's patches so the fleet can spend its last fuel on
 * fuel. But an empty floor queue is precisely what the completion test reads as "the fleet visited
 * every square and did what it could" -- so the floor was judged FINISHED on work that had been
 * cancelled, and the counter advanced once per emergency. Measured walking 0 -> 3 across three
 * pauses with nothing built on any of them, and nothing ever revisits a level.
 *
 * Two changes that are each correct alone, interacting. Dropping the batch removes the thing being
 * judged: with no batch there is nothing to conclude, and startWatchingFloor opens a fresh one once
 * the fleet is fuelled and working the floor again.
 */
describe('pausing the tower for fuel does not advance it', () => {
  const supplySrc = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');
  const fn = (() => {
    const i = supplySrc.indexOf('async function keepTowerOrdered');
    if (i < 0) throw new Error('keepTowerOrdered is gone -- move this assertion, do not delete it');
    return supplySrc.slice(i, supplySrc.indexOf('\n}\n', i) + 3);
  })();

  it('drops the batch when it stops the floor', () => {
    const pause = fn.slice(fn.indexOf('const emergency ='), fn.indexOf('const bricks ='));
    expect(pause).toMatch(/supply\.towerBatch = undefined/);
    expect(pause).toMatch(/saveSupply\(\)/);      // and survives a restart, like every other decision
  });

  /** The completion test still reads an empty queue as drained -- which is why the batch must go. */
  it('completion still keys off the batch, so removing it is what makes the pause safe', () => {
    expect(fn).toMatch(/floorIsFinished\(level, bricks\) && unfinished === 0/);
    const batch = supplySrc.slice(supplySrc.indexOf('function batchPlacedNothing'));
    expect(batch.slice(0, batch.indexOf('\n}\n'))).toMatch(/if \(!last \|\| last\.level !== p_Level\) return false/);
  });
});
