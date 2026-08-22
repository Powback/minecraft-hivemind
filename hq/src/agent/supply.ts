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
  { match: 'coal_ore', min: 32, action: 'gather', limit: 64, depth: 50 },
  { match: 'iron_ore', min: 32, action: 'gather', limit: 64, depth: 35 },
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
const BASE = { x: -85, z: -44 };
const TILE = 24;
const REGION = { minX: -155, maxX: -25, minZ: -105, maxZ: 15 };

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
  const idleMiner = idle('miner');
  const idleScout = idle('scout');
  const idleCrafter = idle('crafter');
  if (!idleMiner && !idleScout && !idleCrafter)
    return { acted: false, reason: 'no idle miner, scout or crafter' };

  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  const detail = stock?.detail ?? stock?.data?.detail ?? [];
  const held = (m: string) =>
    detail.filter((d: any) => typeof d.name === 'string' && d.name.includes(m))
          .reduce((n: number, d: any) => n + (d.count ?? 0), 0);

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
    const list = res?.tasks ?? res?.data?.tasks;
    // A REFUSAL COMES BACK AS A VALUE, NOT AN EXCEPTION.
    //
    // PowNet puts an error in the same field a success uses, so a failed GetTasks arrives as a
    // plain string -- and `undefined?.tasks ?? []` then iterates nothing, leaving the dedup set
    // empty with no error raised anywhere. Dedup silently switched itself off and the queue filled
    // with nine copies of the same two surveys. An empty result and an unreadable one look
    // identical and mean opposite things, so they must be told apart explicitly.
    if (!Array.isArray(list)) {
      return { acted: false, reason: `cannot read the task queue (${typeof res === 'string' ? res : typeof res}); not dispatching blind` };
    }
    for (const t of list) {
      if ((t?.progress ?? 0) < 100 && typeof t?.name === 'string') queued.add(t.name);
    }
  } catch {
    // NOT KNOWING what is queued is a reason to WAIT, not to proceed.
    //
    // Treating an unreadable queue as an empty one is how duplicates got created in the first
    // place: every tick that could not reach TaskMan cheerfully added another survey for a
    // shortage that already had three. A tick skipped costs a minute; a tick that dispatches blind
    // costs a drone and clogs the queue behind it.
    return { acted: false, reason: 'cannot read the task queue; not dispatching blind' };
  }

  const now = Date.now();
  // Each role can take one job per tick. A tick can therefore start a dig AND a survey, which is
  // the point: the scan that finds the next vein should not have to wait for the current one to
  // finish being mined.
  let minerFree = !!idleMiner;
  let scoutFree = !!idleScout;
  let crafterFree = !!idleCrafter;
  const did: string[] = [];
  const waiting: string[] = [];

  for (const rule of supply.rules) {
    if (!minerFree && !scoutFree && !crafterFree) break;
    const have = held(stockKey(rule));
    if (have >= rule.min) continue;
    // Say when a cooldown is the reason. Skipping silently makes "waiting a few minutes" look
    // exactly like "nothing to do", which is how idle drones and an empty log get read as a broken
    // scheduler rather than a timer.
    if ((supply.cooldowns[rule.match] ?? 0) > now) {
      const secs = Math.ceil(((supply.cooldowns[rule.match] ?? 0) - now) / 1000);
      waiting.push(`${rule.match} (${secs}s cooldown)`);
      continue;
    }

    try {
      if (rule.action === 'mine') {
        // Go and LOOK. gather can only revisit coordinates the map already holds, so a material
        // that has never been seen -- iron, at depth, below anything a surface scan can reach --
        // is unreachable by any amount of gathering. This is the job that changes that.
        if (!minerFree) continue;
        supply.cooldowns[rule.match] = now + COOLDOWN_MS;
        const r: any = await callTool('order.prospect', { depth: rule.depth ?? 40 });
        if (r?.ok === false) {
          note(`${rule.match}: ${have}/${rule.min}, prospecting refused — ${r?.error ?? '?'}`);
          continue;
        }
        minerFree = false;
        supply.dispatched++;
        supply.lastAction = `prospect for ${rule.match}`;
        note(`${rule.match}: ${have}/${rule.min} → prospecting at y=${rule.depth ?? 40}`);
        did.push(`prospect ${rule.match}`);
        continue;
      }

      if (rule.action === 'craft' && [...queued].some((n) => n.startsWith(`craft-${stockKey(rule).replace(/^.*:/, '')}`))) {
        note(`${rule.match}: ${have}/${rule.min}, already being crafted`);
        continue;
      }

      if (rule.action === 'craft') {
        // Needs a crafter, not a miner. Nothing else can serve the job, so waiting for one is the
        // correct behaviour rather than dispatching it at a drone that will refuse at the last step.
        if (!idleCrafter) continue;                 // no cooldown burned: retry when one frees up
        supply.cooldowns[rule.match] = now + COOLDOWN_MS;
        // The TARGET, not the deficit. expand() already subtracts what storage holds, so passing
        // (target - have) subtracts the same stock twice: asking for "8 more chests" while holding
        // 8 planned to zero steps and the loop reported "nothing craftable" with a full chest.
        const want = rule.limit ?? rule.min;
        const r: any = await callTool('plan.execute', { item: stockKey(rule), quantity: want });
        const queued = r?.data?.queued ?? r?.queued ?? [];
        if (!queued.length) {
          note(`${rule.match}: ${have}/${rule.min}, nothing craftable — ${JSON.stringify(r?.data?.needsSite ?? [])}`);
          continue;
        }
        crafterFree = false;
        supply.dispatched++;
        supply.lastAction = `craft ${stockKey(rule)}`;
        note(`${rule.match}: ${have}/${rule.min} → craft x${want} queued (${queued.length} steps)`);
        did.push(`craft ${stockKey(rule)}`);
        continue;
      }

      if (rule.action !== 'gather') {
        supply.cooldowns[rule.match] = now + COOLDOWN_MS;
        note(`${rule.match}: ${have}/${rule.min} → ${rule.action} not yet automatable`);
        continue;
      }

      // Ask for the dig first, but only if a miner could actually take it.
      if (minerFree) {
        const r: any = await callTool('order.gather', { match: rule.match, limit: rule.limit ?? 64 });
        if (r?.ok !== false) {
          supply.cooldowns[rule.match] = now + COOLDOWN_MS;
          minerFree = false;
          supply.dispatched++;
          supply.lastAction = `gather ${rule.match}`;
          note(`${rule.match}: ${have}/${rule.min} → gather dispatched`);
          did.push(`gather ${rule.match}`);
          continue;
        }
      }

      // Nothing surveyed matches: the honest answer is "go and look", not "dig somewhere".
      //
      // This branch used to just log and stop, which was survivable only because the index was
      // append-only -- a mined-out vein stayed listed for ever, so the loop always had somewhere to
      // send a miner. Now that the index prunes what drones observe, exhausting a vein empties it
      // properly and this is where the loop would otherwise come to rest permanently. So it
      // dispatches the scan it was only describing.
        // NOTHING SURVEYED: SEND SOMEONE TO LOOK UNDERGROUND.
        //
        // gather can only revisit coordinates the map already holds, and a surface survey cannot
        // reach ore at depth -- a scanner sees 8 blocks and iron is fifty below. A material that has
        // NEVER been seen is not a gathering problem, it is a prospecting one. Without this branch
        // the loop fell straight through to "wait for a scout" and sat there with three idle miners
        // and coal at 0/32.
        if (minerFree && rule.depth !== undefined
            && ![...queued].some((n) => n.startsWith('shaft-'))) {
          supply.cooldowns[rule.match] = now + COOLDOWN_MS;
          const p: any = await callTool('order.prospect', { depth: rule.depth });
          if (p?.ok !== false) {
            minerFree = false;
            supply.dispatched++;
            supply.lastAction = `prospect for ${rule.match}`;
            note(`${rule.match}: ${have}/${rule.min}, none known -> prospecting at y=${rule.depth}`);
            did.push(`prospect ${rule.match}`);
            continue;
          }
          note(`${rule.match}: prospecting refused -- ${p?.error ?? '?'}`);
        }

        // Say so rather than skipping in silence: "no scout free" and "nothing to do" are
        // different states and looked identical in the log.
        if (!scoutFree) {
          waiting.push(`${rule.match} (no scout free)`);
          continue;
        }
      supply.cooldowns[rule.match] = now + COOLDOWN_MS;
      let area = frontier();
      if (!area) {
        // WRAP, don't stop. The spiral walking off the edge of the loaded region is not the same
        // as the region being fully surveyed -- the cursor is a position, not a completion record,
        // and a survey that failed still advanced it. Left as a dead end the loop simply stopped
        // exploring for good, which is what happened here: the last prospecting run was two hours
        // before anyone noticed.
        supply.frontier = 0;
        area = frontier();
        if (!area) { note(`${rule.match}: no surveyable tile inside the loaded region`); continue; }
        note('exploration frontier wrapped -- starting another pass from the base outward');
      }
      supply.frontier = (supply.frontier ?? 0) + 1;
      await bridge.call('TaskMan', 'Add', {
        name: `find-${rule.match}`,
        priority: 3,
        work: { survey: { radius: 8, min: area.min, max: area.max } },
      }, { timeoutMs: 8000 });
      scoutFree = false;
      supply.dispatched++;
      supply.lastAction = `survey for ${rule.match}`;
      note(`${rule.match}: ${have}/${rule.min}, none known → survey tile ${supply.frontier} `
         + `at ${area.min.x},${area.min.z}..${area.max.x},${area.max.z}`);
      did.push(`survey for ${rule.match}`);
    } catch (err) {
      supply.cooldowns[rule.match] = now + COOLDOWN_MS;
      note(`${rule.match}: dispatch failed — ${(err as Error)?.message ?? err}`);
    }
  }

  if (did.length) return { acted: true, reason: did.join(', ') };
  if (waiting.length) return { acted: false, reason: `waiting on cooldown: ${waiting.join(', ')}` };
  return { acted: false, reason: 'nothing to dispatch' };
}

export function startSupplyLoop(intervalMs = 60_000) {
  setInterval(() => { runSupplyTick().catch(() => { /* reported via note() */ }); }, intervalMs).unref();
}
