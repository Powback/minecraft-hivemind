/**
 * The recipe graph, and the planner that walks it.
 *
 * This is the piece whose absence made the fleet an executor rather than an agent. Everything it
 * could do, it could only be TOLD to do: "mine here", "gather that". Ask it for a chest and there
 * was no answer, because nothing anywhere knew that a chest is eight planks, that a plank comes
 * from a log, and that a log has to be felled by a drone with an axe. Every one of those steps had
 * to be issued by a human who already knew the answer.
 *
 * `expand()` is the whole point: a goal and a quantity go in, an ORDERED list of concrete jobs
 * comes out, with what is already in storage subtracted. That single function is the difference
 * between a fleet that follows instructions and one that pursues an objective.
 *
 * Deliberately pure. No bridge, no drones, no world -- stock comes in as a plain lookup. It is
 * therefore testable without a Minecraft server, which matters because this is the component whose
 * bugs are least visible in world: a wrong plan does not crash, it just quietly builds the wrong
 * thing, or nothing, and looks busy doing it.
 */

/** Where a conversion happens. Determines which drone and which structure a step needs. */
export type Station =
  | 'inventory'   // a turtle's own 3x3 grid -- needs a crafting-table upgrade ("crafty" turtle)
  | 'furnace';    // smelting, which StorageMan already drives

export interface Recipe {
  /** Item produced, namespaced exactly as Minecraft reports it. */
  output: string;
  /** How many one application yields. Planks come out 4 at a time; ignoring that over-orders 4x. */
  yields: number;
  /** What one application consumes. */
  inputs: Record<string, number>;
  station: Station;
  /**
   * The 3x3 grid, row-major, using item names or null for an empty cell.
   *
   * turtle.craft() does not take a recipe -- it reads the turtle's inventory slots as a grid and
   * infers what is being made. So the LAYOUT is not documentation, it is the instruction: getting
   * it wrong produces either nothing or the wrong item, silently. Shapeless recipes leave this
   * undefined and the drone packs sequentially.
   */
  grid?: (string | null)[];
}

/**
 * What the fleet can obtain WITHOUT crafting -- the leaves of the graph.
 *
 * Each maps to a job verb that already exists. If a material is not craftable and not here, the
 * planner must say so rather than invent a step, because a plan containing a job nobody can
 * perform is worse than an admission that the goal is out of reach.
 */
export const SOURCES: Record<string, { action: 'gather' | 'lumber' | 'smelt'; block?: string }> = {
  'minecraft:oak_log':   { action: 'lumber' },
  'minecraft:cobblestone': { action: 'gather', block: 'stone' },
  'minecraft:stone':     { action: 'gather', block: 'stone' },
  'minecraft:dirt':      { action: 'gather', block: 'dirt' },
  'minecraft:sand':      { action: 'gather', block: 'sand' },
  'minecraft:coal':      { action: 'gather', block: 'coal_ore' },
  'minecraft:raw_iron':  { action: 'gather', block: 'iron_ore' },
  'minecraft:redstone':  { action: 'gather', block: 'redstone_ore' },
  // Deep, but reachable: prospecting already sinks shafts and drives tunnels, and diamond is the
  // difference between a turtle that chews stone and one that works at a useful rate.
  'minecraft:diamond':   { action: 'gather', block: 'diamond_ore' },
  // Grows by water. Not minable, but a farm is a job the fleet already has a verb for.
  'minecraft:sugar_cane': { action: 'gather', block: 'sugar_cane' },
};

const P = 'minecraft:oak_planks';
const S = 'minecraft:stick';
const ST = 'minecraft:stone';
const IR = 'minecraft:iron_ingot';
const RD = 'minecraft:redstone';
const GP = 'minecraft:glass_pane';
const GL = 'minecraft:glass';
const EP = 'minecraft:ender_pearl';
const COMP = 'computercraft:computer_normal';

/**
 * THE DRONE ITSELF.
 *
 * Taken from the mod's own recipe files rather than memory, because the grid layout IS the
 * instruction -- turtle.craft reads the inventory and infers the result, so a misremembered pattern
 * produces silently nothing.
 *
 * This is the loop closing: iron, stone, sand and wood go in; a machine that can mine iron, stone,
 * sand and wood comes out. Everything in the chain has a source the fleet can reach EXCEPT the
 * ender pearl in the modem, which is a mob drop. There is deliberately no recipe and no source for
 * it, so a plan needing one says so plainly instead of quietly stalling -- stock satisfies it, and
 * seeding that stock is the acknowledged cheat rather than a hidden one.
 */
export const RECIPES: Recipe[] = [
  // Wood chain. Everything the fleet can build starts here, which is why a desert base with no
  // trees could not build anything at all.
  // Oak is written here because a table needs a name, NOT because the fleet requires oak. Every log
  // species makes its own planks and every planks species makes the same chest, stick and crafting
  // table -- so the drone matches wood by FAMILY (see SameItem in DroneLogic). Hard-matching oak is
  // how a fleet standing in a birch forest reports "storage has none of the ingredients".
  { output: P, yields: 4, inputs: { 'minecraft:oak_log': 1 }, station: 'inventory' },
  { output: S, yields: 4, inputs: { [P]: 2 }, station: 'inventory',
    grid: [P, null, null, P, null, null, null, null, null] },

  { output: 'minecraft:chest', yields: 1, inputs: { [P]: 8 }, station: 'inventory',
    grid: [P, P, P, P, null, P, P, P, P] },
  { output: 'minecraft:crafting_table', yields: 1, inputs: { [P]: 4 }, station: 'inventory',
    grid: [P, P, null, P, P, null, null, null, null] },
  { output: 'minecraft:furnace', yields: 1, inputs: { 'minecraft:cobblestone': 8 }, station: 'inventory',
    grid: Array(9).fill('minecraft:cobblestone').map((v, i) => (i === 4 ? null : v)) },
  { output: 'minecraft:torch', yields: 4, inputs: { [S]: 1, 'minecraft:coal': 1 }, station: 'inventory',
    grid: ['minecraft:coal', null, null, S, null, null, null, null, null] },
  { output: 'minecraft:hopper', yields: 1, inputs: { 'minecraft:iron_ingot': 5, 'minecraft:chest': 1 },
    station: 'inventory' },

  // ── The drone factory ────────────────────────────────────────────────────
  { output: GP, yields: 16, inputs: { [GL]: 6 }, station: 'inventory',
    grid: [GL, GL, GL, GL, GL, GL, null, null, null] },

  { output: COMP, yields: 1, inputs: { [ST]: 7, [RD]: 1, [GP]: 1 }, station: 'inventory',
    grid: [ST, ST, ST, ST, RD, ST, ST, GP, ST] },

  { output: 'computercraft:wireless_modem_normal', yields: 1, inputs: { [ST]: 8, [EP]: 1 },
    station: 'inventory', grid: [ST, ST, ST, ST, EP, ST, ST, ST, ST] },

  { output: 'computercraft:turtle_normal', yields: 1,
    inputs: { [IR]: 7, [COMP]: 1, 'minecraft:chest': 1 }, station: 'inventory',
    grid: [IR, IR, IR, IR, COMP, IR, IR, 'minecraft:chest', IR] },

  // THE PIPING. A wired modem joins any inventory to the network, and cable carries it there --
  // after which StorageMan can move items between them directly. That is the conveyor: it runs at
  // server speed, costs no fuel, and needs no drone. Turtles hauling between factories is what you
  // do BEFORE you can afford this, not the goal.
  // The full-block form, which is what a TURTLE can place: turtle.place fills a cell, and the flat
  // modem has to be applied to the face of an existing block. Shapeless, straight from the flat one
  // -- verified against computercraft/recipe/wired_modem_full_from.json rather than assumed.
  { output: 'computercraft:wired_modem_full', yields: 1, inputs: { 'computercraft:wired_modem': 1 },
    station: 'inventory', grid: ['computercraft:wired_modem'] },
  { output: 'computercraft:wired_modem', yields: 1, inputs: { [ST]: 8, [RD]: 1 },
    station: 'inventory', grid: [ST, ST, ST, ST, RD, ST, ST, ST, ST] },
  { output: 'computercraft:cable', yields: 6, inputs: { [ST]: 5, [RD]: 1 },
    station: 'inventory', grid: [null, ST, null, ST, RD, ST, null, ST, null] },

  { output: 'computercraft:disk_drive', yields: 1, inputs: { [ST]: 7, [RD]: 2 },
    station: 'inventory', grid: [ST, ST, ST, ST, RD, ST, ST, RD, ST] },

  // ── Specialised drones ───────────────────────────────────────────────────
  { output: 'minecraft:redstone_block', yields: 1, inputs: { [RD]: 9 }, station: 'inventory',
    grid: Array(9).fill(RD) },
  { output: 'minecraft:iron_bars', yields: 16, inputs: { [IR]: 6 }, station: 'inventory',
    grid: [IR, IR, IR, IR, IR, IR, null, null, null] },

  { output: 'minecraft:diamond_pickaxe', yields: 1,
    inputs: { 'minecraft:diamond': 3, [S]: 2 }, station: 'inventory',
    grid: ['minecraft:diamond', 'minecraft:diamond', 'minecraft:diamond',
           null, S, null, null, S, null] },

  // A tool becomes an UPGRADE by being crafted alongside the turtle -- CC:T handles the transform,
  // so the grid is simply the two items together.
  { output: 'computercraft:turtle_normal_pickaxe', yields: 1,
    inputs: { 'computercraft:turtle_normal': 1, 'minecraft:diamond_pickaxe': 1 },
    station: 'inventory',
    grid: ['computercraft:turtle_normal', 'minecraft:diamond_pickaxe', null,
           null, null, null, null, null, null] },

  // Reachable, and the only part of a geo scanner that is.
  { output: 'advancedperipherals:peripheral_casing', yields: 1,
    inputs: { [IR]: 4, 'minecraft:iron_bars': 4, 'minecraft:redstone_block': 1 },
    station: 'inventory',
    grid: [IR, 'minecraft:iron_bars', IR,
           'minecraft:iron_bars', 'minecraft:redstone_block', 'minecraft:iron_bars',
           IR, 'minecraft:iron_bars', IR] },

  // ── The rest of the base's own infrastructure ────────────────────────────
  //
  // Every one of these was placed by hand to get the fleet running. Leaving them out of the graph
  // would mean the settlement could build drones and never build the things that COMMISSION and
  // watch them -- permanently dependent on someone reaching in from outside.
  { output: 'computercraft:monitor_normal', yields: 1, inputs: { [ST]: 8, [GP]: 1 },
    station: 'inventory', grid: [ST, ST, ST, ST, GP, ST, ST, ST, ST] },

  // A floppy: paper plus redstone. The hatchery's whole trick is a disk with a bootloader on it,
  // so being able to make blank disks is what makes commissioning repeatable.
  { output: 'computercraft:disk', yields: 1,
    inputs: { 'minecraft:paper': 1, [RD]: 1 }, station: 'inventory' },
  { output: 'minecraft:paper', yields: 3, inputs: { 'minecraft:sugar_cane': 3 },
    station: 'inventory', grid: ['minecraft:sugar_cane', 'minecraft:sugar_cane', 'minecraft:sugar_cane',
                                 null, null, null, null, null, null] },

  // These two are recorded with their REAL inputs even though the fleet cannot complete them.
  //
  // Leaving them out entirely made the planner say "no recipe", which reads as "we forgot to add
  // it". Recorded properly it says what it actually is: a scanner needs an observer (nether quartz)
  // and a chunk loader needs an ender eye (blaze powder), so both are gated behind a NETHER
  // EXPEDITION, not behind more mining. That is a different problem and worth naming as one.
  { output: 'advancedperipherals:geo_scanner', yields: 1,
    inputs: { 'minecraft:diamond': 4, 'computercraft:wired_modem_full': 1,
              'advancedperipherals:peripheral_casing': 1, 'minecraft:redstone_block': 1,
              'minecraft:observer': 1 },
    station: 'inventory',
    grid: ['minecraft:diamond', 'computercraft:wired_modem_full', 'minecraft:diamond',
           'minecraft:diamond', 'advancedperipherals:peripheral_casing', 'minecraft:diamond',
           'minecraft:redstone_block', 'minecraft:observer', 'minecraft:redstone_block'] },

  { output: 'advancedperipherals:chunk_controller', yields: 1,
    inputs: { [IR]: 4, [RD]: 4, 'minecraft:ender_eye': 1 }, station: 'inventory',
    grid: [IR, RD, IR, RD, 'minecraft:ender_eye', RD, IR, RD, IR] },

  // A drone is useless without a tool. Iron rather than diamond: reachable from ore the fleet can
  // actually prospect for, and a turtle digs stone just as well with it.
  { output: 'minecraft:iron_pickaxe', yields: 1, inputs: { [IR]: 3, [S]: 2 }, station: 'inventory',
    grid: [IR, IR, IR, null, S, null, null, S, null] },

  // Smelting. StorageMan already drives furnaces, so these are plannable today.
  { output: 'minecraft:glass', yields: 1, inputs: { 'minecraft:sand': 1 }, station: 'furnace' },
  { output: 'minecraft:iron_ingot', yields: 1, inputs: { 'minecraft:raw_iron': 1 }, station: 'furnace' },
  { output: 'minecraft:stone', yields: 1, inputs: { 'minecraft:cobblestone': 1 }, station: 'furnace' },
];

const BY_OUTPUT = new Map(RECIPES.map((r) => [r.output, r]));

export interface PlanStep {
  /** What this step produces. */
  item: string;
  /** How many are needed once yields are accounted for. */
  need: number;
  /** How many times to run the recipe (or how many to gather). */
  runs: number;
  action: 'craft' | 'smelt' | 'gather' | 'lumber';
  station?: Station;
  /** For gather/lumber: what to actually go and get. */
  block?: string;
  grid?: (string | null)[];
}

export interface Plan {
  goal: string;
  quantity: number;
  /** Dependency order: every step's inputs are produced by steps BEFORE it. */
  steps: PlanStep[];
  /** Materials that are neither craftable nor obtainable. A plan with any of these cannot run. */
  missing: string[];
  /** Drawn straight from storage, no work needed. */
  satisfied: Record<string, number>;
}

/**
 * Expand a goal into ordered jobs.
 *
 * `have` is consulted once per material and then DECREMENTED as the plan allocates it, because the
 * same stack cannot be spent twice. Counting stock independently per branch is the obvious
 * implementation and it silently over-commits: ask for four chests with eight planks in storage
 * and every branch happily claims the same eight.
 */
export function expand(goal: string, quantity: number, have: (item: string) => number): Plan {
  const steps: PlanStep[] = [];
  const missing = new Set<string>();
  const satisfied: Record<string, number> = {};
  const pool = new Map<string, number>();          // remaining stock, spent as we go
  const inProgress = new Set<string>();            // cycle guard

  const take = (item: string, want: number): number => {
    if (!pool.has(item)) pool.set(item, Math.max(0, have(item)));
    const got = Math.min(pool.get(item)!, want);
    if (got > 0) {
      pool.set(item, pool.get(item)! - got);
      satisfied[item] = (satisfied[item] ?? 0) + got;
    }
    return got;
  };

  const visit = (item: string, want: number, depth: number) => {
    if (want <= 0) return;
    // A recipe that consumed its own output would recurse for ever. None do today, but the graph
    // is data and data gets edited -- and the failure mode is a hung planner, not an error.
    if (depth > 12 || inProgress.has(item)) {
      missing.add(item);
      return;
    }

    const short = want - take(item, want);
    if (short <= 0) return;

    const recipe = BY_OUTPUT.get(item);
    if (recipe) {
      const runs = Math.ceil(short / recipe.yields);
      inProgress.add(item);
      // Inputs first, so the emitted list is already in dependency order and the caller can simply
      // execute it front to back without a topological sort.
      for (const [ing, per] of Object.entries(recipe.inputs)) visit(ing, per * runs, depth + 1);
      inProgress.delete(item);
      steps.push({
        item, need: short, runs,
        action: recipe.station === 'furnace' ? 'smelt' : 'craft',
        station: recipe.station, grid: recipe.grid,
      });
      return;
    }

    const source = SOURCES[item];
    if (source) {
      steps.push({ item, need: short, runs: short, action: source.action, block: source.block });
      return;
    }

    // Neither craftable nor obtainable. Naming it is the useful output: "we cannot make a hopper
    // because we have no way to get iron" is actionable; a plan silently missing a step is not.
    missing.add(item);
  };

  visit(goal, quantity, 0);
  return { goal, quantity, steps, missing: [...missing], satisfied };
}

/** Everything the graph can currently produce. Useful for "what can we even build?". */
export function craftable(): string[] {
  return RECIPES.map((r) => r.output).sort();
}
