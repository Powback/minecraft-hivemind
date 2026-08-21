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
import { state, STALE_MS, type Vec3 } from '../world/state.js';
import { bridge } from '../bridge/ws.js';

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
async function refreshFleet(): Promise<void> {
  if (!bridge.connected) return;        // offline: serve last-known state rather than erroring
  try {
    const res: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 5000 });
    const list = res?.drones ?? res?.data?.drones;
    if (!Array.isArray(list)) return;
    const now = Date.now();
    for (const d of list) {
      const id = typeof d?.droneID === 'number' ? d.droneID : d?.id;
      if (typeof id !== 'number') continue;
      state.upsertDrone({
        id,
        name: d.name ?? `drone-${id}`,
        role: d.role ?? 'miner',
        status: d.status ?? 'idle',
        fuel: typeof d.fuel === 'number' ? d.fuel : 0,
        pos: d.pos && typeof d.pos.x === 'number' ? d.pos : undefined,
        lastSeen: now,
      });
    }
  } catch (err) {
    // A refresh failure must not take down a read tool; stale data beats no answer. But it must
    // not be silent either -- a swallowed error here reads as "the fleet is empty", which is the
    // most misleading possible answer.
    console.log(`[fleet] refresh failed: ${(err as Error)?.message ?? err}`);
  }
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
    if (d.status === 'lost') problems.push(`${d.name} (#${d.id}) is LOST — silent ${Math.round(d.silentMs / 1000)}s.`);
    else if (d.status === 'stranded') problems.push(`${d.name} (#${d.id}) has gone quiet (${Math.round(d.silentMs / 1000)}s).`);
    else if (d.fuel < 200) problems.push(`${d.name} (#${d.id}) is low on fuel (${d.fuel}).`);
  }
  for (const o of orders) if (o.failure) problems.push(`Order ${o.id} (${o.kind}) failed: ${o.failure}`);

  return {
    fleet: {
      total: drones.length,
      byStatus: tally(drones.map((d) => d.status)),
      drones: drones.map((d) => ({
        id: d.id, name: d.name, status: d.status, fuel: d.fuel,
        pos: d.pos ?? null, order: d.order ?? null,
        silentSec: Math.round(d.silentMs / 1000),
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

// ── fleet.status ───────────────────────────────────────────────────────────
registry.register({
  name: 'fleet.status',
  summary: 'Detail on one drone, or drones filtered by status/role.',
  description: 'Use when the brief is not specific enough — e.g. to check one drone before assigning it work.',
  params: z.object({
    id: z.number().int().optional().describe('A specific drone id.'),
    status: z.enum(['idle', 'working', 'docking', 'stranded', 'lost']).optional(),
    role: z.string().optional(),
  }).strict(),
  returns: 'Matching drones with position, fuel, status, current order and silence duration.',
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
    const drones = state.listDrones().filter(
      (d) => (a.id === undefined || d.id === a.id) &&
             (!a.status || d.status === a.status) &&
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
      lastSeenSecAgo: Math.round(target.silentMs / 1000),
    };
  },
});
