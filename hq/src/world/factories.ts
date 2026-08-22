/**
 * Factories, and the chain between them.
 *
 * A factory is not a new kind of thing. It is a plot (where), a recipe (what), an input chest and
 * an output chest (how material gets in and out), and a standing intent to keep producing. Every
 * one of those already existed separately; this is what makes them one object you can reason about.
 *
 * The important idea here is that CHAINING IS DERIVED, NOT CONFIGURED.
 *
 * If a computer factory needs stone and a stone factory produces it, the route between them is
 * already implied by the recipe graph -- nobody should have to state it, and a human stating it by
 * hand is how you end up with a plant that is subtly mis-wired in a way nothing can detect. So the
 * links are computed from RECIPES, and adding a factory rewires the plant automatically.
 *
 * The routes themselves cost nothing to run: they are wired-modem transfers serviced on StorageMan's
 * tick, not drones carrying crates. Hauling is what you do before you can afford piping.
 */
import { RECIPES, SOURCES } from './recipes.js';

export interface Factory {
  /** Stable name, used by routes and orders. */
  name: string;
  /** What it makes. An item id with a recipe. */
  produces: string;
  /** The plot it occupies. */
  plot: string;
  /** Network names of its chests. Assigned when the physical build happens. */
  input?: string;
  output?: string;
  status: 'planned' | 'building' | 'running' | 'idle';
}

export interface Link {
  /** The factory producing the material. */
  from: string;
  /** The factory consuming it. */
  to: string;
  item: string;
}

/** What a factory consumes, straight from the recipe it exists to run. */
export function inputsOf(produces: string): string[] {
  const r = RECIPES.find((x) => x.output === produces);
  return r ? Object.keys(r.inputs) : [];
}

/**
 * Every link implied by the recipes, given a set of factories.
 *
 * Derived on demand rather than stored, so it cannot drift out of step with the recipe graph. A
 * stored wiring diagram is a second source of truth about the same fact, and the two disagree the
 * moment a recipe changes.
 */
export function chain(factories: Factory[]): Link[] {
  const producers = new Map<string, string[]>();
  for (const f of factories) {
    const list = producers.get(f.produces) ?? [];
    list.push(f.name);
    producers.set(f.produces, list);
  }

  const links: Link[] = [];
  for (const f of factories) {
    for (const item of inputsOf(f.produces)) {
      for (const from of producers.get(item) ?? []) {
        // A factory feeding itself is not a link, it is a loop -- and a loop in a routing table
        // moves items back and forth for ever while looking busy.
        if (from !== f.name) links.push({ from, to: f.name, item });
      }
    }
  }
  return links;
}

/**
 * Inputs a factory needs that NOTHING in the plant produces.
 *
 * These are the plant's real boundary: they must arrive from mining, smelting or the outside world,
 * and a chain that quietly assumes they appear is a chain that stalls with no explanation. Naming
 * them is more useful than a diagram of the parts that already work.
 */
export function unmetInputs(factories: Factory[]): Array<{ factory: string; item: string; source: string }> {
  const made = new Set(factories.map((f) => f.produces));
  const out: Array<{ factory: string; item: string; source: string }> = [];
  for (const f of factories) {
    for (const item of inputsOf(f.produces)) {
      if (made.has(item)) continue;
      const src = SOURCES[item];
      out.push({
        factory: f.name,
        item,
        source: src ? src.action : (RECIPES.some((r) => r.output === item) ? 'craftable, no factory' : 'no source'),
      });
    }
  }
  return out;
}

/**
 * Order the factories so every one is built after the things it depends on.
 *
 * Building a turtle line before the computer line that feeds it produces a plant that looks
 * complete and cannot run. Cycles are reported rather than thrown: the recipe graph should not
 * contain any, and if one appears, saying which is far more useful than failing to sort.
 */
export function buildOrder(factories: Factory[]): { order: string[]; cycles: string[] } {
  const byName = new Map(factories.map((f) => [f.name, f]));
  const links = chain(factories);
  const deps = new Map<string, Set<string>>();
  for (const f of factories) deps.set(f.name, new Set());
  for (const l of links) deps.get(l.to)!.add(l.from);

  const order: string[] = [];
  const done = new Set<string>();
  let progress = true;
  while (progress && order.length < factories.length) {
    progress = false;
    for (const f of factories) {
      if (done.has(f.name)) continue;
      const need = deps.get(f.name)!;
      if ([...need].every((n) => done.has(n))) {
        order.push(f.name);
        done.add(f.name);
        progress = true;
      }
    }
  }
  const cycles = factories.filter((f) => !done.has(f.name)).map((f) => f.name);
  void byName;
  return { order, cycles };
}
