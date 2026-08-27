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
import { city, saveCity, factories } from '../world/city.js';
import { chain, unmetInputs, buildOrder, inputsOf, type Factory } from '../world/factories.js';
import { BLUEPRINTS, blueprint, materials, placementOrder, footprint } from '../world/blueprints.js';
import { PALETTES, towerFloor, floorCost, specForLevel, LEVELS } from '../world/tower.js';
import { supply, runSupplyTick, saveSupply, stockKey, type SupplyRule } from '../agent/supply.js';
import { luaList } from '../lua-table.js';
import { settlement, withinReach } from '../world/settlement.js';

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
  // The return leg to storage. NOT 'docking' -- that is parking on a berth, a different activity
  // that also exists here, and collapsing the two made the panel unreadable.
  hauling: 'hauling',
  docking: 'docking',
  // Stuck is a drone that has given up and said so. It needs a rescue, not a re-queue.
  stuck: 'stranded',
  // Physically fine, cannot act -- missing a position or a heading. Deliberately NOT idle: the
  // scheduler reads idle as "ready for work" and would keep handing it jobs it can only fail.
  blocked: 'stranded',
  offline: 'lost',
};

function normaliseStatus(reported: unknown, offline: unknown): DroneStatus {
  if (offline) return 'lost';
  if (typeof reported !== 'string') return 'idle';
  return REPORTED_STATUS[reported] ?? 'working';
}

/**
 * DroneMan answers the whole fleet from ONE receive loop.
 *
 * Every fleet.status re-asked it for the drone list, and the map polls fleet.status every three
 * seconds -- on top of eight drones heartbeating and TaskMan asking on its own tick. The result was
 * a module that is not broken and simply cannot keep up: calls time out, drones see unanswered
 * heartbeats and report "DroneMan is slow, staying put", and TaskMan plans against a stale fleet.
 *
 * The drone list changes on the order of seconds and is read many times a second, so nearly all of
 * that traffic was asking a busy machine a question we had just asked. A short cache plus a single
 * shared in-flight request removes it without making the data meaningfully older.
 */
const FLEET_CACHE_MS = 3_000;
let fleetAt = 0;
let fleetInflight: Promise<void> | null = null;

async function refreshFleet(): Promise<void> {
  if (!bridge.connected) return;        // offline: serve last-known state rather than erroring
  if (Date.now() - fleetAt < FLEET_CACHE_MS) return;
  // One request shared by every concurrent caller: the map's pollers arrive together, and without
  // this each would start its own round trip to the module already struggling to answer.
  if (fleetInflight) return fleetInflight;
  fleetInflight = doRefreshFleet().finally(() => { fleetInflight = null; });
  return fleetInflight;
}

async function doRefreshFleet(): Promise<void> {
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
        // WHAT it is doing, not just that it is doing something. "crafting" for twenty minutes is
        // indistinguishable from "crafting the same impossible recipe for the ninth time" without
        // the object of the verb; the drone has always known and simply never said.
        detail: typeof d.detail === 'string' ? d.detail : undefined,
        // Stock the fleet cannot see is stock the fleet does not have.
        carrying: d.inv && typeof d.inv === 'object' ? d.inv as Record<string, number> : undefined,
        // The drone's own words for why it stopped. HQ used to drop this, so a drone that had
        // explicitly reported "stuck at -70,88,12 -- no progress over 4 legs" surfaced as the
        // generic "has gone quiet" -- which describes a drone that said NOTHING, the opposite of
        // what happened, and sends you looking for a comms fault instead of reading the reason.
        stuck: typeof d.stuck === 'string' ? d.stuck : undefined,
        // A crash-looping drone reports the error its bootloader recorded. Without this it appears
        // as "idle" at its last known position -- DroneMan is still holding the healthy heartbeat
        // from before it broke -- which is how fourteen drones dying on startup looked like a fleet
        // standing around with nothing to do.
        crash: typeof d.crash === 'string' ? d.crash : undefined,
        // Which drones are currently acting as GPS hosts. Coverage is no longer a fixed bubble
        // around four computers -- it is whatever the parked fleet is collectively reaching -- so
        // "who is relaying" is now a thing an operator needs to be able to see.
        hosting: d.hosting === true ? true : undefined,
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
    fleetAt = Date.now();
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
    // LOOKS BUSY, ACHIEVES NOTHING -- the state that hid every expensive failure tonight. It is
    // reported LAST of the drone problems on purpose: a lost or stuck drone is a louder fact about
    // the same drone, and saying both would just be noise.
    else if (!d.healthy) problems.push(`${d.name} (#${d.id}) ${d.unhealthyWhy}.`);
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
        // Observed, not reported: has this drone moved or delivered lately? See HiveState.karma.
        healthy: d.healthy, stalledFor: d.unhealthyWhy ?? null,
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
      'idle', 'working', 'hauling', 'docking', 'stranded', 'lost',
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
  returns: 'Volume, known-cell count, coverage 0-1 AND the same figure as percent 0-100, top block types, observation ages, stale flag.',
  danger: 'read',
  bounds: 'Region must be non-inverted. Very large regions return coarse summaries.',
  teach: [{
    situation: 'Is the hill north of base worth quarrying?',
    args: { min: { x: 100, y: 60, z: -60 }, max: { x: 130, y: 90, z: -30 } },
    result: {
      volume: 29791, known: 811, coverage: 0.027, percent: 2,
      blocks: { stone: 640, dirt: 121, iron_ore: 22 },
      stale: false, newestObservationAgeMs: 41_000,
    },
    takeaway: 'Only 2.7% mapped — too little to plan a quarry. Scout it before ordering any digging.',
  }],
  handler: async (a) => {
    // ASK THE THING THAT ACTUALLY HAS THE MAP.
    //
    // This used to read state.summarizeRegion -- HQ's own in-memory cell store, filled by a
    // `scan.blocks` bridge event that NOTHING IN THE WORLD HAS EVER SENT. So the store was empty,
    // and world.query answered `known: 0, coverage: 0, stale: true` for every region ever asked
    // about, including cells a drone was standing in at the time, while MapServer sat on 150,000
    // real observations.
    //
    // It never threw and never logged. Both supply-loop guards that gate on coverage therefore took
    // the "we have never looked there" branch on every tick forever: a cave survey and a
    // scout-support survey were dispatched every tick regardless of what was already mapped, which
    // is what kept the queue full of re-surveys of ground the fleet had already read.
    //
    // MapServer.RegionKnown is the real answer, and its `percent` is the units the callers were
    // always written against.
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const r: any = await bridge.call('MapServer', 'RegionKnown',
      { min: a.min, max: a.max }, { timeoutMs: 20_000 });

    const volume =
      (a.max.x - a.min.x + 1) * (a.max.y - a.min.y + 1) * (a.max.z - a.min.z + 1);
    const known = Number(r?.known ?? 0);
    const percent = Number(r?.percent ?? 0);

    // Composition comes from the named-block index, which is a different and narrower thing than
    // the occupancy map -- it only holds positions whose block NAME was reported. Saying so is the
    // point: `blocks` is a partial answer and a plan that treats it as a census will be wrong.
    const counts: Record<string, number> = {};
    try {
      const map = await loadBlocks();
      for (const k in map) {
        const [x, y, z] = k.split(':').map(Number);
        if (x < a.min.x || x > a.max.x) continue;
        if (y < a.min.y || y > a.max.y) continue;
        if (z < a.min.z || z > a.max.z) continue;
        const n = map[k].replace(/^minecraft:/, '');
        counts[n] = (counts[n] ?? 0) + 1;
      }
    } catch { /* composition is a bonus; coverage is the answer that matters */ }

    return {
      volume,
      known,
      // Kept as a 0-1 fraction because that is what this tool has always documented and what the
      // teach example shows. `percent` is the same number in the units the callers compare against;
      // both are published so neither side has to guess which one it is holding.
      coverage: volume ? +(known / volume).toFixed(3) : 0,
      percent,
      blocks: Object.fromEntries(Object.entries(counts).sort((x, y) => y[1] - x[1]).slice(0, 12)),
      blocksNote: 'from the named-block index: identified positions only, not a full census',
      oldestObservationAgeMs: r?.oldestMs ?? null,
      newestObservationAgeMs: r?.newestMs ?? null,
      neverSeen: !!r?.neverSeen,
      stale: r?.neverSeen ? true : (r?.oldestMs ?? 0) > STALE_MS.world,
    };
  },
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
  name: 'world.bounds',
  summary: 'Read or set the region drones are allowed to move in.',
  description:
    'pgps refuses any step that leaves these bounds, and it is right to: stepping into an unloaded ' +
    'chunk is how a drone stops ticking and is lost. Which makes wrong bounds indistinguishable ' +
    'from a paralysed fleet -- every drone reports "outside coverage: unloaded chunk" and will not ' +
    'move, while nothing has actually failed. They must match the force-loaded region.',
  params: z.object({
    minx: z.number().optional(), maxx: z.number().optional(),
    miny: z.number().optional(), maxy: z.number().optional(),
    minz: z.number().optional(), maxz: z.number().optional(),
  }).strict(),
  returns: 'The bounds in force. With no arguments, reads them.',
  danger: 'mutate',
  bounds: 'Setting these wider than the force-loaded region will strand drones outside it.',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    if (a.minx === undefined) {
      return await bridge.call('MapServer', 'GetBounds', {}, { timeoutMs: 8000 });
    }
    return await bridge.call('MapServer', 'bounds', a, { timeoutMs: 8000 });
  },
});

registry.register({
  name: 'storage.deposit',
  summary: 'Register a chest that drones may unload into.',
  description:
    'Until one exists a miner fills its inventory and has nowhere to put anything, so the material ' +
    'economy never starts -- and everything above ground level depends on materials accumulating. ' +
    'Depositing needs NO wired network: the drone flies to one block above the position and drops ' +
    'down into it. The network is only needed for StorageMan to INDEX what is inside, which is a ' +
    'separate and much fussier problem, because activating a wired modem is block-entity state that ' +
    'no command can create.',
  params: z.object({
    x: z.number(), y: z.number(), z: z.number(),
    peripheral: z.string().optional().describe('Network name, if the chest is also wired.'),
  }).strict(),
  returns: 'Confirmation, with the registered position.',
  danger: 'mutate',
  bounds: 'Registers a position. It does not place a chest -- one has to be there already.',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call(
      'StorageMan', 'deposit',
      { pos: { x: a.x, y: a.y, z: a.z }, peripheral: a.peripheral },
      { timeoutMs: 8000 },
    );
  },
});

registry.register({
  name: 'supply.tick',
  summary: 'Run one supply pass now and report exactly what it decided.',
  description:
    'The loop runs on a timer and reports through supply.status, which shows the RESULT of past ' +
    'passes and not the reasoning of the current one. When the fleet is idle and the queue is ' +
    'empty, the useful question is "what did the loop conclude, and why did it stop there" -- and ' +
    'until now the only way to answer it was to read container logs.',
  params: z.object({}).strict(),
  returns: 'acted plus the reason it acted or did not.',
  danger: 'mutate',
  bounds: 'May dispatch work, exactly as the timed pass would.',
  handler: async () => {
    const r = await runSupplyTick();
    return { ...r, state: { frontier: supply.frontier, dispatched: supply.dispatched,
                            lastAction: supply.lastAction, notes: supply.log.slice(-6) } };
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
    action: z.enum(['gather', 'lumber', 'craft', 'mine']).optional(),
    depth: z.number().int().min(-40).max(120).optional()
      .describe('For ores: what depth to prospect at when none has ever been surveyed.'),
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
        if (a.depth !== undefined) existing.depth = a.depth;
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

    // NEAREST FIRST, OR THE FLEET WALKS PAST THE THING IT IS LOOKING FOR.
    //
    // FindBlocks returns the first N matches in index order, which is arbitrary. With 844 known
    // logs it handed back forty from the far north of the region -- so the drone flew 50 blocks to
    // chase entries it had already harvested (stale, all air) while 180 oak logs stood inside the
    // base, untouched, for hours. The gather then hit its give-up budget on those stale entries and
    // started the same trip again.
    //
    // Ask for a wide sample and pick the closest, so "go and get some wood" means the wood here.
    const found: any = await bridge.call('MapServer', 'FindBlocks',
      { match: a.match, limit: 400 }, { timeoutMs: 15000 });
    const hits = found?.hits ?? found?.data?.hits ?? [];
    const all = Array.isArray(hits) ? hits : Object.values(hits ?? {});
    const base = settlement.base;
    const seeds = (all as any[])
      .filter((h) => h && typeof h.x === 'number')
      // INSIDE THE OPERATING CIRCLE, OR THE JOB IS AN INSTRUCTION TO GET LOST.
      //
      // The index still holds positions surveyed when the region was a square, and plenty of them
      // are outside the circle the fleet can actually call home from. Seeding a gather straight
      // from it is how D3 ended up at -496,53,126 -- out of modem range, out of GPS, not ticking,
      // and only found by force-loading a 160-block box to look for it.
      .filter((h) => withinReach(h))
      .sort((p, q) =>
        (Math.abs(p.x - base.x) + Math.abs(p.y - base.y) + Math.abs(p.z - base.z)) -
        (Math.abs(q.x - base.x) + Math.abs(q.y - base.y) + Math.abs(q.z - base.z)))
      .slice(0, 40);
    if (!seeds.length) {
      throw new ToolError(
        `Nothing matching "${a.match}" has been surveyed.`,
        'Survey the area first, or check world.find for what is actually known.');
    }

    // FUEL OUTRANKS EVERYTHING ELSE THE FLEET COULD BE FETCHING.
    //
    // Every gather was queued at the same priority, so coal competed on equal terms with copper,
    // zinc, lapis and dirt -- and lost, repeatedly, because there are six of them and one of it.
    // Watched live: gather:coal_ore sat unassigned through tick after tick with idle miners
    // available, while the settlement burned its last 128 coal and drones started dropping to zero.
    //
    // This is not a preference, it is an ordering constraint. A drone with no fuel cannot gather
    // copper either -- it cannot do ANYTHING, including the rescue that would reach it. Fuel is
    // upstream of every other material by definition, so it belongs above them in the queue.
    const FUEL_MATCH = /coal|charcoal/;
    const res: any = await bridge.call('TaskMan', 'Add', {
      name: `gather:${a.match}`,
      priority: FUEL_MATCH.test(a.match) ? 1 : 2,
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
// FIVE MINUTES, not ten seconds.
//
// Terrain is the slowest-changing thing in the world -- drones reveal it a few hundred cells at a
// time -- and re-reading ALL of it every ten seconds meant 115 paged round trips per refresh
// against the single busiest module in the fleet. MapServer spent most of its life serving the same
// 230,000 cells to the same map page, which is why it answered everything else slowly.
//
// It also produced the "corrupt map": when paging timed out part way, the render got whatever
// fraction had arrived, so /map drew a world with most of the blocks missing and redrew a DIFFERENT
// fraction on the next poll. A five-minute cache is both far cheaper and far more stable to look at.
const VOXEL_CACHE_MS = 300_000;
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
    // PAGE IT. The survey is ~490KB of JSON and a websocket frame caps far below that, so asking
    // for the whole thing did not return a trimmed world -- it returned NOTHING, and the map
    // rendered no terrain at all. There is no reason the viewer cannot have all of it; it just has
    // to arrive in pieces.
    //
    // PowNet replies are unwrapped by the Bridge, but SaveWorld-era callers saw a nested `data`,
    // so accept both shapes rather than returning an empty world on a wrapper change.
    const grid: Record<string, number> = {};
    let offset: number | undefined = 0;
    let truncated = false;
    for (let page = 0; page < 200 && offset !== undefined; page++) {
      let res: any;
      try {
        res = await bridge.call('MapServer', 'LoadWorld', { offset }, { timeoutMs: 20_000 });
      } catch {
        res = null;
      }
      const chunk = res?.cachedWorld ?? res?.data?.cachedWorld;
      // A FAILED PAGE IS NOT THE END OF THE MAP.
      //
      // Missing cachedWorld left `next` undefined, which the loop read as "that was the last page"
      // -- so one timeout mid-walk silently returned a fraction of the world as if it were all of
      // it. The map went from 111,684 cells to 9,216 and reported success. Partial data presented
      // as complete is worse than an error: everything downstream trusts it.
      if (!chunk || typeof chunk !== 'object') {
        truncated = true;
        break;
      }
      Object.assign(grid, chunk);
      const nxt = res?.next ?? res?.data?.next;
      offset = typeof nxt === 'number' ? nxt : undefined;
    }

    // Keep the better answer. A truncated read must not replace a complete one in the cache,
    // because the next caller cannot tell the difference.
    if (truncated && voxelCache && Object.keys(voxelCache.grid).length > Object.keys(grid).length) {
      console.log(`[voxels] partial read (${Object.keys(grid).length} cells); keeping the previous ${Object.keys(voxelCache.grid).length}`);
      return voxelCache.grid;
    }
    // NEVER CACHE A TRUNCATED READ AT FULL TTL, AND NEVER CACHE AN EMPTY ONE AT ALL.
    //
    // A failed page-0 -- MapServer restarting, or busy -- produced an empty grid with no previous
    // cache to fall back on, and that emptiness was then stored for the full five minutes. The map
    // page showed no terrain and kept showing none long after MapServer was healthy again, which
    // read as lost survey data: /map/voxels returned known:0 with cachedAgeMs:103819 while MapServer
    // held 274,750 cells. Backdating the timestamp makes a partial answer expire in 30s instead of
    // 300, so the map heals itself on the next poll rather than at the next restart.
    if (truncated && Object.keys(grid).length === 0) {
      console.log('[voxels] read returned nothing; not caching, will retry');
      return grid;
    }
    voxelCache = { at: truncated ? Date.now() - (VOXEL_CACHE_MS - 30_000) : Date.now(), grid };
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

// Same reasoning as the voxel cache: block identity changes only when a drone reports a new name.
const BLOCKS_CACHE_MS = 300_000;
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
    // 40 pages of 2000 was a 80,000-entry ceiling on an index that now holds 172,296 named blocks,
    // so even a healthy read stopped less than halfway and reported no error. The limit exists only
    // to bound a runaway paginator, so it is set above the largest plausible index rather than at
    // yesterday's map size.
    const map: Record<string, string> = {};
    let offset: number | undefined = 0;
    let truncated = false;
    for (let page = 0; page < 300 && offset !== undefined; page++) {
      let res: any;
      try {
        // A slow page is not a missing one. Eight seconds was tight enough that a busy MapServer
        // threw here, which -- with no catch -- rejected the whole read and left the map with no
        // block identities at all.
        res = await bridge.call('MapServer', 'BlockAt', { offset }, { timeoutMs: 20_000 });
      } catch {
        res = null;
      }
      const chunk = res?.blockAt ?? res?.data?.blockAt;
      if (!chunk || typeof chunk !== 'object') { truncated = true; break; }
      Object.assign(map, chunk);
      const nxt = res?.next ?? res?.data?.next;
      offset = typeof nxt === 'number' ? nxt : undefined;
    }
    if (truncated && blocksCache && Object.keys(blocksCache.map).length > Object.keys(map).length) {
      console.log(`[blocks] partial read (${Object.keys(map).length}); keeping the previous ${Object.keys(blocksCache.map).length}`);
      return blocksCache.map;
    }
    if (truncated && Object.keys(map).length === 0) {
      console.log('[blocks] read returned nothing; not caching, will retry');
      return map;
    }
    blocksCache = { at: truncated ? Date.now() - (BLOCKS_CACHE_MS - 30_000) : Date.now(), map };
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
    // AN EMPTY LUA TABLE IS `{}`, WHICH IS AN OBJECT HERE, NOT AN ARRAY.
    //
    // textutils/JSON cannot tell an empty Lua list from an empty Lua map, so a fleet with nothing
    // queued came back as `{}` and `.map` threw "raw.map is not a function" -- the queue read as
    // BROKEN precisely when it was simply empty. The same happens for a sparse task table, which
    // TaskMan's is: keys are task ids, so any gap makes it serialise as an object.
    const rawAny = res?.tasks ?? res?.data?.tasks ?? [];
    const raw: any[] = Array.isArray(rawAny)
      ? rawAny
      : (rawAny && typeof rawAny === 'object' ? Object.values(rawAny) : []);
    // LIVE WORK FIRST, and only a handful of finished ones.
    //
    // Returning every task ever created meant 149 entries of which 22 were live, so the answer to
    // "what is the fleet doing" was mostly surveys that completed hours ago. TaskMan prunes them on
    // its own timer now; this caps what a caller sees regardless, because the queue can still be
    // large right after a burst of work.
    const all = raw.map(describeTask);
    const live = all.filter((t: any) => (t.progress ?? 0) < 100);
    const done = all.filter((t: any) => (t.progress ?? 0) >= 100).slice(-10);
    // CAP THE LIVE LIST. Returning every live task was fine at 22 of them and fatal at 300: the
    // reply hit 63,792 bytes against a 61,440-byte websocket frame limit and the whole call failed,
    // so the map page and every status check lost the task list entirely -- and "fleet.tasks failed"
    // reads exactly like "the queue is empty", which is the opposite of the truth. The queue was
    // overflowing because the supply loop creates work faster than the fleet retires it.
    //
    // Assigned tasks come first: what the fleet is doing right now is the part worth seeing, and the
    // backlog is a number, not a list.
    const LIVE_CAP = 60;
    const ordered = [...live].sort((a: any, b: any) => (b.assigned ? 1 : 0) - (a.assigned ? 1 : 0));
    const shown = ordered.slice(0, LIVE_CAP);
    // REPORT TASKMAN'S TOTALS, NOT THIS PAGE'S.
    //
    // TaskMan caps its reply at 40 tasks to stay inside the websocket frame, so counting the array
    // that arrives says "40 live" whether the real backlog is 40 or 400 -- a page described as the
    // whole queue, which is the same failure that made the map read 16,000 blocks and call it done.
    const total = typeof res?.total === 'number' ? res.total : all.length;
    const liveTotal = typeof res?.live === 'number' ? res.live : live.length;
    return {
      count: total,
      live: liveTotal,
      assigned: live.filter((t: any) => t.assigned).length,
      backlog: liveTotal > shown.length ? liveTotal - shown.length : 0,
      tasks: [...shown, ...done],
    };
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
  const rawVerb = Object.keys(work)[0];
  // THREE KINDS OF LOOKING, and they are not the same job.
  //
  //   explore  go and find ground nobody has seen. Speculative, chosen by a spiral, lowest value
  //            per scan but the only thing that grows the map outward.
  //   scout    examine something already known to be interesting -- a cave, an ore cluster. The
  //            scanner reads exposed material rather than solid rock, so a scan is worth far more.
  //   assist   support another drone where it is standing. A miner cutting through unmapped rock
  //            with a scanner overhead stops digging blind, which is the entire point of pairing.
  //
  // They were all dispatched as "survey", so the queue could not distinguish a scout flying across
  // the base on a guess from one sent to help a miner right now -- and neither could anyone reading
  // it. The kind rides along inside work.survey, so TaskMan passes it through untouched.
  const verb = rawVerb === 'survey' && typeof work.survey?.kind === 'string'
    ? work.survey.kind : rawVerb;
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
      // No special case any more: MainFrame answers Status like everything else, so it is probed
      // like everything else. The special case existed only because it could not be asked, and it
      // is what showed a healthy module as "not answering" for its entire life.
      try {
        // BUSY IS NOT DEAD. RETRY BEFORE CONDEMNING A MODULE.
        //
        // These are single-threaded computers. MapServer rebuilds a 206,000-cell map and does not
        // answer while it does; probe it in that window and it reads "not answering" -- a healthy
        // module shown as down, next to a MainFrame that was ALSO shown as down for a different
        // spurious reason. That is how a dashboard teaches you to distrust it, and it sent me
        // chasing a wedged MapServer that was busy doing its job.
        //
        // One retry after a short pause distinguishes "busy for a moment" from "gone". A genuinely
        // wedged module fails both and is still reported, which is the case that matters.
        let r: any;
        try {
          r = await bridge.call(m.host, 'Status', {}, { timeoutMs: 5000 });
        } catch {
          await new Promise((res) => setTimeout(res, 1500));
          r = await bridge.call(m.host, 'Status', {}, { timeoutMs: 5000 });
        }
        const s = r?.data ?? r ?? {};
        // A MONITOR LINE FROZEN AT BOOT IS NOT NEWS.
        //
        // DroneMan, StorageMan and DockingMan write "Starting..." once and never again, so the
        // panel showed three healthy modules apparently stuck mid-boot for sixty hours. If the
        // module has nothing newer to say, say how long it has been fine instead.
        const upSec = typeof s.up === 'number' ? Math.round(s.up) : null;
        let monitor = s.monitor ?? null;
        if (upSec !== null && upSec > 120 && (!monitor || /^starting/i.test(String(monitor)))) {
          monitor = `up ${Math.round(upSec / 60)}m, nothing to report`;
        }
        return {
          module: m.label, reachable: true,
          id: s.id ?? null, label: s.label ?? null,
          pos: s.pos && typeof s.pos.x === 'number' ? s.pos : null,
          upSec,
          faults: s.faults ?? 0,
          lastFault: s.lastFault ?? null,
          monitor,
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
    // SIXTY SECONDS. Cave detection walks the entire map twice plus a flood fill, and now that
    // those loops yield (they must -- unyielded they aborted MapServer outright) each yield costs a
    // tick. At 237,000 cells that is legitimately half a minute of wall clock, not a hang. A 15s
    // budget turned a slow-but-correct answer into "no response from MapServer.FindCaves", which is
    // why nothing has ever dispatched a cave survey.
    return await bridge.call('MapServer', 'FindCaves', a, { timeoutMs: 60000 });
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

// ── dock.list / dock.add ───────────────────────────────────────────────────
registry.register({
  name: 'dock.list',
  summary: 'Docking towers and who is berthed in them.',
  description:
    'A docking tower is a column with four berths per level in a plus around a central inventory, ' +
    'so all four drones in a level face the same block and can draw fuel from it. Slots are ' +
    'reserved on docking and released on undocking.',
  params: z.object({}).strict(),
  returns: 'Towers with position, slot count, and current occupants.',
  danger: 'read',
  handler: async () => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('DockingMan', 'ls', {}, { timeoutMs: 8000 });
  },
});

registry.register({
  name: 'dock.add',
  summary: 'Register a docking tower at a position.',
  description:
    'Until one exists, drones have nowhere to park and nowhere to refuel -- and a drone that ' +
    'cannot refuel eventually strands somewhere that needs a miner sent to dig it out. The ' +
    'position is the CENTRAL COLUMN, not a berth: DockingMan places slot % 4 at pos +/- 1 in x or ' +
    'z and turns each drone inward to face it, and height comes from floor(slot / 4). So the ' +
    'position wants to be an inventory with open air on four sides at every level it serves.',
  params: z.object({
    name: z.string().describe('Human label for the tower.'),
    x: z.number(), y: z.number(), z: z.number(),
    height: z.number().default(4).describe('Levels of four berths each, counting up from y.'),
  }).strict(),
  returns: 'The registered tower.',
  danger: 'mutate',
  bounds: 'Registers the tower in DockingMan. It does not build anything -- the blocks must already be there.',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call(
      'DockingMan', 'add',
      { name: a.name, pos: [a.x, a.y, a.z], height: a.height },
      { timeoutMs: 8000 },
    );
  },
});

registry.register({
  name: 'dock.remove',
  summary: 'Unregister a docking tower.',
  description:
    'Needed more often than it sounds: a tower registered with a bad position cannot be fixed in ' +
    'place, only deleted and re-made.',
  params: z.object({ id: z.string().describe('Tower id from dock.list.') }).strict(),
  returns: 'Confirmation from DockingMan.',
  danger: 'mutate',
  bounds: 'Drones berthed in it lose their slot record; they re-allocate on the next dock.',
  handler: async (a) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    return await bridge.call('DockingMan', 'rm', { id: a.id }, { timeoutMs: 8000 });
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

    // 40s, not 15. DroneMan aborts the drone and waits for it to acknowledge BEFORE sending the
    // move, so a tight budget reports failure for an order that is in fact being carried out --
    // the most misleading outcome available, and it has now fooled me twice.
    const res: any = await bridge.call('DroneMan', 'GoTo', { id: a.id, pos: a.pos }, { timeoutMs: 40000 });
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
    'Runs plan.make and submits its CRAFT steps to TaskMan, each waiting on the one before it, so ' +
    'a crafter cannot take the last step first and fail for want of the step it is blocking. ' +
    'Gather and lumber steps are dispatched too: those do not need a chosen site -- the material ' +
    'is simply out there -- and leaving them unqueued is how a plan identifies a shortage and then ' +
    'does nothing about it. Anything with no surveyed source comes back as `unsourced`.',
  params: z.object({
    item: z.string(),
    quantity: z.number().int().min(1).max(512).default(1),
  }).strict(),
  returns: 'What was queued, what still needs a site, and what could not be planned at all.',
  danger: 'mutate',
  teach: [{
    situation: 'We have logs and want four chests.',
    args: { item: 'minecraft:chest', quantity: 4 },
    result: { queued: [{ item: 'minecraft:oak_planks', runs: 8 }, { item: 'minecraft:chest', runs: 4 }], unsourced: [], missing: [] },
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
    // NOT "needs a site" -- that was a wrong assumption, and it shaped the behaviour.
    //
    // Gathering does not need a designated site: logs, ore and dirt are simply out there, and the
    // fleet can be told to go and get some. Only sinking a shaft needs a chosen spot. Calling every
    // non-craft step "needsSite" made them all look like they were waiting on a human decision, so
    // they were reported and dropped -- the planner would work out that the chest needs 32 logs and
    // the fleet has 22, and then queue nothing.
    //
    // What is left here now genuinely means UNSOURCED: nothing surveyed matches it, so there is
    // nowhere to send anyone yet.
    const unsourced: any[] = [];
    // CHAIN THE STEPS, DO NOT MERELY EMIT THEM IN ORDER.
    //
    // This said "in dependency order" and set no dependsOn at all: the steps came out of plan.make
    // topologically sorted and were then queued as unrelated peers. So the crafter was free to take
    // the LAST step first -- and did. craft-chest needs planks, planks did not exist yet, so it
    // failed, was requeued, and took the crafter again, while craft-oak_planks sat behind it marked
    // "no crafter free". The one task that would have unblocked the chain was starved by the task
    // waiting on it, for ever.
    //
    // The order was already correct; it just was not binding. Making each step wait on the one
    // before it is what turns a list into the tree the queue is supposed to be.
    let previous: number | undefined;
    for (const step of plan.steps) {
      // A SHORTAGE THE PLAN FOUND IS A SHORTAGE SOMEBODY SHOULD GO AND FIX.
      //
      // Gather steps were reported as needsSite and then dropped on the floor. So the planner would
      // work out that the chest needs planks, and the planks need 32 logs, and the fleet has 22 --
      // and then queue nothing to close the gap. The craft failed on missing logs for ever while
      // the miners, idle, were never told to cut any. The plan knew; nothing asked it.
      //
      // order.gather is region-filtered and nearest-first, so this is safe to fire automatically.
      // Anything it cannot source (no known deposits) still comes back as needsSite for a human.
      if (step.action !== 'craft') {
        if (step.action === 'gather' || step.action === 'lumber') {
          try {
            const g: any = await registry.invoke('order.gather',
              { match: step.item.replace(/^[a-z0-9_]+:/, ''), limit: 64 }, ctx);
            const gd = g?.data ?? g;
            if (gd?.dispatched) {
              queued.push({ item: step.item, runs: step.runs, action: 'gather', task: gd.task, after: previous });
              // THE GATHER IS THE FIRST LINK, NOT A SIDE ERRAND.
              //
              // Dispatched and then left dangling, it was just another queued gather competing with
              // speculative ones -- so the scheduler had no way to know that THIS wood is what the
              // whole chain is waiting on. Chaining the next craft onto it makes the gather a
              // blocker, which the blocker pass places first and will interrupt other work for.
              if (typeof gd.task === 'number') previous = gd.task;
              continue;
            }
          } catch { /* nothing surveyed for it; fall through and report honestly */ }
        }
        unsourced.push({ item: step.item, action: step.action, runs: step.runs });
        continue;
      }
      const res: any = await bridge.call('TaskMan', 'Add', {
        name: `craft-${step.item.replace('minecraft:', '')}`,
        priority: 3,
        dependsOn: previous,
        work: { craft: { item: step.item, runs: step.runs, grid: step.grid, inputs: recipeInputs(step.item) } },
      }, { timeoutMs: 8000 });
      if (typeof res === 'string') throw new ToolError(`TaskMan refused ${step.item}: ${res}`, 'Check fleet.tasks.');
      const id = res?.id ?? res?.data?.id;
      queued.push({ item: step.item, runs: step.runs, task: id, after: previous });
      previous = typeof id === 'number' ? id : previous;
    }
    ctx.log(`plan.execute ${a.item} x${a.quantity}`, { queued: queued.length });
    return { goal: a.item, quantity: a.quantity, queued, unsourced, missing: plan.missing, satisfied: plan.satisfied };
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
    // Dense on purpose, and different from order.prospect. A miner working ALONE finds ore only
    // by exposing it, so tight branches are correct. Prospecting spaces them for a scout's scanner
    // instead, which sees 8 blocks through rock and makes close branches wasted digging.
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
    /**
     * Spaced for the SCANNER, not the pickaxe.
     *
     * A geo scanner reaches 8 blocks, so tunnels 16 apart let the scan spheres tile the rock
     * between them with nothing missed. This was hardcoded to 3, which is dense branch-mining
     * spacing -- it finds ore by brute exposure and digs roughly five times as much tunnel to
     * cover the same ground. That is the right strategy for a miner working ALONE and the wrong
     * one the moment a scout is coming down behind it, which is the entire point of the pair.
     */
    spacing: z.number().int().min(2).max(24).default(16),
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
    args: { depth: 35, length: 24, branches: 4, spacing: 16 },
    result: { plot: 'mine_head-01', shaftTask: 31, scanTask: 32,
              note: 'scout descends once the shaft is cut' },
    takeaway: 'One order, two drones, in dependency order — and the hole is inside a plot.',
  }],
  handler: async (a, ctx) => {
    // SITE IT. A shaft is permanent and ugly in the wrong place; the registry exists precisely so
    // the settlement does not end up pockmarked with holes nobody meant to leave.
    let plot = a.plot
      ? city.plots.find((p) => p.name === a.plot)
      // NEAREST TO THE SETTLEMENT, NOT FIRST IN THE LIST.
      //
      // "first non-active" meant the centre shaft got marked active on its first attempt, failed,
      // and was never chosen again -- so every later prospect picked a plot further out and the
      // ground directly under the tower stayed untouched. That shaft is the point of the design: it
      // is the basement excavation, the cobblestone quarry, and the only route to the redstone that
      // gates everything above the fifth floor.
      //
      // Preferring the nearest plot makes the centre the default. Active ones are still eligible if
      // nothing else is free -- a shaft can always be deepened, and refusing to reuse one is how the
      // fleet ends up with a field of abandoned holes.
      : (() => {
          const heads = city.plots.filter((p) => p.purpose === 'mine_head');
          const d = (p: typeof heads[number]) =>
            Math.hypot(p.min.x - city.origin.x, p.min.z - city.origin.z);
          const free = heads.filter((p) => p.status !== 'active').sort((x, y) => d(x) - d(y));
          return free[0] ?? heads.sort((x, y) => d(x) - d(y))[0];
        })();
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
      work: { mine: { pos: head, depth: a.depth, length: a.length, branches: a.branches, spacing: a.spacing } },
    }, { timeoutMs: 8000 });
    if (typeof shaft === 'string') throw new ToolError(`TaskMan refused the shaft: ${shaft}`, 'Check fleet.tasks.');

    // The scout waits for the shaft to REACH ITS DEPTH, not to finish.
    //
    // dependsOn is what makes this a mission rather than two unrelated orders racing each other --
    // sending the scout first would strand it on the surface scanning dirt. But waiting for the
    // whole dig to complete serialises work that is meant to overlap: the scan at y=12 becomes
    // possible the moment the shaft passes y=12, and everything after that is branch tunnels the
    // scout does not care about. `after` is the shaft's progress percentage at which the scan is
    // workable -- 95, not 100, because arriving slightly early costs a short wait at the shaft head
    // and arriving late costs the whole remainder of the dig.
    const scan: any = await bridge.call('TaskMan', 'Add', {
      name: `scan-${plot.name}-y${a.depth}`,
      priority: 2,
      dependsOn: shaft?.id,
      after: 95,
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
        // Generous: DroneMan aborts the drone before sending, and doing that for each member of a
        // party in turn easily outruns a tight budget -- the order then reports failure while the
        // work is actually happening, which is the most misleading outcome available.
        await bridge.call('DroneMan', 'GoTo', { id: party[i].id, pos }, { timeoutMs: 40000 });
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
        // Comfortably past DroneMan's own per-drone wait plus its queueing, so a slow relay reads
        // as "that drone declined" rather than "the registry is down" -- two very different faults
        // that this budget used to conflate.
        const res: any = await bridge.call('DroneMan', 'Relay', { id, on: a.on }, { timeoutMs: 20000 });
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


/**
 * Item -> count across every chest the fleet can see.
 *
 * The same eight lines were written out three times, and the copies had already diverged on the one
 * thing that matters: what to do when storage cannot be read. Two of them planned against an empty
 * map, which is right for a planner -- over-ordering is recoverable. The third dispatches a drone to
 * place two thousand blocks, where believing in cobblestone you do not have strands it mid-floor.
 * So the caller decides, and has to say so.
 */
async function readStock(onUnreadable: 'empty' | 'throw'): Promise<Record<string, number>> {
  const stock: Record<string, number> = {};
  try {
    const res: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
    for (const d of luaList<any>(res?.detail ?? res?.data?.detail) ?? []) {
      if (typeof d?.name === 'string') stock[d.name] = (stock[d.name] ?? 0) + (d.count ?? 0);
    }
  } catch {
    if (onUnreadable === 'throw') {
      throw new ToolError('Cannot read storage, so cannot cost the work.', 'Check hive.nodes.');
    }
  }
  return stock;
}

// ── order.build ────────────────────────────────────────────────────────────
//
// The end of the loop: material becomes infrastructure, on ground that was reserved for it.
//
// Everything is checked BEFORE a drone moves, because a half-built structure is far more annoying
// than one that never started: the site is validated against the plot registry, the cost is
// expanded through the recipe graph, and any missing material is CRAFTED first. The build itself is
// queued to depend on those craft steps, so it cannot begin and stall halfway.
registry.register({
  name: 'order.tower',
  summary: 'Build one floor of the tower, in cobblestone, as a chain of drone-sized build tasks.',
  description:
    'The tower generator has existed and been unreachable: nothing imported it, so no tool could ' +
    'ask for a floor and the settlement had no cellar, no ground floor and no way to get one. ' +
    'This is that ask. It costs the floor, keeps only the blocks the fleet can actually afford, ' +
    'and splits the rest into tasks small enough for one drone to carry -- a floor is ~2,350 ' +
    'blocks and a turtle holds 1,024, so a single build task could never finish one.',
  params: z.object({
    level: z.number().int().min(-3).max(7).default(-1)
      .describe('Which level. -1 is the sorted-storage cellar, 0 the ground/ingest floor.'),
    palette: z.enum(['cobble', 'brick', 'create']).default('cobble')
      .describe('cobble is tier 0: everything in it falls out of a mining shaft.'),
    blocksPerTask: z.number().int().min(32).max(512).default(192)
      .describe('Blocks per build task. Must fit a drone: 192 is three stacks with room to work.'),
  }).strict(),
  returns: 'The level, what it costs, what was affordable, and the queued build tasks.',
  danger: 'destructive',
  bounds: 'Centred on the settlement base. Only blocks whose material is in stock are queued.',
  teach: [{
    situation: 'Storage is 78% cobblestone and the settlement has nothing to spend it on.',
    args: { level: -1, palette: 'cobble' as const, blocksPerTask: 192 },
    result: { level: -1, queued: 12, cobblestoneUsed: 2310 },
    takeaway: 'The spoil heap becomes the building. Mining already paid for it.',
  }],
  handler: async (a, ctx) => {
    const spec = specForLevel(a.level);
    const mats = PALETTES[a.palette]!;
    const blocks = towerFloor(spec, a.level, mats);
    const cost = floorCost(blocks);

    // WHAT THE FLEET CAN ACTUALLY AFFORD, not what the design asks for.
    //
    // A floor wants twelve glass, and glass needs a furnace the settlement does not yet have --
    // so a task demanding it dies with "ran out of minecraft:glass partway through" and abandons a
    // half-built floor. The cobblestone is the point here: 2,310 of the 2,354 blocks, and the one
    // material there are ten thousand of. Build what is affordable now and reface later; that is
    // exactly what the palette ladder is for.
    const stock = await readStock('throw');
    const affordable = blocks.filter((b) => (stock[b.item] ?? 0) > 0);
    const skipped = blocks.length - affordable.length;
    if (!affordable.length) throw new ToolError(
      `Nothing in stock for a ${a.palette} level ${a.level}.`,
      `It needs ${Object.keys(cost).join(', ')}.`);

    // Slab first, then outward and upward -- a turtle places against an adjacent face, so the
    // ground must exist before anything can stand on it. Same ordering rule as a blueprint.
    const ordered = [...affordable].sort((x, y) =>
      x.dy - y.dy ||
      (Math.abs(x.dx) + Math.abs(x.dz)) - (Math.abs(y.dx) + Math.abs(y.dz)) ||
      x.dx - y.dx || x.dz - y.dz);

    const base = settlement.base;
    const origin = { x: base.x, y: base.y + a.level * spec.floorHeight, z: base.z };

    // CHUNKED, AND DELIBERATELY NOT CHAINED.
    //
    // A drone holds sixteen stacks and a floor is ~1,500 blocks, so the work is split one task per
    // drone-load. Those tasks USED to chain -- `dependsOn: prev` -- "so the floor is laid in order
    // rather than by whoever happens to be free".
    //
    // That is the reason the tower was never built. Not fuel, not pathing, not congestion: a flat
    // floor laid out of order is indistinguishable from one laid in order, and the chain bought
    // that invisible tidiness at the price of the entire build. Observed live, with SIX drones
    // idle:
    //
    //   tower-L0-p01  running
    //   tower-L0-p02  running
    //   tower-L0-p03  blocked  waiting on tower-L0-p02
    //   ... all eleven remaining blocked, each on the one before
    //
    // Two tasks can run no matter how many drones are free, and the moment the head of the chain
    // stalls -- a drone goes dry, gets rescued, drops to lost, all routine here -- everything
    // behind it waits for ever. Cobblestone sat at 10,864 with 1 free storage slot and did not move
    // by a single block over three minutes, which then jams storage, which strands more drones.
    //
    // The patches are independent. Let whoever is free take one.
    //
    // If a future level genuinely needs the one below it finished first, chain the LEVELS -- do not
    // reintroduce ordering between patches of the same floor.
    const queued: any[] = [];
    for (let i = 0; i < ordered.length; i += a.blocksPerTask) {
      const part = ordered.slice(i, i + a.blocksPerTask);
      const res: any = await bridge.call('TaskMan', 'Add', {
        name: `tower-L${a.level}-p${String(queued.length + 1).padStart(2, '0')}`,
        // ONE. The settlement should be building its base before it speculatively gathers more ore
        // -- which it will otherwise do for ever, because there is always another material short.
        priority: 1,
        work: { build: { origin, blocks: part } },
      }, { timeoutMs: 12000 });
      if (typeof res === 'string') break;      // TaskMan refused; stop rather than queue a gap
      queued.push({ task: res?.id, blocks: part.length });
    }

    ctx.log('order.tower', { level: a.level, palette: a.palette, tasks: queued.length });
    return {
      level: a.level, name: LEVELS.find((l) => l.index === a.level)?.name ?? String(a.level),
      origin, cost, affordable: affordable.length, skippedForMaterials: skipped,
      tasks: queued,
      note: skipped
        ? `${skipped} block(s) skipped -- no stock for them yet; reface when the smelters run`
        : 'everything affordable',
    };
  },
});


// ── order.build ────────────────────────────────────────────────────────────
registry.register({
  name: 'order.build',
  summary: 'Build a blueprint on a plot, crafting whatever it needs first.',
  description:
    'Sites the structure in a plot of the right purpose (allocating one if needed), refuses it if ' +
    'the footprint would leave that plot or enter another, costs it through the recipe graph, ' +
    'queues any crafting, and queues the build behind it. Use blueprints:list to see what exists.',
  params: z.object({
    blueprint: z.string().describe('Blueprint name, e.g. "field-cache".'),
    plot: z.string().optional().describe('Reuse a named plot instead of allocating one.'),
  }).strict(),
  returns: 'The plot, the footprint, what had to be crafted, and the queued tasks.',
  danger: 'destructive',
  bounds: 'Confined to the named plot; refused outright if the footprint leaves it or overlaps another.',
  teach: [{
    situation: 'Miners are commuting home to unload; we want a cache at the dig.',
    args: { blueprint: 'field-cache' },
    result: { plot: 'storage-02', crafted: [{ item: 'minecraft:chest', runs: 1 }], buildTask: 41 },
    takeaway: 'One order: sited, costed, crafted, then built — in that order.',
  }],
  handler: async (a, ctx) => {
    const bp = blueprint(a.blueprint);
    if (!bp) throw new ToolError(
      `No blueprint "${a.blueprint}".`,
      `Known: ${BLUEPRINTS.map((b) => b.name).join(', ')}`);

    let plot = a.plot
      ? city.plots.find((p) => p.name === a.plot)
      : city.plots.find((p) => p.purpose === bp.purpose && p.status === 'planned');
    if (!plot) {
      const r = allocate(city, bp.purpose);
      if ('error' in r) throw new ToolError(r.error, 'Free ground or widen the operating bounds.');
      plot = r;
    }

    // Centre it, then check. Siting and checking are separate on purpose: the check is the rule,
    // and a rule that only ever sees positions the same code chose is not a rule.
    const origin = {
      x: Math.floor((plot.min.x + plot.max.x) / 2),
      // dy=0 is the WORKING SURFACE, not the block above it. Siting at ground+1 pushed every
      // structure one block higher than the plot was sized for, and the registry duly refused a
      // four-block post on a four-block plot -- correctly, which is the point of having the check
      // rather than trusting the code that chose the position.
      y: plot.ground,
      z: Math.floor((plot.min.z + plot.max.z) / 2),
    };
    const fp = footprint(bp, origin);
    const refusal = checkOrder(city, plot.name, fp);
    if (refusal) throw new ToolError(
      `Cannot build ${bp.name} on ${plot.name}: ${refusal}.`,
      'Allocate a bigger plot for this purpose, or name a different one.');

    // Cost it, and make anything missing.
    let stock: Record<string, number> = {};
    try {
      const res: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
      for (const d of res?.detail ?? res?.data?.detail ?? []) {
        if (typeof d?.name === 'string') stock[d.name] = (stock[d.name] ?? 0) + (d.count ?? 0);
      }
    } catch { stock = {}; }

    const need = materials(bp);
    const crafted: any[] = [];
    const cannot: string[] = [];
    let lastCraftTask: number | undefined;
    for (const [item, count] of Object.entries(need)) {
      if ((stock[item] ?? 0) >= count) continue;
      const plan = expand(item, count, (i) => stock[i] ?? 0);
      if (plan.missing.length) { cannot.push(`${item} (needs ${plan.missing.join(', ')})`); continue; }
      for (const step of plan.steps) {
        if (step.action !== 'craft') continue;
        const res: any = await bridge.call('TaskMan', 'Add', {
          name: `craft-${step.item.replace('minecraft:', '')}`,
          priority: 2,
          work: { craft: { item: step.item, runs: step.runs, grid: step.grid, inputs: recipeInputs(step.item) } },
        }, { timeoutMs: 8000 });
        if (typeof res !== 'string') { crafted.push({ item: step.item, runs: step.runs, task: res?.id }); lastCraftTask = res?.id; }
      }
    }
    if (cannot.length) throw new ToolError(
      `Cannot build ${bp.name}: ${cannot.join('; ')}.`,
      'Obtain those materials first — order.prospect for ore, order.issue lumber for wood.');

    // The build waits for the last craft step. Without that it would start, find the chest short,
    // and abandon a half-finished structure on a plot now marked active.
    const build: any = await bridge.call('TaskMan', 'Add', {
      name: `build-${bp.name}-${plot.name}`,
      priority: 2,
      dependsOn: lastCraftTask,
      work: { build: { origin, blocks: placementOrder(bp) } },
    }, { timeoutMs: 12000 });
    if (typeof build === 'string') throw new ToolError(`TaskMan refused the build: ${build}`, 'Check fleet.tasks.');

    plot.status = 'clearing';
    plot.owner = `build-${bp.name}`;
    saveCity();
    ctx.log('order.build', { blueprint: bp.name, plot: plot.name });
    return {
      blueprint: bp.name, plot: plot.name, origin, footprint: fp,
      needs: need, crafted, buildTask: build?.id,
      note: crafted.length ? 'build waits for the crafting to finish' : 'materials already in stock',
    };
  },
});

// ── blueprints.list ────────────────────────────────────────────────────────
registry.register({
  name: 'blueprints.list',
  summary: 'What the fleet knows how to build, and what each costs.',
  description: 'Costs are in finished items; order.build expands them through the recipe graph.',
  params: z.object({}).strict(),
  returns: 'Each blueprint with its purpose, size and material cost.',
  danger: 'read',
  handler: async () => ({
    blueprints: BLUEPRINTS.map((b) => ({
      name: b.name, purpose: b.purpose, summary: b.summary,
      size: b.size, blocks: b.blocks.length, materials: materials(b),
    })),
  }),
});


// ── factory.route ──────────────────────────────────────────────────────────
//
// PIPING, WITHOUT PIPES.
//
// A wired modem joins any inventory to the network, and any two things on that network can hand
// items straight to each other. So connecting factories does not need belts, chutes, or a drone
// ferrying crates between buildings -- it needs to know which items should flow where. StorageMan
// then does it on a tick, at server speed, for no fuel.
//
// A drone hauling a stack across the base is minutes of flying and a drone that can do nothing else
// meanwhile. The same move here is one call. Hauling is what you do BEFORE you can afford this.
registry.register({
  name: 'factory.route',
  summary: 'Make items flow between networked inventories automatically, with no drone involved.',
  description:
    'Rules are read as sentences: "everything matching _ore in the mine chest goes to the smelter ' +
    'feed". `item` is a substring, so one rule can carry a whole family. `keep` leaves a working ' +
    'stock behind, which is what stops a route draining the chest a machine is feeding from. Both ' +
    'inventories must be on the wired network -- see storage.stock for their names.',
  params: z.object({
    from: z.string().optional().describe('Source peripheral name.'),
    to: z.string().optional().describe('Destination peripheral name.'),
    item: z.string().optional().describe('Substring match; omit to move everything.'),
    keep: z.number().int().min(0).max(64).optional().describe('Leave this many behind.'),
    clear: z.boolean().optional().describe('Remove all routes instead of adding one.'),
  }).strict(),
  returns: 'The configured routes.',
  danger: 'mutate',
  teach: [{
    situation: 'Ore piling up in the mine chest should feed the smelter without a drone carrying it.',
    args: { from: 'minecraft:chest_2', to: 'minecraft:chest_0', item: '_ore' },
    result: { route: { from: 'minecraft:chest_2', to: 'minecraft:chest_0', item: '_ore' }, count: 1 },
    takeaway: 'The network is the conveyor; this is just the routing policy on top of it.',
  }],
  handler: async (a, ctx) => {
    if (a.clear) {
      const r: any = await bridge.call('StorageMan', 'ClearRoutes', {}, { timeoutMs: 8000 });
      return { cleared: true, result: r ?? null };
    }
    if (!a.from || !a.to) {
      const r: any = await bridge.call('StorageMan', 'GetRoutes', {}, { timeoutMs: 8000 });
      return { routes: r?.routes ?? r?.data?.routes ?? [] };
    }
    const r: any = await bridge.call('StorageMan', 'AddRoute',
      { from: a.from, to: a.to, item: a.item, keep: a.keep }, { timeoutMs: 8000 });
    if (typeof r === 'string') throw new ToolError(r, 'Check storage.stock for valid peripheral names.');
    ctx.log('factory.route', { from: a.from, to: a.to });
    return r;
  },
});


// ── factory.create ─────────────────────────────────────────────────────────
//
// A factory is a plot, a recipe, an input chest and an output chest. The interesting part is what
// happens on creation: the plant REWIRES ITSELF. Links are derived from the recipe graph, so adding
// a computer line to a plant that already smelts stone connects the two without anyone saying so --
// and a human saying so by hand is how a plant ends up subtly mis-wired in a way nothing detects.
registry.register({
  name: 'factory.create',
  summary: 'Add a production line for one item, and auto-connect it to the rest of the plant.',
  description:
    'Allocates a crafting plot, registers the line, and derives its links from the recipes: ' +
    'anything already produced here that this line consumes is routed to it, and anything it ' +
    'produces is routed onward to lines that need it. Physical chests are attached later with ' +
    'factory.attach, at which point the routes become real item movement.',
  params: z.object({
    produces: z.string().describe('Item id this line makes, e.g. "computercraft:computer_normal".'),
    name: z.string().max(40).optional(),
  }).strict(),
  returns: 'The factory, the links it created, and what the plant still cannot supply.',
  danger: 'mutate',
  teach: [{
    situation: 'We can smelt stone and want to start making computers.',
    args: { produces: 'computercraft:computer_normal' },
    result: {
      factory: { name: 'computer_normal-1', produces: 'computercraft:computer_normal', plot: 'crafting-01' },
      links: [{ from: 'stone-1', to: 'computer_normal-1', item: 'minecraft:stone' }],
      unmet: [{ item: 'minecraft:redstone', source: 'gather' }],
    },
    takeaway: 'The stone link was not configured — the recipe already implied it.',
  }],
  handler: async (a, ctx) => {
    const recipe = RECIPES.find((r) => r.output === a.produces);
    if (!recipe) throw new ToolError(
      `Nothing knows how to make ${a.produces}.`,
      'Add a recipe first, or pick an item from plan.make.');

    const short = a.produces.replace(/^.*:/, '');
    const name = a.name ?? `${short}-${factories.filter((f) => f.produces === a.produces).length + 1}`;
    if (factories.some((f) => f.name === name)) throw new ToolError(
      `A factory called ${name} already exists.`, 'Pass a different name.');

    const r = allocate(city, 'crafting');
    if ('error' in r) throw new ToolError(r.error, 'Free ground or widen the operating bounds.');

    const factory: Factory = { name, produces: a.produces, plot: r.name, status: 'planned' };
    factories.push(factory);
    saveCity();

    const links = chain(factories).filter((l) => l.from === name || l.to === name);
    const unmet = unmetInputs(factories).filter((u) => u.factory === name);

    // Make the derived links REAL wherever both ends already have chests. Lines without chests yet
    // keep the link as intent; factory.attach turns it into item movement.
    const wired: any[] = [];
    for (const l of chain(factories)) {
      const from = factories.find((f) => f.name === l.from);
      const to = factories.find((f) => f.name === l.to);
      if (!from?.output || !to?.input) continue;
      try {
        await bridge.call('StorageMan', 'AddRoute',
          { from: from.output, to: to.input, item: l.item }, { timeoutMs: 8000 });
        wired.push(l);
      } catch { /* reported via the links list; the route can be retried */ }
    }

    ctx.log('factory.create', { name, produces: a.produces });
    return { factory, plot: r, links, wired, unmet,
             note: 'attach chests with factory.attach to turn these links into real item movement' };
  },
});

// ── factory.attach ─────────────────────────────────────────────────────────
registry.register({
  name: 'factory.attach',
  summary: 'Give a factory its input and output chests, turning its derived links into real routes.',
  description:
    'Until a line has chests it is intent, not plant. Both must be on the wired network — see ' +
    'storage.stock for names. Attaching immediately creates every route the recipe graph implies ' +
    'between this line and the others.',
  params: z.object({
    name: z.string(),
    input: z.string().optional(),
    output: z.string().optional(),
  }).strict(),
  returns: 'The factory and the routes now carrying material to and from it.',
  danger: 'mutate',
  handler: async (a, ctx) => {
    const f = factories.find((x) => x.name === a.name);
    if (!f) throw new ToolError(`No factory "${a.name}".`, 'See factory.list.');
    if (a.input) f.input = a.input;
    if (a.output) f.output = a.output;
    f.status = f.input && f.output ? 'running' : 'planned';
    saveCity();

    const wired: any[] = [];
    const pending: any[] = [];
    for (const l of chain(factories)) {
      if (l.from !== f.name && l.to !== f.name) continue;
      const from = factories.find((x) => x.name === l.from);
      const to = factories.find((x) => x.name === l.to);
      if (!from?.output || !to?.input) { pending.push({ ...l, why: 'both ends need chests' }); continue; }
      try {
        const res: any = await bridge.call('StorageMan', 'AddRoute',
          { from: from.output, to: to.input, item: l.item }, { timeoutMs: 8000 });
        if (typeof res === 'string') pending.push({ ...l, why: res });
        else wired.push(l);
      } catch (err) {
        pending.push({ ...l, why: (err as Error)?.message ?? String(err) });
      }
    }
    ctx.log('factory.attach', { name: f.name, wired: wired.length });
    return { factory: f, wired, pending };
  },
});

// ── factory.list ───────────────────────────────────────────────────────────
registry.register({
  name: 'factory.list',
  summary: 'The plant: every line, how they are chained, and what the chain cannot supply itself.',
  description:
    'The unmet list is the useful part — it is the plant boundary, the materials that must arrive ' +
    'from mining or smelting rather than from another line. A chain that quietly assumes they ' +
    'appear is a chain that stalls with no explanation.',
  params: z.object({}).strict(),
  returns: 'Factories, derived links, build order, and unmet inputs.',
  danger: 'read',
  handler: async () => {
    const { order, cycles } = buildOrder(factories);
    return {
      count: factories.length,
      factories: factories.map((f) => ({ ...f, consumes: inputsOf(f.produces) })),
      links: chain(factories),
      buildOrder: order,
      cycles,
      unmet: unmetInputs(factories),
    };
  },
});


// ── task.stop ──────────────────────────────────────────────────────────────
//
// Abandoning work is a first-class operation, not an admin escape hatch.
//
// A task that cannot succeed does not politely go away: it holds a drone, gets reclaimed, is
// re-dispatched, fails again, and starves everything behind it. Three legacy dig tasks jammed the
// whole fleet this way -- two miners and a scout were permanently "working" on orders that reported
// "cannot reach site" every time, so the supply loop correctly concluded there was nobody free and
// did nothing at all. From outside that looks like autonomy having stopped.
// ── hive.plan ──────────────────────────────────────────────────────────────
registry.register({
  name: 'hive.plan',
  summary: 'The work queue as a dependency TREE, with the reason each task is blocked.',
  description:
    'fleet.tasks is a flat list, which cannot answer the question that actually matters: WHY is ' +
    'nothing happening. The queue is a tree -- order.build queues the crafts it needs and waits ' +
    'on them, and those crafts wait on their materials -- so a blocked build looks exactly like ' +
    'an idle fleet unless you can see the chain. This renders that chain and names the blocker.',
  params: z.object({}).strict(),
  returns: 'Roots with nested children, each carrying state and a blockedBy reason.',
  danger: 'read',
  bounds: 'Read-only view of TaskMan and DroneMan.',
  teach: [{
    situation: 'The crafter is idle and nothing is being built. Why?',
    args: {},
    result: {
      tree: [{
        id: 1845, name: 'build-claim-post-docks-01', state: 'blocked',
        blockedBy: 'waiting on craft-oak_planks (#1844)',
        children: [{ id: 1844, name: 'craft-oak_planks', state: 'failing',
                     blockedBy: 'storage has none of the ingredients: minecraft:oak_log' }],
      }],
    },
    takeaway: 'The build is not stuck -- it is waiting on planks, which are waiting on wood nobody has.',
  }],
  handler: async () => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const t: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 10000 });
    const tasks = (luaList<any>(t?.tasks ?? t?.data?.tasks) ?? []).filter(Boolean);
    const drones = luaList<any>(
      (await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 8000 }) as any)?.drones,
    ) ?? [];

    const byId = new Map<string, any>(tasks.map((x: any) => [String(x.id), x]));
    const done = (x: any) => (x?.progress ?? 0) >= 100;

    // Which roles could actually take work right now. "No drone free" is a different problem from
    // "waiting on a dependency", and conflating them is why the queue looked broken when it was
    // merely busy.
    const freeRoles = new Set(
      drones.filter((d: any) => d.status === 'idle' && !d.offline).map((d: any) => d.role ?? 'miner'),
    );
    const roles = new Set(drones.map((d: any) => d.role ?? 'miner'));

    const describe = (x: any): { state: string; blockedBy: string | null } => {
      if (done(x)) return { state: 'done', blockedBy: null };
      if (x.paused) return { state: 'paused', blockedBy: 'paused' };
      if (x.enabled === false) return { state: 'disabled', blockedBy: 'disabled' };
      if (x.assigned) return { state: 'running', blockedBy: null };

      const dep = x.dependsOn != null ? byId.get(String(x.dependsOn)) : null;
      if (dep && !done(dep)) {
        return { state: 'blocked', blockedBy: `waiting on ${dep.name} (#${dep.id})` };
      }
      // A task that keeps failing is not merely queued, and its reason is the whole story.
      if (x.failure) {
        return {
          state: (x.attempts ?? 0) > 0 ? 'failing' : 'queued',
          blockedBy: `${x.failure}${x.attempts ? ` (attempt ${x.attempts})` : ''}`,
        };
      }
      const role = x.role ?? 'miner';
      if (!roles.has(role)) return { state: 'blocked', blockedBy: `no ${role} in the fleet` };
      if (!freeRoles.has(role)) return { state: 'queued', blockedBy: `no ${role} free` };
      return { state: 'queued', blockedBy: null };
    };

    const node = (x: any): any => ({
      id: x.id, name: x.name, verb: x.role, progress: x.progress ?? 0,
      assigned: x.assigned ?? null,
      ...describe(x),
      children: tasks
        .filter((c: any) => c.dependsOn != null && String(c.dependsOn) === String(x.id))
        .map(node),
    });

    const roots = tasks.filter(
      (x: any) => x.dependsOn == null || !byId.has(String(x.dependsOn)),
    );
    const tree = roots.map(node);
    const live = tasks.filter((x: any) => !done(x));
    return {
      tree,
      counts: {
        live: live.length,
        running: live.filter((x: any) => x.assigned).length,
        blocked: live.filter((x: any) => describe(x).state === 'blocked').length,
        failing: live.filter((x: any) => describe(x).state === 'failing').length,
      },
    };
  },
});

// ── world.prune ────────────────────────────────────────────────────────────
registry.register({
  name: 'world.prune',
  summary: 'Drop map cells outside the operating region.',
  description:
    'The map is persistent and append-only in practice, so it accumulates terrain the fleet can ' +
    'never reach -- ground around the ORIGINAL settlement 400 blocks away, and the corners of the ' +
    'old square region. That is not inert: MapServer is a single thread serving five drones\' ' +
    'uploads plus every path request, and it carries the dead weight through every occupancy walk, ' +
    'name-index pass and persist. At 207k cells drones began reporting "MapServer did not take 10 ' +
    'observations, keeping them" -- the map failing to learn what was being mined, which is exactly ' +
    'what leaves phantom ore in the index for gather tasks to chase for ever.',
  params: z.object({
    margin: z.number().int().min(0).max(256).default(32)
      .describe('Blocks of slack outside the region to keep.'),
    aboveY: z.number().int().min(-64).max(320).optional()
      .describe('Also drop every cell above this altitude. Use to clear phantom terrain: a drone ' +
                'with an unverified position files observations INSIDE the region at coordinates ' +
                'it only believes, so the junk is out of reach of a footprint prune and gives ' +
                'itself away by height instead.'),
  }).strict(),
  returns: 'How many cells were dropped and how many kept.',
  danger: 'destructive',
  bounds: 'Map records only, and only outside the operating region. Nothing in the world changes.',
  teach: [{
    situation: 'Drones report "MapServer did not take N observations" and path requests are slow.',
    args: { margin: 32 },
    result: { dropped: 141_000, kept: 66_000 },
    takeaway: 'Most of the map was ground the fleet is not allowed to enter.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const r: any = await bridge.call('MapServer', 'prune',
      { margin: a.margin, aboveY: a.aboveY }, { timeoutMs: 60000 });
    if (typeof r === 'string') throw new ToolError(`MapServer refused: ${r}`, 'Does it have bounds yet?');
    ctx.log('world.prune', { margin: a.margin, aboveY: a.aboveY, dropped: r?.dropped, kept: r?.kept });
    return r;
  },
});

// ── fleet.probe ────────────────────────────────────────────────────────────
registry.register({
  name: 'fleet.probe',
  summary: 'Evaluate a Lua expression on a real drone and return the answer.',
  description:
    'For settling a question about what the game actually does, instead of inferring it and ' +
    'finding out in production. Every semantic bug in the drone code -- items dropped on the ' +
    'floor, an upgrade silently not applied, three wrong implementations of chest withdrawal -- ' +
    'was answerable by asking the world once. The only thing making those expensive was having ' +
    'no way to ask except edit, sync, reboot, wait. This is that way. Read-only by convention; ' +
    'the drone pcalls it, so a bad probe cannot take it down.',
  params: z.object({
    id: z.number().int().describe('Computer id of the drone, from fleet.status.'),
    code: z.string().min(1).max(500).describe('Lua expression, e.g. `peripheral.wrap("bottom") ~= nil`.'),
  }).strict(),
  returns: 'The value, serialised, plus its type — or the error it raised.',
  danger: 'read',
  bounds: 'Runs on one drone. Keep probes read-only: nothing stops a probe that moves or digs.',
  teach: [{
    situation: 'Can a turtle read the chest beneath it, or must it suck items out to find out what is there?',
    args: { id: 47, code: 'peripheral.wrap("bottom").list()' },
    result: { ok: true, type: 'table', value: '{ [1] = { count = 43, name = "minecraft:cobblestone" } }' },
    takeaway: 'It can. Answered in seconds; the alternative cost three wrong implementations.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const r: any = await bridge.call('DroneMan', 'GoTo',
      { id: a.id, verb: 'Probe', pos: { x: 0, y: 0, z: 0 }, code: a.code }, { timeoutMs: 15000 });
    if (typeof r === 'string') throw new ToolError(`DroneMan refused: ${r}`, 'Check the drone id.');
    ctx.log('fleet.probe', { id: a.id, code: a.code.slice(0, 60) });
    return { sent: r, note: 'the answer is written to the drone log; see its trace' };
  },
});

// ── world.forget ───────────────────────────────────────────────────────────
registry.register({
  name: 'world.forget',
  summary: 'Remove blocks matching a name from the world map, index and occupancy grid.',
  description:
    'For records that should never have existed. The scanner returns every non-air block, so ' +
    'drones recorded EACH OTHER as permanent terrain -- 190 turtle blocks for a fleet of five, ' +
    'drawn as white cubes floating wherever a drone once stood, and routed around by the ' +
    'pathfinder as though they were walls. The scan side no longer records them, but the map is ' +
    'persistent: what is written stays written until something removes it.',
  params: z.object({
    match: z.string().min(3).describe('Name substring, e.g. "turtle".'),
  }).strict(),
  returns: 'How many records were forgotten.',
  danger: 'destructive',
  bounds: 'Map records only. Nothing in the world is changed.',
  teach: [{
    situation: 'The map shows white blocks floating in mid-air where drones used to be.',
    args: { match: 'turtle' },
    result: { forgot: 190, match: 'turtle' },
    takeaway: 'Those were drones recorded as terrain, not real blocks.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const r: any = await bridge.call('MapServer', 'forget', { match: a.match }, { timeoutMs: 20000 });
    if (typeof r === 'string') throw new ToolError(`MapServer refused: ${r}`, 'Check the match string.');
    ctx.log('world.forget', { match: a.match, forgot: r?.forgot });
    return r;
  },
});

// ── fleet.handover ─────────────────────────────────────────────────────────
registry.register({
  name: 'fleet.handover',
  summary: 'Have a drone carrying an item fly it directly to a drone that is blocked without it.',
  description:
    'Everything the fleet owns normally has to pass through a chest, which makes the chest a ' +
    'bottleneck and a single point of failure -- and early on there may not be one. A crafter ' +
    'blocked for want of wood cannot be helped by the miner beside it holding sixteen logs. This ' +
    'is the fuel-relief manoeuvre generalised: the holder flies above the recipient and hands the ' +
    'items down. Picks the holder automatically unless you name one.',
  params: z.object({
    to: z.number().int().describe('Computer id of the drone that needs the item.'),
    match: z.string().min(2).describe('Item name substring, e.g. "_log".'),
    from: z.number().int().optional().describe('Specific holder; otherwise the nearest one carrying it.'),
  }).strict(),
  returns: 'The chosen holder, the recipient, and how much it is carrying.',
  danger: 'destructive',
  bounds: 'Interrupts the holder\'s current job. Refuses if nobody is carrying a match.',
  teach: [{
    situation: 'The crafter is blocked on oak_log and a miner is holding sixteen of them.',
    args: { to: 47, match: '_log' },
    result: { from: 'D3', to: 'D4', held: 16 },
    takeaway: 'No chest involved -- the wood goes straight from the drone that has it to the one that needs it.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const drones = state.listDrones();
    const recipient = drones.find((d) => d.id === a.to);
    if (!recipient) throw new ToolError(`No drone ${a.to}.`, 'Check fleet.status.');
    if (!recipient.pos) {
      throw new ToolError(`${recipient.name} has no known position.`,
        'It cannot be delivered to until it reports one.');
    }

    const held = (d: typeof drones[number]) => {
      let n = 0;
      for (const [name, c] of Object.entries(d.carrying ?? {})) {
        if (name.includes(a.match)) n += Number(c) || 0;
      }
      return n;
    };
    const dist = (d: typeof drones[number]) =>
      d.pos ? Math.abs(d.pos.x - recipient.pos!.x) + Math.abs(d.pos.y - recipient.pos!.y)
            + Math.abs(d.pos.z - recipient.pos!.z) : Infinity;

    const holders = drones
      .filter((d) => d.id !== a.to && held(d) > 0 && (a.from == null || d.id === a.from))
      .sort((x, y) => dist(x) - dist(y));

    if (!holders.length) {
      throw new ToolError(
        `No drone is carrying anything matching "${a.match}".`,
        'Check fleet.status carrying, or gather some first.');
    }

    const from = holders[0];
    await bridge.call('DroneMan', 'GoTo', {
      id: from.id, verb: 'Handover',
      pos: recipient.pos, drone: recipient.name, match: a.match,
    }, { timeoutMs: 8000 });
    ctx.log('fleet.handover', { from: from.name, to: recipient.name, match: a.match });
    return { from: from.name, to: recipient.name, held: held(from), match: a.match };
  },
});

// ── storage.recall ─────────────────────────────────────────────────────────
registry.register({
  name: 'storage.recall',
  summary: 'Send drones carrying a material back to storage to deposit it.',
  description:
    'The fleet\'s own inventory is not usable by the fleet: a drone holding sixteen logs is, to ' +
    'every planner, holding nothing. So a craft fails for want of wood that exists, two blocks ' +
    'away, inside a miner. This finds who is carrying what you need and tells them to unload.',
  params: z.object({
    match: z.string().min(2).describe('Item name substring, e.g. "_log" or "coal".'),
  }).strict(),
  returns: 'Which drones were carrying it and were asked to deposit.',
  danger: 'destructive',
  bounds: 'Only interrupts drones that actually hold a match; others are left alone.',
  teach: [{
    situation: 'craft-oak_planks keeps failing on "storage has none of the ingredients", but a miner cut logs earlier.',
    args: { match: '_log' },
    result: { recalled: [{ drone: 'D3', held: 16 }] },
    takeaway: 'The wood existed all along; it was just inside a drone where nothing could see it.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const drones = state.listDrones();
    const holders = drones
      .map((d) => {
        const inv = d.carrying ?? {};
        let held = 0;
        for (const [name, n] of Object.entries(inv)) {
          if (name.includes(a.match)) held += Number(n) || 0;
        }
        return { d, held };
      })
      .filter((x) => x.held > 0);

    if (!holders.length) {
      return { recalled: [], note: `no drone is carrying anything matching "${a.match}"` };
    }

    const out: any[] = [];
    for (const { d, held } of holders) {
      try {
        // Deposit is the drone's own well-trodden path to the chest -- no new protocol, and it
        // already knows how to get there from underground.
        // A verb, not a flag: OnGoTo never read `deposit`, so the previous version of this
        // reported success while the drone carried on mining with a full hold.
        await bridge.call('DroneMan', 'GoTo',
          { id: d.id, verb: 'Unload', pos: d.pos }, { timeoutMs: 8000 });
        out.push({ drone: d.name, held, asked: true });
      } catch (err) {
        out.push({ drone: d.name, held, asked: false, error: String(err).slice(0, 120) });
      }
    }
    ctx.log('storage.recall', { match: a.match, holders: out.length });
    return { recalled: out };
  },
});

// ── fleet.retire ───────────────────────────────────────────────────────────
registry.register({
  name: 'fleet.retire',
  summary: 'Write off a drone that cannot be recovered, so the fleet stops planning around it.',
  description:
    'Removes a drone from the registry. Use ONLY when a drone is genuinely unreachable -- outside ' +
    'the operating region, or silent with a position known to be wrong. A lost drone that stays ' +
    'registered keeps generating rescues aimed at its last reported position, and those rescues ' +
    'consume the drones that still work: one casualty can occupy the whole fleet indefinitely. ' +
    'The turtle is not destroyed; if it ever heartbeats again it re-registers from scratch.',
  params: z.object({
    id: z.number().int().describe('Computer id of the drone, from fleet.status.'),
    reason: z.string().max(200).default('unrecoverable'),
  }).strict(),
  returns: 'The retired drone name and id.',
  danger: 'destructive',
  bounds: 'Registry only. Does not break, move or shut down the turtle.',
  teach: [{
    situation: 'D1 drifted outside the region, stopped ticking, and its record still shows a position inside it.',
    args: { id: 20, reason: 'outside the operating region; reported position is stale' },
    result: { retired: 'D1', id: '20' },
    takeaway: 'Rescues for D1 stop being generated, and the drones that still work go back to real jobs.',
  }],
  handler: async (a, ctx) => {
    if (!bridge.connected) throw new ToolError('Bridge offline.', 'Check hive.pow/health.');
    const r: any = await bridge.call('DroneMan', 'RetireDrone', { id: a.id }, { timeoutMs: 8000 });
    // CLEAR HQ'S OWN ROSTER FIRST, AND REGARDLESS OF WHAT DRONEMAN SAYS.
    //
    // DroneMan's registry is not the list fleet.status reads -- HQ keeps its own Map, and that is
    // the one everything downstream plans against.
    //
    // Two bugs met here. Originally this stopped at the DroneMan call, so the in-world registry
    // forgot the drone and HQ did not: ok:true, and the drone still present in every subsequent
    // fleet.status. Retiring five destroyed drones reported five successes and removed none.
    //
    // The first fix then sat AFTER the throw, which reopened the same hole from the other side:
    // once DroneMan has already forgotten a drone it answers "no such drone", the tool throws, and
    // HQ's copy is never cleared -- so a retry could not clean up after a partial failure. That is
    // exactly the state five destroyed drones were left in. DroneMan not knowing the drone is not
    // a reason to keep it on the roster; it is the strongest reason to drop it.
    const forgotten = state.retireDrone(a.id);
    if (typeof r === 'string' && !forgotten) {
      throw new ToolError(`DroneMan refused: ${r}`, 'Check fleet.status for the id.');
    }
    ctx.log('fleet.retire', { id: a.id, reason: a.reason, forgottenByHQ: forgotten });
    return { ...r, reason: a.reason, forgottenByHQ: forgotten };
  },
});

registry.register({
  name: 'task.stop',
  summary: 'Abandon a queued or stuck task so its drone is released.',
  description:
    'Use when a task keeps failing or predates a change and can never complete. Marks it finished ' +
    'with a reason rather than deleting it, so the record of what happened survives. Check ' +
    'fleet.tasks for ids and their failure text first.',
  params: z.object({
    id: z.union([z.number().int(), z.array(z.number().int()).max(32)]),
    reason: z.string().max(200).default('abandoned by operator'),
  }).strict(),
  returns: 'Which tasks were stopped.',
  danger: 'mutate',
  handler: async (a, ctx) => {
    const ids = Array.isArray(a.id) ? a.id : [a.id];
    const out: any[] = [];
    for (const id of ids) {
      try {
        // TaskDone rather than a delete: the queue should remember that this was given up on and
        // why, because "it vanished" is indistinguishable from "it silently succeeded".
        // Find who is holding it BEFORE marking it done -- TaskDone clears the assignment, and
        // the drone still needs telling.
        let holder: number | undefined;
        try {
          const tasks: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 8000 });
          const list = tasks?.tasks ?? tasks?.data?.tasks ?? [];
          holder = list.find((t: any) => String(t.id) === String(id))?.assignedTo;
        } catch { /* best effort; stopping the task still matters */ }

        // abandon:true, not just ok:false. A plain failure goes through TaskMan's retry path --
        // it spends one of three attempts and requeues -- so "stopped" tasks kept being dispatched
        // and the queue could not be cleared at all.
        const res: any = await bridge.call('TaskMan', 'TaskDone',
          { id, ok: false, abandon: true, reason: a.reason }, { timeoutMs: 8000 });

        // STOP THE DRONE TOO. Cancelling the task in the queue does not reach the machine: it
        // keeps executing, never goes idle, and can never be given anything again -- which looks
        // from outside exactly like the fleet having stopped working.
        let released: any = null;
        if (typeof holder === 'number') {
          try {
            released = await bridge.call('DroneMan', 'Stop', { id: holder }, { timeoutMs: 12000 });
          } catch (err) { released = (err as Error)?.message ?? String(err); }
        }
        out.push({ id, stopped: typeof res !== 'string', drone: holder ?? null, released });
      } catch (err) {
        out.push({ id, stopped: false, error: (err as Error)?.message ?? String(err) });
      }
    }
    ctx.log('task.stop', { count: out.length });
    return { stopped: out };
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
