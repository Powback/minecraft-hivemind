import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { scan } from '../scripts/silence.mjs';

const ROOT = join(__dirname, '../..');
const baseline = JSON.parse(readFileSync(join(__dirname, '../silence-baseline.json'), 'utf8'));

function sources(): string[] {
  const out = readdirSync(join(ROOT, 'lua')).filter((f) => f.endsWith('.lua')).map((f) => `lua/${f}`);
  (function walk(d: string) {
    for (const e of readdirSync(join(ROOT, d), { withFileTypes: true })) {
      const p = `${d}/${e.name}`;
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.ts') && !e.name.includes('.test.')) out.push(p);
    }
  })('hq/src');
  return out.map((p) => join(ROOT, p));
}

/**
 * A FAILURE THAT GOES QUIET IS THE MOST EXPENSIVE PATTERN IN THIS PROJECT.
 *
 * Not one bug -- a shape, repeated, and every instance turns a loud dependency failure into
 * confident wrong output somewhere far away:
 *
 *   `.catch(() => null)` in order.tower: MapServer timed out under load, the catch swallowed it,
 *   every position it would have reported came back "not built", and the tool queued 235 patches
 *   instead of 185. A slow dependency became wrong output with nothing in any log.
 *
 *   `readStock('empty')` in three planners: an unreadable stock read as "the settlement owns
 *   nothing", so the fleet was sent to mine what was already on the shelf.
 *
 *   A discarded `pcall` is the Lua half of the same thing -- the call cannot throw, so the caller
 *   cannot know, so the drone carries on as though it worked.
 *
 * The rule is not "never catch". It is "never catch WITHOUT SAYING SO": logged, counted, or turned
 * into a returned reason is fine; evaporating is not. Genuine best-effort sites carry
 * `silent: allow (<why>)` on the line or the line above, the same exemption every other check here
 * uses -- with the justification written down, so it is a decision rather than a habit.
 */
describe('failures are not swallowed silently', () => {
  const found = scan(sources());
  const counts: Record<string, number> = {};
  for (const f of found) counts[f] = (counts[f] ?? 0) + 1;

  it('no file gains a new silent-failure site', () => {
    const regressions = Object.entries(counts)
      .filter(([k, n]) => n > (baseline.sites[k] ?? 0))
      .map(([k, n]) => `${k}: ${n} sites, baseline allows ${baseline.sites[k] ?? 0}`);
    expect(regressions,
      'A caught error that is neither logged, counted, nor returned as a reason becomes wrong\n' +
      'output somewhere else. Report it, or mark it `silent: allow (<why>)`.').toEqual([]);
  });

  /** May fall, may not rise -- the same ratchet complexity, duplication and adoption use. */
  it('the debt only shrinks', () => {
    const total = found.length;
    const allowed = Object.values(baseline.sites as Record<string, number>).reduce((a, b) => a + b, 0);
    expect(total).toBeLessThanOrEqual(allowed);
  });

  /**
   * A check nobody has seen fail is not a check. Prove it catches the real shapes rather than
   * trusting that it does -- three separate guards went quiet today when code moved under them.
   */
  it('actually detects the shapes it claims to', () => {
    const planted = join(ROOT, 'hq/test/fixtures/silence-canary.ts');
    expect(scan([planted]).length).toBeGreaterThanOrEqual(2);
  });
});
