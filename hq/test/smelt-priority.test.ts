/**
 * WHAT GOES IN THE FURNACE, WHEN FUEL IS THE THING YOU HAVE LEAST OF.
 *
 * The furnaces were unreachable for their whole existence: both wired modems sat UNDER the
 * furnaces, and a modem under a furnace exposes only the DOWN face -- output and fuel, two slots.
 * The input slot is on the top face, so nothing could ever put ore in. `ServiceFurnaces` reported
 * success and moved zero, for weeks.
 *
 * The tick after that was fixed, the first thing the settlement smelted was cobblestone. Not
 * because anything chose it -- `firstInStorage` walks `pairs(m_Index)`, whose order is arbitrary,
 * and 2,410 cobblestone happened to come out in front of 657 raw_copper. Storage held zero coal and
 * zero charcoal at that moment, so those were the last smelts available anywhere in the settlement
 * and they produced a decorative block.
 *
 * That is the bug this file exists to stop coming back. The rule is not "cobblestone is bad", it is
 * that the ORDER must be deliberate and fuel-aware, because the fuel economy is the whole game:
 *   - a log becomes charcoal, and one coal smelts eight logs into eight charcoal, so a log is the
 *     only input whose smelt RETURNS more fuel than it costs;
 *   - raw ore becomes the ingots the settlement is mining for;
 *   - cobblestone becomes stone, of which there is no shortage and no demand.
 *
 * Static guards, like the rest of the Lua checks here -- there is no Lua runtime in this suite.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const SRC = readFileSync(path.resolve(__dirname, '../../lua/StorageMan.lua'), 'utf8');

/**
 * The source with `--` comments stripped.
 *
 * Needed because the comments here deliberately QUOTE the banned call -- explaining which call
 * spent the last fuel on cobblestone is most of the value of the comment. Matching raw source made
 * the guard fire on its own explanation, and the tempting fix (delete the sentence) trades a real
 * piece of institutional memory for a green test.
 */
const CODE = SRC.replace(/--.*$/gm, '');

/**
 * Pull `string.find(p_Name, "<pat>", ...) ... return <n>` pairs out of smeltRank's body, so the
 * test reads the ranking the code actually implements rather than a copy of it kept in sync by
 * hand. A duplicated table is how a guard silently stops guarding.
 */
function smeltRanks(): Map<string, number> {
  const body = /local function smeltRank\(p_Name\)([\s\S]*?)\nend/.exec(CODE);
  expect(body, 'smeltRank must exist -- it is what makes the ordering deliberate').toBeTruthy();
  const ranks = new Map<string, number>();
  for (const line of body![1].split('\n')) {
    const rank = /return\s+(\d+)/.exec(line);
    if (!rank) continue;
    for (const m of line.matchAll(/string\.find\(p_Name,\s*"([^"]+)"/g)) {
      ranks.set(m[1], Number(rank[1]));
    }
  }
  return ranks;
}

describe('furnace input priority', () => {
  it('picks smelt input through a ranked chooser, never an arbitrary pairs() scan', () => {
    // The exact call that spent the last fuel on cobblestone. firstInStorage returns whatever the
    // hash order coughs up first; for a "which is worth most" question that is a coin flip.
    expect(CODE).not.toMatch(/firstInStorage\(isSmeltableInput\)/);
    expect(CODE).toMatch(/local function bestSmeltInput\(\)/);
  });

  it('smelts logs before ore, and ore before cobblestone', () => {
    const r = smeltRanks();
    const log = r.get('_log');
    const raw = r.get('raw_');
    const cobble = r.get('cobble');
    expect(log, 'logs must be ranked: charcoal is the only fuel-positive smelt').toBeDefined();
    expect(raw, 'raw ore must be ranked').toBeDefined();
    expect(cobble, 'cobblestone must be ranked, and ranked last').toBeDefined();

    // Strict: equal ranks put the decision back in pairs() order, which is the original bug.
    expect(log!).toBeLessThan(raw!);
    expect(raw!).toBeLessThan(cobble!);
  });

  it('keeps fuel out of the input ranking', () => {
    // isSmeltableInput excludes fuel, and it must stay that way: coal is "smeltable" in the sense
    // that the furnace accepts it, and feeding the fuel supply into the input slot to be consumed
    // as ore would be the most expensive possible way to lose it.
    expect(CODE).toMatch(/isSmeltableInput\(p_Name\)\s+return isSmeltable\(p_Name\) and not isFuel\(p_Name\)/);
  });
});

/**
 * A FURNACE MUST NOT BURN THE SETTLEMENT'S LAST FUEL ON SOMETHING THAT MAKES NONE.
 *
 * Ranking logs above ore is a preference, not a limit: with no logs in stock the chooser fell
 * through to raw ore and spent every coal on it. Two 64-coal bootstraps went that way in one
 * session -- storage to 0 burnable, copper_ingot to 681, three drones at zero fuel and nothing able
 * to fetch more. The settlement converted the one thing it cannot make into ingots it has no use
 * for, twice.
 *
 * Below the reserve, only the fuel-POSITIVE smelt is allowed in: a furnace either grows the fuel
 * supply or stays cold.
 */
describe('furnaces during a fuel shortage', () => {
  it('smelts only rank-1 (fuel-positive) input when storage fuel is scarce', () => {
    const body = /local function bestSmeltInput\(\)([\s\S]*?)\nend/.exec(CODE);
    expect(body, 'bestSmeltInput must exist').toBeTruthy();
    // The scarcity test must be present AND must gate the candidate, not merely be computed.
    expect(body![1]).toMatch(/fuelInStorage\(\)\s*<\s*SMELT_FUEL_RESERVE/);
    expect(body![1], 'scarcity must restrict the choice to rank 1').toMatch(/r\s*==\s*1/);
  });

  it('counts fuel by the same predicate the furnaces load with', () => {
    // fuelInStorage must use isFuel, not its own list -- two lists of what burns is how one of them
    // silently stops matching charcoal.
    const body = /local function fuelInStorage\(\)([\s\S]*?)\nend/.exec(CODE);
    expect(body).toBeTruthy();
    expect(body![1]).toMatch(/isFuel\(/);
  });
});

/**
 * THE RANKING IS DEAD CODE IF THE GATE ABOVE IT SAYS NO.
 *
 * smeltRank puts logs FIRST, as the only fuel-positive smelt in the settlement. isSmeltable --
 * which decides whether a thing may enter a furnace at all -- listed eight ores and sands and a
 * `_ore$` pattern, and a log is neither. So the furnaces refused wood and the ranking never got a
 * say, while the diagnostic reported "input=yes" because ore qualified.
 *
 * Measured with 255 oak logs in storage and both furnaces lit: cobblestone and raw iron went in,
 * charcoal stayed at 0. Two functions, one question, opposite answers.
 */
describe('wood is smeltable', () => {
  it('isSmeltable accepts logs, or the whole charcoal chain is unreachable', () => {
    const body = /local function isSmeltable\(p_Name\)([\s\S]*?)\nend/.exec(CODE);
    expect(body, 'isSmeltable must exist').toBeTruthy();
    expect(body![1], 'logs must pass the smeltable gate').toMatch(/_log\$/);
  });

  it('accepts any species, not just oak', () => {
    // Hard-coding oak is how a fleet standing in a birch forest starves next to firewood -- the
    // same lesson the planks recipe already carries in the HQ recipe table.
    const body = /local function isSmeltable\(p_Name\)([\s\S]*?)\nend/.exec(CODE)![1];
    expect(body).not.toMatch(/oak_log/);
  });

  it('still ranks that log above ore, so the two agree', () => {
    const r = smeltRanks();
    expect(r.get('_log')!).toBeLessThan(r.get('raw_')!);
  });
});
