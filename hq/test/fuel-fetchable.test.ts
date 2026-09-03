import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const lua = (f: string) => readFileSync(join(__dirname, '../../lua', f), 'utf8');
const logic = lua('DroneLogic.lua');
const taskman = lua('TaskMan.lua');

/**
 * THE DELIVERER MUST BE ABLE TO CARRY EVERYTHING THE ACCOUNTANT COUNTS.
 *
 * TaskMan decides whether a fuel relief is worth queueing by asking storageFuelCount, which asks
 * taskProducesFuel -- and that matches "coal", "log" AND "wood". So a store holding nothing but logs
 * reads as "there is fuel to deliver". CollectFuel, the thing that then goes and gets it, asked only
 * for minecraft:coal and minecraft:charcoal. The drone that answered the call could not pick up the
 * very material the gate had counted, and returned "storage had nothing burnable".
 *
 * That is the fuel deadlock, not a wasted trip: every failed relief occupies one of the few drones
 * that can still move, and the job it displaces is the lumber sweep that would end the shortage.
 * Measured with three drones at zero fuel, one lumber task waiting unassigned, and
 * `task 14723 failed (no fuel to deliver: storage had nothing burnable)` while storage held logs.
 *
 * Two answers to "what is fuel" is a shape this repo has now been bitten by five times.
 */
describe('what counts as fuel is what can be fetched as fuel', () => {
  const fn = (() => {
    const i = logic.indexOf('local function CollectFuel');
    if (i < 0) throw new Error('CollectFuel is gone -- move this assertion, do not delete it');
    return logic.slice(i, logic.indexOf('\nend\n', i) + 5);
  })();

  it('fetches wood as well as coal', () => {
    expect(fn).toMatch(/"minecraft:oak_log"/);
    expect(fn).toMatch(/"minecraft:oak_planks"/);
  });

  it('still prefers the denser fuels first', () => {
    const list = /ipairs\(\{([\s\S]*?)\}\)/.exec(fn)?.[1] ?? '';
    const order = [...list.matchAll(/"minecraft:(\w+)"/g)].map((m) => m[1]);
    expect(order.indexOf('coal')).toBeLessThan(order.indexOf('oak_log'));
    expect(order.indexOf('charcoal')).toBeLessThan(order.indexOf('oak_planks'));
  });

  /**
   * The gate this must agree with. If taskProducesFuel stops matching wood, or CollectFuel stops
   * fetching it, the two have drifted apart again and the deadlock returns.
   */
  it('the gate still counts the wood the fetch now collects', () => {
    const i = taskman.indexOf('local function taskProducesFuel');
    if (i < 0) throw new Error('taskProducesFuel is gone -- move this assertion, do not delete it');
    const gate = taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
    expect(gate).toMatch(/find\("log"\)/);
    expect(gate).toMatch(/find\("coal"\)/);
  });
});

/**
 * "SOME FUEL EXISTS" IS NOT "A RELIEF CAN CARRY SOME".
 *
 * stillTrapped decided whether a fuel relief was worth queueing with `storageFuelCount() ~= 0`.
 * CollectFuel asks FetchItems for each fuel item with a MINIMUM of 8, so a store holding four coal
 * and four logs totals eight and can deliver nothing -- every individual ask falls short.
 *
 * Measured at the bottom of a fuel spiral: storage held ONE acacia log. The total was 1, `1 ~= 0`
 * was true, and TaskMan queued five fuel reliefs -- each taken by one of the only two drones in the
 * settlement still able to move -- while the single lumber task that would have ended the shortage
 * sat unassigned. One stray log held the whole fleet in a loop it could not leave.
 *
 * The two questions now have two functions, and the threshold is the fetch's own minimum rather than
 * a number picked to feel right.
 */
describe('a relief is only queued when something can actually be carried', () => {
  const site = (name: string) => {
    const i = taskman.indexOf(`local function ${name}`);
    if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
    return taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
  };

  it('tests the largest single pile, not the total', () => {
    expect(site('fuelIsDeliverable')).toMatch(/s_Best >= FUEL_FETCH_MIN/);
  });

  it('uses the fetch\'s own minimum as the threshold, and that minimum is one lump', () => {
    // 8 -> 1: at 8, twelve burnable units on the shelf were unfetchable by rule and D31 died two
    // blocks from them. Any fuel is worth a trip; the two sides must still agree.
    expect(taskman).toMatch(/local FUEL_FETCH_MIN = 1/);
    expect(logic).toMatch(/\{\[s_Name\] = 1\}/);
  });

  it('an unreadable store does not block a rescue', () => {
    expect(site('fuelIsDeliverable')).toMatch(/if s_Best == nil then return true end/);
  });

  /** Both decision sites must ask the new question -- one converted call site is the repo's classic. */
  it('every "is a relief worth sending" site asks it', () => {
    expect(site('stillTrapped')).toMatch(/if fuelIsDeliverable\(\) then/);
    expect(site('dropUnfulfillableRescues')).toMatch(/if fuelIsDeliverable\(\) then return 0 end/);
    // the total is still the right question for "is the settlement comfortable"
    expect(taskman).toMatch(/storageFuelCount\(\) or 0\) >= FUEL_COMFORTABLE/);
  });
});

/**
 * A SETTLEMENT THAT CANNOT MOVE CANNOT BUILD.
 *
 * Tower patches are priority 2 and fuel work priority 1, which was believed to be enough. It is not:
 * the patches are already IN the queue, so whenever a drone comes free and no fuel task can be
 * placed for it, it takes one -- and a build is the most fuel-hungry job the fleet has.
 *
 * Measured at the bottom of a fuel spiral: five of seven drones at zero, storage holding one acacia
 * log, and D60 -- one of two machines still able to move -- spending its last 593 fuel laying
 * blocks. Ranking cannot help there. The work has to not be available to take.
 */
describe('the tower stops while the settlement is out of fuel', () => {
  const supplySrc = readFileSync(join(__dirname, '../src/agent/supply.ts'), 'utf8');
  const slice = (name: string) => {
    const i = supplySrc.indexOf(`function ${name}`);
    if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
    return supplySrc.slice(i, supplySrc.indexOf('\n}\n', i) + 3);
  };

  it('stops queued patches rather than relying on priority', () => {
    const fn = slice('keepTowerOrdered');
    expect(fn).toMatch(/stopTasksNamed\(`tower-L\$\{level\}-`\)/);
    expect(fn).toMatch(/fuel emergency -- tower paused/);
  });

  it('an unreadable stock is not an emergency', () => {
    const fn = slice('fuelEmergency');
    expect(fn).toMatch(/if \(burnable === null\) return null/);
    expect(slice('keepTowerOrdered')).toMatch(/emergency !== null && emergency/);
  });

  /**
   * "What counts as fuel" is now answered on BOTH sides of the bridge, and this repo has been bitten
   * five times by two answers that disagreed. They cannot share code, so they are asserted equal:
   * every item CollectFuel fetches must be one HQ counts as burnable.
   */
  it('HQ counts everything the drone can actually fetch', () => {
    const burnable = /const BURNABLE = \/([^/]+)\//.exec(supplySrc)?.[1];
    expect(burnable).toBeTruthy();
    const re = new RegExp(burnable!);
    const collect = logic.slice(logic.indexOf('local function CollectFuel'));
    const list = /ipairs\(\{([\s\S]*?)\}\)/.exec(collect)?.[1] ?? '';
    const fetched = [...list.matchAll(/"(minecraft:\w+)"/g)].map((m) => m[1]);
    expect(fetched.length).toBeGreaterThanOrEqual(4);
    for (const item of fetched) expect(re.test(item), `${item} is fetched but not counted`).toBe(true);
  });
});
