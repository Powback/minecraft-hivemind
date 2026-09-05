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

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { city, factories, saveCity } from '../world/city.js';
import { allocate } from '../world/plots.js';
import { join, dirname } from 'node:path';
import { bridge } from '../bridge/ws.js';
import { registry } from '../tools/registry.js';
import { luaList, field, numField } from '../lua-table.js';
import { settlement, withinReach } from '../world/settlement.js';
import { queueLumberSweep } from '../world/lumber.js';
import { TOWER_TOP } from '../world/tower.js';
import { readStockDetail, readStockWhere } from '../world/stock.js';

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
  /**
   * How to get more.
   *
   * `craft` is what makes the loop reach anything the fleet MAKES rather than digs. Without it the
   * recipe graph was only reachable by hand: the fleet could notice it was short of coal and go
   * mine some, and could not notice it was short of chests, because "short of chests" was not
   * something a rule could say.
   */
  action: 'gather' | 'lumber' | 'craft' | 'mine';
  /** Cap for a single dispatch. */
  limit?: number;
  /** For `mine`: what depth to prospect at. Iron and coal live far below any surface scan. */
  depth?: number;
}

/** Sensible starting policy. Tune with the supply.policy tool rather than editing this. */
/** A crafted stock kept between min and limit, the way planks and chests are. */
function keepCrafted(item: string, min: number, limit: number): SupplyRule {
  return { match: item, stock: item, min, action: 'craft', limit };
}
export const DEFAULT_RULES: SupplyRule[] = [
  // EVERY ORE THE FLEET CAN USE, not just the two it started with.
  //
  // The miners were never the problem: looksValuable matches any "_ore", so a drone takes whatever
  // it walks past. The gap was here -- with rules for coal and iron only, nothing ever DISPATCHED a
  // gather for anything else, so 354 copper, 161 zinc and 19 lapis sat located on the map and
  // untouched while scouts were sent to look for more of the two materials that had rules.
  //
  // `match` is a substring, so each of these also picks up its deepslate variant.
  // SIZED TO CONSUMPTION, NOT PICKED BY EYE.
  //
  // min:32/limit:64 was the same shape as every other ore, and coal is not like every other ore --
  // it is the thing the fleet BURNS, so its target has to be a rate, not a tidy number.
  //
  // Measured while the tower was building: reachable fleet fuel fell 27,449 -> 11,011 in about
  // thirty minutes. That is ~16,400 fuel, ~205 coal, so roughly 400 coal/hour of real consumption.
  // Against that, min:32 means "do nothing until the fleet is eight minutes from empty", and
  // limit:64 means one successful gather buys 5,120 fuel -- about eight minutes. The loop was
  // topping up in units smaller than the interval it takes to notice, which is why four drones went
  // dry within twenty minutes of a full refuel, every single time, all of them mid-build.
  //
  // 256 is a little under an hour of headroom at the measured burn: enough that a failed or slow
  // gather does not immediately strand anyone, without hoarding into a warehouse that has 6 free
  // slots. Revisit if the burn rate changes -- the number is derived from it, not chosen.
  //
  // THESE DEPTHS WERE CALIBRATED FOR A MINECRAFT THAT NO LONGER EXISTS.
  //
  // Before 1.18, redstone and diamond lived below y=16 and gold below y=32, and the numbers here
  // match that world exactly. Caves & Cliffs moved every one of them: the deep ores now follow a
  // triangle distribution whose peak is near the world floor, and the old depths sit at the sparse
  // top edge of the band rather than in it.
  //
  // Redstone is the one that matters, because it is the binding constraint on storage itself -- a
  // chest is invisible to StorageMan without a wired modem, a modem is 8 stone and a redstone, and
  // the base has sixteen crafted chests it cannot attach for want of one. Prospecting for it at
  // y=12 is prospecting at the emptiest part of its range.
  //
  // Confirmed against what the fleet has actually observed, rather than from memory. world.query
  // over the whole base region, by band:
  //
  //   y  40..64   71% mapped   coal 196, copper 173, zinc 34
  //   y  16..40   34% mapped   coal 132, copper 100, iron 79, zinc 57, lapis 8
  //   y -10..16   14% mapped   copper 46, iron 45, coal 23, zinc 19, deepslate_iron 14
  //   y -40..-10   0% mapped   nothing -- 164 cells seen, ever
  //   y -64..-40   0% mapped   nothing -- 94 cells seen, ever
  //
  // Deepslate appears at the bottom of the third band, so the boundary is where it should be, and
  // the fleet has simply never gone below it. Not one redstone, gold, diamond or lapis has ever
  // been observed, which is consistent: every one of them is now mostly below where anyone looked.
  //
  // Copper (peak y=48), coal (abundant y=0..192) and zinc are left alone -- theirs were already in
  // range, which is why those three are the only ores the settlement has ever accumulated.
  { match: 'coal_ore', min: 256, action: 'gather', limit: 256, depth: 50 },
  { match: 'iron_ore', min: 32, action: 'gather', limit: 64, depth: 16 },
  { match: 'copper_ore', min: 32, action: 'gather', limit: 64, depth: 45 },
  { match: 'zinc_ore', min: 32, action: 'gather', limit: 64, depth: 40 },
  // See the note above: the modem chain, and the reason it has never started.
  { match: 'redstone_ore', min: 32, action: 'gather', limit: 64, depth: -50 },
  { match: 'lapis_ore', min: 16, action: 'gather', limit: 32, depth: 0 },
  { match: 'gold_ore', min: 16, action: 'gather', limit: 32, depth: -16 },
  { match: 'diamond_ore', min: 8, action: 'gather', limit: 32, depth: -50 },
  { match: 'dirt', min: 64, action: 'gather', limit: 64 },
  // GATHER, NOT LUMBER -- because `lumber` was never implemented in the dispatcher.
  //
  // dispatchRule handles mine, craft and gather; anything else falls through to "not yet
  // automatable", sets a cooldown and does nothing. So this rule -- the only renewable fuel source
  // the settlement has -- has never once dispatched a job. logs 0 and charcoal 0 all night were not
  // a failing wood chain; there was no wood chain, and the note saying so scrolled past every tick.
  //
  // gather is the right action anyway: 1,069 oak_log are already mapped at y=64-70, on the SURFACE,
  // inside the operating circle -- unlike the 1,046 coal_ore, every one of which is ten to forty
  // blocks underground where the fleet cannot navigate and has stranded three drones trying.
  //
  // This harvests mapped logs rather than farming trees. Real forestry (fell, replant, return) is
  // still worth having, but it is not what stands between this settlement and a fuel supply today.
  { match: 'oak_log', min: 32, action: 'lumber', limit: 64 },
  // Made, not dug. Planks gate every build the settlement will ever do, and chests gate field
  // caches -- so the fleet should keep a working stock of both without being asked.
  { match: 'minecraft:oak_planks', stock: 'minecraft:oak_planks', min: 32, action: 'craft', limit: 32 },
  // The tower eats bricks faster than order.tower's one-off craft supplies them: builds failed
  // "ran out of minecraft:stone_bricks partway" with 6,000 stone on the shelf and no craft queued
  // (2026-09-05 02:45). Keep a working stock the way planks are kept.
  { match: 'minecraft:stone_bricks', stock: 'minecraft:stone_bricks', min: 128, action: 'craft', limit: 128 },
  { match: 'minecraft:chest', stock: 'minecraft:chest', min: 4, action: 'craft', limit: 4 },
  // THE SETTLEMENT HAD NO RENEWABLE FUEL SOURCE. Every joule came from mining coal_ore, and the
  // fleet burns ~400 coal/hour -- so the energy balance was negative by construction and no supply
  // target could fix it. Measured at the point this was added: coal 56, logs 0, furnaces 0.
  //
  // StorageMan already services every furnace on the wired network on a 10s tick (pull output, top
  // up fuel, load input). The only missing piece was a furnace. One is eight cobblestone, and
  // storage holds 10,706 of it doing nothing -- so this both creates the fuel path and eats the
  // material that jams the warehouse. Crafted by the fleet, not spawned.
  //
  // Charcoal then comes from the oak_log rule above, which already exists and had nothing
  // downstream of it. Note a furnace still has to be PLACED on the wired network to be serviced;
  // crafting it is the prerequisite, not the whole job.
  { match: 'minecraft:furnace', stock: 'minecraft:furnace', min: 2, action: 'craft', limit: 4 },
  // The brick palette's patches mix bricks with stairs and walls; a patch short of 6 stairs threw
  // "ran out of minecraft:stone_brick_stairs partway" as readily as one short of bricks.
  ...['minecraft:stone_brick_stairs', 'minecraft:stone_brick_wall'].map((it) => keepCrafted(it, 32, 64)),
];

/**
 * How long to leave a material alone after acting on it.
 *
 * Ten minutes was chosen when the cooldown was the ONLY thing stopping the loop re-dispatching the
 * same shortage every tick. The queue check does that job properly now -- it refuses to add work a
 * material already has -- so this only needs to stop a material that keeps FAILING from being
 * retried instantly. Three minutes is enough for that, and ten meant five idle drones and two
 * materials at 0/32 sitting out most of every hour.
 */
// 3 min -> 1 min. The server runs at `tick rate 60` while the settlement is being brought up, so
// the drones live three times faster than HQ's wall clock; a three-minute cooldown between queuing
// the same rule twice was nine minutes of drone time with an idle miner beside a queued chest.
// WALL-CLOCK, WHILE THE WORLD RUNS AT 10x. Every drone timer is game time (os.clock is ticks/20) and
// the server runs /tick rate 200, so a 60 s cooldown here was ten game-minutes of nothing queued.
const COOLDOWN_MS = 30 * 1000;

/**
 * What the fleet is carrying, summed by item name. PURE, so it can be tested without a world.
 *
 * Pass only drones that can still act. A drone that cannot be reached cannot hand anything over,
 * so its cargo is not supply -- it is loss, and counting it produces exactly the confident-but-
 * wrong totals that stop the loop from fixing a real shortage.
 */
export function carriedStock(drones: any[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const d of drones ?? []) {
    const c = d?.carrying;
    if (!c || typeof c !== 'object') continue;
    for (const [name, raw] of Object.entries(c)) {
      const n = Number(raw) || 0;
      if (n > 0) out[name] = (out[name] ?? 0) + n;
    }
  }
  return out;
}

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
  /** How far along the exploration spiral the fleet has got. Persisted -- see frontier(). */
  frontier?: number;
  /** Which tower floor the settlement is currently laying. Persisted, so a restart does not
   *  re-lay a finished floor -- see keepTowerOrdered(). */
  towerLevel?: number;
  /** The last batch of patches queued for a floor, and the floor material held when it went out.
   *  A batch that drains none of it placed nothing, which is how a floor is known to be done. */
  /** `at` is when the batch was queued: "consumed nothing" and "has not started yet" are the same
   *  reading from the material count alone, so completion is only judged after a grace period. */
  towerBatch?: { level: number; held: number | null; at: number };
}

/**
 * Autonomy has to SURVIVE A RESTART.
 *
 * This state was in memory only, so every HQ rebuild silently switched the loop back off. The
 * fleet then sat idle looking perfectly healthy, and the reason was invisible -- nothing had
 * failed, a deploy had just quietly revoked the decision to be autonomous. Turning it on is an
 * explicit choice by the operator; a container restart is not a reason to un-make it.
 *
 * Rules persist too: a policy tuned through supply.set is exactly the kind of thing nobody
 * remembers having changed, so losing it is worse than losing the flag.
 */
const STATE_DIR = process.env.STATE_DIR ?? '/state';
const SUPPLY_FILE = join(STATE_DIR, 'supply.json');

/**
 * Saved policy on top of current defaults, field by field.
 *
 * A saved rule keeps every value the operator set. Anything the default has and the saved copy does
 * not is filled in -- that is precisely the case a wholesale replace gets wrong. Rules that exist
 * only in the save are kept too, since they were added deliberately.
 */
function mergeRules(defaults: SupplyRule[], saved: SupplyRule[]): SupplyRule[] {
  const out = defaults.map((d) => {
    const s = saved.find((r) => r.match === d.match);
    return s ? { ...d, ...s, depth: s.depth ?? d.depth } : { ...d };
  });
  for (const s of saved) if (!out.some((r) => r.match === s.match)) out.push(s);
  return out;
}

function loadSupply(): SupplyState {
  const base: SupplyState = {
    enabled: false,        // opt in explicitly; an autonomous fleet should not start itself
    rules: [...DEFAULT_RULES],
    lastRun: 0,
    cooldowns: {},
    dispatched: 0,
    frontier: 0,
    log: [],
  };
  try {
    const raw = JSON.parse(readFileSync(SUPPLY_FILE, 'utf8'));
    // READING A WHITELIST IS THE SAME BUG AS WRITING ONE, AND FIXING ONLY THE WRITE FIXED NOTHING.
    //
    // saveSupply was changed to persist the whole state precisely so a newly added field could not
    // be silently dropped -- and this function went on reading five fields by name, so the drop
    // simply moved one step later. `towerLevel` and `towerBatch` were written to disk correctly and
    // discarded on the way back in: measured directly, supply.json holding `towerLevel: 2` while the
    // running loop reported level 0, so every HQ redeploy quietly restarted the tower at the ground
    // floor. The save-side test passed throughout, because it only ever looked at the save.
    //
    // Same rule, both directions: take everything, and name what is deliberately dropped. `log` and
    // `cooldowns` are rebuilt at boot; the fields below are re-derived because they need validating
    // or merging, and a corrupt file must not be able to inject a wrong shape through the spread.
    const { log: _log, cooldowns: _cooldowns, enabled: _e, rules: _r, ...carried } = raw;
    return {
      ...base,
      ...carried,
      enabled: raw.enabled === true,
      // MERGE, do not replace.
      //
      // Persisted rules shadowed the defaults entirely, so any field ADDED to a default rule later
      // never reached a running deployment -- the saved copy simply lacked it. That is how both ore
      // rules ended up with no `depth`: prospecting requires one, the saved policy predated it, and
      // the fallback that sends a miner underground could never fire. The loop reported "nothing to
      // dispatch" with two materials at 0/32 and five idle drones, and it was right -- it had no
      // way to act that it could see.
      //
      // Operator tuning still wins; it just no longer discards fields it has never heard of.
      rules: mergeRules(base.rules, Array.isArray(raw.rules) ? raw.rules : []),
      dispatched: typeof raw.dispatched === 'number' ? raw.dispatched : 0,
      frontier: typeof raw.frontier === 'number' ? raw.frontier : 0,
    };
  } catch (err) {
    // A MISSING FILE IS A FIRST RUN. ANYTHING ELSE IS LOST STATE, AND MUST SAY SO.
    //
    // This swallowed both into the same silent default, so a truncated or half-written supply.json
    // read exactly like a fresh install: policy back to the defaults, the loop switched off, and the
    // tower back to the ground floor, with nothing anywhere reporting that a file had failed to
    // parse. Resetting the settlement is not a thing that should ever happen quietly.
    if ((err as NodeJS.ErrnoException)?.code !== 'ENOENT') {
      console.warn(`[supply] ${SUPPLY_FILE} could not be read -- STARTING FROM DEFAULTS, previous ` +
        `policy and tower progress are lost: ${(err as Error)?.message ?? err}`);
    }
    return base;
  }
}

export const supply: SupplyState = loadSupply();

/**
 * WHERE TO LOOK NEXT.
 *
 * The prospecting survey was dispatched as `{ w: 8, h: 8, radius: 8 }` -- a grid size and nothing
 * else. No region, no position. A scout given that scans wherever it happens to be standing, so
 * three scouts parked in three unrelated places rescanned the same ground indefinitely while the
 * map stayed blank everywhere they were not, and the loop dutifully reported "survey dispatched"
 * every time. Searching for something you have never seen without going anywhere new cannot work.
 *
 * A spiral outward from the base, one tile per dispatch, with the cursor persisted. It is not
 * clever, and that is the point: it is EXHAUSTIVE, it never revisits, it degrades gracefully if a
 * tile fails, and after N dispatches you can say exactly which ground the fleet has walked. A
 * cleverer heuristic that chases ore concentrations tends to circle the same promising area and
 * leave the rest of the world dark.
 */
/**
 * WHERE THE SETTLEMENT IS. NOT A CONSTANT -- IT MOVED, AND THIS DID NOT.
 *
 * These were the previous world's coordinates, left behind when the settlement was re-founded 400
 * blocks away. Every survey the loop dispatched aimed at ground the fleet could not reach and would
 * not have been chunk-loaded if it had, so the map stayed at zero known blocks while the loop
 * reported itself healthy. A hardcoded home is a bug waiting for the first time home changes.
 *
 * HIVE_BASE_X / HIVE_BASE_Z override it; the default is the tower's centre, and the region is
 * derived from the base rather than written out separately, so the two cannot drift apart.
 */
const BASE = settlement.base;
const TILE = 24;
/** How far out the fleet is allowed to work, as a radius from base. */
const REACH = settlement.reach;
const REGION = {
  minX: BASE.x - REACH, maxX: BASE.x + REACH,
  minZ: BASE.z - REACH, maxZ: BASE.z + REACH,
};

type Pt = { x: number; y: number; z: number };
function frontier(): { min: Pt; max: Pt } | null {
  // Walk the spiral from the start each time and take the nth valid tile. The spiral is a few
  // hundred steps at most, so recomputing costs nothing and needs no stored geometry -- only an
  // integer, which is what makes the cursor safe to persist across restarts and code changes.
  const want = supply.frontier ?? 0;
  let x = 0, z = 0, dx = 0, dz = -1, found = 0;
  for (let i = 0; i < 4096; i++) {
    const cx = BASE.x + x * TILE;
    const cz = BASE.z + z * TILE;
    const min = { x: cx - TILE / 2, y: 58, z: cz - TILE / 2 };
    const max = { x: cx + TILE / 2, y: 95, z: cz + TILE / 2 };
    // Only tiles wholly inside the loaded region. A survey ordered outside it sends a drone
    // somewhere it will stop ticking and be lost, which is a far worse outcome than a gap.
    if (min.x >= REGION.minX && max.x <= REGION.maxX
        && min.z >= REGION.minZ && max.z <= REGION.maxZ) {
      if (found === want) return { min, max };
      found++;
    }
    // Standard square spiral: turn at the corners.
    if (x === z || (x < 0 && x === -z) || (x > 0 && x === 1 - z)) { const t = dx; dx = -dz; dz = t; }
    x += dx; z += dz;
  }
  return null;
}



export function saveSupply(): void {
  try {
    mkdirSync(dirname(SUPPLY_FILE), { recursive: true });
    // EVERY FIELD THE STATE CLAIMS TO KEEP, NOT A HAND-PICKED THREE.
    //
    // This wrote { enabled, rules, dispatched } and silently dropped the rest, so anything added to
    // SupplyState afterwards was persisted in the type and nowhere else. `frontier` says
    // "Persisted -- see frontier()" in its own doc comment and never was; `towerLevel` and
    // `towerBatch` meant every HQ restart reset the tower to the ground floor and forgot which
    // floor it was measuring -- which is why the level could never advance across a redeploy, while
    // the code that advances it was working perfectly.
    //
    // A whitelist that must be edited whenever state is added is a silent-drop waiting to happen.
    // Name what is deliberately EXCLUDED instead: `log` is a rolling display buffer, and cooldowns
    // are wall-clock timers that mean nothing after a restart.
    const { log: _log, cooldowns: _cooldowns, ...persisted } = supply;
    writeFileSync(SUPPLY_FILE, JSON.stringify(persisted, null, 2));
  } catch (err) {
    console.error(`[supply] could not persist ${SUPPLY_FILE}: ${(err as Error).message}`);
  }
}

function note(msg: string) {
  supply.log.unshift(`${new Date().toISOString().slice(11, 19)} ${msg}`);
  supply.log.length = Math.min(supply.log.length, 40);
}

/** What each recurring condition last said, so an unchanged one is not re-reported. */
const s_LastNoted: Record<string, string> = {};

/**
 * REPORT A STANDING CONDITION ONCE, NOT ONCE A TICK.
 *
 * The supply log is forty lines deep and this loop runs every sixty seconds, so a condition that
 * persists -- "oak_planks is not craftable from what we have" -- would fill the entire log with
 * forty copies of itself inside an hour and evict every other thing that happened. That is how a
 * report becomes as useless as the swallow it replaced: not by being missing, but by being noise
 * nobody can read past.
 *
 * So: write it when it CHANGES. A condition that clears and returns is worth a second line; the
 * same condition ticking over is not.
 */
function noteOnce(key: string, msg: string) {
  if (s_LastNoted[key] === msg) return;
  s_LastNoted[key] = msg;
  note(msg);
}

/** The condition has cleared -- let the next occurrence report itself. */
function clearNote(key: string) {
  delete s_LastNoted[key];
}

async function callTool(name: string, args: unknown) {
  return registry.invoke(name, args, { agent: 'supply', callId: `supply-${Date.now()}`, log: () => {} });
}

/**
 * The two phases a settlement runs when it can afford to move: repair a shortfall that is blocking
 * a task, then top the queue up. Both RETURN EARLY the moment they do anything, which is why the
 * fuel gate must sit above them rather than below -- see the note at the call site.
 */
/**
 * Planting runs whatever the fuel state -- it is the one action that shortens every future run --
 * and the material phases only when fuel is not critical, because they are what spends it.
 */
async function materialPhases(
  live: any[], fuelCritical: boolean, queued: Set<string>,
): Promise<{ acted: boolean; reason: string } | null> {
  const planted = await plantForestry(queued);
  if (planted || fuelCritical) return planted;
  return (await replanShortfalls()) ?? (await topUpQueue(live));
}

/** One pass. Returns what it did, for the tool and the tests. */
/**
 * Total fleet fuel below which the supply loop dispatches nothing but coal.
 *
 * Three drones topping up to 2,500 each is 7,500, and the fleet burns roughly 120 fuel a minute
 * working. 4,000 leaves well over half an hour of margin to find, cut and carry coal home before
 * anything is actually at risk -- while being low enough that a healthy fleet still spends most of
 * its time on the other materials.
 */
const FUEL_PRIORITY_BELOW = 4000;

/** Fuel one coal yields when burned. A furnace-free settlement has no other conversion. */
const FUEL_PER_COAL = 80;

/**
 * RUNWAY, NOT TANK LEVEL. Total reachable energy below which nothing but coal gets dispatched.
 *
 * FUEL_PRIORITY_BELOW asks what is already in the drones and ignores the coal that refills them, so
 * a fleet holding one tankful with an empty warehouse reads as comfortable. Measured at the moment
 * this was added: 7,078 fuel onboard against 50 coal in storage -- about twenty minutes of flying,
 * and comfortably above the 4,000 tank threshold -- while the queue held ELEVEN tower-building
 * tasks against a single coal gather. The settlement was laying masonry while it starved.
 *
 * The fleet burns roughly 400 coal an hour, so 16,000 is about half an hour of runway: late enough
 * that a healthy settlement never sees it, early enough to still be able to fly out and fix it.
 * Both earlier repairs to this gate were the same mistake in a different input -- fuel counted
 * inside unreachable drones, then stock that could not be read. The number compared has to be the
 * number that decides whether the settlement lives.
 */
const RUNWAY_CRITICAL_BELOW = 16_000;

/**
 * What the fleet can still burn: fuel in the tanks plus fuel the warehouse can hand it.
 *
 * Exact names, NOT substring matching. `held()` matches by `includes`, and
 * 'minecraft:coal_ore'.includes('minecraft:coal') is true -- so a warehouse full of unsmelted ore
 * would read as a full fuel reserve and cancel the very emergency this exists to declare.
 */
export function fuelRunway(
  detail: any[], carried: Record<string, number>, fleetFuel: number,
): { coalReserve: number; runway: number; critical: boolean } {
  const exactStock = (name: string) =>
    detail.filter((d: any) => d.name === name).reduce((n: number, d: any) => n + (d.count ?? 0), 0)
    + (carried[name] ?? 0);
  const coalReserve = exactStock('minecraft:coal') + exactStock('minecraft:charcoal');
  const runway = fleetFuel + coalReserve * FUEL_PER_COAL;
  // Either test can declare the emergency: an empty tank is urgent even with coal in the chest
  // (the drone still has to reach it), and an empty warehouse is urgent even with full tanks.
  return {
    coalReserve, runway,
    critical: fleetFuel < FUEL_PRIORITY_BELOW || runway < RUNWAY_CRITICAL_BELOW,
  };
}

/**
 * Everything one rule's dispatch is allowed to see and change.
 *
 * The three `*Free` flags are deliberately MUTABLE and shared: each role may take one job per tick,
 * so a rule that dispatches a miner has to stop the next rule dispatching another one. They were
 * plain `let`s in a 450-line function, which is exactly the kind of state that is invisible until
 * it is wrong.
 */
export type SupplyCtx = {
  now: number;
  queued: Set<string>;
  did: string[];
  waiting: string[];
  minerFree: boolean;
  scoutFree: boolean;
  crafterFree: boolean;
  idleCrafter: unknown;
  held: (m: string) => number;
  fuelCritical: boolean;    // the tick's fuel emergency; lumber harvests leftover canopy under it
};

/**
 * Does gathering this material end in something the fleet can BURN?
 *
 * This test was `/coal/`, which is right only for a settlement whose coal is reachable. Ours is
 * not: 1,046 coal_ore locations are mapped and inside the operating circle, and every one of them
 * sits between y=27 and y=58 -- ten to forty blocks underground, where there is no GPS and no drone
 * can reliably navigate. Three drones stranded trying. Meanwhile 1,069 oak_log sit at y=64-70, on
 * the surface, in easy reach, and charcoal burns exactly as well as coal.
 *
 * So a fuel emergency that permits only `coal` forbids the fleet from fetching the one fuel it can
 * actually get to -- the gate starves the settlement it was written to save. Wood counts: logs are
 * the feedstock for charcoal, which is the renewable half of the fuel supply and the half that does
 * not require solving underground navigation first.
 */
export function producesFuel(match: string): boolean {
  return /coal|charcoal|_log|planks/.test(match);
}

/**
 * Why this rule is not dispatched this tick, or null to go ahead. PURE -- no I/O, no mutation.
 *
 * Extracted because the fuel-priority test could not reach it. That test re-implemented this
 * decision as a two-line copy and asserted against the copy, so it passed whatever supply.ts did:
 * a test shaped exactly like the bug it was written for, checking a duplicate of the code instead
 * of the code. It now imports this function.
 */
/** The storage chain: what a full shelf must still be allowed to make. */
export function makesStorage(match: string): boolean {
  return /oak_log|oak_planks|:chest$|^chest$/.test(match);
}
export function ruleSkipReason(
  rule: SupplyRule,
  gate: { fuelCritical: boolean; have: number; cooldownUntil: number; now: number; storageFull?: boolean },
): { kind: 'fuel' | 'satisfied' | 'cooldown' | 'full'; message?: string } | null {
  // Coal, charcoal or anything else that burns; everything else waits until the fleet can move.
  if (gate.fuelCritical && !producesFuel(rule.match)) return { kind: 'fuel' };

  // DO NOT MINE INTO A WAREHOUSE WITH NO ROOM IN IT.
  //
  // Storage sat at 0 free slots across 7 chests and 13,856 items, and the loop kept dispatching
  // gathers anyway -- including for DIRT, which has a rule of its own. The drones did exactly as
  // told: filled up, flew home, failed to deposit because there was no slot, retried, and ran dry
  // holding the load. Measured over one window: 221 coal burned, ZERO items deposited.
  //
  // Two of the fleet's drones were found stranded at 0 fuel carrying 170 and 274 items of dirt,
  // gravel and cobblestone respectively -- one of them the fleet's ONLY crafter, which is what
  // builds the chests that would have made room. The loop was starving the cure to feed the disease.
  //
  // Fuel is exempt: coal is burned, not shelved, so it is worth fetching with every slot full --
  // and it is what a drone needs to reach a chest at all. Everything else waits for room.
  // A full shelf stops everything EXCEPT fuel and the chain that makes more shelf: logs -> planks
  // -> chests -> a chest row. Gating those too (2026-09-05) was the deadlock: no logs, so no
  // planks, so no chests, so no new row, so the shelf stayed full and nothing else could run.
  if (gate.storageFull && !/coal/.test(rule.match) && !makesStorage(rule.match)) {
    return { kind: 'full', message: `${rule.match} (storage has no free slot)` };
  }
  if (gate.have >= rule.min) return { kind: 'satisfied' };
  // Say when a cooldown is the reason. Skipping silently makes "waiting a few minutes" look exactly
  // like "nothing to do", which is how idle drones and an empty log get read as a broken scheduler
  // rather than a timer.
  if (gate.cooldownUntil > gate.now) {
    const secs = Math.ceil((gate.cooldownUntil - gate.now) / 1000);
    return { kind: 'cooldown', message: `${rule.match} (${secs}s cooldown)` };
  }
  return null;
}

/**
 * Go and LOOK. gather can only revisit coordinates the map already holds, so a material that has
 * never been seen -- iron, at depth, below anything a surface scan can reach -- is unreachable by
 * any amount of gathering. This is the job that changes that.
 */
async function dispatchMine(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if (!ctx.minerFree) return false;
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  const r: any = await callTool('order.prospect', { depth: rule.depth ?? 40 });
  if (r?.ok === false) {
    note(`${rule.match}: ${have}/${rule.min}, prospecting refused — ${r?.error ?? '?'}`);
    return false;
  }
  ctx.minerFree = false;
  supply.dispatched++;
  supply.lastAction = `prospect for ${rule.match}`;
  note(`${rule.match}: ${have}/${rule.min} → prospecting at y=${rule.depth ?? 40}`);
  ctx.did.push(`prospect ${rule.match}`);
  return true;
}

async function dispatchCraft(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if ([...ctx.queued].some((n) => n.startsWith(`craft-${stockKey(rule).replace(/^.*:/, '')}`))) {
    note(`${rule.match}: ${have}/${rule.min}, already being crafted`);
    return false;
  }
  // Needs a crafter, not a miner. Nothing else can serve the job, so waiting for one is the correct
  // behaviour rather than dispatching it at a drone that will refuse at the last step.
  if (!ctx.idleCrafter) return false;               // no cooldown burned: retry when one frees up
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  // The TARGET, not the deficit. expand() already subtracts what storage holds, so passing
  // (target - have) subtracts the same stock twice: asking for "8 more chests" while holding 8
  // planned to zero steps and the loop reported "nothing craftable" with a full chest.
  const want = rule.limit ?? rule.min;
  const r: any = await callTool('plan.execute', { item: stockKey(rule), quantity: want });
  const steps = r?.data?.queued ?? r?.queued ?? [];
  if (!steps.length) {
    note(`${rule.match}: ${have}/${rule.min}, nothing craftable — ${JSON.stringify(r?.data?.unsourced ?? [])}`);
    return false;
  }
  ctx.crafterFree = false;
  supply.dispatched++;
  supply.lastAction = `craft ${stockKey(rule)}`;
  note(`${rule.match}: ${have}/${rule.min} → craft x${want} queued (${steps.length} steps)`);
  ctx.did.push(`craft ${stockKey(rule)}`);
  return true;
}

/**
 * Dig it if we know where it is; prospect if we have never seen it; survey if neither.
 *
 * The order matters and the last two rungs are not interchangeable. gather can only revisit
 * coordinates the map already holds, and a surface survey cannot reach ore at depth -- a scanner
 * sees 8 blocks and iron is fifty below. A material that has NEVER been seen is a prospecting
 * problem, not a gathering one. Without the prospect rung the loop fell straight through to "wait
 * for a scout" and sat there with three idle miners and coal at 0/32.
 */
/**
 * FELL AND REPLANT, WHICH IS THE ONLY WAY WOOD EVER BECOMES RENEWABLE.
 *
 * The drone has had a complete forestry harvester the whole time: OnLumber sweeps an area in a
 * serpentine, and for each trunk it meets fellTree() takes the whole tree, clears the canopy at
 * each level so the saplings drop while the drone is standing there to collect them, and REPLANTS
 * one before moving on. TaskMan already routes work.lumber to the "Lumber" verb.
 *
 * Nothing could ever ask for it. `action: 'lumber'` fell through dispatchRule to "not yet
 * automatable", so the rule was switched to `gather` -- which mines a single log block out of a
 * tree, leaves the rest standing, collects no sapling and replants nothing. That is strip-mining
 * a forest one block at a time, and it is why the settlement's wood supply only ever went down.
 *
 * This is the missing wire, and it is the difference between a settlement that consumes a forest
 * and one that farms it.
 *
 * Aimed at the DENSEST cluster rather than the nearest tree: the harvester sweeps an area, so its
 * value is trees-per-sweep, not distance to the first one. A sweep that meets six trunks pays for
 * the trip out; one that meets a single tree does not.
 */
async function dispatchLumber(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  // SAY WHY, EVEN WHEN THE ANSWER IS "NOT NOW".
  //
  // A bare `return false` here is the same invisible failure that cost this settlement most of a
  // session elsewhere: the tick prints its fuel-emergency line, the wood rule is skipped, and there
  // is nothing anywhere connecting the two. "No miner free" and "no trees known" need completely
  // different fixes and looked identical from outside.
  // Wood is the storage chain (logs -> planks -> chests -> a row). It is queued even with no miner
  // free, like coal: TaskMan serves it to the next miner that frees up and dedupes the repeat.
  // Waiting for a free miner first left the chest row without logs for a night (2026-09-05).
  if (!ctx.minerFree && !makesStorage(rule.match)) {
    ctx.waiting.push(`lumber ${rule.match}: no miner free`);
    return false;
  }

  // LEFTOVERS WHENEVER WOOD IS SHORT, NOT ONLY IN A FUEL EMERGENCY. With the emergency over the picker
  // went back to "no standing trees known -> survey" while 30 leftover logs stood inside the circle,
  // the chest craft sat short of planks, storage could not expand, and 4,394 stone filled every chest
  // to 27/27 (2026-09-04, overnight). This rule only runs when oak_log is below its minimum.
  const sweep = await queueLumberSweep(bridge, rule.match, 1, { leftovers: true });
  if (sweep.reason) {
    note(`${rule.match}: ${have}/${rule.min}, ${sweep.reason} -> survey`);
    return dispatchSurvey(rule, have, ctx);
  }

  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  ctx.minerFree = false;
  supply.dispatched++;
  const at = sweep.at!;
  supply.lastAction = `lumber at ${at.x},${at.y},${at.z}`;
  note(`${rule.match}: ${have}/${rule.min} -> lumber sweep at ${at.x},${at.y},${at.z} `
     + `(${sweep.trunks} trunks in range, fells and replants`
     + `${sweep.leftovers ? '; leftover canopy too -- fuel emergency' : ''})`);
  ctx.did.push(`lumber ${rule.match}`);
  return true;
}

async function dispatchGather(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  // Ask for the dig first, but only if a miner could actually take it.
  // FUEL ORE IS QUEUED EVEN WHEN NO MINER IS FREE. TaskMan ranks fuel work ahead of building and
  // hands it to the next miner that frees up; waiting for a free miner here meant that while every
  // miner was laying bricks the coal gather was never even queued, and the tick logged "coal_ore:
  // 161/800, none known -> survey" with 1,143 coal ore blocks in the index (2026-09-04).
  if (ctx.minerFree || producesFuel(rule.match) || makesStorage(rule.match)) {
    const r: any = await callTool('order.gather', { match: rule.match, limit: rule.limit ?? 64 });
    if (r?.ok !== false) {
      supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
      ctx.minerFree = false;
      supply.dispatched++;
      supply.lastAction = `gather ${rule.match}`;
      note(`${rule.match}: ${have}/${rule.min} → gather dispatched`);
      ctx.did.push(`gather ${rule.match}`);
      return true;
    }
  }

  if (ctx.minerFree && rule.depth !== undefined
      && ![...ctx.queued].some((n) => n.startsWith('shaft-'))) {
    supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
    const p: any = await callTool('order.prospect', { depth: rule.depth });
    if (p?.ok !== false) {
      ctx.minerFree = false;
      supply.dispatched++;
      supply.lastAction = `prospect for ${rule.match}`;
      note(`${rule.match}: ${have}/${rule.min}, none known -> prospecting at y=${rule.depth}`);
      ctx.did.push(`prospect ${rule.match}`);
      return true;
    }
    note(`${rule.match}: prospecting refused -- ${p?.error ?? '?'}`);
  }

  return dispatchSurvey(rule, have, ctx);
}

/** Last rung: nothing known and nothing to prospect for -- send a scout to look. */
/**
 * QUEUE A SURVEY AND MARK THE SCOUT SPENT.
 *
 * Three dispatch paths -- the exploration spiral, cave scouting and miner support -- each wrote
 * this bookkeeping out, and every line of it is load-bearing:
 *
 *   ctx.scoutFree = false   forgetting it dispatches the SAME scout to several tiles in one tick
 *   supply.dispatched++     and lastAction are the only evidence the loop is alive; without them
 *                           a working loop reads as idle, which is exactly what "autonomy has
 *                           died" looked like from outside while it was running fine
 *
 * radius 8 is the geo scanner's reach and is the same for all three: a survey box is scaffolding
 * for one scan sphere, not a resolution setting.
 */
async function queueSurvey(ctx: SupplyCtx, o: {
  name: string; priority: number; kind: string; box: { min: any; max: any };
  action: string; say: string;
}): Promise<void> {
  await bridge.call('TaskMan', 'Add', {
    name: o.name,
    priority: o.priority,
    work: { survey: { kind: o.kind, radius: 8, min: o.box.min, max: o.box.max } },
  }, { timeoutMs: 8000 });
  ctx.scoutFree = false;
  supply.dispatched++;
  supply.lastAction = o.action;
  note(o.say);
}

async function dispatchSurvey(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  // Say so rather than skipping in silence: "no scout free" and "nothing to do" are different
  // states and looked identical in the log.
  if (!ctx.scoutFree) {
    ctx.waiting.push(`${rule.match} (no scout free)`);
    return false;
  }
  supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
  let area = frontier();
  if (!area) {
    // WRAP, don't stop. The spiral walking off the edge of the loaded region is not the same as the
    // region being fully surveyed -- the cursor is a position, not a completion record, and a
    // survey that failed still advanced it. Left as a dead end the loop simply stopped exploring
    // for good, which is what happened here: the last prospecting run was two hours before anyone
    // noticed.
    supply.frontier = 0;
    area = frontier();
    if (!area) { note(`${rule.match}: no surveyable tile inside the loaded region`); return false; }
    note('exploration frontier wrapped -- starting another pass from the base outward');
  }
  supply.frontier = (supply.frontier ?? 0) + 1;
  await queueSurvey(ctx, {
    name: `find-${rule.match}`, priority: 3, kind: 'explore', box: area,
    action: `survey for ${rule.match}`,
    say: `${rule.match}: ${have}/${rule.min}, none known → survey tile ${supply.frontier} `
       + `at ${area.min.x},${area.min.z}..${area.max.x},${area.max.z}`,
  });
  ctx.did.push(`survey for ${rule.match}`);
  return true;
}

/** An ore that does not burn waits out a fuel emergency; coal does not wait -- see dispatchRule. */
function oreWaitsForFuel(match: string): boolean {
  return /_ore$/.test(match) && !producesFuel(match);
}
/** One rule, start to finish. Throwing is contained by the caller so one bad rule cannot end the tick. */
async function dispatchRule(rule: SupplyRule, have: number, ctx: SupplyCtx): Promise<boolean> {
  if (rule.action === 'mine') return dispatchMine(rule, have, ctx);
  if (rule.action === 'craft') return dispatchCraft(rule, have, ctx);
  if (rule.action === 'lumber') return dispatchLumber(rule, have, ctx);
  if (rule.action !== 'gather') {
    supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
    note(`${rule.match}: ${have}/${rule.min} → ${rule.action} not yet automatable`);
    return false;
  }
  // AN ORE GATHER IS UNDERGROUND, AND UNDERGROUND IS WHERE A DRONE CANNOT BE RESCUED.
  //
  // Below the surface there is no GPS, so the map cannot record what a miner clears and the ore
  // index only ever grows stale ("1/768 checked, 0 taken"); a drone that runs dry down there is
  // beyond every relief. During a fuel emergency the miner sent for coal is the LAST fuelled drone,
  // and this is how D40 was nearly lost twice in one evening: four minutes digging toward a
  // recorded coal_ore that was not there, then breaking off at 821 fuel under a floor of 838 with
  // no fix. Wood is on the surface, in GPS range, and verified standing before a sweep is ordered.
  // So while fuel is short the fleet fells, and ore waits.
  // COAL IS THE FUEL. This refused EVERY ore during a fuel emergency, coal included, because
  // underground is where a drone cannot be rescued -- and the emergency never ended, so the only
  // fuel source the fleet was allowed was wood 50 blocks away at 15 fuel a log, while the index knew
  // 1,143 coal ore blocks, 88 of them inside the circle at y 45-59 and the nearest vein 10 blocks
  // from the origin (2026-09-04). An ore that burns is fuel work; the others still wait.
  if (oreWaitsForFuel(rule.match) && (await fuelEmergency()) === true) {
    supply.cooldowns[rule.match] = ctx.now + COOLDOWN_MS;
    note(`${rule.match}: ${have}/${rule.min} -- not sending a miner underground during a fuel emergency; fuel first`);
    return false;
  }
  return dispatchGather(rule, have, ctx);
}

/**
 * What the failing tasks say they are short OF.
 *
 * Its own function because it is the one part of the re-plan with no I/O in it: a pure string ->
 * set, so the regex that has to match TaskMan's two phrasings can be exercised directly instead of
 * only through a live bridge.
 */
export function shortfallItems(tasks: unknown[]): Set<string> {
  const shortOf = new Set<string>();
  for (const t of tasks) {
    const why = String((t as any)?.failure ?? '');
    // "nothing available for: minecraft:oak_planks" / "short of minecraft:oak_log x8"
    const m = why.match(/(?:nothing available for|short of)\s*:?\s*([a-z0-9_]+:[a-z0-9_]+)/i);
    if (m) shortOf.add(m[1]);
  }
  return shortOf;
}

/**
 * Try to re-plan one shortfall. Returns how many steps were queued, or WHY none were.
 *
 * `number | string` rather than `number` and a swallowed catch: "not craftable from what we have"
 * and "plan.execute is throwing on everything" are different facts, and collapsing them into 0 is
 * what left a stuck queue looking like an idle one.
 */
async function attemptReplan(item: string): Promise<number | string> {
  try {
    const r: any = await callTool('plan.execute', { item, quantity: 16 });
    const rd = r?.data ?? r;
    const queued = (rd?.queued ?? []).length;
    return queued > 0 ? queued : `${item}: nothing queueable`;
  } catch (err) {
    return `${item}: ${(err as Error)?.message ?? err}`;
  }
}

/**
 * Read the queue's FAILURES back into the planner.
 *
 * Returns a tick result when it re-planned something -- the re-plan IS the action, so the tick
 * ends there -- or null to carry on with the rest of the pass.
 */
async function replanShortfalls(): Promise<{ acted: boolean; reason: string } | null> {
// A SHORTFALL FOUND AT RUNTIME IS A PLANNING INPUT, NOT JUST A FAILURE.
//
// plan.execute builds the dependency chain ONCE, from the stock it can see at that moment. When a
// craft later runs short -- because the intermediate got consumed, or the first pass only made a
// partial batch -- nothing notices. craft-chest sat "failing: nothing available for oak_planks"
// while sixteen oak logs sat in a chest and a crafter stood idle beside them: every fact needed to
// fix it was known, and no loop connected them. That is the whole point of having a tree.
//
// So read the failures and re-plan what they are short of. plan.execute is idempotent-ish (it
// queues nothing when stock already satisfies the goal) and dedupes by task name in TaskMan, so
// re-running it costs nothing when the answer has not changed.
try {
  const tl: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 5000 });
  const tasks = luaList(field(tl, 'tasks') ?? []) ?? [];
  // WHY THE RE-PLAN DID NOT HAPPEN IS THE ONLY INTERESTING PART OF THIS LOOP.
  //
  // The old comment here claimed "the failure stands and is reported as such" -- it did not.
  // Nothing recorded which item could not be re-planned or why, so a task stuck on
  // "nothing available for oak_planks" and a re-planner that threw on every attempt looked
  // identical from outside: a queue that never moves and a supply log that never mentions it.
  //
  // Per-item failures are expected (a material genuinely not craftable from current stock), so they
  // are collected rather than logged one by one, and reported ONCE when the whole pass came up
  // empty -- which is the case that means somebody has to intervene.
  const stuck: string[] = [];
  for (const item of shortfallItems(tasks)) {
    const r = await attemptReplan(item);
    if (typeof r === 'string') { stuck.push(r); continue; }
    supply.dispatched += r;
    clearNote('replan-stuck');
    note(`a task was short of ${item} -- re-planned it, ${r} step(s) queued`);
    return { acted: true, reason: `re-planned ${item} for a failing task` };
  }
  if (stuck.length) noteOnce('replan-stuck', `tasks short of material nobody can re-plan -- ${stuck.join('; ')}`);
  else clearNote('replan-stuck');
} catch (err) {
  note(`shortfall re-plan: ${(err as Error)?.message ?? err}`);
}
  return null;
}

/**
 * Which materials already have a gather in flight.
 *
 * ONE LIVE GATHER PER MATERIAL. TaskMan's name dedup only looks at tasks still queued, so once a
 * gather is ASSIGNED its name is free again -- and the top-up, running every sixty seconds,
 * cheerfully queued another. Ten identical gather:oak_log tasks piled up, each claiming a drone for
 * the same 192 candidates. That is worse than idling: the fleet looks fully occupied while several
 * drones re-walk ground another drone has already cleared.
 */
function materialsBeingGathered(tasks: unknown[]): Set<string> {
  const live = new Set<string>();
  for (const t of tasks) {
    const nm = String((t as any)?.name ?? '');
    if (nm.startsWith('gather:') && ((t as any).progress ?? 0) < 100) {
      live.add(nm.slice('gather:'.length));
    }
  }
  return live;
}

/**
 * Queue up to `wanted` gathers, and say what stopped the ones that did not happen.
 *
 * "NOTHING SURVEYED FOR IT" AND "THE TOP-UP IS BROKEN" LOOKED THE SAME FROM OUTSIDE.
 *
 * order.gather throws for an unsurveyed material, which is the expected answer for most of this
 * list most of the time -- so the catch was written empty and the loop moved on. But it caught
 * every other reason too, and the failure mode that matters is the one where drones sit idle, the
 * queue stays empty, and EVERY material threw: from outside that is indistinguishable from a
 * healthy fleet with nothing to do, which is exactly the diagnosis it got.
 *
 * The refusals are RETURNED rather than logged here, so the caller reports them once (noteOnce)
 * instead of writing eight routine lines into a forty-line log every sixty seconds.
 */
async function queueGathers(
  materials: string[], liveFor: Set<string>, wanted: number, idleCount: number, open: number,
): Promise<{ queued: number; refusals: string[] }> {
  let queued = 0;
  const refusals: string[] = [];
  for (const m of materials) {
    if (queued >= wanted) break;
    if (liveFor.has(m)) continue;          // already being worked; queuing another wastes a drone
    try {
      const g: any = await callTool('order.gather', { match: m, limit: 64 });
      if ((g?.data ?? g)?.dispatched) {
        queued++;
        supply.dispatched++;
        note(`${idleCount} drone(s) idle with ${open} unassigned task(s) -- queued gather:${m}`);
      } else {
        refusals.push(`${m}: not dispatched`);
      }
    } catch (err) {
      refusals.push(`${m}: ${(err as Error)?.message ?? err}`);
    }
  }
  return { queued, refusals };
}

/**
 * Top the queue up to the idle-drone count, so no drone is idle purely for want of a task.
 *
 * Returns a tick result when it queued something -- topping up IS the action for this tick -- or
 * null to carry on.
 */
async function topUpQueue(live: any[]): Promise<{ acted: boolean; reason: string } | null> {
// KEEP THE QUEUE AS DEEP AS THE FLEET.
//
// Every task takes exactly one drone, so a queue shorter than the idle count leaves the remainder
// standing still by arithmetic -- and this loop dispatched ONE thing per tick with cooldowns, which
// cannot keep up with a fleet that just grew from five drones to fifteen. Ten miners sat idle in a
// row, fighting each other for space, while the world was full of wood and ore nobody had been
// told to fetch. Idle is not a resting state here: it means the settlement has stopped growing.
//
// So: count the idle, count the queue, and top up from what the map actually knows about. Nothing
// speculative -- order.gather refuses anything unsurveyed and is region-filtered and nearest-first.
try {
  const idleCount = live.filter((d: any) => d.status === 'idle').length;
  if (idleCount > 0) {
    const tl: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 5000 });
    const tasks = luaList(field(tl, 'tasks') ?? []) ?? [];
    const open = tasks.filter((t: any) =>
      t && t.state !== 'done' && t.state !== 'failed' && !t.assigned).length;
    const wanted = idleCount - open;
    if (wanted > 0) {
      // Cycled, so one plentiful material cannot crowd out the rest of the economy.
      //
      // ONLY MATERIALS THE RULE TABLE SAYS TO *GATHER*.
      //
      // This list called order.gather directly, which quietly overrode how a material is meant to
      // be obtained. oak_log's rule says action: 'lumber' -- fell the tree, take the whole trunk,
      // replant -- and this queued a gather for it anyway every time a drone went idle, which is
      // constantly. The rule was never wrong; it was just never consulted here.
      //
      // The cost was the settlement's fuel supply. A wood gather walks scattered individual log
      // blocks, most of them canopy with no standable face: "gather: 1/192 checked, 0 taken",
      // measured repeatedly across four drones. A lumber sweep on the same trees returned 16 logs
      // and put a sapling back. The fleet ran the useless one for the entire session because this
      // loop kept queueing it and it outranked nothing else in the way.
      //
      // Two places decided how to obtain a material and they disagreed. Now there is one: the rule
      // table decides, and anything it does not mark for gathering is left to the rule that owns it.
      const gatherable = new Set(
        supply.rules.filter((r) => (r.action ?? 'gather') === 'gather').map((r) => r.match));
      const MATERIALS = ['oak_log', 'coal_ore', 'iron_ore', 'copper_ore',
                         'zinc_ore', 'lapis_ore', 'sand', 'gravel']
        .filter((m) => gatherable.has(m));

      // ONE LIVE GATHER PER MATERIAL.
      //
      // TaskMan dedupes by name only against tasks still QUEUED, so once a gather is assigned the
      // name is free again -- and this loop, running every sixty seconds, cheerfully queued
      // another. Ten identical gather:oak_log tasks piled up, each one claiming a drone for the
      // same 192 candidates, which is worse than idling: the fleet looks fully occupied while
      // several drones re-walk ground another drone already cleared.
      const liveFor = materialsBeingGathered(tasks);

      const { queued, refusals } = await queueGathers(MATERIALS, liveFor, wanted, idleCount, open);
      if (queued > 0) { clearNote('topup-refused'); return { acted: true, reason: `topped up the queue with ${queued} gather(s)` }; }
      if (refusals.length) {
        noteOnce('topup-refused',
          `${idleCount} drone(s) idle and nothing queueable -- ${refusals.join('; ')}`);
      }
    }
  }
} catch (err) {
  note(`queue top-up: ${(err as Error)?.message ?? err}`);
}
  return null;
}

/**
 * A cave is the best possible place to send a scanner: the ore is already EXPOSED, so a single
 * scan sees far more than the same scan in solid rock. world.caves had been finding them for a
 * long time and absolutely nothing consumed the result.
 */
/**
 * Pad a cave's bounding box outward.
 *
 * A scan centred inside an open pocket mostly reads air. The interesting part of a cave is the rock
 * AROUND it, which is where the exposed ore actually sits.
 */
function padCaveBox(c: any) {
  return {
    min: { x: c.min.x - 4, y: Math.max(0, c.min.y - 4), z: c.min.z - 4 },
    max: { x: c.max.x + 4, y: c.max.y + 4, z: c.max.z + 4 },
  };
}

/**
 * WHICH CAVES ARE WORTH SENDING A SCOUT TO. Pure, so the rule can be tested without a world.
 *
 * THE CAVE INDEX OUTLIVED THE REGION IT WAS BUILT IN. world.caves reads the block index, which
 * still holds pockets found when the operating area was a larger square. The drone is sent to
 * `cave.min`, and six of these sat in the queue targeting points 75-78 blocks out against a reach
 * of 56 -- permanently "could not reach the survey start", re-dispatched for ever, each attempt
 * spending a scout and its fuel on a trip that could not finish. Two had been retrying since task
 * #2919, and the newest was #4756: an open tap, not old debris.
 *
 * settlement.ts states the rule and place.ts obeys it; this path simply never asked. Check the
 * point the drone is actually SENT to, not the cave's centre -- a cave can straddle the boundary.
 */
export function caveCandidates(list: any[]): Array<{ cave: any; box: ReturnType<typeof padCaveBox> }> {
  const out: Array<{ cave: any; box: ReturnType<typeof padCaveBox> }> = [];
  for (const c of list ?? []) {
    if (!c?.min || !c?.max) continue;
    if (!withinReach(c.min)) continue;
    out.push({ cave: c, box: padCaveBox(c) });
  }
  return out;
}

async function dispatchCaveSurvey(ctx: SupplyCtx, c: any, box: any, pct: number): Promise<void> {
  await queueSurvey(ctx, {
    name: `cave-${c.min.x},${c.min.y},${c.min.z}`, priority: 2, kind: 'scout', box,
    action: `cave survey at ${c.min.x},${c.min.y},${c.min.z}`,
    say: `cave of ${c.size ?? '?'} cells at ${c.min.x},${c.min.y},${c.min.z} is ${pct}% mapped -> scout dispatched`,
  });
  ctx.did.push('cave survey');
}

/**
 * EXPLORE THE CAVES. Nobody was.
 *
 * world.caves has found them for a long time -- open pockets with an entrance, complete with their
 * bounding boxes -- and absolutely nothing consumed that. Every cave survey so far was dispatched
 * by hand. Meanwhile the exploration spiral sent scouts to tile solid rock in a fixed pattern,
 * which is the least informative ground there is.
 *
 * A cave is the best possible place to send a scanner: the ore is already EXPOSED, so a single scan
 * sphere reads far more usable material than the same sphere buried in stone, and a miner sent
 * afterwards can reach it without cutting a shaft to get there.
 */
async function surveyCaves(ctx: SupplyCtx): Promise<void> {
  if (!ctx.scoutFree) return;
  // THE TOWER IS THE SETTLEMENT'S PURPOSE; CAVES ARE FOR A SHAFT NOBODY IS DIGGING YET. With every
  // miner on lumber and coal (fuel work outranks building), scouts are the tower's only free hands
  // through anyoneForBuild -- and this sent them underground instead, where one was walled in for an
  // hour (D39, 2026-09-04). In the last hour TaskMan dispatched 1 build. Caves wait while patches queue.
  if ([...ctx.queued].some((n) => n.startsWith('tower-L'))) {
    ctx.waiting.push('cave survey: tower patches queued, scouts build first');
    return;
  }
  try {
    const caves: any = await callTool('world.caves', { min: 8 });
    for (const { cave, box } of caveCandidates(caves?.data?.caves ?? [])) {
      // PERCENT, NOT COVERAGE. `coverage` is a 0-1 fraction and this compares against 60, so the
      // guard could never pass even at 100% mapped -- every cave re-dispatched a survey on every
      // tick for ever. Same mistake at the scout-support guard below.
      const q: any = await callTool('world.query', box);
      const pct = q?.data?.percent ?? 0;
      if (pct >= 60) continue;                          // already read this one
      await dispatchCaveSurvey(ctx, cave, box, pct);
      break;                                            // one per tick
    }
  } catch (err) {
    note(`cave survey: ${(err as Error)?.message ?? err}`);
  }
}

/**
 * Pair a scout with a miner that is digging blind.
 *
 * A geo scanner sees eight blocks THROUGH rock, so a scout standing over a working miner is worth
 * more than one wandering the surface. This is the collaboration the fleet was supposed to have
 * and never did -- pairing existed only inside order.prospect.
 */
/**
 * Support tasks whose reason for existing has gone. PURE, so the rule is testable.
 *
 * scoutForMiners only ever creates support-X for a miner that is WORKING right now, which is
 * correct at creation -- and nothing ever retired them, so they outlived their target.
 *
 * Found live: all three open support tasks pointed at drones that were lost or idle. They are
 * queued at priority 1, AHEAD of exploration, and the settlement has exactly two scouts (role comes
 * from hardware -- a geo scanner -- so a miner cannot be promoted to cover). One of those two was
 * dry. So the single working scout was being pointed at priority-1 work supporting drones that had
 * stopped digging long ago, while eleven scout tasks sat queued. From outside, that reads as
 * "the scouts aren't helping".
 *
 * A task nobody can benefit from is worse than no task: it outranks the work that would have
 * helped.
 */
export function staleSupportTasks(
  tasks: Array<{ id: number; name?: string; progress?: number }>,
  drones: Array<{ name?: string; status?: string }>,
): number[] {
  const working = new Set(
    (drones ?? []).filter((d) => d?.status === 'working').map((d) => d.name),
  );
  return (tasks ?? [])
    .filter((t) => String(t?.name ?? '').startsWith('support-'))
    .filter((t) => (t?.progress ?? 0) < 100)
    .filter((t) => !working.has(String(t.name).slice('support-'.length)))
    .map((t) => t.id);
}

/**
 * Retire support work whose target stopped mining.
 *
 * Runs BEFORE more scout work is dispatched. These tasks sit at priority 1, so a stale one outranks
 * every useful scout job in the queue -- and with two scouts in the entire settlement that is the
 * difference between scouts helping and scouts appearing to do nothing.
 *
 * Best effort throughout: cleanup must never be the thing that breaks a supply tick.
 */
async function retireStaleSupport(live: any[], did: string[]): Promise<void> {
  try {
    const all: any = await callTool('fleet.tasks', {});
    const stale = staleSupportTasks(all?.data?.tasks ?? [], live);
    if (!stale.length) return;
    await callTool('task.stop', {
      id: stale.slice(0, 32),
      reason: 'the drone this supported is no longer working -- priority-1 work with no customer',
    });
    note(`retired ${stale.length} stale support task(s)`);
    did.push(`retired ${stale.length} stale support`);
    clearNote('retire-support');
  } catch (err) {
    // NOT "best effort". This is task.stop, and task.stop is the tool that returned ok:true while
    // 25 tasks went on being dispatched for two hours -- the failure this whole file is written
    // against. Swallowed here, a stale priority-1 support task keeps outranking every useful scout
    // job for ever and the only symptom is "the scouts aren't helping", which is what it was
    // diagnosed as. Cleanup may still fail without ending the tick; it may not fail quietly.
    noteOnce('retire-support', `could not retire stale support work -- ${(err as Error)?.message ?? err}`);
  }
}

async function scoutForMiners(ctx: SupplyCtx): Promise<void> {
// SEND A SCOUT TO WHERE THE MINERS ARE DIGGING BLIND.
//
// This is the collaboration the fleet was supposed to have and never did. Pairing existed only
// inside order.prospect -- a shaft task with a scan task depending on it -- so a miner working
// anywhere else dug through rock nobody had ever scanned while idle scouts were dispatched to
// survey tiles chosen by a spiral that knew nothing about where the fleet actually was. D13
// spent its shift surrounded by unknown terrain with scouts free the whole time.
//
// A geo scanner sees eight blocks THROUGH rock. A scout standing over a working miner is worth
// far more than the same scout surveying open ground on the other side of the base, because what
// it reveals is immediately actionable: the miner turns toward ore instead of past it, and does
// not have to turn at all where the map already answers.
if (ctx.scoutFree) {
  try {
    const fleet: any = await callTool('fleet.status', {});
    const miners = (fleet?.data?.drones ?? []).filter(
      (d: any) => d.role === 'miner' && d.status === 'working' && d.pos?.x !== undefined);

    for (const m of miners) {
      // How well is the ground around this miner mapped? A 24-block box centred on it.
      const half = 12;
      const box = {
        min: { x: m.pos.x - half, y: Math.max(0, m.pos.y - 8), z: m.pos.z - half },
        max: { x: m.pos.x + half, y: m.pos.y + 8, z: m.pos.z + half },
      };
      const q: any = await callTool('world.query', box);
      const cov = q?.data?.percent ?? 0;   // percent: see the cave guard above
      if (cov >= 25) continue;          // already mapped well enough to be useful

      await queueSurvey(ctx, {
        name: `support-${m.name}`,
        priority: 1,                    // ahead of speculative exploration: this has a customer
        kind: 'assist', box,
        action: `scout support for ${m.name}`,
        say: `${m.name} is mining at ${m.pos.x},${m.pos.y},${m.pos.z} with ${cov}% of the `
           + `surrounding rock mapped → scout dispatched to support it`,
      });
      ctx.did.push(`scout support for ${m.name}`);
      break;                            // one per tick; the next tick takes the next miner
    }
  } catch (err) {
    note(`scout support: ${(err as Error)?.message ?? err}`);
  }
}
}

/**
 * The set of task names already outstanding, or a refusal.
 *
 * NOT KNOWING what is queued is a reason to WAIT, not to proceed -- so this returns an explicit
 * refusal rather than an empty set. Treating an unreadable queue as an empty one is how the
 * duplicates got created in the first place.
 */
async function buildQueuedSet(): Promise<{ queued: Set<string> } | { refuse: string }> {
// WHAT IS ALREADY QUEUED.
//
// The cooldown stops a material being re-dispatched every tick, and it does NOT stop the queue
// filling with duplicates over hours: each cooldown expiry adds another identical survey while
// the first one is still waiting for the single scout to become free. Seven copies of
// "find-coal_ore" piled up that way, so the queue looked busy and nothing was being achieved --
// there was one scout and eight jobs that all needed one.
//
// A shortage that already has work outstanding does not need more work; it needs the work to
// finish.
const queued = new Set<string>();
try {
  const res: any = await bridge.call('TaskMan', 'GetTasks', {}, { timeoutMs: 15000 });
  // luaList, not Array.isArray. An EMPTY task queue serialises to {} rather than [], so the
  // array check classed it unreadable -- and the loop then refused to dispatch, which kept the
  // queue empty, which kept it refusing. On a fresh world nothing could ever start.
  const list = luaList<any>(field(res, 'tasks'));
  // A REFUSAL COMES BACK AS A VALUE, NOT AN EXCEPTION.
  //
  // PowNet puts an error in the same field a success uses, so a failed GetTasks arrives as a
  // plain string -- and `undefined?.tasks ?? []` then iterates nothing, leaving the dedup set
  // empty with no error raised anywhere. Dedup silently switched itself off and the queue filled
  // with nine copies of the same two surveys. An empty result and an unreadable one look
  // identical and mean opposite things, so they must be told apart explicitly.
  if (list === null) {
    return { refuse: `cannot read the task queue (${typeof res === 'string' ? res : typeof res}); not dispatching blind` };
  }
  // Prefer the COMPLETE name list over the paged task objects. TaskMan caps the task array to
  // stay inside the websocket frame, so counting names from that page under-reports duplicates and
  // the loop cheerfully adds another copy of work already outstanding -- nine find-iron_ore among
  // 159 live tasks with two assigned. The cap was mine and so was the regression.
  const names = luaList<string>(field(res, 'liveNames'));
  if (names && names.length) {
    for (const n of names) if (typeof n === 'string') queued.add(n);
  } else {
    for (const t of list) {
      if ((t?.progress ?? 0) < 100 && typeof t?.name === 'string') queued.add(t.name);
    }
  }
} catch {
  // NOT KNOWING what is queued is a reason to WAIT, not to proceed.
  //
  // Treating an unreadable queue as an empty one is how duplicates got created in the first
  // place: every tick that could not reach TaskMan cheerfully added another survey for a
  // shortage that already had three. A tick skipped costs a minute; a tick that dispatches blind
  // costs a drone and clogs the queue behind it.
  return { refuse: 'cannot read the task queue; not dispatching blind' };
}
  return { queued };
}

/**
 * A SETTLEMENT THAT RUNS OUT OF SLOTS MUST BUILD MORE, NOT STOP.
 *
 * Storage reached 7 chests and ZERO free slots, and everything downstream jammed at once in a way
 * that reads as several unrelated faults: a miner cannot unload, so it cannot pick up coal, so fuel
 * relief fails with "storage had nothing burnable" while 391 coal sits in a chest; a gather returns
 * "took nothing"; a craft cannot bank its output. None of those are the bug. The bug is that the
 * settlement noticed it was full and did nothing about it, and waited for a human to notice.
 *
 * Being full is a SHORTAGE like any other, and the loop already knows how to answer a shortage --
 * it just had no rule that could say "short of somewhere to put things". This is that rule.
 *
 * chest-row is deliberately the cheapest blueprint there is: bare chests, no floor, no modems. A
 * jam is exactly when the settlement cannot afford anything that needs planks, because planks need
 * logs and a log needs a free slot to be deposited into.
 */
const FREE_SLOTS_FLOOR = 6;

/**
 * Free slots across every chest the fleet can actually see, or null when it has seen none.
 *
 * null is NOT zero, and the difference decides whether the settlement starts building: a fresh
 * world with no chest readings yet looks identical to a jammed one if you let an empty list total
 * to zero, and the answer to "we have no readings" is to wait, not to build.
 */
async function observedFreeSlots(): Promise<number | null> {
  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  const chests = luaList<any>(field(stock, 'chests')) ?? [];
  if (!chests.length) return null;
  return chests.reduce((n: number, c: any) => n + (Number(c.free) || 0), 0);
}

/**
 * Is there anywhere to PUT what a gather brings back?
 *
 * An UNKNOWN is not a FULL. If StorageMan cannot be asked, `observedFreeSlots` returns null, and
 * halting the fleet on a failed status call would turn one unreachable module into a total work
 * stoppage -- the same class of bug as counting lost drones' fuel as available. So an unreadable
 * warehouse falls through to the old behaviour and the fleet keeps working.
 */
async function storageHasNoRoom(): Promise<boolean> {
  const free = await observedFreeSlots();
  // "No room" at the same floor expansion uses, not at zero: with 2 free slots the field-cache hauls
  // still ran and every deposit behind them failed (2026-09-04, 22:50).
  const noRoom = free !== null && free <= FREE_SLOTS_FLOOR;
  if (noRoom) note(`storage down to ${free} free slot(s) -- gathering only fuel until there is room`);
  return noRoom;
}

/**
 * A drone is live only if it is neither FLAGGED offline nor REPORTING an offline-ish status.
 * Checking the flag alone let a dead drone count as "busy", and one dead drone stalled the whole
 * loop -- the supply tick concluded somebody was already working and did nothing, for hours.
 */
function offlineish(d: any): boolean {
  return d.offline === true || d.status === 'offline' || d.status === 'lost';
}

/**
 * KEEPING THE PLACE RUNNING, BEFORE ANY NEW WORK IS CONSIDERED.
 *
 * Both of these are about material the settlement ALREADY has and cannot use: somewhere to put
 * things, and going to fetch what was left in the field. Neither produces anything new, and both
 * must beat speculative gathering -- there is no point mining more ore into a full bay, or felling
 * more trees while the last load sits in a box nobody opened.
 *
 * First one to act wins the tick, which is the same rule the rest of the loop follows.
 */
async function maintenancePhases(
  live: any[], queued: Set<string>,
): Promise<{ acted: boolean; reason: string } | null> {
  return (await expandStorageIfFull(live, queued))
    ?? (await bringFactoriesOnline())
    ?? (await runFactories(queued))
    ?? (await keepTowerOrdered(live, queued))
    ?? (await repairLowerFloors(queued))
    ?? (await collectFieldCaches(live, queued));
}

/**
 * Should this line be asked to make more right now? Its own predicate so runFactories reads as the
 * loop it is. An outstanding craft is the real answer to "did I already ask for this" -- a fact
 * about the queue rather than a guess from a timer, which is the reasoning mayQueue exists for.
 */
function factoryNeedsRun(p_F: any, p_Short: string, p_Have: number, p_Queued: Set<string>): boolean {
  if (p_Have >= FACTORY_TARGET) return false;
  if ([...p_Queued].some((n) => n.startsWith(`craft-${p_Short}`))) return false;
  return mayQueue(p_Queued, `craft-${p_Short}`, `__factory_${p_F.name}`);
}

/** What a line keeps on the shelf before it stops making more. */
const FACTORY_TARGET = 64;

/**
 * MAKE A RUNNING FACTORY ACTUALLY PRODUCE SOMETHING.
 *
 * `running` was a label on a data model and nothing else. Every place factory state was read did
 * one of two things -- wire up a planned line, or sort the dependency order -- and NOTHING walked a
 * running line to move material through it. factory.route returned {}, links were empty, and the
 * Lua side mentions factories only in comments. So planks-01 and charcoal-01 sat `running` and
 * produced nothing; what actually made planks and charcoal was ordinary craft tasks and
 * StorageMan's furnaces, entirely outside the subsystem meant to own them.
 *
 * That is the same defect this project keeps hitting from the other side: a status that reports
 * success without the effect existing. Reporting them "live" on the strength of the field was
 * wrong, and this is the fix -- the line now drives the work.
 *
 * plan.execute rather than a bespoke queue: it already walks the recipe graph, subtracts what
 * storage holds and queues the steps in dependency order. A factory says WHAT to keep in stock;
 * the existing machinery decides how. That also means a factory added later needs no new supply
 * rule -- which is the point of having factories at all.
 */
async function runFactories(queued: Set<string>): Promise<{ acted: boolean; reason: string } | null> {
  const live = factories.filter((f: any) => f.status === 'running' && f.produces);
  if (!live.length) return null;

  // AN UNREADABLE STOCK IS NOT AN EMPTY ONE.
  //
  // This swallowed its rejection into a null with `?? []` behind it -- the readStock('empty') defect
  // exactly: StorageMan times out, `have()` answers 0 for every item, every running line looks
  // starved, and the loop queues a craft for material already sitting on the shelf. The false
  // premise then propagates -- plan.execute subtracts a stock of zero and queues the whole
  // dependency chain underneath it too.
  //
  // A line that cannot be measured must not be dispatched for. Say so and do nothing this tick.
  // null, not a tick result: the later phases (tower, field caches) do not depend on this read and
  // should still get their turn. What must not happen is dispatching ON a stock of zero.
  const detail = await readStockDetail((why) => note(`factories: storage unreadable -- ${why}`));
  if (!detail) return null;
  const have = (item: string) =>
    detail.filter((d: any) => d?.name === item).reduce((n: number, d: any) => n + (d.count ?? 0), 0);

  for (const f of live as any[]) {
    const short = f.produces.replace(/^.*:/, '');
    if (!factoryNeedsRun(f, short, have(f.produces), queued)) continue;

    const r: any = await callTool('plan.execute', { item: f.produces, quantity: FACTORY_TARGET });
    const steps = r?.data?.queued ?? r?.queued ?? [];
    supply.cooldowns[`__factory_${f.name}`] = Date.now() + COOLDOWN_MS;
    if (!steps.length) continue;      // nothing craftable right now; try the next line
    supply.dispatched++;
    supply.lastAction = `factory ${f.name}`;
    saveSupply();
    return { acted: true, reason: `${f.name} making ${short} (${steps.length} step(s))` };
  }
  return null;
}

/** Blocks a batch must actually PLACE to count as progress. Below this, the floor is done. */
const FLOOR_PROGRESS_MIN = 8;

/**
 * Floor material on the shelves, or null when storage cannot be read -- never a guess.
 *
 * The null is load-bearing and the caller respects it, but the REASON for it used to be swallowed
 * by the read, so "storage timed out" and "storage holds no bricks" arrived at keepTowerOrdered as
 * the same value with nothing anywhere to tell them apart. The `note` callback is that reason.
 */
/**
 * BLOCKS ACTUALLY PLACED, NOT MATERIAL THAT LEFT THE SHELVES.
 *
 * This asked storage how much floor material it held and treated a drop as "blocks were placed".
 * It is not the same thing and the difference stalled the tower: measured 79 units gone from
 * storage with 66 of them sitting in drone inventories -- carried out to squares that turned out to
 * be already occupied, and carried back. Material moves for crafting, hauling and carrying; only
 * placing puts it in the world.
 *
 * TaskMan now keeps the true count, fed by the `placed` figure OnBuild has always returned and
 * always thrown away. Null when it cannot be read -- an unknown, never a zero, because "nothing was
 * placed" is exactly the answer that advances a floor and skips it for good.
 */
async function blocksPlacedTotal(): Promise<number | null> {
  const r: any = await bridge.call('TaskMan', 'GetTasks', { limit: 1 }, { timeoutMs: 8000 })
    .catch((err) => {
      note(`tower: cannot read placed count -- ${(err as Error)?.message ?? err}`);
      return null;
    });
  if (r === null) return null;
  const n = Number(field(r, 'placedTotal'));
  return Number.isFinite(n) ? n : null;
}

/**
 * KEEP A FLOOR IN FRONT OF THE FLEET, AND MOVE UP WHEN ONE IS DONE.
 *
 * Nothing queued tower work by itself. A human ran order.tower, the patches drained, and the fleet
 * went idle in front of an empty queue until somebody noticed -- which is not a settlement that
 * builds itself, it is one that waits to be told. Worse, the obvious fix of re-issuing on a timer
 * is what a monitor was doing earlier: it re-queued the whole floor every three minutes, which
 * churned the queue and cancelled work already in flight.
 *
 * So: order only when there is nothing left of this floor to do. `queued` is the live task list,
 * which is a FACT about the queue rather than a guess from a timer -- the same reasoning mayQueue
 * uses. When a level stops yielding patches it is finished (or unaffordable), and the next one
 * becomes the target.
 */
/**
 * Did the last batch of patches for this floor consume any floor material?
 *
 * An unreadable stock is an UNKNOWN, not a zero: both readings must exist before their difference
 * means anything. Coercing a missing number to 0 here would read as "consumed nothing" and advance
 * the floor on a storage hiccup -- the same shape as every other silent fallback that has cost this
 * project a night.
 */
function batchPlacedNothing(p_Level: number, p_Held: number | null): boolean {
  const last = supply.towerBatch;
  if (!last || last.level !== p_Level) return false;
  if (p_Held === null || last.held === null) return false;
  // PLACED COUNTS ONLY RISE, so the sign flips: progress is now-minus-then, not then-minus-now.
  return p_Held - last.held < FLOOR_PROGRESS_MIN;
}

/**
 * Has the current batch had a fair chance to consume anything?
 *
 * Without this the level would advance the instant a batch was queued, because nothing has been
 * placed yet at that moment -- "consumed nothing" and "has not started" look identical from the
 * material count alone. A patch takes minutes: travel, pickup, then a placement per block.
 */
function batchHasHadLongEnough(): boolean {
  const at = supply.towerBatch?.at;
  if (at === undefined) return false;      // no timestamp: cannot judge, so do not
  return Date.now() - at > BATCH_GRACE_MS;
}

/** Long enough for a batch of patches to travel, collect and place. Shorter and a fresh batch
 *  reads as a finished floor; much longer and a genuinely finished floor sits blocked for no gain. */
const BATCH_GRACE_MS = 8 * 60 * 1000;


/**
 * Has this floor stopped changing the world? Both halves of the question in one place: the batch
 * consumed no floor material, AND it has had long enough to have consumed some.
 */
function floorIsFinished(p_Level: number, p_Held: number | null): boolean {
  return batchPlacedNothing(p_Level, p_Held) && batchHasHadLongEnough();
}

/**
 * Begin measuring a floor that already has work outstanding, if nobody is measuring it.
 *
 * A batch used to be recorded only at the moment of ORDERING, and ordering waits for an empty
 * queue -- so a queue full of no-op patches produced no batch, nothing to judge, and therefore
 * nothing that could ever empty it. Returns null when there is nothing to start.
 */
function startWatchingFloor(
  p_Level: number, p_Held: number | null, p_StillQueued: boolean,
): { acted: boolean; reason: string } | null {
  if (!p_StillQueued) return null;
  if (supply.towerBatch?.level === p_Level) return null;
  supply.towerBatch = { level: p_Level, held: p_Held, at: Date.now() };
  saveSupply();
  return { acted: true, reason: `watching level ${p_Level}: ${p_Held ?? '?'} floor material held` };
}

/** Move to the next floor and forget the batch. One place, so the two exits cannot drift apart. */
async function advanceFloor(p_Level: number, p_Why: string): Promise<{ acted: boolean; reason: string }> {
  supply.towerLevel = p_Level + 1;
  supply.towerBatch = undefined;
  saveSupply();

  // A FINISHED FLOOR'S LEFTOVERS MUST GO WITH IT.
  //
  // Ordering the next floor waits for an empty tower queue, and a floor is declared finished
  // precisely BECAUSE its remaining patches place nothing -- so those patches would sit there for
  // ever, refusing every block as already-occupied, and level 1 could never be ordered. Measured
  // straight after the first successful advance: towerLevel 1 with 39 tower-L0 patches still
  // queued, and nothing able to progress.
  //
  // Best effort by design: failing to clear them costs a delay, not correctness, and the next pass
  // tries again. But it is REPORTED, because "the tower silently stopped climbing" is the exact
  // symptom this whole chain exists to prevent.
  const cleared = await stopTasksNamed(`tower-L${p_Level}-`);
  if (cleared > 0) note(`level ${p_Level} finished -- cleared ${cleared} leftover patch(es)`);

  return { acted: true, reason: `${p_Why} -- moving to ${p_Level + 1}` };
}

/**
 * Stop every queued task whose name starts with the prefix. Returns how many actually stopped.
 *
 * ONE CALL, BECAUSE ENUMERATING THE QUEUE FROM OUT HERE CANNOT BE MADE TO WORK.
 *
 * This used to read fleet.tasks, filter by name, and send the ids back to task.stop. Every layer of
 * that has a window in it: TaskMan caps GetTasks at 40 tasks to fit the websocket frame, fleet.tasks
 * caps the live list at 60, and task.stop's id array is capped at 32. With 131 tower-L0 patches
 * queued the loop saw 37, stopped some of them, and reported success -- so a finished floor's
 * leftovers could never be cleared, and clearing them is the only thing that lets the next floor be
 * ordered. The tower sat at level 0 behind 131 dead patches while every log line said the clear had
 * worked. Three separate caps, none of them wrong on its own, and a caller that could not see any
 * of them.
 *
 * task.stopNamed asks TaskMan to do it in its own store, where there is no window between deciding
 * and acting. The count comes back from what it actually marked.
 */
async function stopTasksNamed(p_Prefix: string): Promise<number> {
  const ctx = { agent: 'supply', callId: `supply-clear-${Date.now()}`, log: (m: string) => note(`clear: ${m}`) };
  try {
    const res: any = await registry.invoke('task.stopNamed',
      { prefix: p_Prefix, reason: 'floor finished -- these patches place nothing' }, ctx);
    // SAY WHY NOTHING WAS CLEARED. A bare 0 conflates "the call failed" with "there was nothing to
    // clear", and the first is a bug while the second is routine. This function committed exactly
    // that fault on its first outing: it cleared nothing, said nothing, and the leftovers sat there
    // blocking the tower with no trace of why.
    if (res?.ok === false) {
      note(`could not clear ${p_Prefix} patches -- ${res?.error ?? 'refused'}`);
      return 0;
    }
    const data = res?.data ?? res;
    const stopped = Number(field(data, 'stopped') ?? 0);
    if (!stopped) note(`clearing ${p_Prefix}: nothing matched among ${field(data, 'scanned') ?? '?'} task(s)`);
    return stopped;
  } catch (err) {
    note(`could not clear ${p_Prefix} patches -- ${(err as Error)?.message ?? err}`);
    return 0;
  }
}

/**
 * Ask order.tower for this floor, and say WHICH answer came back.
 *
 * A rejection and an empty result are different facts and must not arrive as the same value: the
 * caller treats "no tasks" as "floor finished, move up", and a floor advanced past is never
 * revisited. Returning `{ failed }` rather than a null keeps that distinction at the type level, so
 * the caller cannot accidentally read a failure as a completion.
 */
/**
 * The palette stays `brick`, and a note about why it is not chosen dynamically.
 *
 * A tier-fallback was written here on the theory that the tower was stalled for want of stone bricks
 * -- drones were logging `ran out of minecraft:stone_bricks` and `fetch: storage holds none of it`.
 * Storage in fact held 575 stone bricks and 77 cobblestone, so `cobble` was the tier that could not
 * be supplied and the fallback would have made things worse on any transient dip. The failing
 * fetches were for GLASS PANES, of which the settlement has none and a floor needs twelve.
 *
 * The lesson is the repo's own: measure the thing, not something adjacent to it. "A build ran out of
 * bricks" is not "storage has no bricks", and one storage read would have said so.
 */
async function orderFloor(p_Level: number): Promise<{ res: unknown } | { failed: string }> {
  const ctx = {
    agent: 'supply',
    callId: `supply-tower-${Date.now()}`,
    log: (m: string) => note(`tower: ${m}`),
  };
  try {
    return { res: await registry.invoke('order.tower',
      // 96, not 32: a patch pays a FIXED cost -- fly from the shelf to the floor, and the gap back to
      // it before the next patch -- whatever its size. Measured on D4 (2026-09-05): a build's first 8
      // squares took ~220 game-s (the fly-out) while a mid-build run of 8 took ~55; between builds sat
      // a ~490 game-s gap returning and refetching. Over a 295s window that overhead held the builder
      // to 21 blocks/min while its best contiguous stretch ran at 31. A turtle carries ~700 items, so
      // 96 bricks is two slots -- amortising the fly-out over 3x the blocks, not straining the load.
      // (Was 8 when relief preemptions cut jobs short; 32 once the shelf was stocked.)
      { level: p_Level, palette: 'brick', blocksPerTask: 96 }, ctx) };
  } catch (err) {
    return { failed: (err as Error)?.message ?? String(err) };
  }
}

/**
 * What the fleet can actually burn. MUST TRACK CollectFuel's LIST IN DroneLogic.
 *
 * "What counts as fuel" now has to be answered on both sides of the bridge, and this repo has been
 * bitten five times by two answers that disagreed. There is no way to share the predicate across
 * Lua and TypeScript, so it is asserted equal instead -- see fuel-fetchable.test.ts.
 */
const BURNABLE = /coal|_log|planks/;

/** Enough burnable material that stopping to refuel is not the fleet's most urgent problem. Sized
 *  against TaskMan's FUEL_COMFORTABLE, which means the same thing on the other side.
 *
 *  64 -> 160. Sixty-four is one stack: a single drone's top-up to REFUEL_TARGET takes twenty of it,
 *  and a relief takes a whole stack. So at 64 the tower was "not in an emergency", batched a floor,
 *  and the first drone to refuel put the settlement straight back under the line -- every bootstrap
 *  of 192 coal went into tanks and travel with the tower running the whole way down. Seven tanks at
 *  1,600 are 140 coal; the line has to sit above what the fleet itself absorbs before building is
 *  affordable, or "not an emergency" is a statement about the next sixty seconds. */
const FUEL_EMERGENCY_BELOW = 160;

/**
 * Is the settlement out of fuel? `null` when storage could not be read -- which must NOT read as an
 * emergency, or one unreadable poll stops the tower for a cooldown.
 */
// AN UNREADABLE SHELF DOES NOT END AN EMERGENCY. One tick at 23:32 got no answer from
// StorageMan.stock; every caller read the null as "no emergency", and in that tick HQ queued a
// haul of a cache at y=8 -- 56 blocks underground -- which went to the crafter carrying the
// fleet's last tank (2026-09-04). The last answer we did get is the honest fallback; null still
// goes back to callers that want to know the read failed.
let lastEmergency: boolean | null = null;
async function fuelEmergency(): Promise<boolean | null> {
  const burnable = await readStockWhere((n) => BURNABLE.test(n),
    (why) => note(`tower: cannot read fuel stock (${why}) -- keeping the last answer (${lastEmergency ?? 'none'})`));
  if (burnable === null) return lastEmergency;
  if (burnable < FUEL_EMERGENCY_BELOW) {
    note(`fuel emergency: ${burnable} burnable in storage (below ${FUEL_EMERGENCY_BELOW})`);
    lastEmergency = true;
    return true;
  }
  lastEmergency = false;
  return false;
}

/** The floor a queued tower task belongs to, or null if the name does not carry one. */
function taskLevel(p_Name: string): number | null {
  const m = /^tower-L(\d+)-/.exec(p_Name);
  return m ? Number(m[1]) : null;
}

/**
 * Split the queued tower work into "this floor's" and "a floor we already moved past".
 *
 * An unparseable name counts as the current floor: a tower task nobody can place is work in
 * progress, not scrap, and guessing "stale" would have it stopped.
 */
export function towerWorkFor(p_Queued: Set<string>, p_Level: number): { stillQueued: boolean; stale: string[] } {
  const tower = [...p_Queued].filter((n) => n.startsWith('tower-'));
  // An unparseable name counts as the CURRENT floor: a tower task nobody can attribute is work in
  // progress, not scrap, and guessing "stale" would have it stopped.
  const at = (n: string) => taskLevel(n) ?? p_Level;
  // ANY floor that is not the one being built is a leftover -- ABOVE as well as below.
  //
  // This tested `< p_Level`, on the assumption the counter only ever goes up. It does not: the
  // counter can be corrected downwards, which is the whole point of supply.set towerLevel, and the
  // moment it was -- from 3 back to 0, to rebuild floors that had been skipped -- level 3's 236
  // patches became work for a floor nobody was building. Ordering waits for an empty tower queue,
  // so they blocked level 0 exactly as thoroughly as the below-level leftovers had, and the filter
  // written for that bug could not see them because they were on the wrong side of it.
  // Patches BELOW the current level are repairs (repairLowerFloors), not leftovers: only a patch
  // for a level the counter has not reached yet is out of place.
  return { stillQueued: tower.some((n) => at(n) === p_Level), stale: tower.filter((n) => at(n) > p_Level) };
}

/**
 * How many of this floor's patches are still outstanding -- COUNTED IN TASKMAN, not inferred from
 * the queue snapshot. `null` if it could not be counted, which must not be read as zero.
 *
 * The snapshot comes from GetTasks, which returns at most 40 tasks. Two decisions hang on this
 * number and both fail badly on an undercount: ordering the next floor requires the current one's
 * queue to be EMPTY, so a false zero queues a second copy of a 295-patch floor; and a floor is
 * judged finished partly on it, so a false zero skips a floor that nothing ever revisits.
 */
/**
 * `live` is work still in the queue; `failed` is work that finished by GIVING UP.
 *
 * TWO NUMBERS BECAUSE THEY ANSWER TWO QUESTIONS, and folding them into one gets a deadlock either
 * way round. Ordering more work must wait only on `live` -- a patch that has finished, however
 * badly, is not going to place anything more, and blocking on it means never re-ordering the floor
 * that needs re-ordering. Declaring the floor FINISHED must consider both, because a task that
 * exhausts its attempts is marked done with a failure recorded on it: counting only `live` makes
 * "the fleet visited every square and found nothing to do" and "the fleet abandoned every square
 * for want of bricks" the same answer, and a level advanced on that is never revisited.
 */
async function outstandingFor(p_Level: number): Promise<{ live: number; failed: number } | null> {
  const ctx = { agent: 'supply', callId: `supply-count-${Date.now()}`, log: () => {} };
  try {
    const res: any = await registry.invoke('task.countNamed', { prefix: `tower-L${p_Level}-` }, ctx);
    if (res?.ok === false) {
      note(`tower: could not count level ${p_Level}'s patches -- ${res?.error ?? 'refused'}`);
      return null;
    }
    const data = res?.data ?? res;
    const live = numField(data, 'live');
    if (live === null) return null;
    // A missing `failed` is a drone-side answer we did not get, not a floor with nothing abandoned
    // on it -- but treating it as zero only ever advances the floor SOONER, so it is the reading
    // that must be justified rather than assumed. TaskMan always sends it; older TaskMan does not,
    // and for that case the old behaviour is right.
    return { live, failed: numField(data, 'failed') ?? 0 };
  } catch (err) {
    note(`tower: could not count level ${p_Level}'s patches -- ${(err as Error)?.message ?? err}`);
    return null;
  }
}

/**
 * FINISHED FLOORS GET HOLES, AND UNTIL NOW NOBODY LOOKED BACK. The level counter only ever moved
 * up: once level 0 counted as done its squares were never ordered again, so every block a drone
 * dug out of it on its way somewhere stayed out. order.tower already skips squares the map says
 * are solid, so re-ordering a finished level queues exactly the holes. Each finished level is
 * looked at every REPAIR_EVERY_MS while nothing of its own is queued.
 */
const REPAIR_EVERY_MS = 10 * 60_000;
const repairCheckedAt = new Map<number, number>();
export async function repairLowerFloors(p_Queued: Set<string>): Promise<{ acted: boolean; reason: string } | null> {
  const level = supply.towerLevel ?? 0;
  for (let l = 0; l < level; l++) {
    if (towerWorkFor(p_Queued, l).stillQueued) continue;
    if (Date.now() - (repairCheckedAt.get(l) ?? 0) < REPAIR_EVERY_MS) continue;
    repairCheckedAt.set(l, Date.now());
    const ordered = await orderFloor(l);
    if ('failed' in ordered) {
      note(`repair: level ${l} could not be re-ordered -- ${ordered.failed}`);
      continue;
    }
    const res: any = ordered.res;
    const holes = (res?.data?.tasks ?? res?.tasks ?? []).length;
    if (holes > 0) return { acted: true, reason: `repair: level ${l} had holes -- ${holes} patch(es) re-ordered` };
  }
  return null;
}
/** Clear patches belonging to floors already advanced past. Reports the shortfall rather than
 *  returning a bare count, because a partial clear leaves the tower just as blocked as no clear. */
async function clearStaleFloors(p_Stale: string[]): Promise<{ acted: boolean; reason: string }> {
  const levels = [...new Set(p_Stale.map(taskLevel))].sort((a, b) => (a ?? 0) - (b ?? 0));
  let cleared = 0;
  for (const l of levels) cleared += await stopTasksNamed(`tower-L${l}-`);
  return {
    acted: cleared > 0,
    reason: `cleared ${cleared} of ${p_Stale.length} patch(es) left over from level(s) ${levels.join(', ')}`,
  };
}

/**
 * THE TOWER PAUSES TO FREE MINERS FOR FUEL WORK -- AND ONLY FOR THAT. Bricks are on the shelf;
 * laying them costs a scout or the crafter a few blocks of travel from the bay, and their fuel
 * cannot become anyone else's. With every miner dry (2026-09-04: four at zero, 818 bricks in
 * stock, tower at level 0 all day) pausing the tower idled the whole settlement for nothing.
 * Pause while a miner still has the fuel to fell; otherwise build with whoever has fuel.
 */
const MINER_CAN_FELL_FUEL = 400;
function towerPausedForFuel(emergency: boolean | null, live: any[]): boolean {
  if (!emergency) return false;
  const minerCouldFell = live.some((d: any) => d.role === 'miner' && Number(d.fuel) >= MINER_CAN_FELL_FUEL);
  if (!minerCouldFell) {
    note('tower: fuel emergency with no miner able to fell -- building continues with the drones that have fuel');
  }
  return minerCouldFell;
}
async function keepTowerOrdered(live: any[], queued: Set<string>): Promise<{ acted: boolean; reason: string } | null> {
  const level = supply.towerLevel ?? 0;

  // THE DESIGN HAS A TOP, AND NOTHING IN THE GEOMETRY SAID SO. bandFor falls back to the topmost
  // band, so every level above the cap yields a perfectly valid cap floor -- the loop would have
  // gone on ordering floors into the sky for as long as bricks lasted, each one advancing the
  // counter, with nothing ever reporting that the building was finished.
  if (level > TOWER_TOP) {
    return { acted: false, reason: `tower complete -- level ${level} is above the design top (${TOWER_TOP})` };
  }

  // A SETTLEMENT THAT CANNOT MOVE CANNOT BUILD. STOP THE TOWER, DO NOT MERELY OUTRANK IT.
  //
  // Tower patches are priority 2 and fuel work is priority 1, which was believed to be enough. It is
  // not: the patches are already IN the queue, so whenever a drone comes free and no fuel task can
  // be placed for it, it takes one -- and a build is the most fuel-hungry job the fleet has.
  //
  // Measured at the bottom of a fuel spiral: five of seven drones at zero, storage holding one
  // acacia log, and D60 -- one of the two machines still able to move -- spending its last 593 fuel
  // laying blocks. Ranking cannot help there; the only thing that helps is the work not being
  // available to take.
  //
  // Reversible by construction: the floor re-orders itself from scratch, so stopping its patches
  // costs a lap and buys the fleet the drones it needs to end the shortage.
  // STALE FLOORS ARE CLEARED BEFORE THE EMERGENCY GATE.
  //
  // Clearing places nothing, and a floor the level has moved away from is work a freed drone can
  // still take. 295 tower-L1 patches sat queued through an entire fuel emergency because this ran
  // below the return just under here, and the emergency branch only stops the CURRENT level's.
  const { stale } = towerWorkFor(queued, level);
  if (stale.length) return await clearStaleFloors(stale);

  const emergency = await fuelEmergency();
  const paused = towerPausedForFuel(emergency, live);
  if (paused) {
    const cleared = await stopTasksNamed(`tower-L${level}-`);
    // A PAUSE MUST NOT LOOK LIKE A COMPLETION.
    //
    // Stopping the floor's patches empties its queue, and an empty queue is exactly what the
    // completion test reads as "the fleet went to every square and did what it could". So the floor
    // was judged finished on work that had been CANCELLED, and the counter advanced once per
    // emergency: measured walking 0 -> 3 across three pauses with nothing built on any of them.
    //
    // Two of my own changes interacting -- each right alone. Dropping the batch removes the thing
    // being judged, so nothing can be concluded from a floor whose work was taken away;
    // startWatchingFloor opens a fresh one when the fleet is fuelled and working again.
    supply.towerBatch = undefined;
    saveSupply();
    // A PAUSE THAT DID NOTHING IS NOT A TICK RESULT. Returning one here ended the tick, so the
    // phases after the tower -- the field-cache haul above all -- never ran while fuel was short.
    // The cache at -520,63,34 held 64 coal through an entire emergency because of this line: the
    // one action that would have ended the emergency sat behind the emergency.
    if (cleared === 0) return null;
    return { acted: true,
      reason: `fuel emergency -- tower paused, ${cleared} patch(es) stopped so the fleet can refuel` };
  }

  const bricks = await blocksPlacedTotal();

  // WHICH FLOOR IS QUEUED MATTERS. ASKING ONLY "IS ANY TOWER WORK QUEUED" WAS ONE BUG WITH THREE FACES.
  //
  // This read `n.startsWith('tower-')`, so patches left over from a floor already advanced past
  // counted as work on the CURRENT floor. Measured: 39 `tower-L0` patches outstanding with the level
  // at 2, and every consequence of that one substring:
  //
  //   - ordering waits for an empty queue, and the leftovers never left it, so levels 1 and 2 were
  //     never ordered at all -- the fleet had nothing to build;
  //   - startWatchingFloor opened a batch for level 2 on the strength of level 0's leftovers, so a
  //     floor nobody had ordered was being timed for completion;
  //   - and it duly completed, because a floor that was never ordered places nothing. The counter
  //     climbed 0 -> 1 -> 2 through floors that do not exist, and NOTHING REVISITS A LEVEL.
  //
  // The queue is the authority on what the fleet is actually working on; the counter is only a
  // pointer into it. When they disagree the counter is wrong, and the disagreement is repairable --
  // so name the two cases separately instead of folding them into one boolean.
  //
  // The SNAPSHOT is used only to spot leftovers, where a miss costs a delay: the next tick sees
  // them. The current floor's count is asked of TaskMan directly, because a miss there orders the
  // floor twice or skips it for ever. Stale floors were already cleared above the emergency gate.


  // A FLOOR IS FINISHED WHEN ITS OWN WORK IS DONE -- NOT WHEN THE FLEET STOPS BEING ABLE TO WORK.
  //
  // "The batch placed nothing" was the whole test, on the reasoning that no-op patches make an empty
  // queue unreachable so completion has to be judged without one. The first half of that is true and
  // the conclusion was wrong: no-op patches DO drain -- a drone refuses the block and the task
  // completes -- and the queue that "never emptied" was being blocked by the level-blindness bug
  // above, not by no-ops. Measured at level 0: 131 patches, 67 already completed.
  //
  // What "placed nothing" cannot distinguish is the case that actually happened. Measured tonight,
  // twice: the counter walked 0 -> 1 -> 2 with `placedTotal` stuck at 1 -- three drones at zero
  // fuel, the only crafter dry, not one block laid anywhere -- and each step was recorded as a
  // finished floor. A fleet that cannot work places nothing, exactly like a floor that is complete,
  // and NOTHING EVER REVISITS A LEVEL. So the failure mode is holes in the building, permanently,
  // caused by a fuel shortage that will clear on its own in twenty minutes.
  //
  // The floor's own patches are the discriminator. Draining them means the fleet went to every
  // square and did what it could; if that placed nothing, the floor really is done. Outstanding
  // patches mean the question has not been answered yet -- so wait, and say why. A stalled tower is
  // visible and recoverable; a skipped floor is neither.
  //
  // Counted in TaskMan rather than read off the 40-task snapshot: an undercount here skips a floor.
  const counted = await outstandingFor(level);
  if (counted === null) {
    return { acted: false, reason: `tower level ${level}: cannot count outstanding patches -- not judging the floor` };
  }
  const stillQueued = counted.live > 0;
  const unfinished = counted.live + counted.failed;
  if (floorIsFinished(level, bricks) && unfinished === 0) {
    return await advanceFloor(level, `level ${level} placed nothing and its patches have all drained`);
  }
  if (floorIsFinished(level, bricks)) {
    note(`tower level ${level}: nothing placed, but ${counted.live} patch(es) queued and `
       + `${counted.failed} abandoned -- waiting rather than advancing past a floor the fleet has `
       + `not finished`);
  }

  // START MEASURING FROM WHEREVER WE FIND OURSELVES.
  //
  // A batch was only ever recorded at the moment of ORDERING, and ordering waits for an empty queue
  // -- so a queue full of no-op patches produced no batch, nothing to judge, and therefore nothing
  // that could ever empty it. A deadlock I built by fixing the judgement without fixing where its
  // input comes from: `towerBatch: none` with hundreds of patches outstanding and the level pinned.
  //
  // If work for this floor is outstanding and nobody is measuring it, measure it from now. The
  // grace period below still applies, so this cannot declare a floor finished on the spot.
  const watching = startWatchingFloor(level, bricks, stillQueued);
  if (watching) return watching;

  // Only ORDERING needs an empty queue -- judging does not.
  if (stillQueued) return null;
  if (!mayQueue(queued, 'tower-', '__tower')) return null;

  // DID THE LAST PASS ACTUALLY BUILD ANYTHING?
  //
  // A floor is finished when working it stops changing the world -- not when a map says so. The
  // map cannot be trusted for this and never could: it remembers blocks that were mined, it does
  // not know the atrium is meant to be open, and it has no idea the settlement's own module row
  // sits inside the tower footprint at z=76 where no floor block can ever go. Deciding "finished"
  // from it meant either re-queueing a built floor for ever, or bolting on one exception after
  // another for every square that is legitimately unbuildable.
  //
  // The drones already answer this honestly by consuming material. A whole batch of patches that
  // drains no floor material placed nothing, whatever the reason -- built already, atrium, a
  // computer in the way, or unreachable. That is the effect, and it is the only thing worth
  // reading.
  if (batchPlacedNothing(level, bricks)) {
    return await advanceFloor(level, `level ${level} placed nothing more`);
  }

  return await orderAndRecord(level, bricks);
}

/**
 * Queue a floor and record the batch -- or say exactly why neither happened.
 *
 * A FLOOR THAT FAILED TO BE ORDERED IS NOT A FLOOR THAT IS FINISHED.
 *
 * The order.tower call used to swallow its rejection into a null, and the very next lines treat
 * "no tasks" as "level complete, move up". So one failure -- MapServer slow, storage unreadable,
 * anything -- was silently promoted into `supply.towerLevel++`, and the floor was skipped
 * PERMANENTLY: nothing ever revisits a level once the counter has passed it. That is the
 * order.tower swallow again, one layer up, and its cost is a hole in the building rather than a
 * wrong task count.
 *
 * The swallowed shape is deliberately not quoted anywhere in this function: autonomy.test.ts
 * greps the body for it, and a comment holding it as an example fails the check exactly as
 * loudly as the code would.
 *
 * A failure and an empty result are different answers. Say which one happened, and only the
 * empty result may advance the level.
 */
async function orderAndRecord(
  level: number, bricks: number | null,
): Promise<{ acted: boolean; reason: string }> {
  const ordered = await orderFloor(level);
  supply.cooldowns['__tower'] = Date.now() + 60_000;
  if ('failed' in ordered) {
    note(`tower level ${level}: order failed -- ${ordered.failed} (level NOT advanced)`);
    return { acted: false, reason: `tower level ${level} could not be ordered -- ${ordered.failed}` };
  }
  const res: any = ordered.res;
  const queuedCount = (res?.data?.tasks ?? []).length;

  // A REFUSED QUEUE IS NOT A FINISHED FLOOR EITHER. order.tower now carries TaskMan's refusal out
  // instead of swallowing it in a bare `break`; "the queue would not take it" is a transient
  // condition, and advancing past the level on it loses the floor for good.
  const refused = res?.data?.refused ?? res?.refused;
  if (refused) {
    note(`tower level ${level}: TaskMan refused -- ${refused} (level NOT advanced)`);
    return { acted: false, reason: `tower level ${level} refused by TaskMan -- ${refused}` };
  }

  // Nothing even queueable -- unaffordable, or off the end of the design. Move on.
  if (queuedCount === 0) return await advanceFloor(level, `level ${level} queued nothing`);

  supply.towerBatch = { level, held: bricks, at: Date.now() };
  saveSupply();
  return { acted: true, reason: `tower level ${level}: queued ${queuedCount} patches` };
}

/**
 * A PLANNED FACTORY IS INTENT. GIVE IT CHESTS AND IT IS PLANT.
 *
 * factory.create files a line against a plot and leaves it `planned`; factory.attach gives it an
 * input and an output and only then does it become `running`. Nothing ever did the second step
 * without a human, so both of this settlement's factories -- planks-01 and charcoal-01, the two
 * that make the planks and the charcoal everything else is built and fuelled with -- sat at
 * `planned` indefinitely, with no links and no routes, while the fleet hand-crafted every plank it
 * needed and ran out of fuel doing it.
 *
 * The settlement is supposed to run without anybody watching it, so the loop that keeps supply
 * moving is the right place to finish the wiring. Chests are chosen by free space, which is the
 * same rule DepositTarget uses -- the emptiest is the one that can actually accept a delivery.
 */
async function bringFactoriesOnline(): Promise<{ acted: boolean; reason: string } | null> {
  const planned = factories.filter((f: any) => !f.input || !f.output);
  if (!planned.length) return null;

  // Unreadable storage used to arrive here as "the settlement has fewer than two chests", which is
  // indistinguishable from a genuinely bare base -- so both factories stayed `planned` indefinitely
  // and the only trace was that nothing ever happened.
  const stock: any = await bridge.call('StorageMan', 'Stock', {}, { timeoutMs: 8000 })
    .catch((err) => { note(`factory wiring: storage unreadable -- ${(err as Error)?.message ?? err}`); return null; });
  const chests = (luaList<any>(field(stock, 'chests')) ?? [])
    .filter((c: any) => typeof c?.name === 'string' && c.name.includes('chest'))
    .sort((a: any, b: any) => (b.free ?? 0) - (a.free ?? 0));
  // Two distinct chests, or the line would draw from the box it fills.
  if (chests.length < 2) return null;

  const f: any = planned[0];
  f.input = f.input ?? chests[0].name;
  f.output = f.output ?? chests[1].name;
  f.status = f.input && f.output ? 'running' : 'planned';
  saveCity();
  return { acted: true, reason: `${f.name} online: in ${f.input}, out ${f.output}` };
}

/**
 * MAY THIS PERIODIC ACTION RUN RIGHT NOW?
 *
 * Two rules govern every one of them and they were written out twice, which is how they drift: an
 * OUTSTANDING TASK is the real answer to "did I already do this" -- a fact rather than a guess --
 * and the cooldown only covers the window between queueing and the task appearing in the list.
 * Getting that order wrong once queued five duplicate chest-rows at 0 free slots.
 */
function mayQueue(queued: Set<string>, prefix: string, cooldownKey: string): boolean {
  if ([...queued].some((n) => n.startsWith(prefix))) return false;
  return (supply.cooldowns[cooldownKey] ?? 0) <= Date.now();
}

/**
 * GO AND EMPTY THE FIELD CACHES. OTHERWISE CACHING LOSES THE MATERIAL IT SAVES.
 *
 * A drone working far from base places a chest and leaves its spoil in it rather than flying the
 * haul once per load. That is right, and PlaceCacheHere registers the chest with StorageMan so it
 * can be found again -- its own comment says "register it, or it is a hole with a chest in it that
 * nobody will ever visit again". Nobody ever visited it.
 *
 * Measured: a lumber sweep logged "JOB Lumber done" with oak_log still 0 in storage, because the
 * wood was in a cache 81 blocks out. Planks come from logs, chests come from planks, and every
 * blueprint in the settlement costs planks or chests -- so the entire build chain was stalled on
 * material that had already been cut and was sitting in a box.
 *
 * A cache is a deposit point with NO peripheral: it has no wired modem, which is exactly why
 * storage cannot see into it and why nothing noticed it was full. That absence is the marker.
 *
 * One at a time, and behind a cooldown, because a haul is a long round trip and the alternative --
 * queueing every cache at once -- takes the whole fleet off work to fetch boxes that may be empty.
 */
/**
 * PLANT THE FOREST WHERE THE FLEET LIVES.
 *
 * Every tree the fleet knows is forty to sixty blocks out. At the measured 2.7 fuel per block of
 * progress a run that fells eight logs costs roughly what the logs return as charcoal, so lumber
 * cannot be fuel-positive from there whatever else is fixed. The drones already carry saplings home
 * from every felling; this puts them in the ground on a forestry plot beside the bay, so the next
 * generation of lumber is a ten-block walk. Runs in an emergency too -- it is cheap, and it is the
 * only thing that changes the distance term.
 */
const FORESTRY_MIN_SAPLINGS = 2;
const FORESTRY_SPACING = 3;
async function plantForestry(queued: Set<string>): Promise<{ acted: boolean; reason: string } | null> {
  if (!mayQueue(queued, 'plant:', '__plant')) return null;
  const saplings = await readStockWhere((n) => /_sapling$/.test(n), () => undefined);
  if (saplings == null || saplings < FORESTRY_MIN_SAPLINGS) return null;

  let plot: any = (city.plots as any[]).find((p) => p.purpose === 'forestry');
  if (!plot) {
    const r = allocate(city, 'forestry', 'grove-01');
    if ('error' in r) { note(`forestry: ${r.error}`); return null; }
    plot = r;
    saveCity();
    note(`forestry: allocated ${plot.name} at ${plot.min.x},${plot.ground},${plot.min.z}`);
  }
  const spots: Array<{ x: number; y: number; z: number }> = [];
  for (let x = plot.min.x + 1; x <= plot.max.x - 1; x += FORESTRY_SPACING) {
    for (let z = plot.min.z + 1; z <= plot.max.z - 1; z += FORESTRY_SPACING) {
      spots.push({ x, y: plot.ground, z });
    }
  }
  const n = Math.min(spots.length, saplings);
  const ok = await queueTask({
    name: `plant:${plot.name}`,
    work: { plant: { pos: { x: plot.min.x, y: plot.ground, z: plot.min.z }, spots: spots.slice(0, n) } },
  }, `forestry: plant at ${plot.name}`);
  if (!ok) return null;
  supply.cooldowns.__plant = Date.now() + COOLDOWN_MS;
  note(`forestry: planting ${n} sapling(s) at ${plot.name}`);
  return { acted: true, reason: `forestry: planting ${n} sapling(s) at ${plot.name}` };
}

/**
 * Queue one task with TaskMan and say so if it did not take. A refusal comes back as a STRING, not
 * an exception (see buildQueuedSet), and a dead bridge as a rejection -- both are "not queued".
 */
async function queueTask(task: { name: string; work: unknown }, what: string): Promise<boolean> {
  const added: any = await bridge.call('TaskMan', 'Add', { ...task, priority: 1 }, { timeoutMs: 8000 })
    .catch((err) => `queue unreachable -- ${(err as Error)?.message ?? err}`);
  if (!added || typeof added === 'string') {
    note(`${what}: NOT queued -- ${added || 'no answer from TaskMan'}`);
    return false;
  }
  return true;
}

async function collectFieldCaches(
  live: any[], queued: Set<string>,
): Promise<{ acted: boolean; reason: string } | null> {
  // No !live.length guard on purpose: a queued haul costs nothing and waits for whoever frees up.
  if (!mayQueue(queued, 'haul:', '__haul')) return null;
  // A FULL SHELF DOES NOT WANT A CACHE OF STONE. With 2 free slots across six chests, hauls kept
  // bringing 64 stone a trip from the field cache and every deposit after them failed; drones sat
  // "refuelling" for hours because the refuel unloads first and had nowhere to unload (2026-09-04).
  if (await storageHasNoRoom()) {
    note('field caches: storage has no room -- not hauling anything in');
    return null;
  }

  // luaList, not Array.isArray -- an empty deposit list serialises to {} rather than [], the same
  // trap that once made a fresh world refuse to dispatch anything at all.
  //
  // And a FAILED read is not an empty one: swallowed, it means "there are no field caches", which is
  // the same wrong premise as an empty stock -- the wood stays in a box 81 blocks out and the build
  // chain starves behind it with nothing anywhere saying why.
  const r: any = await bridge.call('StorageMan', 'DepositPoints', {}, { timeoutMs: 8000 })
    .catch((err) => { note(`field caches: deposit points unreadable -- ${(err as Error)?.message ?? err}`); return null; });
  const points = luaList<any>(field(r, 'points')) ?? [];

  // No peripheral == off the wired network == a field cache rather than a bay chest.
  // A cache a drone has already read as EMPTY is not worth a trip; one nobody has read yet is.
  const holdsSomething = (q: any) =>
    q.items == null || Object.values(q.items as Record<string, unknown>).some((n) => Number(n) > 0);
  // CACHES ARE WHERE MINERS DROP SPOILS SO THEY KEEP MINING; HAULING THEM HOME IS THE DESIGN. A
  // surface-only filter briefly lived here after D31 spent 784 fuel tunnelling sideways toward the
  // shaft-bottom cache at -480,8,87 -- but that was the dig flag never reaching the planner, fixed
  // since, not the cache's fault. Every cache in reach is haulable; the shaft is the route.
  const caches = points.filter((q: any) => q?.pos && !q.peripheral && withinReach(q.pos) && holdsSomething(q));
  if (!caches.length) return null;

  // Furthest first: those are the ones a drone would otherwise refuse to haul from, and the ones
  // holding the most by the time anyone gets there.
  //
  // EXCEPT WHILE FUEL IS SHORT: NEAREST SURFACE CACHE FIRST. Farthest-first chose a mining cache at
  // y=8 -- fifty blocks underground, out of GPS and beyond any relief -- over the surface cache 45
  // blocks away holding 64 coal, i.e. the emergency's own exit. The cheapest haul that can end the
  // shortage goes first, and nothing goes underground until it has.
  const b = settlement.base;
  const far = (q: any) => Math.abs(q.x - b.x) + Math.abs(q.y - b.y) + Math.abs(q.z - b.z);
  const emergency = (await fuelEmergency()) === true;
  // IN A FUEL EMERGENCY A HAUL IS ONLY WORTH ITS FUEL IF IT BRINGS FUEL. Measured 2026-09-04: with
  // the shelf at zero, HQ re-queued haul:-469,64,41 four times in a row because the cache still
  // "held something" -- 64 stone a trip, ~150 fuel a cycle with the shelf check afterwards -- and
  // the scout carrying the fleet's last tank flew it from 1,698 down to 642 while every miner was
  // dead. Surface caches only, as before; KNOWN burnable only, now. "Unread, might be fuel" was
  // tried and re-queued the same stone chest because nothing had ever reported it; the haul job
  // now reports what it leaves, so a cache worth a trip becomes known the first time it is read.
  const holdsFuel = (q: any) => q.items != null && Object.entries(q.items as Record<string, unknown>)
    .some(([n, c]) => BURNABLE.test(n) && Number(c) > 0);
  const usable = emergency ? caches.filter((q: any) => holdsFuel(q)) : caches;
  if (!usable.length) return null;
  // And a cache a drone has SEEN burnable in outranks distance while fuel is short: the one at
  // -520,63,34 was observed holding 64 coal, and it was fourth in line behind three near-base
  // caches full of cobblestone and copper.
  const burnableIn = (q: any) =>
    q.items ? Object.entries(q.items as Record<string, unknown>)
      .some(([n, c]) => BURNABLE.test(n) && Number(c) > 0) : false;
  const chosen = usable.sort((x: any, y: any) => {
    if (emergency) {
      const bx = burnableIn(x) ? 0 : 1, by = burnableIn(y) ? 0 : 1;
      if (bx !== by) return bx - by;
      return far(x.pos) - far(y.pos);
    }
    return far(y.pos) - far(x.pos);
  })[0];
  const at = chosen.pos;
  // A HAUL OF FUEL IS FUEL WORK. TaskMan ranks fuel-producing tasks first during a shortage by
  // their NAME, so a haul from a cache holding 26 logs and 11 coal queued behind every lumber run
  // while the fleet died -- 3,000 fuel-equivalent 45 blocks away, one 250-fuel trip from the
  // network. The suffix ranks it where it belongs; the prefix still matches mayQueue and stops.
  const suffix = burnableIn(chosen) ? ':log' : '';

  const where = `${at.x},${at.y},${at.z}`;
  note(`field cache at ${where} has never been collected -- sending a drone${suffix ? ' (it holds fuel)' : ''}`);
  // Both shapes of failure say WHY (queueTask). The note above already promised a drone was being
  // sent; a silent return here left that promise standing in the log as if it had happened.
  const ok = await queueTask({
    name: `haul:${where}${suffix}`,
    work: { haul: { pos: { x: at.x, y: at.y, z: at.z } } },
  }, `field cache at ${where}: haul`);
  if (!ok) return null;

  supply.cooldowns['__haul'] = Date.now() + 3 * 60_000;
  saveSupply();
  return { acted: true, reason: `queued a haul from the cache at ${where}` };
}

/** Keep one pending storage plot (its name is returned for reuse) and retire the rest. */
function retireExtraStoragePlots(p_Pending: any[]): string | undefined {
  if (!p_Pending.length) return undefined;
  const keep = p_Pending[0].name;
  if (p_Pending.length > 1) {
    const before = city.plots.length;
    (city as any).plots = (city.plots as any[]).filter((p) => !(p.purpose === 'storage' && p.status !== 'active' && p.name !== keep));
    saveCity();
    note(`storage: retired ${before - city.plots.length} pending storage plot(s) nobody was building; keeping ${keep}`);
  }
  return keep;
}
async function expandStorageIfFull(
  live: any[], queued: Set<string>,
): Promise<{ acted: boolean; reason: string } | null> {
  // Any live drone will do -- RoleForWork sends builds to a miner, and miners are the general
  // workers. Waiting for a specific role here would make the settlement stay jammed because the
  // wrong kind of drone was free.
  if (!live.length) return null;
  // DO NOT STACK EXPANSIONS, AND DO NOT TRUST A TIMER TO PREVENT IT.
  //
  // The first version guarded only on a three-minute cooldown, which is not the same question: the
  // cooldown expires while the previous build is still outstanding, so at 0 free slots this queued
  // build-chest-row-storage-03, -05, -06, -07 and -08 -- the duplicate-task problem again, in a new
  // costume, from the rule that was supposed to be fixing things. An outstanding build IS the
  // answer to "should I queue a build", and it is a fact rather than a guess about elapsed time.
  //
  // The cooldown stays as a second line of defence for the window between queueing and the task
  // appearing in the list.
  if (!mayQueue(queued, 'build-chest-row', '__storage')) return null;

  const free = await observedFreeSlots();
  if (free === null || free > FREE_SLOTS_FLOOR) return null;

  // ONE UNFINISHED STORAGE PLOT AT A TIME. Each chest-row order allocated a fresh plot and, with no
  // chests to build it from, the next tick allocated another: 52 storage plots "clearing" by the
  // evening of 2026-09-04, none built. The unfinished one is the expansion; wait for it.
  const pending = (city.plots as any[]).filter((p) => p.purpose === 'storage' && p.status !== 'active');
  // A PENDING PLOT IS ONLY PROGRESS IF SOMETHING IS BUILDING IT. This used to stop here whenever
  // a storage plot was not yet active -- and 51 of them sat "clearing" for a day while the shelf
  // held 0 free slots, because the one chest-row build that existed had vanished from TaskMan and
  // nothing ever ordered another. Now: reuse the first pending plot (the build task is what was
  // missing, not the land), and retire every other pending storage plot -- nothing references
  // them and each one would have been another reason to do nothing.
  const reuse = retireExtraStoragePlots(pending);
  note(`storage down to ${free} free slot(s) -- ${reuse ? `re-ordering the chest-row on ${reuse}` : 'expanding'} before everything jams behind it`);
  try {
    const r: any = await callTool('order.build', { blueprint: 'chest-row', ...(reuse ? { plot: reuse } : {}) });
    if (r?.ok === false) {
      note(`storage expansion refused -- ${r?.error ?? '?'}`);
      return null;
    }
    supply.cooldowns['__storage'] = Date.now() + COOLDOWN_MS;
    supply.dispatched++;
    supply.lastAction = 'expand storage';
    return { acted: true, reason: `storage was down to ${free} free slots -- queued a chest-row` };
  } catch (err) {
    note(`storage expansion failed -- ${(err as Error)?.message ?? err}`);
    return null;
  }
}

export async function runSupplyTick(): Promise<{ acted: boolean; reason: string }> {
  supply.lastRun = Date.now();
  if (!supply.enabled) return { acted: false, reason: 'disabled' };
  if (!bridge.connected) return { acted: false, reason: 'bridge offline' };

  // Never stack speculative work: if anything is already mining, this loop waits.
  const fleet: any = await bridge.call('DroneMan', 'GetDrones', {}, { timeoutMs: 5000 });
  const drones = field(fleet, 'drones') ?? [];
  const live = drones.filter((d: any) => !offlineish(d));
  // Gate per ROLE, not across the fleet.
  //
  // This used to bail whenever any drone was working at all, which sounded conservative and was
  // just wrong: a scout surveying and a miner mining do not contend for anything, so one busy
  // miner silently blocked every scan. One scout also covers many miners -- surveying is what
  // makes the next several digs possible -- so making it wait on a free miner had it backwards.
  const idle = (role: string) => live.find((d: any) => (d.role ?? 'miner') === role && d.status === 'idle');

  // FIRST. NOTHING ELSE CAN SUCCEED WHILE THERE IS NOWHERE TO PUT ANYTHING.
  //
  // This used to sit after replanShortfalls and topUpQueue, both of which RETURN EARLY the moment
  // they do anything -- and with ten idle drones the top-up queues a gather almost every tick. So
  // the one rule that could unjam the settlement was placed behind two rules that almost always
  // preempt it, and it effectively never ran: storage sat at 0 free slots with ten drones idle.
  //
  // The ordering is not just about reachability, it is about correctness. Topping up the gather
  // queue while storage is full is actively harmful -- it sends more drones to fetch material that
  // has nowhere to go, and each of them then fails in a way that looks like its own fault.
  // The queue is read FIRST, before any phase decides to add to it. Not knowing what is already
  // outstanding is a reason to wait, not to proceed -- and every phase below can queue work, so
  // every one of them needs the answer. This used to be read halfway down, which is why the storage
  // rule had to guard itself with a timer instead of a fact.
  const q = await buildQueuedSet();
  if ('refuse' in q) return { acted: false, reason: q.refuse };
  const queued = q.queued;

  const maintained = await maintenancePhases(live, queued);
  if (maintained) return maintained;


  const idleMiner = idle('miner');
  const idleScout = idle('scout');
  const idleCrafter = idle('crafter');
  if (!idleMiner && !idleScout && !idleCrafter)
    return { acted: false, reason: 'no idle miner, scout or crafter' };

  const stock: any = await bridge.call('StorageMan', 'stock', {}, { timeoutMs: 8000 });
  // Same shape trap as the task queue: an empty stock detail arrives as {} and .filter is not a
  // function on it, so the very first supply pass in a new world threw before it could decide
  // anything. Empty stock is the NORMAL state of a settlement that has not mined yet -- it is the
  // condition the loop exists to resolve, so it must be the one case it handles cleanly.
  const detail = luaList<any>(field(stock, 'detail')) ?? [];
  // STOCK INSIDE A DRONE IS STILL STOCK THE FLEET HAS.
  //
  // `held` counted chests only, so everything in transit was invisible to every decision this loop
  // makes. Measured live: the fleet was carrying 3,567 items -- including 421 COAL, about 33,680
  // fuel -- while storage reported 61 coal, the monitor alerted COAL LOW, and this loop dispatched
  // find-coal_ore to go and mine more. It was mining a material it already had, because the
  // material was in a drone's hold rather than a chest.
  //
  // That is not a rare state. Storage sits at 0 free slots, so a drone that finishes a job CANNOT
  // deposit and simply keeps its load -- the fuller the warehouse, the more stock is invisible, and
  // the more phantom shortages this loop invents. The blindness gets worse exactly when it hurts.
  //
  // Counted over `live` only, never over every drone on the books. Material inside a lost drone is
  // not material the fleet has, and treating it as available is precisely the bug that caused the
  // fuel death spiral (41,234 phantom fuel counted from five unreachable drones while every
  // reachable one sat at zero). Same trap, same rule: count what can actually act.
  const carried = carriedStock(live);

  // THE FUEL GATE HAS TO BE ABOVE THE PHASES THAT RETURN EARLY, OR IT IS NEVER REACHED.
  //
  // It was written at the bottom of the tick, below replanShortfalls and topUpQueue, both of which
  // return the moment they do anything at all. So on a settlement with a single failing wood gather
  // the tick short-circuited on the replan EVERY pass -- six identical notes in six minutes,
  // "re-planned minecraft:oak_log for a failing task" -- and execution never once got as far as
  // asking whether the fleet had any fuel. Coal sat at ZERO for the whole of it, and the sentinel
  // correctly reported that nothing was generating the next job.
  //
  // The gate was not broken; it was unreachable, which is worse, because the code reads as if the
  // protection is there. Line 1057 above records the same discovery being made about a different
  // phase -- "this used to sit after replanShortfalls and topUpQueue, both of which RETURN EARLY".
  // The lesson did not get applied to the one check the file calls the precondition for all others.
  const fleetFuel = live.reduce((n: number, d: any) => n + (Number(d.fuel) || 0), 0);
  const { coalReserve, runway, critical: fuelCritical } = fuelRunway(detail, carried, fleetFuel);
  if (fuelCritical) {
    note(`fuel emergency: ${fleetFuel} onboard + ${coalReserve} coal = ${runway} runway `
       + `(floors ${FUEL_PRIORITY_BELOW} / ${RUNWAY_CRITICAL_BELOW}) -- coal only this tick`);
  }

  // Re-planning a wood shortfall and topping the queue up with assorted ore are both things a
  // settlement does when it can afford to move. During a fuel emergency they are what stops it
  // moving, so they are skipped and the tick falls through to the rule loop, where the same
  // fuelCritical flag allows coal and nothing else.
  const phases = await materialPhases(live, fuelCritical, queued);
  if (phases) return phases;
  const held = (m: string) => {
    const inChests = detail
      .filter((d: any) => typeof d.name === 'string' && d.name.includes(m))
      .reduce((n: number, d: any) => n + (d.count ?? 0), 0);
    const inHolds = Object.entries(carried)
      .filter(([name]) => name.includes(m))
      .reduce((n, [, v]) => n + v, 0);
    return inChests + inHolds;
  };


  const now = Date.now();
  // Each role can take one job per tick. A tick can therefore start a dig AND a survey, which is
  // the point: the scan that finds the next vein should not have to wait for the current one to
  // finish being mined.
  let minerFree = !!idleMiner;
  let scoutFree = !!idleScout;
  let crafterFree = !!idleCrafter;
  const did: string[] = [];
  const waiting: string[] = [];

  // FUEL IS NOT ONE MATERIAL AMONG MANY. IT IS THE PRECONDITION FOR ALL OF THEM.
  //
  // The rules are walked in order and every one of them reads as short, because StorageMan cannot
  // report stock -- so the loop round-robins through dirt, copper, zinc and lapis regardless of
  // whether the fleet can still move. It was caught doing exactly that: D1 gathering DIRT while
  // total fleet fuel fell from 7,556 to 5,664 and the coal in storage never moved off 129. A fleet
  // that spends its last few thousand fuel on dirt is not self-sustaining, it is just slow to die.
  //
  // So when the tank is low, coal outranks everything. Not a permanent priority -- once there is a
  // comfortable reserve the normal round-robin resumes and the other materials get their turn.
  // LIVE drones, not every drone on the books.
  //
  // This summed the WHOLE fleet, and fuel inside a drone nobody can reach is not fuel the fleet
  // has. Measured at the point of collapse: eleven reachable drones at ZERO fuel, and 41,234 fuel
  // sitting inside five drones that had been silent for six to fifteen hours. The loop read 41,234,
  // concluded there was a comfortable reserve, and went on round-robining dirt and copper while
  // every drone that could actually move ran dry -- which is the exact death spiral the threshold
  // exists to prevent, entered through the one input nobody checked.
  //
  // `live` already excludes offline and lost drones; it just was not used here.
  const ctx: SupplyCtx = {
    now, queued, did, waiting,
    minerFree, scoutFree, crafterFree,
    idleCrafter, held,
    fuelCritical,
  };
  const storageFull = await storageHasNoRoom();

  for (const rule of supply.rules) {
    if (!ctx.minerFree && !ctx.scoutFree && !ctx.crafterFree) break;
    const have = held(stockKey(rule));
    const skip = ruleSkipReason(rule, {
      fuelCritical, have, now, storageFull,
      cooldownUntil: supply.cooldowns[rule.match] ?? 0,
    });
    if (skip) {
      if (skip.message) waiting.push(skip.message);
      continue;
    }
    try {
      await dispatchRule(rule, have, ctx);
    } catch (err) {
      supply.cooldowns[rule.match] = now + COOLDOWN_MS;
      note(`${rule.match}: dispatch failed — ${(err as Error)?.message ?? err}`);
    }
  }
  // The dispatchers own these from here; the remaining phases read them back off the context.
  minerFree = ctx.minerFree; scoutFree = ctx.scoutFree; crafterFree = ctx.crafterFree;

  await retireStaleSupport(live, did);

  // EXPLORATION IS NOT FREE, AND A FUEL EMERGENCY IS EXACTLY WHEN IT LOOKS FREE.
  //
  // fuelCritical gates materialPhases above and every rule in the loop through ruleSkipReason, so
  // during an emergency the tick correctly refuses to gather dirt, copper or lapis -- and then fell
  // straight through to these two and dispatched a cave survey anyway. They were the only
  // dispatchers in the whole tick that never asked. The protection reads as if it covers the tick;
  // it covered everything except the part that sends a drone furthest from home.
  //
  // Measured at the point this was found: storage holding ZERO coal and zero charcoal, "fuel
  // emergency: ... -- coal only this tick" printed once a minute for the preceding hour, and D19 --
  // the only fuelled mobile drone left, carrying the 32 coal that was going to restart the furnaces
  // -- flying a cave survey at the far edge of the region and burning that same coal to do it
  // ("refuelled +78" three times in four minutes, one coal each). Stopping the task by hand did not
  // help for longer than a tick: this line regenerated it (6870 -> 6890 -> 6908) and TaskMan handed
  // it straight back to the same drone.
  //
  // Surveying is how the settlement finds its NEXT vein. Fuel is how it reaches any vein at all.
  // When the second is in doubt the first is a luxury, and it is spent in the most expensive
  // possible place: a scout at the edge of its range with no reserve to come home on.
  if (fuelCritical) {
    waiting.push('cave survey and miner support: fuel emergency');
  } else {
    await surveyCaves(ctx);
    await scoutForMiners(ctx);
  }

  if (did.length) return { acted: true, reason: did.join(', ') };
  if (waiting.length) return { acted: false, reason: `waiting on cooldown: ${waiting.join(', ')}` };
  return { acted: false, reason: 'nothing to dispatch' };
}

// 60 s -> 20 s: at `tick rate 60` a minute of wall clock is three minutes of drone time.
export function startSupplyLoop(intervalMs = 10_000) {
  setInterval(() => { runSupplyTick().catch(() => { /* reported via note() */ }); }, intervalMs).unref();
}
