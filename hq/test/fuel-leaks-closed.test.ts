import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const lua = (f: string) => readFileSync(join(__dirname, '../../lua', f), 'utf8');
const ts = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');
const logic = lua('DroneLogic.lua');
const pgps = lua('pgps.lua');
const supply = ts('agent/supply.ts');

/**
 * WHERE THE FUEL WENT -- the checks that are still about SHAPE.
 *
 * The behaviour behind each fuel leak of 2026-09-03 is exercised for real in hq/test/lua/run.lua
 * (the Lua runs under a stub ComputerCraft world) and hq/test/lua-behaviour.test.ts: the reliever
 * keeping its payload, the deposit point being a networked chest, the smelter lighting on wood, one
 * coroutine owning travel, saplings going on soil. What remains here is the handful of invariants a
 * behavioural test cannot see -- "there is exactly one of this number", "this loop contains no
 * travel call", a bootloader the runner does not load, and two HQ decisions whose functions are not
 * yet exported for calling. When one of these gains a real test, delete it from here.
 */
describe('fuel-economy invariants that are about shape', () => {
  // Three numbers for "full" (a 4,000 gate, a 2,500 target and a 1,200 fetch) drained every chest
  // into tanks. Behaviour is tested (BurnAboard stops at the target); that there is ONE number is a
  // property of the source.
  it('there is exactly one refuel target', () => {
    expect(logic).not.toMatch(/\bFUEL_LOW\b\s*=/);
    expect(logic).not.toMatch(/\bFUEL_KEEP\b\s*=/);
    expect(logic).not.toMatch(/\bFUEL_TOPUP\b\s*=/);
    const decls = logic.match(/^local REFUEL_TARGET\s*=/gm) ?? [];
    expect(decls).toHaveLength(1);
  });

  // moveLeg is a local inside pgps with no seam yet. A two-cell bounce ran all forty replans because
  // progress was measured against the LAST step.
  it('moveLeg measures progress against the best distance so far, not the last step', () => {
    expect(pgps).not.toMatch(/s_LastDist/);
    expect(pgps).toMatch(/if s_BestDist ~= nil and s_Dist >= s_BestDist then/);
    expect(pgps).toMatch(/s_Stalls = 0\s*\n\s*s_BestDist = s_Dist/);
  });

  // The fuel watchdog used to be the coroutine that flies to storage, so it never looked aboard while
  // flying. The coroutine that burns what is aboard must contain no travel at all -- a property of
  // its text, not of any one call.
  it('the burn watchdog runs in its own coroutine and never travels', () => {
    const i = logic.indexOf('function BurnAboardLoop()');
    expect(i).toBeGreaterThan(0);
    const fn = logic.slice(i, logic.indexOf('\nend\n', i) + 5);
    expect(fn).toMatch(/BurnAboard\(\)/);
    expect(fn).not.toMatch(/TravelTo|RefuelAtStorage|parkForFuel|FetchItems|sendAndWaitForResponse/);
    expect(logic).toMatch(/\{"burnAboard", BurnAboardLoop\}/);
  });

  // The bootloader is not loaded by the Lua runner (it waits for MainFrame). refuel(64) on every boot
  // incinerated whatever coal a drone was carrying -- relief payloads above all.
  it('the bootloader never burns a whole stack', () => {
    const boot = lua('DroneBoot.lua').split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
    expect(boot).not.toMatch(/turtle\.refuel\(\s*(64|\))/);
    expect(boot).toMatch(/turtle\.refuel\(1\)/);
    expect(boot).toMatch(/BOOT_FUEL_MIN/);
  });

  // HQ: the supply tick's functions are not exported for calling yet. Until they are, two decisions
  // are pinned by shape: no miner goes underground during a fuel emergency, and a haul from a cache
  // known to hold burnable is NAMED as fuel work so TaskMan ranks it as such.
  it('HQ does not send a miner underground for a non-fuel ore during a fuel emergency -- coal goes', () => {
    expect(supply).toMatch(/oreWaitsForFuel\(rule\.match\) && \(await fuelEmergency\(\)\) === true/);
    expect(supply).toMatch(/return \/_ore\$\/\.test\(match\) && !producesFuel\(match\)/);
  });

  it('a haul from a cache holding fuel is named as fuel work', () => {
    expect(supply).toMatch(/const suffix = burnableIn\(chosen\) \? ':log' : ''/);
    expect(supply).toMatch(/name: `haul:\$\{where\}\$\{suffix\}`/);
  });
});
