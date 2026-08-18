/**
 * Locks the teach-example volumes in place.
 *
 * A teach example is compiled into the priming transcript the agent boots with,
 * so a volume in an example that disagrees with the bounds the example passes
 * is a lesson that is subtly wrong. The model imitates the number, not the
 * formula, and then produces plausible-looking but inconsistent region reports.
 *
 * This test walks every registered tool, re-derives the volume from each teach
 * example's bounds, and asserts it matches whatever the example's result claims
 * — whether that is a `volume` field or the number embedded in an error string.
 *
 * Run with: npm test
 */
import assert from 'node:assert';
import { registry } from './registry.js';
import './core.js';

function volumeOf(min: { x: number; y: number; z: number }, max: { x: number; y: number; z: number }): number {
  return (max.x - min.x + 1) * (max.y - min.y + 1) * (max.z - min.z + 1);
}

/**
 * Teach examples carry bounds two ways: `args.bounds` (order.issue) and
 * top-level `args.min`/`args.max` (world.query). Resolve both.
 */
function boundsOf(args: unknown): {
  min: { x: number; y: number; z: number };
  max: { x: number; y: number; z: number };
} | null {
  if (typeof args !== 'object' || args === null) return null;
  const a = args as Record<string, unknown>;
  if (a.bounds && typeof a.bounds === 'object')
    return a.bounds as { min: { x: number; y: number; z: number }; max: { x: number; y: number; z: number } };
  if (a.min && a.max)
    return { min: a.min as { x: number; y: number; z: number }, max: a.max as { x: number; y: number; z: number } };
  return null;
}

const tools = registry.list();
assert.ok(tools.length > 0, `expected at least one registered tool, got ${tools.length}`);

let checks = 0;
for (const tool of tools) {
  for (const ex of tool.teach ?? []) {
    const bounds = boundsOf(ex.args);
    if (!bounds) continue;
    const expected = volumeOf(bounds.min, bounds.max);

    const result = ex.result;
    if (typeof result !== 'object' || result === null) continue;
    const r = result as Record<string, unknown>;

    if ('volume' in r) {
      assert.strictEqual(r.volume, expected,
        `${tool.name} teach example: result.volume is ${r.volume} but bounds imply ${expected}`);
      checks++;
    }

    if (typeof r.error === 'string') {
      const m = r.error.match(/Region is (\d+) blocks/);
      if (m) {
        assert.strictEqual(Number(m[1]), expected,
          `${tool.name} teach example: error says ${m[1]} blocks but bounds imply ${expected}`);
        checks++;
      }
    }
  }
}

// The three examples this test exists to lock in. Named so a regression on
// any of them is obvious in the assertion message.
assert.strictEqual(
  volumeOf({ x: 120, y: 64, z: -50 }, { x: 129, y: 68, z: -41 }), 500,
  'order.issue teach[0]: 10x5x10 pad should be 500 blocks',
);
assert.strictEqual(
  volumeOf({ x: 0, y: 0, z: 0 }, { x: 200, y: 60, z: 200 }), 2464461,
  'order.issue teach[1]: 201x61x201 quarry should be 2464461 blocks',
);
assert.strictEqual(
  volumeOf({ x: 100, y: 60, z: -60 }, { x: 130, y: 90, z: -30 }), 29791,
  'world.query teach[0]: 31x31x31 region should be 29791 blocks',
);

assert.ok(checks >= 3, `expected at least 3 teach-example volume checks, got ${checks}`);
console.log(`core.test: OK — ${checks} teach-example volume checks pass across ${tools.length} tools`);
