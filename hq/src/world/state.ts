/**
 * Fleet and world state.
 *
 * In-memory for now, behind interfaces narrow enough that swapping in a real
 * store later touches nothing above. The important design content here is not
 * the storage — it is STALENESS.
 *
 * A drone's map is always a memory, never an observation. Blocks get mined,
 * water flows, other players build. A world model that reports what it saw an
 * hour ago with the same confidence as what it saw ten seconds ago will happily
 * route a drone into a wall and call it a pathfinding bug. So every cell carries
 * when it was seen and by whom, every read reports its own age, and the agent is
 * shown that age rather than being left to assume freshness.
 */

export interface Vec3 { x: number; y: number; z: number; }
export const key = (v: Vec3) => `${v.x},${v.y},${v.z}`;

export interface Cell {
  block: string;
  /** epoch ms when observed */
  seen: number;
  /** which drone reported it — for blaming bad data on a miscalibrated scanner */
  by: number;
}

export type DroneStatus = 'idle' | 'working' | 'docking' | 'stranded' | 'lost';

export interface Drone {
  id: number;
  name: string;
  role: string;
  pos?: Vec3;
  heading?: 'north' | 'south' | 'east' | 'west';
  fuel: number;
  status: DroneStatus;
  /**
   * The word the drone actually used, kept alongside the normalised status.
   *
   * DroneLogic's vocabulary is finer than HQ's — mining, scanning, surveying, hauling, moving,
   * rotation, updating, stuck — and collapsing all of those to 'working' is right for deciding
   * whether a drone is available but wrong for telling an operator what it is doing. Both
   * questions are legitimate, so both answers are kept rather than one being reconstructed from
   * the other.
   */
  reported?: string;
  /** The drone's OWN account of why it stopped. It said this; do not paraphrase it away. */
  stuck?: string;
  /**
   * epoch ms of last heartbeat. Silence is the primary loss signal.
   *
   * OPTIONAL, and that is the point: a drone DroneMan has never heard from has no timestamp at
   * all, which is different from one last seen long ago. Encoding "never" as 0 made silence
   * arithmetic return the entire Unix epoch — /brief reported a drone "silent 1787342964s",
   * roughly 56,000 years, which reads as a broken clock rather than as a dead drone.
   */
  lastSeen?: number;
  order?: string;
}

export interface Order {
  id: string;
  kind: 'dig' | 'build' | 'quarry' | 'explore' | 'recover' | 'follow' | 'lumber';
  issuedBy: string;
  issuedAt: number;
  bounds?: { min: Vec3; max: Vec3 };
  priority: number;
  status: 'queued' | 'active' | 'done' | 'aborted' | 'failed';
  workers: number[];
  progress: number;
  /** Set on failure. Fed back to the agent verbatim — it is the replanning input. */
  failure?: string;
}

/** How long before an observation stops being trustworthy, by kind of question. */
export const STALE_MS = {
  /** Terrain shifts slowly, but players are unpredictable. */
  world: 10 * 60_000,
  /** A drone that hasn't reported in this long is presumed in trouble. */
  drone: 60_000,
};

export class HiveState {
  private cells = new Map<string, Cell>();
  private drones = new Map<number, Drone>();
  private orders = new Map<string, Order>();
  private orderSeq = 0;

  // ── world ────────────────────────────────────────────────────────────────
  /** Ingest a scan. Newer observations always win; we never merge conflicting truth. */
  ingestScan(by: number, blocks: Array<Vec3 & { block: string }>, at = Date.now()): number {
    let changed = 0;
    for (const b of blocks) {
      const k = key(b);
      const prev = this.cells.get(k);
      if (prev && prev.seen > at) continue; // out-of-order packet; keep the fresher one
      if (!prev || prev.block !== b.block) changed++;
      this.cells.set(k, { block: b.block, seen: at, by });
    }
    return changed;
  }

  getCell(v: Vec3): (Cell & { ageMs: number; stale: boolean }) | undefined {
    const c = this.cells.get(key(v));
    if (!c) return undefined;
    const ageMs = Date.now() - c.seen;
    return { ...c, ageMs, stale: ageMs > STALE_MS.world };
  }

  /** Summarise a region rather than dumping cells — agents reason over summaries. */
  summarizeRegion(min: Vec3, max: Vec3) {
    const counts: Record<string, number> = {};
    let known = 0, oldest = Infinity, newest = 0;
    for (let x = min.x; x <= max.x; x++)
      for (let y = min.y; y <= max.y; y++)
        for (let z = min.z; z <= max.z; z++) {
          const c = this.cells.get(key({ x, y, z }));
          if (!c) continue;
          known++;
          counts[c.block] = (counts[c.block] ?? 0) + 1;
          oldest = Math.min(oldest, c.seen);
          newest = Math.max(newest, c.seen);
        }
    const volume =
      (max.x - min.x + 1) * (max.y - min.y + 1) * (max.z - min.z + 1);
    return {
      volume,
      known,
      coverage: volume ? +(known / volume).toFixed(3) : 0,
      blocks: Object.fromEntries(Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 12)),
      oldestObservationAgeMs: known ? Date.now() - oldest : null,
      newestObservationAgeMs: known ? Date.now() - newest : null,
      stale: known ? Date.now() - oldest > STALE_MS.world : true,
    };
  }

  get worldSize() { return this.cells.size; }

  // ── fleet ────────────────────────────────────────────────────────────────
  upsertDrone(d: Partial<Drone> & { id: number }): Drone {
    const prev = this.drones.get(d.id);
    // No lastSeen default. Defaulting it to now() invents proof of life for a drone nobody has
    // ever heard from, which is the one thing this field exists to disprove.
    const next: Drone = {
      name: `drone-${d.id}`, role: 'worker', fuel: 0, status: 'idle',
      ...prev, ...d,
    };
    this.drones.set(d.id, next);
    return next;
  }

  /**
   * Drones with derived status. We downgrade silent drones here rather than in a
   * background job so that state is always self-consistent when read — a drone
   * cannot appear 'working' while having been silent for ten minutes.
   */
  listDrones(): Array<Drone & { silentMs: number | null }> {
    const now = Date.now();
    return [...this.drones.values()].map((d) => {
      // null, not a number, when there is no timestamp: callers must be forced to decide how to
      // say "never heard from" rather than being handed a duration that happens to be enormous.
      const silentMs = d.lastSeen ? now - d.lastSeen : null;
      const status: DroneStatus =
        d.status === 'lost' ? 'lost'
        // Never reported at all is the strongest loss signal there is, not the weakest. DroneMan
        // stamps lastSeen on registration, so its absence means the drone has not spoken since.
        : silentMs === null ? 'lost'
        : silentMs > STALE_MS.drone * 5 ? 'lost'
        : silentMs > STALE_MS.drone ? 'stranded'
        : d.status;
      return { ...d, status, silentMs };
    });
  }

  // ── orders ───────────────────────────────────────────────────────────────
  createOrder(o: Omit<Order, 'id' | 'issuedAt' | 'status' | 'workers' | 'progress'>): Order {
    const order: Order = {
      ...o,
      id: `ord-${++this.orderSeq}`,
      issuedAt: Date.now(),
      status: 'queued',
      workers: [],
      progress: 0,
    };
    this.orders.set(order.id, order);
    return order;
  }

  getOrder(id: string) { return this.orders.get(id); }
  listOrders() { return [...this.orders.values()]; }
  activeOrders() { return this.listOrders().filter((o) => o.status === 'queued' || o.status === 'active'); }
}

export const state = new HiveState();
