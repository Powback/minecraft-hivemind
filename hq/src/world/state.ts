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

// 'hauling' is SEPARATE from 'docking' on purpose. Both existed as real, different behaviours --
// carrying cargo to storage, and parking on a berth -- and both were labelled 'docking', so the
// panel showed "docking - hauling gather zinc_ore" and there was no way to tell which one the
// drone was actually doing. A status that collapses two behaviours is worse than no status.
export type DroneStatus = 'idle' | 'working' | 'hauling' | 'docking' | 'stranded' | 'lost';

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
  /**
   * What the current job actually is, in words -- "craft oak_planks x8", "gather coal_ore".
   *
   * `reported` gives the verb; this gives its object. Without it the fleet view can say a crafter
   * is crafting but not what, so a drone looping on a recipe it can never satisfy looks exactly
   * like one making steady progress.
   */
  detail?: string;
  /**
   * When this drone's POSITION last actually changed, and when its cargo last went DOWN.
   *
   * Both are observations, not reports, and that is the whole point. Every status in this system is
   * a drone's own account of itself, and the expensive failures have all been drones whose account
   * was sincere and wrong: one walked 121 blocks in the wrong direction while logging that it was
   * closing the gap on home; four sat "assigned" to tasks they were not doing; one reported idle
   * for five hours from outside the loaded region. None of those could be caught by reading status,
   * and all of them are obvious the moment you ask "has it moved, and has it delivered anything?".
   */
  lastMovedAt?: number;
  lastDeliveredAt?: number;
  /**
   * What this drone is physically holding, name -> count.
   *
   * Without it the fleet's own inventory is invisible: sixteen logs inside a miner are, as far as
   * every planner and every panel is concerned, nowhere at all -- so the crafter fails for want of
   * wood that is two blocks away.
   */
  carrying?: Record<string, number>;
  /** The drone's OWN account of why it stopped. It said this; do not paraphrase it away. */
  stuck?: string;
  /** Error recorded by the bootloader when the drone's program died. Present means crash-looping. */
  crash?: string;
  /** Answering GPS pings right now, extending coverage for everyone else. */
  hosting?: boolean;
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

    // WHAT ACTUALLY CHANGED IN THE WORLD, recorded here because here is the only place that sees
    // the before and the after. Everything downstream reads a snapshot and cannot tell a drone
    // that is working from one that is merely SAYING so -- which is the failure this whole file
    // keeps running into. A status is a claim; a position that changed is evidence.
    const now = Date.now();
    const moved = prev?.pos && next.pos
      && (prev.pos.x !== next.pos.x || prev.pos.y !== next.pos.y || prev.pos.z !== next.pos.z);
    next.lastMovedAt = moved ? now : prev?.lastMovedAt;

    // A DELIVERY IS CARGO GOING DOWN, and it is the only unambiguous evidence of useful work: a
    // drone can move all day without achieving anything, but items only leave a drone into a chest.
    const held = (c?: Record<string, number>) =>
      Object.values(c ?? {}).reduce((n, v) => n + (Number(v) || 0), 0);
    const before = held(prev?.carrying);
    const after = held(next.carrying);
    next.lastDeliveredAt = (prev && after < before) ? now : prev?.lastDeliveredAt;

    this.drones.set(d.id, next);
    return next;
  }

  /**
   * Forget a drone entirely. THE HALF OF fleet.retire THAT DID NOT EXIST.
   *
   * fleet.retire called DroneMan.RetireDrone, which correctly deleted the drone from the in-world
   * registry -- and HQ kept its own Map, which had upsertDrone and no way to remove anything. So
   * the tool returned ok:true, the drone stayed in fleet.status for ever, and every consumer went
   * on planning around it. Retiring five destroyed drones reported five successes and changed
   * nothing.
   *
   * That was written down in CLAUDE.md as a known trap -- "fleet.retire (HQ still listed the
   * drone)" -- and left unfixed, which is how it cost the fleet again: those five kept generating
   * rescues aimed at their last known positions, and rescues preempt real work, so a handful of
   * casualties occupied the drones that still functioned.
   *
   * Returns whether anything was actually removed, so the caller can report the effect rather than
   * the attempt.
   */
  retireDrone(id: number): boolean {
    return this.drones.delete(id);
  }

  /**
   * How long a drone may claim to be working while nothing about it changes.
   *
   * Generous on purpose. Legitimate work has long quiet stretches -- a miner boring a shaft moves
   * one block every few seconds and delivers nothing for the whole descent; a crafter waits on
   * storage. Six minutes is longer than any of those and far shorter than the FIVE HOURS D6 spent
   * looking idle from outside the loaded region.
   */
  static readonly KARMA_STALL_MS = 6 * 60 * 1000;

  /**
   * Is this drone actually achieving anything?
   *
   * Static and pure so it can be tested without a world. The rule is deliberately narrow: it only
   * accuses a drone that CLAIMS to be doing something. An idle drone that is not moving is being
   * honest, and is somebody else's problem (the scheduler's) -- flagging it here would bury the
   * signal that matters under a dozen drones behaving correctly.
   *
   * "Working but not moving and not delivering" is the state every expensive failure tonight was
   * in, and the only one that reported status could never distinguish from real progress.
   */
  static karma(d: Drone, now: number): { healthy: boolean; why?: string } {
    const claims = d.status === 'working' || d.status === 'hauling' || d.status === 'docking';
    if (!claims) return { healthy: true };
    const moved = d.lastMovedAt ?? 0;
    const gave = d.lastDeliveredAt ?? 0;
    const quiet = now - Math.max(moved, gave);
    // Never observed either: we have nothing to judge on, so do not accuse. It becomes judgeable
    // the moment the drone moves once, and 'lost' already covers a drone that never speaks.
    if (moved === 0 && gave === 0) return { healthy: true };
    if (quiet <= HiveState.KARMA_STALL_MS) return { healthy: true };
    return {
      healthy: false,
      why: `reports ${d.reported ?? d.status} but has not moved or delivered for `
         + `${Math.round(quiet / 60000)} min`,
    };
  }

  /**
   * Drones with derived status. We downgrade silent drones here rather than in a
   * background job so that state is always self-consistent when read — a drone
   * cannot appear 'working' while having been silent for ten minutes.
   */
  listDrones(): Array<Drone & { silentMs: number | null; healthy: boolean; unhealthyWhy?: string }> {
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
      const k = HiveState.karma({ ...d, status }, now);
      return { ...d, status, silentMs, healthy: k.healthy, unhealthyWhy: k.why };
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
