/**
 * WHAT DOES THE SETTLEMENT ACTUALLY HOLD? ONE ANSWER, FOR THE WHOLE OF HQ.
 *
 * This question was answered SIX times in four different ways, and the copies disagreed on the only
 * part that matters -- what to do when storage cannot be read:
 *
 *   core.ts       readStock() was extracted to fix exactly this, with a comment saying the eight
 *                 lines "were written out three times" -- and then ONE of four call sites adopted
 *                 it. The three survivors never got luaList(), so an object-shaped reply (which is
 *                 what an empty or hole-y Lua table becomes over JSON) threw inside their own catch
 *                 and the planner silently concluded the settlement owned nothing.
 *   supply.ts     runFactories and floorMaterialHeld each kept their own copy, correct but separate,
 *                 so the loop that DISPATCHES on this number could drift from the loop that PLANS
 *                 on it without either being wrong on its own.
 *
 * UNREADABLE IS NOT EMPTY, and that distinction is the whole reason this is a module.
 *
 * `null` means "we could not see the shelves". Zero means "we looked, there is none". Collapsing
 * them is what made the supply loop queue a craft for material already sitting in a chest, and what
 * made a builder dispatch a drone to place two thousand blocks of cobblestone it did not have --
 * believing in stock you have not got strands a drone mid-floor. Every caller has to decide which
 * it wants, and say so, so the decision is visible at the call site instead of buried in a catch.
 */
import { bridge } from '../bridge/ws.js';
import { luaList, field } from '../lua-table.js';

/** One line per item kind, as StorageMan reports it. */
export type StockRow = { name?: string; count?: number };

/**
 * The raw rows, or `null` when storage could not be read at all.
 *
 * `onError` is called with the reason rather than swallowed: "storage timed out" and "storage holds
 * no bricks" used to arrive at the caller as the same value, with nothing anywhere able to tell
 * them apart -- so a network blip read as a genuine shortage and queued work to fix it.
 */
export async function readStockDetail(
  onError?: (why: string) => void,
): Promise<StockRow[] | null> {
  const res: any = await bridge
    .call('StorageMan', 'stock', {}, { timeoutMs: 8000 })
    .catch((err) => {
      onError?.((err as Error)?.message ?? String(err));
      return null;
    });
  // Accept both shapes: PowNet replies are unwrapped by the Bridge, but older callers saw a nested
  // `data`. luaList, not Array.isArray -- see lua-table.ts; an empty Lua table arrives as `{}` and
  // `for...of` over an object throws, which is the bug the unadopted copies kept.
  return luaList<StockRow>(field(res, 'detail'));
}

/** Total held of everything matching `pick`. `null` when storage could not be read. */
export async function readStockWhere(
  pick: (name: string) => boolean,
  onError?: (why: string) => void,
): Promise<number | null> {
  const detail = await readStockDetail(onError);
  if (!detail) return null;
  return detail
    .filter((d) => typeof d?.name === 'string' && pick(d.name))
    .reduce((n, d) => n + (d.count ?? 0), 0);
}

/**
 * Item -> count.
 *
 * `onUnreadable` is deliberately required. A planner may plan against nothing -- over-ordering is
 * recoverable -- but anything that DISPATCHES on the number must refuse instead, and making the
 * caller name which one it is means the choice cannot be made by accident.
 */
export async function readStockMap(
  onUnreadable: 'empty' | 'throw',
  onError?: (why: string) => void,
): Promise<Record<string, number>> {
  const detail = await readStockDetail(onError);
  if (!detail) {
    if (onUnreadable === 'throw') throw new Error('Cannot read storage, so cannot cost the work.');
    return {};
  }
  const stock: Record<string, number> = {};
  for (const d of detail) {
    if (typeof d?.name === 'string') stock[d.name] = (stock[d.name] ?? 0) + (d.count ?? 0);
  }
  return stock;
}
