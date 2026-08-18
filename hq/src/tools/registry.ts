/**
 * The contract layer.
 *
 * A HiveMind tool is defined ONCE, here, and that single definition generates
 * every surface the agent touches:
 *
 *     ToolDef ──┬─► JSON Schema        (what the model is allowed to emit)
 *               ├─► runtime validation (what actually reaches a drone)
 *               ├─► skill documentation (how the model learns it)
 *               └─► priming transcript  (the model SEEING it used correctly)
 *
 * This matters more than it looks. The system is meant to end up driven by a
 * small model, and the classic failure mode there is drift: the docs describe
 * one shape, the schema permits another, the examples show a third. A small
 * model has no slack to reconcile that. Deriving all four from one source makes
 * the inconsistency unrepresentable.
 *
 * It is also exactly the trick PowNet V2 already used — `RegisterCallable`
 * shipped typed `params` so the remote could generate its wizard GUI. Same idea,
 * different consumer.
 */
import { z } from 'zod';
import { zodToJsonSchema } from 'zod-to-json-schema';

/** How much damage a tool can do. Drives confirmation + audit, never hidden. */
export type Danger =
  | 'read'        // cannot change the world
  | 'mutate'      // changes fleet/task state, reversible
  | 'destructive';// breaks or places blocks; bounded and abortable, never silent

/**
 * A worked example. Not decoration — this is compiled into the priming
 * transcript the agent boots with, so `args` MUST validate against `params`.
 * A wrong example teaches a small model to be wrong, so we check them at load.
 */
export interface TeachExample<P = unknown> {
  /** The situation, phrased as the operator would phrase it. */
  situation: string;
  /** The call a competent operator makes. Validated at registry build time. */
  args: P;
  /** What comes back. Keep it realistic — including realistic failure. */
  result: unknown;
  /** One line on why this was the right call. Anchors the pattern. */
  takeaway?: string;
}

export interface ToolDef<P = any, R = any> {
  /** Dotted and stable: `fleet.status`, `order.issue`. Renaming breaks priming. */
  name: string;
  /** One line. This is what the model reads when choosing a tool — make it decisive. */
  summary: string;
  /** Fuller prose for the skill doc. Say when NOT to use it; that's the part models miss. */
  description: string;
  /**
   * Input and output types are decoupled on purpose: `.default()` and other
   * transforms mean what the model may OMIT differs from what the handler
   * RECEIVES. Pinning both to P would force handlers to re-check defaults that
   * zod has already applied.
   */
  params: z.ZodType<P, z.ZodTypeDef, any>;
  /** Plain words describing the return shape. Models reason better over prose here. */
  returns: string;
  danger: Danger;
  /** Hard limits, stated to the model rather than only enforced silently. */
  bounds?: string;
  /**
   * Include this tool's output in the boot context pack. Use sparingly: the
   * point is that the agent wakes up already knowing the state it always needs,
   * not that it wakes up with everything.
   */
  preload?: boolean;
  teach?: TeachExample<P>[];
  handler: (args: P, ctx: ToolCtx) => Promise<R>;
}

/** Everything a handler is allowed to reach. Keeps tools testable and honest. */
export interface ToolCtx {
  /** Who is calling — profile name. Audited, and used for tool allowlisting. */
  agent: string;
  /** Monotonic id for correlating the call across HQ, bridge, and drone logs. */
  callId: string;
  log: (msg: string, data?: unknown) => void;
}

export class ToolError extends Error {
  constructor(message: string, readonly fix?: string) {
    super(message);
  }
}

/** Result envelope. Errors are values, never thrown across the agent boundary. */
export type ToolResult =
  | { ok: true; data: unknown }
  | { ok: false; error: string; fix?: string };

export class ToolRegistry {
  private tools = new Map<string, ToolDef>();

  register<P, R>(def: ToolDef<P, R>): void {
    if (this.tools.has(def.name)) throw new Error(`duplicate tool: ${def.name}`);
    // Validate the teaching examples NOW rather than shipping a lesson that
    // contradicts the schema. A bad example is worse than no example: the model
    // will imitate it and then be rejected at runtime, with no idea why.
    for (const [i, ex] of (def.teach ?? []).entries()) {
      const parsed = def.params.safeParse(ex.args);
      if (!parsed.success) {
        throw new Error(
          `tool "${def.name}" teach[${i}] does not satisfy its own schema: ` +
            parsed.error.issues.map((x) => `${x.path.join('.')}: ${x.message}`).join('; '),
        );
      }
    }
    this.tools.set(def.name, def as ToolDef);
  }

  get(name: string): ToolDef | undefined { return this.tools.get(name); }
  list(allow?: string[]): ToolDef[] {
    const all = [...this.tools.values()];
    return allow ? all.filter((t) => allow.includes(t.name)) : all;
  }

  /** Anthropic tool-use definitions, filtered to what a profile may call. */
  toAnthropicTools(allow?: string[]) {
    return this.list(allow).map((t) => ({
      name: t.name,
      description: [t.summary, t.bounds && `Limits: ${t.bounds}`].filter(Boolean).join('\n'),
      input_schema: jsonSchemaFor(t),
    }));
  }

  /**
   * Invoke with validation. The rejection path is the important one: a small
   * model cannot debug a schema dump, so failures come back as an instruction —
   * what was wrong and what to do instead — in the tool_result it already reads.
   */
  async invoke(name: string, rawArgs: unknown, ctx: ToolCtx): Promise<ToolResult> {
    const tool = this.tools.get(name);
    if (!tool) {
      const near = nearest(name, [...this.tools.keys()]);
      return {
        ok: false,
        error: `No tool named "${name}".`,
        fix: near ? `Did you mean "${near}"? Call that instead.` : `Available: ${[...this.tools.keys()].join(', ')}`,
      };
    }
    const parsed = tool.params.safeParse(rawArgs);
    if (!parsed.success) {
      const issues = parsed.error.issues.map((i) => {
        const at = i.path.length ? `"${i.path.join('.')}"` : 'the arguments';
        return `${at}: ${i.message}`;
      });
      return {
        ok: false,
        error: `Invalid arguments for ${name} — ${issues.join('; ')}.`,
        // Tell it precisely how to retry. "Invalid input" teaches nothing.
        fix: `Re-send ${name} with those fields corrected. ${tool.bounds ?? ''}`.trim(),
      };
    }
    try {
      const data = await tool.handler(parsed.data, ctx);
      return { ok: true, data };
    } catch (err) {
      if (err instanceof ToolError) return { ok: false, error: err.message, fix: err.fix };
      ctx.log(`tool ${name} threw`, err);
      return {
        ok: false,
        error: `${name} failed: ${(err as Error).message}`,
        fix: 'This is a HiveMind fault, not a bad call. Report it and try a different approach.',
      };
    }
  }
}

export function jsonSchemaFor(t: ToolDef): Record<string, unknown> {
  return zodToJsonSchema(t.params, { target: 'jsonSchema7', $refStrategy: 'none' }) as Record<string, unknown>;
}

/** Cheap edit distance, only used to turn a typo into a usable correction. */
function nearest(input: string, options: string[]): string | undefined {
  let best: string | undefined, bestScore = Infinity;
  for (const o of options) {
    const d = levenshtein(input, o);
    if (d < bestScore) { bestScore = d; best = o; }
  }
  return bestScore <= Math.max(3, input.length / 3) ? best : undefined;
}

function levenshtein(a: string, b: string): number {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return dp[a.length][b.length];
}

export const registry = new ToolRegistry();
