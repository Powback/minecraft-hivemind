/**
 * THE SYSTEM LIES ABOUT ITSELF. THIS IS THE PART THAT NOTICES.
 *
 * Every outage in this project so far has been survivable by a person reading a log and spotting a
 * contradiction. Nothing in the system reads its own output: there are logs, faults, exit reasons and
 * crash records, all written for a human, and consumed by nobody. So the fleet could run for twelve
 * hours doing nothing at all and the only thing that noticed was me.
 *
 * The important observation is that the fleet's problem was never capability. The drones could dig,
 * path, scan and haul. What the system could not do was tell true from false about ITSELF:
 *
 *   - hive.nodes reported "0 of 7 up" while tasks, fleet and storage queries were all succeeding
 *     through those same modules.
 *   - Drones reported "idle" while holding unfinished assignments. Six of them at once.
 *   - A rescue task sat at 0% while the miner that owned it stood on the exact target block, job
 *     done, waiting for nothing.
 *   - A paged read returned 16,000 blocks of a 120,000-block index and was cached as the whole map.
 *   - MapServer resolved in rednet for every caller, for hours, while answering none of them.
 *
 * None of those is a component failing. Each is the system's self-model disagreeing with itself, and
 * that is what this looks for. A detector here does not ask "is X up" -- that question is exactly the
 * one that returned the wrong answer all day. It asks "do two things the system believes contradict
 * each other", which is much harder to fake, because it takes two independent lies to hide.
 *
 * WHAT IT IS ACTUALLY MEASURING.
 *
 * Two numbers nobody has ever had for this system:
 *
 *   mtbiMs            mean time between incidents opening -- how long it runs before it breaks
 *   selfResolvedPct   share of incidents that closed with no out-of-band intervention
 *
 * The second is the real score. An incident that closes because TaskMan reclaimed a task, or because
 * a drone recovered, cost nothing. An incident that closes because somebody power-cycled a computer
 * over rcon is the system failing to be autonomous, and it is recorded as such deliberately: the goal
 * is to drive outOfBand to zero, and a metric that quietly forgives manual rescues cannot show that.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';

export type Severity = 'wedge' | 'stall' | 'lie';

export interface Incident {
  /** Stable across ticks, so the same fault opens once and closes once. */
  key: string;
  kind: string;
  severity: Severity;
  detail: string;
  openedAt: number;
  closedAt?: number;
  /** Set when something outside the system had to intervene. The number to drive to zero. */
  outOfBand?: string;
}

/** What a detector is handed. Deliberately plain data, so detectors are testable without a world. */
export interface Observation {
  at: number;
  /** Per-module: did a direct functional call succeed, and did the status probe say it was up? */
  modules: Array<{ name: string; probeSaysUp: boolean | null; directCallWorked: boolean | null }>;
  drones: Array<{ name: string; role?: string; status?: string; pos?: { x: number; y: number; z: number } }>;
  tasks: Array<{
    id: number | string; assigned?: string | null; progress?: number; role?: string;
    pos?: { x: number; y: number; z: number } | null;
  }>;
  /** Paged reads, so a shrinking one can be caught. */
  reads: Array<{ name: string; count: number }>;
  liveTasks?: number;
  assignedTasks?: number;
}

export interface Detection {
  key: string;
  kind: string;
  severity: Severity;
  detail: string;
}

const near = (
  a?: { x: number; y: number; z: number } | null,
  b?: { x: number; y: number; z: number } | null,
  r = 3,
) => {
  if (!a || !b) return false;
  return Math.abs(a.x - b.x) <= r && Math.abs(a.y - b.y) <= r && Math.abs(a.z - b.z) <= r;
};

/**
 * The detectors. Each one is a contradiction that actually happened, written down so it cannot
 * happen unnoticed again.
 *
 * `best` carries the largest count ever seen for each paged read, because "smaller than last time"
 * is the only way to catch a truncated read from outside -- the read itself reports success either
 * way, which is precisely what made it dangerous.
 */
export function detect(o: Observation, best: Map<string, number>): Detection[] {
  const out: Detection[] = [];

  for (const m of o.modules) {
    // MapServer, for hours: resolvable, addressable, and answering nothing. The probe and the work
    // disagree, and the work is the one that matters.
    if (m.probeSaysUp === true && m.directCallWorked === false) {
      out.push({
        key: `silent:${m.name}`, kind: 'resolves-but-silent', severity: 'wedge',
        detail: `${m.name} probes healthy but a real call to it fails -- found and then silent`,
      });
    }
    // The same disagreement the other way round is not a fault in the module, it is a fault in the
    // monitoring, and it is worth just as much: it is what made "0 of 7 up" believable.
    if (m.probeSaysUp === false && m.directCallWorked === true) {
      out.push({
        key: `misreport:${m.name}`, kind: 'probe-lies', severity: 'lie',
        detail: `${m.name} is doing real work while the status probe reports it down`,
      });
    }
  }

  const held = new Map<string, Array<Observation['tasks'][number]>>();
  for (const t of o.tasks) {
    if (t.assigned && (t.progress ?? 0) < 100) {
      if (!held.has(t.assigned)) held.set(t.assigned, []);
      held.get(t.assigned)!.push(t);
    }
  }

  for (const d of o.drones) {
    const mine = held.get(d.name) ?? [];
    if (mine.length === 0) continue;

    if (d.status === 'idle') {
      // Six drones were in exactly this state while 58 tasks sat unassigned and ten drones had
      // nothing to do. The log said "reclaim? task N held by X: idle" 61 times and never once said
      // what it did about it.
      out.push({
        key: `idleheld:${d.name}`, kind: 'idle-but-committed', severity: 'stall',
        detail: `${d.name} reports idle while holding ${mine.length} unfinished task(s): ${mine.map((t) => t.id).join(', ')}`,
      });
    }

    // A miner dug through rock to a trapped scout's exact position, arrived, went idle -- and the
    // task stayed at 0% and assigned, holding a rescue slot against every other trapped drone. The
    // work was done and nothing knew it.
    for (const t of mine) {
      if ((t.progress ?? 0) === 0 && t.pos && near(d.pos, t.pos)) {
        out.push({
          key: `unreported:${t.id}`, kind: 'work-done-not-reported', severity: 'stall',
          detail: `task ${t.id} is at 0% but ${d.name} is standing on its target -- the report never arrived`,
        });
      }
    }
  }

  for (const r of o.reads) {
    const high = best.get(r.name) ?? 0;
    if (r.count > high) best.set(r.name, r.count);
    // 16,000 blocks of a 120,000-block index, cached as the whole map, reported as success. Partial
    // data presented as complete is worse than an error, because everything downstream trusts it.
    else if (high > 0 && r.count < high * 0.5) {
      out.push({
        key: `shrank:${r.name}`, kind: 'partial-read-as-complete', severity: 'lie',
        detail: `${r.name} returned ${r.count} having previously returned ${high} -- a truncated read reporting success`,
      });
    }
  }

  // 114 live tasks, 10 assigned, 11 drones idle. Nothing was broken; the work simply was not moving,
  // and no single component was in a position to notice.
  const idleCount = o.drones.filter((d) => d.status === 'idle').length;
  if ((o.liveTasks ?? 0) > 20 && (o.assignedTasks ?? 0) < 5 && idleCount >= 3) {
    out.push({
      key: 'starved', kind: 'queue-starvation', severity: 'stall',
      detail: `${o.liveTasks} live tasks, only ${o.assignedTasks} assigned, ${idleCount} drones idle`,
    });
  }

  return out;
}

/**
 * The ledger. Incidents open once, close once, and are written down either way.
 *
 * Persisted rather than held in memory, because the question worth answering -- "is it getting
 * better?" -- spans restarts of this process, and an uptime counter that resets whenever the
 * observer restarts measures the observer.
 */
export class Ledger {
  private open = new Map<string, Incident>();
  private closed: Incident[] = [];
  private best = new Map<string, number>();
  private file: string;

  constructor(stateDir = process.env.HIVE_STATE ?? '/state') {
    this.file = path.join(stateDir, 'incidents.jsonl');
  }

  async load(): Promise<void> {
    try {
      const text = await fs.readFile(this.file, 'utf8');
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        const inc = JSON.parse(line) as Incident;
        if (inc.closedAt) this.closed.push(inc);
        else this.open.set(inc.key, inc);
      }
    } catch {
      // No ledger yet is the normal first run, not an error.
    }
  }

  private async append(inc: Incident): Promise<void> {
    try {
      await fs.mkdir(path.dirname(this.file), { recursive: true });
      await fs.appendFile(this.file, JSON.stringify(inc) + '\n');
    } catch {
      // A ledger that cannot be written must not take down the loop that writes it.
    }
  }

  /** Reconcile what is currently true against what was already open. Returns newly-opened. */
  async reconcile(found: Detection[], at: number): Promise<Incident[]> {
    const seen = new Set(found.map((f) => f.key));
    const opened: Incident[] = [];

    for (const f of found) {
      if (this.open.has(f.key)) continue;
      const inc: Incident = { ...f, openedAt: at };
      this.open.set(f.key, inc);
      opened.push(inc);
      await this.append(inc);
    }

    for (const [key, inc] of [...this.open]) {
      if (seen.has(key)) continue;
      inc.closedAt = at;
      this.open.delete(key);
      this.closed.push(inc);
      await this.append(inc);
    }
    return opened;
  }

  /** Record that something outside the system had to fix this. The number to drive to zero. */
  async markOutOfBand(key: string, what: string): Promise<void> {
    const inc = this.open.get(key);
    if (!inc) return;
    inc.outOfBand = what;
    await this.append(inc);
  }

  counts() { return { open: this.open.size, closed: this.closed.length }; }
  openIncidents() { return [...this.open.values()]; }
  reads() { return this.best; }

  /**
   * MTBI and the self-resolution rate.
   *
   * Mean time between incidents OPENING, not between failures resolving: the interval that matters
   * is how long it runs before something goes wrong, and a fault that takes a long time to fix
   * should not flatter that number by stretching the gap to the next one.
   */
  metrics(now = Date.now()) {
    const all = [...this.closed, ...this.open.values()].sort((a, b) => a.openedAt - b.openedAt);
    let mtbiMs: number | null = null;
    if (all.length >= 2) {
      let sum = 0;
      for (let i = 1; i < all.length; i++) sum += all[i]!.openedAt - all[i - 1]!.openedAt;
      mtbiMs = Math.round(sum / (all.length - 1));
    }
    const resolved = this.closed.length;
    const manual = this.closed.filter((c) => c.outOfBand).length;
    return {
      incidents: all.length,
      open: this.open.size,
      resolved,
      outOfBand: manual,
      selfResolvedPct: resolved > 0 ? Math.round(((resolved - manual) / resolved) * 100) : null,
      mtbiMs,
      mtbiHuman: mtbiMs == null ? null : humanise(mtbiMs),
      longestOpenMs: this.open.size
        ? Math.max(...[...this.open.values()].map((i) => now - i.openedAt))
        : 0,
    };
  }
}

function humanise(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 120) return `${s}s`;
  const m = Math.round(s / 60);
  if (m < 120) return `${m}m`;
  return `${(m / 60).toFixed(1)}h`;
}

/* ------------------------------------------------------------------------- *
 * Runtime: gathering the observation, and the loop.
 * ------------------------------------------------------------------------- */

import { bridge } from '../bridge/ws.js';
import { luaList } from '../lua-table.js';

/**
 * Probe every module TWICE, in two different ways, and keep both answers.
 *
 * A single probe is exactly what failed: Status answered for modules that were doing no work, and
 * failed for modules that were working fine. So each module gets its status probe AND a call to
 * something it actually does, and the detectors compare them. One probe cannot catch a liar; two
 * disagreeing probes catch it without either of them needing to be trustworthy.
 */
const PROBES: Array<{ name: string; work: () => Promise<unknown> }> = [
  { name: 'DroneMan',   work: () => bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 6000 }) },
  { name: 'TaskMan',    work: () => bridge.call('TaskMan', 'GetTasks', { limit: 1 }, { timeoutMs: 6000 }) },
  { name: 'MapServer',  work: () => bridge.call('MapServer', 'BlockAt', { offset: 0, limit: 1 }, { timeoutMs: 8000 }) },
  // GetStock, not Stock; GetDroneInfo, not ListDockingTowers. Both were wrong, and both produced a
  // confident WEDGE against a perfectly healthy module -- because an unknown endpoint used to draw
  // no reply at all, which looks exactly like a wedge. PowNet answers "no such endpoint" now, but
  // the probe should still ask for something real: a monitor that has to be right about method names
  // to avoid crying wolf is a monitor that will cry wolf.
  { name: 'StorageMan', work: () => bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 }) },
  { name: 'DockingMan', work: () => bridge.call('DockingMan', 'GetDroneInfo', { id: '1' }, { timeoutMs: 6000 }) },
];

const ok = async (p: Promise<unknown>): Promise<boolean> => {
  try { await p; return true; } catch { return false; }
};

/**
 * Lua tables arrive as arrays OR as objects, and which one you get depends on the data.
 *
 * A Lua table with holes, or with non-sequential keys, serialises to a JSON object -- so DroneMan's
 * drone list is an array when the ids happen to be 1..n and a dict the moment they are not. Calling
 * .map on the result threw, observe() bailed, and the tick returned early WITHOUT reconciling the
 * ledger. The sentinel then went on serving a stale incident with complete confidence while being
 * broken itself, which is precisely the failure it exists to catch. It could not see, and it said
 * nothing about not being able to see.
 */
const toArray = <T,>(v: unknown): T[] => luaList<T>(v) ?? [];

export async function observe(): Promise<Observation | null> {
  if (!bridge.connected) return null;

  const modules = await Promise.all(PROBES.map(async (p) => ({
    name: p.name,
    probeSaysUp: await ok(bridge.call(p.name, 'Status', {}, { timeoutMs: 5000 })),
    directCallWorked: await ok(p.work()),
  })));

  const fleet: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 6000 }).catch(() => null);
  const drones = toArray<any>(fleet?.drones ?? fleet?.data?.drones).map((d: any) => ({
    name: String(d.name ?? d.droneID ?? d.id),
    role: d.role, status: d.status, pos: d.pos,
  }));

  const tk: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 8000 }).catch(() => null);
  const rawTasks = toArray<any>(tk?.tasks ?? tk?.data?.tasks);
  const tasks = rawTasks.map((t: any) => ({
    id: t.id,
    assigned: t.assigned ?? null,
    progress: t.progress ?? 0,
    role: t.role,
    // Rescues are the case where "the drone is standing on the target" is meaningful, and they are
    // the ones that silently held a slot after the work was finished.
    pos: t.work?.rescue?.pos ?? t.work?.mine?.pos ?? t.work?.gather?.pos ?? null,
  }));

  // Only counts. The point is whether a paged read SHRANK, and pulling the whole map every minute to
  // find that out would itself be the load that wedges MapServer.
  const reads: Array<{ name: string; count: number }> = [];
  const blocks: any = await bridge.call('MapServer', 'BlockAt', { offset: 0, limit: 1 }, { timeoutMs: 8000 }).catch(() => null);
  const blockCount = blocks?.count ?? blocks?.data?.count;
  if (typeof blockCount === 'number') reads.push({ name: 'blocks', count: blockCount });
  const world: any = await bridge.call('MapServer', 'LoadWorld', { offset: 0, limit: 1 }, { timeoutMs: 8000 }).catch(() => null);
  const worldCount = world?.count ?? world?.data?.count;
  if (typeof worldCount === 'number') reads.push({ name: 'voxels', count: worldCount });

  return {
    at: Date.now(),
    modules,
    drones,
    tasks,
    reads,
    liveTasks: tk?.live ?? tk?.data?.live ?? rawTasks.filter((t: any) => (t.progress ?? 0) < 100).length,
    assignedTasks: rawTasks.filter((t: any) => t.assigned && (t.progress ?? 0) < 100).length,
  };
}

export const sentinel = {
  ledger: new Ledger(),
  lastRun: 0,
  lastError: null as string | null,
  // The raw observation the detectors were handed. Without this, diagnosing a detector means
  // guessing at what it saw -- which is the exact failure mode this whole file exists to end.
  lastObservation: null as Observation | null,
};

export async function runSentinelTick(): Promise<{ opened: number; open: number }> {
  sentinel.lastRun = Date.now();
  try {
    const o = await observe();
    if (!o) return { opened: 0, open: sentinel.ledger.counts().open };
    sentinel.lastObservation = o;
    const found = detect(o, sentinel.ledger.reads());
    const opened = await sentinel.ledger.reconcile(found, o.at);
    for (const inc of opened) {
      console.log(`[sentinel] ${inc.severity.toUpperCase()} ${inc.kind}: ${inc.detail}`);
    }
    sentinel.lastError = null;
    return { opened: opened.length, open: sentinel.ledger.counts().open };
  } catch (err) {
    // A MONITOR THAT CANNOT SEE MUST SAY SO.
    //
    // This used to swallow the error and return, leaving every open incident open and every closed
    // one unreported -- so a broken sentinel looked exactly like a healthy system with one stubborn
    // fault. Blindness is now itself an incident, which means the one number that matters cannot be
    // quietly flattered by the observer falling over.
    sentinel.lastError = String(err);
    await sentinel.ledger.reconcile(
      [{ key: 'blind', kind: 'sentinel-cannot-observe', severity: 'lie',
         detail: `the sentinel failed to gather an observation: ${String(err).slice(0, 160)}` }],
      Date.now(),
    );
    return { opened: 0, open: sentinel.ledger.counts().open };
  }
}

export function startSentinel(intervalMs = 60_000): void {
  sentinel.ledger.load().catch(() => { /* first run has no ledger */ });
  setInterval(() => { runSentinelTick().catch(() => { /* recorded in lastError */ }); }, intervalMs).unref();
}
