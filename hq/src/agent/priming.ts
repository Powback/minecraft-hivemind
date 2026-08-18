/**
 * Priming — synthetic conversation the agent boots with.
 *
 * Two jobs, deliberately fused into one mechanism:
 *
 *   1. TEACH. A small model follows demonstrated patterns far more reliably than
 *      described ones. Instead of prose saying "call order.issue with a bounded
 *      region", it opens its context having *already seen itself* do exactly
 *      that, correctly, and having seen the tool_result come back.
 *
 *   2. DELIVER STATE. The final exchange is a real `hive.brief` call whose
 *      tool_result holds the live context pack. The agent therefore wakes up with
 *      current fleet and world state already in hand, in the same shape it would
 *      have fetched it — so its first real turn is an ACTION, not an orientation
 *      round-trip. This matters at small-model scale, where every wasted turn is
 *      a chance to lose the thread.
 *
 * The transcript is fabricated but never fictional: examples are validated
 * against the live schemas (see registry.register) and the brief is real data.
 * We are shortcutting the agent's warm-up, not lying to it.
 *
 * Cache note: priming is a stable prefix, so it caches well. Keep the volatile
 * part (the brief) LAST, or every state change invalidates every teaching turn.
 */
import type { ToolRegistry, TeachExample, ToolDef } from '../tools/registry.js';

export type Msg =
  | { role: 'user'; content: string | ContentBlock[] }
  | { role: 'assistant'; content: string | ContentBlock[] };

export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: unknown }
  | { type: 'tool_result'; tool_use_id: string; content: string; is_error?: boolean };

let seq = 0;
/** Deterministic ids keep the prefix byte-stable, which keeps the cache warm. */
const nextId = (tool: string) => `prime_${tool.replace(/\W/g, '_')}_${++seq}`;

/** One teaching exchange: situation → correct call → result → why. */
function teachTurn(tool: ToolDef, ex: TeachExample): Msg[] {
  const id = nextId(tool.name);
  const msgs: Msg[] = [
    { role: 'user', content: ex.situation },
    { role: 'assistant', content: [{ type: 'tool_use', id, name: tool.name, input: ex.args }] },
    {
      role: 'user',
      content: [{ type: 'tool_result', tool_use_id: id, content: render(ex.result) }],
    },
  ];
  if (ex.takeaway) msgs.push({ role: 'assistant', content: ex.takeaway });
  return msgs;
}

/**
 * Build the full priming prefix for a profile.
 *
 * Order is load-bearing: teaching turns first (stable, cacheable), the live
 * brief last (volatile). Reversing that would blow the prompt cache on every
 * heartbeat, which at fleet scale is most of your token budget.
 */
export function buildPriming(opts: {
  registry: ToolRegistry;
  /** Tools this profile may call; also bounds which lessons are shown. */
  allow: string[];
  /** Live context pack, rendered. Arrives as a tool_result, not as prose. */
  brief: string;
  /** Cap lessons so priming can't crowd out the actual task. */
  maxLessons?: number;
}): Msg[] {
  const { registry, allow, brief, maxLessons = 8 } = opts;
  seq = 0;

  const msgs: Msg[] = [];

  // Teaching turns, in registry order so the prefix is deterministic. We favour
  // tools that can do damage: those are where a wrong call is expensive, so
  // those are where a demonstration pays for its tokens.
  const lessons = registry
    .list(allow)
    .filter((t) => t.teach?.length)
    .sort((a, b) => rank(b) - rank(a))
    .flatMap((t) => (t.teach ?? []).map((ex) => ({ tool: t, ex })))
    .slice(0, maxLessons);

  for (const { tool, ex } of lessons) msgs.push(...teachTurn(tool, ex));

  // Final exchange: the agent "asks" for the situation and receives it. From the
  // model's perspective it has just oriented itself, so the next token it owes
  // is a decision.
  const briefId = nextId('hive.brief');
  msgs.push(
    { role: 'user', content: 'Before acting, get the current situation.' },
    { role: 'assistant', content: [{ type: 'tool_use', id: briefId, name: 'hive.brief', input: {} }] },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: briefId, content: brief }] },
    {
      role: 'assistant',
      content:
        'Situation received. I have the fleet, the active orders and the known world. ' +
        'I will act on this rather than re-querying unless something looks stale.',
    },
  );

  return msgs;
}

/** Destructive lessons are worth the most tokens; reads are worth the least. */
function rank(t: ToolDef): number {
  return t.danger === 'destructive' ? 3 : t.danger === 'mutate' ? 2 : 1;
}

/**
 * Render a tool result the way the real invoke path renders it, so the priming
 * examples and live results are indistinguishable in shape. If these diverge,
 * the model learns to parse a format it will never actually receive.
 */
export function render(result: unknown): string {
  if (typeof result === 'string') return result;
  return JSON.stringify(result, null, 2);
}
