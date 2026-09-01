/**
 * HOW THE SETTLEMENT GETS WOOD. ONE ANSWER, SHARED.
 *
 * There were three places that decided how to obtain oak_log and they did not agree:
 *
 *   the rule table          action: 'lumber'  -- fell the trunk, take the tree, replant
 *   the idle top-up loop    order.gather      -- walk scattered log blocks
 *   the plan executor       order.gather      -- even for steps whose action IS 'lumber'
 *
 * Two of the three queued a gather, so the fleet ran the gather permanently. That is not a
 * near-miss: a wood gather visits individual mapped log blocks, most of which are canopy with no
 * standable face, and it was measured at "gather: 1/192 checked, 0 taken" repeatedly across four
 * drones. A lumber sweep over the same trees returned 16 logs and put a sapling back.
 *
 * Wood is the settlement's only renewable fuel, so that disagreement is why it spent a whole
 * session fuel-starved, why the plank chain never started, and therefore why nothing was ever
 * built: order.build allocates a plot and queues the crafting it needs, and the crafting never
 * completed because there were never any planks. Eighteen storage plots sit in 'clearing' for that
 * reason alone.
 *
 * So this lives in one module and every caller uses it. Same rule as "what counts as fuel", which
 * this project has now been bitten by four times: when a question matters to more than one file,
 * it gets exactly one answer.
 */
import { withinReach } from './settlement.js';

/** How far a single sweep reaches from its start, in blocks. */
export const SWEEP = 8;

export interface LumberSweep {
  /** TaskMan id, when one was queued. */
  task?: number;
  /** Where the sweep starts -- the densest cluster of known trunks. */
  at?: { x: number; y: number; z: number };
  /** How many known trunks fall inside the sweep from there. */
  trunks?: number;
  /** Why nothing was queued, when nothing was. */
  reason?: string;
}

/** Known trunks of this kind that sit inside the operating circle. */
async function knownTrunks(
  bridge: { call: (mod: string, key: string, data: unknown,
                   opts?: { timeoutMs?: number; idem?: string }) => Promise<any> },
  match: string,
): Promise<any[]> {
  const found: any = await bridge.call('MapServer', 'FindBlocks',
    { match, limit: 400 }, { timeoutMs: 15000 });
  const hits = found?.hits ?? found?.data?.hits ?? [];
  const list = Array.isArray(hits) ? hits : Object.values(hits ?? {});
  return (list as any[]).filter((h: any) => h && typeof h.x === 'number' && withinReach(h));
}

/**
 * The start that puts the most trunks inside one sweep.
 *
 * DENSEST, NOT NEAREST. The value of a sweep is trees-per-trip, not distance to the first one: a
 * sweep meeting six trunks pays for its travel several times over and one meeting a lonely tree
 * does not. The drone is going out either way.
 */
function densestStart(p_All: any[]): { at: any; trunks: number } {
  let best = p_All[0];
  let bestN = -1;
  for (const h of p_All) {
    const n = p_All.filter((o) =>
      Math.abs(o.x - h.x) <= SWEEP && Math.abs(o.z - h.z) <= SWEEP).length;
    if (n > bestN) { best = h; bestN = n; }
  }
  return { at: best, trunks: bestN };
}

/**
 * Queue a lumber sweep on the densest cluster of known trunks inside the operating circle.
 *
 * Returns a reason rather than throwing when there is nothing to fell, so the caller can decide
 * whether that means "survey for more" or "give up quietly".
 */
export async function queueLumberSweep(
  bridge: { call: (mod: string, key: string, data: unknown,
                   opts?: { timeoutMs?: number; idem?: string }) => Promise<any> },
  match: string,
  priority = 1,
): Promise<LumberSweep> {
  const all = await knownTrunks(bridge, match);
  if (!all.length) return { reason: 'no trees known inside the operating circle' };

  const { at, trunks } = densestStart(all);

  // Priority 1, the same as the other fuels. Felling and gathering compete for the same miners and
  // lumber used to queue at 3 against the gather's 2, so with lowest-first the fleet ran the gather
  // every time and the lumber task sat unassigned for an entire session.
  const r: any = await bridge.call('TaskMan', 'Add', {
    name: `lumber:${match}`,
    priority,
    work: { lumber: { w: SWEEP, l: SWEEP, start: { x: at.x, y: at.y, z: at.z } } },
  }, { timeoutMs: 8000 });

  const id = typeof r?.id === 'number' ? r.id
           : (typeof r?.data?.id === 'number' ? r.data.id : undefined);
  return { task: id, at: { x: at.x, y: at.y, z: at.z }, trunks };
}
