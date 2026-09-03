import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const lua = (f: string) => readFileSync(join(__dirname, '../../lua', f), 'utf8');
const ts = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');
const logic = lua('DroneLogic.lua');
const pgps = lua('pgps.lua');
const supply = ts('agent/supply.ts');

/**
 * WHERE THE FUEL WENT.
 *
 * The settlement reached the fuel trap four times in one day, and each time 192 coal added by hand
 * was gone within the hour. Measured against the world rather than the logs, the coal took four
 * exits, and each one below is a check because each one had a fix that a later edit could undo
 * without noticing:
 *
 *  1. THREE NUMBERS FOR "FULL". CollectFuel took to REFUEL_TARGET and left the rest; TryRefuel ran
 *     every twenty seconds with its own gate (4,000) and target (2,500) and sucked the chest below
 *     dry. Seven tanks at 2,500 is 17,500 fuel that had to fill before one lump could stay in a chest.
 *  2. THE RELIEVER ATE THE PAYLOAD. "carrying 28 fuel" ... "refuelled +559" x5 ... "arrived but
 *     dropped nothing". Every delivery failed this way once it could reach the casualty at all.
 *  3. PACING. moveLeg compared each replan with the previous one, so a two-cell bounce never
 *     tripped the stall counter and ran all forty replans -- one GetPath and one move each. Traced
 *     as a drone stepping forward and back every two seconds for forty seconds, silently.
 *  4. THE MESH FIX CRASHED. setLocation(x, y, z, nil) ran string.lower(nil); every underground
 *     recovery logged "FAILED to adopt the meshed position" and kept the position it was told
 *     was wrong.
 */
describe('the four fuel leaks stay closed', () => {
  it('there is exactly one refuel target and the watchdog uses it', () => {
    expect(logic).not.toMatch(/\bFUEL_LOW\b\s*=/);
    expect(logic).not.toMatch(/\bFUEL_KEEP\b\s*=/);
    expect(logic).not.toMatch(/\bFUEL_TOPUP\b\s*=/);
    const decls = logic.match(/^local REFUEL_TARGET\s*=/gm) ?? [];
    expect(decls).toHaveLength(1);
    // TryRefuel gates on it, burnFrom stops at it, and the blind suck stops when what is aboard would reach it.
    expect(logic).toMatch(/if s_Level >= REFUEL_TARGET then return false end/);
    expect(logic).toMatch(/turtle\.getFuelLevel\(\) >= REFUEL_TARGET then return end/);
    expect(logic).toMatch(/if s_Level \+ carriedBurnable\(\) >= REFUEL_TARGET then break end/);
  });

  it('a reliever does not burn the fuel it is carrying for somebody else', () => {
    // Declared at file scope BEFORE burnFrom (a local first assigned in OnRelieve would be a global there
    // and nil in burnFrom -- the check would compile and never fire).
    const decl = logic.indexOf('local m_Relieving = false');
    const burn = logic.indexOf('local function burnFrom(');
    const relieve = logic.indexOf('function OnRelieve(');
    expect(decl).toBeGreaterThan(0);
    expect(decl).toBeLessThan(burn);
    expect(decl).toBeLessThan(relieve);
    expect(logic).toMatch(/if m_Relieving and turtle\.getFuelLevel\(\) >= FuelFloorNow\(\) then return end/);
    // Set for the run and cleared on every exit, including an error.
    const body = logic.slice(relieve, logic.indexOf('function OnHaul('));
    expect(body).toMatch(/m_Relieving = true\s*\n\s*local ok, r1, r2 = pcall\(relieveBody, d\)\s*\n\s*m_Relieving = false/);
  });

  it('moveLeg measures progress against the best distance so far, not the last step', () => {
    expect(pgps).not.toMatch(/s_LastDist/);
    expect(pgps).toMatch(/if s_BestDist ~= nil and s_Dist >= s_BestDist then/);
    expect(pgps).toMatch(/s_Stalls = 0\s*\n\s*s_BestDist = s_Dist/);
  });

  it('setLocation with no heading keeps the current one instead of throwing', () => {
    const fn = pgps.slice(pgps.indexOf('function setLocation('), pgps.indexOf('function startGPS('));
    const nilGuard = fn.indexOf('if d == nil then');
    const ladder = fn.indexOf('string.lower(d)');
    expect(nilGuard).toBeGreaterThan(0);
    expect(nilGuard).toBeLessThan(ladder);
  });

  // A cache chest (no peripheral) is invisible to Stock, WhereIs, the smelter and the factories, so
  // anything deposited there has left the economy. With no site to anchor the distance, the
  // emptiest chest won -- a spoil cache 45 blocks out -- and became "home" for refuelling too.
  it('a deposit with no site goes to a networked chest, never a cache', () => {
    const storage = lua('StorageMan.lua');
    const fn = storage.slice(storage.indexOf('function OnDepositPoint('), storage.indexOf('function OnAddDeposit('));
    expect(fn).toMatch(/local s_Usable, s_Offline = \{\}, \{\}/);
    // a cache is the fallback ONLY when no networked chest has room -- a site does not change that
    expect(fn).toMatch(/if #s_Usable == 0 then s_Usable = s_Offline end/);
    expect(fn).not.toMatch(/s_Near/);
    // and the registry is deduplicated first, so a bound chest's unbound twin cannot pose as a cache
    expect(fn).toMatch(/dedupeDeposits\(\)/);
    expect(storage).toMatch(/function OnDepositPoints\(p_ID, p_Message\)\s*\n\s*Rescan\(\)\s*\n\s*dedupeDeposits\(\)/);
  });

  // fuelLoop both watches the tank and flies off to fix it, so while it was flying it never looked
  // aboard: D40 went 300 -> 59 with eight coal in slot 16 for fifteen minutes. The coroutine that
  // burns what is aboard must never be the one that travels.
  it('the burn watchdog runs in its own coroutine and never travels', () => {
    const i = logic.indexOf('function BurnAboardLoop()');
    expect(i).toBeGreaterThan(0);
    const fn = logic.slice(i, logic.indexOf('\nend\n', i) + 5);
    expect(fn).toMatch(/BurnAboard\(\)/);
    expect(fn).not.toMatch(/TravelTo|RefuelAtStorage|parkForFuel|FetchItems|sendAndWaitForResponse/);
    expect(logic).toMatch(/\{"burnAboard", BurnAboardLoop\}/);
  });

  // A boot-time refuel(64) burned the whole selected stack, so every redeploy incinerated whatever
  // coal a drone was carrying -- relief payloads above all.
  it('the bootloader never burns a whole stack', () => {
    const boot = lua('DroneBoot.lua').split('\n').filter((l) => !/^\s*--/.test(l)).join('\n');
    expect(boot).not.toMatch(/turtle\.refuel\(\s*(64|\))/);
    expect(boot).toMatch(/turtle\.refuel\(1\)/);
    expect(boot).toMatch(/BOOT_FUEL_MIN/);
  });

  // Zero coal with logs on the shelf was a dead end twice over: the wood reserve for crafting held
  // the logs back, and the fuel face took only coal. Fuel before furniture, in BOTH places, and wood
  // may light the furnace when nothing else can.
  it('the smelter bootstraps from wood when fuel is short', () => {
    const storage = lua('StorageMan.lua');
    const reserved = storage.slice(storage.indexOf('local function reservedForCrafting('), storage.indexOf('local function smeltRank('));
    expect(reserved).toMatch(/if fuelInStorage\(\) < SMELT_FUEL_RESERVE then return false end/);
    const allowance = storage.slice(storage.indexOf('local function smeltAllowance('), storage.indexOf('local function drainTo('));
    expect(allowance).toMatch(/if fuelInStorage\(\) < SMELT_FUEL_RESERVE then return math\.min\(SMELT_BATCH, n\) end/);
    const fill = storage.slice(storage.indexOf('local function fillFor('), storage.indexOf('function ServiceFurnaces('));
    expect(fill).toMatch(/return firstInStorage\(isWoodFuel\), WOOD_FUEL_BATCH/);
    // and wood in the fuel slot is kept, not drained straight back out
    expect(storage).toMatch(/return not \(KEEP_AS_FUEL\[p_Item\.name\] or isWoodFuel\(p_Item\.name\)\)/);
  });

  it('HQ does not send a miner underground during a fuel emergency', () => {
    expect(supply).toMatch(/\/_ore\$\/\.test\(rule\.match\) && \(await fuelEmergency\(\)\) === true/);
  });
});
