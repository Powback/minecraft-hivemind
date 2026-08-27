/**
 * The supply loop: notice a shortage, send the right drone at it.
 *
 * Everything the fleet can do has been reactive until now -- a human decides a material is needed,
 * looks up where it is, and issues an order. Meanwhile four drones sit on their docks. This closes
 * that: stock is compared against targets on a timer, and each deficit becomes the job that fixes
 * it. Miners mine, scouts scan, and nobody has to be watching.
 *
 * Deliberately conservative, because an autonomous loop that dispatches badly is worse than one
 * that does nothing:
 *
 *   * ONE auto-task in flight at a time. The fleet is small and a queue of speculative work is
 *     impossible to reason about when something goes wrong.
 *   * Only dispatches when a drone of the required role is actually idle, so it never competes
 *     with work a human ordered.
 *   * A cooldown per material, so a job that fails to raise stock -- the vein was exhausted, the
 *     site was unreachable -- does not re-fire every tick forever.
 *   * Gather only for materials the survey has actually located. "We need iron" with no iron in
 *     the index is a request to SCAN, not to dig hopefully.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { bridge } from '../bridge/ws.js';
import { registry } from '../tools/registry.js';
import { luaList } from '../lua-table.js';
import { settlement, withinReach } from '../world/settlement.js';

export interface SupplyRule {
  /** The BLOCK to go and mine, e.g. "coal_ore". */
  match: string;
  /**
   * The ITEM to count in storage, when it differs from the block mined.
   *
   * These are not the same thing and conflating them breaks the loop silently: mining
   * minecraft:coal_ore yields minecraft:coal, so counting "coal_ore" in storage always returns
   * zero, the material looks permanently short, and the loop re-dispatches for ever while the
   * chest fills up. Defaults to `match` with a trailing _ore removed, which is right for every
   * vanilla ore.
   */
  stock?: string;
  /** Dispatch when storage holds fewer than this. */
  min: number;
  /**
   * How to get more.
   *
   * `craft` is what makes the loop reach anything the fleet MAKES rather than digs. Without it the
   * recipe graph was only reachable by hand: the fleet could notice it was short of coal and go
   * mine some, and could not notice it was short of chests, because "short of chests" was not
   * something a rule could say.
   */
  action: 'gather' | 'lumber' | 'craft' | 'mine';
  /** Cap for a single dispatch. */
  limit?: number;
  /** For `mine`: what depth to prospect at. Iron and coal live far below any surface scan. */
  depth?: number;
}

/** Sensible starting policy. Tune with the supply.policy tool rather than editing this. */
export const DEFAULT_RULES: SupplyRule[] = [
  // EVERY ORE THE FLEET CAN USE, not just the two it started with.
  //
  // The miners were never the problem: looksValuable matches any "_ore", so a drone takes whatever
  // it walks past. The gap was here -- with rules for coal and iron only, nothing ever DISPATCHED a
  // gather for anything else, so 354 copper, 161 zinc and 19 lapis sat located on the map and
  // untouched while scouts were sent to look for more of the two materials that had rules.
  //
  // `match` is a substring, so each of these also picks up its deepslate variant.
  { match: 'coal_ore', min: 32, action: 'gather', limit: 64, depth: 50 },
  { match: 'iron_ore', min: 32, action: 'gather', limit: 64, depth: 35 },
  { match: 'copper_ore', min: 32, action: 'gather', limit: 64, depth: 45 },
  { match: 'zinc_ore', min: 32, action: 'gather', limit: 64, depth: 40 },
  // Redstone is the binding constraint on storage itself: a chest is invisible to StorageMan
  // without a wired modem, and a modem is 8 stone and a redstone. The base filled to 21 free slots
  // with sixteen unplaced chests in inventory for exactly this reason.
  { match: 'redstone_ore', min: 32, action: 'gather', limit: 64, depth: 12 },
  { match: 'lapis_ore', min: 16, action: 'gather', limit: 32, depth: 20 },
  { match: 'gold_ore', min: 16, action: 'gather', limit: 32, depth: 20 },
  { match: 'diamond_ore', min: 8, action: 'gather', limit: 32, depth: 0 },
  { match: 'dirt', min: 64, action: 'gather', limit: 64 },
  { match: 'oak_log', min: 32, action: 'lumber' },
  // Made, not dug. Planks gate every build the settlement will ever do, and chests gate field
  // caches -- so the fleet should keep a working stock of both without being asked.
  { match: 'minecraft:oak_planks', stock: 'minecraft:oak_planks', min: 32, action: 'craft', limit: 32 },
  { match: 'minecraft:chest', stock: 'minecraft:chest', min: 4, action: 'craft', limit: 4 },
];

/**
 * How long to leave a material alone after acting on it.
 *
 * Ten minutes was chosen when the cooldown was the ONLY thing stopping the loop re-dispatching the
 * same shortage every tick. The queue check does that job properly now -- it refuses to add work a
 * material already has -- so this only needs to stop a material that keeps FAILING from being
 * retried instantly. Three minutes is enough for that, and ten meant five idle drones and two
 * materials at 0/32 sitting out most of every hour.
 */
const COOLDOWN_MS = 3 * 60 * 1000;

/** What to COUNT for a rule, as opposed to what to mine. */
export function stockKey(r: SupplyRule): string {
  return r.stock ?? r.match.replace(/_ore$/, '');
}

export interface SupplyState {
  enabled: boolean;
  rules: SupplyRule[];
  lastRun: number;
  lastAction?: string;
  cooldowns: Record<string, number>;
  dispatched: number;
  log: string[];
  /** How far along the exploration spiral the fleet has got. Persisted -- see frontier(). */
  frontier?: number;
}

/**
 * Autonomy has to SURVIVE A RESTART.
 *
 * This state was in memory only, so every HQ rebuild silently switched the loop back off. The
 * fleet then sat idle looking perfectly healthy, and the reason was invisible -- nothing had
 * failed, a deploy had just quietly revoked the decision to be autonomous. Turning it on is an
 * explicit choice by the operator; a container restart is not a reason to un-make it.
 *
 * Rules persist too: a policy tuned through supply.set is exactly the kind of thing nobody
 * remembers having changed, so losing it is worse than losing the flag.
 */
const STATE_DIR = process.env.STATE_DIR ?? '/state';
const SUPPLY_FILE = join(STATE_DIR, 'supply.json');

/**
 * Saved policy on top of current defaults, field by field.
 *
 * A saved rule keeps every value the operator set. Anything the default has and the saved copy does
 * not is filled in -- that is precisely the case a wholesale replace gets wrong. Rules that exist
 * only in the save are kept too, since they were added deliberately.
 */
function mergeRules(defaults: SupplyRule[], saved: SupplyRule[]): SupplyRule[] {
  const out = defaults.map((d) => {
    const s = saved.find((r) => r.match === d.match);
    return s ? { ...d, ...s, depth: s.depth ?? d.depth } : { ...d };
  });
  for (const s of saved) if (!out.some((r) => r.match === s.match)) out.push(s);
  return out;
}

function loadSupply(): SupplyState {
  const base: SupplyState = {
    enabled: false,        // opt in explicitly; an autonomous fleet should not start itself
    rules: [...DEFAULT_RULES],
    lastRun: 0,
    cooldowns: {},
    dispatched: 0,
    frontier: 0,
    log: [],
  };
  try {
    const raw = JSON.parse(readFileSync(SUPPLY_FILE, 'utf8'));
    return {
      ...base,
      enabled: raw.enabled === true,
      // MERGE, do not replace.
      //
      // Persisted rules shadowed the defaults entirely, so any field ADDED to a default rule later
      // never reached a running deployment -- the saved copy simply lacked it. That is how both ore
      // rules ended up with no `depth`: prospecting requires one, the saved policy predated it, and
      // the fallback that sends a miner underground could never fire. The loop reported "nothing to
      // dispatch" with two materials at 0/32 and five idle drones, and it was right -- it had no
      // way to act that it could see.
      //
      // Operator tuning still wins; it just no longer discards fields it has never heard of.
      rules: mergeRules(base.rules, Array.isArray(raw.rules) ? raw.rules : []),
      dispatched: typeof raw.dispatched === 'number' ? raw.dispatched : 0,
      frontier: typeof raw.frontier === 'number' ? raw.frontier : 0,
    };
  } catch {
    return base;
  }
}

export const supply: SupplyState = loadSupply();

/**
 * WHERE TO LOOK NEXT.
 *
 * The prospecting survey was dispatched as `{ w: 8, h: 8, radius: 8 }` -- a grid size and nothing
 * else. No region, no position. A scout given that scans wherever it happens to be standing, so
 * three scouts parked in three unrelated places rescanned the same ground indefinitely while the
 * map stayed blank everywhere they were not, and the loop dutifully reported "survey dispatched"
 * every time. Searching for something you have never seen without going anywhere new cannot work.
 *
 * A spiral outward from the base, one tile per dispatch, with the cursor persisted. It is not
 * clever, and that is the point: it is EXHAUSTIVE, it never revisits, it degrades gracefully if a
 * tile fails, and after N dispatches you can say exactly which ground the fleet has walked. A
 * cleverer heuristic that chases ore concentrations tends to circle the same promising area and
 * leave the rest of the world dark.
 */
/**
 * WHERE THE SETTLEMENT IS. NOT A CONSTANT -- IT MOVED, AND THIS DID NOT.
 *
 * These were the previous world's coordinates, left behind when the settlement was re-founded 400
 * blocks away. Every survey the loop dispatched aimed at ground the fleet could not reach and would
 * not have been chunk-loaded if it had, so the map stayed at zero known blocks while the loop
 * reported itself healthy. A hardcoded home is a bug waiting for the first time home changes.
 *
 * HIVE_BASE_X / HIVE_BASE_Z override it; the default is the tower's centre, and the region is
 * derived from the base rather than written out separately, so the two cannot drift apart.
 */
const BASE = settlement.base;
const TILE = 24;
/** How far out the fleet is allowed to work, as a radius from base. */
const REACH = settlement.reach;
const REGION = {
  minX: BASE.x - REACH, maxX: BASE.x + REACH,
  minZ: BASE.z - REACH, maxZ: BASE.z + REACH,
};

type Pt = { x: number; y: number; z: number };
function frontier(): { min: Pt; max: Pt } | null {
  // Walk the spiral from the start each time and take the nth valid tile. The spiral is a few
  // hundred steps at most, so recomputing costs nothing and needs no stored geometry -- only an
  // integer, which is what makes the cursor safe to persist across restarts and code changes.
  const want = supply.frontier ?? 0;
  let x = 0, z = 0, dx = 0, dz = -1, found = 0;
  for (let i = 0; i < 4096; i++) {
    const cx = BASE.x + x * TILE;
    const cz = BASE.z + z * TILE;
    const min = { x: cx - TILE / 2, y: 58, z: cz - TILE / 2 };
    const max = { x: cx + TILE / 2, y: 95, z: cz + TILE / 2 };
    // Only tiles wholly inside the loaded region. A survey ordered outside it sends a drone
    // somewhere it will stop ticking and be lost, which is a far worse outcome than a gap.
    if (min.x >= REGION.minX && max.x <= REGION.maxX
        && min.z >= REGION.minZ && max.z <= REGION.maxZ) {
      if (found === want) return { min, max };
      found++;
    }
    // Standard square spiral: turn at the corners.
    if (x === z || (x < 0 && x === -z) || (x > 0 && x === 1 - z)) { const t = dx; dx = -dz; dz = t; }
    x += dx; z += dz;
  }
  return null;
}



export function saveSupply(): void {
  try {
    mkdirSync(dirname(SUPPLY_FILE), { recursive: true });
    writeFileSync(SUPPLY_FILE, JSON.stringify(
      { enabled: supply.enabled, rules: supply.rules, dispatched: supply.dispatched }, null, 2));
  } catch (err) {
    console.error(`[supply] could not persist ${SUPPLY_FILE}: ${(err as Error).message}`);
  }
}

function note(msg: string) {
  supply.log.unshift(`${new Date().toISOString().slice(11, 19)} ${msg}`);
  supply.log.length = Math.min(supply.log.length, 40);
}

async function callTool(name: string, args: unknown) {
  return registry.invoke(name, args, { agent: 'supply', callId: `supply-${Date.now()}`, log: () => {} });
}

/** One pass. Returns what it did, for the tool and the tests. */
/**
 * Total fleet fuel below which the supply loop dispatches nothing but coal.
 *
 * Three drones topping up to 2,500 each is 7,500, and the fleet burns roughly 120 fuel a minute
 * working. 4,000 leaves well over half an hour of margin to find, cut and carry coal home before
 * anything is actually at risk -- while being low enough that a healthy fleet still spends most of
 * its time on the other materials.
 */
const FUEL_PRIORITY_BELOW = 4000;

/**
 * Everything one rule's dispatch is allowed to see and change.
 *
 * The three `*Free` flags are deliberately MUTABLE and shared: each role may take one job per tick,
 * so a rule that dispatches a miner has to stop the next rule dispatching another one. They were
 * plain `let`s in a 450-line function, which is exactly the kind of state that is invisible until
 * it is wrong.
 */
export type SupplyCtx = {
  now: number;
  queued: Set<string>;
  did: string[];
  waiting: string[];
  minerFree: boolean;
  scoutFree: boolean;
  crafterFree: boolean;
  idleCrafter: unknown;
  held: (m: string) => number;
};

/**
 * Why this rule is not dispatched this tick, or null to go ahead. PURE -- no I/O, no mutation.
 *
 * Extracted because the fuel-priority test could not reach it. That test re-implemented this
 * decision as a two-line copy and asserted against the copy, so it passed whatever supply.ts did:
 * a test shaped exactly like the bug it was written for, checking a duplicate of the code instead
 * of the code. It now imports this function.
 */
export function ruleSkipReason(
  rule: SupplyRule,
  gate: { fuelCritical: boolean; have: number; cooldownUntil: number; now: number },
): { kind: 'fuel' | 'satisfied' | 'cooldown'; message?: string } | null {
  // Coal, charcoal or anything else that burns; everything else waits until the fleet can move.
  if (gate.fuelCritical && !/coal/.test(rule.match)) return { kind: 'fuel' };
  if (gate.have >= rule.min) return { kind: 'satisfied' };
  // Say when a cooldown is the reason. Skipping silently makes "waiting a few minutes" look exactly
  // like "nothing to do", which is how idle drones and an empty log get read as a broken scheduler
  // rather than a timer.
  if (gate.cooldownUntil > gate.now) {
    const secs = Math.ceil((gate.cooldownUntil - gate.now) / 1000);
    return { kind: 'cooldown', message: `${rule.match} (${secs}s cooldown)` };
  }
  return null;
}

/**
 * Go and LOOK. gather can only revisit coordinates the map already holds, so a material that has
 * never been seen -- iron, at depth, below anything a surface scan can reach -- is unreachable by
 * any amount of gathering. This is the job that changes that.
 */
async function dispatchMine(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if (!ctx.minerFree) return false;
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  const r: any = await callTool('order.prospect', { depth: rule.depth ?? 40 });
  if (r?.ok === false) {
    note(`${rule.match}: ${have}/${rule.min}, prospecting refused — ${r?.error ?? '?'}`);
    return false;
  }
  ctx.minerFree = false;
  supply.dispatched++;
  supply.lastAction = `prospect for ${rule.match}`;
  note(`${rule.match}: ${have}/${rule.min} → prospecting at y=${rule.depth ?? 40}`);
  ctx.did.push(`prospect ${rule.match}`);
  return true;
}

async function dispatchCraft(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if ([...ctx.queued].some((n) => n.startsWith(`craft-${stockKey(rule).replace(/^.*:/, '')}`))) {
    note(`${rule.match}: ${have}/${rule.min}, already being crafted`);
    return false;
  }
  // Needs a crafter, not a miner. Nothing else can serve the job, so waiting for one is the correct
  // behaviour rather than dispatching it at a drone that will refuse at the last step.
  if (!ctx.idleCrafter) return false;               // no cooldown burned: retry when one frees up
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  // The TARGET, not the deficit. expand() already subtracts what storage holds, so passing
  // (target - have) subtracts the same stock twice: asking for "8 more chests" while holding 8
  // planned to zero steps and the loop reported "nothing craftable" with a full chest.
  const want = rule.limit ?? rule.min;
  const r: any = await callTool('plan.execute', { item: stockKey(rule), quantity: want });
  const steps = r?.data?.queued ?? r?.queued ?? [];
  if (!steps.length) {
    note(`${rule.match}: ${have}/${rule.min}, nothing craftable — ${JSON.stringify(r?.data?.unsourced ?? [])}`);
    return false;
  }
  ctx.crafterFree = false;
  supply.dispatched++;
  supply.lastAction = `craft ${stockKey(rule)}`;
  note(`${rule.match}: ${have}/${rule.min} → craft x${want} queued (${steps.length} steps)`);
  ctx.did.push(`craft ${stockKey(rule)}`);
  return true;
}

/**
 * Dig it if we know where it is; prospect if we have never seen it; survey if neither.
 *
 * The order matters and the last two rungs are not interchangeable. gather can only revisit
 * coordinates the map already holds, and a surface survey cannot reach ore at depth -- a scanner
 * sees 8 blocks and iron is fifty below. A material that has NEVER been seen is a prospecting
 * problem, not a gathering one. Without the prospect rung the loop fell straight through to "wait
 * for a scout" and sat there with three idle miners and coal at 0/32.
 */
async function dispatchGather(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  // Ask for the dig first, but only if a miner could actually take it.
  if (ctx.minerFree) {
    const r: any = await callTool('order.gather', { match: rule.match, limit: rule.limit ?? 64 });
    if (r?.ok !== false) {
      supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
      ctx.minerFree = false;
      supply.dispatched++;
      supply.lastAction = `gather ${rule.match}`;
      note(`${rule.match}: ${have}/${rule.min} → gather dispatched`);
      ctx.did.push(`gather ${rule.match}`);
      return true;
    }
  }

  if (ctx.minerFree && rule.depth !== undefined
      && ![...ctx.queued].some((n) => n.startsWith('shaft-'))) {
    supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
    const p: any = await callTool('order.prospect', { depth: rule.depth });
    if (p?.ok !== false) {
      ctx.minerFree = false;
      supply.dispatched++;
      supply.lastAction = `prospect for ${rule.match}`;
      note(`${rule.match}: ${have}/${rule.min}, none known -> prospecting at y=${rule.depth}`);
      ctx.did.push(`prospect ${rule.match}`);
      return true;
    }
    note(`${rule.match}: prospecting refused -- ${p?.error ?? '?'}`);
  }

  return dispatchSurvey(rule, have, ctx);
}

/** Last rung: nothing known and nothing to prospect for -- send a scout to look. */
async function dispatchSurvey(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  // Say so rather than skipping in silence: "no scout free" and "nothing to do" are different
  // states and looked identical in the log.
  if (!ctx.scoutFree) {
    ctx.waiting.push(`${rule.match} (no scout free)`);
    return false;
  }
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  let area = frontier();
  if (!area) {
    // WRAP, don't stop. The spiral walking off the edge of the loaded region is not the same as the
    // region being fully surveyed -- the cursor is a position, not a completion record, and a
    // survey that failed still advanced it. Left as a dead end the loop simply stopped exploring
    // for good, which is what happened here: the last prospecting run was two hours before anyone
    // noticed.
    supply.frontier = 0;
    area = frontier();
    if (!area) { note(`${rule.match}: no surveyable tile inside the loaded region`); return false; }
    note('exploration frontier wrapped -- starting another pass from the base outward');
  }
  supply.frontier = (supply.frontier ?? 0) + 1;
  await bridge.call('TaskMan', 'Add', {
    name: `find-${rule.match}`,
    priority: 3,
    work: { survey: { kind: 'explore', radius: 8, min: area.min, max: area.max } },
  }, { timeoutMs: 8000 });
  ctx.scoutFree = false;
  supply.dispatched++;
  supply.lastAction = `survey for ${rule.match}`;
  note(`${rule.match}: ${have}/${rule.min}, none known → survey tile ${supply.frontier} `
     + `at ${area.min.x},${area.min.z}..${area.max.x},${area.max.z}`);
  ctx.did.push(`survey for ${rule.match}`);
  return true;
}

/** One rule, start to finish. Throwing is contained by the caller so one bad rule cannot end the tick. */
async function dispatchRule(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if (rule.action === 'mine') return dispatchMine(rule, have, ctx);
  if (rule.action === 'craft') return dispatchCraft(rule, have, ctx);
  if (rule.action !== 'gather') {
    supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
    note(`${rule.match}: ${have}/${rule.min} → ${rule.action} not yet automatable`);
    return false;
  }
  return dispatchGather(rule, have, ctx);
}

/**
 * Read the queue's FAILURES back into the planner.
 *
 * Returns a tick result when it re-planned something -- the re-plan IS the action, so the tick
 * ends there -- or null to carry on with the rest of the pass.
 */
async function replanShortfalls(): Promise<{ acted: boolean; reason: string } | null> {
// A SHORTFALL FOUND AT RUNTIME IS A PLANNING INPUT, NOT JUST A FAILURE.
//
// plan.execute builds the dependency chain ONCE, from the stock it can see at that moment. When a
// craft later runs short -- because the intermediate got consumed, or the first pass only made a
// partial batch -- nothing notices. craft-chest sat "failing: nothing available for oak_planks"
// while sixteen oak logs sat in a chest and a crafter stood idle beside them: every fact needed to
// fix it was known, and no loop connected them. That is the whole point of having a tree.
//
// So read the failures and re-plan what they are short of. plan.execute is idempotent-ish (it
// queues nothing when stock already satisfies the goal) and dedupes by task name in TaskMan, so
// re-running it costs nothing when the answer has not changed.
try {
  const tl: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 5000 });
  const tasks = luaList(tl?.tasks ?? tl?.data?.tasks ?? []) ?? [];
  const shortOf = new Set<string>();
  for (const t of tasks) {
    const why = String((t as any)?.failure ?? '');
    // "nothing available for: minecraft:oak_planks" / "short of minecraft:oak_log x8"
    const m = why.match(/(?:nothing available for|short of)\s*:?\s*([a-z0-9_]+:[a-z0-9_]+)/i);
    if (m) shortOf.add(m[1]);
  }
  for (const item of shortOf) {
    try {
      const r: any = await callTool('plan.execute', { item, quantity: 16 });
      const rd = r?.data ?? r;
      const queued = (rd?.queued ?? []).length;
      if (queued > 0) {
        supply.dispatched += queued;
        note(`a task was short of ${item} -- re-planned it, ${queued} step(s) queued`);
        return { acted: true, reason: `re-planned ${item} for a failing task` };
      }
    } catch { /* not craftable from what we have; the failure stands and is reported as such */ }
  }
} catch (err) {
  note(`shortfall re-plan: ${(err as Error)?.message ?? err}`);
}
  return null;
}

/**
 * Which materials already have a gather in flight.
 *
 * ONE LIVE GATHER PER MATERIAL. TaskMan's name dedup only looks at tasks still queued, so once a
 * gather is ASSIGNED its name is free again -- and the top-up, running every sixty seconds,
 * cheerfully queued another. Ten identical gather:oak_log tasks piled up, each claiming a drone for
 * the same 192 candidates. That is worse than idling: the fleet looks fully occupied while several
 * drones re-walk ground another drone has already cleared.
 */
function materialsBeingGathered(tasks: unknown[]): Set<string> {
  const live = new Set<string>();
  for (const t of tasks) {
    const nm = String((t as any)?.name ?? '');
    if (nm.startsWith('gather:') && ((t as any).progress ?? 0) < 100) {
      live.add(nm.slice('gather:'.length));
    }
  }
  return live;
}

/**
 * Top the queue up to the idle-drone count, so no drone is idle purely for want of a task.
 *
 * Returns a tick result when it queued something -- topping up IS the action for this tick -- or
 * null to carry on.
 */
async function topUpQueue(live: any[]): Promise<{ acted: boolean; reason: string } | null> {
// KEEP THE QUEUE AS DEEP AS THE FLEET.
//
// Every task takes exactly one drone, so a queue shorter than the idle count leaves the remainder
// standing still by arithmetic -- and this loop dispatched ONE thing per tick with cooldowns, which
// cannot keep up with a fleet that just grew from five drones to fifteen. Ten miners sat idle in a
// row, fighting each other for space, while the world was full of wood and ore nobody had been
// told to fetch. Idle is not a resting state here: it means the settlement has stopped growing.
//
// So: count the idle, count the queue, and top up from what the map actually knows about. Nothing
// speculative -- order.gather refuses anything unsurveyed and is region-filtered and nearest-first.
try {
  const idleCount = live.filter((d: any) => d.status === 'idle').length;
  if (idleCount > 0) {
    const tl: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 5000 });
    const tasks = luaList(tl?.tasks ?? tl?.data?.tasks ?? []) ?? [];
    const open = tasks.filter((t: any) =>
      t && t.state !== 'done' && t.state !== 'failed' && !t.assigned).length;
    const wanted = idleCount - open;
    if (wanted > 0) {
      // Cycled, so one plentiful material cannot crowd out the rest of the economy.
      const MATERIALS = ['oak_log', 'coal_ore', 'iron_ore', 'copper_ore',
                         'zinc_ore', 'lapis_ore', 'sand', 'gravel'];

      // ONE LIVE GATHER PER MATERIAL.
      //
      // TaskMan dedupes by name only against tasks still QUEUED, so once a gather is assigned the
      // name is free again -- and this loop, running every sixty seconds, cheerfully queued
      // another. Ten identical gather:oak_log tasks piled up, each one claiming a drone for the
      // same 192 candidates, which is worse than idling: the fleet looks fully occupied while
      // several drones re-walk ground another drone already cleared.
      const liveFor = materialsBeingGathered(tasks);

      let queued = 0;
      for (const m of MATERIALS) {
        if (queued >= wanted) break;
        if (liveFor.has(m)) continue;          // already being worked; queuing another wastes a drone
        try {
          const g: any = await callTool('order.gather', { match: m, limit: 64 });
          const gd = g?.data ?? g;
          if (gd?.dispatched) {
            queued++;
            supply.dispatched++;
            note(`${idleCount} drone(s) idle with ${open} unassigned task(s) -- queued gather:${m}`);
          }
        } catch { /* nothing surveyed for it; try the next material */ }
      }
      if (queued > 0) return { acted: true, reason: `topped up the queue with ${queued} gather(s)` };
    }
  }
} catch (err) {
  note(`queue top-up: ${(err as Error)?.message ?? err}`);
}
  return null;
}

/**
 * A cave is the best possible place to send a scanner: the ore is already EXPOSED, so a single
 * scan sees far more than the same scan in solid rock. world.caves had been finding them for a
 * long time and absolutely nothing consumed the result.
 */
/**
 * Pad a cave's bounding box outward.
 *
 * A scan centred inside an open pocket mostly reads air. The interesting part of a cave is the rock
 * AROUND it, which is where the exposed ore actually sits.
 */
function padCaveBox(c: any) {
  return {
    min: { x: c.min.x - 4, y: Math.max(0, c.min.y - 4), z: c.min.z - 4 },
    max: { x: c.max.x + 4, y: c.max.y + 4, z: c.max.z + 4 },
  };
}

/**
 * WHICH CAVES ARE WORTH SENDING A SCOUT TO. Pure, so the rule can be tested without a world.
 *
 * THE CAVE INDEX OUTLIVED THE REGION IT WAS BUILT IN. world.caves reads the block index, which
 * still holds pockets found when the operating area was a larger square. The drone is sent to
 * `cave.min`, and six of these sat in the queue targeting points 75-78 blocks out against a reach
 * of 56 -- permanently "could not reach the survey start", re-dispatched for ever, each attempt
 * spending a scout and its fuel on a trip that could not finish. Two had been retrying since task
 * #2919, and the newest was #4756: an open tap, not old debris.
 *
 * settlement.ts states the rule and place.ts obeys it; this path simply never asked. Check the
 * point the drone is actually SENT to, not the cave's centre -- a cave can straddle the boundary.
 */
export function caveCandidates(list: any[]): Array<{ cave: any; box: ReturnType<typeof padCaveBox> }> {
  const out: Array<{ cave: any; box: ReturnType<typeof padCaveBox> }> = [];
  for (const c of list ?? []) {
    if (!c?.min || !c?.max) continue;
    if (!withinReach(c.min)) continue;
    out.push({ cave: c, box: padCaveBox(c) });
  }
  return out;
}

async function dispatchCaveSurvey(ctx: SupplyCtx, c: any, box: any, pct: number): Promise<void> {
  await bridge.call('TaskMan', 'Add', {
    name: `cave-${c.min.x},${c.min.y},${c.min.z}`,
    priority: 2,
    work: { survey: { kind: 'scout', radius: 8, min: box.min, max: box.max } },
  }, { timeoutMs: 8000 });
  ctx.scoutFree = false;
  supply.dispatched++;
  supply.lastAction = `cave survey at ${c.min.x},${c.min.y},${c.min.z}`;
  note(`cave of ${c.size ?? '?'} cells at ${c.min.x},${c.min.y},${c.min.z} is ${pct}% mapped -> scout dispatched`);
  ctx.did.push('cave survey');
}

/**
 * EXPLORE THE CAVES. Nobody was.
 *
 * world.caves has found them for a long time -- open pockets with an entrance, complete with their
 * bounding boxes -- and absolutely nothing consumed that. Every cave survey so far was dispatched
 * by hand. Meanwhile the exploration spiral sent scouts to tile solid rock in a fixed pattern,
 * which is the least informative ground there is.
 *
 * A cave is the best possible place to send a scanner: the ore is already EXPOSED, so a single scan
 * sphere reads far more usable material than the same sphere buried in stone, and a miner sent
 * afterwards can reach it without cutting a shaft to get there.
 */
async function surveyCaves(ctx: SupplyCtx): Promise<void> {
  if (!ctx.scoutFree) return;
  try {
    const caves: any = await callTool('world.caves', { min: 8 });
    for (const { cave, box } of caveCandidates(caves?.data?.caves ?? [])) {
      // PERCENT, NOT COVERAGE. `coverage` is a 0-1 fraction and this compares against 60, so the
      // guard could never pass even at 100% mapped -- every cave re-dispatched a survey on every
      // tick for ever. Same mistake at the scout-support guard below.
      const q: any = await callTool('world.query', box);
      const pct = q?.data?.percent ?? 0;
      if (pct >= 60) continue;                          // already read this one
      await dispatchCaveSurvey(ctx, cave, box, pct);
      break;                                            // one per tick
    }
  } catch (err) {
    note(`cave survey: ${(err as Error)?.message ?? err}`);
  }
}

/**
 * Pair a scout with a miner that is digging blind.
 *
 * A geo scanner sees eight blocks THROUGH rock, so a scout standing over a working miner is worth
 * more than one wandering the surface. This is the collaboration the fleet was supposed to have
 * and never did -- pairing existed only inside order.prospect.
 */
async function scoutForMiners(ctx: SupplyCtx): Promise<void> {
// SEND A SCOUT TO WHERE THE MINERS ARE DIGGING BLIND.
//
// This is the collaboration the fleet was supposed to have and never did. Pairing existed only
// inside order.prospect -- a shaft task with a scan task depending on it -- so a miner working
// anywhere else dug through rock nobody had ever scanned while idle scouts were dispatched to
// survey tiles chosen by a spiral that knew nothing about where the fleet actually was. D13
// spent its shift surrounded by unknown terrain with scouts free the whole time.
//
// A geo scanner sees eight blocks THROUGH rock. A scout standing over a working miner is worth
// far more than the same scout surveying open ground on the other side of the base, because what
// it reveals is immediately actionable: the miner turns toward ore instead of past it, and does
// not have to turn at all where the map already answers.
if (ctx.scoutFree) {
  try {
    const fleet: any = await callTool('fleet.status', {});
    const miners = (fleet?.data?.drones ?? []).filter(
      (d: any) => d.role === 'miner' && d.status === 'working' && d.pos?.x !== undefined);

    for (const m of miners) {
      // How well is the ground around this miner mapped? A 24-block box centred on it.
      const half = 12;
      const box = {
        min: { x: m.pos.x - half, y: Math.max(0, m.pos.y - 8), z: m.pos.z - half },
        max: { x: m.pos.x + half, y: m.pos.y + 8, z: m.pos.z + half },
      };
      const q: any = await callTool('world.query', box);
      const cov = q?.data?.percent ?? 0;   // percent: see the cave guard above
      if (cov >= 25) continue;          // already mapped well enough to be useful

      await bridge.call('TaskMan', 'Add', {
        name: `support-${m.name}`,
        priority: 1,                    // ahead of speculative exploration: this has a customer
        work: { survey: { kind: 'assist', radius: 8, min: box.min, max: box.max } },
      }, { timeoutMs: 8000 });
      ctx.scoutFree = false;
      supply.dispatched++;
      supply.lastAction = `scout support for ${m.name}`;
      note(`${m.name} is mining at ${m.pos.x},${m.pos.y},${m.pos.z} with ${cov}% of the `
         + `surrounding rock mapped → scout dispatched to support it`);
      ctx.did.push(`scout support for ${m.name}`);
      break;                            // one per tick; the next tick takes the next miner
    }
  } catch (err) {
    note(`scout support: ${(err as Error)?.message ?? err}`);
  }
}
}

/**
 * The set of task names already outstanding, or a refusal.
 *
 * NOT KNOWING what is queued is a reason to WAIT, not to proceed -- so this returns an explicit
 * refusal rather than an empty set. Treating an unreadable queue as an empty one is how the
 * duplicates got created in the first place.
 */
async function buildQueuedSet(): Promise<{ queued: Set<string> } | { refuse: string }> {
// WHAT IS ALREADY QUEUED.
//
// The cooldown stops a material being re-dispatched every tick, and it does NOT stop the queue
// filling with duplicates over hours: each cooldown expiry adds another identical survey while
// the first one is still waiting for the single scout to become free. Seven copies of
// "find-coal_ore" piled up that way, so the queue looked busy and nothing was being achieved --
// there was one scout and eight jobs that all needed one.
//
// A shortage that already has work outstanding does not need more work; it needs the work to
// finish.
const queued = new Set<string>();
try {
  const res: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 15000 });
  // luaList, not Array.isArray. An EMPTY task queue serialises to {} rather than [], so the
  // array check classed it unreadable -- and the loop then refused to dispatch, which kept the
  // queue empty, which kept it refusing. On a fresh world nothing could ever start.
  const list = luaList<any>(res?.tasks ?? res?.data?.tasks);
  // A REFUSAL COMES BACK AS A VALUE, NOT AN EXCEPTION.
  //
  // PowNet puts an error in the same field a success uses, so a failed GetTasks arrives as a
  // plain string -- and `undefined?.tasks ?? []` then iterates nothing, leaving the dedup set
  // empty with no error raised anywhere. Dedup silently switched itself off and the queue filled
  // with nine copies of the same two surveys. An empty result and an unreadable one look
  // identical and mean opposite things, so they must be told apart explicitly.
  if (list === null) {
    return { refuse: `cannot read the task queue (${typeof res === 'string' ? res : typeof res}); not dispatching blind` };
  }
  // Prefer the COMPLETE name list over the paged task objects. TaskMan caps the task array to
  // stay inside the websocket frame, so counting names from that page under-reports duplicates and
  // the loop cheerfully adds another copy of work already outstanding -- nine find-iron_ore among
  // 159 live tasks with two assigned. The cap was mine and so was the regression.
  const names = luaList<string>(res?.liveNames ?? res?.data?.liveNames);
  if (names && names.length) {
    for (const n of names) if (typeof n === 'string') queued.add(n);
  } else {
    for (const t of list) {
      if ((t?.progress ?? 0) < 100 && typeof t?.name === 'string') queued.add(t.name);
    }
  }
} catch {
  // NOT KNOWING what is queued is a reason to WAIT, not to proceed.
  //
  // Treating an unreadable queue as an empty one is how duplicates got created in the first
  // place: every tick that could not reach TaskMan cheerfully added another survey for a
  // shortage that already had three. A tick skipped costs a minute; a tick that dispatches blind
  // costs a drone and clogs the queue behind it.
  return { refuse: 'cannot read the task queue; not dispatching blind' };
}
  return { queued };
}

/**
 * A SETTLEMENT THAT RUNS OUT OF SLOTS MUST BUILD MORE, NOT STOP.
 *
 * Storage reached 7 chests and ZERO free slots, and everything downstream jammed at once in a way
 * that reads as several unrelated faults: a miner cannot unload, so it cannot pick up coal, so fuel
 * relief fails with "storage had nothing burnable" while 391 coal sits in a chest; a gather returns
 * "took nothing"; a craft cannot bank its output. None of those are the bug. The bug is that the
 * settlement noticed it was full and did nothing about it, and waited for a human to notice.
 *
 * Being full is a SHORTAGE like any other, and the loop already knows how to answer a shortage --
 * it just had no rule that could say "short of somewhere to put things". This is that rule.
 *
 * chest-row is deliberately the cheapest blueprint there is: bare chests, no floor, no modems. A
 * jam is exactly when the settlement cannot afford anything that needs planks, because planks need
 * logs and a log needs a free slot to be deposited into.
 */
const FREE_SLOTS_FLOOR = 6;

/**
 * Free slots across every chest the fleet can actually see, or null when it has seen none.
 *
 * null is NOT zero, and the difference decides whether the settlement starts building: a fresh
 * world with no chest readings yet looks identical to a jammed one if you let an empty list total
 * to zero, and the answer to "we have no readings" is to wait, not to build.
 */
async function observedFreeSlots(): Promise<number | null> {
  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  const chests = luaList<any>(stock?.chests ?? stock?.data?.chests) ?? [];
  if (!chests.length) return null;
  return chests.reduce((n: number, c: any) => n + (Number(c.free) || 0), 0);
}

async function expandStorageIfFull(
  live: any[], queued: Set<string>,
): Promise<{ acted: boolean; reason: string } | null> {
  // Any live drone will do -- RoleForWork sends builds to a miner, and miners are the general
  // workers. Waiting for a specific role here would make the settlement stay jammed because the
  // wrong kind of drone was free.
  if (!live.length) return null;
  // DO NOT STACK EXPANSIONS, AND DO NOT TRUST A TIMER TO PREVENT IT.
  //
  // The first version guarded only on a three-minute cooldown, which is not the same question: the
  // cooldown expires while the previous build is still outstanding, so at 0 free slots this queued
  // build-chest-row-storage-03, -05, -06, -07 and -08 -- the duplicate-task problem again, in a new
  // costume, from the rule that was supposed to be fixing things. An outstanding build IS the
  // answer to "should I queue a build", and it is a fact rather than a guess about elapsed time.
  //
  // The cooldown stays as a second line of defence for the window between queueing and the task
  // appearing in the list.
  if ([...queued].some((n) => n.startsWith('build-chest-row'))) return null;
  const until = supply.cooldowns['__storage'] ?? 0;
  if (until > Date.now()) return null;

  const free = await observedFreeSlots();
  if (free === null || free > FREE_SLOTS_FLOOR) return null;

  note(`storage down to ${free} free slot(s) -- expanding before everything jams behind it`);
  try {
    const r: any = await callTool('order.build', { blueprint: 'chest-row' });
    if (r?.ok === false) {
      note(`storage expansion refused -- ${r?.error ?? '?'}`);
      return null;
    }
    supply.cooldowns['__storage'] = Date.now() + COOLDOWN_MS;
    supply.dispatched++;
    supply.lastAction = 'expand storage';
    return { acted: true, reason: `storage was down to ${free} free slots -- queued a chest-row` };
  } catch (err) {
    note(`storage expansion failed -- ${(err as Error)?.message ?? err}`);
    return null;
  }
}

export async function runSupplyTick(): Promise<{ acted: boolean; reason: string }> {
  supply.lastRun = Date.now();
  if (!supply.enabled) return { acted: false, reason: 'disabled' };
  if (!bridge.connected) return { acted: false, reason: 'bridge offline' };

  // Never stack speculative work: if anything is already mining, this loop waits.
  const fleet: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 5000 });
  const drones = fleet?.drones ?? fleet?.data?.drones ?? [];
  // A drone is live only if it is neither flagged offline nor REPORTING an offline-ish status.
  // Checking the flag alone let a dead drone count as "busy" and stalled the whole loop.
  const dead = (d: any) => d.offline === true || d.status === 'offline' || d.status === 'lost';
  const live = drones.filter((d: any) => !dead(d));
  // Gate per ROLE, not across the fleet.
  //
  // This used to bail whenever any drone was working at all, which sounded conservative and was
  // just wrong: a scout surveying and a miner mining do not contend for anything, so one busy
  // miner silently blocked every scan. One scout also covers many miners -- surveying is what
  // makes the next several digs possible -- so making it wait on a free miner had it backwards.
  const idle = (role: string) => live.find((d: any) => (d.role ?? 'miner') === role && d.status === 'idle');

  // FIRST. NOTHING ELSE CAN SUCCEED WHILE THERE IS NOWHERE TO PUT ANYTHING.
  //
  // This used to sit after replanShortfalls and topUpQueue, both of which RETURN EARLY the moment
  // they do anything -- and with ten idle drones the top-up queues a gather almost every tick. So
  // the one rule that could unjam the settlement was placed behind two rules that almost always
  // preempt it, and it effectively never ran: storage sat at 0 free slots with ten drones idle.
  //
  // The ordering is not just about reachability, it is about correctness. Topping up the gather
  // queue while storage is full is actively harmful -- it sends more drones to fetch material that
  // has nowhere to go, and each of them then fails in a way that looks like its own fault.
  // The queue is read FIRST, before any phase decides to add to it. Not knowing what is already
  // outstanding is a reason to wait, not to proceed -- and every phase below can queue work, so
  // every one of them needs the answer. This used to be read halfway down, which is why the storage
  // rule had to guard itself with a timer instead of a fact.
  const q = await buildQueuedSet();
  if ('refuse' in q) return { acted: false, reason: q.refuse };
  const queued = q.queued;

  const expanded = await expandStorageIfFull(live, queued);
  if (expanded) return expanded;

  const replanned = await replanShortfalls();
  if (replanned) return replanned;

  const toppedUp = await topUpQueue(live);
  if (toppedUp) return toppedUp;

  const idleMiner = idle('miner');
  const idleScout = idle('scout');
  const idleCrafter = idle('crafter');
  if (!idleMiner && !idleScout && !idleCrafter)
    return { acted: false, reason: 'no idle miner, scout or crafter' };

  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  // Same shape trap as the task queue: an empty stock detail arrives as {} and .filter is not a
  // function on it, so the very first supply pass in a new world threw before it could decide
  // anything. Empty stock is the NORMAL state of a settlement that has not mined yet -- it is the
  // condition the loop exists to resolve, so it must be the one case it handles cleanly.
  const detail = luaList<any>(stock?.detail ?? stock?.data?.detail) ?? [];
  const held = (m: string) =>
    detail.filter((d: any) => typeof d.name === 'string' && d.name.includes(m))
          .reduce((n: number, d: any) => n + (d.count ?? 0), 0);


  const now = Date.now();
  // Each role can take one job per tick. A tick can therefore start a dig AND a survey, which is
  // the point: the scan that finds the next vein should not have to wait for the current one to
  // finish being mined.
  let minerFree = !!idleMiner;
  let scoutFree = !!idleScout;
  let crafterFree = !!idleCrafter;
  const did: string[] = [];
  const waiting: string[] = [];

  // FUEL IS NOT ONE MATERIAL AMONG MANY. IT IS THE PRECONDITION FOR ALL OF THEM.
  //
  // The rules are walked in order and every one of them reads as short, because StorageMan cannot
  // report stock -- so the loop round-robins through dirt, copper, zinc and lapis regardless of
  // whether the fleet can still move. It was caught doing exactly that: D1 gathering DIRT while
  // total fleet fuel fell from 7,556 to 5,664 and the coal in storage never moved off 129. A fleet
  // that spends its last few thousand fuel on dirt is not self-sustaining, it is just slow to die.
  //
  // So when the tank is low, coal outranks everything. Not a permanent priority -- once there is a
  // comfortable reserve the normal round-robin resumes and the other materials get their turn.
  // LIVE drones, not every drone on the books.
  //
  // This summed the WHOLE fleet, and fuel inside a drone nobody can reach is not fuel the fleet
  // has. Measured at the point of collapse: eleven reachable drones at ZERO fuel, and 41,234 fuel
  // sitting inside five drones that had been silent for six to fifteen hours. The loop read 41,234,
  // concluded there was a comfortable reserve, and went on round-robining dirt and copper while
  // every drone that could actually move ran dry -- which is the exact death spiral the threshold
  // exists to prevent, entered through the one input nobody checked.
  //
  // `live` already excludes offline and lost drones; it just was not used here.
  const fleetFuel = live.reduce((n: number, d: any) => n + (Number(d.fuel) || 0), 0);
  const fuelCritical = fleetFuel < FUEL_PRIORITY_BELOW;
  if (fuelCritical) note(`fleet fuel ${fleetFuel} below ${FUEL_PRIORITY_BELOW} -- coal only this tick`);

  const ctx: SupplyCtx = {
    now, queued, did, waiting,
    minerFree, scoutFree, crafterFree,
    idleCrafter, held,
  };
  for (const rule of supply.rules) {
    if (!ctx.minerFree && !ctx.scoutFree && !ctx.crafterFree) break;
    const have = held(stockKey(rule));
    const skip = ruleSkipReason(rule, {
      fuelCritical, have, now,
      cooldownUntil: supply.cooldowns[rule.match] ?? 0,
    });
    if (skip) {
      if (skip.message) waiting.push(skip.message);
      continue;
    }
    try {
      await dispatchRule(rule, have, ctx);
    } catch (err) {
      supply.cooldowns[rule.match] = now + COOLDOWN_MS;
      note(`${rule.match}: dispatch failed — ${(err as Error)?.message ?? err}`);
    }
  }
  // The dispatchers own these from here; the remaining phases read them back off the context.
  minerFree = ctx.minerFree; scoutFree = ctx.scoutFree; crafterFree = ctx.crafterFree;

  await surveyCaves(ctx);
  await scoutForMiners(ctx);

  if (did.length) return { acted: true, reason: did.join(', ') };
  if (waiting.length) return { acted: false, reason: `waiting on cooldown: ${waiting.join(', ')}` };
  return { acted: false, reason: 'nothing to dispatch' };
}

export function startSupplyLoop(intervalMs = 60_000) {
  setInterval(() => { runSupplyTick().catch(() => { /* reported via note() */ }); }, intervalMs).unref();
}
