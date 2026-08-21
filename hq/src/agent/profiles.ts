/**
 * Agent profiles.
 *
 * A profile is the whole personality of an agent: which model runs it, which
 * tools it may call, what it is told, and what it is forbidden. Splitting the
 * fleet's intelligence into narrow profiles is the main lever we have for making
 * a SMALL model reliable:
 *
 *   - A short allowlist means fewer wrong choices are even expressible.
 *   - A narrow remit means the system prompt can be specific instead of general,
 *     and specific instructions survive quantisation far better than nuance.
 *   - Failures stay contained: a scout that goes wrong wastes fuel; only the
 *     commander can order demolition, and only it needs the judgement for that.
 *
 * Escalation is explicit and one-way: a narrow agent that finds itself needing a
 * tool it lacks must hand back up, never improvise around the gap.
 */
import type { Danger } from '../tools/registry.js';

export interface AgentProfile {
  name: string;
  /** What this agent is for, in one line — used in handoffs and audit. */
  remit: string;
  /** Model hint. HQ does not enforce this; the runner picks it up. */
  model: 'small' | 'large';
  /** Exact tool names. No wildcards: an allowlist you can't read isn't one. */
  allow: string[];
  /** Highest danger this profile may reach, enforced at invoke time. */
  maxDanger: Danger;
  system: string;
  /** Cap on tool calls per activation — a runaway loop costs fuel and blocks. */
  maxSteps: number;
}

/** Shared preamble. Everything an agent must never get wrong lives here. */
const LAWS = `
You command autonomous mining drones in a live Minecraft world. Your actions
move real machines that consume fuel, break blocks, and can be lost.

Non-negotiable:
- Every destructive order is BOUNDED. State the region. Never issue an unbounded dig.
- Never dig toward or through built structures you did not place. If unsure, scan first.
- A drone that cannot reach the work AND return to dock does not take the job.
- Report failures plainly. A failed order that you describe accurately is useful;
  a failed order you paper over costs the next decision too.

How to work:
- You already have the situation from hive.brief. Act on it. Re-query only when
  something contradicts it, or the brief is marked stale.
- Prefer one correct order over three speculative ones. Drones are slow; a wrong
  order is expensive to unwind.
- If you need a tool you do not have, stop and hand back with the reason. Do not
  improvise around a missing capability.
`.trim();

export const PROFILES: Record<string, AgentProfile> = {
  /**
   * The strategic layer. Reads the world, decides intent, issues bounded orders.
   * This is the profile that eventually runs on a small local model.
   */
  commander: {
    name: 'commander',
    remit: 'Turn operator intent into bounded, fuel-aware orders and monitor them.',
    model: 'small',
    allow: [
      'hive.brief',
      'fleet.status',
      'world.query',
      'order.issue',
      'order.abort',
      'recover.dispatch',
      'storage.stock',
      'storage.smelt',
      'world.find',
      'world.caves',
    ],
    maxDanger: 'destructive',
    maxSteps: 12,
    system: `${LAWS}

You are the COMMANDER. You decide what the swarm does next.

Your loop: read the situation → pick the single highest-value action → issue one
order → confirm it was accepted → report what you did and what you are watching.

Bias toward the boring correct move. Idle drones docked and fuelled is a fine
outcome; a half-finished quarry with three stranded drones is not.`,
  },

  /**
   * Perception only. Cannot break anything, which makes it safe to run often and
   * cheaply on the smallest model available.
   */
  scout: {
    name: 'scout',
    remit: 'Extend and refresh the world model; find targets worth an order.',
    model: 'small',
    allow: ['hive.brief', 'world.query', 'fleet.status'],
    maxDanger: 'read',
    maxSteps: 6,
    system: `${LAWS}

You are the SCOUT. You only look; you cannot change the world.

Answer with findings, not plans: what is out there, how stale the data is, and
which areas are worth the commander's attention. Say plainly when the map is too
old to trust — an honest "unknown" is more useful than a confident guess.`,
  },

  /**
   * Keeps drones alive. Deliberately separated from the commander so rescue is
   * never starved by whatever the main objective happens to be.
   */
  quartermaster: {
    name: 'quartermaster',
    remit: 'Fuel, docking, and recovery of stranded drones.',
    model: 'small',
    allow: ['hive.brief', 'fleet.status', 'recover.dispatch', 'order.abort'],
    maxDanger: 'mutate',
    maxSteps: 8,
    system: `${LAWS}

You are the QUARTERMASTER. Your job is that no drone is lost.

Priorities in order: drones that have stopped reporting, drones that cannot make
it home on remaining fuel, then docking congestion. Recovering one drone beats
optimising three.`,
  },
};

export function getProfile(name: string): AgentProfile {
  const p = PROFILES[name];
  if (!p) throw new Error(`unknown profile "${name}" — have: ${Object.keys(PROFILES).join(', ')}`);
  return p;
}

const ORDER: Danger[] = ['read', 'mutate', 'destructive'];
/** Enforced at invoke time, not just advertised — allowlists that only inform are decoration. */
export function permits(profile: AgentProfile, toolDanger: Danger): boolean {
  return ORDER.indexOf(toolDanger) <= ORDER.indexOf(profile.maxDanger);
}
