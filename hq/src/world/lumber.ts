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
import { withinReach, settlement } from './settlement.js';
import { field } from '../lua-table.js';

/** How far a single sweep reaches from its start, in blocks. */
export const SWEEP = 8;

export interface LumberSweep {
  /** TaskMan id, when one was queued. */
  task?: number;
  /** Where the sweep starts -- the densest cluster of known trunks. */
  at?: { x: number; y: number; z: number };
  /** How many known trunks fall inside the sweep from there. */
  trunks?: number;
  leftovers?: boolean;      // true when the sweep harvests canopy leftovers (fuel emergency)
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
  const hits = field(found, 'hits') ?? [];
  const list = Array.isArray(hits) ? hits : Object.values(hits ?? {});
  // SURFACE WOOD ONLY. An oak_log at y=19 is a mineshaft beam; a lumber job was sent to one
  // (2026-09-04) and the drone would have had to tunnel 45 blocks down for a single log.
  const surface = (h: any) => typeof h.y !== 'number' || h.y >= settlement.base.y - 4;
  return (list as any[]).filter((h: any) => h && typeof h.x === 'number' && withinReach(h) && surface(h));
}

/**
 * A LOG IS NOT A TREE, AND THE INDEX FILLS UP WITH THE DIFFERENCE.
 *
 * Felling leaves the canopy behind, and the map keeps every log it has ever seen -- so each harvest
 * ADDS single floating logs six or seven blocks up with nothing beneath them. Nothing removes them,
 * so the proportion of un-fellable targets rises with every tree cut. This is a self-poisoning
 * index: the better the fleet works, the worse its next target gets.
 *
 * Measured on the settlement that died of it -- 200 recorded oak logs, 101 distinct columns:
 *
 *   height 1: 63 columns   <- remnants. 62% of everything the picker could choose.
 *   height 2: 11
 *   height 3+: 27 columns  <- actual standing trees
 *
 * And the last sweep before the fuel ran out was sent to `-505,71,30`: a single log at y=71 with
 * air for six blocks under it, verified against the world. The drone arrives at `pos.y + 1`, so it
 * serpentined through open sky and honestly reported `felled 0 tree(s), 0 log(s)`.
 *
 * That is the whole fuel death: wood income went to zero while every sweep completed successfully,
 * the charcoal line starved behind it, and the fleet burned its reserve down to nothing.
 *
 * An oak is four to six logs tall, so three is comfortably below a real tree and comfortably above
 * a leftover. NOT a spot-check against the world: those blocks ARE there -- being present and being
 * a tree are different questions, and checking presence is what made this look fine earlier.
 */
const MIN_TRUNK = 3;

/** Group logs into columns, keeping only those tall enough to be a standing tree. */
export function standingTrees(p_All: any[]): any[] {
  const col = new Map<string, any[]>();
  for (const h of p_All) {
    const k = `${h.x},${h.z}`;
    const at = col.get(k);
    if (at) at.push(h); else col.set(k, [h]);
  }
  const out: any[] = [];
  for (const logs of col.values()) if (logs.length >= MIN_TRUNK) out.push(...logs);
  return out;
}

/**
 * The start that puts the most trunks inside one sweep.
 *
 * DENSEST, NOT NEAREST. The value of a sweep is trees-per-trip, not distance to the first one: a
 * sweep meeting six trunks pays for its travel several times over and one meeting a lonely tree
 * does not. The drone is going out either way.
 */
/**
 * COUNT THE TREES THE DRONE WILL ACTUALLY WALK PAST.
 *
 * This counted anything within +/-SWEEP of the candidate -- a 17x17 box, 289 cells. The drone walks
 * `Serpentine(SWEEP, SWEEP)`: an 8x8 block, 64 cells, anchored at the point it arrives on and
 * oriented by whatever heading it happens to have. So the number scored the site over four and a
 * half times the ground the sweep covers, and only one quadrant of it could ever be visited.
 *
 * Measured: `oak_log: 8/128 -> lumber sweep at -495,65,19 (32 trunks in range)`, and the sweep
 * returned `felled 1 tree(s), 9 log(s)`. Nothing failed -- the drone walked its 64 cells and met one
 * tree, exactly as instructed. The site picker had scored a neighbourhood and sent the drone to a
 * corner of it.
 *
 * Half a sweep either way is the largest window that fits inside the walked block whichever way the
 * drone ends up facing, so every trunk counted is one it can actually reach. That makes the reported
 * figure honest AND picks a better start: the best 9x9 window rather than the best 17x17
 * neighbourhood.
 */
const HALF_SWEEP = Math.floor(SWEEP / 2);

/**
 * TREES, NOT LOG BLOCKS. A trunk is a COLUMN, and the map records every block in it.
 *
 * The score counted map hits, so one oak eight blocks tall scored eight. Spot-checking the index
 * against the world found `-477,67,11` and `-477,70,11` -- the same tree, two records, and the
 * sweep can fell it once. That is how a site advertised as "32 trunks in range" returns
 * `felled 1 tree(s), 9 log(s)` with nothing having gone wrong: nine logs IS that tree, and the
 * other records were the rest of it and its neighbours' upper halves.
 *
 * An inflated count is not just a wrong number in a log line -- it picks the site. A single tall
 * tree outscored a stand of short ones, so the drone was repeatedly sent to the least productive
 * ground available, burning a round trip for one tree while wood is the settlement's only renewable
 * fuel.
 */
function columnsNear(p_All: any[], p_At: any): number {
  const seen = new Set<string>();
  for (const o of p_All) {
    if (Math.abs(o.x - p_At.x) <= HALF_SWEEP && Math.abs(o.z - p_At.z) <= HALF_SWEEP) {
      seen.add(`${o.x},${o.z}`);
    }
  }
  return seen.size;
}

/**
 * START AT THE FOOT OF THE TREE, NOT WHEREVER THE BEST-SCORING BLOCK HAPPENED TO SIT.
 *
 * The map records every log in a column, so the chosen record is as likely to be a canopy log as a
 * trunk one -- and the sweep walks at the altitude it is given. RunJobNow arrives at `pos.y + 1`, so
 * a start taken from a log at y=71 puts the drone at y=72, ABOVE the canopy, where `turtle.inspect()`
 * looks forward into open air for all sixty-four cells of the sweep.
 *
 * That is the shape CLAUDE.md already records for gathers: "approaching vertically wrote off the
 * entire forest". A trunk log has more trunk above it and dirt below; only the SIDES are open, so
 * the drone has to be at trunk height to see anything at all. It explains a sweep that walks its
 * whole grid over a verified stand of trees and reports `felled 0 tree(s), 0 log(s)` with nothing
 * having failed.
 *
 * The lowest recorded log in the column is the trunk base, which is the one height where forward
 * inspection meets wood.
 */
/**
 * The lowest trunk foot of ANY standing column inside the sweep window, not just the densest one.
 *
 * The sweep flies one plane and looks forward and up, so a trunk whose base sits BELOW that plane
 * is never seen at all -- the drone passes through its canopy. Starting at the lowest foot in the
 * window puts every trunk at or above the plane, where the forward and overhead inspections find it.
 * The densest column's own foot was used before; on uneven ground it read as "felled 0" while
 * rcon showed oak_log two blocks lower in the next column over.
 */
/** Every log column inside the sweep window around p_At, with its lowest and highest recorded log. */
function columnsInWindow(p_All: any[], p_At: any): Map<string, { x: number; z: number; lo: number; hi: number }> {
  const cols = new Map<string, { x: number; z: number; lo: number; hi: number }>();
  for (const o of p_All) {
    if (Math.abs(o.x - p_At.x) > HALF_SWEEP || Math.abs(o.z - p_At.z) > HALF_SWEEP) continue;
    if (typeof o.y !== 'number') continue;
    const k = `${o.x},${o.z}`;
    const c = cols.get(k);
    if (c) { c.lo = Math.min(c.lo, o.y); c.hi = Math.max(c.hi, o.y); }
    else cols.set(k, { x: o.x, z: o.z, lo: o.y, hi: o.y });
  }
  return cols;
}

function lowestFootNear(p_All: any[], p_At: any): number {
  // THE PLANE THAT CUTS THE MOST TRUNKS, NOT THE LOWEST FOOT.
  //
  // The sweep sees the cell in front and the cell overhead, so a plane at y finds every trunk
  // whose logs include y or y+1. The lowest foot in the window put the plane at 64 under a trunk
  // whose remaining logs sat at 67-70 -- its base had been cut on an earlier pass and it hung in
  // the air -- and three sweeps in a row walked beneath it: "felled 0 tree(s), 0 log(s)", ~900
  // fuel. Score every candidate height by the columns it would intersect and take the best;
  // ties go to the lowest, which is where uncut trees begin.
  const cols = columnsInWindow(p_All, p_At);
  if (!cols.size) return p_At.y;
  let best = p_At.y;
  let bestN = -1;
  const lo = Math.min(...[...cols.values()].map((c) => c.lo));
  const hi = Math.max(...[...cols.values()].map((c) => c.hi));
  for (let y = lo; y <= hi; y++) {
    let n = 0;
    for (const c of cols.values()) if (c.lo <= y + 1 && c.hi >= y) n++;
    if (n > bestN) { best = y; bestN = n; }
  }
  return best;
}

/**
 * THE JOB IS THE TRUNKS, NOT THE SQUARE.
 *
 * A sweep walks one plane and hopes the trunks cross it. Three sweeps in one evening walked under a
 * trunk whose remaining logs hung two blocks above the plane, each reporting "felled 0" with the
 * tree verified standing by rcon. The index already knows where every standing trunk begins, so the
 * drone is handed that list: it goes to each foot, approaches from the side, fells the column and
 * climbs it, and records the ones that are gone so the index forgets them. The sweep stays as the
 * fallback for a task that carries no targets.
 */
const LUMBER_TARGETS_MAX = 12;
function trunkFeetNear(p_Trees: any[], p_At: any): Array<{ x: number; y: number; z: number }> {
  const near = (p: { x: number; z: number }) => Math.abs(p.x - p_At.x) + Math.abs(p.z - p_At.z);
  return [...columnsInWindow(p_Trees, p_At).values()]
    .map((c) => ({ x: c.x, y: c.lo, z: c.z }))
    .sort((a, b) => near(a) - near(b))
    .slice(0, LUMBER_TARGETS_MAX);
}

function densestStart(p_All: any[]): { at: any; trunks: number } {
  let best = p_All[0];
  let bestN = -1;
  for (const h of p_All) {
    const n = columnsNear(p_All, h);
    if (n > bestN) { best = h; bestN = n; }
  }
  return { at: { ...best, y: lowestFootNear(p_All, best) }, trunks: bestN };
}

/**
 * Queue a lumber sweep on the densest cluster of known trunks inside the operating circle.
 *
 * Returns a reason rather than throwing when there is nothing to fell, so the caller can decide
 * whether that means "survey for more" or "give up quietly".
 */
/**
 * THE CHOICE, WITHOUT THE NETWORK. Which logs count as a tree, where the sweep starts and which
 * trunk feet the drone is sent to -- pure, so the test can hand it a forest and read the answer.
 *
 * `leftovers` is the fuel-emergency switch. The standing-tree filter exists because leftover canopy
 * poisoned every pick when the fleet was choosing ONE sweep by density; but 88 leftover logs inside
 * the operating circle are 88 charcoal, and their canopies still hold the saplings the grove needs.
 * With no standing tree in reach and the shelf at zero (2026-09-04), refusing them is refusing the
 * only wood there is. Standing trees are still preferred when any exist.
 */
export function chooseSweep(p_All: any[], p_Leftovers = false):
    { at: { x: number; y: number; z: number }; trunks: number;
      targets: Array<{ x: number; y: number; z: number }>; leftovers: boolean } | { reason: string } {
  if (!p_All.length) return { reason: 'no trees known inside the operating circle' };
  let trees = standingTrees(p_All);
  let leftovers = false;
  if (!trees.length) {
    if (!p_Leftovers) {
      return { reason: `no standing trees known -- ${p_All.length} recorded log(s) are all leftover `
                     + `canopy, ${MIN_TRUNK} stacked logs needed to be worth felling` };
    }
    trees = p_All;
    leftovers = true;
  }
  const { at, trunks } = densestStart(trees);
  const targets = trunkFeetNear(trees, at);
  return { at: { x: at.x, y: at.y, z: at.z }, trunks, targets, leftovers };
}

export async function queueLumberSweep(
  bridge: { call: (mod: string, key: string, data: unknown,
                   opts?: { timeoutMs?: number; idem?: string }) => Promise<any> },
  match: string,
  priority = 1,
  opts: { leftovers?: boolean } = {},
): Promise<LumberSweep> {
  const all = await knownTrunks(bridge, match);
  const pick = chooseSweep(all, opts.leftovers === true);
  if ('reason' in pick) return { reason: pick.reason };
  const { at, trunks, targets, leftovers } = pick;
  const r: any = await bridge.call('TaskMan', 'Add', {
    name: `lumber:${match}`,
    priority,
    work: { lumber: { w: SWEEP, l: SWEEP, start: { x: at.x, y: at.y, z: at.z }, targets } },
  }, { timeoutMs: 8000 });
  const id = typeof r?.id === 'number' ? r.id
           : (typeof r?.data?.id === 'number' ? r.data.id : undefined);
  return { task: id, at: { x: at.x, y: at.y, z: at.z }, trunks, leftovers };
}
