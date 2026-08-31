/**
 * THE FLEET'S MESSAGING LAYER, RUN FOR REAL.
 *
 * Every other Lua guard in this repo reads the source as text. This one LOADS it: `lua/PowNet` is
 * executed under stubbed CC APIs and its reply decoding is exercised directly, so the thing being
 * checked is the code that ships rather than a pattern that resembles it.
 *
 * It exists because of the most expensive single line this codebase has produced.
 * `sendAndWaitForResponse` returned `reply.data` and nothing else, so an endpoint that ends
 * `return true` -- succeeded, nothing to report -- answered with nil, which is the SAME value the
 * function returns when nobody replies at all. Success and silence were the same value.
 *
 * `OnHeartbeat` ends `return true`. So DroneMan received every heartbeat from every drone, kept its
 * registry current and replied to every one, while each drone read the nil, logged "tower
 * unreachable", counted a miss, and eventually flew RecoverLink() back down its own breadcrumbs to
 * restore a link that had never dropped. Weeks of "the drones keep going offline" was this. They
 * were never offline. Measured at the end: D4 sat 2.4 blocks from DroneMan reporting no answer,
 * while a probe round-trip to that same module from that same drone succeeded.
 *
 * A function whose success value equals its failure value cannot be used correctly by anyone, and
 * no amount of care at the call sites fixes it. So the invariant is pinned here, in behaviour.
 */
import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';

const LUA_DIR = path.resolve(__dirname, '../../lua');
const HARNESS = path.resolve(__dirname, 'pownet-reply.harness.lua');

function haveLua(bin: string): boolean {
  try { execFileSync(bin, ['-v'], { stdio: 'ignore' }); return true; } catch { return false; }
}

const MISSING = [
  'The Lua guards need a host Lua: brew install lua',
  'These are the only checks that run the fleet\'s code rather than reading it, so skipping them',
  'quietly would leave the repo believing it is covered. Install lua or delete this file knowingly.',
].join('\n');

describe('PowNet reply decoding', () => {
  it('has a host lua to run against', () => {
    expect(haveLua('lua'), MISSING).toBe(true);
  });

  /** name=type:value lines from the harness, parsed into a map. */
  function run(): Record<string, string> {
    const out = execFileSync('lua', [HARNESS, path.join(LUA_DIR, 'PowNet')], { encoding: 'utf8' });
    const map: Record<string, string> = {};
    for (const line of out.trim().split('\n')) {
      const i = line.indexOf('=');
      if (i > 0) map[line.slice(0, i)] = line.slice(i + 1);
    }
    return map;
  }

  it('an answer with no payload is not reported as silence', () => {
    // THE REGRESSION. `return true` from a handler must not reach the caller as nil.
    expect(run().payloadless, [
      'A handler that returned true with no data came back as nil -- the same value this function',
      'returns when nobody answered. That is what made every drone in the fleet believe it was out',
      'of radio range while DroneMan was answering every single heartbeat.',
    ].join('\n')).toBe('boolean:true');
  });

  it('a refusal with no reason is false, not nil', () => {
    // Callers branch on `== false` to mean "refused" and on nil to mean "unreachable". Collapsing
    // the two loses the distinction in the other direction.
    expect(run().bareRefusal).toBe('boolean:false');
  });

  it('silence is still silence', () => {
    // The fix must not make an unanswered call look successful -- that would be the same bug with
    // the sign flipped, and far more dangerous.
    expect(run().silence).toBe('boolean:false');
  });

  it('a real payload is passed through untouched', () => {
    expect(run().withData).toBe('number:7');
  });

  it('a refusal that carries a reason still surfaces the reason', () => {
    // reregisterIfDisowned reads this string. Flattening it to `false` would strand every drone
    // whose registration DroneMan has lost.
    expect(run().refusal).toBe('string:unregistered');
  });
});

describe('every Lua file compiles', () => {
  /**
   * There was no syntax check on this code at all, and one line was the reason.
   *
   * `dump()` assigned to a generic-for control variable. CC's Lua accepts that; Lua 5.4 rejects it
   * at COMPILE time -- so `luac -p lua/PowNet` failed on a line that was never a bug, and the file
   * every module and every drone depends on was the one file no syntax check could read. It looked
   * like a host/CC incompatibility to be worked around rather than a one-line fix.
   */
  const files = readdirSync(LUA_DIR).filter((f) => !f.startsWith('.'));
  for (const f of files) {
    const full = path.join(LUA_DIR, f);
    it(f, () => {
      expect(haveLua('luac'), MISSING).toBe(true);
      if (!existsSync(full) || readdirSync(LUA_DIR, { withFileTypes: true })
            .find((d) => d.name === f)?.isDirectory()) return;
      // luac -p parses without emitting. Any output at all is a syntax error.
      expect(() => execFileSync('luac', ['-p', full], { stdio: 'pipe' })).not.toThrow();
    });
  }
});
