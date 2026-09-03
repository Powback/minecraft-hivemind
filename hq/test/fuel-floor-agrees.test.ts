import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const lua = (f: string) => readFileSync(join(__dirname, '../../lua', f), 'utf8');
const taskman = lua('TaskMan.lua');
const logic = lua('DroneLogic.lua');
const droneman = lua('DroneMan.lua');

/**
 * "HOW MUCH FUEL IS ENOUGH" IS ONE QUESTION AND MUST HAVE ONE ANSWER.
 *
 * TaskMan's own comment beside DISPATCH_FUEL_FLOOR says it: "Two numbers for one idea is how they
 * drift apart. They mean the same thing, so they are the same number." It was written after the
 * pair had drifted once. They then drifted again, because FUEL_SEARCH_ALLOWANCE (400) was added to
 * the DRONE's floor and not to TaskMan's constant -- so the drone's real floor became ~700 near base
 * while the scheduler went on using 300.
 *
 * That gap is not a rounding error, it is a trap door. Between the two numbers a drone is:
 *   - refused work,  because it reports "low fuel" distress and marks itself unavailable; and
 *   - refused fuel,  because droneIsDry says it has plenty.
 * Nothing reports that state. The drone simply ceases to exist as far as the scheduler is concerned.
 *
 * Measured: D4, the settlement's ONLY crafter, at 507 fuel, raising distress every fifteen seconds
 * while 295 tower patches waited on stone bricks that only it could craft -- and a third site
 * aborted it once a minute "so it can be given work" that pickDrone would refuse on arrival.
 *
 * A constant cannot be kept in step across three files. A REPORTED value cannot drift, because only
 * one place computes it.
 */
describe('the fuel floor is one number, computed once', () => {
  it('the drone reports the floor it actually uses', () => {
    // FuelFloorNow is what the drone's own watchdog tests against
    expect(logic).toMatch(/if s_Fuel ~= "unlimited" and s_Fuel < s_Floor/);
    // ...and it is what goes on the wire
    expect(logic).toMatch(/fuelFloor = ReportedFuelFloor\(\)/);
    expect(logic).toMatch(/local s_Ok, s_Floor = pcall\(FuelFloorNow\)/);
  });

  /**
   * DroneMan's reply is an explicit allowlist that has already swallowed `build` in silence. A field
   * the drone reports and nobody copies across is dropped with no error anywhere.
   */
  it('survives DroneMan\'s allowlist on the way to the scheduler', () => {
    const i = droneman.indexOf('local s_List');
    const list = droneman.slice(i, droneman.indexOf('return true, {drones = s_List', i));
    expect(list).toMatch(/fuelFloor = v\.fuelFloor/);
  });

  it('TaskMan believes the drone rather than its own constant', () => {
    expect(taskman).toMatch(/local function fuelFloorOf\(d\)/);
    expect(taskman).toMatch(/tonumber\(d\.fuelFloor\) or DISPATCH_FUEL_FLOOR/);
  });

  /**
   * The three sites that ask the question. All of them must route through the one answer -- the
   * whole defect was two of them agreeing and the third not.
   */
  it('every site asks the same way', () => {
    const site = (name: string) => {
      const i = taskman.indexOf(`local function ${name}(`);
      if (i < 0) throw new Error(`${name} is gone -- move this assertion, do not delete it`);
      return taskman.slice(i, taskman.indexOf('\nend\n', i) + 5);
    };
    expect(site('hasFuel')).toMatch(/f >= fuelFloorOf\(d\)/);
    expect(site('droneIsDry')).toMatch(/f < fuelFloorOf\(p_Drone\)/);

    // The abort pass tested the bare constant while pickDrone tested the reported floor, so it
    // aborted exactly the drones it had just decided could not be given work.
    expect(taskman).toMatch(/if not hasFuel\(d\) then s_Busy = false end/);
  });

  /**
   * The constant may remain as a fallback for a drone on older code -- but only as a fallback.
   * Anything still comparing a raw fuel number against it is a fourth answer waiting to drift.
   */
  it('keeps the constant only as a fallback', () => {
    const code = taskman.split('\n').filter((l) => !l.trim().startsWith('--')).join('\n');
    const uses = [...code.matchAll(/DISPATCH_FUEL_FLOOR/g)].length;
    expect(uses).toBe(2);   // the declaration, and the fallback inside fuelFloorOf
  });
});
