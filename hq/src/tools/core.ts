/**
 * Core tools — perception, fleet, orders.
 *
 * Note what these deliberately are NOT: there is no `drone.forward`, no
 * `turtle.dig`. The agent expresses INTENT over regions and the planner turns it
 * into behaviours. Exposing movement primitives would let a small model burn its
 * whole step budget walking a drone across a field, and would put a network
 * round-trip in the middle of every block placement.
 *
 * Every tool here states its bounds to the model rather than only enforcing them
 * silently, because a limit the model knows about becomes a plan; a limit it
 * discovers becomes a retry loop.
 */
import { z } from 'zod';
import { registry, ToolError } from './registry.js';
import { state, STALE_MS, type Vec3, type DroneStatus } from '../world/state.js';
import { bridge } from '../bridge/ws.js';
import { expand, craftable, RECIPES } from '../world/recipes.js';
import { allocate, checkOrder, SPEC, type Purpose } from '../world/plots.js';
import { city, saveCity } from '../world/city.js';
import { supply, runSupplyTick, saveSupply, stockKey, type SupplyRule } from '../agent/supply.js';

/**
 * Pull the fleet from DroneMan, which owns the registry.
 *
 * HQ was designed to learn about drones passively, from `drone.heartbeat` EVENTs the Bridge would
 * relay. Those can never arrive: DroneLogic sends heartbeats with
 * `PowNet.SendToServer("DroneMan", ...)` -- directed, on SERVER_PROTOCOL -- while the Bridge
 * listens with `rednet.receive(DRONE_PROTOCOL)`, which only sees broadcasts or traffic addressed
 * to itself. Wrong protocol AND wrong addressing, so every tool read an empty world and answered
 * "0 drones" with ok:true -- indistinguishable from a healthy fleet that happens to be empty.
 *
 * Asking is also better than sniffing: DroneMan owns the registry, it survives a Bridge restart,
 * and heartbeats only fire at boot and shutdown anyway (there is no timer), so a passive listener
 * would go stale the moment a drone settled.
 */
/**
 * DroneLogic's status words, mapped onto the five HQ reasons about.
 *
 * These two vocabularies were never reconciled and the mismatch was invisible: `d.status` arrives
 * off an `any`, so TypeScript accepted "mining" as a DroneStatus and the wrong value flowed all
 * the way to the agent. The damage was silent and total --
 *
 *   - buildBrief tests `status === 'lost' | 'stranded'`, so a drone DroneMan had explicitly marked
 *     "offline" raised NO problem at all. /brief said `problems: ["none"]` while a drone was dead.
 *   - fleet.status's filter enum has no "mining", so `{status:'working'}` matched zero drones
 *     while two were actively mining, and `{status:'mining'}` was rejected as invalid. There was
 *     no accepted value that could find a working drone.
 *
 * Anything unrecognised maps to 'working' rather than 'idle': a drone reporting a word we do not
 * know is doing SOMETHING, and guessing "idle" would offer it more work on top.
 */
const REPORTED_STATUS: Record<string, DroneStatus> = {
  idle: 'idle',
  mining: 'working', scanning: 'working', surveying: 'working',
  moving: 'working', rotation: 'working', updating: 'working',
  // Hauling is the return leg to storage, which is what 'docking' means here.
  hauling: 'docking',
  // Stuck is a drone that has given up and said so. It needs a rescue, not a re-queue.
  stuck: 'stranded',
  offline: 'lost',
};

function normaliseStatus(reported: unknown, offline: unknown): DroneStatus {
  if (offline) return 'lost';
  if (typeof reported !== 'string') return 'idle';
  return REPORTED_STATUS[reported] ?? 'working';
}

async function refreshFleet(): Promise<void> {
  if (!bridge.connected) return;        // offline: serve last-known state rather than erroring
  try {
    const res: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 5000 });
    const list = res?.drones ?? res?.data?.drones;
    if (!Array.isArray(list)) return;
    for (const d of list) {
      const id = typeof d?.droneID === 'number' ? d.droneID : d?.id;
      if (typeof id !== 'number') continue;
      const patch: Parameters<typeof state.upsertDrone>[0] = {
        id,
        name: d.name ?? `drone-${id}`,
        role: d.role ?? 'miner',
        status: normaliseStatus(d.status, d.offline),
        reported: typeof d.status === 'string' ? d.status : undefined,
        // The drone's own words for why it stopped. HQ used to drop this, so a drone that had
        // explicitly reported "stuck at -70,88,12 -- no progress over 4 legs" surfaced as the
        // generic "has gone quiet" -- which describes a drone that said NOTHING, the opposite of
        // what happened, and sends you looking for a comms fault instead of reading the reason.
        stuck: typeof d.stuck === 'string' ? d.stuck : undefined,
        fuel: typeof d.fuel === 'number' ? d.fuel : 0,
        pos: d.pos && typeof d.pos.x === 'number' ? d.pos : undefined,
      };
      // DroneMan's timestamp, NOT now. Stamping `now` here measures when HQ last polled, so every
      // drone reported silent=0s -- including one that had been mined out of the world. A liveness
      // field that is always zero is worse than none: it looks like proof of life.
      //
      // Absent stays absent. It is only set when DroneMan actually has one, so that a drone it has
      // never heard from keeps `lastSeen: undefined` and is reported as never-seen rather than as
      // silent-since-1970.
      if (typeof d.lastSeen === 'number' && d.lastSeen > 0) patch.lastSeen = d.lastSeen;
      state.upsertDrone(patch);
    }
  } catch (err) {
    // A refresh failure must not take down a read tool; stale data beats no answer. But it must
    // not be silent either -- a swallowed error here reads as "the fleet is empty", which is the
    // most misleading possible answer.
    console.log(`[fleet] refresh failed: ${(err as Error)?.message ?? err}`);
  }
}

/** A step carries its grid but not its ingredient list; the drone needs both to load the grid. */
function recipeInputs(item: string): Record<string, number> {
  return RECIPES.find((r) => r.output === item)?.inputs ?? {};
}

const vec3 = z.object({ x: z.number().int(), y: z.number().int(), z: z.number().int() });

/** Shared safety rail: no unbounded destruction, ever. */
const MAX_DIG_VOLUME = 32_768; // 32^3 — a big but comprehensible bite
function assertBounded(min: Vec3, max: Vec3) {
  const volume = (max.x - min.x + 1) * (max.y - min.y + 1) * (max.z - min.z + 1);
  if (volume <= 0) throw new ToolError('Region is empty or inverted.', 'Ensure every min component is <= the matching max component.');
  if (volume > MAX_DIG_VOLUME)
    throw new ToolError(
      `Region is ${volume} blocks, over the ${MAX_DIG_VOLUME} limit.`,
      'Split it into smaller regions and issue them as separate orders, highest-value first.',
    );
  return volume;
}

// ── hive.brief ─────────────────────────────────────────────────────────────
// The one tool priming depends on. Everything an agent needs to act, in one
// read, deliberately summarised rather than dumped: a small model handed 400
// drone records will spend its budget parsing instead of deciding.
registry.register({
  name: 'hive.brief',
  summary: 'Current situation: fleet, active orders, world coverage, and anything wrong.',
  description:
    'The standing orientation call. You are given this automatically at the start ' +
    'of every activation, so you normally should NOT call it again. Call it only if ' +
    'something you were told contradicts what you now see, or the brief says it is stale.',
  params: z.object({}).strict(),
  returns: 'Fleet summary, active orders, world model coverage, and a problems list.',
  danger: 'read',
  preload: true,
  handler: async () => { await refreshFleet(); return buildBrief(); },
});

export function buildBrief() {
  const drones = state.listDrones();
  const orders = state.activeOrders();
  const problems: string[] = [];

  for (const d of drones) {
    if (d.status === 'lost') problems.push(`${d.name} (#${d.id}) is LOST — ${describeSilence(d.silentMs)}.`);
    else if (d.status === 'stranded') problems.push(
      d.stuck
        ? `${d.name} (#${d.id}) is STUCK — ${d.stuck}`
        : `${d.name} (#${d.id}) has gone quiet (${describeSilence(d.silentMs)}).`);
    else if (d.fuel < 200) problems.push(`${d.name} (#${d.id}) is low on fuel (${d.fuel}).`);
  }
  for (const o of orders) if (o.failure) problems.push(`Order ${o.id} (${o.kind}) failed: ${o.failure}`);

  return {
    fleet: {
      total: drones.length,
      byStatus: tally(drones.map((d) => d.status)),
      drones: drones.map((d) => ({
        id: d.id, name: d.name, status: d.status, doing: d.reported ?? null, fuel: d.fuel,
        pos: d.pos ?? null, order: d.order ?? null,
        silentSec: silentSec(d.silentMs),
      })),
    },
    orders: orders.map((o) => ({
      id: o.id, kind: o.kind, status: o.status, priority: o.priority,
      progress: o.progress, workers: o.workers.length, failure: o.failure ?? null,
    })),
    world: { knownBlocks: state.worldSize, staleAfterSec: STALE_MS.world / 1000 },
    problems: problems.length ? problems : ['none'],
    generatedAt: new Date().toISOString(),
  };
}

const tally = (xs: string[]) =>
  xs.reduce<Record<string, number>>((a, x) => ((a[x] = (a[x] ?? 0) + 1), a), {});

/** Seconds of silence, or null for a drone that has never reported. Never a fake number. */
const silentSec = (ms: number | null) => (ms === null ? null : Math.round(ms / 1000));

/**
 * Silence in words. "Never reported" is a different diagnosis from "silent for four minutes" —
 * the first means the drone may not exist, the second means it stopped — and the agent replans
 * differently on each, so the distinction has to survive into the prose it actually reads.
 */
const describeSilence = (ms: number | null) =>
  ms === null ? 'never reported to DroneMan' : `silent ${Math.round(ms / 1000)}s`;

// ── fleet.status ───────────────────────────────────────────────────────────
registry.register({
  name: 'fleet.status',
  summary: 'Detail on one drone, or drones filtered by status/role.',
  description: 'Use when the brief is not specific enough — e.g. to check one drone before assigning it work.',
  params: z.object({
    id: z.number().int().optional().describe('A specific drone id.'),
    /**
     * Both vocabularies are accepted, because a caller cannot be expected to know which one a
     * given drone happens to be speaking. Asking for 'working' finds the drone that reported
     * 'mining'; asking for 'mining' finds it too. Previously neither did: 'mining' was rejected
     * by the enum and 'working' matched nothing, so a mining drone was unreachable by any
     * accepted value of the one filter meant to find it.
     */
    status: z.enum([
      'idle', 'working', 'docking', 'stranded', 'lost',
      'mining', 'scanning', 'surveying', 'moving', 'rotation', 'updating', 'hauling',
      'stuck', 'offline',
    ]).optional().describe('HQ status (idle/working/docking/stranded/lost) or the drone\'s own word (mining, scanning, hauling…).'),
    role: z.string().optional(),
  }).strict(),
  returns: 'Matching drones with position, fuel, status, what they reported doing, current order and silence duration (null if never heard from).',
  danger: 'read',
  teach: [{
    situation: 'Which drones are free to take work right now?',
    args: { status: 'idle' },
    result: { matched: 2, drones: [
      { id: 3, name: 'drone-3', status: 'idle', fuel: 1840, pos: { x: 112, y: 64, z: -40 } },
      { id: 5, name: 'drone-5', status: 'idle', fuel: 620, pos: { x: 108, y: 64, z: -38 } },
    ] },
    takeaway: 'Two idle. drone-3 has the fuel for distant work; drone-5 should stay close to dock.',
  }],
  handler: async (a) => {
    await refreshFleet();
    // Match on either the normalised status or the drone's own word, so both spellings of the
    // same question return the same drones.
    const wanted = a.status;
    const matches = (d: { status: DroneStatus; reported?: string }) =>
      !wanted || d.status === wanted || d.reported === wanted ||
      (REPORTED_STATUS[wanted] !== undefined && d.status === REPORTED_STATUS[wanted]);

    const drones = state.listDrones().filter(
      (d) => (a.id === undefined || d.id === a.id) &&
             matches(d) &&
             (!a.role || d.role === a.role),
    );
    return { matched: drones.length, drones };
  },
});

// ── world.query ────────────────────────────────────────────────────────────
registry.register({
  name: 'world.query',
  summary: 'What is known about a region — block composition, coverage, and how stale it is.',
  description:
    'Returns a SUMMARY, not raw blocks. Always check `stale` and `coverage` before ' +
    'planning against it: low coverage means the drones have not looked there, and a ' +
    'stale region may have been changed by players or by your own earlier orders.',
  params: z.object({ min: vec3, max: vec3 }).strict(),
  returns: 'Volume, known-cell count, coverage 0-1, top block types, observation ages, stale flag.',
  danger: 'read',
  bounds: 'Region must be non-inverted. Very large regions return coarse summaries.',
  teach: [{
    situation: 'Is the hill north of base worth quarrying?',
    args: { min: { x: 100, y: 60, z: -60 }, max: { x: 130, y: 90, z: -30 } },
    result: {
      volume: 29791, known: 811, coverage: 0.027,
      blocks: { stone: 640, dirt: 121, iron_ore: 22 },
      stale: false, newestObservationAgeMs: 41_000,
    },
    takeaway: 'Only 2.7% mapped — too little to plan a quarry. Scout it before ordering any digging.',
  }],
  handler: async (a) => state.summarizeRegion(a.min, a.max),
});

// ── order.issue ────────────────────────────────────────────────────────────
registry.register({
  name: 'order.issue',
  summary: 'Issue a bounded order to the swarm (dig, quarry, explore, build, follow).',
  description:
    'The main way you act. Orders are intent over a REGION; the planner assigns drones, ' +
    'paths them, and handles failure. Destructive kinds (dig, quarry) require bounds and ' +
    'are rejected if the region is too large — split large jobs deliberately rather than ' +
    'hoping. Check world.query coverage first if you are not sure what is there.',
  params: z.object({
    kind: z.enum(['dig', 'build', 'quarry', 'explore', 'follow', 'lumber']),
    bounds: z.object({ min: vec3, max: vec3 }).optional()
      .describe('Required for dig, quarry, explore and build.'),
    priority: z.number().int().min(1).max(5).default(3)
      .describe('1 is highest. Issuing at 1 pushes existing work down.'),
    note: z.string().max(200).optional().describe('Why — recorded in the audit log.'),
  }).strict(),
  returns: 'The created order: id, kind, status, priority, estimated volume.',
  danger: 'destructive',
  bounds: `Destructive regions capped at ${MAX_DIG_VOLUME} blocks. Every order is abortable via order.abort.`,
  teach: [
    {
      situation: 'Clear a 10x5x10 pad for the new dock at 120,64,-50.',
      args: {
        kind: 'dig',
        bounds: { min: { x: 120, y: 64, z: -50 }, max: { x: 129, y: 68, z: -41 } },
        priority: 2,
        note: 'dock foundation pad',
      },
      result: { id: 'ord-14', kind: 'dig', status: 'queued', priority: 2, volume: 500 },
      takeaway: 'Bounded, small, and explained. The order is queued and can be aborted by id.',
    },
    {
      situation: 'Strip mine the whole area around base.',
      args: {
        kind: 'quarry',
        bounds: { min: { x: 0, y: 0, z: 0 }, max: { x: 200, y: 60, z: 200 } },
        priority: 1,
      },
      // A deliberate demonstration of REJECTION. The model should see the guard
      // rail fire and see the correct recovery, not just the happy path.
      result: {
        ok: false,
        error: 'Region is 2464461 blocks, over the 32768 limit.',
        fix: 'Split it into smaller regions and issue them as separate orders, highest-value first.',
      },
      takeaway: 'Too big. I will split this into 32-block chunks and issue the most promising first.',
    },
  ],
  handler: async (a, ctx) => {
    const needsBounds = a.kind !== 'follow';
    if (needsBounds && !a.bounds)
      throw new ToolError(`${a.kind} needs bounds.`, 'Re-send with bounds.min and bounds.max.');
    let volume = 0;
    if (a.bounds) volume = assertBounded(a.bounds.min, a.bounds.max);
    const order = state.createOrder({
      kind: a.kind, bounds: a.bounds, priority: a.priority, issuedBy: ctx.agent,
    });

    // Actually hand the work to TaskMan. Without this the order existed only in HQ's memory:
    // order.issue returned a plausible id and status:'queued', nothing reached the fleet, and the
    // drones sat idle -- the single most misleading failure this API could have.
    //
    // TaskMan.AddTask takes { name, priority, work }, where `work` selects the job type and the
    // role: work.dig -> dig.PrepareTask (miner), work.survey / work.scan -> scout.
    let dispatched = false;
    let dispatchError: string | undefined;
    if (bridge.connected) {
      const b = a.bounds!;
      const work: Record<string, unknown> =
        a.kind === 'explore' ? { survey: { min: b.min, max: b.max } }
        : a.kind === 'lumber'
          // Lumber walks a surface area rather than excavating a volume, so it takes width/length
          // and settles to the ground itself -- a height is meaningless for felling trees.
          ? { lumber: { start: b.min, w: Math.abs(b.max.x - b.min.x) + 1,
                        l: Math.abs(b.max.z - b.min.z) + 1 } }
        : { dig: { start: b.min, stop: b.max } };
      try {
        // 'Add', not 'AddTask'. The wire key is the KEY in the module's m_ServerEvents table,
        // which is not the same as the On<Name> handler function. TaskMan registers OnAddTask
        // under 'Add'; calling 'AddTask' reaches TaskMan, finds no handler, and gets no reply at
        // all -- which surfaces as a timeout, not as "unknown method".
        await bridge.call('TaskMan', 'Add', {
          name: `${order.id}:${a.kind}`, priority: a.priority, work,
        }, { timeoutMs: 8000, idem: order.id });
        dispatched = true;
      } catch (err) {
        dispatchError = (err as Error)?.message ?? String(err);
      }
    } else {
      dispatchError = 'bridge offline';
    }

    ctx.log(`order ${order.id} issued`, { kind: a.kind, volume, note: a.note, dispatched });
    return {
      id: order.id, kind: order.kind, status: dispatched ? order.status : 'not-dispatched',
      priority: order.priority, volume, dispatched, dispatchError,
    };
  },
});

// ── fleet.faults ───────────────────────────────────────────────────────────
// Ask every module what has gone wrong. Almost every hour lost building this fleet went to a
// failure that was detected, described, and then thrown away.
registry.register({
  name: 'fleet.faults',
  summary: 'Recent errors recorded by each in-world module.',
  description:
    'Check this FIRST when something "works" but produces nothing. A module can be up, answering ' +
    'calls, and still failing every tick -- that is what these record.',
  params: z.object({ module: z.string().optional() }).strict(),
  returns: 'Per-module fault lists: where it happened and the error text.',
  danger: 'read',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const mods = a.module ? [a.module]
      : ['DroneMan', 'TaskMan', 'DockingMan', 'MapServer', 'StorageMan'];
    const out: Record<string, unknown> = {};
    let total = 0;
    for (const m of mods) {
      try {
        const r: any = await bridge.call(m, 'Faults', {}, { timeoutMs: 5000 });
        const list = r?.faults ?? r?.data?.faults ?? [];
        out[m] = list;
        total += Array.isArray(list) ? list.length : 0;
      } catch (err) {
        // A module that cannot even be asked is itself the most important fault.
        out[m] = [{ where: 'unreachable', err: (err as Error)?.message ?? String(err) }];
        total += 1;
      }
    }
    return { total, modules: out };
  },
});

// ── supply.status / supply.set ─────────────────────────────────────────────
// The autonomous half: stock is compared against targets on a timer and each shortfall becomes
// the job that fixes it, so drones stop idling while a human decides what is needed.
registry.register({
  name: 'supply.status',
  summary: 'The standing supply policy, and what the loop has been doing.',
  description: 'Shows each material target, current holdings, whether the loop is on, and its recent actions.',
  params: z.object({}).strict(),
  returns: 'enabled flag, rules with current stock, recent decisions.',
  danger: 'read',
  handler: async () => {
    let held: Record<string, number> = {};
    if (bridge.connected) {
      try {
        const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
        const detail = stock?.detail ?? stock?.data?.detail ?? [];
        for (const r of supply.rules) {
          held[r.match] = detail
            .filter((d: any) => typeof d.name === 'string' && d.name.includes(stockKey(r)))
            .reduce((n: number, d: any) => n + (d.count ?? 0), 0);
        }
      } catch { /* reported as unknown below */ }
    }
    return {
      enabled: supply.enabled,
      dispatched: supply.dispatched,
      lastAction: supply.lastAction ?? null,
      rules: supply.rules.map((r) => ({ ...r, have: held[r.match] ?? null,
                                        short: (held[r.match] ?? 0) < r.min })),
      recent: supply.log.slice(0, 10),
    };
  },
});

registry.register({
  name: 'supply.set',
  summary: 'Turn the supply loop on or off, or change a material target.',
  description:
    'The loop dispatches at most ONE job at a time and only when a drone of the right role is ' +
    'idle, so it never competes with work you ordered. Off by default: an autonomous fleet should ' +
    'not start itself.',
  params: z.object({
    enabled: z.boolean().optional(),
    match: z.string().min(2).optional().describe('Material to add or adjust.'),
    min: z.number().int().min(0).max(10000).optional(),
    action: z.enum(['gather', 'lumber', 'craft']).optional(),
    limit: z.number().int().min(1).max(512).optional(),
    runNow: z.boolean().optional().describe('Run one tick immediately rather than waiting.'),
  }).strict(),
  returns: 'The updated policy, and the result of the immediate tick if requested.',
  danger: 'mutate',
  handler: async (a, ctx) => {
    if (typeof a.enabled === 'boolean') supply.enabled = a.enabled;
    if (a.match) {
      const existing = supply.rules.find((r) => r.match === a.match);
      if (existing) {
        if (a.min !== undefined) existing.min = a.min;
        if (a.action) existing.action = a.action;
        if (a.limit !== undefined) existing.limit = a.limit;
      } else {
        supply.rules.push({ match: a.match, min: a.min ?? 32,
                            action: a.action ?? 'gather', limit: a.limit } as SupplyRule);
      }
    }
    // Persist BEFORE running a tick: if the tick throws, the operator's decision to enable
    // autonomy must still have been recorded. Losing it silently is how the loop ended up off.
    saveSupply();
    let tick;
    if (a.runNow) tick = await runSupplyTick();
    ctx.log('supply.set', { enabled: supply.enabled, rules: supply.rules.length });
    return { enabled: supply.enabled, rules: supply.rules, tick: tick ?? null };
  },
});

// ── order.gather ───────────────────────────────────────────────────────────
// The consuming half of surveying. world.find already knows where things are; without this the
// index is a report nobody acts on, and the only way to get a material was to quarry a box and
// hope. Seeds come from the index; the drone flood-fills each one, so a vein is taken whole.
registry.register({
  name: 'order.gather',
  summary: 'Send a miner to collect a specific material the survey has already located.',
  description:
    'Looks the material up in the block index and dispatches a miner to each cluster, following ' +
    'the vein outward from every seed. Use for ore, dirt, clay -- anything known and scattered. ' +
    'Use order.issue{kind:dig} instead for bulk excavation of a volume.',
  params: z.object({
    match: z.string().min(2).describe('Block name substring, e.g. "coal_ore" or "dirt".'),
    limit: z.number().int().min(1).max(512).default(64)
      .describe('Maximum blocks to take, so one huge vein cannot occupy a drone forever.'),
  }).strict(),
  returns: 'Whether it dispatched, how many seed positions were found, and the material.',
  danger: 'destructive',
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');

    const found: any = await bridge.call('MapServer', 'FindBlocks',
      { match: a.match, limit: 40 }, { timeoutMs: 10000 });
    const hits = found?.hits ?? found?.data?.hits ?? [];
    const seeds = Array.isArray(hits) ? hits : Object.values(hits ?? {});
    if (!seeds.length) {
      throw new ToolError(
        `Nothing matching "${a.match}" has been surveyed.`,
        'Survey the area first, or check world.find for what is actually known.');
    }

    const res: any = await bridge.call('TaskMan', 'Add', {
      name: `gather:${a.match}`,
      priority: 2,
      work: { gather: { targets: seeds, match: a.match, limit: a.limit } },
    }, { timeoutMs: 8000 });

    ctx.log(`gather ${a.match}`, { seeds: seeds.length, limit: a.limit });
    return { dispatched: true, material: a.match, seeds: seeds.length,
             limit: a.limit, task: res?.id ?? res?.data?.id };
  },
});

// ── world.find ─────────────────────────────────────────────────────────────
// Ask the surveyed map where something is, instead of digging to find out. The base sits in a
// desert, so guessing cost a whole dig job that returned nothing but sand.
registry.register({
  name: 'world.find',
  summary: 'Locate surveyed blocks by name, e.g. "ore", "dirt", "log".',
  description:
    'Reads the scouts\' occupancy map -- no drone, no fuel, no travel. Substring match, so "ore" ' +
    'finds every ore type. Returns nothing if that block has not been surveyed yet, which means ' +
    'survey first rather than that it is absent.',
  params: z.object({
    match: z.string().min(2).describe('Substring of the block name, e.g. "iron_ore".'),
    limit: z.number().int().min(1).max(200).default(40),
  }).strict(),
  returns: 'Total found, counts per block name, and up to `limit` coordinates.',
  danger: 'read',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('MapServer', 'FindBlocks', a, { timeoutMs: 10000 });
  },
});

// ── world.voxels ───────────────────────────────────────────────────────────
// The occupancy grid itself, for RENDERERS rather than for reasoning.
//
// Every other world tool here deliberately summarises, because a small model handed thousands of
// cells spends its budget parsing instead of deciding. A 3D viewer has the opposite need: it wants
// the cells and nothing else. Rather than bolt a second, untyped data path onto the bridge for the
// map page, this stays a tool -- same validation, same error envelope, same audit line -- and pays
// for the size difference with a `raw` flag that is off by default. An agent that calls it without
// asking for raw gets a one-paragraph answer; the page asks for raw and gets the grid.
//
// MapServer's LoadWorld returns PowGPSServer's `cachedWorld`, keyed "x:y:z":
//   1 = solid, 0 = surveyed air, 2 = a cell a drone was parked in, absent = never surveyed.
// The distinction between 0 and absent is the whole value of the map, so we never collapse them.

/** How long a fetched grid stays good. */
const VOXEL_CACHE_MS = 10_000;
let voxelCache: { at: number; grid: Record<string, number> } | null = null;
/**
 * A single in-flight fetch shared by every concurrent caller. The cache alone is not enough: the
 * map page polls, and rednet round-trips take seconds, so two pollers arriving inside one fetch
 * would each start their own. The grid is ~100KB over a link that also carries drone orders --
 * exactly the traffic the Bridge's backpressure exists to avoid generating in the first place.
 */
let voxelInflight: Promise<Record<string, number>> | null = null;

async function loadVoxels(): Promise<Record<string, number>> {
  if (voxelCache && Date.now() - voxelCache.at < VOXEL_CACHE_MS) return voxelCache.grid;
  if (voxelInflight) return voxelInflight;
  voxelInflight = (async () => {
    const res: any = await bridge.call('MapServer', 'LoadWorld', {}, { timeoutMs: 20_000 });
    // PowNet replies are unwrapped by the Bridge, but SaveWorld-era callers saw a nested `data`,
    // so accept both shapes rather than returning an empty world on a wrapper change.
    const grid = res?.cachedWorld ?? res?.data?.cachedWorld ?? {};
    voxelCache = { at: Date.now(), grid };
    return grid;
  })().finally(() => { voxelInflight = null; });
  return voxelInflight;
}

/** Bounds and composition, derived once so neither the agent nor the page has to scan twice. */
function voxelStats(grid: Record<string, number>) {
  let solid = 0, air = 0, other = 0;
  let minx = Infinity, miny = Infinity, minz = Infinity;
  let maxx = -Infinity, maxy = -Infinity, maxz = -Infinity;
  for (const k in grid) {
    const p = k.split(':');
    const x = Number(p[0]), y = Number(p[1]), z = Number(p[2]);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) continue;
    if (x < minx) minx = x; if (x > maxx) maxx = x;
    if (y < miny) miny = y; if (y > maxy) maxy = y;
    if (z < minz) minz = z; if (z > maxz) maxz = z;
    const v = grid[k];
    if (v === 1) solid++; else if (v === 0) air++; else other++;
  }
  const known = solid + air + other;
  return {
    known, solid, air, other,
    // Null rather than an inverted infinity box: a caller centring a camera on this must be able
    // to tell "no survey yet" from "a box at the origin", and Infinity would silently become NaN.
    bounds: known
      ? { min: { x: minx, y: miny, z: minz }, max: { x: maxx, y: maxy, z: maxz } }
      : null,
    cachedAgeMs: voxelCache ? Date.now() - voxelCache.at : 0,
  };
}

registry.register({
  name: 'world.voxels',
  summary: 'The raw surveyed occupancy grid — solid/air/unknown per cell. For rendering, not reading.',
  description:
    'Returns coverage and bounds by default. Pass raw:true only if you are DRAWING the map: that ' +
    'sends every surveyed cell (tens of thousands of numbers) and there is nothing in it a plan ' +
    'can use that world.query, world.find or world.caves do not already answer in one line.',
  params: z.object({
    raw: z.boolean().default(false).describe('Include the full cell map. Renderers only.'),
  }).strict(),
  returns: 'Counts of solid/air/unknown cells, the surveyed bounding box, and with raw:true a `cells` map keyed "x:y:z" (1 solid, 0 air, 2 drone-occupied).',
  danger: 'read',
  bounds: `Served from a ${VOXEL_CACHE_MS / 1000}s cache, so polling it is cheap but it can be that stale.`,
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const grid = await loadVoxels();
    const stats = voxelStats(grid);
    return a.raw ? { ...stats, cells: grid } : stats;
  },
});

// ── world.blocks ───────────────────────────────────────────────────────────
// Position -> block name, for colouring a map by what is actually there.
//
// world.voxels answers "is this cell solid", which is what a pathfinder needs and all a renderer
// could previously show: terrain as one grey mass. This says WHAT is solid. It is a strict subset
// of the occupancy grid -- only positions a drone reported a name for -- so a missing key means
// "solid but unidentified", never "air". Collapsing those two would draw holes in the ground.

const BLOCKS_CACHE_MS = 15_000;
let blocksCache: { at: number; map: Record<string, string> } | null = null;
let blocksInflight: Promise<Record<string, string>> | null = null;

async function loadBlocks(): Promise<Record<string, string>> {
  if (blocksCache && Date.now() - blocksCache.at < BLOCKS_CACHE_MS) return blocksCache.map;
  if (blocksInflight) return blocksInflight;
  blocksInflight = (async () => {
    // Shorter than the voxel fetch it rides alongside. Identity is an enrichment: if MapServer
    // does not have this endpoint yet, the map must fall back to unidentified terrain quickly
    // rather than hold the whole terrain refresh open waiting for a call that will never answer.
    // Page through it. MapServer caps each reply so it fits in a websocket frame -- asking for
    // the whole map in one go produced 427KB, which CC:T refuses to send, and the failed send
    // closed the socket and dropped the WHOLE FLEET off HQ every time this ran.
    const map: Record<string, string> = {};
    let offset: number | undefined = 0;
    for (let page = 0; page < 40 && offset !== undefined; page++) {
      const res: any = await bridge.call('MapServer', 'BlockAt', { offset }, { timeoutMs: 8000 });
      const chunk = res?.blockAt ?? res?.data?.blockAt ?? {};
      Object.assign(map, chunk);
      const nxt = res?.next ?? res?.data?.next;
      offset = typeof nxt === 'number' ? nxt : undefined;
    }
    blocksCache = { at: Date.now(), map };
    return map;
  })().finally(() => { blocksInflight = null; });
  return blocksInflight;
}

registry.register({
  name: 'world.blocks',
  summary: 'Every surveyed position and the block name at it. For rendering, not reading.',
  description:
    'Like world.voxels, this is renderer input: raw:true returns thousands of entries. The ' +
    'summary form tells you how many positions are identified and what they are, which is the ' +
    'part a plan can use. To FIND something use world.find instead -- it answers the same ' +
    'question in one line.',
  params: z.object({
    raw: z.boolean().default(false).describe('Include the full position->name map. Renderers only.'),
  }).strict(),
  returns: 'Count of identified positions, a tally by block name, and with raw:true a `blockAt` map keyed "x:y:z".',
  danger: 'read',
  bounds: `Served from a ${BLOCKS_CACHE_MS / 1000}s cache. Covers only observed positions, not the whole world.`,
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const map = await loadBlocks();
    const counts: Record<string, number> = {};
    let n = 0;
    for (const k in map) { counts[map[k]] = (counts[map[k]] ?? 0) + 1; n++; }
    const stats = {
      identified: n,
      counts: Object.fromEntries(Object.entries(counts).sort((x, y) => y[1] - x[1])),
      cachedAgeMs: blocksCache ? Date.now() - blocksCache.at : 0,
    };
    return a.raw ? { ...stats, blockAt: map } : stats;
  },
});

// ── fleet.tasks ────────────────────────────────────────────────────────────
// What the fleet has been TOLD to do, as opposed to where it happens to be.
//
// fleet.status answers "where is D3"; this answers "and why". Those are different questions with
// different failure modes, and only the second one can tell you that a scout has been assigned a
// survey it is nowhere near. The work payload travels whole because its shape differs per verb.
registry.register({
  name: 'fleet.tasks',
  summary: 'The task queue: what each job is, its region, who it is assigned to, and progress.',
  description:
    'Use to answer "what is the fleet actually doing" and to check that an order you issued was ' +
    'picked up. A task with no `assignedTo` is queued but unstaffed -- usually because every ' +
    'drone of the required role is busy or dead.',
  params: z.object({}).strict(),
  returns: 'Tasks with id, name, verb, region, assigned drone id and name, role, progress, paused/enabled flags.',
  danger: 'read',
  handler: async () => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const res: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 8000 });
    const raw = res?.tasks ?? res?.data?.tasks ?? [];
    return { count: raw.length, tasks: raw.map(describeTask) };
  },
});

/**
 * Turn a task's `work` table into a verb and a region.
 *
 * Every job type spells its geometry differently -- dig uses start/stop, survey min/max, lumber a
 * corner plus width and length, gather a list of target positions -- because each was added when
 * it was needed. Normalising here rather than in the renderer means the map, the agent and any
 * future consumer all read the same shape, and a new verb degrades to "unknown region" instead of
 * silently drawing nothing.
 */
function describeTask(t: any) {
  const work = t?.work ?? {};
  const verb = Object.keys(work)[0];
  const w: any = verb ? work[verb] : undefined;
  let region: { min: Vec3; max: Vec3 } | null = null;
  let targets: Vec3[] | null = null;

  const box = (a: any, b: any) => ({
    min: { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), z: Math.min(a.z, b.z) },
    max: { x: Math.max(a.x, b.x), y: Math.max(a.y, b.y), z: Math.max(a.z, b.z) },
  });

  if (w?.start && w?.stop) region = box(w.start, w.stop);
  else if (w?.min && w?.max) region = box(w.min, w.max);
  else if (w?.start && typeof w.w === 'number') {
    // Lumber walks a surface: a corner plus width and length, with no meaningful height. Give it
    // a thin slab so it can be drawn, rather than a degenerate box that renders as nothing.
    region = box(w.start, { x: w.start.x + w.w - 1, y: w.start.y, z: w.start.z + (w.l ?? w.w) - 1 });
  }
  if (Array.isArray(w?.targets)) {
    targets = w.targets.filter((p: any) => typeof p?.x === 'number');
    if (!region && targets && targets.length) {
      // A gather job has no box of its own, so derive one from the seeds. It is the region the
      // drone will actually be working in, which is the thing an operator wants to see.
      const xs = targets.map((p) => p.x), ys = targets.map((p) => p.y), zs = targets.map((p) => p.z);
      region = {
        min: { x: Math.min(...xs), y: Math.min(...ys), z: Math.min(...zs) },
        max: { x: Math.max(...xs), y: Math.max(...ys), z: Math.max(...zs) },
      };
    }
  }

  return {
    id: t.id, name: t.name, verb: verb ?? null,
    role: t.role ?? null,
    assignedTo: typeof t.assignedTo === 'number' ? t.assignedTo : null,
    assigned: t.assigned ?? null,
    progress: t.progress ?? null,
    paused: t.paused === true,
    enabled: t.enabled !== false,
    region, targets,
    match: w?.match ?? null,
    limit: w?.limit ?? null,
  };
}

// ── hive.nodes ─────────────────────────────────────────────────────────────
// The computers, as opposed to the turtles.
//
// Drones report themselves on a heartbeat; the machines that command them reported nothing, so
// the entire control plane was invisible from outside the game. Five idle drones look identical
// whether there is no work to do or TaskMan has been dead since the last chunk unload.
// Display name -> the name the module actually HOSTS under on rednet.
//
// MainFrame hosts itself as "MAINFRAME". Probing "MainFrame" therefore looked up a host that has
// never existed, and the panel reported the one module the entire fleet had just booted from as
// "not answering" -- a monitor that cries wolf is worse than no monitor, because the next real
// outage gets ignored.
const NODE_MODULES: Array<{ label: string; host: string; noStatus?: boolean }> = [
  // MainFrame runs its own receive loop and never registered a Status event, so probing it is
  // guaranteed to time out. Reporting that as "not answering" put the one module the whole fleet
  // had just booted from at the top of the panel as a failure. It is flagged instead: absent
  // endpoint, not absent module.
  { label: 'MainFrame',  host: 'MAINFRAME', noStatus: true },
  { label: 'DroneMan',   host: 'DroneMan' },
  { label: 'TaskMan',    host: 'TaskMan' },
  { label: 'MapServer',  host: 'MapServer' },
  { label: 'StorageMan', host: 'StorageMan' },
  { label: 'DockingMan', host: 'DockingMan' },
];

/**
 * Cached hard, and backed off harder when nothing answers.
 *
 * This is the most expensive read in the system: seven modules, each a rednet round-trip, and an
 * unreachable one costs the full timeout rather than failing fast. Left uncached behind a page
 * that polls every three seconds it would keep six timed-out calls permanently in flight on the
 * link the fleet uses to receive orders — a monitoring tool degrading the thing it monitors.
 *
 * The long backoff exists because "no module answers Status" is the expected state until the Lua
 * side is synced and rebooted, and retrying that every 20s for hours is pure noise on the bridge.
 * A computer's position and uptime are not fast-moving data in any case.
 */
const NODES_CACHE_MS = 20_000;
const NODES_BACKOFF_MS = 90_000;
let nodesCache: { at: number; value: any; anyUp: boolean } | null = null;
let nodesInflight: Promise<any> | null = null;

registry.register({
  name: 'hive.nodes',
  summary: 'The in-world computers: up/down, position, fault count, and their last log lines.',
  description:
    'Check this when the fleet is idle for no reason, or when a tool times out. A module that ' +
    'does not answer here is down, and that is a different problem from a drone being stuck. ' +
    'Positions come from the GPS constellation and are absent for a computer without a wireless ' +
    'modem -- absent means unknown, not origin.',
  params: z.object({}).strict(),
  returns: 'Per-module: reachable flag, computer id, position, uptime, fault count, last fault, last monitor line, recent log lines.',
  danger: 'read',
  handler: async () => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const ttl = nodesCache?.anyUp === false ? NODES_BACKOFF_MS : NODES_CACHE_MS;
    const stale = !nodesCache || Date.now() - nodesCache.at >= ttl;

    // Refresh in the BACKGROUND and answer from cache. A probe takes up to five seconds when a
    // module is down, and the map polls every three: awaiting it here would make the whole page's
    // update rate hostage to its slowest, least urgent panel, and starve the terrain fetch behind
    // it. Whoever asks next gets the fresh answer.
    if (stale && !nodesInflight) {
      nodesInflight = probeNodes()
        .catch(() => undefined)     // a failed probe must not become an unhandled rejection
        .finally(() => { nodesInflight = null; });
    }
    if (!nodesCache) {
      // First call ever: there is nothing to serve yet, and saying so beats blocking.
      return { count: NODE_MODULES.length + 1, up: 0, nodes: [], probing: true,
               note: 'Probing the in-world computers; results appear on the next poll.' };
    }
    return { ...nodesCache.value, cachedAgeMs: Date.now() - nodesCache.at };
  },
});

async function probeNodes() {
    // Asked in parallel: six sequential rednet round-trips at up to 5s each is long enough that
    // the page polling this would never see a complete answer.
    const nodes = await Promise.all(NODE_MODULES.map(async (m) => {
      if (m.noStatus) {
        return {
          module: m.label, reachable: null, id: null, label: null, pos: null, upSec: null,
          faults: 0, lastFault: null, monitor: null, log: [],
          note: 'serves the VFS; does not implement Status, so it cannot be probed this way',
        };
      }
      try {
        const r: any = await bridge.call(m.host, 'Status', {}, { timeoutMs: 5000 });
        const s = r?.data ?? r ?? {};
        return {
          module: m.label, reachable: true,
          id: s.id ?? null, label: s.label ?? null,
          pos: s.pos && typeof s.pos.x === 'number' ? s.pos : null,
          upSec: typeof s.up === 'number' ? Math.round(s.up) : null,
          faults: s.faults ?? 0,
          lastFault: s.lastFault ?? null,
          monitor: s.monitor ?? null,
          log: Array.isArray(s.log) ? s.log : [],
        };
      } catch (err) {
        // Unreachable is the answer, not an error. A module that cannot be asked is the most
        // important thing on this list, and throwing would hide the five that did reply.
        return {
          module: m.label, reachable: false,
          id: null, label: null, pos: null, upSec: null, faults: 0, lastFault: null,
          monitor: null, log: [],
          error: (err as Error)?.message ?? String(err),
        };
      }
    }));

    // The Bridge answers on its own path, which works even when PowNet does not -- so it is the
    // one node whose silence would mean something entirely different.
    let bridgeNode: any = { module: 'Bridge', reachable: false };
    try {
      const b: any = await bridge.call('BRIDGE', 'ping', {}, { timeoutMs: 4000 });
      bridgeNode = { module: 'Bridge', reachable: true, id: b?.id ?? null, pos: null,
                     upSec: typeof b?.up === 'number' ? Math.round(b.up) : null,
                     faults: 0, lastFault: null, monitor: null, log: [] };
    } catch { /* left unreachable */ }

  const all = [...nodes, bridgeNode];
  // "Any PowNet module answered" — the Bridge is excluded deliberately, because it answers on its
  // own path and would mask the case this backoff exists for: Status not deployed anywhere.
  const anyUp = nodes.some((n) => n.reachable === true);
  const value = {
    count: all.length, up: all.filter((n) => n.reachable).length, nodes: all,
    // Said plainly rather than left to be inferred from six identical timeouts.
    note: anyUp ? undefined
      : 'No module answered Status. That endpoint ships with PowNet; until the Lua tree is synced ' +
        'and the fleet reloaded, every module will report unreachable here while working normally.',
  };
  nodesCache = { at: Date.now(), value, anyUp };
  return { ...value, cachedAgeMs: 0 };
}

// ── world.caves ────────────────────────────────────────────────────────────
registry.register({
  name: 'world.caves',
  summary: 'Enclosed air pockets in the surveyed map — candidate caves worth exploring.',
  description:
    'A cave is connected surveyed air that sits below the highest solid block in its column, so ' +
    'open sky is excluded. Gives size, bounding box and an entry cell for each pocket.',
  params: z.object({
    min: z.number().int().min(1).max(1000).default(8).describe('Ignore pockets smaller than this.'),
  }).strict(),
  returns: 'Cave pockets, largest first, with size, bounds and an entry coordinate.',
  danger: 'read',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('MapServer', 'FindCaves', a, { timeoutMs: 15000 });
  },
});

// ── storage.stock ──────────────────────────────────────────────────────────
// StorageMan indexes every inventory on the wired network. These are the first tools that let a
// commander see and act on materials rather than only on drones.
registry.register({
  name: 'storage.stock',
  summary: 'What the base has: item kinds, totals, chests, free slots, furnaces.',
  description: 'Ask before ordering work that needs materials, and to confirm a haul actually landed.',
  params: z.object({}).strict(),
  returns: 'Summary line plus per-item totals from StorageMan.',
  danger: 'read',
  handler: async () => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  },
});

// ── storage.smelt ──────────────────────────────────────────────────────────
registry.register({
  name: 'storage.smelt',
  summary: 'Turn automatic smelting on or off.',
  description:
    'StorageMan services every furnace on the wired network on a 10s tick: pulls finished output ' +
    'to a chest, tops up fuel, and loads smeltable input. Needs at least one furnace on the ' +
    'network and fuel (coal/charcoal) in storage, or it has nothing to do.',
  params: z.object({ off: z.boolean().default(false).describe('true to stop smelting.') }).strict(),
  returns: 'Whether smelting is now on, and how many furnaces are on the network.',
  danger: 'mutate',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('StorageMan', 'smelt', a.off ? { off: true } : {}, { timeoutMs: 8000 });
  },
});

// ── order.abort ────────────────────────────────────────────────────────────
registry.register({
  name: 'order.abort',
  summary: 'Stop an order. Workers finish their current step and return to dock.',
  description: 'Safe to use whenever an order looks wrong. Aborting is cheap; a wrong order left running is not.',
  params: z.object({ id: z.string(), reason: z.string().max(200) }).strict(),
  returns: 'The aborted order and which drones were released.',
  danger: 'mutate',
  handler: async (a, ctx) => {
    const o = state.getOrder(a.id);
    if (!o) throw new ToolError(`No order "${a.id}".`, 'Check hive.brief for active order ids.');
    if (o.status === 'done' || o.status === 'aborted')
      return { id: o.id, status: o.status, note: 'already finished; nothing to stop' };
    o.status = 'aborted';
    const released = o.workers.slice();
    o.workers = [];
    ctx.log(`order ${o.id} aborted`, { reason: a.reason });
    return { id: o.id, status: o.status, released };
  },
});

// ── fleet.goto ─────────────────────────────────────────────────────────────
//
// Moving ONE named drone to ONE position was, until now, the only thing the fleet could not be
// asked to do from here. Every tool issued work over a region and let the planner choose who went.
// That is the right default and the wrong only option: when a drone is somewhere it should not be
// -- stranded on a ledge, parked at the bounds, stopped mid-job -- the fix is not an order, it is
// a destination.
//
// The gap had a real cost. D3 ended up 64 blocks above the terrain at the edge of the world and
// the only ways to move it were to invent a fake mining job near where you wanted it, or to reach
// past the system entirely and edit the save. Both are worse than the fleet simply being able to
// take the instruction.
registry.register({
  name: 'fleet.goto',
  summary: 'Send one drone to one position. The direct control the region tools deliberately lack.',
  description:
    'Use for recovery and repositioning: a drone stranded high, parked outside its dock, or ' +
    'left somewhere awkward by an aborted job. NOT for work -- digging, gathering and surveying ' +
    'are region orders so the planner can split and assign them. This aborts whatever the drone ' +
    'is currently doing, so check fleet.status first if that matters.',
  params: z.object({
    id: z.number().int().describe('Drone computer id, as shown by fleet.status.'),
    pos: vec3.describe('Where it should end up. Must be inside the operating bounds.'),
  }).strict(),
  returns: 'Whether the drone accepted the move, and the destination it was given.',
  danger: 'mutate',
  teach: [{
    situation: 'D3 (#123) finished a survey stranded at y=150 on the map edge and needs to come home.',
    args: { id: 123, pos: { x: -88, y: 86, z: -51 } },
    result: { sent: true, id: 123, to: { x: -88, y: 86, z: -51 } },
    takeaway: 'Recovery is a destination, not a job. The drone aborts and travels.',
  }],
  handler: async (a, ctx) => {
    const drone = state.listDrones().find((d) => d.id === a.id);
    if (!drone) throw new ToolError(`No drone #${a.id}.`, 'Check fleet.status for drone ids.');
    // A drone that is not reporting cannot be steered -- it will not hear this. Say so plainly
    // rather than returning a hopeful success; recover.dispatch is the tool for that case.
    if (drone.status === 'lost')
      return { sent: false, id: a.id, reason: 'drone is lost and not reporting; use recover.dispatch' };

    const res: any = await bridge.call('DroneMan', 'GoTo', { id: a.id, pos: a.pos }, { timeoutMs: 15000 });
    ctx.log(`goto #${a.id}`, { to: a.pos });
    if (res === false || res == null)
      return { sent: false, id: a.id, to: a.pos, reason: 'DroneMan did not answer' };
    // A REFUSAL COMES BACK AS A PLAIN STRING.
    //
    // PowNet puts the handler's error message in the same `data` field a success uses, so
    // `{ok:true, data:"Could not find drone with ID: 121"}` is what a rejection looks like from
    // here. Treating any non-null answer as success reported every failed order as sent -- which
    // is how a GoTo that matched no drone at all looked like it had worked.
    if (typeof res === 'string')
      return { sent: false, id: a.id, to: a.pos, reason: res };
    return { sent: true, id: a.id, to: a.pos, addressed: res?.sent ?? undefined };
  },
});


// ── plan.make ──────────────────────────────────────────────────────────────
//
// The tool that turns a GOAL into WORK. Everything else here acts on a region or a drone; this is
// the only one that answers "what would it take?".
registry.register({
  name: 'plan.make',
  summary: 'Expand a goal into the ordered jobs that would achieve it, minus what storage already holds.',
  description:
    'Ask before ordering anything compound. "Four chests" is not a job -- it is logs, planks and ' +
    'crafting, in that order, less whatever is already in the chest. Steps come back in ' +
    'dependency order, so they can be executed front to back. If something cannot be made or ' +
    'obtained it is listed in `missing` rather than quietly omitted, so an impossible goal says ' +
    'so instead of producing a plan that stalls halfway.',
  params: z.object({
    item: z.string().describe('Namespaced item, e.g. "minecraft:chest".'),
    quantity: z.number().int().min(1).max(512).default(1),
  }).strict(),
  returns: 'Ordered steps, what stock was drawn on, and anything unobtainable.',
  danger: 'read',
  teach: [{
    situation: 'We want four chests for field caches and have 8 planks in storage.',
    args: { item: 'minecraft:chest', quantity: 4 },
    result: {
      steps: [
        { item: 'minecraft:oak_log', action: 'lumber', runs: 6 },
        { item: 'minecraft:oak_planks', action: 'craft', need: 24, runs: 6 },
        { item: 'minecraft:chest', action: 'craft', need: 4, runs: 4 },
      ],
      satisfied: { 'minecraft:oak_planks': 8 },
      missing: [],
    },
    takeaway: 'The 8 planks already held are subtracted once, not once per chest.',
  }],
  handler: async (a) => {
    let stock: Record<string, number> = {};
    try {
      const res: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
      for (const d of res?.detail ?? res?.data?.detail ?? []) {
        if (typeof d?.name === 'string') stock[d.name] = (stock[d.name] ?? 0) + (d.count ?? 0);
      }
    } catch {
      // Plan against nothing rather than refusing. A plan that over-orders is recoverable; no
      // plan at all when the bridge blips is not. The response says which happened.
      stock = {};
    }
    const plan = expand(a.item, a.quantity, (i) => stock[i] ?? 0);
    return { ...plan, stockKnown: Object.keys(stock).length > 0, craftable: craftable().length };
  },
});

// ── plot.alloc ─────────────────────────────────────────────────────────────
registry.register({
  name: 'plot.alloc',
  summary: 'Reserve ground for a purpose. Every build must sit inside a plot.',
  description:
    'Allocation walks outward from the base and returns the first free footprint that fits, ' +
    'sized for the purpose and separated from its neighbours by a street. Do this BEFORE ' +
    'ordering any build: an order that names no plot is an order nothing can check, and that is ' +
    'how a monitor wall was built on top of a drone.',
  params: z.object({
    purpose: z.enum(['docks','storage','smelting','crafting','farm','forestry','mine_head','power','reserved']),
    name: z.string().max(40).optional().describe('Override the generated name.'),
  }).strict(),
  returns: 'The allocated plot, or why no ground was free.',
  danger: 'mutate',
  teach: [{
    situation: 'We have saplings and dirt and need somewhere to put a tree farm.',
    args: { purpose: 'forestry' },
    result: { name: 'forestry-01', min: { x: -85, y: 81, z: -44 }, max: { x: -75, y: 96, z: -34 }, status: 'planned' },
    takeaway: 'Site first, build second. The plot is what makes the build order checkable.',
  }],
  handler: async (a, ctx) => {
    const r = allocate(city, a.purpose as Purpose, a.name);
    if ('error' in r) throw new ToolError(r.error, 'Free ground by removing a planned plot, or widen the operating bounds.');
    saveCity();
    ctx.log(`plot ${r.name} allocated`, { purpose: r.purpose });
    return { ...r, footprint: SPEC[r.purpose] };
  },
});

// ── plot.list ──────────────────────────────────────────────────────────────
registry.register({
  name: 'plot.list',
  summary: 'What the settlement is made of, and whether a region is safe to work.',
  description:
    'With `check`, answers the only question that matters before a destructive order: may this ' +
    'region be dug or built in? A null reason means yes.',
  params: z.object({
    check: z.object({
      plot: z.string(),
      min: vec3, max: vec3,
    }).optional().describe('Validate a region against a named plot.'),
  }).strict(),
  returns: 'Every plot, and the verdict for a checked region.',
  danger: 'read',
  handler: async (a) => {
    const out: any = {
      origin: city.origin,
      bounds: city.bounds,
      count: city.plots.length,
      plots: city.plots,
    };
    if (a.check) {
      const reason = checkOrder(city, a.check.plot, { min: a.check.min, max: a.check.max });
      out.check = { allowed: reason === null, reason };
    }
    return out;
  },
});


// ── plan.execute ───────────────────────────────────────────────────────────
//
// The join between knowing and doing. plan.make answers "what would it take"; without this the
// answer had to be retyped by hand as individual orders, which is exactly the manual step the
// recipe graph exists to remove.
registry.register({
  name: 'plan.execute',
  summary: 'Expand a goal and queue the craftable steps as tasks.',
  description:
    'Runs plan.make and submits its CRAFT steps to TaskMan in dependency order, so a crafter ' +
    'picks them up as it frees. Gather and lumber steps are reported but NOT queued: those need ' +
    'a site, and guessing where to dig is how drones get sent to the wrong place. Refuses ' +
    'outright if anything in the plan is unobtainable, rather than queueing a chain that must ' +
    'stall partway.',
  params: z.object({
    item: z.string(),
    quantity: z.number().int().min(1).max(512).default(1),
  }).strict(),
  returns: 'What was queued, what still needs a site, and what could not be planned at all.',
  danger: 'mutate',
  teach: [{
    situation: 'We have logs and want four chests.',
    args: { item: 'minecraft:chest', quantity: 4 },
    result: { queued: [{ item: 'minecraft:oak_planks', runs: 8 }, { item: 'minecraft:chest', runs: 4 }], needsSite: [], missing: [] },
    takeaway: 'Both craft steps queued in order; nothing needed a dig site because the logs were held.',
  }],
  handler: async (a, ctx) => {
    let stock: Record<string, number> = {};
    try {
      const res: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
      for (const d of res?.detail ?? res?.data?.detail ?? []) {
        if (typeof d?.name === 'string') stock[d.name] = (stock[d.name] ?? 0) + (d.count ?? 0);
      }
    } catch { stock = {}; }

    const plan = expand(a.item, a.quantity, (i) => stock[i] ?? 0);
    if (plan.missing.length)
      throw new ToolError(
        `Cannot plan ${a.item}: no way to obtain ${plan.missing.join(', ')}.`,
        'Add a recipe or a source for those, or pick a different goal.');

    const queued: any[] = [];
    const needsSite: any[] = [];
    for (const step of plan.steps) {
      if (step.action !== 'craft') { needsSite.push({ item: step.item, action: step.action, runs: step.runs }); continue; }
      const res: any = await bridge.call('TaskMan', 'Add', {
        name: `craft-${step.item.replace('minecraft:', '')}`,
        priority: 3,
        work: { craft: { item: step.item, runs: step.runs, grid: step.grid, inputs: recipeInputs(step.item) } },
      }, { timeoutMs: 8000 });
      if (typeof res === 'string') throw new ToolError(`TaskMan refused ${step.item}: ${res}`, 'Check fleet.tasks.');
      queued.push({ item: step.item, runs: step.runs, task: res?.id });
    }
    ctx.log(`plan.execute ${a.item} x${a.quantity}`, { queued: queued.length });
    return { goal: a.item, quantity: a.quantity, queued, needsSite, missing: plan.missing, satisfied: plan.satisfied };
  },
});


// ── storage.pickup ─────────────────────────────────────────────────────────
registry.register({
  name: 'storage.pickup',
  summary: 'Set or read the chest where storage hands items over to drones.',
  description:
    'Crafting and any other job needing INPUTS collects from this chest. It must be a chest that ' +
    'is otherwise kept EMPTY: a turtle has twelve usable slots and turtle.suck always takes the ' +
    'first occupied slot, so a handover chest that doubles as bulk storage hides everything ' +
    'behind the first twelve stacks. Call storage.stock first to see chest names.',
  params: z.object({
    pos: vec3.optional().describe('The chest position. Omit to just read the current setting.'),
    peripheral: z.string().optional().describe('Its network name, from storage.stock.'),
  }).strict(),
  returns: 'The configured pickup point.',
  danger: 'mutate',
  handler: async (a) => {
    if (!a.pos || !a.peripheral) {
      const cur: any = await bridge.call('StorageMan', 'GetPickup', {}, { timeoutMs: 8000 });
      return { pickup: typeof cur === 'string' ? null : cur?.pickup ?? null };
    }
    const res: any = await bridge.call('StorageMan', 'SetPickup',
      { pos: a.pos, peripheral: a.peripheral }, { timeoutMs: 8000 });
    if (typeof res === 'string') throw new ToolError(res, 'Check storage.stock for valid chest names.');
    return res;
  },
});


// ── order.mine ─────────────────────────────────────────────────────────────
registry.register({
  name: 'order.mine',
  summary: 'Sink a shaft and drive branch tunnels, taking any ore the digging exposes.',
  description:
    'The only way the fleet can find ore it has never seen. gather revisits coordinates the map ' +
    'already holds; a surface survey cannot reach ore at depth, because a geo scanner sees 8 ' +
    'blocks and iron is fifty below the base. This digs down and inspects what it opens, so it ' +
    'both PRODUCES ore and TEACHES the map where more of it is. Depth matters: coal is common ' +
    'around y=50, iron around y=35, and below y=0 is deepslate and lava.',
  params: z.object({
    depth: z.number().int().min(-40).max(120).default(40).describe('Target Y for the tunnels.'),
    length: z.number().int().min(4).max(64).default(24).describe('How far each branch runs.'),
    branches: z.number().int().min(1).max(8).default(4),
    spacing: z.number().int().min(2).max(8).default(3).describe('Blocks between parallel branches.'),
    pos: vec3.optional().describe('Shaft head. Defaults to the drone starting where it is.'),
  }).strict(),
  returns: 'The queued prospecting task.',
  danger: 'destructive',
  bounds: 'Bounded by branch count and length; abortable via order.abort. Digs only ore it exposes plus the tunnels themselves.',
  teach: [{
    situation: 'We are short of iron and nothing in the survey has ever seen any.',
    args: { depth: 35, length: 24, branches: 4, spacing: 3 },
    result: { task: 31, depth: 35, note: 'prospecting; ore found is added to the map as well as the chest' },
    takeaway: 'Iron is not findable from the surface. Send someone down to look.',
  }],
  handler: async (a, ctx) => {
    const res: any = await bridge.call('TaskMan', 'Add', {
      name: `prospect-y${a.depth}`,
      priority: 3,
      work: { mine: { depth: a.depth, length: a.length, branches: a.branches, spacing: a.spacing, pos: a.pos } },
    }, { timeoutMs: 8000 });
    if (typeof res === 'string') throw new ToolError(`TaskMan refused: ${res}`, 'Check fleet.tasks.');
    ctx.log('order.mine', { depth: a.depth });
    return { task: res?.id, depth: a.depth, length: a.length, branches: a.branches };
  },
});


// ── order.prospect ─────────────────────────────────────────────────────────
//
// A MISSION, not a job: two drones with complementary hardware, in sequence.
//
// Neither can prospect alone, and the reason is physical rather than a limitation of the code. A
// turtle has two upgrade slots and the wireless modem takes one, so a scout carries a geo scanner
// and no pickaxe -- it can see 8 blocks through solid rock and cannot dig a single one. A miner
// carries a pickaxe and no scanner: it can reach any depth and can only learn what a block is by
// breaking the one in front of it. Surface surveying can never find iron, because the scanner's
// reach is 8 blocks and the ore is fifty below.
//
// Paired, they cover each other exactly: the miner cuts an access shaft, the scout walks down it
// and scans from inside -- where one sphere reveals thousands of cells of ore-bearing rock -- and
// the located veins go into the map for gather to collect. That is the whole loop, and it needs
// the two of them.
registry.register({
  name: 'order.prospect',
  summary: 'Send a miner and a scout underground together to find ore nobody has seen.',
  description:
    'Allocates (or reuses) a mine_head plot so shafts are SITED rather than dug wherever a drone ' +
    'was standing, queues a miner to sink the shaft and drive branches, then queues a scout to ' +
    'descend and scan from depth once the shaft exists. Ore found this way enters the world model, ' +
    'so ordinary gather orders can collect it afterwards. Use when a material is short and the ' +
    'survey has never seen any of it.',
  params: z.object({
    depth: z.number().int().min(-40).max(120).default(35).describe('Target Y. Coal ~50, iron ~35.'),
    length: z.number().int().min(4).max(64).default(24),
    branches: z.number().int().min(1).max(8).default(4),
    plot: z.string().optional().describe('Reuse a named mine_head plot instead of allocating one.'),
  }).strict(),
  returns: 'The plot used and both queued tasks.',
  danger: 'destructive',
  bounds: 'The SHAFT HEAD is confined to an allocated mine_head plot, so the surface keeps one ' +
    'tidy entrance per mine instead of holes wherever a drone happened to stand. The tunnels ' +
    'themselves run well beyond that footprint underground, by design — plots zone the ' +
    'settlement, not the rock beneath it.',
  teach: [{
    situation: 'Iron is at 0/32 and nothing in the survey has ever seen any.',
    args: { depth: 35, length: 24, branches: 4 },
    result: { plot: 'mine_head-01', shaftTask: 31, scanTask: 32,
              note: 'scout descends once the shaft is cut' },
    takeaway: 'One order, two drones, in dependency order — and the hole is inside a plot.',
  }],
  handler: async (a, ctx) => {
    // SITE IT. A shaft is permanent and ugly in the wrong place; the registry exists precisely so
    // the settlement does not end up pockmarked with holes nobody meant to leave.
    let plot = a.plot
      ? city.plots.find((p) => p.name === a.plot)
      : city.plots.find((p) => p.purpose === 'mine_head' && p.status !== 'active');
    if (!plot) {
      const r = allocate(city, 'mine_head');
      if ('error' in r) throw new ToolError(r.error, 'Free ground or widen the operating bounds.');
      plot = r;
    }
    plot.status = 'active';
    saveCity();

    // Shaft head at the middle of the plot.
    //
    // Only the HEAD is bounded. A grid of 32-block tunnels 16 apart covers far more ground than a
    // 5x5 plot, and pretending otherwise would be a comfortable lie: what the plot actually buys
    // is one deliberate entrance on the surface instead of a scatter of holes across the base.
    const head = {
      x: Math.floor((plot.min.x + plot.max.x) / 2),
      y: plot.ground,
      z: Math.floor((plot.min.z + plot.max.z) / 2),
    };

    const shaft: any = await bridge.call('TaskMan', 'Add', {
      name: `shaft-${plot.name}`,
      priority: 2,
      work: { mine: { pos: head, depth: a.depth, length: a.length, branches: a.branches, spacing: 3 } },
    }, { timeoutMs: 8000 });
    if (typeof shaft === 'string') throw new ToolError(`TaskMan refused the shaft: ${shaft}`, 'Check fleet.tasks.');

    // The scout waits for the shaft. dependsOn is what makes this a mission rather than two
    // unrelated orders racing each other -- sending the scout first would strand it on the surface
    // scanning dirt, which is exactly what surveying has been doing.
    const scan: any = await bridge.call('TaskMan', 'Add', {
      name: `scan-${plot.name}-y${a.depth}`,
      priority: 2,
      dependsOn: shaft?.id,
      work: { survey: { w: 4, h: 4, radius: 8, pos: { x: head.x, y: a.depth, z: head.z } } },
    }, { timeoutMs: 8000 });
    if (typeof scan === 'string') throw new ToolError(`TaskMan refused the scan: ${scan}`, 'Check fleet.tasks.');

    ctx.log('order.prospect', { plot: plot.name, depth: a.depth });
    return {
      plot: plot.name, bounds: { min: plot.min, max: plot.max },
      head, depth: a.depth,
      shaftTask: shaft?.id, scanTask: scan?.id,
      note: 'scout descends and scans once the shaft is cut; found ore enters the map for gather',
    };
  },
});


// ── rescue.party ───────────────────────────────────────────────────────────
//
// THE RESCUE TACTIC. Three drones, each carrying the one thing a casualty might be missing.
//
// A drone stops being reachable for exactly three reasons, and they need different answers:
//
//   no chunk    it left the force-loaded region and stopped ticking -- a LOADER parked nearby
//               makes the ground live again
//   no GPS      it is outside the constellation, so it cannot establish a position and (before
//               this) crashed in a reboot loop trying -- relays extend coverage to it
//   entombed    it is walled in and cannot move -- a MINER can cut it out
//
// Guessing which one it is wastes the trip, so the party carries all three answers. The members
// anchor at deliberately non-coplanar offsets, because four hosts sharing a plane cannot resolve a
// fix -- the same reason the base constellation is built the way it is.
const RESCUE_OFFSETS = [
  { x:  10, y:  6, z:   0 },
  { x: -10, y:  4, z:   6 },
  { x:   0, y:  8, z: -10 },
];

registry.register({
  name: 'rescue.party',
  summary: 'Send a loader, a scout and a miner to recover a drone that has stopped reporting.',
  description:
    'Use when a drone is lost or stranded and recover.dispatch is not enough. The party parks ' +
    'around its last known position and each member becomes a GPS relay, which both restores ' +
    'coverage and keeps the chunk ticking; the miner can dig it out if it is walled in. Members ' +
    'are chosen by role, so a fleet missing a loader gets a smaller party rather than a refusal.',
  params: z.object({
    id: z.number().int().describe('The casualty, from fleet.status.'),
    at: vec3.optional().describe('Where to search. Defaults to its last reported position.'),
  }).strict(),
  returns: 'Who was sent, where they were parked, and what the casualty last reported.',
  danger: 'mutate',
  teach: [{
    situation: 'D3 (#123) has been silent for 40 minutes at the edge of the map.',
    args: { id: 123 },
    result: { casualty: 123, at: { x: -90, y: 89, z: 12 },
              sent: [{ id: 120, role: 'loader' }, { id: 121, role: 'miner' }] },
    takeaway: 'Coverage goes TO the casualty, because the casualty cannot come to it.',
  }],
  handler: async (a, ctx) => {
    const target = state.listDrones().find((d) => d.id === a.id);
    const at = a.at ?? target?.pos;
    if (!at) throw new ToolError(
      `No position known for #${a.id}.`,
      'Pass `at` explicitly — computercraft dump shows where a computer really is.');

    // One of each role, and never the casualty itself.
    const live = state.listDrones().filter((d) =>
      d.id !== a.id && d.status !== 'lost' && d.status !== 'stranded');
    const party: any[] = [];
    for (const role of ['loader', 'scout', 'miner']) {
      const pick = live.find((d) => d.role === role && !party.some((p) => p.id === d.id));
      if (pick) party.push(pick);
    }
    if (!party.length) throw new ToolError(
      'No drone is available to send.', 'Everything else is lost or busy; free one first.');

    const sent: any[] = [];
    for (let i = 0; i < party.length; i++) {
      const o = RESCUE_OFFSETS[i % RESCUE_OFFSETS.length];
      const pos = { x: at.x + o.x, y: at.y + o.y, z: at.z + o.z };
      try {
        await bridge.call('DroneMan', 'GoTo', { id: party[i].id, pos }, { timeoutMs: 15000 });
        sent.push({ id: party[i].id, name: party[i].name, role: party[i].role, pos });
      } catch (err) {
        sent.push({ id: party[i].id, role: party[i].role, error: (err as Error)?.message ?? String(err) });
      }
    }

    ctx.log('rescue.party', { casualty: a.id, sent: sent.length });
    return {
      casualty: a.id,
      casualtyStatus: target?.status ?? 'unknown',
      casualtyReported: target?.stuck ?? null,
      at, sent,
      next: 'once they arrive, call rescue.relay to have them anchor and answer GPS pings',
    };
  },
});

// ── rescue.relay ───────────────────────────────────────────────────────────
registry.register({
  name: 'rescue.relay',
  summary: 'Have drones anchor where they are and answer GPS pings, extending the constellation.',
  description:
    'A fix needs FOUR hosts, so a single relay does not create coverage on its own — it adds to ' +
    'the pool. Run this once a rescue party has arrived. Each drone anchors on a real fix of its ' +
    'own before broadcasting, so it can never hand the casualty a confidently wrong position.',
  params: z.object({
    ids: z.array(z.number().int()).min(1).max(8),
    on: z.boolean().default(true),
  }).strict(),
  returns: 'Which drones are now relaying.',
  danger: 'mutate',
  handler: async (a, ctx) => {
    const out: any[] = [];
    for (const id of a.ids) {
      try {
        // Through DroneMan: the Bridge can only address MODULES, so anything aimed at a drone has
        // to be relayed by the module that owns the registry.
        const res: any = await bridge.call('DroneMan', 'Relay', { id, on: a.on }, { timeoutMs: 12000 });
        if (typeof res === 'string') out.push({ id, relaying: false, error: res });
        else out.push({ id, relaying: a.on, result: res ?? null });
      } catch (err) {
        out.push({ id, relaying: false, error: (err as Error)?.message ?? String(err) });
      }
    }
    ctx.log('rescue.relay', { count: out.length });
    return { relays: out };
  },
});

// ── recover.dispatch ───────────────────────────────────────────────────────
registry.register({
  name: 'recover.dispatch',
  summary: 'Send a rescue for a stranded or lost drone.',
  description:
    'A drone that stopped reporting cannot ask for help, so recovery works from its ' +
    'last known position and assigned path. Do this early: a stranded drone is a ' +
    'recoverable asset, a forgotten one is a permanent loss.',
  params: z.object({
    id: z.number().int().describe('The drone to recover.'),
    rescuer: z.number().int().optional().describe('Specific rescuer; otherwise the nearest fuelled idle drone.'),
  }).strict(),
  returns: 'The recovery order, the chosen rescuer, and the last known position being searched.',
  danger: 'mutate',
  teach: [{
    situation: 'drone-7 has been silent for four minutes.',
    args: { id: 7 },
    result: { order: 'ord-21', rescuer: 3, searching: { x: 240, y: 12, z: -180 }, lastSeenSecAgo: 244 },
    takeaway: 'Recovery dispatched from its last known position. I will watch for drone-7 to re-register.',
  }],
  handler: async (a, ctx) => {
    const target = state.listDrones().find((d) => d.id === a.id);
    if (!target) throw new ToolError(`No drone #${a.id}.`, 'Check hive.brief for drone ids.');
    if (target.status !== 'stranded' && target.status !== 'lost')
      return { skipped: true, reason: `#${a.id} is ${target.status}, not stranded or lost.` };
    const rescuer = a.rescuer ?? state.listDrones()
      .filter((d) => d.status === 'idle' && d.fuel > 400)
      .sort((x, y) => y.fuel - x.fuel)[0]?.id;
    if (rescuer === undefined)
      throw new ToolError('No idle drone with enough fuel to attempt a rescue.',
        'Refuel a drone or wait for one to finish, then retry.');
    const order = state.createOrder({ kind: 'recover', priority: 1, issuedBy: ctx.agent });
    order.workers = [rescuer];
    return {
      order: order.id, rescuer,
      searching: target.pos ?? null,
      lastSeenSecAgo: silentSec(target.silentMs),
    };
  },
});
