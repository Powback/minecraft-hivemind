/**
 * LUA TABLES DO NOT SURVIVE JSON AS ONE SHAPE, AND THE AMBIGUITY IS LOAD-BEARING.
 *
 * A Lua table is both list and map. Serialised, one with keys 1..n becomes a JSON array, one with
 * holes or string keys becomes an object -- and an EMPTY one is genuinely ambiguous and generally
 * arrives as `{}`. So the same endpoint returns `[...]`, `{...}` or `{}` depending on its data, and
 * a caller that checks Array.isArray is right two thirds of the time.
 *
 * It has cost real outages twice, both in the same week and in opposite directions:
 *
 *   The sentinel called .map on it, threw, and returned early without reconciling -- so it served a
 *   stale incident with total confidence while blind.
 *
 *   The supply loop checked Array.isArray and treated anything else as "cannot read the task queue;
 *   not dispatching blind". That check exists for a good reason: an unreadable queue must not be
 *   mistaken for an empty one, because dispatching blind fills the queue with duplicates. But an
 *   EMPTY queue arrives as `{}` and was therefore classed unreadable -- so on a fresh world the loop
 *   refused to dispatch anything, which kept the queue empty, which kept it refusing. A cold start
 *   could never begin.
 *
 * The distinction that actually matters is not array-versus-object. It is READABLE versus NOT: a
 * PowNet refusal comes back as a plain string in the same field a success uses. So this returns a
 * list for anything list-shaped including empty, and null only when the answer is not a collection
 * at all -- which is the case the caller must refuse to act on.
 */
export function luaList<T = unknown>(v: unknown): T[] | null {
  if (v == null) return null;                       // absent: nothing was said
  if (Array.isArray(v)) return v as T[];            // 1..n, the easy case
  if (typeof v === 'object') return Object.values(v as Record<string, T>);  // holes, or empty
  return null;                                      // a string is a refusal; a number is nonsense
}

/** Same, but for callers that only need "is this a collection at all". */
export function isLuaList(v: unknown): boolean {
  return luaList(v) !== null;
}

/**
 * READ A FIELD OFF A POWNET REPLY, WRAPPED OR NOT.
 *
 * The Bridge unwraps replies, but SaveWorld-era callers saw a nested `data`, so every consumer
 * hedges: `res?.tasks ?? res?.data?.tasks`. That was written out TWENTY-EIGHT times across HQ.
 *
 * It is not just noise. It is a real question -- "where does the payload live" -- and answering it
 * inline everywhere means a reply shape that changes has to be chased through 28 sites, of which
 * some will be missed; that is exactly how readStock's three unadopted copies came to disagree.
 * It also costs about four branches every time, which is why it shows up in the complexity budget
 * of functions that are otherwise perfectly simple.
 */
// Returns `any` by default: these are untyped wire replies, and every call site this
// replaced was already `any`. Callers that know the shape can supply T.
export function field<T = any>(reply: any, name: string): T {
  return reply?.[name] ?? reply?.data?.[name];
}

/**
 * A NUMERIC field from a Lua reply, or `null` when it is absent or unreadable.
 *
 * `Number(field(r, 'live'))` was written out in three places within a week, and the coercion is the
 * whole point of it: `Number(undefined)` is NaN, which is not a number you can compare but IS a
 * value that flows onward silently. Every one of those sites then wrote its own
 * `Number.isFinite(...) ? ... : null` guard, and a site that forgets it reads a missing field as a
 * live figure -- the shape that had a floor counter advancing on a count that was never taken.
 *
 * Null, never 0: "the module did not say" and "the module said none" are different facts, and this
 * repo's most expensive bugs are the ones that treated them as the same.
 */
export function numField(reply: any, name: string): number | null {
  const n = Number(field(reply, name));
  return Number.isFinite(n) ? n : null;
}
