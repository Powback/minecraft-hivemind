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
  /** How to get more. */
  action: 'gather' | 'lumber';
  /** Cap for a single dispatch. */
  limit?: number;
}

/** Sensible starting policy. Tune with the supply.policy tool rather than editing this. */
export const DEFAULT_RULES: SupplyRule[] = [
  { match: 'coal_ore', min: 32, action: 'gather', limit: 64 },
  { match: 'iron_ore', min: 32, action: 'gather', limit: 64 },
  { match: 'dirt', min: 64, action: 'gather', limit: 64 },
  { match: 'oak_log', min: 32, action: 'lumber' },
];

const COOLDOWN_MS = 10 * 60 * 1000;

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
}

export const supply: SupplyState = {
  enabled: false,          // opt in explicitly; an autonomous fleet should not start itself
  rules: [...DEFAULT_RULES],
  lastRun: 0,
  cooldowns: {},
  dispatched: 0,
  log: [],
};

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
  const live = drones.filter((d: any) => !d.offline);
  const busy = live.find((d: any) => d.status && d.status !== 'idle');
  if (busy) return { acted: false, reason: `waiting: ${busy.name} is ${busy.status}` };
  const idleMiner = live.find((d: any) => (d.role ?? 'miner') === 'miner' && d.status === 'idle');
  if (!idleMiner) return { acted: false, reason: 'no idle miner' };

  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  const detail = stock?.detail ?? stock?.data?.detail ?? [];
  const held = (m: string) =>
    detail.filter((d: any) => typeof d.name === 'string' && d.name.includes(m))
          .reduce((n: number, d: any) => n + (d.count ?? 0), 0);

  const now = Date.now();
  for (const rule of supply.rules) {
    const have = held(stockKey(rule));
    if (have >= rule.min) continue;
    if ((supply.cooldowns[rule.match] ?? 0) > now) continue;

    supply.cooldowns[rule.match] = now + COOLDOWN_MS;
    try {
      if (rule.action === 'gather') {
        const r: any = await callTool('order.gather', { match: rule.match, limit: rule.limit ?? 64 });
        if (r?.ok === false) {
          // Nothing surveyed matches: the honest answer is "go and look", not "dig somewhere".
          note(`${rule.match}: ${have}/${rule.min} but nothing surveyed — needs a scan`);
          return { acted: false, reason: `${rule.match} not surveyed` };
        }
        supply.dispatched++;
        supply.lastAction = `gather ${rule.match}`;
        note(`${rule.match}: ${have}/${rule.min} → gather dispatched`);
        return { acted: true, reason: `gather ${rule.match}` };
      }
      note(`${rule.match}: ${have}/${rule.min} → ${rule.action} not yet automatable`);
      return { acted: false, reason: `${rule.action} unavailable` };
    } catch (err) {
      note(`${rule.match}: dispatch failed — ${(err as Error)?.message ?? err}`);
      return { acted: false, reason: 'dispatch failed' };
    }
  }
  return { acted: false, reason: 'all materials above target' };
}

export function startSupplyLoop(intervalMs = 60_000) {
  setInterval(() => { runSupplyTick().catch(() => { /* reported via note() */ }); }, intervalMs).unref();
}
